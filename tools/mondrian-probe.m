/*
 * The accessory init that stops backboardd, answered instead of awaited.
 *
 * A boot with the UI hook out of backboardd (mondrian_ui_hook=61) gets past
 * the logging block and stops in CoreAccessoriesInitForHID -> dispatch_sync ->
 * mach_msg; the compositor then never reaches display bring-up (present 0/s,
 * no framebuffer selectors). Reproducing the call from another process hangs
 * in the same frame, so the wait belongs to the framework, not to backboardd's
 * call site.
 *
 * This dylib is injected with mondrian_probe=1
 * mondrian_probe_proc=backboardd, links Foundation and CoreAccessories and
 * nothing else (no QuartzCore: the UI hook's CA link is what moves
 * backboardd's logging wait ahead of everything), and returns from that call
 * so the rest of the startup runs. The report thread reads
 * CARenderServerIsRunning through dlsym, so observing the server does not
 * create one.
 */
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>

extern void CoreAccessoriesInitForHID(void);

static void
say(const char *message)
{
	FILE *console = fopen("/dev/console", "a");

	if (console == NULL) {
		return;
	}
	fputs(message, console);
	fclose(console);
}

/*
 * The replacement: the caller wanted the accessory HID stack wired up, and on
 * a phone with no accessory hardware the only thing it does here is wait for a
 * Mach reply that never comes. Returning keeps the caller's state machine
 * moving, which is what this boot is measuring.
 */
static void
mondrian_skip_accessory_init(void)
{
	say("MONDRIAN BBPROBE: CoreAccessoriesInitForHID skipped\n");
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
	const void *replacement;
	const void *replacee;
} mondrian_probe_interposers[] = {
	{ (const void *)mondrian_skip_accessory_init,
	  (const void *)CoreAccessoriesInitForHID },
};

static void *
mondrian_probe_report(void *unused)
{
	int (*is_running)(void);
	char line[160];

	(void)unused;
	for (int i = 0; i < 12; i++) {
		sleep(10);
		is_running = (int (*)(void))dlsym(RTLD_DEFAULT,
		    "CARenderServerIsRunning");
		snprintf(line, sizeof(line),
		    "MONDRIAN BBPROBE: t %d render server %d\n", (i + 1) * 10,
		    is_running != NULL ? is_running() : -1);
		say(line);
	}
	return NULL;
}

static void *
mondrian_probe_container(void *unused)
{
	char *(*path_for)(const char *);
	char line[192];

	(void)unused;
	/*
	 * The kernel trace only records sends after t=75 s, and backboardd's
	 * own container query happens before that, so the probe repeats it here:
	 * the send this makes is recorded with the owner of the destination
	 * port, which names the process that never answers.
	 */
	sleep(90);
	path_for = (char *(*)(const char *))dlsym(RTLD_DEFAULT,
	    "container_system_path_for_identifier");
	snprintf(line, sizeof(line), "MONDRIAN BBPROBE: container probe %p\n",
	    (void *)path_for);
	say(line);
	if (path_for == NULL) {
		return NULL;
	}
	{
		char *path = path_for("com.apple.backboardd");

		snprintf(line, sizeof(line),
		    "MONDRIAN BBPROBE: container path %s\n",
		    path != NULL ? path : "(null)");
		say(line);
		free(path);
	}
	return NULL;
}

__attribute__((constructor))
static void
mondrian_probe_start(void)
{
	char line[192];
	pthread_t thread;

	snprintf(line, sizeof(line), "MONDRIAN BBPROBE: loaded pid %d %s acc %p\n",
	    getpid(), getprogname(),
	    dlsym(RTLD_DEFAULT, "CoreAccessoriesInitForHID"));
	say(line);
	if (pthread_create(&thread, NULL, mondrian_probe_report, NULL) == 0) {
		pthread_detach(thread);
	}
	if (pthread_create(&thread, NULL, mondrian_probe_container, NULL) == 0) {
		pthread_detach(thread);
	}
}
