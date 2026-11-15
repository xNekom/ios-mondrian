/* Opt-in containermanagerd/backboardd diagnostics for the mondrian bring-up test. */
#import <objc/objc.h>
#import <objc/runtime.h>
#import <objc/objc-exception.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <os/log.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/thread_act.h>
#import <mach/thread_state.h>
#import <mach/thread_info.h>
#import <dlfcn.h>

/*
 * libxpc, declared here: this toolchain's iPhoneOS SDK ships neither the
 * headers nor libxpc.tbd.
 */
typedef struct _xpc_connection_s *xpc_connection_t;
typedef struct _xpc_object_s *xpc_object_t;
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);
extern const char *xpc_connection_get_name(xpc_connection_t connection);
extern char *xpc_copy_description(xpc_object_t object);
extern int xpc_pipe_routine(xpc_object_t pipe, xpc_object_t message,
    xpc_object_t *reply);
/* Defined far below; the XPC wrapper above needs them. */
static int boot_arg_set(const char *name);
static int boot_arg_int(const char *name, int fallback);

/*
 * The bootstrap namespace lives in libSystem and the SDK ships no servers/
 * headers: the two entry points this probe needs are declared here.
 */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bootstrap_port,
    const char *service_name, mach_port_t *service_port);

#include <crt_externs.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>

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
 * Interposing a libsystem symbol does not take effect in this dylib: the XPC
 * wrapper that would have logged the launch request stayed silent across two
 * boots that did include a tap, while every Objective-C hook works. The
 * remaining way to see the request is to name it: this prints the selectors of
 * the classes in the launch path, so the next build swizzles the right one with
 * the right signature instead of guessing.
 */
static void
mondrian_rbs_probe(void)
{
	static const char *classes[] = {
		"RBSConnection", "RBSService",
		"FBProcessManager", "FBProcess", "FBApplicationProcess"
	};
	extern Class objc_getClass(const char *);
	unsigned shown = 0;

	for (size_t c = 0; c < sizeof(classes) / sizeof(classes[0]); c++) {
		Class cls = objc_getClass(classes[c]);
		char line[224];

		if (cls == Nil) {
			snprintf(line, sizeof(line),
			    "MONDRIAN RBS: %s absent\n", classes[c]);
			say(line);
			continue;
		}
		for (int meta = 0; meta < 2; meta++) {
			Class owner = meta ? object_getClass((id)cls) : cls;
			unsigned count = 0;
			Method *methods = class_copyMethodList(owner, &count);

			for (unsigned i = 0; methods != NULL && i < count; i++) {
				const char *sel = sel_getName(method_getName(methods[i]));

				if (strstr(sel, "launch") == NULL &&
				    strstr(sel, "Launch") == NULL &&
				    strstr(sel, "exec") == NULL &&
				    strstr(sel, "Exec") == NULL &&
				    strstr(sel, "bootstrap") == NULL &&
				    strstr(sel, "spawn") == NULL) {
					continue;
				}
				if (shown++ > 60) {
					continue;
				}
				snprintf(line, sizeof(line),
				    "MONDRIAN RBS: %s%s %s %s\n", classes[c],
				    meta ? " +" : " -", sel,
				    method_getTypeEncoding(methods[i]));
				say(line);
			}
			if (methods != NULL) {
				free(methods);
			}
		}
	}
}

static IMP forward_impl;
static int mondrian_srv_listed;

/*
 * The frames that matter in runningboardd are offsets inside images that live in
 * the dyld shared cache (AppServerSupport+0x2d10, RunningBoard+0x2eaf0), and the
 * cache is not on disk, so the file probe cannot name them. Here the Mach-O is
 * read from memory: a file offset is turned into the vmaddr of the segment that
 * contains it, then the symbol table is searched for the nearest name below.
 */
/*
 * Every frame line goes to the console, not to stdout: a daemon's stdout is
 * /dev/null, which is where the first version of this probe sent its answers.
 */
static void
mondrian_frame_say(int index, const char *image, uint64_t off, const char *sym,
    uint64_t delta, bool ok)
{
	char line[240];

	if (ok) {
		snprintf(line, sizeof(line),
		    "MONDRIAN FRAME[%d]: %s+0x%llx -> %s+0x%llx\n", index, image,
		    (unsigned long long)off, sym, (unsigned long long)delta);
	} else if (sym != NULL) {
		snprintf(line, sizeof(line), "MONDRIAN FRAME[%d]: %s %s\n",
		    index, image, sym);
	} else {
		snprintf(line, sizeof(line),
		    "MONDRIAN FRAME[%d]: %s+0x%llx -> no symbol below\n", index,
		    image, (unsigned long long)off);
	}
	say(line);
}

/*
 * A file offset inside an image becomes an address in memory: segments are
 * mapped relative to the image header, and __TEXT is the header, so the address
 * is hdr + (seg->vmaddr - __TEXT->vmaddr) + (off - seg->fileoff). The first
 * version used header + off, which is only right for a plain executable and
 * gave garbage for every image in the shared cache.
 */
static uintptr_t
mondrian_seg_addr(const struct mach_header_64 *hdr, uint32_t off,
    const char **why)
{
	struct load_command *cmd = (struct load_command *)((char *)hdr +
	    sizeof(*hdr));
	uint64_t text = 0;
	uintptr_t answer = 0;

	for (uint32_t pass = 0; pass < 2; pass++) {
		cmd = (struct load_command *)((char *)hdr + sizeof(*hdr));
		for (uint32_t i = 0; i < hdr->ncmds; i++) {
			if (cmd->cmd == LC_SEGMENT_64) {
				struct segment_command_64 *seg =
				    (struct segment_command_64 *)cmd;

				if (pass == 0 && strcmp(seg->segname, "__TEXT") == 0) {
					text = seg->vmaddr;
				} else if (pass == 1 &&
				    off >= seg->fileoff &&
				    off < seg->fileoff + seg->filesize) {
					answer = (uintptr_t)hdr +
					    (uintptr_t)(seg->vmaddr - text) +
					    (uintptr_t)(off - seg->fileoff);
				}
			}
			if (cmd->cmdsize == 0) {
				break;
			}
			cmd = (struct load_command *)((char *)cmd + cmd->cmdsize);
		}
	}
	if (answer == 0 && why != NULL) {
		*why = "offset outside the segments";
	}
	return answer;
}

static uint64_t
mondrian_image_text(const struct mach_header_64 *hdr)
{
	struct load_command *cmd = (struct load_command *)((char *)hdr +
	    sizeof(*hdr));

	for (uint32_t i = 0; i < hdr->ncmds; i++) {
		if (cmd->cmd == LC_SEGMENT_64) {
			struct segment_command_64 *seg = (struct segment_command_64 *)cmd;

			if (strcmp(seg->segname, "__TEXT") == 0) {
				return seg->vmaddr;
			}
		}
		if (cmd->cmdsize == 0) {
			break;
		}
		cmd = (struct load_command *)((char *)cmd + cmd->cmdsize);
	}
	return 0;
}

static void
mondrian_frame_name(int index, const char *wanted, uint64_t off)
{
	uint32_t count = _dyld_image_count();

	for (uint32_t i = 0; i < count; i++) {
		const struct mach_header_64 *hdr =
		    (const struct mach_header_64 *)_dyld_get_image_header(i);
		const char *path = _dyld_get_image_name(i);
		const char *base;
		struct load_command *cmd;
		struct symtab_command *sym = NULL;
		struct nlist_64 *nl;
		const char *strs;
		uint64_t target;
		const char *best = NULL;
		uint64_t best_val = 0;

		if (hdr == NULL || path == NULL || hdr->magic != MH_MAGIC_64) {
			continue;
		}
		base = strrchr(path, '/');
		base = base != NULL ? base + 1 : path;
		if (strncmp(base, wanted, strlen(wanted)) != 0) {
			continue;
		}
		cmd = (struct load_command *)((char *)hdr + sizeof(*hdr));
		for (uint32_t k = 0; k < hdr->ncmds; k++) {
			if (cmd->cmd == LC_SYMTAB) {
				sym = (struct symtab_command *)cmd;
			}
			if (cmd->cmdsize == 0) {
				break;
			}
			cmd = (struct load_command *)((char *)cmd + cmd->cmdsize);
		}
		if (sym == NULL || sym->symoff == 0 || sym->nsyms == 0) {
			mondrian_frame_say(index, base, off, "has no symbol table", 0,
			    false);
			return;
		}
		nl = (struct nlist_64 *)mondrian_seg_addr(hdr, sym->symoff, NULL);
		strs = (const char *)mondrian_seg_addr(hdr, sym->stroff, NULL);
		if (nl == NULL || strs == NULL) {
			mondrian_frame_say(index, base, off, "symbol table unmapped",
			    0, false);
			return;
		}
		target = mondrian_image_text(hdr) + off;
		for (uint32_t k = 0; k < sym->nsyms; k++) {
			if ((nl[k].n_type & 0x0e) != 0x0e || nl[k].n_un.n_strx == 0 ||
			    nl[k].n_value == 0 || nl[k].n_value > target) {
				continue;
			}
			if (nl[k].n_value < best_val) {
				continue;
			}
			best_val = nl[k].n_value;
			best = strs + nl[k].n_un.n_strx;
		}
		if (best != NULL && best[0] != '\0') {
			mondrian_frame_say(index, base, off, best, target - best_val,
			    true);
		} else {
			mondrian_frame_say(index, base, off, "no symbol below", 0,
			    false);
		}
		return;
	}
	mondrian_frame_say(index, wanted, off, "not loaded", 0, false);
}

static void *
mondrian_frames_thread(void *unused)
{
	static const struct {
		const char *image;
		uint64_t off;
	} frames[] = {
		{ "AppServerSupport", 0x2d10 },
		{ "AppServerSupport", 0x243c },
		{ "RunningBoard", 0x2eaf0 },
		{ "RunningBoard", 0x360f8 },
		{ "RunningBoard", 0x15504 },
		{ "libxpc.dylib", 0x4358 },
	};

	(void)unused;
	sleep(50);
	for (size_t i = 0; i < sizeof(frames) / sizeof(frames[0]); i++) {
		mondrian_frame_name((int)i, frames[i].image, frames[i].off);
	}
	return NULL;
}

/*
 * The server side, now named: RBLaunchdInterface hands the extension to launchd
 * and OSLaunchdJob is that client. One of these is where the poster launch
 * stops, so each one prints what it was asked and what it answered; a missing
 * `ret` line is the call that never came back.
 */
static char *
mondrian_obj_text(id object, char *buffer, size_t size)
{
	const char *utf8 = NULL;

	buffer[0] = '\0';
	if (object != nil && [object respondsToSelector:sel_registerName("description")]) {
		id text = ((id (*)(id, SEL))objc_msgSend)(object,
		    sel_registerName("description"));

		if (text != nil) {
			utf8 = ((const char *(*)(id, SEL))objc_msgSend)(text,
			    sel_registerName("UTF8String"));
		}
	}
	if (utf8 != NULL) {
		snprintf(buffer, size, "%s", utf8);
	}
	return buffer;
}

static void
mondrian_launch_say(const char *what, const char *detail, int ok, long code,
    int done)
{
	char line[420];

	if (!done) {
		snprintf(line, sizeof(line), "MONDRIAN LAUNCH: %s %s\n", what,
		    detail);
	} else {
		snprintf(line, sizeof(line), "MONDRIAN LAUNCH: %s ret %d err %ld\n",
		    what, ok, code);
	}
	say(line);
}

static id mondrian_forward_submit_extension;
static id mondrian_forward_job_submit;
static id mondrian_forward_execute_request;

static id
mondrian_submit_extension(id self, SEL _cmd, id ext, id overlay, id domain,
    id *error)
{
	static id (*forward)(id, SEL, id, id, id, id *);
	char text[300];

	if (forward == NULL) {
		forward = (id (*)(id, SEL, id, id, id, id *))
		    mondrian_forward_submit_extension;
	}
	mondrian_launch_say("submitExtension", mondrian_obj_text(ext, text,
	    sizeof(text)), 0, 0, 0);
	/*
	 * The domain is what tells a system job from a per-user one, and a job
	 * that never answers is worth knowing the domain of: a whole domain can be
	 * the broken part.
	 */
	mondrian_launch_say("submitDomain", mondrian_obj_text(domain, text,
	    sizeof(text)), 0, 0, 0);
	if (forward == NULL) {
		return nil;
	}
	{
		id result = forward(self, _cmd, ext, overlay, domain, error);
		long code = -1;

		if (error != NULL && *error != nil) {
			code = (long)((NSInteger (*)(id, SEL))objc_msgSend)(*error,
			    sel_registerName("code"));
		}
		mondrian_launch_say("submitExtension", NULL, result != nil, code, 1);
		return result;
	}
}

static BOOL
mondrian_job_submit(id self, SEL _cmd, id *error)
{
	static BOOL (*forward)(id, SEL, id *);
	char text[300];

	if (forward == NULL) {
		forward = (BOOL (*)(id, SEL, id *))mondrian_forward_job_submit;
	}
	mondrian_launch_say("jobSubmit", mondrian_obj_text(self, text,
	    sizeof(text)), 0, 0, 0);
	if (forward == NULL) {
		return NO;
	}
	{
		BOOL ok = forward(self, _cmd, error);
		long code = -1;

		if (error != NULL && *error != nil) {
			code = (long)((NSInteger (*)(id, SEL))objc_msgSend)(*error,
			    sel_registerName("code"));
		}
		mondrian_launch_say("jobSubmit", NULL, ok, code, 1);
		return ok;
	}
}

static id
mondrian_execute_request(id self, SEL _cmd, id request, id existing,
    id identity, id *error)
{
	static id (*forward)(id, SEL, id, id, id, id *);
	char text[300];

	if (forward == NULL) {
		forward = (id (*)(id, SEL, id, id, id, id *))
		    mondrian_forward_execute_request;
	}
	mondrian_launch_say("executeLaunchRequest", mondrian_obj_text(request,
	    text, sizeof(text)), 0, 0, 0);
	if (forward == NULL) {
		return nil;
	}
	{
		id result = forward(self, _cmd, request, existing, identity, error);
		long code = -1;

		if (error != NULL && *error != nil) {
			code = (long)((NSInteger (*)(id, SEL))objc_msgSend)(*error,
			    sel_registerName("code"));
		}
		mondrian_launch_say("executeLaunchRequest", NULL, result != nil, code,
		    1);
		return result;
	}
}

/*
 * The kernel's IPC trace has to start after the boot, not with it: the console
 * write that prints a traced message sends a message of its own, and tracing
 * that from the trap wedged two boots before the USB came up. The switch is a
 * sysctl, so the trace begins here, when the system is quiet and the next tap is
 * the only traffic worth looking at.
 */
static void *
mondrian_trace_on_thread(void *unused)
{
	int one = 1;
	int rc;

	(void)unused;
	sleep(75);
	rc = sysctlbyname("kern.mondrian_trace_on", NULL, NULL, &one, sizeof(one));
	{
		char line[160];

		snprintf(line, sizeof(line),
		    "MONDRIAN MSG: userspace trace on rc %d errno %d\n", rc, errno);
		say(line);
	}
	return NULL;
}

/*
 * Two questions about the call that never answers, asked where it is made.
 *
 * 1. Is it hung or just slow? A watcher thread says, three seconds later, that
 *    the call is still pending, so a slow call cannot be mistaken for a lost one.
 * 2. Do mach port rights travel in replies at all? A job start is answered with
 *    a message that carries the job's service port, and the same mechanism is
 *    what bootstrap_look_up uses; if a lookup of a service that is certainly
 *    running fails here, the reply is the broken part and not launchd.
 */
static volatile int mondrian_start_pending;
static volatile int mondrian_start_count;

static void *
mondrian_start_watch(void *unused)
{
	int seen = 0, rounds = 0;

	(void)unused;
	for (rounds = 0; rounds < 400; rounds++) {
		if (mondrian_start_count != seen) {
			seen = mondrian_start_count;
			say("MONDRIAN JOB: start in flight\n");
		} else if (mondrian_start_pending > 0) {
			char line[120];

			snprintf(line, sizeof(line),
			    "MONDRIAN JOB: start %d still pending after %d s\n",
			    mondrian_start_pending, rounds);
			say(line);
		}
		sleep(1);
	}
	return NULL;
}

static void *
mondrian_port_probe(void *unused)
{
	static const char *services[] = {
		"com.apple.cfprefsd.daemon",
		"com.apple.runningboard",
		"com.apple.system.logger",
	};
	extern int bootstrap_look_up(mach_port_t, const char *, mach_port_t *);

	for (size_t i = 0; i < sizeof(services) / sizeof(services[0]); i++) {
		mach_port_t port = MACH_PORT_NULL;
		int kr = bootstrap_look_up(bootstrap_port, services[i], &port);
		char line[200];

		snprintf(line, sizeof(line),
		    "MONDRIAN PORT: lookup %s kr %d port 0x%x\n", services[i], kr,
		    port);
		say(line);
		if (kr == 0 && port != MACH_PORT_NULL) {
			mach_port_deallocate(mach_task_self(), port);
		}
	}
	return NULL;
}

/* the properties that name a job, read only when the class has them */
static void
mondrian_job_properties(id job)
{
	static const char *keys[] = {
		"label", "program", "domain", "type", "handle", "serviceName",
	};

	for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
		SEL sel = sel_registerName(keys[i]);
		char text[200];
		char line[260];

		if (![job respondsToSelector:sel]) {
			continue;
		}
		@try {
			id value = ((id (*)(id, SEL))objc_msgSend)(job, sel);

			mondrian_obj_text(value, text, sizeof(text));
			snprintf(line, sizeof(line), "MONDRIAN JOB: %s = %s\n", keys[i],
			    text);
			say(line);
		} @catch (id exception) {
			(void)exception;
		}
	}
}

static id mondrian_forward_job_start;
static id mondrian_forward_job_submit_start;

static id
mondrian_job_start(id self, SEL _cmd, id *error)
{
	static id (*forward)(id, SEL, id *);
	char text[300];

	if (forward == NULL) {
		forward = (id (*)(id, SEL, id *))mondrian_forward_job_start;
	}
	mondrian_launch_say("jobStart", mondrian_obj_text(self, text,
	    sizeof(text)), 0, 0, 0);
	mondrian_job_properties(self);
	if (forward == NULL) {
		return nil;
	}
	{
		id result;
		long code = -1;

		mondrian_start_pending++;
		mondrian_start_count++;
		result = forward(self, _cmd, error);
		mondrian_start_pending--;
		if (error != NULL && *error != nil) {
			code = (long)((NSInteger (*)(id, SEL))objc_msgSend)(*error,
			    sel_registerName("code"));
		}
		mondrian_launch_say("jobStart", NULL, result != nil, code, 1);
		return result;
	}
}

static id
mondrian_job_submit_start(id self, SEL _cmd, id *error)
{
	static id (*forward)(id, SEL, id *);
	char text[300];

	if (forward == NULL) {
		forward = (id (*)(id, SEL, id *))mondrian_forward_job_submit_start;
	}
	mondrian_launch_say("jobSubmitStart", mondrian_obj_text(self, text,
	    sizeof(text)), 0, 0, 0);
	if (forward == NULL) {
		return nil;
	}
	{
		id result = forward(self, _cmd, error);
		long code = -1;

		if (error != NULL && *error != nil) {
			code = (long)((NSInteger (*)(id, SEL))objc_msgSend)(*error,
			    sel_registerName("code"));
		}
		mondrian_launch_say("jobSubmitStart", NULL, result != nil, code, 1);
		return result;
	}
}

static void
mondrian_wrap(const char *class_name, const char *sel_name, IMP replacement,
    id *slot)
{
	Class cls = objc_getClass(class_name);
	Method method;

	if (cls == Nil ||
	    (method = class_getInstanceMethod(cls, sel_registerName(sel_name))) == NULL) {
		char line[200];

		snprintf(line, sizeof(line), "MONDRIAN LAUNCH: no %s -%s\n",
		    class_name, sel_name);
		say(line);
		return;
	}
	*slot = (id)method_getImplementation(method);
	method_setImplementation(method, replacement);
}

static void
mondrian_install_server_wrappers(void)
{
	mondrian_wrap("RBLaunchdInterface", "submitExtension:overlay:domain:error:",
	    (IMP)mondrian_submit_extension, &mondrian_forward_submit_extension);
	mondrian_wrap("OSLaunchdJob", "submit:", (IMP)mondrian_job_submit,
	    &mondrian_forward_job_submit);
	mondrian_wrap("OSLaunchdJob", "start:", (IMP)mondrian_job_start,
	    &mondrian_forward_job_start);
	mondrian_wrap("OSLaunchdJob", "submitAndStart:",
	    (IMP)mondrian_job_submit_start, &mondrian_forward_job_submit_start);
	mondrian_wrap("RBLaunchManager",
	    "executeLaunchRequest:existingProcess:requestIdentity:withError:",
	    (IMP)mondrian_execute_request, &mondrian_forward_execute_request);
	say("MONDRIAN LAUNCH: server wrappers installed\n");
}

/*
 * SpringBoard's first launch request on every boot is the poster extension
 * (com.apple.WallpaperKit.CollectionsPoster) and it never returns, so it holds
 * FrontBoard's bootstrap lock and every app launch queues behind it. The client
 * side is named now; this names the server side: the classes in runningboardd
 * that submit a job to launchd, and whether a start method runs and returns.
 */
static void
mondrian_rbsrv_probe(void)
{
	Class *classes;
	unsigned total = 0, shown = 0;
	int showed_classes = 0;

	if (mondrian_srv_listed) {
		return;
	}
	mondrian_srv_listed = 1;
	classes = objc_copyClassList(&total);
	if (classes == NULL) {
		say("MONDRIAN RBSRV: no class list\n");
		return;
	}
	for (unsigned i = 0; i < total && showed_classes < 14; i++) {
		const char *name = class_getName(classes[i]);
		unsigned count = 0, printed = 0;
		Method *methods;

		if (strstr(name, "Launch") == NULL && strstr(name, "launchd") == NULL) {
			continue;
		}
		showed_classes++;
		{
			char line[200];

			snprintf(line, sizeof(line), "MONDRIAN RBSRV: class %s\n", name);
			say(line);
		}
		methods = class_copyMethodList(classes[i], &count);
		for (unsigned k = 0; methods != NULL && k < count && printed < 10; k++) {
			const char *sel = sel_getName(method_getName(methods[k]));
			const char *enc = method_getTypeEncoding(methods[k]);

			if (strstr(sel, "start") == NULL && strstr(sel, "submit") == NULL &&
			    strstr(sel, "launch") == NULL && strstr(sel, "exec") == NULL) {
				continue;
			}
			printed++;
			{
				char line[220];

				snprintf(line, sizeof(line),
				    "MONDRIAN RBSRV: %s -%s %s\n", name, sel,
				    enc != NULL ? enc : "-");
				say(line);
			}
		}
		if (methods != NULL) {
			free(methods);
		}
	}
	free(classes);
	(void)shown;
}

/*
 * The one call that carries an app launch from SpringBoard to runningboardd.
 * Its signature came from the probe above (B48@0:8@16o^@24o^@32o^@40), so the
 * request can be read and the call forwarded unchanged: a request that returns
 * NO with an error is a refusal, and one that never returns is the hang the
 * thread dump shows.
 */
static BOOL
mondrian_execute_launch(id self, SEL _cmd, id request, id process, id assertion,
    id *error)
{
	char line[420];
	char what[300];

	(void)self;
	what[0] = '\0';
	if (request != nil && [request respondsToSelector:sel_registerName("description")]) {
		id text = ((id (*)(id, SEL))objc_msgSend)(request,
		    sel_registerName("description"));
		const char *utf8 = NULL;

		if (text != nil) {
			utf8 = ((const char *(*)(id, SEL))objc_msgSend)(text,
			    sel_registerName("UTF8String"));
		}
		if (utf8 != NULL) {
			snprintf(what, sizeof(what), "%s", utf8);
		}
	}
	snprintf(line, sizeof(line), "MONDRIAN RBSX: req %s\n", what);
	say(line);
	if (forward_impl != NULL) {
		BOOL ok = ((BOOL (*)(id, SEL, id, id, id, id *))forward_impl)(
		    self, _cmd, request, process, assertion, error);
		long code = -1;

		if (error != NULL && *error != nil) {
			code = (long)((NSInteger (*)(id, SEL))objc_msgSend)(*error,
			    sel_registerName("code"));
		}
		snprintf(line, sizeof(line), "MONDRIAN RBSX: ret %d err %ld\n",
		    (int)ok, code);
		say(line);
		return ok;
	}
	return NO;
}

static void
mondrian_install_launch_wrapper(void)
{
	Class cls = objc_getClass("RBSConnection");
	Method method;
	IMP impl;

	if (cls == Nil ||
	    (method = class_getInstanceMethod(cls,
	    sel_registerName("executeLaunchRequest:process:assertion:error:"))) == NULL) {
		say("MONDRIAN RBSX: no method to wrap\n");
		return;
	}
	impl = method_getImplementation(method);
	forward_impl = impl;
	method_setImplementation(method, (IMP)mondrian_execute_launch);
	say("MONDRIAN RBSX: wrapped\n");
}

static void *
mondrian_rbs_thread(void *unused)
{
	(void)unused;
	sleep(60);
	mondrian_rbs_probe();
	return NULL;
}

/*
 * The crash reporter records an uncaught NSException as `ns 2 code 0x6` and a
 * backtrace that ends in abort(), which names nothing. The preprocessor sees
 * the exception object before any handler, so the name and the reason land in
 * the ring; it is bounded because a handled exception is normal control flow.
 */
static volatile int mondrian_exc_logs;

static id
mondrian_exc_pre(id exception)
{
	if (mondrian_exc_logs < 24) {
		id reason = nil;
		char line[320];

		mondrian_exc_logs++;
		if (exception != nil &&
		    [exception respondsToSelector:sel_registerName("reason")]) {
			reason = ((id (*)(id, SEL))objc_msgSend)(exception,
			    sel_registerName("reason"));
		}
		snprintf(line, sizeof(line), "MONDRIAN UI: raised %s: %s\n",
		    exception != nil ? object_getClassName(exception) : "?",
		    reason != nil ? [(NSString *)reason UTF8String] : "(no reason)");
		say(line);
	}
	return exception;
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

/*
 * A layer that does not answer -setPosition is not a layer that forgot the
 * method: CALayer has it. The message either goes to memory that was freed and
 * reused, or to a class that only pretends to be CALayer, and the receiver's
 * address is what tells them apart. This hook logs the receiver, its real
 * class, whether the method exists in that class and in its superclasses, and
 * the caller as image + offset, before letting the original crash happen.
 * Boot arg mondriandnr=1.
 */
static void (*mondrian_dnr_orig)(id, SEL, SEL);
static volatile int mondrian_dnr_logs;

static void
mondrian_dnr(id self, SEL _cmd, SEL selector)
{
	Class cls = object_getClass(self);
	const char *cname = cls != Nil ? class_getName(cls) : "?";
	const char *sname = selector != NULL ? sel_getName(selector) : "?";
	BOOL layerish;

	layerish = cname != NULL && (strstr(cname, "Layer") != NULL ||
	    strstr(cname, "CA") == cname);
	if (mondrian_dnr_orig == NULL) {
		return;
	}
	if (layerish && mondrian_dnr_logs < 8) {
		void *frames[18];
		int n, i;
		char buf[224];

		mondrian_dnr_logs++;
		snprintf(buf, sizeof(buf),
		    "MONDRIAN UI: dnr %p class %s sel %s present %d\n", self,
		    cname, sname,
		    class_getInstanceMethod(cls, selector) != NULL);
		say(buf);
		for (cls = class_getSuperclass(object_getClass(self)), i = 0;
		    cls != Nil && i < 4; cls = class_getSuperclass(cls), i++) {
			snprintf(buf, sizeof(buf), "MONDRIAN UI: dnr   super %s\n",
			    class_getName(cls));
			say(buf);
		}
		n = backtrace(frames, 18);
		for (i = 0; i < n; i++) {
			Dl_info info;

			if (dladdr(frames[i], &info)) {
				snprintf(buf, sizeof(buf),
				    "MONDRIAN UI: dnr   #%d %s+0x%lx %s\n", i,
				    info.dli_fname ?: "?",
				    info.dli_fbase != NULL ?
				    (unsigned long)((char *)frames[i] -
				    (char *)info.dli_fbase) : 0,
				    info.dli_sname ?: "");
				say(buf);
			}
		}
	}
	mondrian_dnr_orig(self, _cmd, selector);
}

static void
install_dnr_hook(void)
{
	Class cls = objc_getClass("NSObject");
	Method m;

	if (cls == Nil) {
		return;
	}
	m = class_getInstanceMethod(cls,
	    sel_registerName("doesNotRecognizeSelector:"));
	if (m != NULL) {
		mondrian_dnr_orig = (void (*)(id, SEL, SEL))
		    method_setImplementation(m, (IMP)mondrian_dnr);
		say("MONDRIAN UI: dnr hook installed\n");
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
/*
 * The window server is created by the process that hosts it, so `+server` is
 * nil in a constructor that runs before that. Ask again once the app has had
 * time to build it: a nil server at 60 s says CoreAnimation never created one
 * (and no display link can tick), while a server with zero displays says the
 * display list came back empty, which is the kernel's contract to fix.
 */
static void
say_window_server(void)
{
	id cls = (id)objc_getClass("CAWindowServer");
	id (*send_id)(id, SEL);
	NSUInteger (*send_uint)(id, SEL);
	id server, displays;
	char line[160];

	if (cls == Nil) {
		say("MONDRIAN WS: CAWindowServer class missing\n");
		return;
	}
	send_id = (id (*)(id, SEL))objc_msgSend;
	send_uint = (NSUInteger (*)(id, SEL))objc_msgSend;
	server = send_id(cls, sel_registerName("server"));
	if (server == nil) {
		say("MONDRIAN WS: server nil\n");
		return;
	}
	displays = nil;
	if ([(id)server respondsToSelector:sel_registerName("displays")]) {
		displays = send_id(server, sel_registerName("displays"));
	}
	snprintf(line, sizeof(line), "MONDRIAN WS: server %p displays %lu\n", server,
	    displays != nil ? (unsigned long)send_uint(displays, sel_registerName("count")) : 0UL);
	say(line);
}

static void *
heartbeat(void *unused)
{
	(void)unused;
	for (int i = 0; i < 30; i++) {
		sleep(2);
		say("MONDRIAN UI: heartbeat\n");
		if (i == 9 || i == 19 || i == 29) {
			say_window_server();
		}
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

/*
 * One full stack for the thread that waits on a synchronous XPC reply. The six
 * hottest addresses stop at libxpc -- mach_msg, libdispatch, xpc -- and the
 * caller above them is the frame that names the request, so it needs a longer
 * walk than the hot list keeps. Bounded to eight dumps a boot.
 */
static int mondrian_stack_dumps;

static int
frame_is_xpc(uint64_t addr)
{
	Dl_info dl;

	if (dladdr((void *)addr, &dl) == 0 || dl.dli_sname == NULL) {
		return 0;
	}
	return strcmp(dl.dli_sname,
	    "xpc_connection_send_message_with_reply_sync") == 0;
}

static void
dump_xpc_stack(mach_port_t target)
{
	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	uint64_t frames[24];
	uint64_t fp;
	int n = 0, hit = 0, i;

	if (mondrian_stack_dumps >= 8) {
		return;
	}
	if (thread_get_state(target, ARM_THREAD_STATE64,
	    (thread_state_t)&state, &count) != KERN_SUCCESS) {
		return;
	}
	frames[n++] = state.__pc;
	fp = state.__fp;
	for (i = 0; i < 23 && fp >= 0x100000000ULL; i++) {
		uint64_t frame[2];
		vm_size_t out = 0;

		if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
		    sizeof(frame), (vm_address_t)frame, &out) != KERN_SUCCESS ||
		    out != sizeof(frame) || frame[1] == 0) {
			break;
		}
		frames[n++] = frame[1];
		fp = frame[0];
	}
	for (i = 0; i < n; i++) {
		if (frame_is_xpc(frames[i])) {
			hit = 1;
		}
	}
	if (!hit) {
		return;
	}
	mondrian_stack_dumps++;
	say("MONDRIAN UI: xpc stack\n");
	for (i = 0; i < n; i++) {
		Dl_info dl;
		char line[220];
		char image[140];
		const char *name = "?";

		if (dladdr((void *)frames[i], &dl) != 0) {
			if (dl.dli_sname != NULL &&
			    strcmp(dl.dli_sname, "<redacted>") != 0) {
				name = dl.dli_sname;
			} else if (dl.dli_fname != NULL) {
				const char *base = strrchr(dl.dli_fname, '/');

				snprintf(image, sizeof(image), "%s+0x%llx",
				    base != NULL ? base + 1 : dl.dli_fname,
				    (unsigned long long)(frames[i] -
				    (uint64_t)(uintptr_t)dl.dli_fbase));
				name = image;
			}
		}
		snprintf(line, sizeof(line), "MONDRIAN UI:   #%d %s\n", i, name);
		say(line);
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
		dump_xpc_stack(mondrian_target_thread);
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
			char image[160];
			const char *name = "?";

			for (i = 1; i < mondrian_hot_count; i++) {
				if (mondrian_hot[i].count > mondrian_hot[best].count) {
					best = i;
				}
			}
			if (mondrian_hot[best].count < 2) {
				break;
			}
			/*
			 * The shared cache ships without symbols, so a frame in a
			 * system library has no name: print the image it belongs to
			 * and its offset instead, which still says where the thread
			 * is waiting.
			 */
			if (dladdr((void *)mondrian_hot[best].addr, &dl) != 0) {
				if (dl.dli_sname != NULL &&
				    strcmp(dl.dli_sname, "<redacted>") != 0) {
					name = dl.dli_sname;
				} else if (dl.dli_fname != NULL) {
					const char *base = strrchr(dl.dli_fname, '/');

					snprintf(image, sizeof(image),
					    "%s+0x%llx",
					    base != NULL ? base + 1 : dl.dli_fname,
					    (unsigned long long)
					    (mondrian_hot[best].addr -
					    (uint64_t)(uintptr_t)dl.dli_fbase));
					name = image;
				}
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

static int boot_arg_set(const char *name);
static int boot_arg_int(const char *name, int fallback);

/*
 * The UI hangs off one clock: CoreAnimation's display link. The compositor
 * and every app wait for its callback and only commit when it fires, so when
 * a drag produces one frame instead of sixty, this is the first thing to
 * measure rather than the last. A CADisplayLink of our own, on the same main
 * run loop the app uses, counts the ticks per second and prints the period CA
 * believes the panel has: zero ticks means the link never starts (the vsync
 * plumbing), sixty ticks with no app frames means the app is not committing.
 */
static uint64_t mondrian_dl_total;
static uint64_t mondrian_dl_total2;      /* the late link */
static double   mondrian_dl_period;      /* link.duration */
static double   mondrian_dl_target;      /* targetTimestamp - timestamp */
static double   mondrian_dl_stamp;

@interface MondrianDisplayLinkProbe : NSObject
{
@public
	BOOL late;
}
- (void)arm;
- (void)tick:(CADisplayLink *)link;
@end

@implementation MondrianDisplayLinkProbe
/*
 * Never from +load: creating the link asks the render server for the panel's
 * vsync source, and during dyld load that connection does not exist yet, so
 * the call blocks and with it the main thread (the symptom was SpringBoard
 * stuck before the Apple logo, not a single frame). Four seconds in, from a
 * helper thread, the cost of a hang is a quiet probe instead of a dead UI,
 * and each step says where it stopped.
 */
- (void)arm
{
	CADisplayLink *link;
	char line[112];
	const char *what = late ? "late" : "early";

	snprintf(line, sizeof(line), "MONDRIAN DL[%d]: %s creating\n", getpid(), what);
	say(line);
	link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	if (link == nil) {
		say("MONDRIAN DL: no display link\n");
		return;
	}
	snprintf(line, sizeof(line), "MONDRIAN DL[%d]: %s created\n", getpid(), what);
	say(line);
	if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
		link.preferredFramesPerSecond = 60;
	}
	[link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	snprintf(line, sizeof(line), "MONDRIAN DL[%d]: %s armed\n", getpid(), what);
	say(line);
}

- (void)tick:(CADisplayLink *)link
{
	if (late) {
		mondrian_dl_total2++;
	} else {
		mondrian_dl_total++;
	}
	mondrian_dl_period = link.duration;
	mondrian_dl_stamp = link.timestamp;
	mondrian_dl_target = link.targetTimestamp - link.timestamp;
}
@end

static MondrianDisplayLinkProbe *mondrian_dl_probe;
static MondrianDisplayLinkProbe *mondrian_dl_probe2;

static void *
dl_arm(void *unused)
{
	(void)unused;
	sleep(4);
	[mondrian_dl_probe arm];
	return NULL;
}

/*
 * The same link, 120 s later, once SpringBoard is actually on screen. The
 * early one is armed while the process is still loading; if the late one ticks
 * and the early one does not, the problem is the moment, not the display.
 */
static void *
dl_arm_late(void *unused)
{
	(void)unused;
	sleep(120);
	[mondrian_dl_probe2 arm];
	return NULL;
}

/*
 * When the link does not tick, the question stops being about CA and becomes
 * "what is the main thread doing instead": the run loop is what delivers the
 * tick, so a thread that waits two seconds in a synchronous call starves the
 * link for those two seconds. Symbolicated stack, six dumps a boot.
 */
static int mondrian_dl_dumps;

static void
dl_dump_main(void)
{
	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	uint64_t frames[18];
	uint64_t fp;
	int n = 0;

	if (mondrian_dl_dumps >= 8) {
		return;
	}
	if (mondrian_main_thread == MACH_PORT_NULL ||
	    thread_get_state(mondrian_main_thread, ARM_THREAD_STATE64,
	    (thread_state_t)&state, &count) != KERN_SUCCESS) {
		say("MONDRIAN DL: main thread state unavailable\n");
		return;
	}
	mondrian_dl_dumps++;
	say("MONDRIAN DL: main thread stack\n");
	frames[n++] = state.__pc;
	fp = state.__fp;
	for (int i = 0; i < 17 && fp >= 0x100000000ULL; i++) {
		uint64_t frame[2];
		vm_size_t out = 0;

		if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
		    sizeof(frame), (vm_address_t)frame, &out) != KERN_SUCCESS ||
		    out != sizeof(frame) || frame[1] == 0) {
			break;
		}
		frames[n++] = frame[1];
		fp = frame[0];
	}
	for (int i = 0; i < n; i++) {
		Dl_info dl;
		char line[220];
		char image[140];
		const char *name = "?";

		if (dladdr((void *)frames[i], &dl) != 0) {
			if (dl.dli_sname != NULL &&
			    strcmp(dl.dli_sname, "<redacted>") != 0) {
				name = dl.dli_sname;
			} else if (dl.dli_fname != NULL) {
				const char *base = strrchr(dl.dli_fname, '/');

				snprintf(image, sizeof(image), "%s+0x%llx",
				    base != NULL ? base + 1 : dl.dli_fname,
				    (unsigned long long)(frames[i] -
				    (uint64_t)(uintptr_t)dl.dli_fbase));
				name = image;
			}
		}
		snprintf(line, sizeof(line), "MONDRIAN DL:   #%d %s\n", i, name);
		say(line);
	}
}

static struct timespec
dl_now(void)
{
	struct timespec ts = { 0, 0 };

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts;
}

/*
 * Thirty minutes at one sample every five seconds. Sixty seconds was not
 * enough: on this port SpringBoard's startup alone outlasts the report, so the
 * first version measured the loading phase and stopped before the UI settled.
 */
#define MONDRIAN_DL_SECONDS   5
#define MONDRIAN_DL_SAMPLES   360

static void *
dl_report(void *unused)
{
	uint64_t last = 0;
	uint64_t last2 = 0;
	int dumps = 0;

	(void)unused;
	for (int i = 0; i < MONDRIAN_DL_SAMPLES; i++) {
		char buf[256];
		int n;
		uint64_t rate, rate2;
		struct timespec ts;

		sleep(MONDRIAN_DL_SECONDS);
		rate = mondrian_dl_total - last;
		rate2 = mondrian_dl_total2 - last2;
		ts = dl_now();
		n = snprintf(buf, sizeof(buf),
		    "MONDRIAN DL[%d]: early %llu late %llu ticks/%ds total %llu/%llu now %.3f stamp %.3f\n",
		    getpid(), (unsigned long long)rate, (unsigned long long)rate2,
		    MONDRIAN_DL_SECONDS, (unsigned long long)mondrian_dl_total,
		    (unsigned long long)mondrian_dl_total2,
		    (double)ts.tv_sec + ts.tv_nsec / 1e9, mondrian_dl_stamp);
		if (n > 0) {
			say(buf);
		}
		last = mondrian_dl_total;
		last2 = mondrian_dl_total2;
		/*
		 * A quiet window is the interesting one; eight of them is more
		 * than enough to tell a startup stall from a permanent one.
		 */
		if (rate == 0 && i > 2 && dumps < 8 && mondrian_dl_dumps < 8) {
			dumps++;
			dl_dump_main();
		}
	}
	return NULL;
}

/*
 * What the graphics stack can see from inside a hooked process, asked once:
 * whether the kernel's framebuffer matches by name (IOMobileFramebuffer's
 * framework counts /arm-io children that do), whether CoreAnimation has a
 * display at all, and whether os_log returns -- it is the call that hung the
 * injector's initializer on 2026-11-15, so it is asked from its own thread and
 * the line after it only appears if it came back.
 */
static void *
mondrian_env_probe(void *unused)
{
	char line[160];
	io_service_t svc;
	io_name_t name;
	io_connect_t conn = 0;
	kern_return_t kr;

	(void)unused;
	say("MONDRIAN PROBE: thread start\n");
	sleep(5);
	say("MONDRIAN PROBE: framebuffer match, before\n");
	svc = IOServiceGetMatchingService(kIOMainPortDefault,
	    IOServiceMatching("IOMobileFramebuffer"));
	snprintf(line, sizeof(line), "MONDRIAN PROBE: framebuffer match %u\n",
	    (unsigned)svc);
	say(line);
	if (svc != 0) {
		if (IORegistryEntryGetName(svc, name) == KERN_SUCCESS) {
			snprintf(line, sizeof(line), "MONDRIAN PROBE: framebuffer name %s\n",
			    name);
			say(line);
		}
		/*
		 * Type 0 is what IOMobileFramebufferOpen asks for: if this works
		 * from here, the plumbing the window server needs is there and
		 * its absence is somewhere else.
		 */
		kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
		snprintf(line, sizeof(line), "MONDRIAN PROBE: IOServiceOpen -> 0x%x conn %u\n",
		    kr, (unsigned)conn);
		say(line);
		if (kr == KERN_SUCCESS) {
			IOServiceClose(conn);
		}
		IOObjectRelease(svc);
	}
	say("MONDRIAN PROBE: window server, before\n");
	{
		Class cls = objc_getClass("CAWindowServer");
		id server = Nil;

		if (cls != Nil) {
			server = ((id (*)(id, SEL))objc_msgSend)((id)cls,
			    sel_registerName("serverIfRunning"));
		}
		snprintf(line, sizeof(line), "MONDRIAN PROBE: CAWindowServer %s\n",
		    cls == Nil ? "class missing" : (server != nil ? "running" : "nil"));
		say(line);
	}
	{
		Class cls = objc_getClass("CADisplay");
		id display = Nil;

		if (cls != Nil) {
			display = ((id (*)(id, SEL))objc_msgSend)((id)cls,
			    sel_registerName("mainDisplay"));
		}
		snprintf(line, sizeof(line), "MONDRIAN PROBE: CADisplay %s\n",
		    cls == Nil ? "class missing" : (display != nil ? "present" : "nil"));
		say(line);
	}
	say("MONDRIAN PROBE: os_log enter\n");
	os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "mondrian env probe");
	say("MONDRIAN PROBE: os_log return\n");
	return NULL;
}

/*
 * The same os_log ask, later: if the first one is stuck because logd was not
 * up yet, these two come back and say so.
 */
static void *
mondrian_os_log_again(void *arg)
{
	char line[64];
	int seconds = (int)(intptr_t)arg;

	sleep((unsigned)seconds);
	snprintf(line, sizeof(line), "MONDRIAN PROBE: os_log %d enter\n", seconds);
	say(line);
	os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "mondrian env probe late");
	snprintf(line, sizeof(line), "MONDRIAN PROBE: os_log %d return\n", seconds);
	say(line);
	return NULL;
}

/*
 * Which bootstrap services exist decides whether a daemon that blocks in
 * mach_msg is waiting for a service nobody registered or for a service that is
 * there and does not answer. os_log is the case in hand: it is the shim path
 * for an unentitled process, so it looks a name up and sends to it.
 */
static pthread_mutex_t mondrian_pp_lock = PTHREAD_MUTEX_INITIALIZER;

static void *
mondrian_bootstrap_probe(void *unused)
{
	static const char *names[] = {
		"com.apple.system.logger",
		"com.apple.logd",
		"com.apple.logd.buffer",
		"com.apple.system.logger.logd",
		"com.apple.diagnosticd",
	};
	mach_port_t bp = MACH_PORT_NULL;
	char line[160];

	(void)unused;
	sleep(25);
	if (task_get_bootstrap_port(mach_task_self(), &bp) != KERN_SUCCESS ||
	    bp == MACH_PORT_NULL) {
		say("MONDRIAN SVC: no bootstrap port\n");
		return NULL;
	}
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		mach_port_t svc = MACH_PORT_NULL;
		kern_return_t (*look_up)(mach_port_t, const char *, mach_port_t *) =
		    (kern_return_t (*)(mach_port_t, const char *, mach_port_t *))
		    dlsym(RTLD_DEFAULT, "bootstrap_look_up");
		kern_return_t kr;

		if (look_up == NULL) {
			say("MONDRIAN SVC: bootstrap_look_up missing\n");
			return NULL;
		}
		kr = look_up(bp, names[i], &svc);
		snprintf(line, sizeof(line), "MONDRIAN SVC: %s -> 0x%x port %u\n",
		    names[i], kr, (unsigned)svc);
		say(line);
		if (kr == 0) {
			mach_port_deallocate(mach_task_self(), svc);
		}
	}
	return NULL;
}

/*
 * Name an address that came from somewhere else: the kernel sampler prints raw
 * user pcs for a process it cannot symbolicate, and every process shares the
 * same images at the same addresses, so this process's dladdr answers for it.
 * `tools/usb-ring.py wfile /private/var/vm/mondrian-addrs.txt local-file` with
 * one 0x... per line, and the lines below appear in the ring.
 */
static void *
mondrian_addr_watch(void *unused)
{
	const char *path = "/private/var/vm/mondrian-addrs.txt";

	(void)unused;
	(void)mondrian_pp_lock;
	for (;;) {
		FILE *f = fopen(path, "r");
		char line[512];

		if (f == NULL) {
			sleep(10);
			continue;
		}
		while (fgets(line, sizeof(line), f) != NULL) {
			unsigned long long addr = 0;
			Dl_info info;
			char out[512];
			char *p = line;

			while (*p == ' ' || *p == '\t') {
				p++;
			}
			if (strncmp(p, "0x", 2) != 0 && strncmp(p, "0X", 2) != 0) {
				continue;
			}
			addr = strtoull(p, NULL, 16);
			memset(&info, 0, sizeof(info));
			if (addr != 0 && dladdr((void *)(uintptr_t)addr, &info) != 0) {
				snprintf(out, sizeof(out),
				    "MONDRIAN ADDR[%d]: 0x%llx -> %s+0x%llx %s\n",
				    getpid(), addr,
				    info.dli_fname != NULL ? info.dli_fname : "?",
				    addr - (unsigned long long)(uintptr_t)info.dli_fbase,
				    info.dli_sname != NULL ? info.dli_sname : "");
			} else {
				snprintf(out, sizeof(out),
				    "MONDRIAN ADDR[%d]: 0x%llx -> ?\n",
				    getpid(), addr);
			}
			say(out);
		}
		fclose(f);
		(void)unlink(path);
	}
	return NULL;
}

static void
start_display_link_probe(void)
{
	pthread_t thread;

	mondrian_dl_probe = [[MondrianDisplayLinkProbe alloc] init];
	mondrian_dl_probe2 = [[MondrianDisplayLinkProbe alloc] init];
	mondrian_dl_probe2->late = YES;
	(void)pthread_create(&thread, NULL, dl_arm, NULL);
	(void)pthread_create(&thread, NULL, dl_arm_late, NULL);
	(void)pthread_create(&thread, NULL, dl_report, NULL);
	(void)pthread_create(&thread, NULL, mondrian_env_probe, NULL);
	(void)pthread_create(&thread, NULL, mondrian_os_log_again, (void *)(intptr_t)45);
	(void)pthread_create(&thread, NULL, mondrian_os_log_again, (void *)(intptr_t)100);
	(void)pthread_create(&thread, NULL, mondrian_bootstrap_probe, NULL);
	(void)pthread_create(&thread, NULL, mondrian_addr_watch, NULL);
}

/*
 * Where a frame stops. A client that never opens a transaction and a render
 * server that never draws look the same from the glass, and both read
 * `present 0/s`; these hooks split them. CoreAnimation opens a transaction
 * around every batch of layer changes an app makes and asks each layer to
 * display while it flushes one, so the counts per second are the client's
 * commit rate, not the server's draw rate.
 */
static volatile unsigned mondrian_ca_begins;
static volatile unsigned mondrian_ca_commits;
static volatile unsigned mondrian_ca_displays;
static volatile unsigned mondrian_ca_slow;
static volatile unsigned mondrian_loop_ticks;
static void (*mondrian_ca_begin_orig)(id, SEL);
static void (*mondrian_ca_commit_orig)(id, SEL);
static void (*mondrian_ca_display_orig)(id, SEL);

/*
 * A timer on the main run loop, in the common modes the UI runs in. It says
 * whether that run loop is being serviced at all: CoreAnimation's animations
 * advance from a display link on the same loop, so a link that stops while
 * this keeps firing means the fault is in the frame path, and both going quiet
 * means the main thread itself is not running.
 */
static void
mondrian_loop_timer(CFRunLoopTimerRef timer, void *info)
{
	(void)timer;
	(void)info;
	mondrian_loop_ticks++;
}

static void
mondrian_start_loop_probe(void)
{
	CFRunLoopTimerRef timer;

	timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.05, 0.05,
	    0, 0, mondrian_loop_timer, NULL);
	if (timer == NULL) {
		say("MONDRIAN UI: loop timer failed\n");
		return;
	}
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
	say("MONDRIAN UI: loop timer armed\n");
}

static void
mondrian_ca_begin(id self, SEL cmd)
{
	mondrian_ca_begins++;
	if (mondrian_ca_begin_orig != NULL) {
		mondrian_ca_begin_orig(self, cmd);
	}
}

static void
mondrian_ca_commit(id self, SEL cmd)
{
	struct timespec began, ended;
	long total;

	mondrian_ca_commits++;
	clock_gettime(CLOCK_MONOTONIC, &began);
	if (mondrian_ca_commit_orig != NULL) {
		mondrian_ca_commit_orig(self, cmd);
	}
	clock_gettime(CLOCK_MONOTONIC, &ended);
	total = (long)(ended.tv_sec - began.tv_sec) * 1000 +
	    (long)(ended.tv_nsec - began.tv_nsec) / 1000000;
	if (total > 100) {
		mondrian_ca_slow++;
	}
}

static void
mondrian_ca_display(id self, SEL cmd)
{
	mondrian_ca_displays++;
	if (mondrian_ca_display_orig != NULL) {
		mondrian_ca_display_orig(self, cmd);
	}
}

static void *
mondrian_ca_report(void *unused)
{
	unsigned begin = 0, commit = 0, display = 0, slow = 0, loop = 0;

	(void)unused;
	for (;;) {
		char line[160];

		sleep(1);
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: ca begin %u commit %u slow %u display %u "
		    "loop %u in 1 s\n",
		    mondrian_ca_begins - begin, mondrian_ca_commits - commit,
		    mondrian_ca_slow - slow, mondrian_ca_displays - display,
		    mondrian_loop_ticks - loop);
		begin = mondrian_ca_begins;
		commit = mondrian_ca_commits;
		slow = mondrian_ca_slow;
		display = mondrian_ca_displays;
		loop = mondrian_loop_ticks;
		say(line);
	}
	return NULL;
}

static void
mondrian_ca_count(void)
{
	Class tx = objc_getClass("CATransaction");
	Class layer = objc_getClass("CALayer");
	Method m;
	pthread_t thread;
	const char *me = getprogname();

	/*
	 * The line is one per second per process and the hook runs in every
	 * injected daemon, so only the two ends of the frame path report.
	 */
	if (me == NULL ||
	    (strcmp(me, "SpringBoard") != 0 && strcmp(me, "backboardd") != 0)) {
		return;
	}

	m = tx != Nil ? class_getClassMethod(tx, sel_registerName("begin")) : NULL;
	if (m != NULL) {
		mondrian_ca_begin_orig = (void (*)(id, SEL))
		    method_setImplementation(m, (IMP)mondrian_ca_begin);
	}
	m = tx != Nil ? class_getClassMethod(tx, sel_registerName("commit")) : NULL;
	if (m != NULL) {
		mondrian_ca_commit_orig = (void (*)(id, SEL))
		    method_setImplementation(m, (IMP)mondrian_ca_commit);
	}
	m = layer != Nil
	    ? class_getInstanceMethod(layer, sel_registerName("displayIfNeeded")) : NULL;
	if (m != NULL) {
		mondrian_ca_display_orig = (void (*)(id, SEL))
		    method_setImplementation(m, (IMP)mondrian_ca_display);
	}
	if (mondrian_ca_begin_orig == NULL && mondrian_ca_commit_orig == NULL &&
	    mondrian_ca_display_orig == NULL) {
		say("MONDRIAN UI: ca counters: nothing hooked\n");
		return;
	}
	say("MONDRIAN UI: ca counters installed\n");
	mondrian_start_loop_probe();
	if (pthread_create(&thread, NULL, mondrian_ca_report, NULL) != 0) {
		say("MONDRIAN UI: ca report thread failed\n");
	}
}

static void
start_heartbeat(void)
{
	pthread_t thread;

	mondrian_main_thread = mach_thread_self();
	(void)pthread_create(&thread, NULL, heartbeat, NULL);
	start_display_link_probe();
	/*
	 * The stack sampler follows the busiest thread in the process with a
	 * burst of 200 samples at 1 ms, every 5 s. That suspends the thread it
	 * is measuring 200 times per burst, which is exactly what the frame
	 * numbers are trying to see: keep it off unless asked for.
	 * mondrianmain=1 (the main-thread walk below) is separate.
	 */
	if (boot_arg_set("mondrian_ui_sample=1")) {
		(void)pthread_create(&thread, NULL, sampler, NULL);
	}
	/*
	 * Counting commits and display passes splits the two halves of a
	 * stopped screen; it is one method call per transaction while on, so it
	 * stays behind its own boot argument.
	 */
	if (boot_arg_set("mondrianca=1")) {
		mondrian_ca_count();
	}
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
/* The probe layer, so a 60 Hz link can drive it (boot-arg mondriananim=2). */
static id mondrian_probe_layer;
static volatile unsigned mondrian_probe_moves;
static int mondrian_dock_mask;
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
 * bundle path comes from the model's application object. The canvas is a 3x
 * geometry (1125x2436 = 375x812 pt), so the @3x file is the one whose pixels
 * land on canvas pixels; the @2x pair is the fallback and is visibly softer.
 */
static const char *const mondrian_icon_files[] = {
	"AppIcon60x60@3x.png",
	"AppIcon60x60@2x.png",
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
			/*
			 * An app-icon PNG is a full square; SpringBoard masks it
			 * with a continuous-corner shape. The radius is the same
			 * silhouette to the eye, and the compositor pays nothing
			 * for it on this port.
			 */
			{
				id layer = mondrian_send(image_view, "layer");

				if (layer != NULL) {
					((void (*)(id, SEL, double))objc_msgSend)(
					    layer, sel_registerName("setCornerRadius:"),
					    (double)bounds.size.width * 0.2237);
					((void (*)(id, SEL, BOOL))objc_msgSend)(
					    image_view, sel_registerName("setClipsToBounds:"),
					    YES);
				}
			}
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
		/*
		 * The layer belongs to a window that the next screen change
		 * destroys, and the display link keeps moving it after that; a
		 * pointer into a freed tree is how the probe killed SpringBoard
		 * on the way out of the lock screen. Hold a reference and drop
		 * it only when a new window's tree has been adopted.
		 */
		if (dot != mondrian_probe_layer) {
			[mondrian_probe_layer release];
			[dot retain];
		}
		mondrian_probe_layer = dot;
		/*
		 * `mondriananim=1` runs it as a CoreAnimation animation (the render
		 * server owns the clock); `=2` moves it from the 60 Hz display link
		 * in this process, which makes every tick a commit.
		 */
		if (mondrian_anim_enabled == 1) {
			move = [objc_getClass("CABasicAnimation")
			    animationWithKeyPath:@"position.x"];
			[move setFromValue:[NSNumber numberWithDouble:60.0]];
			[move setToValue:[NSNumber numberWithDouble:w - 60.0]];
			[move setDuration:2.0];
			[move setAutoreverses:YES];
			[move setRepeatCount:1e9];
			[dot addAnimation:move forKey:@"mondrian-move"];
		}
		/*
		 * The probe is a CoreAnimation animation, so the render server runs it
		 * on its own clock and the client does not have to commit a frame for it
		 * to move. Reading the presentation layer back every tick therefore
		 * separates the two halves of a stalled screen: a presentation position
		 * that changes 60 times a second with a panel that does not means the
		 * compositor or the present is late; one that changes once a second
		 * means the animation clock itself is stopped, and no amount of drawing
		 * would help.
		 */
		{
			static unsigned present_ticks, present_moved;
			static double present_last;
			id present = ((id (*)(id, SEL))objc_msgSend)(dot,
			    sel_registerName("presentationLayer"));
			double x = present != NULL ?
			    ((CGPoint (*)(id, SEL))objc_msgSend)(present,
			    sel_registerName("position")).x : -1.0;

			if (x != present_last) {
				present_last = x;
				present_moved++;
			}
			if (++present_ticks == 60) {
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: probe present %u/60 ticks moved x %.0f\n",
				    present_moved, x);
				say(line);
				present_ticks = 0;
				present_moved = 0;
			}
		}
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
 * What the UI thinks the screen is. The Control Center lays itself out from
 * the screen's point size, so a wrong bounds/scale pair shows up as modules
 * of the wrong height long before it shows up as a drag that moves the whole
 * panel (the sliders land in the home-gesture strip). One line per window
 * plus the Control Center's container frames answers where the layout got its
 * numbers: `mondriangeom=1`.
 */
static int
mondrian_geom_identity(CATransform3D m)
{
	return m.m11 == 1.0 && m.m12 == 0.0 && m.m13 == 0.0 && m.m14 == 0.0 &&
	    m.m21 == 0.0 && m.m22 == 1.0 && m.m23 == 0.0 && m.m24 == 0.0 &&
	    m.m31 == 0.0 && m.m32 == 0.0 && m.m33 == 1.0 && m.m34 == 0.0 &&
	    m.m41 == 0.0 && m.m42 == 0.0 && m.m43 == 0.0 && m.m44 == 1.0;
}

/*
 * `mondriancct=1`: the Control Center's grid arrives on the glass about twice
 * as tall as its own view frames, which is a layer transform the frames do
 * not show. Walk the Control Center window, say every non-identity transform
 * and animation, and put the model transforms back to identity: the grid is
 * static, so nothing there needs one.
 */
static unsigned
mondrian_cc_normalize(id view, unsigned depth, unsigned *changed)
{
	id kids, layer;
	unsigned n, i;
	char line[192];

	if (view == nil || depth > 10) {
		return 0;
	}
	layer = mondrian_send(view, "layer");
	if (layer != nil) {
		CATransform3D t = ((CATransform3D (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("transform"));
		CATransform3D s = ((CATransform3D (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("sublayerTransform"));
		id keys = mondrian_send(layer, "animationKeys");
		unsigned k = keys != nil ? (unsigned)[(NSArray *)keys count] : 0;
		const char *name = object_getClassName(layer);

		if (!mondrian_geom_identity(t) || !mondrian_geom_identity(s) || k != 0) {
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: cc norm %s T[%.3f %.3f %.3f %.3f]"
			    " S[%.3f %.3f %.3f %.3f] anim %u\n",
			    name != NULL ? name : "?", t.m11, t.m22, t.m33, t.m44,
			    s.m11, s.m22, s.m33, s.m44, k);
			say(line);
			(*changed)++;
			if (!mondrian_geom_identity(t)) {
				((void (*)(id, SEL, CATransform3D))objc_msgSend)(layer,
				    sel_registerName("setTransform:"), CATransform3DIdentity);
			}
			if (!mondrian_geom_identity(s)) {
				((void (*)(id, SEL, CATransform3D))objc_msgSend)(layer,
				    sel_registerName("setSublayerTransform:"),
				    CATransform3DIdentity);
			}
			if (k != 0) {
				((void (*)(id, SEL))objc_msgSend)(layer,
				    sel_registerName("removeAllAnimations"));
			}
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_cc_normalize([(NSArray *)kids objectAtIndex:i], depth + 1, changed);
	}
	return *changed;
}

/*
 * The window the touches land in, kept from the sendEvent probe: the sheet the
 * finger reaches is not always the window `[UIApplication windows]` lists (a
 * touch on the connectivity block reports `NSKVONotifying_CCUIRoundButton`
 * inside `SBControlCenterWindow`, while walking that window shows empty module
 * containers). Whatever window a Control Center touch arrives in is the one
 * worth describing, so it is remembered here and the geometry thread walks it.
 */
static id mondrian_cc_touch_window;

typedef struct {
	CGFloat top;
	CGFloat left;
	CGFloat bottom;
	CGFloat right;
} mondrian_insets;

/*
 * The slider modules are the ones whose touches stop at
 * `CCUIContentModuleContentContainerView`: the container is in the tree and
 * takes the hit, its content is what the finger never reaches. Walk that
 * subtree alone, deep, and say of every UIControl whether it is enabled and
 * whether anything is wired to it.
 */
static void
mondrian_deep_walk(id view, unsigned depth, CGPoint space, unsigned *lines)
{
	CGRect frame, bounds;
	CGPoint here;
	id kids;
	unsigned n, i;
	char line[256];
	const char *name;
	char extra[64] = "";
	BOOL control;

	if (view == nil || depth > 14 || *lines >= 200) {
		return;
	}
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
	bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("bounds"));
	name = object_getClassName(view);
	here.x = space.x + frame.origin.x;
	here.y = space.y + frame.origin.y;
	control = [[view class] isSubclassOfClass:objc_getClass("UIControl")];
	if (control) {
		id targets = mondrian_send(view, "allTargets");
		unsigned long events = ((unsigned long (*)(id, SEL))objc_msgSend)(
		    view, sel_registerName("allControlEvents"));

		snprintf(extra, sizeof(extra), " ctl en %d ev %lu tg %u",
		    (int)((BOOL (*)(id, SEL))objc_msgSend)(view,
			sel_registerName("isEnabled")), events,
		    targets != nil ? (unsigned)[(NSSet *)targets count] : 0);
	}
	(*lines)++;
	{
		unsigned indent = depth < 12 ? depth : 12;

		memset(line, ' ', indent);
		snprintf(line + indent, sizeof(line) - indent,
		    "%s %.1fx%.1f abs %.1f,%.1f b %.1f,%.1f ui %d hid %d a %.2f%s\n",
		    name != NULL ? name : "?", frame.size.width, frame.size.height,
		    here.x, here.y, bounds.origin.x, bounds.origin.y,
		    (int)((BOOL (*)(id, SEL))objc_msgSend)(view,
			sel_registerName("isUserInteractionEnabled")),
		    (int)((BOOL (*)(id, SEL))objc_msgSend)(view,
			sel_registerName("isHidden")),
		    (double)((CGFloat (*)(id, SEL))objc_msgSend)(view,
			sel_registerName("alpha")), extra);
	}
	say(line);
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	space.x = here.x - bounds.origin.x;
	space.y = here.y - bounds.origin.y;
	for (i = 0; i < n && *lines < 140; i++) {
		mondrian_deep_walk([(NSArray *)kids objectAtIndex:i], depth + 1,
		    space, lines);
	}
}

/*
 * Find the module content containers the sheet holds and walk each one.
 */
static unsigned
mondrian_deep_find(id view, unsigned depth, CGPoint space, unsigned found)
{
	CGRect frame;
	id kids;
	unsigned n, i;
	const char *name = object_getClassName(view);

	if (view == nil || depth > 14 || found >= 3) {
		return found;
	}
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
	if (name != NULL && strstr(name, "ContentModuleContent") != NULL) {
		unsigned lines = 0;
		char line[224];

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: deep %s %.0fx%.0f abs %.0f,%.0f\n", name,
		    frame.size.width, frame.size.height,
		    space.x + frame.origin.x, space.y + frame.origin.y);
		say(line);
		mondrian_deep_walk(view, 0, space, &lines);
		return found + 1;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	space.x += frame.origin.x;
	space.y += frame.origin.y;
	for (i = 0; i < n; i++) {
		found = mondrian_deep_find([(NSArray *)kids objectAtIndex:i],
		    depth + 1, space, found);
	}
	return found;
}

static void
mondrian_geom_walk(id view, unsigned depth, unsigned *lines, CGPoint space)
{
	CGRect frame, bounds;
	CGPoint here;
	id kids, layer;
	unsigned n, i;
	char line[224];
	const char *name;

	if (view == nil || depth > 14 || *lines >= 700) {
		return;
	}
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
	bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("bounds"));
	here.x = space.x + frame.origin.x;
	here.y = space.y + frame.origin.y;
	name = object_getClassName(view);
	(*lines)++;
	n = depth < 10 ? depth : 10;
	memset(line, ' ', n);
	snprintf(line + n, sizeof(line) - n,
	    "%s %.1fx%.1f abs %.1f,%.1f b %.1f,%.1f ui %d hid %d a %.2f\n",
	    name != NULL ? name : "?", frame.size.width, frame.size.height,
	    here.x, here.y, bounds.origin.x, bounds.origin.y,
	    (int)((BOOL (*)(id, SEL))objc_msgSend)(view,
		sel_registerName("isUserInteractionEnabled")),
	    (int)((BOOL (*)(id, SEL))objc_msgSend)(view,
		sel_registerName("isHidden")),
	    (double)((CGFloat (*)(id, SEL))objc_msgSend)(view,
		sel_registerName("alpha")));
	say(line);
	if (name != NULL && strstr(name, "ScrollView") != NULL &&
	    [view respondsToSelector:sel_registerName("contentSize")]) {
		CGSize content = ((CGSize (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("contentSize"));
		CGPoint offset = ((CGPoint (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("contentOffset"));
		mondrian_insets inset = ((mondrian_insets (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("contentInset"));

		memset(line, ' ', n + 1);
		snprintf(line + n + 1, sizeof(line) - n - 1,
		    "content %.1fx%.1f offset %.1f,%.1f inset %.1f,%.1f,%.1f,%.1f\n",
		    content.width, content.height, offset.x, offset.y,
		    inset.top, inset.left, inset.bottom, inset.right);
		say(line);
	}
	layer = mondrian_send(view, "layer");
	if (layer != nil && depth <= 7) {
		CATransform3D t = ((CATransform3D (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("transform"));
		CATransform3D s = ((CATransform3D (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("sublayerTransform"));
		id keys = mondrian_send(layer, "animationKeys");
		unsigned k = keys != nil ? (unsigned)[(NSArray *)keys count] : 0;
		const char *lname = object_getClassName(layer);

		if (!mondrian_geom_identity(t) || !mondrian_geom_identity(s) || k != 0) {
			memset(line, ' ', n + 1);
			snprintf(line + n + 1, sizeof(line) - n - 1,
			    "L %s T[%.3f %.3f %.3f %.3f] S[%.3f %.3f %.3f %.3f] anim %u\n",
			    lname != NULL ? lname : "?", t.m11, t.m22, t.m33, t.m44,
			    s.m11, s.m22, s.m33, s.m44, k);
			say(line);
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	if (name != NULL && strstr(name, "ModuleContainer") != NULL &&
	    frame.size.width >= 160.0) {
		id sublayers = layer != nil ? mondrian_send(layer, "sublayers") : nil;
		unsigned lc = sublayers != nil ?
		    (unsigned)[(NSArray *)sublayers count] : 0;
		char line2[224];

		snprintf(line2, sizeof(line2),
		    "MONDRIAN UI: geom module %s %.0fx%.0f kids %u"
		    " layer %s sublayers %u\n", name, frame.size.width,
		    frame.size.height, n,
		    layer != nil ? object_getClassName(layer) : "nil", lc);
		say(line2);
		for (i = 0; i < lc && i < 6; i++) {
			id sl = [(NSArray *)sublayers objectAtIndex:i];

			snprintf(line2, sizeof(line2),
			    "MONDRIAN UI: geom module layer %u %s\n", i,
			    object_getClassName(sl));
			say(line2);
		}
	}
	space.x = here.x - bounds.origin.x;
	space.y = here.y - bounds.origin.y;
	for (i = 0; i < n && *lines < 700; i++) {
		mondrian_geom_walk([(NSArray *)kids objectAtIndex:i], depth + 1,
		    lines, space);
	}
}

/*
 * `mondriancctest=1`: press the first module the sheet holds, without a touch
 * on the glass. A module that reacts to -sendActionsForControlEvents: says the
 * input path is what swallows the touches; a module that does nothing says its
 * action is what is missing, and the touch path is innocent.
 */
static id
mondrian_cc_module(id view, unsigned depth, CGPoint space,
    unsigned *count)
{
	CGRect frame;
	id kids;
	unsigned n, i;
	const char *name = object_getClassName(view);

	if (view == nil || depth > 9) {
		return nil;
	}
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
	if (name != NULL && (strstr(name, "TemplateView") != NULL ||
	    strstr(name, "ButtonModule") != NULL) &&
	    [view respondsToSelector:sel_registerName("sendActionsForControlEvents:")]) {
		char line[224];

		(*count)++;
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: cc module %u %s %.1fx%.1f abs %.1f,%.1f\n",
		    *count, name, frame.size.width, frame.size.height,
		    space.x + frame.origin.x, space.y + frame.origin.y);
		say(line);
		return view;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	space.x += frame.origin.x;
	space.y += frame.origin.y;
	for (i = 0; i < n; i++) {
		id found = mondrian_cc_module([(NSArray *)kids objectAtIndex:i],
		    depth + 1, space, count);

		if (found != nil) {
			return found;
		}
	}
	return nil;
}

static void
mondrian_cc_activate(id window)
{
	static int dumps;
	static int fired;
	unsigned count = 0;
	id module;
	char line[224];

	if (fired != 0 || ++dumps < 3) {
		return;
	}
	module = mondrian_cc_module(window, 0, CGPointZero, &count);
	if (module == nil) {
		/* Not laid out yet: keep looking on the next dump. */
		dumps = 2;
		return;
	}
	fired = 1;
	snprintf(line, sizeof(line), "MONDRIAN UI: cc activate %s\n",
	    object_getClassName(module));
	say(line);
	((void (*)(id, SEL, unsigned long))objc_msgSend)(module,
	    sel_registerName("sendActionsForControlEvents:"), 1UL << 6);
}

static void
mondrian_log_screen_geometry(void)
{
	Class screen_cls = objc_getClass("UIScreen");
	Class app_cls = objc_getClass("UIApplication");
	id screen = nil;
	id app = nil;
	char line[256];
	unsigned i;

	if (screen_cls != Nil) {
		Method method = class_getClassMethod(screen_cls,
		    sel_registerName("mainScreen"));

		if (method != NULL) {
			screen = ((id (*)(id, SEL))method_getImplementation(method))(
			    (id)screen_cls, sel_registerName("mainScreen"));
		}
	}
	if (screen != nil) {
		CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("bounds"));
		CGRect native = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("nativeBounds"));
		CGFloat scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("scale"));
		CGFloat native_scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("nativeScale"));
		id modes = mondrian_send(screen, "availableModes");
		unsigned count = modes != nil ? (unsigned)[(NSArray *)modes count] : 0;

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: geom screen %.1fx%.1f at %.1f,%.1f scale %.3f"
		    " native %.1fx%.1f scale %.3f modes %u\n",
		    bounds.size.width, bounds.size.height, bounds.origin.x,
		    bounds.origin.y, scale, native.size.width, native.size.height,
		    native_scale, count);
		say(line);
		for (i = 0; i < count && i < 6; i++) {
			id mode = [(NSArray *)modes objectAtIndex:i];
			CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(mode,
			    sel_registerName("size"));
			CGSize pixels = CGSizeZero;

			if ([mode respondsToSelector:sel_registerName("pixelSize")]) {
				pixels = ((CGSize (*)(id, SEL))objc_msgSend)(mode,
				    sel_registerName("pixelSize"));
			}
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: geom mode %u %.1fx%.1f pixel %.1fx%.1f\n",
			    i, size.width, size.height, pixels.width, pixels.height);
			say(line);
		}
	}
	if (app_cls != Nil) {
		Method method = class_getClassMethod(app_cls,
		    sel_registerName("sharedApplication"));

		if (method != NULL) {
			app = ((id (*)(id, SEL))method_getImplementation(method))(
			    (id)app_cls, sel_registerName("sharedApplication"));
		}
	}
	if (app == nil) {
		return;
	}
	{
		id windows = mondrian_send(app, "windows");
		unsigned count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
		BOOL walked_touch = NO;

		for (i = 0; i < count; i++) {
			id window = [(NSArray *)windows objectAtIndex:i];
			CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("frame"));
			CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("bounds"));
			BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("isHidden"));
			CGFloat level = ((CGFloat (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("windowLevel"));
			const char *name = object_getClassName(window);

			snprintf(line, sizeof(line),
			    "MONDRIAN UI: geom window %u %s frame %.1fx%.1f at %.1f,%.1f"
			    " bounds %.1fx%.1f level %.1f hidden %d\n",
			    i, name != NULL ? name : "?", frame.size.width,
			    frame.size.height, frame.origin.x, frame.origin.y,
			    bounds.size.width, bounds.size.height, level, (int)hidden);
			say(line);
		}
		for (i = 0; i < count; i++) {
			id window = [(NSArray *)windows objectAtIndex:i];
			const char *name = object_getClassName(window);
			unsigned lines = 0;
			BOOL hidden;

			if (name == NULL || (strstr(name, "ControlCenter") == NULL &&
			    strstr(name, "CCUI") == NULL)) {
				continue;
			}
			/*
			 * SpringBoard keeps a hidden Control Center window around
			 * before the sheet is ever shown; walking that one answers
			 * nothing (its modules are not built and its hit tests are
			 * nil by definition).
			 */
			hidden = ((BOOL (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("isHidden"));
			if (hidden) {
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: geom cc window %s hidden\n",
				    name);
				say(line);
				continue;
			}
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: geom cc window %s\n", name);
			say(line);
			mondrian_geom_walk(window, 0, &lines, CGPointZero);
			mondrian_deep_find(window, 0, CGPointZero, 0);
			if (window == mondrian_cc_touch_window) {
				walked_touch = YES;
			}
			if (boot_arg_set("mondriancctest=1")) {
				mondrian_cc_activate(window);
			}
		}
		/*
		 * The window a Control Center touch arrives in is not always one of
		 * these; when it is a different object, describe that one too.
		 */
		if (mondrian_cc_touch_window != nil && !walked_touch) {
			unsigned lines = 0;
			const char *tname = object_getClassName(mondrian_cc_touch_window);

			snprintf(line, sizeof(line),
			    "MONDRIAN UI: geom cc touch window %s\n",
			    tname != NULL ? tname : "?");
			say(line);
			mondrian_geom_walk(mondrian_cc_touch_window, 0, &lines,
			    CGPointZero);
			mondrian_deep_find(mondrian_cc_touch_window, 0, CGPointZero,
			    0);
		}
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
/*
 * The dock bar is a translucent backdrop and its corners arrive square: the
 * icons the hook paints are rounded, the bar is not, because the blur is
 * painted by a layer nothing masked. Round every view whose class carries
 * "Dock" and let the log name it, so the next boot says whether the radius
 * landed on the bar or on a container that does not paint.
 */
/*
 * Setting a layer property dirties the tree, and a material view recomposites
 * its backdrop when it changes: a pass that writes the same radius on every
 * tick pays for the blur sixty times a second. Read the value and write only
 * when it is wrong -- SpringBoard's own layout does reset it, which is what the
 * periodic re-apply is for.
 */
static void
mondrian_layer_round(id layer, double radius)
{
	double cur = ((double (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("cornerRadius"));

	if (cur < radius - 0.5 || cur > radius + 0.5) {
		((void (*)(id, SEL, double))objc_msgSend)(layer,
		    sel_registerName("setCornerRadius:"), radius);
	}
}

/*
 * `mondriandockmask=1`. A mask layer filled with a colour is rounded by its own
 * corner radius, so no path is needed, and because the mask is applied to the
 * material's layer the backdrop underneath is clipped with it -- which the
 * radius alone and `clipsToBounds` did not do (measured: the bar stayed
 * square). The mask is set once per layer, not every pass: creating one dirties
 * the tree, and a material view recomposites its backdrop when it changes.
 */
static void
mondrian_layer_mask_round(id layer, CGRect bounds, double radius)
{
	id mask, colour;

	if (layer == NULL || radius <= 0.0) {
		return;
	}
	mask = [objc_getClass("CALayer") layer];
	colour = [objc_getClass("UIColor") blackColor];
	if (mask == NULL || colour == NULL) {
		return;
	}
	[mask setFrame:bounds];
	[mask setCornerRadius:radius];
	[mask setBackgroundColor:[colour CGColor]];
	[layer setMask:mask];
}

static unsigned
mondrian_dock_walk(id view, unsigned depth, unsigned *seen)
{
	static int told;
	static int subs_told;
	unsigned done = 0;
	const char *name = view != NULL ? object_getClassName(view) : NULL;
	id subs;
	unsigned n, i;

	if (view == NULL || depth > 16 || *seen >= MONDRIAN_ICON_VISITS) {
		return 0;
	}
	(*seen)++;
	if (name != NULL && strcasestr(name, "Dock") != NULL) {
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("frame"));
		id layer = mondrian_send(view, "layer");
		id kids = mondrian_send(view, "subviews");
		unsigned kn = kids != NULL ? (unsigned)[(NSArray *)kids count] : 0;
		double radius = frame.size.height * 0.3;
		unsigned k;

		if (!told) {
			char line[192];

			told = 1;
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: dock %s %.0fx%.0f at %.0f,%.0f"
			    " subviews %u radius %.1f\n",
			    name, frame.size.width, frame.size.height,
			    frame.origin.x, frame.origin.y, kn, radius);
			say(line);
		}
		if (layer != NULL && radius > 0.0) {
			mondrian_layer_round(layer, radius);
			done++;
		}
		/*
		 * The bar itself is a backdrop that outgrows the dock's bounds by a
		 * few points, so clipping the dock cuts it at the sides (measured).
		 * The radius belongs on whatever fills the dock, and that view can
		 * clip its own children.
		 */
		for (k = 0; k < kn; k++) {
			id sub = [(NSArray *)kids objectAtIndex:k];
			CGRect sf = ((CGRect (*)(id, SEL))objc_msgSend)(sub,
			    sel_registerName("frame"));
			id sl;
			double br;
			CGRect bounds = CGRectZero;
			id mask = nil;

			/*
			 * `mondriandockmask=1` rounds the material through a mask
			 * layer instead of the radius on its own layer, which is the
			 * only thing that clipped the blur (measured: the radius and
			 * `clipsToBounds` left the bar square). It is a knob because a
			 * mask forces the layer to be composited offscreen, so the
			 * blur is paid on every frame the home screen draws: measure
			 * it with `mondriananim=1` before making it the default.
			 */
			if (mondrian_dock_mask) {
				mask = mondrian_send(sub, "mask");
			}

			if (subs_told < 6) {
				char line[192];
				const char *sn = object_getClassName(sub);
				id subl = mondrian_send(sub, "layer");
				const char *ln = subl != NULL ?
				    object_getClassName(subl) : "?";

				subs_told++;
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: dock sub %u %s layer %s"
				    " %.0fx%.0f at %.0f,%.0f\n",
				    k, sn != NULL ? sn : "?", ln,
				    sf.size.width, sf.size.height,
				    sf.origin.x, sf.origin.y);
				say(line);
			}
			if (sf.size.width * sf.size.height <
			    frame.size.width * frame.size.height * 0.5) {
				continue;
			}
			sl = mondrian_send(sub, "layer");
			if (sl == NULL || radius <= 0.0) {
				continue;
			}
			/*
			 * The radius follows the view that paints: the dock's own
			 * radius is 31.2 for a 104 pt container, the material inside
			 * it is 94 tall and wants its own.
			 */
			br = sf.size.height * 0.3;
			mondrian_layer_round(sl, br);
			if (mondrian_dock_mask && mask == nil) {
				bounds = ((CGRect (*)(id, SEL))objc_msgSend)(sub,
				    sel_registerName("bounds"));
				mondrian_layer_mask_round(sl, bounds, br);
			}
			done++;
		}
	}
	subs = mondrian_send(view, "subviews");
	n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		done += mondrian_dock_walk([(NSArray *)subs objectAtIndex:i],
		    depth + 1, seen);
	}
	return done;
}

static void
mondrian_dock_round(void)
{
	id app = [objc_getClass("UIApplication") sharedApplication];
	id windows = app != NULL ? [app windows] : nil;
	unsigned count = windows != NULL ? (unsigned)[(NSArray *)windows count] : 0;
	unsigned i;

	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		unsigned seen = 0;

		if (name == NULL || strcasestr(name, "HomeScreenWindow") == NULL) {
			continue;
		}
		mondrian_dock_walk(window, 0, &seen);
	}
}

static void
mondrian_icon_probe_once(void)
{
	static unsigned attempts;

	if (mondrian_icon_late_done) {
		return;
	}
	mondrian_icon_late_report();
	if (mondrian_live_count == 0 && ++attempts < 45) {
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
	mondrian_dock_round();
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
static unsigned mondrian_unlock_attempts;

/*
 * Window geometry. A sheet that draws at the wrong size and a sheet that ignores
 * touches are the same question - what frame does UIKit think the window has -
 * so the window list is printed from here (frame, level, scene coordinate
 * space, root view): `mondrianwin=1`, and the Control Center's own tree every
 * five seconds with `mondriangeom=1`.
 */
static int mondrian_win_logs;

static void
mondrian_dump_windows(const char *why)
{
	Class app_cls = objc_getClass("UIApplication");
	id app;
	id windows;
	unsigned count, i;
	char line[288];

	if (app_cls == Nil) {
		return;
	}
	app = mondrian_send((id)app_cls, "sharedApplication");
	if (app == nil) {
		return;
	}
	windows = mondrian_send(app, "windows");
	if (windows == nil) {
		return;
	}
	count = (unsigned)[(NSArray *)windows count];
	snprintf(line, sizeof(line), "MONDRIAN UI: %s windows %u\n", why, count);
	say(line);
	for (i = 0; i < count && i < 14; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		const char *scene_name = "-";
		const char *root_name = "-";
		CGRect frame, bounds, scene_bounds = { { 0, 0 }, { 0, 0 } };
		CGFloat level = 0.0;
		CGFloat scale = 0.0;
		BOOL hidden = 0;
		id scene, root;

		frame = ((CGRect (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("frame"));
		bounds = ((CGRect (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("bounds"));
		level = ((CGFloat (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("windowLevel"));
		scale = ((CGFloat (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("contentScaleFactor"));
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("isHidden"));
		scene = mondrian_send(window, "windowScene");
		if (scene != nil) {
			id space = mondrian_send(scene, "coordinateSpace");
			scene_name = object_getClassName(scene);
			if (space != nil) {
				scene_bounds = ((CGRect (*)(id, SEL))objc_msgSend)(space,
				    sel_registerName("bounds"));
			}
		}
		root = mondrian_send(window, "rootViewController");
		if (root != nil) {
			root_name = object_getClassName(root);
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: win %u %s %.0fx%.0f at %.0f,%.0f b %.0fx%.0f"
		    " lvl %.0f sc %.2f hid %d scene %s %.0fx%.0f root %s\n",
		    i, name != NULL ? name : "?", frame.size.width,
		    frame.size.height, frame.origin.x, frame.origin.y,
		    bounds.size.width, bounds.size.height, level, scale, hidden,
		    scene_name, scene_bounds.size.width, scene_bounds.size.height,
		    root_name);
		say(line);
	}
}

/*
 * What is on the glass, asked from UIKit rather than from the panel buffer.
 * `usb-ring.py screen` reads the console HUD's memory, so it cannot say
 * whether the composited frame is the lock screen, the home screen or nothing;
 * the window list can, and it costs one boot. `mondrianwin=1`, SpringBoard
 * only, once the UI has settled.
 */
static void *
mondrian_window_watch(void *unused)
{
	(void)unused;
	sleep(100);
	mondrian_dump_windows("win watch");
	sleep(10);
	mondrian_dump_windows("win watch");
	return NULL;
}

/*
 * There is no hook in the touch path any more. Patching
 * -[UIWindow hitTest:withEvent:] put the log inside every point test UIKit
 * makes and aborted SpringBoard (sig 6) within a handful of touches, with the
 * sheet gone and only the spinner left on the glass; the answer it was after -
 * where a point lands in the Control Center - comes from the frames instead
 * (the walking dump prints each view's absolute rect), and the ones that must
 * be measured live are measured by calling hitTest on the sheet's window from
 * the geometry thread, never by wrapping it.
 */

/*
 * `mondriantouch=1`: where the events SpringBoard receives end up.
 * -[UIApplication sendEvent:] is called once per event, not once per view, so
 * wrapping it is cheap where wrapping hitTest was not. One line per touch: its
 * phase, the point, the window UIKit gives it to, and the view it lands on --
 * `nil` for the view is what a sheet that swallows touches looks like.
 */
static void (*mondrian_send_event_orig)(id, SEL, id);
static unsigned mondrian_touch_logs;

static void
mondrian_send_event(id self, SEL cmd, id event)
{
	if (mondrian_send_event_orig != NULL) {
		mondrian_send_event_orig(self, cmd, event);
	}
	if (event == nil || mondrian_touch_logs >= 200) {
		return;
	}
	{
		Class touch_cls = objc_getClass("UITouch");
		id touch = nil;
		char line[256];
		CGPoint at = { 0.0, 0.0 };
		const char *wclass = "nil";
		const char *vclass = "nil";
		long phase = -1;

		if (touch_cls != Nil) {
			id touches = mondrian_send(event, "allTouches");

			if (touches != nil && [(NSSet *)touches count] > 0) {
				touch = [(NSSet *)touches anyObject];
			}
		}
		if (touch != nil) {
			id win, view;

			phase = (long)((long (*)(id, SEL))objc_msgSend)(touch,
			    sel_registerName("phase"));
			at = ((CGPoint (*)(id, SEL, id))objc_msgSend)(touch,
			    sel_registerName("locationInView:"), nil);
			win = mondrian_send(touch, "window");
			view = mondrian_send(touch, "view");
			wclass = win != nil ? object_getClassName(win) : "nil";
			vclass = view != nil ? object_getClassName(view) : "nil";
			if (win != nil && wclass != NULL &&
			    strstr(wclass, "ControlCenter") != NULL &&
			    win != mondrian_cc_touch_window) {
				[(id)win retain];
				if (mondrian_cc_touch_window != nil) {
					[(id)mondrian_cc_touch_window release];
				}
				mondrian_cc_touch_window = win;
			}
		}
		/* A drag is a hundred moves; the phases that matter are the ends. */
		if (phase == 1) {
			return;
		}
		mondrian_touch_logs++;
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: touch %u phase %ld at %.1f,%.1f window %s view %s\n",
		    mondrian_touch_logs, phase, at.x, at.y, wclass, vclass);
		say(line);
	}
}

static void
install_touch_probe(void)
{
	Class cls = objc_getClass("UIApplication");
	Method m;

	if (!boot_arg_set("mondriantouch=1") || cls == Nil) {
		return;
	}
	m = class_getInstanceMethod(cls, sel_registerName("sendEvent:"));
	if (m == NULL) {
		return;
	}
	mondrian_send_event_orig = (void (*)(id, SEL, id))
	    method_setImplementation(m, (IMP)mondrian_send_event);
	say("MONDRIAN UI: touch probe installed\n");
}

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
	id app;
	Method idle_method;

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
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls, app_sel);
	if (app == nil) {
		/* still starting: the next tick retries */
		return;
	}
	if (boot_arg_set("mondrianwin=1")) {
		static unsigned win_ticks;

		if ((win_ticks++ % 5) == 1) {
			mondrian_dump_windows("win tick");
		}
	} else if (mondrian_win_logs < 2) {
		if ((mondrian_win_logs++ == 0) || (mondrian_lock_ticks % 5) == 0) {
			mondrian_dump_windows("win early");
		}
	}
	if (boot_arg_set("mondriangeom=1")) {
		static unsigned geom_ticks;

		if ((geom_ticks++ % 10) == 1) {
			mondrian_log_screen_geometry();
		}
	}
	if (boot_arg_set("mondriancct=1")) {
		id windows = mondrian_send(app, "windows");
		unsigned count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
		unsigned wi;

		for (wi = 0; wi < count; wi++) {
			id window = [(NSArray *)windows objectAtIndex:wi];
			const char *name = object_getClassName(window);
			unsigned changed = 0;

			if (name == NULL || strstr(name, "ControlCenter") == NULL) {
				continue;
			}
			if (((BOOL (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("isHidden"))) {
				continue;
			}
			mondrian_cc_normalize(window, 0, &changed);
			if (changed != 0) {
				char line[96];

				snprintf(line, sizeof(line),
				    "MONDRIAN UI: cc normalized %u layers\n", changed);
				say(line);
			}
		}
	}
	/*
	 * Keep the display awake. Nothing in this userland ever asks for it:
	 * SpringBoard arms its idle timer a minute after the UI settles, the
	 * backlight state goes off, and every CADisplayLink in the system stops
	 * even though the panel keeps the last frame (measured: frames stop at
	 * ts 138 s, fifty seconds after the unlock, and no touch brings them
	 * back). The public property is the documented switch for it; setting
	 * it every two seconds survives a userland that clears it.
	 */
	idle_method = class_getInstanceMethod(app_cls,
	    sel_registerName("setIdleTimerDisabled:"));
	if (idle_method != NULL) {
		((void (*)(id, SEL, BOOL))method_getImplementation(idle_method))(
		    app, sel_registerName("setIdleTimerDisabled:"), YES);
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
		/*
		 * SpringBoard rebuilds the dock when the layout changes, and a
		 * radius put on the old view goes with it: walk the tree again,
		 * but every twenty ticks rather than every one -- the walk itself
		 * costs, and the write is already guarded by a read.
		 */
		if ((mondrian_home_ticks % 20) == 0) {
			mondrian_dock_round();
		}
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
	 * A minute in and every step after it: the home screen tree is behind
	 * the lock screen, and the artwork is wanted *there*. The paint pass
	 * used to wait for the unlock, which put eight PNG reads and their
	 * decode in the same two seconds as the unlock animation: the transition
	 * then held 4-10 frames a second (ring252, the first ten seconds after
	 * `lock screen gone`) while a drag on the lock screen held 1.3. Painting while
	 * locked moves that work to a moment when nothing is moving. The report
	 * is read-only until the tree has live views, so it is safe to ask early.
	 */
	if (mondrian_lock_ticks >= 10) {
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
	/*
	 * First attempt twenty seconds in, then one a minute: a display that
	 * slept before the idle timer was disabled locks again, and the home
	 * screen has to come back without a reboot.
	 */
	if (mondrian_lock_ticks < 10 ||
	    (mondrian_lock_ticks > 10 && (mondrian_lock_ticks % 30) != 0)) {
		return;
	}
	method = class_getInstanceMethod(cls, request_sel);
	if (method != NULL) {
		((void (*)(id, SEL))method_getImplementation(method))(manager, request_sel);
		if (mondrian_unlock_attempts < 10) {
			mondrian_unlock_attempts++;
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: unlock requested (lock screen view, attempt %u)\n",
			    mondrian_unlock_attempts);
			say(line);
		}
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
	mondrian_anim_enabled = boot_arg_int("mondriananim=", 0);
	/*
	 * The dock's mask is on: measured against a home screen drawing every frame
	 * (`mondriananim=1`), it cost nothing at the panel -- 59.7 fps over 180 s,
	 * 172 seconds at exactly 60, `pgap over30` 0.06 a second (ring257) against
	 * 59.9 and 0.05 without it (ring256). It makes the renderer burstier (11
	 * ticks a second got two records and 11 got none, against 60 one-record
	 * ticks) and the two-deep queue absorbs exactly that. `mondriandockmask=0`
	 * turns it off.
	 */
	mondrian_dock_mask = boot_arg_set("mondriandockmask=0") == 0;
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
 * The frame rate a display link asks for.
 *
 * UIKit runs the animations an application does in its own process (a home
 * screen page settling after a swipe among them) from a CADisplayLink whose
 * target is UIViewInProcessAnimationManager, and asks that link for 20..30 a
 * second: on a ProMotion iPhone the lower rate saves power. This panel
 * refreshes at 60 whatever is drawn, so the animation runs at half the panel
 * and a page that settles looks like it steps -- measured on the SM8475 port
 * this comes from (UniXNU-zizhan, 42629e5d): the same image, only the target
 * name matched, went from 56.7 fps with the presentation interval at 16.59 ms
 * to 95.3 fps at 8.33 ms. Its first version matched only the Objective-C
 * spelling and did nothing, because the class in the device runtime is the
 * Swift one, "UIKit.InProcessAnimationManager"; both are matched here.
 *
 * Only that link loses its rate. The clock's and the motion effects' keep
 * theirs: run at the panel's rate they wake SpringBoard six times as often
 * for nothing. mondrianlinkfull=0 keeps every rate (the A/B);
 * mondrianlinksay=1 says every link made and every rate asked of one.
 */
typedef struct {
	float minimum, maximum, preferred;
} mondrian_frame_rate_range;

static id (*mondrian_original_link_with_target)(id, SEL, id, SEL);
static void (*mondrian_original_link_set_fps)(id, SEL, long);
static void (*mondrian_original_link_set_range)(id, SEL,
    mondrian_frame_rate_range);
static int mondrian_link_full_rate = 1;
static int mondrian_link_say;
static unsigned mondrian_link_said;
static char mondrian_link_full_key;

static const char *
mondrian_link_caller(const void *address, char *buffer, size_t size)
{
	Dl_info info;
	const char *image;

	if (dladdr(address, &info) == 0 || info.dli_fname == NULL) {
		snprintf(buffer, size, "%p", address);
		return buffer;
	}
	image = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 :
	    info.dli_fname;
	snprintf(buffer, size, "%s+%#lx", image,
	    (unsigned long)((uintptr_t)address - (uintptr_t)info.dli_fbase));
	return buffer;
}

static int
mondrian_link_at_full_rate(id link)
{
	return mondrian_link_full_rate &&
	    objc_getAssociatedObject(link, &mondrian_link_full_key) != nil;
}

static id
mondrian_link_with_target(id self, SEL selector, id target, SEL action)
{
	id link = mondrian_original_link_with_target(self, selector, target,
	    action);
	char who[160];

	if (link != NULL && target != NULL) {
		const char *name = object_getClassName(target);

		if (strcmp(name, "UIViewInProcessAnimationManager") == 0 ||
		    strcmp(name, "UIKit.InProcessAnimationManager") == 0) {
			objc_setAssociatedObject(link, &mondrian_link_full_key,
			    (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
		}
	}
	if (mondrian_link_say && mondrian_link_said++ < 120) {
		char line[260];

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: display link %p made for -[%s %s] by %s\n",
		    (void *)link, target ? object_getClassName(target) : "nil",
		    action ? sel_getName(action) : "",
		    mondrian_link_caller(__builtin_return_address(0), who,
		    sizeof(who)));
		say(line);
	}
	return link;
}

static void
mondrian_link_set_fps(id self, SEL selector, long fps)
{
	char who[160];

	if (mondrian_link_say && mondrian_link_said++ < 120) {
		char line[200];

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: display link %p asked for %ld a second%s by %s\n",
		    (void *)self, fps,
		    mondrian_link_at_full_rate(self) ? " (dropped)" : "",
		    mondrian_link_caller(__builtin_return_address(0), who,
		    sizeof(who)));
		say(line);
	}
	mondrian_original_link_set_fps(self, selector,
	    mondrian_link_at_full_rate(self) ? 0 : fps);
}

static void
mondrian_link_set_range(id self, SEL selector,
    mondrian_frame_rate_range range)
{
	char who[160];

	if (mondrian_link_say && mondrian_link_said++ < 120) {
		char line[220];

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: display link %p asked for %.0f..%.0f, %.0f a "
		    "second%s by %s\n", (void *)self, range.minimum,
		    range.maximum, range.preferred,
		    mondrian_link_at_full_rate(self) ? " (dropped)" : "",
		    mondrian_link_caller(__builtin_return_address(0), who,
		    sizeof(who)));
		say(line);
	}
	if (mondrian_link_at_full_rate(self)) {
		range = (mondrian_frame_rate_range){ 0, 0, 0 };
	}
	mondrian_original_link_set_range(self, selector, range);
}

static void
install_display_link_rate_hooks(void)
{
	Class cls = objc_getClass("CADisplayLink");
	Method with_target, fps, range;

	if (cls == Nil) {
		say("MONDRIAN UI: CADisplayLink not found; rates not hooked\n");
		return;
	}
	mondrian_link_full_rate = boot_arg_set("mondrianlinkfull=0") == 0;
	mondrian_link_say = boot_arg_set("mondrianlinksay=1") != 0;
	with_target = class_getClassMethod(cls,
	    @selector(displayLinkWithTarget:selector:));
	if (with_target != NULL) {
		mondrian_original_link_with_target =
		    (id (*)(id, SEL, id, SEL))method_setImplementation(with_target,
		    (IMP)mondrian_link_with_target);
	}
	fps = class_getInstanceMethod(cls, @selector(setPreferredFramesPerSecond:));
	if (fps != NULL) {
		mondrian_original_link_set_fps =
		    (void (*)(id, SEL, long))method_setImplementation(fps,
		    (IMP)mondrian_link_set_fps);
	}
	range = class_getInstanceMethod(cls, @selector(setPreferredFrameRateRange:));
	if (range != NULL) {
		mondrian_original_link_set_range =
		    (void (*)(id, SEL, mondrian_frame_rate_range))
		    method_setImplementation(range, (IMP)mondrian_link_set_range);
	}
	say("MONDRIAN UI: display link rates hooked (in-process animations at "
	    "the panel's rate)\n");
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

/*
 * Brightness. CoreBrightness never comes up on this port (the display publishes
 * no IODisplay backlight node), so IOMobileFramebuffer's own brightness control
 * stays disabled and iOS drops SwapSetBrightness with "Brightness control is
 * not enabled": the swap record's brightness byte is never set. The level iOS
 * wants is computed in SpringBoard instead, so take it there and hand it to the
 * driver's selector 100, which writes the panel's DCS 0x51 at the next vsync.
 *
 * The level is not in SBBacklightController on iOS 16.7 (that class only
 * carries the screen-on/off state); SBDisplayBrightnessController has it. Both
 * are scanned, and the setter is matched by name and by type encoding rather
 * than by a hardcoded selector, because reading a float argument as a double
 * would send half the level's bits to the panel.
 */
static io_connect_t mondrian_bl_conn;
static uint32_t mondrian_bl_sent = 0xffffffffu;
static int mondrian_bl_logs;
static double mondrian_bl_panel_w;
static double mondrian_bl_panel_h;
static void (*mondrian_bl_orig_1d)(id, SEL, double);
static void (*mondrian_bl_orig_1f)(id, SEL, float);
static void (*mondrian_bl_orig_2d)(id, SEL, double, long);
static void (*mondrian_bl_orig_2f)(id, SEL, float, long);

static int
mondrian_bl_connect(void)
{
	io_service_t service;
	io_connect_t conn;

	if (mondrian_bl_conn != 0) {
		return 1;
	}
	service = IOServiceGetMatchingService(0,
	    IOServiceMatching("IOMobileFramebuffer"));
	if (service == MACH_PORT_NULL) {
		return 0;
	}
	if (IOServiceOpen(service, mach_task_self(), 0, &conn) != KERN_SUCCESS) {
		IOObjectRelease(service);
		say("MONDRIAN UI: brightness: no user client\n");
		return 0;
	}
	IOObjectRelease(service);
	mondrian_bl_conn = conn;
	/*
	 * GetDisplaySize: the panel's canvas in pixels, straight from the driver.
	 * The reference-bounds hook needs it, and this is the only place the
	 * connection is created.
	 */
	{
		uint64_t out[2] = { 0, 0 };
		uint32_t count = 2;

		if (IOConnectCallScalarMethod(conn, 8, NULL, 0, out, &count) ==
		    KERN_SUCCESS && count == 2 && out[0] > 0 && out[1] > 0) {
			mondrian_bl_panel_w = (double)out[0];
			mondrian_bl_panel_h = (double)out[1];
		}
	}
	return 1;
}

static void
mondrian_bl_apply(const char *who, double level)
{
	uint64_t in;
	uint32_t v;

	if (!(level >= 0.0)) {
		return;
	}
	if (level > 1.0) {
		level = 1.0;
	}
	v = (uint32_t)(level * 4095.0 + 0.5);
	if (v == mondrian_bl_sent || !mondrian_bl_connect()) {
		return;
	}
	mondrian_bl_sent = v;
	in = v;
	IOConnectCallScalarMethod(mondrian_bl_conn, 100, &in, 1, NULL, NULL);
	if (mondrian_bl_logs < 24) {
		char buf[128];

		mondrian_bl_logs++;
		snprintf(buf, sizeof(buf), "MONDRIAN UI: %s %.3f -> %u\n", who,
		    level, v);
		say(buf);
	}
}

static void
mondrian_bl_1d(id self, SEL cmd, double level)
{
	mondrian_bl_apply(sel_getName(cmd), level);
	if (mondrian_bl_orig_1d != NULL) {
		mondrian_bl_orig_1d(self, cmd, level);
	}
}

static void
mondrian_bl_1f(id self, SEL cmd, float level)
{
	mondrian_bl_apply(sel_getName(cmd), (double)level);
	if (mondrian_bl_orig_1f != NULL) {
		mondrian_bl_orig_1f(self, cmd, level);
	}
}

static void
mondrian_bl_2d(id self, SEL cmd, double level, long flag)
{
	mondrian_bl_apply(sel_getName(cmd), level);
	if (mondrian_bl_orig_2d != NULL) {
		mondrian_bl_orig_2d(self, cmd, level, flag);
	}
}

static void
mondrian_bl_2f(id self, SEL cmd, float level, long flag)
{
	mondrian_bl_apply(sel_getName(cmd), (double)level);
	if (mondrian_bl_orig_2f != NULL) {
		mondrian_bl_orig_2f(self, cmd, level, flag);
	}
}

/*
 * First argument of an Objective-C method, from its type encoding. The encoding
 * carries the size of every element ("v24@0:8f16B20"), so the digits and the
 * self/_cmd pair have to be skipped before the argument types start.
 */
static const char *
mondrian_bl_args(const char *types)
{
	const char *p = types;

	if (p == NULL || *p == 0) {
		return NULL;
	}
	p++;                                    /* return type */
	while (*p >= '0' && *p <= '9') {
		p++;
	}
	if (*p != '@') {
		return NULL;
	}
	p++;
	while (*p >= '0' && *p <= '9') {
		p++;
	}
	if (*p != ':') {
		return NULL;
	}
	p++;
	while (*p >= '0' && *p <= '9') {
		p++;
	}
	return p;
}

static void
mondrian_bl_try(Method m, const char *types)
{
	const char *a = mondrian_bl_args(types);
	const char *b;

	if (a == NULL || (*a != 'f' && *a != 'd')) {
		return;
	}
	/* Second argument, if any: skip its size, then read its type. */
	b = a + 1;
	while (*b >= '0' && *b <= '9') {
		b++;
	}
	if (*b == 0 && *a == 'd' && mondrian_bl_orig_1d == NULL) {
		mondrian_bl_orig_1d = (void (*)(id, SEL, double))
		    method_setImplementation(m, (IMP)mondrian_bl_1d);
	} else if (*b == 0 && *a == 'f' && mondrian_bl_orig_1f == NULL) {
		mondrian_bl_orig_1f = (void (*)(id, SEL, float))
		    method_setImplementation(m, (IMP)mondrian_bl_1f);
	} else if ((*b == 'B' || *b == 'q' || *b == 'c' || *b == 'i') &&
	    *a == 'd' && mondrian_bl_orig_2d == NULL) {
		mondrian_bl_orig_2d = (void (*)(id, SEL, double, long))
		    method_setImplementation(m, (IMP)mondrian_bl_2d);
	} else if ((*b == 'B' || *b == 'q' || *b == 'c' || *b == 'i') &&
	    *a == 'f' && mondrian_bl_orig_2f == NULL) {
		mondrian_bl_orig_2f = (void (*)(id, SEL, float, long))
		    method_setImplementation(m, (IMP)mondrian_bl_2f);
	} else {
		return;
	}
}

static void
mondrian_bl_scan(const char *class_name, int dump)
{
	Class cls = objc_getClass(class_name);
	unsigned int i, n = 0;
	Method *methods;

	if (cls == Nil) {
		say("MONDRIAN UI: no class for the brightness level\n");
		return;
	}
	methods = class_copyMethodList(cls, &n);
	for (i = 0; i < n; i++) {
		const char *name = sel_getName(method_getName(methods[i]));
		const char *types = method_getTypeEncoding(methods[i]);
		char buf[200];

		if (dump) {
			snprintf(buf, sizeof(buf), "MONDRIAN UI: %s -%s %s\n",
			    class_name, name, types != NULL ? types : "?");
			say(buf);
		}
		if (strstr(name, "etBrightnessLevel") == NULL &&
		    strstr(name, "etBacklightLevel") == NULL) {
			continue;
		}
		if (!dump) {
			snprintf(buf, sizeof(buf), "MONDRIAN UI: %s -%s %s\n",
			    class_name, name, types != NULL ? types : "?");
			say(buf);
		}
		mondrian_bl_try(methods[i], types);
	}
	free(methods);
}

static void
install_brightness_hooks(void)
{
	mondrian_bl_scan("SBDisplayBrightnessController", 1);
	mondrian_bl_scan("SBBacklightController", 0);
	mondrian_bl_scan("SBBrightnessControl", 0);
	say(mondrian_bl_orig_1d != NULL || mondrian_bl_orig_1f != NULL ||
	    mondrian_bl_orig_2d != NULL || mondrian_bl_orig_2f != NULL ?
	    "MONDRIAN UI: brightness level hooked\n" :
	    "MONDRIAN UI: brightness level not hooked\n");
}

/*
 * UI size. The panel is 1440x3200 (480x1066 pt at scale 3), and SpringBoard's
 * own window uses that, but every sheet that lays itself out from UIKit's
 * *reference* bounds - Control Center, Spotlight and its keyboard - comes out
 * 375x812 pt instead: it draws into a 1125x2436 surface, which the compositor
 * then puts in the panel's top-left corner, with a wide margin to the right and
 * wallpaper below. -[UIScreen _referenceBounds] is the model's point size, not
 * the screen's, so return the screen's: nativeBounds / scale, which is what the
 * home screen already uses. nativeBounds is read instead of bounds so the
 * replacement cannot recurse into the method it replaces.
 */
static CGRect (*mondrian_bl_orig_ref_bounds)(id, SEL);
static CGRect (*mondrian_bl_orig_unjailed)(id, SEL);
static uint64_t mondrian_bl_ref_logged;

static CGRect
mondrian_screen_reference_bounds(void)
{
	/*
	 * The panel in points: the driver's canvas over the display's scale. No
	 * call back into UIScreen here - nativeBounds, scale and mainScreen all
	 * end up reading the reference bounds on this build, and re-entering the
	 * method being replaced was a SpringBoard crash loop with no log line.
	 * 3.0 is this panel's scale (1440x3200 px, 480x1066 pt), the same one the
	 * home screen's own window uses.
	 */
	CGRect out = { { 0, 0 }, { 0, 0 } };

	if (mondrian_bl_panel_w <= 0.0 || mondrian_bl_panel_h <= 0.0) {
		/* The user client is not open yet: try again on the next call. */
		(void)mondrian_bl_connect();
	}
	if (mondrian_bl_panel_w > 0.0 && mondrian_bl_panel_h > 0.0) {
		out.size.width = mondrian_bl_panel_w / 3.0;
		out.size.height = mondrian_bl_panel_h / 3.0;
	}
	return out;
}

/*
 * Which of UIScreen's several "reference" rectangles a sheet actually reads is
 * not obvious - the Control Center came out 375x812 pt while
 * _unjailedReferenceBounds already answered 480x1067 - so every parameterless
 * accessor in the family is hooked to the same replacement, and the first call
 * of each logs what it used to answer. The replacement answers the panel, so a
 * method that was right before stays right.
 */
#define MONDRIAN_SCREEN_ACCESSORS 8

static const char *const mondrian_screen_names[MONDRIAN_SCREEN_ACCESSORS] = {
	"_referenceBounds",
	"_unjailedReferenceBounds",
	"_mainSceneReferenceBounds",
	"_sceneReferenceBounds",
	"_fixedReferenceBounds",
	"_dynamicReferenceBounds",
	"_lock_referenceBounds",
	"_lock_unjailedReferenceBounds",
};

static struct {
	const char *name;
	IMP         orig;
	int         logged;
} mondrian_screen_imps[MONDRIAN_SCREEN_ACCESSORS];

static IMP
mondrian_screen_original(SEL cmd)
{
	unsigned i;

	for (i = 0; i < MONDRIAN_SCREEN_ACCESSORS; i++) {
		if (mondrian_screen_imps[i].name != NULL &&
		    strcmp(mondrian_screen_imps[i].name, sel_getName(cmd)) == 0) {
			return mondrian_screen_imps[i].orig;
		}
	}
	return NULL;
}

static CGRect
mondrian_screen_bounds_family(id self, SEL cmd)
{
	CGRect real = mondrian_screen_reference_bounds();
	const char *name = sel_getName(cmd);
	unsigned i;

	mondrian_bl_ref_logged++;      /* calls seen, for the report thread */
	for (i = 0; i < MONDRIAN_SCREEN_ACCESSORS; i++) {
		if (mondrian_screen_imps[i].name == NULL ||
		    strcmp(mondrian_screen_imps[i].name, name) != 0 ||
		    mondrian_screen_imps[i].logged != 0) {
			continue;
		}
		mondrian_screen_imps[i].logged = 1;
		if (mondrian_screen_imps[i].orig != NULL) {
			CGRect was = ((CGRect (*)(id, SEL))
			    mondrian_screen_imps[i].orig)(self, cmd);
			char buf[192];

			snprintf(buf, sizeof(buf),
			    "MONDRIAN UI: %s %.0fx%.0f -> %.0fx%.0f\n", name,
			    was.size.width, was.size.height, real.size.width,
			    real.size.height);
			say(buf);
		}
	}
	if (real.size.width > 0.0 && real.size.height > 0.0) {
		return real;
	}
	{
		IMP orig = mondrian_screen_original(cmd);

		if (orig != NULL) {
			return ((CGRect (*)(id, SEL))orig)(self, cmd);
		}
	}
	return real;
}

/*
 * One late report of what UIKit thinks the display is, for the log.
 *
 * UIKit's screen accessors belong to the main thread: called from a thread of
 * our own they raise an exception and the daemon dies (measured: SpringBoard
 * aborted in a loop once the boot got fast enough for the report to land after
 * UIKit was up). The report is therefore queued on the main queue, and an
 * exception in it is caught rather than fatal.
 */
static void
mondrian_screen_report(void *unused)
{
	Class cls = objc_getClass("UIScreen");
	id screen;
	CGRect bounds, native;
	double scale;
	unsigned i;
	char buf[224];

	(void)unused;
	if (cls == Nil) {
		return;
	}
	@try {
		screen = ((id (*)(id, SEL))objc_msgSend)(cls,
		    @selector(mainScreen));
		if (screen == nil) {
			return;
		}
		bounds = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("bounds"));
		native = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("nativeBounds"));
		scale = ((double (*)(id, SEL))objc_msgSend)(screen,
		    sel_registerName("scale"));
	} @catch (NSException *e) {
		say("MONDRIAN UI: screen report skipped (exception)\n");
		return;
	}
	snprintf(buf, sizeof(buf),
	    "MONDRIAN UI: screen bounds %.1fx%.1f native %.0fx%.0f scale %.2f\n",
	    bounds.size.width, bounds.size.height, native.size.width,
	    native.size.height, scale);
	say(buf);
	for (i = 0; i < MONDRIAN_SCREEN_ACCESSORS; i++) {
		SEL sel;
		IMP imp;
		CGRect was;

		if (mondrian_screen_imps[i].name == NULL ||
		    mondrian_screen_imps[i].orig == NULL) {
			continue;
		}
		sel = sel_registerName(mondrian_screen_imps[i].name);
		imp = mondrian_screen_imps[i].orig;
		if (class_getInstanceMethod(cls, sel) == NULL) {
			continue;
		}
		@try {
			was = ((CGRect (*)(id, SEL))imp)(screen, sel);
		} @catch (NSException *e) {
			continue;
		}
		snprintf(buf, sizeof(buf), "MONDRIAN UI: %s was %.0fx%.0f\n",
		    mondrian_screen_imps[i].name, was.size.width,
		    was.size.height);
		say(buf);
	}
}

static void *
mondrian_screen_report_thread(void *unused)
{
	(void)unused;
	sleep(12);
	dispatch_async_f(dispatch_get_main_queue(), NULL, mondrian_screen_report);
	return NULL;
}

/*
 * `mondriangeom=1` used to dump from the lock screen's step, which stops
 * running once the phone is unlocked -- and Control Center is opened after the
 * unlock, so the sheet that lays itself out wrong was never described. This
 * thread keeps dumping every five seconds: the screen's bounds and scale, every
 * window, and the Control Center's own frames with their transforms, so
 * whatever is on the glass when the dump is read is what the lines describe.
 */
static void *
mondrian_geom_report_thread(void *unused)
{
	(void)unused;

	/*
	 * Called straight from this thread, not through the main queue: on this
	 * port SpringBoard's main run loop spends long stretches blocked, and a
	 * dispatch_async dump waits for it -- which is exactly how the first
	 * version of this thread produced no lines at all. Everything it reads
	 * (bounds, frames, transforms) is a property read.
	 */
	for (unsigned i = 0; i < 90; i++) {
		sleep(5);
		mondrian_log_screen_geometry();
	}
	return NULL;
}

/*
 * Control Center's module grid is 430 pt wide whatever the screen is. On this
 * panel (480 pt) it sits at x=0 inside a full-width scroll view, which leaves
 * 37 pt on the left and 87 on the right: the sheet is not centred. Widening the
 * grid was the obvious fix and broke the present (partial frames, one boot), so
 * the whole sheet is shifted instead -- a left and right content inset of half
 * the slack, which moves the drawing without touching a single frame.
 *
 * The inset is written from the main-queue pass below, never from
 * -layoutSubviews: a write there re-enters the layout the sheet is running and
 * the sheet spends its time laying out (measured: a frozen panel).
 */
static void
mondrian_cc_centre(id scroll)
{
	CGRect b;
	CGSize content;
	mondrian_insets inset;
	CGFloat pad;

	b = ((CGRect (*)(id, SEL))objc_msgSend)(scroll, sel_registerName("bounds"));
	content = ((CGSize (*)(id, SEL))objc_msgSend)(scroll,
	    sel_registerName("contentSize"));
	if (b.size.width < 1.0 || content.width < 1.0 ||
	    content.width + 1.0 >= b.size.width) {
		return;
	}
	pad = (b.size.width - content.width) / 2.0;
	inset = ((mondrian_insets (*)(id, SEL))objc_msgSend)(scroll,
	    sel_registerName("contentInset"));
	if (inset.left == pad && inset.right == pad) {
		return;
	}
	inset.left = pad;
	inset.right = pad;
	((void (*)(id, SEL, mondrian_insets))objc_msgSend)(scroll,
	    sel_registerName("setContentInset:"), inset);
}

/*
 * The sheet's sliders need three small corrections, all applied from here once a
 * second while the sheet is open:
 *
 * - a vertical drag never reached them: the touch began on the module and was
 *   gone 200 ms later (the sendEvent log shows `touch.view` going nil in the
 *   middle of the drag), the scroll view's touch delay handing it to its pan.
 *   The sheet does not scroll on a panel this tall -- its grid fits -- so the
 *   scrolling and the delay go, and the swipe affordance stays live or the
 *   sheet cannot be pulled down at all;
 * - the brightness slider arrives with `userInteractionEnabled` off
 *   (`CCUIContinuousSliderView ... ui 0`) while the volume slider next to it is
 *   enabled, so interaction is turned back on;
 * - its module never calls a brightness setter, so each Control Center slider
 *   gets one target of ours that hands its value to the panel.
 *
 * Always on: it only ever touches a visible Control Center window.
 */
/*
 * A Control Center slider moves but nothing follows it: the module controller
 * never calls the brightness controller (no `MONDRIAN UI: <setter> ...` line
 * after a drag), so the only thing that changes is the control's own paint.
 * The level has to reach the panel anyway -- CoreBrightness never comes up on
 * this port -- so each sheet slider gets one target of ours that reads its
 * value and hands it to the panel, the same way the brightness hook does. The
 * volume slider is MediaRemoteUI's and is left alone: it needs the media stack,
 * not this bridge.
 */
@interface MondrianCCSliderTarget : NSObject
- (void)mondrianSliderChanged:(id)sender;
@end

static void
mondrian_cc_slider_value(id slider)
{
	SEL sel = sel_registerName("value");
	Method m = class_getInstanceMethod(object_getClass(slider), sel);
	const char *types = m != NULL ? method_getTypeEncoding(m) : NULL;
	const char *name = object_getClassName(slider);
	double level;
	char line[192];

	if (types == NULL) {
		return;
	}
	if (types[0] == 'f') {
		level = (double)((float (*)(id, SEL))objc_msgSend)(slider, sel);
	} else if (types[0] == 'd') {
		level = ((double (*)(id, SEL))objc_msgSend)(slider, sel);
	} else {
		return;
	}
	/*
	 * A DBV of 0 is a black panel, which reads as a dead phone: the sheet's
	 * own minimum is where a finger stops, not where the light does.
	 */
	if (level < 0.05) {
		level = 0.05;
	}
	snprintf(line, sizeof(line), "MONDRIAN UI: cc slider %s %.3f\n",
	    name != NULL ? name : "?", level);
	say(line);
	mondrian_bl_apply("cc slider", level);
}

@implementation MondrianCCSliderTarget
- (void)mondrianSliderChanged:(id)sender
{
	mondrian_cc_slider_value(sender);
}
@end

static void
mondrian_cc_bridge_slider(id slider)
{
	static void *seen[8];
	static MondrianCCSliderTarget *target;
	unsigned i;

	for (i = 0; i < sizeof(seen) / sizeof(seen[0]); i++) {
		if (seen[i] == (void *)slider) {
			return;
		}
	}
	if (target == nil) {
		target = [[MondrianCCSliderTarget alloc] init];
	}
	if (target == nil) {
		return;
	}
	((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(slider,
	    sel_registerName("addTarget:action:forControlEvents:"), target,
	    sel_registerName("mondrianSliderChanged:"), 1UL << 12);
	for (i = 0; i < sizeof(seen) / sizeof(seen[0]); i++) {
		if (seen[i] == NULL) {
			seen[i] = (void *)slider;
			break;
		}
	}
}

static unsigned
mondrian_cc_wake_sliders(id view, unsigned depth)
{
	id kids;
	unsigned n, i, woken = 0;
	const char *name = object_getClassName(view);

	if (view == nil || depth > 16) {
		return 0;
	}
	if (name != NULL && strstr(name, "SliderView") != NULL) {
		if (strstr(name, "CCUI") != NULL) {
			BOOL enabled = ((BOOL (*)(id, SEL))objc_msgSend)(view,
			    sel_registerName("isUserInteractionEnabled"));

			if (!enabled) {
				((void (*)(id, SEL, BOOL))objc_msgSend)(view,
				    sel_registerName("setUserInteractionEnabled:"), YES);
				woken++;
			}
			mondrian_cc_bridge_slider(view);
		} else {
			/*
			 * MediaRemoteUI's volume slider: its module talks to the
			 * media stack, which this port does not have, so a drag
			 * moves the control and changes nothing. Dim it and keep
			 * the finger off it until audio exists; a slider that
			 * answers but does nothing reads as a broken phone.
			 *
			 * The module owns a second, hidden slider for its
			 * expanded state; dimming that one makes it appear at the
			 * sheet's right edge (measured), so only a visible one is
			 * touched.
			 */
			BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view,
			    sel_registerName("isHidden"));
			double alpha = ((double (*)(id, SEL))objc_msgSend)(view,
			    sel_registerName("alpha"));

			if (!hidden && alpha > 0.05) {
				((void (*)(id, SEL, BOOL))objc_msgSend)(view,
				    sel_registerName("setUserInteractionEnabled:"),
				    NO);
				((void (*)(id, SEL, double))objc_msgSend)(view,
				    sel_registerName("setAlpha:"), 0.35);
			}
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		woken += mondrian_cc_wake_sliders(
		    [(NSArray *)kids objectAtIndex:i], depth + 1);
	}
	return woken;
}

/*
 * One dump of the whole sheet, once per boot, on the frame that first sees it:
 * the banding question is whether the sheet's material covers the screen or
 * stops short, and that is a frame, not a colour. Depth 12 with 70 lines was
 * enough to reach the grid on this layout (a cap of 9 hid the sliders).
 */
static unsigned mondrian_cc_dump_lines;

static void
mondrian_cc_dump(id view, unsigned depth)
{
	const char *name = object_getClassName(view);
	id kids;
	unsigned n, i;

	if (view == nil || depth > 12 || mondrian_cc_dump_lines > 70) {
		return;
	}
	{
		BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("isHidden"));
		double alpha = ((double (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("alpha"));
		CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("frame"));
		char line[192];

		snprintf(line, sizeof(line),
		    "MONDRIAN CC %u %s %.0f,%.0f %.0fx%.0f h%d a%.2f\n",
		    depth, name != NULL ? name : "?", f.origin.x, f.origin.y,
		    f.size.width, f.size.height, hidden ? 1 : 0, alpha);
		say(line);
		mondrian_cc_dump_lines++;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_cc_dump([(NSArray *)kids objectAtIndex:i], depth + 1);
	}
}

static void
mondrian_cc_main_pass(void)
{
	static int told_woken;
	Class app_cls = objc_getClass("UIApplication");
	Method shared;
	id app, windows;
	unsigned n, i;

	if (app_cls == Nil) {
		return;
	}
	shared = class_getClassMethod(app_cls, sel_registerName("sharedApplication"));
	if (shared == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(shared))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	n = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < n; i++) {
		id win = [(NSArray *)windows objectAtIndex:i];
		const char *wclass = object_getClassName(win);
		BOOL hidden;
		id kids;

		if (wclass == NULL || strstr(wclass, "ControlCenter") == NULL) {
			continue;
		}
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(win,
		    sel_registerName("isHidden"));
		kids = mondrian_send(win, "subviews");
		for (unsigned k = 0; k < (kids != nil ? (unsigned)[(NSArray *)kids count] : 0); k++) {
			id v = [(NSArray *)kids objectAtIndex:k];
			const char *c = object_getClassName(v);

			if (c != NULL && strstr(c, "CCUIScrollView") != NULL && !hidden) {
				((void (*)(id, SEL, BOOL))objc_msgSend)(v,
				    sel_registerName("setScrollEnabled:"), NO);
				((void (*)(id, SEL, BOOL))objc_msgSend)(v,
				    sel_registerName("setDelaysContentTouches:"), NO);
				mondrian_cc_centre(v);
			}
		}
		if (!hidden) {
			unsigned woken = mondrian_cc_wake_sliders(win, 0);

			if (mondrian_cc_dump_lines == 0) {
				CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(win,
				    sel_registerName("bounds"));
				char line[128];

				snprintf(line, sizeof(line),
				    "MONDRIAN CC window %s %.0fx%.0f\n", wclass,
				    b.size.width, b.size.height);
				say(line);
				mondrian_cc_dump(win, 0);
			}
			if (woken != 0 && told_woken == 0) {
				told_woken = 1;
				say("MONDRIAN UI: cc sliders woken\n");
			}
		}
	}
}

static int mondrian_cc_pass_pending;

/*
 * Every UIKit change the sheet needs happens on the main thread: the pass only
 * dispatches, and only when the previous one has finished, so a blocked main
 * thread does not collect a queue of work it will run late.
 */
static void
mondrian_cc_gestures_pass(void)
{
	if (mondrian_cc_pass_pending != 0) {
		return;
	}
	mondrian_cc_pass_pending = 1;
	dispatch_async(dispatch_get_main_queue(), ^{
		mondrian_cc_main_pass();
		mondrian_cc_pass_pending = 0;
	});
}

static void *
mondrian_cc_gesture_thread(void *unused)
{
	(void)unused;

	/*
	 * Forever, not for four minutes: the sheet builds new slider views every
	 * time it is opened, and they arrive with interaction off. A pass that
	 * stops leaves the next opening with a dead slider.
	 */
	for (;;) {
		sleep(1);
		mondrian_cc_gestures_pass();
	}
	return NULL;
}

static void
install_screen_size_hooks(void)
{
	Class cls = objc_getClass("UIScreen");
	unsigned i;
	pthread_t thread;

	if (cls == Nil) {
		return;
	}
	for (i = 0; i < MONDRIAN_SCREEN_ACCESSORS; i++) {
		Method m;
		SEL sel = sel_registerName(mondrian_screen_names[i]);

		m = class_getInstanceMethod(cls, sel);
		if (m == NULL) {
			continue;
		}
		mondrian_screen_imps[i].name = mondrian_screen_names[i];
		mondrian_screen_imps[i].orig = method_setImplementation(m,
		    (IMP)mondrian_screen_bounds_family);
		if (strcmp(mondrian_screen_names[i], "_referenceBounds") == 0) {
			mondrian_bl_orig_ref_bounds =
			    (CGRect (*)(id, SEL))mondrian_screen_imps[i].orig;
		}
		if (strcmp(mondrian_screen_names[i], "_unjailedReferenceBounds") == 0) {
			mondrian_bl_orig_unjailed =
			    (CGRect (*)(id, SEL))mondrian_screen_imps[i].orig;
		}
	}
	say("MONDRIAN UI: screen bounds family hooked\n");
	if (pthread_create(&thread, NULL, mondrian_screen_report_thread, NULL) != 0) {
		say("MONDRIAN UI: screen report thread failed\n");
	}
	if (boot_arg_set("mondriangeom=1")) {
		pthread_t geom;

		if (pthread_create(&geom, NULL, mondrian_geom_report_thread, NULL) != 0) {
			say("MONDRIAN UI: geometry thread failed\n");
		}
	}
	if (strcmp(getprogname(), "SpringBoard") == 0) {
		pthread_t cg;

		if (pthread_create(&cg, NULL, mondrian_cc_gesture_thread, NULL) != 0) {
			say("MONDRIAN UI: cc gesture thread failed\n");
		}
	}
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
	if (self.which == 0 && mondrian_link_ticks[0] <= 3) {
		char line[112];

		snprintf(line, sizeof(line),
		    "MONDRIAN UI: link tick %llu anim %d layer %d\n",
		    (unsigned long long)mondrian_link_ticks[0],
		    mondrian_anim_enabled, mondrian_probe_layer != nil);
		say(line);
	}
	/*
	 * `mondriananim=2`: the probe is moved from here, once per display-link
	 * tick, so every tick is a real commit from this client. `=1` leaves the
	 * move to a CoreAnimation animation, which the render server runs on its
	 * own; the two are different asks and the composite rate tells them apart.
	 */
	if (self.which == 0 && mondrian_anim_enabled == 2 &&
	    mondrian_probe_layer != nil &&
	    ((id (*)(id, SEL))objc_msgSend)(mondrian_probe_layer,
	    sel_registerName("superlayer")) != nil) {
		static double t;
		static unsigned told;
		double x;

		/*
		 * The move goes through -setFrame:, the same call the attach
		 * path uses. -setPosition: raises "unrecognized selector" on
		 * this runtime's layer even though the property exists, and an
		 * uncaught exception in a display-link callback kills
		 * SpringBoard, which is what the crash on leaving the lock
		 * screen was. Report what the receiver really is once.
		 */
		if (told++ == 0) {
			char line[192];
			Class cls = object_getClass(mondrian_probe_layer);

			snprintf(line, sizeof(line),
			    "MONDRIAN UI: probe layer %p class %s meta %d "
			    "setPosition %d setFrame %d\n", mondrian_probe_layer,
			    cls != Nil ? class_getName(cls) : "?",
			    cls != Nil && class_isMetaClass(cls),
			    ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
			    mondrian_probe_layer,
			    sel_registerName("respondsToSelector:"),
			    sel_registerName("setPosition:")),
			    ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
			    mondrian_probe_layer,
			    sel_registerName("respondsToSelector:"),
			    sel_registerName("setFrame:")));
			say(line);
		}
		t += 1.0 / 60.0;
		x = 60.0 + fmod(t * 480.0, 360.0);
		((void (*)(id, SEL, CGRect))objc_msgSend)(mondrian_probe_layer,
		    sel_registerName("setFrame"), CGRectMake(x, 200.0, 120.0,
		    120.0));
		mondrian_probe_moves++;
		if ((mondrian_probe_moves % 30) == 0) {
			char line[96];

			snprintf(line, sizeof(line),
			    "MONDRIAN UI: probe moves %u\n",
			    mondrian_probe_moves);
			say(line);
		}
	}
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
	if (dladdr((void *)addr, &info) != 0) {
		if (info.dli_sname != NULL &&
		    strcmp(info.dli_sname, "<redacted>") != 0) {
			snprintf(out, size, "%s+%ld", info.dli_sname,
			    (long)((char *)addr - (char *)info.dli_saddr));
			return;
		}
		/*
		 * The shared cache ships no symbols, and dyld answers with the
		 * literal "<redacted>": name the image and the offset instead,
		 * which is what says who is waiting inside mach_msg.
		 */
		if (info.dli_fname != NULL) {
			const char *base = strrchr(info.dli_fname, '/');

			snprintf(out, size, "%s+0x%llx",
			    base != NULL ? base + 1 : info.dli_fname,
			    (unsigned long long)(addr -
			    (uint64_t)(uintptr_t)info.dli_fbase));
			return;
		}
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
		char line[640], f[8][76];
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
		for (int i = 2; i < 8 && fp >= 0x100000000ULL; i++) {
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

/*
 * Boot-arg mondrianbdt=1 (every process) or mondrianbdtpid=<pid> (that one):
 * every thread of the process with a frame chain each, six samples two seconds
 * apart. The compositor draws one frame every five seconds and calls none of
 * the framebuffer's selectors in between, so the thread that owns that period
 * is the one that says what the period is: a mach_msg with a five second
 * timeout reads differently from a semaphore that a fence never signals, and
 * from a thread that is not scheduled at all.
 */
/*
 * The dyld cache ships no symbols, so a stuck thread reads as
 * "FrontBoard+0x1fad4". The class and method lists are in memory, though:
 * every Objective-C method knows its IMP, so sorting the IMPs of the image
 * turns the offset into the method that contains it. That is enough to name
 * the lock the launch is waiting on.
 */
struct mondrian_method_span {
	uint64_t off;
	char name[160];
};

static void mondrian_probe_fmt(const char *fmt, ...);

static int
mondrian_method_span_cmp(const void *pa, const void *pb)
{
	const struct mondrian_method_span *a = pa, *b = pb;

	return a->off < b->off ? -1 : (a->off > b->off ? 1 : 0);
}

static void
mondrian_symbolicate_pc(uint64_t pc, const char *tag)
{
	struct mondrian_method_span *spans = NULL;
	Class *classes = NULL;
	Dl_info info;
	int num, n = 0, cap = 0;
	uint64_t off, base;

	if (pc == 0 || dladdr((void *)pc, &info) == 0 || info.dli_fbase == NULL) {
		return;
	}
	base = (uint64_t)(uintptr_t)info.dli_fbase;
	off = pc - base;
	num = objc_getClassList(NULL, 0);
	if (num <= 0) {
		return;
	}
	classes = malloc(sizeof(Class) * (size_t)num);
	if (classes == NULL) {
		return;
	}
	num = objc_getClassList(classes, num);
	cap = num * 6 + 256;
	spans = malloc(sizeof(*spans) * (size_t)cap);
	if (spans == NULL) {
		free(classes);
		return;
	}
	for (int i = 0; i < num && n < cap; i++) {
		Class cls = classes[i];
		const char *image = class_getImageName(cls);
		const char *want = strrchr(info.dli_fname, '/');
		const char *have = image != NULL ? strrchr(image, '/') : NULL;

		/*
		 * Only the target image's classes can own one of its offsets.
		 * class_getImageName is not always the full path dladdr returns,
		 * so compare the last component.
		 */
		want = want != NULL ? want + 1 : info.dli_fname;
		have = have != NULL ? have + 1 : image;
		if (have == NULL || strcmp(have, want) != 0) {
			continue;
		}

		for (int meta = 0; meta < 2 && n < cap; meta++) {
			Class target = meta ? object_getClass((id)cls) : cls;
			unsigned mc = 0;
			Method *methods = class_copyMethodList(target, &mc);

			if (methods == NULL) {
				continue;
			}
			for (unsigned k = 0; k < mc && n < cap; k++) {
				IMP imp = method_getImplementation(methods[k]);
				Dl_info mi;

				if (dladdr((void *)imp, &mi) == 0 ||
				    mi.dli_fbase != info.dli_fbase) {
					continue;
				}
				spans[n].off = (uint64_t)(uintptr_t)imp - base;
				snprintf(spans[n].name, sizeof(spans[n].name),
				    "%s[%s %s]", meta ? "+" : "-",
				    class_getName(cls),
				    sel_getName(method_getName(methods[k])));
				n++;
			}
			free(methods);
		}
	}
	free(classes);
	if (n <= 0) {
		const char *name = strrchr(info.dli_fname, '/');

		mondrian_probe_fmt(
		    "MONDRIAN SYM[%d]: %s %s+0x%llx -> no classes in that image (%d scanned)\n",
		    getpid(), tag, name != NULL ? name + 1 : info.dli_fname,
		    (unsigned long long)off, num);
		free(spans);
		return;
	}
	qsort(spans, (size_t)n, sizeof(*spans), mondrian_method_span_cmp);
	{
		int lo = 0, hi = n - 1, best = -1;

		while (lo <= hi) {
			int mid = (lo + hi) / 2;

			if (spans[mid].off <= off) {
				best = mid;
				lo = mid + 1;
			} else {
				hi = mid - 1;
			}
		}
		if (best >= 0) {
			const char *name = strrchr(info.dli_fname, '/');

			mondrian_probe_fmt(
			    "MONDRIAN SYM[%d]: %s %s+0x%llx -> %s+0x%llx\n",
			    getpid(), tag,
			    name != NULL ? name + 1 : info.dli_fname,
			    (unsigned long long)off, spans[best].name,
			    (unsigned long long)(off - spans[best].off));
		} else {
			const char *name = strrchr(info.dli_fname, '/');

			mondrian_probe_fmt(
			    "MONDRIAN SYM[%d]: %s %s+0x%llx -> no method below (%d)\n",
			    getpid(), tag,
			    name != NULL ? name + 1 : info.dli_fname,
			    (unsigned long long)off, n);
		}
	}
	free(spans);
}

static void
mondrian_dump_threads(const char *tag)
{
	thread_act_array_t list = NULL;
	mach_msg_type_number_t count = 0;
	char head[96];

	if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS ||
	    list == NULL) {
		return;
	}
	snprintf(head, sizeof(head), "MONDRIAN THR[%d]: %s, %u threads\n",
	    getpid(), tag, (unsigned)count);
	say(head);
	for (mach_msg_type_number_t i = 0; i < count; i++) {
		arm_thread_state64_t state;
		mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
		thread_identifier_info_data_t id;
		mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
		/*
		 * Six frames were not enough to tell a thread that waits on a
		 * lock from the thread that took it: the outer launch frames
		 * sit below the six that were dumped. Walk deep enough to see
		 * a second acquisition of the same lock on the same thread.
		 */
		char line[1600], f[16][80];
		uint64_t fp, addrs[16];
		int used = 2;

		memset(&id, 0, sizeof(id));
		if (thread_get_state(list[i], ARM_THREAD_STATE64,
		    (thread_state_t)&state, &sc) != KERN_SUCCESS) {
			mach_port_deallocate(mach_task_self(), list[i]);
			continue;
		}
		mondrian_main_frame(state.__pc, f[0], sizeof(f[0]));
		mondrian_main_frame(state.__lr, f[1], sizeof(f[1]));
		addrs[0] = state.__pc;
		addrs[1] = state.__lr;
		fp = state.__fp;
		for (int k = 2; k < 16 && fp >= 0x100000000ULL; k++) {
			uint64_t frame[2];
			vm_size_t got = 0;

			if (vm_read_overwrite(mach_task_self(),
			    (vm_address_t)fp, sizeof(frame),
			    (vm_address_t)frame, &got) != KERN_SUCCESS ||
			    got != sizeof(frame) || frame[1] == 0) {
				break;
			}
			mondrian_main_frame(frame[1], f[k], sizeof(f[k]));
			addrs[k] = frame[1];
			used = k + 1;
			fp = frame[0];
		}
		(void)thread_info(list[i], THREAD_IDENTIFIER_INFO,
		    (thread_info_t)&id, &ic);
		{
			char *p = line;
			size_t left = sizeof(line);
			int k = snprintf(p, left, "MONDRIAN THR[%d]: t %llu",
			    getpid(), (unsigned long long)id.thread_id);

			p += k;
			left -= (size_t)k;
			for (int j = 0; j < used && left > 8; j++) {
				k = snprintf(p, left, " %s", f[j]);
				p += k;
				left -= (size_t)k;
			}
			snprintf(p, left, "\n");
		}
		say(line);
		/*
		 * A thread parked on a lock is the interesting one: name the
		 * method that owns the wait so the deadlock has an owner. A
		 * thread already inside FrontBoard is the other candidate for
		 * the owner of that lock, so it gets named too.
		 */
		{
			int front = 0;

			for (int j = 0; j < used; j++) {
				if (strstr(f[j], "FrontBoard") != NULL) {
					front = 1;
				}
			}
			if (front || strstr(f[0], "__ulock_wait") != NULL ||
			    strstr(f[0], "semaphore_wait") != NULL) {
				for (int j = 1; j < used; j++) {
					mondrian_symbolicate_pc(addrs[j], tag);
				}
			}
		}
		mach_port_deallocate(mach_task_self(), list[i]);
	}
	vm_deallocate(mach_task_self(), (vm_address_t)list,
	    count * sizeof(*list));
}

static void *
mondrian_threads_watch(void *unused)
{
	(void)unused;
	/*
	 * The first sample waits for the UI to settle; the rest follow it. An
	 * app that never finishes booting starts hanging early, and FrontBoard
	 * may kill it before a daemon-length wait ends, so an app gets its
	 * first dump much sooner. runningboardd is the process on trial for a
	 * launch that never spawns, so it is sampled across the whole window
	 * in which the request arrives.
	 */
	int settle = 100, rounds = 4, gap = 2;

	if (strcmp(getprogname(), "runningboardd") == 0 ||
	    strcmp(getprogname(), "launchd") == 0) {
		/*
		 * The spawn request arrives when an app is asked for, not at a
		 * fixed time, so these two are sampled across the whole window in
		 * which a launch happens: launchd because it is the last link,
		 * runningboardd because it waits on it.
		 */
		settle = 20;
		rounds = 40;
		gap = 10;
	} else if (strcmp(getprogname(), "SpringBoard") != 0 &&
	    strcmp(getprogname(), "backboardd") != 0) {
		settle = 25;
	}
	for (int n = 0; n < rounds; n++) {
		sleep(n == 0 ? settle : gap);
		mondrian_dump_threads("sample");
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

	if (!boot_arg_set("mondrianlink=1") &&
	    boot_arg_int("mondriananim=", 0) != 2) {
		return;
	}
	/*
	 * The unlock thread sets this at its own pace and this runs before it
	 * may have, so the one boot argument both tests reads here is repeated:
	 * without it the link is armed for a probe that the tick still refuses
	 * to move (measured: no `probe moves` line at all).
	 */
	if (boot_arg_int("mondriananim=", 0) == 2) {
		mondrian_anim_enabled = 2;
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
	if (boot_arg_set("mondrianlink=1")) {
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
}

/*
 * The root volume is HFS+ with no journal, and this port's bring-up habit is
 * the hard reset, which leaves metadata half written: measured, the live
 * volume grew files whose catalog entry claims data but owns no allocated
 * blocks, and the kernel then refuses every open of them. One of those was
 * what launchd_cache_loader reads to validate the dyld shared cache, and the
 * agents that could not be started went with it. A pristine copy of the same
 * image passes fsck_hfs and holds no such file, so the damage is what the
 * resets write, not what the image shipped.
 *
 * This turns journaling on the way hfs.util does: two files at the volume root,
 * then the HFS vfs sysctl that adopts them. The sysctl validates both block
 * numbers before it writes anything, so a wrong guess is refused, not applied.
 * It runs once per volume; afterwards the mount reports MNT_JOURNALED.
 */
#define MONDRIAN_HFS_ENABLE_JOURNALING  0x082969
#define MONDRIAN_HFS_DISABLE_JOURNALING 0x031272
#define MONDRIAN_JOURNAL_BYTES          (8 * 1024 * 1024)
#ifndef CTL_VFS
#define CTL_VFS                         5
#endif
#ifndef VFS_GENERIC
#define VFS_GENERIC                     1
#endif

static void
mondrian_jnl_log(const char *fmt, ...)
{
	char line[160];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	say(line);
}

static long
mondrian_device_block(int fd, off_t size, off_t block)
{
	struct log2phys l2p;

	memset(&l2p, 0, sizeof(l2p));
	l2p.l2p_devoffset = 0;
	l2p.l2p_contigbytes = size;
	if (fcntl(fd, F_LOG2PHYS_EXT, &l2p) != 0) {
		return -1;
	}
	if (l2p.l2p_contigbytes < size) {
		return -2;              /* fragmented: unusable as a journal */
	}
	return (long)(l2p.l2p_devoffset / block);
}

static void *
mondrian_journal_thread(void *unused)
{
	struct statfs sfs;
	struct vfsconf vfsconf;
	char *zero;
	int jnl_fd, jib_fd, mib[6], error;
	long block, jnl_start, jib_start;
	off_t done;

	(void)unused;
	if (geteuid() != 0 || statfs("/", &sfs) != 0) {
		return NULL;
	}
	/*
	 * Booting with mondriannojnl=1 leaves the journal closed (hfsmp->jnl
	 * is NULL), and the disable-journal sysctl calls journal_close() on it
	 * without a NULL check, so it panics the kernel: measured, that boot
	 * never brought USB up. The volume keeps its journal bit and every
	 * boot ignores it; the bit is not worth a panic to clear.
	 */

	if (sfs.f_flags & MNT_JOURNALED) {
		say("MONDRIAN JNL: volume already journaled\n");
		return NULL;
	}
	block = sfs.f_bsize;
	if (block < 512 || chdir("/") != 0) {
		return NULL;
	}
	(void)unlink("/.journal");
	(void)unlink("/.journal_info_block");
	zero = calloc(1, (size_t)block);
	if (zero == NULL) {
		return NULL;
	}

	jnl_fd = open("/.journal", O_CREAT | O_RDWR | O_TRUNC, 0600);
	if (jnl_fd < 0) {
		mondrian_jnl_log("MONDRIAN JNL: create failed errno %d\n", errno);
		free(zero);
		return NULL;
	}
	for (done = 0; done < MONDRIAN_JOURNAL_BYTES; done += block) {
		if (write(jnl_fd, zero, (size_t)block) != (ssize_t)block) {
			break;
		}
	}
	(void)fsync(jnl_fd);
	jnl_start = mondrian_device_block(jnl_fd,
	    (off_t)MONDRIAN_JOURNAL_BYTES, block);
	if (jnl_start < 0) {
		mondrian_jnl_log("MONDRIAN JNL: journal unusable (%ld)\n", jnl_start);
		close(jnl_fd);
		(void)unlink("/.journal");
		free(zero);
		return NULL;
	}

	jib_fd = open("/.journal_info_block", O_CREAT | O_RDWR | O_TRUNC, 0600);
	if (jib_fd < 0 || write(jib_fd, zero, (size_t)block) != (ssize_t)block) {
		mondrian_jnl_log("MONDRIAN JNL: info block failed errno %d\n", errno);
		if (jib_fd >= 0) {
			close(jib_fd);
			(void)unlink("/.journal_info_block");
		}
		close(jnl_fd);
		(void)unlink("/.journal");
		free(zero);
		return NULL;
	}
	(void)fsync(jib_fd);
	jib_start = mondrian_device_block(jib_fd, (off_t)block, block);
	free(zero);
	if (jib_start < 0) {
		mondrian_jnl_log("MONDRIAN JNL: info block unusable (%ld)\n", jib_start);
		close(jib_fd);
		close(jnl_fd);
		return NULL;
	}

	/*
	 * The HFS vfs sysctl hangs off the filesystem's own node, so the second
	 * element is the hfs type number, not VFS_GENERIC: with the generic one
	 * the lookup ends in ENOENT.
	 */
	memset(&vfsconf, 0, sizeof(vfsconf));
	if (getvfsbyname("hfs", &vfsconf) != 0) {
		mondrian_jnl_log("MONDRIAN JNL: hfs not registered errno %d\n",
		    errno);
		close(jib_fd);
		close(jnl_fd);
		return NULL;
	}
	mib[0] = CTL_VFS;
	mib[1] = vfsconf.vfc_typenum;
	mib[2] = MONDRIAN_HFS_ENABLE_JOURNALING;
	mib[3] = (int)jib_start;
	mib[4] = (int)jnl_start;
	mib[5] = MONDRIAN_JOURNAL_BYTES;
	error = sysctl(mib, 6, NULL, NULL, NULL, 0);
	if (error != 0) {
		mondrian_jnl_log("MONDRIAN JNL: enable failed errno %d\n", errno);
	} else {
		mondrian_jnl_log("MONDRIAN JNL: journal on %d bytes at block %ld\n",
		    MONDRIAN_JOURNAL_BYTES, jnl_start);
	}
	close(jib_fd);
	close(jnl_fd);
	return NULL;
}


/*
 * cfprefsd never runs on this port: launchd finishes early boot and starts its
 * run-at-load jobs, but the preferences daemon is demand launched, and nothing
 * starts it -- measured, the process never exists, and backboardd's main thread
 * then waits forever inside CoreFoundation's synchronous preferences call,
 * which is what keeps the compositor from drawing. This asks launchd to start
 * the job by name once, and reports what it answered, so the boot either shows
 * the daemon in the sampler or says why it did not.
 */
static void
mondrian_run(const char *what, char *const argv[])
{
	int status = -1;
	pid_t pid = fork();

	if (pid == 0) {
		execv(what, argv);
		_exit(127);
	}
	if (pid > 0 && waitpid(pid, &status, 0) == pid) {
		mondrian_jnl_log("MONDRIAN RESCUE: %s -> %d\n", argv[1] != NULL ?
		    argv[1] : what, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
	}
}

static void *
mondrian_rescue_thread(void *unused)
{
	struct stat st;
	char *kick[] = { "/bin/launchctl", "kickstart", "system/com.apple.cfprefsd",
	    NULL };
	char *print[] = { "/bin/launchctl", "print", "system/com.apple.cfprefsd",
	    NULL };

	(void)unused;
	if (geteuid() != 0) {
		return NULL;
	}
	mondrian_jnl_log("MONDRIAN RESCUE: env avoid-daemon %s\n",
	    getenv("__CFPREFERENCES_AVOID_DAEMON") != NULL ? "present" : "absent");
	if (stat("/System/Library/LaunchDaemons/com.apple.cfprefsd.plist",
	    &st) == 0) {
		mondrian_jnl_log("MONDRIAN RESCUE: cfprefsd.plist %lld bytes\n",
		    (long long)st.st_size);
	} else {
		mondrian_jnl_log("MONDRIAN RESCUE: no cfprefsd.plist errno %d\n",
		    errno);
	}
	sleep(6);
	mondrian_run("/bin/launchctl", print);
	mondrian_run("/bin/launchctl", kick);
	sleep(4);
	mondrian_jnl_log("MONDRIAN RESCUE: done\n");
	return NULL;
}


/* Is "name=<n>" in the kernel's boot arguments? */
static int
boot_arg_int(const char *name, int fallback)
{
	char args[2048];
	size_t size = sizeof(args);
	const char *at;
	char *end;
	long value;

	if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0 ||
	    size == 0) {
		return fallback;
	}
	args[sizeof(args) - 1] = 0;
	at = strstr(args, name);
	if (at == NULL) {
		return fallback;
	}
	at += __builtin_strlen(name);
	value = strtol(at, &end, 0);
	return end == at ? fallback : (int)value;
}

/*
 * The materials the home screen is built from are the ones that freeze it:
 * the dock's backdrop and the App Library's background both ask the render
 * server for a snapshot of the screen, and on this port that snapshot takes
 * seconds and comes back as garbage (a black dock, a striped App Library).
 * Reduce Transparency is the system's own switch for those materials; set it
 * before UIKit creates them and the blur is a flat colour instead.
 *
 * The preference is what AXSettings reads; the private setter is only called
 * if AccessibilityUtilities happens to be loaded already, because dlopen()ing
 * a framework inside SpringBoard's constructor is a good way to break a boot.
 */
static void
mondrian_ax_apply(int mask)
{
	Boolean exists = false;
	Boolean was;
	BOOL (*api)(void);
	int effective = -1;
	void (*setter)(Boolean);
	char line[176];

	was = CFPreferencesGetAppBooleanValue(CFSTR("ReduceTransparencyEnabled"),
	    CFSTR("com.apple.Accessibility"), &exists);
	CFPreferencesSetAppValue(CFSTR("ReduceTransparencyEnabled"),
	    (mask & 1) ? kCFBooleanTrue : kCFBooleanFalse,
	    CFSTR("com.apple.Accessibility"));
	(void)CFPreferencesAppSynchronize(CFSTR("com.apple.Accessibility"));
	setter = (void (*)(Boolean))dlsym(RTLD_DEFAULT,
	    "_AXSSetReduceTransparencyEnabled");
	if (setter != NULL) {
		setter((mask & 1) ? true : false);
	}
	api = (BOOL (*)(void))dlsym(RTLD_DEFAULT,
	    "UIAccessibilityIsReduceTransparencyEnabled");
	if (api != NULL) {
		effective = api();
	}
	snprintf(line, sizeof(line),
	    "MONDRIAN AX[%d]: transparency %d (was %d exists %d setter %d api %d)\n",
	    getpid(), mask & 1, was, (int)exists, setter != NULL, effective);
	say(line);
}

static void *
mondrian_ax_thread(void *arg)
{
	int mask = (int)(intptr_t)arg;

	sleep(5);
	mondrian_ax_apply(mask);
	sleep(15);
	mondrian_ax_apply(mask);
	return NULL;
}

/*
 * The iOS SDK trims <net/route.h>, so the routing-message layout is written
 * here. It is the stable ABI of route_output(): a fixed 84-byte header (the
 * rt_metrics block included) followed by the sockaddrs the rtm_addrs bits
 * name, in bit order.
 */
struct mondrian_rtmsg {
	struct {
		unsigned short msglen;
		unsigned char version;
		unsigned char type;
		unsigned short index;
		int flags;
		int addrs;
		int pid;
		int seq;
		int err;
		int use;
		unsigned int inits;
		struct {
			unsigned int locks;
			unsigned int mtu;
			unsigned int hopcount;
			int expire;
			unsigned int recvpipe;
			unsigned int sendpipe;
			unsigned int ssthresh;
			unsigned int rtt;
			unsigned int rttvar;
			unsigned int pksent;
			unsigned int state;
			unsigned int filler[3];
		} rmx;
	} hdr;
	struct sockaddr_in dst;
	struct sockaddr_in gw;
	struct sockaddr_in mask;
};

#define MONDRIAN_RTM_VERSION	5
#define MONDRIAN_RTM_ADD	0x1
#define MONDRIAN_RTA_DST	0x1
#define MONDRIAN_RTA_GATEWAY	0x2
#define MONDRIAN_RTA_NETMASK	0x4
#define MONDRIAN_RTF_UP		0x1
#define MONDRIAN_RTF_GATEWAY	0x2
#define MONDRIAN_RTF_STATIC	0x800

static const char *const mondrian_net_logs[] = {
	"/private/var/tmp/mondrian-net.txt",
	"/private/tmp/mondrian-net.txt",
};

static void
mondrian_net_note(const char *line)
{
	unsigned i;
	int wrote = 0;

	/*
	 * A root daemon's write to /dev/console stops reaching the ring once the
	 * UI owns the console (measured: the same process's constructor line is
	 * there, its 5 s thread line is not, while SpringBoard's thread lines
	 * are). So the line also goes to a file that SpringBoard relays into the
	 * ring, which is why it is readable in a dump.
	 */
	for (i = 0; i < sizeof(mondrian_net_logs) / sizeof(mondrian_net_logs[0]);
	    i++) {
		int f = open(mondrian_net_logs[i],
		    O_WRONLY | O_CREAT | O_APPEND, 0644);

		if (f >= 0) {
			(void)write(f, line, strlen(line));
			close(f);
			wrote = 1;
			break;
		}
	}
	(void)wrote;
	say(line);
}

/*
 * The USB link is an Ethernet interface with 192.168.7.2/24 and no default
 * route: the kernel sets the address for the debug channel and stops there.
 * Behind the host's NAT at 192.168.7.1 the phone reaches the Internet over
 * the cable, which is the only network a boot without WiFi or a modem has.
 * The route goes in from a process that is root (containermanagerd); the
 * resolver file is written too, and the two probes say whether the route
 * works and whether getaddrinfo gets an answer, which separates "no route"
 * from "no DNS" in one boot.
 */
static void
mondrian_net_setup(void)
{
	int s, err = 0;
	struct mondrian_rtmsg m;
	char line[128];
	int f;

	s = socket(PF_ROUTE, SOCK_RAW, 0);
	if (s < 0) {
		mondrian_net_note("MONDRIAN NET: no route socket\n");
	} else {
		bzero(&m, sizeof(m));
		m.hdr.msglen = sizeof(m);
		m.hdr.version = MONDRIAN_RTM_VERSION;
		m.hdr.type = MONDRIAN_RTM_ADD;
		m.hdr.flags = MONDRIAN_RTF_UP | MONDRIAN_RTF_GATEWAY |
		    MONDRIAN_RTF_STATIC;
		m.hdr.addrs = MONDRIAN_RTA_DST | MONDRIAN_RTA_GATEWAY |
		    MONDRIAN_RTA_NETMASK;
		m.hdr.seq = 1;
		m.dst.sin_len = sizeof(m.dst);
		m.dst.sin_family = AF_INET;
		m.dst.sin_addr.s_addr = htonl(0);               /* default */
		m.gw.sin_len = sizeof(m.gw);
		m.gw.sin_family = AF_INET;
		m.gw.sin_addr.s_addr = htonl(0xc0a80701);       /* .7.1 */
		m.mask.sin_len = sizeof(m.mask);
		m.mask.sin_family = AF_INET;
		m.mask.sin_addr.s_addr = htonl(0);
		if (write(s, &m, sizeof(m)) < 0) {
			err = errno;
		}
		close(s);
		snprintf(line, sizeof(line),
		    "MONDRIAN NET: default route 192.168.7.1 err %d\n", err);
		mondrian_net_note(line);
	}
	f = open("/etc/resolv.conf", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (f < 0) {
		f = open("/private/var/run/resolv.conf",
		    O_WRONLY | O_CREAT | O_TRUNC, 0644);
	}
	if (f >= 0) {
		static const char dns[] = "nameserver 1.1.1.1\n"
		    "nameserver 8.8.8.8\n";

		(void)write(f, dns, sizeof(dns) - 1);
		close(f);
		mondrian_net_note("MONDRIAN NET: resolv.conf written\n");
	} else {
		snprintf(line, sizeof(line), "MONDRIAN NET: no resolv.conf (%d)\n",
		    errno);
		mondrian_net_note(line);
	}
}

/*
 * iOS never reads /etc/resolv.conf: configd owns the resolver and hands it to
 * mDNSResponder through the dynamic store, and the same store tells CFNetwork
 * which interface is the primary one. A link configd did not create gets
 * neither -- it sees ue0's address but no service -- so the boot had TCP
 * (`tcp 1.1.1.1:80 err 0`, measured) and no name resolution (`getaddrinfo`
 * returned EAI_NONAME). Publish the service, its servers and the global
 * primary service; configd forwards them and mDNSResponder answers.
 *
 * The keys are the literal property names, so CFSTR works and no
 * SystemConfiguration symbol has to resolve at load time.
 */
static void
mondrian_net_publish(void)
{
	typedef const void *(*create_f)(CFAllocatorRef, CFStringRef, const void *,
	    const void *);
	typedef unsigned char (*set_f)(const void *, CFStringRef, const void *);
	void *handle;
	create_f create;
	set_f set_value;
	const void *store;
	CFMutableArrayRef addrs = NULL, masks = NULL, servers = NULL;
	CFMutableDictionaryRef service = NULL, dns = NULL, global = NULL;
	CFMutableDictionaryRef iface = NULL;
	unsigned ok = 0;

	handle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework"
	    "/SystemConfiguration", RTLD_LAZY);
	if (handle == NULL) {
		mondrian_net_note("MONDRIAN NET: no SystemConfiguration\n");
		return;
	}
	create = (create_f)dlsym(handle, "SCDynamicStoreCreate");
	set_value = (set_f)dlsym(handle, "SCDynamicStoreSetValue");
	if (create == NULL || set_value == NULL) {
		mondrian_net_note("MONDRIAN NET: no SCDynamicStore\n");
		return;
	}
	store = create(NULL, CFSTR("mondrian-net"), NULL, NULL);
	if (store == NULL) {
		mondrian_net_note("MONDRIAN NET: no dynamic store\n");
		return;
	}
	addrs = CFArrayCreateMutable(NULL, 1, &kCFTypeArrayCallBacks);
	masks = CFArrayCreateMutable(NULL, 1, &kCFTypeArrayCallBacks);
	servers = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
	service = CFDictionaryCreateMutable(NULL, 4, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	dns = CFDictionaryCreateMutable(NULL, 1, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	global = CFDictionaryCreateMutable(NULL, 3, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	iface = CFDictionaryCreateMutable(NULL, 3, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (addrs == NULL || masks == NULL || servers == NULL || service == NULL ||
	    dns == NULL || global == NULL || iface == NULL) {
		mondrian_net_note("MONDRIAN NET: no CF objects\n");
		return;
	}
	CFArrayAppendValue(addrs, CFSTR("192.168.7.2"));
	CFArrayAppendValue(masks, CFSTR("255.255.255.0"));
	CFArrayAppendValue(servers, CFSTR("1.1.1.1"));
	CFArrayAppendValue(servers, CFSTR("8.8.8.8"));

	CFDictionarySetValue(service, CFSTR("Addresses"), addrs);
	CFDictionarySetValue(service, CFSTR("SubnetMasks"), masks);
	CFDictionarySetValue(service, CFSTR("Router"), CFSTR("192.168.7.1"));
	CFDictionarySetValue(service, CFSTR("InterfaceName"), CFSTR("ue0"));
	CFDictionarySetValue(dns, CFSTR("ServerAddresses"), servers);
	CFDictionarySetValue(global, CFSTR("PrimaryService"),
	    CFSTR("mondrian-usb"));
	CFDictionarySetValue(global, CFSTR("PrimaryInterface"), CFSTR("ue0"));
	CFDictionarySetValue(global, CFSTR("Router"), CFSTR("192.168.7.1"));
	CFDictionarySetValue(iface, CFSTR("Addresses"), addrs);
	CFDictionarySetValue(iface, CFSTR("SubnetMasks"), masks);

	ok += set_value(store, CFSTR("State:/Network/Interface/ue0/IPv4"), iface);
	ok += set_value(store, CFSTR("State:/Network/Service/mondrian-usb/IPv4"),
	    service);
	ok += set_value(store, CFSTR("State:/Network/Service/mondrian-usb/DNS"),
	    dns);
	ok += set_value(store, CFSTR("State:/Network/Global/IPv4"), global);
	ok += set_value(store, CFSTR("State:/Network/Global/DNS"), dns);
	if (ok != 5) {
		char line[128];

		snprintf(line, sizeof(line), "MONDRIAN NET: store keys %u of 5\n",
		    ok);
		mondrian_net_note(line);
	}
}

/*
 * Does UDP leave the phone at all? A bare A query for example.com to
 * 1.1.1.1:53 separates "the resolver is not configured" from "port 53 is
 * filtered": 0 is NOERROR, 3 NXDOMAIN, -1 no reply.
 */
static int
mondrian_dns_query(void)
{
	static const char name[] = "example.com";
	unsigned char q[96], a[512];
	struct sockaddr_in to;
	struct timeval tv;
	fd_set rfds;
	size_t len = 12;
	const char *p = name;
	int s, n, rcode = -1;

	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) {
		return -2;
	}
	bzero(q, sizeof(q));
	q[0] = 0x12;
	q[1] = 0x34;
	q[2] = 0x01;                    /* recursion desired */
	q[5] = 0x01;                    /* one question */
	for (;;) {
		const char *dot = strchr(p, '.');
		size_t l = dot != NULL ? (size_t)(dot - p) : strlen(p);

		q[len++] = (unsigned char)l;
		memcpy(q + len, p, l);
		len += l;
		if (dot == NULL) {
			break;
		}
		p = dot + 1;
	}
	q[len++] = 0x00;                /* end of name */
	q[len++] = 0x00;
	q[len++] = 0x01;                /* type A */
	q[len++] = 0x00;
	q[len++] = 0x01;                /* class IN */

	bzero(&to, sizeof(to));
	to.sin_len = sizeof(to);
	to.sin_family = AF_INET;
	to.sin_port = htons(53);
	to.sin_addr.s_addr = htonl(0x01010101);
	if (sendto(s, q, len, 0, (struct sockaddr *)&to, sizeof(to)) < 0) {
		close(s);
		return -3;
	}
	FD_ZERO(&rfds);
	FD_SET(s, &rfds);
	tv.tv_sec = 3;
	tv.tv_usec = 0;
	if (select(s + 1, &rfds, NULL, NULL, &tv) == 1) {
		n = (int)recv(s, a, sizeof(a), 0);

		if (n >= 12 && a[0] == 0x12 && a[1] == 0x34) {
			rcode = a[3] & 0x0f;
		}
	}
	close(s);
	return rcode;
}

static int
mondrian_net_probe(void)
{
	struct sockaddr_in a;
	struct timeval tv;
	fd_set wfds;
	char line[128];
	int s, err = -1;

	s = socket(AF_INET, SOCK_STREAM, 0);
	if (s >= 0) {
		int rc;

		fcntl(s, F_SETFL, O_NONBLOCK);
		bzero(&a, sizeof(a));
		a.sin_len = sizeof(a);
		a.sin_family = AF_INET;
		a.sin_port = htons(80);
		a.sin_addr.s_addr = htonl(0x01010101);          /* 1.1.1.1 */
		rc = connect(s, (struct sockaddr *)&a, sizeof(a));
		if (rc == 0) {
			err = 0;
		} else if (errno == EINPROGRESS) {
			FD_ZERO(&wfds);
			FD_SET(s, &wfds);
			tv.tv_sec = 3;
			tv.tv_usec = 0;
			if (select(s + 1, NULL, &wfds, NULL, &tv) == 1) {
				socklen_t len = sizeof(err);

				(void)getsockopt(s, SOL_SOCKET, SO_ERROR, &err,
				    &len);
			} else {
				err = ETIMEDOUT;
			}
		} else {
			err = errno;
		}
		close(s);
	}
	snprintf(line, sizeof(line), "MONDRIAN NET: tcp 1.1.1.1:80 err %d\n", err);
	mondrian_net_note(line);
	{
		struct addrinfo hints, *res = NULL;
		int rc, udp;

		bzero(&hints, sizeof(hints));
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_STREAM;
		rc = getaddrinfo("example.com", "80", &hints, &res);
		udp = mondrian_dns_query();
		snprintf(line, sizeof(line),
		    "MONDRIAN NET: dns example.com rc %d udp %d\n", rc, udp);
		mondrian_net_note(line);
		if (res != NULL) {
			freeaddrinfo(res);
		}
		if (err == 0 && rc != 0) {
			err = 1;        /* names still unresolved */
		}
	}
	return err;
}

/*
 * The clock is right and the zone is not: with no location fix iOS keeps
 * Cupertino (UTC-8), so Madrid shows 02:24 when it is 11:24. The zone database
 * ships in the root; nothing selects one. Point the localtime symlink at
 * Europe/Madrid and let Foundation re-read it. Measured: the path the link
 * carries decides what the status bar prints, and NSTimeZone caches it until
 * `resetSystemTimeZone`.
 */
static void
mondrian_tz_set(void)
{
	static const char *const dirs[] = {
		"/var/db/timezone/zoneinfo",
		"/usr/share/zoneinfo",
	};
	char target[160], now[160], line[256];
	const char *dir = NULL;
	ssize_t n;
	unsigned i;

	for (i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		snprintf(target, sizeof(target), "%s/Europe/Madrid", dirs[i]);
		if (access(target, R_OK) == 0) {
			dir = dirs[i];
			break;
		}
	}
	n = readlink("/var/db/timezone/localtime", now, sizeof(now) - 1);
	now[n >= 0 ? (size_t)n : 0] = '\0';
	if (dir == NULL) {
		snprintf(line, sizeof(line),
		    "MONDRIAN TZ: no Europe/Madrid under timezone\n");
		mondrian_net_note(line);
		return;
	}
	if (strcmp(now, target) == 0) {
		return;
	}
	snprintf(line, sizeof(line), "MONDRIAN TZ: localtime %s -> %s\n",
	    n >= 0 ? now : "(none)", target);
	mondrian_net_note(line);
	(void)unlink("/private/var/db/timezone/localtime");
	(void)symlink(target, "/private/var/db/timezone/localtime");
}

/*
 * A Foundation that already read the old zone keeps it: the status bar is
 * formatted once per minute and would go on printing Cupertino.
 */
static void
mondrian_tz_announce(void)
{
	static const char name[] = "NSSystemTimeZoneDidChangeNotification";
	Class tz = objc_getClass("NSTimeZone");
	Class center_cls = objc_getClass("NSNotificationCenter");
	Class string_cls = objc_getClass("NSString");
	Method reset;
	id center, note;

	if (tz != Nil) {
		reset = class_getClassMethod(tz, sel_registerName("resetSystemTimeZone"));
		if (reset != NULL) {
			((void (*)(id, SEL))method_getImplementation(reset))((id)tz,
			    sel_registerName("resetSystemTimeZone"));
		}
	}
	if (center_cls == Nil || string_cls == Nil) {
		return;
	}
	center = ((id (*)(id, SEL))objc_msgSend)((id)center_cls,
	    sel_registerName("defaultCenter"));
	note = ((id (*)(id, SEL, const char *))objc_msgSend)((id)string_cls,
	    sel_registerName("stringWithUTF8String:"), name);
	if (center != nil && note != nil) {
		((void (*)(id, SEL, id, id))objc_msgSend)(center,
		    sel_registerName("postNotificationName:object:"), note, nil);
		say("MONDRIAN TZ: announced\n");
	}
}

static void
mondrian_net_relay_pass(void)
{
	static off_t offset;
	char buf[2048];
	ssize_t n;
	unsigned i;
	int f = -1;

	for (i = 0; i < sizeof(mondrian_net_logs) / sizeof(mondrian_net_logs[0]);
	    i++) {
		f = open(mondrian_net_logs[i], O_RDONLY);
		if (f >= 0) {
			break;
		}
	}
	if (f < 0) {
		return;
	}
	if (lseek(f, offset, SEEK_SET) < 0) {
		close(f);
		return;
	}
	n = read(f, buf, sizeof(buf) - 1);
	close(f);
	if (n <= 0) {
		return;
	}
	offset += n;
	buf[n] = '\0';
	say(buf);
}

static void *
mondrian_tz_thread(void *unused)
{
	int i;

	(void)unused;
	sleep(35);
	dispatch_async(dispatch_get_main_queue(), ^{
		mondrian_tz_announce();
	});
	/* Six minutes of relay covers the boot and the host's first attach. */
	for (i = 0; i < 60; i++) {
		sleep(6);
		mondrian_net_relay_pass();
	}
	return NULL;
}

static void *
mondrian_net_thread(void *unused)
{
	char line[128];
	int attempt, err = -1;

	(void)unused;

	sleep(5);
	if (geteuid() != 0) {
		return NULL;
	}
	snprintf(line, sizeof(line), "MONDRIAN NET: setup uid %d prog %s\n",
	    (int)geteuid(), getprogname());
	say(line);
	mondrian_tz_set();
	mondrian_net_setup();
	/*
	 * The link only exists once the host attaches the phone, which happens
	 * after the boot has finished, so one probe at startup says nothing.
	 * Probe again every 20 s until both TCP and DNS answer, and stop there:
	 * the first success is the answer and the lines stay in the ring.
	 */
	for (attempt = 0; attempt < 45; attempt++) {
		sleep(attempt == 0 ? 3 : 20);
		if (attempt % 4 == 0) {
			mondrian_net_publish();
		}
		err = mondrian_net_probe();
		if (err == 0) {
			break;
		}
	}
	return NULL;
}

/*
 * App launch probe.
 *
 * The last thing between the home screen and a usable phone is the launch
 * pipeline, and it fails where nothing is logged: SpringBoard shows the
 * snapshot and no app binary execs. This runs inside SpringBoard and answers
 * the whole chain in one boot -- the file itself, what LaunchServices thinks
 * of it, whether this process can exec it, what launchd's own log says, what
 * the workspace request returns, and which processes FrontBoard holds. Every
 * selector is guarded and the body is wrapped in @try: a probe that takes
 * SpringBoard down with it is worse than no probe.
 */
static void
mondrian_probe_fmt(const char *fmt, ...)
{
	char line[352];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	say(line);
}

/* -[obj selector] for a zero-argument object getter, nil when absent. */
static id
mondrian_probe_call(id object, const char *selector)
{
	SEL sel;

	if (object == nil) {
		return nil;
	}
	sel = sel_registerName(selector);
	if (![object respondsToSelector:sel]) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

/* +[Class selector] for a shared-instance style class getter. */
static id
mondrian_probe_class_call(const char *class_name, const char *selector)
{
	Class cls = objc_getClass(class_name);
	SEL sel;

	if (cls == Nil) {
		return nil;
	}
	sel = sel_registerName(selector);
	if (![cls respondsToSelector:sel]) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

/* A guarded BOOL getter: -1 when the receiver cannot answer. */
static int
mondrian_probe_bool(id object, const char *selector)
{
	SEL sel;

	if (object == nil) {
		return -1;
	}
	sel = sel_registerName(selector);
	if (![object respondsToSelector:sel]) {
		return -1;
	}
	return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel) ? 1 : 0;
}

static const char *
mondrian_probe_string(id object, const char *selector)
{
	id value = mondrian_probe_call(object, selector);

	if (value == nil) {
		return "-";
	}
	if ([value isKindOfClass:[NSString class]]) {
		return [value UTF8String];
	}
	if ([value respondsToSelector:@selector(absoluteString)]) {
		return [[value performSelector:@selector(absoluteString)] UTF8String];
	}
	return [[value description] UTF8String];
}

/* A guarded int getter (-[FBProcess pid] and friends): -1 when absent. */
static int
mondrian_probe_int(id object, const char *selector)
{
	SEL sel;

	if (object == nil) {
		return -1;
	}
	sel = sel_registerName(selector);
	if (![object respondsToSelector:sel]) {
		return -1;
	}
	return ((int (*)(id, SEL))objc_msgSend)(object, sel);
}

/*
 * launchd keeps its own log on the writable root. Reading it here is the only
 * way to see what launchd says about a spawn that never reaches the kernel's
 * exec path. The whole file is scanned: the interesting line is the app job's,
 * and the tail is full of commcenter lookup noise.
 */
static void
mondrian_probe_launchd_log(void)
{
	static const char path[] = "/private/var/log/com.apple.xpc.launchd/launchd.log";
	const char *inst[12], *app[12], *fail[16], *tail[15], *deny[16], *head[20];
	char *buf, *line, *next;
	int fd, got, i;
	int inst_n = 0, app_n = 0, fail_n = 0, tail_n = 0, deny_n = 0, head_n = 0;
	long size;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: launchd.log open errno %d\n", errno);
		return;
	}
	size = (long)lseek(fd, 0, SEEK_END);
	(void)lseek(fd, 0, SEEK_SET);
	if (size <= 0 || size > (16L * 1024 * 1024)) {
		(void)close(fd);
		mondrian_probe_fmt("MONDRIAN LAUNCH: launchd.log size %ld\n", size);
		return;
	}
	buf = malloc((size_t)size + 1);
	if (buf == NULL) {
		(void)close(fd);
		mondrian_probe_fmt("MONDRIAN LAUNCH: launchd.log no memory\n");
		return;
	}
	got = 0;
	while (got < size) {
		int n = (int)read(fd, buf + got, (size_t)(size - got));

		if (n <= 0) {
			break;
		}
		got += n;
	}
	(void)close(fd);
	buf[got] = '\0';

	line = buf;
	while (line != NULL && *line != '\0') {
		next = strchr(line, '\n');
		if (next != NULL) {
			*next++ = '\0';
		}
		tail[tail_n % 15] = line;
		tail_n++;
		if (head_n < 20) {
			head[head_n++] = line;
		}
		if (strstr(line, "installd") != NULL) {
			inst[inst_n % 12] = line;
			inst_n++;
		} else if (strstr(line, "UIKitApplication") != NULL ||
		    strstr(line, "Preferences") != NULL) {
			app[app_n % 12] = line;
			app_n++;
		} else if (strstr(line, "could not exec") != NULL ||
		    strstr(line, "Exited with code") != NULL ||
		    strstr(line, "Service only ran") != NULL ||
		    strstr(line, "failed to exec") != NULL ||
		    strstr(line, "unknown user") != NULL ||
		    strstr(line, "Sandbox") != NULL) {
			fail[fail_n % 16] = line;
			fail_n++;
		} else if (strstr(line, "denied") != NULL ||
		    strstr(line, "entitle") != NULL ||
		    strstr(line, "policy") != NULL ||
		    strstr(line, "not allowed") != NULL ||
		    strstr(line, "Invalid") != NULL ||
		    strstr(line, "invalid") != NULL) {
			deny[deny_n % 16] = line;
			deny_n++;
		}
		line = next;
	}
	mondrian_probe_fmt(
	    "MONDRIAN LAUNCH: log %ld bytes installd %d app %d fail %d deny %d\n",
	    size, inst_n, app_n, fail_n, deny_n);
	for (i = 0; i < head_n; i++) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: head | %s\n", head[i]);
	}
	for (i = inst_n > 12 ? inst_n - 12 : 0; i < inst_n; i++) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: ist | %s\n", inst[i % 12]);
	}
	for (i = app_n > 12 ? app_n - 12 : 0; i < app_n; i++) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: app | %s\n", app[i % 12]);
	}
	for (i = fail_n > 16 ? fail_n - 16 : 0; i < fail_n; i++) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: fail | %s\n", fail[i % 16]);
	}
	for (i = deny_n > 16 ? deny_n - 16 : 0; i < deny_n; i++) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: deny | %s\n", deny[i % 16]);
	}
	/* The raw tail: whatever launchd wrote last, unfiltered. */
	for (i = tail_n > 15 ? tail_n - 15 : 0; i < tail_n; i++) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: tail | %s\n", tail[i % 15]);
	}
	free(buf);
}

/* The whole process table, compact: this is how lsd/runningboardd are checked. */
static void
mondrian_probe_proclist(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	struct kinfo_proc *list;
	size_t size = 0;
	char line[320];
	size_t used = 0;
	int n, i, lines = 0;

	if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: proclist size errno %d\n", errno);
		return;
	}
	list = malloc(size);
	if (list == NULL) {
		return;
	}
	if (sysctl(mib, 4, list, &size, NULL, 0) != 0) {
		free(list);
		mondrian_probe_fmt("MONDRIAN LAUNCH: proclist read errno %d\n", errno);
		return;
	}
	n = (int)(size / sizeof(struct kinfo_proc));
	mondrian_probe_fmt("MONDRIAN LAUNCH: proclist %d\n", n);
	line[0] = '\0';
	for (i = 0; i < n; i++) {
		char entry[40];
		int len = snprintf(entry, sizeof(entry), "%s(%d) ",
		    list[i].kp_proc.p_comm, list[i].kp_proc.p_pid);

		if (len <= 0) {
			continue;
		}
		if (used + (size_t)len >= sizeof(line) - 1) {
			mondrian_probe_fmt("MONDRIAN LAUNCH: proc | %s\n", line);
			used = 0;
			line[0] = '\0';
			if (++lines >= 20) {
				break;
			}
		}
		memcpy(line + used, entry, (size_t)len);
		used += (size_t)len;
		line[used] = '\0';
	}
	if (used > 0 && lines < 20) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: proc | %s\n", line);
	}
	free(list);
}

/*
 * The launch path asks installd for the app and the daemon is absent from the
 * process table although its Mach service answers. The lookup above asks
 * launchd for it; this second answer, a direct spawn from a root process,
 * separates "launchd will not start it" from "the binary cannot run here".
 *
 * The same thread then asks for an app from outside SpringBoard: if a root
 * daemon's request also times out, the gap is below SpringBoard's state
 * machine; if it works, the request path is fine and SpringBoard is what
 * drops it.
 */
static void mondrian_probe_processes(const char *when);

/*
 * The launch call blocks for its whole timeout, and the interesting thread is
 * the one that is supposed to answer it, not this one. Sample every thread
 * while the caller is stuck so the frame that waits is on the record.
 */
static void *
mondrian_launch_sampler(void *unused)
{
	(void)unused;
	usleep(3000 * 1000);
	mondrian_dump_threads("launch wait");
	return NULL;
}

/*
 * One launch attempt through the public SpringBoardServices entry point, with
 * the error text and the time it took. Called from three processes: SpringBoard
 * (the path the icon uses), backboardd (a plain user-501 daemon) and
 * containermanagerd (root). The three answers say where the request dies.
 */
static void
mondrian_probe_app(const char *tag)
{
	static const char path[] = "/Applications/Preferences.app/Preferences";
	struct stat st;
	void *handle;

	if (stat(path, &st) == 0) {
		mondrian_probe_fmt("MONDRIAN APP[%s]: %lld bytes mode %o\n", tag,
		    (long long)st.st_size, (unsigned)(st.st_mode & 07777));
	}
	handle = dlopen(
	    "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
	    RTLD_LAZY);
	if (handle != NULL) {
		int (*launch)(CFStringRef, Boolean) = (int (*)(CFStringRef, Boolean))
		    dlsym(handle, "SBSLaunchApplicationWithIdentifier");
		CFStringRef (*errtxt)(int) = (CFStringRef (*)(int))
		    dlsym(handle, "SBSApplicationLaunchingErrorString");
		struct timeval before, after;

		/*
		 * The two services a launch waits on, asked in this process
		 * before the launch: LaunchServices (a bundle nobody has asked
		 * for yet, so the answer cannot be an in-process cache) and
		 * RunningBoard (a plain process handle). Whichever hangs names
		 * the layer that never answers.
		 */
		@try {
			Class proxy_cls = objc_getClass("LSApplicationProxy");
			id proxy = nil;

			(void)gettimeofday(&before, NULL);
			if (proxy_cls != Nil && [proxy_cls respondsToSelector:
			    @selector(applicationProxyForIdentifier:)]) {
				proxy = ((id (*)(id, SEL, id))objc_msgSend)(
				    (id)proxy_cls,
				    sel_registerName("applicationProxyForIdentifier:"),
				    @"com.apple.mobiletimer");
			}
			(void)gettimeofday(&after, NULL);
			mondrian_probe_fmt(
			    "MONDRIAN APP[%s]: lsd proxy %s %ld ms\n", tag,
			    proxy != nil ? "yes" : "nil",
			    (long)((after.tv_sec - before.tv_sec) * 1000 +
			    (after.tv_usec - before.tv_usec) / 1000));
		} @catch (id exception) {
			mondrian_probe_fmt("MONDRIAN APP[%s]: lsd probe raised\n", tag);
		}
		@try {
			Class ident_cls = (id)objc_getClass("RBSProcessIdentifier");
			Class hcls = (id)objc_getClass("RBSProcessHandle");
			id ident = nil, rhandle = nil;
			NSError *rerr = nil;

			(void)gettimeofday(&before, NULL);
			if (ident_cls != nil && [ident_cls respondsToSelector:
			    @selector(identifierWithPid:)]) {
				ident = ((id (*)(id, SEL, int))objc_msgSend)(
				    ident_cls, sel_registerName("identifierWithPid:"),
				    (int)getpid());
			}
			if (hcls != nil && ident != nil && [hcls respondsToSelector:
			    @selector(handleForIdentifier:error:)]) {
				rhandle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
				    hcls, sel_registerName("handleForIdentifier:error:"),
				    ident, &rerr);
			}
			(void)gettimeofday(&after, NULL);
			mondrian_probe_fmt(
			    "MONDRIAN APP[%s]: rbs handle %s %ld ms error %s\n", tag,
			    rhandle != nil ? "yes" : "nil",
			    (long)((after.tv_sec - before.tv_sec) * 1000 +
			    (after.tv_usec - before.tv_usec) / 1000),
			    rerr != nil ? [[rerr description] UTF8String] : "-");
		} @catch (id exception) {
			mondrian_probe_fmt("MONDRIAN APP[%s]: rbs probe raised\n", tag);
		}
		/*
		 * The handle above may come from RBSConnection's cache. A pid that
		 * cannot exist must go to runningboardd, so this one says whether
		 * the server answers at all.
		 */
		@try {
			Class ident_cls = (id)objc_getClass("RBSProcessIdentifier");
			Class hcls = (id)objc_getClass("RBSProcessHandle");
			id ident = nil, ghost = nil;
			NSError *gerr = nil;

			(void)gettimeofday(&before, NULL);
			if (ident_cls != nil && [ident_cls respondsToSelector:
			    @selector(identifierWithPid:)]) {
				ident = ((id (*)(id, SEL, int))objc_msgSend)(
				    ident_cls, sel_registerName("identifierWithPid:"),
				    99999);
			}
			if (hcls != nil && ident != nil && [hcls respondsToSelector:
			    @selector(handleForIdentifier:error:)]) {
				ghost = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
				    hcls, sel_registerName("handleForIdentifier:error:"),
				    ident, &gerr);
			}
			(void)gettimeofday(&after, NULL);
			mondrian_probe_fmt(
			    "MONDRIAN APP[%s]: rbs ghost %s %ld ms error %s\n", tag,
			    ghost != nil ? "yes" : "nil",
			    (long)((after.tv_sec - before.tv_sec) * 1000 +
			    (after.tv_usec - before.tv_usec) / 1000),
			    gerr != nil ? [[gerr description] UTF8String] : "-");
		} @catch (id exception) {
			mondrian_probe_fmt("MONDRIAN APP[%s]: rbs ghost raised\n", tag);
		}
		/*
		 * The app's data container is the one dependency left that a launch
		 * cannot skip: containermanagerd is asked before the spawn. The
		 * proxy answers this from the daemon, not from its own cache.
		 */
		@try {
			Class proxy_cls = objc_getClass("LSApplicationProxy");
			id proxy = nil;

			if (proxy_cls != Nil && [proxy_cls respondsToSelector:
			    @selector(applicationProxyForIdentifier:)]) {
				proxy = ((id (*)(id, SEL, id))objc_msgSend)(
				    (id)proxy_cls,
				    sel_registerName("applicationProxyForIdentifier:"),
				    @"com.apple.Preferences");
			}
			if (proxy != nil && [proxy respondsToSelector:
			    @selector(dataContainerURL)]) {
				id url = nil;

				(void)gettimeofday(&before, NULL);
				url = ((id (*)(id, SEL))objc_msgSend)(proxy,
				    sel_registerName("dataContainerURL"));
				(void)gettimeofday(&after, NULL);
				mondrian_probe_fmt(
				    "MONDRIAN APP[%s]: container url %s %ld ms %s\n",
				    tag, url != nil ? "yes" : "nil",
				    (long)((after.tv_sec - before.tv_sec) * 1000 +
				    (after.tv_usec - before.tv_usec) / 1000),
				    url != nil ? [[url description] UTF8String] : "-");
			} else {
				mondrian_probe_fmt(
				    "MONDRIAN APP[%s]: container url api missing\n", tag);
			}
		} @catch (id exception) {
			mondrian_probe_fmt("MONDRIAN APP[%s]: container url raised\n", tag);
		}
		if (launch != NULL) {
			int lrc;
			char message[192];
			pthread_t sampler;

			/* Dump the process' threads while this call is blocked. */
			if (pthread_create(&sampler, NULL, mondrian_launch_sampler,
			    NULL) == 0) {
				pthread_detach(sampler);
			}
			(void)gettimeofday(&before, NULL);
			errno = 0;
			lrc = launch(CFSTR("com.apple.Preferences"), false);
			(void)gettimeofday(&after, NULL);
			message[0] = '\0';
			if (errtxt != NULL && lrc != 0) {
				CFStringRef text = errtxt(lrc);

				if (text != NULL) {
					(void)CFStringGetCString(text, message,
					    sizeof(message), kCFStringEncodingUTF8);
				}
			}
			mondrian_probe_fmt(
			    "MONDRIAN APP[%s]: SBSLaunch rc %d errno %d %ld ms -> %s\n",
			    tag, lrc, errno,
			    (long)((after.tv_sec - before.tv_sec) * 1000 +
			    (after.tv_usec - before.tv_usec) / 1000),
			    message[0] != '\0' ? message : "-");
		} else {
			mondrian_probe_fmt("MONDRIAN APP[%s]: no symbol\n", tag);
		}
	} else {
		mondrian_probe_fmt("MONDRIAN APP[%s]: no framework\n", tag);
	}
	sleep(2);
	mondrian_probe_processes(tag);
}

/*
 * Name an offset inside a binary on the device. A thread dumped from another
 * process prints as `<image>+0x<offset>` because the frame walk only has
 * addresses, and an offset below the lowest Objective-C method (launchd+0x5898)
 * has no name at all. The binary carries a symbol table even when nothing else
 * can name it: read it here and print the nearest symbol below the offset.
 */
static void
mondrian_symbol_file(const char *path, uint64_t off)
{
	struct mach_header_64 *hdr;
	struct load_command *cmd;
	struct symtab_command *sym = NULL;
	uint64_t text_vmaddr = 0;
	struct nlist_64 *nl;
	const char *strs;
	const char *best = NULL;
	uint64_t best_val = 0, want;
	struct stat st;
	void *map;
	int fd;

	fd = open(path, O_RDONLY);
	if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(*hdr)) {
		if (fd >= 0) {
			close(fd);
		}
		mondrian_probe_fmt("MONDRIAN SYMFILE: %s unreadable\n", path);
		return;
	}
	map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (map == MAP_FAILED) {
		mondrian_probe_fmt("MONDRIAN SYMFILE: %s map failed\n", path);
		return;
	}
	hdr = (struct mach_header_64 *)map;
	if (hdr->magic != MH_MAGIC_64) {
		mondrian_probe_fmt("MONDRIAN SYMFILE: %s not a 64-bit Mach-O\n", path);
		munmap(map, (size_t)st.st_size);
		return;
	}
	cmd = (struct load_command *)((char *)map + sizeof(*hdr));
	for (uint32_t i = 0; i < hdr->ncmds; i++) {
		if (cmd->cmd == LC_SEGMENT_64) {
			struct segment_command_64 *seg = (struct segment_command_64 *)cmd;

			if (strcmp(seg->segname, "__TEXT") == 0) {
				text_vmaddr = seg->vmaddr;
			}
		} else if (cmd->cmd == LC_SYMTAB) {
			sym = (struct symtab_command *)cmd;
		}
		if (cmd->cmdsize == 0) {
			break;
		}
		cmd = (struct load_command *)((char *)cmd + cmd->cmdsize);
	}
	if (sym == NULL || sym->symoff == 0 || sym->nsyms == 0) {
		mondrian_probe_fmt("MONDRIAN SYMFILE: %s has no symbol table\n", path);
		munmap(map, (size_t)st.st_size);
		return;
	}
	want = text_vmaddr + off;
	nl = (struct nlist_64 *)((char *)map + sym->symoff);
	strs = (char *)map + sym->stroff;
	for (uint32_t i = 0; i < sym->nsyms; i++) {
		const char *name;

		if ((nl[i].n_type & 0x0e) != 0x0e || nl[i].n_un.n_strx == 0 ||
		    nl[i].n_value == 0 || nl[i].n_value > want) {
			continue;
		}
		if (nl[i].n_value < best_val) {
			continue;
		}
		name = strs + nl[i].n_un.n_strx;
		/*
		 * Every C symbol in a Mach-O starts with '_', so only an empty
		 * name is filtered here: skipping the underscore hid launchd's
		 * whole symbol table.
		 */
		if (name[0] == '\0') {
			continue;
		}
		best = name;
		best_val = nl[i].n_value;
	}
	if (best != NULL) {
		char line[224];

		snprintf(line, sizeof(line),
		    "MONDRIAN SYMFILE: %s+0x%llx -> %s+0x%llx\n", path,
		    (unsigned long long)off, best,
		    (unsigned long long)(want - best_val));
		say(line);
	} else {
		mondrian_probe_fmt(
		    "MONDRIAN SYMFILE: %s+0x%llx -> no symbol below\n", path,
		    (unsigned long long)off);
	}
	munmap(map, (size_t)st.st_size);
}

static void *
mondrian_symbol_probe(void *unused)
{
	int off = boot_arg_int("mondriansym=", 0);

	(void)unused;
	if (off <= 0) {
		return NULL;
	}
	sleep(60);
	mondrian_symbol_file("/sbin/launchd", (uint64_t)off);
	return NULL;
}

static void *
mondrian_launchctl_test(void *unused)
{
	char *argv[] = { (char *)"launchctl", (char *)"list", NULL };
	extern char **environ;
	posix_spawn_file_actions_t actions;
	int out, rc, status = 0;
	pid_t pid = 0;

	(void)unused;
	sleep(90);
	/*
	 * runningboardd waits on launchd's job API and launchd looks idle, so the
	 * question is whether that API answers at all from another client. The
	 * console is where the answer lands: stdout goes to /dev/console, which the
	 * kernel copies into the ring, and a call that hangs leaves no status.
	 */
	out = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (out < 0) {
		say("MONDRIAN LAUNCHCTL: no console\n");
		return NULL;
	}
	if (posix_spawn_file_actions_init(&actions) != 0) {
		close(out);
		return NULL;
	}
	(void)posix_spawn_file_actions_adddup2(&actions, out, STDOUT_FILENO);
	(void)posix_spawn_file_actions_adddup2(&actions, out, STDERR_FILENO);
	say("MONDRIAN LAUNCHCTL: list start\n");
	errno = 0;
	rc = posix_spawn(&pid, "/bin/launchctl", &actions, NULL, argv, environ);
	mondrian_probe_fmt("MONDRIAN LAUNCHCTL: spawn rc %d errno %d pid %d\n",
	    rc, errno, (int)pid);
	posix_spawn_file_actions_destroy(&actions);
	close(out);
	if (rc == 0) {
		(void)waitpid(pid, &status, 0);
		mondrian_probe_fmt("MONDRIAN LAUNCHCTL: list done status 0x%x\n",
		    status);
	}
	return NULL;
}

static void *
mondrian_installd_test(void *unused)
{
	char *argv[] = { (char *)"installd", NULL };
	extern char **environ;
	pid_t pid = 0;
	int rc;

	(void)unused;
	sleep(40);
	errno = 0;
	rc = posix_spawn(&pid, "/usr/libexec/installd", NULL, NULL, argv, environ);
	mondrian_probe_fmt("MONDRIAN INSTALLD: posix_spawn rc %d errno %d pid %d\n",
	    rc, errno, (int)pid);
	sleep(3);
	mondrian_probe_proclist();
	mondrian_probe_app("root");
	return NULL;
}

/*
 * backboardd runs as the mobile user and is not SpringBoard. Its launch answer
 * is the control for "FrontBoard refuses this requestor" against "the launch
 * path is broken for every requestor".
 */
static void *
mondrian_backboard_probe(void *unused)
{
	(void)unused;
	sleep(100);
	mondrian_probe_app("backboardd");
	return NULL;
}

/* FrontBoard's live process set, one line per process, capped. */
static void
mondrian_probe_processes(const char *when)
{
	id manager = nil;
	id all;
	Class cls = objc_getClass("FBProcessManager");

	if (cls != Nil && [cls respondsToSelector:@selector(sharedInstance)]) {
		manager = ((id (*)(id, SEL))objc_msgSend)((id)cls,
		    sel_registerName("sharedInstance"));
	}
	all = mondrian_probe_call(manager, "allProcesses");
	mondrian_probe_fmt("MONDRIAN LAUNCH: %s processes %lu\n", when,
	    (unsigned long)(all != nil && [all respondsToSelector:@selector(count)] ?
	    [all count] : 0));
	if (all != nil && [all respondsToSelector:@selector(allObjects)]) {
		NSArray *list = [all performSelector:@selector(allObjects)];
		NSUInteger i, count = [list count];

		for (i = 0; i < count && i < 14; i++) {
			id process = [list objectAtIndex:i];

			mondrian_probe_fmt("MONDRIAN LAUNCH: %s proc %s pid %d\n", when,
			    mondrian_probe_string(process, "name"),
			    mondrian_probe_int(process, "pid"));
		}
	}
}

static void
mondrian_probe_launch(void)
{
	static const char path[] = "/Applications/Preferences.app/Preferences";
	struct stat st;
	unsigned char magic[4] = { 0, 0, 0, 0 };
	int opened, got, err, i;
	pid_t pid = 0;
	int rc, status = 0;

	@try {
		(void)stat(path, &st);
		mondrian_probe_fmt(
		    "MONDRIAN LAUNCH: file exists %d exec %d size %lld mode %o\n",
		    [[NSFileManager defaultManager] fileExistsAtPath:
		    [NSString stringWithUTF8String:path]] ? 1 : 0,
		    [[NSFileManager defaultManager] isExecutableFileAtPath:
		    [NSString stringWithUTF8String:path]] ? 1 : 0,
		    (long long)st.st_size, (unsigned)(st.st_mode & 07777));
		opened = open(path, O_RDONLY);
		err = errno;
		got = -1;
		if (opened >= 0) {
			got = (int)read(opened, magic, sizeof(magic));
			err = errno;
			(void)close(opened);
		}
		mondrian_probe_fmt(
		    "MONDRIAN LAUNCH: read open %d n %d errno %d magic %02x%02x%02x%02x\n",
		    opened >= 0 ? 1 : 0, got, err, magic[0], magic[1], magic[2],
		    magic[3]);
	} @catch (id exception) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: file probe raised\n");
	}

	@try {
		id lock_manager = mondrian_probe_class_call("SBLockScreenManager",
		    "sharedInstance");
		id lock_state = mondrian_probe_class_call("SBLockStateAggregator",
		    "sharedInstance");

		mondrian_probe_fmt("MONDRIAN LAUNCH: locked %d state %d\n",
		    mondrian_probe_bool(lock_manager, "isUILocked"),
		    mondrian_probe_int(lock_state, "lockState"));
	} @catch (id exception) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: lock probe raised\n");
	}

	/*
	 * Who answers. launchd starts an on-demand job when its Mach service is
	 * looked up, so the com.apple.mobile.installd entry both measures the
	 * service and asks launchd for the daemon the launch path is missing.
	 */
	{
		static const char *const names[] = {
			"com.apple.runningboard",
			"com.apple.mobile.installd",
			"com.apple.springboard.services",
			"com.apple.backboard.hid-services.xpc",
			"com.apple.backboard.system-app-server",
			"com.apple.iohideventsystem",
			"com.apple.frontboard.systemappservices",
		};
		unsigned i;

		for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
			mach_port_t port = MACH_PORT_NULL;
			kern_return_t kr = bootstrap_look_up(bootstrap_port,
			    names[i], &port);

			mondrian_probe_fmt(
			    "MONDRIAN LAUNCH: lookup %s kr %d port %u\n",
			    names[i], (int)kr, (unsigned)port);
			if (port != MACH_PORT_NULL) {
				(void)mach_port_deallocate(mach_task_self(), port);
			}
		}
	}

	/* RunningBoard's own query path, the one FrontBoard uses. */
	@try {
		id ident_cls = (id)objc_getClass("RBSProcessIdentifier");
		id handle_cls = (id)objc_getClass("RBSProcessHandle");
		id ident = nil;
		id handle = nil;
		NSError *rbs_error = nil;

		if (ident_cls != nil &&
		    [ident_cls respondsToSelector:@selector(identifierWithPid:)]) {
			ident = ((id (*)(id, SEL, int))objc_msgSend)(ident_cls,
			    sel_registerName("identifierWithPid:"), 26);
		}
		if (handle_cls != nil && ident != nil &&
		    [handle_cls respondsToSelector:
		    @selector(handleForIdentifier:error:)]) {
			handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
			    handle_cls, sel_registerName("handleForIdentifier:error:"),
			    ident, &rbs_error);
		}
		mondrian_probe_fmt("MONDRIAN LAUNCH: RBS handle %s error %s\n",
		    handle != nil ? "yes" : "nil",
		    rbs_error != nil ? [[rbs_error description] UTF8String] : "-");
	} @catch (id exception) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: RBS probe raised\n");
	}

	{
		Class proxy_cls = objc_getClass("LSApplicationProxy");
		id proxy = nil;

		if (proxy_cls != Nil &&
		    [proxy_cls respondsToSelector:
		    @selector(applicationProxyForIdentifier:)]) {
			proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxy_cls,
			    sel_registerName("applicationProxyForIdentifier:"),
			    @"com.apple.Preferences");
		}
		mondrian_probe_fmt(
		    "MONDRIAN LAUNCH: proxy %s installed %d placeholder %d type %s\n",
		    proxy != nil ? "yes" : "nil",
		    mondrian_probe_bool(proxy, "isInstalled"),
		    mondrian_probe_bool(proxy, "isPlaceholder"),
		    mondrian_probe_string(proxy, "applicationType"));
		mondrian_probe_fmt("MONDRIAN LAUNCH: proxy url %s\n",
		    mondrian_probe_string(proxy, "bundleURL"));
	}

	/*
	 * The launch request goes before anything else spawns the app: with a
	 * Preferences already running the workspace answers no for the wrong
	 * reason, which is what the first version of this probe measured.
	 */
	@try {
		Class workspace_cls = objc_getClass("LSApplicationWorkspace");
		id workspace = nil;
		SEL sel = sel_registerName("openApplicationWithBundleID:");
		BOOL opened_app = NO;

		if (workspace_cls != Nil &&
		    [workspace_cls respondsToSelector:@selector(defaultWorkspace)]) {
			workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspace_cls,
			    sel_registerName("defaultWorkspace"));
		}
		if (workspace != nil && [workspace respondsToSelector:sel]) {
			opened_app = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace,
			    sel, @"com.apple.Preferences");
		}
		mondrian_probe_fmt("MONDRIAN LAUNCH: workspace %s open -> %d\n",
		    workspace != nil ? "yes" : "nil", opened_app ? 1 : 0);
	} @catch (id exception) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: workspace raised\n");
	}
	sleep(3);
	mondrian_probe_processes("workspace");

	/*
	 * SpringBoardServices is the C entry point the icon path ends in; its
	 * return value says whether the request was accepted at all. The same
	 * helper the other two processes use dumps every thread while the call
	 * is blocked, so the frame that waits is on the record.
	 */
	mondrian_probe_app("springboard");
	sleep(3);
	mondrian_probe_processes("sbslaunch");

	/*
	 * Control: this process execs the binary itself. It worked in the first
	 * probe, so it separates "the kernel refuses the app" from "the launch
	 * pipeline never asks".
	 */
	{
		char *argv[] = { (char *)"Preferences", NULL };
		extern char **environ;

		errno = 0;
		rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
		mondrian_probe_fmt("MONDRIAN LAUNCH: posix_spawn rc %d errno %d pid %d\n",
		    rc, errno, (int)pid);
		if (rc == 0) {
			for (i = 0; i < 20; i++) {
				if (waitpid(pid, &status, WNOHANG) == pid) {
					break;
				}
				usleep(250000);
			}
			mondrian_probe_fmt(
			    "MONDRIAN LAUNCH: spawn status 0x%x after %d ms\n",
			    status, i * 250);
		}
	}
}

/*
 * One boot, two passes: the passive half at boot (file, launchd log, direct
 * spawn, workspace) and the process set every 15 s for five minutes, so a tap
 * made at any point is caught with the processes it created.
 */
static void *
mondrian_launch_thread(void *unused)
{
	unsigned last = 0;
	int i;

	(void)unused;
	sleep(60);
	mondrian_probe_fmt("MONDRIAN LAUNCH: probe begins\n");
	mondrian_probe_fmt("MONDRIAN LAUNCH: insert %s\n",
	    getenv("DYLD_INSERT_LIBRARIES") != NULL ?
	    getenv("DYLD_INSERT_LIBRARIES") : "-");
	@try {
		mondrian_probe_proclist();
		mondrian_probe_launch();
		/*
		 * The log is read *after* the launch attempts: the app job's lines
		 * (spawn scheduled, xpcproxy, exec failure) are written by launchd
		 * while the request is being handled, so an earlier read only shows
		 * the boot's daemons.
		 */
		mondrian_probe_launchd_log();
		/* A second table after the lookups: did launchd start installd? */
		mondrian_probe_proclist();
	} @catch (id exception) {
		mondrian_probe_fmt("MONDRIAN LAUNCH: probe raised\n");
	}
	for (i = 0; i < 20; i++) {
		@try {
			id manager = nil;
			id all;
			Class cls = objc_getClass("FBProcessManager");
			unsigned count = 0;

			if (cls != Nil &&
			    [cls respondsToSelector:@selector(sharedInstance)]) {
				manager = ((id (*)(id, SEL))objc_msgSend)((id)cls,
				    sel_registerName("sharedInstance"));
			}
			all = mondrian_probe_call(manager, "allProcesses");
			if (all != nil && [all respondsToSelector:@selector(count)]) {
				count = (unsigned)[all count];
			}
			if (i == 0 || count != last) {
				last = count;
				mondrian_probe_processes("watch");
			}
		} @catch (id exception) {
			mondrian_probe_fmt("MONDRIAN LAUNCH: watch raised\n");
		}
		sleep(15);
	}
	return NULL;
}

__attribute__((constructor))
static void
mondrian_install_ui_hooks(void)
{
	console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	/*
	 * Two processes only report, because the UI hooks break the boot in
	 * either of them: launchd is the reaper and xpcproxy is what executes
	 * every app job. runningboardd's spawn request is waiting for launchd's
	 * answer while no app appears, and xpcproxy's argv says whether that
	 * request ever reached the spawn at all.
	 */
	if (strcmp(getprogname(), "launchd") == 0 ||
	    strcmp(getprogname(), "xpcproxy") == 0) {
		char tag[160];

		snprintf(tag, sizeof(tag),
		    "MONDRIAN UI: hook tag cc56 uid %d prog %s\n",
		    (int)geteuid(), getprogname());
		say(tag);
		if (strcmp(getprogname(), "xpcproxy") == 0) {
			int argc = *_NSGetArgc();
			char **argv = *_NSGetArgv();
			char line[400];

			snprintf(line, sizeof(line),
			    "MONDRIAN XPCPROXY: argc %d a0 %s a1 %s a2 %s\n",
			    argc, argc > 0 && argv[0] != NULL ? argv[0] : "-",
			    argc > 1 && argv[1] != NULL ? argv[1] : "-",
			    argc > 2 && argv[2] != NULL ? argv[2] : "-");
			say(line);
			return;
		}
		if (boot_arg_set("mondrianbdt=1")) {
			pthread_t thread;

			if (pthread_create(&thread, NULL, mondrian_threads_watch,
			    NULL) == 0) {
				pthread_detach(thread);
			}
		}
		return;
	}
	NSSetUncaughtExceptionHandler(mondrian_uncaught);
	(void)objc_setExceptionPreprocessor(mondrian_exc_pre);
	install_number_length_hook();
	if (boot_arg_set("mondriandnr=1")) {
		install_dnr_hook();
	}
	say_pid("UI: dylib loaded");
	/*
	 * Before UIKit builds the home screen: the material switch has to be in
	 * place when the dock and the App Library read it.
	 */
	{
		int ax = boot_arg_int("mondrianax=", -1);

		if (ax >= 0 && strcmp(getprogname(), "SpringBoard") == 0) {
			pthread_t thread;

			mondrian_ax_apply(ax);
			if (pthread_create(&thread, NULL, mondrian_ax_thread,
			    (void *)(intptr_t)ax) != 0) {
				say("MONDRIAN AX: thread failed\n");
			}
		}
	}
	install_personas_hook();
	/* The build tag: a boot that logs it proves which hook it is running. */
	{
		char tag[128];

		snprintf(tag, sizeof(tag),
		    "MONDRIAN UI: hook tag cc56 uid %d prog %s\n",
		    (int)geteuid(), getprogname());
		say(tag);
	}
	/*
	 * mondrianbare=1 keeps the probe and the network link but installs none
	 * of the SpringBoard swizzles. One boot with it answers whether FrontBoard
	 * deadlocks on its own or because of a hook in that path.
	 */
	if (!boot_arg_set("mondrianbare=1")) {
		install_display_diagnostic();
		install_activation_hooks();
		install_icon_probe();
		install_idle_hooks();
		install_display_link_rate_hooks();
		install_brightness_hooks();
		install_screen_size_hooks();
		install_touch_probe();
	} else {
		say("MONDRIAN UI: bare mode, swizzles skipped\n");
	}
	/*
	 * The launch path on the server side: runningboardd is where the request
	 * to launchd is made, and the frames to name are offsets inside the images
	 * it has loaded. Nothing here touches SpringBoard.
	 */
	if (strcmp(getprogname(), "runningboardd") == 0) {
		pthread_t fr;

		if (boot_arg_set("mondrianframes=1") &&
		    pthread_create(&fr, NULL, mondrian_frames_thread, NULL) == 0) {
			pthread_detach(fr);
		}
		if (boot_arg_set("mondrianrbsrv=1")) {
			mondrian_rbsrv_probe();
		}
		if (boot_arg_set("mondrianlaunch=1")) {
			pthread_t watch, trace;

			mondrian_install_server_wrappers();
			if (pthread_create(&trace, NULL, mondrian_trace_on_thread,
			    NULL) == 0) {
				pthread_detach(trace);
			}
			if (pthread_create(&watch, NULL, mondrian_start_watch, NULL) == 0) {
				pthread_detach(watch);
			}
		}
		if (boot_arg_set("mondrianports=1")) {
			pthread_t ports;

			if (pthread_create(&ports, NULL, mondrian_port_probe, NULL) == 0) {
				pthread_detach(ports);
			}
		}
	}
	if (strcmp(getprogname(), "SpringBoard") == 0) {
		pthread_t tz, launch;

		/* The zone file is written by a root daemon; Foundation re-reads it. */
		if (pthread_create(&tz, NULL, mondrian_tz_thread, NULL) == 0) {
			pthread_detach(tz);
		}
		if (boot_arg_set("mondrianrbsx=1")) {
			mondrian_install_launch_wrapper();
		}
		if (boot_arg_set("mondrianrbs=1")) {
			pthread_t rbs;

			if (pthread_create(&rbs, NULL, mondrian_rbs_thread, NULL) == 0) {
				pthread_detach(rbs);
			}
		}
		if (boot_arg_set("mondrianwin=1")) {
			pthread_t win;

			if (pthread_create(&win, NULL, mondrian_window_watch, NULL) == 0) {
				pthread_detach(win);
			}
		}
		/*
		 * The app-launch probe runs once per boot, after the home screen
		 * has settled, and watches FrontBoard's process set for five
		 * minutes so a tap made at any point is caught with the processes
		 * it created. Its launch times out and leaves FrontBoard's
		 * bootstrap lock held, after which the compositor stops
		 * presenting: a boot with the probe is a boot whose screen goes
		 * black on its own, so it runs only when asked for.
		 */
		if (boot_arg_set("mondrianprobe=1") &&
		    pthread_create(&launch, NULL, mondrian_launch_thread, NULL) == 0) {
			pthread_detach(launch);
		}
	}
	/*
	 * A root daemon whose launch path is the one that hangs: ask for
	 * installd at the same time the SpringBoard probe does, so the two
	 * answers line up.
	 */
	if (boot_arg_set("mondrianprobe=1") && geteuid() == 0 &&
	    strcmp(getprogname(), "containermanagerd") == 0) {
		pthread_t inst;

		if (pthread_create(&inst, NULL, mondrian_installd_test, NULL) == 0) {
			pthread_detach(inst);
		}
	}
	/*
	 * A user-501 process that is not SpringBoard: the same launch call from
	 * here answers "did FrontBoard refuse SpringBoard, or is the launch path
	 * broken for everyone".
	 */
	if (boot_arg_set("mondrianprobe=1") && geteuid() == 501 &&
	    strcmp(getprogname(), "backboardd") == 0) {
		pthread_t app;

		if (pthread_create(&app, NULL, mondrian_backboard_probe, NULL) == 0) {
			pthread_detach(app);
		}
	}
	/*
	 * Does launchd answer its own job API from another client? runningboardd
	 * waits on it while launchd looks idle, and only a call from a process
	 * that is not runningboardd tells the two apart.
	 */
	if (boot_arg_int("mondriansym=", 0) > 0 &&
	    strcmp(getprogname(), "SpringBoard") == 0) {
		pthread_t sym;

		if (pthread_create(&sym, NULL, mondrian_symbol_probe, NULL) == 0) {
			pthread_detach(sym);
		}
	}
	if (boot_arg_set("mondrianlaunchctl=1") &&
	    strcmp(getprogname(), "SpringBoard") == 0) {
		pthread_t lc;

		if (pthread_create(&lc, NULL, mondrian_launchctl_test, NULL) == 0) {
			pthread_detach(lc);
		}
	}
	start_heartbeat();
	if (!boot_arg_set("mondriannet=0")) {
		pthread_t net;

		if (pthread_create(&net, NULL, mondrian_net_thread, NULL) != 0) {
			say("MONDRIAN NET: thread failed\n");
		}
	}
	if (boot_arg_set("mondrianrescue=1")) {
		pthread_t rescue;

		if (pthread_create(&rescue, NULL, mondrian_rescue_thread, NULL) != 0) {
			say("MONDRIAN RESCUE: thread failed\n");
		}
	}
	if (boot_arg_set("mondrianjnl=1")) {
		pthread_t jnl;

		if (pthread_create(&jnl, NULL, mondrian_journal_thread, NULL) != 0) {
			say("MONDRIAN JNL: thread failed\n");
		}
	}
	if (boot_arg_set("mondrianmain=1")) {
		pthread_t thread;

		if (pthread_create(&thread, NULL, mondrian_main_watch, NULL) != 0) {
			say("MONDRIAN UI: main watch failed\n");
		}
	}
	{
		int want = boot_arg_int("mondrianbdtpid=", 0);

		if (boot_arg_set("mondrianbdt=1") ||
		    (want != 0 && want == (int)getpid())) {
			pthread_t thread;

			if (pthread_create(&thread, NULL, mondrian_threads_watch,
			    NULL) != 0) {
				say("MONDRIAN UI: thread watch failed\n");
			}
		}
	}
	mondrian_link_probe();
	load_gpu_test();
}
