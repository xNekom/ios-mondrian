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
 *   quiet      pass every call through without looking at it: the control run
 *              that keeps only the stack sampler
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
 * /dev/null, which is why an exception never said anything), logs the
 * navigation pushes, and arms two instruments. A sampler: `wfile` anything to
 * /private/var/vm/mondrian-probe.cmd and every thread of the process reports its
 * frames, named with dladdr; `wfile` "sym ADDR..." instead names addresses that
 * belong to *another* process, because the dyld shared cache is mapped at the
 * same place everywhere. And a fatal-signal handler, which prints the fault
 * address and a full sample before exiting -- when it runs at all: it never
 * does for the fault this app dies of, which is the point.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#define _XOPEN_SOURCE 700
#include <ucontext.h>
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
extern pid_t xpc_connection_get_pid(xpc_connection_t connection);
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
#define CMD_PATH    "/private/var/vm/mondrian-probe.cmd"
#define PROBE_PROC  "Preferences"

static int console_fd = -1;
static int lines;
static int logged_mode = -1;
static pthread_mutex_t say_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile sig_atomic_t in_crash;

enum mode { MODE_PASS, MODE_EMPTY, MODE_ERROR, MODE_DELAY, MODE_OFF, MODE_QUIET };

static void
say(const char *fmt, ...)
{
	char line[400];
	va_list ap;
	int n;

	if (lines >= 2000) {
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
	/*
	 * From inside the crash handler the lock is not taken: the signal can arrive
	 * while this very thread is between the trylock and the write, and a
	 * handler that waits there prints nothing at all -- which is exactly how the
	 * first attempt at catching the fault came back empty.
	 */
	if (in_crash) {
		if (console_fd >= 0) {
			(void)write(console_fd, line, (size_t)n);
		}
		return;
	}
	/*
	 * The sampler thread must never wait on the app's main thread: the whole
	 * point of a sample is that the main thread is stuck somewhere, and if it
	 * is stuck holding this lock a plain lock would hang the sampler too.
	 */
	if (pthread_mutex_trylock(&say_lock) != 0) {
		return;
	}
	if (console_fd >= 0) {
		(void)write(console_fd, line, (size_t)n);
	}
	pthread_mutex_unlock(&say_lock);
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
	} else if (strncmp(buf, "quiet", 5) == 0) {
		*mode = MODE_QUIET;
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
	case MODE_QUIET: return "quiet";
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

/* First sighting of a service name: 1, so the caller can time the call. */
static int
note_name(const char *name)
{
	int i;

	for (i = 0; i < seen_count; i++) {
		if (strcmp(seen_names[i], name) == 0) {
			return 0;
		}
	}
	if (seen_count >= MAX_NAMES || strlen(name) >= sizeof(seen_names[0])) {
		return 0;
	}
	strcpy(seen_names[seen_count], name);
	seen_count++;
	return 1;
}

/*
 * The replaced call has to be reached through the next image in the search
 * order: dyld rewrites the symbol table of every image, this one included, so a
 * direct call from here would run this function again until the stack is gone.
 */
typedef xpc_object_t (*sync_fn)(xpc_connection_t, xpc_object_t);

static sync_fn real_sync;

static void start_sampler(void);

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
	read_config(&mode, &delay_s);
	/*
	 * `quiet` is the control run: the interposition is still installed, but it
	 * looks at nothing and logs nothing, so the app sees what it would see
	 * without this dylib while the stack sampler stays armed.
	 */
	if (mode == MODE_QUIET) {
		return real_sync_send(connection, message);
	}
	/*
	 * The sampler thread is created here, on the first sync call, and not in
	 * the constructor: a thread started while dyld and UIKit are still
	 * initialising is one more thing to rule out when an app never draws.
	 */
	start_sampler();
	if (!probe_sync_wanted(connection, &name)) {
		int first = strcmp(name, "(null)") != 0 ? note_name(name) : 0;

		/*
		 * The two lines around the call are the measurement when a daemon
		 * does not answer: a name with "before" and no "after" never came
		 * back, which is a different fault from a reply the app mishandles.
		 */
		if (first) {
			say("MONDRIAN PROBE: xpc sync on %s (pid %d), before\n", name,
			    (int)xpc_connection_get_pid(connection));
		}
		reply = real_sync_send(connection, message);
		if (first) {
			say("MONDRIAN PROBE: xpc sync on %s, after (%s)\n", name,
			    reply == NULL ? "null" :
			    xpc_get_type(reply) == &_xpc_type_error ? "error" : "value");
		}
		return reply;
	}

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

/*
 * STACK SAMPLES ON DEMAND
 *
 * The pane that hangs shows nothing: no exception, no XPC line, and the app is
 * killed silently (runningboard answers a blocked main thread with SIGKILL, so
 * there is not even a crash report to read). What is left is where the threads
 * are, and that has to come from inside the wedged process.
 *
 * Writing /private/var/vm/mondrian-probe.cmd over the USB channel makes this
 * thread sample every thread of the process once and print the frames, each one
 * named with dladdr (the images are already loaded, so no symbols are needed on
 * the host and no boot is spent). The main thread is the interesting one: its
 * innermost frame names the call it is stuck in, and the frames above it name
 * the caller that asked for it.
 */
static mach_port_t main_thread_port;

static void
log_pc(uint64_t pc, const char *what, int frame)
{
	Dl_info info;
	const char *img = NULL;
	const char *sym = NULL;

	memset(&info, 0, sizeof(info));
	if (dladdr((void *)(uintptr_t)pc, &info) != 0) {
		sym = info.dli_sname;
		img = info.dli_fname;
	}
	if (img != NULL) {
		const char *slash = strrchr(img, '/');

		img = slash != NULL ? slash + 1 : img;
	}
	if (sym != NULL) {
		say("MONDRIAN PROBE: %s f%d %p %s %s+%#lx\n", what, frame,
		    (void *)(uintptr_t)pc, img != NULL ? img : "?", sym,
		    (unsigned long)(pc - (uint64_t)(uintptr_t)info.dli_saddr));
	} else {
		say("MONDRIAN PROBE: %s f%d %p %s+%#lx\n", what, frame,
		    (void *)(uintptr_t)pc, img != NULL ? img : "?",
		    (unsigned long)(pc - (uint64_t)(uintptr_t)info.dli_fbase));
	}
}

/* Reading a stale frame pointer has to fail, not fault: vm_read_overwrite. */
static bool
read_frame(uint64_t at, uint64_t *fp_out, uint64_t *lr_out)
{
	uint64_t frame[2];
	vm_size_t got = 0;

	if (vm_read_overwrite(mach_task_self(), (vm_address_t)at, sizeof(frame),
	    (vm_address_t)(uintptr_t)frame, &got) != KERN_SUCCESS ||
	    got != sizeof(frame)) {
		return false;
	}
	*fp_out = frame[0];
	*lr_out = frame[1];
	return true;
}

static void
log_thread(mach_port_t thread, int n)
{
	arm_thread_state64_t st;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	uint64_t pc, lr, fp, sp, cur;
	char what[16];
	int frame;

	if (thread_get_state(thread, ARM_THREAD_STATE64,
	    (thread_state_t)&st, &count) != KERN_SUCCESS) {
		return;
	}
	pc = arm_thread_state64_get_pc(st);
	lr = arm_thread_state64_get_lr(st);
	fp = arm_thread_state64_get_fp(st);
	sp = arm_thread_state64_get_sp(st);
	snprintf(what, sizeof(what), "t%d", n);
	say("MONDRIAN PROBE: %s pc %p lr %p sp %p\n", what, (void *)(uintptr_t)pc,
	    (void *)(uintptr_t)lr, (void *)(uintptr_t)sp);
	log_pc(pc, what, 0);
	if (lr != 0) {
		log_pc(lr, what, 1);
	}
	cur = fp;
	for (frame = 2; frame < 14 && cur != 0; frame++) {
		uint64_t next;

		if ((cur & 7) != 0 || cur < sp || cur - sp > (64u << 20)) {
			break;
		}
		if (!read_frame(cur, &next, &lr) || lr == 0) {
			break;
		}
		log_pc(lr, what, frame);
		if (next <= cur) {
			break;
		}
		cur = next;
	}
}

/*
 * NAME ANOTHER PROCESS'S ADDRESS
 *
 * The dyld shared cache is mapped at the same address in every process, so a
 * pc read out of another process's thread state -- the kernel sampler prints
 * those ("SMP name t2 pc 0x...") -- resolves here with dladdr. That turns
 * "cfprefsd's three threads are all at 0x205b554f0" into a function name in the
 * same boot, and into the library that called it, without the shared cache.
 */
static void
symbolize(const char *args)
{
	const char *p = args;

	for (int i = 0; i < 8; i++) {
		char *end = NULL;
		unsigned long long a;

		while (*p == ' ' || *p == ',') {
			p++;
		}
		if (*p == 0) {
			return;
		}
		a = strtoull(p, &end, 0);
		if (end == p) {
			return;
		}
		p = end;
		log_pc((uint64_t)a, "sym", i);
	}
}

static void
sample_threads(void);

static void
read_command(void)
{
	char buf[256];
	int fd, n;

	fd = open(CMD_PATH, O_RDONLY);
	if (fd < 0) {
		return;
	}
	n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) {
		return;
	}
	buf[n] = 0;
	if (strncmp(buf, "sym", 3) == 0) {
		symbolize(buf + 3);
		return;
	}
	/*
	 * Two calibration commands, used once and kept because they answer questions
	 * the ring cannot: "exit N" tells whether the kernel's exit line prints the
	 * exit code or the terminating signal, and "raise N" tells whether a signal
	 * this process raises itself reaches the handler above (a fault that is not
	 * catchable at all -- a guard exception -- does not).
	 */
	if (strncmp(buf, "exit ", 5) == 0) {
		int code = atoi(buf + 5);

		say("MONDRIAN PROBE: self exit %d\n", code);
		_exit(code);
	}
	if (strncmp(buf, "raise ", 6) == 0) {
		int sig = atoi(buf + 6);

		say("MONDRIAN PROBE: self raise %d\n", sig);
		(void)raise(sig);
		return;
	}
	sample_threads();
}

static void
sample_threads(void)
{
	thread_act_array_t list = NULL;
	mach_msg_type_number_t n = 0;
	mach_msg_type_number_t i;

	say("MONDRIAN PROBE: sample begin pid %d\n", (int)getpid());
	if (main_thread_port != MACH_PORT_NULL) {
		log_thread(main_thread_port, 0);
	}
	if (task_threads(mach_task_self(), &list, &n) == KERN_SUCCESS && list != NULL) {
		say("MONDRIAN PROBE: %u threads\n", (unsigned)n);
		for (i = 0; i < n && i < 12; i++) {
			if (list[i] == main_thread_port) {
				continue;
			}
			log_thread(list[i], (int)i + 1);
		}
		vm_deallocate(mach_task_self(), (vm_address_t)list,
		    n * sizeof(*list));
	}
	say("MONDRIAN PROBE: sample end\n");
}

static void *
sampler_main(void *arg)
{
	struct stat sb;

	(void)arg;
	for (;;) {
		if (stat(CMD_PATH, &sb) == 0) {
			read_command();
			(void)unlink(CMD_PATH);
		}
		usleep(200000);
	}
	return NULL;
}

static void
start_sampler(void){
	static int started;
	pthread_t tid;

	if (started) {
		return;
	}
	started = 1;
	if (main_thread_port == MACH_PORT_NULL) {
		main_thread_port = mach_thread_self();
	}
	if (pthread_create(&tid, NULL, sampler_main, NULL) != 0) {
		say("MONDRIAN PROBE: sampler thread failed\n");
		return;
	}
	say("MONDRIAN PROBE: sampler armed on %s\n", CMD_PATH);
}

/*
 * THE LAST FRAMES BEFORE THE PROCESS DIES
 *
 * This app is killed by a signal (the kernel says "exit Preferences[pid]
 * status 0xa", SIGBUS) and the port's crash printer has nothing to show for it,
 * so the fault address and the stack at that instant are captured here. The
 * handler prints the signal, its address and the faulting pc/lr, samples every
 * thread once, and exits rather than returning: a fatal signal that is resumed
 * faults forever and fills the ring with the same report.
 */
static void
crash_handler(int sig, siginfo_t *si, void *uctx)
{
	ucontext_t *uc = (ucontext_t *)uctx;

	if (in_crash) {
		_exit(0);
	}
	in_crash = 1;
	(void)write(STDOUT_FILENO, "MONDRIAN PROBE: fatal signal entered\n", 37);
	if (uc != NULL) {
		uint64_t pc = (uint64_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
		uint64_t lr = (uint64_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
		uint64_t far = (uint64_t)uc->uc_mcontext->__es.__far;

		say("MONDRIAN PROBE: SIGNAL %d code %d addr %p pc %p lr %p far %p\n",
		    sig, si != NULL ? si->si_code : -1,
		    si != NULL ? si->si_addr : NULL,
		    (void *)(uintptr_t)pc, (void *)(uintptr_t)lr,
		    (void *)(uintptr_t)far);
		log_pc(pc, "sig", 0);
	} else {
		say("MONDRIAN PROBE: SIGNAL %d (no ucontext)\n", sig);
	}
	sample_threads();
	say("MONDRIAN PROBE: after SIGNAL %d\n", sig);
	_exit(0);
}

static void
arm_crash_handler(void)
{
	static const int fatal[] = { SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = crash_handler;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
	sigemptyset(&sa.sa_mask);
	for (unsigned i = 0; i < sizeof(fatal) / sizeof(fatal[0]); i++) {
		(void)sigaction(fatal[i], &sa, NULL);
	}
	say("MONDRIAN PROBE: crash handler armed\n");
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
	main_thread_port = mach_thread_self();	/* the constructor runs on it */
	NSSetUncaughtExceptionHandler(probe_exception);
	arm_crash_handler();

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
