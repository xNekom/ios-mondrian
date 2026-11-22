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
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define BRIDGE_CACHE	8
#define BRIDGE_CACHE_MAX (1024u * 1024u)

static int bridge_console = -1;
static unsigned bridge_made;
static unsigned bridge_hits;
static unsigned bridge_empty;
static bool bridge_log_started;

static void bridge_snapshot_hooks(void);
static void bridge_fbs_hooks(void);
static void bridge_chain_dump(const char *tag, CGImageRef image);

/* Prefix for a dump made from a named checkpoint, so a picture converted from
 * the cache can be told from one converted on its way to a layer. */
static const char *bridge_dump_tag;

/*
 * A second channel for the dump.
 *
 * Console writes from an app do not reach the kernel ring on this port: the
 * bridge's own `loaded in ...` line never appears for Spotlight, yet Spotlight
 * creates its surfaces (`MONDRIAN SURF: Spotlight create ... keys 6`), so the
 * dylib runs and its console output is dropped. A dump therefore goes to a file
 * the host can pull with `rf`, and -- until an app proves it can write there --
 * to the console as well.
 */
static void
bridge_dump_write(const char *line)
{
	int fd;
	int32_t pid = (int32_t)getpid();
	char path[160];

	snprintf(path, sizeof(path),
	    "/private/var/mobile/Library/Preferences/mondrian-appdeep-%d.log",
	    (int)pid);
	if (!bridge_log_started) {
		fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
		if (fd >= 0) {
			close(fd);
			bridge_log_started = true;
		}
	}
	if (!bridge_log_started) {
		return;
	}
	fd = open(path, O_WRONLY | O_APPEND, 0666);
	if (fd < 0) {
		return;
	}
	(void)write(fd, line, strlen(line));
	close(fd);
}

/*
 * One line per load, appended to a file shared by every process: the only way
 * to tell "the dylib is not in Spotlight" from "it is, and its console output
 * is dropped" and from "its sandbox refuses the write". The dump below uses a
 * file per pid, so a process that never writes one is invisible without this.
 */
static void
bridge_alive(const char *what)
{
	static bool wrote;
	char line[160];
	int fd;

	snprintf(line, sizeof(line), "%s pid %d: %s\n",
	    getprogname() != NULL ? getprogname() : "?", (int)getpid(), what);
	fd = open("/private/var/mobile/Library/Preferences/"
	    "mondrian-bridge-alive.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
	if (fd < 0) {
		return;
	}
	(void)write(fd, line, strlen(line));
	close(fd);
	wrote = true;
	(void)wrote;
}

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

/* The first byte of a marker, or -1. The snapshot marker doubles as a mode:
 * "1" arms the cache hooks, "2" also asks the layer dump. A separate file for
 * the mode was not visible to SpringBoard (measured 2026-11-22), while the
 * marker this dylib already reads was. */
static int
bridge_file_byte(const char *path)
{
	char c;
	int fd = open(path, O_RDONLY);
	ssize_t n;

	if (fd < 0) {
		return -1;
	}
	n = read(fd, &c, 1);
	(void)close(fd);
	return n == 1 ? (unsigned char)c : -1;
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
	/*
	 * A raw copy of what the layer will hand the server. The ring can say a
	 * 129x129 picture was converted and how much of it is not zero, but not
	 * whether it is the knob or a transparent square; this writes the bytes a
	 * host can look at. Armed by /private/var/vm/mondrian-dump-picture.
	 */
	if (width >= 300 && height >= 500 &&
	    access("/private/var/vm/mondrian-dump-picture", F_OK) == 0) {
		/*
		 * A budget per geometry, not per process: the wallpaper replica is
		 * converted on every change and used to take all eight slots before
		 * the card's own picture (1080x2400, 360x800 points at 3x) arrived.
		 */
		static struct {
			size_t w, h;
			unsigned n;
		} shown[12];
		static unsigned kinds;
		unsigned slot = kinds, i;
		char path[160];
		const void *base = IOSurfaceGetBaseAddress(surface);
		int fd = -1;

		for (i = 0; i < kinds; i++) {
			if (shown[i].w == width && shown[i].h == height) {
				slot = i;
				break;
			}
		}
		if (i == kinds) {
			if (kinds < 12) {
				shown[kinds].w = width;
				shown[kinds].h = height;
				shown[kinds].n = 0;
				kinds++;
			} else {
				slot = 12;
			}
		}
		if (slot < kinds && shown[slot].n < 2) {
		if (row * height <= 16u * 1024u * 1024u) {
			snprintf(path, sizeof(path),
			    "/private/var/mobile/Library/Preferences/"
			    "mondrian-pic-%s%zux%zu-%zu-%u.bgra",
			    bridge_dump_tag != NULL ? bridge_dump_tag : "",
			    width, height, row, shown[slot].n);
			fd = base != NULL ? open(path,
			    O_WRONLY | O_CREAT | O_TRUNC, 0666) : -1;
			if (fd >= 0) {
				(void)write(fd, base, row * height);
				close(fd);
			}
		} else if (base != NULL) {
			/*
			 * A full-screen card is 1440x3200, 18 MB: too big to pull
			 * over the ring just to see its background. A quarter-scale
			 * copy keeps every fourth row and column, which is enough to
			 * tell a magenta placeholder from a drawn card.
			 */
			size_t sw = width / 4, sh = height / 4, srow = sw * 4;
			uint8_t *small = malloc(srow * sh);

			if (small != NULL) {
				size_t x, y;

				for (y = 0; y < sh; y++) {
					const uint8_t *src =
					    (const uint8_t *)base + (y * 4) * row;

					for (x = 0; x < sw; x++) {
						memcpy(small + y * srow + x * 4,
						    src + (x * 4) * 4, 4);
					}
				}
				snprintf(path, sizeof(path),
				    "/private/var/mobile/Library/Preferences/"
				    "mondrian-pic-%s%zux%zu-%zu-%u.bgra",
				    bridge_dump_tag != NULL ? bridge_dump_tag : "",
				    sw, sh, srow, shown[slot].n);
				fd = open(path, O_WRONLY | O_CREAT | O_TRUNC,
				    0666);
				if (fd >= 0) {
					(void)write(fd, small, srow * sh);
					close(fd);
				}
				free(small);
			}
		}
			if (fd >= 0) {
				shown[slot].n++;
			}
		}
	}
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
static unsigned bridge_late;
static id (*bridge_contents_orig)(id, SEL);

/*
 * A layer whose contents are still a CGImage when CoreAnimation reads them.
 *
 * The setter hook only reaches a layer whose `setContents:` is CALayer's own.
 * A subclass that overrides it, or a layer filled by something other than
 * -setContents:, keeps the picture, and the commit then hands it to the server,
 * which builds its own format-less surface and leaves it zero. Measured
 * 2026-11-22 on the Today view: four 192x192 suggestion cards, each answered by
 * `backboardd create ... 192x192 fmt 0x0` right after Spotlight had already
 * made its own `fmt 0x42475241` surface for a sibling card.
 *
 * The commit is the last place the picture is still in the process, so the
 * conversion belongs there as a fallback: a picture read at commit becomes a
 * surface, kept on the layer beside the picture it came from. The box is
 * separate from the setter's so neither path can steal the other's entry.
 */
static char bridge_commit_box_key;

static IOSurfaceRef
bridge_commit_surface(id layer, CGImageRef image)
{
	CFDictionaryRef box = (CFDictionaryRef)objc_getAssociatedObject(layer,
	    &bridge_commit_box_key);
	CGImageRef kept;
	IOSurfaceRef surface;

	if (box == NULL) {
		return NULL;
	}
	kept = (CGImageRef)CFDictionaryGetValue(box, CFSTR("image"));
	surface = (IOSurfaceRef)CFDictionaryGetValue(box, CFSTR("surface"));
	return kept == image ? surface : NULL;
}

static void
bridge_commit_remember(id layer, CGImageRef image, IOSurfaceRef surface)
{
	CFMutableDictionaryRef box = CFDictionaryCreateMutable(NULL, 2,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	if (box == NULL) {
		return;
	}
	CFDictionarySetValue(box, CFSTR("image"), image);
	CFDictionarySetValue(box, CFSTR("surface"), surface);
	objc_setAssociatedObject(layer, &bridge_commit_box_key, (id)box,
	    OBJC_ASSOCIATION_RETAIN);
	CFRelease(box);
}

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
	 * A picture that reached the commit without going through the setter (a
	 * subclass's own setContents:, a layer filled some other way) is
	 * converted here: the server cannot take a CGImage on this port, and
	 * this is the last point where its pixels are still in the process.
	 */
	if (commit && real != nil && !bridge_off() &&
	    CFGetTypeID((CFTypeRef)real) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)real;
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);

		if (w >= 4 && h >= 4) {
			IOSurfaceRef surface = bridge_commit_surface(self, image);
			bool made = false;

			if (surface == NULL) {
				CGImageRef used = image;
				unsigned coverage = 0;

				surface = bridge_surface(image, &used,
				    &coverage);
				if (surface != NULL) {
					bridge_commit_remember(self, image,
					    surface);
					made = true;
					if (bridge_late++ < 4) {
						snprintf(line, sizeof(line),
						    "MONDRIAN BRIDGE[%d]: %zux%zu "
						    "as surface %u at commit on "
						    "%s drew %u/49\n", getpid(),
						    w, h, IOSurfaceGetID(surface),
						    object_getClassName(self),
						    coverage);
						bridge_say(line);
					}
				}
			}
			if (surface != NULL) {
				real = (id)surface;
				if (made) {
					CFRelease(surface); /* the box holds it */
				}
			}
		}
	}

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

static int bridge_watch_on = -1;

/*
 * What the switcher hands its cards. Armed by
 * /private/var/vm/mondrian-switch-watch: the card views are created by
 * SpringBoard and the deep dump says their content view has no contents, so the
 * only way to name the picture's road is to stand in setContents() while the
 * switcher opens and print each distinct layer shape with what it was given.
 */
static int
bridge_watch_contents(id layer, id contents)
{
	Class cls;
	const char *name;
	CGRect bounds;
	id delegate;
	const char *owner;
	static struct {
		const char *name;
		const char *owner;
		int w, h;
	} seen[16];
	static unsigned n;
	unsigned i;
	const char *kind = "nil";
	char line[260];

	if (bridge_watch_on < 0) {
		bridge_watch_on = bridge_file_on(
		    "/private/var/vm/mondrian-switch-watch") ? 1 : 0;
	}
	if (bridge_watch_on == 0 || getprogname() == NULL ||
	    strcmp(getprogname(), "SpringBoard") != 0) {
		return 0;
	}
	cls = object_getClass(layer);
	name = cls != NULL ? class_getName(cls) : NULL;
	if (name == NULL) {
		return 0;
	}
	bounds = ((CGRect (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("bounds"));
	if (!(bounds.size.width >= 300 && bounds.size.height >= 500) &&
	    strstr(name, "Snapshot") == NULL &&
	    strstr(name, "Switcher") == NULL) {
		return 0;
	}
	/*
	 * The card and the wallpaper replica are both a plain `CALayer 480x1067`
	 * to -[CALayer setContents:], and keying only on the layer class and size
	 * folded them into one line -- which is how the replica's wallpaper read
	 * as "the cards get their picture". The owning view is the difference.
	 */
	delegate = ((id (*)(id, SEL))objc_msgSend)(layer,
	    sel_registerName("delegate"));
	owner = delegate != nil ? object_getClassName(delegate) : "-";
	for (i = 0; i < n; i++) {
		if (seen[i].name == name && seen[i].owner == owner &&
		    seen[i].w == (int)bounds.size.width &&
		    seen[i].h == (int)bounds.size.height) {
			return 0;
		}
	}
	if (n < 16) {
		seen[n].name = name;
		seen[n].owner = owner;
		seen[n].w = (int)bounds.size.width;
		seen[n].h = (int)bounds.size.height;
		n++;
	}
	if (contents != NULL) {
		CFTypeID type = CFGetTypeID((CFTypeRef)contents);

		if (type == CGImageGetTypeID()) {
			kind = "CGImage";
		} else if (type == IOSurfaceGetTypeID()) {
			kind = "IOSurface";
		} else {
			kind = object_getClassName(contents);
		}
	}
	snprintf(line, sizeof(line),
	    "MONDRIAN SW2: %s %.0fx%.0f view %s contents %s\n",
	    name, (double)bounds.size.width, (double)bounds.size.height, owner,
	    kind);
	bridge_say(line);
	return 1;
}

static void
bridge_set_contents(id self, SEL cmd, id contents)
{
	IOSurfaceRef surface = NULL;
	int watched;

	bridge_snapshot_hooks();
	bridge_fbs_hooks();
	watched = bridge_watch_contents(self, contents);

	if (contents != NULL && !bridge_off() &&
	    CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID()) {
		CGImageRef image = (CGImageRef)contents;
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);

		if (w >= 4 && h >= 4) {
			surface = bridge_cached(image);
			if (surface != NULL) {
				if (watched) {
					char line[240];
					CGRect lb = ((CGRect (*)(id, SEL))objc_msgSend)(
					    self, sel_registerName("bounds"));

					snprintf(line, sizeof(line),
					    "MONDRIAN SW3: %s %.0fx%.0f image %zux%zu "
					    "cached surface %u\n",
					    object_getClassName(self),
					    (double)lb.size.width, (double)lb.size.height,
					    w, h, IOSurfaceGetID(surface));
					bridge_say(line);
				}
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
				if (watched) {
					char line[280];
					CGRect lb = ((CGRect (*)(id, SEL))objc_msgSend)(
					    self, sel_registerName("bounds"));

					snprintf(line, sizeof(line),
					    "MONDRIAN SW3: %s %.0fx%.0f image %zux%zu "
					    "surface %s drew %u/49%s\n",
					    object_getClassName(self),
					    (double)lb.size.width, (double)lb.size.height,
					    w, h, surface != NULL ? "made" : "none",
					    coverage,
					    used != image ? " relabelled" : "");
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
	if (watched && surface == NULL) {
		char line[300];
		CGRect lb = ((CGRect (*)(id, SEL))objc_msgSend)(self,
		    sel_registerName("bounds"));
		id delegate = ((id (*)(id, SEL))objc_msgSend)(self,
		    sel_registerName("delegate"));

		snprintf(line, sizeof(line),
		    "MONDRIAN SW3: %s %.0fx%.0f view %s no surface made "
		    "(contents %s, off %d)\n", object_getClassName(self),
		    (double)lb.size.width, (double)lb.size.height,
		    delegate != nil ? object_getClassName(delegate) : "-",
		    contents != NULL ? object_getClassName(contents) : "nil",
		    bridge_off() ? 1 : 0);
		bridge_say(line);
	}
	if (surface == NULL && contents != NULL &&
	    CFGetTypeID((CFTypeRef)contents) == IOSurfaceGetTypeID()) {
		/*
		 * The card layer that gets an IOSurface and not a picture: the
		 * bridge passes it through, so its bytes are the only way to say
		 * whether the window server filled it or left it poisoned. Read
		 * only; two dumps a process, 8 MiB at most.
		 */
		static unsigned dumped;
		IOSurfaceRef shared = (IOSurfaceRef)contents;
		size_t w = IOSurfaceGetWidth(shared);
		size_t h = IOSurfaceGetHeight(shared);
		size_t row = IOSurfaceGetBytesPerRow(shared);
		uint32_t seed = 0;
		char line[240];

		if (bridge_watch_on <= 0) {
			bridge_watch_on = bridge_file_on(
			    "/private/var/vm/mondrian-switch-watch") ? 1 : 0;
		}
		if (bridge_watch_on > 0 && getprogname() != NULL &&
		    strcmp(getprogname(), "SpringBoard") == 0) {
			kern_return_t lock = IOSurfaceLock(shared,
			    kIOSurfaceLockReadOnly, &seed);

			snprintf(line, sizeof(line),
			    "MONDRIAN SW4: surface %zux%zu row %zu lock %d\n",
			    w, h, row, (int)lock);
			bridge_say(line);
			if (lock == 0) {
				const void *base =
				    IOSurfaceGetBaseAddress(shared);
				char path[160];
				int fd = -1;

				if (dumped < 2 && w >= 300 && h >= 500 &&
				    row * h <= 8u * 1024u * 1024u &&
				    base != NULL) {
					snprintf(path, sizeof(path),
					    "/private/var/mobile/Library/"
					    "Preferences/mondrian-card-%zux%zu-"
					    "%zu-%u.bgra", w, h, row, dumped);
					fd = open(path, O_WRONLY | O_CREAT |
					    O_TRUNC, 0666);
					if (fd >= 0) {
						(void)write(fd, base, row * h);
						close(fd);
						dumped++;
					}
				}
				IOSurfaceUnlock(shared,
				    kIOSurfaceLockReadOnly, &seed);
				snprintf(line, sizeof(line),
				    "MONDRIAN SW4: %zux%zu row %zu dumped %s\n",
				    w, h, row, fd >= 0 ? "yes" : "no");
				bridge_say(line);
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

static bool bridge_console_open;
static bool bridge_installed;
static bool bridge_told;

/*
 * The view tree of the process that carries this dylib, for the screens no
 * other dump can reach. The hook's deep dump walks SpringBoard's windows, and
 * on the Today view that names only the backdrop and the search pill: the four
 * 192x192 suggestion cards live in the Spotlight process, behind a
 * `_UIPortalView`/`CAPortalLayer`, so the only way to read their class and
 * whether they hold contents is from inside Spotlight -- and Spotlight gets
 * this dylib, not the hook.
 *
 * Armed by /private/var/vm/mondrian-deep-app holding a new number, four dumps
 * per process, like the hook's. The lines go to /dev/console and to a file;
 * the console is dropped for an app on this port, which is why the file exists.
 */
#define BRIDGE_DEEP_MAX 220

static unsigned bridge_deep_prints;

static void
bridge_deep_view(id view, unsigned depth)
{
	id layer, kids;
	const char *name;
	char line[300];
	CGRect frame;
	const char *lname = "-";
	bool has_contents = false;
	unsigned n, i;

	if (view == nil || depth > 12 || bridge_deep_prints >= BRIDGE_DEEP_MAX) {
		return;
	}
	name = object_getClassName(view);
	frame = ((CGRect (*)(id, SEL))objc_msgSend)(view,
	    sel_registerName("frame"));
	layer = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("layer"));
	if (layer != nil) {
		lname = object_getClassName(layer);
		has_contents = ((id (*)(id, SEL))objc_msgSend)(layer,
		    sel_registerName("contents")) != nil;
	}
	bridge_deep_prints++;
	snprintf(line, sizeof(line),
	    "MONDRIAN APPDEEP: %*s%s %.0f,%.0f %.0fx%.0f layer %s contents %s\n",
	    (int)(depth * 2), "", name != NULL ? name : "?",
	    (double)frame.origin.x, (double)frame.origin.y,
	    (double)frame.size.width, (double)frame.size.height, lname,
	    has_contents ? "yes" : "no");
	bridge_say(line);
	bridge_dump_write(line);

	kids = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
	n = kids != nil ? (unsigned)[(NSArray *)kids count] : 0;
	for (i = 0; i < n; i++) {
		bridge_deep_view([(NSArray *)kids objectAtIndex:i], depth + 1);
	}
}

static void
bridge_deep_dump(void)
{
	Class app_cls = objc_getClass("UIApplication");
	id app, windows, scenes;
	char line[160];
	unsigned count, i;
	if (app_cls == NULL) {
		return;
	}
	app = ((id (*)(id, SEL))objc_msgSend)(app_cls,
	    sel_registerName("sharedApplication"));
	if (app == nil) {
		return;
	}
	snprintf(line, sizeof(line), "MONDRIAN APPDEEP: %s pid %d\n",
	    getprogname() != NULL ? getprogname() : "?", getpid());
	bridge_say(line);
	bridge_dump_write(line);

	/*
	 * `-[UIApplication windows]` is empty for a scene-based app (measured
	 * 2026-11-22: Preferences in the foreground answered 0), so the windows
	 * come from each connected scene as well.
	 */
	windows = ((id (*)(id, SEL))objc_msgSend)(app,
	    sel_registerName("windows"));
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		id window = [(NSArray *)windows objectAtIndex:i];

		snprintf(line, sizeof(line), "MONDRIAN APPDEEP: window %s\n",
		    object_getClassName(window));
		bridge_say(line);
		bridge_dump_write(line);
		bridge_deep_view(window, 1);
	}
	scenes = ((id (*)(id, SEL))objc_msgSend)(app,
	    sel_registerName("connectedScenes"));
	count = scenes != nil ? (unsigned)[(NSSet *)scenes count] : 0;
	if (count > 0) {
		NSArray *each = [(NSSet *)scenes allObjects];

		for (i = 0; i < count; i++) {
			id scene = [each objectAtIndex:i];
			id wins = ((id (*)(id, SEL))objc_msgSend)(scene,
			    sel_registerName("windows"));
			unsigned n = wins != nil ?
			    (unsigned)[(NSArray *)wins count] : 0;
			unsigned k;

			for (k = 0; k < n; k++) {
				id window = [(NSArray *)wins objectAtIndex:k];

				snprintf(line, sizeof(line),
				    "MONDRIAN APPDEEP: scene %s window %s\n",
				    object_getClassName(scene),
				    object_getClassName(window));
				bridge_say(line);
				bridge_dump_write(line);
				bridge_deep_view(window, 1);
			}
		}
	}
}

static void
bridge_deep_probe(void)
{
	static unsigned long asked;
	static unsigned dumps;
	FILE *file;
	unsigned long wanted = 0;

	file = fopen("/private/var/vm/mondrian-deep-app", "r");
	if (file == NULL) {
		return;
	}
	if (fscanf(file, "%lu", &wanted) != 1) {
		(void)fclose(file);
		return;
	}
	(void)fclose(file);
	/*
	 * A new number restarts the series. The first dump lands before the app
	 * has a window, so one dump per arm is useless here: an app can be
	 * killed about two seconds after exec (measured 2026-11-22, `exit
	 * Preferences[pid] status 0x9`), which leaves only the dumps that the
	 * half-second timer fits in that life.
	 */
	if (wanted != asked) {
		asked = wanted;
		dumps = 0;
	}
	if (dumps >= 8) {
		return;
	}
	dumps++;
	bridge_deep_dump();
}

/* Armed by /private/var/vm/mondrian-switch-test, read from the main-queue timer. */
static int bridge_switch_added;

static void
bridge_switch_test(void)
{
	Class app_cls, switch_cls;
	id app, windows, window, sw;
	unsigned count, i;
	char line[200];

	if (bridge_switch_added ||
	    !bridge_file_on("/private/var/vm/mondrian-switch-test")) {
		return;
	}
	if (getprogname() != NULL && strcmp(getprogname(), "SpringBoard") == 0) {
		return;
	}
	app_cls = objc_getClass("UIApplication");
	switch_cls = objc_getClass("UISwitch");
	if (app_cls == Nil || switch_cls == Nil) {
		return;
	}
	app = ((id (*)(id, SEL))objc_msgSend)((id)app_cls,
	    sel_registerName("sharedApplication"));
	windows = app != nil ?
	    ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows")) : nil;
	count = windows != nil ? (unsigned)[(NSArray *)windows count] : 0;
	for (i = 0; i < count; i++) {
		window = [(NSArray *)windows objectAtIndex:i];
		if (window == nil ||
		    ((BOOL (*)(id, SEL))objc_msgSend)(window,
		    sel_registerName("isHidden"))) {
			continue;
		}
		sw = ((id (*)(id, SEL))objc_msgSend)((id)switch_cls,
		    sel_registerName("alloc"));
		sw = ((id (*)(id, SEL, CGRect))objc_msgSend)(sw,
		    sel_registerName("initWithFrame:"),
		    CGRectMake(40, 200, 51, 31));
		((void (*)(id, SEL, BOOL))objc_msgSend)(sw,
		    sel_registerName("setOn:"), NO);
		((void (*)(id, SEL, id))objc_msgSend)(window,
		    sel_registerName("addSubview:"), sw);
		sw = ((id (*)(id, SEL))objc_msgSend)((id)switch_cls,
		    sel_registerName("alloc"));
		sw = ((id (*)(id, SEL, CGRect))objc_msgSend)(sw,
		    sel_registerName("initWithFrame:"),
		    CGRectMake(140, 200, 51, 31));
		((void (*)(id, SEL, BOOL))objc_msgSend)(sw,
		    sel_registerName("setOn:"), YES);
		((void (*)(id, SEL, id))objc_msgSend)(window,
		    sel_registerName("addSubview:"), sw);
		bridge_switch_added = 1;
		snprintf(line, sizeof(line),
		    "MONDRIAN BRIDGE[%d]: switch test added in %s\n", getpid(),
		    getprogname() != NULL ? getprogname() : "?");
		bridge_say(line);
		return;
	}
}

/*
 * The dump needs the main thread (UIKit), and the dylib has no run loop of its
 * own: one main-queue timer per process, which reads a marker file every two
 * seconds and does nothing else while the file is absent.
 */
static dispatch_source_t bridge_timer;

static void
bridge_deep_start(void)
{
	if (bridge_timer != NULL) {
		return;
	}
	bridge_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
	    dispatch_get_main_queue());
	if (bridge_timer == NULL) {
		return;
	}
	dispatch_source_set_timer(bridge_timer,
	    dispatch_time(DISPATCH_TIME_NOW, 0), 500ull * NSEC_PER_MSEC,
	    100ull * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(bridge_timer, ^{
		bridge_deep_probe();
		bridge_switch_test();
	});
	dispatch_resume(bridge_timer);
}

static void (*bridge_snap_image_original)(id, SEL, id, id);
static void (*bridge_snap_cache_original)(id, SEL, id, id);

/*
 * What the switcher's snapshot cache is handed. This is the far end of the
 * request: the app has rendered (or not) and SpringBoard receives the picture.
 * A real image here means the loss is downstream; magenta means the render
 * produced the placeholder; no line at all means the request never completed.
 */
static void
bridge_snap_image(id self, SEL cmd, id image, id request)
{
	static unsigned said;
	char line[220];

	if (said < 8) {
		said++;
		if (image == nil) {
			snprintf(line, sizeof(line),
			    "MONDRIAN SNAP: finished, image nil\n");
		} else {
			const char *cls = object_getClassName(image);
			size_t w = 0, h = 0;
			CGImageRef cg = NULL;

			if (CFGetTypeID((CFTypeRef)image) == CGImageGetTypeID()) {
				cg = (CGImageRef)image;
				w = CGImageGetWidth(cg);
				h = CGImageGetHeight(cg);
			} else if ([image respondsToSelector:sel_registerName("size")]) {
				CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(
				    image, sel_registerName("size"));

				w = (size_t)size.width;
				h = (size_t)size.height;
			}
			snprintf(line, sizeof(line),
			    "MONDRIAN SNAP: finished, %s %zux%zu\n", cls, w, h);
			/*
			 * The picture the cache is handed, in pixels: the size alone
			 * cannot tell a real snapshot from a placeholder. The object
			 * is not always a CGImage; `XBApplicationSnapshotImage` keeps
			 * the picture behind a method, so both roads are tried.
			 */
			if (cg == NULL &&
			    [image respondsToSelector:sel_registerName("CGImage")]) {
				cg = ((CGImageRef (*)(id, SEL))objc_msgSend)(image,
				    sel_registerName("CGImage"));
			}
			if (cg != NULL && said <= 4) {
				bridge_chain_dump("CACHE", cg);
			}
		}
		bridge_say(line);
	}
	if (bridge_snap_image_original != NULL) {
		bridge_snap_image_original(self, cmd, image, request);
	}
}

static void
bridge_snap_cache(id self, SEL cmd, id image, id request)
{
	static unsigned said;
	char line[200];

	if (said < 8) {
		said++;
		snprintf(line, sizeof(line),
		    "MONDRIAN SNAP: cached %s\n",
		    image != nil ? object_getClassName(image) : "nil");
		bridge_say(line);
	}
	if (bridge_snap_cache_original != NULL) {
		bridge_snap_cache_original(self, cmd, image, request);
	}
}

static void (*bridge_snap_load_original)(id, SEL, id, id, id);
static void (*bridge_snap_create_original)(id, SEL, id, id, BOOL);

/*
 * The snapshot render, from the inside. `_FBSSnapshot` is what turns a
 * `_FBSSnapshotContext` into a picture: the context carries the layers to draw
 * and the size, `capture` renders, `CGImage` hands the result out. The cache
 * receives a 100 % magenta 336x746 picture, so the question is whether the
 * context has layers at all, and whether a capture with layers still yields
 * magenta. The answer goes to one file every process appends to, because the
 * app's console output is dropped.
 */
static void
bridge_chain_line(const char *what)
{
	char line[300];
	int fd;

	snprintf(line, sizeof(line), "%s[%d]: %s\n",
	    getprogname() != NULL ? getprogname() : "?", (int)getpid(), what);
	fd = open("/private/var/mobile/Library/Preferences/"
	    "mondrian-chain.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
	if (fd >= 0) {
		(void)write(fd, line, strlen(line));
		close(fd);
	}
	/*
	 * The file is the channel that survives an app sandbox; the console is
	 * the channel that survives a file the kernel created as root before
	 * the process could. Write both (measured 2026-11-22: a log pre-created
	 * by `wfile` is root-owned and the append fails silently).
	 */
	snprintf(line, sizeof(line), "MONDRIAN CHAIN: %s\n", what);
	bridge_say(line);
}

static void
bridge_bitmap_probe(const char *tag, CGImageRef image)
{
	size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
	size_t sw = w / 4, sh = h / 4, row, x, y;
	uint8_t *buf;
	CGColorSpaceRef rgb;
	CGContextRef ctx;
	char path[200];
	char line[360];
	unsigned nonzero = 0;

	if (sw < 2 || sh < 2) {
		return;
	}
	/*
	 * What the picture is made of, not just how big it is: a solid red result
	 * can come from red source bytes, from a colour space that maps everything
	 * to red, or from an image whose provider has nothing to read. The raw
	 * prefix is the difference between those.
	 */
	{
		CGColorSpaceRef cs = CGImageGetColorSpace(image);
		CGDataProviderRef dp = CGImageGetDataProvider(image);
		CFDataRef raw = dp != NULL ? CGDataProviderCopyData(dp) : NULL;
		const UInt8 *bytes = raw != NULL ? CFDataGetBytePtr(raw) : NULL;
		CFIndex length = raw != NULL ? CFDataGetLength(raw) : 0;
		char space[80] = "none";
		int model = -1;

		if (cs != NULL) {
			CFStringRef name = CGColorSpaceCopyName(cs);

			model = (int)CGColorSpaceGetModel(cs);
			if (name != NULL) {
				CFStringGetCString(name, space, sizeof(space),
				    kCFStringEncodingUTF8);
				CFRelease(name);
			}
		}
		snprintf(line, sizeof(line),
		    "%s image %zux%zu bpc %zu bpp %zu row %zu alpha %u "
		    "info 0x%x model %d space %s raw %ld first %02x %02x %02x %02x",
		    tag, w, h, CGImageGetBitsPerComponent(image),
		    CGImageGetBitsPerPixel(image), CGImageGetBytesPerRow(image),
		    (unsigned)CGImageGetAlphaInfo(image),
		    (unsigned)CGImageGetBitmapInfo(image), model, space,
		    (long)length,
		    bytes != NULL && length > 0 ? bytes[0] : 0,
		    bytes != NULL && length > 1 ? bytes[1] : 0,
		    bytes != NULL && length > 2 ? bytes[2] : 0,
		    bytes != NULL && length > 3 ? bytes[3] : 0);
		bridge_chain_line(line);
		if (raw != NULL) {
			CFRelease(raw);
		}
	}
	row = sw * 4;
	buf = calloc(1, row * sh);
	rgb = CGColorSpaceCreateDeviceRGB();
	if (buf == NULL || rgb == NULL) {
		free(buf);
		if (rgb != NULL) {
			CGColorSpaceRelease(rgb);
		}
		return;
	}
	ctx = CGBitmapContextCreate(buf, sw, sh, 8, row, rgb,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	if (ctx == NULL) {
		CGColorSpaceRelease(rgb);
		free(buf);
		return;
	}
	CGContextTranslateCTM(ctx, 0, (CGFloat)sh);
	CGContextScaleCTM(ctx, 1, -1);
	CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
	CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)sw, (CGFloat)sh),
	    image);
	CGContextRelease(ctx);
	CGColorSpaceRelease(rgb);
	for (y = 0; y < sh; y++) {
		const uint8_t *p = buf + y * row;

		for (x = 0; x < sw; x++) {
			if (p[x * 4] != 0 || p[x * 4 + 1] != 0 ||
			    p[x * 4 + 2] != 0) {
				nonzero++;
			}
		}
	}
	/*
	 * Zeroed before the draw, so `nonzero` is what CoreGraphics actually
	 * painted. A blank picture and a draw that silently did nothing used to
	 * look the same once the bytes landed in allocator memory.
	 */
	snprintf(line, sizeof(line), "%s bitmap %zux%zu drawn %u/%zu", tag,
	    sw, sh, nonzero, sw * sh);
	bridge_chain_line(line);
	if (nonzero > 0) {
		int fd;

		snprintf(path, sizeof(path),
		    "/private/var/mobile/Library/Preferences/"
		    "mondrian-pic-%sbitmap-%zux%zu-%zu.bgra", tag, sw, sh, row);
		fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
		if (fd >= 0) {
			(void)write(fd, buf, row * sh);
			close(fd);
		}
	}
	free(buf);
}

/*
 * A picture handed over at a checkpoint, drawn through the same conversion the
 * layers use so the host can read its pixels. `bridge_surface` already writes
 * the dump file when /private/var/vm/mondrian-dump-picture is present; this
 * only reports where it went. The tag says which end of the chain produced it.
 */
static void
bridge_chain_dump(const char *tag, CGImageRef image)
{
	CGImageRef used = image;
	IOSurfaceRef surface;
	unsigned coverage = 0;
	char line[200];
	/* One file per checkpoint and geometry: a checkpoint is read once. */
	static struct {
		const char *tag;
		size_t w, h;
	} seen[8];
	static unsigned seen_count;

	if (image == NULL) {
		return;
	}
	{
		const char *saved = bridge_dump_tag;
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
		unsigned i;

		for (i = 0; i < seen_count; i++) {
			if (seen[i].w == w && seen[i].h == h &&
			    strcmp(seen[i].tag, tag) == 0) {
				return;
			}
		}
		bridge_dump_tag = tag != NULL ? tag : "";
		surface = bridge_surface(image, &used, &coverage);
		bridge_dump_tag = saved;
		if (surface != NULL && seen_count < 8) {
			seen[seen_count].tag = tag;
			seen[seen_count].w = w;
			seen[seen_count].h = h;
			seen_count++;
			bridge_bitmap_probe(tag, image);
			/*
			 * The layer dump has a per-geometry budget, and the card's
			 * own surface takes the 1440x3200 slots before the snapshot
			 * checkpoint does (measured 2026-11-22: the CACHE picture was
			 * written, the FBS one was not). A checkpoint is written by
			 * its own name instead of competing for those slots.
			 */
			{
				size_t row = (w * 4 + 15) & ~(size_t)15;
				const void *base;
				uint32_t seed = 0;
				char path[200];
				int fd = -1;

				if (IOSurfaceLock(surface,
				    kIOSurfaceLockReadOnly, &seed) == 0) {
					base = IOSurfaceGetBaseAddress(surface);
					if (base != NULL &&
					    row * h <= 16u * 1024u * 1024u) {
						snprintf(path, sizeof(path),
						    "/private/var/mobile/Library/"
						    "Preferences/mondrian-pic-%s%zux%zu-"
						    "%zu.bgra", tag, w, h, row);
						fd = open(path, O_WRONLY |
						    O_CREAT | O_TRUNC, 0666);
						if (fd >= 0) {
							(void)write(fd, base, row * h);
							close(fd);
						}
					} else if (base != NULL) {
						size_t sw = w / 4, sh = h / 4;
						size_t srow = sw * 4;
						uint8_t *small = malloc(srow * sh);

						if (small != NULL) {
							size_t x, y;

							for (y = 0; y < sh; y++) {
								const uint8_t *src =
								    (const uint8_t *)base +
								    (y * 4) * row;

								for (x = 0; x < sw; x++) {
									memcpy(small +
									    y * srow + x * 4,
									    src + (x * 4) * 4, 4);
								}
							}
							snprintf(path,
							    sizeof(path),
							    "/private/var/mobile/"
							    "Library/Preferences/"
							    "mondrian-pic-%s%zux%zu-%zu"
							    ".bgra", tag, sw, sh,
							    srow);
							fd = open(path, O_WRONLY |
							    O_CREAT | O_TRUNC, 0666);
							if (fd >= 0) {
								(void)write(fd, small,
								    srow * sh);
								close(fd);
							}
							free(small);
						}
					}
					IOSurfaceUnlock(surface, 0, &seed);
				}
			}
		}
	}
	snprintf(line, sizeof(line), "%s picture %zux%zu surface %s cov %u",
	    tag, CGImageGetWidth(image), CGImageGetHeight(image),
	    surface != NULL ? "made" : "none", coverage);
	bridge_chain_line(line);
	if (used != image) {
		CGImageRelease(used);
	}
	if (surface != NULL) {
		CFRelease(surface);
	}
}

static id (*bridge_fbs_init_original)(id, SEL, id);
static BOOL (*bridge_fbs_capture_original)(id, SEL);
static CGImageRef (*bridge_fbs_cgimage_original)(id, SEL);

static id
bridge_fbs_init(id self, SEL cmd, id context)
{
	id result, layers = nil;
	CGSize size = { 0, 0 };
	double scale = 0;
	unsigned count = 0;
	static bool methods_told;
	char line[300];

	if (context != nil) {
		if ([context respondsToSelector:sel_registerName("snapshotSize")]) {
			size = ((CGSize (*)(id, SEL))objc_msgSend)(context,
			    sel_registerName("snapshotSize"));
		}
		if ([context respondsToSelector:sel_registerName("scale")]) {
			scale = ((double (*)(id, SEL))objc_msgSend)(context,
			    sel_registerName("scale"));
		}
		layers = ((id (*)(id, SEL))objc_msgSend)(context,
		    sel_registerName("layers"));
		count = layers != nil ? (unsigned)[(NSArray *)layers count] : 0;
	}
	snprintf(line, sizeof(line),
	    "_FBSSnapshot init %.0fx%.0f scale %.2f layers %u%s\n",
	    (double)size.width, (double)size.height, scale, count,
	    count > 0 ? "" : " (nothing to draw)");
	bridge_chain_line(line);
	/*
	 * What the renderer was given, only when armed after boot: the first
	 * version ran on every snapshot, including the one SpringBoard takes while
	 * it starts, and the reach into the layer array there is not worth the
	 * risk. The contents are the decisive part: a layer with nil contents
	 * means nothing to draw, a layer with a picture and a blank result puts
	 * the fault in the render.
	 */
	if (layers != nil &&
	    bridge_file_byte("/private/var/vm/mondrian-snap-probe") == '2' &&
	    [layers respondsToSelector:sel_registerName("count")]) {
		unsigned i;

		for (i = 0; i < count && i < 4; i++) {
			id layer = ((id (*)(id, SEL, unsigned))objc_msgSend)(layers,
			    sel_registerName("objectAtIndex:"), i);
			char contents[80] = "nil";

			if (layer != nil &&
			    [layer respondsToSelector:sel_registerName("contents")]) {
				id c = ((id (*)(id, SEL))objc_msgSend)(layer,
				    sel_registerName("contents"));

				if (c != nil) {
					CFTypeID t = CFGetTypeID((CFTypeRef)c);

					if (t == CGImageGetTypeID()) {
						snprintf(contents, sizeof(contents),
						    "CGImage %zux%zu",
						    CGImageGetWidth((CGImageRef)c),
						    CGImageGetHeight((CGImageRef)c));
					} else if (t == IOSurfaceGetTypeID()) {
						snprintf(contents, sizeof(contents),
						    "IOSurface %u %zux%zu",
						    IOSurfaceGetID((IOSurfaceRef)c),
						    IOSurfaceGetWidth((IOSurfaceRef)c),
						    IOSurfaceGetHeight((IOSurfaceRef)c));
					} else {
						snprintf(contents, sizeof(contents),
						    "%s", object_getClassName(c));
					}
				}
			}
			snprintf(line, sizeof(line), " layer %u %s contents %s",
			    i, layer != nil ? object_getClassName(layer) : "nil",
			    contents);
			bridge_chain_line(line);
			if (layer != nil &&
			    [layer respondsToSelector:sel_registerName("contextID")]) {
				unsigned cid = ((unsigned (*)(id, SEL))objc_msgSend)(
				    layer, sel_registerName("contextID"));

				snprintf(line, sizeof(line),
				    " layer %u contextID %u", i, cid);
				bridge_chain_line(line);
			}
			/*
			 * The wrapper is not a CALayer: `contents` on it is nil
			 * while the renderer may read another property. Its own
			 * method list names the accessor to ask for next.
			 */
			if (i == 0 && layer != nil && !methods_told) {
				unsigned mcount = 0, k;
				Method *methods = class_copyMethodList(
				    object_getClass(layer), &mcount);

				methods_told = true;
				for (k = 0; k < mcount && k < 40; k++) {
					snprintf(line, sizeof(line), " method %s",
					    sel_getName(method_getName(methods[k])));
					bridge_chain_line(line);
				}
				free(methods);
			}
		}
	}
	result = bridge_fbs_init_original != NULL ?
	    bridge_fbs_init_original(self, cmd, context) : nil;
	return result;
}

static BOOL
bridge_fbs_capture(id self, SEL cmd)
{
	BOOL ok = bridge_fbs_capture_original != NULL ?
	    bridge_fbs_capture_original(self, cmd) : NO;

	bridge_chain_line(ok ? "_FBSSnapshot capture ok" :
	    "_FBSSnapshot capture failed");
	return ok;
}

static CGImageRef
bridge_fbs_cgimage(id self, SEL cmd)
{
	CGImageRef image = bridge_fbs_cgimage_original != NULL ?
	    bridge_fbs_cgimage_original(self, cmd) : NULL;
	char line[300];

	if (image == NULL) {
		snprintf(line, sizeof(line), "_FBSSnapshot CGImage nil");
	} else {
		size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
		unsigned char pixel[4] = { 0, 0, 0, 0 };
		CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = rgb != NULL ? CGBitmapContextCreate(pixel,
		    1, 1, 8, 4, rgb, kCGImageAlphaPremultipliedLast) : NULL;

		if (ctx != NULL) {
			CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), image);
			CGContextRelease(ctx);
		}
		if (rgb != NULL) {
			CGColorSpaceRelease(rgb);
		}
		snprintf(line, sizeof(line),
		    "_FBSSnapshot CGImage %zux%zu average %u/%u/%u",
		    w, h, pixel[0], pixel[1], pixel[2]);
	}
	bridge_chain_line(line);
	if (image != NULL &&
	    [self respondsToSelector:sel_registerName("IOSurface")]) {
		IOSurfaceRef s = (IOSurfaceRef)((id (*)(id, SEL))objc_msgSend)(
		    self, sel_registerName("IOSurface"));

		if (s != NULL) {
			snprintf(line, sizeof(line),
			    "_FBSSnapshot IOSurface %u %zux%zu row %zu fmt 0x%x",
			    IOSurfaceGetID(s), IOSurfaceGetWidth(s),
			    IOSurfaceGetHeight(s), IOSurfaceGetBytesPerRow(s),
			    (unsigned)IOSurfaceGetPixelFormat(s));
			bridge_chain_line(line);
		}
	}
	if (image != NULL) {
		static unsigned dumped;

		if (dumped < 4) {
			dumped++;
			bridge_chain_dump("FBS", image);
		}
	}
	return image;
}

static void
bridge_snap_load(id self, SEL cmd, id request, id item, id layout)
{
	static unsigned said;

	if (said < 8) {
		char line[200];

		said++;
		snprintf(line, sizeof(line), "MONDRIAN SNAP: load for %s\n",
		    item != nil ? object_getClassName(item) : "-");
		bridge_say(line);
	}
	if (bridge_snap_load_original != NULL) {
		bridge_snap_load_original(self, cmd, request, item, layout);
	}
}

static void
bridge_snap_create(id self, SEL cmd, id item, id layout, BOOL full)
{
	static unsigned said;

	if (said < 8) {
		char line[200];

		said++;
		snprintf(line, sizeof(line), "MONDRIAN SNAP: create for %s full %d\n",
		    item != nil ? object_getClassName(item) : "-", (int)full);
		bridge_say(line);
	}
	if (bridge_snap_create_original != NULL) {
		bridge_snap_create_original(self, cmd, item, layout, full);
	}
}

/*
 * The app's snapshot service, named. The switcher card is a placeholder because
 * the picture never arrives, and on iOS 16 the request is served in the app, not
 * in SpringBoard. This writes the class and its methods to a file the host can
 * pull; armed by /private/var/vm/mondrian-snap-probe, once per process.
 */
static void
bridge_snapshot_probe(void)
{
	static const char *const names[] = {
		"_UISnapshotService", "UISnapshotService",
		"XBApplicationSnapshotService", "XBSnapshotService",
		"_UIApplicationSnapshotService", "UISceneSnapshotService",
		"SBAppSwitcherSnapshotImageCache", "_FBSSnapshot",
		"_FBSSnapshotContext", "FBSSceneSnapshotRequest",
	};
	static bool done;
	unsigned i;
	int fd;

	if (done || !bridge_file_on("/private/var/vm/mondrian-snap-probe")) {
		return;
	}
	done = true;
	fd = open("/private/var/mobile/Library/Preferences/"
	    "mondrian-snapprobe.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
	if (fd < 0) {
		return;
	}
	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		Class cls = objc_getClass(names[i]);
		char line[220];
		unsigned count = 0, k;

		if (cls == Nil) {
			snprintf(line, sizeof(line), "%s %s: no class\n",
			    getprogname() != NULL ? getprogname() : "?",
			    names[i]);
			(void)write(fd, line, strlen(line));
			continue;
		}
		{
			Method *methods = class_copyMethodList(cls, &count);

			snprintf(line, sizeof(line), "%s %s: %u methods\n",
			    getprogname() != NULL ? getprogname() : "?",
			    names[i], count);
			(void)write(fd, line, strlen(line));
			for (k = 0; k < count && k < 40; k++) {
				snprintf(line, sizeof(line), "  %s\n",
				    sel_getName(method_getName(methods[k])));
				(void)write(fd, line, strlen(line));
			}
			free(methods);
		}
	}
	/*
	 * The guessed names were all absent (measured 2026-11-22), so list the
	 * classes that carry "Snapshot" in their name instead: the real service
	 * is one of them, and the method list says what to hook.
	 */
	{
		int total = objc_getClassList(NULL, 0);
		Class *all = total > 0 ? malloc((size_t)total * sizeof(Class)) : NULL;
		unsigned shown = 0;

		if (all != NULL) {
			total = objc_getClassList(all, total);
			for (i = 0; i < (unsigned)total && shown < 40; i++) {
				const char *name = class_getName(all[i]);
				Method *methods;
				unsigned count = 0, k;
				char line[220];

				if (name == NULL || strstr(name, "Snapshot") == NULL) {
					continue;
				}
				shown++;
				methods = class_copyMethodList(all[i], &count);
				snprintf(line, sizeof(line), "%s class %s: %u methods\n",
				    getprogname() != NULL ? getprogname() : "?",
				    name, count);
				(void)write(fd, line, strlen(line));
				for (k = 0; k < count && k < 40; k++) {
					snprintf(line, sizeof(line), "  %s\n",
					    sel_getName(method_getName(methods[k])));
					(void)write(fd, line, strlen(line));
				}
				free(methods);
			}
			free(all);
		}
	}
	close(fd);
}

static void bridge_fbs_hooks(void);

/*
 * The hook is installed from setContents, not from the class listing: the
 * cache class is not loaded when the dylib installs (measured 2026-11-22), so
 * the first attempt would silently find nothing.
 */
static void
bridge_snapshot_hooks(void)
{
	static bool hooked;
	static bool told;

	if (hooked || getprogname() == NULL ||
	    strcmp(getprogname(), "SpringBoard") != 0 ||
	    !bridge_file_on("/private/var/vm/mondrian-snap-probe")) {
		return;
	}
	{
		Class cache = objc_getClass("SBAppSwitcherSnapshotImageCache");
		Method method;

		if (cache == Nil) {
			if (!told) {
				told = true;
				bridge_say("MONDRIAN SNAP: cache class not up yet\n");
			}
			return;
		}
		hooked = true;
		method = class_getInstanceMethod(cache,
		    sel_registerName("_snapshotImage:finishedLoadingForRequest:"));
		if (method != NULL) {
			bridge_snap_image_original = (void (*)(id, SEL, id, id))
			    method_setImplementation(method, (IMP)bridge_snap_image);
		}
		method = class_getInstanceMethod(cache,
		    sel_registerName("_addCacheEntryForImage:fromRequest:"));
		if (method != NULL) {
			bridge_snap_cache_original = (void (*)(id, SEL, id, id))
			    method_setImplementation(method, (IMP)bridge_snap_cache);
		}
		method = class_getInstanceMethod(cache,
		    sel_registerName("_loadSnapshotForRequest:withDisplayItem:inAppLayout:"));
		if (method != NULL) {
			bridge_snap_load_original = (void (*)(id, SEL, id, id, id))
			    method_setImplementation(method, (IMP)bridge_snap_load);
		}
		method = class_getInstanceMethod(cache,
		    sel_registerName("_createSnapshotRequestWithDisplayItem:inAppLayout:forFullSizeSnapshot:"));
		if (method != NULL) {
			bridge_snap_create_original = (void (*)(id, SEL, id, id, BOOL))
			    method_setImplementation(method, (IMP)bridge_snap_create);
		}
		bridge_say("MONDRIAN SNAP: cache hooked\n");
	}
}

/*
 * The render side, in whatever process asks for it. FrontBoardServices is
 * loaded in the app as well as in SpringBoard, so the hook is not limited to
 * one program name; the marker decides. `_FBSSnapshot` is not up when the
 * dylib installs in a small process, so this retries from every setContents.
 */
static void
bridge_fbs_hooks(void)
{
	static bool hooked;
	static bool told;

	if (hooked || !bridge_file_on("/private/var/vm/mondrian-snap-probe")) {
		return;
	}
	{
		Class snapshot = objc_getClass("_FBSSnapshot");
		Method method;

		if (snapshot == Nil) {
			if (!told) {
				told = true;
				bridge_chain_line("_FBSSnapshot class not up yet");
			}
			return;
		}
		hooked = true;
		method = class_getInstanceMethod(snapshot,
		    sel_registerName("initWithSnapshotContext:"));
		if (method != NULL) {
			bridge_fbs_init_original = (id (*)(id, SEL, id))
			    method_setImplementation(method, (IMP)bridge_fbs_init);
		}
		method = class_getInstanceMethod(snapshot,
		    sel_registerName("capture"));
		if (method != NULL) {
			bridge_fbs_capture_original = (BOOL (*)(id, SEL))
			    method_setImplementation(method, (IMP)bridge_fbs_capture);
		}
		method = class_getInstanceMethod(snapshot,
		    sel_registerName("CGImage"));
		if (method != NULL) {
			bridge_fbs_cgimage_original = (CGImageRef (*)(id, SEL))
			    method_setImplementation(method, (IMP)bridge_fbs_cgimage);
		}
		bridge_chain_line("_FBSSnapshot hooked");
	}
}

/*
 * Install when CoreAnimation is there.
 *
 * A process that receives this dylib before it has loaded QuartzCore has no
 * CALayer to hook, and returning silently made that state indistinguishable
 * from "the dylib was never injected": measured 2026-11-22, Spotlight created
 * its suggestion images (`MONDRIAN SURF: Spotlight create ... 192x192 fmt
 * 0x42475241`) and the server then made its own zero surfaces for them, while
 * no `loaded in Spotlight` line existed anywhere. The install is retried from
 * the dyld add-image callback, which fires again for every image QuartzCore is
 * in.
 */
static void
bridge_install(void)
{
	Class layer;
	Method method;
	char line[200];

	if (bridge_installed) {
		return;
	}
	if (!bridge_console_open) {
		bridge_console = open("/dev/console", O_WRONLY | O_NOCTTY);
		bridge_console_open = true;
	}
	layer = objc_getClass("CALayer");
	if (!bridge_told) {
		bridge_told = true;
		snprintf(line, sizeof(line),
		    "MONDRIAN BRIDGE[%d]: in %s, CALayer %s\n", getpid(),
		    getprogname() != NULL ? getprogname() : "?",
		    layer != NULL ? "up" : "not up yet");
		bridge_say(line);
	}
	if (layer == NULL) {
		return;
	}
	method = class_getInstanceMethod(layer, sel_registerName("setContents:"));
	if (method == NULL) {
		return;
	}
	bridge_installed = true;
	bridge_snapshot_probe();
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
	bridge_alive("loaded");
	bridge_deep_start();
}

static void
bridge_image_added(const struct mach_header *header, intptr_t slide)
{
	(void)header;
	(void)slide;
	if (!bridge_installed) {
		bridge_install();
	}
}

__attribute__((constructor))
static void
bridge_load(void)
{
	bridge_install();
	_dyld_register_func_for_add_image(bridge_image_added);
}
