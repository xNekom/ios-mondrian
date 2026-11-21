/*
 * Every thread of one daemon, named, for the processes the UI hook cannot
 * enter.
 *
 * tools/mondrian-ui-hook.m carries interposers (sandbox, TCC, IORegistry) that
 * belong to the services and to SpringBoard, not to an arbitrary daemon, so it
 * is not the thing to inject into lsd or cfprefsd. Patch 0306 already has the
 * narrow path: `mondrian_probe=1 mondrian_probe_proc=<name>` puts
 * /private/var/vm/mondrian-probe.dylib inside exactly that exec. This dylib is
 * what goes there when the question is "which thread holds the lock".
 *
 * It links nothing but libSystem on purpose: a daemon's dyld work is not where
 * this probe should add load. The output goes to /dev/console, which on this
 * port is the kernel ring, and each frame is named by dladdr or by
 * image+offset when the shared cache ships no symbol.
 *
 * Build: tools/build-mondrian-thrprobe.sh out/gpu/mondrian-thrprobe.dylib
 * Deploy: tools/usb-ring.py wfile /private/var/vm/mondrian-probe.dylib OUT
 *         (that path is the one patch 0306 injects; the bring-up probe that
 *          normally lives there is rebuilt by tools/build-mondrian-probe.sh)
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/arm/thread_status.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int thr_out = -1;

static void
thr_say(const char *message)
{
	if (thr_out >= 0) {
		(void)write(thr_out, message, strlen(message));
	}
}

static void
thr_frame(uint64_t addr, char *out, size_t size)
{
	Dl_info info;

	if (addr == 0) {
		snprintf(out, size, "-");
		return;
	}
	if (dladdr((void *)(uintptr_t)addr, &info) != 0) {
		if (info.dli_sname != NULL &&
		    strcmp(info.dli_sname, "<redacted>") != 0) {
			snprintf(out, size, "%s+%ld", info.dli_sname,
			    (long)((char *)(uintptr_t)addr -
			    (char *)info.dli_saddr));
			return;
		}
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

static void
thr_dump(void)
{
	thread_act_array_t list = NULL;
	mach_msg_type_number_t count = 0;
	char head[128];
	static unsigned round;

	if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS ||
	    list == NULL) {
		thr_say("MONDRIAN THRP: task_threads failed\n");
		return;
	}
	snprintf(head, sizeof(head), "MONDRIAN THRP[%d]: %u threads, dump %u\n",
	    (int)getpid(), (unsigned)count, ++round);
	thr_say(head);
	for (mach_msg_type_number_t i = 0; i < count; i++) {
		arm_thread_state64_t state;
		mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
		thread_identifier_info_data_t id;
		mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
		char line[1400], f[16][72];
		uint64_t fp;
		int used = 2;

		if (thread_get_state(list[i], ARM_THREAD_STATE64,
		    (thread_state_t)&state, &sc) != KERN_SUCCESS) {
			mach_port_deallocate(mach_task_self(), list[i]);
			continue;
		}
		thr_frame(state.__pc, f[0], sizeof(f[0]));
		thr_frame(state.__lr, f[1], sizeof(f[1]));
		fp = state.__fp;
		for (int k = 2; k < 16 && fp >= 0x100000000ULL; k++) {
			uint64_t frame[2];
			vm_size_t got = 0;

			if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
			    sizeof(frame), (vm_address_t)frame, &got) !=
			    KERN_SUCCESS || got != sizeof(frame) ||
			    frame[1] == 0) {
				break;
			}
			thr_frame(frame[1], f[k], sizeof(f[k]));
			used = k + 1;
			fp = frame[0];
		}
		memset(&id, 0, sizeof(id));
		(void)thread_info(list[i], THREAD_IDENTIFIER_INFO,
		    (thread_info_t)&id, &ic);
		{
			char *p = line;
			size_t left = sizeof(line);
			int k = snprintf(p, left, "MONDRIAN THRP[%d]: t %llu",
			    (int)getpid(), (unsigned long long)id.thread_id);

			p += k;
			left -= (size_t)k;
			for (int j = 0; j < used && left > 8; j++) {
				k = snprintf(p, left, " %s", f[j]);
				p += k;
				left -= (size_t)k;
			}
			snprintf(p, left, "\n");
		}
		thr_say(line);
		mach_port_deallocate(mach_task_self(), list[i]);
	}
}

static void *
thr_run(void *unused)
{
	(void)unused;
	/* Let the daemon reach the wait it is suspected of, then look twice. */
	sleep(20);
	thr_dump();
	sleep(15);
	thr_dump();
	return NULL;
}

/*
 * On demand, from the host. The fixed 20 s and 35 s samples are a guess about
 * when the wait forms; a deadlock that settles later is missed. The host writes
 * /private/var/vm/mondrian-thrprobe and this thread dumps once per new write,
 * so the sample lands at the moment the boot has reached, not at a time the
 * dylib chose before it knew. The kernel also rewrites its own blob at boot,
 * but this marker is a plain file and survives.
 */
static void *
thr_watch(void *unused)
{
	struct stat st;
	struct timespec seen = { 0, 0 };

	(void)unused;
	for (;;) {
		if (stat("/private/var/vm/mondrian-thrprobe", &st) == 0 &&
		    (st.st_mtimespec.tv_sec != seen.tv_sec ||
		    st.st_mtimespec.tv_nsec != seen.tv_nsec)) {
			seen = st.st_mtimespec;
			thr_dump();
		}
		sleep(1);
	}
	return NULL;
}

__attribute__((constructor)) static void
thr_start(void)
{
	pthread_t thread;

	thr_out = open("/dev/console", O_WRONLY | O_NOCTTY);
	thr_say("MONDRIAN THRP: loaded\n");
	if (pthread_create(&thread, NULL, thr_run, NULL) == 0) {
		(void)pthread_detach(thread);
	}
	if (pthread_create(&thread, NULL, thr_watch, NULL) == 0) {
		(void)pthread_detach(thread);
	}
}
