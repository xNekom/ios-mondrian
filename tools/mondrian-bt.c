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
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <mach/thread_act.h>
#include <objc/message.h>
#include <objc/runtime.h>
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
#include <sys/uio.h>
#include <unistd.h>

/* The iPhoneOS SDK used on Linux ships dispatch but not the XPC headers. */
typedef void *xpc_object_t;
typedef void *xpc_connection_t;

/*
 * IOKit and CoreFoundation declarations by hand: the uid-501 daemon cannot
 * read the device tree through this port's IOKit yet, so the shim answers the
 * two lookups main() makes for the controller address (see
 * my_io_registry_search below). Types follow <IOKit/IOKitLib.h>.
 */
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;
typedef uint32_t IOOptionBits;
extern io_service_t IOServiceGetMatchingService(mach_port_t mainPort,
    CFDictionaryRef matching);
extern CFTypeRef IORegistryEntrySearchCFProperty(io_registry_entry_t entry,
    const char *plane, CFStringRef key, CFAllocatorRef allocator,
    IOOptionBits options);
extern CFPropertyListRef _CFPreferencesCopyAppValue(CFStringRef key,
    CFStringRef application);

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
extern void xpc_dictionary_set_string(xpc_object_t dictionary, const char *key,
    const char *value);
extern const void *xpc_get_type(xpc_object_t object);
extern const char *xpc_connection_get_name(xpc_connection_t connection);
extern int bootstrap_look_up(mach_port_t bootstrap_port,
    const char *service_name, mach_port_t *service_port);
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);

/*
 * The third token is the control name the POSIX driver resolves with
 * CTLIOCGINFO. "com.apple.uart.sk.bluetooth" would select the Skywalk path,
 * which aborts without a nexus (this kernel has no Skywalk); any other name
 * keeps the driver on termios plus read/write over the control socket
 * (measured 2026-11-20).
 */
#define TRANSPORT "H4:POSIX:com.mondrian.btuart"
#define BAUDRATE "115200"
#define PORT "/dev/cu.bluetooth"

#define CTLIOCGINFO 0xC0644E03UL
#define PF_SYSTEM_DARWIN 32
#define SYSPROTO_CONTROL_DARWIN 2

/*
 * The daemon's PF_SYSTEM control socket, remembered so read() can hide the
 * controller's HCI-IBS bytes from Apple's H4 parser (see my_read).
 */
static int control_socket_fd = -1;

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

/*
 * Why a run ends is invisible in the main log: `logged_lines` stops the
 * diagnostics and the daemon restarts every ~16 s, so only the first packets
 * of a run survive. Keep the last few HCI writes and reads instead and print
 * them inside the exit report, which is written by the `_exit` interposer
 * before the process goes away. The packet that ends a run is then always in
 * that report, which is the one file that outlives the restart.
 */
#define BT_RING_DEPTH 16

struct bt_ring_entry {
	uint8_t data[32];
	size_t len;
};

static struct bt_ring_entry bt_tx_ring[BT_RING_DEPTH];
static struct bt_ring_entry bt_rx_ring[BT_RING_DEPTH];
static unsigned bt_tx_ring_pos;
static unsigned bt_rx_ring_pos;

static void
bt_ring_record(struct bt_ring_entry *ring, unsigned *pos, const void *buf,
    size_t len)
{
	struct bt_ring_entry *entry = &ring[*pos % BT_RING_DEPTH];

	memset(entry, 0, sizeof(*entry));
	entry->len = len < sizeof(entry->data) ? len : sizeof(entry->data);
	memcpy(entry->data, buf, entry->len);
	(*pos)++;
}

static void
bt_ring_dump(const char *what, const struct bt_ring_entry *ring, unsigned pos)
{
	unsigned count = pos < BT_RING_DEPTH ? pos : BT_RING_DEPTH;
	unsigned first = pos < BT_RING_DEPTH ? 0 : pos % BT_RING_DEPTH;
	unsigned i;
	unsigned k;
	char line[200];
	int n;

	for (i = 0; i < count; i++) {
		const struct bt_ring_entry *entry =
		    &ring[(first + i) % BT_RING_DEPTH];

		n = snprintf(line, sizeof(line), "%s %zu:", what, entry->len);
		for (k = 0; k < entry->len && n > 0 &&
		    n < (int)sizeof(line) - 4; k++) {
			n += snprintf(line + n, sizeof(line) - (size_t)n,
			    " %02x", entry->data[k]);
		}
		if (n > 0 && n < (int)sizeof(line) - 1) {
			snprintf(line + n, sizeof(line) - (size_t)n, "\n");
			bt_log("%s", line);
		}
	}
}

/*
 * The power path is the one that ends in a crash, and the main log is
 * truncated by the next start (launchd restarts within a second), so these
 * lines go to their own append-only file: it survives the crash and the
 * restart, which is the only way to read what the daemon received.
 */
static void
bt_power_append(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n;
	int fd;

	n = snprintf(line, sizeof(line), "mondrian-bt[%d]: ", getpid());
	if (n < 0 || n >= (int)sizeof(line)) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	fd = open("/private/var/mobile/Library/Preferences/mondrian-bt-power.log",
	    O_WRONLY | O_CREAT | O_APPEND, 0666);
	if (fd < 0) {
		return;
	}
	(void)syscall(SYS_write, fd, line, strlen(line));
	close(fd);
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

/*
 * XNU's struct ctl_info puts ctl_id first and the name second (kern_control.h).
 * The daemon fills the name at the right offset; reading it the other way round
 * logged an empty name and id 0, and a shim that wrote the name first asked the
 * kernel for a control with an empty name and got ENOENT (measured 2026-11-20).
 */
struct ctl_info_32 {
	uint32_t ctl_id;
	char ctl_name[96];
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
		if (fd >= 0 && protocol == SYSPROTO_CONTROL_DARWIN) {
			control_socket_fd = fd;
		}
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
	static unsigned long opens;

	if ((flags & O_CREAT) != 0) {
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	fd = (int)syscall(SYS_open, path, flags, mode);
	error = errno;
	/*
	 * Every open, capped: the transport asks os_channel_create() for a
	 * resource named by the UUID it read from the control, and the path it
	 * looks for is the one fact this run needs. interesting_path() hides
	 * exactly the candidates (measured 2026-11-20).
	 */
	if (opens++ < 400) {
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
 * HCI-IBS is a wire protocol between this UART and the controller: 0xfe is the
 * controller announcing sleep, 0xfd its wake indication and 0xfc the host's
 * acknowledgement (hci_qca.c). Apple's H4 transport knows none of it, so the
 * controller's Reset response sits behind an unanswered 0xfd and the daemon
 * retries the Reset forever (measured 2026-11-20). Answer every indication and
 * keep both bytes out of the daemon's stream.
 *
 * They are only markers at an H4 packet boundary: the supported commands
 * bitmap legitimately contains 0xfe, and stripping it by value shortened the
 * 71-byte event to 70 and timed the init out (measured 2026-11-20, v50). So
 * track the H4 framing and filter only while a new packet type is expected.
 */
static int h4_state;		/* 0 = type, 1 = header, 2 = payload */
static uint8_t h4_type;
static uint8_t h4_hdr[4];
static size_t h4_hdr_need;
static size_t h4_hdr_got;
static size_t h4_left;
static size_t h4_pos;
static int h4_supported_mask;

/*
 * Apple's init chain sends 0x0c5b (Write Default Erroneous Data Reporting)
 * and refuses to continue when the controller's supported commands mask does
 * not advertise it. The patched WCN7850 firmware reports byte 0x12 = 0x83,
 * i.e. bit 3 clear (measured 2026-11-20, both with and without the NVM), so
 * the shim advertises it in transit and answers the command itself below.
 */
static uint8_t inject_buf[64];
static volatile size_t inject_len;
static volatile size_t inject_off;

static void
inject_event(const uint8_t *event, size_t len)
{
	if (len > sizeof(inject_buf)) {
		return;
	}
	memcpy(inject_buf, event, len);
	inject_off = 0;
	inject_len = len;
}

static ssize_t
my_read(int fd, void *buf, size_t len)
{
	uint8_t raw[256];
	uint8_t *out = buf;
	size_t produced = 0;
	static unsigned int reads;

	if (fd != control_socket_fd || control_socket_fd < 0 || len == 0) {
		return (ssize_t)syscall(SYS_read, fd, buf, len);
	}
	while (produced < len) {
		size_t want;
		ssize_t got;
		size_t i;

		if (h4_state == 0 && inject_off < inject_len) {
			size_t take = inject_len - inject_off;

			if (take > len - produced) {
				take = len - produced;
			}
			memcpy(out + produced, inject_buf + inject_off, take);
			produced += take;
			inject_off += take;
			if (inject_off == inject_len) {
				inject_off = 0;
				inject_len = 0;
			}
			break;
		}
		if (h4_state == 2) {
			want = h4_left;
			if (want > len - produced) {
				want = len - produced;
			}
			if (want > sizeof(raw)) {
				want = sizeof(raw);
			}
		} else if (h4_state == 1) {
			want = h4_hdr_need - h4_hdr_got;
			if (want > len - produced) {
				want = len - produced;
			}
		} else {
			/*
			 * A new packet may not have started yet; returning the
			 * bytes already framed is better than blocking on it.
			 */
			if (produced > 0) {
				break;
			}
			want = 1;
		}
		/*
		 * Polling recvfrom instead of a blocking read: the emulated
		 * vendor replies are injected by the write thread, and a read
		 * already parked in the kernel would never look at them
		 * (measured 2026-11-20, the antenna reply sat unread until the
		 * VSC timer declared a firmware crash).
		 */
		got = (ssize_t)syscall(SYS_recvfrom, fd, raw, want,
		    MSG_DONTWAIT, NULL, NULL);
		if (got <= 0) {
			if (got == 0 ||
			    (got < 0 && (errno == EAGAIN ||
			    errno == EWOULDBLOCK))) {
				if (produced > 0) {
					break;
				}
				usleep(1000);
				continue;
			}
			if (produced > 0) {
				break;
			}
			return got;
		}
		for (i = 0; i < (size_t)got && produced < len; i++) {
			uint8_t byte = raw[i];

			if (h4_state == 2) {
				if (h4_type == 0x04 && h4_hdr[0] == 0x0e) {
					if (h4_pos == 1) {
						h4_supported_mask = byte == 0x02;
					} else if (h4_pos == 2) {
						if (byte != 0x10) {
							h4_supported_mask = 0;
						}
					} else if (h4_supported_mask && h4_pos == 22) {
						byte |= 0x08;
					}
				}
				out[produced++] = byte;
				h4_pos++;
				if (--h4_left == 0) {
					h4_state = 0;
				}
				continue;
			}
			if (h4_state == 1) {
				out[produced++] = byte;
				h4_hdr[h4_hdr_got++] = byte;
				if (h4_hdr_got == h4_hdr_need) {
					if (h4_type == 0x04) {
						h4_left = h4_hdr[1];
					} else if (h4_type == 0x03) {
						h4_left = h4_hdr[2];
					} else {
						h4_left = (size_t)h4_hdr[2] |
						    ((size_t)h4_hdr[3] << 8);
					}
					h4_state = h4_left != 0 ? 2 : 0;
				}
				continue;
			}
			if (byte == 0xfd) {
				static const uint8_t ack = 0xfc;

				syscall(SYS_write, fd, &ack, 1);
				continue;
			}
			if (byte == 0xfe) {
				continue;
			}
			if (byte == 0x04 || byte == 0x02 || byte == 0x03) {
				h4_type = byte;
				h4_hdr_need = byte == 0x02 ? 4 :
				    (byte == 0x03 ? 3 : 2);
				h4_hdr_got = 0;
				h4_pos = 0;
				h4_supported_mask = 0;
				h4_state = 1;
				out[produced++] = byte;
				continue;
			}
			/* Noise at a packet boundary: not an H4 type. */
		}
		if (got < (ssize_t)want) {
			break;
		}
	}
	if (reads++ < 80) {
		const uint8_t *p = buf;
		char text[256];
		size_t n = produced < 74 ? produced : 74;
		size_t used = 0;
		size_t k;

		text[0] = 0;
		for (k = 0; k < n; k++) {
			int w = snprintf(text + used, sizeof(text) - used, " %02x",
			    p[k]);

			if (w <= 0 || (size_t)w >= sizeof(text) - used) {
				break;
			}
			used += (size_t)w;
		}
		bt_log("hci read %zu of %zu:%s\n", produced, len, text);
	}
	if (produced > 0) {
		bt_ring_record(bt_rx_ring, &bt_rx_ring_pos, buf, produced);
	}
	return (ssize_t)produced;
}

static void
log_hci_write(const char *what, const void *buf, size_t len)
{
	static unsigned int writes;
	const uint8_t *p = buf;
	char text[64];
	size_t i;
	size_t used = 0;

	if (writes++ >= 80) {
		return;
	}
	text[0] = 0;
	for (i = 0; i < len && i < 10; i++) {
		int n = snprintf(text + used, sizeof(text) - used, " %02x", p[i]);

		if (n <= 0 || (size_t)n >= sizeof(text) - used) {
			break;
		}
		used += (size_t)n;
	}
	bt_log("%s %zu:%s\n", what, len, text);
}

static ssize_t
my_write(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;

	if (fd == control_socket_fd && control_socket_fd >= 0) {
		bt_ring_record(bt_tx_ring, &bt_tx_ring_pos, buf, len);
		if (len >= 4 && p[0] == 0x01 && p[1] == 0x5b &&
		    p[2] == 0x0c) {
			static const uint8_t complete[] = {
				0x04, 0x0e, 0x04, 0x01, 0x5b, 0x0c, 0x00
			};

			/*
			 * The controller has no 0x0c5b; answering the command
			 * here keeps Apple's init chain moving. The setting only
			 * picks the default erroneous-data policy, so the
			 * controller's own default is what stays in effect.
			 */
			bt_log("hci 0x0c5b: emulated completion\n");
			inject_event(complete, sizeof(complete));
			return (ssize_t)len;
		}
		if (len >= 5 && p[0] == 0x01 && p[1] == 0xe2 &&
		    p[2] == 0xfc && p[4] == 0x15) {
			/*
			 * BD_VSC_OLYMPIC_ANTENNA_PREF_B: a Broadcom antenna
			 * preference read. The controller answers "unknown
			 * command" with no data, the BCM byte-stream parser
			 * then logs "Invalid data size 0" and declares a
			 * firmware crash (measured 2026-11-20). A success with
			 * a two-byte payload (VSC status 0, preference 0) is
			 * what the parser wants; the WCN7850 has no such
			 * preference to report.
			 */
			static const uint8_t complete[] = {
				0x04, 0x0e, 0x06, 0x01, 0xe2, 0xfc, 0x00, 0x00,
				0x00
			};

			bt_log("hci 0xfce2/15: emulated antenna pref\n");
			inject_event(complete, sizeof(complete));
			return (ssize_t)len;
		}
		if (len >= 4 && p[0] == 0x01 && p[1] == 0x1b &&
		    p[2] == 0xfd) {
			static const uint8_t complete[] = {
				0x04, 0x0e, 0x06, 0x01, 0x1b, 0xfd, 0x00, 0x00,
				0x00
			};

			/*
			 * BD_VSC_FACTORY_CAL_READ_TABLE: the WCN7850 has no
			 * Apple calibration table. An empty reply made the BCM
			 * parser log "Invalid data size 0" and the stack
			 * restart; two zero bytes are the smallest payload it
			 * accepts, and the callback then reads a zero table.
			 */
			bt_log("hci 0xfd1b: emulated factory cal\n");
			inject_event(complete, sizeof(complete));
			return (ssize_t)len;
		}
		log_hci_write("hci write", buf, len);
	}
	return (ssize_t)syscall(SYS_write, fd, buf, len);
}

static ssize_t
my_writev(int fd, const struct iovec *iov, int count)
{
	if (fd == control_socket_fd && control_socket_fd >= 0) {
		bt_log("hci writev %d iov\n", count);
	}
	return (ssize_t)syscall(SYS_writev, fd, iov, count);
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
log_connection(const char *what, xpc_connection_t connection)
{
	const char *name = NULL;

	if (connection != NULL) {
		name = xpc_connection_get_name(connection);
	}
	bt_log("xpc.conn %s %s\n", what, name != NULL ? name : "(unnamed)");
}

static void *
interposed_real(const void *replacement);

/* Present in libxpc but missing from this SDK's header. */
extern uint64_t xpc_dictionary_get_uint64(xpc_object_t, const char *);

/*
 * A client that cannot reach the daemon leaves BluetoothManager with
 * available 0, and Settings then hides the pane entirely. The traffic has to
 * be readable to tell a missing request from a rejected one: this budget keeps
 * the descriptions from crowding the rest of the log.
 */
static int xpc_description_budget = 400;

static void
log_description(const char *what, xpc_object_t message)
{
	char *description;

	if (message == NULL || xpc_description_budget <= 0) {
		return;
	}
	description = xpc_copy_description(message);
	if (description == NULL) {
		return;
	}
	xpc_description_budget--;
	bt_log("xpc.%s %.400s\n", what, description);
	free(description);
}

static void
my_xpc_send(xpc_connection_t connection, xpc_object_t message)
{
	static void (*original)(xpc_connection_t, xpc_object_t);

	if (original == NULL) {
		original = (void (*)(xpc_connection_t, xpc_object_t))
		    interposed_real((const void *)my_xpc_send);
	}
	log_connection("oneway", connection);
	log_message("oneway", message, "kMsgId");
	log_description("out", message);
	if (original != NULL) {
		original(connection, message);
	} else {
		bt_log("xpc.conn oneway: no real sender\n");
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
		    dispatch_queue_t, void *))
		    interposed_real((const void *)my_xpc_send_with_reply);
	}
	log_connection("send", connection);
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
		    interposed_real((const void *)my_xpc_send_with_reply_sync);
	}
	log_connection("sync", connection);
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
	int fd;

	if (status == 0) {
		return;
	}
	/*
	 * The main log is truncated on every start, so a run's report is gone
	 * before it can be read: the daemon leaves about every 16 s. Append the
	 * exit report to its own file instead; this runs once, at exit, so it
	 * does not disturb the run's log.
	 */
	fd = open("/private/var/mobile/Library/Preferences/mondrian-bt-exit.log",
	    O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd >= 0) {
		dup2(fd, STDOUT_FILENO);
		dup2(fd, STDERR_FILENO);
		if (fd > STDERR_FILENO) {
			close(fd);
		}
	}
	/*
	 * The logger stops after `logged_lines`; the report is what has to be
	 * written late in a run, when that counter is exhausted.
	 */
	logged_lines = 0;
	bt_log("_exit(%d) x19=0x%lx x20=0x%lx\n", status,
	    (unsigned long)r19, (unsigned long)r20);
	bt_string("x19", r19);
	bt_std_string("x19", r19);
	bt_string("x20", r20);
	bt_backtrace("exit");
	bt_ring_dump("last tx", bt_tx_ring, bt_tx_ring_pos);
	bt_ring_dump("last rx", bt_rx_ring, bt_rx_ring_pos);
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

static io_service_t
my_io_service_get(mach_port_t main_port, CFDictionaryRef matching);
static CFTypeRef
my_io_registry_search(io_registry_entry_t entry, const char *plane,
    CFStringRef key, CFAllocatorRef allocator, IOOptionBits options);
static CFPropertyListRef
my_prefs_copy(CFStringRef key, CFStringRef application);
static CFPropertyListRef
my_cf_prefs_copy(CFStringRef key, CFStringRef application);
static void
my_prefs_set(CFStringRef key, CFPropertyListRef value, CFStringRef application);
static Boolean
my_prefs_sync(CFStringRef application);
static CFPropertyListRef
my_prefs_copy_value(CFStringRef key, CFStringRef application, CFStringRef user,
    CFStringRef host);static CFDictionaryRef
my_prefs_copy_multiple(CFArrayRef keys, CFStringRef application,
    CFStringRef user, CFStringRef host);
static CFArrayRef
my_prefs_copy_keys(CFStringRef application, CFStringRef user, CFStringRef host);
static Boolean
my_prefs_get_bool(CFStringRef key, CFStringRef application, Boolean *valid);
static CFIndex
my_prefs_get_int(CFStringRef key, CFStringRef application, Boolean *valid);
static void
my_prefs_set_value(CFStringRef key, CFPropertyListRef value,
    CFStringRef application, CFStringRef user, CFStringRef host);
static int
my_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *port);

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
	{ (const void *)my_read, (const void *)read },
	{ (const void *)my_write, (const void *)write },
	{ (const void *)my_writev, (const void *)writev },
	{ (const void *)my_access, (const void *)access },
	{ (const void *)my_xpc_send_with_reply,
	    (const void *)xpc_connection_send_message_with_reply },
	{ (const void *)my_xpc_send_with_reply_sync,
	    (const void *)xpc_connection_send_message_with_reply_sync },
	{ (const void *)my_xpc_send, (const void *)xpc_connection_send_message },
	{ (const void *)my_io_service_get, (const void *)IOServiceGetMatchingService },
	{ (const void *)my_io_registry_search,
	    (const void *)IORegistryEntrySearchCFProperty },
	{ (const void *)my_cf_prefs_copy, (const void *)CFPreferencesCopyAppValue },
	{ (const void *)my_prefs_set, (const void *)CFPreferencesSetAppValue },
	{ (const void *)my_prefs_sync, (const void *)CFPreferencesAppSynchronize },
	{ (const void *)my_prefs_copy_value, (const void *)CFPreferencesCopyValue },
	{ (const void *)my_prefs_copy_multiple,
	    (const void *)CFPreferencesCopyMultiple },
	{ (const void *)my_prefs_copy_keys, (const void *)CFPreferencesCopyKeyList },
	{ (const void *)my_prefs_get_bool,
	    (const void *)CFPreferencesGetAppBooleanValue },
	{ (const void *)my_prefs_get_int,
	    (const void *)CFPreferencesGetAppIntegerValue },
	{ (const void *)my_prefs_set_value, (const void *)CFPreferencesSetValue },
	{ (const void *)my_bootstrap_look_up, (const void *)bootstrap_look_up },
};

/*
 * dyld fills the second field of each __interpose pair with the real function,
 * and that is the only reliable way to reach it from a dylib inserted at the
 * head of the image list: dlsym(RTLD_NEXT, ...) resolves forward from this
 * image and returned NULL for libxpc here, which silently dropped every XPC
 * message bluetoothd sent (measured 2026-11-20: the daemon waited forever on
 * com.apple.cfprefsd.daemon and never created its server).
 */
static void *
interposed_real(const void *replacement)
{
	unsigned int i;

	for (i = 0; i < sizeof(interposers) / sizeof(interposers[0]); i++) {
		if (interposers[i].replacement == replacement) {
			return (void *)interposers[i].replacee;
		}
	}
	return NULL;
}

/*
 * main() asks the registry for a service named "marconi-bt" or "bluetooth" and
 * reads local-mac-address from it. With no such node it prints "No bluetooth
 * on this device" and exits before it builds the server (measured 2026-11-20:
 * no CBDaemonServer, no activate, no XPC listener, and SpringBoard's
 * BluetoothManager stays "available 0"). This port's kernel publishes no
 * /arm-io/bluetooth yet, so the shim answers those two calls for those names,
 * and leaves every other IOKit lookup to the real functions. The address is
 * provisional: the real one belongs in the device-tree node, and the QCA
 * firmware/NVM carries the controller's own copy.
 */
static io_service_t synthetic_service;
static const uint8_t synthetic_mac[6] = {
	0xb1, 0x80, 0xed, 0x2e, 0xed, 0x13,
};

static int
bluetooth_matching_name(CFDictionaryRef matching)
{
	CFStringRef name;
	char text[32];

	if (matching == NULL || CFGetTypeID(matching) != CFDictionaryGetTypeID()) {
		return 0;
	}
	name = (CFStringRef)CFDictionaryGetValue(matching, CFSTR("IONameMatch"));
	if (name == NULL || CFGetTypeID(name) != CFStringGetTypeID() ||
	    !CFStringGetCString(name, text, sizeof(text), kCFStringEncodingUTF8)) {
		return 0;
	}
	return strcmp(text, "marconi-bt") == 0 || strcmp(text, "bluetooth") == 0;
}

static io_service_t
my_io_service_get(mach_port_t main_port, CFDictionaryRef matching)
{
	static io_service_t (*real)(mach_port_t, CFDictionaryRef);
	io_service_t service = 0;

	/*
	 * Do not call the real lookup for the bluetooth names: on this port it
	 * never returns (the kernel does not answer the IOKit match), and the
	 * daemon dies waiting in it before it builds the server.
	 */
	if (!bluetooth_matching_name(matching)) {
		if (real == NULL) {
			real = (io_service_t (*)(mach_port_t, CFDictionaryRef))
			    interposed_real((const void *)my_io_service_get);
		}
		return real != NULL ? real(main_port, matching) : 0;
	}
	/*
	 * A real IOService arrives with a send right, and IOObjectRelease
	 * releases it with mach_port_mod_refs(MACH_PORT_RIGHT_SEND, -1). A
	 * receive-only port makes that call an invalid-right guard violation:
	 * the kernel kills the daemon with EXC_GUARD (measured 2026-11-20,
	 * flavor 0x100, target = this port name). Give the name both rights.
	 */
	if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &service) != KERN_SUCCESS) {
		bt_log("iokit: no port for the synthetic service\n");
		return 0;
	}
	if (mach_port_insert_right(mach_task_self(), service, service,
	    MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
		bt_log("iokit: no send right for the synthetic service\n");
	}
	synthetic_service = service;
	bt_log("iokit: synthetic bluetooth service %u\n", synthetic_service);
	return synthetic_service;
}

static CFTypeRef
my_io_registry_search(io_registry_entry_t entry, const char *plane,
    CFStringRef key, CFAllocatorRef allocator, IOOptionBits options)
{
	static CFTypeRef (*real)(io_registry_entry_t, const char *, CFStringRef,
	    CFAllocatorRef, IOOptionBits);
	CFTypeRef result = NULL;
	uint32_t word;

	if (entry != synthetic_service) {
		if (real == NULL) {
			real = (CFTypeRef (*)(io_registry_entry_t, const char *,
			    CFStringRef, CFAllocatorRef, IOOptionBits))
			    interposed_real((const void *)my_io_registry_search);
		}
		return real != NULL ? real(entry, plane, key, allocator, options) : NULL;
	}
	if (key == NULL) {
		return NULL;
	}
	if (CFEqual(key, CFSTR("local-mac-address"))) {
		return CFDataCreate(allocator, synthetic_mac, sizeof(synthetic_mac));
	}
	if (CFEqual(key, CFSTR("transport-encoding"))) {
		word = 1;
		return CFDataCreate(allocator, (const UInt8 *)&word, sizeof(word));
	}
	if (CFEqual(key, CFSTR("transport-speed"))) {
		word = 115200;
		return CFDataCreate(allocator, (const UInt8 *)&word, sizeof(word));
	}
	return NULL;
}

static CFPropertyListRef
my_prefs_copy(CFStringRef key, CFStringRef application)
{
	char key_text[128] = "?";
	char app_text[128] = "?";

	if (key != NULL) {
		CFStringGetCString(key, key_text, sizeof(key_text),
		    kCFStringEncodingUTF8);
	}
	if (application != NULL) {
		CFStringGetCString(application, app_text, sizeof(app_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: copy %s app %s\n", key_text, app_text);
	/*
	 * cfprefsd never answers this daemon on this port (measured 2026-11-20:
	 * main stops inside the first CFPreferences read and no server is ever
	 * built), so answer "key absent" here. Every caller in bluetoothd
	 * treats a missing preference as its compiled-in default.
	 */
	return NULL;
}

static CFPropertyListRef
my_cf_prefs_copy(CFStringRef key, CFStringRef application)
{
	return my_prefs_copy(key, application);
}

/*
 * main() deletes the address it just read from the plist right after
 * FindLocalMacAddress succeeds, through CFPreferencesSetAppValue +
 * CFPreferencesAppSynchronize. Both are writes to cfprefsd, which never
 * answers this daemon here: the main thread sits in CoreFoundation and the
 * server is never built (measured 2026-11-20, main pc inside
 * CoreFoundation+0x1721b0 for 30 s). Dropping the write is harmless: the
 * address is regenerated from the same source on the next boot.
 */
static void
my_prefs_set(CFStringRef key, CFPropertyListRef value, CFStringRef application)
{
	char key_text[128] = "?";
	char app_text[128] = "?";

	(void)value;
	if (key != NULL) {
		CFStringGetCString(key, key_text, sizeof(key_text),
		    kCFStringEncodingUTF8);
	}
	if (application != NULL) {
		CFStringGetCString(application, app_text, sizeof(app_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: set %s app %s (dropped)\n", key_text, app_text);
}

static Boolean
my_prefs_sync(CFStringRef application)
{
	char app_text[128] = "?";

	if (application != NULL) {
		CFStringGetCString(application, app_text, sizeof(app_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: sync app %s (dropped)\n", app_text);
	return true;
}

static CFPropertyListRef
my_prefs_copy_value(CFStringRef key, CFStringRef application, CFStringRef user,
    CFStringRef host)
{
	char key_text[128] = "?";

	(void)user;
	(void)host;
	if (key != NULL) {
		CFStringGetCString(key, key_text, sizeof(key_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: value %s (absent)\n", key_text);
	return NULL;
}

static CFDictionaryRef
my_prefs_copy_multiple(CFArrayRef keys, CFStringRef application,
    CFStringRef user, CFStringRef host)
{
	(void)keys;
	(void)application;
	(void)user;
	(void)host;
	bt_log("prefs: multiple (empty)\n");
	return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFArrayRef
my_prefs_copy_keys(CFStringRef application, CFStringRef user, CFStringRef host)
{
	(void)application;
	(void)user;
	(void)host;
	bt_log("prefs: key list (absent)\n");
	return NULL;
}

static Boolean
my_prefs_get_bool(CFStringRef key, CFStringRef application, Boolean *valid)
{
	char key_text[128] = "?";

	if (key != NULL) {
		CFStringGetCString(key, key_text, sizeof(key_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: bool %s (false)\n", key_text);
	if (valid != NULL) {
		*valid = false;
	}
	return false;
}

static CFIndex
my_prefs_get_int(CFStringRef key, CFStringRef application, Boolean *valid)
{
	char key_text[128] = "?";

	if (key != NULL) {
		CFStringGetCString(key, key_text, sizeof(key_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: int %s (0)\n", key_text);
	if (valid != NULL) {
		*valid = false;
	}
	return 0;
}

static void
my_prefs_set_value(CFStringRef key, CFPropertyListRef value,
    CFStringRef application, CFStringRef user, CFStringRef host)
{
	char key_text[128] = "?";

	(void)value;
	(void)application;
	(void)user;
	(void)host;
	if (key != NULL) {
		CFStringGetCString(key, key_text, sizeof(key_text),
		    kCFStringEncodingUTF8);
	}
	bt_log("prefs: set-value %s (dropped)\n", key_text);
}

static int
my_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *port)
{
	static int (*real)(mach_port_t, const char *, mach_port_t *);

	if (real == NULL) {
		real = (int (*)(mach_port_t, const char *, mach_port_t *))
		    interposed_real((const void *)my_bootstrap_look_up);
	}
	bt_log("xpc.lookup %s\n", name != NULL ? name : "(null)");
	return real != NULL ? real(bp, name, port) : -1;
}

/*
 * The prefs interpose below is enough on this build: bluetoothd's
 * _CFPreferencesCopyAppValue call lands in the public CFPreferencesCopyAppValue,
 * which is what the interpose table replaces (measured 2026-11-20 with the
 * stub patch failing vm_protect and the daemon still logging this function's
 * key). Keep the reasons a stub patch is not an option: the private symbol is
 * two-level only, and an interpose entry for it aborts the exec with
 * "symbol not found in flat namespace".
 */

/*
 * The daemon powers the chip through _xpcSetPowerState:, a method on the
 * connection object it builds for each client. The client frameworks cannot
 * reach it here (available 0, no session), so hook the delegate's message entry
 * point and, for our own marker message, run the power path on that live
 * object: same code the daemon would run for a client, without the envelope.
 */
static void (*original_xpc_received)(id, SEL, xpc_object_t);

static void
my_xpc_received(id self, SEL _cmd, xpc_object_t message)
{
	const char *mark = NULL;

	bt_log("power.hook: recv %p self %p\n", message, self);
	{
		static id seen[8];
		static int seen_count;
		Ivar pid_ivar = class_getInstanceVariable(object_getClass(self),
		    "_pid");
		int index;
		int known = 0;

		for (index = 0; index < seen_count; index++) {
			if (seen[index] == self) {
				known = 1;
				break;
			}
		}
		if (!known && seen_count < (int)(sizeof(seen) / sizeof(seen[0]))) {
			seen[seen_count++] = self;
			bt_log("power.hook: conn %p pid %d\n", self,
			    pid_ivar != NULL ?
			    *(int *)((char *)self + ivar_getOffset(pid_ivar)) : -1);
		}
	}
	if (message != NULL) {
		char *description = xpc_copy_description(message);

		/*
		 * The SDK header declares no XPC_TYPE_DICTIONARY, and dlsym of
		 * the type object returned NULL, so the description is what
		 * tells a dictionary from anything else here.
		 */
		if (description != NULL &&
		    strstr(description, "<dictionary:") != NULL) {
			uint64_t msgid = xpc_dictionary_get_uint64(message,
			    "kCBMsgId");

			bt_log("power.hook: id %llu\n",
			    (unsigned long long)msgid);
			bt_power_append("id %llu\n",
			    (unsigned long long)msgid);
			mark = xpc_dictionary_get_string(message, "mondrian");
			if (mark != NULL) {
				bt_log("power.hook: mark %s\n", mark);
			}
		}
		if (description != NULL) {
			bt_power_append("msg %.300s\n", description);
			if (xpc_description_budget > 0) {
				xpc_description_budget--;
				bt_log("power.hook: msg %.600s\n", description);
			}
		}
		free(description);
	}
	if (mark != NULL && strcmp(mark, "power") == 0) {
		xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);

		bt_log("power.hook: set power 5 on %p\n", self);
		if (args != NULL) {
			xpc_dictionary_set_int64(args, "pwrS", 5);
			((void (*)(id, SEL, xpc_object_t))objc_msgSend)(self,
			    sel_registerName("_xpcSetPowerState:"), args);
			xpc_release(args);
		}
		return;
	}
	if (original_xpc_received != NULL) {
		original_xpc_received(self, _cmd, message);
	}
}

static BOOL (*original_entitled)(id, SEL, id *);

static BOOL
my_entitled(id self, SEL _cmd, id *error)
{
	BOOL result = YES;

	if (original_entitled != NULL) {
		result = original_entitled(self, _cmd, error);
	}
	bt_log("power.hook: entitled %d self %p\n", result, self);
	bt_power_append("entitled %d self %p\n", result, self);
	return result;
}

/*
 * The teardown that a power change runs calls the transport's notify slot at
 * +0x60 through a bare `br x0` (bluetoothd `0xf3b4c` calls `0xe6aac`, whose
 * body loads `[transport + 0x60]` and branches). Apple's H4 table leaves that
 * slot NULL: the APPLEBT and H4BC tables fill it with a stub that sets a state
 * byte, and H4 has no such byte. The tail call therefore lands on address 0,
 * which is the Settings switch crash: `sig 11 pc 0x0 far 0x0 lr
 * bluetoothd + 0xf3b50`. A no-op in the empty slot is what H4 already does
 * with the other one: no H4 code reads that state.
 *
 * The table is in __DATA of the main image (vmaddr 0x100844228, first word 1
 * and name "H4"), so it is writable at constructor time.
 */
#define H4_TRANSPORT_TABLE 0x844228UL
#define H4_TRANSPORT_NAME 0x08UL
#define H4_TRANSPORT_NOTIFY 0x60UL

static void
mondrian_bt_transport_notify(void)
{
}

static uintptr_t
main_image_base(void)
{
	uint32_t i;
	uint32_t count = _dyld_image_count();

	for (i = 0; i < count; i++) {
		const struct mach_header_64 *header =
		    (const struct mach_header_64 *)_dyld_get_image_header(i);

		if (header != NULL && header->filetype == MH_EXECUTE) {
			return (uintptr_t)header;
		}
	}
	return 0;
}

static void
fix_h4_transport(void)
{
	uintptr_t base = main_image_base();
	uint32_t *table;
	void **slot;
	const char *name;

	if (base == 0) {
		bt_log("h4: no executable image\n");
		bt_power_append("h4: no executable image\n");
		return;
	}
	table = (uint32_t *)(base + H4_TRANSPORT_TABLE);
	slot = (void **)((uintptr_t)table + H4_TRANSPORT_NOTIFY);
	name = *(const char **)((uintptr_t)table + H4_TRANSPORT_NAME);
	if (table[0] != 1 || name == NULL || strcmp(name, "H4") != 0) {
		bt_log("h4: base %p id %u name \"%s\", slot untouched\n",
		    (void *)base, table[0], name != NULL ? name : "(null)");
		bt_power_append("h4: base %p id %u name \"%s\", slot untouched\n",
		    (void *)base, table[0], name != NULL ? name : "(null)");
		return;
	}
	if (*slot != NULL) {
		bt_log("h4: notify slot already %p\n", *slot);
		bt_power_append("h4: notify slot already %p\n", *slot);
		return;
	}
	*slot = (void *)&mondrian_bt_transport_notify;
	bt_log("h4: notify slot +0x60 was NULL, no-op installed\n");
	bt_power_append("h4: notify slot +0x60 was NULL, no-op installed\n");
}

static void
hook_power_method(void)
{
	Class cls = objc_getClass("CBDaemonXPCConnection");
	Method method;

	if (cls == Nil) {
		bt_log("power.hook: no class\n");
		return;
	}
	method = class_getInstanceMethod(cls, sel_registerName("xpcReceivedMessage:"));
	if (method == NULL) {
		bt_log("power.hook: no method\n");
		return;
	}
	original_xpc_received = (void (*)(id, SEL, xpc_object_t))
	    method_setImplementation(method, (IMP)my_xpc_received);
	bt_log("power.hook: xpcReceivedMessage: replaced\n");
	method = class_getInstanceMethod(cls,
	    sel_registerName("_entitledAndReturnError:"));
	if (method != NULL) {
		original_entitled = (BOOL (*)(id, SEL, id *))
		    method_setImplementation(method, (IMP)my_entitled);
		bt_log("power.hook: _entitledAndReturnError: replaced\n");
	}
}

/*
 * The power request needs a client connection object, and no client ever
 * attaches. The call _xpcSetPowerState: makes is [self->_X setPowerState:state
 * error:&err]; find out what _X is (ivar offsets) and where the daemon keeps
 * the object, so the same call can be made without an XPC client.
 */
static void
dump_class(const char *name, int *budget)
{
	Class cls = objc_getClass(name);
	Class super;
	Ivar *ivars;
	Method *methods;
	unsigned int count = 0;
	unsigned int i;

	if (cls == Nil) {
		bt_log("rt: %s absent\n", name);
		return;
	}
	super = class_getSuperclass(cls);
	bt_log("rt: class %s super %s\n", name,
	    super != Nil ? class_getName(super) : "-");
	ivars = class_copyIvarList(cls, &count);
	for (i = 0; i < count; i++) {
		bt_log("rt:   ivar %s @%u\n", ivar_getName(ivars[i]),
		    (unsigned)ivar_getOffset(ivars[i]));
	}
	free(ivars);
	methods = class_copyMethodList(cls, &count);
	for (i = 0; i < count && *budget > 0; i++) {
		const char *sel = sel_getName(method_getName(methods[i]));

		if (strstr(sel, "ower") == NULL && strstr(sel, "hared") == NULL &&
		    strstr(sel, "efault") == NULL && strstr(sel, "nstance") == NULL &&
		    strstr(sel, "tate") == NULL) {
			continue;
		}
		bt_log("rt:   - %s\n", sel);
		(*budget)--;
	}
	free(methods);
	methods = class_copyMethodList(object_getClass((id)cls), &count);
	for (i = 0; i < count && *budget > 0; i++) {
		bt_log("rt:   + %s\n", sel_getName(method_getName(methods[i])));
		(*budget)--;
	}
	free(methods);
}

/*
 * CBDaemonServer is not a singleton: main() allocates it, so the instance is
 * only reachable by catching its init. _stackController @408 is the
 * CBStackControllerBTStack that owns -setPowerState:error:, the same call
 * _xpcSetPowerState: makes on _activatedController.
 */
static id daemon_server;
static id (*original_server_init)(id, SEL);
static id (*original_server_init_adaptor)(id, SEL, id);
static void (*original_server_activate)(id, SEL);
static mach_port_t main_thread;

static id
my_server_init_adaptor(id self, SEL _cmd, id adaptor)
{
	id result = self;

	if (original_server_init_adaptor != NULL) {
		result = original_server_init_adaptor(self, _cmd, adaptor);
	}
	if (result != nil) {
		daemon_server = result;
		bt_log("rt: server init %p adaptor %p\n", result, adaptor);
	}
	return result;
}

static void
my_server_activate(id self, SEL _cmd)
{
	if (daemon_server == NULL) {
		daemon_server = self;
		bt_log("rt: server captured at activate %p\n", self);
	}
	if (original_server_activate != NULL) {
		original_server_activate(self, _cmd);
	}
}

static id
my_server_init(id self, SEL _cmd)
{
	id result = self;

	if (original_server_init != NULL) {
		result = original_server_init(self, _cmd);
	}
	if (result != nil) {
		daemon_server = result;
		bt_log("rt: CBDaemonServer init -> %p\n", result);
	}
	return result;
}

static Method
own_method(Class cls, const char *name)
{
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	Method found = NULL;
	unsigned int i;

	for (i = 0; i < count; i++) {
		if (strcmp(sel_getName(method_getName(methods[i])), name) == 0) {
			found = methods[i];
			break;
		}
	}
	free(methods);
	return found;
}

/*
 * What the daemon knows about a discovered device. Its name comes from the
 * classic EIR, a Remote Name Request completion or an LE report, and the
 * Settings pane shows the address instead. These two selectors are the stack
 * reporting a device upward, so reading `name` off the object says whether the
 * loss is here or in the client that draws the row. The strings go to the
 * append-only power log because the main log is truncated on every start.
 */
static void (*original_device_found)(id, SEL, id);
static void (*original_classic_found)(id, SEL, id);
static unsigned devices_logged;

static BOOL
has_selector(id object, const char *name)
{
	return object != nil && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(object,
	    sel_registerName("respondsToSelector:"), sel_registerName(name));
}

static const char *
object_text(id object, const char *selector)
{
	id value;
	const char *text;

	if (!has_selector(object, selector)) {
		return NULL;
	}
	value = ((id (*)(id, SEL))objc_msgSend)(object,
	    sel_registerName(selector));
	if (value == nil || !has_selector(value, "UTF8String")) {
		return NULL;
	}
	text = ((const char *(*)(id, SEL))objc_msgSend)(value,
	    sel_registerName("UTF8String"));
	return text;
}

static void
log_device_found(const char *what, id device)
{
	const char *name, *address;

	if (device == nil || devices_logged >= 8) {
		return;
	}
	devices_logged++;
	name = object_text(device, "name");
	address = object_text(device, "addressString");
	bt_power_append("%s name \"%s\" addr \"%s\"\n", what,
	    name != NULL ? name : "(nil)", address != NULL ? address : "(nil)");
}

static void
my_device_found(id self, SEL _cmd, id device)
{
	log_device_found("reportDeviceFound", device);
	if (original_device_found != NULL) {
		original_device_found(self, _cmd, device);
	}
}

static void
my_classic_found(id self, SEL _cmd, id device)
{
	log_device_found("classicDeviceFound", device);
	if (original_classic_found != NULL) {
		original_classic_found(self, _cmd, device);
	}
}

static void
hook_device_found(void)
{
	Class cls = objc_getClass("CBDaemonServer");
	Method method;

	if (cls == Nil) {
		return;
	}
	method = own_method(cls, "_reportDeviceFound:");
	if (method != NULL) {
		original_device_found = (void (*)(id, SEL, id))
		    method_setImplementation(method, (IMP)my_device_found);
		bt_log("dev.hook: _reportDeviceFound: replaced\n");
	}
	method = own_method(cls, "_stackClassicScannerDeviceFound:");
	if (method != NULL) {
		original_classic_found = (void (*)(id, SEL, id))
		    method_setImplementation(method, (IMP)my_classic_found);
		bt_log("dev.hook: _stackClassicScannerDeviceFound: replaced\n");
	}
}

static void
hook_server_entry(void)
{
	Class cls = objc_getClass("CBDaemonServer");
	Method method;

	if (cls == Nil) {
		bt_log("rt: no CBDaemonServer\n");
		return;
	}
	method = own_method(cls, "activate");
	if (method != NULL) {
		original_server_activate = (void (*)(id, SEL))
		    method_setImplementation(method, (IMP)my_server_activate);
		bt_log("rt: CBDaemonServer activate hooked\n");
	} else {
		bt_log("rt: CBDaemonServer has no own activate\n");
	}
	method = own_method(cls, "initWithCBStackAdaptor:");
	if (method != NULL) {
		original_server_init_adaptor = (id (*)(id, SEL, id))
		    method_setImplementation(method, (IMP)my_server_init_adaptor);
		bt_log("rt: CBDaemonServer init hooked\n");
	}
	method = own_method(cls, "init");
	if (method != NULL) {
		original_server_init = (id (*)(id, SEL))
		    method_setImplementation(method, (IMP)my_server_init);
		bt_log("rt: CBDaemonServer plain init hooked\n");
	}
}

static id stack_controller;

static long
controller_power_state(void)
{
	if (stack_controller == NULL) {
		return -1;
	}
	return ((long (*)(id, SEL))objc_msgSend)(stack_controller,
	    sel_registerName("powerState"));
}

static void
power_sample(void *context)
{
	bt_log("rt: powerState at %ld s -> %ld\n", (long)context,
	    controller_power_state());
}

/*
 * The server object never appears, so the daemon stops in main before it is
 * built. The constructor runs on the main thread before main(), and Mach lets
 * this process read that thread's state, so the PC and the frame chain name
 * the blocking call. Offsets are relative to the main image's slide.
 */
static void
log_address(const char *tag, uintptr_t address)
{
	Dl_info info;

	if (dladdr((void *)address, &info) != 0 && info.dli_fname != NULL &&
	    info.dli_fbase != NULL) {
		bt_log("rt: %s %p %s+0x%lx %s\n", tag, (void *)address,
		    info.dli_fname,
		    (unsigned long)(address - (uintptr_t)info.dli_fbase),
		    info.dli_sname != NULL ? info.dli_sname : "");
		return;
	}
	bt_log("rt: %s %p (no image)\n", tag, (void *)address);
}

static void
scan_stack(uintptr_t stack_pointer)
{
	uint64_t words[192];
	vm_size_t got = 0;
	unsigned int i;
	unsigned int shown = 0;

	if (vm_read_overwrite(mach_task_self(), (vm_address_t)stack_pointer,
	    sizeof(words), (vm_address_t)words, &got) != KERN_SUCCESS) {
		return;
	}
	for (i = 0; i < got / sizeof(words[0]) && shown < 8; i++) {
		uintptr_t value = (uintptr_t)words[i];
		Dl_info info;

		if (value < 0x100000000ULL) {
			continue;
		}
		if (dladdr((void *)value, &info) == 0 || info.dli_fname == NULL) {
			continue;
		}
		bt_log("rt: stack[%u] %s+0x%lx\n", i, info.dli_fname,
		    (unsigned long)(value - (uintptr_t)info.dli_fbase));
		shown++;
	}
}

static void
sample_main_thread(void)
{
	arm_thread_state64_t state;
	mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
	uintptr_t frame_pointer;
	kern_return_t kr;
	int i;

	if (main_thread == MACH_PORT_NULL) {
		bt_log("rt: no main thread port\n");
		return;
	}
	kr = thread_get_state(main_thread, ARM_THREAD_STATE64,
	    (thread_state_t)&state, &count);
	if (kr != KERN_SUCCESS) {
		bt_log("rt: main state kr %d\n", kr);
		return;
	}
	log_address("main pc", (uintptr_t)state.__pc);
	log_address("main lr", (uintptr_t)state.__lr);
	frame_pointer = state.__fp;
	for (i = 0; i < 10 && frame_pointer != 0; i++) {
		struct {
			uintptr_t next;
			uintptr_t ret;
		} frame;
		vm_size_t got = 0;

		if (vm_read_overwrite(mach_task_self(), (vm_address_t)frame_pointer,
		    sizeof(frame), (vm_address_t)&frame, &got) != KERN_SUCCESS ||
		    got != sizeof(frame)) {
			break;
		}
		if (frame.ret < 0x1000 || frame.next <= frame_pointer) {
			break;
		}
		log_address("frame", frame.ret);
		frame_pointer = frame.next;
	}
	scan_stack((uintptr_t)state.__sp);
}

static void
dump_all_methods(Class cls)
{
	Method *methods;
	unsigned int count = 0;
	unsigned int i;

	methods = class_copyMethodList(cls, &count);
	bt_log("rt: %s has %u methods\n", class_getName(cls), count);
	for (i = 0; i < count && i < 250; i++) {
		bt_log("rt:   - %s\n", sel_getName(method_getName(methods[i])));
	}
	free(methods);
}

static void
runtime_dump(void *context)
{
	static const char *const names[] = {
		"CBDaemonXPCConnection", "CBDaemonServer",
		"CBStackControllerBTStack",
	};
	static int retries;
	static int dumped;
	Class server_class = objc_getClass("CBDaemonServer");
	Ivar controller_ivar;
	int budget = 200;
	unsigned int i;

	(void)context;
	if (!dumped) {
		dumped = 1;
		for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
			dump_class(names[i], &budget);
		}
		if (server_class != Nil) {
			dump_all_methods(server_class);
		}
	}
	bt_log("rt: server %p\n", daemon_server);
	sample_main_thread();
	if (daemon_server == nil && retries++ < 15) {
		dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2000000000LL),
		    dispatch_get_global_queue(0, 0), NULL, runtime_dump);
		return;
	}
	if (daemon_server == nil || server_class == Nil) {
		return;
	}
	controller_ivar = class_getInstanceVariable(server_class,
	    "_stackController");
	if (controller_ivar == NULL) {
		bt_log("rt: no _stackController ivar\n");
		return;
	}
	stack_controller = *(id *)((char *)daemon_server +
	    ivar_getOffset(controller_ivar));
	bt_log("rt: stackController %p powerState %ld\n", stack_controller,
	    controller_power_state());
	if (stack_controller == NULL) {
		return;
	}
	bt_log("rt: calling -setPowerState:5\n");
	{
		id error = nil;
		long result = ((long (*)(id, SEL, long, id *))objc_msgSend)(
		    stack_controller, sel_registerName("setPowerState:error:"), 5,
		    &error);

		bt_log("rt: -setPowerState:error: -> %ld err %p\n", result, error);
	}
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2000000000LL),
	    dispatch_get_global_queue(0, 0), (void *)2, power_sample);
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 6000000000LL),
	    dispatch_get_global_queue(0, 0), (void *)6, power_sample);
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 12000000000LL),
	    dispatch_get_global_queue(0, 0), (void *)12, power_sample);
}

/*
 * QCA6490 boot from the shim.
 *
 * The controller answers HCI from its ROM as soon as the transport powers it,
 * but the ROM lacks commands the Apple stack requires: measured 2026-11-20,
 * HCI_Write_Erroneous_Data_Reporting (0x0C5F) returned status 701 and
 * bluetoothd stopped with "HCI initialization failed". btqca's download fixes
 * that. The sequence is the one tools/bt-download.py already proved on this
 * phone: EDL_PATCH_VER_REQ (0xFC00 0x19) names the ROM, hpbtfw21.tlv is
 * streamed raw in 243-byte segments with only the last one acknowledged
 * (QCA_SKIP_EVT_VSE_CC), hpnv21.bin follows with its HCI rate byte rewritten
 * to 115200 so the chip stays on the rate the kernel engine is fixed at, and
 * without the in-band-sleep bit btqca sets for Linux (Apple's H4 driver does
 * not speak IBS), QCA_DISABLE_LOGGING (0xFC17), HCI_Reset and Read Local
 * Version close it. The patch version moving from 0x38e6 to 0x5e81 is the
 * proof.
 *
 * The controller speaks HCI-IBS while it does this: 0xfd is its WAKE_IND and
 * needs a 0xfc WAKE_ACK from the host, or it repeats the wake every 100 ms and
 * takes no command (hci_qca.c; measured 2026-11-20, a version request answered
 * with nothing but 0xfd filler). qca_read_more acknowledges every 0xfd it sees.
 *
 * This has to happen in the shim and not in mondrian_btuart_tty_open: the
 * kernel cannot read userdata that early, and the shim runs before main() opens
 * the transport, so the daemon finds a patched controller. A restarted
 * bluetoothd finds the same chip still powered; asking the version first keeps
 * it from downloading a second time.
 */
#define QCA_CTL_NAME "com.mondrian.btuart"
#define QCA_FW_PATH "/private/var/vm/hpbtfw21.tlv"
#define QCA_NVM_PATH "/private/var/vm/hpnv21.bin"
#define QCA_SEG 243
#define QCA_PATCHED_VERSION 0x5e81
#define QCA_RATE_115200 0

struct qca_reader {
	int fd;
	size_t len;
	unsigned int acks;
	unsigned int sleeps;
	unsigned int woke;
	uint8_t buf[1024];
};

static uint8_t *
qca_read_file(const char *path, size_t *size)
{
	int fd;
	struct stat st;
	uint8_t *blob;
	size_t done = 0;

	fd = (int)syscall(SYS_open, path, O_RDONLY, 0);
	if (fd < 0) {
		return NULL;
	}
	if (fstat(fd, &st) != 0 || st.st_size <= 0) {
		syscall(SYS_close, fd);
		return NULL;
	}
	blob = malloc((size_t)st.st_size);
	if (blob == NULL) {
		syscall(SYS_close, fd);
		return NULL;
	}
	while (done < (size_t)st.st_size) {
		ssize_t got = (ssize_t)syscall(SYS_read, fd, blob + done,
		    (size_t)st.st_size - done);

		if (got <= 0) {
			break;
		}
		done += (size_t)got;
	}
	syscall(SYS_close, fd);
	if (done != (size_t)st.st_size) {
		free(blob);
		return NULL;
	}
	*size = done;
	return blob;
}

static int
qca_open(void)
{
	struct ctl_info_32 info;
	struct sockaddr_ctl_32 address;
	int fd;
	int flags;

	fd = (int)syscall(SYS_socket, PF_SYSTEM_DARWIN, SOCK_STREAM,
	    SYSPROTO_CONTROL_DARWIN);
	if (fd < 0) {
		return -1;
	}
	bzero(&info, sizeof(info));
	strlcpy(info.ctl_name, QCA_CTL_NAME, sizeof(info.ctl_name));
	if (syscall(SYS_ioctl, fd, CTLIOCGINFO, &info) < 0) {
		syscall(SYS_close, fd);
		return -1;
	}
	bzero(&address, sizeof(address));
	address.sc_len = sizeof(address);
	address.sc_family = PF_SYSTEM_DARWIN;
	address.ss_sysaddr = 2; /* AF_SYS_CONTROL */
	address.sc_id = info.ctl_id;
	address.sc_unit = 0;
	if (syscall(SYS_connect, fd, (struct sockaddr *)&address,
	    sizeof(address)) < 0) {
		syscall(SYS_close, fd);
		return -1;
	}
	flags = (int)syscall(SYS_fcntl, fd, F_GETFL, 0);
	if (flags >= 0) {
		syscall(SYS_fcntl, fd, F_SETFL, flags | O_NONBLOCK);
	}
	return fd;
}

static int
qca_write_all(int fd, const uint8_t *data, size_t len)
{
	size_t done = 0;

	while (done < len) {
		ssize_t wrote = (ssize_t)syscall(SYS_write, fd, data + done,
		    len - done);

		if (wrote > 0) {
			done += (size_t)wrote;
			continue;
		}
		if (wrote < 0 && errno != EAGAIN && errno != EINTR) {
			return -1;
		}
		usleep(1000);
	}
	return 0;
}

/* One more read; 1 when bytes arrived, 0 on timeout, -1 on error. */
static int
qca_read_more(struct qca_reader *r, int timeout_ms)
{
	int waited = 0;

	while (waited < timeout_ms) {
		/*
		 * MSG_DONTWAIT, not O_NONBLOCK: the control socket accepted the
		 * fcntl and read() still blocked when the chip went quiet, which
		 * left the first download attempt asleep in the constructor
		 * forever (measured 2026-11-20).
		 */
		ssize_t got = (ssize_t)syscall(SYS_recvfrom, r->fd,
		    r->buf + r->len, sizeof(r->buf) - r->len, MSG_DONTWAIT,
		    NULL, NULL);

		if (got > 0) {
			size_t first = r->len;
			size_t i;

			r->len += (size_t)got;
			for (i = first; i < r->len; i++) {
				if (r->buf[i] == 0xfd) {
					/*
					 * HCI_IBS: 0xfd is the controller's
					 * WAKE_IND and 0xfc the host's ACK
					 * (hci_qca.c). Unanswered, the part
					 * repeats it every 100 ms and never
					 * takes a command.
					 */
					static const uint8_t ack = 0xfc;

					qca_write_all(r->fd, &ack, 1);
					r->acks++;
				} else if (r->buf[i] == 0xfe) {
					r->sleeps++;
				}
			}
			return 1;
		}
		if (got < 0 && errno != EAGAIN && errno != EINTR &&
		    errno != EWOULDBLOCK) {
			return -1;
		}
		usleep(2000);
		waited += 2;
	}
	return 0;
}

static void
qca_drop(struct qca_reader *r, size_t count)
{
	if (count >= r->len) {
		r->len = 0;
		return;
	}
	memmove(r->buf, r->buf + count, r->len - count);
	r->len -= count;
}

/*
 * Wait for the Command Complete of opcode and copy its return parameters,
 * starting at the status byte. Returns that status, or -1 on timeout or a
 * transport error. Events for other commands are discarded.
 */
static int
qca_complete(struct qca_reader *r, uint16_t opcode, int timeout_ms,
    uint8_t *params, size_t cap, size_t *params_len)
{
	int waited = 0;

	for (;;) {
		if (r->len >= 3) {
			size_t total;

			if (r->buf[0] != 0x04) {
				qca_drop(r, 1);
				continue;
			}
			total = 3 + (size_t)r->buf[2];
			if (r->len >= total) {
				uint8_t code = r->buf[1];
				uint8_t length = r->buf[2];
				const uint8_t *p = r->buf + 3;

				if (code == 0x0e && length >= 3 &&
				    (uint16_t)(p[1] | (p[2] << 8)) == opcode) {
					size_t n = length > 3 ? length - 3 : 0;

					if (params != NULL && params_len != NULL) {
						if (n > cap) {
							n = cap;
						}
						memcpy(params, p + 3, n);
						*params_len = n;
					}
					qca_drop(r, total);
					return length > 3 ? p[3] : -1;
				}
				qca_drop(r, total);
				continue;
			}
		}
		{
			int got = qca_read_more(r, 20);

			if (got < 0) {
				return -1;
			}
			/*
			 * Count elapsed time even when filler keeps arriving:
			 * the controller's IBS wake packets are read on their
			 * own, and a parser that resets its clock on every
			 * byte never times out (measured 2026-11-20, the
			 * first download attempt spun in here for minutes).
			 */
			waited += 20;
			if (waited >= timeout_ms) {
				return -1;
			}
		}
	}
}

static int
qca_command(struct qca_reader *r, uint16_t opcode, const void *params,
    size_t count, int timeout_ms, uint8_t *reply, size_t reply_cap,
    size_t *reply_len)
{
	uint8_t packet[260];

	if (count > sizeof(packet) - 4) {
		return -1;
	}
	packet[0] = 0x01;
	packet[1] = (uint8_t)(opcode & 0xff);
	packet[2] = (uint8_t)(opcode >> 8);
	packet[3] = (uint8_t)count;
	if (count > 0) {
		memcpy(packet + 4, params, count);
	}
	if (qca_write_all(r->fd, packet, 4 + count) != 0) {
		return -1;
	}
	return qca_complete(r, opcode, timeout_ms, reply, reply_cap, reply_len);
}

/*
 * HCI_IBS both ways: the host wakes the controller with 0xfd and expects a
 * 0xfc ack; the controller's own 0xfd is acknowledged by qca_read_more. Until
 * both directions are awake the part ignores commands and repeats its wake
 * every 100 ms (hci_qca.c; measured 2026-11-20: the version request after a
 * one-way handshake was answered with nothing but 0xfd).
 */
static int
qca_wake(struct qca_reader *r)
{
	static const uint8_t wake_ind = 0xfd;
	int waited = 0;
	int i;

	for (i = 0; i < 3; i++) {
		qca_write_all(r->fd, &wake_ind, 1);
	}
	while (waited < 400) {
		size_t j;

		if (qca_read_more(r, 20) < 0) {
			break;
		}
		for (j = 0; j < r->len; j++) {
			if (r->buf[j] == 0xfc) {
				r->len = 0;
				return 0;
			}
		}
		waited += 20;
	}
	r->len = 0;
	return -1;
}

/*
 * The controller drops into deep sleep on its own: it sends 0xfe and stops
 * taking commands until the host wakes it with 0xfd and it answers 0xfc. A
 * download that ignores this reaches the first segment and then writes into a
 * sleeping part (measured 2026-11-20, the NVM's last segment never acked).
 */
static void
qca_keep_awake(struct qca_reader *r)
{
	static const uint8_t indicator = 0xfd;
	int tries;

	/* Pick up a 0xfe/0xfd that arrived since the last segment. */
	(void)qca_read_more(r, 10);
	if (r->sleeps == r->woke) {
		return;
	}
	for (tries = 0; tries < 3; tries++) {
		int waited = 0;

		qca_write_all(r->fd, &indicator, 1);
		while (waited < 40) {
			size_t i;

			if (qca_read_more(r, 10) < 0) {
				break;
			}
			for (i = 0; i < r->len; i++) {
				if (r->buf[i] == 0xfc) {
					r->len = 0;
					r->woke = r->sleeps;
					return;
				}
			}
			waited += 10;
		}
	}
	r->len = 0;
	r->woke = r->sleeps;
}

static int
qca_version(struct qca_reader *r, uint32_t *product, uint16_t *patch,
    uint16_t *rom, uint32_t *soc)
{
	uint8_t reply[32];
	size_t length = 0;
	int tries;

	for (tries = 0; tries < 3; tries++) {
		uint8_t request = 0x19;
		int status = qca_command(r, 0xfc00, &request, 1, 3000, reply,
		    sizeof(reply), &length);

		if (status == 0 && length >= 15 && reply[1] == 0x19 &&
		    reply[2] == 0x0c) {
			*product = (uint32_t)reply[3] |
			    ((uint32_t)reply[4] << 8) |
			    ((uint32_t)reply[5] << 16) |
			    ((uint32_t)reply[6] << 24);
			*patch = (uint16_t)(reply[7] | (reply[8] << 8));
			*rom = (uint16_t)(reply[9] | (reply[10] << 8));
			*soc = (uint32_t)reply[11] |
			    ((uint32_t)reply[12] << 8) |
			    ((uint32_t)reply[13] << 16) |
			    ((uint32_t)reply[14] << 24);
			return 1;
		}
		usleep(200000);
	}
	return 0;
}

/*
 * qca_tlv_check_data's rewrite of the NVM before it goes on the wire: the HCI
 * tag carries the UART rate the controller switches to when it applies the
 * file, and the stock file says 3.2 Mbaud. Only the rate is rewritten:
 * btqca also sets the in-band-sleep bit (data[0] |= 0x80) because Linux speaks
 * HCI_IBS, but Apple's H4 driver does not, so the bit stays as the file has it
 * (clear) and the controller keeps to plain H4 after the boot.
 */
static void
qca_patch_nvm(uint8_t *blob, size_t size, uint8_t rate)
{
	uint32_t type_len;
	size_t index;
	size_t end;

	if (size < 4) {
		return;
	}
	type_len = (uint32_t)blob[0] | ((uint32_t)blob[1] << 8) |
	    ((uint32_t)blob[2] << 16) | ((uint32_t)blob[3] << 24);
	end = 4 + (size_t)(type_len >> 8);
	if (end > size) {
		end = size;
	}
	for (index = 4; index + 12 <= end; ) {
		uint16_t tag = (uint16_t)(blob[index] | (blob[index + 1] << 8));
		uint16_t length = (uint16_t)(blob[index + 2] |
		    (blob[index + 3] << 8));
		size_t data = index + 12;

		if (data + length > end) {
			break;
		}
		if (tag == 0x11 && length >= 3) {
			blob[data] &= 0x7f;
			blob[data + 1] = rate;
		}
		index = data + length;
	}
}

static int
qca_stream(struct qca_reader *r, const char *name, const uint8_t *blob,
    size_t size)
{
	uint8_t packet[4 + 2 + QCA_SEG];
	size_t sent = 0;

	while (sent < size) {
		size_t piece = size - sent;
		int last;
		int status;

		if (piece > QCA_SEG) {
			piece = QCA_SEG;
		}
		last = sent + piece >= size;
		packet[0] = 0x01;
		packet[1] = 0x00;
		packet[2] = 0xfc;
		packet[3] = (uint8_t)(piece + 2);
		packet[4] = 0x1e;
		packet[5] = (uint8_t)piece;
		memcpy(packet + 6, blob + sent, piece);
		qca_keep_awake(r);
		if (qca_write_all(r->fd, packet, 6 + piece) != 0) {
			bt_log("qca: %s write failed at %zu of %zu\n", name, sent,
			    size);
			return -1;
		}
		sent += piece;
		if (!last) {
			if (sent % (QCA_SEG * 100) < QCA_SEG) {
				bt_log("qca: %s %zu of %zu bytes\n", name, sent,
				    size);
			}
			continue;
		}
		status = qca_complete(r, 0xfc00, 30000, NULL, 0, NULL);
		bt_log("qca: %s %zu of %zu bytes, last segment status %d\n",
		    name, sent, size, status);
		if (status != 0) {
			return -1;
		}
	}
	return 0;
}

/*
 * Will the controller scan with the extended commands? The daemon drives the
 * legacy pair (0x200b/0x200c), which the WCN7850 answers with 0x0c "command
 * disallowed", so no LE advertising report reaches the daemon and the device
 * list stays on addresses. Its LE features carry bit 12 (extended
 * advertising), so the extended pair is the other way in. The probe runs only
 * when /private/var/vm/bt-ext-probe exists: it reports the statuses and the
 * first event's bytes, which is what decides whether a kernel-level
 * translation of the daemon's legacy scan commands is worth writing.
 */
static void
qca_probe_scan(struct qca_reader *r)
{
	static const uint8_t params[] = {
		0x00, 0x00, 0x01, 0x01, 0x30, 0x00, 0x30, 0x00
	};
	static const uint8_t enable[] = { 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
	static const uint8_t disable[] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
	int status;
	int waited;

	status = qca_command(r, 0x2041, params, sizeof(params), 3000, NULL, 0,
	    NULL);
	bt_power_append("ext: 0x2041 params status %d\n", status);
	status = qca_command(r, 0x2042, enable, sizeof(enable), 3000, NULL, 0,
	    NULL);
	bt_power_append("ext: 0x2042 enable status %d\n", status);
	if (status == 0) {
		for (waited = 0; waited < 1000 && r->len < 3; waited += 20) {
			if (qca_read_more(r, 20) <= 0) {
				break;
			}
		}
		if (r->len >= 3) {
			bt_power_append("ext: first event %02x %02x %02x\n",
			    r->buf[0], r->buf[1], r->buf[2]);
		}
	}
	status = qca_command(r, 0x2042, disable, sizeof(disable), 3000, NULL, 0,
	    NULL);
	bt_power_append("ext: 0x2042 disable status %d\n", status);
}

static void
qca_boot(void)
{
	uint8_t *fw;
	uint8_t *nvm;
	size_t fw_size = 0;
	size_t nvm_size = 0;
	struct qca_reader reader;
	uint32_t product = 0;
	uint32_t soc = 0;
	uint16_t patch = 0;
	uint16_t rom = 0;
	int fd;
	int status;
	int i;

	fw = qca_read_file(QCA_FW_PATH, &fw_size);
	if (fw == NULL) {
		bt_log("qca: %s is not readable, leaving the ROM in place\n",
		    QCA_FW_PATH);
		return;
	}
	nvm = qca_read_file(QCA_NVM_PATH, &nvm_size);
	if (nvm == NULL) {
		bt_log("qca: %s is not readable, leaving the ROM in place\n",
		    QCA_NVM_PATH);
		free(fw);
		return;
	}
	fd = qca_open();
	if (fd < 0) {
		bt_log("qca: cannot open %s (errno %d)\n", QCA_CTL_NAME, errno);
		free(fw);
		free(nvm);
		return;
	}
	bzero(&reader, sizeof(reader));
	reader.fd = fd;
	bt_log("qca: control connected, wake %s\n",
	    qca_wake(&reader) == 0 ? "acked" : "not answered");
	if (qca_version(&reader, &product, &patch, &rom, &soc)) {
		bt_log("qca: product 0x%08x patch 0x%04x rom 0x%04x "
		    "soc 0x%08x\n", product, patch, rom, soc);
		if (patch == QCA_PATCHED_VERSION) {
			/*
			 * The patch is in and the mask is the firmware's: the
			 * NVM does not change it (measured 2026-11-20, byte
			 * 0x12 stays 0x83). Re-sending the TLV on every
			 * respawn only makes the boot slow, and 0x0c5b is
			 * handled in the H4 filter below.
			 */
			bt_log("qca: already patched, leaving the NVM alone\n");
			if (access("/private/var/vm/bt-ext-probe",
			    F_OK) == 0) {
				qca_probe_scan(&reader);
			}
			syscall(SYS_close, fd);
			free(fw);
			free(nvm);
			return;
		}
	} else {
		/*
		 * Streaming into a controller that is not answering writes a
		 * firmware image into nothing and leaves its state unknown, so
		 * stop here and let the next boot (or the host tool) do it.
		 */
		bt_log("qca: the ROM did not answer the version request, "
		    "not downloading\n");
		syscall(SYS_close, fd);
		free(fw);
		free(nvm);
		return;
	}
	if (qca_command(&reader, 0xfc00, "\x20", 1, 3000, NULL, 0, NULL) == 0) {
		bt_log("qca: build info read\n");
	}
	if (qca_command(&reader, 0xfc00, "\x23", 1, 3000, NULL, 0, NULL) == 0) {
		bt_log("qca: board id read\n");
	}
	if (qca_stream(&reader, "patch", fw, fw_size) == 0 &&
	    qca_version(&reader, &product, &patch, &rom, &soc)) {
		bt_log("qca: after the patch 0x%04x (want 0x%04x)\n", patch,
		    QCA_PATCHED_VERSION);
	}
nvm:
	qca_patch_nvm(nvm, nvm_size, QCA_RATE_115200);
	qca_stream(&reader, "nvm", nvm, nvm_size);
	status = qca_command(&reader, 0xfc17, "\x14\x00", 2, 3000, NULL, 0,
	    NULL);
	bt_log("qca: disable logging status %d\n", status);
	status = qca_command(&reader, 0x0c03, NULL, 0, 5000, NULL, 0, NULL);
	bt_log("qca: reset status %d\n", status);
	if (qca_version(&reader, &product, &patch, &rom, &soc)) {
		bt_log("qca: booted patch 0x%04x rom 0x%04x\n", patch, rom);
	}
	if (access("/private/var/vm/bt-ext-probe", F_OK) == 0) {
		qca_probe_scan(&reader);
	}
	/* Nothing the burst left behind may reach the daemon's H4 parser. */
	for (i = 0; i < 50 && reader.len > 0; i++) {
		reader.len = 0;
		if (qca_read_more(&reader, 20) <= 0) {
			break;
		}
	}
	syscall(SYS_close, fd);
	free(fw);
	free(nvm);
}

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
	/* This runs on the main thread, before main(). */
	main_thread = mach_thread_self();
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
	bt_log("init v63 %s uid %d log \"%s\" boot %ld inherited \"%s\" "
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
		qca_boot();
		fix_h4_transport();
		hook_power_method();
		/*
		 * main() allocates the server, so the init hook has to be in
		 * place before it runs.
		 */
		hook_server_entry();
		hook_device_found();
		dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 4000000000LL),
		    dispatch_get_global_queue(0, 0), NULL, runtime_dump);
	}
}
