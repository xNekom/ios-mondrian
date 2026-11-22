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
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <stdlib.h>
#import <signal.h>
#import <pwd.h>
#import <grp.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/thread_act.h>
#import <mach/thread_state.h>
#import <mach/thread_info.h>

/*
 * The iPhoneOS SDK marks mach_vm.h unsupported in userland, but the trap is in
 * libsystem_kernel: reading another thread's message without faulting on a bad
 * pointer is what this probe needs.
 */
extern kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
    mach_vm_address_t address, mach_vm_size_t size, mach_vm_address_t data,
    mach_vm_size_t *outsize);
#import <dlfcn.h>

/*
 * libxpc, declared here: this toolchain's iPhoneOS SDK ships neither the
 * headers nor libxpc.tbd.
 */
typedef struct _xpc_connection_s *xpc_connection_t;
typedef struct _xpc_object_s *xpc_object_t;
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);
extern xpc_connection_t xpc_connection_create_mach_service(const char *name,
    dispatch_queue_t targetq, uint64_t flags);
extern void xpc_connection_resume(xpc_connection_t connection);
extern xpc_object_t xpc_dictionary_create(const char *const *keys,
    xpc_object_t *values, size_t count);
extern void xpc_dictionary_set_string(xpc_object_t dictionary, const char *key,
    const char *value);
extern void xpc_connection_send_message(xpc_connection_t connection,
    xpc_object_t message);
extern void xpc_release(xpc_object_t object);
extern const char *xpc_connection_get_name(xpc_connection_t connection);
extern char *xpc_copy_description(xpc_object_t object);
extern int xpc_pipe_routine(xpc_object_t pipe, xpc_object_t message,
    xpc_object_t *reply);
/* Defined far below; the XPC wrapper above needs them. */
static int boot_arg_set(const char *name);
static int boot_arg_int(const char *name, int fallback);
static void mondrian_probe_fmt(const char *fmt, ...);
static int mondrian_file_on(const char *path);
static void mondrian_touch(const char *path);
static void *mondrian_surface_owner(void *unused);

/*
 * The bootstrap namespace lives in libSystem and the SDK ships no servers/
 * headers: the two entry points this probe needs are declared here.
 */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bootstrap_port,
    const char *service_name, mach_port_t *service_port);

#include <dispatch/dispatch.h>
#include <crt_externs.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <ImageIO/ImageIO.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <dirent.h>
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

/*
 * ReportCrash faults inside libc++ with a libsystem_info caller, and that library
 * is where getpwuid, getgrgid and getaddrinfo live: ReportCrash names the user
 * and the group of the process in its report. This names the frames the crash
 * landed in (offsets from the kernel's pc and bt, resolved against the images pid
 * exec printed) and then asks the same lookups, so a missing or unreadable user
 * database shows up as an errno instead of a fault.
 * Switch: /private/var/vm/mondrian-crashsyms.
 */
static void
mondrian_crash_syms(void)
{
	static const char *const files[] = {
		"/etc/passwd",
		"/etc/master.passwd",
		"/etc/group",
		"/var/db/dslocal/nodes/Default/users/root.plist",
	};
	struct passwd pw;
	struct group gr;
	char buf[1024];
	struct passwd *pwp = NULL;
	struct group *grp = NULL;
	int pw_err, gr_err;
	unsigned i;

	mondrian_frame_name(0, "libsystem_info.dylib", 0x1ef84);
	mondrian_frame_name(1, "libsystem_info.dylib", 0x207d4);
	mondrian_frame_name(2, "libc++.1.dylib", 0x55e5c);
	mondrian_frame_name(3, "libc++.1.dylib", 0x683b4);
	for (i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
		struct stat st;
		int err = stat(files[i], &st);

		mondrian_probe_fmt("MONDRIAN CRAX[%d]: %s stat %d size %lld\n",
		    getpid(), files[i], err,
		    err == 0 ? (long long)st.st_size : -1LL);
	}
	memset(&pw, 0, sizeof(pw));
	pw_err = getpwuid_r(0, &pw, buf, sizeof(buf), &pwp);
	mondrian_probe_fmt("MONDRIAN CRAX[%d]: getpwuid_r(0) -> %d ptr %s uid %d\n",
	    getpid(), pw_err, pwp != NULL ? "set" : "nil",
	    pwp != NULL ? (int)pw.pw_uid : -1);
	memset(&gr, 0, sizeof(gr));
	gr_err = getgrgid_r(0, &gr, buf, sizeof(buf), &grp);
	mondrian_probe_fmt("MONDRIAN CRAX[%d]: getgrgid_r(0) -> %d ptr %s gid %d\n",
	    getpid(), gr_err, grp != NULL ? "set" : "nil",
	    grp != NULL ? (int)gr.gr_gid : -1);
}

/*
 * ReportCrash faults inside libc++'s
 * `std::__fs::filesystem::path::lexically_relative(path const&)`, called from
 * libsystem_info, with a faulting address that lands in a hole between two of its
 * own mappings and changes every run. The question the crash cannot answer is
 * which path it was splitting, so the interposer below prints both arguments;
 * it lives with the other interpose tuples, where the struct is defined.
 */

static const char *
mondrian_cxx_string(const void *string)
{
	const unsigned char *bytes = string;

	if (bytes == NULL) {
		return "(null)";
	}
	if ((bytes[0] & 0x80) != 0) {
		const char *data = *(const char *const *)string;

		return data != NULL ? data : "(long, no data)";
	}
	return (const char *)(bytes + 1);
}

/*
 * The library is empty, so "Photos draws its Library tab" only proves it can draw
 * the empty state. This imports one image with PhotoKit's own API, in the app
 * that already carries the hook, so the next launch has something to render.
 * Switch: /private/var/vm/mondrian-import; the image is
 * /private/var/vm/mondrian-photo.png, written from the host.
 */
/*
 * Photos runs in multi-library mode here: the platform cannot resolve a system
 * photo library URL in the app (`+systemLibraryURLIfResolvable` answers nil), so
 * every single-library API refuses with `Calling single library mode API while
 * in multi library mode`. That refusal killed the first import attempt by
 * throwing on a background thread, which is a process-wide death. This prints
 * the platform's own answers before the app runs, so the next step is decided
 * from the mode and not from the message alone.
 */
static void
mondrian_library_probe(void)
{
	Class pm = objc_getClass("PLPhotoLibraryPathManager");
	Class ph = objc_getClass("PHPhotoLibrary");
	id manager = nil;
	id url = nil;
	BOOL defined = NO;

	if (pm != Nil) {
		if ([pm respondsToSelector:@selector(systemLibraryPathManager)]) {
			manager = [pm performSelector:
			    @selector(systemLibraryPathManager)];
		}
		if ([pm respondsToSelector:@selector(isSystemLibraryURLDefined)]) {
			defined = ((BOOL (*)(id, SEL))objc_msgSend)(pm,
			    @selector(isSystemLibraryURLDefined));
		}
		if ([pm respondsToSelector:
		    @selector(systemLibraryURLIfResolvable)]) {
			url = [pm performSelector:
			    @selector(systemLibraryURLIfResolvable)];
		}
	}
	mondrian_probe_fmt("MONDRIAN LIB[%d]: defined %d system %s\n", getpid(),
	    defined ? 1 : 0,
	    url != nil ? [[url absoluteString] UTF8String] : "(none)");
	/*
	 * The platform reports the URL as defined and yet unresolvable, and every
	 * change request then fails for want of a security-scoped bookmark. The
	 * registration call is the one a device uses when the system library moves,
	 * so asking it here says whether the port can put the library back in the
	 * single-library slot at all.
	 */
	if (url == nil && pm != Nil && [pm respondsToSelector:
	    @selector(setSystemPhotoLibraryURL:error:)]) {
		NSURL *root = [NSURL fileURLWithPath:
		    @"/private/var/mobile/Media/PhotoData" isDirectory:YES];
		NSError *error = nil;
		BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(pm,
		    @selector(setSystemPhotoLibraryURL:error:), root, &error);

		mondrian_probe_fmt("MONDRIAN LIB[%d]: set %d error %s\n", getpid(),
		    ok ? 1 : 0,
		    error != nil ? [[error description] UTF8String] : "-");
		if ([pm respondsToSelector:
		    @selector(systemLibraryURLIfResolvable)]) {
			id after = [pm performSelector:
			    @selector(systemLibraryURLIfResolvable)];

			mondrian_probe_fmt(
			    "MONDRIAN LIB[%d]: after set system %s\n", getpid(),
			    after != nil ? [[after absoluteString] UTF8String] :
			    "(none)");
		}
	}
	if (manager != nil &&
	    [manager respondsToSelector:@selector(systemLibraryURL)]) {
		id murl = [manager performSelector:@selector(systemLibraryURL)];

		mondrian_probe_fmt("MONDRIAN LIB[%d]: manager %s url %s\n",
		    getpid(), class_getName(object_getClass(manager)),
		    murl != nil ? [[murl absoluteString] UTF8String] : "(none)");
	}
	if (ph != Nil && [ph respondsToSelector:@selector(sharedPhotoLibrary)]) {
		@try {
			id shared = [ph performSelector:
			    @selector(sharedPhotoLibrary)];
			id liburl = nil;
			const char *image = class_getImageName(ph);

			mondrian_probe_fmt(
			    "MONDRIAN LIB[%d]: PHPhotoLibrary from %s\n", getpid(),
			    image != NULL ? image : "(none)");
			if ([ph respondsToSelector:@selector(authorizationStatus)]) {
				int status = ((int (*)(id, SEL))objc_msgSend)(ph,
				    @selector(authorizationStatus));

				mondrian_probe_fmt(
				    "MONDRIAN LIB[%d]: authorizationStatus %d\n",
				    getpid(), status);
			}
			if ([ph respondsToSelector:
			    @selector(authorizationStatusForAccessLevel:)]) {
				int add = ((int (*)(id, SEL, long))objc_msgSend)(ph,
				    @selector(authorizationStatusForAccessLevel:), 1L);
				int rw = ((int (*)(id, SEL, long))objc_msgSend)(ph,
				    @selector(authorizationStatusForAccessLevel:), 2L);

				mondrian_probe_fmt(
				    "MONDRIAN LIB[%d]: addOnly %d readWrite %d\n",
				    getpid(), add, rw);
			}
			if (shared != nil &&
			    [shared respondsToSelector:@selector(libraryURL)]) {
				liburl = [shared performSelector:
				    @selector(libraryURL)];
			}
			mondrian_probe_fmt(
			    "MONDRIAN LIB[%d]: shared %s url %s\n", getpid(),
			    shared != nil ? "ok" : "nil",
			    liburl != nil ? [[liburl absoluteString]
			    UTF8String] : "(none)");
		} @catch (id e) {
			mondrian_probe_fmt(
			    "MONDRIAN LIB[%d]: shared threw %s\n", getpid(),
			    [[e reason] UTF8String]);
		}
	}
	{
		DIR *dir = opendir("/private/var/mobile/Media/PhotoData");
		struct dirent *ent;
		char names[300];
		size_t used = 0;

		names[0] = '\0';
		while (dir != NULL && (ent = readdir(dir)) != NULL &&
		    used < sizeof(names) - 40) {
			size_t len = strlen(ent->d_name);

			if (strcmp(ent->d_name, ".") == 0 ||
			    strcmp(ent->d_name, "..") == 0 || len > 30) {
				continue;
			}
			memcpy(names + used, ent->d_name, len);
			used += len;
			names[used++] = ' ';
			names[used] = '\0';
		}
		if (dir != NULL) {
			(void)closedir(dir);
		}
		mondrian_probe_fmt("MONDRIAN LIB[%d]: PhotoData [%s]\n", getpid(),
		    names);
	}
}

/*
 * A change submitted through the shared library needs no bookmark, and the
 * per-library door needs one the client does not have ("Client did not provide
 * bookmarkData" for /private/var/mobile/Media/PhotoData/). Both are tried, plus
 * the importer's own `PHAssetCreationRequest`, and the one that submits says
 * which path the port can use.
 */
static id
mondrian_library_for(NSURL *root)
{
	Class ph = objc_getClass("PHPhotoLibrary");
	id instance = nil;

	if (ph == Nil || root == nil ||
	    ![ph instancesRespondToSelector:
	    @selector(initWithPhotoLibraryURL:)]) {
		return nil;
	}
	@try {
		instance = [[ph alloc] initWithPhotoLibraryURL:root];
	} @catch (id e) {
		mondrian_probe_fmt("MONDRIAN IMPORT[%d]: open threw %s\n",
		    getpid(), [[e reason] UTF8String]);
	}
	return instance;
}

static int
mondrian_import_submit(id library, Class request, NSURL *source,
    const char *which)
{
	if (library == nil) {
		return 0;
	}
	@try {
		[library performChanges:^{
			[request creationRequestForAssetFromImageAtFileURL:source];
		} completionHandler:^(BOOL success, NSError *error) {
			mondrian_probe_fmt(
			    "MONDRIAN IMPORT[%d]: %s success %d error %s\n",
			    getpid(), which, success ? 1 : 0,
			    error != nil ? [[error description] UTF8String] : "-");
			if (error != nil) {
				mondrian_probe_fmt(
				    "MONDRIAN IMPORT[%d]: %s domain %s code %ld\n",
				    getpid(), which, [[error domain] UTF8String],
				    (long)[error code]);
			}
			if (success) {
				mondrian_touch("/private/var/vm/mondrian-imported");
			}
		}];
	} @catch (id e) {
		mondrian_probe_fmt("MONDRIAN IMPORT[%d]: %s threw %s\n", getpid(),
		    which, [[e reason] UTF8String]);
		return 0;
	}
	mondrian_probe_fmt("MONDRIAN IMPORT[%d]: submitted via %s\n", getpid(),
	    which);
	return 1;
}

/* The importer's API: a creation request that names the file as a resource. */
static int
mondrian_import_creation(id library, NSURL *source, const char *which)
{
	Class creation = objc_getClass("PHAssetCreationRequest");

	if (library == nil || creation == Nil ||
	    ![creation respondsToSelector:@selector(creationRequestForAsset)]) {
		return 0;
	}
	@try {
		[library performChanges:^{
			id request = [creation creationRequestForAsset];

			if (request != nil && [request respondsToSelector:
			    @selector(addResourceWithType:fileURL:options:)]) {
				((void (*)(id, SEL, long, id, id))objc_msgSend)(
				    request, @selector(addResourceWithType:
				    fileURL:options:), 1L, source, nil);
			}
		} completionHandler:^(BOOL success, NSError *error) {
			mondrian_probe_fmt(
			    "MONDRIAN IMPORT[%d]: %s success %d error %s\n",
			    getpid(), which, success ? 1 : 0,
			    error != nil ? [[error description] UTF8String] : "-");
			if (error != nil) {
				mondrian_probe_fmt(
				    "MONDRIAN IMPORT[%d]: %s domain %s code %ld\n",
				    getpid(), which, [[error domain] UTF8String],
				    (long)[error code]);
			}
			if (success) {
				mondrian_touch("/private/var/vm/mondrian-imported");
			}
		}];
	} @catch (id e) {
		mondrian_probe_fmt("MONDRIAN IMPORT[%d]: %s threw %s\n", getpid(),
		    which, [[e reason] UTF8String]);
		return 0;
	}
	mondrian_probe_fmt("MONDRIAN IMPORT[%d]: submitted via %s\n", getpid(),
	    which);
	return 1;
}

/* A bounded directory size, for a volume that reports almost no free space. */
static unsigned long long
mondrian_du(const char *path, int depth)
{
	DIR *dir;
	struct dirent *ent;
	unsigned long long total = 0;

	if (depth <= 0) {
		return 0;
	}
	dir = opendir(path);
	if (dir == NULL) {
		return 0;
	}
	while ((ent = readdir(dir)) != NULL) {
		char child[512];
		struct stat st;

		if (strcmp(ent->d_name, ".") == 0 ||
		    strcmp(ent->d_name, "..") == 0) {
			continue;
		}
		if (snprintf(child, sizeof(child), "%s/%s", path, ent->d_name) <= 0) {
			continue;
		}
		if (lstat(child, &st) != 0) {
			continue;
		}
		if (S_ISDIR(st.st_mode)) {
			total += mondrian_du(child, depth - 1);
		} else if (S_ISREG(st.st_mode)) {
			total += (unsigned long long)st.st_size;
		}
	}
	(void)closedir(dir);
	return total;
}

/*
 * The bitmap says the volume is full; a tree-by-tree walk cannot tell "full of
 * files" from "full of blocks no fork owns". This walks the whole volume and
 * sums every regular file once (hard links share an inode, so a small table
 * keeps the second link from being counted again), which separates the two.
 * Switch: mondrian-du.
 */
struct mondrian_inode {
	uint64_t dev;
	uint64_t ino;
};

static struct mondrian_inode *mondrian_inodes;
static unsigned mondrian_inodes_used;
static unsigned mondrian_inodes_cap;

static int
mondrian_inode_seen(uint64_t dev, uint64_t ino)
{
	unsigned slot, i;

	if (mondrian_inodes == NULL) {
		mondrian_inodes_cap = 1u << 16;
		mondrian_inodes = calloc(mondrian_inodes_cap,
		    sizeof(*mondrian_inodes));
		if (mondrian_inodes == NULL) {
			mondrian_inodes_cap = 0;
			return 0;
		}
	}
	if (mondrian_inodes_cap == 0) {
		return 0;
	}
	slot = (unsigned)((dev * 31u + ino) & (mondrian_inodes_cap - 1));
	for (i = 0; i < 64; i++) {
		unsigned at = (slot + i) & (mondrian_inodes_cap - 1);

		if (mondrian_inodes[at].ino == 0) {
			mondrian_inodes[at].dev = dev;
			mondrian_inodes[at].ino = ino;
			return 0;
		}
		if (mondrian_inodes[at].dev == dev &&
		    mondrian_inodes[at].ino == ino) {
			return 1;
		}
	}
	return 0;
}

/*
 * A walk under a sandbox cannot enter every tree, and a skipped tree reads as
 * empty space. Keep the first failures with their errno: without them a 3.7 GB
 * gap between `statfs` and the file total is not evidence of anything.
 */
static struct {
	char path[160];
	int err;
} mondrian_du_denied[12];
static unsigned mondrian_du_denied_count;
static unsigned mondrian_du_denied_seen;
static unsigned mondrian_du_files;

static unsigned long long
mondrian_du_all(const char *path)
{
	DIR *dir;
	struct dirent *ent;
	unsigned long long total = 0;

	dir = opendir(path);
	if (dir == NULL) {
		if (mondrian_du_denied_seen <
		    sizeof(mondrian_du_denied) / sizeof(mondrian_du_denied[0])) {
			snprintf(mondrian_du_denied[mondrian_du_denied_count].path,
			    sizeof(mondrian_du_denied[0].path), "%s", path);
			mondrian_du_denied[mondrian_du_denied_seen].err = errno;
			mondrian_du_denied_seen++;
		}
		mondrian_du_denied_count++;
		return 0;
	}
	while ((ent = readdir(dir)) != NULL) {
		char child[512];
		struct stat st;

		if (strcmp(ent->d_name, ".") == 0 ||
		    strcmp(ent->d_name, "..") == 0) {
			continue;
		}
		if (snprintf(child, sizeof(child), "%s%s%s", path,
		    strcmp(path, "/") == 0 ? "" : "/", ent->d_name) <= 0) {
			continue;
		}
		if (lstat(child, &st) != 0) {
			continue;
		}
		if (S_ISDIR(st.st_mode)) {
			total += mondrian_du_all(child);
		} else if (S_ISREG(st.st_mode)) {
			if (st.st_nlink > 1 && mondrian_inode_seen(st.st_dev,
			    st.st_ino)) {
				continue;
			}
			mondrian_du_files++;
			total += (unsigned long long)st.st_size;
		}
	}
	(void)closedir(dir);
	return total;
}

/*
 * The volume reports 37 MB free of 16 GB while the same root's image carried
 * 2.4 GB, so the port's own bookkeeping is what filled it. These are the trees a
 * boot grows: logs, caches, crash reports and the old diagnostics store. Print
 * each one's size and let the reading decide what is regenerable.
 * Switch: /private/var/vm/mondrian-du.
 */
static void *
mondrian_du_report(void *unused)
{
	(void)unused;
	static const struct {
		const char *path;
		int depth;
	} trees[] = {
		{ "/private/var", 3 },
		{ "/private/var/mobile", 3 },
		{ "/private/var/mobile/Library", 2 },
		{ "/private/var/mobile/Documents", 2 },
		{ "/private/var/MobileSoftwareUpdate", 3 },
		{ "/private/var/containers", 3 },
		{ "/private/var/staged_system_apps", 2 },
		{ "/private/var/db", 3 },
		{ "/private/var/log", 4 },
		{ "/private/var/mobile/Library/Caches", 3 },
		{ "/private/var/mobile/Media", 3 },
		{ "/Applications", 2 },
		{ "/usr", 2 },
		{ "/System/Library", 2 },
	};
	struct statfs space;
	unsigned i;

	if (statfs("/private/var", &space) == 0) {
		unsigned long long size = (unsigned long long)space.f_bsize;

		/*
		 * `f_bavail` is what the driver hands a writer: `freeBlocks` minus
		 * the reserve and minus the journal and Spotlight loans. `f_bfree`
		 * is the same counter without those subtractions, so the pair names
		 * the layer: a healthy `f_bfree` and an empty `f_bavail` is not a
		 * full volume, it is a reservation.
		 */
		mondrian_probe_fmt(
		    "MONDRIAN DU[%d]: blocks %llu, free %llu (%llu MB), "
		    "avail %llu (%llu MB), bsize %u\n", getpid(),
		    (unsigned long long)space.f_blocks,
		    (unsigned long long)space.f_bfree,
		    (unsigned long long)space.f_bfree * size / (1024 * 1024),
		    (unsigned long long)space.f_bavail,
		    (unsigned long long)space.f_bavail * size / (1024 * 1024),
		    (unsigned)space.f_bsize);
	}
	for (i = 0; i < sizeof(trees) / sizeof(trees[0]); i++) {
		unsigned long long bytes = mondrian_du(trees[i].path,
		    trees[i].depth);

		mondrian_probe_fmt("MONDRIAN DU[%d]: %-40s %llu MB\n", getpid(),
		    trees[i].path, bytes / (1024 * 1024));
	}
	/*
	 * `/lost+found` is where a repair puts what it cannot attach to a name, it
	 * is 0700 root, and it is the one tree the walk cannot enter. Its entry
	 * count says whether the missing gigabytes are there, and `getattrlist`
	 * answers that from the catalog without read permission on the directory.
	 */
	{
		struct stat st;
		struct attrlist attributes;
		struct {
			uint32_t length;
			uint32_t entrycount;
			uint32_t linkcount;
		} __attribute__((aligned(4))) answer;
		int err = 0;
		int found = 0;

		memset(&answer, 0, sizeof(answer));
		if (lstat("/lost+found", &st) == 0) {
			memset(&attributes, 0, sizeof(attributes));
			attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
			attributes.dirattr = ATTR_DIR_ENTRYCOUNT |
			    ATTR_DIR_LINKCOUNT;
			/*
			 * The returned set starts with its own length, then the
			 * attributes in bitmap order, each aligned.
			 */
			if (getattrlist("/lost+found", &attributes, &answer,
			    sizeof(answer), FSOPT_NOFOLLOW) == 0) {
				found = 1;
			} else {
				err = errno;
			}
			mondrian_probe_fmt(
			    "MONDRIAN DU[%d]: lost+found size %lld blocks %lld "
			    "entries %u found %d errno %d\n", getpid(),
			    (long long)st.st_size, (long long)st.st_blocks,
			    found ? answer.entrycount : 0, found, err);
		} else {
			mondrian_probe_fmt(
			    "MONDRIAN DU[%d]: lost+found stat errno %d\n",
			    getpid(), errno);
		}
	}
	{
		unsigned long long files;
		unsigned k;

		mondrian_du_denied_count = 0;
		mondrian_du_denied_seen = 0;
		mondrian_du_files = 0;
		files = mondrian_du_all("/");
		mondrian_probe_fmt(
		    "MONDRIAN DU[%d]: every file %llu MB, %u files, links %u, "
		    "skipped %u\n", getpid(), files / (1024 * 1024),
		    mondrian_du_files, mondrian_inodes_used,
		    mondrian_du_denied_count);
		for (k = 0; k < mondrian_du_denied_seen; k++) {
			mondrian_probe_fmt("MONDRIAN DU[%d]: skipped %s errno %d\n",
			    getpid(), mondrian_du_denied[k].path,
			    mondrian_du_denied[k].err);
		}
	}
	return NULL;
}

/*
 * What the decoder makes of the picture.
 *
 * Measured 2026-11-19: the import succeeds (`shared success 1`), the Library
 * draws one tile, the viewer opens on it, and both are black -- while the source
 * PNG decodes to four coloured quadrants on the host. The compositor's log shows
 * the upload at that moment (`1 textures refilled from IOSurfaces (1875 KB)`,
 * exactly 800x600x4), so either the bytes were already black before the upload or
 * the upload read them wrong. This decodes the staged file through ImageIO and
 * reads the four quadrants back: colour here and black on screen is the upload
 * path, black here is the decoder. Either answer names the layer.
 */
static void
mondrian_decode_probe(NSString *path)
{
	const char *file = [path UTF8String];
	CFURLRef url;
	CGImageSourceRef source;
	CGImageRef image = NULL;
	CGColorSpaceRef space;
	CGContextRef context;
	unsigned char px[16];
	size_t w = 0, h = 0;

	if (file == NULL) {
		return;
	}
	url = CFURLCreateFromFileSystemRepresentation(NULL,
	    (const UInt8 *)file, (CFIndex)strlen(file), false);
	source = url != NULL ? CGImageSourceCreateWithURL(url, NULL) : NULL;
	if (source != NULL) {
		image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
	}
	if (image == NULL) {
		mondrian_probe_fmt("MONDRIAN DECODE[%d]: no image from %s\n",
		    getpid(), file);
		return;
	}
	w = CGImageGetWidth(image);
	h = CGImageGetHeight(image);
	memset(px, 0, sizeof(px));
	space = CGColorSpaceCreateDeviceRGB();
	context = CGBitmapContextCreate(px, 2, 2, 8, 8, space,
	    kCGImageAlphaPremultipliedLast);
	if (context != NULL) {
		CGContextDrawImage(context, CGRectMake(0, 0, 2, 2), image);
		mondrian_probe_fmt("MONDRIAN DECODE[%d]: %zux%zu bpp %zu quadrants "
		    "%d,%d,%d | %d,%d,%d | %d,%d,%d | %d,%d,%d\n", getpid(), w, h,
		    CGImageGetBitsPerPixel(image),
		    px[0], px[1], px[2], px[4], px[5], px[6],
		    px[8], px[9], px[10], px[12], px[13], px[14]);
		CGContextRelease(context);
	}
	CGImageRelease(image);
	if (source != NULL) {
		CFRelease(source);
	}
	if (url != NULL) {
		CFRelease(url);
	}
}

/*
 * The layer between the decoded file and the screen.
 *
 * Measured 2026-11-19: ImageIO decodes the imported file to its four coloured
 * quadrants inside the app, the compositor uploads an 800x600x4 surface when the
 * viewer opens, and the tile and the viewer both draw black. Those two facts do
 * not say whether the app ever receives the image: PhotoKit's own path for a
 * photo is a thumbnail request, and on a port without `IOSurfaceAccelerator` a
 * scaling step can fail and hand back nothing. This asks `PHImageManager` for the
 * first asset's thumbnail synchronously and reads the result back: a coloured
 * UIImage here puts the loss in the upload to the layer; nil or black here puts it
 * inside PhotoKit.
 */
static void
mondrian_image_probe(void)
{
	Class asset_class = objc_getClass("PHAsset");
	Class fetch_class = objc_getClass("PHFetchOptions");
	Class manager_class = objc_getClass("PHImageManager");
	Class request_class = objc_getClass("PHImageRequestOptions");
	id assets, first, manager, options;

	if (asset_class == Nil || fetch_class == Nil || manager_class == Nil ||
	    request_class == Nil) {
		mondrian_probe_fmt("MONDRIAN IMAGE[%d]: no PhotoKit\n", getpid());
		return;
	}
	assets = ((id (*)(id, SEL, id))objc_msgSend)(asset_class,
	    sel_registerName("fetchAssetsWithOptions:"), [fetch_class new]);
	if (assets == nil ||
	    ((unsigned long (*)(id, SEL))objc_msgSend)(assets,
	    sel_registerName("count")) == 0) {
		mondrian_probe_fmt("MONDRIAN IMAGE[%d]: no asset\n", getpid());
		return;
	}
	first = ((id (*)(id, SEL, unsigned long))objc_msgSend)(assets,
	    sel_registerName("objectAtIndex:"), 0);
	manager = ((id (*)(id, SEL))objc_msgSend)(manager_class,
	    sel_registerName("defaultManager"));
	options = [request_class new];
	((void (*)(id, SEL, BOOL))objc_msgSend)(options,
	    sel_registerName("setSynchronous:"), YES);
	((void (*)(id, SEL, id, CGSize, long, id, id))objc_msgSend)(manager,
	    sel_registerName("requestImageForAsset:targetSize:contentMode:"
	    "options:resultHandler:"), first, CGSizeMake(200, 200), 0, options,
	    ^(id image, id info) {
		CGImageRef cg;

		if (image == nil) {
			mondrian_probe_fmt("MONDRIAN IMAGE[%d]: nil image %s\n",
			    getpid(), [[info description] UTF8String]);
			return;
		}
		cg = (CGImageRef)(uintptr_t)((void *(*)(id, SEL))objc_msgSend)(
		    image, sel_registerName("CGImage"));
		if (cg == NULL) {
			mondrian_probe_fmt("MONDRIAN IMAGE[%d]: no CGImage\n",
			    getpid());
			return;
		}
		{
			unsigned char px[16];
			CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
			CGContextRef context = CGBitmapContextCreate(px, 2, 2, 8,
			    8, space, kCGImageAlphaPremultipliedLast);

			memset(px, 0, sizeof(px));
			if (context != NULL) {
				CGContextDrawImage(context, CGRectMake(0, 0, 2, 2),
				    cg);
				mondrian_probe_fmt("MONDRIAN IMAGE[%d]: %zux%zu "
				    "quadrants %d,%d,%d | %d,%d,%d | %d,%d,%d | "
				    "%d,%d,%d\n", getpid(), CGImageGetWidth(cg),
				    CGImageGetHeight(cg), px[0], px[1], px[2],
				    px[4], px[5], px[6], px[8], px[9], px[10],
				    px[12], px[13], px[14]);
				CGContextRelease(context);
			}
			CGColorSpaceRelease(space);
		}
	});
}

static void *
mondrian_import_thread(void *unused)
{
	Class ph;
	Class request;
	Class asset;
	Class options;
	id shared;
	id library;
	NSURL *source;
	NSURL *root;
	id existing;
	unsigned have = 0;

	(void)unused;
	sleep(8);
	if (mondrian_file_on("/private/var/vm/mondrian-imported")) {
		return NULL;
	}
	ph = objc_getClass("PHPhotoLibrary");
	request = objc_getClass("PHAssetChangeRequest");
	asset = objc_getClass("PHAsset");
	options = objc_getClass("PHFetchOptions");
	source = [NSURL fileURLWithPath:@"/private/var/vm/mondrian-photo.png"];
	root = [NSURL fileURLWithPath:@"/private/var/mobile/Media/PhotoData"
	    isDirectory:YES];
	if (request == Nil || source == nil) {
		mondrian_probe_fmt("MONDRIAN IMPORT[%d]: no PhotoKit\n", getpid());
		return NULL;
	}
	if (asset != Nil && options != Nil &&
	    [asset respondsToSelector:@selector(fetchAssetsWithOptions:)]) {
		@try {
			existing = [asset performSelector:
			    @selector(fetchAssetsWithOptions:)
			    withObject:[options new]];
		} @catch (id e) {
			existing = nil;
		}
		if (existing != nil &&
		    [existing respondsToSelector:@selector(count)]) {
			have = (unsigned)[existing count];
		}
	}
	mondrian_probe_fmt("MONDRIAN IMPORT[%d]: library has %u, source %s\n",
	    getpid(), have, [[source path] UTF8String]);
	/*
	 * Before the early return: with an asset already in the library the import
	 * has nothing to submit, but the question this probe answers -- whether the
	 * decoder produces colour or black -- is independent of that.
	 */
	mondrian_decode_probe([source path]);
	mondrian_image_probe();
	if (have > 0) {
		mondrian_touch("/private/var/vm/mondrian-imported");
		return NULL;
	}
	/*
	 * Read the picture from the app's own temporary directory: a sandbox
	 * refusal on /private/var/vm would come back as an import error, not as a
	 * permission failure, so this takes the file access out of the question.
	 */
	{
		NSString *tmp = [NSTemporaryDirectory()
		    stringByAppendingPathComponent:@"mondrian-photo.png"];
		NSFileManager *fm = [NSFileManager defaultManager];
		BOOL copied;

		if (tmp == nil) {
			return NULL;
		}
		[fm removeItemAtPath:tmp error:NULL];
		copied = [fm copyItemAtPath:[source path] toPath:tmp
		    error:NULL];
		mondrian_probe_fmt("MONDRIAN IMPORT[%d]: staged %d at %s\n",
		    getpid(), copied ? 1 : 0, [tmp UTF8String]);
		if (copied) {
			source = [NSURL fileURLWithPath:tmp];
			mondrian_decode_probe(tmp);
		}
	}
	shared = nil;
	{
		struct statfs space;

		if (statfs("/private/var/mobile/Media", &space) == 0) {
			unsigned long long size = (unsigned long long)space.f_bsize;
			unsigned long long free_mb = (unsigned long long)space.f_bavail *
			    size / (1024 * 1024);
			unsigned long long total_mb =
			    (unsigned long long)space.f_blocks * size /
			    (1024 * 1024);

			mondrian_probe_fmt(
			    "MONDRIAN IMPORT[%d]: free %llu MB of %llu MB\n",
			    getpid(), free_mb, total_mb);
		}
	}
	if (ph != Nil && [ph respondsToSelector:@selector(sharedPhotoLibrary)]) {		@try {
			shared = [ph performSelector:@selector(sharedPhotoLibrary)];
			mondrian_probe_fmt("MONDRIAN IMPORT[%d]: shared %s\n",
			    getpid(), shared != nil ? "available" : "nil");
		} @catch (id e) {
			mondrian_probe_fmt("MONDRIAN IMPORT[%d]: shared threw %s\n",
			    getpid(), [[e reason] UTF8String]);
			shared = nil;
		}
	}
	if (mondrian_import_submit(shared, request, source, "shared")) {
		return NULL;
	}
	library = mondrian_library_for(root);
	if (mondrian_import_submit(library, request, source, "url")) {
		return NULL;
	}
	(void)mondrian_import_creation(library, source, "creation");
	return NULL;
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
 *
 * Opt-in with a file rather than a boot argument: the command line is at its
 * 607-byte limit, and this probe runs in every hooked process, so a boot that
 * does not ask for it must stay the boot that is known to work.
 * `tools/usb-ring.py wfile /private/var/vm/mondrian-ws LOCAL-FILE`.
 */
#define MONDRIAN_WS_MARKER	"/private/var/vm/mondrian-ws"

static int
window_server_probe_wanted(void)
{
	static int wanted = -1;

	if (wanted < 0) {
		wanted = access(MONDRIAN_WS_MARKER, F_OK) == 0;
	}
	return wanted;
}

/*
 * The dispatch_sync interposer is gone on purpose. Two boots measured what it
 * costs: with the dylib loaded anywhere, the first `dispatch_sync` of a
 * process enters the replacement, the replacement asks dyld for the real
 * symbol (dlsym(RTLD_NEXT)), and a thread already holding dyld's lock parks
 * it there -- SpringBoard's main thread sat in
 * `mondrian_dispatch_sync -> ChronoServices -> SBSystemAppMain` and the panel
 * never left the Apple logo, while containermanagerd never answered
 * backboardd's container query. That is the same dyld deadlock the logging
 * interposers paid for. Name the queue some other way, or not at all.
 */

static void
say_window_server(void)
{
	char line[160];
	int (*is_running)(void);

	/*
	 * No process in the hook set ever asks for the window server: on every
	 * boot so far `+[CAWindowServer server]` was never called, and calling it
	 * from here created the server and stopped the boot dead. The decision
	 * that leaves the port without frames is therefore taken earlier, in
	 * CARenderServerStart, and its companion getter says whether that server
	 * came up at all without doing any of that work.
	 */
	is_running = (int (*)(void))dlsym(RTLD_DEFAULT, "CARenderServerIsRunning");
	snprintf(line, sizeof(line), "MONDRIAN WS: %s render server running %d\n",
	    getprogname(), is_running != NULL ? is_running() : -1);
	say(line);
}

/*
 * Calling `+[CAWindowServer server]` ourselves creates the window server on
 * the spot, and a boot that did it stopped answering on the ring before the
 * first heartbeat pair was over: observing the call is safe, making it is not.
 * So watch who asks and what comes back, and let the system decide when.
 */
static id (*original_server)(id, SEL);

static id
mondrian_server(id self, SEL selector)
{
	id server = original_server(self, selector);
	char line[128];

	snprintf(line, sizeof(line), "MONDRIAN WS: +server -> %p\n", server);
	say(line);
	return server;
}

static void
install_server_hook(void)
{
	Class cls = objc_getClass("CAWindowServer");
	Method method = cls != Nil ? class_getClassMethod(cls, sel_registerName("server")) : NULL;
	IMP implementation;

	if (method == NULL) {
		return;
	}
	implementation = method_getImplementation(method);
	if (implementation == NULL) {
		return;
	}
	original_server = (id (*)(id, SEL))method_setImplementation(method, (IMP)mondrian_server);
	if (original_server != NULL) {
		say("MONDRIAN WS: +server hook installed\n");
	}
}

/*
 * A userland test the boot carries: the first line of
 * /private/var/vm/mondrian-run is a command line, spawn it once with its
 * output on the console, and log the exit status. The ring is the only
 * channel a test program has before there is a shell, and writing the file
 * is one wfile. Runs in SpringBoard only: that is the process the heartbeat
 * thread belongs to, and a spawn from every hooked daemon would multiply it.
 */
static void *
run_waiter(void *argument)
{
	pid_t pid = (pid_t)(intptr_t)argument;
	int status = 0;

	(void)waitpid(pid, &status, 0);
	mondrian_probe_fmt("MONDRIAN RUN: exit 0x%x\n", status);
	return NULL;
}

static void
mondrian_run_once(void)
{
	static char done[512];
	static int primed;
	char text[512], command[512];
	char *argv[17];
	posix_spawn_file_actions_t actions;
	ssize_t n;
	int fd, argc = 0, out = -1, rc;
	pid_t pid = 0;
	pthread_t thread;

	if (__builtin_strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	fd = open("/private/var/vm/mondrian-run", O_RDONLY);
	if (fd < 0) {
		/*
		 * Nothing to prime: if the file was absent at first sight, the next
		 * content is a request from the host, not a leftover.
		 */
		primed = 1;
		return;
	}
	n = read(fd, text, sizeof(text) - 1);
	(void)close(fd);
	if (n <= 0) {
		return;
	}
	text[n] = '\0';
	while (n > 0 && (text[n - 1] == '\n' || text[n - 1] == '\r' ||
	    text[n - 1] == ' ' || text[n - 1] == '\t')) {
		text[--n] = '\0';
	}
	if (n == 0 || __builtin_strcmp(text, done) == 0) {
		return;
	}
	/*
	 * A marker left by an earlier boot is not a request. Measured 2026-11-21:
	 * /private/var/vm/mondrian-run still held /private/var/vm/bt-power, which
	 * no longer exists, and every SpringBoard start tried to spawn it (errno
	 * 2). Prime from whatever the file holds at first sight, exactly like the
	 * open marker; the host writes after the ring is up, so a real request
	 * always differs.
	 */
	if (!primed) {
		primed = 1;
		(void)strlcpy(done, text, sizeof(done));
		return;
	}
	(void)strlcpy(done, text, sizeof(done));
	(void)strlcpy(command, text, sizeof(command));
	for (char *p = strtok(command, " \t"); p != NULL && argc < 16;
	    p = strtok(NULL, " \t")) {
		argv[argc++] = p;
	}
	argv[argc] = NULL;
	/*
	 * /dev/console is the framebuffer console here, which is also the ring:
	 * a test's printf lands beside the kernel's lines.
	 */
	out = open("/dev/console", O_WRONLY);
	if (out >= 0) {
		(void)posix_spawn_file_actions_init(&actions);
		(void)posix_spawn_file_actions_adddup2(&actions, out, STDOUT_FILENO);
		(void)posix_spawn_file_actions_adddup2(&actions, out, STDERR_FILENO);
	} else {
		(void)posix_spawn_file_actions_init(&actions);
	}
	/*
	 * wfile writes the bytes and not the mode: a test uploaded that way is
	 * not executable until this says so.
	 */
	(void)chmod(argv[0], 0755);
	extern char **environ;
	errno = 0;
	rc = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
	mondrian_probe_fmt("MONDRIAN RUN: %s pid %d rc %d errno %d\n",
	    argv[0], (int)pid, rc, errno);
	(void)posix_spawn_file_actions_destroy(&actions);
	if (out >= 0) {
		(void)close(out);
	}
	if (rc == 0) {
		if (pthread_create(&thread, NULL, run_waiter,
		    (void *)(intptr_t)pid) == 0) {
			(void)pthread_detach(thread);
		}
	}
}

/*
 * bluetoothd only powers the chip when a client asks it to, and the Control
 * Center toggle stays inert while the daemon reports no controller. SpringBoard
 * is where the toggle would run, so ask through the same private framework from
 * here: an unsigned child process cannot exec on this root (measured: the hook's
 * posix_spawn of /private/var/vm/bt-power fails), but a dylib injected into
 * SpringBoard runs with its entitlements. The marker file arms it and the loop
 * retries until the daemon reports powered, or forty tries have gone by.
 */
static void
bluetooth_power_dump(id instance)
{
	unsigned int count = 0;
	Method *methods;
	Ivar *ivars;
	unsigned int i;

	methods = class_copyMethodList(object_getClass(instance), &count);
	mondrian_probe_fmt("MONDRIAN BTPOWER: %u methods\n", count);
	for (i = 0; i < count; i++) {
		const char *name = sel_getName(method_getName(methods[i]));

		if (strstr(name, "ower") != NULL || strstr(name, "XPC") != NULL ||
		    strstr(name, "send") != NULL || strstr(name, "connect") != NULL) {
			mondrian_probe_fmt("MONDRIAN BTPOWER:   - %s\n", name);
		}
	}
	free(methods);
	ivars = class_copyIvarList(object_getClass(instance), &count);
	mondrian_probe_fmt("MONDRIAN BTPOWER: %u ivars\n", count);
	for (i = 0; i < count; i++) {
		const char *name = ivar_getName(ivars[i]);
		const char *type = ivar_getTypeEncoding(ivars[i]);
		id value;

		if (type == NULL || type[0] != '@') {
			mondrian_probe_fmt("MONDRIAN BTPOWER:   %s %s\n", name,
			    type != NULL ? type : "?");
			continue;
		}
		value = object_getIvar(instance, ivars[i]);
		mondrian_probe_fmt("MONDRIAN BTPOWER:   %s -> %s\n", name,
		    value != nil ? class_getName(object_getClass(value)) : "nil");
	}
	free(ivars);
}

static int
bluetooth_has_ivar(Class cls, const char *needle)
{
	unsigned int count = 0;
	Ivar *ivars;
	unsigned int i;
	int found = 0;

	ivars = class_copyIvarList(cls, &count);
	for (i = 0; i < count; i++) {
		const char *name = ivar_getName(ivars[i]);

		if (name != NULL && strstr(name, needle) != NULL) {
			found = 1;
		}
	}
	free(ivars);
	return found;
}

static void
bluetooth_power_native(id instance, void *library)
{
	static const char *const names[] = {
		"BTLocalDeviceSetPowerState",
		"BTLocalDeviceGetPowerState",
		"BTLocalDeviceGetDefault",
		"BTSessionAttachWithQueue",
		"BTSessionDetachWithQueue",
		"BluetoothLocalDeviceSetPowerState",
		"BTLocalDevicePower",
	};
	Class cls = object_getClass(instance);
	Ivar device_ivar = class_getInstanceVariable(cls, "_localDevice");
	Ivar session_ivar = class_getInstanceVariable(cls, "_session");
	Ivar available_ivar = class_getInstanceVariable(cls, "_available");
	void *device = NULL;
	void *session = NULL;
	int available = -99;
	unsigned int i;

	if (device_ivar != NULL) {
		device = *(void **)((char *)instance + ivar_getOffset(device_ivar));
	}
	if (session_ivar != NULL) {
		session = *(void **)((char *)instance + ivar_getOffset(session_ivar));
	}
	if (available_ivar != NULL) {
		available = *(int *)((char *)instance + ivar_getOffset(available_ivar));
	}
	mondrian_probe_fmt("MONDRIAN BTPOWER: ivars device %p session %p available %d\n",
	    device, session, available);
	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		void *symbol = dlsym(library != NULL ? library : RTLD_DEFAULT, names[i]);

		mondrian_probe_fmt("MONDRIAN BTPOWER: sym %s %p\n", names[i], symbol);
	}
	if (device != NULL) {
		int (*set_state)(void *, int) = (int (*)(void *, int))
		    dlsym(library != NULL ? library : RTLD_DEFAULT,
		    "BTLocalDeviceSetPowerState");

		if (set_state != NULL) {
			int result = set_state(device, 1);

			mondrian_probe_fmt("MONDRIAN BTPOWER: C set state 1 -> %d\n",
			    result);
		}
	}
}

static void
bluetooth_scan_once(id manager)
{
	static int done;
	static const char *const candidates[] = {
		"startScan",
		"startScanning",
		"scan",
		"startDiscovery",
		"startScanForDevices",
		"scanForDevices",
	};
	Class cls = object_getClass(manager);
	unsigned int i;

	if (done) {
		return;
	}
	for (i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
		SEL sel = sel_registerName(candidates[i]);
		Method method = class_getInstanceMethod(cls, sel);

		if (method == NULL) {
			continue;
		}
		mondrian_probe_fmt("MONDRIAN BTSCAN: %s args %u type %s\n",
		    candidates[i], method_getNumberOfArguments(method),
		    method_getTypeEncoding(method));
		if (method_getNumberOfArguments(method) == 2) {
			((void (*)(id, SEL))objc_msgSend)(manager, sel);
			mondrian_probe_fmt("MONDRIAN BTSCAN: called %s\n",
			    candidates[i]);
			done = 1;
			return;
		}
	}
	/*
	 * None of the guessed selectors exists with no arguments: list what
	 * the class actually has so the next build calls the right one.
	 */
	{
		unsigned int count = 0;
		Method *methods = class_copyMethodList(cls, &count);

		for (i = 0; i < count; i++) {
			const char *name = sel_getName(method_getName(methods[i]));

			if (strstr(name, "can") != NULL ||
			    strstr(name, "Scan") != NULL ||
			    strstr(name, "iscover") != NULL ||
			    strstr(name, "Discover") != NULL) {
				mondrian_probe_fmt("MONDRIAN BTSCAN: - %s args %u\n",
				    name, method_getNumberOfArguments(methods[i]));
			}
		}
		free(methods);
		done = 1;
	}
}

/*
 * The Settings row for Bluetooth is drawn only when BluetoothManager reports a
 * controller, so the root list hides it while the daemon has no client. The
 * pane itself still exists (Preferences.app carries the prefs:root=Bluetooth
 * specifier), and opening it by URL tells the two cases apart: a pane that
 * loads with a working toggle means only the row is gated; a pane that says
 * unavailable points at the daemon's client path.
 */
static void
bluetooth_open_pane(void)
{
	static int attempt;
	static const char *const urls[] = {
		"app-prefs:root=Bluetooth",
		"App-prefs:Bluetooth",
		"prefs:root=Bluetooth",
	};
	static NSURL *url;
	static int done;
	Class workspace_class;
	id workspace;
	BOOL opened;

	if (done || !mondrian_file_on("/private/var/vm/bt-openpane") ||
	    __builtin_strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	if (attempt >= (int)(sizeof(urls) / sizeof(urls[0]))) {
		done = 1;
		return;
	}
	/*
	 * The Preferences bundle declares the app-prefs scheme (measured from
	 * its Info.plist), so a prefs: URL is not the one to hand to
	 * LaunchServices. Try one per tick and stop at the first that opens.
	 */
	url = [NSURL URLWithString:[NSString stringWithUTF8String:
	    urls[attempt]]];
	attempt++;
	workspace_class = objc_getClass("LSApplicationWorkspace");
	workspace = workspace_class != Nil ?
	    ((id (*)(id, SEL))objc_msgSend)((id)workspace_class,
	    sel_registerName("defaultWorkspace")) : nil;
	mondrian_probe_fmt("MONDRIAN BTPANE: %s workspace %p url %p\n",
	    urls[attempt - 1], workspace, url);
	if (workspace != nil && url != nil) {
		opened = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace,
		    sel_registerName("openSensitiveURL:withOptions:"), url, nil);
		mondrian_probe_fmt("MONDRIAN BTPANE: open -> %d\n", opened);
		done = opened;
	}
}

/*
 * BluetoothManager leaves _session NULL on this root, so nothing asks the
 * daemon for a local device and Settings hides the row. The framework's own
 * private C API is the reliable way in: attach a session with a callback, then
 * take the default local device and power it. The event numbers are logged
 * rather than decoded, because the header is not in the SDK.
 */
typedef struct BTSessionImpl *BTSession;
typedef struct BTLocalDeviceImpl *BTLocalDevice;
typedef void (*bt_session_callback_t)(BTSession session, int event,
    int result);

static void *bluetooth_manager_library;

static void
bluetooth_session_event(BTSession session, int event, int result)
{
	BTLocalDevice device = NULL;
	int (*get_default)(BTSession, BTLocalDevice *);
	int (*set_power)(BTLocalDevice, int);
	int status = -1;

	mondrian_probe_fmt("MONDRIAN BTSESSION: event %d result %d session %p\n",
	    event, result, session);
	if (result != 0 || session == NULL) {
		return;
	}
	get_default = (int (*)(BTSession, BTLocalDevice *))
	    dlsym(bluetooth_manager_library, "BTLocalDeviceGetDefault");
	if (get_default != NULL) {
		status = get_default(session, &device);
	}
	mondrian_probe_fmt("MONDRIAN BTSESSION: device %p result %d\n",
	    device, status);
	set_power = (int (*)(BTLocalDevice, int))
	    dlsym(bluetooth_manager_library, "BTLocalDeviceSetPowerState");
	if (device != NULL && set_power != NULL) {
		mondrian_probe_fmt("MONDRIAN BTSESSION: power 1 -> %d\n",
		    set_power(device, 1));
	}
}

static void
bluetooth_session_attach(void)
{
	static int attached;
	int (*attach)(char *, bt_session_callback_t, void *, dispatch_queue_t);
	int result;

	if (attached || bluetooth_manager_library == NULL ||
	    !mondrian_file_on("/private/var/vm/bt-client")) {
		return;
	}
	attached = 1;
	attach = (int (*)(char *, bt_session_callback_t, void *,
	    dispatch_queue_t))dlsym(bluetooth_manager_library,
	    "BTSessionAttachWithQueue");
	if (attach == NULL) {
		mondrian_probe_fmt("MONDRIAN BTSESSION: no attach\n");
		return;
	}
	result = attach("MondrianSettings", bluetooth_session_event, NULL,
	    dispatch_get_main_queue());
	mondrian_probe_fmt("MONDRIAN BTSESSION: attach -> %d\n", result);
}

/*
 * Everything the client side can be refused on, in one dump: the framework's
 * own init error, the entitlements SecTask sees for this process, and whether
 * the legacy Mach channel to bluetoothd opens at all. The attach itself fails
 * with 9 here, and none of these three is visible from the daemon side.
 */
static void
bluetooth_diag(id manager)
{
	static const char *const entitlements[] = {
		"com.apple.bluetooth.system",
		"com.apple.bluetooth.internal",
		"com.apple.bluetooth",
	};
	void *security;
	void *(*create_from_self)(CFAllocatorRef);
	CFTypeRef (*copy_entitlement)(void *, CFStringRef, void *);
	mach_port_t (*server_port)(void);
	unsigned int i;

	mondrian_probe_fmt("MONDRIAN BTDIAG: lastInitError %d\n",
	    ((int (*)(id, SEL))objc_msgSend)(object_getClass(manager),
	    sel_registerName("lastInitError")));
	server_port = (mach_port_t (*)(void))dlsym(bluetooth_manager_library,
	    "ServerPort");
	if (server_port != NULL) {
		mondrian_probe_fmt("MONDRIAN BTDIAG: ServerPort -> %u\n",
		    server_port());
	} else {
		mondrian_probe_fmt("MONDRIAN BTDIAG: no ServerPort\n");
	}
	security = dlopen("/System/Library/Frameworks/Security.framework/"
	    "Security", RTLD_NOW);
	create_from_self = security != NULL ?
	    dlsym(security, "SecTaskCreateFromSelf") : NULL;
	copy_entitlement = security != NULL ?
	    dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
	if (create_from_self == NULL || copy_entitlement == NULL) {
		mondrian_probe_fmt("MONDRIAN BTDIAG: no SecTask\n");
		return;
	}
	{
		void *task = create_from_self(kCFAllocatorDefault);

		for (i = 0; i < sizeof(entitlements) / sizeof(entitlements[0]);
		    i++) {
			CFStringRef name = CFStringCreateWithCString(
			    kCFAllocatorDefault, entitlements[i],
			    kCFStringEncodingUTF8);
			CFTypeRef value = copy_entitlement(task, name, NULL);
			int granted = value != NULL &&
			    CFGetTypeID(value) == CFBooleanGetTypeID() &&
			    CFBooleanGetValue(value);

			mondrian_probe_fmt("MONDRIAN BTDIAG: %s -> %d\n",
			    entitlements[i], granted);
			if (value != NULL) {
				CFRelease(value);
			}
			CFRelease(name);
		}
		CFRelease(task);
	}
}

/*
 * The attach fails with no IPC, no TCC query and no MobileGestalt answer, so
 * the refusal is inside the client framework. Its own strings name the check:
 * scan the loaded images of BluetoothManager and MobileBluetooth for the few
 * keywords that can gate an attach and print them.
 */
static void
bluetooth_scan_strings(const char *path, uintptr_t base,
    const struct mach_header_64 *header)
{
	static const char *const keywords[] = {
		"entitl", "thoriz", "TCC", "not supported", "unavailable",
		"com.apple.bluetooth",
	};
	static int budget = 80;
	const struct load_command *command;
	uint64_t text_vmaddr = 0;
	uint32_t index;

	if (budget <= 0 || header->magic != MH_MAGIC_64) {
		return;
	}
	command = (const struct load_command *)(header + 1);
	for (index = 0; index < header->ncmds && budget > 0; index++) {
		const struct segment_command_64 *segment;
		const unsigned char *bytes;
		uint64_t size;
		uint64_t at;
		unsigned int k;

		if (command->cmd != LC_SEGMENT_64) {
			command = (const struct load_command *)
			    ((uintptr_t)command + command->cmdsize);
			continue;
		}
		segment = (const struct segment_command_64 *)command;
		if (strcmp(segment->segname, "__TEXT") == 0) {
			text_vmaddr = segment->vmaddr;
		}
		/* Shared-cache images carry their preferred addresses. */
		bytes = (const unsigned char *)(segment->vmaddr + base -
		    text_vmaddr);
		size = segment->vmsize;
		if (text_vmaddr == 0 ||
		    strcmp(segment->segname, "__LINKEDIT") == 0) {
			size = 0;
		}
		for (at = 0; at + 5 < size && budget > 0; at++) {
			char run[160];
			uint64_t start = at;
			uint64_t length;

			if (bytes[at] < 0x20 || bytes[at] > 0x7e) {
				continue;
			}
			while (at < size && bytes[at] >= 0x20 &&
			    bytes[at] <= 0x7e) {
				at++;
			}
			length = at - start;
			if (length < 8) {
				continue;
			}
			if (length > sizeof(run) - 1) {
				length = sizeof(run) - 1;
			}
			memcpy(run, bytes + start, (size_t)length);
			run[length] = '\0';
			for (k = 0; k < sizeof(keywords) / sizeof(keywords[0]);
			    k++) {
				if (strstr(run, keywords[k]) != NULL) {
					budget--;
					mondrian_probe_fmt(
					    "MONDRIAN BTFW: %s: %.140s\n",
					    path, run);
					break;
				}
			}
		}
		command = (const struct load_command *)
		    ((uintptr_t)command + command->cmdsize);
	}
}

static void
bluetooth_dump_framework_strings(void)
{
	unsigned int count = _dyld_image_count();
	unsigned int i;

	for (i = 0; i < count; i++) {
		const struct mach_header *header = _dyld_get_image_header(i);
		const char *path = _dyld_get_image_name(i);

		if (header == NULL || path == NULL) {
			continue;
		}
		if (strstr(path, "BluetoothManager.framework") == NULL &&
		    strstr(path, "MobileBluetooth.framework") == NULL) {
			continue;
		}
		mondrian_probe_fmt("MONDRIAN BTFW: image %s at %p\n", path,
		    header);
		bluetooth_scan_strings(path, (uintptr_t)header,
		    (const struct mach_header_64 *)header);
	}
}

/*
 * The attach refuses with 9 after the entitlement queries come back true, so
 * the branch that refuses is in the function itself. Its code is written as
 * hex from the loaded image: the framework lives in the shared cache, whose
 * file is not on this root, and 2 KB around the entry point is enough to see
 * the test that returns the error.
 */
static void
bluetooth_dump_attach_code(void)
{
	void *function = dlsym(bluetooth_manager_library,
	    "BTSessionAttachWithQueue");
	char path[] = "/private/var/mobile/Library/Preferences/bt-fn.hex";
	unsigned char bytes[2048];
	Dl_info info;
	int fd;
	int written;

	if (function == NULL || dladdr(function, &info) == 0) {
		mondrian_probe_fmt("MONDRIAN BTCODE: no function\n");
		return;
	}
	mondrian_probe_fmt("MONDRIAN BTCODE: %p %s+0x%lx\n", function,
	    info.dli_fname,
	    (unsigned long)((uintptr_t)function - (uintptr_t)info.dli_fbase));
	memcpy(bytes, function, sizeof(bytes));
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		mondrian_probe_fmt("MONDRIAN BTCODE: open %d\n", errno);
		return;
	}
	for (written = 0; written < (int)sizeof(bytes); written += 32) {
		char line[80];
		int at = 0;
		int index;

		for (index = 0; index < 32; index++) {
			at += snprintf(line + at, sizeof(line) - (size_t)at,
			    "%02x", bytes[written + index]);
		}
		line[at++] = '\n';
		if (write(fd, line, (size_t)at) != at) {
			break;
		}
	}
	close(fd);
	mondrian_probe_fmt("MONDRIAN BTCODE: %d bytes written\n", written);
}

/* Name the function behind a PLT stub: symbol first, then its GOT slot. */
static void
bluetooth_name_stub(void *target)
{
	const uint32_t *code = target;
	uint64_t adrp = 0;
	Dl_info info;
	int index;

	if (dladdr(target, &info) != 0 && info.dli_sname != NULL) {
		mondrian_probe_fmt("MONDRIAN BTCALL: %p %s\n", target,
		    info.dli_sname);
		return;
	}
	for (index = 0; index < 4; index++) {
		uint32_t word = code[index];

		if ((word & 0x9F000000u) == 0x90000000u) {
			int64_t immhi = (int64_t)((word >> 5) & 0x7FFFF);
			int64_t imm = (immhi << 2) | ((word >> 29) & 3);
			uint64_t pc = (uintptr_t)target +
			    (uint64_t)index * 4;

			if (imm & (1 << 20)) {
				imm -= (1 << 21);
			}
			adrp = (pc & ~0xFFFull) + (uint64_t)(imm << 12);
			continue;
		}
		if ((word & 0xFFC00000u) == 0xF9400000u && adrp != 0) {
			void *pointer = *(void **)(adrp +
			    (((word >> 10) & 0xFFF) * 8));

			if (dladdr(pointer, &info) != 0) {
				mondrian_probe_fmt(
				    "MONDRIAN BTCALL: %p -> %s\n", target,
				    info.dli_sname != NULL ? info.dli_sname :
				    info.dli_fname);
			}
			return;
		}
	}
	mondrian_probe_fmt("MONDRIAN BTCALL: %p unresolved\n", target);
}

/*
 * Two C-string arguments gate the attach with inverted polarity, and their
 * pages are far enough from the image that the dump above cannot resolve them.
 * Decoding ADRP+ADD in the entry point recovers both literals, and each BL
 * lands in a stub whose image dladdr names.
 */
static void
bluetooth_dump_call_strings(void)
{
	void *function = dlsym(bluetooth_manager_library,
	    "BTSessionAttachWithQueue");
	const uint32_t *code = function;
	uint64_t adrp = 0;
	int index;

	if (function == NULL) {
		return;
	}
	for (index = 0; index < 120; index++) {
		uint32_t word = code[index];
		uint64_t pc = (uintptr_t)function + (uint64_t)index * 4;

		if ((word & 0x9F000000u) == 0x90000000u &&
		    (word & 0x1Fu) == 0) {
			int64_t immhi = (int64_t)((word >> 5) & 0x7FFFF);
			int64_t imm = (immhi << 2) | ((word >> 29) & 3);

			if (imm & (1 << 20)) {
				imm -= (1 << 21);
			}
			adrp = (pc & ~0xFFFull) + (uint64_t)(imm << 12);
			continue;
		}
		if ((word & 0xFFC00000u) == 0x91000000u &&
		    ((word >> 5) & 0x1Fu) == 0 && adrp != 0) {
			const char *text = (const char *)(adrp +
			    ((word >> 10) & 0xFFF));

			mondrian_probe_fmt("MONDRIAN BTSTR: %p %.120s\n",
			    text, text);
			adrp = 0;
			continue;
		}
		if ((word & 0xFC000000u) == 0x94000000u) {
			int64_t imm = word & 0x3FFFFFF;
			void *target;
			Dl_info info;

			if (imm & 0x2000000) {
				imm -= 0x4000000;
			}
			target = (void *)(pc + (uint64_t)(imm << 2));
			if (dladdr(target, &info) != 0) {
				mondrian_probe_fmt("MONDRIAN BTCALL: %s+0x%lx\n",
				    info.dli_fname, (unsigned long)
				    ((uintptr_t)target -
				    (uintptr_t)info.dli_fbase));
			}
			bluetooth_name_stub(target);
		}
	}
}

/*
 * The whole __cstring of MobileBluetooth, written to the app's own container
 * so the host can read the vocabulary of the framework: the error the attach
 * returns and the names it tests are strings, and guessing them from a keyword
 * filter has already missed twice.
 */
static void
bluetooth_dump_cstrings(void)
{
	char path[] = "/private/var/mobile/Library/Preferences/bt-cstr.bin";
	unsigned int count = _dyld_image_count();
	unsigned int image;

	for (image = 0; image < count; image++) {
		const struct mach_header_64 *header =
		    (const struct mach_header_64 *)_dyld_get_image_header(image);
		const char *name = _dyld_get_image_name(image);
		const struct load_command *command;
		uint64_t text_base = 0;
		uint64_t text_vmaddr = 0;
		uint32_t index;

		if (header == NULL || name == NULL ||
		    strstr(name, "MobileBluetooth.framework") == NULL ||
		    header->magic != MH_MAGIC_64) {
			continue;
		}
		command = (const struct load_command *)(header + 1);
		for (index = 0; index < header->ncmds; index++) {
			const struct segment_command_64 *segment;

			if (command->cmd != LC_SEGMENT_64) {
				command = (const struct load_command *)
				    ((uintptr_t)command + command->cmdsize);
				continue;
			}
			segment = (const struct segment_command_64 *)command;
			if (strcmp(segment->segname, "__TEXT") == 0) {
				text_base = (uintptr_t)header;
				text_vmaddr = segment->vmaddr;
			}
			if (text_vmaddr != 0 &&
			    strcmp(segment->segname, "__TEXT") == 0) {
				const struct section_64 *section =
				    (const struct section_64 *)(segment + 1);
				uint32_t at;

				for (at = 0; at < segment->nsects; at++) {
					if (strcmp(section[at].sectname,
					    "__cstring") != 0) {
						continue;
					}
					{
						const void *bytes = (const void *)
						    (section[at].addr + text_base -
						    text_vmaddr);
						int fd = open(path, O_WRONLY |
						    O_CREAT | O_TRUNC, 0644);
						size_t size = section[at].size;

						if (size > 65536) {
							size = 65536;
						}
						if (fd < 0) {
							mondrian_probe_fmt(
							    "MONDRIAN CSTR: open %d\n",
							    errno);
							return;
						}
						mondrian_probe_fmt(
						    "MONDRIAN CSTR: %lu bytes\n",
						    (unsigned long)size);
						(void)write(fd, bytes, size);
						close(fd);
					}
				}
			}
			command = (const struct load_command *)
			    ((uintptr_t)command + command->cmdsize);
		}
	}
}

/*
 * `_session` and `_localDevice` are the two pointers the framework walks when
 * it is told to power the controller. Both are NULL until BluetoothManager's
 * own session setup runs, which needs a live bluetoothd; a direct
 * BTSessionAttachWithQueue returning 0 is not enough. Measured 2026-11-20:
 * forcing `available` and calling setPowered: with session 0x0 makes
 * MobileBluetooth jump through a NULL BTLocalDeviceSetPowerState and SpringBoard
 * dies with SIGBUS (pc == far) before its first commit.
 */
static void *
bluetooth_manager_pointer(id instance, const char *name)
{
	Ivar ivar = class_getInstanceVariable(object_getClass(instance), name);

	if (ivar == NULL) {
		return NULL;
	}
	return *(void **)((char *)instance + ivar_getOffset(ivar));
}

static void
bluetooth_power_once(void)
{
	static Class manager_class;
	static id manager_instance;
	static void *manager_library;
	static SEL responds_sel;
	static SEL set_powered_sel;
	static SEL powered_sel;
	static SEL available_sel;
	static SEL set_value_sel;
	static int attempts;
	static int dumped;
	BOOL (*responds_to)(id, SEL, SEL);
	BOOL (*is_powered)(id, SEL);
	void (*set_powered_fn)(id, SEL, BOOL);

	if (attempts >= 300 || __builtin_strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	if (!mondrian_file_on("/private/var/vm/bt-power")) {
		return;
	}
	attempts++;
	if (manager_class == Nil) {
		void *library;

		library = dlopen("/System/Library/PrivateFrameworks/"
		    "BluetoothManager.framework/BluetoothManager", RTLD_NOW);
		manager_library = library;
		bluetooth_manager_library = library;
		mondrian_probe_fmt("MONDRIAN BTPOWER: dlopen %s\n",
		    library != NULL ? "ok" : dlerror());
		manager_class = objc_getClass("BluetoothManager");
		if (manager_class == Nil) {
			return;
		}
		responds_sel = sel_registerName("respondsToSelector:");
		set_powered_sel = sel_registerName("setPowered:");
		powered_sel = sel_registerName("powered");
		available_sel = sel_registerName("available");
		set_value_sel = sel_registerName("setValue:forKey:");
		manager_instance = ((id (*)(id, SEL))objc_msgSend)((id)manager_class,
		    sel_registerName("sharedInstance"));
		mondrian_probe_fmt("MONDRIAN BTPOWER: instance %p\n", manager_instance);
	}
	if (manager_instance == Nil) {
		return;
	}
	bluetooth_session_attach();
	responds_to = (BOOL (*)(id, SEL, SEL))objc_msgSend;
	is_powered = (BOOL (*)(id, SEL))objc_msgSend;
	if (!dumped) {
		static const char *const services[] = {
			"com.apple.server.bluetooth",
			"com.apple.bluetooth.xpc",
			"com.apple.BlueTool",
		};
		unsigned int service;

		dumped = 1;
		bluetooth_power_dump(manager_instance);
		bluetooth_power_native(manager_instance, manager_library);
		bluetooth_diag(manager_instance);
		if (mondrian_file_on("/private/var/vm/bt-lookup")) {
			bluetooth_dump_framework_strings();
			bluetooth_dump_attach_code();
			bluetooth_dump_call_strings();
			bluetooth_dump_cstrings();
		}
		for (service = 0; service < 3; service++) {
			mach_port_t port = MACH_PORT_NULL;
			kern_return_t kr;

			kr = bootstrap_look_up(bootstrap_port, services[service], &port);
			mondrian_probe_fmt("MONDRIAN BTPOWER: lookup %s kr %d port %u\n",
			    services[service], kr, port);
			if (port != MACH_PORT_NULL) {
				mach_port_deallocate(mach_task_self(), port);
			}
		}
		mondrian_probe_fmt("MONDRIAN BTPOWER: available %d powered %d\n",
		    responds_to(manager_instance, responds_sel, available_sel) ?
		    is_powered(manager_instance, available_sel) : -1,
		    is_powered(manager_instance, powered_sel));
		/*
		 * The framework refuses to send the power message while it believes
		 * there is no controller. KVC reaches the ivar behind the readonly
		 * property, so set it and let the regular path send the request.
		 */
		if (mondrian_file_on("/private/var/vm/bt-force") &&
		    bluetooth_manager_pointer(manager_instance, "_session") != NULL &&
		    bluetooth_manager_pointer(manager_instance, "_localDevice") != NULL &&
		    responds_to(manager_instance, responds_sel,
		    sel_registerName("setValue:forKey:")) &&
		    bluetooth_has_ivar(object_getClass(manager_instance),
		    "vailable")) {
			((void (*)(id, SEL, id, id))objc_msgSend)(manager_instance,
			    set_value_sel, (id)kCFBooleanTrue, (id)CFSTR("available"));
			mondrian_probe_fmt("MONDRIAN BTPOWER: available forced\n");
		} else {
			mondrian_probe_fmt("MONDRIAN BTPOWER: available held, session %p"
			    " device %p\n",
			    bluetooth_manager_pointer(manager_instance, "_session"),
			    bluetooth_manager_pointer(manager_instance, "_localDevice"));
		}
	}
	if (attempts % 5 == 0) {
		mondrian_probe_fmt("MONDRIAN BTPOWER: try %d available %d powered %d"
		    " session %p device %p\n", attempts,
		    responds_to(manager_instance, responds_sel, available_sel) ?
		    is_powered(manager_instance, available_sel) : -1,
		    is_powered(manager_instance, powered_sel),
		    bluetooth_manager_pointer(manager_instance, "_session"),
		    bluetooth_manager_pointer(manager_instance, "_localDevice"));
	}
	if (is_powered(manager_instance, powered_sel)) {
		mondrian_probe_fmt("MONDRIAN BTPOWER: powered after %d tries"
		    " available %d session %p device %p\n", attempts,
		    responds_to(manager_instance, responds_sel, available_sel) ?
		    is_powered(manager_instance, available_sel) : -1,
		    bluetooth_manager_pointer(manager_instance, "_session"),
		    bluetooth_manager_pointer(manager_instance, "_localDevice"));
		bluetooth_scan_once(manager_instance);
		attempts = 300;
		return;
	}
	if (!responds_to(manager_instance, responds_sel, set_powered_sel)) {
		mondrian_probe_fmt("MONDRIAN BTPOWER: no setPowered:\n");
		attempts = 300;
		return;
	}
	set_powered_fn = (void (*)(id, SEL, BOOL))objc_msgSend;
	/*
	 * Writing the ivar and calling the setter are behind their own marker.
	 * Measured 2026-11-21: with bt-client and bt-power armed, every
	 * SpringBoard start crashes inside MobileBluetooth about two seconds
	 * after its session appears (SIGBUS, pc == far); with the markers off
	 * the same boot has no SpringBoard crash at all. The framework's own
	 * setup is not to be poked until this is understood.
	 */
	if (!mondrian_file_on("/private/var/vm/bt-force")) {
		return;
	}
	if (bluetooth_manager_pointer(manager_instance, "_session") == NULL ||
	    bluetooth_manager_pointer(manager_instance, "_localDevice") == NULL) {
		if (attempts <= 3 || attempts % 10 == 0) {
			mondrian_probe_fmt("MONDRIAN BTPOWER: setPowered held (try %d)"
			    " session %p device %p\n", attempts,
			    bluetooth_manager_pointer(manager_instance, "_session"),
			    bluetooth_manager_pointer(manager_instance, "_localDevice"));
		}
		return;
	}
	if (attempts <= 3 || attempts % 10 == 0) {
		mondrian_probe_fmt("MONDRIAN BTPOWER: setPowered YES (try %d)\n",
		    attempts);
	}
	set_powered_fn(manager_instance, set_powered_sel, YES);
}

/*
 * The software keyboard's geometry, on demand.
 *
 * The panel is 480x1066 pt, and the keyboard lays its ten-key row out for 480
 * pt correctly: the keys measure 42 pt wide on a 48 pt pitch (measured
 * 2026-11-21 on Spotlight's keyboard). The row is nevertheless drawn about 35
 * pt too far right, so its last column is clipped by the screen. That number
 * is the whole question: a 480-pt plane inside a wider window, a plane offset
 * inside a 480-pt window, or a window offset in a scene that is not the
 * screen. `mondrianwin=1` cannot answer it -- it dumps 100 s into every
 * process, and it cannot be aimed at the moment the keyboard is up -- so this
 * one is asked for with a file. Rewrite /private/var/vm/mondrian-kbd and each
 * hooked process prints its screen, its window list, and the view tree of any
 * window whose class says keyboard with every frame in window coordinates.
 *
 * The print is on the main queue: UIKit's screen and window accessors belong to
 * the main thread and raise from another one (the same reason the screen
 * report is queued).
 */
/*
 * The layout and the keyplane, wherever they are in this process's tree: their
 * frames are the number the whole keyboard question turns on. A visible
 * keyboard drawn from a hidden plane (a snapshot or a remote layer) shows the
 * offset here as well, which is why this does not filter by hidden.
 */
static void
mondrian_kbd_plane_walk(id view, unsigned depth, unsigned *lines)
{
	char line[200];
	const char *name;
	NSArray *kids;
	unsigned count, i;
	CGRect rect;
	BOOL hidden;
	CGFloat alpha;

	if (view == nil || depth > 16 || *lines >= 40) {
		return;
	}
	name = object_getClassName(view);
	if (name != NULL &&
	    (strstr(name, "KeyboardLayout") != NULL ||
	    strstr(name, "Keyplane") != NULL ||
	    strstr(name, "KeyPlane") != NULL)) {
		rect = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("bounds"));
		rect = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(view,
		    sel_registerName("convertRect:toView:"), rect, nil);
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("isHidden"));
		alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("alpha"));
		snprintf(line, sizeof(line),
		    "MONDRIAN KBP: d%u %s %.1f,%.1f %.1fx%.1f hid %d a %.2f\n",
		    depth, name, rect.origin.x, rect.origin.y, rect.size.width,
		    rect.size.height, hidden, alpha);
		say(line);
		(*lines)++;
	}
	kids = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
	if (kids == nil) {
		return;
	}
	count = (unsigned)[(NSArray *)kids count];
	for (i = 0; i < count; i++) {
		mondrian_kbd_plane_walk([(NSArray *)kids objectAtIndex:i],
		    depth + 1, lines);
	}
}

static void
mondrian_kbd_walk(id view, unsigned depth, unsigned *lines)
{
	char line[256];
	CGRect rect;
	const char *name;
	NSArray *kids;
	unsigned count, i;
	BOOL hidden;
	CGFloat alpha;

	if (view == nil || depth > 8 || *lines >= 80) {
		return;
	}
	rect = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("bounds"));
	rect = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(view,
	    sel_registerName("convertRect:toView:"), rect, nil);
	name = object_getClassName(view);
	hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isHidden"));
	alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(view, sel_registerName("alpha"));
	snprintf(line, sizeof(line),
	    "MONDRIAN KBD: %*s%s %.1f,%.1f %.1fx%.1f hid %d a %.2f\n",
	    (int)(depth * 2), "", name != NULL ? name : "?", rect.origin.x,
	    rect.origin.y, rect.size.width, rect.size.height, hidden, alpha);
	say(line);
	(*lines)++;
	kids = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
	if (kids == nil) {
		return;
	}
	count = (unsigned)[(NSArray *)kids count];
	for (i = 0; i < count; i++) {
		mondrian_kbd_walk([(NSArray *)kids objectAtIndex:i], depth + 1, lines);
	}
}

/*
 * The rendered side. The keyboard is a scene another process owns, so the
 * frames inside it are not in this process's UIKit tree; what is here is the
 * layer host and the layer it presents. Its bounds say which point space the
 * keyboard was drawn for, and a host wider than the screen with the content
 * centred in it is the clipped column's cause.
 */
typedef struct {
	CGFloat top;
	CGFloat left;
	CGFloat bottom;
	CGFloat right;
} mondrian_kbd_insets;

/* Defined with the layout probe below; the marker dump lists what is here. */
static void mondrian_kl_list(void);

static void
mondrian_kbd_layers(id view)
{
	char line[224];
	id layer;
	NSArray *sublayers;
	CGRect bounds, frame;
	unsigned count, i;

	layer = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("layer"));
	if (layer == nil) {
		return;
	}
	bounds = ((CGRect (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("bounds"));
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("frame"));
	snprintf(line, sizeof(line),
	    "MONDRIAN KBD: layer %s b %.1fx%.1f f %.1f,%.1f %.1fx%.1f\n",
	    object_getClassName(layer), bounds.size.width, bounds.size.height,
	    frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
	say(line);
	sublayers = ((id (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("sublayers"));
	if (sublayers == nil) {
		return;
	}
	count = (unsigned)[(NSArray *)sublayers count];
	snprintf(line, sizeof(line), "MONDRIAN KBD: sublayers %u\n", count);
	say(line);
	for (i = 0; i < count && i < 8; i++) {
		id sub = [(NSArray *)sublayers objectAtIndex:i];

		bounds = ((CGRect (*)(id, SEL))objc_msgSend)(sub,
		    sel_registerName("bounds"));
		frame = ((CGRect (*)(id, SEL))objc_msgSend)(sub,
		    sel_registerName("frame"));
		snprintf(line, sizeof(line),
		    "MONDRIAN KBD: sub %u %s b %.1fx%.1f f %.1f,%.1f"
		    " %.1fx%.1f\n", i, object_getClassName(sub),
		    bounds.size.width, bounds.size.height, frame.origin.x,
		    frame.origin.y, frame.size.width, frame.size.height);
		say(line);
	}
}

static void
mondrian_kbd_find(id view, unsigned depth, id *best, CGFloat *best_area)
{
	const char *name;
	NSArray *kids;
	unsigned count, i;

	if (view == nil || depth > 14) {
		return;
	}
	name = object_getClassName(view);
	if (name != NULL && strstr(name, "Keyboard") != NULL) {
		CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("bounds"));

		rect = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(view,
		    sel_registerName("convertRect:toView:"), rect, nil);
		if (rect.size.width * rect.size.height > *best_area) {
			*best_area = rect.size.width * rect.size.height;
			*best = view;
		}
	}
	kids = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
	if (kids == nil) {
		return;
	}
	count = (unsigned)[(NSArray *)kids count];
	for (i = 0; i < count; i++) {
		mondrian_kbd_find([(NSArray *)kids objectAtIndex:i], depth + 1,
		    best, best_area);
	}
}

/*
 * The window list is not where the keyboard's layout lives: the visible one is
 * a subtree of a text-effects window in the process that owns the field, and
 * the only window that names itself keyboard is a hidden Medusa leftover. Find
 * the view and print the chain from its window down, then its own tree; the
 * offset is in that chain and nowhere else.
 */
static void
mondrian_keyboard_dump(void)
{
	Class app_cls = objc_getClass("UIApplication");
	Class screen_cls = objc_getClass("UIScreen");
	id screen, app, windows, found, chain[20];
	CGRect bounds, native, rect;
	double scale;
	unsigned count, i, n, lines = 0, planelines = 0;
	char line[256];

	if (!mondrian_file_on("/private/var/vm/mondrian-kbd")) {
		return;
	}
	mondrian_kl_list();
	@try {
		screen = screen_cls != Nil ?
		    ((id (*)(id, SEL))objc_msgSend)((id)screen_cls,
		    sel_registerName("mainScreen")) : nil;
		if (screen != nil) {
			bounds = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
			    sel_registerName("bounds"));
			native = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
			    sel_registerName("nativeBounds"));
			scale = ((double (*)(id, SEL))objc_msgSend)(screen,
			    sel_registerName("scale"));
			snprintf(line, sizeof(line),
			    "MONDRIAN KBD: screen %.1fx%.1f native %.0fx%.0f"
			    " scale %.2f\n", bounds.size.width,
			    bounds.size.height, native.size.width,
			    native.size.height, scale);
			say(line);
		}
		app = app_cls != Nil ?
		    ((id (*)(id, SEL))objc_msgSend)((id)app_cls,
		    sel_registerName("sharedApplication")) : nil;
		windows = app != nil ? ((id (*)(id, SEL))objc_msgSend)(app,
		    sel_registerName("windows")) : nil;
		if (windows == nil) {
			return;
		}
		count = (unsigned)[(NSArray *)windows count];
		snprintf(line, sizeof(line), "MONDRIAN KBD: windows %u\n", count);
		say(line);
		for (i = 0; i < count && i < 20; i++) {
			id window = [(NSArray *)windows objectAtIndex:i];
			const char *name = object_getClassName(window);

			bounds = ((CGRect (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("bounds"));
			snprintf(line, sizeof(line),
			    "MONDRIAN KBD: win %u %s %.1fx%.1f b %.1fx%.1f\n",
			    i, name != NULL ? name : "?", bounds.size.width,
			    bounds.size.height, bounds.size.width,
			    bounds.size.height);
			say(line);
			mondrian_kbd_plane_walk(window, 0, &planelines);
			{
				CGFloat best_area = 0.0;

				found = nil;
				mondrian_kbd_find(window, 0, &found, &best_area);
			}
			if (found == nil) {
				continue;
			}
			n = 0;
			for (; found != nil && n < 20; found = ((id (*)(id, SEL))
			    objc_msgSend)(found, sel_registerName("superview"))) {
				chain[n++] = found;
			}
			snprintf(line, sizeof(line),
			    "MONDRIAN KBD: chain %u in win %u\n", n, i);
			say(line);
			for (; n > 0; n--) {
				id view = chain[n - 1];
				mondrian_kbd_insets inset =
				    ((mondrian_kbd_insets (*)(id, SEL))
				    objc_msgSend)(view,
				    sel_registerName("safeAreaInsets"));

				rect = ((CGRect (*)(id, SEL))objc_msgSend)(view,
				    sel_registerName("bounds"));
				rect = ((CGRect (*)(id, SEL, CGRect, id))
				    objc_msgSend)(view,
				    sel_registerName("convertRect:toView:"),
				    rect, nil);
				snprintf(line, sizeof(line),
				    "MONDRIAN KBD: %*s%s %.1f,%.1f"
				    " %.1fx%.1f sa %.1f,%.1f,%.1f,%.1f\n",
				    (int)((20 - n) * 2), "",
				    object_getClassName(view), rect.origin.x,
				    rect.origin.y, rect.size.width,
				    rect.size.height, inset.top, inset.left,
				    inset.bottom, inset.right);
				say(line);
			}
			mondrian_kbd_layers(chain[0]);
			mondrian_kbd_walk(chain[0], 0, &lines);
			break;
		}
	} @catch (NSException *e) {
		say("MONDRIAN KBD: skipped (exception)\n");
	}
}

/*
 * The frame UIKit tells the host the keyboard will take. A host whose layer is
 * 480 wide but whose notification says 550, or one whose plane draws 35 pt in
 * from the edge of a frame it was given at 0, are two different bugs and this
 * one line separates them. Registered only when the marker is present, so an
 * ordinary boot logs nothing new.
 */
static void
mondrian_kbd_observe(void)
{
	static int registered;

	if (registered) {
		return;
	}
	registered = 1;
	[[NSNotificationCenter defaultCenter] addObserverForName:
	    @"UIKeyboardWillChangeFrameNotification" object:nil
	    queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		NSDictionary *info = [note userInfo];
		NSValue *begin = [info objectForKey:
		    @"UIKeyboardFrameBeginUserInfoKey"];
		NSValue *end = [info objectForKey:@"UIKeyboardFrameEndUserInfoKey"];
		CGRect b = CGRectZero, e = CGRectZero;
		char line[224];

		if (begin != nil) {
			[begin getValue:&b];
		}
		if (end != nil) {
			[end getValue:&e];
		}

		snprintf(line, sizeof(line),
		    "MONDRIAN KBD: note begin %.1f,%.1f %.1fx%.1f end"
		    " %.1f,%.1f %.1fx%.1f\n", b.origin.x, b.origin.y,
		    b.size.width, b.size.height, e.origin.x, e.origin.y,
		    e.size.width, e.size.height);
		say(line);
	}];
}

/*
 * The process table, on demand. The keyboard is drawn by a process the hook
 * does not enter, and the first question is its name: the kernel injects by
 * image name, so a bit for it cannot be written until the name is known.
 * `/private/var/vm/mondrian-ps` rewritten in SpringBoard prints every process
 * the kernel reports, pid, ppid and comm, to the ring.
 */
static void
proc_probe_once(void)
{
	static long long seen;
	struct stat st;
	long long now;
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0, i, count;
	char *buf;
	char line[160];

	if (__builtin_strcmp(getprogname(), "SpringBoard") != 0 ||
	    stat("/private/var/vm/mondrian-ps", &st) != 0) {
		return;
	}
	now = (long long)st.st_mtimespec.tv_sec * 1000000000LL +
	    (long long)st.st_mtimespec.tv_nsec;
	if (now == seen) {
		return;
	}
	seen = now;
	if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) {
		say("MONDRIAN PS: sysctl size failed\n");
		return;
	}
	buf = malloc(len);
	if (buf == NULL) {
		return;
	}
	if (sysctl(mib, 4, buf, &len, NULL, 0) != 0) {
		free(buf);
		say("MONDRIAN PS: sysctl read failed\n");
		return;
	}
	count = len / sizeof(struct kinfo_proc);
	snprintf(line, sizeof(line), "MONDRIAN PS: %zu procs\n", count);
	say(line);
	for (i = 0; i < count; i++) {
		struct kinfo_proc *kp = &((struct kinfo_proc *)buf)[i];

		snprintf(line, sizeof(line), "MONDRIAN PS: %d %d %s\n",
		    kp->kp_proc.p_pid, kp->kp_eproc.e_ppid,
		    kp->kp_proc.p_comm);
		say(line);
	}
	free(buf);
}

/*
 * The keyboard's own layout pass. kbd's sandbox cannot read
 * /private/var/vm, so the marker file above never reaches it; the boot mask
 * can, because kern.bootargs is a sysctl. Bit 11 (0x800) of mondrian_ui_hook is
 * the diagnostic boot, and the last key on the line wins (a duplicate is how
 * the mask is widened without changing the default command line).
 *
 * The layout is where the 33 pt is chosen: `-[UIKeyboardLayout layoutSubviews]`
 * is handed the frame it lays the keys out in, so it prints its own frame, its
 * bounds, the superview chain's frames, the window and the screen the first
 * few times it runs. A second, correct pass (the one a tap triggers) shows the
 * same print with the centred plane, which is what tells a stale frame from a
 * bad constant.
 */
#define MONDRIAN_UI_HOOK_KBD	0x800

static int
mondrian_kbd_mask(void)
{
	char args[2048];
	size_t size = sizeof(args);
	const char *at, *last = NULL;

	if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0 ||
	    size == 0) {
		return 0;
	}
	args[sizeof(args) - 1] = 0;
	at = strstr(args, "mondrian_ui_hook=");
	while (at != NULL) {
		last = at;
		at = strstr(at + 1, "mondrian_ui_hook=");
	}
	if (last == NULL) {
		return 0;
	}
	return (int)strtol(last + sizeof("mondrian_ui_hook=") - 1, NULL, 0) &
	    MONDRIAN_UI_HOOK_KBD;
}

/*
 * More than one class can carry the layout in a single build (UIKeyboardLayout
 * and its Star subclass, and TextUI's TUI variants), and an instance may be of
 * a private subclass, so each hooked class keeps its own original and the
 * trampoline finds it by walking self's superclass chain. A single original
 * would either lose a class or, worse, skip the original layout for it.
 */
#define MONDRIAN_KL_MAX	4

static struct {
	char name[48];
	void (*orig)(id, SEL);
} mondrian_kl_hooks[MONDRIAN_KL_MAX];
static unsigned mondrian_kl_nhooks;
static unsigned mondrian_kl_dumps;
static int mondrian_kl_installed;

/*
 * The panel is 480 pt wide; UIKit sizes `UIKeyboardAutomatic` for a 414 pt
 * phone keyboard and centres it, so the automatic sits at x 33 and the 480 pt
 * `UIKeyboardImpl` inside it is clipped at the right edge (measured 2026-11-21
 * in the Spotlight process: UIInputSetHostView 480 -> _UIKBCompatInputView 480
 * -> UIKeyboardAutomatic 414 at x 33 -> UIKeyboardImpl 480 ->
 * UIKeyboardLayoutStar 480).
 *
 * The class clamps both `setFrame:` and `setBounds:` back to its 414 pt
 * keyboard, so the frame is corrected through UIView's own setters after the
 * class has seen it: bounds 480 wide with the centre at 240 leaves the
 * automatic at x 0 and the impl where the keys are drawn. The correction runs
 * only when the incoming frame is narrower than the window, so a settled
 * keyboard costs nothing; correcting after the layout pass instead was
 * measured to loop at about a hundred passes a second.
 */
static int mondrian_kl_defines(Class cls, const char *want);

static void (*mondrian_kbf_orig_setframe)(id, SEL, CGRect);
static void (*mondrian_uiview_setbounds)(id, SEL, CGRect);
static void (*mondrian_uiview_setcenter)(id, SEL, CGPoint);
static unsigned mondrian_kbf_writes;

static void
mondrian_kbf_setframe(id self, SEL cmd, CGRect frame)
{
	CGRect bounds;
	CGPoint centre;
	id window;
	CGFloat width = 0.0;

	if (mondrian_kbf_orig_setframe != NULL) {
		mondrian_kbf_orig_setframe(self, cmd, frame);
	}
	window = ((id (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("window"));
	if (window != nil) {
		width = ((CGRect (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("bounds")).size.width;
	}
	if (width < 1.0) {
		Class screen_cls = objc_getClass("UIScreen");
		id screen = screen_cls != Nil ?
		    ((id (*)(id, SEL))objc_msgSend)((id)screen_cls,
		    sel_registerName("mainScreen")) : nil;

		if (screen != nil) {
			width = ((CGRect (*)(id, SEL))objc_msgSend)(screen,
			    sel_registerName("bounds")).size.width;
		}
	}
	if (width < 1.0 || frame.size.width + 0.5 >= width ||
	    mondrian_uiview_setbounds == NULL ||
	    mondrian_uiview_setcenter == NULL) {
		return;
	}
	bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("bounds"));
	centre = ((CGPoint (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("center"));
	bounds.origin.x = 0.0;
	bounds.size.width = width;
	mondrian_uiview_setbounds(self, sel_registerName("setBounds:"), bounds);
	centre.x = width / 2.0;
	mondrian_uiview_setcenter(self, sel_registerName("setCenter:"), centre);
	if (mondrian_kbf_writes < 8) {
		char line[96];

		snprintf(line, sizeof(line),
		    "MONDRIAN KBF: keyboard widened to %.1f (%u)\n",
		    width, mondrian_kbf_writes + 1);
		say(line);
	}
	mondrian_kbf_writes++;
}

/*
 * Installed in whichever process instantiates the class. `setFrame:` is
 * UIView's unless the subclass overrides it, and replacing UIView's would
 * change every view in the process, so the override is added to the subclass
 * when it does not define one. The class's `setBounds:`/`setCenter:` clamp,
 * so UIView's implementations are saved and called directly.
 */
static void
mondrian_kbf_hook_frame(void)
{
	Class cls = objc_getClass("UIKeyboardAutomatic");
	Class uiview;
	Method method;
	IMP imp;

	if (cls == Nil) {
		return;
	}
	if (mondrian_uiview_setbounds == NULL) {
		uiview = objc_getClass("UIView");
		if (uiview != Nil) {
			method = class_getInstanceMethod(uiview,
			    sel_registerName("setBounds:"));
			mondrian_uiview_setbounds = method != NULL ?
			    (void (*)(id, SEL, CGRect))
			    method_getImplementation(method) : NULL;
			method = class_getInstanceMethod(uiview,
			    sel_registerName("setCenter:"));
			mondrian_uiview_setcenter = method != NULL ?
			    (void (*)(id, SEL, CGPoint))
			    method_getImplementation(method) : NULL;
		}
	}
	if (mondrian_kbf_orig_setframe != NULL) {
		return;
	}
	method = class_getInstanceMethod(cls, sel_registerName("setFrame:"));
	if (method == NULL) {
		return;
	}
	imp = method_getImplementation(method);
	mondrian_kbf_orig_setframe = (void (*)(id, SEL, CGRect))imp;
	if (mondrian_kl_defines(cls, "setFrame:")) {
		method_setImplementation(method, (IMP)mondrian_kbf_setframe);
	} else {
		class_addMethod(cls, sel_registerName("setFrame:"),
		    (IMP)mondrian_kbf_setframe, method_getTypeEncoding(method));
	}
	{
		char line[96];

		snprintf(line, sizeof(line),
		    "MONDRIAN KBF: keyboard frame hooked in %s\n",
		    getprogname());
		say(line);
	}
}

static void
mondrian_kl_layout(id self, SEL cmd)
{
	char line[224];
	CGRect frame, bounds, in_window;
	id superview, window;
	Class screen_cls, cls;
	id screen;
	CGRect screen_bounds;
	void (*orig)(id, SEL) = NULL;
	unsigned i;

	for (cls = object_getClass(self); cls != Nil;
	    cls = class_getSuperclass(cls)) {
		const char *name = class_getName(cls);

		for (i = 0; i < mondrian_kl_nhooks; i++) {
			if (name != NULL &&
			    strcmp(mondrian_kl_hooks[i].name, name) == 0) {
				orig = mondrian_kl_hooks[i].orig;
			}
		}
		if (orig != NULL) {
			break;
		}
	}
	if (orig != NULL) {
		orig(self, cmd);
	}
	if (mondrian_kl_dumps >= 10) {
		return;
	}
	mondrian_kl_dumps++;
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("frame"));
	bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("bounds"));
	in_window = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(self,
	    sel_registerName("convertRect:toView:"), bounds, nil);
	superview = ((id (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("superview"));
	window = ((id (*)(id, SEL))objc_msgSend)(self,
	    sel_registerName("window"));
	screen_cls = objc_getClass("UIScreen");
	screen = screen_cls != Nil ?
	    ((id (*)(id, SEL))objc_msgSend)((id)screen_cls,
	    sel_registerName("mainScreen")) : nil;
	screen_bounds = screen != nil ?
	    ((CGRect (*)(id, SEL))objc_msgSend)(screen,
	    sel_registerName("bounds")) : CGRectZero;
	/*
	 * The ancestors, up to the window: the layout itself is 480 wide at x 0
	 * and only its conversion to the window says 33, so the offset is added
	 * by one of these frames, not by the layout.
	 */
	{
		id at = self;
		unsigned up;

		for (up = 0; up < 6 && at != nil; up++) {
			CGRect r = ((CGRect (*)(id, SEL))objc_msgSend)(at,
			    sel_registerName("bounds"));
			CGRect in_win = ((CGRect (*)(id, SEL, CGRect, id))
			    objc_msgSend)(at, sel_registerName("convertRect:toView:"),
			    r, nil);

			snprintf(line, sizeof(line),
			    "MONDRIAN KLC[%s %d]: %u %s win %.1f,%.1f %.1fx%.1f\n",
			    getprogname(), getpid(), up,
			    object_getClassName(at), in_win.origin.x,
			    in_win.origin.y, in_win.size.width,
			    in_win.size.height);
			say(line);
			at = ((id (*)(id, SEL))objc_msgSend)(at,
			    sel_registerName("superview"));
		}
	}
	snprintf(line, sizeof(line),
	    "MONDRIAN KL[%s %d]: %s f %.1f,%.1f %.1fx%.1f b %.1fx%.1f win %.1f,%.1f"
	    " super %s %.1f,%.1f %.1fx%.1f window %s %.1fx%.1f screen %.1fx%.1f\n",
	    getprogname(), getpid(), object_getClassName(self),
	    frame.origin.x, frame.origin.y,
	    frame.size.width, frame.size.height, bounds.size.width,
	    bounds.size.height, in_window.origin.x, in_window.origin.y,
	    superview != nil ? object_getClassName(superview) : "-",
	    superview != nil ? ((CGRect (*)(id, SEL))objc_msgSend)(superview,
	    sel_registerName("frame")).origin.x : 0.0,
	    superview != nil ? ((CGRect (*)(id, SEL))objc_msgSend)(superview,
	    sel_registerName("frame")).origin.y : 0.0,
	    superview != nil ? ((CGRect (*)(id, SEL))objc_msgSend)(superview,
	    sel_registerName("frame")).size.width : 0.0,
	    superview != nil ? ((CGRect (*)(id, SEL))objc_msgSend)(superview,
	    sel_registerName("frame")).size.height : 0.0,
	    window != nil ? object_getClassName(window) : "-",
	    window != nil ? ((CGRect (*)(id, SEL))objc_msgSend)(window,
	    sel_registerName("bounds")).size.width : 0.0,
	    window != nil ? ((CGRect (*)(id, SEL))objc_msgSend)(window,
	    sel_registerName("bounds")).size.height : 0.0,
	    screen_bounds.size.width, screen_bounds.size.height);
	say(line);
}

/*
 * The layout class is private and its name has moved between releases
 * (UIKeyboardLayoutStar, TUIKeyboardLayoutStar, and a keyplane class under
 * TextUI), so ask the runtime what this build actually registers instead of
 * guessing: every class whose name mentions Keyboard, capped.
 */
static void
mondrian_kl_list(void)
{
	char line[160];
	Class *classes;
	int total, i, shown = 0;

	total = objc_getClassList(NULL, 0);
	if (total <= 0) {
		return;
	}
	classes = malloc((size_t)total * sizeof(Class));
	if (classes == NULL) {
		return;
	}
	total = objc_getClassList(classes, total);
	snprintf(line, sizeof(line), "MONDRIAN KL: %d classes\n", total);
	say(line);
	for (i = 0; i < total && shown < 40; i++) {
		const char *name = class_getName(classes[i]);

		if (name == NULL ||
		    (strstr(name, "KeyboardLayout") == NULL &&
		    strstr(name, "Keyplane") == NULL &&
		    strstr(name, "KeyPlane") == NULL)) {
			continue;
		}
		snprintf(line, sizeof(line), "MONDRIAN KL: has %s\n", name);
		say(line);
		shown++;
	}
	free(classes);
}

/* Does this class implement the selector itself (not only inherit it)? */
static int
mondrian_kl_defines(Class cls, const char *want)
{
	Method *list;
	unsigned count = 0, i;
	int found = 0;

	list = class_copyMethodList(cls, &count);
	if (list == NULL) {
		return 0;
	}
	for (i = 0; i < count && !found; i++) {
		const char *name = sel_getName(method_getName(list[i]));

		if (name != NULL && strcmp(name, want) == 0) {
			found = 1;
		}
	}
	free(list);
	return found;
}

/*
 * The keyboard exists only after the first presentation, and its layout class
 * is private, so the install scans every tick until one appears: a class whose
 * name says keyboard layout and that implements `layoutSubviews` itself. A
 * class that only inherits it would send the swizzle to UIView and print the
 * first ten layout passes of the whole process instead of the keyboard's.
 */
static void
mondrian_kl_hook(const char *name, Class cls)
{
	Method method;
	void (*orig)(id, SEL);
	unsigned i;

	if (cls == Nil || mondrian_kl_nhooks >= MONDRIAN_KL_MAX) {
		return;
	}
	for (i = 0; i < mondrian_kl_nhooks; i++) {
		if (strcmp(mondrian_kl_hooks[i].name, name) == 0) {
			return;
		}
	}
	if (!mondrian_kl_defines(cls, "layoutSubviews")) {
		return;
	}
	method = class_getInstanceMethod(cls, sel_registerName("layoutSubviews"));
	if (method == NULL ||
	    method_getImplementation(method) == (IMP)mondrian_kl_layout) {
		return;
	}
	orig = (void (*)(id, SEL))
	    method_setImplementation(method, (IMP)mondrian_kl_layout);
	strlcpy(mondrian_kl_hooks[mondrian_kl_nhooks].name, name,
	    sizeof(mondrian_kl_hooks[0].name));
	mondrian_kl_hooks[mondrian_kl_nhooks].orig = orig;
	mondrian_kl_nhooks++;
	mondrian_kl_installed = 1;
	{
		char line[96];

		snprintf(line, sizeof(line), "MONDRIAN KL: hooked %s\n", name);
		say(line);
	}
}

static void
mondrian_kl_install(void)
{
	char line[160];
	Class *classes;
	int total, i;
	static int said, listed, ticks;

	if (mondrian_kbd_mask() == 0) {
		return;
	}
	/*
	 * The frame hook runs before the layout scan's cap: the keyboard's frame
	 * is set once, when it is presented, so it must be installed even when
	 * every layout slot is already used.
	 */
	mondrian_kbf_hook_frame();
	/*
	 * Keep scanning until every slot is used: the classes do not all exist at
	 * the same moment (UIKit's layout and TextUI's keyplane appear with the
	 * first presentation), and one tick that finds only the first must not end
	 * the search for the others.
	 */
	if (mondrian_kl_nhooks >= MONDRIAN_KL_MAX) {
		return;
	}
	if (!said) {
		said = 1;
		snprintf(line, sizeof(line),
		    "MONDRIAN KL: enter prog %s pid %d mask 0x%x\n",
		    getprogname(), getpid(), mondrian_kbd_mask());
		say(line);
	}
	ticks++;
	/*
	 * Measured 2026-11-21: the layout is not SpringBoard's and not kbd's.
	 * SpringBoard registers the whole keyboard class family and instantiates
	 * none of it for the presented keyboard; kbd carries the input managers
	 * (TIKeyboard*) and no layout class at all, even after the keyboard is up.
	 * The surfaces of that keyboard are created by the Spotlight process
	 * (`MONDRIAN SURF: Spotlight ... 1440x729`), which hosts the search UI and
	 * its keyboard, so the scan runs in whatever process the mask bit reaches
	 * and prints where the class actually is.
	 */
	{
		static const char *const preferred[] = {
			"UIKeyboardLayoutStar", "TUIKeyboardLayoutStar",
			"UIKeyboardLayout", "TUIKeyboardLayout",
		};
		unsigned p;

		for (p = 0; p < sizeof(preferred) / sizeof(preferred[0]); p++) {
			mondrian_kl_hook(preferred[p],
			    objc_getClass(preferred[p]));
		}
	}
	total = objc_getClassList(NULL, 0);
	if (total <= 0) {
		return;
	}
	classes = malloc((size_t)total * sizeof(Class));
	if (classes == NULL) {
		return;
	}
	total = objc_getClassList(classes, total);
	for (i = 0; i < total; i++) {
		const char *name = class_getName(classes[i]);

		if (name == NULL ||
		    (strstr(name, "KeyboardLayout") == NULL &&
		    strstr(name, "Keyplane") == NULL &&
		    strstr(name, "KeyPlane") == NULL)) {
			continue;
		}
		mondrian_kl_hook(name, classes[i]);
	}
	free(classes);
	if (!mondrian_kl_installed && !listed) {
		listed = 1;
		mondrian_kl_list();
	}
	if (!mondrian_kl_installed && ticks == 20) {
		say("MONDRIAN KL: still no keyboard layout class\n");
	}
}

static void
keyboard_probe_once(void)
{
	static long long seen;
	struct stat st;
	long long now;

	if (stat("/private/var/vm/mondrian-kbd", &st) != 0) {
		return;
	}
	now = (long long)st.st_mtimespec.tv_sec * 1000000000LL +
	    (long long)st.st_mtimespec.tv_nsec;
	if (now == seen) {
		return;
	}
	seen = now;
	dispatch_async(dispatch_get_main_queue(), ^{
		mondrian_kbd_observe();
		mondrian_keyboard_dump();
	});
}

/*
 * The heartbeat stops after a minute; a test can be uploaded at any time, so
 * the run file gets a watcher of its own that never stops asking. It costs one
 * open() every two seconds and says nothing unless it has something to run.
 */
static void *
run_watcher(void *unused)
{
	(void)unused;
	for (;;) {
		/*
		 * The keyboard frame hooks have to exist before the first
		 * presentation, which happens well inside the first two seconds
		 * of a process that was just started to show a keyboard. The
		 * probe itself only touches marker files, so it can wait.
		 */
		mondrian_kl_install();
		sleep(2);
		mondrian_run_once();
		bluetooth_power_once();
		bluetooth_open_pane();
		keyboard_probe_once();
		proc_probe_once();
	}
	return NULL;
}

static void *
heartbeat(void *unused)
{
	(void)unused;
	for (int i = 0; i < 30; i++) {
		sleep(2);
		say("MONDRIAN UI: heartbeat\n");
		/*
		 * Opt-in through a marker file: this probe runs in every hooked
		 * process and calling CA early can take the boot with it, so the
		 * default image stays exactly the image that booted.
		 */
		if ((i == 9 || i == 19 || i == 29) && window_server_probe_wanted()) {
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
 * Which service does the accessory init open? With the hook out of
 * backboardd, its main thread waits for a reply from a connection the
 * CoreAccessories framework makes, and the name never reaches the ring. The
 * fix is to reproduce the call from a process that carries the probe, with
 * `xpc_connection_create_mach_service` interposed, so the name prints before
 * the wait; the call is expected to hang, which is what backboardd shows.
 *
 * The interposer passes every call through and only reports while the probe
 * below is armed, because this dylib also lives in launchd and SpringBoard.
 */
extern xpc_connection_t xpc_connection_create_mach_service(const char *name,
    dispatch_queue_t targetq, uint64_t flags);
struct mondrian_xpc_interpose {
	const void *replacement;
	const void *replacee;
};
extern const struct mondrian_xpc_interpose mondrian_xpc_interposer[];
static xpc_connection_t (*real_create_mach_service)(const char *,
    dispatch_queue_t, uint64_t);
static volatile int mondrian_acc_armed;

static xpc_connection_t
mondrian_create_mach_service(const char *name, dispatch_queue_t targetq,
    uint64_t flags)
{
	/*
	 * The original comes from dyld's interpose tuple, not from dlsym.
	 * `dlsym(RTLD_NEXT, "xpc_connection_create_mach_service")` resolves to
	 * this very function -- interposition is applied to lookups, and RTLD_NEXT
	 * only skips the *images* before this one -- so the first call recursed
	 * into itself. Measured on assetsd 2026-11-18: pc inside this function at
	 * +0x4, lr at the `blr` that calls it, far = sp + 0x100, and a `bt` that
	 * repeats one address; every level costs 0x140 of stack until the guard
	 * page, which is why assetsd died `sig 11` with this dylib loaded and
	 * `sig 6` without it. The tuple's second field is the definition dyld
	 * found for the replacee, so it is the real function by construction.
	 */
	if (real_create_mach_service == NULL) {
		static unsigned told;

		real_create_mach_service = (xpc_connection_t (*)(const char *,
		    dispatch_queue_t, uint64_t))
		    mondrian_xpc_interposer[0].replacee;
		if (told++ == 0) {
			char line[160];

			snprintf(line, sizeof(line),
			    "MONDRIAN ACC[%d]: real %p self %p\n", getpid(),
			    (void *)real_create_mach_service,
			    (void *)mondrian_create_mach_service);
			say(line);
		}
	}
	/*
	 * This dylib is injected into launchd, xpcproxy and every daemon in the
	 * mask, so a NULL here would take the boot down with it.
	 */
	if (real_create_mach_service == NULL ||
	    real_create_mach_service == mondrian_create_mach_service) {
		return NULL;
	}
	if (mondrian_acc_armed) {
		char line[224];

		snprintf(line, sizeof(line),
		    "MONDRIAN ACC: create %s flags 0x%llx\n",
		    name != NULL ? name : "(null)", (unsigned long long)flags);
		say(line);
	}
	return real_create_mach_service(name, targetq, flags);
}

__attribute__((used, section("__DATA,__interpose")))
const struct mondrian_xpc_interpose mondrian_xpc_interposer[] = {
	{ (const void *)mondrian_create_mach_service,
	  (const void *)xpc_connection_create_mach_service },
};

static void mondrian_dump_threads(const char *tag);

/*
 * The blocked thread is inside `mach_msg`, so its user registers still point at
 * the trap arguments: x0 is `struct mach_msg2_trap_args *` and the first field
 * is the message header. Reading it through `mach_vm_read_overwrite` names the
 * destination port without risking a fault in this thread, and
 * `mach_port_type` says whether that name is a live send right or a dead name
 * -- the difference between "the service never answered" and "the service no
 * longer exists".
 */
static void
mondrian_acc_peek(pthread_t thread)
{
	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	mach_vm_size_t got = 0;
	uint64_t args[1] = { 0 };
	struct {
		uint32_t bits;
		uint32_t size;
		uint32_t remote;
		uint32_t local;
		uint32_t voucher;
		int32_t id;
	} header;
	mach_port_type_t type = 0;
	char line[224];

	if (thread_get_state(pthread_mach_thread_np(thread), ARM_THREAD_STATE64,
	    (thread_state_t)&state, &count) != KERN_SUCCESS) {
		say("MONDRIAN ACC: thread state failed\n");
		return;
	}
	if (mach_vm_read_overwrite(mach_task_self(),
	    (mach_vm_address_t)state.__x[0], sizeof(args),
	    (mach_vm_address_t)args, &got) != KERN_SUCCESS || got != sizeof(args)) {
		snprintf(line, sizeof(line), "MONDRIAN ACC: x0 %p unreadable\n",
		    (void *)(uintptr_t)state.__x[0]);
		say(line);
		return;
	}
	if (mach_vm_read_overwrite(mach_task_self(),
	    (mach_vm_address_t)args[0], sizeof(header),
	    (mach_vm_address_t)&header, &got) != KERN_SUCCESS ||
	    got != sizeof(header)) {
		snprintf(line, sizeof(line), "MONDRIAN ACC: msg %p unreadable\n",
		    (void *)(uintptr_t)args[0]);
		say(line);
		return;
	}
	(void)mach_port_type(mach_task_self(), header.remote, &type);
	snprintf(line, sizeof(line),
	    "MONDRIAN ACC: msg %p id %d bits 0x%x size %u remote %u local %u type 0x%x\n",
	    (void *)(uintptr_t)args[0], header.id, header.bits, header.size,
	    header.remote, header.local, type);
	say(line);
}

static void *
mondrian_acc_watch(void *unused)
{
	(void)unused;
	sleep(20);
	mondrian_dump_threads("acc");
	mondrian_acc_peek((pthread_t)unused);
	return NULL;
}

static void *
mondrian_acc_probe(void *unused)
{
	void *handle;
	void (*init_hid)(void);
	pthread_t watch;
	char line[192];

	(void)unused;
	sleep(60);
	if (strcmp(getprogname(), "runningboardd") != 0) {
		return NULL;
	}
	handle = dlopen("/System/Library/PrivateFrameworks/"
	    "CoreAccessories.framework/CoreAccessories", RTLD_NOW);
	if (handle == NULL) {
		snprintf(line, sizeof(line), "MONDRIAN ACC: dlopen failed %s\n",
		    dlerror() != NULL ? dlerror() : "?");
		say(line);
		return NULL;
	}
	init_hid = (void (*)(void))dlsym(handle, "CoreAccessoriesInitForHID");
	snprintf(line, sizeof(line), "MONDRIAN ACC: init %p\n",
	    (void *)init_hid);
	say(line);
	if (init_hid == NULL) {
		return NULL;
	}
	mondrian_acc_armed = 1;
	/*
	 * The call is expected to hang; a watchdog dumps every thread 20 s
	 * later, so the frame that never returns is read here instead of being
	 * guessed from another process's stack.
	 */
	(void)pthread_create(&watch, NULL, mondrian_acc_watch,
	    (void *)pthread_self());
	init_hid();
	mondrian_acc_armed = 0;
	say("MONDRIAN ACC: init returned\n");
	return NULL;
}

/*
 * Does the on-demand path work? A Mach service that no job is serving is a
 * send right whose first message is supposed to make launchd start the job.
 * Backboardd waiting for accessoryd and runningboardd waiting for launchd
 * both look exactly like that path not firing, so the probe walks it end to
 * end: look the service up, send a message with a marker id, and let the exec
 * trace say whether a process appeared. The marker also lands in launchd's
 * receive trace, which splits "launchd never got the message" from "launchd
 * got it and did nothing".
 */
#define MONDRIAN_DEMAND_ID 0x4d4f4e44 /* 'MOND' */

static void *
mondrian_demand_probe(void *unused)
{
	static const char *names[] = {
		/*
		 * First: the container manager is a RunAtLoad job whose Mach
		 * name answers lookups while the process never appears, so the
		 * message is the on-demand path's last chance to start it.
		 */
		"com.apple.containermanagerd",
		"com.apple.accessories.hid",
		"com.apple.accessories.connection-info-server",
		"com.apple.accessories.transport-server",
		"com.apple.diagnosticd",
	};
	mach_port_t bp = MACH_PORT_NULL;
	char line[192];

	(void)unused;
	{
		snprintf(line, sizeof(line), "MONDRIAN DEMAND: %d armed %s\n",
		    getpid(), getprogname());
		say(line);
	}
	sleep(40);
	if (task_get_bootstrap_port(mach_task_self(), &bp) != KERN_SUCCESS ||
	    bp == MACH_PORT_NULL) {
		say("MONDRIAN DEMAND: no bootstrap port\n");
		return NULL;
	}
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		struct {
			mach_msg_header_t header;
		} msg;
		mach_port_t svc = MACH_PORT_NULL;
		kern_return_t kr;

		kr = bootstrap_look_up(bp, names[i], &svc);
		snprintf(line, sizeof(line),
		    "MONDRIAN DEMAND: %d %s -> 0x%x port %u\n",
		    getpid(), names[i], kr, (unsigned)svc);
		say(line);
		if (kr != KERN_SUCCESS || svc == MACH_PORT_NULL) {
			continue;
		}
		memset(&msg, 0, sizeof(msg));
		msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
		msg.header.msgh_size = sizeof(msg.header);
		msg.header.msgh_remote_port = svc;
		msg.header.msgh_id = MONDRIAN_DEMAND_ID;
		kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
		    sizeof(msg.header), 0, MACH_PORT_NULL, 200, MACH_PORT_NULL);
		snprintf(line, sizeof(line),
		    "MONDRIAN DEMAND: %d %s send 0x%x\n", getpid(), names[i], kr);
		say(line);
		mach_port_deallocate(mach_task_self(), svc);
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
	(void)pthread_create(&thread, NULL, mondrian_demand_probe, NULL);
	(void)pthread_create(&thread, NULL, mondrian_acc_probe, NULL);
	(void)pthread_create(&thread, NULL, mondrian_addr_watch, NULL);
	(void)pthread_create(&thread, NULL, mondrian_surface_owner, NULL);
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

static int mondrian_fix_on(const char *path);
static int mondrian_file_on(const char *path);
static int mondrian_file_is(const char *path, char want);

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
	(void)pthread_create(&thread, NULL, run_watcher, NULL);
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
	 * stays behind its own switch. It is a file as well as a boot argument so a
	 * running system can be measured without a reboot
	 * (`/private/var/vm/mondrian-ca`, `0` turns it off).
	 */
	if (boot_arg_set("mondrianca=1") ||
	    mondrian_fix_on("/private/var/vm/mondrian-ca")) {
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
		    "MONDRIAN UI: idle timer asked %d, forced %d\n", (int)disabled,
		    boot_arg_set("mondriankeepawake=0") == 0);
		say(line);
	}
	if (original_idle_disabled != NULL) {
		/*
		 * SpringBoard asks for the timer to stay off and the port has
		 * honoured that since the day the display never came back
		 * (`mondrian_lock_step` explains it). `mondriankeepawake=0`
		 * passes the ask through unchanged instead, so one boot can
		 * watch the idle path.
		 */
		BOOL forced = boot_arg_set("mondriankeepawake=0") == 0;

		original_idle_disabled(self, selector, forced ? YES : disabled,
		    reason);
	}
}

static BOOL (*original_idle_disabled_for_reason)(id, SEL, id);

static BOOL
mondrian_idle_disabled_for_reason(id self, SEL selector, id reason)
{
	/* The setter is forced too; this answers with the same value. */
	if (boot_arg_set("mondriankeepawake=0") && original_idle_disabled_for_reason) {
		return original_idle_disabled_for_reason(self, selector, reason);
	}
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
		original_idle_disabled_for_reason = (BOOL (*)(id, SEL, id))
		    method_setImplementation(method,
		    (IMP)mondrian_idle_disabled_for_reason);
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
static volatile unsigned mondrian_step_calls;
static volatile unsigned mondrian_step_works;
static int mondrian_agent_hooks;
static int mondrian_lock_last = -1;
/*
 * A display that sleeps between two measurements is the measurement trap that
 * has cost the most: CoreAnimation stops presenting, `fps` reads 0 on a screen
 * that looks frozen, and no injected touch wakes it again. A power assertion of
 * the kind an app takes for NoDisplaySleep keeps it up, so a boot stays usable
 * for as long as the ring is being read. `mondriannosleep=1` asks for it.
 */
typedef unsigned int mondrian_assertion_id;
extern int IOPMAssertionCreateWithName(const void *type, unsigned int level,
    const void *name, mondrian_assertion_id *out);

static mondrian_assertion_id mondrian_sleep_assertion;

static void
mondrian_hold_display_awake(void)
{
	int r;

	if (mondrian_sleep_assertion != 0) {
		return;
	}
	r = IOPMAssertionCreateWithName(CFSTR("NoDisplaySleepAssertion"), 255u,
	    CFSTR("mondrian: frame path measurement"), &mondrian_sleep_assertion);
	if (r == 0 && mondrian_sleep_assertion != 0) {
		say("MONDRIAN UI: display stays awake (assertion held)\n");
	} else {
		mondrian_sleep_assertion = 0;
		say("MONDRIAN UI: display assertion refused\n");
	}
}

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
 * The App Library's category cards.
 *
 * Measured 2026-11-18 with the card dump, library on the glass: a card is an
 * `_SBHLibraryPodIconView` 170x184 in `_SBHLibraryPodIconListView` whose only
 * child is an `SBFTouchPassThroughView`, whose layer carries no `contents` on
 * three of the four cards and no `backgroundColor` on any of them. The grey
 * square a good card shows is that layer's `contents`, so this port draws the
 * card itself instead of waiting for the preview grid `IconServices` never
 * produces here.
 *
 * The preview is the category's own application icons: the card's `icon` is an
 * `SBHLibraryPodCategoryIcon` whose only accessor is `-category`, and
 * `SBHLibraryCategory -icons` returns one to four `SBApplicationIcon`s. They are
 * drawn into one bitmap and hung under a card layer of ours with the material's
 * colour, its continuous corners and the tiles inside.
 *
 * Layers, not subviews: the proven operation is the one the library's background
 * uses (`mondrian_library_paint`), and a subview added to an icon view is a
 * message to SpringBoard's own layout, which this port does not need to send.
 *
 * The bounds gate is deliberate: a class-name match alone can be a full-screen
 * container, and painting one puts a giant rounded layer over the UI.
 */
#define MONDRIAN_LIBRARY_CARDS 6

static id
mondrian_icon_file_image(NSString *path)
{
	unsigned f;
	Class ui_image = objc_getClass("UIImage");

	if (path == nil || ui_image == Nil) {
		return nil;
	}
	for (f = 0; f < sizeof(mondrian_icon_files) /
	    sizeof(mondrian_icon_files[0]); f++) {
		char file[512];
		id image;

		snprintf(file, sizeof(file), "%s/%s", [path UTF8String],
		    mondrian_icon_files[f]);
		if (access(file, R_OK) != 0) {
			continue;
		}
		image = ((id (*)(id, SEL, id))objc_msgSend)((id)ui_image,
		    sel_registerName("imageWithContentsOfFile:"),
		    [NSString stringWithUTF8String:file]);
		if (image != NULL) {
			return image;
		}
	}
	return nil;
}

/* What a category icon might answer with its children; the first that returns a
 * non-empty array wins and is named in the log, so one boot identifies it. */
static const char *const mondrian_card_lists[] = {
	"icons", "allIcons", "applicationIcons", "categoryIcons", "leafIcons",
	"sortedIcons", "iconsOfCategory", "children", "folderIcons",
};

/* The artwork box is the card's material, not the card: measured, a card is a
 * 170x184 `_SBHLibraryPodIconView` and the material on it is a 170x170 square,
 * so the label sits in the 14 points below it. No card dumped carries a
 * material *view* (its only child is an `SBFTouchPassThroughView`) and none has
 * a `backgroundColor`, so the grey square is the card's layer contents; three of
 * the four draw none. */
static CGRect
mondrian_card_box(id view, CGRect bounds)
{
	id subs = mondrian_send(view, "subviews");
	unsigned n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0, i;

	for (i = 0; i < n; i++) {
		id sub = [(NSArray *)subs objectAtIndex:i];
		const char *name = sub != NULL ? object_getClassName(sub) : NULL;

		if (name != NULL && strstr(name, "Material") != NULL) {
			return ((CGRect (*)(id, SEL))objc_msgSend)(sub,
			    sel_registerName("frame"));
		}
	}
	return CGRectMake(0, 0, bounds.size.width, bounds.size.width);
}

/* The 2x2 preview of a category, drawn on a transparent bitmap. */
static CGImageRef
mondrian_card_picture(id icon, double side, const char **used, unsigned *total,
    unsigned *drawn_out)
{
	id icons = NULL;
	Class ui_image = objc_getClass("UIImage");
	size_t pixels, row;
	CGColorSpaceRef rgb;
	CGContextRef ctx;
	CGImageRef picture = NULL;
	uint8_t *bytes;
	unsigned count = 0, drawn = 0, i, k;
	double pad, gap, cell;

	*used = "none";
	*total = 0;
	*drawn_out = 0;
	if (icon == NULL || ui_image == Nil || side < 1.0) {
		return NULL;
	}
	for (k = 0; k < sizeof(mondrian_card_lists) / sizeof(mondrian_card_lists[0]);
	    k++) {
		SEL sel = sel_registerName(mondrian_card_lists[k]);
		id candidate;

		if (![icon respondsToSelector:sel]) {
			continue;
		}
		candidate = mondrian_send(icon, mondrian_card_lists[k]);
		if (candidate != NULL && [candidate isKindOfClass:[NSArray class]] &&
		    [(NSArray *)candidate count] > 0) {
			icons = candidate;
			*used = mondrian_card_lists[k];
			break;
		}
	}
	if (icons == NULL) {
		return NULL;
	}
	count = (unsigned)[(NSArray *)icons count];
	*total = count;
	pixels = (size_t)side;
	row = pixels * 4;
	bytes = calloc(1, row * pixels);
	rgb = CGColorSpaceCreateDeviceRGB();
	ctx = bytes != NULL ? CGBitmapContextCreate(bytes, pixels, pixels, 8, row,
	    rgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
	if (ctx == NULL) {
		free(bytes);
		if (rgb != NULL) {
			CGColorSpaceRelease(rgb);
		}
		return NULL;
	}
	pad = side * 0.10;
	gap = side * 0.06;
	cell = (side - 2.0 * pad - gap) / 2.0;
	for (i = 0; i < count && drawn < 4; i++) {
		id child = [(NSArray *)icons objectAtIndex:i];
		const char *child_class = child != NULL ?
		    object_getClassName(child) : NULL;
		NSString *path;
		id image;
		CGImageRef art;

		if (child_class == NULL ||
		    strstr(child_class, "ApplicationIcon") == NULL) {
			continue;
		}
		path = mondrian_icon_bundle_path(child);
		image = path != nil ? mondrian_icon_file_image(path) : nil;
		if (image == nil) {
			continue;
		}
		art = ((CGImageRef (*)(id, SEL))objc_msgSend)(image,
		    sel_registerName("CGImage"));
		if (art == NULL) {
			continue;
		}
		{
			/* The iOS silhouette, so the tiles are icons and not squares. */
			CGRect rect = CGRectMake(pad + (drawn % 2) * (cell + gap),
			    side - pad - cell - (drawn / 2) * (cell + gap), cell, cell);
			CGPathRef path = CGPathCreateWithRoundedRect(rect,
			    cell * 0.2237, cell * 0.2237, NULL);

			if (path != NULL) {
				CGContextSaveGState(ctx);
				CGContextAddPath(ctx, path);
				CGContextClip(ctx);
				CGContextDrawImage(ctx, rect, art);
				CGContextRestoreGState(ctx);
				CGPathRelease(path);
			} else {
				CGContextDrawImage(ctx, rect, art);
			}
		}
		drawn++;
	}
	if (drawn > 0) {
		picture = CGBitmapContextCreateImage(ctx);
	}
	*drawn_out = drawn;
	CGContextRelease(ctx);
	CGColorSpaceRelease(rgb);
	free(bytes);
	return picture;
}

static unsigned
mondrian_library_cards(id view, unsigned depth, unsigned *painted)
{
	const char *name = view != NULL ? object_getClassName(view) : NULL;
	id subs;
	unsigned n, i, hits = 0;

	if (view == NULL || depth > 18 || *painted >= MONDRIAN_LIBRARY_CARDS) {
		return 0;
	}
	/*
	 * On unless `/private/var/vm/mondrian-cardspaint` holds `0`.
	 *
	 * Boots with this hook have left 0, 6 or 12 `CRASH SpringBoard` entries at
	 * one fixed pc; the pc is a `bl` at SpringBoard + 0xa4a14 and `far - 0xf42`
	 * is page-aligned, i.e. a message to a freed object reported at its call
	 * site. It is intermittent and this pass only runs with the library on the
	 * glass, so it cannot be that crasher; the switch is here to take the pass
	 * out of a session that needs a quiet boot.
	 */
	if (!mondrian_fix_on("/private/var/vm/mondrian-cardspaint")) {
		return 0;
	}
	if (name != NULL && strstr(name, "LibraryPodIconView") != NULL) {
		CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("bounds"));
		CGRect box = mondrian_card_box(view, bounds);
		id icon, layer;
		CGImageRef art;
		double side = box.size.width;
		char line[224];

		if (side < 80.0 || side > 300.0) {
			snprintf(line, sizeof(line),
			    "MONDRIAN LIBRARY: card %s %.0fx%.0f skipped, not a card\n",
			    name, side, bounds.size.height);
			say(line);
			return 0;
		}
		layer = mondrian_send(view, "layer");
		if (layer == NULL ||
		    [(CALayer *)layer valueForKey:@"mondrianCardArt"] != nil) {
			return 0;
		}
		icon = mondrian_send(view, "icon");
		{
			static int dumped;
			const char *icon_class = icon != NULL ?
			    object_getClassName(icon) : NULL;

			/* Once: which children accessor this userland's category exposes.
			 * The log names the class and every instance method. */
			if (!dumped) {
				dumped = 1;
				if (icon_class != NULL &&
				    strstr(icon_class, "CategoryIcon") != NULL) {
					mondrian_dump_all_methods(icon_class);
				}
				mondrian_dump_all_methods("SBHLibraryCategory");
			}
		}
		{
			/* The category icon carries the model, not the children:
			 * measured 2026-11-18, its only accessor is `category`. */
			id model = icon;
			const char *used = "none";
			unsigned total = 0, drew = 0;

			if (icon != NULL &&
			    [icon respondsToSelector:sel_registerName("category")]) {
				id category = mondrian_send(icon, "category");

				if (category != NULL) {
					model = category;
				}
			}
			art = mondrian_card_picture(model, side, &used, &total, &drew);
			snprintf(line, sizeof(line),
			    "MONDRIAN LIBRARY: card %s icon %s model %s via %s:"
			    " %u icons, %u drawn%s\n", name,
			    icon != NULL ? object_getClassName(icon) : "none",
			    model != NULL ? object_getClassName(model) : "none", used,
			    total, drew, art == NULL ? ", no artwork" : "");
			say(line);
			if (art == NULL) {
				return 0;
			}
		}
		{
			/*
			 * The card under the tiles, as a layer with a background colour
			 * and continuous corners -- the shape iOS itself gives it. Measured
			 * 2026-11-18: three of the four cards in the library draw no
			 * material (their layers carry no contents and no background
			 * colour) and the fourth shows a flat slate square, which is the
			 * color read off the panel here.
			 *
			 * On unless `/private/var/vm/mondrian-cardmaterial` holds `0`: the
			 * shape is measured on the glass (four cards, SpringBoard's pid
			 * stable while the library was displayed), and the switch is there
			 * for an A/B because painting the same square into the tiles' own
			 * bitmap coincided with a SpringBoard crash loop when the library
			 * opened.
			 */
			CALayer *card = [CALayer layer];

			if (mondrian_fix_on("/private/var/vm/mondrian-cardmaterial")) {
				CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
				CGFloat parts[4] = { 82.0 / 255.0, 93.0 / 255.0,
				    107.0 / 255.0, 0.97 };

				[card setCornerRadius:side * 0.16];
				[card setMasksToBounds:YES];
				if (rgb != NULL) {
					CGColorRef colour = CGColorCreate(rgb, parts);

					if (colour != NULL) {
						[card setBackgroundColor:colour];
						CGColorRelease(colour);
					}
					CGColorSpaceRelease(rgb);
				}
			}
			[card setFrame:box];
			{
				CALayer *tiles = [CALayer layer];

				[tiles setContents:(id)art];
				[tiles setFrame:CGRectMake(0, 0, side, side)];
				[tiles setContentsGravity:(NSString *)@"resize"];
				[card addSublayer:tiles];
			}
			[(CALayer *)layer setValue:card forKey:@"mondrianCardArt"];
			[(CALayer *)layer addSublayer:card];
		}
		CGImageRelease(art);
		snprintf(line, sizeof(line),
		    "MONDRIAN LIBRARY: card %s icon %s, the preview is on it\n", name,
		    icon != NULL ? object_getClassName(icon) : "none");
		say(line);
		(*painted)++;
		return 1;
	}
	subs = mondrian_send(view, "subviews");
	n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_library_cards([(NSArray *)subs objectAtIndex:i],
		    depth + 1, painted);
	}
	return hits;
}

/* A layer's painted background, as the numbers that decide whether it shows:
 * is there a colour, how opaque is it, does it mask itself. A view and a layer
 * answer different selectors, so each is asked only what it has. */
static void
mondrian_card_layer_line(char *line, size_t size, const char *tag, unsigned n,
    id item)
{
	Class ui_view = objc_getClass("UIView");
	id layer = item;
	id bg;
	CGRect frame;
	double alpha = 1.0;
	BOOL hidden = 0, masks = 0, is_view;

	if (item == NULL) {
		snprintf(line, size, "MONDRIAN CARD %u:   %s none\n", n, tag);
		return;
	}
	is_view = ui_view != Nil && [item isKindOfClass:ui_view];
	if (is_view) {
		layer = mondrian_send(item, "layer");
		alpha = ((double (*)(id, SEL))objc_msgSend)(item,
		    sel_registerName("alpha"));
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(item,
		    sel_registerName("isHidden"));
	}
	if (layer == NULL) {
		snprintf(line, size, "MONDRIAN CARD %u:   %s %s no layer\n", n, tag,
		    object_getClassName(item));
		return;
	}
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(layer, sel_registerName("frame"));
	if (!is_view) {
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("isHidden"));
	}
	if ([layer respondsToSelector:sel_registerName("masksToBounds")]) {
		masks = ((BOOL (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("masksToBounds"));
	}
	bg = mondrian_send(layer, "backgroundColor");
	{
		id contents = mondrian_send(layer, "contents");
		long cw = 0, ch = 0;

		if (contents != NULL &&
		    CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
			cw = (long)CGImageGetWidth((CGImageRef)contents);
			ch = (long)CGImageGetHeight((CGImageRef)contents);
		}
		snprintf(line, size,
		    "MONDRIAN CARD %u:   %s %s layer %s %.0f,%.0f %.0fx%.0f alpha %.2f"
		    " hidden %d mask %d bg %d contents %ldx%ld\n", n, tag,
		    object_getClassName(item), object_getClassName(layer),
		    frame.origin.x, frame.origin.y, frame.size.width,
		    frame.size.height, alpha, (int)hidden, (int)masks, bg != NULL,
		    cw, ch);
	}
}

/*
 * What a category card is made of, once: its frame, its alpha, its own layer's
 * paint and its children. Measured 2026-11-18 with only two cards dumped: the
 * cards that draw no grey square carry a lone `SBFTouchPassThroughView` and two
 * layers, so the material is not a child at all. This names the difference
 * between a card that paints and one that does not, for every card, instead of
 * guessing. Armed by `/private/var/vm/mondrian-cards`.
 */
static unsigned
mondrian_card_tree(id view, unsigned depth, unsigned *dumped)
{
	const char *name = view != NULL ? object_getClassName(view) : NULL;
	id layer, subs;
	unsigned n, i, hits = 0;
	char line[320];

	if (view == NULL || depth > 18 || *dumped >= 6) {
		return 0;
	}
	if (name != NULL && strstr(name, "LibraryPodIconView") != NULL) {
		CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("bounds"));
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("frame"));
		id parent = mondrian_send(view, "superview");

		(*dumped)++;
		snprintf(line, sizeof(line),
		    "MONDRIAN CARD %u: %s frame %.0f,%.0f %.0fx%.0f bounds"
		    " %.0fx%.0f in %s\n", *dumped, name, frame.origin.x,
		    frame.origin.y, frame.size.width, frame.size.height,
		    bounds.size.width, bounds.size.height,
		    parent != NULL ? object_getClassName(parent) : "none");
		say(line);
		mondrian_card_layer_line(line, sizeof(line), "view", *dumped, view);
		say(line);
		subs = mondrian_send(view, "subviews");
		n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
		snprintf(line, sizeof(line), "MONDRIAN CARD %u: %u subviews\n", *dumped, n);
		say(line);
		for (i = 0; i < n; i++) {
			mondrian_card_layer_line(line, sizeof(line), "sub", *dumped,
			    [(NSArray *)subs objectAtIndex:i]);
			say(line);
		}
		layer = mondrian_send(view, "layer");
		subs = layer != NULL ? mondrian_send(layer, "sublayers") : nil;
		n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
		snprintf(line, sizeof(line), "MONDRIAN CARD %u: %u sublayers\n", *dumped, n);
		say(line);
		for (i = 0; i < n; i++) {
			id sub = [(NSArray *)subs objectAtIndex:i];

			mondrian_card_layer_line(line, sizeof(line), "layer", *dumped,
			    sub);
			say(line);
		}
		return 1;
	}
	subs = mondrian_send(view, "subviews");
	n = subs != NULL ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_card_tree([(NSArray *)subs objectAtIndex:i], depth + 1,
		    dumped);
	}
	return hits;
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

/*
 * The App Library's background is a blurred snapshot, and iOS draws it through
 * a _UIVisualEffectView. When its pixels arrive blocky the two explanations are
 * "the layer is scaled, so a small texture covers a big area" (geometry) and
 * "the texture itself is small or wrong" (contents), and they need different
 * work. Print every effect/backdrop view of a window with the numbers that
 * separate them -- frame, bounds, the layer's bounds, contentsScale,
 * rasterizationScale and whether the layer transform is identity.
 * `mondriangeom=1` turns it on; the cap keeps one pass to a readable size.
 */
static unsigned
mondrian_effect_walk(id view, unsigned depth, unsigned *printed, unsigned *seen)
{
	id kids, layer;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 12 || *printed >= 16 || *seen >= 4000) {
		return 0;
	}
	(*seen)++;
	if (name != NULL && (strstr(name, "Backdrop") != NULL ||
	    strstr(name, "VisualEffect") != NULL ||
	    strstr(name, "EffectView") != NULL)) {
		char line[288];

		(*printed)++;
		hits++;
		layer = mondrian_send(view, "layer");
		{
			CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view,
			    sel_registerName("frame"));
			CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view,
			    sel_registerName("bounds"));
			CGFloat scale = -1.0, rast = -1.0;
			CGRect lb = CGRectZero;
			BOOL ident = YES, contents = NO;
			const char *gravity = "-";

			if (layer != nil) {
				if ([layer respondsToSelector:sel_registerName("contentsScale")]) {
					scale = ((CGFloat (*)(id, SEL))objc_msgSend)(layer,
					    sel_registerName("contentsScale"));
				}
				if ([layer respondsToSelector:sel_registerName("rasterizationScale")]) {
					rast = ((CGFloat (*)(id, SEL))objc_msgSend)(layer,
					    sel_registerName("rasterizationScale"));
				}
				if ([layer respondsToSelector:sel_registerName("contents")]) {
					contents = mondrian_send(layer, "contents") != nil;
				}
				if ([layer respondsToSelector:sel_registerName("contentsGravity")]) {
					id g = mondrian_send(layer, "contentsGravity");

					if (g != nil && [g isKindOfClass:[NSString class]]) {
						gravity = [(NSString *)g UTF8String];
					}
				}
				lb = ((CGRect (*)(id, SEL))objc_msgSend)(layer,
				    sel_registerName("bounds"));
				{
					CATransform3D m = ((CATransform3D (*)(id, SEL))objc_msgSend)(
					    layer, sel_registerName("transform"));

					ident = mondrian_geom_identity(m);
				}
			}
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: fx %s d%u frame %.1fx%.1f at %.1f,%.1f"
			    " bounds %.1fx%.1f layer %.1fx%.1f scale %.2f rast %.2f"
			    " contents %d gravity %s ident %d\n",
			    name, depth, frame.size.width, frame.size.height,
			    frame.origin.x, frame.origin.y, bounds.size.width,
			    bounds.size.height, lb.size.width, lb.size.height,
			    (double)scale, (double)rast, (int)contents,
			    gravity != NULL ? gravity : "-", (int)ident);
			say(line);
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_effect_walk([(NSArray *)kids objectAtIndex:i],
		    depth + 1, printed, seen);
	}
	layer = mondrian_send(view, "layer");
	if (layer != nil) {
		id subs = mondrian_send(layer, "sublayers");
		unsigned sc = subs != nil ? (unsigned)[(NSArray *)subs count] : 0;

		for (i = 0; i < sc; i++) {
			id sl = [(NSArray *)subs objectAtIndex:i];
			const char *sn = sl != nil ? object_getClassName(sl) : NULL;

			if (sn != NULL && (strstr(sn, "Backdrop") != NULL ||
			    strstr(sn, "VisualEffect") != NULL)) {
				CGRect lb = ((CGRect (*)(id, SEL))objc_msgSend)(sl,
				    sel_registerName("bounds"));
				CGFloat scale = -1.0, bscale = -1.0;
				char line[288];

				(*printed)++;
				hits++;
				if ([sl respondsToSelector:sel_registerName("contentsScale")]) {
					scale = ((CGFloat (*)(id, SEL))objc_msgSend)(sl,
					    sel_registerName("contentsScale"));
				}
				/*
				 * A CABackdropLayer carries its own `scale`, which is the
				 * one its filter samples at; contentsScale says nothing
				 * about the blur.
				 */
				if ([sl respondsToSelector:sel_registerName("scale")]) {
					bscale = ((CGFloat (*)(id, SEL))objc_msgSend)(sl,
					    sel_registerName("scale"));
				}
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: fx L %s d%u bounds %.1fx%.1f"
				    " scale %.2f bscale %.2f contents %d\n", sn, depth,
				    lb.size.width, lb.size.height, (double)scale,
				    (double)bscale,
				    (int)(mondrian_send(sl, "contents") != nil));
				say(line);
			}
		}
	}
	return hits;
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
		/*
		 * Every visible window, because the App Library is not the Control
		 * Center: it is SpringBoard's own tree, and the backdrop that draws
		 * wrong is somewhere inside it.
		 */
		for (i = 0; i < count && i < 8; i++) {
			id window = [(NSArray *)windows objectAtIndex:i];
			const char *name = object_getClassName(window);
			unsigned printed = 0, seen = 0, hits;

			if (((BOOL (*)(id, SEL))objc_msgSend)(window,
			    sel_registerName("isHidden"))) {
				continue;
			}
			hits = mondrian_effect_walk(window, 0, &printed, &seen);
			if (hits != 0) {
				snprintf(line, sizeof(line),
				    "MONDRIAN UI: fx window %s hits %u seen %u\n",
				    name != NULL ? name : "?", hits, seen);
				say(line);
			}
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
static int mondrian_keepawake_off_logs;
static int mondrian_pref_logs;

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
 * `mondriantouch=1`, or /private/var/vm/mondrian-touch: where the events an app
 * receives end up. The boot argument costs a reboot and the 607-byte command
 * line has no room for it; the marker file arms the same probe on the next
 * launch, which is what a dead button needs. -[UIApplication sendEvent:] is
 * called once per event, not once per view, so wrapping it is cheap where
 * wrapping hitTest was not. One line per touch: its phase, the point, the
 * window UIKit gives it to, and the view it lands on -- `nil` for the view is
 * what a sheet that swallows touches looks like.
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

	if ((!boot_arg_set("mondriantouch=1") &&
	    !mondrian_file_on("/private/var/vm/mondrian-touch")) || cls == Nil) {
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

/*
 * Auto-lock. The idle timer never fires on this port and the hook no longer
 * holds it (measured 2026-11-16: `SBUserAgent` never asks, no `panel blank`
 * line, 21 fps for ten minutes), so the timeout is the next thing to look at.
 * It lives in SpringBoard's own preferences; print what is there, and let
 * `mondrianautolock=N` replace it through cfprefsd (the boot log shows the
 * daemon starting, so the write is the supported one and persists in the root).
 */
static void
mondrian_report_autolock(void)
{
	static const char *keys[] = {
		"SBLockScreenAutoLockTime",
		"SBLockScreenDisableAutoLock",
		"SBIdleTimerTimeout",
		"SBDeviceLockBlocked",
	};
	CFStringRef app = CFSTR("com.apple.springboard");
	char line[160];
	unsigned i;
	int seconds;

	for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
		CFStringRef key = CFStringCreateWithCString(NULL, keys[i],
		    kCFStringEncodingUTF8);
		CFTypeRef value = key != NULL ?
		    CFPreferencesCopyAppValue(key, app) : NULL;

		if (value == NULL) {
			snprintf(line, sizeof(line), "MONDRIAN PREF: %s missing\n",
			    keys[i]);
		} else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
			int number = 0;

			CFNumberGetValue((CFNumberRef)value, kCFNumberIntType,
			    &number);
			snprintf(line, sizeof(line), "MONDRIAN PREF: %s = %d\n",
			    keys[i], number);
		} else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
			snprintf(line, sizeof(line), "MONDRIAN PREF: %s = %s\n",
			    keys[i], CFBooleanGetValue((CFBooleanRef)value) ?
			    "true" : "false");
		} else {
			snprintf(line, sizeof(line), "MONDRIAN PREF: %s type %lu\n",
			    keys[i], (unsigned long)CFGetTypeID(value));
		}
		say(line);
		if (value != NULL) {
			CFRelease(value);
		}
		if (key != NULL) {
			CFRelease(key);
		}
	}
	seconds = boot_arg_int("mondrianautolock=", 0);
	if (seconds <= 0) {
		return;
	}
	{
		CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType,
		    &seconds);

		if (number == NULL) {
			return;
		}
		CFPreferencesSetAppValue(CFSTR("SBLockScreenAutoLockTime"), number,
		    app);
		CFPreferencesSetAppValue(CFSTR("SBLockScreenDisableAutoLock"),
		    kCFBooleanFalse, app);
		CFPreferencesAppSynchronize(app);
		CFRelease(number);
		snprintf(line, sizeof(line), "MONDRIAN PREF: auto-lock set to %d s\n",
		    seconds);
		say(line);
	}
}

/*
 * What is the idle machinery doing? SpringBoard's lock screen owns an
 * `SBIdleTimerPolicyAggregator` fed by providers (`idleTimerProvider:
 * didProposeBehavior:forReason:`); its description lists the providers and the
 * behaviour in effect, which is what says whether the timer was ever armed.
 */
static void
mondrian_report_idle(void)
{
	Class cls = objc_getClass("SBLockScreenManager");
	SEL shared_sel = sel_registerName("sharedInstance");
	SEL agg_sel = sel_registerName("_idleTimerPolicyAggregator");
	char line[400];
	Method method;
	id manager;
	id agg;

	if (cls == Nil) {
		say("MONDRIAN IDLE: no SBLockScreenManager\n");
		return;
	}
	method = class_getClassMethod(cls, shared_sel);
	if (method == NULL) {
		return;
	}
	manager = ((id (*)(id, SEL))method_getImplementation(method))((id)cls,
	    shared_sel);
	if (manager == nil) {
		say("MONDRIAN IDLE: no shared lock screen manager\n");
		return;
	}
	if (![manager respondsToSelector:agg_sel]) {
		say("MONDRIAN IDLE: no _idleTimerPolicyAggregator\n");
		return;
	}
	agg = ((id (*)(id, SEL))objc_msgSend)(manager, agg_sel);
	snprintf(line, sizeof(line), "MONDRIAN IDLE: aggregator %s\n",
	    agg != NULL ? object_getClassName(agg) : "(nil)");
	say(line);
	if (agg == nil) {
		return;
	}
	if ([agg respondsToSelector:sel_registerName("description")]) {
		id desc = ((id (*)(id, SEL))objc_msgSend)(agg,
		    sel_registerName("description"));
		const char *text = desc != nil ? [desc UTF8String] : NULL;

		if (text != NULL) {
			snprintf(line, sizeof(line), "MONDRIAN IDLE: %.360s\n", text);
			say(line);
		}
	}
	if ([agg respondsToSelector:sel_registerName("isDisabled")]) {
		BOOL disabled = ((BOOL (*)(id, SEL))objc_msgSend)(agg,
		    sel_registerName("isDisabled"));

		snprintf(line, sizeof(line), "MONDRIAN IDLE: disabled %d\n",
		    (int)disabled);
		say(line);
	}
}

/*
 * Does the blanking call return? `0261` recorded SpringBoard's main thread
 * stopping inside `BKSDisplayServicesSetScreenBlanked`, so the call runs on a
 * thread of its own: if it never returns, the ring shows the enter line
 * without the exit one and the UI keeps its run loop. `mondrianblank=N`.
 */
static void *
mondrian_blank_test(void *unused)
{
	void (*set_blanked)(int) = (void (*)(int))dlsym(RTLD_DEFAULT,
	    "BKSDisplayServicesSetScreenBlanked");

	(void)unused;
	if (set_blanked == NULL) {
		say("MONDRIAN BLANK: BKSDisplayServicesSetScreenBlanked missing\n");
		return NULL;
	}
	say("MONDRIAN BLANK: setScreenBlanked 1 enter\n");
	set_blanked(1);
	say("MONDRIAN BLANK: setScreenBlanked 1 exit\n");
	sleep(5);
	say("MONDRIAN BLANK: setScreenBlanked 0 enter\n");
	set_blanked(0);
	say("MONDRIAN BLANK: setScreenBlanked 0 exit\n");
	return NULL;
}

/*
 * The App Library's background comes out grey -- and while the kernel console
 * was still painting, it had the console's own pixels in it. Both are the same
 * fault: a CABackdropLayer with allowsInPlaceFiltering set applies its filters
 * into the buffer it is reading, so what it samples is what was drawn there
 * last, not what is behind it; a layer tree the window server has flattened has
 * no live content left for it at all. Turn both off on every backdrop layer and
 * on every window, and say once what each key did (a key a class does not have
 * raises, and that is not worth a boot).
 *
 * Measured 2026-11-17: the App Library's background is drawn by a backdrop layer
 * in SpringBoard's own tree (`mondriangeom=1` names it), and it came out grey
 * with the previous frame's pixels in it.
 */
static int mondrian_backdrop_keys_off(void);

/* how many layers took each key (see the table in the walker) */
static unsigned backdrop_keys[3];

static unsigned
mondrian_backdrop_fix_layer(id layer, unsigned depth, unsigned *told, unsigned *seen)
{
	id subs;
	unsigned n, i, hits = 0;
	const char *name = layer != nil ? object_getClassName(layer) : NULL;

	if (layer == nil || depth > 14 || *seen >= 6000) {
		return 0;
	}
	(*seen)++;
	if (name != NULL && strstr(name, "Backdrop") != NULL) {
		/*
		 * Three keys, from what CABackdropLayer is documented to do (see
		 * the comment above): filter in place (stale content), substitute
		 * a solid colour when the window server cannot sample what is
		 * behind (a flat grey -- which is what the App Library's
		 * background is), and drop the blur when CA thinks the backdrop
		 * is occluded. A key a class does not have raises; that is
		 * counted, not fatal.
		 */
		static const char *keys[] = {
			"allowsInPlaceFiltering",
			"allowsSubstituteColor",
			"disablesOccludedBackdropBlurs",
		};

		for (unsigned k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
			@try {
				[layer setValue:[NSNumber numberWithBool:NO]
				    forKey:[NSString stringWithUTF8String:keys[k]]];
				backdrop_keys[k]++;
				(*told)++;
				hits++;
			} @catch (id e) {
			}
		}
	}
	subs = mondrian_send(layer, "sublayers");
	n = subs != nil ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_backdrop_fix_layer(
		    [(NSArray *)subs objectAtIndex:i], depth + 1, told, seen);
	}
	return hits;
}

static void
mondrian_backdrop_fix(void)
{
	static unsigned said;
	Class app_cls = objc_getClass("UIApplication");
	SEL app_sel = sel_registerName("sharedApplication");
	Method method;
	id app, windows, layer;
	unsigned count, i, told = 0, seen = 0, flattened = 0;

	if (app_cls == Nil || boot_arg_set("mondrianbackdrop=0") || mondrian_backdrop_keys_off()) {
		return;
	}
	method = class_getClassMethod(app_cls, app_sel);
	if (method == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    app_sel);
	if (app == nil) {
		return;
	}
	windows = mondrian_send(app, "windows");
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count && i < 12; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];

		@try {
			[window setValue:[NSNumber numberWithBool:NO]
			    forKey:@"shouldAutoFlattenLayerTree"];
			flattened++;
		} @catch (id e) {
		}
		layer = mondrian_send(window, "layer");
		(void)mondrian_backdrop_fix_layer(layer, 0, &told, &seen);
	}
	if (told != 0 && said < 6) {
		char line[160];

		said++;
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: backdrop fix %u: %u key(s) told (%u place,"
		    " %u substitute, %u occluded), %u seen, %u window(s) kept"
		    " from flattening\n", said, told, backdrop_keys[0],
		    backdrop_keys[1], backdrop_keys[2], seen, flattened);
		say(line);
	}
}

/*
 * Is the wallpaper still there behind the App Library? The App Library's
 * background is a backdrop that samples what is behind it: if SpringBoard hides
 * the wallpaper view when the library opens, or if the library's own background
 * is opaque black, there is nothing to sample and the material comes out as a
 * substitute colour -- which is what the panel shows.
 *
 * Written when /private/var/vm/mondrian-wallprobe exists: every view of every
 * window whose class names a wallpaper, a poster or the library, with its frame,
 * hidden flag, alpha and layer background colour. Ten dumps, then quiet.
 */
static unsigned
mondrian_wall_walk(id view, unsigned depth, unsigned *printed, unsigned *seen)
{
	id layer, kids, colour;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 12 || *printed >= 24 || *seen >= 6000) {
		return 0;
	}
	(*seen)++;
	if (name != NULL && (strstr(name, "Wallpaper") != NULL || strstr(name, "Poster") != NULL ||
	    strstr(name, "Library") != NULL || strstr(name, "Homescreen") != NULL ||
	    strstr(name, "HomeScreen") != NULL)) {
		char line[320];
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
		CGFloat alpha = -1.0;
		BOOL hidden = NO;
		const char *super = "?";
		char background[64] = "none";

		if ([view respondsToSelector:sel_registerName("alpha")]) {
			alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(view, sel_registerName("alpha"));
		}
		if ([view respondsToSelector:sel_registerName("isHidden")]) {
			hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isHidden"));
		}
		if (mondrian_send(view, "superview") != nil) {
			super = object_getClassName(mondrian_send(view, "superview"));
		}
		layer = mondrian_send(view, "layer");
		if (layer != nil && [layer respondsToSelector:sel_registerName("backgroundColor")]) {
			CGColorRef cg = (CGColorRef)((id (*)(id, SEL))objc_msgSend)(layer,
			    sel_registerName("backgroundColor"));

			if (cg != NULL) {
				size_t parts = CGColorGetNumberOfComponents(cg);
				const CGFloat *c = CGColorGetComponents(cg);

				(void)snprintf(background, sizeof(background), "%zu:", parts);
				for (size_t k = 0; k < parts && k < 4; k++) {
					(void)snprintf(background + strlen(background),
					    sizeof(background) - strlen(background), " %.2f", (double)c[k]);
				}
			}
		}
		(void)colour;
		(*printed)++;
		hits++;
		snprintf(line, sizeof(line),
		    "MONDRIAN WALL: %s in %s at %.0f,%.0f %.0fx%.0f hidden %d alpha %.2f"
		    " layer %s background %s\n", name, super, (double)frame.origin.x,
		    (double)frame.origin.y, (double)frame.size.width, (double)frame.size.height,
		    (int)hidden, (double)alpha, layer != nil ? object_getClassName(layer) : "-",
		    background);
		say(line);
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_wall_walk([(NSArray *)kids objectAtIndex:i], depth + 1, printed, seen);
	}
	return hits;
}

static void
mondrian_wall_probe(void)
{
	static unsigned dumps;
	Class app_cls = objc_getClass("UIApplication");
	SEL app_sel = sel_registerName("sharedApplication");
	Method method;
	id app, windows;
	unsigned count, i;

	if (dumps >= 300 || access("/private/var/vm/mondrian-wallprobe", F_OK) != 0) {
		return;
	}
	if (app_cls == Nil || (method = class_getClassMethod(app_cls, app_sel)) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls, app_sel);
	if (app == nil) {
		return;
	}
	windows = mondrian_send(app, "windows");
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	dumps++;
	{
		char line[160];

		snprintf(line, sizeof(line), "MONDRIAN WALL: dump %u of %u window(s)\n", dumps, count);
		say(line);
	}
	for (i = 0; i < count && i < 10; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		unsigned printed = 0, seen = 0;
		char line[192];
		const char *name = object_getClassName(window);
		BOOL hidden = NO;
		CGFloat alpha = -1.0;

		if ([window respondsToSelector:sel_registerName("isHidden")]) {
			hidden = ((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("isHidden"));
		}
		if ([window respondsToSelector:sel_registerName("alpha")]) {
			alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(window, sel_registerName("alpha"));
		}
		snprintf(line, sizeof(line), "MONDRIAN WALL: window %s hidden %d alpha %.2f\n",
		    name != NULL ? name : "?", (int)hidden, (double)alpha);
		say(line);
		if (hidden) {
			continue;
		}
		(void)mondrian_wall_walk(window, 0, &printed, &seen);
	}
}

/* A backdrop layer that is allowed to fall back to a solid colour hides the fault
 * it works around: /private/var/vm/mondrian-backdrop-off puts the keys back as
 * they were for an A/B that needs no build, no boot and no file of its own. */
static int
mondrian_backdrop_keys_off(void)
{
	return access("/private/var/vm/mondrian-backdrop-off", F_OK) == 0;
}

/*
 * The App Library's background is a backdrop, and a backdrop is a window-server
 * feature: the layer asks the compositor for what is below it. Measured here
 * (2026-11-17): the picture it samples is a full-screen surface that nothing on
 * this port fills -- with the layers at their defaults the library comes out
 * black, and the grey it used to show is the substitute colour
 * CABackdropLayer falls back to. The wallpaper itself is in a window of its own
 * (_SBWallpaperSecureWindow, whose poster view holds the bitmap), so what this
 * does is take that bitmap, put it under the home screen's own layers, and take
 * the broken backdrop out of the way.
 *
 * Armed by /private/var/vm/mondrian-wallpaint; while the file is absent nothing
 * is touched and the layer is taken away again, so the A/B is a file.
 */
static id mondrian_wall_contents;
static id mondrian_wall_find(id view, unsigned depth);

/* What the picture really is: a photograph, or a grey mask with stripes in it. */
static void
mondrian_wall_inspect(CGImageRef image)
{
	size_t width, height, row;
	CGColorSpaceModel model;
	CGContextRef ctx;
	uint8_t *pixels;
	char line[300];
	static const struct {
		int x, y;
	} places[] = { { 720, 300 }, { 720, 1600 }, { 720, 2900 }, { 200, 1600 } };

	if (image == NULL) {
		return;
	}
	width = CGImageGetWidth(image);
	height = CGImageGetHeight(image);
	model = CGColorSpaceGetModel(CGImageGetColorSpace(image));
	snprintf(line, sizeof(line),
	    "MONDRIAN WALL: image %zux%zu, %zu bits a component, %zu a pixel, %zu a row,"
	    " model %d, alpha %d\n", width, height, CGImageGetBitsPerComponent(image),
	    CGImageGetBitsPerPixel(image), CGImageGetBytesPerRow(image), (int)model,
	    (int)CGImageGetAlphaInfo(image));
	say(line);
	if (width == 0 || height == 0 || width > 4096 || height > 4096) {
		return;
	}
	row = width * 4;
	pixels = calloc(1, row * height);
	if (pixels == NULL) {
		return;
	}
	ctx = CGBitmapContextCreate(pixels, width, height, 8, row, CGColorSpaceCreateDeviceRGB(),
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	if (ctx == NULL) {
		free(pixels);
		return;
	}
	CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
	for (unsigned i = 0; i < sizeof(places) / sizeof(places[0]); i++) {
		int x = places[i].x, y = places[i].y;
		size_t at;

		/*
		 * `places` is written in full-panel coordinates (1440x3200) and this
		 * runs on whatever image the window holds, which can be the 720x1600
		 * wallpaper this hook draws itself: there y = 1600 and 2900 are past
		 * the end of the buffer, and the read below lands in whatever is
		 * mapped after it. That was the intermittent SpringBoard SEGV of
		 * 2026-11-18: `pc` at this `ldrb`, `far` in the hole just past the
		 * allocation. Skip a place that is not inside the image.
		 */
		if (x < 0 || y < 0 || (size_t)x >= width || (size_t)y >= height) {
			snprintf(line, sizeof(line),
			    "MONDRIAN WALL: pixel %d,%d outside %zux%zu\n",
			    x, y, width, height);
			say(line);
			continue;
		}
		at = (size_t)y * row + (size_t)x * 4;
		snprintf(line, sizeof(line), "MONDRIAN WALL: pixel %d,%d is %u %u %u %u\n",
		    x, y, pixels[at + 2], pixels[at + 1], pixels[at + 0],
		    pixels[at + 3]);
		say(line);
	}
	CGContextRelease(ctx);
	free(pixels);
	/*
	 * And the bytes as they are, without CoreGraphics in the middle: if the surface
	 * holds a colour picture described as grey, the four bytes at a place are the
	 * wallpaper's own channels and the label is the whole bug.
	 */
	{
		CGDataProviderRef provider = CGImageGetDataProvider(image);
		CFDataRef data = provider != NULL ? CGDataProviderCopyData(provider) : NULL;

		if (data != NULL) {
			const uint8_t *bytes = CFDataGetBytePtr(data);
			CFIndex length = CFDataGetLength(data);
			size_t stride = CGImageGetBytesPerRow(image);

			for (unsigned i = 0; i < sizeof(places) / sizeof(places[0]); i++) {
				size_t at = (size_t)places[i].y * stride + (size_t)places[i].x * 4;

				if (bytes != NULL && (CFIndex)(at + 4) <= length) {
					snprintf(line, sizeof(line),
					    "MONDRIAN WALL: raw %d,%d is %02x %02x %02x %02x\n",
					    places[i].x, places[i].y, bytes[at + 0], bytes[at + 1],
					    bytes[at + 2], bytes[at + 3]);
					say(line);
				}
			}
			CFRelease(data);
		}
	}
}

/* The same view of the system's own snapshot, for the A/B that has nothing of ours in it. */
static void
mondrian_wall_snapshot(void)
{
	static unsigned said;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;
	id found = nil;

	if (said >= 2 || app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		found = mondrian_wall_find([(NSArray *)windows objectAtIndex:i], 0);
		if (found != nil) {
			break;
		}
	}
	if (found != nil && CFGetTypeID((CFTypeRef)found) == CGImageGetTypeID()) {
		said++;
		mondrian_wall_inspect((CGImageRef)found);
	}
}

/*
 * A colour picture under a grey label.
 *
 * Measured 2026-11-17: the App Library's background arrives as a CGImage of four
 * bytes a pixel whose colour space says "monochrome", and those bytes are a colour
 * picture (`f47c5b`, `68a4d9` -- the wallpaper and the icons). CoreGraphics draws
 * them anyway; CoreAnimation's GLES renderer believes the label and hands a grey
 * image to the GPU one byte a pixel, so one byte of every four reaches the screen
 * and the result is the 4-px striping behind the library.
 *
 * The fix is the label, not the picture: the same bytes under an RGB colour space,
 * keeping the alpha and byte order the source declared. The guard matters -- a
 * truly grey 32-bit bitmap has equal channels, and relabelling that would invent
 * colour -- so the data is sampled before anything is rebuilt.
 */
static int
mondrian_picture_has_colour(CGDataProviderRef provider, size_t width, size_t height,
    size_t bytesPerRow)
{
	CFDataRef data = provider != NULL ? CGDataProviderCopyData(provider) : NULL;
	const uint8_t *bytes;
	CFIndex length;
	int colour = 0;

	if (data == NULL) {
		return 0;
	}
	bytes = CFDataGetBytePtr(data);
	length = CFDataGetLength(data);
	if (bytes != NULL) {
		for (unsigned i = 0; i < 96 && !colour; i++) {
			size_t x = (width * (size_t)((i * 37) % 96)) / 96;
			size_t y = (height * (size_t)((i * 53) % 96)) / 96;
			size_t at = y * bytesPerRow + x * 4;

			if ((CFIndex)(at + 4) <= length &&
			    (bytes[at] != bytes[at + 1] || bytes[at + 1] != bytes[at + 2])) {
				colour = 1;
			}
		}
	}
	CFRelease(data);
	return colour;
}

static CGImageRef
mondrian_wall_relabel(CGImageRef image)
{
	CGDataProviderRef source;
	CFDataRef data;
	CGDataProviderRef provider;
	CGColorSpaceRef rgb;
	CGImageRef made;

	if (image == NULL || CGImageGetBitsPerPixel(image) != 32 ||
	    CGImageGetBitsPerComponent(image) != 8 ||
	    CGColorSpaceGetModel(CGImageGetColorSpace(image)) != kCGColorSpaceModelMonochrome ||
	    CGImageGetBytesPerRow(image) < CGImageGetWidth(image) * 4) {
		return NULL;
	}
	source = CGImageGetDataProvider(image);
	if (!mondrian_picture_has_colour(source, CGImageGetWidth(image), CGImageGetHeight(image),
	    CGImageGetBytesPerRow(image))) {
		return NULL;
	}
	data = CGDataProviderCopyData(source);
	if (data == NULL) {
		return NULL;
	}
	provider = CGDataProviderCreateWithCFData(data);
	rgb = CGColorSpaceCreateDeviceRGB();
	/* The source's own alpha and byte order: only the colour model is wrong. */
	made = provider != NULL ? CGImageCreate(CGImageGetWidth(image), CGImageGetHeight(image), 8, 32,
	    CGImageGetBytesPerRow(image), rgb, CGImageGetBitmapInfo(image), provider, NULL, false,
	    kCGRenderingIntentDefault) : NULL;
	if (rgb != NULL) {
		CGColorSpaceRelease(rgb);
	}
	if (provider != NULL) {
		CGDataProviderRelease(provider);
	}
	CFRelease(data);
	return made;
}

static CALayer *mondrian_wall_layer;
static unsigned mondrian_wall_said;

static int
mondrian_file_on(const char *path)
{
	char first = 0;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		return 0;
	}
	(void)read(fd, &first, 1);
	(void)close(fd);
	return !(first == '0' || first == 'n');
}

/* The switch's first byte, for a probe with more than on/off. */
static int
mondrian_file_is(const char *path, char want)
{
	char first = 0;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		return 0;
	}
	(void)read(fd, &first, 1);
	(void)close(fd);
	return first == want;
}

/* A switch written from inside the process, for a step that must run once. */
static void
mondrian_touch(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd < 0) {
		return;
	}
	(void)write(fd, "1", 1);
	(void)close(fd);
}

/*
 * These two fixes are on unless a file says otherwise: the wallpaper and the library's
 * background were never drawn on this port, and without them the UI looks broken. A
 * file holding `0` turns one off for an A/B, which needs no build and no boot.
 */
static int
mondrian_fix_on(const char *path)
{
	char first = 0;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		return 1;
	}
	if (read(fd, &first, 1) != 1) {
		(void)close(fd);
		return 1;
	}
	(void)close(fd);
	return !(first == '0' || first == 'n');
}

/* The first layer under `view` whose class names the wallpaper and that has a picture. */
static id
mondrian_wall_find(id view, unsigned depth)
{
	id layer, kids, contents;
	unsigned n, i;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 10) {
		return nil;
	}
	layer = mondrian_send(view, "layer");
	if (layer != nil) {
		contents = mondrian_send(layer, "contents");

		if (contents != nil && name != NULL &&
		    (strstr(name, "ImageView") != NULL || strstr(name, "Snapshot") != NULL ||
		    strstr(name, "Poster") != NULL || strstr(name, "Wallpaper") != NULL)) {
			return contents;
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		id found = mondrian_wall_find([(NSArray *)kids objectAtIndex:i], depth + 1);

		if (found != nil) {
			return found;
		}
	}
	return nil;
}

/* Every `*Backdrop*` view inside `view` stops drawing. */
static unsigned
mondrian_backdrop_hide(id view, unsigned depth)
{
	id kids;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 8) {
		return 0;
	}
	if (name != NULL && strstr(name, "Backdrop") != NULL &&
	    [view respondsToSelector:sel_registerName("setAlpha:")]) {
		((void (*)(id, SEL, CGFloat))objc_msgSend)(view, sel_registerName("setAlpha:"), (CGFloat)0.0);
		hits++;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_backdrop_hide([(NSArray *)kids objectAtIndex:i], depth + 1);
	}
	return hits;
}

/*
 * A snapshot of the display, taken by the window server itself. The poster's own
 * replica is magenta on this port (measured: every byte of the 1440x3200 CGImage is
 * ff 00 ff ff), so the only reliable picture of the wallpaper is the screen it is
 * already drawn on. The symbol is looked up at run time: if this build has no such
 * function the paint simply does not happen.
 */
static CGImageRef
mondrian_display_picture(void)
{
	static void (*render_display)(unsigned, CFStringRef, CGContextRef, int, int);
	static int looked;
	size_t width = 1440, height = 3200, row = width * 4;
	CGColorSpaceRef rgb;
	CGContextRef ctx;
	CGImageRef made = NULL;
	uint8_t *buffer;
	const uint8_t *middle;

	if (!looked) {
		looked = 1;
		render_display = (void (*)(unsigned, CFStringRef, CGContextRef, int, int))
		    dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
		if (render_display == NULL) {
			say("MONDRIAN WALL: no CARenderServerRenderDisplay here\n");
		}
	}
	if (render_display == NULL) {
		return NULL;
	}
	buffer = calloc(1, row * height);
	if (buffer == NULL) {
		return NULL;
	}
	rgb = CGColorSpaceCreateDeviceRGB();
	ctx = CGBitmapContextCreate(buffer, width, height, 8, row, rgb,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(rgb);
	if (ctx == NULL) {
		free(buffer);
		return NULL;
	}
	render_display(0, CFSTR("mon"), ctx, 0, 0);
	middle = buffer + (size_t)(height / 2) * row + (size_t)(width / 2) * 4;
	if (!(middle[0] == 0xff && middle[1] == 0x00 && middle[2] == 0xff) &&
	    (middle[0] | middle[1] | middle[2]) != 0) {
		made = CGBitmapContextCreateImage(ctx);
	} else {
		static unsigned said;

		if (said++ < 3) {
			char line[96];

			snprintf(line, sizeof(line), "MONDRIAN WALL: the display came back %02x %02x %02x\n",
			    middle[2], middle[1], middle[0]);
			say(line);
		}
	}
	CGContextRelease(ctx);
	free(buffer);
	return made;
}

static int
mondrian_visible(id view)
{
	id up = view;
	unsigned guard = 0;

	while (up != nil && guard++ < 40) {
		if ([up respondsToSelector:sel_registerName("isHidden")]) {
			BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(up, sel_registerName("isHidden"));
			CGFloat alpha = 1.0;

			if ([up respondsToSelector:sel_registerName("alpha")]) {
				alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(up, sel_registerName("alpha"));
			}
			if (hidden || alpha < 0.01) {
				return 0;
			}
		}
		up = mondrian_send(up, "superview");
	}
	return view != nil;
}

static id
mondrian_find_class(id view, unsigned depth, const char *part)
{
	id kids;
	unsigned n, i;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 14) {
		return nil;
	}
	if (name != NULL && strstr(name, part) != NULL) {
		return view;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		id found = mondrian_find_class([(NSArray *)kids objectAtIndex:i], depth + 1, part);

		if (found != nil) {
			return found;
		}
	}
	return nil;
}

/* Is the App Library on screen? Its view exists all the time; what changes when it
 * opens is that nothing above it is hidden any more. */
static int
mondrian_library_open(void)
{
	static id (*shared)(id, SEL);
	Class cls = objc_getClass("UIApplication");
	Method method = cls != Nil ? class_getClassMethod(cls, sel_registerName("sharedApplication")) : NULL;
	id app, windows;
	unsigned count, i;

	if (method == NULL) {
		return 0;
	}
	shared = (id (*)(id, SEL))method_getImplementation(method);
	app = shared((id)cls, sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id view = mondrian_find_class([(NSArray *)windows objectAtIndex:i], 0, "SBHLibraryPodFolder");

		if (view != nil) {
			return mondrian_visible(view);
		}
	}
	return 0;
}

static void
mondrian_wallpaint(void)
{
	static unsigned said;
	static double last_picture;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows, home = nil;
	unsigned count, i;

	if (!mondrian_file_on("/private/var/vm/mondrian-wallpaint")) {
		if (mondrian_wall_layer != nil) {
			((void (*)(id, SEL))objc_msgSend)(mondrian_wall_layer,
			    sel_registerName("removeFromSuperlayer"));
			mondrian_wall_layer = nil;
			if (said++ < 4) {
				say("MONDRIAN WALL: paint off\n");
			}
		}
		return;
	}
	if (mondrian_wall_layer != nil) {
		/*
		 * In place: the picture is taken again now and then while the App
		 * Library is closed, because that is when the wallpaper is on the
		 * glass, and it is kept for when it opens.
		 */
		double now = (double)CFAbsoluteTimeGetCurrent();

		if (!mondrian_library_open() && now - last_picture > 5.0) {
			CGImageRef picture = mondrian_display_picture();

			last_picture = now;
			if (picture != NULL) {
				((void (*)(id, SEL, id))objc_msgSend)(mondrian_wall_layer,
				    sel_registerName("setContents:"), (id)picture);
				CGImageRelease(picture);
			}
		}
		return;
	}
	if (app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	if (app == nil) {
		return;
	}
	windows = mondrian_send(app, "windows");
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);

		if (name != NULL && strstr(name, "HomeScreenWindow") != NULL) {
			home = window;
		}
	}
	if (home == nil) {
		return;
	}
	{
		id layer = mondrian_send(home, "layer");
		CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(home, sel_registerName("bounds"));
		Class calayer = objc_getClass("CALayer");
		id made, dim;
		CGColorRef black;

		if (layer == nil || calayer == Nil) {
			return;
		}
		made = ((id (*)(id, SEL))objc_msgSend)((id)calayer, sel_registerName("alloc"));
		made = ((id (*)(id, SEL))objc_msgSend)(made, sel_registerName("init"));
		if (made == nil) {
			return;
		}
		((void (*)(id, SEL, CGRect))objc_msgSend)(made, sel_registerName("setFrame:"), bounds);
		((void (*)(id, SEL, CGFloat))objc_msgSend)(made, sel_registerName("setContentsScale:"),
		    (CGFloat)3.0);
		((void (*)(id, SEL, id))objc_msgSend)(made, sel_registerName("setContentsGravity:"),
		    @"resizeAspectFill");
		((void (*)(id, SEL, CGFloat))objc_msgSend)(made, sel_registerName("setZPosition:"),
		    (CGFloat)-100000.0);
		((void (*)(id, SEL, id, unsigned))objc_msgSend)(layer,
		    sel_registerName("insertSublayer:atIndex:"), made, (unsigned)0);
		mondrian_wall_layer = made;
		dim = ((id (*)(id, SEL))objc_msgSend)((id)calayer, sel_registerName("alloc"));
		dim = ((id (*)(id, SEL))objc_msgSend)(dim, sel_registerName("init"));
		black = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.12);
		if (dim != nil && black != NULL) {
			((void (*)(id, SEL, CGColorRef))objc_msgSend)(dim,
			    sel_registerName("setBackgroundColor:"), black);
			((void (*)(id, SEL, CGRect))objc_msgSend)(dim, sel_registerName("setFrame:"), bounds);
			((void (*)(id, SEL, CGFloat))objc_msgSend)(dim, sel_registerName("setZPosition:"),
			    (CGFloat)-99000.0);
			((void (*)(id, SEL, id, id))objc_msgSend)(layer,
			    sel_registerName("insertSublayer:above:"), dim, made);
		}
		if (black != NULL) {
			CGColorRelease(black);
		}
	}
	{
		char line[128];

		snprintf(line, sizeof(line), "MONDRIAN WALL: paint on: %u backdrop view(s) hidden\n",
		    mondrian_backdrop_hide(home, 0));
		say(line);
	}
	last_picture = 0.0;
}

/* What is actually in the home screen's window, layer by layer. */
static unsigned
mondrian_tree_walk(id view, unsigned depth, unsigned *printed)
{
	id layer, kids;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 7 || *printed >= 90) {
		return 0;
	}
	{
		char line[300];
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
		BOOL hidden = NO;
		id contents = nil;
		const char *lname = "-";
		const char *group = "-";

		if ([view respondsToSelector:sel_registerName("isHidden")]) {
			hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isHidden"));
		}
		layer = mondrian_send(view, "layer");
		if (layer != nil) {
			lname = object_getClassName(layer);
			contents = mondrian_send(layer, "contents");
			if ([layer respondsToSelector:sel_registerName("groupName")]) {
				id g = mondrian_send(layer, "groupName");

				if (g != nil && [g isKindOfClass:objc_getClass("NSString")]) {
					group = [(NSString *)g UTF8String];
				}
			}
		}
		(*printed)++;
		hits++;
		snprintf(line, sizeof(line),
		    "MONDRIAN TREE: %*s%s at %.0f,%.0f %.0fx%.0f hidden %d layer %s contents %s group %s\n",
		    (int)(depth * 2), "", name != NULL ? name : "?", (double)frame.origin.x,
		    (double)frame.origin.y, (double)frame.size.width, (double)frame.size.height,
		    (int)hidden, lname, contents != nil ? "yes" : "no", group);
		say(line);
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_tree_walk([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
	return hits;
}

static void
mondrian_tree_probe(void)
{
	static unsigned said;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;

	if (said >= 6 || !mondrian_file_on("/private/var/vm/mondrian-treeprobe")) {
		return;
	}
	if (app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	if (app == nil) {
		return;
	}
	windows = mondrian_send(app, "windows");
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		unsigned printed = 0;

		if (name == NULL || (strstr(name, "HomeScreenWindow") == NULL &&
		    strstr(name, "Wallpaper") == NULL)) {
			continue;
		}
		said++;
		{
			char line[96];

			snprintf(line, sizeof(line), "MONDRIAN TREE: %s, dump %u\n", name, said);
			say(line);
		}
		(void)mondrian_tree_walk(window, 0, &printed);
	}
}

/*
 * Everything inside the two windows, layer by layer, when the host asks for it: the file
 * /private/var/vm/mondrian-deep is written again (its mtime moves) and the next tick
 * dumps. That is what identifies which layer draws a full-screen picture, in the state
 * the screen is really in -- with the App Library open, not at boot.
 */
static unsigned
mondrian_deep_view(id view, unsigned depth, unsigned *printed)
{
	id layer, kids;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 14 || *printed >= 240 ||
	    (name != NULL && (strstr(name, "SBIconView") != NULL || strstr(name, "SBIconImage") != NULL))) {
		return 0;
	}
	{
		char line[300];
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
		BOOL hidden = NO;
		CGFloat alpha = -1.0, layer_alpha = -1.0;
		id contents = nil;
		const char *lname = "-";

		if ([view respondsToSelector:sel_registerName("isHidden")]) {
			hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isHidden"));
		}
		if ([view respondsToSelector:sel_registerName("alpha")]) {
			alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(view, sel_registerName("alpha"));
		}
		layer = mondrian_send(view, "layer");
		if (layer != nil) {
			lname = object_getClassName(layer);
			contents = mondrian_send(layer, "contents");
			if ([layer respondsToSelector:sel_registerName("opacity")]) {
				layer_alpha = ((float (*)(id, SEL))objc_msgSend)(layer,
				    sel_registerName("opacity"));
			}
		}
		(*printed)++;
		hits++;
		snprintf(line, sizeof(line),
		    "MONDRIAN DEEP: %*s%s %.0f,%.0f %.0fx%.0f hidden %d alpha %.2f layer %s"
		    " opacity %.2f contents %s\n", (int)(depth * 2), "", name != NULL ? name : "?",
		    (double)frame.origin.x, (double)frame.origin.y, (double)frame.size.width,
		    (double)frame.size.height, (int)hidden, (double)alpha, lname, (double)layer_alpha,
		    contents != nil ? "yes" : "no");
		say(line);
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_deep_view([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
	return hits;
}

static void
mondrian_deep_probe(void)
{
	static unsigned long asked;
	static unsigned dumps;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;

	/*
	 * The file holds a number the host changes; stat() is refused here (measured:
	 * a daemon cannot stat /private/var/vm on this port) and open() is not.
	 */
	{
		FILE *asked_file = fopen("/private/var/vm/mondrian-deep", "r");
		unsigned long wanted = 0;

		if (asked_file == NULL) {
			return;
		}
		if (fscanf(asked_file, "%lu", &wanted) != 1) {
			(void)fclose(asked_file);
			return;
		}
		(void)fclose(asked_file);
		if (dumps >= 4 || wanted == asked) {
			return;
		}
		asked = wanted;
	}
	if (app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	if (app == nil) {
		return;
	}
	windows = mondrian_send(app, "windows");
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	dumps++;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		unsigned printed = 0;
		char line[128];

		if (name == NULL || (strstr(name, "HomeScreenWindow") == NULL &&
		    strstr(name, "Wallpaper") == NULL)) {
			continue;
		}
		snprintf(line, sizeof(line), "MONDRIAN DEEP: %s, dump %u\n", name, dumps);
		say(line);
		(void)mondrian_deep_view(window, 0, &printed);
	}
}

/*
 * The App Library's own background is a picture, and on this port that picture is a
 * magenta placeholder read as one byte a pixel -- which is the fine grey striping on
 * the glass. The wallpaper itself cannot be copied: it is a CALayerHost rendered by
 * another process. What can be copied is the display, while the home screen is on it,
 * and that picture is what the library's background is given instead.
 */
static CGImageRef mondrian_live_picture;
static id mondrian_live_replaced;
static double mondrian_live_at;

/* Is the home screen the one on the glass? Then the App Library is not open. */
static int
mondrian_home_visible(void)
{
	Class app_cls = objc_getClass("UIApplication");
	Method method = app_cls != Nil ?
	    class_getClassMethod(app_cls, sel_registerName("sharedApplication")) : NULL;
	id app, windows;
	unsigned count, i;

	if (method == NULL) {
		return 0;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		id folder;

		if (name == NULL || strstr(name, "HomeScreenWindow") == NULL) {
			continue;
		}
		folder = mondrian_find_class(window, 0, "SBRootFolderView");
		if (folder != nil) {
			return mondrian_visible(folder);
		}
	}
	return 0;
}

/* Every full-screen layer of the library that carries a picture: give it the real one. */
static unsigned
mondrian_live_walk(id view, unsigned depth, unsigned *printed)
{
	id layer, kids, contents;
	unsigned n, i, hits = 0;

	if (view == nil || depth > 12 || *printed >= 60) {
		return 0;
	}
	layer = mondrian_send(view, "layer");
	if (layer != nil) {
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));

		contents = mondrian_send(layer, "contents");
		if (contents != nil && frame.size.width >= 400.0 && frame.size.height >= 900.0 &&
		    (id)contents != (id)mondrian_live_picture) {
			char line[220];

			((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setContents:"),
			    (id)mondrian_live_picture);
			(*printed)++;
			snprintf(line, sizeof(line), "MONDRIAN LIVE: %s %.0fx%.0f got the picture\n",
			    object_getClassName(view), (double)frame.size.width,
			    (double)frame.size.height);
			say(line);
			mondrian_live_replaced = view;
			hits++;
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_live_walk([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
	return hits;
}

static void
mondrian_live_paint(void)
{
	Class app_cls = objc_getClass("UIApplication");
	Method method = app_cls != Nil ?
	    class_getClassMethod(app_cls, sel_registerName("sharedApplication")) : NULL;
	static double looked_at;
	double now;
	id app, windows;
	unsigned count, i;

	if (!mondrian_file_on("/private/var/vm/mondrian-live") || method == NULL) {
		return;
	}
	now = (double)CFAbsoluteTimeGetCurrent();
	if (now - looked_at < 3.0) {
		return;
	}
	looked_at = now;
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	/*
	 * Take a picture, but keep only one with colour in it: the home screen's
	 * wallpaper is blue and the App Library's background is grey, so the picture
	 * that survives is always the home screen, whatever the library is doing at
	 * that moment. Nothing has to know when the library opens.
	 */
	{
		CGImageRef picture = mondrian_display_picture();

		if (picture != NULL) {
			uint8_t *sample = calloc(1, 4);
			CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
			CGContextRef ctx = sample != NULL ? CGBitmapContextCreate(sample, 1, 1, 8, 4,
			    rgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
			int colourful = 0;

			if (ctx != NULL) {
				CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), picture);
				colourful = (int)sample[2] - (int)sample[0];
				colourful = colourful < 0 ? -colourful : colourful;
				colourful = colourful > 16;
				CGContextRelease(ctx);
			}
			if (rgb != NULL) {
				CGColorSpaceRelease(rgb);
			}
			free(sample);
			if (colourful) {
				if (mondrian_live_picture != NULL) {
					CGImageRelease(mondrian_live_picture);
				}
				mondrian_live_picture = picture;
			} else {
				CGImageRelease(picture);
			}
		}
	}
	if (mondrian_live_picture == NULL) {
		return;
	}
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);

		if (name == NULL || strstr(name, "HomeScreenWindow") == NULL) {
			continue;
		}
		{
			unsigned printed = 0;

			(void)mondrian_live_walk(window, 0, &printed);
		}
	}
}

/*
 * The wallpaper picture, read as data and as CoreGraphics sees it.
 *
 * The measurement that decides the shape of the fix: if the bytes under a grey
 * label are a colour picture, the label is the bug and the fix is to give the
 * same bytes a label that says what they are. If they are a placeholder, no
 * label helps and the picture has to come from somewhere else.
 *
 * Runs twice on its own (the lock screen after a respring shows the same
 * replica), so the A/B costs a respring and not a visit to the library.
 */
static void
mondrian_picture_report(id view, unsigned depth, unsigned *printed)
{
	id layer, kids, contents;
	unsigned n, i;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 10 || *printed >= 12) {
		return;
	}
	layer = mondrian_send(view, "layer");
	contents = layer != nil ? mondrian_send(layer, "contents") : nil;
	if (contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)contents;
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
		CGImageRef fixed = mondrian_wall_relabel(image);
		char line[260];

		(*printed)++;
		snprintf(line, sizeof(line),
		    "MONDRIAN PIC: %s %.0fx%.0f -> %zux%zu %zu/%zu bits, model %d, %zu a row\n",
		    name != NULL ? name : "?", (double)frame.size.width, (double)frame.size.height,
		    CGImageGetWidth(image), CGImageGetHeight(image), CGImageGetBitsPerComponent(image),
		    CGImageGetBitsPerPixel(image), (int)CGColorSpaceGetModel(CGImageGetColorSpace(image)),
		    CGImageGetBytesPerRow(image));
		say(line);
		if (fixed != NULL) {
			say("MONDRIAN PIC:   the same bytes under an RGB label (a colour picture)\n");
			CGImageRelease(fixed);
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_picture_report([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
}

/*
 * Every picture in the wallpaper's own window and in the home screen window, on
 * demand: the file holds a number the host changes (stat() is refused here).
 */
static void
mondrian_picture_probe(void)
{
	static unsigned long asked;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	FILE *file = fopen("/private/var/vm/mondrian-picture", "r");
	unsigned long wanted = 0;
	id app, windows;
	unsigned count, i;

	if (file == NULL) {
		return;
	}
	if (fscanf(file, "%lu", &wanted) != 1) {
		(void)fclose(file);
		return;
	}
	(void)fclose(file);
	if (wanted == asked || app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	asked = wanted;
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		unsigned printed = 0;

		if (name == NULL || (strstr(name, "Wallpaper") == NULL &&
		    strstr(name, "HomeScreenWindow") == NULL)) {
			continue;
		}
		say("MONDRIAN PIC: --- window\n");
		mondrian_picture_report(window, 0, &printed);
	}
}

static unsigned
mondrian_hide_walk(id view, unsigned depth, const char *needle, BOOL hidden)
{
	id kids;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 10) {
		return 0;
	}
	if (name != NULL && strstr(name, needle) != NULL &&
	    [view respondsToSelector:sel_registerName("setHidden:")]) {
		((void (*)(id, SEL, BOOL))objc_msgSend)(view, sel_registerName("setHidden:"), hidden);
		hits++;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_hide_walk([(NSArray *)kids objectAtIndex:i], depth + 1, needle, hidden);
	}
	return hits;
}

static void
mondrian_hide_step(void)
{
	static unsigned said[2];
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;
	int wall = mondrian_file_on("/private/var/vm/mondrian-hide-wall");
	int replica = mondrian_file_on("/private/var/vm/mondrian-hide-replica");
	unsigned walls = 0, replicas = 0;

	if (app_cls == Nil || (method = class_getClassMethod(app_cls,
	    sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);

		if (name == NULL) {
			continue;
		}
		if (strstr(name, "Wallpaper") != NULL && [window respondsToSelector:sel_registerName("setHidden:")]) {
			((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setHidden:"),
			    wall ? YES : NO);
			walls++;
		}
		if (replica || (!replica && said[1] != 0)) {
			replicas += mondrian_hide_walk(window, 0, "SnapshotReplica", replica ? YES : NO);
		}
	}
	if ((wall && !said[0]) || (replica && !said[1]) || (!wall && !replica && (said[0] || said[1]))) {
		char line[192];

		said[0] = (unsigned)wall;
		said[1] = (unsigned)replica;
		snprintf(line, sizeof(line), "MONDRIAN HIDE: wallpaper %d (%u windows), replica %d (%u views)\n",
		    wall, walls, replica, replicas);
		say(line);
	}
}

/*
 * Every picture the UI draws arrives through -[CALayer setContents:], so fixing the
 * label there fixes all of its consumers at once -- the library's backdrop, the lock
 * screen, the Control Center material -- with the same bytes rather than a substitute.
 * Armed by /private/var/vm/mondrian-relabel; `0` in it puts the pictures back exactly
 * as they arrived, which is the A/B and needs no build.
 */
static void (*mondrian_set_contents)(id, SEL, id);
static volatile int mondrian_relabel_installed;

static int
mondrian_relabel_on(void)
{
	static CFAbsoluteTime looked;
	static int on;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

	if (now - looked > 1.0 || looked == 0.0) {
		looked = now;
		on = mondrian_file_on("/private/var/vm/mondrian-relabel");
	}
	return on;
}

static CGImageRef mondrian_wallpaper_image(void);

static void
mondrian_layer_set_contents(id self, SEL _cmd, id contents)
{
	CGImageRef fixed = NULL;
	int owns = 0;

	/*
	 * The launch animation shows the wallpaper's poster replica behind the
	 * zooming app, and on this port the replica is the poster's own
	 * uninitialised surface: magenta on one boot, black on the next
	 * (measured 2026-11-22, a burst capture of a Settings launch). The home
	 * wallpaper is the gradient this hook writes, so paint the replica with
	 * the same picture or every app opens through a coloured flash.
	 */
	if (mondrian_file_on("/private/var/vm/mondrian-replica-paint")) {
		id delegate = mondrian_send(self, "delegate");
		const char *owner = delegate != nil ?
		    object_getClassName(delegate) : NULL;

		if (owner != NULL && (strstr(owner, "Replica") != NULL ||
		    strstr(owner, "Poster") != NULL)) {
			fixed = mondrian_wallpaper_image();
		}
	}
	if (fixed == NULL && contents != nil &&
	    CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() &&
	    mondrian_relabel_on()) {
		fixed = mondrian_wall_relabel((CGImageRef)contents);
		owns = fixed != NULL;
	}
	if (fixed != NULL && owns) {
		static unsigned said;

		if (said < 8) {
			char line[192];

			said++;
			snprintf(line, sizeof(line),
			    "MONDRIAN RELABEL: %zux%zu, %zu a row, was a colour picture"
			    " under a grey label\n", CGImageGetWidth(fixed), CGImageGetHeight(fixed),
			    CGImageGetBytesPerRow(fixed));
			say(line);
		}
	}
	mondrian_set_contents(self, _cmd, fixed != NULL ? (id)fixed : contents);
	if (owns) {
		CGImageRelease(fixed);
	}
}

static void
mondrian_relabel_arm(void)
{
	Class layer_class = objc_getClass("CALayer");
	Method method;

	if (mondrian_relabel_installed) {
		return;
	}
	if (layer_class == Nil ||
	    (method = class_getInstanceMethod(layer_class, sel_registerName("setContents:"))) == NULL) {
		return;
	}
	mondrian_set_contents = (void (*)(id, SEL, id))method_getImplementation(method);
	(void)method_setImplementation(method, (IMP)mondrian_layer_set_contents);
	mondrian_relabel_installed = 1;
	say("MONDRIAN RELABEL: -[CALayer setContents:] hooked\n");
}

/*
 * The wallpaper, drawn.
 *
 * Measured 2026-11-17: nothing on this port fills the poster. CollectionsPoster makes
 * the surface and dies before a frame, because its renderer is Metal and this port
 * draws through Mesa's OpenGL ES; the glass then shows that surface's memory, which is
 * why the lock screen and the App Library's backdrop are garbage (black on a fresh
 * boot, fine 4-px stripes when the memory held something).
 *
 * So the still picture the poster was supposed to produce is produced here, in the
 * wallpaper's own window: every layer whose contents is a picture at least half the
 * screen wide gets one, and it is refreshed because the replica rewrites it. The App
 * Library's material samples that window, so it gets the same picture rather than a
 * substitute laid on top of the library.
 *
 * Armed by /private/var/vm/mondrian-wallpaper; `0` stops the refresh, so the A/B is a
 * write and needs no build.
 */
static CGImageRef mondrian_wallpaper;

static CGImageRef
mondrian_wallpaper_image(void)
{
	size_t const width = 720, height = 1600, row = width * 4;
	static const CGFloat places[4] = { 0.0, 0.45, 0.75, 1.0 };
	static const CGFloat stops[16] = {
		0.06, 0.09, 0.20, 1.0,          /* deep navy at the top */
		0.10, 0.24, 0.55, 1.0,          /* a blue band in the middle */
		0.16, 0.45, 0.78, 1.0,
		0.30, 0.68, 0.92, 1.0,          /* light at the bottom */
	};
	CGColorSpaceRef rgb;
	CGGradientRef gradient;
	CGContextRef ctx;
	uint8_t *pixels;

	if (mondrian_wallpaper != NULL) {
		return mondrian_wallpaper;
	}
	pixels = calloc(1, row * height);
	rgb = CGColorSpaceCreateDeviceRGB();
	ctx = pixels != NULL ? CGBitmapContextCreate(pixels, width, height, 8, row, rgb,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
	gradient = rgb != NULL ? CGGradientCreateWithColorComponents(rgb, stops, places, 4) : NULL;
	if (ctx != NULL && gradient != NULL) {
		CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, (CGFloat)height),
		    CGPointMake((CGFloat)width * 0.3, 0),
		    kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
		mondrian_wallpaper = CGBitmapContextCreateImage(ctx);
		if (mondrian_wallpaper != NULL) {
			char line[128];

			snprintf(line, sizeof(line),
			    "MONDRIAN WALLPAPER: the still picture is ready, %zux%zu\n", width, height);
			say(line);
		}
	}
	if (gradient != NULL) {
		CGGradientRelease(gradient);
	}
	if (ctx != NULL) {
		CGContextRelease(ctx);
	}
	if (rgb != NULL) {
		CGColorSpaceRelease(rgb);
	}
	free(pixels);
	return mondrian_wallpaper;
}

static unsigned
mondrian_wallpaper_paste(id view, unsigned depth, unsigned *printed)
{
	id layer, kids, contents;
	unsigned n, i, hits = 0;

	if (view == nil || depth > 12 || *printed >= 6) {
		return 0;
	}
	layer = mondrian_send(view, "layer");
	contents = layer != nil ? mondrian_send(layer, "contents") : nil;
	if (contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() &&
	    CGImageGetWidth((CGImageRef)contents) >= 640 &&
	    (id)contents != (id)mondrian_wallpaper) {
		char line[192];

		((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setContents:"),
		    (id)mondrian_wallpaper);
		(*printed)++;
		snprintf(line, sizeof(line), "MONDRIAN WALLPAPER: %s holds the picture now\n",
		    object_getClassName(view) != NULL ? object_getClassName(view) : "?");
		say(line);
		hits++;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_wallpaper_paste([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
	return hits;
}

static void
mondrian_wallpaper_step(void)
{
	static CFAbsoluteTime pasted;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;

	if (!mondrian_fix_on("/private/var/vm/mondrian-nowallpaper") || now - pasted < 2.0 ||
	    mondrian_wallpaper_image() == NULL || app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	pasted = now;
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		unsigned printed = 0;

		if (name == NULL || strstr(name, "Wallpaper") == NULL) {
			continue;
		}
		(void)mondrian_wallpaper_paste(window, 0, &printed);
	}
}

static unsigned
mondrian_replica_paint_layer(id layer, unsigned depth, unsigned *printed)
{
	id contents, kids;
	unsigned n, i, hits = 0;

	if (layer == nil || depth > 8) {
		return 0;
	}
	contents = mondrian_send(layer, "contents");
	if (contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() &&
	    CGImageGetWidth((CGImageRef)contents) >= 640 &&
	    CGImageGetHeight((CGImageRef)contents) >= 1000) {
		((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setContents:"),
		    (id)mondrian_wallpaper_image());
		if (*printed < 4) {
			(*printed)++;
			say("MONDRIAN REPLICA: the full-screen picture is the wallpaper now\n");
		}
		hits++;
	}
	kids = mondrian_send(layer, "sublayers");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_replica_paint_layer([(NSArray *)kids objectAtIndex:i],
		    depth + 1, printed);
	}
	return hits;
}

static unsigned
mondrian_replica_paint_view(id view, unsigned depth, unsigned *printed)
{
	id kids, layer;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 10) {
		return 0;
	}
	if (name != NULL && (strstr(name, "Replica") != NULL ||
	    strstr(name, "Poster") != NULL)) {
		layer = mondrian_send(view, "layer");
		if (layer != nil) {
			((void (*)(id, SEL, id))objc_msgSend)(layer,
			    sel_registerName("setContents:"),
			    (id)mondrian_wallpaper_image());
			if (*printed < 4) {
				char line[160];

				(*printed)++;
				snprintf(line, sizeof(line),
				    "MONDRIAN REPLICA: %s painted\n", name);
				say(line);
			}
			hits++;
			hits += mondrian_replica_paint_layer(layer, 0, printed);
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_replica_paint_view([(NSArray *)kids objectAtIndex:i],
		    depth + 1, printed);
	}
	return hits;
}

/*
 * The replica can already hold its picture when the hook is installed, so a
 * tick repaints it. Armed by /private/var/vm/mondrian-replica-paint.
 */
static void
mondrian_replica_paint_step(void)
{
	static unsigned said;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i, hits = 0, printed = 0;

	if (!mondrian_file_on("/private/var/vm/mondrian-replica-paint") ||
	    mondrian_wallpaper_image() == NULL || app_cls == Nil ||
	    (method = class_getClassMethod(app_cls,
	    sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		hits += mondrian_replica_paint_view([(NSArray *)windows objectAtIndex:i],
		    0, &printed);
	}
	if (hits > 0 && said++ < 6) {
		char line[128];

		snprintf(line, sizeof(line),
		    "MONDRIAN REPLICA: %u painted in %u window(s)\n", hits, count);
		say(line);
	}
}

/*
 * The lock screen's date and time live inside BSUIVibrancyEffectView, behind a
 * CAPortalLayer and a CABackdropLayer, and that group draws nothing here: the
 * views are in the tree with no contents and the glass shows the wallpaper
 * alone. The wallpaper had the same shape -- a full-screen picture that never
 * crossed -- and the answer was to paint it ourselves. This does the same with
 * two labels, added above the portal in SBFLockScreenDateView and updated when
 * the minute changes; the frames are the ones the app-side dump reported
 * (`BSUIVibrancyEffectView 32,96 416x234`, time 0,21 416x129, date 0,0 416x36).
 *
 * Armed by /private/var/vm/mondrian-lockscreen-clock.
 */
static id mondrian_clock_host;
static id mondrian_clock_time_label;
static id mondrian_clock_date_label;
static id mondrian_clock_time_text;
static id mondrian_clock_date_text;
static long mondrian_clock_minute = -1;

static id
mondrian_find_view_named(id view, const char *needle, unsigned depth)
{
	id kids;
	unsigned n, i;

	if (view == nil || depth > 14) {
		return nil;
	}
	{
		const char *name = object_getClassName(view);

		if (name != NULL && strstr(name, needle) != NULL) {
			return view;
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		id hit = mondrian_find_view_named(
		    [(NSArray *)kids objectAtIndex:i], needle, depth + 1);

		if (hit != nil) {
			return hit;
		}
	}
	return nil;
}

static id
mondrian_clock_label(CGRect frame, double size, double weight, id colour)
{
	Class label_cls = objc_getClass("UILabel");
	Class font_cls = objc_getClass("UIFont");
	id label, font;

	if (label_cls == Nil || font_cls == Nil || colour == nil) {
		return nil;
	}
	label = ((id (*)(id, SEL))objc_msgSend)((id)label_cls,
	    sel_registerName("alloc"));
	label = ((id (*)(id, SEL, CGRect))objc_msgSend)(label,
	    sel_registerName("initWithFrame:"), frame);
	if (label == nil) {
		return nil;
	}
	font = ((id (*)(id, SEL, double, double))objc_msgSend)((id)font_cls,
	    sel_registerName("systemFontOfSize:weight:"), size, weight);
	if (font != nil) {
		((void (*)(id, SEL, id))objc_msgSend)(label,
		    sel_registerName("setFont:"), font);
	}
	((void (*)(id, SEL, id))objc_msgSend)(label,
	    sel_registerName("setTextColor:"), colour);
	((void (*)(id, SEL, long))objc_msgSend)(label,
	    sel_registerName("setTextAlignment:"), 1L);
	((void (*)(id, SEL, BOOL))objc_msgSend)(label,
	    sel_registerName("setUserInteractionEnabled:"), NO);
	((void (*)(id, SEL, BOOL))objc_msgSend)(label,
	    sel_registerName("setAdjustsFontSizeToFitWidth:"), YES);
	((void (*)(id, SEL, double))objc_msgSend)(label,
	    sel_registerName("setMinimumScaleFactor:"), 0.4);
	return label;
}

static void
mondrian_lockscreen_clock_step(id app)
{
	Class app_cls = objc_getClass("UIApplication");
	Class colour_cls = objc_getClass("UIColor");
	Class fmt_cls = objc_getClass("NSDateFormatter");
	Class date_cls = objc_getClass("NSDate");
	Class locale_cls = objc_getClass("NSLocale");
	id windows, host = nil, now, locale, fmt, pattern;
	id time_text, date_text, colour, date_colour;
	CGRect bounds, time_frame, date_frame;
	double scale;
	long minute;
	unsigned count, i;

	if (app == nil || app_cls == Nil || colour_cls == Nil || fmt_cls == Nil ||
	    date_cls == Nil || locale_cls == Nil ||
	    !mondrian_file_on("/private/var/vm/mondrian-lockscreen-clock")) {
		return;
	}
	windows = mondrian_send(app, "windows");
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count && host == nil; i++) {
		host = mondrian_find_view_named([(NSArray *)windows objectAtIndex:i],
		    "SBFLockScreenDateView", 0);
	}
	if (host == nil) {
		/* A scene-based SpringBoard can answer 0 from -windows. */
		id scenes = mondrian_send(app, "connectedScenes");
		unsigned sc = scenes != nil ? (unsigned)[(NSSet *)scenes count] : 0;
		id each = sc > 0 ? [(NSSet *)scenes allObjects] : nil;

		for (i = 0; i < sc && host == nil; i++) {
			id wins = mondrian_send([(NSArray *)each objectAtIndex:i],
			    "windows");
			unsigned n = wins != nil ?
			    (unsigned)[(NSArray *)wins count] : 0;
			unsigned k;

			for (k = 0; k < n && host == nil; k++) {
				host = mondrian_find_view_named(
				    [(NSArray *)wins objectAtIndex:k],
				    "SBFLockScreenDateView", 0);
			}
		}
	}
	if (host == nil) {
		return;
	}
	/*
	 * The labels go on the window, not on the date view: the wallpaper replica
	 * (`PBUIPosterFloatingLayerReplica`, painted by this hook) is a later
	 * sibling of the date view in the lock screen window and covers a label
	 * added there (measured: the clock line printed and the glass stayed
	 * wallpaper). The window's last subview is above the replica, and the date
	 * view's coordinate space is the window's.
	 */
	{
		id window = mondrian_send(host, "window");

		if (window != nil) {
			host = window;
		}
	}
	if (host != mondrian_clock_host) {
		((void (*)(id, SEL))objc_msgSend)(mondrian_clock_time_label,
		    sel_registerName("release"));
		((void (*)(id, SEL))objc_msgSend)(mondrian_clock_date_label,
		    sel_registerName("release"));
		mondrian_clock_time_label = nil;
		mondrian_clock_date_label = nil;
		mondrian_clock_host = host;
		mondrian_clock_minute = -1;
	}
	if (mondrian_clock_time_label == nil) {
		bounds = ((CGRect (*)(id, SEL))objc_msgSend)(host,
		    sel_registerName("bounds"));
		scale = bounds.size.width > 1.0 ? bounds.size.width / 480.0 : 1.0;
		time_frame = CGRectMake(32.0 * scale, 132.0 * scale,
		    416.0 * scale, 114.0 * scale);
		date_frame = CGRectMake(32.0 * scale, 96.0 * scale,
		    416.0 * scale, 36.0 * scale);
		colour = ((id (*)(id, SEL))objc_msgSend)((id)colour_cls,
		    sel_registerName("whiteColor"));
		date_colour = ((id (*)(id, SEL, double, double))objc_msgSend)(
		    (id)colour_cls, sel_registerName("colorWithWhite:alpha:"),
		    1.0, 0.88);
		mondrian_clock_time_label = mondrian_clock_label(time_frame,
		    96.0 * scale, 0.23, colour);
		mondrian_clock_date_label = mondrian_clock_label(date_frame,
		    22.0 * scale, 0.23, date_colour != nil ? date_colour : colour);
		if (mondrian_clock_time_label != nil &&
		    mondrian_clock_date_label != nil) {
			((void (*)(id, SEL, id))objc_msgSend)(host,
			    sel_registerName("addSubview:"),
			    mondrian_clock_date_label);
			((void (*)(id, SEL, id))objc_msgSend)(host,
			    sel_registerName("addSubview:"),
			    mondrian_clock_time_label);
			say("MONDRIAN CLOCK: date and time painted in "
			    "SBFLockScreenDateView\n");
		}
	}
	if (mondrian_clock_time_label == nil ||
	    mondrian_clock_date_label == nil) {
		return;
	}
	now = ((id (*)(id, SEL))objc_msgSend)((id)date_cls,
	    sel_registerName("date"));
	minute = (long)(((double (*)(id, SEL))objc_msgSend)(now,
	    sel_registerName("timeIntervalSince1970")) / 60.0);
	if (minute == mondrian_clock_minute && mondrian_clock_time_text != nil &&
	    mondrian_clock_date_text != nil) {
		return;
	}
	locale = ((id (*)(id, SEL))objc_msgSend)((id)locale_cls,
	    sel_registerName("currentLocale"));
	fmt = ((id (*)(id, SEL))objc_msgSend)((id)fmt_cls,
	    sel_registerName("alloc"));
	fmt = ((id (*)(id, SEL))objc_msgSend)(fmt, sel_registerName("init"));
	pattern = ((id (*)(id, SEL, id, unsigned long, id))objc_msgSend)(
	    (id)fmt_cls, sel_registerName("dateFormatFromTemplate:options:locale:"),
	    @"jm", 0UL, locale);
	/* The lock clock has no AM/PM even when the locale writes one. */
	pattern = ((id (*)(id, SEL, id, id))objc_msgSend)(pattern,
	    sel_registerName("stringByReplacingOccurrencesOfString:withString:"),
	    @" a", @"");
	((void (*)(id, SEL, id))objc_msgSend)(fmt,
	    sel_registerName("setDateFormat:"), pattern);
	time_text = ((id (*)(id, SEL, id))objc_msgSend)(fmt,
	    sel_registerName("stringFromDate:"), now);
	/* iOS writes the weekday and the day, not the year ("Sunday, November 22"). */
	pattern = ((id (*)(id, SEL, id, unsigned long, id))objc_msgSend)(
	    (id)fmt_cls, sel_registerName("dateFormatFromTemplate:options:locale:"),
	    @"EEEEMMMMd", 0UL, locale);
	((void (*)(id, SEL, id))objc_msgSend)(fmt,
	    sel_registerName("setDateFormat:"), pattern);
	date_text = ((id (*)(id, SEL, id))objc_msgSend)(fmt,
	    sel_registerName("stringFromDate:"), now);
	if (time_text != nil) {
		((void (*)(id, SEL, id))objc_msgSend)(mondrian_clock_time_label,
		    sel_registerName("setText:"), time_text);
		((void (*)(id, SEL))objc_msgSend)(time_text,
		    sel_registerName("retain"));
		((void (*)(id, SEL))objc_msgSend)(mondrian_clock_time_text,
		    sel_registerName("release"));
		mondrian_clock_time_text = time_text;
	}
	if (date_text != nil) {
		((void (*)(id, SEL, id))objc_msgSend)(mondrian_clock_date_label,
		    sel_registerName("setText:"), date_text);
		((void (*)(id, SEL))objc_msgSend)(date_text,
		    sel_registerName("retain"));
		((void (*)(id, SEL))objc_msgSend)(mondrian_clock_date_text,
		    sel_registerName("release"));
		mondrian_clock_date_text = date_text;
	}
	((void (*)(id, SEL))objc_msgSend)(fmt, sel_registerName("release"));
	mondrian_clock_minute = minute;
	{
		static unsigned told;

		if (told++ < 4) {
			char line[200];
			const char *t = time_text != nil ?
			    ((const char *(*)(id, SEL))objc_msgSend)(time_text,
			    sel_registerName("UTF8String")) : "nil";
			const char *d = date_text != nil ?
			    ((const char *(*)(id, SEL))objc_msgSend)(date_text,
			    sel_registerName("UTF8String")) : "nil";

			snprintf(line, sizeof(line),
			    "MONDRIAN CLOCK: '%s' '%s' host %s\n", t, d,
			    object_getClassName(host));
			say(line);
		}
	}
}

/*
 * The App Library's own background.
 *
 * Measured 2026-11-17: the library's backdrop asks the window server for a capture of
 * the wallpaper group and gets an empty surface -- black on a fresh boot, 4-px stripes
 * when that memory held something -- even when the wallpaper window itself is right.
 * A picture laid behind the home screen does not show either: the library draws its
 * own quad above it.
 *
 * What is left is the picture the quad was supposed to show, placed inside the
 * library's own folder view, under its cards. It is the same gradient the wallpaper
 * carries, dimmed, because that is what the library's material does to it.
 *
 * Armed by /private/var/vm/mondrian-library; `0` takes the layer away again.
 */
static CGImageRef mondrian_library_picture;

static CGImageRef
mondrian_library_image(void)
{
	size_t const width = 720, height = 1600, row = width * 4;
	static const CGFloat places[4] = { 0.0, 0.45, 0.75, 1.0 };
	static const CGFloat stops[16] = {
		0.03, 0.04, 0.08, 1.0,
		0.04, 0.09, 0.20, 1.0,
		0.06, 0.16, 0.30, 1.0,
		0.10, 0.24, 0.36, 1.0,
	};
	CGColorSpaceRef rgb;
	CGGradientRef gradient;
	CGContextRef ctx;
	uint8_t *pixels;

	if (mondrian_library_picture != NULL) {
		return mondrian_library_picture;
	}
	pixels = calloc(1, row * height);
	rgb = CGColorSpaceCreateDeviceRGB();
	ctx = pixels != NULL ? CGBitmapContextCreate(pixels, width, height, 8, row, rgb,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
	gradient = rgb != NULL ? CGGradientCreateWithColorComponents(rgb, stops, places, 4) : NULL;
	if (ctx != NULL && gradient != NULL) {
		CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, (CGFloat)height),
		    CGPointMake((CGFloat)width * 0.3, 0),
		    kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
		mondrian_library_picture = CGBitmapContextCreateImage(ctx);
		if (mondrian_library_picture != NULL) {
			say("MONDRIAN LIBRARY: the background picture is ready\n");
		}
	}
	if (gradient != NULL) {
		CGGradientRelease(gradient);
	}
	if (ctx != NULL) {
		CGContextRelease(ctx);
	}
	if (rgb != NULL) {
		CGColorSpaceRelease(rgb);
	}
	free(pixels);
	return mondrian_library_picture;
}

/* Find the library's folder view and put the picture under everything it holds. */
static unsigned
mondrian_library_paint(id view, unsigned depth, const char *needle, CGImageRef picture)
{
	id kids;
	unsigned n, i, hits = 0;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 14) {
		return 0;
	}
	if (name != NULL && strstr(name, needle) != NULL) {
		CALayer *layer = (CALayer *)mondrian_send(view, "layer");
		CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("bounds"));
		NSString *key = (NSString *)@"mondrianLibraryBackground";

		if (layer != nil && bounds.size.width > 100.0 && bounds.size.height > 100.0 &&
		    [(CALayer *)layer valueForKey:key] == nil) {
			CALayer *bg = [CALayer layer];
			char line[192];

			[bg setContents:(id)picture];
			[bg setFrame:bounds];
			[bg setContentsGravity:(NSString *)@"resize"];
			[bg setMasksToBounds:YES];
			[(CALayer *)layer setValue:bg forKey:key];
			[(CALayer *)layer insertSublayer:bg atIndex:0];
			snprintf(line, sizeof(line), "MONDRIAN LIBRARY: %s has the background now\n", name);
			say(line);
			hits++;
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_library_paint([(NSArray *)kids objectAtIndex:i], depth + 1, needle,
		    picture);
	}
	return hits;
}

static void
mondrian_library_step(void)
{
	static unsigned painted;
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;
	int on = mondrian_fix_on("/private/var/vm/mondrian-nolibrary");

	if (app_cls == Nil || (method = class_getClassMethod(app_cls,
	    sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	if (!on) {
		return;
	}
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);

		if (name == NULL || strstr(name, "HomeScreenWindow") == NULL) {
			continue;
		}
		if (mondrian_library_image() != NULL) {
			painted += mondrian_library_paint(window, 0, "LibraryPodFolderView",
			    mondrian_library_image());
		}
		if (mondrian_wallpaper_image() != NULL) {
			painted += mondrian_library_paint(window, 0, "SBRootFolderView",
			    mondrian_wallpaper_image());
		}
		{
			unsigned cards = 0;

			(void)mondrian_library_cards(window, 0, &cards);
		}
		if (mondrian_fix_on("/private/var/vm/mondrian-cards")) {
			static unsigned dumped;

			if (dumped < 6) {
				(void)mondrian_card_tree(window, 0, &dumped);
			}
		}
	}
}

/*
 * What the two windows actually hold, once every few seconds: every layer with
 * contents, its class, and whether that contents is a picture, a surface or nothing.
 * This is the measurement that says what to give the wallpaper and the library.
 */
static void
mondrian_layer_report_walk(id view, unsigned depth, unsigned *printed)
{
	id layer, kids, contents;
	unsigned n, i;
	const char *name = view != nil ? object_getClassName(view) : NULL;

	if (view == nil || depth > 12 || *printed >= 10) {
		return;
	}
	layer = mondrian_send(view, "layer");
	contents = layer != nil ? mondrian_send(layer, "contents") : nil;
	if (contents != nil) {
		CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
		CFTypeID type = CFGetTypeID((CFTypeRef)contents);
		CFStringRef described = CFCopyTypeIDDescription(type);
		char kind[64] = "?";
		char extra[96] = "";

		if (described != NULL) {
			(void)CFStringGetCString(described, kind, sizeof(kind), kCFStringEncodingUTF8);
			CFRelease(described);
		}
		if (type == CGImageGetTypeID()) {
			snprintf(extra, sizeof(extra), " %zux%zu model %d",
			    CGImageGetWidth((CGImageRef)contents), CGImageGetHeight((CGImageRef)contents),
			    (int)CGColorSpaceGetModel(CGImageGetColorSpace((CGImageRef)contents)));
		}
		(*printed)++;
		{
			char line[260];

			snprintf(line, sizeof(line), "MONDRIAN LAYERS: %*s%s %.0fx%.0f contents %s%s\n",
			    (int)(depth * 2), "", name != NULL ? name : "?", (double)frame.size.width,
			    (double)frame.size.height, kind, extra);
			say(line);
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_layer_report_walk([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
}

static void
mondrian_layer_report(void)
{
	static CFAbsoluteTime said;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	Class app_cls = objc_getClass("UIApplication");
	Method method;
	id app, windows;
	unsigned count, i;

	if (!mondrian_file_on("/private/var/vm/mondrian-layers") || now - said < 6.0 ||
	    app_cls == Nil ||
	    (method = class_getClassMethod(app_cls, sel_registerName("sharedApplication"))) == NULL) {
		return;
	}
	said = now;
	app = ((id (*)(id, SEL))method_getImplementation(method))((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ? mondrian_send(app, "windows") : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];
		const char *name = object_getClassName(window);
		unsigned printed = 0;

		if (name == NULL || (strstr(name, "Wallpaper") == NULL &&
		    strstr(name, "HomeScreenWindow") == NULL)) {
			continue;
		}
		say("MONDRIAN LAYERS: --- window\n");
		mondrian_layer_report_walk(window, 0, &printed);
	}
}

/*
 * A switch of the hook's own, because the glass cannot say which of a UISwitch's
 * layers is missing: in Settings the row's track is drawn and its knob is not
 * (measured 2026-11-20, the Airplane Mode row). One built here, in SpringBoard,
 * goes through the same render server, and printing its whole layer tree says
 * whether the knob is a layer that is not composed, a picture whose contents
 * never arrive, or a colour a filter removes.
 *
 * Switch: /private/var/vm/mondrian-switch, a number the hook has not seen.
 * 1 adds the switch and dumps it, 2 sets it on, 3 sets it off, 4 dumps again;
 * every request dumps on this tick and the next, because the first one is
 * before the layout has run.
 */
static id mondrian_switch_view;
static unsigned long mondrian_switch_seen;
static unsigned mondrian_switch_pending;

/*
 * What a picture layer's CGImage actually holds, because "invisible" has two
 * meanings here: the image may be empty (nothing decoded) or full of pixels the
 * transfer drops. Four quadrant samples and a nonzero count separate them. Skips
 * anything bigger than 4 Mpixel: the probe must not allocate a full screen.
 */
static void
mondrian_image_sample(CGImageRef image, char *out, size_t len)
{
	size_t width, height, row, x, y, nonzero = 0, total = 0;
	uint8_t *pixels;
	CGColorSpaceRef rgb;
	CGContextRef ctx;

	snprintf(out, len, " sample -");
	if (image == NULL) {
		return;
	}
	width = CGImageGetWidth(image);
	height = CGImageGetHeight(image);
	if (width == 0 || height == 0 || width * height > 4 * 1024 * 1024) {
		return;
	}
	row = width * 4;
	pixels = calloc(1, row * height);
	rgb = CGColorSpaceCreateDeviceRGB();
	ctx = pixels != NULL && rgb != NULL ? CGBitmapContextCreate(pixels, width, height,
	    8, row, rgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;
	if (ctx != NULL) {
		CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
		for (y = 0; y < height; y += height / 4 > 0 ? height / 4 : 1) {
			for (x = 0; x < width; x += width / 4 > 0 ? width / 4 : 1) {
				if (*(uint32_t *)(pixels + y * row + x * 4) != 0) {
					nonzero++;
				}
				total++;
			}
		}
		snprintf(out, len, " sample %02x%02x%02x%02x nz %zu/%zu",
		    pixels[0], pixels[1], pixels[2], pixels[3], nonzero, total);
	}
	if (ctx != NULL) {
		CGContextRelease(ctx);
	}
	if (rgb != NULL) {
		CGColorSpaceRelease(rgb);
	}
	free(pixels);
}

static void
mondrian_switch_colour(id layer, char *out, size_t len){
	CGColorRef colour;
	const CGFloat *parts;
	size_t n;

	snprintf(out, len, "-");
	if (layer == nil ||
	    ![layer respondsToSelector:sel_registerName("backgroundColor")]) {
		return;
	}
	colour = (CGColorRef)((id (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("backgroundColor"));
	if (colour == NULL) {
		return;
	}
	parts = CGColorGetComponents(colour);
	n = CGColorGetNumberOfComponents(colour);
	if (parts == NULL || n == 0) {
		snprintf(out, len, "pattern");
	} else if (n >= 4) {
		snprintf(out, len, "%02x%02x%02x%02x", (unsigned)(parts[0] * 255.0 + 0.5),
		    (unsigned)(parts[1] * 255.0 + 0.5), (unsigned)(parts[2] * 255.0 + 0.5),
		    (unsigned)(parts[3] * 255.0 + 0.5));
	} else if (n == 1) {
		snprintf(out, len, "%02x", (unsigned)(parts[0] * 255.0 + 0.5));
	}
}

static void
mondrian_switch_layer(id layer, unsigned depth, unsigned *printed)
{
	char line[440], bg[16], kind[48] = "-", extra[220] = "";
	id contents, subs;
	unsigned n, i, filters = 0;
	CGRect frame = CGRectZero;
	float opacity = -1.0f, scale = -1.0f;
	BOOL hidden = NO, masks = NO;
	CGFloat corner = -1.0, border = -1.0;
	const char *name;

	if (layer == nil || depth > 6 || *printed >= 48) {
		return;
	}
	name = object_getClassName(layer);
	if ([layer respondsToSelector:sel_registerName("frame")]) {
		frame = ((CGRect (*)(id, SEL))objc_msgSend)(layer, sel_registerName("frame"));
	}
	if ([layer respondsToSelector:sel_registerName("opacity")]) {
		opacity = ((float (*)(id, SEL))objc_msgSend)(layer, sel_registerName("opacity"));
	}
	if ([layer respondsToSelector:sel_registerName("contentsScale")]) {
		scale = ((float (*)(id, SEL))objc_msgSend)(layer, sel_registerName("contentsScale"));
	}
	if ([layer respondsToSelector:sel_registerName("isHidden")]) {
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(layer, sel_registerName("isHidden"));
	}
	if ([layer respondsToSelector:sel_registerName("masksToBounds")]) {
		masks = ((BOOL (*)(id, SEL))objc_msgSend)(layer, sel_registerName("masksToBounds"));
	}
	if ([layer respondsToSelector:sel_registerName("cornerRadius")]) {
		corner = ((CGFloat (*)(id, SEL))objc_msgSend)(layer, sel_registerName("cornerRadius"));
	}
	if ([layer respondsToSelector:sel_registerName("borderWidth")]) {
		border = ((CGFloat (*)(id, SEL))objc_msgSend)(layer, sel_registerName("borderWidth"));
	}
	if ([layer respondsToSelector:sel_registerName("filters")]) {
		id list = mondrian_send(layer, "filters");
		filters = list != nil ? (unsigned)[(NSArray *)list count] : 0;
	}
	mondrian_switch_colour(layer, bg, sizeof(bg));
	contents = mondrian_send(layer, "contents");
	if (contents != nil) {
		CFTypeID type = CFGetTypeID((CFTypeRef)contents);
		CFStringRef described = CFCopyTypeIDDescription(type);

		if (described != NULL) {
			(void)CFStringGetCString(described, kind, sizeof(kind),
			    kCFStringEncodingUTF8);
			CFRelease(described);
		}
		if (type == CGImageGetTypeID()) {
			size_t row = CGImageGetBytesPerRow((CGImageRef)contents);

			snprintf(extra, sizeof(extra), " %zux%zu model %d bpc %zu bpp %zu row %zu"
			    " alpha %d",
			    CGImageGetWidth((CGImageRef)contents),
			    CGImageGetHeight((CGImageRef)contents),
			    (int)CGColorSpaceGetModel(CGImageGetColorSpace((CGImageRef)contents)),
			    CGImageGetBitsPerComponent((CGImageRef)contents),
			    CGImageGetBitsPerPixel((CGImageRef)contents), row,
			    (int)CGImageGetAlphaInfo((CGImageRef)contents));
			mondrian_image_sample((CGImageRef)contents,
			    extra + strlen(extra), sizeof(extra) - strlen(extra));
		} else if (type == IOSurfaceGetTypeID()) {
			snprintf(extra, sizeof(extra), " %zux%zu fmt %08x",
			    IOSurfaceGetWidth((IOSurfaceRef)contents),
			    IOSurfaceGetHeight((IOSurfaceRef)contents),
			    (unsigned)IOSurfaceGetPixelFormat((IOSurfaceRef)contents));
		}
	}
	(*printed)++;
	snprintf(line, sizeof(line),
	    "MONDRIAN SW: L%u %*s%s %.0f,%.0f %.0fx%.0f op %.2f hid %d mask %d bg %s"
	    " corner %.1f border %.1f scale %.2f filters %u contents %s%s\n",
	    depth, (int)(depth * 2), "", name != NULL ? name : "?", (double)frame.origin.x,
	    (double)frame.origin.y, (double)frame.size.width, (double)frame.size.height,
	    (double)opacity, (int)hidden, (int)masks, bg, (double)corner, (double)border,
	    (double)scale, filters, contents != nil ? kind : "none", extra);
	say(line);
	subs = mondrian_send(layer, "sublayers");
	n = subs != nil ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_switch_layer([(NSArray *)subs objectAtIndex:i], depth + 1, printed);
	}
}

/*
 * The knob, and the two ways the knob's picture can be lost on this port: the
 * colour space says monochrome while the data is four bytes a pixel (the transfer
 * then reads one byte a pixel), and a CGImage's pixels do not cross to the window
 * server at all. `/private/var/vm/mondrian-switch-fix` picks which repair this
 * run applies to every picture layer inside the switch: 1 a copy whose colour
 * space is really RGB, 2 a client surface holding the same pixels, 3 both.
 */
static IOSurfaceRef
mondrian_switch_surface(CGImageRef image)
{
	size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
	size_t row = (width * 4 + 15) & ~(size_t)15;
	CFMutableDictionaryRef props;
	IOSurfaceRef surface;
	CGColorSpaceRef space;
	CGContextRef context;
	uint32_t seed = 0;
	int values[5];
	const char *keys[5] = { "IOSurfaceWidth", "IOSurfaceHeight", "IOSurfaceBytesPerElement",
		"IOSurfaceBytesPerRow", "IOSurfacePixelFormat" };
	unsigned i;

	if (width < 4 || height < 4 || row * height > 32u * 1024 * 1024) {
		return NULL;
	}
	props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (props == NULL) {
		return NULL;
	}
	values[0] = (int)width;
	values[1] = (int)height;
	values[2] = 4;
	values[3] = (int)row;
	values[4] = 'BGRA';
	for (i = 0; i < 5; i++) {
		CFStringRef key = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
		CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &values[i]);

		CFDictionarySetValue(props, key, number);
		CFRelease(number);
		CFRelease(key);
	}
	surface = IOSurfaceCreate(props);
	CFRelease(props);
	if (surface == NULL) {
		return NULL;
	}
	/*
	 * A copied layer holds this surface without the box `-setContents:`
	 * leaves on the original; the readback rebuilds a CGImage for a box-less
	 * layer from the surface's own pixels (mondrian_surface_picture).
	 */
	if (IOSurfaceLock(surface, 0, &seed) != 0) {
		CFRelease(surface);
		return NULL;
	}
	space = CGColorSpaceCreateDeviceRGB();
	context = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), width, height, 8, row,
	    space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(space);
	if (context != NULL) {
		CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
		CGContextFlush(context);
		CGContextRelease(context);
	}
	IOSurfaceUnlock(surface, 0, &seed);
	return surface;
}

static unsigned
mondrian_switch_repair(id layer, unsigned depth, unsigned mode, unsigned *printed)
{
	id contents, subs;
	unsigned n, i, hits = 0;

	if (layer == nil || depth > 6) {
		return 0;
	}
	contents = mondrian_send(layer, "contents");
	if (contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)contents;
		CGImageRef copy = NULL;
		IOSurfaceRef surface = NULL;
		char line[220];

		if (mode == 1 || mode == 3) {
			CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();

			if (rgb != NULL) {
				copy = CGImageCreateCopyWithColorSpace(image, rgb);
				CGColorSpaceRelease(rgb);
			}
		}
		if (mode == 2 || mode == 3) {
			surface = mondrian_switch_surface(copy != NULL ? copy : image);
		}
		if (surface != NULL) {
			((void (*)(id, SEL, id))objc_msgSend)(layer,
			    sel_registerName("setContents:"), (id)surface);
			snprintf(line, sizeof(line), "MONDRIAN SW: repaired %s %zux%zu as surface %u\n",
			    object_getClassName(layer), CGImageGetWidth(image),
			    CGImageGetHeight(image), IOSurfaceGetID(surface));
			say(line);
			CFRelease(surface);
			(*printed)++;
			hits++;
		} else if (copy != NULL) {
			((void (*)(id, SEL, id))objc_msgSend)(layer,
			    sel_registerName("setContents:"), (id)copy);
			snprintf(line, sizeof(line), "MONDRIAN SW: repaired %s %zux%zu as RGB copy\n",
			    object_getClassName(layer), CGImageGetWidth(image),
			    CGImageGetHeight(image));
			say(line);
			CFRelease(copy);
			(*printed)++;
			hits++;
		} else if (copy != NULL) {
			CFRelease(copy);
		}
	}
	subs = mondrian_send(layer, "sublayers");
	n = subs != nil ? (unsigned)[(NSArray *)subs count] : 0;
	for (i = 0; i < n; i++) {
		hits += mondrian_switch_repair([(NSArray *)subs objectAtIndex:i], depth + 1, mode,
		    printed);
	}
	return hits;
}

static void
mondrian_switch_view_walk(id view, unsigned depth, unsigned *printed){
	CGRect frame = CGRectZero;
	BOOL hidden = NO;
	CGFloat alpha = -1.0;
	id kids;
	unsigned n, i;
	const char *name;

	if (view == nil || depth > 4 || *printed >= 24) {
		return;
	}
	name = object_getClassName(view);
	if ([view respondsToSelector:sel_registerName("frame")]) {
		frame = ((CGRect (*)(id, SEL))objc_msgSend)(view, sel_registerName("frame"));
	}
	if ([view respondsToSelector:sel_registerName("isHidden")]) {
		hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isHidden"));
	}
	if ([view respondsToSelector:sel_registerName("alpha")]) {
		alpha = ((CGFloat (*)(id, SEL))objc_msgSend)(view, sel_registerName("alpha"));
	}
	(*printed)++;
	{
		char line[200];

		snprintf(line, sizeof(line), "MONDRIAN SW: V%u %*s%s %.0f,%.0f %.0fx%.0f hid %d"
		    " alpha %.2f\n", depth, (int)(depth * 2), "", name != NULL ? name : "?",
		    (double)frame.origin.x, (double)frame.origin.y, (double)frame.size.width,
		    (double)frame.size.height, (int)hidden, (double)alpha);
		say(line);
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_switch_view_walk([(NSArray *)kids objectAtIndex:i], depth + 1, printed);
	}
}

static void
mondrian_switch_probe(id app)
{
	static unsigned dumped;
	FILE *file;
	unsigned long wanted = 0;
	id window = nil, windows;
	unsigned count, i, printed = 0;
	char line[128];

	/*
	 * Disarmed for good. Measured 2026-11-20: with /private/var/vm/mondrian-switch
	 * holding 1, every dump shows `MONDRIAN SW: V0 UISwitch` and thirty lines
	 * later `CRASH SpringBoard`, and a boot with the marker at 0 has none. The
	 * probe builds its view inside the window server's client and that view is
	 * what kills it, so a diagnostic must not be one file write away from a
	 * crash loop at the logo. The knob is drawn by the picture bridge now, and
	 * the tree below stays as the record of what the dump measured.
	 */
	(void)app;
	return;
	file = fopen("/private/var/vm/mondrian-switch", "r");
	if (file == NULL) {
		return;
	}
	if (fscanf(file, "%lu", &wanted) != 1) {
		(void)fclose(file);
		return;
	}
	(void)fclose(file);
	if (wanted == 0 || (wanted == mondrian_switch_seen && mondrian_switch_pending == 0)) {
		return;
	}
	if (wanted != mondrian_switch_seen) {
		mondrian_switch_seen = wanted;
		dumped = 0;
		mondrian_switch_pending = 2;
		if (mondrian_switch_view == nil && (wanted == 1 || wanted == 2 || wanted == 3)) {
			Class switch_cls = objc_getClass("UISwitch");

			windows = mondrian_send(app, "windows");
			count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
			window = mondrian_send(app, "keyWindow");
			for (i = 0; window == nil && i < count; i++) {
				id candidate = [(NSArray *)windows objectAtIndex:i];
				const char *name = object_getClassName(candidate);

				if (name != NULL && strstr(name, "HomeScreenWindow") != NULL) {
					window = candidate;
				}
			}
			if (switch_cls == Nil || window == nil) {
				say("MONDRIAN SW: no UISwitch or no window\n");
				return;
			}
			mondrian_switch_view = ((id (*)(id, SEL, CGRect))objc_msgSend)(
			    ((id (*)(id, SEL))objc_msgSend)((id)switch_cls,
			    sel_registerName("alloc")), sel_registerName("initWithFrame:"),
			    CGRectMake(40.0, 120.0, 51.0, 31.0));
			if (mondrian_switch_view == nil) {
				say("MONDRIAN SW: UISwitch refused\n");
				return;
			}
			((void (*)(id, SEL, id))objc_msgSend)(window,
			    sel_registerName("addSubview:"), mondrian_switch_view);
			((void (*)(id, SEL, id))objc_msgSend)(window,
			    sel_registerName("bringSubviewToFront:"), mondrian_switch_view);
			snprintf(line, sizeof(line), "MONDRIAN SW: added to %s\n",
			    object_getClassName(window) != NULL ? object_getClassName(window) : "?");
			say(line);
		} else if (mondrian_switch_view != nil && (wanted == 2 || wanted == 3)) {
			((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(mondrian_switch_view,
			    sel_registerName("setOn:animated:"), wanted == 2 ? YES : NO, NO);
		}
	}
	if (mondrian_switch_view == nil || mondrian_switch_pending == 0 || dumped >= 6) {
		return;
	}
	mondrian_switch_pending--;
	dumped++;
	snprintf(line, sizeof(line), "MONDRIAN SW: dump %u, on %d, frame %.0fx%.0f\n", dumped,
	    (int)((BOOL (*)(id, SEL))objc_msgSend)(mondrian_switch_view, sel_registerName("isOn")),
	    (double)((CGRect (*)(id, SEL))objc_msgSend)(mondrian_switch_view,
	    sel_registerName("frame")).size.width,
	    (double)((CGRect (*)(id, SEL))objc_msgSend)(mondrian_switch_view,
	    sel_registerName("frame")).size.height);
	say(line);
	mondrian_switch_view_walk(mondrian_switch_view, 0, &printed);
	mondrian_switch_layer(mondrian_send(mondrian_switch_view, "layer"), 0, &printed);
	{
		FILE *fix = fopen("/private/var/vm/mondrian-switch-fix", "r");
		unsigned mode = 0;

		if (fix != NULL) {
			if (fscanf(fix, "%u", &mode) != 1) {
				mode = 0;
			}
			(void)fclose(fix);
		}
		if (mode != 0) {
			unsigned changed = 0;

			(void)mondrian_switch_repair(mondrian_send(mondrian_switch_view, "layer"), 0,
			    mode, &changed);
			if (changed == 0) {
				say("MONDRIAN SW: nothing to repair\n");
			}
		}
	}
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
	mondrian_step_calls++;
	if (cls == Nil) {
		return;
	}
	if (mondrian_pref_logs++ == 0) {
		mondrian_report_autolock();
		mondrian_report_idle();
		if (boot_arg_int("mondrianblank=", 0) > 0) {
			pthread_t thread;

			if (pthread_create(&thread, NULL, mondrian_blank_test,
			    NULL) == 0) {
				say("MONDRIAN BLANK: test thread running\n");
			}
		}
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
		static unsigned waits;

		if ((waits++ % 15) == 0) {
			say("MONDRIAN UI: step waiting for UIApplication\n");
		}
		return;
	}
	mondrian_step_works++;
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
	{
		/*
		 * Backdrop layers are made and thrown away as views come and go,
		 * so this is not a one-off; a few seconds apart is enough.
		 */
		static unsigned backdrop_ticks;

		if (backdrop_ticks++ % 8 == 1) {
			mondrian_backdrop_fix();
		}
		if (backdrop_ticks % 8 == 1) {
			mondrian_wall_probe();
		}
		if (backdrop_ticks % 8 == 3) {
			mondrian_wallpaint();
		}
		if (backdrop_ticks % 40 == 5) {
			mondrian_tree_probe();
		}
		if (backdrop_ticks % 40 == 15) {
			mondrian_wall_snapshot();
		}
		mondrian_hide_step();
		mondrian_wallpaper_step();
		mondrian_replica_paint_step();
		mondrian_lockscreen_clock_step(app);
		mondrian_library_step();
		mondrian_layer_report();
		mondrian_relabel_arm();
		mondrian_deep_probe();
		mondrian_switch_probe(app);
		mondrian_picture_probe();
		mondrian_live_paint();
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
	 *
	 * `mondriankeepawake=0` turns the switch off so a boot can watch the
	 * blanking path itself and name the selector that hangs SpringBoard
	 * (`MONDRIAN FB: sel`, 0261) instead of guessing from a dead panel.
	 */
	if (!boot_arg_set("mondriankeepawake=0")) {
		idle_method = class_getInstanceMethod(app_cls,
		    sel_registerName("setIdleTimerDisabled:"));
		if (idle_method != NULL) {
			((void (*)(id, SEL, BOOL))method_getImplementation(idle_method))(
			    app, sel_registerName("setIdleTimerDisabled:"), YES);
		}
	} else if (mondrian_keepawake_off_logs++ == 0) {
		say("MONDRIAN UI: idle timer left armed (mondriankeepawake=0)\n");
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
		/*
		 * Undo the wallpaper experiment: its trigger file lives on the data
		 * volume and would hide the wallpaper on every boot, and the ring has
		 * no way to delete a file. Removing it here is the only way back, and
		 * a missing file is not an error.
		 */
		{
			static int cleaned;

			if (!cleaned) {
				cleaned = 1;
				(void)unlink("/private/var/vm/mondrian-hide-wallpaper");
			}
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
	if (boot_arg_set("mondriannosleep=1")) {
		mondrian_hold_display_awake();
	}
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
		static unsigned stuck;
		unsigned cycles = 0;

		for (;;) {
			/* What the watcher itself did: without it a silent death reads as
			 * "the step never ran", and every fix looks broken. */
			if ((++cycles % 15) == 0) {
				char watch[160];

				snprintf(watch, sizeof(watch),
				    "MONDRIAN UI: lock watch %u cycles, %u steps, %u with an app\n",
				    cycles, mondrian_step_calls, mondrian_step_works);
				say(watch);
			}
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
	/*
	 * An argument that is in the payload's command line but not in this
	 * string is invisible to every hook in the boot, and the two look
	 * identical from the ring: the hook simply behaves as if it was never
	 * passed. Say the length and the tail once, so the next boot answers
	 * whether the kernel sees the whole line.
	 */
	{
		static int said;
		static const char *wanted[] = { "mondrianunlock=1",
		    "mondriannosleep=1", "mondrianwallpaper=1" };
		unsigned i;

		if (!said) {
			char line[256];
			size_t len = strlen(args);
			const char *tail = len > 100 ? args + len - 100 : args;

			said = 1;
			snprintf(line, sizeof(line),
			    "MONDRIAN BOOT: args %u bytes tail '%s'\n",
			    (unsigned)len, tail);
			say(line);
			/* The whole string, so the head is visible too: an argument
			 * missing from the middle says the shim rebuilt the line and
			 * dropped it, not that it was cut off the end. */
			{
				size_t off;

				for (off = 0; off < len && off < 640; off += 120) {
					snprintf(line, sizeof(line),
					    "MONDRIAN BOOT: [%03u] %.120s\n",
					    (unsigned)off, args + off);
					say(line);
				}
			}
			for (i = 0; i < sizeof(wanted) / sizeof(wanted[0]); i++) {
				snprintf(line, sizeof(line),
				    "MONDRIAN BOOT: %s %s\n", wanted[i],
				    strstr(args, wanted[i]) != NULL ? "present" : "absent");
				say(line);
			}
		}
	}
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
	CGFloat pad, grid = 0.0;
	id kids;
	unsigned n, i;
	static int told;

	b = ((CGRect (*)(id, SEL))objc_msgSend)(scroll, sel_registerName("bounds"));
	content = ((CGSize (*)(id, SEL))objc_msgSend)(scroll,
	    sel_registerName("contentSize"));
	/*
	 * The 430 pt grid is a child of the full-width scroll view, so
	 * contentSize says 480 and the old test was a no-op. Take the widest
	 * direct child narrower than the scroll view instead.
	 */
	kids = mondrian_send(scroll, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(
		    [(NSArray *)kids objectAtIndex:i], sel_registerName("frame"));

		if (f.size.width > grid && f.size.width < b.size.width - 0.5) {
			grid = f.size.width;
		}
	}
	if (grid < 1.0) {
		grid = content.width;
	}
	if (b.size.width < 1.0 || grid < 1.0 || grid + 1.0 >= b.size.width) {
		return;
	}
	pad = (b.size.width - grid) / 2.0;
	inset = ((mondrian_insets (*)(id, SEL))objc_msgSend)(scroll,
	    sel_registerName("contentInset"));
	if (inset.left == pad && inset.right == pad) {
		return;
	}
	inset.left = pad;
	inset.right = pad;
	((void (*)(id, SEL, mondrian_insets))objc_msgSend)(scroll,
	    sel_registerName("setContentInset:"), inset);
	if (!told) {
		char line[192];

		told = 1;
		snprintf(line, sizeof(line),
		    "MONDRIAN UI: cc centre grid %.0f content %.0f bounds %.0f inset %.0f\n",
		    grid, content.width, b.size.width, pad);
		say(line);
	}
}

/*
 * The scroll view is not a direct child of the Control Center window (measured
 * at depth 3), so the window's child loop never reached it and the grid stayed
 * at 430 pt against the left edge. Walk to it; the loop's scroll settings stay
 * where they are, this only centres the content.
 */
static void
mondrian_cc_find_scroll(id view, unsigned depth)
{
	const char *name = object_getClassName(view);
	id kids;
	unsigned n, i;

	if (view == nil || depth > 12) {
		return;
	}
	if (name != NULL && strstr(name, "CCUIScrollView") != NULL) {
		mondrian_cc_centre(view);
		return;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_cc_find_scroll([(NSArray *)kids objectAtIndex:i], depth + 1);
	}
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
 * The volume and "Not Playing" modules promise things this port cannot do: the
 * volume card talks to a media stack that does not exist and the media card has
 * nothing to play. Their content views are the only stable handles: measured
 * `MRUVolumeView` for the volume capsule and the label text "Not Playing" for
 * the media card (its class is below the old dump cap). Both are dimmed on
 * their nearest `CCUIContentModuleContainerView`, which is what the sheet
 * actually draws; the alpha is re-checked every pass, so a view iOS resets is
 * dimmed again, and the sheet builds new views on every open.
 */
static void
mondrian_cc_dim_media(id view, unsigned depth)
{
	const char *name = object_getClassName(view);
	id kids, c;
	unsigned n, i;
	BOOL want = NO, found = NO;
	const char *why = NULL;

	if (view == nil || depth > 24) {
		return;
	}
	if (name != NULL && strstr(name, "MRUVolumeView") != NULL) {
		want = YES;
		why = "volume";
	}
	if ([view respondsToSelector:sel_registerName("text")]) {
		id t = mondrian_send(view, "text");
		const char *u = t != nil &&
		    [t respondsToSelector:sel_registerName("UTF8String")] ?
		    [t UTF8String] : NULL;

		if (u != NULL && strcmp(u, "Not Playing") == 0) {
			want = YES;
			why = "not-playing";
		}
	}
	for (i = 0, c = view; want && c != nil && i < 16; i++) {
		const char *cn = object_getClassName(c);

		if (cn != NULL &&
		    strstr(cn, "CCUIContentModuleContainerView") != NULL) {
			found = YES;
			break;
		}
		c = mondrian_send(c, "superview");
	}
	if (want && found && c != nil) {
		BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(c,
		    sel_registerName("isHidden"));
		double alpha = ((double (*)(id, SEL))objc_msgSend)(c,
		    sel_registerName("alpha"));

		if (!hidden && alpha > 0.36) {
			char line[160];

			((void (*)(id, SEL, double))objc_msgSend)(c,
			    sel_registerName("setAlpha:"), 0.35);
			((void (*)(id, SEL, BOOL))objc_msgSend)(c,
			    sel_registerName("setUserInteractionEnabled:"), NO);
			snprintf(line, sizeof(line),
			    "MONDRIAN UI: cc dim %s %s a %.2f\n", why,
			    object_getClassName(c), alpha);
			say(line);
		}
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_cc_dim_media([(NSArray *)kids objectAtIndex:i], depth + 1);
	}
}

/*
 * One dump of the whole sheet, once per boot, on the frame that first sees it:
 * the banding question is whether the sheet's material covers the screen or
 * stops short, and that is a frame, not a colour. Depth 24 with 400 lines names
 * the media card's classes, which the old depth-12 / 70-line cap cut off; the
 * cap still bounds the walk.
 */
static unsigned mondrian_cc_dump_lines;

static void
mondrian_cc_dump(id view, unsigned depth)
{
	const char *name = object_getClassName(view);
	id kids;
	unsigned n, i;

	if (view == nil || depth > 24 || mondrian_cc_dump_lines > 400) {
		return;
	}
	{
		BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("isHidden"));
		double alpha = ((double (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("alpha"));
		CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(view,
		    sel_registerName("frame"));
		id layer = mondrian_send(view, "layer");
		const char *lname = layer != nil ? object_getClassName(layer) : "-";
		const char *group = "-";
		char line[256];

		/*
		 * The module platters that draw garbage capture a named group
		 * instead of the screen behind them: the group is the handle the
		 * repair below needs, so the dump names it.
		 */
		if (layer != nil &&
		    [layer respondsToSelector:sel_registerName("groupName")]) {
			id g = mondrian_send(layer, "groupName");

			if (g != nil && [g isKindOfClass:objc_getClass("NSString")]) {
				group = [(NSString *)g UTF8String];
				if (group == NULL) {
					group = "-";
				}
			}
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN CC %u %s %.0f,%.0f %.0fx%.0f h%d a%.2f layer %s group %s\n",
		    depth, name != NULL ? name : "?", f.origin.x, f.origin.y,
		    f.size.width, f.size.height, hidden ? 1 : 0, alpha, lname, group);
		say(line);
		mondrian_cc_dump_lines++;
	}
	kids = mondrian_send(view, "subviews");
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		mondrian_cc_dump([(NSArray *)kids objectAtIndex:i], depth + 1);
	}
}

/*
 * The sheet's module platters share one backdrop capture, named
 * `ControlCenterModuleBackground.modules` (from the dump above; the sheet's own
 * background is `...modulesBackground` and it draws its blur correctly). Over
 * the Bluetooth pane that shared capture comes out as a sheared, magnified
 * fragment of the pane -- the cyan block the panel shows -- while the media
 * column beside it stays clean (measured 2026-11-21; the sheet opens clean over
 * the home screen and Settings' root, so the capture is there and its content
 * is what goes wrong). Clearing the name is not the fix: the live clear cleans
 * most of the sheet, a reopened one is corrupted again, and MaterialKit never
 * calls `setGroupName:` after the fact. See docs/UI_PERFORMANCE.md for the
 * capture trace; the next lever is the capture texture, not the group.
 */
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

			mondrian_cc_find_scroll(win, 0);
			mondrian_cc_dim_media(win, 0);
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
	 * SpringBoard draws the status bar and the lock screen itself, and it is
	 * the one injected image that receives the hook *instead of* the app
	 * bridge: 0402's branch only runs for a process the mask does not already
	 * claim, and SpringBoard is bit 4. Every CGImage SpringBoard sets -- the
	 * battery outline, the lock screen's legibility pictures -- therefore
	 * takes the broken CGImage road while the same picture inside an app
	 * draws. Load the bridge here as well; its constructor defers until
	 * CALayer is up, and QTMovie/CA are up before any status bar exists.
	 */
	if (strcmp(getprogname(), "SpringBoard") == 0 &&
	    access("/private/var/vm/mondrian-layer-bridge.dylib", R_OK) == 0) {
		void *bridge = dlopen("/private/var/vm/mondrian-layer-bridge.dylib",
		    RTLD_NOW);

		say(bridge != NULL ?
		    "MONDRIAN UI: picture bridge in SpringBoard\n" :
		    "MONDRIAN UI: picture bridge dlopen failed\n");
	}
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

/*
 * The same dump, asked for from the host. The fixed sample times are a guess
 * about when a wait forms, and a daemon whose first frame never arrives has no
 * moment to guess: /private/var/vm/mondrian-thrprobe is written by the host and
 * every new write is one dump. Used in the processes the fixed watch does not
 * cover, `iconservicesagent` first (measured 2026-11-21: lsd waits on it
 * forever while SpringBoard's main thread waits on lsd).
 */
static void *
mondrian_threads_demand(void *unused)
{
	struct stat st;
	struct timespec seen = { 0, 0 };

	(void)unused;
	for (;;) {
		if (stat("/private/var/vm/mondrian-thrprobe", &st) == 0 &&
		    (st.st_mtimespec.tv_sec != seen.tv_sec ||
		    st.st_mtimespec.tv_nsec != seen.tv_nsec)) {
			seen = st.st_mtimespec;
			mondrian_dump_threads("demand");
		}
		sleep(1);
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
mondrian_cm_thread(void *unused)
{
	static const char *const cmds[][5] = {
		{ "launchctl", "print", "system/com.apple.containermanagerd", NULL },
		{ "launchctl", "kickstart", "-k", "system/com.apple.containermanagerd", NULL },
		{ "launchctl", "list", NULL },
	};
	extern char **environ;
	size_t i;

	(void)unused;
	sleep(6);
	/*
	 * Ask launchd itself, rather than spawning the binary: a manually spawned
	 * containermanagerd cannot own the Mach name launchd hands to its clients,
	 * so it would answer nothing. `print` says what state the job is in,
	 * `kickstart` asks launchd to run it in its own context, and `list` shows
	 * whether it appears at all.
	 */
	for (i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
		posix_spawn_file_actions_t actions;
		char *argv[5];
		int out, rc, status = 0;
		pid_t pid = 0;
		size_t k = 0;

		while (cmds[i][k] != NULL && k < 4) {
			argv[k] = (char *)cmds[i][k];
			k++;
		}
		argv[k] = NULL;
		out = open("/dev/console", O_WRONLY | O_NOCTTY);
		if (out < 0) {
			continue;
		}
		if (posix_spawn_file_actions_init(&actions) != 0) {
			close(out);
			continue;
		}
		(void)posix_spawn_file_actions_adddup2(&actions, out, STDOUT_FILENO);
		(void)posix_spawn_file_actions_adddup2(&actions, out, STDERR_FILENO);
		mondrian_probe_fmt("MONDRIAN CM: %s %s start\n", argv[1],
		    argv[2] != NULL ? argv[2] : "");
		rc = posix_spawn(&pid, "/bin/launchctl", &actions, NULL, argv, environ);
		posix_spawn_file_actions_destroy(&actions);
		close(out);
		if (rc == 0) {
			(void)waitpid(pid, &status, 0);
		}
		mondrian_probe_fmt("MONDRIAN CM: %s done rc %d status 0x%x\n",
		    argv[1], rc, status);
	}
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
 *
 * Do not leave this on for a boot whose UI matters. Measured 2026-11-21:
 * this thread's workspace call created SBLockScreenManager before UIApplication
 * existed, SpringBoard raised "Unexpectedly created SBLockScreenManager before
 * UIApplication instance was created", aborted (sig 6) and was relaunched --
 * twice in one boot, with the abort stack ending in mondrian_launch_thread.
 * The process table it prints is worth a dedicated boot, never a mixed one.
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

/*
 * Why a service dies, in its own words. A process that aborts through
 * libc++abi has thrown its message away by the time the kernel records `sig 6`:
 * measured on assetsd, fileproviderd and the three speech plug-in hosts, the
 * chain is `__pthread_kill <- pthread_kill <- abort <- libc++abi`, which says
 * "an exception reached the terminate handler" and nothing about which one.
 * objc's own terminate path calls the uncaught exception handler before it
 * aborts, so installing that handler is what names the exception; the C++
 * handler is the fallback for a throw that never went through objc.
 *
 * These processes only get this file for that reason, so the constructor
 * returns right after arming it: no UI hooks, no threads, nothing that changes
 * what the service was doing when it died.
 */
static int
mondrian_probe_service(void)
{
	const char *prog = getprogname();

	if (prog == NULL) {
		return 0;
	}
	/*
	 * PhotosFileProvider is the appex, not the daemon: when Photos opens it is
	 * this process that dies sig 6, and a list that names only fileproviderd
	 * leaves the one that matters uninstrumented.
	 */
	return strcmp(prog, "assetsd") == 0 ||
	    strcmp(prog, "fileproviderd") == 0 ||
	    strcmp(prog, "PhotosFileProvider") == 0 ||
	    strcmp(prog, "photolibraryd") == 0 ||
	    strcmp(prog, "MobileSlideShow") == 0 ||
	    strcmp(prog, "ReportCrash") == 0 ||
	    strcmp(prog, "iconservicesagent") == 0;
}

/* Probe output goes to the console only: stderr becomes the pipe being read. */
static void
mondrian_exc_say(const char *message)
{
	if (console_fd >= 0) {
		(void)write(console_fd, message, __builtin_strlen(message));
	}
}

/*
 * Which entitlements the kernel thinks this process has.
 *
 * assetsd raises "requires TCCPhotosService access", and its own code signature
 * carries that entitlement: read from the image, slot 5 of the SuperBlob is a
 * 5635-byte XML blob with com.apple.private.tcc.allow = kTCCServicePhotos. The
 * port's AMFI stand-in (xnu 0030) answers entitlement queries from exactly that
 * XML, but it attaches it only when `cs_blob != csb_ro_addr`, so the question
 * "did this process get them" is a measurement, not a reading. csops returns
 * the blob the kernel holds for the caller: zero or -1 means the stand-in never
 * attached it, and the fix belongs in the kernel, not in a hook.
 * Switch: /private/var/vm/mondrian-images (shared with the image dump).
 */
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define MONDRIAN_CS_OPS_ENTITLEMENTS_BLOB 7

static void
mondrian_ent_probe(void)
{
	char buf[8192];
	const char *blob = buf;
	uint32_t magic, length;
	int n;

	/*
	 * csops returns 0 on success; the length is in the blob it copies out,
	 * a CS_GenericBlob with a big-endian length. Reading the return value as
	 * a size made "has 62 entitlements" look like "has none" for a whole
	 * session.
	 */
	n = csops(getpid(), MONDRIAN_CS_OPS_ENTITLEMENTS_BLOB, buf, sizeof(buf));
	if (n != 0) {
		mondrian_probe_fmt("MONDRIAN ENT[%d]: csops -> %d errno %d\n",
		    getpid(), n, errno);
		return;
	}
	memcpy(&magic, buf, sizeof(magic));
	memcpy(&length, buf + 4, sizeof(length));
	magic = ntohl(magic);
	length = ntohl(length);
	mondrian_probe_fmt(
	    "MONDRIAN ENT[%d]: %u bytes magic 0x%x tcc.allow %s photos %s\n",
	    getpid(), length, magic,
	    strstr(blob + 8, "com.apple.private.tcc.allow") != NULL ? "yes" : "no",
	    strstr(blob + 8, "kTCCServicePhotos") != NULL ? "yes" : "no");
}

/*
 * Whether the TCC daemon can even be reached from this process. assetsd's
 * "requires TCCPhotosService access" is raised by a library-services operation
 * named ActivateTCC, its own entitlement blob is present and complete, and it
 * never calls TCCAccessPreflight or TCCAccessCheckAuditToken: the remaining path
 * is an XPC query to tccd, which on this port is a daemon nobody has watched
 * start. A failed bootstrap look-up says that in one line.
 */
static void
mondrian_tccd_probe(void)
{
	mach_port_t bootstrap = MACH_PORT_NULL;
	mach_port_t port = MACH_PORT_NULL;
	kern_return_t (*look_up)(mach_port_t, const char *, mach_port_t *);
	kern_return_t kr;

	kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT,
	    &bootstrap);
	look_up = (kern_return_t (*)(mach_port_t, const char *, mach_port_t *))
	    dlsym(RTLD_DEFAULT, "bootstrap_look_up");
	if (kr != KERN_SUCCESS || look_up == NULL) {
		mondrian_probe_fmt("MONDRIAN TCCD[%d]: no bootstrap 0x%x %p\n",
		    getpid(), kr, (void *)look_up);
		return;
	}
	kr = look_up(bootstrap, "com.apple.tccd", &port);
	mondrian_probe_fmt("MONDRIAN TCCD[%d]: tccd -> 0x%x port %u\n", getpid(),
	    kr, port);
	if (port != MACH_PORT_NULL) {
		mach_port_deallocate(mach_task_self(), port);
	}
}

/*
 * The exception at the moment it is thrown, where the stack still exists.
 *
 * The uncaught handler is the wrong place to read it: measured on assetsd
 * 2026-11-18, the handler runs with 0x100 bytes of stack left above the guard
 * page, `-reason` faults, and the report collapses to `reason ns 2 code 0xb:
 * (none)` -- it can say an NSException existed and nothing about what it was.
 * objc_exception_throw runs on the thrower's own stack, before any unwinding,
 * so `name` and `reason` are ordinary messages there.
 *
 * Interposing this symbol reaches every throw in every process that loads this
 * file, so the report is gated on /private/var/vm/mondrian-throw and on the
 * service list above; the first eight throws are enough to name a crash loop.
 * The re-entry flag matters because a reason that itself throws would recurse.
 */
extern void objc_exception_throw(id exception);

static int mondrian_exc_read(const void *from, void *to, size_t len);

static void (*mondrian_throw_original)(id);
static _Thread_local int mondrian_throw_busy;
static int mondrian_throw_armed = -1;
static unsigned mondrian_throw_told;

/*
 * Who threw it. The reason names a condition, not a caller, and the code that
 * builds it is not always in the binary that carries the string: assetsd holds
 * "requires TCCPhotosService access" but never loads that literal, so the raise
 * happens one framework up. Frame pointers are intact at throw time -- the
 * unwinding has not started -- so the walk is ordinary memory reads, and dladdr
 * names the image each return address belongs to.
 */
static void
mondrian_throw_trace(void)
{
	uint64_t *fp = (uint64_t *)__builtin_frame_address(0);
	char line[300];

	for (int i = 0; i < 8; i++) {
		uint64_t frame[2];
		Dl_info info;
		const char *base;

		if (fp == NULL ||
		    !mondrian_exc_read(fp, frame, sizeof(frame)) ||
		    frame[1] == 0) {
			return;
		}
		if (dladdr((void *)(uintptr_t)frame[1], &info) == 0 ||
		    info.dli_fname == NULL) {
			fp = (uint64_t *)(uintptr_t)frame[0];
			continue;
		}
		base = strrchr(info.dli_fname, '/');
		snprintf(line, sizeof(line), "MONDRIAN THROW[%d]:   #%d %s+0x%lx\n",
		    getpid(), i,
		    base != NULL ? base + 1 : info.dli_fname,
		    (unsigned long)(frame[1] - (uint64_t)(uintptr_t)info.dli_fbase));
		mondrian_exc_say(line);
		fp = (uint64_t *)(uintptr_t)frame[0];
	}
}

static void
mondrian_throw(id exception)
{
	if (mondrian_throw_armed < 0) {
		mondrian_throw_armed =
		    mondrian_file_on("/private/var/vm/mondrian-throw") &&
		    mondrian_probe_service();
	}
	if (mondrian_throw_armed && !mondrian_throw_busy && exception != nil &&
	    mondrian_throw_told < 8) {
		char line[360];
		const char *reason = "(nil)";
		const char *name = "(nil)";
		id n = nil;
		id r = nil;

		mondrian_throw_busy = 1;
		mondrian_throw_told++;
		if ([exception respondsToSelector:@selector(name)]) {
			n = [exception name];
		}
		if ([exception respondsToSelector:@selector(reason)]) {
			r = [exception reason];
		}
		if (n != nil && [n isKindOfClass:[NSString class]]) {
			name = [n UTF8String];
		}
		if (r != nil && [r isKindOfClass:[NSString class]]) {
			reason = [r UTF8String];
		}
		snprintf(line, sizeof(line), "MONDRIAN THROW[%d]: %s name %s reason %s\n",
		    getpid(), object_getClassName(exception), name, reason);
		mondrian_exc_say(line);
		mondrian_throw_trace();
		mondrian_throw_busy = 0;
	}
	if (mondrian_throw_original != NULL) {
		mondrian_throw_original(exception);
	}
}


static void
mondrian_exc_report(id exception)
{
	NSString *n = nil, *r = nil;

	/*
	 * Print before touching the exception. Measured 2026-11-18: a handler that
	 * asked -name/-reason first died in the stack guard page (`sig 11`,
	 * `far = sp + 0x100`, `prot 0/7`) and left no line at all, so this object
	 * cannot be assumed readable and the plain line is the evidence that the
	 * handler ran at all.
	 */
	say("MONDRIAN EXC: uncaught exception reached the handler\n");
	@try {
		if (exception != nil &&
		    [exception respondsToSelector:@selector(name)] &&
		    [exception respondsToSelector:@selector(reason)]) {
			n = [exception name];
			r = [exception reason];
		}
		if (n != nil && [n isKindOfClass:[NSString class]]) {
			mondrian_probe_fmt("MONDRIAN EXC[%d]: name %s\n", getpid(),
			    [n UTF8String]);
		}
		if (r != nil && [r isKindOfClass:[NSString class]]) {
			mondrian_probe_fmt("MONDRIAN EXC[%d]: reason %s\n", getpid(),
			    [r UTF8String]);
		}
	} @catch (id other) {
		say("MONDRIAN EXC: the handler could not read the exception\n");
	}
}

/* libc++abi: the thrown object sits right after its 0x70-byte exception header. */
#define MONDRIAN_CXA_OBJECT_OFF 0x70

extern void *__cxa_get_globals(void);

static int
mondrian_exc_read(const void *from, void *to, size_t len)
{
	mach_vm_size_t got = 0;

	return mach_vm_read_overwrite(mach_task_self(), (vm_address_t)from,
	    len, (vm_address_t)to, &got) == KERN_SUCCESS && got == len;
}

/*
 * The loaded images, as a crash address needs them. The kernel prints pc, lr and
 * a frame-pointer walk, but `pc - mh` only resolves while pc is inside the main
 * executable: measured on assetsd, pc sits 0xD025C past a header whose image is
 * only 0x44570 bytes, so the frame belongs to a dylib and the offset names
 * nothing. With each image's runtime __TEXT range on record, the CRASH line can
 * be resolved offline -- no dyld call in the faulting thread, which is what a
 * handler that resolved addresses in place would have to do with the stack
 * already gone.
 *
 * Two traps cost a round each here. `_dyld_get_image_header` already returns the
 * runtime address: adding `_dyld_get_image_vmaddr_slide` on top printed every
 * base one slide too high and read __TEXT from an unmapped address, 484 entries
 * of zeros that made the crash look like it belonged to no image at all. And the
 * union of every segment is not the image: shared-cache dylibs keep a segment at
 * vmaddr 0, whose `vmaddr + slide` becomes a base in the middle of nowhere and
 * an image "size" of 0x4372d000. __TEXT alone is what a pc needs.
 *
 * Print the whole table at exec, once: assetsd restarts every few seconds, so
 * the last table before a CRASH line is the one that belongs to it.
 */
static void
mondrian_exc_images(void)
{
	uint32_t count = _dyld_image_count();
	char line[260];

	mondrian_probe_fmt("MONDRIAN EXC[%d]: images %u\n", getpid(), count);
	for (uint32_t i = 0; i < count; i++) {
		const struct mach_header_64 *mh =
		    (const struct mach_header_64 *)_dyld_get_image_header(i);
		const char *name = _dyld_get_image_name(i);
		uint64_t size = 0;
		struct mach_header_64 header;
		char *cmds;

		if (mh == NULL || name == NULL ||
		    !mondrian_exc_read(mh, &header, sizeof(header)) ||
		    header.magic != MH_MAGIC_64) {
			continue;
		}
		cmds = malloc(header.sizeofcmds);
		if (cmds == NULL ||
		    !mondrian_exc_read((const char *)mh + sizeof(header), cmds,
		    header.sizeofcmds)) {
			free(cmds);
			continue;
		}
		for (uint32_t c = 0, at = 0; c < header.ncmds; c++) {
			struct load_command *cmd = (struct load_command *)(cmds + at);
			struct segment_command_64 *seg;

			if (at + sizeof(*cmd) > header.sizeofcmds ||
			    cmd->cmdsize == 0) {
				break;
			}
			if (cmd->cmd == LC_SEGMENT_64 &&
			    at + sizeof(*seg) <= header.sizeofcmds) {
				seg = (struct segment_command_64 *)cmd;
				if (strncmp(seg->segname, "__TEXT", 16) == 0 &&
				    seg->vmsize != 0) {
					size = seg->vmsize;
					break;
				}
			}
			at += cmd->cmdsize;
		}
		free(cmds);
		if (size == 0) {
			continue;
		}
		snprintf(line, sizeof(line),
		    "MONDRIAN EXC[%d]: img 0x%llx 0x%llx %s\n", getpid(),
		    (unsigned long long)(uintptr_t)mh, (unsigned long long)size,
		    name);
		mondrian_exc_say(line);
	}
}


/*
 * The exception itself. objc throws through the C++ ABI, so the object is in
 * libc++abi's globals; the isa is checked with dladdr before anything is
 * messaged, because a wrong offset would fault inside the handler and lose the
 * line that says why.
 */
static id
mondrian_exc_object(void)
{
	void *(*get_globals)(void) = (void *(*)(void))dlsym(RTLD_DEFAULT,
	    "__cxa_get_globals");
	void *caught = NULL;
	uintptr_t isa = 0;
	Dl_info info;

	if (get_globals == NULL) {
		return nil;
	}
	if (!mondrian_exc_read(get_globals(), &caught, sizeof(caught)) || caught == NULL) {
		return nil;
	}
	if (!mondrian_exc_read((char *)caught + MONDRIAN_CXA_OBJECT_OFF, &isa,
	    sizeof(isa)) || isa == 0) {
		return nil;
	}
	if (dladdr((void *)isa, &info) == 0) {
		return nil;
	}
	return (id)((char *)caught + MONDRIAN_CXA_OBJECT_OFF);
}

static void
mondrian_exc_terminate(void)
{
	/* libc++abi's std::type_info is { vptr, const char *__type_name }. */
	void *(*current_type)(void) = (void *(*)(void))dlsym(RTLD_DEFAULT,
	    "__cxa_current_exception_type");
	const char *name = "none";
	void *info = NULL;
	id exception;

	say("MONDRIAN EXC: terminate reached the handler\n");
	if (current_type != NULL) {
		info = current_type();
	}
	if (info != NULL) {
		const char *at = *(const char **)((char *)info + sizeof(void *));

		if (at != NULL && (uintptr_t)at > 0x10000) {
			name = at;
		}
	}
	mondrian_probe_fmt("MONDRIAN EXC[%d]: terminate %s\n", getpid(), name);
	exception = mondrian_exc_object();
	if (exception != nil) {
		@try {
			if ([exception respondsToSelector:@selector(name)] &&
			    [exception respondsToSelector:@selector(reason)]) {
				NSString *n = [exception name];
				NSString *r = [exception reason];

				mondrian_probe_fmt("MONDRIAN EXC[%d]: name %s\n",
				    getpid(), [n UTF8String]);
				mondrian_probe_fmt("MONDRIAN EXC[%d]: reason %s\n",
				    getpid(), [r UTF8String]);
			}
		} @catch (id other) {
			say("MONDRIAN EXC: messaging the exception threw\n");
		}
	} else {
		say("MONDRIAN EXC: no exception object in the globals\n");
	}
	abort();
}

/*
 * A fault is a signal, and by the time the crash reporter reads it the stack is
 * gone: the handler is the only place that still holds pc, lr and the faulting
 * address. This names the image each address lands in by walking the dyld image
 * list and the segment table -- memory reads only, no locks -- so the line is
 * usable without the images table that a repeated exec would flood.
 */
static void
mondrian_fault_image(uint64_t addr, char *out, size_t size)
{
	uint32_t count = _dyld_image_count();
	uint32_t i;

	for (i = 0; i < count; i++) {
		const struct mach_header_64 *hdr =
		    (const struct mach_header_64 *)_dyld_get_image_header(i);
		intptr_t slide = _dyld_get_image_vmaddr_slide(i);
		const char *path = _dyld_get_image_name(i);
		const struct load_command *cmd;
		uint64_t low = 0, high = 0;
		const char *base;

		if (hdr == NULL || hdr->magic != MH_MAGIC_64) {
			continue;
		}
		cmd = (const struct load_command *)((const char *)hdr + sizeof(*hdr));
		for (uint32_t k = 0; k < hdr->ncmds; k++) {
			if (cmd->cmd == LC_SEGMENT_64) {
				const struct segment_command_64 *seg =
				    (const struct segment_command_64 *)cmd;

				if (seg->vmsize != 0) {
					uint64_t start = seg->vmaddr + (uint64_t)slide;
					uint64_t end = start + seg->vmsize;

					if (low == 0 || start < low) {
						low = start;
					}
					if (end > high) {
						high = end;
					}
				}
			}
			if (cmd->cmdsize == 0) {
				break;
			}
			cmd = (const struct load_command *)((const char *)cmd +
			    cmd->cmdsize);
		}
		if (low != 0 && addr >= low && addr < high) {
			base = path != NULL ? strrchr(path, '/') : NULL;
			base = base != NULL ? base + 1 : path;

			snprintf(out, size, "%s+0x%llx",
			    base != NULL ? base : "?",
			    (unsigned long long)(addr - low));
			return;
		}
	}
	snprintf(out, size, "?+0x%llx", (unsigned long long)addr);
}

static void
mondrian_fault(int sig, siginfo_t *info, void *context)
{
	static int told;
	ucontext_t *uc = (ucontext_t *)context;
	char where[220];
	char line[420];

	if (told++ < 2 && uc != NULL) {
		uint64_t pc = (uint64_t)uc->uc_mcontext->__ss.__pc;
		uint64_t x0 = (uint64_t)uc->uc_mcontext->__ss.__x[0];
		uint64_t x1 = (uint64_t)uc->uc_mcontext->__ss.__x[1];

		mondrian_fault_image(pc, where, sizeof(where));
		snprintf(line, sizeof(line),
		    "MONDRIAN FAULT[%d]: sig %d code %d pc %s far 0x%llx x0 0x%llx x1 0x%llx\n",
		    getpid(), sig, info != NULL ? info->si_code : -1, where,
		    (unsigned long long)(info != NULL ?
		    (uintptr_t)info->si_addr : 0),
		    (unsigned long long)x0, (unsigned long long)x1);
		mondrian_exc_say(line);
		/*
		 * A C++ member function takes `this` in x0 and its argument in x1;
		 * for the paths that is the pair being split. Printed only where the
		 * fault is inside libc++, so a wild register elsewhere does not turn
		 * into a second fault in the handler.
		 */
		if (strncmp(where, "libc++", 6) == 0) {
			snprintf(line, sizeof(line),
			    "MONDRIAN FAULT[%d]: self '%s' base '%s'\n",
			    getpid(), mondrian_cxx_string((const void *)(uintptr_t)x0),
			    mondrian_cxx_string((const void *)(uintptr_t)x1));
			mondrian_exc_say(line);
		}
	}
	/* SA_RESETHAND already restored the default: returning re-executes the
	 * faulting instruction, so the process dies the way it would have. */
}

static void
mondrian_fault_arm(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = mondrian_fault;
	sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
	sigemptyset(&sa.sa_mask);
	(void)sigaction(SIGSEGV, &sa, NULL);
	(void)sigaction(SIGBUS, &sa, NULL);
}

static void
mondrian_exc_install(int quiet)
{
	void (*set_objc)(void (*)(id)) =
	    (void (*)(void (*)(id)))dlsym(RTLD_DEFAULT,
	    "NSSetUncaughtExceptionHandler");
	int (*set_cxx)(void (*)(void)) =
	    (int (*)(void (*)(void)))dlsym(RTLD_DEFAULT, "_ZSt13set_terminatePFvvE");
	/*
	 * quiet: arm only the hooks that print the exception where it is built,
	 * and leave the uncaught/terminate handlers alone. Measured 2026-11-18:
	 * with this dylib's terminate handler in place assetsd dies `sig 11` in
	 * its guard page instead of `sig 6`, so its own death mode stops being
	 * evidence. The construction hooks do not perturb: they read the object
	 * before anyone throws it.
	 */
	if (!quiet) {
		if (set_objc != NULL) {
			set_objc(mondrian_exc_report);
		}
		if (set_cxx != NULL) {
			(void)set_cxx(mondrian_exc_terminate);
		}
		mondrian_fault_arm();
	}
	mondrian_probe_fmt("MONDRIAN EXC[%d]: armed prog %s objc %d cxx %d quiet %d\n",
	    getpid(), getprogname(), quiet ? 0 : set_objc != NULL,
	    quiet ? 0 : set_cxx != NULL, quiet);
}

/*
 * The reason string, caught where it is raised. Interposing a libsystem symbol
 * does not take effect in this dylib (measured before this probe existed), but
 * Objective-C swizzling does, and every NSException is raised through
 * -[NSException raise] -- the class methods call it too. Measured 2026-11-18:
 * the terminate handler names the type (`NSException`) and the machine dies
 * before the object can be read out of libc++abi's globals, so this is the one
 * place where the message is still reachable.
 */
static void (*mondrian_raise_original)(id, SEL);
static id (*mondrian_exc_with_original)(id, SEL, id, id, id);
static id (*mondrian_exc_init_original)(id, SEL, id, id, id);

static void
mondrian_exc_note(id self, const char *how)
{
	@try {
		NSString *n = [self name];
		NSString *r = [self reason];

		if (n != nil && [n isKindOfClass:[NSString class]]) {
			mondrian_probe_fmt("MONDRIAN EXC[%d]: %s name %s\n", getpid(),
			    how, [n UTF8String]);
		}
		if (r != nil && [r isKindOfClass:[NSString class]]) {
			mondrian_probe_fmt("MONDRIAN EXC[%d]: %s reason %s\n", getpid(),
			    how, [r UTF8String]);
		}
	} @catch (id other) {
		mondrian_exc_say("MONDRIAN EXC: could not read the exception\n");
	}
	/*
	 * Who raised it. The message alone says what failed; the frames say where,
	 * and tools/dsc-va.py turns `image+0x...` into a symbol. Printed at
	 * construction, so it is there even when the process dies before the
	 * handler runs.
	 */
	{
		void *frames[14];
		int n = backtrace(frames, 14);
		int i;

		for (i = 1; i < n && i < 10; i++) {
			Dl_info info;
			const char *base;

			if (dladdr(frames[i], &info) == 0 || info.dli_fname == NULL) {
				continue;
			}
			base = strrchr(info.dli_fname, '/');
			mondrian_probe_fmt("MONDRIAN EXC[%d]:   %s #%d %s+0x%lx\n",
			    getpid(), how, i, base != NULL ? base + 1 : info.dli_fname,
			    (unsigned long)((uintptr_t)frames[i] -
			    (uintptr_t)info.dli_fbase));
		}
	}
}

static id
mondrian_exc_with(id self, SEL _cmd, id name, id reason, id info)
{
	if (mondrian_exc_with_original != NULL) {
		self = mondrian_exc_with_original(self, _cmd, name, reason, info);
	}
	mondrian_exc_note(self, "with");
	return self;
}

static id
mondrian_exc_init(id self, SEL _cmd, id name, id reason, id info)
{
	if (mondrian_exc_init_original != NULL) {
		self = mondrian_exc_init_original(self, _cmd, name, reason, info);
	}
	mondrian_exc_note(self, "init");
	return self;
}

static void
mondrian_raise(id self, SEL _cmd)
{
	mondrian_exc_note(self, "raised");
	if (mondrian_raise_original != NULL) {
		mondrian_raise_original(self, _cmd);
	}
}

static void
mondrian_probe_raise(void)
{
	Class cls = objc_getClass("NSException");
	Method method;

	if (cls == Nil) {
		return;
	}
	method = class_getInstanceMethod(cls, sel_registerName("raise"));
	if (method != NULL) {
		mondrian_raise_original = (void (*)(id, SEL))method_setImplementation(
		    method, (IMP)mondrian_raise);
	}
	method = class_getClassMethod(cls,
	    sel_registerName("exceptionWithName:reason:userInfo:"));
	if (method != NULL) {
		mondrian_exc_with_original = (id (*)(id, SEL, id, id, id))
		    method_setImplementation(method, (IMP)mondrian_exc_with);
	}
	method = class_getInstanceMethod(cls,
	    sel_registerName("initWithName:reason:userInfo:"));
	if (method != NULL) {
		mondrian_exc_init_original = (id (*)(id, SEL, id, id, id))
		    method_setImplementation(method, (IMP)mondrian_exc_init);
	}
	mondrian_probe_fmt("MONDRIAN EXC[%d]: exception hooks %d %d %d\n", getpid(),
	    mondrian_raise_original != NULL, mondrian_exc_with_original != NULL,
	    mondrian_exc_init_original != NULL);
}

/*
 * Is a service actually registered in this port's bootstrap namespace? Five
 * services die in PlugInKit's extension bootstrap (measured 2026-11-18: the
 * frames sit in the code that prints "Bootstrapping; Bootstrap complete. Ready
 * for handshake from host."), and the plug-in broker `pkd` -- whose binary and
 * launchd job are both in the root -- never appears in the ring at all. A
 * lookup from a process that does not own the name answers whether launchd has
 * it, which is the difference between "the broker is broken" and "the broker
 * was never asked".
 */
static void
mondrian_xpc_probe(void)
{
	static const char *const names[] = {
		"com.apple.pluginkit.pkd",
		"com.apple.containermanagerd",
		"com.apple.assetsd",
		"com.apple.iconservices.agent",
		"com.apple.runningboardd",
		"com.apple.backboardd",
	};
	size_t i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		mach_port_t port = MACH_PORT_NULL;
		kern_return_t kr = bootstrap_look_up(bootstrap_port, names[i], &port);

		mondrian_probe_fmt("MONDRIAN XPC: %s -> %d\n", names[i], (int)kr);
		if (kr == KERN_SUCCESS && port != MACH_PORT_NULL) {
			mach_port_deallocate(mach_task_self(), port);
		}
	}
}

static void *
mondrian_xpc_probe_thread(void *unused)
{
	(void)unused;
	/* Late enough that launchd has finished bringing the session up. */
	sleep(4);
	mondrian_xpc_probe();
	return NULL;
}

static NSURL *(*mondrian_group_original)(id, SEL, NSString *);
static NSURL *(*mondrian_url_for_dir_original)(id, SEL, NSUInteger, NSUInteger, NSURL *, BOOL, NSError **);
static NSArray *(*mondrian_urls_for_dir_original)(id, SEL, NSUInteger, NSUInteger);

/*
 * Which path resolved to nil. The exception says the service passed a nil URL to
 * -createDirectoryAtURL:, so the question is which resolver produced it: a group
 * container, one of the standard directories, or the home the process thinks it
 * has. Directory enum values are printed raw (1 Documents, 5 Library, 6 Caches,
 * 13 ApplicationSupport on iOS) so the line stays short.
 */
static void
mondrian_url_note(const char *what, unsigned long which, id value)
{
	if (value == nil) {
		mondrian_probe_fmt("MONDRIAN URL[%d]: %s %lu -> nil\n", getpid(), what,
		    which);
		return;
	}
	if ([value isKindOfClass:[NSArray class]]) {
		NSArray *list = value;

		mondrian_probe_fmt("MONDRIAN URL[%d]: %s %lu -> %lu path %s\n",
		    getpid(), what, which, (unsigned long)[list count],
		    [list count] > 0
		    ? [[[list objectAtIndex:0] path] UTF8String] : "-");
		return;
	}
	{
		NSString *s = [value isKindOfClass:[NSURL class]]
		    ? [(NSURL *)value path] : [value description];

		mondrian_probe_fmt("MONDRIAN URL[%d]: %s %lu -> %s\n", getpid(), what,
		    which, s != nil ? [s UTF8String] : "-");
	}
}

static NSURL *
mondrian_group_url(id self, SEL _cmd, NSString *group)
{
	NSURL *result = mondrian_group_original != NULL
	    ? mondrian_group_original(self, _cmd, group) : nil;

	mondrian_probe_fmt("MONDRIAN URL[%d]: group %s\n", getpid(),
	    group != nil ? [group UTF8String] : "-");
	mondrian_url_note("group", 0, result);
	return result;
}

static NSURL *
mondrian_url_for_dir(id self, SEL _cmd, NSUInteger directory,
    NSUInteger domains, NSURL *appropriate, BOOL create, NSError **error)
{
	NSURL *result = mondrian_url_for_dir_original != NULL
	    ? mondrian_url_for_dir_original(self, _cmd, directory, domains,
	    appropriate, create, error) : nil;

	mondrian_url_note("urlForDirectory", (unsigned long)directory, result);
	return result;
}

static NSArray *
mondrian_urls_for_dir(id self, SEL _cmd, NSUInteger directory, NSUInteger domains)
{
	NSArray *result = mondrian_urls_for_dir_original != NULL
	    ? mondrian_urls_for_dir_original(self, _cmd, directory, domains) : nil;

	mondrian_url_note("urlsForDirectory", (unsigned long)directory, result);
	return result;
}

static BOOL (*mondrian_create_dir_original)(id, SEL, NSURL *, BOOL, NSDictionary *, NSError **);

/*
 * Who asks for the nil URL. Nothing in the resolver hooks fired before the
 * exception, so the URL is built (or left nil) elsewhere: this prints the caller
 * of -createDirectoryAtURL: as image+offset, which tools/dsc-va.py turns into a
 * cache image and a disassembly.
 */
static BOOL
mondrian_create_dir(id self, SEL _cmd, NSURL *url, BOOL intermediate,
    NSDictionary *attributes, NSError **error)
{
	static unsigned said;

	if (url == nil && said < 3) {
		void *frames[20];
		int n = backtrace(frames, 20);
		int i;

		said++;
		mondrian_probe_fmt("MONDRIAN URL[%d]: createDirectoryAtURL nil\n",
		    getpid());
		for (i = 1; i < n && i < 12; i++) {
			Dl_info info;
			const char *base;

			if (dladdr(frames[i], &info) == 0 || info.dli_fname == NULL) {
				continue;
			}
			base = strrchr(info.dli_fname, '/');
			mondrian_probe_fmt("MONDRIAN URL[%d]:   #%d %s+0x%lx\n",
			    getpid(), i, base != NULL ? base + 1 : info.dli_fname,
			    (unsigned long)((uintptr_t)frames[i] -
			    (uintptr_t)info.dli_fbase));
		}
	}
	return mondrian_create_dir_original != NULL
	    ? mondrian_create_dir_original(self, _cmd, url, intermediate,
	    attributes, error) : NO;
}

static void
mondrian_probe_urls(void)
{
	Class cls = objc_getClass("NSFileManager");
	Method method;

	if (cls == Nil) {
		return;
	}
	method = class_getInstanceMethod(cls,
	    sel_registerName("createDirectoryAtURL:withIntermediateDirectories:attributes:error:"));
	if (method != NULL) {
		mondrian_create_dir_original = (BOOL (*)(id, SEL, NSURL *, BOOL,
		    NSDictionary *, NSError **))method_setImplementation(method,
		    (IMP)mondrian_create_dir);
	}
	method = class_getInstanceMethod(cls,
	    sel_registerName("containerURLForSecurityApplicationGroupIdentifier:"));
	if (method != NULL) {
		mondrian_group_original = (NSURL *(*)(id, SEL, NSString *))
		    method_setImplementation(method, (IMP)mondrian_group_url);
	}
	method = class_getInstanceMethod(cls,
	    sel_registerName("URLForDirectory:inDomains:appropriateForURL:create:error:"));
	if (method != NULL) {
		mondrian_url_for_dir_original =
		    (NSURL *(*)(id, SEL, NSUInteger, NSUInteger, NSURL *, BOOL,
		    NSError **))method_setImplementation(method,
		    (IMP)mondrian_url_for_dir);
	}
	method = class_getInstanceMethod(cls, sel_registerName("URLsForDirectory:inDomains:"));
	if (method != NULL) {
		mondrian_urls_for_dir_original = (NSArray *(*)(id, SEL, NSUInteger,
		    NSUInteger))method_setImplementation(method,
		    (IMP)mondrian_urls_for_dir);
	}
	mondrian_probe_fmt("MONDRIAN URL[%d]: hooks group %d dir %d dirs %d create %d home %s\n",
	    getpid(), mondrian_group_original != NULL,
	    mondrian_url_for_dir_original != NULL,
	    mondrian_urls_for_dir_original != NULL,
	    mondrian_create_dir_original != NULL,
	    NSHomeDirectory() != nil ? [NSHomeDirectory() UTF8String] : "nil");
}

/*
 * Can a normal mobile-uid process resolve the containers the appex needs?
 *
 * The services that die raise on a nil URL, and the appex itself is awkward to
 * reach (it only execs when the photo library is touched, and only once a
 * session). SpringBoard is easy to restart and runs as the same uid, so this
 * asks the same questions there: the Photos app group, the standard
 * directories, and the home. A nil here is the port's container environment,
 * not something the appex does; an answer here while the appex still gets nil
 * would put the difference in its sandbox instead.
 *
 * Switch: /private/var/vm/mondrian-urltest (separate from the exception probe,
 * so an ordinary boot with the UI hook never runs it).
 */
#define MONDRIAN_GROUP_PHOTOS "group.com.apple.mobileslideshow.PhotosFileProvider"

static void
mondrian_url_report(const char *what, id value)
{
	if (value == nil) {
		mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: %s -> nil\n", getpid(),
		    what);
		return;
	}
	if ([value isKindOfClass:[NSURL class]]) {
		NSString *p = [(NSURL *)value path];
		mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: %s -> %s\n", getpid(),
		    what, p != nil ? [p UTF8String] : "(no path)");
		return;
	}
	if ([value isKindOfClass:[NSArray class]]) {
		NSArray *list = value;
		NSUInteger i, n = [list count];

		mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: %s -> %lu path(s)\n",
		    getpid(), what, (unsigned long)n);
		for (i = 0; i < n && i < 3; i++) {
			id item = [list objectAtIndex:i];
			NSString *p = [item isKindOfClass:[NSURL class]]
			    ? [(NSURL *)item path] : nil;

			mondrian_probe_fmt("MONDRIAN URLLOOK[%d]:   %s[%lu] %s\n",
			    getpid(), what, (unsigned long)i,
			    p != nil ? [p UTF8String] : "(no path)");
		}
		return;
	}
	mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: %s -> %s\n", getpid(), what,
	    [[value description] UTF8String]);
}

/*
 * "plugin has invalid sandbox or container: error 2 path ?" -- the appex dies
 * saying it has no container, so the question is which of the paths it would be
 * sandboxed with is missing. This runs inside the dying process, before it
 * returns from the constructor, and prints what the sandbox handed it.
 */
/*
 * "plugin has invalid sandbox or container: error 2 path ?" is ENOENT: the
 * appex cannot be sandboxed because the app it belongs to has no data
 * container. Photos' (`com.apple.mobileslideshow`) is not among the 129 the
 * root ships, and the service that would create it never runs, so this builds
 * it from the same metadata an existing container carries and lets libcontainer
 * find it. Sandboxed processes run as mobile, and SpringBoard is mobile too.
 */
static void
mondrian_seed_container(const char *identifier, NSString *uuid)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *base = [NSString stringWithFormat:
	    @"/private/var/mobile/Containers/Data/Application/%@", uuid];
	static NSString *const dirs[] = { @"Documents", @"Library",
		@"Library/Caches", @"Library/Preferences",
		@"Library/Application Support", @"SystemData", @"tmp" };
	NSString *metaPath;
	NSDictionary *meta;
	NSUInteger i;
	BOOL ok;

	ok = [fm createDirectoryAtPath:base withIntermediateDirectories:YES
	    attributes:nil error:NULL];
	for (i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		NSString *p = [base stringByAppendingPathComponent:dirs[i]];

		(void)[fm createDirectoryAtPath:p withIntermediateDirectories:YES
		    attributes:nil error:NULL];
	}
	meta = @{
		@"MCMMetadataActiveDPClass": @(-1),
		@"MCMMetadataContentClass": @2,
		@"MCMMetadataIdentifier": [NSString stringWithUTF8String:identifier],
		@"MCMMetadataInfo": @{
			@"com.apple.MobileInstallation.ContentProtectionClass": @(-1),
		},
		@"MCMMetadataSchemaVersion": @1,
		@"MCMMetadataUUID": uuid,
		@"MCMMetadataUserIdentity": @{
			@"posixUID": @501,
			@"posixGID": @501,
			@"type": @2,
			@"version": @"2",
		},
		@"MCMMetadataVersion": @6,
	};
	metaPath = [base stringByAppendingPathComponent:
	    @".com.apple.mobile_container_manager.metadata.plist"];
	mondrian_probe_fmt("MONDRIAN SEED[%d]: %s dir %d meta %d at %s\n", getpid(),
	    identifier, (int)ok, (int)[meta writeToFile:metaPath atomically:YES],
	    [base UTF8String]);
}

static void
mondrian_pluginkit_calls(unsigned long frame);

static void
mondrian_tcc_report(void);

struct mondrian_tcc_cols {
	int count;
	char name[32][40];
};

static int
mondrian_tcc_col_cb(void *ctx, int n, char **vals, char **cols)
{
	struct mondrian_tcc_cols *c = (struct mondrian_tcc_cols *)ctx;

	(void)n;
	(void)cols;
	if (c->count < 32 && vals[1] != NULL) {
		snprintf(c->name[c->count], sizeof(c->name[0]), "%s", vals[1]);
		c->count++;
	}
	return 0;
}

static int
mondrian_tcc_has(const struct mondrian_tcc_cols *c, const char *name)
{
	int i;

	for (i = 0; i < c->count; i++) {
		if (strcmp(c->name[i], name) == 0) {
			return 1;
		}
	}
	return 0;
}

static int
mondrian_tcc_row_cb(void *ctx, int n, char **vals, char **cols)
{
	(void)ctx;
	(void)n;
	(void)cols;
	mondrian_probe_fmt("MONDRIAN TCC[%d]: row %s auth %s\n", getpid(),
	    vals[0] != NULL ? vals[0] : "?", vals[1] != NULL ? vals[1] : "?");
	return 0;
}

static int
mondrian_tcc_insert(void *db,
    int (*exec)(void *, const char *, int (*)(void *, int, char **, char **),
    void *, char **),
    const struct mondrian_tcc_cols *cols, const char *client, int client_type)
{
	char sql[1024];
	size_t n = 0;

	n += (size_t)snprintf(sql + n, sizeof(sql) - n,
	    "INSERT OR REPLACE INTO access (service, client, client_type,"
	    " auth_value, auth_reason, auth_version");
	if (mondrian_tcc_has(cols, "last_modified"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", last_modified");
	if (mondrian_tcc_has(cols, "last_reminded"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", last_reminded");
	if (mondrian_tcc_has(cols, "flags"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", flags");
	if (mondrian_tcc_has(cols, "indirect_object_identifier"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n,
		    ", indirect_object_identifier");
	if (mondrian_tcc_has(cols, "pid"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", pid");
	if (mondrian_tcc_has(cols, "pid_version"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", pid_version");
	if (mondrian_tcc_has(cols, "boot_uuid"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", boot_uuid");
	n += (size_t)snprintf(sql + n, sizeof(sql) - n,
	    ") VALUES ('kTCCServicePhotos', '%s', %d, 2, 4, 1", client,
	    client_type);
	if (mondrian_tcc_has(cols, "last_modified"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n,
		    ", strftime('%%s','now')");
	if (mondrian_tcc_has(cols, "last_reminded"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n,
		    ", strftime('%%s','now')");
	if (mondrian_tcc_has(cols, "flags"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", 0");
	if (mondrian_tcc_has(cols, "indirect_object_identifier"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", ''");
	if (mondrian_tcc_has(cols, "pid"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", NULL");
	if (mondrian_tcc_has(cols, "pid_version"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", NULL");
	if (mondrian_tcc_has(cols, "boot_uuid"))
		n += (size_t)snprintf(sql + n, sizeof(sql) - n, ", NULL");
	n += (size_t)snprintf(sql + n, sizeof(sql) - n, ");");
	mondrian_probe_fmt("MONDRIAN TCC[%d]: sql %s\n", getpid(), sql);
	return exec(db, sql, NULL, NULL, NULL);
}

/*
 * The grant itself. TCC.db already has an `access` table, but not the columns
 * iOS 16 documents (measured: "no column named last_reminded"), so the insert is
 * built from the columns the table really has. The clients are the ones that
 * take part -- the app, the extension's host daemon and the library daemon;
 * assetsd's own message names assetsd, not Photos -- plus each process's own
 * executable path, because a row is only found if the client string matches what
 * TCC computes for the caller. Switch: /private/var/vm/mondrian-tccgrant.
 */
static void
mondrian_tcc_grant(void)
{
	static const char *const clients[] = {
		"com.apple.assetsd",
		"com.apple.mobileslideshow",
		"com.apple.photolibraryd",
	};
	void *lib = dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW);
	int (*open_v2)(const char *, void **, int, const char *) =
	    (int (*)(const char *, void **, int, const char *))
	    dlsym(lib != NULL ? lib : RTLD_DEFAULT, "sqlite3_open_v2");
	int (*exec)(void *, const char *,
	    int (*)(void *, int, char **, char **), void *, char **) =
	    (int (*)(void *, const char *, int (*)(void *, int, char **, char **),
	    void *, char **))dlsym(lib != NULL ? lib : RTLD_DEFAULT, "sqlite3_exec");
	void (*close)(void *) = (void (*)(void *))
	    dlsym(lib != NULL ? lib : RTLD_DEFAULT, "sqlite3_close");
	struct mondrian_tcc_cols cols;
	void *db = NULL;
	char *err = NULL;
	int rc, i;

	if (open_v2 == NULL || exec == NULL) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: grant no sqlite\n", getpid());
		mondrian_tcc_report();
		return;
	}
	rc = open_v2("/private/var/mobile/Library/TCC/TCC.db", &db, 2, NULL);
	if (rc != 0) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: grant open %d\n", getpid(), rc);
		mondrian_tcc_report();
		return;
	}
	cols.count = 0;
	(void)exec(db, "PRAGMA table_info(access);", mondrian_tcc_col_cb, &cols, NULL);
	mondrian_probe_fmt("MONDRIAN TCC[%d]: columns %d\n", getpid(), cols.count);
	for (i = 0; i < (int)(sizeof(clients) / sizeof(clients[0])); i++) {
		int out = mondrian_tcc_insert(db, exec, &cols, clients[i], 0);

		mondrian_probe_fmt("MONDRIAN TCC[%d]: insert %s -> %d\n", getpid(),
		    clients[i], out);
	}
	/*
	 * TCC pairs a row with the client's code identity, and the client is
	 * named either by bundle identifier (client_type 0) or by path (1). A
	 * daemon has no bundle, so the row above is a guess at a name the
	 * database may never be asked about. This one is not a guess: it is the
	 * path this very process was executed from, which the process can print.
	 */
	{
		char exe[PATH_MAX];
		uint32_t size = sizeof(exe);
		int out = -1;

		if (_NSGetExecutablePath(exe, &size) == 0) {
			out = mondrian_tcc_insert(db, exec, &cols, exe, 1);
			mondrian_probe_fmt(
			    "MONDRIAN TCC[%d]: insert path %s -> %d\n", getpid(),
			    exe, out);
		}
	}
	/* The override table is what `tccutil`/profiles use to allow a service for
	 * everyone; it has no client column, so there is no code identity to
	 * match. */
	mondrian_probe_fmt("MONDRIAN TCC[%d]: override photos -> %d\n", getpid(),
	    exec(db, "INSERT OR REPLACE INTO access_overrides (service) VALUES "
	    "('kTCCServicePhotos');", NULL, NULL, NULL));
	mondrian_probe_fmt("MONDRIAN TCC[%d]: override photoadd -> %d\n", getpid(),
	    exec(db, "INSERT OR REPLACE INTO access_overrides (service) VALUES "
	    "('kTCCServicePhotosAdd');", NULL, NULL, NULL));
	/* The rows sit in the WAL; a reader that cannot write -shm sees the old
	 * database. Fold the WAL into the file and leave it in rollback mode. */
	(void)exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", mondrian_tcc_row_cb,
	    NULL, NULL);
	(void)exec(db, "PRAGMA journal_mode=delete;", mondrian_tcc_row_cb, NULL,
	    NULL);
	(void)exec(db, "SELECT count(*) FROM access;", mondrian_tcc_row_cb, NULL,
	    NULL);
	(void)exec(db, "SELECT client || '@' || client_type, auth_value FROM access "
	    "WHERE service = 'kTCCServicePhotos';", mondrian_tcc_row_cb, NULL, &err);
	if (err != NULL) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: readback error %s\n", getpid(),
		    err);
	}
	{
		(void)exec(db, "PRAGMA journal_mode;", mondrian_tcc_row_cb, NULL,
		    NULL);
		(void)exec(db, "SELECT changes();", mondrian_tcc_row_cb, NULL, NULL);
	}
	if (close != NULL) {
		close(db);
	}
	mondrian_tcc_report();
}

/*
 * TCC, the privacy database. assetsd's own exception says "assetsd requires
 * TCCPhotosService access", and nothing in the port has ever dealt with TCC: no
 * database in the root, no grant. This asks the same function assetsd asks, from
 * inside assetsd, and reports whether the database exists at all. Switch:
 * /private/var/vm/mondrian-tcc.
 */
static void
mondrian_tcc_report(void)
{
	typedef int (*preflight_t)(CFStringRef, CFDictionaryRef);
	preflight_t preflight = (preflight_t)dlsym(RTLD_DEFAULT,
	    "TCCAccessPreflight");
	NSString *db = @"/private/var/mobile/Library/TCC/TCC.db";
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attrs = [fm attributesOfItemAtPath:db error:NULL];
	long long size = [[attrs objectForKey:NSFileSize] longLongValue];
	int result = -999;

	if (preflight != NULL) {
		result = preflight(CFSTR("kTCCServicePhotos"), NULL);
	}
	mondrian_probe_fmt(
	    "MONDRIAN TCC[%d]: preflight %d (%s) db %d size %lld\n", getpid(),
	    result, preflight != NULL ? "called" : "symbol missing",
	    (int)[fm fileExistsAtPath:db], size);
}

/*
 * What the dying appex was told about itself. iOS gives a plug-in its own data
 * container under `Containers/Data/PluginKitPlugin`, not an app container under
 * `Application`, so the container seeded for `com.apple.mobileslideshow` cannot
 * be the one this process looks for. Printed before anything can fault: the
 * bundle identifier and NSHomeDirectory() alone say whether the process was
 * given a container at all (a sandboxed app gets its container as HOME), and
 * the directory listing says whether the plugin container tree exists in this
 * root. Switch: /private/var/vm/mondrian-appex.
 */
static void
mondrian_appex_report(void)
{
	static const char *const dirs[] = {
		"/private/var/mobile/Containers/Data/Application",
		"/private/var/mobile/Containers/Data/PluginKitPlugin",
		"/private/var/mobile/Containers/Bundle/Application",
		"/private/var/mobile/Containers/Bundle/PluginKitPlugin",
	};
	NSBundle *bundle = [NSBundle mainBundle];
	NSString *bid = [bundle bundleIdentifier];
	NSString *exe = [bundle executablePath];
	NSString *home = NSHomeDirectory();
	const char *env_home = getenv("HOME");
	const char *env_cfixed = getenv("CFFIXED_USER_HOME");
	const char *env_tmp = getenv("TMPDIR");
	NSFileManager *fm = [NSFileManager defaultManager];
	size_t i;

	mondrian_probe_fmt("MONDRIAN APPEX[%d]: bid %s\n", getpid(),
	    bid != nil ? [bid UTF8String] : "(nil)");
	mondrian_probe_fmt("MONDRIAN APPEX[%d]: exe %s\n", getpid(),
	    exe != nil ? [exe UTF8String] : "(nil)");
	mondrian_probe_fmt("MONDRIAN APPEX[%d]: home %s env %s cfixed %s tmp %s\n",
	    getpid(), home != nil ? [home UTF8String] : "(nil)",
	    env_home != NULL ? env_home : "(nil)",
	    env_cfixed != NULL ? env_cfixed : "(nil)",
	    env_tmp != NULL ? env_tmp : "(nil)");
	mondrian_probe_fmt("MONDRIAN APPEX[%d]: uid %d gid %d ppid %d\n", getpid(),
	    (int)geteuid(), (int)getegid(), (int)getppid());
	/*
	 * Name the calls of the function that raises the exception. The frame is
	 * the return address into PlugInKit, measured from this boot's stacks; the
	 * offsets have been the same every time (+0x18d5c).
	 */
	if (mondrian_file_on("/private/var/vm/mondrian-bl")) {
		mondrian_pluginkit_calls(0x18d5c);
	}
	for (i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		NSString *p = [NSString stringWithUTF8String:dirs[i]];
		NSArray *list = [fm contentsOfDirectoryAtPath:p error:NULL];

		mondrian_probe_fmt("MONDRIAN APPEX[%d]: %s exists %d entries %ld\n",
		    getpid(), dirs[i], (int)[fm fileExistsAtPath:p],
		    list != nil ? (long)[list count] : -1L);
	}
	/*
	 * The sandbox's own answer is the one PlugInKit checks. The symbol is
	 * private, so it is looked up and its return value printed; a missing
	 * symbol is a result too (this process may not have the sandbox at all).
	 */
	{
		typedef int (*container_path_pid_t)(int, char *, size_t);
		container_path_pid_t path_for_pid =
		    (container_path_pid_t)dlsym(RTLD_DEFAULT,
		    "sandbox_container_path_for_pid");
		void *libc = dlsym(RTLD_DEFAULT, "container_copy_path");

		mondrian_probe_fmt("MONDRIAN APPEX[%d]: syms cpath_pid %d libcontainer %d\n",
		    getpid(), path_for_pid != NULL, libc != NULL);
		mondrian_probe_fmt(
		    "MONDRIAN APPEX[%d]: syms path_token %d consume %d\n",
		    getpid(),
		    dlsym(RTLD_DEFAULT, "sandbox_container_path_for_audit_token") != NULL,
		    dlsym(RTLD_DEFAULT, "sandbox_extension_consume") != NULL);
		if (path_for_pid != NULL) {
			char buf[1024];

			memset(buf, 0, sizeof(buf));
			int r = path_for_pid(getpid(), buf, sizeof(buf));

			mondrian_probe_fmt(
			    "MONDRIAN APPEX[%d]: sandbox path -> err %d path %s\n",
			    getpid(), r, buf[0] != '\0' ? buf : "(empty)");
		}
	}
	/*
	 * The container side of the same message. The query API is asked the way
	 * libcontainer's own clients ask it, for the appex's identifier and for
	 * Photos', across the classes that exist; a NULL path with an error
	 * number is the "path ?" of the exception.
	 */
	{
		typedef void *mcm_query_t;
		typedef void *mcm_container_t;
		mcm_query_t (*q_create)(void) = (mcm_query_t (*)(void))
		    dlsym(RTLD_DEFAULT, "container_query_create");
		void (*q_set_id)(mcm_query_t, const char *) =
		    (void (*)(mcm_query_t, const char *))
		    dlsym(RTLD_DEFAULT, "container_query_set_identifiers");
		void (*q_set_class)(mcm_query_t, int) =
		    (void (*)(mcm_query_t, int))
		    dlsym(RTLD_DEFAULT, "container_query_set_class");
		void (*q_set_owners)(mcm_query_t, int) =
		    (void (*)(mcm_query_t, int))
		    dlsym(RTLD_DEFAULT, "container_query_set_include_other_owners");
		mcm_container_t (*q_single)(mcm_query_t) =
		    (mcm_container_t (*)(mcm_query_t))
		    dlsym(RTLD_DEFAULT, "container_query_get_single_result");
		const char *(*c_path)(mcm_container_t) =
		    (const char *(*)(mcm_container_t))
		    dlsym(RTLD_DEFAULT, "container_copy_path");
		const char *ids[2];
		int cls;

		ids[0] = bid != nil ? [bid UTF8String] : "";
		ids[1] = "com.apple.mobileslideshow";
		mondrian_probe_fmt(
		    "MONDRIAN APPEX[%d]: container api create %d id %d class %d single %d path %d\n",
		    getpid(), q_create != NULL, q_set_id != NULL,
		    q_set_class != NULL, q_single != NULL, c_path != NULL);
		if (q_create != NULL && q_set_id != NULL && q_single != NULL) {
			for (i = 0; i < 2; i++) {
				for (cls = 0; cls <= 6; cls++) {
					mcm_query_t q = q_create();
					mcm_container_t c;
					const char *p = NULL;

					q_set_id(q, ids[i]);
					if (q_set_class != NULL) {
						q_set_class(q, cls);
					}
					if (q_set_owners != NULL) {
						q_set_owners(q, 1);
					}
					c = q_single(q);
					if (c != NULL && c_path != NULL) {
						p = c_path(c);
					}
					mondrian_probe_fmt(
					    "MONDRIAN APPEX[%d]: query %s class %d -> %s\n",
					    getpid(), ids[i], cls,
					    p != NULL ? p : "(no path)");
				}
			}
		}
	}
}

/*
 * Which app containers exist, and whether one of them is Photos'. The container
 * manager now starts, so the question is whether it created the container the
 * appex cannot find -- and whether the one this hook seeded by hand is the only
 * one. Printed only when the URL test switch is on.
 */
/*
 * What the plug-in handshake asks for, and what it gets. The message says the
 * extension has "invalid sandbox or container" and prints a NULL path, so the
 * answer is the key it looked up in the reply that pkd (or the host) sent. Only
 * keys that name a sandbox, container or plug-in are printed, so the noise stays
 * out of the ring. Switch: /private/var/vm/mondrian-keys.
 */
static id (*mondrian_objkey_orig)(id, SEL, id);
static id (*mondrian_subscript_orig)(id, SEL, id);

static int
mondrian_key_of_interest(id key)
{
	const char *s;

	if (![key isKindOfClass:[NSString class]]) {
		return 0;
	}
	s = [key UTF8String];
	if (s == NULL) {
		return 0;
	}
	return strstr(s, "sandbox") != NULL || strstr(s, "container") != NULL ||
	    strstr(s, "Sandbox") != NULL || strstr(s, "Container") != NULL ||
	    strstr(s, "PlugIn") != NULL || strstr(s, "plugin") != NULL;
}

static id
mondrian_objkey(id self, SEL _cmd, id key)
{
	id value = mondrian_objkey_orig != NULL
	    ? mondrian_objkey_orig(self, _cmd, key) : nil;

	/*
	 * The handshake failure reads "missing data key in reply", so the useful
	 * line is the miss: a key asked for and answered with nil. Interest-based
	 * filtering caught nothing (the reply is not read with a sandbox-looking
	 * key name), and printing every hit floods the ring.
	 */
	if (value == nil && key != nil && [key isKindOfClass:[NSString class]]) {
		static unsigned misses;

		if (misses < 40) {
			misses++;
			mondrian_probe_fmt("MONDRIAN KEY[%d]: miss %s\n", getpid(),
			    [(NSString *)key UTF8String]);
		}
		return value;
	}
	if (mondrian_key_of_interest(key)) {
		mondrian_probe_fmt("MONDRIAN KEY[%d]: %s -> %s\n", getpid(),
		    [(NSString *)key UTF8String], value != nil ? "value" : "nil");
	}
	return value;
}

static id
mondrian_subscript(id self, SEL _cmd, id key)
{
	id value = mondrian_subscript_orig != NULL
	    ? mondrian_subscript_orig(self, _cmd, key) : nil;

	if (value == nil && key != nil && [key isKindOfClass:[NSString class]]) {
		static unsigned misses;

		if (misses < 40) {
			misses++;
			mondrian_probe_fmt("MONDRIAN KEY[%d]: miss [ ] %s\n", getpid(),
			    [(NSString *)key UTF8String]);
		}
		return value;
	}
	if (mondrian_key_of_interest(key)) {
		mondrian_probe_fmt("MONDRIAN KEY[%d]: %s [ ] -> %s\n", getpid(),
		    [(NSString *)key UTF8String], value != nil ? "value" : "nil");
	}
	return value;
}

static void
mondrian_key_probe(void)
{
	Class cls = objc_getClass("NSDictionary");
	Method method;

	if (cls == Nil) {
		return;
	}
	method = class_getInstanceMethod(cls, sel_registerName("objectForKey:"));
	if (method != NULL) {
		mondrian_objkey_orig = (id (*)(id, SEL, id))
		    method_setImplementation(method, (IMP)mondrian_objkey);
	}
	method = class_getInstanceMethod(cls, sel_registerName("objectForKeyedSubscript:"));
	if (method != NULL) {
		mondrian_subscript_orig = (id (*)(id, SEL, id))
		    method_setImplementation(method, (IMP)mondrian_subscript);
	}
	mondrian_probe_fmt("MONDRIAN KEY[%d]: hooks %d %d\n", getpid(),
	    mondrian_objkey_orig != NULL, mondrian_subscript_orig != NULL);
}

static void
mondrian_containers_report(void)
{
	static const char *const watch[] = {
		"com.apple.mobileslideshow",
		"com.apple.Preferences",
		"com.apple.AppStore",
		"com.apple.mobilesafari",
	};
	NSString *base = @"/private/var/mobile/Containers/Data/Application";
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *list = [fm contentsOfDirectoryAtPath:base error:NULL];
	NSMutableDictionary *found = [NSMutableDictionary dictionary];
	NSUInteger i, n, photos = 0;
	size_t w;

	if (list == nil) {
		say("MONDRIAN CONTAINERS: no listing\n");
		return;
	}
	n = [list count];
	mondrian_probe_fmt("MONDRIAN CONTAINERS[%d]: %lu entries\n", getpid(),
	    (unsigned long)n);
	for (i = 0; i < n; i++) {
		NSString *dir = [list objectAtIndex:i];
		NSString *meta = [base stringByAppendingPathComponent:dir];

		meta = [meta stringByAppendingPathComponent:
		    @".com.apple.mobile_container_manager.metadata.plist"];
		@try {
			NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
			NSString *ident = [d objectForKey:@"MCMMetadataIdentifier"];

			if (ident == nil || ![ident isKindOfClass:[NSString class]]) {
				continue;
			}
			[found setObject:dir forKey:ident];
			if ([ident rangeOfString:@"photo" options:NSCaseInsensitiveSearch].location != NSNotFound ||
			    [ident rangeOfString:@"slideshow" options:NSCaseInsensitiveSearch].location != NSNotFound) {
				mondrian_probe_fmt(
				    "MONDRIAN CONTAINERS[%d]: %s -> %s\n", getpid(),
				    [ident UTF8String], [dir UTF8String]);
				photos++;
			}
		} @catch (id other) {
			continue;
		}
	}
	mondrian_probe_fmt("MONDRIAN CONTAINERS[%d]: photos-ish %lu of %lu\n",
	    getpid(), (unsigned long)photos, (unsigned long)n);
	/*
	 * Whether the container manager creates one at all: these are apps that
	 * have no container in the image, so a container here after an app has
	 * been launched is the daemon's work.
	 */
	for (w = 0; w < sizeof(watch) / sizeof(watch[0]); w++) {
		NSString *ident = [NSString stringWithUTF8String:watch[w]];
		NSString *dir = [found objectForKey:ident];

		mondrian_probe_fmt("MONDRIAN CONTAINERS[%d]: watch %s %s\n", getpid(),
		    watch[w], dir != nil ? [dir UTF8String] : "none");
	}
}

static void
mondrian_url_probe_env(void)
{
	static const char *const vars[] = {
		"HOME", "CFFIXED_USER_HOME", "TMPDIR", "SANDBOX_PROFILE",
	};
	NSBundle *bundle = [NSBundle mainBundle];
	NSFileManager *fm = [NSFileManager defaultManager];
	size_t i;

	mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: prog %s uid %d home %s\n",
	    getpid(), getprogname(), getuid(),
	    NSHomeDirectory() != nil ? [NSHomeDirectory() UTF8String] : "nil");
	mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: bundle %s\n", getpid(),
	    bundle != nil && [bundle bundleIdentifier] != nil
	    ? [[bundle bundleIdentifier] UTF8String] : "nil");
	for (i = 0; i < sizeof(vars) / sizeof(vars[0]); i++) {
		const char *v = getenv(vars[i]);

		mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: env %s %s\n", getpid(),
		    vars[i], v != NULL ? v : "(unset)");
	}
	if ([fm respondsToSelector:@selector(containerURLForSecurityApplicationGroupIdentifier:)]) {
		@try {
			mondrian_url_report("group Photos",
			    [fm containerURLForSecurityApplicationGroupIdentifier:
			    @MONDRIAN_GROUP_PHOTOS]);
		} @catch (id other) {
			say("MONDRIAN URLLOOK: group lookup threw\n");
		}
	}
	@try {
		mondrian_url_report("Library/user",
		    [fm URLsForDirectory:5 inDomains:1]);
		mondrian_url_report("Caches/user",
		    [fm URLsForDirectory:6 inDomains:1]);
	} @catch (id other) {
		say("MONDRIAN URLLOOK: dirs lookup threw\n");
	}
}

static void *
mondrian_url_test(void *unused)
{
	static const struct {
		const char *name;
		NSUInteger directory;
		NSUInteger domain;
	} dirs[] = {
		{ "Documents/user", 1, 1 },
		{ "Library/user", 5, 1 },
		{ "Caches/user", 6, 1 },
		{ "ApplicationSupport/user", 13, 1 },
		{ "Library/local", 5, 2 },
	};
	NSFileManager *fm;
	SEL single = sel_registerName(
	    "URLForDirectory:inDomains:appropriateForURL:create:error:");
	size_t i;

	(void)unused;
	sleep(8);
	fm = [NSFileManager defaultManager];
	if (fm == nil) {
		say("MONDRIAN URLLOOK: no NSFileManager\n");
		return NULL;
	}
	mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: prog %s uid %d home %s\n",
	    getpid(), getprogname(), getuid(),
	    NSHomeDirectory() != nil ? [NSHomeDirectory() UTF8String] : "nil");
	/*
	 * Only what this Foundation answers. Measured 2026-11-18: calling
	 * -URLForDirectory:inDomains:appropriateForURL:create:error: directly
	 * killed SpringBoard (sig 6, the same abort trace as the services) twenty
	 * times in a row, and class_getInstanceMethod had already said the method
	 * is not there. Ask, never assume.
	 */
	mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: responds single %d dirs %d\n",
	    getpid(), (int)[fm respondsToSelector:single],
	    (int)[fm respondsToSelector:@selector(URLsForDirectory:inDomains:)]);

	if ([fm respondsToSelector:@selector(containerURLForSecurityApplicationGroupIdentifier:)]) {
		@try {
			mondrian_url_report("group Photos",
			    [fm containerURLForSecurityApplicationGroupIdentifier:
			    @MONDRIAN_GROUP_PHOTOS]);
			mondrian_url_report("group tipsnext",
			    [fm containerURLForSecurityApplicationGroupIdentifier:
			    @"group.com.apple.tipsnext"]);
		} @catch (id other) {
			say("MONDRIAN URLLOOK: group lookup threw\n");
		}
	}
	for (i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
		NSArray *list;

		mondrian_probe_fmt("MONDRIAN URLLOOK[%d]: dir %s %lu/%lu\n",
		    getpid(), dirs[i].name, (unsigned long)dirs[i].directory,
		    (unsigned long)dirs[i].domain);
		@try {
			list = [fm URLsForDirectory:dirs[i].directory
			    inDomains:dirs[i].domain];
		} @catch (id other) {
			say("MONDRIAN URLLOOK: dirs lookup threw\n");
			continue;
		}
		mondrian_url_report(dirs[i].name, list);
	}
	return NULL;
}

/*
 * Who is running, and with which pid, so the kernel's own `kill` command can
 * aim at the process that caches a failure. A `respring` restarts SpringBoard
 * but not pkd, and an extension that has failed once is not requested again
 * until something upstream forgets it. Filtered to the names that matter, so
 * the ring keeps its room. Switch: /private/var/vm/mondrian-ps.
 */
static void
mondrian_process_report(void)
{
	static const char *const watch[] = {
		"launchd", "pkd", "tccd", "runningboardd", "xpcproxy", "assetsd",
		"photolibraryd", "fileproviderd", "containermanagerd",
		"MobileSlideShow", "PhotosFileProvid", "SpringBoard",
	};
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	struct kinfo_proc *procs;
	size_t size = 0, count, i;
	size_t w;

	if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
		return;
	}
	procs = malloc(size);
	if (procs == NULL) {
		return;
	}
	if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
		free(procs);
		return;
	}
	count = size / sizeof(*procs);
	mondrian_probe_fmt("MONDRIAN PS[%d]: %lu processes\n", getpid(),
	    (unsigned long)count);
	for (i = 0; i < count; i++) {
		for (w = 0; w < sizeof(watch) / sizeof(watch[0]); w++) {
			if (strcmp(procs[i].kp_proc.p_comm, watch[w]) != 0) {
				continue;
			}
			mondrian_probe_fmt("MONDRIAN PS[%d]: %s pid %d uid %d\n",
			    getpid(), watch[w], (int)procs[i].kp_proc.p_pid,
			    (int)procs[i].kp_eproc.e_ucred.cr_uid);
			break;
		}
	}
	free(procs);
}

/*
 * The port's sandbox stand-in (xnu 0043) answers ENOENT to the container-path
 * operation, which is the one query PlugInKit makes before it launches a
 * plug-in: the appex dies "plugin has invalid sandbox or container: error 2".
 * The process already knows its own container -- it is HOME, under
 * Containers/Data/PluginKitPlugin -- so the chain is tested here first:
 * answer that one query with HOME and nothing else changes. Switch:
 * /private/var/vm/mondrian-sbx, because interposing is process-wide as soon as
 * this file is loaded and the switch must be able to turn it off. The kernel
 * fix, if this proves the cause, belongs in 0043 and not here.
 */
extern int sandbox_container_path_for_pid(int pid, char *path, size_t size)
    __attribute__((weak_import));
extern int TCCAccessPreflight(CFStringRef service, CFDictionaryRef options)
    __attribute__((weak_import));
extern bool TCCAccessCheckAuditToken(CFStringRef service, audit_token_t token,
    CFDictionaryRef options) __attribute__((weak_import));
extern int TCCAccessPreflightWithAuditToken(CFStringRef service,
    audit_token_t token, CFDictionaryRef options)
    __attribute__((weak_import));
/*
 * The path that crashes a client: TCCAccessRequest aborts the caller when tccd
 * denies and the app has no usage description in its Info.plist, which is the
 * `__CRASHING_DUE_TO_PRIVACY_VIOLATION__` abort MobileSlideShow and AegirPoster
 * die of (measured 2026-11-18: same pc, lr and far in both). Interposing the
 * preflight was never enough because an app asks, it does not preflight.
 */
extern void TCCAccessRequest(CFStringRef service, CFDictionaryRef options,
    void (^reply)(bool granted)) __attribute__((weak_import));

/* Defined with the stand-in itself; used by every interposer below. */
static int mondrian_tcc_standin(void);

/*
 * TCC cannot answer these binaries: the grant is in the database (measured:
 * the row reads back with auth 2, the file is checkpointed, tccd restarted) and
 * the preflight still denies, because a row is matched against the client's code
 * identity and ad-hoc binaries have none. The port has no code signatures, so
 * the query has to be answered the way 0043 answers the sandbox's: allowed.
 * On by default; `/private/var/vm/mondrian-tccoff` turns it off for an A/B.
 */
static int
mondrian_tcc_preflight(CFStringRef service, CFDictionaryRef options)
{
	(void)options;
	if (mondrian_tcc_standin()) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: preflight %s -> allowed\n",
		    getpid(), service != NULL
		        ? [(__bridge NSString *)service UTF8String] : "(null)");
		return 0;
	}
	return 1;
}

static bool
mondrian_tcc_token(CFStringRef service, audit_token_t token,
    CFDictionaryRef options)
{
	(void)token;
	(void)options;
	if (mondrian_tcc_standin()) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: token %s -> allowed\n",
		    getpid(), service != NULL
		        ? [(__bridge NSString *)service UTF8String] : "(null)");
		return true;
	}
	return false;
}

/*
 * The same question, asked with the token but through the preflight entry
 * point: `PHAssetChangeRequest` submission is refused with
 * `PHPhotosErrorAccessRestricted` (3310) while both `TCCAccessPreflight` and
 * `TCCAccessCheckAuditToken` answer allowed here, so this is the call that was
 * left uncovered. Same switch, same answer.
 */
static int
mondrian_tcc_preflight_token(CFStringRef service, audit_token_t token,
    CFDictionaryRef options)
{
	(void)token;
	(void)options;
	if (mondrian_tcc_standin()) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: preflightToken %s -> allowed\n",
		    getpid(), service != NULL
		        ? [(__bridge NSString *)service UTF8String] : "(null)");
		return 0;
	}
	return 1;
}

/*
 * The request an app makes, which the preflight never covered: this is the call
 * whose denial aborts the client, and the abort is the crash MobileSlideShow and
 * AegirPoster die of. The switch is the same one that answers the preflight, so
 * a boot either has the stand-in or has none.
 */
static void
mondrian_tcc_request(CFStringRef service, CFDictionaryRef options,
    void (^reply)(bool granted))
{
	(void)options;
	if (mondrian_tcc_standin()) {
		mondrian_probe_fmt("MONDRIAN TCC[%d]: request %s -> allowed\n",
		    getpid(), service != NULL
		        ? [(__bridge NSString *)service UTF8String] : "(null)");
		if (reply != NULL) {
			reply(true);
		}
		return;
	}
	if (reply != NULL) {
		reply(false);
	}
}

/*
 * Which calls the raising function makes. The cache image is truncated on the
 * workstation, so the imported targets of these `bl`s cannot be named offline;
 * here the code is read in the process and every target goes through dladdr,
 * which names the image it really lands in.
 */
static void
mondrian_pluginkit_calls(unsigned long frame)
{
	const char *path = NULL;
	uintptr_t base = 0;
	uint32_t i;
	int image;

	for (image = 0; image < 4096; image++) {
		const struct mach_header *h = _dyld_get_image_header((uint32_t)image);

		if (h == NULL) {
			break;
		}
		path = _dyld_get_image_name((uint32_t)image);
		if (path != NULL && strstr(path, "PlugInKit") != NULL &&
		    strstr(path, "mondrian") == NULL) {
			base = (uintptr_t)h;
			break;
		}
	}
	if (base == 0) {
		return;
	}
	mondrian_probe_fmt("MONDRIAN PKCALL[%d]: PlugInKit base 0x%lx frame +0x%lx\n",
	    getpid(), (unsigned long)base, frame);
	/* 160 instructions ending at the raising call. */
	for (i = 0; i < 160; i++) {
		uintptr_t addr = base + frame - (160 - i) * 4;
		uint32_t insn = *(const uint32_t *)addr;
		Dl_info info;

		if ((insn & 0xFC000000) != 0x94000000) {
			continue;
		}
		{
			int32_t imm = (int32_t)(insn & 0x03FFFFFF);

			if (imm & 0x02000000) {
				imm |= (int32_t)0xFC000000;
			}
			addr += (intptr_t)imm * 4;
		}
		if (dladdr((void *)addr, &info) == 0 || info.dli_fname == NULL) {
			mondrian_probe_fmt("MONDRIAN PKCALL[%d]:   +0x%lx -> (unknown)\n",
			    getpid(), (unsigned long)(base + frame - (160 - i) * 4));
			continue;
		}
		mondrian_probe_fmt("MONDRIAN PKCALL[%d]:   +0x%lx -> %s+0x%lx\n",
		    getpid(), (unsigned long)(base + frame - (160 - i) * 4),
		    strrchr(info.dli_fname, '/') != NULL
		        ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
		    (unsigned long)(addr - (uintptr_t)info.dli_fbase));
	}
}
extern int64_t sandbox_extension_consume(const char *token)
    __attribute__((weak_import));

/*
 * The other half of "invalid sandbox or container": the launch request carries
 * a sandbox extension token, the appex consumes it, and 0043 answers ENOENT to
 * that operation too (6). The kernel is permissive anyway, so a handle is all
 * the caller needs; the log says whether the call happened at all.
 */
static int64_t
mondrian_sbx_consume(const char *token)
{
	if (!mondrian_file_on("/private/var/vm/mondrian-sbx")) {
		return -1;
	}
	mondrian_probe_fmt("MONDRIAN SBX[%d]: consume %s len %ld\n", getpid(),
	    token != NULL ? "token" : "null",
	    token != NULL ? (long)strlen(token) : -1L);
	return 1;
}

static int
mondrian_sbx_path(int pid, char *buf, size_t size)
{
	/*
	 * No call to the original: `dlsym(RTLD_NEXT)` returns the interposed
	 * definition, so asking for it recursed into this function until the
	 * stack guard page (measured: `sig 11`, the same return address ten
	 * times). The stand-in in xnu 0043 answers ENOENT to every container
	 * query, so that is what this returns when it has nothing to add.
	 */
	if ((pid == getpid() || pid <= 0) && buf != NULL && size > 0 &&
	    mondrian_file_on("/private/var/vm/mondrian-sbx")) {
		const char *home = getenv("HOME");

		if (home != NULL && home[0] != '\0') {
			snprintf(buf, size, "%s", home);
			mondrian_probe_fmt(
			    "MONDRIAN SBX[%d]: container path %s\n",
			    getpid(), home);
			return 0;
		}
	}
	return ENOENT;
}

/*
 * dyld's interpose tuple: { replacement, replacee }. Kept weak so a process
 * that does not link libsystem_sandbox leaves the tuple pointing at nothing
 * instead of failing to load the hook.
 */
struct mondrian_interpose {
	const void *replacement;
	const void *replacee;
};

/* Defined with the interpose tables below; the replacements call through. */
static const struct mondrian_interpose mondrian_bootstrap_interpose;
static const struct mondrian_interpose mondrian_bootstrap_look_up2_interpose;

/*
 * BTSessionAttachWithQueue returns 9 before any XPC connection reaches the
 * daemon, so whatever it looks up in the bootstrap namespace is the missing
 * link. Every lookup in this process is logged while
 * /private/var/vm/bt-lookup exists; the tuple's replacee is the real
 * implementation, which dlsym(RTLD_NEXT) could not reach in the daemon's case.
 */
static int mondrian_bt_lookup_armed = -1;

static int
mondrian_bt_lookup_on(void)
{
	if (mondrian_bt_lookup_armed < 0) {
		mondrian_bt_lookup_armed =
		    access("/private/var/vm/bt-lookup", F_OK) == 0;
	}
	return mondrian_bt_lookup_armed;
}

static kern_return_t
mondrian_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *port)
{
	static int budget = 300;
	kern_return_t (*real)(mach_port_t, const char *, mach_port_t *);
	kern_return_t result;

	real = (kern_return_t (*)(mach_port_t, const char *,
	    mach_port_t *))mondrian_bootstrap_interpose.replacee;
	result = real != NULL ? real(bp, name, port) : (kern_return_t)5;
	if (mondrian_bt_lookup_on() && budget > 0 && name != NULL) {
		budget--;
		mondrian_probe_fmt("MONDRIAN BSL: %s -> %d port %u\n", name,
		    result, port != NULL ? *port : 0);
	}
	return result;
}

/* Not in this SDK's bootstrap.h; the interpose tuple needs the symbol. */
extern kern_return_t bootstrap_look_up2(mach_port_t, const char *,
    mach_port_t *, pid_t, uint64_t) __attribute__((weak_import));

static kern_return_t
mondrian_bootstrap_look_up2(mach_port_t bp, const char *name, mach_port_t *port,
    pid_t target, uint64_t flags)
{
	static int budget = 300;
	kern_return_t (*real)(mach_port_t, const char *, mach_port_t *, pid_t,
	    uint64_t);
	kern_return_t result;

	real = (kern_return_t (*)(mach_port_t, const char *, mach_port_t *, pid_t,
	    uint64_t))mondrian_bootstrap_look_up2_interpose.replacee;
	result = real != NULL ? real(bp, name, port, target, flags) :
	    (kern_return_t)5;
	if (mondrian_bt_lookup_on() && budget > 0 && name != NULL) {
		budget--;
		mondrian_probe_fmt("MONDRIAN BSL2: %s -> %d port %u\n", name,
		    result, port != NULL ? *port : 0);
	}
	return result;
}

/*
 * The attach returns 9 without a single bootstrap lookup and without a TCC
 * preflight, which leaves the capability query: MobileGestalt is what tells a
 * client whether this hardware has Bluetooth at all, and a "no" there is a
 * local refusal with no IPC to see. Logged for keys that mention it while the
 * same marker is set.
 */
extern Boolean MGGetBoolAnswer(CFStringRef) __attribute__((weak_import));
extern CFTypeRef MGCopyAnswer(CFStringRef) __attribute__((weak_import));

static const struct mondrian_interpose mondrian_mg_bool_interpose;
static const struct mondrian_interpose mondrian_mg_copy_interpose;

static int
mondrian_mg_interesting(const char *name)
{
	return name != NULL && (strstr(name, "luetooth") != NULL ||
	    strstr(name, "BT") != NULL || strstr(name, "bt") != NULL);
}

static Boolean
mondrian_mg_bool(CFStringRef key)
{
	static int budget = 200;
	Boolean (*real)(CFStringRef) = (Boolean (*)(CFStringRef))
	    mondrian_mg_bool_interpose.replacee;
	Boolean result = real != NULL ? real(key) : 0;
	const char *name = key != NULL ?
	    [(__bridge NSString *)key UTF8String] : NULL;

	if (mondrian_bt_lookup_on() && budget > 0 &&
	    mondrian_mg_interesting(name)) {
		budget--;
		mondrian_probe_fmt("MONDRIAN MG: bool %s -> %d\n", name, result);
	}
	return result;
}

static CFTypeRef
mondrian_mg_copy(CFStringRef key)
{
	static int budget = 200;
	CFTypeRef (*real)(CFStringRef) = (CFTypeRef (*)(CFStringRef))
	    mondrian_mg_copy_interpose.replacee;
	CFTypeRef result = real != NULL ? real(key) : NULL;
	const char *name = key != NULL ?
	    [(__bridge NSString *)key UTF8String] : NULL;

	if (mondrian_bt_lookup_on() && budget > 0 &&
	    mondrian_mg_interesting(name)) {
		budget--;
		mondrian_probe_fmt("MONDRIAN MG: copy %s -> %p\n", name, result);
	}
	return result;
}

/*
 * A client framework that gates its attach on an entitlement would refuse a
 * process that lacks it without any IPC, which is exactly the measured
 * behaviour. Under the same marker this answers every com.apple.bluetooth*
 * query with true, so the next attach says whether that was the gate.
 */
extern CFTypeRef SecTaskCopyValueForEntitlement(void *, CFStringRef,
    CFErrorRef *) __attribute__((weak_import));

static const struct mondrian_interpose mondrian_sectask_interpose;

static CFTypeRef
mondrian_sectask_entitlement(void *task, CFStringRef entitlement,
    CFErrorRef *error)
{
	CFTypeRef (*real)(void *, CFStringRef, CFErrorRef *);
	CFTypeRef value;
	const char *name = entitlement != NULL ?
	    [(__bridge NSString *)entitlement UTF8String] : NULL;

	real = (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))
	    mondrian_sectask_interpose.replacee;
	value = real != NULL ? real(task, entitlement, error) : NULL;
	if (name != NULL && strncmp(name, "com.apple.bluetooth", 18) == 0 &&
	    mondrian_bt_lookup_on()) {
		int granted = value != NULL &&
		    CFGetTypeID(value) == CFBooleanGetTypeID() &&
		    CFBooleanGetValue(value);

		if (!granted) {
			mondrian_probe_fmt("MONDRIAN ENT: %s forced\n", name);
			if (value != NULL) {
				CFRelease(value);
			}
			value = CFRetain(kCFBooleanTrue);
		}
	}
	return value;
}

/*
 * The attach gate, decoded from MobileBluetooth's BTSessionAttachWithQueue:
 * IOServiceNameMatching("marconi-bt"), then IOServiceGetMatchingService, and a
 * second name if the first finds nothing; both failing returns 9 before any
 * IPC. This port's kernel publishes no such node (the bluetoothd shim already
 * answers the same two calls for the daemon), so the hook answers them here
 * too: the service is a bare Mach port and the property read supplies the
 * address the daemon also uses.
 */
static io_service_t mondrian_bt_service;
static const uint8_t mondrian_bt_mac[6] = {
	0xb1, 0x80, 0xed, 0x2e, 0xed, 0x13,
};

static const struct mondrian_interpose mondrian_io_service_interpose;
static const struct mondrian_interpose mondrian_io_property_interpose;

static int
mondrian_bt_matching(CFDictionaryRef matching)
{
	static const CFStringRef keys[] = { CFSTR("IONameMatch") };
	unsigned int index;

	if (matching == NULL ||
	    CFGetTypeID(matching) != CFDictionaryGetTypeID()) {
		return 0;
	}
	for (index = 0; index < 2; index++) {
		CFStringRef name = index == 0 ?
		    (CFStringRef)CFDictionaryGetValue(matching,
		    CFSTR("IONameMatch")) :
		    (CFStringRef)CFDictionaryGetValue(matching,
		    CFSTR("IOProviderClass"));
		char text[32];

		(void)keys;
		if (name == NULL || CFGetTypeID(name) != CFStringGetTypeID() ||
		    !CFStringGetCString(name, text, sizeof(text),
		    kCFStringEncodingUTF8)) {
			continue;
		}
		if (strcmp(text, "marconi-bt") == 0 ||
		    strcmp(text, "bluetooth") == 0) {
			return 1;
		}
	}
	return 0;
}

static io_service_t
mondrian_io_service_get(mach_port_t main_port, CFDictionaryRef matching)
{
	io_service_t (*real)(mach_port_t, CFDictionaryRef);
	io_service_t service = 0;

	real = (io_service_t (*)(mach_port_t, CFDictionaryRef))
	    mondrian_io_service_interpose.replacee;
	/*
	 * /private/var/vm/bt-iokit keeps the synthetic answer for a boot without
	 * the device-tree node; with the node in the ADT the real registry is
	 * what has to be measured, so the default is to pass through.
	 */
	if (real == NULL || !mondrian_file_on("/private/var/vm/bt-iokit")) {
		return real != NULL ? real(main_port, matching) : 0;
	}
	if (!mondrian_bt_matching(matching)) {
		return real(main_port, matching);
	}
	if (mondrian_bt_service != 0) {
		return mondrian_bt_service;
	}
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &service) != KERN_SUCCESS) {
		return 0;
	}
	if (mach_port_insert_right(mach_task_self(), service, service,
	    MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
		mondrian_probe_fmt("MONDRIAN IOKIT: no send right\n");
	}
	mondrian_bt_service = service;
	mondrian_probe_fmt("MONDRIAN IOKIT: synthetic bluetooth service %u\n",
	    mondrian_bt_service);
	return mondrian_bt_service;
}

static CFTypeRef
mondrian_io_property(io_registry_entry_t entry, const char *plane,
    CFStringRef key, CFAllocatorRef allocator, IOOptionBits options)
{
	CFTypeRef (*real)(io_registry_entry_t, const char *, CFStringRef,
	    CFAllocatorRef, IOOptionBits);

	if (entry != mondrian_bt_service) {
		real = (CFTypeRef (*)(io_registry_entry_t, const char *,
		    CFStringRef, CFAllocatorRef, IOOptionBits))
		    mondrian_io_property_interpose.replacee;
		return real != NULL ? real(entry, plane, key, allocator,
		    options) : NULL;
	}
	if (key == NULL) {
		return NULL;
	}
	if (CFEqual(key, CFSTR("local-mac-address"))) {
		return CFDataCreate(allocator, mondrian_bt_mac,
		    sizeof(mondrian_bt_mac));
	}
	return NULL;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_io_service_interpose = {
	(const void *)mondrian_io_service_get,
	(const void *)IOServiceGetMatchingService,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_io_property_interpose = {
	(const void *)mondrian_io_property,
	(const void *)IORegistryEntrySearchCFProperty,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_sectask_interpose = {
	(const void *)mondrian_sectask_entitlement,
	(const void *)SecTaskCopyValueForEntitlement,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_bootstrap_interpose = {
	(const void *)mondrian_bootstrap_look_up,
	(const void *)bootstrap_look_up,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_bootstrap_look_up2_interpose = {
	(const void *)mondrian_bootstrap_look_up2,
	(const void *)bootstrap_look_up2,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_mg_bool_interpose = {
	(const void *)mondrian_mg_bool,
	(const void *)MGGetBoolAnswer,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_mg_copy_interpose = {
	(const void *)mondrian_mg_copy,
	(const void *)MGCopyAnswer,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_sbx_interpose = {
	(const void *)mondrian_sbx_path,
	(const void *)sandbox_container_path_for_pid,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_sbx_consume_interpose = {
	(const void *)mondrian_sbx_consume,
	(const void *)sandbox_extension_consume,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_tcc_preflight_interpose = {
	(const void *)mondrian_tcc_preflight,
	(const void *)TCCAccessPreflight,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_tcc_token_interpose = {
	(const void *)mondrian_tcc_token,
	(const void *)TCCAccessCheckAuditToken,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_tcc_preflight_token_interpose = {
	(const void *)mondrian_tcc_preflight_token,
	(const void *)TCCAccessPreflightWithAuditToken,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_tcc_request_interpose = {
	(const void *)mondrian_tcc_request,
	(const void *)TCCAccessRequest,
};

extern void
__ZNKSt3__14__fs10filesystem4path18lexically_relativeERKS2_(void *ret,
    const void *self, const void *arg) __attribute__((weak_import));

static const struct mondrian_interpose mondrian_lexrel_interpose;

static void
mondrian_lexrel(void *ret, const void *self, const void *arg)
{
	static int told;
	void (*original)(void *, const void *, const void *) =
	    (void (*)(void *, const void *, const void *))
	    mondrian_lexrel_interpose.replacee;

	if (told++ < 8) {
		mondrian_probe_fmt(
		    "MONDRIAN LEXREL[%d]: self '%s' base '%s' caller %p\n",
		    getpid(), mondrian_cxx_string(self),
		    mondrian_cxx_string(arg), __builtin_return_address(0));
	}
	if (original != NULL) {
		original(ret, self, arg);
	}
}

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_lexrel_interpose = {
	(const void *)mondrian_lexrel,
	(const void *)__ZNKSt3__14__fs10filesystem4path18lexically_relativeERKS2_,
};

/*
 * The throw hook: `mondrian_throw` reads `name`/`reason` on the thrower's own
 * stack and calls the real objc_exception_throw afterwards. Its original comes
 * from the tuple for the reason written above `mondrian_sbx_path`: dlsym on an
 * interposed symbol answers with the replacement.
 */
__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose mondrian_throw_interpose = {
	(const void *)mondrian_throw,
	(const void *)objc_exception_throw,
};

/*
 * The check that kills assetsd, read off the binary:
 * `-[PLPlatformLibraryServicesDelegate commonBuiltInOperations]_block_invoke_3`
 * asks `-[PLPrivacy photosAccessAllowedWithScope:7]` and raises
 * "assetsd requires TCCPhotosService access" when the answer is true. The class
 * is in AssetsLibraryServices, the instance comes from +sharedInstance, and
 * scope 7 is the only argument: the whole exception is one BOOL. Measured
 * 2026-11-18: reading that BOOL as an object made assetsd die `sig 11` instead of
 * `sig 6`, which is what proved the return type. The line says which way the
 * check went; forcing NO answers whether this check alone gates the library.
 * Switch: /private/var/vm/mondrian-tccforce.
 */
static BOOL (*mondrian_privacy_original)(id, SEL, long long);
static long long (*mondrian_privacy_status_original)(id, SEL, long long);
static int mondrian_tcc_ask(CFStringRef service);

/*
 * The number the public API is made of: `+[PHPhotoLibrary
 * authorizationStatusForAccessLevel:]` answers 2 (denied) for read-write and 1
 * (restricted) for add-only here, and a change request is then refused with
 * `PHPhotosErrorAccessRestricted` before it ever leaves the process -- the error
 * carries no underlying error. This is the same stand-in answering the same
 * question one level lower, and it prints the original so the mapping from
 * scope to status stays measured.
 */
static long long
mondrian_privacy_status(id self, SEL _cmd, long long scope)
{
	long long answer = mondrian_privacy_status_original(self, _cmd, scope);
	static int told;

	if (told++ < 8) {
		mondrian_probe_fmt("MONDRIAN PLSTATUS[%d]: scope %lld -> %lld\n",
		    getpid(), scope, answer);
	}
	if (mondrian_tcc_standin()) {
		return 3; /* PHAuthorizationStatusAuthorized */
	}
	return answer;
}

static BOOL
mondrian_privacy_access(id self, SEL _cmd, long long scope)
{
	BOOL answer = mondrian_privacy_original(self, _cmd, scope);
	int preflight = mondrian_tcc_ask(CFSTR("kTCCServicePhotos"));
	int standin = mondrian_tcc_standin();
	BOOL corrected = answer;
	static int told;

	/*
	 * assetsd's own activation check asks for scope 7, its entitlement names
	 * kTCCServicePhotos, and the answer disagrees with what this port grants:
	 * tccd denies it (measured: the real preflight answers 1 even though
	 * SecTask reads the entitlement through the audit token), while the port
	 * answers TCC itself through this stand-in, the same way 0043 answers
	 * the sandbox. The line keeps both values on the record; the switch forces
	 * the answer for an A/B.
	 */
	if (answer && (preflight == 0 || standin)) {
		corrected = NO;
	}
	if (told++ < 6) {
		mondrian_probe_fmt(
		    "MONDRIAN PLPRIV[%d]: scope %lld says %s, tcc %d, standin %d, answer %s\n",
		    getpid(), scope, answer ? "not allowed" : "allowed",
		    preflight, standin, corrected ? "not allowed" : "allowed");
	}
	if (mondrian_file_on("/private/var/vm/mondrian-tccforce")) {
		return NO;
	}
	return corrected;
}

/*
 * The client switches itself into multi-library mode while the app starts, and
 * from then on the shared library refuses every change ("Calling single library
 * mode API while in multi library mode") and the per-URL door wants a
 * security-scoped bookmark this port cannot mint ("Client did not provide
 * bookmarkData"). Measured 2026-11-18: `+isMultiLibraryModeEnabled` answers 0 at
 * load and the shared library throws eight seconds later, so the app is the one
 * that flips it.
 *
 * Measured 2026-11-19: with the flip blocked, Photos dies earlier, asking for
 * `file:///var/mobile/Library/Photos/Libraries/Syndication.photoslibrary/`
 * while the path manager is still in single-library mode. The two faults are
 * the same switch seen from both sides, so the hook now lets the app flip it
 * and records the call; the throw hook names whatever fails next.
 */
static struct {
	Class cls;
	IMP original;
} mondrian_multilib[2];
static unsigned mondrian_multilib_count;

static void
mondrian_library_mode_log(id self, SEL _cmd)
{
	unsigned i;
	IMP original = NULL;

	for (i = 0; i < mondrian_multilib_count; i++) {
		if ((id)mondrian_multilib[i].cls == self) {
			original = mondrian_multilib[i].original;
			break;
		}
	}
	mondrian_probe_fmt(
	    "MONDRIAN LIBURL[%d]: enableMultiLibraryMode %s caller %p\n",
	    getpid(), class_getName((Class)self), __builtin_return_address(0));
	if (original != NULL) {
		((void (*)(id, SEL))original)(self, _cmd);
	}
	if ([(id)self respondsToSelector:
	    @selector(isMultiLibraryModeEnabled)]) {
		BOOL on = ((BOOL (*)(id, SEL))objc_msgSend)(self,
		    @selector(isMultiLibraryModeEnabled));

		mondrian_probe_fmt(
		    "MONDRIAN LIBURL[%d]: multi library now %d\n", getpid(),
		    on ? 1 : 0);
	}
}

/*
 * Which URL loses the comparison.
 *
 * Measured 2026-11-19: Photos dies `sig 6` on every launch with
 * `NSInternalInconsistencyException` "Requesting different library while in
 * single library mode", and the symbols cache puts the throw in
 * `-[PLPhotoLibraryPathManager throwMultiLibraryAPIMisuseForLibraryPath:]`
 * called from `-[PLPhotoLibraryPathManager setOrCompareLibraryURL:]` (its
 * +0xf8), reached from `-[PLPhotoLibraryBundle initWithLibraryURL:...]` and
 * `-[PLPhotoLibraryBundleController newPhotoLibraryBundleWithLibraryURL:]`.
 * The reason names no path, so one launch has to print both sides: the
 * manager's own URL and the one the bundle asks for, with the caller's address
 * for `tools/dsc-va.py`.
 */
static void (*mondrian_seturl_original)(id, SEL, id);

static void
mondrian_seturl_log(id self, SEL _cmd, id url)
{
	static int told;
	id current = nil;

	if ([self respondsToSelector:@selector(libraryURL)]) {
		current = ((id (*)(id, SEL))objc_msgSend)(self,
		    @selector(libraryURL));
	}
	if (told++ < 12) {
		mondrian_probe_fmt(
		    "MONDRIAN LIBURL[%d]: %s current %s requested %s caller %p\n",
		    getpid(), class_getName(object_getClass(self)),
		    current != nil ? [[current absoluteString] UTF8String] :
		    "(none)",
		    url != nil ? [[url absoluteString] UTF8String] : "(none)",
		    __builtin_return_address(0));
	}
	mondrian_seturl_original(self, _cmd, url);
}

static void
mondrian_install_library_hook(void)
{
	static const char *const classes[] = {
		"PHPhotoLibrary",
		"PLPhotoLibraryPathManager",
	};
	unsigned i;

	for (i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
		Class cls = objc_getClass(classes[i]);
		Method method = cls != Nil ? class_getClassMethod(cls,
		    sel_registerName("enableMultiLibraryMode")) : NULL;

		if (method != NULL && mondrian_multilib_count < 2) {
			mondrian_multilib[mondrian_multilib_count].cls = cls;
			mondrian_multilib[mondrian_multilib_count].original =
			    method_getImplementation(method);
			mondrian_multilib_count++;
			method_setImplementation(method,
			    (IMP)mondrian_library_mode_log);
		}
	}
	{
		Class pm = objc_getClass("PLPhotoLibraryPathManager");
		Method compare = pm != Nil ? class_getInstanceMethod(pm,
		    sel_registerName("setOrCompareLibraryURL:")) : NULL;

		if (compare != NULL) {
			mondrian_seturl_original = (void (*)(id, SEL, id))
			    method_setImplementation(compare,
			    (IMP)mondrian_seturl_log);
		}
	}
}

static void
mondrian_install_privacy_hook(void){
	Class cls = objc_getClass("PLPrivacy");
	Method method = cls != Nil ?
	    class_getInstanceMethod(cls,
	    sel_registerName("photosAccessAllowedWithScope:")) : NULL;
	Method status = cls != Nil ?
	    class_getInstanceMethod(cls, sel_registerName("_authStatusForScope:")) :
	    NULL;

	if (method != NULL) {
		mondrian_privacy_original = (BOOL (*)(id, SEL, long long))
		    method_setImplementation(method, (IMP)mondrian_privacy_access);
	}
	if (status != NULL) {
		mondrian_privacy_status_original =
		    (long long (*)(id, SEL, long long))
		    method_setImplementation(status, (IMP)mondrian_privacy_status);
	}
}

/*
 * Why PLPrivacy says "not allowed". Two answers are possible and they need
 * different fixes: tccd refuses the service, or PLPrivacy's own state says so
 * without asking it. This asks both in one line -- the preflight TCC exports for
 * each service assetsd's own entitlement names, and PLPrivacy's cached status.
 */
/*
 * TCC's real verdict. The port interposes `TCCAccessPreflight` and answers
 * "allowed" for these binaries because tccd denies them (measured 2026-11-18:
 * the original behind the tuple answers 1 while SecTask reads the entitlement
 * through the audit token). Answering the symbol asks the interposer, so a probe
 * that reads `preflight 0` is reading this shim, not tccd -- use
 * `mondrian_tcc_preflight_interpose.replacee` to measure the OS.
 *
 * The stand-in is on by default: the working state of Photos must not depend on
 * a file somebody seeded by hand. `/private/var/vm/mondrian-tccoff` turns it off
 * for an A/B.
 */
static int
mondrian_tcc_standin(void)
{
	return access("/private/var/vm/mondrian-tccoff", F_OK) != 0;
}

static int
mondrian_tcc_ask(CFStringRef service)
{
	int (*real)(CFStringRef, CFDictionaryRef) =
	    (int (*)(CFStringRef, CFDictionaryRef))
	    mondrian_tcc_preflight_interpose.replacee;

	if (real == NULL) {
		return -1;
	}
	return real(service, NULL);
}

static void
mondrian_tcc_status_probe(void)
{
	static const char *const services[] = {
		"kTCCServicePhotos",
		"kTCCServicePhotosAdd",
	};
	Class privacy = objc_getClass("PLPrivacy");
	id shared = privacy != Nil ?
	    ((id (*)(id, SEL))objc_msgSend)((id)privacy,
	    sel_registerName("sharedInstance")) : nil;
	unsigned i;

	for (i = 0; i < sizeof(services) / sizeof(services[0]); i++) {
		CFStringRef service = CFStringCreateWithCString(kCFAllocatorDefault,
		    services[i], kCFStringEncodingUTF8);
		int answer = mondrian_tcc_ask(service);

		mondrian_probe_fmt("MONDRIAN TCCS[%d]: %s preflight %d\n",
		    getpid(), services[i], answer);
		CFRelease(service);
	}
	/*
	 * PLPrivacy's own state, guarded: the private selectors differ between
	 * builds and an unguarded one raises in a constructor, which is a
	 * SpringBoard crash loop (measured 2026-11-18). Nothing here is owned by
	 * the caller except what CF naming says, so the cached status is copied
	 * to an int before anything else happens.
	 */
	if (shared != nil) {
		int status = -1;
		int read = -1;
		int write = -1;

		if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(shared,
		    sel_registerName("respondsToSelector:"),
		    sel_registerName("photosTCCAccessStatus"))) {
			status = ((int (*)(id, SEL))objc_msgSend)(shared,
			    sel_registerName("photosTCCAccessStatus"));
		}
		if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(shared,
		    sel_registerName("respondsToSelector:"),
		    sel_registerName("isPhotoLibraryReadAccessAllowed"))) {
			read = ((BOOL (*)(id, SEL))objc_msgSend)(shared,
			    sel_registerName("isPhotoLibraryReadAccessAllowed"));
		}
		if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(shared,
		    sel_registerName("respondsToSelector:"),
		    sel_registerName("isPhotoLibrarySharingOrModificationAllowed"))) {
			write = ((BOOL (*)(id, SEL))objc_msgSend)(shared,
			    sel_registerName("isPhotoLibrarySharingOrModificationAllowed"));
		}
		mondrian_probe_fmt(
		    "MONDRIAN TCCS[%d]: cached status %d read %d write %d\n",
		    getpid(), status, read, write);
	}
}

/*
 * What a library-services check can see. PLPrivacy answers "not allowed" while
 * the XML blob carries kTCCServicePhotos and no TCCAccess* symbol is ever
 * called, so the remaining question is whether the API a framework uses to read
 * its own entitlements agrees with csops. This asks three in one line: the XML
 * blob, the DER blob (a separate, silent path in proc_csops), and
 * SecTaskCopyValueForEntitlement on this very process.
 */
static void
mondrian_sec_probe(void)
{
	static char xml[8192];
	static char der[8192];
	CFTypeRef (*create_task)(CFAllocatorRef) =
	    (CFTypeRef (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT,
	    "SecTaskCreateFromSelf");
	CFTypeRef (*copy_value)(CFTypeRef, CFStringRef, CFErrorRef *) =
	    (CFTypeRef (*)(CFTypeRef, CFStringRef, CFErrorRef *))dlsym(
	    RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
	int nxml = csops(getpid(), 7, xml, sizeof(xml));
	int nder = csops(getpid(), 16, der, sizeof(der));
	char shown[200] = "no SecTask";
	char audited[160] = "no audit task";
	CFTypeRef (*with_token)(CFAllocatorRef, audit_token_t) =
	    (CFTypeRef (*)(CFAllocatorRef, audit_token_t))dlsym(RTLD_DEFAULT,
	    "SecTaskCreateWithAuditToken");

	if (create_task != NULL && copy_value != NULL) {
		CFTypeRef task = create_task(kCFAllocatorDefault);

		if (task != NULL) {
			CFTypeRef value = copy_value(task,
			    CFSTR("com.apple.private.tcc.allow"), NULL);

			if (value != NULL) {
				CFStringRef text = CFCopyDescription(value);
				char flat[240] = "value present";
				CFIndex used = 0;

				if (text != NULL &&
				    CFStringGetCString(text, flat, sizeof(flat),
				    kCFStringEncodingUTF8)) {
					for (used = 0; flat[used] != '\0'; used++) {
						if (flat[used] == '\n' || flat[used] == '\t') {
							flat[used] = ' ';
						}
					}
				}
				snprintf(shown, sizeof(shown), "%.150s", flat);
				if (text != NULL) {
					CFRelease(text);
				}
				CFRelease(value);
			} else {
				snprintf(shown, sizeof(shown), "nil");
			}
			CFRelease(task);
		} else {
			snprintf(shown, sizeof(shown), "no task");
		}
	}
	/*
	 * The path tccd actually uses for a client: a SecTask built from the
	 * audit token, not from self. If this one cannot see the entitlement while
	 * the self task can, the denial is the kernel answering csops_audittoken.
	 */
	if (with_token != NULL && copy_value != NULL) {
		audit_token_t token;
		mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;

		if (task_info(mach_task_self(), TASK_AUDIT_TOKEN,
		    (task_info_t)&token, &count) != KERN_SUCCESS) {
			snprintf(audited, sizeof(audited), "no token");
		} else {
			CFTypeRef task = with_token(kCFAllocatorDefault, token);

			if (task != NULL) {
				CFTypeRef value = copy_value(task,
				    CFSTR("com.apple.private.tcc.allow"), NULL);

				snprintf(audited, sizeof(audited), "%s",
				    value != NULL ? "present" : "nil");
				if (value != NULL) {
					CFRelease(value);
				}
				CFRelease(task);
			} else {
				snprintf(audited, sizeof(audited), "no task");
			}
		}
	}
	mondrian_probe_fmt("MONDRIAN SEC[%d]: xml %d der %d allow %s audit %s\n",
	    getpid(), nxml, nder, shown, audited);
}

/*
 * Opening an app from the host. A synthetic touch is delivered (the kernel logs
 * it) but the home screen's icon view does not act on it, so an icon cannot be
 * scripted into opening Photos -- Spotlight's field can be, and a tapped key
 * types its key (measured 2026-11-21). This watches a switch and asks
 * SpringBoard's own workspace, which is the entry an icon press ends in.
 * Switch: /private/var/vm/mondrian-open, holding the bundle id. Every rewrite
 * of the file -- even with the same identifier -- is a new request, so the host
 * unlocks first and then asks, and the same boot can open several apps.
 */
static void *
mondrian_open_thread(void *unused)
{
	struct timespec seen = { 0, 0 };
	char last[160] = { 0 };

	(void)unused;
	/*
	 * A marker left by an earlier boot is not a request. Measured 2026-11-21:
	 * a stale /private/var/vm/mondrian-open made every SpringBoard start call
	 * -[LSApplicationWorkspace openApplicationWithBundleID:], whose
	 * synchronous LaunchServices call holds the _LSDatabase lock while
	 * Control Center reads the same database on the main thread -- the panel
	 * never drew and the main thread sat in __ulock_wait. Prime from whatever
	 * the file holds now and let only a later change count. A repeated
	 * identical request therefore needs a new value (a URL with a fresh
	 * query, see below), which is the protocol the host already follows.
	 */
	{
		struct stat st;
		FILE *file;
		char stale[160];

		if (stat("/private/var/vm/mondrian-open", &st) == 0) {
			seen = st.st_mtimespec;
			file = fopen("/private/var/vm/mondrian-open", "r");
			if (file != NULL) {
				if (fgets(stale, sizeof(stale), file) != NULL) {
					stale[strcspn(stale, "\r\n")] = '\0';
					strlcpy(last, stale, sizeof(last));
				}
				fclose(file);
			}
		}
	}
	for (;;) {
		struct stat st;
		FILE *file;
		char bundle[160];
		id workspace;
		BOOL opened;

		sleep(3);
		if (stat("/private/var/vm/mondrian-open", &st) != 0) {
			continue;
		}
		file = fopen("/private/var/vm/mondrian-open", "r");
		if (file == NULL || fgets(bundle, sizeof(bundle), file) == NULL) {
			if (file != NULL) {
				fclose(file);
			}
			continue;
		}
		fclose(file);
		bundle[strcspn(bundle, "\r\n")] = '\0';
		if (bundle[0] == '\0') {
			continue;
		}
		/*
		 * The timestamp alone is not a request: this HFS answers a write
		 * without moving the mtime (measured 2026-11-20, the kernel logged
		 * `WFILE /private/var/vm/mondrian-open 38 bytes -> 0` and this
		 * thread never ran). The contents are the request, so a URL that
		 * carries a fresh query is a new one; the timestamp still covers a
		 * repeated bundle id.
		 */
		if (strcmp(bundle, last) == 0 &&
		    st.st_mtimespec.tv_sec == seen.tv_sec &&
		    st.st_mtimespec.tv_nsec == seen.tv_nsec) {
			continue;
		}
		strlcpy(last, bundle, sizeof(last));
		seen = st.st_mtimespec;
		workspace = ((id (*)(id, SEL))objc_msgSend)(
		    (id)objc_getClass("LSApplicationWorkspace"),
		    sel_registerName("defaultWorkspace"));
		if (strncmp(bundle, "http://", 7) == 0 ||
		    strncmp(bundle, "https://", 8) == 0) {
			/*
			 * A URL opens the page in Safari without its address bar:
			 * the USB injector cannot focus that, so a local page is
			 * the only way to tell a network failure from WebKit.
			 */
			id url = ((id (*)(id, SEL, id))objc_msgSend)(
			    (id)objc_getClass("NSURL"), sel_registerName("URLWithString:"),
			    [NSString stringWithUTF8String:bundle]);
			BOOL responds = workspace != nil &&
			    ((BOOL (*)(id, SEL, SEL))objc_msgSend)(workspace,
			    sel_registerName("respondsToSelector:"),
			    sel_registerName("openURL:withOptions:"));

			/*
			 * LSApplicationWorkspace is the thread-safe entry. UIApplication
			 * openURL: from this pthread aborts SpringBoard in a loop (sig 6,
			 * libc++abi terminate), measured 2026-11-19.
			 */
			opened = responds && url != nil &&
			    ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace,
			    sel_registerName("openURL:withOptions:"), url, nil);
		} else {
			opened = workspace != nil &&
			    ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace,
			    sel_registerName("openApplicationWithBundleID:"),
			    [NSString stringWithUTF8String:bundle]);
		}
		mondrian_probe_fmt("MONDRIAN OPEN[%d]: %s -> %d\n", getpid(), bundle,
		    opened ? 1 : 0);
	}
	return NULL;
}

/*
 * Who owns the pixels of a picture the window server shows.
 *
 * Measured 2026-11-19: the imported picture draws black, and the 800 x 600 and
 * 640 x 480 surfaces the window server shows for it read as all zero from inside
 * backboardd, with a seed of 1 -- one write lock and no colour. Every surface is
 * one IOBufferMemoryDescriptor mapped into each task that looks it up, so either
 * what filled it wrote zeros or the two mappings are not the same memory. This
 * asks every hooked process -- SpringBoard, backboardd and the app -- to look the
 * same id up and read its four corners, and lets Photos write a marker into them.
 * The marker seen from another process means the memory is shared and the fill
 * wrote nothing; the marker missing there means the mappings are not the same.
 *
 * The id arrives in /private/var/vm/mondrian-surf-id (a `wfile`), which is why
 * this polls instead of running once: the surface only exists once the server has
 * drawn the picture, and its id changes with every launch.
 */
static void *
mondrian_surface_owner(void *unused)
{
	const char *path = "/private/var/vm/mondrian-surf-id";
	const char *me = getprogname() != NULL ? getprogname() : "?";
	unsigned last = 0;

	(void)unused;
	for (;;) {
		char buf[32];
		ssize_t n;
		int fd;
		unsigned id;
		IOSurfaceRef s;

		sleep(2);
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			continue;
		}
		n = read(fd, buf, sizeof(buf) - 1);
		(void)close(fd);
		if (n <= 0) {
			continue;
		}
		buf[n] = '\0';
		id = (unsigned)strtoul(buf, NULL, 10);
		if (id == 0 || id == last) {
			continue;
		}
		last = id;
		s = IOSurfaceLookup(id);
		if (s == NULL) {
			mondrian_probe_fmt("MONDRIAN XSURF[%s]: %u not found\n", me, id);
			continue;
		}
		{
			size_t w = IOSurfaceGetWidth(s);
			size_t h = IOSurfaceGetHeight(s);
			size_t row = IOSurfaceGetBytesPerRow(s);
			size_t bpe = IOSurfaceGetBytesPerElement(s);
			unsigned fmt = (unsigned)IOSurfaceGetPixelFormat(s);
			uint32_t seed = 0;
			uint8_t quad[4][4];
			const uint8_t *base = NULL;
			unsigned i;
			int read = 0;

			memset(quad, 0, sizeof(quad));
			if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed) == 0) {
				base = IOSurfaceGetBaseAddress(s);
				if (base != NULL && bpe == 4 && w > 8 && h > 8) {
					for (i = 0; i < 4; i++) {
						size_t x = (i & 1) ? 3 * w / 4 : w / 4;
						size_t y = (i & 2) ? 3 * h / 4 : h / 4;

						memcpy(quad[i], base + row * y + x * 4, 4);
					}
					read = 1;
				}
				IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
			}
			mondrian_probe_fmt("MONDRIAN XSURF[%s]: %u %zux%zu %zu a row, format %#x, seed %u, base %d: "
			    "%02x%02x%02x%02x | %02x%02x%02x%02x | %02x%02x%02x%02x | %02x%02x%02x%02x\n", me, id, w, h,
			    row, fmt, seed, base != NULL, quad[0][0], quad[0][1], quad[0][2], quad[0][3],
			    quad[1][0], quad[1][1], quad[1][2], quad[1][3], quad[2][0], quad[2][1],
			    quad[2][2], quad[2][3], quad[3][0], quad[3][1], quad[3][2], quad[3][3]);
			if (read && strcmp(me, "MobileSlideShow") == 0 && IOSurfaceLock(s, 0, &seed) == 0) {
				uint8_t *write = IOSurfaceGetBaseAddress(s);
				static const uint8_t ink[4][4] = {
					{ 0x00, 0x00, 0xff, 0xff },     /* red, in the order of bgra memory */
					{ 0x00, 0xff, 0x00, 0xff },     /* green */
					{ 0xff, 0x00, 0x00, 0xff },     /* blue */
					{ 0x00, 0xff, 0xff, 0xff },     /* yellow */
				};

				if (write != NULL) {
					for (i = 0; i < 4; i++) {
						size_t x = (i & 1) ? 3 * w / 4 : w / 4;
						size_t y = (i & 2) ? 3 * h / 4 : h / 4;

						memcpy(write + row * y + x * 4, ink[i], 4);
					}
				}
				IOSurfaceUnlock(s, 0, &seed);
				mondrian_probe_fmt("MONDRIAN XSURF[%s]: %u wrote the four corners, seed %u\n", me, id, seed);
			}
		}
		CFRelease(s);
	}
	return NULL;
}

/*
 * The app's own gate: the library answers, the volume walk and the import.
 *
 * It has to run before the probe-service branch, which returns: MobileSlideShow
 * is one of the probe services (its extension is what dies `sig 6`), and that
 * early return is why two sessions of "the import prints nothing in the ring"
 * read like a missing hook when the hook had loaded and already left. The first
 * line says which copy is loaded and what the switch looks like from inside the
 * app's sandbox: a switch this process may not read and a missing switch are the
 * same closed gate, and only the errno tells them apart.
 */
/*
 * Does CoreGraphics fill an IOSurface on this port?
 *
 * Measured 2026-11-19 in the kernel ring: the window server creates the 640 x 480
 * surface the Library tile shows, takes one write lock on it, and the bytes are
 * all zero, while the app never touches the surface at all. The fill therefore
 * happens inside backboardd, and the two candidates are CoreGraphics drawing the
 * image into the surface and CoreAnimation's own image transfer. This settles the
 * first: the app creates a surface of the picture's size, draws the same PNG into
 * it through CGBitmapContextCreate over the surface's memory, and reads the four
 * corners back -- with the same draw into malloc'd memory as the control. Colour
 * in both clears CoreGraphics and the surface memory; colour in the control only
 * puts the fault in the surface-backed context, which is a memory or layout
 * question this port owns.
 */
static void
mondrian_cg_surface_probe(void)
{
	static const char *path = "/private/var/vm/mondrian-photo.png";
	CFMutableDictionaryRef props;
	IOSurfaceRef surface;
	CGImageSourceRef source;
	CGImageRef image;
	CGColorSpaceRef space;
	CGContextRef context;
	uint8_t *plain;
	uint8_t quad[4][4];
	uint32_t seed = 0;
	unsigned width = 640, height = 480, row = width * 4;
	int created = 0, locked = 0, drew = 0;

	if (!mondrian_file_on("/private/var/vm/mondrian-cgsurf")) {
		return;
	}
	props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (props != NULL) {
		CFNumberRef n;

#define MONDRIAN_SURF_NUM(key, value)                                          \
	do {                                                                   \
		int v = (value);                                                \
		n = CFNumberCreate(NULL, kCFNumberIntType, &v);                 \
		CFDictionarySetValue(props, CFSTR(key), n);                     \
		CFRelease(n);                                                   \
	} while (0)

		MONDRIAN_SURF_NUM("IOSurfaceWidth", width);
		MONDRIAN_SURF_NUM("IOSurfaceHeight", height);
		MONDRIAN_SURF_NUM("IOSurfaceBytesPerElement", 4);
		MONDRIAN_SURF_NUM("IOSurfaceBytesPerRow", row);
		MONDRIAN_SURF_NUM("IOSurfacePixelFormat", 'BGRA');
#undef MONDRIAN_SURF_NUM
	}
	surface = props != NULL ? IOSurfaceCreate(props) : NULL;
	if (props != NULL) {
		CFRelease(props);
	}
	if (surface == NULL) {
		mondrian_probe_fmt("MONDRIAN CGSURF[%d]: no surface\n", getpid());
		return;
	}
	created = 1;
	if (IOSurfaceLock(surface, 0, &seed) != 0) {
		mondrian_probe_fmt("MONDRIAN CGSURF[%d]: surface %u will not lock\n",
		    getpid(), IOSurfaceGetID(surface));
	} else {
		locked = 1;
	}
	source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL
	    fileURLWithPath:[NSString stringWithUTF8String:path]], NULL);
	image = source != NULL ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
	space = CGColorSpaceCreateDeviceRGB();
	if (image != NULL && locked) {
		context = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface),
		    width, height, 8, row, space,
		    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		if (context != NULL) {
			CGContextDrawImage(context, CGRectMake(0, 0, width, height),
			    image);
			CGContextFlush(context);
			CGContextRelease(context);
			drew = 1;
		}
	}
	if (drew) {
		const uint8_t *base = IOSurfaceGetBaseAddress(surface);
		unsigned i;

		for (i = 0; i < 4; i++) {
			unsigned x = (i & 1) ? 3 * width / 4 : width / 4;
			unsigned y = (i & 2) ? 3 * height / 4 : height / 4;

			memcpy(quad[i], base + (size_t)y * row + (size_t)x * 4, 4);
		}
		mondrian_probe_fmt("MONDRIAN CGSURF[%d]: surface %u %ux%u drew %d: "
		    "%02x%02x%02x%02x | %02x%02x%02x%02x | %02x%02x%02x%02x | "
		    "%02x%02x%02x%02x\n", getpid(), IOSurfaceGetID(surface), width,
		    height, drew, quad[0][0], quad[0][1], quad[0][2], quad[0][3],
		    quad[1][0], quad[1][1], quad[1][2], quad[1][3], quad[2][0],
		    quad[2][1], quad[2][2], quad[2][3], quad[3][0], quad[3][1],
		    quad[3][2], quad[3][3]);
	}
	/*
	 * The control: the same image, the same size, plain malloc'd memory. A
	 * blank surface with colour here is the surface's memory, not the draw.
	 */
	plain = calloc((size_t)height, row);
	if (plain != NULL && image != NULL) {
		context = CGBitmapContextCreate(plain, width, height, 8, row, space,
		    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
		if (context != NULL) {
			unsigned i;

			CGContextDrawImage(context, CGRectMake(0, 0, width, height),
			    image);
			CGContextFlush(context);
			for (i = 0; i < 4; i++) {
				unsigned x = (i & 1) ? 3 * width / 4 : width / 4;
				unsigned y = (i & 2) ? 3 * height / 4 : height / 4;

				memcpy(quad[i], plain + (size_t)y * row + (size_t)x * 4,
				    4);
			}
			mondrian_probe_fmt("MONDRIAN CGSURF[%d]: the control: "
			    "%02x%02x%02x%02x | %02x%02x%02x%02x | %02x%02x%02x%02x | "
			    "%02x%02x%02x%02x\n", getpid(), quad[0][0], quad[0][1],
			    quad[0][2], quad[0][3], quad[1][0], quad[1][1],
			    quad[1][2], quad[1][3], quad[2][0], quad[2][1],
			    quad[2][2], quad[2][3], quad[3][0], quad[3][1],
			    quad[3][2], quad[3][3]);
			CGContextRelease(context);
		}
		free(plain);
	}
	if (space != NULL) {
		CGColorSpaceRelease(space);
	}
	if (image != NULL) {
		CGImageRelease(image);
	}
	if (source != NULL) {
		CFRelease(source);
	}
	if (locked) {
		IOSurfaceUnlock(surface, 0, &seed);
	}
	if (created) {
		CFRelease(surface);
	}
}

/*
 * The image on its way to the window server.
 *
 * Measured 2026-11-19: the app decodes the imported picture, PhotoKit hands a
 * thumbnail back in colour, CoreGraphics fills an IOSurface from the same file in
 * colour, and the window server creates a surface of the picture's size, takes one
 * write lock, and leaves it all zero. The server has the size, so the client sent
 * an image; what is missing is the pixels. This reads the image the layer is
 * actually given, before CoreAnimation serialises it, so the two halves can be
 * told apart: colour here means the client had it and the transfer lost it, zero
 * here means the layer was handed an empty image and the fix is upstream of the
 * transfer.
 *
 * Only CGImages of a picture's size are read, and only a handful of lines, so the
 * ring stays legible.
 */
static void (*mondrian_layer_contents_orig)(id, SEL, id);
static unsigned mondrian_layer_lines;
static unsigned mondrian_layer_made;

/*
 * Pictures reach the screen as surfaces, not as CGImages.
 *
 * Measured 2026-11-19: the layer is given a 640 x 480 CGImage whose four corners
 * decode to the picture's colours, and the window server creates a surface of the
 * same size, write-locks it once and shows it all zero -- the pixels never cross
 * that transfer. The same app fills an IOSurface of the same size from the same
 * image correctly (MONDRIAN CGSURF), and a layer whose contents is that surface
 * draws the four quadrants on the glass. So on this port a client surface is the
 * path CoreAnimation can show and a CGImage is not, and this hands every picture
 * to the layer as the surface it already knows how to display.
 *
 * The switch is the off side: `/private/var/vm/mondrian-layercsurf-off` keeps the
 * CGImages as they are, for an A/B that shows the transfer failing on its own. The
 * loss itself is in CoreAnimation's server-side fill and is still the open work
 * item; this is what makes the system usable while it is.
 *
 * A surface's row must be a multiple of the kernel's 16-byte alignment, which is
 * why only widths divisible by four are converted; the rest keep their CGImage so
 * a bad stride cannot be mistaken for a bad idea.
 */
/*
 * The picture under a label that does not describe it.
 *
 * Measured 2026-11-20: the Airplane Mode knob is a 129x129 CGImage, 8 bits a
 * component, 32 bits a pixel, 544 a row, colour model 1 -- four real bytes a
 * pixel under a label that says one component. CoreGraphics draws the bytes
 * through the label, which is why the same picture drawn into a BGRA context
 * came out at 8 of 25 sampled points while the 1530x3 track next to it came
 * out with its colour. Only the label changes, and only when there are four
 * bytes a pixel to keep: a true 8-bit grey picture has a row below
 * `width * 4` and is left alone. `mondrian_wall_relabel` is the same repair for
 * the wallpaper, with an extra guard that refuses a picture whose channels are
 * equal -- the knob is white, so that guard refuses exactly the picture that
 * needs the repair.
 */
static CGImageRef
mondrian_image_drawable(CGImageRef image)
{
	CGColorSpaceRef space = CGImageGetColorSpace(image);
	CGDataProviderRef source;
	CFDataRef data;
	CGDataProviderRef provider;
	CGColorSpaceRef rgb;
	CGImageRef copy = NULL;
	CGColorSpaceModel model;

	if (space == NULL || CGImageGetBitsPerComponent(image) != 8 ||
	    CGImageGetBitsPerPixel(image) < 24 ||
	    CGImageGetBytesPerRow(image) < CGImageGetWidth(image) * 4) {
		return NULL;
	}
	model = CGColorSpaceGetModel(space);
	if (model == kCGColorSpaceModelRGB || model == kCGColorSpaceModelCMYK) {
		return NULL;
	}
	/*
	 * Rebuilt, not CGImageCreateCopyWithColorSpace: that one requires the
	 * new colour space to have the same number of components as the old
	 * one, and one (grey) to three (RGB) is exactly the change wanted here.
	 * The bytes, the alpha and the byte order are the source's own.
	 */
	source = CGImageGetDataProvider(image);
	data = source != NULL ? CGDataProviderCopyData(source) : NULL;
	if (data == NULL) {
		return NULL;
	}
	provider = CGDataProviderCreateWithCFData(data);
	rgb = CGColorSpaceCreateDeviceRGB();
	if (provider != NULL && rgb != NULL) {
		copy = CGImageCreate(CGImageGetWidth(image),
		    CGImageGetHeight(image), 8, 32, CGImageGetBytesPerRow(image),
		    rgb, CGImageGetBitmapInfo(image), provider, NULL, false,
		    kCGRenderingIntentDefault);
	}
	if (rgb != NULL) {
		CGColorSpaceRelease(rgb);
	}
	if (provider != NULL) {
		CGDataProviderRelease(provider);
	}
	CFRelease(data);
	return copy;
}

/* How many of a 7x7 grid of the surface's own memory is not zero. */
static unsigned
mondrian_surface_coverage(IOSurfaceRef surface)
{
	const uint8_t *base = IOSurfaceGetBaseAddress(surface);
	size_t row = IOSurfaceGetBytesPerRow(surface);
	size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
	unsigned found = 0, x, y;

	if (base == NULL || width == 0 || height == 0) {
		return 0;
	}
	for (y = 0; y < 7; y++) {
		for (x = 0; x < 7; x++) {
			size_t at = ((height - 1) * y / 6) * row +
			    ((width - 1) * x / 6) * 4;
			const uint8_t *p = base + at;

			if (p[0] | p[1] | p[2] | p[3]) {
				found++;
			}
		}
	}
	return found;
}

static int
mondrian_image_draw(IOSurfaceRef surface, CGImageRef image)
{
	size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
	size_t row = IOSurfaceGetBytesPerRow(surface);
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = space != NULL ? CGBitmapContextCreate(
	    IOSurfaceGetBaseAddress(surface), width, height, 8, row, space,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;

	if (space != NULL) {
		CGColorSpaceRelease(space);
	}
	if (context == NULL) {
		return 0;
	}
	CGContextDrawImage(context,
	    CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
	CGContextFlush(context);
	CGContextRelease(context);
	return 1;
}

/*
 * One surface per picture, kept while the picture is alive.
 *
 * CoreAnimation asks for the same image on every layout and state change:
 * measured 2026-11-20, one boot made 1011 surfaces and the 129x129 knob was a
 * new one ten times a second. Each conversion is a CoreGraphics draw plus a GPU
 * buffer that has to find an IOVA in backboardd, and that boot's ring carried
 * `MondrianGPU: gem_new 0x700000 refused` right beside the switch. The entry
 * holds the CGImage itself, so a recycled address cannot hand back another
 * picture's surface.
 */
#define MONDRIAN_LAYER_CACHE	8
#define MONDRIAN_LAYER_CACHE_MAX (1024u * 1024u)
static struct {
	CGImageRef image;
	IOSurfaceRef surface;
} mondrian_layer_cache[MONDRIAN_LAYER_CACHE];
static unsigned mondrian_layer_cache_next;
static unsigned mondrian_layer_hits;

/*
 * The A/B is a file and -setContents: runs thousands of times a boot, so the
 * answer is remembered for a second instead of an open() per picture. A file's
 * *existence* is the switch here, as docs/COREANIMATION_GLES.md states it, so
 * `touch` and `1` mean the same and `0` does not quietly turn the bridge on.
 */
static int
mondrian_layer_bridge_off(void)
{
	static double looked;
	static int off;
	double now = CFAbsoluteTimeGetCurrent();

	if (looked == 0.0 || now - looked > 1.0 || now < looked) {
		int fd = open("/private/var/vm/mondrian-layercsurf-off", O_RDONLY);

		looked = now;
		off = fd >= 0;
		if (fd >= 0) {
			(void)close(fd);
		}
	}
	return off;
}

static IOSurfaceRef
mondrian_image_cached(CGImageRef image)
{
	unsigned i;

	for (i = 0; i < MONDRIAN_LAYER_CACHE; i++) {
		if (mondrian_layer_cache[i].image == image &&
		    mondrian_layer_cache[i].surface != NULL) {
			return (IOSurfaceRef)CFRetain(mondrian_layer_cache[i].surface);
		}
	}
	return NULL;
}

static void
mondrian_image_remember(CGImageRef image, IOSurfaceRef surface)
{
	unsigned slot = mondrian_layer_cache_next;

	mondrian_layer_cache_next = (mondrian_layer_cache_next + 1) %
	    MONDRIAN_LAYER_CACHE;
	if (mondrian_layer_cache[slot].surface != NULL) {
		CFRelease(mondrian_layer_cache[slot].surface);
	}
	if (mondrian_layer_cache[slot].image != NULL) {
		CGImageRelease(mondrian_layer_cache[slot].image);
	}
	mondrian_layer_cache[slot].image = (CGImageRef)CFRetain(image);
	mondrian_layer_cache[slot].surface = (IOSurfaceRef)CFRetain(surface);
}

/*
 * UIKit reads a layer's contents back and expects the picture it put there.
 *
 * Measured 2026-11-21: opening Settings asserted in
 * -[_UIImageCGImageContent _initWithCGImageSource:CGImage:scale:]
 * (`_UIImageContent.m:533`, "imageRef passed is not a CGImageRef") and
 * SpringBoard aborted `sig 6` after `exec Preferences`. The render server needs
 * the surface, so the surface stays what the layer holds; `-contents` answers
 * the picture instead.
 *
 * A fixed table is the wrong home for that: SpringBoard converts hundreds of
 * layers (icons, badges, widgets), the first version kept sixteen, and an
 * evicted layer answered with its surface and asserted again. The picture now
 * hangs off the layer for as long as the layer lives, with the surface ID it
 * was made for beside it, so a layer that has moved on cannot answer with an
 * older picture. The box is a CFDictionary: its value callbacks hold the
 * CGImage, so the association only has to retain the box.
 *
 * A copied layer never went through -setContents: and has no box of its own;
 * for it the surface is rebuilt into a CGImage over its own pixels
 * (`mondrian_surface_picture`), so a copy does not answer with the surface
 * either. There is no marker to put on a surface: this port's IOSurface kernel
 * accepts `IOSurfaceSetValue` in its default selector and stores nothing, so
 * the fallback tests the 32-bit row geometry instead. CoreAnimation reads its
 * stored contents when it builds the render tree, not this accessor, so the
 * frame path keeps the surface.
 */
static char mondrian_layer_box_key;
static unsigned mondrian_layer_reads;
static unsigned mondrian_layer_copies;
static unsigned mondrian_layer_foreign;
static unsigned mondrian_picture_nolock;
static id (*mondrian_layer_contents_get_orig)(id, SEL);

static void
mondrian_layer_side_set(id layer, IOSurfaceRef surface, CGImageRef image)
{
	CFMutableDictionaryRef box;
	CFNumberRef identity;
	int32_t value = (int32_t)IOSurfaceGetID(surface);

	box = CFDictionaryCreateMutable(NULL, 2,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (box == NULL) {
		return;
	}
	CFDictionarySetValue(box, CFSTR("picture"), image);
	identity = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
	if (identity != NULL) {
		CFDictionarySetValue(box, CFSTR("surface"), identity);
		CFRelease(identity);
	}
	objc_setAssociatedObject(layer, &mondrian_layer_box_key, (id)box,
	    OBJC_ASSOCIATION_RETAIN);
	CFRelease(box);
}

/* The picture this layer was given for this surface, or NULL. */
static CGImageRef
mondrian_layer_side_get(id layer, IOSurfaceRef surface)
{
	CFDictionaryRef box = (CFDictionaryRef)objc_getAssociatedObject(layer,
	    &mondrian_layer_box_key);
	CFNumberRef identity;
	int32_t value = 0;

	if (box == NULL) {
		return NULL;
	}
	identity = (CFNumberRef)CFDictionaryGetValue(box, CFSTR("surface"));
	if (identity == NULL || !CFNumberGetValue(identity, kCFNumberSInt32Type,
	    &value) || (uint32_t)value != IOSurfaceGetID(surface)) {
		return NULL;
	}
	return (CGImageRef)CFDictionaryGetValue(box, CFSTR("picture"));
}

#define MONDRIAN_PICTURE_CACHE	8
#define MONDRIAN_PICTURE_CACHE_MAX (4u * 1024u * 1024u)
static struct {
	IOSurfaceRef surface;
	uint32_t id;
	CGImageRef picture;
} mondrian_picture_cache[MONDRIAN_PICTURE_CACHE];
static unsigned mondrian_picture_cache_next;
static pthread_mutex_t mondrian_picture_lock = PTHREAD_MUTEX_INITIALIZER;

static void
mondrian_picture_release(void *info, const void *data, size_t size)
{
	(void)data;
	(void)size;
	CFRelease((CFTypeRef)info);
}

/*
 * A CGImage over the pixels a 32-bit surface already holds. The data provider
 * holds the surface so the mapping cannot go away under the image; a layer
 * that holds a surface has no other picture to offer.
 */
static CGImageRef
mondrian_surface_picture(IOSurfaceRef surface)
{
	CGDataProviderRef provider;
	CGColorSpaceRef space;
	CGImageRef picture;
	const uint8_t *base;
	size_t width, height, row, size;
	uint32_t seed = 0, id = IOSurfaceGetID(surface);
	unsigned i;
	bool locked = false;

	pthread_mutex_lock(&mondrian_picture_lock);
	for (i = 0; i < MONDRIAN_PICTURE_CACHE; i++) {
		if (mondrian_picture_cache[i].surface == surface &&
		    mondrian_picture_cache[i].id == id &&
		    mondrian_picture_cache[i].picture != NULL) {
			picture = (CGImageRef)CFRetain(
			    mondrian_picture_cache[i].picture);
			pthread_mutex_unlock(&mondrian_picture_lock);
			return picture;
		}
	}
	pthread_mutex_unlock(&mondrian_picture_lock);

	/*
	 * The picture is a view over the surface's mapped pixels, so the lock is
	 * only there to keep a writer from moving them, never to wait for the
	 * render server. Measured 2026-11-21: this code from a main-thread reader
	 * (UIKit's image-content path) with a plain read lock left presentation
	 * frozen at `ca begin 0 commit 0` and no crash -- the lock waited for the
	 * server's hold and the commit never ran. AvoidSync never blocks, and a
	 * readback that gets a torn frame is harmless.
	 */
	if (IOSurfaceLock(surface,
	    kIOSurfaceLockReadOnly | kIOSurfaceLockAvoidSync, &seed) == 0) {
		locked = true;
	} else if (mondrian_picture_nolock++ < 4) {
		mondrian_probe_fmt("MONDRIAN LAYER[%d]: surface %u picture "
		    "read without the lock\n", getpid(), id);
	}
	base = IOSurfaceGetBaseAddress(surface);
	width = IOSurfaceGetWidth(surface);
	height = IOSurfaceGetHeight(surface);
	row = IOSurfaceGetBytesPerRow(surface);
	if (locked) {
		IOSurfaceUnlock(surface,
		    kIOSurfaceLockReadOnly | kIOSurfaceLockAvoidSync, &seed);
	}
	if (base == NULL || width == 0 || height == 0 || row < width * 4) {
		return NULL;
	}
	size = row * height;
	CFRetain(surface);
	provider = CGDataProviderCreateWithData((void *)surface, base, size,
	    mondrian_picture_release);
	if (provider == NULL) {
		CFRelease(surface);
		return NULL;
	}
	space = CGColorSpaceCreateDeviceRGB();
	picture = space != NULL ? CGImageCreate(width, height, 8, 32, row,
	    space, kCGImageAlphaPremultipliedFirst |
	    kCGBitmapByteOrder32Little, provider, NULL, false,
	    kCGRenderingIntentDefault) : NULL;
	if (space != NULL) {
		CGColorSpaceRelease(space);
	}
	CGDataProviderRelease(provider);
	if (picture == NULL) {
		return NULL;
	}
	if (size > MONDRIAN_PICTURE_CACHE_MAX) {
		return picture;
	}
	pthread_mutex_lock(&mondrian_picture_lock);
	i = mondrian_picture_cache_next++ % MONDRIAN_PICTURE_CACHE;
	if (mondrian_picture_cache[i].picture != NULL) {
		CGImageRelease(mondrian_picture_cache[i].picture);
	}
	mondrian_picture_cache[i].surface = surface;
	mondrian_picture_cache[i].id = id;
	mondrian_picture_cache[i].picture = (CGImageRef)CFRetain(picture);
	pthread_mutex_unlock(&mondrian_picture_lock);
	return picture;
}

static id
mondrian_layer_contents_get(id self, SEL cmd)
{
	id real = mondrian_layer_contents_get_orig != NULL
	    ? mondrian_layer_contents_get_orig(self, cmd) : nil;
	CGImageRef picture = NULL;
	bool rebuilt = false;

	if (real != nil && CFGetTypeID((CFTypeRef)real) == IOSurfaceGetTypeID()) {
		IOSurfaceRef surface = (IOSurfaceRef)real;

		picture = mondrian_layer_side_get(self, surface);
		if (picture != NULL) {
			picture = (CGImageRef)CFRetain(picture);
		} else {
			picture = mondrian_surface_picture(surface);
			rebuilt = picture != NULL;
		}
		if (picture == NULL && mondrian_layer_foreign++ < 4) {
			mondrian_probe_fmt("MONDRIAN LAYER[%d]: contents %zux%zu "
			    "fmt %08x is not a 32-bit picture, left a "
			    "surface\n", getpid(),
			    IOSurfaceGetWidth(surface),
			    IOSurfaceGetHeight(surface),
			    (unsigned)IOSurfaceGetPixelFormat(surface));
		}
	}
	if (picture != NULL) {
		if (rebuilt) {
			if (mondrian_layer_copies++ == 0) {
				mondrian_probe_fmt("MONDRIAN LAYER[%d]: contents "
				    "read back from a surface with no picture "
				    "on the layer, rebuilt\n", getpid());
			}
		} else if (mondrian_layer_reads++ == 0) {
			mondrian_probe_fmt("MONDRIAN LAYER[%d]: contents read "
			    "back as the picture, surface kept for the "
			    "renderer\n", getpid());
		}
		return (id)CFAutorelease(picture);
	}
	return real;
}

/*
 * `*used` is the picture that was actually drawn (the relabelled copy when one
 * was made) and `*coverage` how much of a 7x7 grid of the surface came out
 * non-zero, so the ring says whether the bridge made a picture and not only
 * whether it made a surface.
 */
static IOSurfaceRef
mondrian_image_surface(CGImageRef image, CGImageRef *used, unsigned *coverage)
{
	size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
	size_t row = (width * 4 + 15) & ~(size_t)15;
	CFMutableDictionaryRef props;
	IOSurfaceRef surface;
	CGImageRef drawable;
	uint32_t seed = 0;
	int values[5];
	const char *keys[5] = { "IOSurfaceWidth", "IOSurfaceHeight",
	    "IOSurfaceBytesPerElement", "IOSurfaceBytesPerRow",
	    "IOSurfacePixelFormat" };
	unsigned i;

	*used = image;
	*coverage = 0;
	if (width < 4 || height < 4 || row * height > 64u * 1024 * 1024) {
		return NULL;
	}
	props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (props == NULL) {
		return NULL;
	}
	values[0] = (int)width;
	values[1] = (int)height;
	values[2] = 4;
	values[3] = (int)row;
	values[4] = 'BGRA';
	for (i = 0; i < 5; i++) {
		CFStringRef key = CFStringCreateWithCString(NULL, keys[i],
		    kCFStringEncodingUTF8);
		CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType,
		    &values[i]);

		CFDictionarySetValue(props, key, number);
		CFRelease(number);
		CFRelease(key);
	}
	surface = IOSurfaceCreate(props);
	CFRelease(props);
	if (surface == NULL) {
		return NULL;
	}
	/*
	 * A copied layer holds this surface without the box `-setContents:`
	 * leaves on the original; the readback rebuilds a CGImage for a box-less
	 * layer from the surface's own pixels (mondrian_surface_picture).
	 */
	if (IOSurfaceLock(surface, 0, &seed) != 0) {
		CFRelease(surface);
		return NULL;
	}
	/*
	 * The repaired label first, the picture as it arrived second: a picture
	 * CoreGraphics cannot draw under the repaired label still gets its own
	 * attempt instead of a surface nothing was drawn into.
	 */
	drawable = mondrian_image_drawable(image);
	if (drawable != NULL) {
		*used = drawable;
		(void)mondrian_image_draw(surface, drawable);
		*coverage = mondrian_surface_coverage(surface);
	}
	if (*coverage == 0 && drawable != NULL) {
		*used = image;
		(void)mondrian_image_draw(surface, image);
		*coverage = mondrian_surface_coverage(surface);
	} else if (drawable == NULL) {
		(void)mondrian_image_draw(surface, image);
		*coverage = mondrian_surface_coverage(surface);
	}
	if (drawable != NULL) {
		CGImageRelease(drawable);
	}
	IOSurfaceUnlock(surface, 0, &seed);
	return surface;
}

static void
mondrian_layer_contents(id self, SEL cmd, id contents)
{
	IOSurfaceRef surface = NULL;

	if (contents != NULL &&
	    !mondrian_layer_bridge_off() &&
	    CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)contents;
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);

		/*
		 * Every picture, not just the ones of screen size. Measured
		 * 2026-11-20 on the Settings list: the Airplane Mode row's
		 * switch drew its track (a plain colour layer) and no knob, and
		 * the knob is a 129x129 CGImage on a 43x43 layer -- under the
		 * old 300x200 floor, so it kept the CGImage path and the window
		 * server created a 129x129 surface for it and left it zero. The
		 * floor was there to keep the ring legible, not because small
		 * pictures take a different road; the road is the same one.
		 */
		if (w >= 4 && h >= 4) {
			surface = mondrian_image_cached(image);
			if (surface != NULL) {
				if (mondrian_layer_hits++ < 4) {
					mondrian_probe_fmt("MONDRIAN LAYER[%d]: "
					    "%zux%zu as cached surface %u\n",
					    getpid(), w, h,
					    IOSurfaceGetID(surface));
				}
			} else {
				CGImageRef used = image;
				unsigned coverage = 0;

				surface = mondrian_image_surface(image, &used,
				    &coverage);
				if (surface != NULL) {
					if (IOSurfaceGetAllocSize(surface) <=
					    MONDRIAN_LAYER_CACHE_MAX) {
						mondrian_image_remember(image,
						    surface);
					}
					if (mondrian_layer_made++ < 8) {
						/*
						 * `drew N/49` is the half that
						 * was missing: a surface with
						 * no pixels and a picture with
						 * no surface drew the same.
						 */
						mondrian_probe_fmt("MONDRIAN "
						    "LAYER[%d]: %zux%zu as surface "
						    "%u bpr %zu drew %u/49%s%s\n",
						    getpid(), w, h,
						    IOSurfaceGetID(surface),
						    IOSurfaceGetBytesPerRow(surface),
						    coverage,
						    used != image ? " relabelled" : "",
						    coverage == 0 ? " empty" : "");
					}
				}
			}
			if (surface != NULL) {
				mondrian_layer_side_set(self, surface, image);
				contents = (id)surface;
			}
		}
	}
	if (mondrian_layer_contents_orig != NULL) {
		mondrian_layer_contents_orig(self, cmd, contents);
	}
	if (surface != NULL) {
		CFRelease(surface);     /* the contents retain it */
	}
	if (contents == NULL || mondrian_layer_lines >= 12 ||
	    !mondrian_file_on("/private/var/vm/mondrian-layers")) {
		return;
	}
	if (CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)contents;
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);

		if (w >= 300 && h >= 200) {
			unsigned char px[16];
			CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
			CGContextRef context = CGBitmapContextCreate(px, 2, 2, 8, 8,
			    space, kCGImageAlphaPremultipliedLast);

			memset(px, 0, sizeof(px));
			mondrian_layer_lines++;
			if (context != NULL) {
				CGContextDrawImage(context, CGRectMake(0, 0, 2, 2),
				    image);
				mondrian_probe_fmt("MONDRIAN LAYER[%d]: %zux%zu "
				    "quadrants %d,%d,%d | %d,%d,%d | %d,%d,%d | "
				    "%d,%d,%d\n", getpid(), w, h, px[0], px[1], px[2],
				    px[4], px[5], px[6], px[8], px[9], px[10],
				    px[12], px[13], px[14]);
				CGContextRelease(context);
			}
			CGColorSpaceRelease(space);
		}
	}
}

static void
mondrian_layer_probe_install(void)
{
	static int installed;
	Class layer = objc_getClass("CALayer");
	Method m = layer != NULL
	    ? class_getInstanceMethod(layer, sel_registerName("setContents:")) : NULL;

	if (installed || m == NULL) {
		return;
	}
	/*
	 * Twice would make the "original" this function itself and every
	 * picture would be converted again inside its own call. The bridge is
	 * installed from the constructor and again by Photos' probe, so the
	 * guard is what keeps that one installation.
	 */
	mondrian_layer_contents_orig = (void (*)(id, SEL, id))
	    method_setImplementation(m, (IMP)mondrian_layer_contents);
	/*
	 * And the read side: UIKit asks a layer for its contents and expects the
	 * picture (see mondrian_layer_contents_get). Installed in the same
	 * guarded place so a second call cannot chain either hook into itself.
	 */
	{
		Method get = class_getInstanceMethod(layer,
		    sel_registerName("contents"));

		if (get != NULL) {
			mondrian_layer_contents_get_orig = (id (*)(id, SEL))
			    method_setImplementation(get,
			    (IMP)mondrian_layer_contents_get);
		}
	}
	installed = 1;
}

static void
mondrian_app_probe(void)
{
	char tag[180];
	int fd;

	if (getprogname() == NULL ||
	    strcmp(getprogname(), "MobileSlideShow") != 0) {
		return;
	}
	/*
	 * The CGImage-to-surface bridge is the working state of Photos, not a
	 * probe: measured 2026-11-19, the Library tile draws its four coloured
	 * quadrants when this is installed and is black without it. It used to
	 * sit behind /private/var/vm/mondrian-import, so a boot with no seeded
	 * file lost the bridge and the tile went black -- the functional state
	 * depended on a file somebody wrote by hand. Install it for every launch
	 * of this app; the import and library probes stay behind their switch.
	 */
	mondrian_cg_surface_probe();
	mondrian_layer_probe_install();
	fd = open("/private/var/vm/mondrian-import", O_RDONLY);
	snprintf(tag, sizeof(tag),
	    "MONDRIAN APP[%d]: import open %d errno %d uid %d\n", getpid(),
	    fd >= 0, fd >= 0 ? 0 : errno, (int)geteuid());
	say(tag);
	snprintf(tag, sizeof(tag),
	    "MONDRIAN UI: hook tag cc56 uid %d prog %s built %s %s\n",
	    (int)geteuid(), getprogname(), __DATE__, __TIME__);
	say(tag);
	if (fd < 0) {
		return;
	}
	(void)close(fd);
	mondrian_library_probe();
	if (mondrian_file_on("/private/var/vm/mondrian-du")) {
		pthread_t du;

		if (pthread_create(&du, NULL, mondrian_du_report, NULL) == 0) {
			(void)pthread_detach(du);
		}
	}
	if (mondrian_file_on("/private/var/vm/mondrian-doimport")) {
		pthread_t importer;

		if (pthread_create(&importer, NULL, mondrian_import_thread,
		    NULL) == 0) {
			(void)pthread_detach(importer);
		}
	}
}

/*
 * The image list with each range, so a crash pc printed by the kernel in a
 * later boot can be matched to the image that produced it. The shared cache is
 * slid per boot, which is why the ranges have to come from the same boot as
 * the crash.
 */
static void
mondrian_dump_images(void)
{
	uint32_t count = _dyld_image_count();
	uint32_t index;

	for (index = 0; index < count; index++) {
		const struct mach_header_64 *header =
		    (const struct mach_header_64 *)_dyld_get_image_header(index);
		const char *path = _dyld_get_image_name(index);
		uint64_t text_vmaddr = 0;
		uint64_t end = 0;
		const struct load_command *command;
		uint32_t at;

		if (header == NULL || header->magic != MH_MAGIC_64) {
			continue;
		}
		command = (const struct load_command *)(header + 1);
		for (at = 0; at < header->ncmds; at++) {
			if (command->cmd == LC_SEGMENT_64) {
				const struct segment_command_64 *segment =
				    (const struct segment_command_64 *)command;

				if (strcmp(segment->segname, "__TEXT") == 0) {
					text_vmaddr = segment->vmaddr;
				}
				if (segment->vmaddr + segment->vmsize > end) {
					end = segment->vmaddr + segment->vmsize;
				}
			}
			command = (const struct load_command *)
			    ((uintptr_t)command + command->cmdsize);
		}
		if (text_vmaddr == 0) {
			continue;
		}
		mondrian_probe_fmt("MONDRIAN MAP: %p-%p %s\n", header,
		    (void *)(uintptr_t)header + (end - text_vmaddr),
		    path != NULL ? path : "?");
	}
}

__attribute__((constructor))
static void
mondrian_install_ui_hooks(void)
{
	console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	/*
	 * The icons daemon is the one process whose own wait is invisible to the
	 * fixed watch: it has no window yet, and lsd's only worker never returns
	 * while it waits for this process to answer. The probe injection cannot
	 * reach it (the hook takes the env slot first), so the dump lives here.
	 */
	if (getprogname() != NULL &&
	    strcmp(getprogname(), "iconservicesagent") == 0) {
		pthread_t demand;

		if (pthread_create(&demand, NULL, mondrian_threads_demand,
		    NULL) == 0) {
			(void)pthread_detach(demand);
		}
	}
	if (mondrian_file_on("/private/var/vm/bt-maps")) {
		mondrian_dump_images();
	}
	mondrian_throw_original = (void (*)(id))mondrian_throw_interpose.replacee;
	/*
	 * ReportCrash faults inside libc++'s filesystem path code
	 * (`path::lexically_relative`), reached through a branch the dyld shared
	 * cache pre-links, so no interposer sees the call; the faulting `this` is
	 * unreadable and changes every run, and every crash writes the report it
	 * then cannot process -- 80 spawns in ten minutes on a boot whose UI is
	 * clean. The kernel's own handler already records every crash in the ring
	 * with its pc and frame chain, so the reporter is redundant on this port
	 * while that fault stands. `mondrianreportcrash=1` in the boot arguments
	 * turns it back on for a session that needs the .ips files: a switch file
	 * cannot serve here, because one written by `wfile` is root-owned and the
	 * reporter cannot unlink it, so a stale file turns the loop back on and no
	 * later write can undo it (measured 2026-11-18: three crashes in a boot
	 * whose switch had been seeded once).
	 */
	if (getprogname() != NULL && strcmp(getprogname(), "ReportCrash") == 0 &&
	    !boot_arg_set("mondrianreportcrash=1")) {
		_exit(0);
	}
	/*
	 * A picture crosses to the window server as a surface on this port and not
	 * as a CGImage (see mondrian_layer_contents), so every process that draws
	 * one needs the bridge whatever else it is here for. backboardd is the
	 * renderer and receives render nodes, not a client's layers.
	 */
	if (getprogname() == NULL || strcmp(getprogname(), "backboardd") != 0) {
		mondrian_layer_probe_install();
	}
	if (getprogname() != NULL && strcmp(getprogname(), "SpringBoard") == 0) {
		pthread_t opener;

		if (pthread_create(&opener, NULL, mondrian_open_thread, NULL) == 0) {
			(void)pthread_detach(opener);
		}
	}
	/*
	 * The import runs inside Photos itself: adding an asset needs the photo
	 * library entitlement that the app has and SpringBoard does not.
	 */
	mondrian_app_probe();
	/*
	 * Outside the probe gate on purpose: the question is whether the kernel
	 * attaches entitlements at all, so the answer has to include the processes
	 * that have never had a problem (SpringBoard, backboardd).
	 */
	if (mondrian_file_on("/private/var/vm/mondrian-images")) {
		mondrian_ent_probe();
		mondrian_tccd_probe();
		mondrian_sec_probe();
	}
	if (mondrian_file_on("/private/var/vm/mondrian-crashsyms")) {
		mondrian_crash_syms();
	}
	/*
	 * A switch that was written and is still not seen: open() tells a missing
	 * file apart from one this process may not read. Measured 2026-11-18: a
	 * `wfile` of mondrian-ent reported 0 yet the probe never armed, so the
	 * check's own errno is part of the answer.
	 */
	if (mondrian_probe_service() ||
	    (getprogname() != NULL && strcmp(getprogname(), "SpringBoard") == 0)) {
		mondrian_install_privacy_hook();
		mondrian_install_library_hook();
		/*
		 * The status probe asks tccd for the real verdict, and on this port a
		 * process tccd will not answer for waits forever: measured
		 * 2026-11-21, iconservicesagent's constructor sat in
		 * TCCAccessPreflight -> synchronous XPC to tccd, so the daemon never
		 * reached its own main, lsd waited on it and SpringBoard's main
		 * thread waited on lsd. It is a diagnostic; a marker keeps it out of
		 * every boot.
		 */
		if (mondrian_file_on("/private/var/vm/mondrian-tccs")) {
			mondrian_tcc_status_probe();
		}
		int fd = open("/private/var/vm/mondrian-ent", O_RDONLY);

		if (fd < 0) {
			mondrian_probe_fmt("MONDRIAN ENT[%d]: mondrian-ent open -> errno %d\n",
			    getpid(), errno);
		} else {
			(void)close(fd);
		}
	}
	if (mondrian_probe_service()) {
		if (mondrian_file_on("/private/var/vm/mondrian-images")) {
			mondrian_exc_images();
		}
		if (mondrian_file_on("/private/var/vm/mondrian-exc")) {
			int quiet = mondrian_file_is("/private/var/vm/mondrian-exc", '2');
			int nourl = mondrian_file_is("/private/var/vm/mondrian-exc", '3');
			int nothing = mondrian_file_is("/private/var/vm/mondrian-exc", '4');

			/*
			 * 4: injection only. assetsd dies `sig 6` with no dylib in it
			 * and `sig 11` in its guard page with this file loaded, so the
			 * first question is whether the mere mapping is what changes
			 * its death. Answering it needs a copy that installs nothing.
			 */
			if (!nothing) {
				mondrian_exc_install(quiet);
				mondrian_probe_raise();
				/*
				 * 3: the exception handlers only, without the URL hooks.
				 * Measured 2026-11-18: assetsd dies `sig 11` in its guard
				 * page with the whole probe in place, and asking which
				 * hook does it is cheaper than guessing.
				 */
				if (!nourl) {
					mondrian_probe_urls();
				}
				if (mondrian_file_on("/private/var/vm/mondrian-urltest")) {
					mondrian_url_probe_env();
					mondrian_containers_report();
				}
				if (mondrian_file_on("/private/var/vm/mondrian-keys")) {
					mondrian_key_probe();
				}
				if (mondrian_file_on("/private/var/vm/mondrian-appex") &&
				    strcmp(getprogname(), "PhotosFileProvider") == 0) {
					mondrian_appex_report();
				}
				if (mondrian_file_on("/private/var/vm/mondrian-tcc")) {
					mondrian_tcc_report();
				}
				if (mondrian_file_on("/private/var/vm/mondrian-tccgrant")) {
					mondrian_tcc_grant();
				}
			}
		} else {
			mondrian_exc_say("MONDRIAN EXC: switch off, probe idle\n");
		}
		return;
	}
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
		    "MONDRIAN UI: hook tag cc56 uid %d prog %s built %s %s\n",
		    (int)geteuid(), getprogname(), __DATE__, __TIME__);
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
	mondrian_relabel_arm();
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
	/*
	 * The build tag: a boot that logs it proves which hook it is running.
	 * The base and size go with it, because a kernel crash record names
	 * `mh` -- the main executable -- and this dylib is loaded right behind
	 * it, so `pc - mh` only becomes an offset in this file once both are
	 * known (measured 2026-11-18: the records' "SpringBoard + 0xa4a14" sits
	 * past the end of that 0x98000-byte main executable, inside this dylib).
	 */
	{
		char tag[160];
		const struct mach_header_64 *hdr =
		    (const struct mach_header_64 *)_dyld_get_image_header(0);

		snprintf(tag, sizeof(tag),
		    "MONDRIAN UI: hook tag cc56 uid %d prog %s built %s %s\n",
		    (int)geteuid(), getprogname(), __DATE__, __TIME__);
		say(tag);
		if (hdr != NULL) {
			const struct load_command *lc =
			    (const struct load_command *)(hdr + 1);
			uint64_t size = 0;

			for (uint32_t i = 0; i < hdr->ncmds; i++) {
				if (lc->cmd == LC_SEGMENT_64) {
					const struct segment_command_64 *seg =
					    (const struct segment_command_64 *)lc;

					if (strcmp(seg->segname, "__TEXT") == 0) {
						size = seg->vmsize;
						break;
					}
				}
				lc = (const struct load_command *)
				    ((const char *)lc + lc->cmdsize);
			}
			snprintf(tag, sizeof(tag),
			    "MONDRIAN UI: image0 %p size %#llx %s\n",
			    (const void *)hdr, (unsigned long long)size,
			    _dyld_get_image_name(0) != NULL ?
			    _dyld_get_image_name(0) : "?");
			say(tag);
		}
	}
	/*
	 * The container question, answered in a process that is easy to
	 * restart and runs as the same uid as the appex.
	 */
	if (mondrian_file_on("/private/var/vm/mondrian-urltest")) {
		pthread_t thread;

		if (pthread_create(&thread, NULL, mondrian_url_test, NULL) == 0) {
			pthread_detach(thread);
		}
	}
	/*
	 * "plugin has invalid sandbox or container": build the container the app
	 * cannot get, so the next launch of the appex can be sandboxed.
	 */
	if (mondrian_file_on("/private/var/vm/mondrian-seed")) {
		mondrian_seed_container("com.apple.mobileslideshow",
		    @"8F2B1C64-7A3D-4E52-9C1B-2D9A6E4F1C30");
	}
	/*
	 * Ask launchd for the container manager by sending a message to its Mach
	 * service: the job is RunAtLoad and its name answers lookups, yet no
	 * process ever appears, so the on-demand path is the cheap way to find out
	 * whether launchd refuses to start it or nothing ever asked.
	 */
	if (mondrian_file_on("/private/var/vm/mondrian-demand")) {
		pthread_t thread;

		if (pthread_create(&thread, NULL, mondrian_demand_probe, NULL) == 0) {
			pthread_detach(thread);
		}
	}
	/*
	 * mondrianbare=1 keeps the probe and the network link but installs none
	 * of the SpringBoard swizzles. One boot with it answers whether FrontBoard
	 * deadlocks on its own or because of a hook in that path.
	 */
	if (!boot_arg_set("mondrianbare=1")) {
		install_display_diagnostic();
		if (window_server_probe_wanted()) {
			install_server_hook();
		}
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
		if (mondrian_file_on("/private/var/vm/mondrian-cm")) {
			pthread_t cm;

			if (pthread_create(&cm, NULL, mondrian_cm_thread, NULL) == 0) {
				pthread_detach(cm);
			}
		}
		if (mondrian_file_on("/private/var/vm/mondrian-xpc")) {
			pthread_t xpc;

			if (pthread_create(&xpc, NULL, mondrian_xpc_probe_thread,
			    NULL) == 0) {
				pthread_detach(xpc);
			}
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
	if (strcmp(getprogname(), "SpringBoard") == 0 &&
	    mondrian_file_on("/private/var/vm/mondrian-ps")) {
		mondrian_process_report();
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
