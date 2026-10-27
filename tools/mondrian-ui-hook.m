/* Opt-in containermanagerd/backboardd diagnostics for the mondrian bring-up test. */
#import <objc/objc.h>
#import <objc/runtime.h>

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

static void
start_heartbeat(void)
{
	pthread_t thread;

	(void)pthread_create(&thread, NULL, heartbeat, NULL);
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
		snprintf(line, sizeof(line), "  %s\n", ivar_getName(ivars[i]));
		say(line);
	}
	free(ivars);
}

static BOOL
mondrian_setup_not_required(id self, __unused SEL selector)
{
	(void)self;
	say("MONDRIAN UI: setup not required\n");
	return NO;
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
 * A root that has just been flashed never reaches -_setupActivationState:
 * SpringBoard takes the setup path first, so the ivar that method is supposed
 * to fill keeps its zero and the boot sits at the Apple logo. Write the same
 * value whenever the manager is handed out or created, so the lock screen has
 * an activated state whatever path SpringBoard takes.
 */
static id (*original_lockdown_init)(id, SEL);
static id (*original_shared_instance)(id, SEL);

static void
mondrian_force_activation(id manager, const char *where)
{
	int *state;

	if (manager == nil || mondrian_activation_offset < 0) {
		return;
	}
	state = (int *)((char *)manager + mondrian_activation_offset);
	if (*state != 2) {
		*state = 2;    /* activated */
		say(where);
	}
}

static id
mondrian_lockdown_init(id self, SEL selector)
{
	id manager = original_lockdown_init != NULL ? original_lockdown_init(self, selector) : self;

	mondrian_force_activation(manager, "MONDRIAN UI: lockdown init -> activated\n");
	return manager;
}

static id
mondrian_lockdown_shared(id self, SEL selector)
{
	id manager = original_shared_instance != NULL ? original_shared_instance(self, selector) : nil;

	mondrian_force_activation(manager, "MONDRIAN UI: lockdown sharedInstance -> activated\n");
	return manager;
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
		Method init = class_getInstanceMethod(lockdown, sel_registerName("init"));
		if (init != NULL) {
			original_lockdown_init = (id (*)(id, SEL))method_setImplementation(
			    init, (IMP)mondrian_lockdown_init);
			say("MONDRIAN UI: lockdown init hook installed\n");
		}
		Method shared = class_getClassMethod(lockdown, sel_registerName("sharedInstance"));
		if (shared != NULL) {
			original_shared_instance = (id (*)(id, SEL))method_setImplementation(
			    shared, (IMP)mondrian_lockdown_shared);
			say("MONDRIAN UI: lockdown sharedInstance hook installed\n");
		}
	}

	Class setup_manager = objc_getClass("SBSetupManager");
	SEL reason_sel = sel_registerName("_setSetupRequiredReason:");
	Method reason = setup_manager != Nil ? class_getInstanceMethod(setup_manager, reason_sel) : NULL;

	if (setup_manager != Nil) {
		static const char *const questions[] = {
			"isSetupRequired", "isSetupAssistantRunning",
		};

		mondrian_dump_class("SBSetupManager");
		for (unsigned i = 0; i < sizeof(questions) / sizeof(questions[0]); i++) {
			Method m = class_getInstanceMethod(setup_manager,
			    sel_registerName(questions[i]));

			if (m != NULL) {
				method_setImplementation(m, (IMP)mondrian_setup_not_required);
				snprintf(line, sizeof(line), "MONDRIAN UI: %s -> NO\n", questions[i]);
				say(line);
			}
		}
	}

	if (reason != NULL && method_getNumberOfArguments(reason) == 3) {
		original_set_setup_reason = (void (*)(id, SEL, long))method_setImplementation(
		    reason, (IMP)mondrian_set_setup_reason);
		say("MONDRIAN UI: setup-assistant hook installed\n");
	}
}

__attribute__((constructor))
static void
mondrian_install_ui_hooks(void)
{
	console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	say_pid("UI: dylib loaded");
	install_personas_hook();
	install_display_diagnostic();
	install_activation_hooks();
	start_heartbeat();
}
