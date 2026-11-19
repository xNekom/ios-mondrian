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
	int count, killed = 0, list = 0, shown = 0;
	const char *want;

	if (argc < 2) {
		printf("kill_proc: usage: kill_proc [-l] NAME-PREFIX\n");
		return 2;
	}
	/* -l lists the matches instead of killing them: p_comm is 16 bytes and
	 * a name guessed wrong kills nothing and says nothing. */
	if (strcmp(argv[1], "-l") == 0) {
		list = 1;
		want = argc > 2 ? argv[2] : "";
	} else {
		want = argv[1];
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
		if (strncmp(procs[i].kp_proc.p_comm, want, strlen(want)) != 0) {
			continue;
		}
		if (list) {
			if (shown++ < 40) {
				printf("kill_proc: LIST '%s' %d\n",
				    procs[i].kp_proc.p_comm, pid);
			}
			continue;
		}
		printf("kill_proc: %s %d\n", procs[i].kp_proc.p_comm, pid);
		if (kill(pid, SIGKILL) == 0) {
			killed++;
		}
	}
	printf("kill_proc: %d %s, %d total\n", list ? shown : killed,
	    list ? "listed" : "killed", count);
	free(procs);
	return list ? 0 : (killed > 0 ? 0 : 1);
}
