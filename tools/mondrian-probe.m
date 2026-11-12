/*
 * /private/var/vm/mondrian-probe.dylib: what the Settings app needs to open a
 * pane on this port, and what it does when it does not get it.
 *
 * The report was "General > Date & Time never opens": the row highlights, no
 * further touch is taken, and the panel keeps showing the list. The process
 * sampler puts the app's main thread in a synchronous response wait:
 *
 *   libsystem_kernel mach_msg <- libdispatch _dispatch_mach_send_and_wait...
 *   <- libxpc xpc_connection_send_message_with_reply_sync <- Foundation
 *   <- CoreLocation <- GeneralSettingsUI (the pushed pane's own setup)
 *   <- Preferences (the push)
 *
 * so the pane asks CoreLocation something and waits for locationd, which on
 * this port starts and never answers. Nothing in that chain is an Objective-C
 * method, so the instrument is the XPC call itself.
 *
 * WHAT IT DOES, AND WHY IT IS CONFIGURABLE
 *
 * A boot is expensive, so the behaviour is chosen at run time instead of being
 * compiled in: /private/var/vm/mondrian-probe.cfg holds one line, reread on
 * every call (these calls are rare), and the host rewrites it over the USB
 * control channel ("wfile") while the phone runs. The variants:
 *
 *   pass       observe only: log the request and the reply (the default)
 *   empty      answer with an empty dictionary
 *   error      answer with XPC_ERROR_CONNECTION_INVALID
 *   delay N    wait N seconds and then pass through
 *   off        do not intercept at all
 *
 * One boot can therefore answer "which reply shape opens the pane" and "what
 * does the pane do with a bad answer", instead of one boot per guess.
 *
 * WHAT IT LOGS
 *
 *   MONDRIAN PROBE: xpc sync com.apple.locationd.private req {...}
 *   MONDRIAN PROBE: xpc sync com.apple.locationd.private reply {...}
 *   MONDRIAN PROBE: xpc get key <name> -> <type>
 *
 * The request and the reply are printed with xpc_copy_description, and the
 * reply of the call under test is remembered so the getters the app calls on
 * it name the keys it actually needs. That is the observation that turns the
 * next boot into a fix: the keys, not a guess at them.
 *
 * WHO LOADS IT
 *
 *   bsd/kern/kern_exec.c, boot arguments mondrian_probe=1 and
 *   mondrian_probe_proc=Preferences, inject
 *   DYLD_INSERT_LIBRARIES=/private/var/vm/mondrian-probe.dylib into the exec of
 *   that process. glblob=1 writes that file from the kernel image at boot, so
 *   no userdata flash is involved (xnu patch 0306, tools/gen-glblob.py);
 *   "wfile" replaces it afterwards (xnu patch 0311).
 *
 * It also points the app's stderr at the console ring (an app's stderr is
 * /dev/null, which is why an exception never said anything) and logs the
 * navigation pushes.
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
 *
 * xpc_get_type returns a pointer to a type object, so a type is named by
 * comparing against the exported ones; the error objects are structs whose
 * address is the object (that is what XPC_ERROR_CONNECTION_INVALID is).
 */
struct _xpc_type_s;
typedef struct _xpc_connection_s *xpc_connection_t;
typedef struct _xpc_object_s *xpc_object_t;
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);
extern const char *xpc_connection_get_name(xpc_connection_t connection);
extern xpc_object_t xpc_dictionary_create(const void *keys, const void *values,
    size_t count);
extern char *xpc_copy_description(xpc_object_t object);
extern xpc_object_t xpc_dictionary_get_value(xpc_object_t object,
    const char *key);
extern struct _xpc_type_s *xpc_get_type(xpc_object_t object);
extern bool xpc_dictionary_apply(xpc_object_t object,
    bool (^applier)(const char *key, xpc_object_t value));
extern struct _xpc_type_s _xpc_type_dictionary;
extern struct _xpc_type_s _xpc_type_array;
extern struct _xpc_type_s _xpc_type_string;
extern struct _xpc_type_s _xpc_type_int64;
extern struct _xpc_type_s _xpc_type_uint64;
extern struct _xpc_type_s _xpc_type_bool;
extern struct _xpc_type_s _xpc_type_double;
extern struct _xpc_type_s _xpc_type_error;
extern struct _xpc_type_s _xpc_type_null;
extern struct _xpc_object_s _xpc_error_connection_invalid;

#define CFG_PATH    "/private/var/vm/mondrian-probe.cfg"
#define PROBE_PROC  "Preferences"

static int console_fd = -1;
static int lines;
static int logged_mode = -1;

enum mode { MODE_PASS, MODE_EMPTY, MODE_ERROR, MODE_DELAY, MODE_OFF };

static void
say(const char *fmt, ...)
{
	char line[400];
	va_list ap;
	int n;

	if (lines >= 400) {
		return;
	}
	va_start(ap, fmt);
	n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (n <= 0) {
		return;
	}
	if (n > (int)sizeof(line) - 1) {
		n = (int)sizeof(line) - 1;
	}
	lines++;
	if (console_fd >= 0) {
		(void)write(console_fd, line, (size_t)n);
	}
}

/*
 * The variant, read from a file the host can rewrite while the phone runs. A
 * missing or unreadable file is "pass": observing never changes what the app
 * sees, so the default is safe for a boot that only wants the log.
 */
static void
read_config(enum mode *mode, int *delay_s)
{
	char buf[64];
	int fd, n;

	*mode = MODE_PASS;
	*delay_s = 0;
	fd = open(CFG_PATH, O_RDONLY);
	if (fd < 0) {
		return;
	}
	n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) {
		return;
	}
	buf[n] = 0;
	if (strncmp(buf, "empty", 5) == 0) {
		*mode = MODE_EMPTY;
	} else if (strncmp(buf, "error", 5) == 0) {
		*mode = MODE_ERROR;
	} else if (strncmp(buf, "delay", 5) == 0) {
		*mode = MODE_DELAY;
		*delay_s = atoi(buf + 5);
		if (*delay_s < 0) {
			*delay_s = 0;
		}
	} else if (strncmp(buf, "off", 3) == 0) {
		*mode = MODE_OFF;
	}
}

static const char *
mode_name(enum mode mode)
{
	switch (mode) {
	case MODE_EMPTY: return "empty";
	case MODE_ERROR: return "error";
	case MODE_DELAY: return "delay";
	case MODE_OFF:   return "off";
	default:         return "pass";
	}
}

/*
 * The replies under test, so a getter can tell whether it is looking at one.
 * Small and fixed: the app hands the dictionary straight to its own code.
 */
#define MAX_REPLIES 8
static xpc_object_t replies[MAX_REPLIES];
static int reply_next;

static void
remember_reply(xpc_object_t reply)
{
	replies[reply_next] = reply;
	reply_next = (reply_next + 1) % MAX_REPLIES;
}

static int
is_ours(xpc_object_t object)
{
	int i;

	for (i = 0; i < MAX_REPLIES; i++) {
		if (replies[i] == object) {
			return 1;
		}
	}
	return 0;
}

static const char *
type_name(xpc_object_t object)
{
	struct _xpc_type_s *t;

	if (object == NULL) {
		return "null";
	}
	t = xpc_get_type(object);
	if (t == &_xpc_type_dictionary) {
		return "dictionary";
	}
	if (t == &_xpc_type_array) {
		return "array";
	}
	if (t == &_xpc_type_string) {
		return "string";
	}
	if (t == &_xpc_type_int64) {
		return "int64";
	}
	if (t == &_xpc_type_uint64) {
		return "uint64";
	}
	if (t == &_xpc_type_bool) {
		return "bool";
	}
	if (t == &_xpc_type_double) {
		return "double";
	}
	if (t == &_xpc_type_error) {
		return "error";
	}
	if (t == &_xpc_type_null) {
		return "null";
	}
	return "other";
}

static void
print_keys(const char *what, xpc_object_t object)
{
	__block int n = 0;

	if (object == NULL) {
		say("MONDRIAN PROBE: %s (null)\n", what);
		return;
	}
	if (xpc_get_type(object) != &_xpc_type_dictionary) {
		say("MONDRIAN PROBE: %s type %s\n", what, type_name(object));
		return;
	}
	xpc_dictionary_apply(object, ^bool(const char *key, xpc_object_t value) {
		if (n++ < 24) {
			say("MONDRIAN PROBE: %s key %s (%s)\n", what, key,
			    type_name(value));
		} else if (n == 25) {
			say("MONDRIAN PROBE: %s more keys follow\n", what);
		}
		return true;
	});
	if (n == 0) {
		say("MONDRIAN PROBE: %s has no keys\n", what);
	}
}

static bool
probe_sync_wanted(xpc_connection_t connection, const char **name_out)
{
	const char *name = connection != NULL ?
	    xpc_connection_get_name(connection) : NULL;

	*name_out = name != NULL ? name : "(null)";
	return name != NULL && strstr(name, "location") != NULL;
}

/*
 * A call on another service still says which one: the blocked call is known
 * from a stack sample, but one boot can also answer "was it even locationd?"
 * without a second boot. Each name is reported once, so a busy app cannot
 * drown the ring.
 */
#define MAX_NAMES 8
static char seen_names[MAX_NAMES][64];
static int seen_count;

static void
note_name(const char *name)
{
	int i;

	for (i = 0; i < seen_count; i++) {
		if (strcmp(seen_names[i], name) == 0) {
			return;
		}
	}
	if (seen_count >= MAX_NAMES || strlen(name) >= sizeof(seen_names[0])) {
		return;
	}
	strcpy(seen_names[seen_count], name);
	seen_count++;
	say("MONDRIAN PROBE: xpc sync on %s, passing through\n", name);
}

/*
 * The replaced call has to be reached through the next image in the search
 * order: dyld rewrites the symbol table of every image, this one included, so a
 * direct call from here would run this function again until the stack is gone.
 */
typedef xpc_object_t (*sync_fn)(xpc_connection_t, xpc_object_t);

static sync_fn real_sync;

static xpc_object_t
real_sync_send(xpc_connection_t connection, xpc_object_t message)
{
	if (real_sync == NULL) {
		real_sync = (sync_fn)dlsym(RTLD_NEXT,
		    "xpc_connection_send_message_with_reply_sync");
	}
	if (real_sync == NULL) {
		return NULL;
	}
	return real_sync(connection, message);
}

static xpc_object_t
probe_sync(xpc_connection_t connection, xpc_object_t message)
{
	enum mode mode;
	int delay_s;
	const char *name;
	xpc_object_t reply;
	char *desc;

	if (!probe_sync_wanted(connection, &name)) {
		if (strcmp(name, "(null)") != 0) {
			note_name(name);
		}
		return real_sync_send(connection, message);
	}

	read_config(&mode, &delay_s);
	if (mode != logged_mode) {
		logged_mode = mode;
		say("MONDRIAN PROBE: mode %s (pid %d)\n", mode_name(mode),
		    (int)getpid());
	}
	desc = xpc_copy_description(message);
	say("MONDRIAN PROBE: xpc sync %s req %.320s\n", name,
	    desc != NULL ? desc : "(no description)");
	free(desc);

	if (mode == MODE_OFF) {
		return real_sync_send(connection, message);
	}
	if (mode == MODE_EMPTY) {
		reply = xpc_dictionary_create(NULL, NULL, 0);
		remember_reply(reply);
		say("MONDRIAN PROBE: xpc sync %s answered empty\n", name);
		return reply;
	}
	if (mode == MODE_ERROR) {
		say("MONDRIAN PROBE: xpc sync %s answered error\n", name);
		return (xpc_object_t)&_xpc_error_connection_invalid;
	}
	if (mode == MODE_DELAY && delay_s > 0) {
		say("MONDRIAN PROBE: xpc sync %s sleeping %d s\n", name, delay_s);
		sleep((unsigned)delay_s);
	}

	reply = real_sync_send(connection, message);
	desc = reply != NULL ? xpc_copy_description(reply) : NULL;
	say("MONDRIAN PROBE: xpc sync %s reply %.320s\n", name,
	    desc != NULL ? desc : "(null)");
	free(desc);
	if (reply != NULL && xpc_get_type(reply) == &_xpc_type_dictionary) {
		remember_reply(reply);
		print_keys("reply", reply);
	}
	return reply;
}

/*
 * The getter, wrapped only for the replies under test: a global wrap would tax
 * every xpc call in the app and answer nothing more. This is the half that
 * names the keys the pane needs when locationd never sends a dictionary.
 */
typedef xpc_object_t (*get_value_fn)(xpc_object_t, const char *);

static get_value_fn real_get_value;

static xpc_object_t
probe_get_value(xpc_object_t object, const char *key)
{
	xpc_object_t value;

	if (real_get_value == NULL) {
		real_get_value = (get_value_fn)dlsym(RTLD_NEXT,
		    "xpc_dictionary_get_value");
	}
	if (real_get_value == NULL) {
		return NULL;
	}
	value = real_get_value(object, key);
	if (is_ours(object) && key != NULL) {
		say("MONDRIAN PROBE: xpc get key %s -> %s\n", key,
		    value != NULL ? type_name(value) : "missing");
	}
	return value;
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

DYLD_INTERPOSE(probe_get_value, xpc_dictionary_get_value);
/*
 * The call the pane blocks in. Without this line the whole variant machinery
 * above is unreferenced static code and the linker drops it: the boot then logs
 * the Objective-C hooks and nothing about the request that never answers.
 */
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
	const char *me = getprogname();

	/*
	 * The kernel injects this into one process, but a copied image or a
	 * second target must not turn the other daemons into a log source.
	 */
	if (me != NULL && strcmp(me, PROBE_PROC) != 0) {
		return;
	}
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
