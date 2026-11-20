/*
 * bluetoothd's diagnostic shim, injected at exec by 0389.
 *
 * The daemon cannot log anywhere this port can read: launchd gives it
 * /dev/null, its job cannot be edited (the launchd table is load-bearing for
 * early boot, see docs/MONDIAN_WIRELESS.md), and /dev/console does not reach
 * the ring. So the shim claims descriptors 1 and 2 for the first file it can
 * open, and hands the daemon the transport it needs.
 *
 * Its failure report is unreadable (an os_log message built at runtime), so
 * the account comes from the registers it leaves behind: the restart helper
 * keeps the reason in x19 and the context string in x20 across its own call
 * to the logger, and the trampoline below reads both at `_exit`. Each is also
 * read back as a string through mach_vm_read_overwrite, which answers an
 * error instead of faulting on a bad address.
 *
 * The job runs as `mobile`, not root, so a sandboxed daemon is denied most
 * paths: /private/var/tmp answered ENOENT to `rf` after a boot whose shim
 * could not open it. The candidate list starts in mobile's own Library.
 *
 * The transport is set here rather than on the kernel's command line so that
 * changing it costs a `wfile` and a boot, not a kernel build.
 */
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
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

static void bt_backtrace(const char *why);

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
	/*
	 * A file descriptor is fully buffered, and the daemon leaves through
	 * _exit, which discards the buffer: with buffering on, the log ends at
	 * whatever the last 4 KB flush happened to catch (measured 2026-11-20).
	 */
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	bt_log("init uid %d log \"%s\" transport \"%s\" baud \"%s\" port %d\n",
	    getuid(),
	    chosen != NULL ? chosen : "(none)",
	    getenv("BT_HCI_TRANSPORT") != NULL ? getenv("BT_HCI_TRANSPORT") : "(null)",
	    getenv("BT_BAUDRATE") != NULL ? getenv("BT_BAUDRATE") : "(null)",
	    access(PORT, F_OK));
}
