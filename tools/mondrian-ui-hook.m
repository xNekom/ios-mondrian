/* Opt-in containermanagerd/backboardd diagnostics for the mondrian bring-up test. */
#import <objc/objc.h>
#import <objc/runtime.h>

#include <stddef.h>
#include <unistd.h>

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

static void
say(const char *message)
{
	(void)write(STDERR_FILENO, message, __builtin_strlen(message));
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
	say("MONDRIAN UI: CAWindowServer._detectDisplays enter\n");
	original_detect_displays(self, selector);
	say("MONDRIAN UI: CAWindowServer._detectDisplays return\n");
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

__attribute__((constructor))
static void
mondrian_install_ui_hooks(void)
{
	install_personas_hook();
	install_display_diagnostic();
}
