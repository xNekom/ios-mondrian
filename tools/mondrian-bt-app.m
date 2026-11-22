/*
 * The Settings app's outgoing XPC, alone in its own dylib.
 *
 * Tapping the device row in Settings > Bluetooth makes bluetoothd send Create
 * Connection (0x0405), but the daemon logs no client message for it and the
 * pairing client (CBConnection) is never created. To tell "the app sends
 * nothing" from "the app sends to a service nobody watches", this file logs the
 * service name and the message of every send from the process it is loaded
 * into. It is loaded only by Preferences: tools/mondrian-layer-bridge.m (the
 * only dylib every app receives) dlopens it when the program name is
 * "Preferences", because interposing XPC inside the shared bridge itself left
 * Settings painting a solid red window (measured 2026-11-22).
 *
 * Build: tools/build-mondrian-bt-app.sh
 * Off:   overwrite the installed dylib with any non-Mach-O file; the loader
 *        then fails and Preferences keeps its normal XPC.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
#include <dlfcn.h>

/* No xpc headers in this SDK path; the symbols come from the dyld cache. */
typedef void *xpc_object_t;
typedef void *xpc_connection_t;
extern const char *xpc_connection_get_name(xpc_connection_t connection);
extern char *xpc_copy_description(xpc_object_t object);
extern void xpc_connection_send_message(xpc_connection_t connection,
    xpc_object_t message);
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);
extern void xpc_connection_send_message_with_reply(
    xpc_connection_t connection, xpc_object_t message, void *queue,
    void *handler);

#define APP_XPC_MAX	400u

static unsigned app_xpc_lines;

static void
app_xpc_log(const char *what, xpc_connection_t connection, xpc_object_t message)
{
	char *text;
	char line[1400];
	const char *service = NULL;
	int fd;
	int n;

	if (app_xpc_lines >= APP_XPC_MAX || message == NULL) {
		return;
	}
	if (connection != NULL) {
		service = xpc_connection_get_name(connection);
	}
	text = xpc_copy_description(message);
	if (text == NULL) {
		return;
	}
	app_xpc_lines++;
	n = snprintf(line, sizeof(line), "app[%d] %s -> %s: %.1200s\n",
	    getpid(), what, service != NULL ? service : "(none)", text);
	free(text);
	fd = open("/private/var/mobile/Library/Preferences/mondrian-app-xpc.log",
	    O_WRONLY | O_CREAT | O_APPEND, 0666);
	if (fd < 0 || n <= 0) {
		if (fd >= 0) {
			close(fd);
		}
		return;
	}
	(void)write(fd, line, (size_t)n);
	close(fd);
}

static void
app_xpc_send(xpc_connection_t connection, xpc_object_t message)
{
	void (*original)(xpc_connection_t, xpc_object_t);

	original = (void (*)(xpc_connection_t, xpc_object_t))
	    dlsym(RTLD_NEXT, "xpc_connection_send_message");
	app_xpc_log("send", connection, message);
	if (original != NULL) {
		original(connection, message);
	}
}

static xpc_object_t
app_xpc_send_sync(xpc_connection_t connection, xpc_object_t message)
{
	xpc_object_t (*original)(xpc_connection_t, xpc_object_t);

	original = (xpc_object_t (*)(xpc_connection_t, xpc_object_t))
	    dlsym(RTLD_NEXT, "xpc_connection_send_message_with_reply_sync");
	app_xpc_log("sync", connection, message);
	return original != NULL ? original(connection, message) : NULL;
}

__attribute__((used)) static struct {
	const void *replacement;
	const void *replacee;
} app_xpc_interposers[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)app_xpc_send,
	  (const void *)xpc_connection_send_message },
	{ (const void *)app_xpc_send_sync,
	  (const void *)xpc_connection_send_message_with_reply_sync },
};
