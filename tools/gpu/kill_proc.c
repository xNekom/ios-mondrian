/*
 * Kill a process by name. WebKit's GPU process loads the Metal provider at
 * exec (0385), so a new one is the only way to see what this build does with
 * it; WebKit starts another on demand. p_comm is 16 bytes, so the match is on
 * that prefix, and the caller's own pid is never touched.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/types.h>

int
main(int argc, char **argv)
{
	struct kinfo_proc *procs;
	size_t size = 0;
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	int count, killed = 0;

	if (argc < 2) {
		printf("kill_proc: usage: kill_proc NAME-PREFIX\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
		printf("kill_proc: sysctl size failed\n");
		return 1;
	}
	procs = malloc(size);
	if (procs == NULL) {
		return 1;
	}
	if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
		printf("kill_proc: sysctl failed\n");
		return 1;
	}
	count = (int)(size / sizeof(*procs));
	for (int i = 0; i < count; i++) {
		pid_t pid = procs[i].kp_proc.p_pid;

		if (pid == getpid() || pid <= 1) {
			continue;
		}
		if (strncmp(procs[i].kp_proc.p_comm, argv[1],
		    strlen(argv[1])) != 0) {
			continue;
		}
		printf("kill_proc: %s %d\n", procs[i].kp_proc.p_comm, pid);
		if (kill(pid, SIGKILL) == 0) {
			killed++;
		}
	}
	printf("kill_proc: %d killed\n", killed);
	free(procs);
	return killed > 0 ? 0 : 1;
}
