/*
 * Which drawing API does WebKit's GPU process use for its page surface? It
 * never asks Metal for a device, so the paint happens through something else.
 * Each intercepted entry point dies with a different signal, so the ring's
 * `CRASH ... sig N` names the API that was reached: SIGILL for creating a
 * bitmap context, SIGTRAP for filling a rect, SIGABRT for drawing an image.
 *
 * Injected only into com.apple.WebKit.GPU, so CoreGraphics elsewhere in the
 * system is untouched.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <signal.h>
#include <stdlib.h>

static void
mondrian_die(int sig)
{
	raise(sig);
	for (;;) {
		/* raise may be caught; do not return to the caller */
		sleep(1);
	}
}

static CGContextRef
mondrian_cg_bitmap(CGColorSpaceRef space, size_t width, size_t height,
    size_t bits, size_t bytesPerRow, CGDataProviderRef provider,
    const CGFloat *decode, int shouldInterpolate, CGColorRenderingIntent intent)
{
	(void)space; (void)width; (void)height; (void)bits; (void)bytesPerRow;
	(void)provider; (void)decode; (void)shouldInterpolate; (void)intent;
	mondrian_die(SIGILL);
	return NULL;
}

static void
mondrian_cg_fill(CGContextRef ctx, CGRect rect)
{
	(void)ctx; (void)rect;
	mondrian_die(SIGTRAP);
}

static void
mondrian_cg_image(CGContextRef ctx, CGRect rect, CGImageRef image)
{
	(void)ctx; (void)rect; (void)image;
	mondrian_die(SIGABRT);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
	const void *replacement;
	const void *replaced;
} mondrian_cg_interpose[] = {
	{ (const void *)mondrian_cg_bitmap, (const void *)CGBitmapContextCreate },
	{ (const void *)mondrian_cg_fill, (const void *)CGContextFillRect },
	{ (const void *)mondrian_cg_image, (const void *)CGContextDrawImage },
};
