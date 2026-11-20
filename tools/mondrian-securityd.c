/*
 * securityd's diagnostic shim, injected at exec like tools/mondrian-bt.c.
 *
 * securityd is the only process that sees the keychain's refusal, and it has
 * nowhere to say it: launchd gives the job /dev/null, /dev/console does not
 * reach the ring, and the job table cannot be edited (writing it stopped the
 * boot at two processes, see docs/MONDIAN_WIRELESS.md). Measured 2026-11-20,
 * the kernel side answers everything securityd asks - selectors 14, 10 and 11
 * all return 0x0 - and SecItemAdd still comes back errSecNotAvailable
 * (-25291), so the reason exists only in this process.
 *
 * This claims stderr for a file `rf` can read and writes the os_log formats
 * that mention the keychain, an error or a bag, plus the status and backtrace
 * of a non-zero _exit.
 */
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char *const log_paths[] = {
	"/private/var/mobile/Library/Preferences/mondrian-securityd.log",
	"/private/var/log/mondrian-securityd.log",
	"/dev/console",
};

static const char *const interesting[] = {
	"keychain", "Keychain", "SecItem", "item", "bag", "Bag", "AKS",
	"aks", "error", "Error", "fail", "Fail", "locked", "Locked",
};

static void
sd_log(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	int n;

	n = snprintf(line, sizeof(line), "mondrian-sd[%d]: ", getpid());
	if (n < 0) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	write(STDERR_FILENO, line, strlen(line));
}

static int
wanted(const char *format)
{
	size_t i;

	if (format == NULL) {
		return 0;
	}
	for (i = 0; i < sizeof(interesting) / sizeof(interesting[0]); i++) {
		if (strstr(format, interesting[i]) != NULL) {
			return 1;
		}
	}
	return 0;
}

#define INTERPOSE_LOG(fn, kind)						\
	static void							\
	my_##fn(void *dso, os_log_t log, os_log_type_t type,		\
	    const char *format, uint8_t *buf, unsigned size)		\
	{								\
		(void)dso; (void)log; (void)type; (void)buf; (void)size;	\
		if (wanted(format)) {					\
			sd_log("oslog.%s %s\n", kind, format);		\
		}							\
	}

INTERPOSE_LOG(os_log_impl, "default")
INTERPOSE_LOG(os_log_error_impl, "error")
INTERPOSE_LOG(os_log_fault_impl, "fault")
INTERPOSE_LOG(os_log_debug_impl, "debug")

static void
sd_backtrace(const char *why)
{
	void *frames[16];
	int n, i;

	sd_log("%s from %p\n", why, __builtin_return_address(0));
	n = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
	for (i = 0; i < n; i++) {
		Dl_info info;

		if (dladdr(frames[i], &info) == 0 || info.dli_fname == NULL) {
			continue;
		}
		sd_log("  frame %d %s + 0x%lx\n", i,
		    strrchr(info.dli_fname, '/') != NULL ?
		    strrchr(info.dli_fname, '/') + 1 : info.dli_fname,
		    (unsigned long)((uintptr_t)frames[i] -
		    (uintptr_t)info.dli_fbase));
	}
}

/* Global: the trampoline is assembler and must not be a static symbol. */
void
sd_report_exit(int status)
{
	if (status == 0) {
		return;
	}
	sd_log("_exit(%d)\n", status);
	sd_backtrace("exit");
}

__attribute__((naked, noreturn))
static void
mondrian_sd_exit(void)
{
	__asm__ volatile(
		"sub\tsp, sp, #16\n"
		"str\tw0, [sp, #8]\n"
		"bl\t_sd_report_exit\n"
		"ldr\tw0, [sp, #8]\n"
		"mov\tx16, #1\n"
		"svc\t#0x80\n"
		"brk\t#0\n");
}

static const struct {
	const void *replacement;
	const void *replacee;
} interposers[] __attribute__((used, section("__DATA,__interpose"))) = {
	{ (const void *)mondrian_sd_exit, (const void *)_exit },
	{ (const void *)my_os_log_impl, (const void *)_os_log_impl },
	{ (const void *)my_os_log_error_impl, (const void *)_os_log_error_impl },
	{ (const void *)my_os_log_fault_impl, (const void *)_os_log_fault_impl },
	{ (const void *)my_os_log_debug_impl, (const void *)_os_log_debug_impl },
};

__attribute__((constructor))
static void
mondrian_sd_init(void)
{
	size_t i;
	int fd;

	for (i = 0; i < sizeof(log_paths) / sizeof(log_paths[0]); i++) {
		fd = open(log_paths[i], O_WRONLY | O_CREAT | O_APPEND, 0666);
		if (fd >= 0) {
			dup2(fd, STDOUT_FILENO);
			dup2(fd, STDERR_FILENO);
			if (fd > STDERR_FILENO) {
				close(fd);
			}
			break;
		}
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	sd_log("init uid %d log %s\n", getuid(), log_paths[i < 3 ? i : 0]);
}
