/*
 * The m2v Metal device as a dylib a process can load: AdrenoMetal's frontend
 * over metal2vulkan over Turnip (tools/mk-m2v-ios.sh). It interposes Metal's
 * two factory functions, so a client that asks for a system default device
 * gets this one without knowing anything changed; a process that never loads
 * this dylib is unaffected.
 *
 * Meant for com.apple.WebKit.GPU, whose page surfaces stay zero because it
 * renders through Metal (0379/0380). Loaded by name, not by the UI hook: the
 * hook is injected into processes that must not depend on Metal.framework.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

id native_bridge_metal_open(const char *loader, const char *cache, uint64_t registryID, void (*missing)(const char *, const char *));

#define TURNIP "/private/var/vm/libvulkan_freedreno.dylib"
#define CACHE "/private/var/tmp/m2v"

static pthread_once_t mondrian_metal_once = PTHREAD_ONCE_INIT;
static id mondrian_metal_device;
static int mondrian_metal_console = -1;

/* stderr in a WebKit process goes nowhere: the ring is /dev/console. */
static void
mondrian_metal_say(const char *format, ...)
{
	char line[512];
	va_list args;
	int n;

	va_start(args, format);
	n = vsnprintf(line, sizeof(line), format, args);
	va_end(args);
	if (n <= 0) {
		return;
	}
	if (mondrian_metal_console < 0) {
		mondrian_metal_console = open("/dev/console", O_WRONLY);
	}
	if (mondrian_metal_console >= 0) {
		(void)write(mondrian_metal_console, line, (size_t)n);
	}
	(void)write(STDERR_FILENO, line, (size_t)n);
}

static void
mondrian_metal_missing(const char *class, const char *selector)
{
	mondrian_metal_say("mondrian-metal: missing -[%s %s]\n", class, selector);
}

static void
mondrian_metal_make(void)
{
	mondrian_metal_device = native_bridge_metal_open(TURNIP, CACHE, 0, mondrian_metal_missing);
	if (mondrian_metal_device != nil) {
		mondrian_metal_say("mondrian-metal: device \"%s\" for %s\n",
		    [[mondrian_metal_device name] UTF8String], getprogname());
	} else {
		mondrian_metal_say("mondrian-metal: no device for %s\n", getprogname());
	}
}

static id
mondrian_metal_default_device(void)
{
	pthread_once(&mondrian_metal_once, mondrian_metal_make);
	return mondrian_metal_device;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
	const void *replacement;
	const void *replaced;
} mondrian_metal_interpose[] = {
	{ (const void *)mondrian_metal_default_device, (const void *)MTLCreateSystemDefaultDevice },
};
