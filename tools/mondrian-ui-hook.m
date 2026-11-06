/* Opt-in containermanagerd/backboardd diagnostics for the mondrian bring-up test. */
#import <objc/objc.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/thread_act.h>
#import <mach/thread_state.h>
#import <mach/thread_info.h>
#import <dlfcn.h>

#include <fcntl.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * The daemons' stderr is /dev/null, so the traces go to the system console:
 * on this port that is the framebuffer console, the only readable channel
 * before the UI works. Keep the lines short: they share the screen with the
 * kernel log.
 */
static int console_fd = -1;

static void
say(const char *message)
{
	size_t len = __builtin_strlen(message);

	(void)write(STDERR_FILENO, message, len);
	if (console_fd >= 0) {
		(void)write(console_fd, message, len);
	}
}

/*
 * Log-only uncaught-exception handler: the daemons' stderr is discarded and
 * an exception otherwise leaves no symbol behind. It names the exception and
 * the call chain; it does not change behaviour.
 */
static void
mondrian_uncaught(NSException *e)
{
	void *frames[16];
	int n, i;

	say("MONDRIAN UI: uncaught ");
	say([[e name] UTF8String] ?: "?");
	say(": ");
	say([[e reason] UTF8String] ?: "?");
	say("\n");
	n = backtrace(frames, 16);
	for (i = 0; i < n; i++) {
		Dl_info info;
		char buf[256];

		if (dladdr(frames[i], &info)) {
			snprintf(buf, sizeof(buf), "  #%d %p %s +%ld\n", i, frames[i],
			    info.dli_sname ?: "?",
			    (long)((char *)frames[i] - (char *)info.dli_saddr));
			say(buf);
		}
	}
}

/*
 * CA's display path sends -length to what should be a string but is an
 * NSNumber. The uncaught handler only sees the throw site; this interposer
 * logs the caller's stack at the call site and then preserves the original
 * doesNotRecognizeSelector crash.
 */
static NSUInteger
mondrian_number_length(id self, SEL _cmd)
{
	void *frames[16];
	int n, i;

	say("MONDRIAN UI: __NSCFNumber length called\n");
	n = backtrace(frames, 16);
	for (i = 0; i < n; i++) {
		Dl_info info;
		char buf[192];

		if (dladdr(frames[i], &info)) {
			snprintf(buf, sizeof(buf), "  L#%d %p %s +%ld\n", i, frames[i],
			    info.dli_sname ?: "?",
			    (long)((char *)frames[i] - (char *)info.dli_saddr));
			say(buf);
		}
	}
	[self doesNotRecognizeSelector:_cmd];
	return 0;
}

static void
install_number_length_hook(void)
{
	Class cls = NSClassFromString(@"__NSCFNumber");

	if (cls != Nil && class_addMethod(cls, @selector(length),
	    (IMP)mondrian_number_length, "Q@:")) {
		say("MONDRIAN UI: __NSCFNumber length hook installed\n");
	} else {
		say("MONDRIAN UI: __NSCFNumber length hook failed\n");
	}
}

static void
say_pid(const char *what)
{
	char buf[64];
	int n = snprintf(buf, sizeof(buf), "MONDRIAN %s pid %d\n", what, getpid());

	if (n > 0) {
		say(buf);
	}
}

/*
 * backboardd can die or block without a kernel CRASH line when it exits by
 * itself. A slow heartbeat proves the image is loaded and alive, and the
 * last beat tells how far it got before the screen stopped.
 */
static void *
heartbeat(void *unused)
{
	(void)unused;
	for (int i = 0; i < 30; i++) {
		sleep(2);
		say("MONDRIAN UI: heartbeat\n");
	}
	return NULL;
}

static mach_port_t mondrian_main_thread = MACH_PORT_NULL;

/*
 * B: a periodic sampler of the main thread. Every five seconds it takes 200
 * stacks a millisecond apart, counts every return address and prints the six
 * hottest symbols plus the thread's cpu_usage and run_state. That separates
 * "the main thread is busy in the rasterizer" (high cpu, hot CA symbols) from
 * "it waits" (low cpu) without Instruments. The sampling itself costs about
 * 200 ms of a helper thread every five seconds.
 */
#define MONDRIAN_HOT_MAX		256
#define MONDRIAN_SAMPLE_BURST	200

struct mondrian_hot {
	uint64_t addr;
	uint32_t count;
};

static struct mondrian_hot mondrian_hot[MONDRIAN_HOT_MAX];
static int mondrian_hot_count;

static void
hot_add(uint64_t addr)
{
	if (addr < 0x100000000ULL) {
		return;
	}
	for (int i = 0; i < mondrian_hot_count; i++) {
		if (mondrian_hot[i].addr == addr) {
			mondrian_hot[i].count++;
			return;
		}
	}
	if (mondrian_hot_count < MONDRIAN_HOT_MAX) {
		mondrian_hot[mondrian_hot_count].addr = addr;
		mondrian_hot[mondrian_hot_count].count = 1;
		mondrian_hot_count++;
	}
}

static mach_port_t mondrian_target_thread = MACH_PORT_NULL;

/*
 * The main thread of backboardd/SpringBoard only waits in its run loop: the
 * rasterizer runs in a CoreAnimation thread. Pick the busiest thread of the
 * task (the sampler's own excluded) and sample that one.
 */
static mach_port_t
busiest_thread(int *cpu_out)
{
	thread_act_array_t list = NULL;
	mach_msg_type_number_t n = 0;
	mach_port_t self = mach_thread_self();
	mach_port_t best = MACH_PORT_NULL;
	int best_cpu = -1;

	if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) {
		return MACH_PORT_NULL;
	}
	for (mach_msg_type_number_t i = 0; i < n; i++) {
		struct thread_basic_info info;
		mach_msg_type_number_t icount = THREAD_BASIC_INFO_COUNT;

		if (list[i] == self) {
			continue;
		}
		if (thread_info(list[i], THREAD_BASIC_INFO,
		    (thread_info_t)&info, &icount) == KERN_SUCCESS) {
			if ((int)info.cpu_usage > best_cpu) {
				best_cpu = (int)info.cpu_usage;
				best = list[i];
			}
		}
	}
	/* Keep the winner, drop the rest of the array (the ports stay valid). */
	if (best != MACH_PORT_NULL) {
		mach_port_mod_refs(mach_task_self(), best, MACH_PORT_RIGHT_SEND, 1);
	}
	vm_deallocate(mach_task_self(), (vm_address_t)list,
	    n * sizeof(thread_act_t));
	mach_port_deallocate(mach_task_self(), self);
	if (cpu_out != NULL) {
		*cpu_out = best_cpu;
	}
	return best;
}

static void
sample_main_thread_once(mach_port_t target)
{
	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	uint64_t fp;
	kern_return_t kr;

	kr = thread_get_state(target, ARM_THREAD_STATE64,
	    (thread_state_t)&state, &count);
	if (kr != KERN_SUCCESS) {
		return;
	}
	hot_add(state.__pc);
	fp = state.__fp;
	for (int i = 0; i < 10 && fp >= 0x100000000ULL; i++) {
		uint64_t frame[2];
		vm_size_t out = 0;

		kr = vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
		    sizeof(frame), (vm_address_t)frame, &out);
		if (kr != KERN_SUCCESS || out != sizeof(frame) || frame[1] == 0) {
			break;
		}
		hot_add(frame[1]);
		fp = frame[0];
	}
}

static void *
sampler(void *unused)
{
	(void)unused;
	for (;;) {
		struct thread_basic_info info;
		mach_msg_type_number_t icount = THREAD_BASIC_INFO_COUNT;
		char line[200];
		int cpu = -1, run = -1;
		int i, k;

		sleep(5);
		if (mondrian_target_thread != MACH_PORT_NULL) {
			mach_port_deallocate(mach_task_self(), mondrian_target_thread);
			mondrian_target_thread = MACH_PORT_NULL;
		}
		mondrian_target_thread = busiest_thread(&cpu);
		if (mondrian_target_thread == MACH_PORT_NULL) {
			say("MONDRIAN UI: no threads\n");
			continue;
		}
		mondrian_hot_count = 0;
		for (i = 0; i < MONDRIAN_SAMPLE_BURST; i++) {
			sample_main_thread_once(mondrian_target_thread);
			usleep(1000);
		}
		if (thread_info(mondrian_target_thread, THREAD_BASIC_INFO,
		    (thread_info_t)&info, &icount) == KERN_SUCCESS) {
			cpu = info.cpu_usage;
			run = info.run_state;
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: sample n %d cpu %d run %d\n",
		    mondrian_hot_count, cpu, run);
		say(line);
		for (k = 0; k < 6 && mondrian_hot_count > 0; k++) {
			int best = 0;
			Dl_info dl;
			const char *name = "?";

			for (i = 1; i < mondrian_hot_count; i++) {
				if (mondrian_hot[i].count > mondrian_hot[best].count) {
					best = i;
				}
			}
			if (mondrian_hot[best].count < 2) {
				break;
			}
			if (dladdr((void *)mondrian_hot[best].addr, &dl) != 0 &&
			    dl.dli_sname != NULL) {
				name = dl.dli_sname;
			}
			snprintf(line, sizeof(line), "MONDRIAN UI: hot %u %llx %s\n",
			    mondrian_hot[best].count,
			    (unsigned long long)mondrian_hot[best].addr, name);
			say(line);
			mondrian_hot[best].count = 0;
		}
	}
	return NULL;
}

static void
start_heartbeat(void)
{
	pthread_t thread;

	mondrian_main_thread = mach_thread_self();
	(void)pthread_create(&thread, NULL, heartbeat, NULL);
	(void)pthread_create(&thread, NULL, sampler, NULL);
}

static int
is_boolean_encoding(const char *type)
{
	if (type == NULL) {
		return 0;
	}
	while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V') {
		type++;
	}
	return *type == 'B' || *type == 'c';
}

static int
is_void_encoding(const char *type)
{
	if (type == NULL) {
		return 0;
	}
	while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V') {
		type++;
	}
	return *type == 'v';
}

static BOOL
mondrian_personas_disabled(id self, SEL selector)
{
	(void)self;
	(void)selector;
	return NO;
}

static void (*original_detect_displays)(id, SEL);

static void
mondrian_detect_displays(id self, SEL selector)
{
	say("MONDRIAN UI: _detectDisplays enter\n");
	original_detect_displays(self, selector);
	say("MONDRIAN UI: _detectDisplays return\n");
}

static void
install_personas_hook(void)
{
	Class cls = objc_getClass("MCMUserIdentityCache");
	SEL selector = sel_registerName("personasAreSupported");
	Method method = cls != Nil ? class_getClassMethod(cls, selector) : NULL;
	char return_type[16] = { 0 };

	if (cls == Nil) {
		return;
	}
	if (method == NULL) {
		say("MONDRIAN personas hook: selector missing; unchanged\n");
		return;
	}
	method_getReturnType(method, return_type, sizeof(return_type));
	if (method_getNumberOfArguments(method) != 2 || !is_boolean_encoding(return_type)) {
		say("MONDRIAN personas hook: unexpected method signature; unchanged\n");
		return;
	}
	(void)method_setImplementation(method, (IMP)mondrian_personas_disabled);
	say("MONDRIAN personas hook: personasAreSupported -> NO\n");
}

static void
install_display_diagnostic(void)
{
	Class cls = objc_getClass("CAWindowServer");
	SEL selector = sel_registerName("_detectDisplays");
	Method method = cls != Nil ? class_getInstanceMethod(cls, selector) : NULL;
	char return_type[16] = { 0 };
	IMP original;

	if (cls == Nil) {
		say("MONDRIAN UI: CAWindowServer missing\n");
		return;
	}
	if (method == NULL) {
		say("MONDRIAN UI: CAWindowServer._detectDisplays missing\n");
		return;
	}
	method_getReturnType(method, return_type, sizeof(return_type));
	if (method_getNumberOfArguments(method) != 2 || !is_void_encoding(return_type)) {
		say("MONDRIAN UI: _detectDisplays signature mismatch; unchanged\n");
		return;
	}
	original = method_getImplementation(method);
	if (original == NULL) {
		say("MONDRIAN UI: _detectDisplays has no implementation; unchanged\n");
		return;
	}
	original_detect_displays = (void (*)(id, SEL))method_setImplementation(method, (IMP)mondrian_detect_displays);
	if (original_detect_displays == NULL) {
		say("MONDRIAN UI: _detectDisplays hook failed\n");
		return;
	}
	say("MONDRIAN UI: _detectDisplays hook installed (runtime lookup)\n");
}

/*
 * SpringBoard asks MobileActivation for the activation state before it shows
 * the lock screen (-[SBLockdownManager _setupActivationState], a synchronous
 * XPC call). On hardware that is not an iPhone nothing answers, the state
 * stays 0, and the boot sits at the Apple logo for ever. Force the state the
 * lock screen wants and skip the setup assistant.
 */
static int mondrian_activation_offset = -1;

/*
 * What SpringBoard asks before it shows anything is -[SBSetupManager
 * isSetupRequired], not the lockdown activation state: on a root that was just
 * flashed the answer is yes, SpringBoard runs budd instead of the lock screen,
 * and SBLockdownManager is never created. Print the class's selectors and
 * ivars once (the log is the only way to learn the names on this build), then
 * answer no to the two questions that gate the lock screen.
 */
static void
mondrian_dump_class(const char *name)
{
	Class cls = objc_getClass(name);
	Method *methods;
	Ivar *ivars;
	unsigned int count = 0, i;
	char line[160];
	const char *name_of;

	if (cls == Nil) {
		snprintf(line, sizeof(line), "MONDRIAN UI: %s missing\n", name);
		say(line);
		return;
	}
	methods = class_copyMethodList(cls, &count);
	snprintf(line, sizeof(line), "MONDRIAN UI: %s %u methods\n", name, count);
	say(line);
	for (i = 0; i < count; i++) {
		name_of = sel_getName(method_getName(methods[i]));
		if (strstr(name_of, "etup") == NULL && strstr(name_of, "ctiv") == NULL &&
		    strstr(name_of, "ock") == NULL && strstr(name_of, "State") == NULL) {
			continue;
		}
		snprintf(line, sizeof(line), "  %s\n", name_of);
		say(line);
	}
	free(methods);
	ivars = class_copyIvarList(cls, &count);
	snprintf(line, sizeof(line), "MONDRIAN UI: %s %u ivars\n", name, count);
	say(line);
	for (i = 0; i < count; i++) {
		snprintf(line, sizeof(line), "  %s %s\n", ivar_getName(ivars[i]),
		    ivar_getTypeEncoding(ivars[i]) != NULL ? ivar_getTypeEncoding(ivars[i]) : "?");
		say(line);
	}
	free(ivars);
}

/*
 * The real gate is -isInSetupMode (the class has 24 methods, and the dump
 * showed isInSetupMode, _isInSetupMode, isInSetupModeReadyToExit and
 * isInSetupModeForDeviceMigration; there is no -isSetupRequired). Answering no
 * there and yes to "ready to exit" is what lets SpringBoard build the lock
 * screen instead of parking in setup mode.
 */
static BOOL
mondrian_answer_no(id self, SEL selector)
{
	char line[96];

	(void)self;
	snprintf(line, sizeof(line), "MONDRIAN UI: %s -> NO\n", sel_getName(selector));
	say(line);
	return NO;
}

static BOOL
mondrian_answer_yes(id self, SEL selector)
{
	char line[96];

	(void)self;
	snprintf(line, sizeof(line), "MONDRIAN UI: %s -> YES\n", sel_getName(selector));
	say(line);
	return YES;
}

static void
mondrian_setup_activation_state(id self, __unused SEL selector)
{
	if (mondrian_activation_offset < 0) {
		return;
	}
	*(int *)((char *)self + mondrian_activation_offset) = 2;      /* activated */
	say("MONDRIAN UI: SBLockdownManager activation -> 2\n");
}

static void (*original_set_setup_reason)(id, SEL, long);

static void
mondrian_set_setup_reason(id self, SEL selector, long reason)
{
	if (reason != 0) {
		say("MONDRIAN UI: SpringBoard wants the setup assistant; skipped\n");
	}
	if (original_set_setup_reason != NULL) {
		original_set_setup_reason(self, selector, 0);
	}
}

/*
 * The setup path is decided by SBSetupManager, not by -isInSetupMode alone:
 * -updateInSetupMode and the setup-process notification are the entry points
 * that present the assistant. Read the real ivar type from the runtime (the
 * dump prints it), force the reason to zero before those methods run, and
 * log every call so a boot log says which path SpringBoard took.
 */
static ptrdiff_t mondrian_setup_reason_offset = -1;
static char mondrian_setup_reason_type;
static void (*original_update_setup)(id, SEL);
static void (*original_setup_changed)(id, SEL, id);
static id (*original_setup_shared)(id, SEL);

static void
mondrian_clear_setup_reason(id manager)
{
	char *p;

	if (manager == nil || mondrian_setup_reason_offset < 0) {
		return;
	}
	p = (char *)manager + mondrian_setup_reason_offset;
	switch (mondrian_setup_reason_type) {
	case 'c': case 'C': case 'B':
		*(volatile char *)p = 0;
		break;
	case 's': case 'S':
		*(volatile short *)p = 0;
		break;
	case 'i': case 'I':
		*(volatile int *)p = 0;
		break;
	case 'q': case 'Q': case 'l': case 'L':
		*(volatile long long *)p = 0;
		break;
	default:
		break;
	}
}

static id
mondrian_setup_shared(id self, SEL selector)
{
	id manager = original_setup_shared != NULL ? original_setup_shared(self, selector) : nil;

	mondrian_clear_setup_reason(manager);
	say("MONDRIAN UI: SBSetupManager sharedInstance, reason forced 0\n");
	return manager;
}

static void
mondrian_update_setup(id self, SEL selector)
{
	mondrian_clear_setup_reason(self);
	say("MONDRIAN UI: updateInSetupMode, reason forced 0\n");
	if (original_update_setup != NULL) {
		original_update_setup(self, selector);
	}
}

static void
mondrian_setup_changed(id self, SEL selector, id notification)
{
	say("MONDRIAN UI: setupProcessChanged notification\n");
	mondrian_clear_setup_reason(self);
	if (original_setup_changed != NULL) {
		original_setup_changed(self, selector, notification);
	}
}

static id (*original_lockdown_init)(id, SEL);
static id (*original_lockdown_shared)(id, SEL);

static long
mondrian_activation_getter(id self, SEL selector)
{
	(void)self;
	say("MONDRIAN UI: SBLockdownManager activation getter -> 2\n");
	return 2;
}

static id
mondrian_lockdown_init_log(id self, SEL selector)
{
	id manager = original_lockdown_init != NULL ? original_lockdown_init(self, selector) : self;

	say("MONDRIAN UI: SBLockdownManager init\n");
	return manager;
}

static id
mondrian_lockdown_shared_log(id self, SEL selector)
{
	id manager = original_lockdown_shared != NULL ? original_lockdown_shared(self, selector) : nil;

	say("MONDRIAN UI: SBLockdownManager sharedInstance\n");
	return manager;
}

static void
mondrian_dump_class_methods(const char *name)
{
	Class cls = objc_getClass(name);
	Class meta = cls != Nil ? object_getClass(cls) : Nil;
	Method *methods;
	unsigned int count = 0, i;
	char line[160];

	if (meta == Nil) {
		snprintf(line, sizeof(line), "MONDRIAN UI: %s class missing\n", name);
		say(line);
		return;
	}
	methods = class_copyMethodList(meta, &count);
	snprintf(line, sizeof(line), "MONDRIAN UI: %s +%u methods\n", name, count);
	say(line);
	for (i = 0; i < count; i++) {
		const char *method = sel_getName(method_getName(methods[i]));

		if (strstr(method, "ctiv") == NULL && strstr(method, "State") == NULL &&
		    strstr(method, "etup") == NULL && strstr(method, "ock") == NULL) {
			continue;
		}
		snprintf(line, sizeof(line), "  +%s\n", method);
		say(line);
	}
	free(methods);
}

/*
 * Auto-lock. SpringBoard arms its idle timer about two minutes after the UI
 * settles, the display sleeps, and every CADisplayLink in the system stops
 * with it while NSTimers keep their rate (measured: links stop at ts 146 s,
 * the timer sample keeps ticking, and the framebuffer keeps the last frame,
 * so the phone looks frozen on the lock screen). The names below are from the
 * shipped iOS 16 userland:
 *
 *   -[SBUserAgent setIdleTimerDisabled:forReason:]
 *   -[SBUserAgent isIdleTimerDisabledForReason:]
 *   -[SBLockScreenManager unlockUIFromSource:withOptions:]
 *   -[SBLockScreenManager isUILocked]
 *
 * plus SBDeviceLockBlocked in com.apple.springboard. Everything is looked up
 * at run time, so a missing method is a log line and not a crash.
 */
static void (*original_idle_disabled)(id, SEL, BOOL, id);

static int boot_arg_set(const char *name);

static void
mondrian_idle_disabled(id self, SEL selector, BOOL disabled, id reason)
{
	static int last = -1;
	char line[96];

	if ((int)disabled != last) {
		last = (int)disabled;
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: idle timer asked %d, forced 1\n", (int)disabled);
		say(line);
	}
	if (original_idle_disabled != NULL) {
		original_idle_disabled(self, selector, YES, reason);
	}
}

static BOOL
mondrian_idle_disabled_for_reason(id self, SEL selector, id reason)
{
	(void)self;
	(void)selector;
	(void)reason;
	return YES;
}

/*
 * Every method of a class, unfiltered: SBLockScreenManager's list is the only
 * place that says which wake and unlock entry points this build actually has
 * (the selectors in the shared cache are not attributed to a class).
 */
static void
mondrian_dump_all_methods(const char *name)
{
	Class cls = objc_getClass(name);
	Method *methods;
	unsigned int count = 0, i;
	char line[192];

	if (cls == Nil) {
		return;
	}
	methods = class_copyMethodList(cls, &count);
	snprintf(line, sizeof(line), "MONDRIAN UI: %s -%u methods\n", name, count);
	say(line);
	for (i = 0; i < count; i++) {
		const char *types = method_getTypeEncoding(methods[i]);

		snprintf(line, sizeof(line), "  -%s %s\n",
		    sel_getName(method_getName(methods[i])), types != NULL ? types : "?");
		say(line);
	}
	free(methods);
}

/*
 * SBUserAgent is looked up when the thread needs it, not at load time (the
 * class may not be registered yet when a dylib initializer runs), and it is
 * installed exactly once: a second install would hand the hook its own
 * implementation and recurse.
 */
static int
mondrian_install_agent_hooks(void)
{
	Class agent = objc_getClass("SBUserAgent");
	Method method;
	char line[112];

	if (agent == Nil) {
		return 0;
	}
	mondrian_dump_all_methods("SBUserAgent");
	method = class_getInstanceMethod(agent,
	    sel_registerName("setIdleTimerDisabled:forReason:"));
	if (method != NULL) {
		original_idle_disabled = (void (*)(id, SEL, BOOL, id))
		    method_setImplementation(method, (IMP)mondrian_idle_disabled);
		say("MONDRIAN UI: idle timer disable hook installed\n");
	} else {
		say("MONDRIAN UI: SBUserAgent setIdleTimerDisabled:forReason: missing\n");
	}
	method = class_getInstanceMethod(agent,
	    sel_registerName("isIdleTimerDisabledForReason:"));
	if (method != NULL) {
		method_setImplementation(method, (IMP)mondrian_idle_disabled_for_reason);
		say("MONDRIAN UI: idle timer getter hook installed\n");
	}
	/*
	 * SBDeviceLockBlocked is not "block locking": in com.apple.springboard it
	 * is true when the device is blocked, and that is the screen that says
	 * "iPhone is not available" and refuses every unlock (measured after this
	 * hook wrote true: `unlock attempt -> 0` thirteen times). Clear it, and
	 * clear the failed-attempt counter that goes with it.
	 */
	CFPreferencesSetAppValue(CFSTR("SBDeviceLockBlocked"), kCFBooleanFalse,
	    CFSTR("com.apple.springboard"));
	CFPreferencesSetAppValue(CFSTR("SBDeviceLockFailedAttempts"),
	    (CFNumberRef)[NSNumber numberWithInt:0], CFSTR("com.apple.springboard"));
	snprintf(line, sizeof(line), "MONDRIAN UI: lock block cleared, written %d\n",
	    (int)CFPreferencesAppSynchronize(CFSTR("com.apple.springboard")));
	say(line);
	return 1;
}

/*
 * SpringBoard traps when its lock screen is driven from another queue:
 * "BUG IN CLIENT OF LIBDISPATCH: Assertion failed: Block was expected to
 * execute on queue [com.apple.main-thread]" (SIGTRAP, ring198), which killed it
 * thirteen seconds into every launch and made the device reboot. Everything
 * that touches SBLockScreenManager therefore runs as a block on the main
 * queue, posted by a thread whose only job is the five second tick, and
 * +[SBLockScreenManager sharedInstance] still waits for +[UIApplication
 * sharedApplication] because it asserts before that object exists.
 */
static volatile int mondrian_lock_step_pending;
static int mondrian_agent_hooks;
static int mondrian_lock_last = -1;
static int mondrian_unlock_enabled;
static int mondrian_unlock2_enabled;
static int mondrian_anim_enabled;
static int mondrian_anim_started;
static int mondrian_lock_ticks;
static volatile unsigned mondrian_home_ticks;
static volatile unsigned mondrian_icon_after_wait;

static void mondrian_try_unlock_options(void);

/*
 * A frame rate needs something that moves: a static lock screen draws nothing,
 * so `fps 0` says nothing about the renderer. This puts one red square in
 * SpringBoard's own window layer and animates it with CoreAnimation, which the
 * render server composites at the display rate; if the screen shows the square
 * moving and `MONDRIAN FB: fps` says 60, the whole CoreAnimation -> GL -> panel
 * path is running at 60 Hz with no finger on the glass.
 */
/*
 * The home screen: an empty layer tree and an empty icon model look the same on
 * the panel, so ask SpringBoard what it has. `leafIcons` is the model's flat
 * list (apps, folders, widgets); zero means nothing to draw, non-zero with no
 * icons on screen means the model is there and the view is not.
 */
static void
mondrian_log_home_screen(void)
{
	/*
	 * `iconModel` answering nil (measured, five boots: `controller 1 model 0
	 * leaf 0`) is not proof that the model is absent: it may be `_iconModel`,
	 * behind `SBIconController`'s icon manager, or `rootFolder`. Ask every
	 * name this build might have and print which one answers, with the leaf
	 * count when it does.
	 */
	static const char *const model_selectors[] = {
		"iconModel", "_iconModel", "model", "rootFolder",
	};
	static const char *const manager_selectors[] = {
		"iconManager", "_iconManager",
	};
	Class controller_class = objc_getClass("SBIconController");
	id controller = controller_class != Nil
	    ? ((id (*)(id, SEL))objc_msgSend)((id)controller_class,
	    sel_registerName("sharedInstance")) : nil;
	char line[160];
	unsigned i;

	snprintf(line, sizeof(line), "MONDRIAN UI: home screen controller %d\n",
	    controller != nil);
	say(line);
	if (controller == nil) {
		return;
	}
	for (i = 0; i < sizeof(model_selectors) / sizeof(model_selectors[0]); i++) {
		id model = nil;
		id icons = nil;
		unsigned count = 0;

		if (![controller respondsToSelector:sel_registerName(model_selectors[i])]) {
			continue;
		}
		model = ((id (*)(id, SEL))objc_msgSend)(controller,
		    sel_registerName(model_selectors[i]));
		if (model != nil &&
		    [model respondsToSelector:sel_registerName("leafIcons")]) {
			icons = ((id (*)(id, SEL))objc_msgSend)(model,
			    sel_registerName("leafIcons"));
		}
		if (icons != nil && [icons respondsToSelector:sel_registerName("count")]) {
			count = (unsigned)((NSUInteger (*)(id, SEL))objc_msgSend)(icons,
			    sel_registerName("count"));
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: icon %s -> %d leaf %u\n",
		    model_selectors[i], model != nil, count);
		say(line);
	}
	for (i = 0; i < sizeof(manager_selectors) / sizeof(manager_selectors[0]); i++) {
		id manager;
		id model = nil;
		unsigned count = 0;

		if (![controller respondsToSelector:sel_registerName(manager_selectors[i])]) {
			continue;
		}
		manager = ((id (*)(id, SEL))objc_msgSend)(controller,
		    sel_registerName(manager_selectors[i]));
		if (manager == nil) {
			continue;
		}
		if ([manager respondsToSelector:sel_registerName("model")]) {
			model = ((id (*)(id, SEL))objc_msgSend)(manager,
			    sel_registerName("model"));
		}
		if (model != nil &&
		    [model respondsToSelector:sel_registerName("leafIcons")]) {
			id icons = ((id (*)(id, SEL))objc_msgSend)(model,
			    sel_registerName("leafIcons"));

			if (icons != nil &&
			    [icons respondsToSelector:sel_registerName("count")]) {
				count = (unsigned)((NSUInteger (*)(id, SEL))objc_msgSend)(icons,
				    sel_registerName("count"));
			}
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: %s -> %d leaf %u\n",
		    manager_selectors[i], model != nil, count);
		say(line);
	}
}

/*
 * Do icon views exist at all? `-[SBIconView setIcon:]` runs whenever SpringBoard
 * lays one out, so counting the calls separates "no model, nothing to draw"
 * from "views built and nothing reaches the panel". The first five answer with
 * the icon's class, the rest is a total every ten seconds.
 */
static void (*original_set_icon)(id, SEL, id);
static volatile unsigned mondrian_icon_calls;

static id
mondrian_send(id object, const char *selector)
{
	if (object == nil || ![object respondsToSelector:sel_registerName(selector)]) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

/*
 * Icons are laid out and invisible (measured, ring210: 79 SBIconView setIcon:
 * calls, `icon model -> 1 leaf 13`, and nothing of it on the panel). Three
 * causes look the same from outside, and the previous probe could not tell
 * them apart because it read `iconImageView.image` *inside* `-setIcon:`, which
 * is the moment the view has just been handed its model and not yet its
 * artwork: on this build the image is set later, from the icon's image cache.
 * Measured that way, "image 0" on the first five calls says nothing.
 *
 * So the boot keeps the first eight views and asks them again thirty seconds
 * after the home screen is up, which separates:
 *
 *  - the artwork never arrives (image nil, contents nil) -- the icon image
 *    pipeline is dead, `assetsd` aborts and `iconservicesagent` exits 0x9;
 *  - the artwork arrives but the view is not composited (image non-nil, window
 *    nil or hidden or alpha 0) -- a layout/visibility problem;
 *  - the view is composited and the panel still shows nothing -- a render
 *    server or surface problem, which is where the red paint
 *    (`mondrianiconpaint=1`) and `layer.contents` tell the two apart.
 *
 * `mondriandumpicon=1` prints the model's own image selectors instead of
 * guessing them, and `mondrianiconset=1` falls back to loading the app's
 * `AppIcon60x60@2x.png` straight out of its bundle, which is the artwork the
 * pipeline is failing to produce.
 */
#define MONDRIAN_ICON_VIEWS 8

static id mondrian_live_views[MONDRIAN_ICON_VIEWS];
static id mondrian_live_objects[MONDRIAN_ICON_VIEWS];
static unsigned mondrian_icon_view_count;
static unsigned mondrian_live_count;
static volatile unsigned mondrian_icon_late_done;
static volatile unsigned mondrian_icon_dump_done;

static void
mondrian_set_icon(id self, SEL selector, id icon)
{
	static unsigned logged;

	if (original_set_icon != NULL) {
		original_set_icon(self, selector, icon);
	}
	/*
	 * Only the calls that carry an icon say anything: SpringBoard clears
	 * its recycled views with `setIcon:nil` (measured, ring212: the first
	 * five all nil, `image 0 frame -7,-7 64x78`), so counting those hides
	 * the ones that matter.
	 */
	if (icon != nil && logged < 5) {
		char line[200];
		id image_view = mondrian_send(self, "iconImageView");
		id image = image_view != nil ? mondrian_send(image_view, "image") : nil;
		id name = mondrian_send(icon, "displayName");
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(self,
		    sel_registerName("frame"));

		logged++;
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: icon %s%s%s image %d frame %.0f,%.0f %.0fx%.0f\n",
		    object_getClassName(icon),
		    name != nil ? " name " : "",
		    name != nil ? [(NSString *)name UTF8String] : "",
		    image != nil, frame.origin.x, frame.origin.y,
		    frame.size.width, frame.size.height);
		say(line);
		if (logged == 3 && boot_arg_set("mondrianiconpaint=1")) {
			id layer = mondrian_send(self, "layer");
			CGFloat red[4] = { 1.0, 0.0, 0.0, 1.0 };
			CGColorRef colour = CGColorCreate(
			    CGColorSpaceCreateDeviceRGB(), red);

			if (layer != nil) {
				((void (*)(id, SEL, CGColorRef))objc_msgSend)(layer,
				    sel_registerName("setBackgroundColor:"), colour);
				say("MONDRIAN UI: icon painted red\n");
			}
			if (colour != NULL) {
				CGColorRelease(colour);
			}
		}
	}
	if (icon != nil && mondrian_icon_view_count < MONDRIAN_ICON_VIEWS) {
		/*
		 * Counted, never kept: SpringBoard frees these views, and a
		 * message to a freed object is the SIGSEGV that killed ring223.
		 * The live ones are found by the tree walk at probe time.
		 */
		mondrian_icon_view_count++;
	}
	mondrian_icon_calls++;
}

static void
install_icon_probe(void)
{
	Class view = objc_getClass("SBIconView");
	Method method = view != Nil
	    ? class_getInstanceMethod(view, sel_registerName("setIcon:")) : NULL;

	if (method == NULL) {
		say("MONDRIAN UI: SBIconView missing; icons not observable\n");
		return;
	}
	original_set_icon = (void (*)(id, SEL, id))method_getImplementation(method);
	method_setImplementation(method, (IMP)mondrian_set_icon);
	say("MONDRIAN UI: SBIconView setIcon: hooked\n");
}

static void
mondrian_icon_report(void)
{
	static unsigned last;
	char line[112];

	if (mondrian_icon_calls == last) {
		return;
	}
	last = mondrian_icon_calls;
	snprintf(line, sizeof(line), "MONDRIAN UI: icons laid out %u so far\n",
	    mondrian_icon_calls);
	say(line);
}

/*
 * Ask the model what it can do across its whole class chain: a subclass in
 * this userland declares almost nothing itself (`SBApplicationIcon` measured:
 * two own methods), so a dump of one class says nothing about the artwork
 * entry points, which live in `SBIcon`/`SBLeafIcon`.
 */
static void
mondrian_icon_dump_selectors(id view, id icon)
{
	Class classes[2];
	unsigned c;

	classes[0] = object_getClass(view);
	classes[1] = icon != NULL ? object_getClass(icon) : Nil;
	for (c = 0; c < 2; c++) {
		Class cls = classes[c];

		for (; cls != Nil; cls = class_getSuperclass(cls)) {
			Method *methods;
			unsigned count = 0, i;
			char line[160];

			methods = class_copyMethodList(cls, &count);
			snprintf(line, sizeof(line), "MONDRIAN UI: %s %u methods\n",
			    class_getName(cls), count);
			say(line);
			for (i = 0; i < count; i++) {
				const char *name =
				    sel_getName(method_getName(methods[i]));

				if (strstr(name, "mage") == NULL &&
				    strstr(name, "con") == NULL) {
					continue;
				}
				snprintf(line, sizeof(line), "  -%s\n", name);
				say(line);
			}
			free(methods);
		}
	}
}

static const char *
mondrian_icon_label(id icon)
{
	id name = icon != NULL ? mondrian_send(icon, "displayName") : nil;

	return (name != nil && [name isKindOfClass:[NSString class]])
	    ? [(NSString *)name UTF8String] : "?";
}

/*
 * One icon view: its image, its layer contents and its place in the window
 * tree. A view that is hidden or has no window is invisible whatever its
 * image says; an image with empty contents never reached the render server.
 */
static void
mondrian_icon_probe_one(id view, id icon, const char *where)
{
	id image_view = mondrian_send(view, "iconImageView");
	id image = image_view != NULL ? mondrian_send(image_view, "image") : nil;
	id layer = mondrian_send(view, "layer");
	id contents = layer != NULL ? mondrian_send(layer, "contents") : nil;
	id window = mondrian_send(view, "window");
	CGRect frame = CGRectZero;
	CGSize size = CGSizeZero;
	CGFloat alpha = 0.0;
	int hidden = 0;
	char line[240];

	frame = ((CGRect (*)(id, SEL))objc_msgSend)(view,
	    sel_registerName("frame"));
	if (image != NULL) {
		size = ((CGSize (*)(id, SEL))objc_msgSend)(image,
		    sel_registerName("size"));
	}
	if ([view respondsToSelector:sel_registerName("isHidden")]) {
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("isHidden")) ? 1 : 0;
	}
	if ([view respondsToSelector:sel_registerName("alpha")]) {
		alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("alpha"));
	}
	snprintf(line, sizeof(line),
	    "MONDRIAN UI: icon %s %s image %d %.0fx%.0f contents %d win %d"
	    " hidden %d alpha %.2f frame %.0f,%.0f %.0fx%.0f\n",
	    mondrian_icon_label(icon), where, image != NULL, size.width,
	    size.height, contents != NULL, window != NULL, hidden, alpha,
	    frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
	say(line);
}

/*
 * The first eight views are handed to the hook long before the home screen
 * exists, and SpringBoard recycles them: by thirty seconds the pointers name
 * whatever object took their memory (measured, ring220: the dump answered
 * `CSCoverSheetView`, and every late line read `image 0`). The live views are
 * therefore found by walking the windows' view trees instead of keeping
 * pointers to the first ones.
 *
 * The visit budget is large on purpose: the wallpaper and lock windows carry
 * subtrees of hundreds of views, and a small cap spends itself before the
 * home screen's icon list is reached. The walk stops as soon as it has the
 * eight views it can hold.
 */
#define MONDRIAN_ICON_VISITS 20000

static unsigned
mondrian_icon_walk(id view, unsigned depth, unsigned *seen, unsigned *store)
{
	Class icon_view = objc_getClass("SBIconView");
	id subs;
	unsigned n, i;

	if (view == NULL || depth > 24 || *seen >= MONDRIAN_ICON_VISITS ||
	    *store >= MONDRIAN_ICON_VIEWS) {
		return 0;
	}
	(*seen)++;
	if (icon_view != Nil && [view isKindOfClass:icon_view]) {
		mondrian_live_views[*store] = view;
		mondrian_live_objects[*store] = mondrian_send(view, "icon");
		(*store)++;
		return 1;
	}
	subs = mondrian_send(view, "subviews");
	n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_icon_walk([(NSArray *)subs objectAtIndex:i], depth + 1,
		    seen, store);
	}
	return 0;
}

static void
mondrian_icon_scan_window(id window, unsigned *seen, unsigned *live)
{
	const char *name = object_getClassName(window);

	mondrian_icon_walk(window, 0, seen, live);
	if (*live > 0) {
		char line[160];

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: icon window %s carries %u\n", name, *live);
		say(line);
	}
}

static void
mondrian_icon_late_report(void)
{
	id app = [objc_getClass("UIApplication") sharedApplication];
	id windows = app != nil ? [app windows] : nil;
	unsigned count = windows != nil ? (unsigned)[windows count] : 0;
	unsigned seen = 0, live = 0, i;
	char line[200];

	/*
	 * The home screen window first: it is where the icon views live, and
	 * the other fourteen windows are large enough to matter for the budget.
	 */
	for (i = 0; i < count && live == 0; i++) {
		const char *name = object_getClassName([windows objectAtIndex:i]);

		if (name != NULL && strstr(name, "HomeScreen") != NULL) {
			mondrian_icon_scan_window([windows objectAtIndex:i],
			    &seen, &live);
		}
	}
	for (i = 0; i < count && live == 0; i++) {
		const char *name = object_getClassName([windows objectAtIndex:i]);

		if (name == NULL || strstr(name, "HomeScreen") == NULL) {
			mondrian_icon_scan_window([windows objectAtIndex:i],
			    &seen, &live);
		}
	}
	mondrian_live_count = live;
	snprintf(line, sizeof(line),
	    "MONDRIAN UI: icon tree %u views, %u icon views live\n", seen, live);
	say(line);
	for (i = 0; i < live; i++) {
		mondrian_icon_probe_one(mondrian_live_views[i],
		    mondrian_live_objects[i], "live");
	}
}

/*
 * The artwork the pipeline never produced, from the app's own bundle. The
 * bundle path comes from the model's application object; the file names are
 * the ones this userland ships (the 60 pt @2x pair is the home screen's).
 */
static const char *const mondrian_icon_files[] = {
	"AppIcon60x60@2x.png",
	"AppIcon60x60@3x.png",
	"AppIcon76x76@2x~ipad.png",
	"Icon-60@2x.png",
	"Icon-72@2x.png",
	"Icon.png",
	"Icon@2x.png",
	"AppIcon29x29@2x.png",
};

static NSString *
mondrian_icon_bundle_path(id icon)
{
	static const char *const selectors[] = {
		"bundleURL", "dataContainerURL", "bundleContainerURL",
		"containerURL", "url",
	};
	id app = mondrian_send(icon, "application");
	unsigned i;

	for (i = 0; app != NULL && i < sizeof(selectors) / sizeof(selectors[0]);
	    i++) {
		id url = mondrian_send(app, selectors[i]);

		if (url != NULL && [url isKindOfClass:[NSURL class]]) {
			return [(NSURL *)url path];
		}
	}
	return nil;
}

#define MONDRIAN_ICON_TAG	0x4d4f4e31	/* 'MON1', ours */

/*
 * The view this hook paints: an image view of ours, tagged so a later pass
 * finds it again without keeping a pointer. SpringBoard's own image views are
 * never written -- see mondrian_icon_force_artwork for what writing them cost.
 */
static id
mondrian_icon_own_view(id view)
{
	id subs = mondrian_send(view, "subviews");
	unsigned n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
	unsigned i;

	for (i = 0; i < n; i++) {
		id sub = [(NSArray *)subs objectAtIndex:i];
		long tag = ((long (*)(id, SEL))objc_msgSend)(sub,
		    sel_registerName("tag"));

		if (tag == MONDRIAN_ICON_TAG) {
			return sub;
		}
	}
	return nil;
}

static void mondrian_icon_check_one(id view, const char *label);

static void
mondrian_icon_force_artwork(void)
{
	id *views = mondrian_live_views;
	id *objects = mondrian_live_objects;
	unsigned count = mondrian_live_count;
	unsigned i, f;
	unsigned loaded = 0;
	char line[240];

	if (count == 0) {
		say("MONDRIAN UI: icons no live view to paint\n");
		return;
	}

	for (i = 0; i < count; i++) {
		id view = views[i];
		id icon = objects[i];
		id image_view;
		NSString *path = mondrian_icon_bundle_path(icon);
		const char *label = mondrian_icon_label(icon);
		CGRect bounds;

		if (path == nil) {
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: icon %s no artwork path\n", label);
			say(line);
			continue;
		}
		/*
		 * Always an image view of our own, never one of SpringBoard's.
		 * Writing theirs makes SpringBoard rebuild the icon at the
		 * model's image info, and that request is 84 pt against a pool
		 * whose maximum slot is 80 pt: `requested slot length (64512)
		 * larger than maximum slotLength (57600)` is an uncaught
		 * exception, so SpringBoard dies and restarts (measured,
		 * ring227: 52 assertions and 24 restarts, after the second
		 * pass repainted its views). Our own UIImageView has a layer
		 * of its own -- the compositor draws it and no icon image is
		 * ever requested -- and it is placed at the icon view's bounds
		 * and above its siblings.
		 */
		bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("bounds"));
		/*
		 * The icon view is the icon plus its label (60x74 on the home
		 * screen); the artwork is square and sits at the top, so a
		 * square of the view's width is the right frame -- stretching a
		 * 60x60 PNG over 60x74 would show a squashed icon.
		 */
		bounds.size.height = bounds.size.width;
		image_view = mondrian_icon_own_view(view);
		if (image_view == NULL) {
			Class ui_image_view = objc_getClass("UIImageView");

			if (ui_image_view == Nil) {
				continue;
			}
			image_view = ((id (*)(id, SEL))objc_msgSend)(
			    (id)ui_image_view, sel_registerName("alloc"));
			image_view = ((id (*)(id, SEL, CGRect))objc_msgSend)(
			    image_view, sel_registerName("initWithFrame:"), bounds);
			((void (*)(id, SEL, long))objc_msgSend)(image_view,
			    sel_registerName("setTag:"), (long)MONDRIAN_ICON_TAG);
			((void (*)(id, SEL, id))objc_msgSend)(view,
			    sel_registerName("addSubview:"), image_view);
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: icon %s own view %.0fx%.0f\n", label,
			    bounds.size.width, bounds.size.height);
			say(line);
		}
		for (f = 0; f < sizeof(mondrian_icon_files) /
		    sizeof(mondrian_icon_files[0]); f++) {
			char file[512];
			id image;
			Class ui_image = objc_getClass("UIImage");

			snprintf(file, sizeof(file), "%s/%s",
			    [path UTF8String], mondrian_icon_files[f]);
			if (access(file, R_OK) != 0) {
				continue;
			}
			image = ui_image != Nil
			    ? ((id (*)(id, SEL, id))objc_msgSend)((id)ui_image,
			        sel_registerName("imageWithContentsOfFile:"),
			        [NSString stringWithUTF8String:file]) : nil;
			if (image == NULL) {
				continue;
			}
			((void (*)(id, SEL, id))objc_msgSend)(image_view,
			    sel_registerName("setImage:"), image);
			loaded++;
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: icon %s <- %s\n", label,
			    mondrian_icon_files[f]);
			say(line);
			mondrian_icon_check_one(image_view, label);
			break;
		}
	}
	snprintf(line, sizeof(line), "MONDRIAN UI: icons loaded from the bundle %u\n",
	    loaded);
	say(line);
}

/*
 * After the artwork is set, read it back *in the same tick*, on the object that
 * was just written: a delayed report would have to reuse view pointers, and
 * SpringBoard frees icon views (ring224: the ten-second report crashed it four
 * times). "The image was set" is not "the layer has contents", so both are
 * printed here while the object is certainly alive.
 */
static void
mondrian_icon_check_one(id view, const char *label)
{
	id image = mondrian_send(view, "image");
	id layer = mondrian_send(view, "layer");
	id contents = layer != NULL ? mondrian_send(layer, "contents") : nil;
	CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view,
	    sel_registerName("frame"));
	CGSize size = CGSizeZero;
	char line[200];

	if (image != NULL) {
		size = ((CGSize (*)(id, SEL))objc_msgSend)(image,
		    sel_registerName("size"));
	}
	snprintf(line, sizeof(line),
	    "MONDRIAN UI: icon %s set %s image %d %.0fx%.0f contents %d"
	    " frame %.0f,%.0f %.0fx%.0f\n",
	    label, object_getClassName(view), image != NULL, size.width,
	    size.height, contents != NULL, frame.origin.x, frame.origin.y,
	    frame.size.width, frame.size.height);
	say(line);
}

/*
 * Read-only: does the view this hook painted still carry the image, and has the
 * render server got contents for it? Only our own tagged subviews are touched,
 * and the walk that finds them is repeated, so no icon view pointer is kept.
 */
static void
mondrian_icon_own_report(void)
{
	unsigned i, n = mondrian_live_count;
	char line[200];

	for (i = 0; i < n; i++) {
		id view = mondrian_live_views[i];
		id own = mondrian_icon_own_view(view);
		id image = own != NULL ? mondrian_send(own, "image") : nil;
		id layer = own != NULL ? mondrian_send(own, "layer") : nil;
		id contents = layer != NULL ? mondrian_send(layer, "contents") : nil;
		const char *label = mondrian_icon_label(mondrian_live_objects[i]);

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: icon %s own %d image %d contents %d\n",
		    label, own != NULL, image != NULL, contents != NULL);
		say(line);
	}
}

/*
 * The wallpaper is the home screen's frame budget, not the icon drawing: HakiOS
 * measured 28 fps with it composed every frame, 78 with it hidden and 92 with it
 * frozen as one still picture, and its gradients drawn 3509 times a run
 * (CHANGELOG 2.3.3-2.3.4). This port has no still picture to put in its place
 * yet, so `mondrianwallpaper=1` hides the wallpaper window and measures what
 * that is worth here: a black backdrop behind the icons, and one number that
 * says whether freezing the wallpaper is the next thing worth building.
 */
static volatile int mondrian_wallpaper_done;

static void
mondrian_hide_wallpaper(void)
{
	id app = [objc_getClass("UIApplication") sharedApplication];
	id windows = app != nil ? [app windows] : nil;
	unsigned count = windows != nil ? (unsigned)[windows count] : 0;
	unsigned hidden = 0;
	char line[128];
	unsigned i;

	for (i = 0; i < count; i++) {
		id window = [windows objectAtIndex:i];
		const char *name = object_getClassName(window);

		if (name == NULL ||
		    (strcasestr(name, "wallpaper") == NULL &&
		    strcasestr(name, "poster") == NULL)) {
			continue;
		}
		if ([window respondsToSelector:sel_registerName("setHidden:")]) {
			[window setHidden:YES];
			hidden++;
		}
	}
	snprintf(line, sizeof(line), "MONDRIAN UI: wallpaper windows hidden %u\n",
	    hidden);
	say(line);
}

static int
mondrian_probe_tick(void)
{
	id app = [objc_getClass("UIApplication") sharedApplication];
	id windows = [app windows];
	id key = [app respondsToSelector:sel_registerName("keyWindow")]
	    ? [app keyWindow] : nil;
	id target = nil;
	CGFloat components[4] = { 1.0, 0.0, 0.0, 1.0 };
	CGColorRef red = NULL;
	unsigned count;
	unsigned i;
	unsigned attached = 0;
	char line[128];

	if (windows == nil) {
		return 0;
	}
	/*
	 * One window, the one on the glass: SpringBoard has fifteen (the lock
	 * screen's, the wallpaper's, the home screen's, helpers), and a layer
	 * animated in an offscreen one is a layer nobody composites -- that is
	 * how a boot reads `fps 0` while the probe says it is attached. The key
	 * window is the one UIKit puts in front; if it has no size, fall back to
	 * an unhidden window as large as the display.
	 */
	count = (unsigned)[windows count];
	/*
	 * The key window first, then the first window that is not hidden and is
	 * as wide as the display: the layer has to be in the tree backboardd
	 * composites, or the boot reads `fps 0` while the probe swears it is
	 * attached.
	 */
	if (key != nil) {
		id root = [key layer];

		if (root != nil && [root bounds].size.width >= 100.0) {
			target = key;
		}
	}
	for (i = 0; target == nil && i < count; i++) {
		id window = [windows objectAtIndex:i];
		id root = [window layer];

		if (root == nil || [root bounds].size.width < 100.0) {
			continue;
		}
		if ([window respondsToSelector:sel_registerName("isHidden")] &&
		    [window isHidden]) {
			continue;
		}
		target = window;
	}
	if (target == nil) {
		return 0;
	}
	red = CGColorCreate(CGColorSpaceCreateDeviceRGB(), components);
	{
		id root = [target layer];
		id sublayers;
		id move;
		id dot = nil;
		double w = [root bounds].size.width;
		unsigned j;

		sublayers = [root sublayers];
		for (j = 0; j < (unsigned)[sublayers count]; j++) {
			id sub = [sublayers objectAtIndex:j];

			if ([[sub name] isEqualToString:@"mondrian-probe"]) {
				dot = sub;
				break;
			}
		}
		if (dot == nil) {
			static unsigned told;

			dot = [objc_getClass("CALayer") layer];
			[dot setName:@"mondrian-probe"];
			[dot setFrame:CGRectMake(60.0, 200.0, 120.0, 120.0)];
			if (red != NULL) {
				[dot setBackgroundColor:red];
			}
			[root addSublayer:dot];
			if (told++ < 4) {
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: probe attached (%.0fx%.0f, key %d)\n",
				    w, [root bounds].size.height, target == key);
				say(line);
			}
		}
		attached = 1;
		move = [objc_getClass("CABasicAnimation") animationWithKeyPath:@"position.x"];
		[move setFromValue:[NSNumber numberWithDouble:60.0]];
		[move setToValue:[NSNumber numberWithDouble:w - 60.0]];
		[move setDuration:2.0];
		[move setAutoreverses:YES];
		[move setRepeatCount:1e9];
		[dot addAnimation:move forKey:@"mondrian-move"];
	}
	if (red != NULL) {
		CGColorRelease(red);
	}
	return (int)attached;
}

/*
 * The device state, once, from the classes that own it: these four answers say
 * whether the lock screen is refusing because of a passcode, a lockout or a
 * blocked device, which a bare "unlock returned 0" cannot.
 */
static void
mondrian_log_device_state(void)
{
	static const struct {
		const char *name;
		const char *selector;
	} agent_queries[] = {
		{ "deviceIsLocked", "deviceIsLocked" },
		{ "deviceIsPasscodeLocked", "deviceIsPasscodeLocked" },
		{ "deviceIsBlocked", "deviceIsBlocked" },
		{ "lockScreenIsShowing", "lockScreenIsShowing" },
	};
	static const char *const manager_queries[] = {
		"isUILocked", "isLockScreenVisible", "isLockScreenDisabledForAssertion",
	};
	Class agent = objc_getClass("SBUserAgent");
	Class manager_cls = objc_getClass("SBLockScreenManager");
	Method shared_method = manager_cls != Nil
	    ? class_getClassMethod(manager_cls, sel_registerName("sharedInstance")) : NULL;
	id manager = shared_method != NULL
	    ? ((id (*)(id, SEL))method_getImplementation(shared_method))(
		(id)manager_cls, sel_registerName("sharedInstance")) : nil;
	id user_agent = nil;
	char line[96];
	unsigned i;

	if (agent != Nil) {
		Method shared = class_getClassMethod(agent,
		    sel_registerName("sharedUserAgentInstance"));

		if (shared == NULL) {
			shared = class_getClassMethod(agent, sel_registerName("sharedInstance"));
		}
		if (shared != NULL) {
			user_agent = ((id (*)(id, SEL))method_getImplementation(shared))(
			    (id)agent, sel_registerName("sharedUserAgentInstance"));
		}
	}
	for (i = 0; i < sizeof(agent_queries) / sizeof(agent_queries[0]); i++) {
		Method method = user_agent != nil
		    ? class_getInstanceMethod(agent, sel_registerName(agent_queries[i].selector))
		    : NULL;

		if (method == NULL) {
			continue;
		}
		snprintf(line, sizeof(line), "MONDRIAN UI: state %s %d\n",
		    agent_queries[i].name,
		    (int)((BOOL (*)(id, SEL))method_getImplementation(method))(user_agent,
			sel_registerName(agent_queries[i].selector)));
		say(line);
	}
	for (i = 0; i < sizeof(manager_queries) / sizeof(manager_queries[0]); i++) {
		Method method = manager_cls != Nil
		    ? class_getInstanceMethod(manager_cls, sel_registerName(manager_queries[i]))
		    : NULL;

		if (method == NULL || manager == nil) {
			continue;
		}
		snprintf(line, sizeof(line), "MONDRIAN UI: state %s %d\n",
		    manager_queries[i],
		    (int)((BOOL (*)(id, SEL))method_getImplementation(method))(manager,
			sel_registerName(manager_queries[i])));
		say(line);
	}
}

/*
 * One probe, once, whatever the lock state: the home screen is built behind
 * the lock screen too, and the unlock is the flakiest step in this port
 * (ring221 never left the lock screen at all). Probing from both branches is
 * what keeps an icon finding from depending on it.
 *
 * The first ticks after the unlock can still be too early for the icon list,
 * so an empty walk retries (ten ticks, twenty seconds) instead of spending the
 * one probe on a tree that had nothing in it yet.
 */
static void
mondrian_icon_probe_once(void)
{
	static unsigned attempts;

	if (mondrian_icon_late_done) {
		return;
	}
	mondrian_icon_late_report();
	if (mondrian_live_count == 0 && ++attempts < 10) {
		return;
	}
	mondrian_icon_late_done = 1;
	if (!mondrian_icon_dump_done && mondrian_live_count > 0 &&
	    boot_arg_set("mondriandumpicon=1")) {
		mondrian_icon_dump_done = 1;
		mondrian_icon_dump_selectors(mondrian_live_views[0],
		    mondrian_live_objects[0]);
	}
	/*
	 * The artwork goes on unconditionally: the icon views have no image of
	 * their own on this port, and the view this adds is the only one that
	 * draws an icon (`docs/MONDIAN_GPU.md`). `mondrianiconset=0` is the way
	 * to boot a clean home screen without it.
	 */
	if (!boot_arg_set("mondrianiconset=0")) {
		mondrian_icon_force_artwork();
	}
	/*
	 * And once more, later: the artwork is what the icon list does with the
	 * model a few seconds after it exists, so a view that answers `image 0`
	 * at the probe can still be right a moment afterwards. The walk repeats
	 * from the windows -- nothing is kept -- and only reads.
	 */
	mondrian_icon_after_wait = 10;
}

/*
 * The lock screen is dismissed through the entry point its own swipe uses
 * (-lockScreenViewControllerRequestsUnlock), twenty seconds after the UI is
 * up. unlockUIFromSource:withOptions: with a nil request returns NO and each
 * refused call counts as a failed attempt (ring199: thirteen of them, then
 * "iPhone not available" on the screen), so that path is not used. The request
 * itself gives no answer, and one call is not always enough -- ring221 stayed
 * `lock screen up` for the whole boot after a single request -- so it is
 * repeated twice more, a minute apart, and the log says which attempt it was.
 */
static void
mondrian_lock_step(void *context)
{
	Class cls = objc_getClass("SBLockScreenManager");
	Class app_cls = objc_getClass("UIApplication");
	SEL shared_sel = sel_registerName("sharedInstance");
	SEL app_sel = sel_registerName("sharedApplication");
	SEL locked_sel = sel_registerName("isUILocked");
	SEL request_sel = sel_registerName("lockScreenViewControllerRequestsUnlock");
	Method method;
	id manager;
	BOOL locked;
	char line[96];

	(void)context;
	mondrian_lock_step_pending = 0;
	if (cls == Nil) {
		return;
	}
	if (!mondrian_agent_hooks) {
		mondrian_agent_hooks = mondrian_install_agent_hooks();
	}
	method = app_cls != Nil ? class_getClassMethod(app_cls, app_sel) : NULL;
	if (method == NULL) {
		return;
	}
	if (((id (*)(id, SEL))method_getImplementation(method))((id)app_cls, app_sel) == nil) {
		/* still starting: the next tick retries */
		return;
	}
	method = class_getClassMethod(cls, shared_sel);
	if (method == NULL) {
		return;
	}
	manager = ((id (*)(id, SEL))method_getImplementation(method))((id)cls, shared_sel);
	if (manager == nil) {
		return;
	}
	method = class_getInstanceMethod(cls, locked_sel);
	locked = method != NULL
	    ? ((BOOL (*)(id, SEL))method_getImplementation(method))(manager, locked_sel)
	    : YES;
	if (mondrian_icon_after_wait != 0 && --mondrian_icon_after_wait == 0) {
		say("MONDRIAN UI: icon again, twenty seconds on\n");
		mondrian_icon_late_report();
		mondrian_icon_own_report();
	}
	if ((int)locked != mondrian_lock_last) {
		mondrian_lock_last = (int)locked;
		snprintf(line, sizeof(line), "MONDRIAN UI: lock screen %s\n",
		    locked ? "up" : "gone");
		say(line);
	}
	if (!locked) {
		/*
		 * The home screen is up. The artwork is set after -setIcon:
		 * returns, so the views are asked again twenty seconds in, boot
		 * settled; the animation probe is only a frame-rate reference,
		 * and hiding the wallpaper is only for a boot that cannot draw
		 * one.
		 */
		mondrian_home_ticks++;
		if (mondrian_anim_enabled) {
			int attached = mondrian_probe_tick();

			mondrian_icon_report();
			if (attached > 0 && !mondrian_anim_started) {
				mondrian_anim_started = 1;
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: probe alive on %d windows\n", attached);
				say(line);
				mondrian_log_home_screen();
			}
		}
		if (!mondrian_wallpaper_done &&
		    boot_arg_set("mondrianwallpaper=1")) {
			mondrian_wallpaper_done = 1;
			mondrian_hide_wallpaper();
		}
		mondrian_icon_probe_once();
		return;
	}
	if (!mondrian_unlock_enabled) {
		return;
	}
	mondrian_lock_ticks++;
	if (mondrian_lock_ticks == 10) {
		mondrian_log_device_state();
	}
	/*
	 * A minute in, ask the icon views even if the unlock has not taken: the
	 * report is read-only and a locked boot is still a boot that can say
	 * whether the artwork exists.
	 */
	if (mondrian_lock_ticks == 30) {
		mondrian_icon_probe_once();
	}
	if (mondrian_lock_ticks == 12 && mondrian_anim_enabled && !mondrian_anim_started &&
	    mondrian_probe_tick() > 0) {
		mondrian_anim_started = 1;
	}
	if (mondrian_lock_ticks == 25) {
		if (mondrian_unlock2_enabled) {
			say("MONDRIAN UI: trying the options unlock\n");
			mondrian_try_unlock_options();
			mondrian_log_device_state();
		}
		return;
	}
	if (mondrian_lock_ticks != 10 && mondrian_lock_ticks != 30 &&
	    mondrian_lock_ticks != 50) {
		return;			/* three attempts, twenty seconds apart */
	}
	method = class_getInstanceMethod(cls, request_sel);
	if (method != NULL) {
		((void (*)(id, SEL))method_getImplementation(method))(manager, request_sel);
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: unlock requested (lock screen view, attempt %u)\n",
		    (mondrian_lock_ticks == 10) ? 1u
		    : (mondrian_lock_ticks == 30) ? 2u : 3u);
		say(line);
	} else {
		say("MONDRIAN UI: lockScreenViewControllerRequestsUnlock missing\n");
	}
}

/*
 * The documented refusal path ("Bailing from UIUnlock because: turnOnScreenFirst
 * ...") reads the options argument, so a dictionary of the SpringBoardServices
 * keys is worth one attempt -- but only behind its own boot argument: if the
 * build wants a typed object instead, the call raises inside SpringBoard and
 * every new SpringBoard would raise again, which is a boot loop.
 */
static void
mondrian_try_unlock_options(void)
{
	Class cls = objc_getClass("SBLockScreenManager");
	Method shared = cls != Nil
	    ? class_getClassMethod(cls, sel_registerName("sharedInstance")) : NULL;
	Method method = cls != Nil
	    ? class_getInstanceMethod(cls, sel_registerName("unlockUIFromSource:withOptions:")) : NULL;
	NSDictionary *options;
	id manager;
	BOOL done;
	char line[96];

	if (shared == NULL || method == NULL) {
		return;
	}
	manager = ((id (*)(id, SEL))method_getImplementation(shared))(
	    (id)cls, sel_registerName("sharedInstance"));
	if (manager == nil) {
		return;
	}
	options = @{
		@"SBUIUnlockOptionsTurnOnScreenFirstKey": @YES,
		@"SBUIUnlockOptionsStartFadeInAnimation": @YES,
		@"SBUIUnlockOptionsStartFadeInAnimationKey": @YES,
		@"SBUIUnlockOptionsSimulateSwipeToUnlock": @YES,
		@"SBUIUnlockOptionsSimulateSwipeToUnlockKey": @YES,
	};
	done = ((BOOL (*)(id, SEL, id, id))method_getImplementation(method))(
	    manager, sel_registerName("unlockUIFromSource:withOptions:"), nil, options);
	snprintf(line, sizeof(line), "MONDRIAN UI: unlock with options -> %d\n", (int)done);
	say(line);
}

static void *
mondrian_unlock_run(void *unused)
{
	(void)unused;
	if (objc_getClass("SBLockScreenManager") == Nil) {
		return NULL;
	}
	if (!boot_arg_set("mondrianunlock=1")) {
		say("MONDRIAN UI: unlock disabled (mondrianunlock=1 to enable)\n");
	} else {
		mondrian_unlock_enabled = 1;
	}
	mondrian_unlock2_enabled = boot_arg_set("mondrianunlock2=1") != 0;
	mondrian_anim_enabled = boot_arg_set("mondriananim=1") != 0;
	{
		unsigned stuck = 0;

		for (;;) {
			if (!mondrian_lock_step_pending) {
				stuck = 0;
				mondrian_lock_step_pending = 1;
				dispatch_async_f(dispatch_get_main_queue(), NULL,
				    mondrian_lock_step);
			} else if (++stuck == 5) {
				/*
				 * The step never reached the main queue -- a blocked
				 * main thread, measured in ring217 as a boot that
				 * stayed `lock screen up` for 1049 s. Say so and let
				 * the next tick post it again.
				 */
				say("MONDRIAN UI: lock step stuck; reposting\n");
				mondrian_lock_step_pending = 0;
				stuck = 0;
			}
			sleep(2);
		}
	}
	return NULL;
}

static void
install_idle_hooks(void)
{
	pthread_t thread;

	/* SBLockScreenManager only exists in SpringBoard: leave the other
	 * injected daemons alone. */
	if (objc_getClass("SBLockScreenManager") == Nil) {
		return;
	}
	mondrian_dump_all_methods("SBLockScreenManager");
	if (pthread_create(&thread, NULL, mondrian_unlock_run, NULL) != 0) {
		say("MONDRIAN UI: unlock thread failed\n");
	}
}

static void
install_activation_hooks(void)
{
	char line[96];
	Class lockdown = objc_getClass("SBLockdownManager");
	SEL setup_sel = sel_registerName("_setupActivationState");
	Method setup = lockdown != Nil ? class_getInstanceMethod(lockdown, setup_sel) : NULL;

	if (lockdown == Nil) {
		say("MONDRIAN UI: SBLockdownManager missing\n");
	} else {
		Ivar ivar = class_getInstanceVariable(lockdown, "_activationState");

		mondrian_activation_offset = ivar != NULL ? ivar_getOffset(ivar) : 8;
		if (setup != NULL) {
			method_setImplementation(setup, (IMP)mondrian_setup_activation_state);
			say("MONDRIAN UI: activation hook installed\n");
		}
		mondrian_dump_class("SBLockdownManager");
		mondrian_dump_class_methods("SBLockdownManager");
		{
			Method init = class_getInstanceMethod(lockdown, sel_registerName("init"));

			if (init != NULL) {
				original_lockdown_init = (id (*)(id, SEL))method_setImplementation(
				    init, (IMP)mondrian_lockdown_init_log);
				say("MONDRIAN UI: lockdown init logged\n");
			}
			Method shared = class_getClassMethod(lockdown, sel_registerName("sharedInstance"));
			if (shared != NULL) {
				original_lockdown_shared = (id (*)(id, SEL))method_setImplementation(
				    shared, (IMP)mondrian_lockdown_shared_log);
				say("MONDRIAN UI: lockdown sharedInstance logged\n");
			}
		}
		{
			static const char *const getters[] = {
				"isActivated", "activationState", "isActivationState",
			};

			for (unsigned i = 0; i < sizeof(getters) / sizeof(getters[0]); i++) {
				Method getter = class_getInstanceMethod(lockdown,
				    sel_registerName(getters[i]));

				if (getter != NULL) {
					method_setImplementation(getter, (IMP)mondrian_activation_getter);
					snprintf(line, sizeof(line), "MONDRIAN UI: hooked activation getter %s\n",
					    getters[i]);
					say(line);
				}
			}
		}
	}

	mondrian_dump_class("MobileActivation");
	mondrian_dump_class_methods("MobileActivation");

	Class setup_manager = objc_getClass("SBSetupManager");
	SEL reason_sel = sel_registerName("_setSetupRequiredReason:");
	Method reason = setup_manager != Nil ? class_getInstanceMethod(setup_manager, reason_sel) : NULL;

	if (setup_manager != Nil) {
		static const struct {
			const char *selector;
			BOOL yes;
		} answers[] = {
			{ "isInSetupMode", NO },
			{ "_isInSetupMode", NO },
			{ "isInSetupModeForDeviceMigration", NO },
			{ "setupHasFinishedRestoringFromBackup", YES },
			{ "isInSetupModeReadyToExit", YES },
		};

		for (unsigned i = 0; i < sizeof(answers) / sizeof(answers[0]); i++) {
			Method m = class_getInstanceMethod(setup_manager,
			    sel_registerName(answers[i].selector));

			if (m != NULL) {
				method_setImplementation(m, answers[i].yes
				    ? (IMP)mondrian_answer_yes : (IMP)mondrian_answer_no);
				snprintf(line, sizeof(line), "MONDRIAN UI: hooked %s\n",
				    answers[i].selector);
				say(line);
			}
		}

		{
			Ivar reason_ivar = class_getInstanceVariable(setup_manager,
			    "_setupRequiredReason");
			const char *encoding = reason_ivar != NULL
			    ? ivar_getTypeEncoding(reason_ivar) : NULL;

			if (reason_ivar != NULL) {
				mondrian_setup_reason_offset = ivar_getOffset(reason_ivar);
				mondrian_setup_reason_type = encoding != NULL ? encoding[0] : 0;
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: _setupRequiredReason offset %ld type %c\n",
				    (long)mondrian_setup_reason_offset,
				    mondrian_setup_reason_type != 0 ? mondrian_setup_reason_type : '?');
				say(line);
			}
		}
		{
			Method shared = class_getClassMethod(setup_manager,
			    sel_registerName("sharedInstance"));

			if (shared != NULL) {
				original_setup_shared = (id (*)(id, SEL))method_setImplementation(
				    shared, (IMP)mondrian_setup_shared);
				say("MONDRIAN UI: SBSetupManager sharedInstance hook installed\n");
			}
		}
		{
			Method update = class_getInstanceMethod(setup_manager,
			    sel_registerName("updateInSetupMode"));

			if (update != NULL) {
				original_update_setup = (void (*)(id, SEL))method_setImplementation(
				    update, (IMP)mondrian_update_setup);
				say("MONDRIAN UI: updateInSetupMode hook installed\n");
			}
		}
		{
			Method changed = class_getInstanceMethod(setup_manager,
			    sel_registerName("_setupProcessChangedNotificationReceived:"));

			if (changed != NULL) {
				original_setup_changed = (void (*)(id, SEL, id))method_setImplementation(
				    changed, (IMP)mondrian_setup_changed);
				say("MONDRIAN UI: setupProcessChanged hook installed\n");
			}
		}
	}

	if (reason != NULL && method_getNumberOfArguments(reason) == 3) {
		original_set_setup_reason = (void (*)(id, SEL, long))method_setImplementation(
		    reason, (IMP)mondrian_set_setup_reason);
		say("MONDRIAN UI: setup-assistant hook installed\n");
	}
}

/*
 * The GPU smoke test (tools/mondrian-gpu-test.c) is a second dylib, installed
 * as /usr/libexec/mondrian-gpu-test.dylib by tools/install-gpu-test.sh. Load
 * it here instead of adding a kernel boot argument: this hook runs in every
 * daemon the kernel injects it into, which is after MondrianGPU is published,
 * and the test logs its own verdict. A missing file is not an error; the test
 * is opt-in.
 */
/* Is name (for example "gltest=1") in the kernel's boot arguments? */
static int
boot_arg_set(const char *name)
{
	char args[2048];
	size_t size = sizeof(args);

	if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0 ||
	    size == 0) {
		return 0;
	}
	args[sizeof(args) - 1] = 0;
	return strstr(args, name) != NULL;
}

static void
load_gpu_test(void)
{
	void *handle;

	/*
	 * The CoreAnimation-on-GLES path (docs/COREANIMATION_GLES.md). The
	 * injector's constructor does nothing outside backboardd, so loading it
	 * from every daemon the hook lands in is harmless: it waits for
	 * MondrianGPU, then loads mondrian-gl.dylib, which replaces the EAGL
	 * context and patches CA::OGL::GLESContext.
	 */
	if (access("/usr/libexec/mondrian-inject.dylib", R_OK) == 0) {
		handle = dlopen("/usr/libexec/mondrian-inject.dylib",
		    RTLD_NOW);
		say(handle != NULL ? "MONDRIAN UI: CA GLES injector loaded\n"
		    : "MONDRIAN UI: CA GLES injector dlopen failed\n");
	}
	/*
	 * The smoke tests are opt-in (gltest=1). Both create Mesa contexts of
	 * their own in the process that will later render the UI; the Mesa test
	 * used to leave its 256 KiB context current with a freed window, and
	 * the next calloc served the freed block to the EAGLContext, which the
	 * old context then flushed its red triangle over. That corruption is
	 * fixed at the source, but a second context in backboardd is still not
	 * what the UI path wants.
	 */
	if (!boot_arg_set("gltest=1")) {
		return;
	}
	if (access("/usr/libexec/mondrian-gpu-test.dylib", R_OK) != 0) {
		return;
	}
	handle = dlopen("/usr/libexec/mondrian-gpu-test.dylib", RTLD_NOW);
	say(handle != NULL ? "MONDRIAN UI: gpu test loaded\n"
	    : "MONDRIAN UI: gpu test dlopen failed\n");
	/* Mesa drawing on the GPU, independent of CoreAnimation. */
	if (access("/usr/libexec/mondrian-mesa-test.dylib", R_OK) == 0) {
		handle = dlopen("/usr/libexec/mondrian-mesa-test.dylib",
		    RTLD_NOW);
		say(handle != NULL ? "MONDRIAN UI: mesa test loaded\n"
		    : "MONDRIAN UI: mesa test dlopen failed\n");
	}
}

/*
 * Boot-arg mondrianlink=1: two CADisplayLinks of our own, one on the main
 * run loop and one on a run loop of a thread we start, and a line a second
 * with how many times each fired. Everything the window server does with a
 * finger and every animation CoreAnimation runs hang off this link; if it
 * never fires, the clock stands still and touches are only parked. Two links
 * tell the two failures apart: neither ticking is the link itself, only the
 * main one is a stuck main run loop.
 */
static volatile uint64_t mondrian_link_ticks[2];
static volatile uint64_t mondrian_timer_ticks;
static volatile uint64_t mondrian_wait_ticks;
static CADisplayLink *mondrian_main_link;
static volatile double mondrian_link_duration;
static volatile double mondrian_link_timestamp;

@interface MondrianLinkTarget : NSObject
@property(nonatomic) int which;
@end

@implementation MondrianLinkTarget
- (void)tick:(CADisplayLink *)link
{
	(void)link;
	mondrian_link_ticks[self.which]++;
}

- (void)timerTick:(NSTimer *)timer
{
	(void)timer;
	mondrian_timer_ticks++;
}
@end

/*
 * Two counters beside the links, because "the link never fires" has three
 * different causes and the fix differs for each. A plain one-second NSTimer on
 * the same run loop says whether the run loop serves timers at all; a thread
 * that only ever calls mach_wait_until says whether an absolute deadline in
 * this kernel wakes a user thread.
 */
static void *
mondrian_wait_run(void *unused)
{
	mach_timebase_info_data_t tb;
	uint64_t period;

	(void)unused;
	mach_timebase_info(&tb);
	period = tb.numer != 0 ? (uint64_t)1000000000ULL * tb.denom / tb.numer : 24000000ULL;
	for (;;) {
		mach_wait_until(mach_absolute_time() + period);
		mondrian_wait_ticks++;
	}
	return NULL;
}

/*
 * Boot-arg mondrianmain=1: every two seconds, one sample of the main thread's
 * pc and frame-pointer chain, resolved to symbols. The sampler above follows
 * the busiest thread, which on this port is always an idle libdispatch worker;
 * when the main run loop stops being serviced (no CADisplayLink, no NSTimer)
 * this is what says where the main thread actually is.
 */
static void
mondrian_main_frame(uint64_t addr, char *out, size_t size)
{
	Dl_info info;

	if (addr == 0) {
		snprintf(out, size, "-");
		return;
	}
	if (dladdr((void *)addr, &info) != 0 && info.dli_sname != NULL) {
		snprintf(out, size, "%s+%ld", info.dli_sname,
		    (long)((char *)addr - (char *)info.dli_saddr));
		return;
	}
	snprintf(out, size, "%llx", (unsigned long long)addr);
}

static void *
mondrian_main_watch(void *unused)
{
	(void)unused;
	for (int n = 0; n < 90; n++) {
		arm_thread_state64_t state;
		mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
		char line[420], f[6][72];
		uint64_t fp;
		int used = 0;

		sleep(2);
		if (mondrian_main_thread == MACH_PORT_NULL) {
			continue;
		}
		if (thread_get_state(mondrian_main_thread, ARM_THREAD_STATE64,
		    (thread_state_t)&state, &count) != KERN_SUCCESS) {
			continue;
		}
		mondrian_main_frame(state.__pc, f[0], sizeof(f[0]));
		mondrian_main_frame(state.__lr, f[1], sizeof(f[1]));
		fp = state.__fp;
		for (int i = 2; i < 6 && fp >= 0x100000000ULL; i++) {
			uint64_t frame[2];
			vm_size_t got = 0;

			if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
			    sizeof(frame), (vm_address_t)frame, &got) != KERN_SUCCESS ||
			    got != sizeof(frame) || frame[1] == 0) {
				break;
			}
			mondrian_main_frame(frame[1], f[i], sizeof(f[i]));
			used = i;
			fp = frame[0];
		}
		used = used < 2 ? 2 : used + 1;
		{
			char *p = line;
			size_t left = sizeof(line);

			int k = snprintf(p, left, "MONDRIAN UI: main pid %d", getpid());
			p += k; left -= (size_t)k;
			for (int i = 0; i < used && left > 8; i++) {
				k = snprintf(p, left, " %s", f[i]);
				p += k; left -= (size_t)k;
			}
			snprintf(p, left, "\n");
		}
		say(line);
	}
	return NULL;
}

static void *
mondrian_link_run(void *unused)
{
	(void)unused;
	@autoreleasepool {
		MondrianLinkTarget *target = [[MondrianLinkTarget alloc] init];
		CADisplayLink *link;

		target.which = 1;
		link = [CADisplayLink displayLinkWithTarget:target
		    selector:@selector(tick:)];
		if (link == nil) {
			say("MONDRIAN UI: link own thread: no link\n");
			return NULL;
		}
		[link addToRunLoop:[NSRunLoop currentRunLoop]
		    forMode:NSDefaultRunLoopMode];
		say("MONDRIAN UI: link own thread armed\n");
		for (;;) {
			@autoreleasepool {
				[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
			}
		}
	}
	return NULL;
}

static void *
mondrian_link_report(void *unused)
{
	(void)unused;
	for (int i = 0; i < 150; i++) {
		char line[128];

		sleep(1);
		if (mondrian_main_link != nil) {
			mondrian_link_duration = mondrian_main_link.duration;
			mondrian_link_timestamp = mondrian_main_link.timestamp;
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: link pid %d main %llu own %llu timer %llu wait %llu dur %d ts %d\n",
		    getpid(),
		    (unsigned long long)mondrian_link_ticks[0],
		    (unsigned long long)mondrian_link_ticks[1],
		    (unsigned long long)mondrian_timer_ticks,
		    (unsigned long long)mondrian_wait_ticks,
		    (int)(mondrian_link_duration * 1000.0),
		    (int)mondrian_link_timestamp);
		say(line);
	}
	return NULL;
}

static void
mondrian_link_probe(void)
{
	static MondrianLinkTarget *main_target;
	pthread_t thread;

	if (!boot_arg_set("mondrianlink=1")) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		CADisplayLink *link;
		NSTimer *timer;

		main_target = [[MondrianLinkTarget alloc] init];
		main_target.which = 0;
		link = [CADisplayLink displayLinkWithTarget:main_target
		    selector:@selector(tick:)];
		if (link == nil) {
			say("MONDRIAN UI: link main: no link\n");
		} else {
			[link addToRunLoop:[NSRunLoop mainRunLoop]
			    forMode:NSRunLoopCommonModes];
			mondrian_main_link = link;
			say("MONDRIAN UI: link main armed\n");
		}
		timer = [NSTimer timerWithTimeInterval:1.0 target:main_target
		    selector:@selector(timerTick:) userInfo:nil repeats:YES];
		[[NSRunLoop mainRunLoop] addTimer:timer
		    forMode:NSRunLoopCommonModes];
		say("MONDRIAN UI: timer armed\n");
	});
	if (pthread_create(&thread, NULL, mondrian_link_run, NULL) != 0) {
		say("MONDRIAN UI: link own thread failed\n");
	}
	if (pthread_create(&thread, NULL, mondrian_wait_run, NULL) != 0) {
		say("MONDRIAN UI: wait thread failed\n");
	}
	if (pthread_create(&thread, NULL, mondrian_link_report, NULL) != 0) {
		say("MONDRIAN UI: link report failed\n");
	}
}

__attribute__((constructor))
static void
mondrian_install_ui_hooks(void)
{
	console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	NSSetUncaughtExceptionHandler(mondrian_uncaught);
	install_number_length_hook();
	say_pid("UI: dylib loaded");
	install_personas_hook();
	install_display_diagnostic();
	install_activation_hooks();
	install_icon_probe();
	install_idle_hooks();
	start_heartbeat();
	if (boot_arg_set("mondrianmain=1")) {
		pthread_t thread;

		if (pthread_create(&thread, NULL, mondrian_main_watch, NULL) != 0) {
			say("MONDRIAN UI: main watch failed\n");
		}
	}
	mondrian_link_probe();
	load_gpu_test();
}
