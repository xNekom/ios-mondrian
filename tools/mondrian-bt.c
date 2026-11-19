/*
 * bluetoothd's diagnostic shim, injected at exec by 0389.
 *
 * The daemon cannot log anywhere this port can read: launchd gives it
 * /dev/null, its job cannot be edited (the launchd table is load-bearing for
 * early boot, see docs/MONDIAN_WIRELESS.md), and /dev/console does not reach
 * the ring. So the shim claims descriptors 1 and 2 for the first file it can
 * open, and hands the daemon the transport it needs.
 *
 * The job runs as `mobile`, not root, so a sandboxed daemon is denied most
 * paths: /private/var/tmp answered ENOENT to `rf` after a boot whose shim
 * could not open it. The candidate list starts in mobile's own Library, which
 * is where the preferences it already reads live.
 *
 * The daemon leaves through `_exit`, which runs no atexit handler, so the
 * interposer below logs the status and the call addresses. They are printed as
 * offsets from the main image, which is what the disassembly of
 * /usr/sbin/bluetoothd uses.
 *
 * The transport is set here rather than on the kernel's command line so that
 * changing it costs a `wfile` and a boot, not a kernel build.
 */
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define TRANSPORT "H4:POSIX"
#define BAUDRATE "115200"
#define PORT "/dev/cu.bluetooth"

static const char *const log_paths[] = {
	"/private/var/mobile/Library/Preferences/mondrian-bt.log",
	"/private/var/mobile/Library/Logs/mondrian-bt.log",
	"/private/var/log/mondrian-bt.log",
	"/private/var/tmp/mondrian-bt.log",
	"/dev/console",
};

static const char *chosen;

static void
bt_log(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n;

	n = snprintf(line, sizeof(line), "mondrian-bt[%d]: ", getpid());
	if (n < 0) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	write(STDERR_FILENO, line, strlen(line));
}

/*
 * The daemon's own failure path ends in `_exit`, so this is the only place
 * that can report where it gave up.
 */
__attribute__((noreturn))
static void
mondrian_bt_exit(int status)
{
	void *frames[24];
	int n;
	int i;
	uintptr_t base = (uintptr_t)_dyld_get_image_header(0);

	bt_log("_exit(%d)\n", status);
	n = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
	for (i = 0; i < n; i++) {
		bt_log("  frame %d 0x%lx\n", i,
		    (unsigned long)((uintptr_t)frames[i] - base));
	}
	syscall(SYS_exit, status);
	__builtin_unreachable();
}

static const struct {
	const void *replacement;
	const void *replacee;
} interposers[] __attribute__((used, section("__DATA,__interpose"))) = {
	{ (const void *)mondrian_bt_exit, (const void *)_exit },
};

__attribute__((constructor))
static void
mondrian_bt_init(void)
{
	size_t i;
	int fd;

	for (i = 0; i < sizeof(log_paths) / sizeof(log_paths[0]); i++) {
		fd = open(log_paths[i], O_WRONLY | O_CREAT | O_APPEND, 0666);
		if (fd >= 0) {
			chosen = log_paths[i];
			dup2(fd, STDOUT_FILENO);
			dup2(fd, STDERR_FILENO);
			if (fd > STDERR_FILENO) {
				close(fd);
			}
			break;
		}
	}
	setenv("BT_HCI_TRANSPORT", TRANSPORT, 1);
	setenv("BT_BAUDRATE", BAUDRATE, 1);
	bt_log("init uid %d log \"%s\" transport \"%s\" baud \"%s\" port %d\n",
	    getuid(),
	    chosen != NULL ? chosen : "(none)",
	    getenv("BT_HCI_TRANSPORT") != NULL ? getenv("BT_HCI_TRANSPORT") : "(null)",
	    getenv("BT_BAUDRATE") != NULL ? getenv("BT_BAUDRATE") : "(null)",
	    access(PORT, F_OK));
}
