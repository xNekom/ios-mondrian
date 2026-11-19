/*
 * bluetoothd's diagnostic shim, injected at exec by 0389.
 *
 * The daemon cannot log anywhere this port can read: launchd gives it
 * /dev/null, its job cannot be edited (the launchd table is load-bearing for
 * early boot, see docs/MONDIAN_WIRELESS.md), and /dev/console does not reach
 * the ring. So the shim claims descriptors 1 and 2 for a file the ring's `rf`
 * reads back, and hands the daemon the transport it needs.
 *
 * The transport is set here rather than on the kernel's command line so that
 * changing it costs a `wfile` and a boot, not a kernel build.
 */
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOG_PATH "/private/var/tmp/bt-inject.log"
#define TRANSPORT "H4:POSIX"
#define PORT "/dev/cu.bluetooth"

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
bt_exit(void)
{
	bt_log("atexit\n");
}

__attribute__((constructor))
static void
mondrian_bt_init(void)
{
	int fd;

	fd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		dup2(fd, STDOUT_FILENO);
		dup2(fd, STDERR_FILENO);
		if (fd > STDERR_FILENO) {
			close(fd);
		}
	}
	setenv("BT_HCI_TRANSPORT", TRANSPORT, 1);
	bt_log("init uid %d transport \"%s\" port access %d\n", getuid(),
	    getenv("BT_HCI_TRANSPORT") != NULL ? getenv("BT_HCI_TRANSPORT") : "(null)",
	    access(PORT, F_OK));
	atexit(bt_exit);
}
