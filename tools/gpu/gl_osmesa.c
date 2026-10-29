/*
 * The OpenGL ES library behind tools/gpu/eagl.c when that library is Mesa as the
 * mesa agent's build makes it (tools/mesa/mondrian-darwin.patch, out/mesa): any of its drivers
 * that draws into memory, reached through its off-screen interface (OSMesa, given an OpenGL ES
 * profile by the ES-profile half of that patch).
 *
 * This file is all that knows which library draws. eagl.c wants four things besides the gl*
 * functions themselves: a context of a version of OpenGL ES, that context made the calling
 * thread's, a context taken away again, and a name for the log. A library with another way to
 * its contexts gets another file like this one.
 *
 * NOT YET RUN ON HARDWARE. It compiles against the iPhoneOS SDK and the Mesa build; nothing here
 * has created a context on the phone.
 *
 * ---------------------------------------------------------------------------------------------
 * Where an IOSurface's number goes (the part that needs the kernel)
 *
 * eagl.c holds an IOSurfaceRef for every surface CoreAnimation hands it and calls
 *
 *     mondrian_gl_surface_texture(e->gl, IOSurfaceGetID(surface))
 *
 * This file turns that number into the EGL image OpenGL ES's OES_EGL_image extension takes:
 *
 *     glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (void *)(uintptr_t)surface_id)
 *
 * Mesa's OSMesa front end has to resolve the image in osmesa_st_get_egl_image()
 * (src/gallium/frontends/osmesa/osmesa.c), by calling osmesa_surface_resource(screen, surface)
 * with the same number (src/gallium/targets/osmesa/osmesa_target.c), which asks the Darwin libdrm
 * shim, tools/mesa/mondrian-drm/. Neither hook is in tools/mesa/mondrian-darwin.patch yet (nor
 * the OSMesa ES profile mondrian_gl_create() needs) -- they are the Mesa half of this dependency:
 *
 *     struct mondrian_drm_surface s = { .surface = surface };
 *     mondrian_drm_surface(gpu_fd, &s);              -> request 0x7e, below
 *     screen->resource_from_handle(..., handle.handle = surface,
 *                                  handle.stride = s.row_bytes, handle.offset = s.offset)
 *
 * and the shim's drmPrimeFDToHandle() (ENOSYS today) would issue the same request with the number
 * as the "file descriptor", because freedreno imports every foreign buffer by descriptor.
 *
 * REQUEST 0x7e (NOT IMPLEMENTED IN THE KERNEL YET -- a dependency of this file):
 * MondrianGPU's user client (xnu/patches-mondrian/0182) answers Linux's msm_drm requests
 * 0x40..0x4c. 0x7e is the port's own, modelled on topaz's kRedwoodSurface (patch 0901 there),
 * with the structure
 *
 *     struct mondrian_surface {
 *             uint32_t surface;        // in: IOSurfaceGetID()
 *             uint32_t handle;         // 0xffffffff: describe only; else back: the GEM handle
 *             uint64_t size;           // back: the buffer's size
 *             uint32_t offset, row_bytes;         // where the pixels start, how long a row is
 *             uint32_t width, height, pixel_format, planes;   // and what they are
 *     };
 *
 * It has to do three things the kernel does not do today: find the surface by ID (the display
 * driver's IOSurface table, iokit/Kernel/arm/MondrianSurface), make a GPU buffer of the
 * surface's memory descriptor (an IOBufferMemoryDescriptor the CP can address, wired, with the
 * 16 KiB alignment and the user-accessible permissions 0181 uses for user buffers), and map it
 * into the GPU's stage-1 context (its IOVA, like GEM_NEW/GEM_INFO does for fresh memory). The
 * first half is why this path is optional here: while 0x7e answers an error, the call above
 * fails, mondrian_gl_surface_texture() returns 0, and eagl.c falls back to filling a texture of
 * its own from the surface and reading the frame back -- correct pixels, at the cost of two
 * copies a frame (the renderer the port runs today, only through Mesa's rasteriser instead of
 * CoreAnimation's).
 *
 * A surface that reaches the GPU this way must be one plane of 32-bit pixels, blue first, in
 * rows the GPU can address. CoreAnimation's surfaces are; the flag `plane != 0` and a pixel
 * format other than 'BGRA' in eagl.c keep the rest away.
 * ---------------------------------------------------------------------------------------------
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "mondrian_gl.h"

/* GL/osmesa.h of Mesa */
#define OSMESA_RGBA                     0x1908
#define OSMESA_FORMAT                   0x22
#define OSMESA_DEPTH_BITS               0x30
#define OSMESA_STENCIL_BITS             0x31
#define OSMESA_PROFILE                  0x33
#define OSMESA_CONTEXT_MAJOR_VERSION    0x36
#define OSMESA_CONTEXT_MINOR_VERSION    0x37
#define OSMESA_ES_PROFILE               0x38
#define GL_UNSIGNED_BYTE                0x1401
#define GL_TEXTURE_2D                   0x0de1
#define GL_RENDERER                     0x1f01

typedef struct osmesa_context *OSMesaContext;
extern OSMesaContext OSMesaCreateContextAttribs(const int *attributes, OSMesaContext share);
extern unsigned char OSMesaMakeCurrent(OSMesaContext context, void *buffer, unsigned type, int width, int height);
extern void OSMesaDestroyContext(OSMesaContext context);
extern void (*OSMesaGetProcAddress(const char *name))(void);
extern const unsigned char *glGetString(unsigned name);
extern unsigned glGetError(void);

/*
 * OSMesa draws its "window" into memory handed to it. Nothing here draws into a window (the
 * window server draws into textures of its own, see eagl.c): a few pixels will do.
 */
#define WINDOW  16

struct mondrian_gl {
	OSMesaContext context;
	unsigned char window[WINDOW * WINDOW * 4];
};

struct mondrian_gl *
mondrian_gl_create(int version)
{
	const int attributes[] = {
		OSMESA_FORMAT, OSMESA_RGBA, OSMESA_DEPTH_BITS, 24, OSMESA_STENCIL_BITS, 8,
		OSMESA_PROFILE, OSMESA_ES_PROFILE, OSMESA_CONTEXT_MAJOR_VERSION, version, OSMESA_CONTEXT_MINOR_VERSION, 0,
		0
	};
	struct mondrian_gl *gl = calloc(1, sizeof(*gl));

	if (gl != NULL && (gl->context = OSMesaCreateContextAttribs(attributes, NULL)) == NULL) {
		free(gl);
		gl = NULL;
	}
	return gl;
}

int
mondrian_gl_make_current(struct mondrian_gl *gl)
{
	if (gl == NULL) {
		return OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
	}
	return OSMesaMakeCurrent(gl->context, gl->window, GL_UNSIGNED_BYTE, WINDOW, WINDOW);
}

void
mondrian_gl_destroy(struct mondrian_gl *gl)
{
	OSMesaDestroyContext(gl->context);
	free(gl);
}

const char *
mondrian_gl_library(void)
{
	return "Mesa, off-screen (OSMesa)";
}

/*
 * OES_EGL_image, with the IOSurface's ID as the image (the comment at the top of the file says
 * what has to happen behind it). The drivers that draw in memory of their own with this
 * processor are not asked: they refuse every time, and the answer being "not done" is what
 * makes eagl.c copy.
 */
int
mondrian_gl_surface_texture(struct mondrian_gl *gl, uint32_t surface)
{
	static void (*image_target)(unsigned target, void *image);
	static int asked, software;

	(void)gl;
	if (!asked) {
		const char *renderer = (const char *)glGetString(GL_RENDERER);

		asked = 1;
		image_target = (void (*)(unsigned, void *))OSMesaGetProcAddress("glEGLImageTargetTexture2DOES");
		software = renderer == NULL || strstr(renderer, "softpipe") != NULL || strstr(renderer, "llvmpipe") != NULL;
	}
	if (image_target == NULL || software) {
		return 0;
	}
	while (glGetError() != 0) {
	}
	image_target(GL_TEXTURE_2D, (void *)(uintptr_t)surface);
	return glGetError() == 0;
}
