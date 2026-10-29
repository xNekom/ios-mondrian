/* Opt-in containermanagerd/backboardd diagnostics for the mondrian bring-up test. */
#import <objc/objc.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/thread_state.h>
#import <mach/thread_info.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

#include <fcntl.h>
#include <pthread.h>
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
static void
load_gpu_test(void)
{
	void *handle;

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
	start_heartbeat();
	load_gpu_test();
}
