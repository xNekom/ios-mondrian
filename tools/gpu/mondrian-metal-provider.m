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
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

id native_bridge_metal_open(const char *loader, const char *cache, uint64_t registryID, void (*missing)(const char *, const char *));
size_t native_bridge_metal_status(char *out, size_t size);
uint64_t native_bridge_metal_first_problem(char *out, size_t size);

#define TURNIP "/private/var/vm/libvulkan_freedreno.dylib"
#define CACHE "/private/var/tmp/m2v"

/* The kernel's 0385 gate injects this dylib; this second gate arms the test. */
#define MONDRIAN_METAL_PROBE_FILE "/private/var/vm/mondrian-metal-probe"
#define MONDRIAN_METAL_PROBE_SIDE 64u
#define MONDRIAN_METAL_PROBE_PIXELS (MONDRIAN_METAL_PROBE_SIDE * MONDRIAN_METAL_PROBE_SIDE)
#define MONDRIAN_METAL_PROBE_TIMEOUT 20

static void mondrian_metal_probe_constructor(void);

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
	if (n > (int)sizeof(line) - 1) {
		n = (int)sizeof(line) - 1;
	}
	/*
	 * WebKit's GPU process is sandboxed and cannot open /dev/console; logd
	 * is what reaches the ring from there (the hook's own lines are
	 * `|SpringBoard| MONDRIAN ...` for the same reason). Both paths, so
	 * the same dylib still talks in an unsandboxed process.
	 */
	NSLog(@"%s", line);
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

/*
 * Loaded is not the same as used: DYLD_INSERT_LIBRARIES can be refused, and a
 * client that never asks for a device says nothing either way. The line this
 * prints at load is what tells the two apart from the ring.
 */
__attribute__((constructor))
static void
mondrian_metal_loaded(void)
{
	mondrian_metal_say("mondrian-metal: loaded into %s\n", getprogname());
	mondrian_metal_probe_constructor();
}

/*
 * Does the GPU process actually submit work through this device? The page
 * surfaces stay zero with the device created, which is either "WebKit never
 * draws" or "WebKit draws and the result never lands". Counting the command
 * buffers and their commits separates the two, and nothing else does: the
 * client's own errors do not reach the ring.
 */
static unsigned mondrian_cb_count;
static unsigned mondrian_commit_count;
static unsigned mondrian_present_count;
static unsigned mondrian_wait_count;
static unsigned mondrian_queue_count;
static IMP mondrian_orig_new_queue;
static IMP mondrian_orig_command_buffer;
static IMP mondrian_orig_commit;
static IMP mondrian_orig_present;
static IMP mondrian_orig_wait;

static void
mondrian_metal_counts(const char *what)
{
	mondrian_metal_say(
	    "mondrian-metal: %s queues %u buffers %u commits %u presents %u waits %u\n",
	    what, mondrian_queue_count, mondrian_cb_count, mondrian_commit_count,
	    mondrian_present_count, mondrian_wait_count);
}

static void
mondrian_metal_commit(id self, SEL _cmd)
{
	mondrian_commit_count++;
	if (mondrian_commit_count <= 3 || (mondrian_commit_count % 200) == 0) {
		mondrian_metal_counts("commit");
	}
	((void (*)(id, SEL))mondrian_orig_commit)(self, _cmd);
}

static void
mondrian_metal_present(id self, SEL _cmd, id drawable)
{
	mondrian_present_count++;
	if (mondrian_present_count <= 3 || (mondrian_present_count % 200) == 0) {
		mondrian_metal_counts("present");
	}
	((void (*)(id, SEL, id))mondrian_orig_present)(self, _cmd, drawable);
}

static void
mondrian_metal_wait(id self, SEL _cmd)
{
	mondrian_wait_count++;
	if (mondrian_wait_count <= 3 || (mondrian_wait_count % 200) == 0) {
		mondrian_metal_counts("wait");
	}
	((void (*)(id, SEL))mondrian_orig_wait)(self, _cmd);
}

/* Swizzles once per class; a class that does not answer is left alone. */
static void
mondrian_metal_hook_class(id object, SEL selector, IMP replacement, IMP *original)
{
	Class cls;
	Method method;

	if (object == nil || *original != NULL) {
		return;
	}
	cls = object_getClass(object);
	method = class_getInstanceMethod(cls, selector);
	if (method == NULL) {
		return;
	}
	*original = method_setImplementation(method, replacement);
}

static id
mondrian_metal_command_buffer(id self, SEL _cmd)
{
	id buffer = ((id (*)(id, SEL))mondrian_orig_command_buffer)(self, _cmd);

	mondrian_cb_count++;
	if (mondrian_cb_count <= 3 || (mondrian_cb_count % 200) == 0) {
		mondrian_metal_counts("buffer");
	}
	if (buffer != nil) {
		mondrian_metal_hook_class(buffer, @selector(commit),
		    (IMP)mondrian_metal_commit, &mondrian_orig_commit);
		mondrian_metal_hook_class(buffer, @selector(presentDrawable:),
		    (IMP)mondrian_metal_present, &mondrian_orig_present);
		mondrian_metal_hook_class(buffer, @selector(waitUntilCompleted),
		    (IMP)mondrian_metal_wait, &mondrian_orig_wait);
	}
	return buffer;
}

static id
mondrian_metal_new_queue(id self, SEL _cmd)
{
	id queue = ((id (*)(id, SEL))mondrian_orig_new_queue)(self, _cmd);

	mondrian_queue_count++;
	mondrian_metal_counts("queue");
	if (queue != nil) {
		mondrian_metal_hook_class(queue, @selector(commandBuffer),
		    (IMP)mondrian_metal_command_buffer, &mondrian_orig_command_buffer);
	}
	return queue;
}

static void
mondrian_metal_make(void)
{
	/*
	 * The runtime's and Turnip's diagnostics go to stderr, and stderr in a
	 * WebKit process is discarded: the ring is /dev/console. Without this,
	 * a refused command buffer inside the GPU process says nothing.
	 */
	(void)freopen("/dev/console", "w", stderr);
	mondrian_metal_device = native_bridge_metal_open(TURNIP, CACHE, 0, mondrian_metal_missing);
	if (mondrian_metal_device != nil) {
		mondrian_metal_say("mondrian-metal: device \"%s\" for %s\n",
		    [[mondrian_metal_device name] UTF8String], getprogname());
		mondrian_metal_hook_class(mondrian_metal_device,
		    @selector(newCommandQueue), (IMP)mondrian_metal_new_queue,
		    &mondrian_orig_new_queue);
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

/*
 * File-gated WebKit GPU probe. The design follows iOSPlus10's NegroniMetal
 * selftest (MIT) and this tree's m2v_test.m (MIT, HakiOS authors); this
 * implementation is original. It deliberately calls the provider's own
 * factory, the function installed in __DATA,__interpose, so the test does not
 * depend on WebKit happening to ask Metal first.
 */
static void
mondrian_metal_probe_status(const char *verdict)
{
	char status[512] = "", problem[256] = "";

	(void)native_bridge_metal_status(status, sizeof(status));
	if (native_bridge_metal_first_problem(problem, sizeof(problem)) != 0)
		mondrian_metal_say("mondrian-metal-probe: %s | %s | %s\n",
		    verdict, status, problem);
	else
		mondrian_metal_say("mondrian-metal-probe: %s | %s\n",
		    verdict, status);
}

static void __attribute__((noreturn))
mondrian_metal_probe_fail(const char *why)
{
	mondrian_metal_say("mondrian-metal-probe: FAIL %s\n", why);
	mondrian_metal_probe_status("FAIL");
	signal(SIGSEGV, SIG_DFL);
	raise(SIGSEGV);
	_exit(139);
}

static void *
mondrian_metal_probe_watchdog(void *unused)
{
	struct timespec wait = { .tv_sec = MONDRIAN_METAL_PROBE_TIMEOUT,
	    .tv_nsec = 0 };

	(void)unused;
	while (nanosleep(&wait, &wait) != 0 && errno == EINTR)
		;
	mondrian_metal_say("mondrian-metal-probe: TIMEOUT after %d s\n",
	    MONDRIAN_METAL_PROBE_TIMEOUT);
	_exit(124);
	return NULL;
}

static void *
mondrian_metal_probe_run(void *unused)
{
	(void)unused;
	@autoreleasepool {
		id<MTLDevice> device = mondrian_metal_default_device();

		if (device == nil) {
			mondrian_metal_probe_status("NO_DEVICE");
			_exit(0);
		}
		mondrian_metal_say("mondrian-metal-probe: device \"%s\"\n",
		    [[device name] UTF8String]);

		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil)
			mondrian_metal_probe_fail("newCommandQueue nil");

		NSDictionary *props = @{
			(id)kIOSurfaceWidth: @(MONDRIAN_METAL_PROBE_SIDE),
			(id)kIOSurfaceHeight: @(MONDRIAN_METAL_PROBE_SIDE),
			(id)kIOSurfaceBytesPerElement: @4,
			(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')
		};
		IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		if (surface == NULL)
			mondrian_metal_probe_fail("IOSurfaceCreate NULL");
		mondrian_metal_say("mondrian-metal-probe: surface %u %ux%u row %zu\n",
		    IOSurfaceGetID(surface), MONDRIAN_METAL_PROBE_SIDE,
		    MONDRIAN_METAL_PROBE_SIDE, IOSurfaceGetBytesPerRow(surface));

		MTLTextureDescriptor *td = [MTLTextureDescriptor
		    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		    width:MONDRIAN_METAL_PROBE_SIDE height:MONDRIAN_METAL_PROBE_SIDE
		    mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModeShared;
		id<MTLTexture> texture = [device newTextureWithDescriptor:td
		    iosurface:surface plane:0];
		if (texture == nil)
			mondrian_metal_probe_fail("IOSurface texture nil");

		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor
		    renderPassDescriptor];
		pass.colorAttachments[0].texture = texture;
		pass.colorAttachments[0].loadAction = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);

		id<MTLCommandBuffer> cb = [queue commandBuffer];
		if (cb == nil)
			mondrian_metal_probe_fail("commandBuffer nil");
		id<MTLRenderCommandEncoder> encoder =
		    [cb renderCommandEncoderWithDescriptor:pass];
		if (encoder == nil)
			mondrian_metal_probe_fail("renderCommandEncoder nil");
		[encoder endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		if (cb.status != MTLCommandBufferStatusCompleted) {
			const char *detail = cb.error.localizedDescription.UTF8String;

			mondrian_metal_probe_fail(detail != NULL ? detail :
			    "command buffer did not complete");
		}

		if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != 0)
			mondrian_metal_probe_fail("IOSurfaceLock failed");
		void *base = IOSurfaceGetBaseAddress(surface);
		size_t row = IOSurfaceGetBytesPerRow(surface);
		if (base == NULL || row < MONDRIAN_METAL_PROBE_SIDE * 4)
			mondrian_metal_probe_fail("IOSurface mapping invalid");

		NSUInteger good = 0;
		uint32_t first = 0, last = 0;
		for (NSUInteger y = 0; y < MONDRIAN_METAL_PROBE_SIDE; y++) {
			const uint32_t *pixels = (const uint32_t *)((const uint8_t *)base +
			    y * row);

			for (NSUInteger x = 0; x < MONDRIAN_METAL_PROBE_SIDE; x++) {
				uint32_t pixel = pixels[x];

				if (x == 0 && y == 0)
					first = pixel;
				last = pixel;
				good += pixel == 0xff0000ffu;
			}
		}
		IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
		CFRelease(surface);

		mondrian_metal_say("mondrian-metal-probe: clear good %lu/%u "
		    "first %#x last %#x status %ld\n",
		    (unsigned long)good, MONDRIAN_METAL_PROBE_PIXELS, first, last,
		    (long)cb.status);
		if (good != MONDRIAN_METAL_PROBE_PIXELS)
			mondrian_metal_probe_fail("pixel readback wrong");

		mondrian_metal_probe_status("PASS");
		signal(SIGABRT, SIG_DFL);
		abort();
		_exit(134);
	}
	return NULL;
}

static void
mondrian_metal_probe_constructor(void)
{
	struct stat st;
	pthread_t probe, watchdog;

	if (strcmp(getprogname(), "com.apple.WebKit.GPU") != 0 ||
	    stat(MONDRIAN_METAL_PROBE_FILE, &st) != 0 || !S_ISREG(st.st_mode))
		return;
	if (pthread_create(&watchdog, NULL, mondrian_metal_probe_watchdog,
	    NULL) != 0)
		_exit(125);
	pthread_detach(watchdog);
	if (pthread_create(&probe, NULL, mondrian_metal_probe_run, NULL) != 0)
		_exit(126);
	pthread_detach(probe);
}
