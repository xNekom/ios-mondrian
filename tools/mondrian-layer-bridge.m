/*
 * The picture bridge, alone.
 *
 * On this port a layer's CGImage does not cross to the window server: the
 * server creates a surface of the picture's size and leaves it without colour
 * (docs/COREANIMATION_GLES.md). A layer whose `contents` is a filled IOSurface
 * draws, so every process that draws a picture needs this one hook.
 *
 * It is a separate dylib from tools/mondrian-ui-hook.m on purpose. That file
 * carries sixteen dyld interposers (IORegistry, sandbox, TCC, the Objective-C
 * throw path, libc++'s filesystem), and the kernel injects it for the services
 * that need them. An app needs none of that: it needs setContents: and a
 * surface, so this file is the whole of what an app receives and there is
 * nothing left in it that can change how the app behaves.
 *
 * Two measurements shape the conversion, both from the ring:
 *
 * 1. A picture can carry four real bytes a pixel under a colour space that says
 *    "monochrome" -- the Airplane Mode knob is 129x129, 8 bits a component, 32
 *    bits a pixel, 544 a row, model 1. CoreGraphics draws those bytes through
 *    the label, so the copy is labelled RGB before it is drawn
 *    (`mondrian_wall_relabel` in tools/mondrian-ui-hook.m is the same repair
 *    for the wallpaper). Without it the surface holds the picture's bytes read
 *    as one component and the layer draws nothing or a smear.
 *
 * 2. CoreAnimation asks for the same picture again on every layout and state
 *    change: one boot made 1011 surfaces, and the ten-a-second 129x129 knob was
 *    a new surface each time. Each conversion is a CoreGraphics draw plus a GPU
 *    buffer in backboardd, so the arena ran out of IOVAs and began refusing
 *    (`MondrianGPU: gem_new 0x700000 refused` right next to the switch). Small
 *    pictures (<= 1 MiB) are therefore kept per CGImage, which is exact because
 *    the cache holds a reference to the image itself.
 *
 * Build: tools/build-mondrian-layer-bridge.sh [out/gpu/mondrian-layer-bridge.dylib]
 * A/B:   /private/var/vm/mondrian-layercsurf-off (existence keeps the CGImage)
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#define BRIDGE_CACHE	8
#define BRIDGE_CACHE_MAX (1024u * 1024u)

static int bridge_console = -1;
static unsigned bridge_made;
static unsigned bridge_hits;
static unsigned bridge_empty;

static void (*bridge_original)(id, SEL, id);

/*
 * One surface per picture, kept while the picture is alive. `image` is owned by
 * the entry, so a stale pointer cannot alias a different CGImage: the address
 * stays that picture's until the entry is released.
 */
static struct {
	CGImageRef image;
	IOSurfaceRef surface;
} bridge_cache[BRIDGE_CACHE];
static unsigned bridge_cache_next;

static int
bridge_file_on(const char *path)
{
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		return 0;
	}
	(void)close(fd);
	return 1;
}

/*
 * The A/B is a file, and setContents: runs thousands of times a boot, so the
 * answer is remembered for a second: the marker is not expected to change
 * inside one frame, and one open() per picture is already too many.
 */
static int
bridge_off(void)
{
	static unsigned long long looked;
	static int off;
	struct timeval now;

	(void)gettimeofday(&now, NULL);
	if (looked == 0 ||
	    (unsigned long long)now.tv_sec * 1000000ull + (unsigned)now.tv_usec -
	    looked > 1000000ull) {
		looked = (unsigned long long)now.tv_sec * 1000000ull +
		    (unsigned)now.tv_usec;
		off = bridge_file_on("/private/var/vm/mondrian-layercsurf-off");
	}
	return off;
}

static void
bridge_say(const char *line)
{
	if (bridge_console >= 0) {
		(void)write(bridge_console, line, strlen(line));
	}
}

/*
 * The Settings > Bluetooth switch does not follow a drag that toggles every
 * other UISwitch in the same app (docs/UI_PERFORMANCE.md). The ring cannot say
 * whether the gesture reaches UIControl's action dispatch, so this logs the
 * action and its target. It runs in every app the bridge enters, so it is armed
 * by a marker file: echo > /private/var/vm/bridge-switch-probe, relaunch the
 * app, then drag the switch.
 */
static BOOL (*bridge_switch_orig)(id, SEL, SEL, id, id);

static BOOL
bridge_switch_send(id self, SEL cmd, SEL action, id target, id event)
{
	char line[200];

	snprintf(line, sizeof(line),
	    "MONDRIAN BRIDGE[%d]: switch action %s -> %s\n", getpid(),
	    action != NULL ? sel_getName(action) : "(null)",
	    target != NULL ? object_getClassName(target) : "(nil)");
	bridge_say(line);
	return bridge_switch_orig(self, cmd, action, target, event);
}

/*
 * The picture under a label that does not describe it: four real bytes a pixel
 * declared as one component. Only the label changes, and only when there are
 * four bytes a pixel to keep -- a true 8-bit grey picture has `bytesPerRow`
 * below `width * 4` and is left alone.
 */
static CGImageRef
bridge_drawable(CGImageRef image)
{
	CGColorSpaceRef space = CGImageGetColorSpace(image);
	CGDataProviderRef source;
	CFDataRef data;
	CGDataProviderRef provider;
	CGColorSpaceRef rgb;
	CGImageRef copy = NULL;
	CGColorSpaceModel model;

	if (space == NULL || CGImageGetBitsPerComponent(image) != 8 ||
	    CGImageGetBitsPerPixel(image) < 24 ||
	    CGImageGetBytesPerRow(image) < CGImageGetWidth(image) * 4) {
		return NULL;
	}
	model = CGColorSpaceGetModel(space);
	if (model == kCGColorSpaceModelRGB || model == kCGColorSpaceModelCMYK) {
		return NULL;
	}
	/*
	 * Rebuilt, not CGImageCreateCopyWithColorSpace: that one requires the new
	 * colour space to have the same number of components as the old one, and
	 * one (grey) to three (RGB) is exactly the change wanted here.
	 */
	source = CGImageGetDataProvider(image);
	data = source != NULL ? CGDataProviderCopyData(source) : NULL;
	if (data == NULL) {
		return NULL;
	}
	provider = CGDataProviderCreateWithCFData(data);
	rgb = CGColorSpaceCreateDeviceRGB();
	if (provider != NULL && rgb != NULL) {
		copy = CGImageCreate(CGImageGetWidth(image), CGImageGetHeight(image),
		    8, 32, CGImageGetBytesPerRow(image), rgb,
		    CGImageGetBitmapInfo(image), provider, NULL, false,
		    kCGRenderingIntentDefault);
	}
	if (rgb != NULL) {
		CGColorSpaceRelease(rgb);
	}
	if (provider != NULL) {
		CGDataProviderRelease(provider);
	}
	CFRelease(data);
	return copy;
}

/* How many of a 7x7 grid of the surface's own memory is not zero. */
static unsigned
bridge_coverage(IOSurfaceRef surface)
{
	const uint8_t *base = IOSurfaceGetBaseAddress(surface);
	size_t row = IOSurfaceGetBytesPerRow(surface);
	size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
	unsigned found = 0, x, y;

	if (base == NULL || width == 0 || height == 0) {
		return 0;
	}
	for (y = 0; y < 7; y++) {
		for (x = 0; x < 7; x++) {
			size_t at = ((height - 1) * y / 6) * row +
			    ((width - 1) * x / 6) * 4;
			const uint8_t *p = base + at;

			if (p[0] | p[1] | p[2] | p[3]) {
				found++;
			}
		}
	}
	return found;
}

static int
bridge_draw(IOSurfaceRef surface, CGImageRef image)
{
	size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
	size_t row = IOSurfaceGetBytesPerRow(surface);
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = space != NULL ? CGBitmapContextCreate(
	    IOSurfaceGetBaseAddress(surface), width, height, 8, row, space,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;

	if (space != NULL) {
		CGColorSpaceRelease(space);
	}
	if (context == NULL) {
		return 0;
	}
	CGContextDrawImage(context,
	    CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
	CGContextFlush(context);
	CGContextRelease(context);
	return 1;
}

/*
 * Draw the picture into a surface of its own. The row is padded to 16 bytes
 * because a picture's width is its own business: the old bridge demanded a
 * width that divided by four and lost every other size.
 *
 * The label is tried first and the picture as it arrived second, so a picture
 * that CoreGraphics cannot draw under the repaired label still gets its own
 * attempt instead of a surface nothing was drawn into. `*coverage` says which
 * one worked, and 0 says neither did.
 */
static IOSurfaceRef
bridge_surface(CGImageRef image, CGImageRef *used, unsigned *coverage)
{
	size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
	size_t row = (width * 4 + 15) & ~(size_t)15;
	CFMutableDictionaryRef props;
	IOSurfaceRef surface;
	CGImageRef drawable;
	uint32_t seed = 0;
	int values[5];
	const char *keys[5] = { "IOSurfaceWidth", "IOSurfaceHeight",
	    "IOSurfaceBytesPerElement", "IOSurfaceBytesPerRow",
	    "IOSurfacePixelFormat" };
	unsigned i;

	*used = image;
	*coverage = 0;
	if (width < 4 || height < 4 || row * height > 64u * 1024 * 1024) {
		return NULL;
	}
	props = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	if (props == NULL) {
		return NULL;
	}
	values[0] = (int)width;
	values[1] = (int)height;
	values[2] = 4;
	values[3] = (int)row;
	values[4] = 'BGRA';
	for (i = 0; i < 5; i++) {
		CFStringRef key = CFStringCreateWithCString(NULL, keys[i],
		    kCFStringEncodingUTF8);
		CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType,
		    &values[i]);

		CFDictionarySetValue(props, key, number);
		CFRelease(number);
		CFRelease(key);
	}
	surface = IOSurfaceCreate(props);
	CFRelease(props);
	if (surface == NULL) {
		return NULL;
	}
	/* A copied layer holds this surface without the box -setContents: leaves. */
	if (IOSurfaceLock(surface, 0, &seed) != 0) {
		CFRelease(surface);
		return NULL;
	}
	drawable = bridge_drawable(image);
	if (drawable != NULL) {
		*used = drawable;
		(void)bridge_draw(surface, drawable);
		*coverage = bridge_coverage(surface);
	}
	if (*coverage == 0 && drawable != NULL) {
		/* The label was not the fault: try the picture as it arrived. */
		*used = image;
		(void)bridge_draw(surface, image);
		*coverage = bridge_coverage(surface);
	} else if (drawable == NULL) {
		(void)bridge_draw(surface, image);
		*coverage = bridge_coverage(surface);
	}
	if (drawable != NULL) {
		CGImageRelease(drawable);
	}
	IOSurfaceUnlock(surface, 0, &seed);
	if (*coverage == 0) {
		bridge_empty++;
	}
	return surface;
}

/* The cached surface for this picture, retained, or NULL. */
static IOSurfaceRef
bridge_cached(CGImageRef image)
{
	unsigned i;

	for (i = 0; i < BRIDGE_CACHE; i++) {
		if (bridge_cache[i].image == image && bridge_cache[i].surface != NULL) {
			return (IOSurfaceRef)CFRetain(bridge_cache[i].surface);
		}
	}
	return NULL;
}

static void
bridge_remember(CGImageRef image, IOSurfaceRef surface)
{
	unsigned slot = bridge_cache_next;

	bridge_cache_next = (bridge_cache_next + 1) % BRIDGE_CACHE;
	if (bridge_cache[slot].surface != NULL) {
		CFRelease(bridge_cache[slot].surface);
	}
	if (bridge_cache[slot].image != NULL) {
		CGImageRelease(bridge_cache[slot].image);
	}
	bridge_cache[slot].image = (CGImageRef)CFRetain(image);
	bridge_cache[slot].surface = (IOSurfaceRef)CFRetain(surface);
}

/*
 * UIKit reads a layer's contents back and expects the CGImage it set: measured
 * 2026-11-21, that read cost SpringBoard an assertion in
 * -[_UIImageCGImageContent _initWithCGImageSource:CGImage:scale:] as soon as a
 * converted layer was looked at. CoreAnimation's commit must see the surface
 * instead: measured the same day in an app, answering the commit with the
 * picture made the render server build its own format-less, zero surface for
 * the knob (`MONDRIAN SURF: backboardd create ... 129x129 fmt 0x0 bpr 544`),
 * so the app's `fmt 0x42475241` surface never left the process.
 *
 * `-contents` therefore splits on its caller: QuartzCore, whose commit builds
 * the render tree, gets what the layer holds (the surface); every other
 * reader, UIKitCore's image content included, gets the picture. The caller is
 * named once for the first reads, so the ring says which road was taken.
 *
 * The picture hangs off the layer for its lifetime, with the surface ID it was
 * made for beside it; a fixed table of sixteen cannot hold the hundreds of
 * layers SpringBoard converts, and the evicted ones answered with their
 * surfaces. The box is a CFDictionary because its callbacks hold the CGImage.
 * A copied layer never went through -setContents: and has no box; its surface
 * is rebuilt into a CGImage over its own pixels instead. There is no marker to
 * put on a surface: this port's IOSurface kernel accepts `IOSurfaceSetValue`
 * and stores nothing (MondrianSurface.cpp), so the test is the 32-bit row.
 */
static char bridge_layer_box_key;
static unsigned bridge_reads;
static unsigned bridge_copies;
static unsigned bridge_foreign;
static unsigned bridge_picture_nolock;
static unsigned bridge_contents_reads;
static unsigned bridge_commit_reads;
static id (*bridge_contents_orig)(id, SEL);

/* The image and nearest symbol behind a return address, for the ring. */
static const char *
bridge_caller(void *address, char *buffer, size_t size)
{
	Dl_info info;
	const char *base;

	if (address == NULL || dladdr(address, &info) == 0 ||
	    info.dli_fname == NULL) {
		return "?";
	}
	base = strrchr(info.dli_fname, '/');
	snprintf(buffer, size, "%s%s%s",
	    base != NULL ? base + 1 : info.dli_fname,
	    info.dli_sname != NULL ? ":" : "",
	    info.dli_sname != NULL ? info.dli_sname : "");
	return buffer;
}

/* True for CoreAnimation itself: its commit is the reader that needs the
 * surface, and giving it the picture is what produced the server's zero copy.
 * A call through a helper in another image fails this test and answers the
 * picture, which is the old, presenting behaviour. */
static bool
bridge_caller_is_quartzcore(void *address)
{
	Dl_info info;
	const char *base;

	if (address == NULL || dladdr(address, &info) == 0 ||
	    info.dli_fname == NULL) {
		return false;
	}
	base = strrchr(info.dli_fname, '/');
	return strcmp(base != NULL ? base + 1 : info.dli_fname,
	    "QuartzCore") == 0;
}

static void
bridge_side_set(id layer, IOSurfaceRef surface, CGImageRef image)
{
	CFMutableDictionaryRef box;
	CFNumberRef identity;
	int32_t value = (int32_t)IOSurfaceGetID(surface);

	box = CFDictionaryCreateMutable(NULL, 2,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (box == NULL) {
		return;
	}
	CFDictionarySetValue(box, CFSTR("picture"), image);
	identity = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
	if (identity != NULL) {
		CFDictionarySetValue(box, CFSTR("surface"), identity);
		CFRelease(identity);
	}
	objc_setAssociatedObject(layer, &bridge_layer_box_key, (id)box,
	    OBJC_ASSOCIATION_RETAIN);
	CFRelease(box);
}

static CGImageRef
bridge_side_get(id layer, IOSurfaceRef surface)
{
	CFDictionaryRef box = (CFDictionaryRef)objc_getAssociatedObject(layer,
	    &bridge_layer_box_key);
	CFNumberRef identity;
	int32_t value = 0;

	if (box == NULL) {
		return NULL;
	}
	identity = (CFNumberRef)CFDictionaryGetValue(box, CFSTR("surface"));
	if (identity == NULL || !CFNumberGetValue(identity, kCFNumberSInt32Type,
	    &value) || (uint32_t)value != IOSurfaceGetID(surface)) {
		return NULL;
	}
	return (CGImageRef)CFDictionaryGetValue(box, CFSTR("picture"));
}

#define BRIDGE_PICTURE_CACHE	8
#define BRIDGE_PICTURE_CACHE_MAX (4u * 1024u * 1024u)
static struct {
	IOSurfaceRef surface;
	uint32_t id;
	CGImageRef picture;
} bridge_picture_cache[BRIDGE_PICTURE_CACHE];
static unsigned bridge_picture_cache_next;
static pthread_mutex_t bridge_picture_lock = PTHREAD_MUTEX_INITIALIZER;

static void
bridge_picture_release(void *info, const void *data, size_t size)
{
	(void)data;
	(void)size;
	CFRelease((CFTypeRef)info);
}

/* A CGImage over the pixels a 32-bit surface already holds (see the comment above). */
static CGImageRef
bridge_surface_picture(IOSurfaceRef surface)
{
	CGDataProviderRef provider;
	CGColorSpaceRef space;
	CGImageRef picture;
	const uint8_t *base;
	size_t width, height, row, size;
	uint32_t seed = 0, id = IOSurfaceGetID(surface);
	unsigned i;
	bool locked = false;

	pthread_mutex_lock(&bridge_picture_lock);
	for (i = 0; i < BRIDGE_PICTURE_CACHE; i++) {
		if (bridge_picture_cache[i].surface == surface &&
		    bridge_picture_cache[i].id == id &&
		    bridge_picture_cache[i].picture != NULL) {
			picture = (CGImageRef)CFRetain(
			    bridge_picture_cache[i].picture);
			pthread_mutex_unlock(&bridge_picture_lock);
			return picture;
		}
	}
	pthread_mutex_unlock(&bridge_picture_lock);

	/*
	 * The picture is a view over the surface's mapped pixels, so the lock is
	 * only there to keep a writer from moving them, never to wait for the
	 * render server. Measured 2026-11-21: this code from a main-thread reader
	 * with a plain read lock froze presentation (`ca begin 0 commit 0`, no
	 * crash) -- the lock waited for the server's hold and the commit never
	 * ran. AvoidSync never blocks, and a torn readback is harmless.
	 */
	if (IOSurfaceLock(surface,
	    kIOSurfaceLockReadOnly | kIOSurfaceLockAvoidSync, &seed) == 0) {
		locked = true;
	} else if (bridge_picture_nolock++ < 4) {
		char line[120];

		snprintf(line, sizeof(line),
		    "MONDRIAN BRIDGE[%d]: surface %u picture read without "
		    "the lock\n", getpid(), id);
		bridge_say(line);
	}
	base = IOSurfaceGetBaseAddress(surface);
	width = IOSurfaceGetWidth(surface);
	height = IOSurfaceGetHeight(surface);
	row = IOSurfaceGetBytesPerRow(surface);
	if (locked) {
		IOSurfaceUnlock(surface,
		    kIOSurfaceLockReadOnly | kIOSurfaceLockAvoidSync, &seed);
	}
	if (base == NULL || width == 0 || height == 0 || row < width * 4) {
		return NULL;
	}
	size = row * height;
	CFRetain(surface);
	provider = CGDataProviderCreateWithData((void *)surface, base, size,
	    bridge_picture_release);
	if (provider == NULL) {
		CFRelease(surface);
		return NULL;
	}
	space = CGColorSpaceCreateDeviceRGB();
	picture = space != NULL ? CGImageCreate(width, height, 8, 32, row,
	    space, kCGImageAlphaPremultipliedFirst |
	    kCGBitmapByteOrder32Little, provider, NULL, false,
	    kCGRenderingIntentDefault) : NULL;
	if (space != NULL) {
		CGColorSpaceRelease(space);
	}
	CGDataProviderRelease(provider);
	if (picture == NULL) {
		return NULL;
	}
	if (size > BRIDGE_PICTURE_CACHE_MAX) {
		return picture;
	}
	pthread_mutex_lock(&bridge_picture_lock);
	i = bridge_picture_cache_next++ % BRIDGE_PICTURE_CACHE;
	if (bridge_picture_cache[i].picture != NULL) {
		CGImageRelease(bridge_picture_cache[i].picture);
	}
	bridge_picture_cache[i].surface = surface;
	bridge_picture_cache[i].id = id;
	bridge_picture_cache[i].picture = (CGImageRef)CFRetain(picture);
	pthread_mutex_unlock(&bridge_picture_lock);
	return picture;
}

static id
bridge_get_contents(id self, SEL cmd)
{
	void *caller = __builtin_return_address(0);
	bool commit = bridge_caller_is_quartzcore(caller);
	id real = bridge_contents_orig != NULL
	    ? bridge_contents_orig(self, cmd) : nil;
	CGImageRef picture = NULL;
	id result;
	bool rebuilt = false;
	char line[220];
	char name[96];

	/*
	 * The commit keeps the surface the layer was given; building a picture
	 * for it is what hid the app's surface and left the knob zero. Every
	 * other reader gets the picture, which is what UIKitCore asserts on.
	 */
	if (commit && real != nil &&
	    CFGetTypeID((CFTypeRef)real) == IOSurfaceGetTypeID() &&
	    bridge_commit_reads++ < 4) {
		snprintf(line, sizeof(line),
		    "MONDRIAN BRIDGE[%d]: contents surface %u %zux%zu handed "
		    "to QuartzCore\n", getpid(),
		    IOSurfaceGetID((IOSurfaceRef)real),
		    IOSurfaceGetWidth((IOSurfaceRef)real),
		    IOSurfaceGetHeight((IOSurfaceRef)real));
		bridge_say(line);
	}
	if (!commit && real != nil &&
	    CFGetTypeID((CFTypeRef)real) == IOSurfaceGetTypeID()) {
		IOSurfaceRef surface = (IOSurfaceRef)real;

		picture = bridge_side_get(self, surface);
		if (picture != NULL) {
			picture = (CGImageRef)CFRetain(picture);
		} else {
			picture = bridge_surface_picture(surface);
			rebuilt = picture != NULL;
		}
		if (picture == NULL && bridge_foreign++ < 4) {
			snprintf(line, sizeof(line),
			    "MONDRIAN BRIDGE[%d]: contents %zux%zu fmt %08x is "
			    "not a 32-bit picture, left a surface\n", getpid(),
			    IOSurfaceGetWidth(surface),
			    IOSurfaceGetHeight(surface),
			    (unsigned)IOSurfaceGetPixelFormat(surface));
			bridge_say(line);
		}
	}
	if (picture != NULL) {
		result = (id)CFAutorelease(picture);
		if (rebuilt) {
			if (bridge_copies++ == 0) {
				snprintf(line, sizeof(line),
				    "MONDRIAN BRIDGE[%d]: contents read back "
				    "from a surface with no picture on the "
				    "layer, rebuilt\n", getpid());
				bridge_say(line);
			}
		} else if (bridge_reads++ == 0) {
			snprintf(line, sizeof(line),
			    "MONDRIAN BRIDGE[%d]: contents read back as the "
			    "picture, surface kept\n", getpid());
			bridge_say(line);
		}
	} else {
		result = real;
	}
	if (bridge_contents_reads++ < 8) {
		snprintf(line, sizeof(line),
		    "MONDRIAN BRIDGE[%d]: contents %s for %s\n", getpid(),
		    result != nil && CFGetTypeID((CFTypeRef)result) ==
		    IOSurfaceGetTypeID() ? "surface" : "picture",
		    bridge_caller(caller, name, sizeof(name)));
		bridge_say(line);
	}
	return result;
}

static void
bridge_set_contents(id self, SEL cmd, id contents)
{
	IOSurfaceRef surface = NULL;

	if (contents != NULL && !bridge_off() &&
	    CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)contents;
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);

		if (w >= 4 && h >= 4) {
			surface = bridge_cached(image);
			if (surface != NULL) {
				if (bridge_hits++ < 4) {
					char line[160];

					snprintf(line, sizeof(line),
					    "MONDRIAN BRIDGE[%d]: %zux%zu as "
					    "cached surface %u\n", getpid(), w, h,
					    IOSurfaceGetID(surface));
					bridge_say(line);
				}
			} else {
				CGImageRef used = image;
				unsigned coverage = 0;

				surface = bridge_surface(image, &used, &coverage);
				if (surface != NULL && bridge_made++ < 8) {
					char line[220];

					snprintf(line, sizeof(line),
					    "MONDRIAN BRIDGE[%d]: %zux%zu as "
					    "surface %u bpr %zu drew %u/49%s%s\n",
					    getpid(), w, h,
					    IOSurfaceGetID(surface),
					    IOSurfaceGetBytesPerRow(surface),
					    coverage,
					    used != image ? " relabelled" : "",
					    coverage == 0 ? " empty" : "");
					bridge_say(line);
				}
				if (surface != NULL &&
				    IOSurfaceGetAllocSize(surface) <= BRIDGE_CACHE_MAX) {
					bridge_remember(image, surface);
				}
			}
			if (surface != NULL) {
				bridge_side_set(self, surface, image);
				contents = (id)surface;
			}
		}
	}
	if (bridge_original != NULL) {
		bridge_original(self, cmd, contents);
	}
	if (surface != NULL) {
		CFRelease(surface);     /* the contents retain it */
	}
}

__attribute__((constructor))

/*
 * The Bluetooth API the Settings process carries, and a line every time the
 * connect entry point runs. Both classes are bridged to bluetoothd by XPC, so a
 * tap that logs here but sends nothing to the daemon means the message is
 * dropped below this call, and a tap that logs nothing means the row does not
 * use this API at all.
 */
static void
bridge_bt_log(const char *fmt, ...)
{
	static unsigned lines;
	char line[600];
	va_list ap;
	int n;

	if (lines >= 160) {
		return;
	}
	lines++;
	n = snprintf(line, sizeof(line), "MONDRIAN BTAPP[%d]: ", getpid());
	if (n < 0 || n >= (int)sizeof(line)) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
	va_end(ap);
	bridge_say(line);
	/* bridge_say writes without a newline of its own. */
	bridge_say("\n");
}

static BOOL (*bridge_bt_connect_orig)(id, SEL, id, unsigned long,
    unsigned long, id *);

static BOOL
bridge_bt_connect(id self, SEL cmd, id device, unsigned long connection_flags,
    unsigned long service_flags, id *error)
{
	bridge_bt_log("connectDevice %s flags %lu/%lu\n",
	    self != nil ? class_getName(object_getClass(self)) : "?",
	    connection_flags, service_flags);
	if (bridge_bt_connect_orig != NULL) {
		return bridge_bt_connect_orig(self, cmd, device, connection_flags,
		    service_flags, error);
	}
	return NO;
}

static BOOL (*bridge_bt_pair_client_orig)(id, SEL, id, id *);

static BOOL
bridge_bt_pair_client(id self, SEL cmd, id client, id *error)
{
	bridge_bt_log("addPairingClient %s %s\n",
	    self != nil ? class_getName(object_getClass(self)) : "?",
	    client != nil ? class_getName(object_getClass(client)) : "(nil)");
	if (bridge_bt_pair_client_orig != NULL) {
		return bridge_bt_pair_client_orig(self, cmd, client, error);
	}
	return NO;
}

static void
bridge_bt_probe(void)
{
	static const char *names[] = {
		"CBConnection", "CBManager", "CBStackController",
		"CBStackControllerBTStack", "CBDevice"
	};
	unsigned i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		Class cls = objc_getClass(names[i]);
		unsigned m, count;
		Method *list;

		if (cls == Nil) {
			bridge_bt_log("class %s: absent\n", names[i]);
			continue;
		}
		list = class_copyMethodList(cls, &count);
		bridge_bt_log("class %s: %u methods\n", names[i], count);
		for (m = 0; m < count; m++) {
			const char *name = sel_getName(method_getName(list[m]));

			if (strstr(name, "connect") != NULL ||
			    strstr(name, "air") != NULL ||
			    strstr(name, "ctivate") != NULL) {
				bridge_bt_log("  -%s %s\n", name,
				    method_getTypeEncoding(list[m]));
			}
		}
		free(list);

		if (strcmp(names[i], "CBConnection") == 0) {
			Method method = class_getInstanceMethod(cls,
			    sel_registerName("connectDevice:connectionFlags:"
			    "serviceFlags:error:"));

			if (method != NULL && bridge_bt_connect_orig == NULL) {
				bridge_bt_connect_orig = (BOOL (*)(id, SEL, id,
				    unsigned long, unsigned long, id *))
				    method_setImplementation(method,
				    (IMP)bridge_bt_connect);
				bridge_bt_log("swizzled connectDevice on %s\n",
				    names[i]);
			}
			method = class_getInstanceMethod(cls,
			    sel_registerName("addPairingClient:error:"));
			if (method != NULL && bridge_bt_pair_client_orig == NULL) {
				bridge_bt_pair_client_orig = (BOOL (*)(id, SEL,
				    id, id *))method_setImplementation(method,
				    (IMP)bridge_bt_pair_client);
				bridge_bt_log("swizzled addPairingClient on %s\n",
				    names[i]);
			}
		}
	}
}

static void
bridge_install(void)
{
	Class layer = objc_getClass("CALayer");
	Method method;
	char line[200];

	bridge_console = open("/dev/console", O_WRONLY | O_NOCTTY);
	/*
	 * Settings is the only app that has to answer "what does the row tap
	 * call": bluetoothd receives no client message for the connect, so the
	 * question is which Bluetooth call the app makes. dump an app dylib
	 * through dlopen was refused (no AMFI signature), and interposing XPC
	 * here painted Settings red (both measured 2026-11-22), so this reads
	 * the classes the app already links and swizzles the connect entry
	 * points it has.
	 */
	if (getprogname() != NULL && strcmp(getprogname(), "Preferences") == 0) {
		bridge_bt_probe();
	}
	if (layer == NULL) {
		return;
	}
	method = class_getInstanceMethod(layer, sel_registerName("setContents:"));
	if (method == NULL) {
		return;
	}
	bridge_original = (void (*)(id, SEL, id))
	    method_setImplementation(method, (IMP)bridge_set_contents);
	/* And the read side, so UIKit still sees the picture (bridge_get_contents). */
	method = class_getInstanceMethod(layer, sel_registerName("contents"));
	if (method != NULL) {
		bridge_contents_orig = (id (*)(id, SEL))
		    method_setImplementation(method, (IMP)bridge_get_contents);
	}
	if (bridge_file_on("/private/var/vm/bridge-switch-probe")) {
		Class sw = objc_getClass("UISwitch");
		Method sm = sw != NULL ? class_getInstanceMethod(sw,
		    sel_registerName("sendAction:to:forEvent:")) : NULL;

		if (sm != NULL) {
			bridge_switch_orig = (BOOL (*)(id, SEL, SEL, id, id))
			    method_setImplementation(sm, (IMP)bridge_switch_send);
		}
	}
	/*
	 * A load line, because "the dylib is missing", "the dylib is loaded and
	 * the app never set a picture" and "the bridge ran and made a surface"
	 * are three different findings and no other line separates them.
	 */
	snprintf(line, sizeof(line),
	    "MONDRIAN BRIDGE[%d]: loaded in %s, setContents %s%s%s\n", getpid(),
	    getprogname() != NULL ? getprogname() : "?",
	    bridge_original != NULL ? "hooked" : "NOT hooked",
	    bridge_off() ? ", marker on (CGImages kept)" : "",
	    bridge_switch_orig != NULL ? ", switch probe on" : "");
	bridge_say(line);
}
