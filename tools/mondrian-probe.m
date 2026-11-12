/*
 * /private/var/vm/mondrian-probe.dylib: what the Settings app needs to open a
 * pane on this port.
 *
 * The report was "General > Date & Time never opens". What actually happens is
 * a hang inside the push: the row highlights, no further touch is taken, and
 * the panel keeps showing the list. The process sampler (mondriansample) puts
 * the app's main thread here:
 *
 *   libsystem_kernel mach_msg <- libdispatch _dispatch_mach_send_and_wait...
 *   <- libxpc xpc_connection_send_message_with_reply_sync <- Foundation
 *   <- CoreLocation +0x33ec0 / +0xb710 / +0xca6c
 *   <- GeneralSettingsUI (the pushed pane's own setup)
 *   <- Preferences (the push)
 *
 * i.e. the pane's setup asks CoreLocation something and waits for a reply from
 * locationd that never arrives. Nothing in that chain is an Objective-C method,
 * so the instrument here is the XPC call itself: interpose
 * xpc_connection_send_message_with_reply_sync, print the service name and the
 * caller, and answer a location service with an empty reply so the pane takes
 * its "no location" path instead of waiting forever.
 *
 * WHO LOADS IT
 *
 *   bsd/kern/kern_exec.c, boot arguments mondrian_probe=1 and
 *   mondrian_probe_proc=Preferences, inject
 *   DYLD_INSERT_LIBRARIES=/private/var/vm/mondrian-probe.dylib into the exec of
 *   that process. glblob=1 writes that file from the kernel image at boot, so
 *   no userdata flash is involved (xnu patch 0306, tools/gen-glblob.py).
 *
 * It also points the app's stderr at the console ring (an app's stderr is
 * /dev/null, which is why an exception never said anything) and logs every
 * navigation push.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#import <Foundation/Foundation.h>

/*
 * libxpc, declared here: this toolchain's iPhoneOS SDK ships neither the
 * headers nor libxpc.tbd (the same reason tools/mondrian-ui-hook.m does it).
 */
typedef struct _xpc_connection_s *xpc_connection_t;
typedef struct _xpc_object_s *xpc_object_t;
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);
extern const char *xpc_connection_get_name(xpc_connection_t connection);
extern xpc_object_t xpc_dictionary_create(const void *keys, const void *values,
    size_t count);

static int console_fd = -1;

static void
say(const char *fmt, ...)
{
	char line[240];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (n <= 0) {
		return;
	}
	if (n > (int)sizeof(line) - 1) {
		n = (int)sizeof(line) - 1;
	}
	if (console_fd >= 0) {
		(void)write(console_fd, line, (size_t)n);
	}
}

/*
 * The synchronous XPC path. A caller that blocks here shows up in the sampler
 * as mach_msg <- libdispatch <- libxpc; printing the service name and the
 * caller's PC names the request without needing CoreLocation's symbol table,
 * which the shared cache does not carry.
 */
static xpc_object_t
probe_sync(xpc_connection_t connection, xpc_object_t message)
{
	const char *name = connection != NULL ?
	    xpc_connection_get_name(connection) : NULL;
	void *caller = __builtin_return_address(0);

	say("MONDRIAN PROBE: xpc sync %s from %p\n", name != NULL ? name : "(null)",
	    caller);
	if (name != NULL && strstr(name, "location") != NULL) {
		say("MONDRIAN PROBE: xpc sync %s answered empty\n", name);
		return xpc_dictionary_create(NULL, NULL, 0);
	}
	return xpc_connection_send_message_with_reply_sync(connection, message);
}

#define DYLD_INTERPOSE(_replacement, _replacee)                              \
	static struct {                                                      \
		const void *replacement;                                     \
		const void *replacee;                                        \
	} _interpose_##_replacee                                             \
	    __attribute__((used, section("__DATA,__interpose"))) = {         \
		(const void *)(unsigned long)&_replacement,                  \
		(const void *)(unsigned long)&_replacee,                     \
	}

DYLD_INTERPOSE(probe_sync, xpc_connection_send_message_with_reply_sync);

/*
 * Logging hooks on CoreLocation's Objective-C surface: the pane's request may
 * be an ordinary CLLocationManager message, and the last line before a hang
 * says which. Return types are split so the call through keeps the ABI right.
 */
#define MAX_HOOKS 24
static struct {
	Class receiver_class;
	SEL sel;
	IMP original;
} hooks[MAX_HOOKS];
static unsigned hook_count;

static IMP
original_for(id self, SEL cmd)
{
	Class receiver = object_getClass(self);
	unsigned i;

	for (i = 0; i < hook_count; i++) {
		if (hooks[i].receiver_class == receiver && hooks[i].sel == cmd) {
			return hooks[i].original;
		}
	}
	return NULL;
}

static void
log_call(id self, SEL cmd)
{
	say("MONDRIAN PROBE: call %c%s\n",
	    class_isMetaClass(object_getClass(self)) ? '+' : '-', sel_getName(cmd));
}

static id
logged_object(id self, SEL cmd)
{
	IMP original = original_for(self, cmd);

	log_call(self, cmd);
	return original != NULL ? ((id (*)(id, SEL))original)(self, cmd) : nil;
}

static void
logged_void(id self, SEL cmd)
{
	IMP original = original_for(self, cmd);

	log_call(self, cmd);
	if (original != NULL) {
		((void (*)(id, SEL))original)(self, cmd);
	}
}

enum hook_kind { K_OBJECT, K_VOID };

static void
hook_method(const char *cls_name, const char *sel_name, enum hook_kind kind)
{
	Class cls = objc_getClass(cls_name);
	Method m;

	if (cls == Nil || hook_count >= MAX_HOOKS) {
		return;
	}
	m = class_getInstanceMethod(cls, sel_registerName(sel_name));
	if (m == NULL) {
		return;
	}
	hooks[hook_count].receiver_class = cls;
	hooks[hook_count].sel = method_getName(m);
	hooks[hook_count].original = method_getImplementation(m);
	hook_count++;
	method_setImplementation(m, kind == K_OBJECT ? (IMP)logged_object :
	    (IMP)logged_void);
}

static void (*orig_push_vc)(id, SEL, id, BOOL);

static void
probe_push_vc(id self, SEL cmd, id controller, BOOL animated)
{
	say("MONDRIAN PROBE: push %s -> %s\n", class_getName(object_getClass(self)),
	    controller != Nil ? class_getName(object_getClass(controller)) : "nil");
	if (orig_push_vc != NULL) {
		orig_push_vc(self, cmd, controller, animated);
	}
}

static void
probe_exception(NSException *e)
{
	say("MONDRIAN PROBE: UNCAUGHT %s: %s\n",
	    e != nil ? [[e name] UTF8String] : "?",
	    e != nil ? [[e reason] UTF8String] : "?");
}

__attribute__((constructor)) static void
mondrian_probe_init(void)
{
	Class uinc;

	console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (console_fd >= 0) {
		dup2(console_fd, STDOUT_FILENO);
		dup2(console_fd, STDERR_FILENO);
		setvbuf(stderr, NULL, _IONBF, 0);
	}

	say("MONDRIAN PROBE: pid %d, injected\n", (int)getpid());
	NSSetUncaughtExceptionHandler(probe_exception);

	hook_method("CLLocationManager", "init", K_OBJECT);
	hook_method("CLLocationManager", "requestLocation", K_VOID);
	hook_method("CLLocationManager", "startUpdatingLocation", K_VOID);
	hook_method("CLLocationManager", "location", K_OBJECT);
	hook_method("CLLocationManager", "setDelegate:", K_VOID);
	hook_method("CLGeocoder", "reverseGeocodeLocation:completionHandler:", K_VOID);

	uinc = objc_getClass("UINavigationController");
	if (uinc != Nil) {
		Method m = class_getInstanceMethod(uinc,
		    sel_registerName("pushViewController:animated:"));

		if (m != NULL) {
			orig_push_vc = (void (*)(id, SEL, id, BOOL))
			    method_getImplementation(m);
			method_setImplementation(m, (IMP)probe_push_vc);
		}
	}
}
