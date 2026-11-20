/*
 * bluetoothd's diagnostic shim, injected at exec by 0389.
 *
 * The daemon cannot log anywhere this port can read: launchd gives it
 * /dev/null, its job cannot be edited (the launchd table is load-bearing for
 * early boot, see docs/MONDIAN_WIRELESS.md), and /dev/console does not reach
 * the ring. So the shim claims descriptors 1 and 2 for the first file it can
 * open, and hands the daemon the transport it needs.
 *
 * Its failure reports leave through os_log, with formats that are messages in
 * their own right, so the `_os_log_*_impl` interposers write the ones that
 * mention Bluetooth, transport, HCI or an error to the same file. The `_exit`
 * interposer adds the status, the caller's x19/x20 and a resolved backtrace;
 * those are what named the call in `main` that gives up.
 *
 * The job runs as `mobile`, not root, so a sandboxed daemon is denied most
 * paths: /private/var/tmp answered ENOENT to `rf` after a boot whose shim
 * could not open it. The candidate list starts in mobile's own Library.
 *
 * The transport is set here rather than on the kernel's command line so that
 * changing it costs a `wfile` and a boot, not a kernel build.
 *
 * v6 adds the instrumentation the transport hunt needs and nothing else:
 * the daemon's own OI_Log calls carry their text as an os_log argument, so a
 * format like "%s" hides every message the stack prints. The argument at
 * buf+4 is the pointer to that text; reading it back turns "Searching for
 * transport", "HCI Transport is set to H4" and "FATAL ERROR - no hci driver"
 * into lines in this log. getenv, socket, connect and ioctl are interposed
 * through the raw syscall (not dlsym, which recurses through getenv) to see
 * whether the H4:POSIX driver is created at all and where it stops.
 */
#include <crt_externs.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

/* The iPhoneOS SDK used on Linux ships dispatch but not the XPC headers. */
typedef void *xpc_object_t;
typedef void *xpc_connection_t;

extern const char *xpc_dictionary_get_string(xpc_object_t dictionary,
    const char *key);
extern xpc_object_t xpc_dictionary_create(const char *const *keys,
    xpc_object_t *values, size_t count);
extern void xpc_dictionary_set_int64(xpc_object_t dictionary, const char *key,
    int64_t value);
extern void xpc_release(xpc_object_t object);
extern char *xpc_copy_description(xpc_object_t object);
extern void xpc_connection_send_message_with_reply(xpc_connection_t connection,
    xpc_object_t message, dispatch_queue_t replyq, void *handler);
extern void xpc_connection_send_message(xpc_connection_t connection,
    xpc_object_t message);
extern xpc_connection_t xpc_connection_create_mach_service(const char *name,
    dispatch_queue_t targetq, uint64_t flags);
extern void xpc_connection_set_event_handler(xpc_connection_t connection,
    void *handler);
extern void xpc_connection_resume(xpc_connection_t connection);
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);

#define TRANSPORT "H4:POSIX"
#define BAUDRATE "115200"
#define PORT "/dev/cu.bluetooth"

#define CTLIOCGINFO 0xC0644E03UL
#define PF_SYSTEM_DARWIN 32

static const char *const log_paths[] = {
	"/private/var/mobile/Library/Preferences/mondrian-bt.log",
	"/private/var/mobile/Library/Logs/mondrian-bt.log",
	"/private/var/log/mondrian-bt.log",
	"/private/var/tmp/mondrian-bt.log",
	"/dev/console",
};

/*
 * One file per executable, truncated when that executable starts: bluetoothd
 * and BlueTool both write, and a shared append-only file grew past 2 GB in a
 * boot once every cfprefsd round trip was logged. Truncating bluetoothd's copy
 * at its (once per boot) start gives a clean per-boot transcript.
 */
static const char *const bluetoothd_log =
    "/private/var/mobile/Library/Preferences/mondrian-btd.log";
static const char *const bluetool_log =
    "/private/var/mobile/Library/Preferences/mondrian-blue.log";

static const char *chosen;
static char executable[256];
static unsigned long logged_lines;

static void
bt_log(const char *fmt, ...)
{
	char line[1024];
	va_list ap;
	int n;
	size_t len;

	if (logged_lines >= 4000) {
		if (logged_lines++ % 1000 != 0) {
			return;
		}
		n = snprintf(line, sizeof(line), "mondrian-bt[%d]: capped after %lu lines\n",
		    getpid(), logged_lines);
		if (n > 0) {
			write(STDERR_FILENO, line, strlen(line));
		}
		return;
	}
	logged_lines++;
	n = snprintf(line, sizeof(line), "mondrian-bt[%d]: ", getpid());
	if (n < 0) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	len = strlen(line);
	write(STDERR_FILENO, line, len);
}

static const char *const interesting[] = {
	"Bluetooth", "bluetooth", "transport", "Transport", "HCI", "restart",
	"Switch", "switch", "failed", "Failed", "error", "Error", "driver",
	"Driver", "socket", "ioctl", "connect", "POSIX", "firmware", "Firmware",
	"OI_", "serial", "Serial",
};

static int
wanted(const char *text)
{
	size_t i;

	if (text == NULL) {
		return 0;
	}
	for (i = 0; i < sizeof(interesting) / sizeof(interesting[0]); i++) {
		if (strstr(text, interesting[i]) != NULL) {
			return 1;
		}
	}
	return 0;
}

/*
 * The first conversion in an os_log format, or 0. The daemon's OI_Log calls
 * pass "%s" (or "%{public}s") and the message pointer sits at buf+4, so a
 * leading string conversion is the case worth decoding.
 */
static char
first_conversion(const char *format)
{
	const char *p = format;

	while (*p != 0) {
		if (*p != '%') {
			p++;
			continue;
		}
		p++;
		if (*p == '%') {
			p++;
			continue;
		}
		if (*p == '{') {
			const char *end = strchr(p, '}');

			if (end == NULL) {
				return 0;
			}
			p = end + 1;
		}
		while (*p != 0 && strchr("0123456789.*+- #lhqztj", *p) != NULL) {
			p++;
		}
		return *p;
	}
	return 0;
}

static void
log_arg_string(const uint8_t *buf, unsigned size, const char *format)
{
	char text[257];
	uintptr_t pointer = 0;
	vm_size_t got = 0;
	size_t i;

	if (size < 12 || first_conversion(format) != 's') {
		return;
	}
	memcpy(&pointer, buf + 4, sizeof(pointer));
	if (pointer < 0x1000) {
		return;
	}
	if (vm_read_overwrite(mach_task_self(), (vm_address_t)pointer,
	    sizeof(text) - 1, (vm_address_t)(uintptr_t)text, &got) != KERN_SUCCESS) {
		return;
	}
	text[sizeof(text) - 1] = 0;
	for (i = 0; i < sizeof(text) - 1; i++) {
		unsigned char c = (unsigned char)text[i];

		if (c == 0) {
			break;
		}
		if (c < 0x20 && c != '\t') {
			text[i] = 0;
			break;
		}
		if (c > 0x7e) {
			text[i] = 0;
			break;
		}
	}
	if (text[0] != 0) {
		bt_log("oslog.text %s\n", text);
	}
}

static void
log_format(const char *kind, const char *format, const uint8_t *buf,
    unsigned size)
{
	char hex[3 * 25];
	unsigned i;
	size_t n = 0;

	log_arg_string(buf, size, format);
	if (!wanted(format)) {
		return;
	}
	for (i = 0; i < size && i < 24; i++) {
		n += (size_t)snprintf(hex + n, sizeof(hex) - n, "%02x",
		    buf != NULL ? buf[i] : 0);
	}
	hex[n] = 0;
	bt_log("oslog.%s %s | args %s\n", kind, format, hex);
}

#define INTERPOSE_LOG(fn, kind)						\
	static void							\
	my_##fn(void *dso, os_log_t log, os_log_type_t type,		\
	    const char *format, uint8_t *buf, unsigned size)		\
	{								\
		(void)dso; (void)log; (void)type;			\
		log_format(kind, format, buf, size);			\
	}

INTERPOSE_LOG(os_log_impl, "default")
INTERPOSE_LOG(os_log_error_impl, "error")
INTERPOSE_LOG(os_log_fault_impl, "fault")
INTERPOSE_LOG(os_log_debug_impl, "debug")

static char **
environment(void)
{
	return *_NSGetEnviron();
}

/*
 * getenv by hand: dlsym(RTLD_NEXT, "getenv") from an interposed getenv runs
 * back through dlsym's own getenv lookups and overflows the stack. Everything
 * this file logs is a BT_* name, so the scan is enough and the constructor's
 * own setenv/getenv traffic stays out of the noise.
 */
static const char *
my_getenv(const char *name)
{
	char **env;
	const char *value = NULL;

	if (name == NULL) {
		return NULL;
	}
	for (env = environment(); env != NULL && *env != NULL; env++) {
		size_t len = strlen(name);

		if (strncmp(*env, name, len) == 0 && (*env)[len] == '=') {
			value = *env + len + 1;
			break;
		}
	}
	if (strncmp(name, "BT_", 3) == 0) {
		bt_log("getenv(%s) -> %s\n", name, value != NULL ? value : "(null)");
	}
	return value;
}

struct ctl_info_32 {
	char ctl_name[96];
	uint32_t ctl_id;
};

/* sys/kern_control.h is not in every SDK this file is built against. */
struct sockaddr_ctl_32 {
	uint8_t sc_len;
	uint8_t sc_family;
	uint16_t ss_sysaddr;
	uint32_t sc_id;
	uint32_t sc_unit;
	uint32_t sc_reserved[5];
};

static int
my_socket(int domain, int type, int protocol)
{
	int fd = (int)syscall(SYS_socket, domain, type, protocol);
	int error = errno;

	if (domain == PF_SYSTEM_DARWIN) {
		bt_log("socket(PF_SYSTEM, %d, %d) -> %d errno %d\n",
		    type, protocol, fd, error);
	}
	errno = error;
	return fd;
}

static int
my_connect(int fd, const struct sockaddr *address, socklen_t length)
{
	int result = (int)syscall(SYS_connect, fd, address, length);
	int error = errno;

	if (address != NULL && address->sa_family == PF_SYSTEM_DARWIN &&
	    length >= sizeof(struct sockaddr_ctl_32)) {
		const struct sockaddr_ctl_32 *ctl =
		    (const struct sockaddr_ctl_32 *)address;

		bt_log("connect(fd %d, sc_id %u sc_unit %u) -> %d errno %d\n",
		    fd, ctl->sc_id, ctl->sc_unit, result, error);
	} else if (result != 0 && (errno == ENOENT || errno == ENODEV)) {
		bt_log("connect(fd %d family %d) -> %d errno %d\n", fd,
		    address != NULL ? address->sa_family : -1, result, error);
	}
	errno = error;
	return result;
}

static int
my_ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	void *argument;
	int result;
	int error;
	unsigned group = (unsigned)((request >> 8) & 0xff);

	va_start(ap, request);
	argument = va_arg(ap, void *);
	va_end(ap);

	if (request == CTLIOCGINFO) {
		struct ctl_info_32 *info = (struct ctl_info_32 *)argument;

		result = (int)syscall(SYS_ioctl, fd, request, argument);
		error = errno;
		bt_log("ioctl CTLIOCGINFO \"%s\" -> %d id %u errno %d\n",
		    info != NULL ? info->ctl_name : "(null)", result,
		    info != NULL ? info->ctl_id : 0, error);
		errno = error;
		return result;
	}
	result = (int)syscall(SYS_ioctl, fd, request, argument);
	if (group == 'N' || group == 't' || request == 0x800c5414UL) {
		error = errno;
		bt_log("ioctl(fd %d, %#lx) -> %d errno %d\n", fd, request,
		    result, error);
		errno = error;
	}
	return result;
}

/*
 * The BlueTool boot script fails before any socket or tty write, so the
 * firmware lookup and the com-port open are the next question. Raw syscalls
 * again: this file's own constructor opens the log through the same name.
 */
static int
interesting_path(const char *path)
{
	static const char *const names[] = {
		"bluetooth", "Bluetooth", "firmware", "Firmware", ".tlv", ".bin",
		"btwake", "uart", "/etc/", "/usr/share", "Bluetool", "bluetool",
	};

	size_t i;

	if (path == NULL) {
		return 0;
	}
	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (strstr(path, names[i]) != NULL) {
			return 1;
		}
	}
	return 0;
}

static int
my_open(const char *path, int flags, ...)
{
	va_list ap;
	mode_t mode = 0;
	int fd;
	int error;

	if ((flags & O_CREAT) != 0) {
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	fd = (int)syscall(SYS_open, path, flags, mode);
	error = errno;
	if (interesting_path(path)) {
		bt_log("open(\"%s\", %#x) -> %d errno %d\n",
		    path != NULL ? path : "(null)", flags, fd, error);
	}
	errno = error;
	return fd;
}

static int
my_access(const char *path, int mode)
{
	int result = (int)syscall(SYS_access, path, mode);
	int error = errno;

	if (interesting_path(path)) {
		bt_log("access(\"%s\", %d) -> %d errno %d\n",
		    path != NULL ? path : "(null)", mode, result, error);
	}
	errno = error;
	return result;
}

/*
 * bluetoothd asks the com.apple.BlueTool XPC service to run the built-in
 * "boot" script; that service is Apple's Broadcom loader and has no entry for
 * this chipset (its own log says getFirmwarePosForPlatform = -1), so the
 * request always fails with result 1 and the daemon stops before it opens a
 * transport. The reply the daemon wants is one key: {"result": 0}. Answer it
 * here so the daemon proceeds to the HCI init that opens the POSIX control,
 * which is the piece this port can actually serve.
 */
struct block_layout {
	void *isa;
	volatile int32_t flags;
	int32_t reserved;
	void *invoke;
	void *descriptor;
};

extern void *_Block_copy(const void *block);
extern void _Block_release(const void *block);

struct reply_context {
	void *handler;
	xpc_object_t reply;
};

static void
deliver_reply(void *context)
{
	struct reply_context *ctx = context;
	struct block_layout *block = (struct block_layout *)ctx->handler;

	if (block != NULL && block->invoke != NULL) {
		((void (*)(void *, xpc_object_t))block->invoke)(ctx->handler,
		    ctx->reply);
	}
	_Block_release(ctx->handler);
	xpc_release(ctx->reply);
	free(ctx);
}

static void
log_message(const char *what, xpc_object_t message, const char *filter)
{
	char *description;

	if (message == NULL) {
		return;
	}
	description = xpc_copy_description(message);
	if (description != NULL) {
		if (filter == NULL || strstr(description, filter) != NULL) {
			bt_log("xpc.%s %.900s\n", what, description);
		}
		free(description);
	}
}

static void
my_xpc_send(xpc_connection_t connection, xpc_object_t message)
{
	static void (*original)(xpc_connection_t, xpc_object_t);

	if (original == NULL) {
		original = (void (*)(xpc_connection_t, xpc_object_t))
		    dlsym(RTLD_NEXT, "xpc_connection_send_message");
	}
	log_message("oneway", message, "kMsgId");
	if (original != NULL) {
		original(connection, message);
	}
}

static void
my_xpc_send_with_reply(xpc_connection_t connection, xpc_object_t message,
    dispatch_queue_t replyq, void *handler)
{
	static void (*original)(xpc_connection_t, xpc_object_t, dispatch_queue_t,
	    void *);
	const char *identifier;

	if (original == NULL) {
		original = (void (*)(xpc_connection_t, xpc_object_t,
		    dispatch_queue_t, void *))dlsym(RTLD_NEXT,
		    "xpc_connection_send_message_with_reply");
	}
	log_message("send", message, "kMsgId");
	identifier = xpc_dictionary_get_string(message, "kMsgId");
	if (identifier != NULL && strcmp(identifier, "RunBuiltinScript") == 0 &&
	    handler != NULL) {
		struct reply_context *ctx = calloc(1, sizeof(*ctx));
		xpc_object_t reply = xpc_dictionary_create(NULL, NULL, 0);

		if (ctx == NULL || reply == NULL) {
			free(ctx);
			if (original != NULL) {
				original(connection, message, replyq, handler);
			}
			return;
		}
		xpc_dictionary_set_int64(reply, "result", 0);
		ctx->handler = _Block_copy(handler);
		ctx->reply = reply;
		bt_log("xpc %s -> faked result 0\n", identifier);
		dispatch_async_f(replyq != NULL ? replyq :
		    dispatch_get_global_queue(0, 0), ctx, deliver_reply);
		return;
	}
	if (original != NULL) {
		original(connection, message, replyq, handler);
	}
}

static xpc_object_t
my_xpc_send_with_reply_sync(xpc_connection_t connection, xpc_object_t message)
{
	static xpc_object_t (*original)(xpc_connection_t, xpc_object_t);
	const char *identifier;

	if (original == NULL) {
		original = (xpc_object_t (*)(xpc_connection_t, xpc_object_t))
		    dlsym(RTLD_NEXT,
		    "xpc_connection_send_message_with_reply_sync");
	}
	log_message("sync", message, "kMsgId");
	identifier = xpc_dictionary_get_string(message, "kMsgId");
	if (identifier != NULL && strcmp(identifier, "RunBuiltinScript") == 0) {
		static unsigned long fakes;
		xpc_object_t reply = xpc_dictionary_create(NULL, NULL, 0);

		if (reply != NULL) {
			xpc_dictionary_set_int64(reply, "result", 0);
			fakes++;
			if (fakes <= 5 || fakes % 200 == 0) {
				bt_log("xpc.sync %s -> faked result 0 (#%lu)\n",
				    identifier, fakes);
			}
			return reply;
		}
	}
	if (original != NULL) {
		return original(connection, message);
	}
	return NULL;
}

static void
bt_string(const char *what, uintptr_t value)
{
	char buf[129];
	vm_size_t got = 0;
	kern_return_t kr;
	size_t i;

	memset(buf, 0, sizeof(buf));
	kr = vm_read_overwrite(mach_task_self(), (vm_address_t)value,
	    sizeof(buf) - 1, (vm_address_t)(uintptr_t)buf, &got);
	if (kr != KERN_SUCCESS) {
		return;
	}
	for (i = 0; i < sizeof(buf) - 1; i++) {
		if (buf[i] < 0x20 || buf[i] > 0x7e) {
			buf[i] = 0;
			break;
		}
	}
	if (buf[0] != 0) {
		bt_log("  %s as text: \"%s\"\n", what, buf);
	}
}

static void
bt_backtrace(const char *why)
{
	void *frames[20];
	int n;
	int i;

	bt_log("%s from %p\n", why, __builtin_return_address(0));
	n = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
	for (i = 0; i < n; i++) {
		Dl_info info;

		if (dladdr(frames[i], &info) == 0 || info.dli_fname == NULL) {
			bt_log("  frame %d %p ?\n", i, frames[i]);
			continue;
		}
		bt_log("  frame %d %s + 0x%lx\n", i,
		    strrchr(info.dli_fname, '/') != NULL ?
		    strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
		    (unsigned long)((uintptr_t)frames[i] -
		    (uintptr_t)info.dli_fbase));
	}
}

static void
power_send(const char *service)
{
	xpc_connection_t connection;
	xpc_object_t message;

	connection = xpc_connection_create_mach_service(service, NULL, 0);
	if (connection == NULL) {
		bt_log("power: no connection to %s\n", service);
		return;
	}
	xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
		char *text = xpc_copy_description(event);

		bt_log("power: %s event %.200s\n", service,
		    text != NULL ? text : "?");
		free(text);
	});
	xpc_connection_resume(connection);
	message = xpc_dictionary_create(NULL, NULL, 0);
	if (message != NULL) {
		xpc_dictionary_set_int64(message, "pwrS", 5);
		xpc_connection_send_message_with_reply(connection, message,
		    dispatch_get_global_queue(0, 0), ^(xpc_object_t reply) {
			char *text = xpc_copy_description(reply);

			bt_log("power: %s reply %.200s\n", service,
			    text != NULL ? text : "?");
			free(text);
		});
		xpc_release(message);
	}
	bt_log("power: sent pwrS 5 to %s\n", service);
}

/*
 * bluetoothd only powers the chip when a client asks it to, and the Control
 * Center toggle stays inert while the daemon reports no controller, so the
 * request never arrives on its own. `_xpcSetPowerState:` reads an int64 under
 * "pwrS" and the table next to it names 5 as PoweredOn, so ask the daemon
 * itself; it answers by running BlueTool, whose reply the shim fakes, and then
 * opens the transport.
 */
static void
power_probe(void *context)
{
	(void)context;
	power_send("com.apple.bluetooth.xpc");
	power_send("com.apple.server.bluetooth");
}

static void
bt_std_string(const char *what, uintptr_t value)
{
	char buf[257];
	char *data = (char *)value;
	unsigned char flag = 0;
	vm_size_t got = 0;
	size_t i;

	if (value < 0x1000) {
		return;
	}
	/*
	 * libc++ keeps short strings inline and the long ones behind a pointer;
	 * bit 7 of the byte at +0x17 says which. The restart helper takes its
	 * context as a std::string, so this is where the text lives.
	 */
	if (vm_read_overwrite(mach_task_self(), (vm_address_t)(value + 0x17), 1,
	    (vm_address_t)(uintptr_t)&flag, &got) != KERN_SUCCESS) {
		return;
	}
	if (flag & 0x80) {
		uintptr_t p = 0;

		if (vm_read_overwrite(mach_task_self(), (vm_address_t)value,
		    sizeof(p), (vm_address_t)(uintptr_t)&p, &got) != KERN_SUCCESS ||
		    p < 0x1000) {
			return;
		}
		data = (char *)p;
	}
	if (vm_read_overwrite(mach_task_self(), (vm_address_t)data,
	    sizeof(buf) - 1, (vm_address_t)(uintptr_t)buf, &got) != KERN_SUCCESS) {
		return;
	}
	buf[sizeof(buf) - 1] = 0;
	for (i = 0; i < sizeof(buf) - 1; i++) {
		if ((unsigned char)buf[i] < 0x20 || (unsigned char)buf[i] > 0x7e) {
			buf[i] = 0;
			break;
		}
	}
	if (buf[0] != 0) {
		bt_log("  %s as std::string: \"%s\"\n", what, buf);
	}
}

/* Global on purpose: the trampoline below is assembler, and a static symbol
 * left undefined by -undefined dynamic_lookup crashes at the first call. */
void
bt_report_exit(int status, uintptr_t r19, uintptr_t r20)
{
	if (status == 0) {
		return;
	}
	bt_log("_exit(%d) x19=0x%lx x20=0x%lx\n", status,
	    (unsigned long)r19, (unsigned long)r20);
	bt_string("x19", r19);
	bt_std_string("x19", r19);
	bt_string("x20", r20);
	bt_backtrace("exit");
}

/*
 * `_exit(status)` arrives with w0 = status, and the caller's x19/x20 still
 * holding what the restart helper was given. A naked entry is the only way to
 * read them before the C prologue decides about them.
 */
__attribute__((naked, noreturn))
static void
mondrian_bt_exit(void)
{
	__asm__ volatile(
		"sub	sp, sp, #32\n"
		"stp	x19, x20, [sp, #16]\n"
		"str	w0, [sp, #8]\n"
		"mov	x1, x19\n"
		"mov	x2, x20\n"
		"ldr	w0, [sp, #8]\n"
		"bl	_bt_report_exit\n"
		"ldr	w0, [sp, #8]\n"
		"mov	x16, #1\n"
		"svc	#0x80\n"
		"brk	#0\n");
}

static const struct {
	const void *replacement;
	const void *replacee;
} interposers[] __attribute__((used, section("__DATA,__interpose"))) = {
	{ (const void *)mondrian_bt_exit, (const void *)_exit },
	{ (const void *)my_os_log_impl, (const void *)_os_log_impl },
	{ (const void *)my_os_log_error_impl, (const void *)_os_log_error_impl },
	{ (const void *)my_os_log_fault_impl, (const void *)_os_log_fault_impl },
	{ (const void *)my_os_log_debug_impl, (const void *)_os_log_debug_impl },
	{ (const void *)my_getenv, (const void *)getenv },
	{ (const void *)my_socket, (const void *)socket },
	{ (const void *)my_connect, (const void *)connect },
	{ (const void *)my_ioctl, (const void *)ioctl },
	{ (const void *)my_open, (const void *)open },
	{ (const void *)my_access, (const void *)access },
	{ (const void *)my_xpc_send_with_reply,
	    (const void *)xpc_connection_send_message_with_reply },
	{ (const void *)my_xpc_send_with_reply_sync,
	    (const void *)xpc_connection_send_message_with_reply_sync },
	{ (const void *)my_xpc_send, (const void *)xpc_connection_send_message },
};

__attribute__((constructor))
static void
mondrian_bt_init(void)
{
	struct timeval boot;
	size_t boot_len = sizeof(boot);
	const char *const *paths = log_paths;
	size_t path_count = sizeof(log_paths) / sizeof(log_paths[0]);
	const char *btd = "/bluetoothd";
	const char *tool = "/BlueTool";
	const char *log_path[2];
	unsigned path_index;
	int truncate;
	size_t i;
	int fd;
	const char *before;
	uint32_t executable_size = sizeof(executable);

	if (_NSGetExecutablePath(executable, &executable_size) != 0) {
		strlcpy(executable, "?", sizeof(executable));
	}
	if (strstr(executable, btd) != NULL) {
		log_path[0] = bluetoothd_log;
		log_path[1] = NULL;
		paths = log_path;
		path_count = 1;
		truncate = 1;
	} else if (strstr(executable, tool) != NULL) {
		log_path[0] = bluetool_log;
		log_path[1] = NULL;
		paths = log_path;
		path_count = 1;
		truncate = 1;
	} else {
		truncate = 0;
	}
	for (i = 0; i < path_count; i++) {
		fd = open(paths[i], O_WRONLY | O_CREAT | (truncate ? O_TRUNC : O_APPEND),
		    0666);
		if (fd >= 0) {
			chosen = paths[i];
			chmod(chosen, 0666);
			dup2(fd, STDOUT_FILENO);
			dup2(fd, STDERR_FILENO);
			if (fd > STDERR_FILENO) {
				close(fd);
			}
			break;
		}
	}
	before = getenv("BT_HCI_TRANSPORT");
	setenv("BT_HCI_TRANSPORT", TRANSPORT, 1);
	setenv("BT_BAUDRATE", BAUDRATE, 1);
	/*
	 * A file descriptor is fully buffered, and the daemon leaves through
	 * _exit, which discards the buffer: with buffering on, the log ends at
	 * whatever the last 4 KB flush happened to catch (measured 2026-11-20).
	 */
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	if (sysctlbyname("kern.boottime", &boot, &boot_len, NULL, 0) != 0) {
		boot.tv_sec = 0;
	}
	bt_log("init v12 %s uid %d log \"%s\" boot %ld inherited \"%s\" "
	    "transport \"%s\" baud \"%s\" port %d\n",
	    executable,
	    getuid(),
	    chosen != NULL ? chosen : "(none)",
	    (long)boot.tv_sec,
	    before != NULL ? before : "(null)",
	    getenv("BT_HCI_TRANSPORT") != NULL ? getenv("BT_HCI_TRANSPORT") : "(null)",
	    getenv("BT_BAUDRATE") != NULL ? getenv("BT_BAUDRATE") : "(null)",
	    access(PORT, F_OK));
	if (strstr(executable, btd) != NULL) {
		dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 6000000000LL),
		    dispatch_get_global_queue(0, 0), NULL, power_probe);
	}
}
