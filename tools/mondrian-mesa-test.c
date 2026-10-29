/*
 * Mesa on the Adreno 730, without CoreAnimation.
 *
 * Creates an OSMesa context on freedreno's msm backend (this port's
 * MondrianGPU service through tools/mesa/mondrian-drm), clears to a known
 * colour, reads it back and logs the renderer string, so one boot says
 * whether the GPU draws and whether Mesa is using it at all or has fallen
 * back to softpipe.
 *
 * Built as a dylib (tools/build-mondrian-mesa-test.sh) and dlopened by
 * mondrian-ui-hook.dylib. Everything is resolved with dlopen/dlsym so a
 * missing or broken Mesa is a logged line, not a process that will not load.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include <IOKit/IOKitLib.h>

#define kMesaPath	"/usr/lib/libOSMesa.8.dylib"
#define kWidth		256
#define kHeight		256

/* GL enums, so this file needs no GL headers to build against the SDK. */
#define GL_RGBA			0x1908
#define GL_UNSIGNED_BYTE	0x1401
#define GL_RENDERER		0x1F01
#define GL_VERSION		0x1F02
#define GL_VENDOR		0x1F00
#define GL_COLOR_BUFFER_BIT	0x00004000
#define GL_NO_ERROR		0

struct osmesa_context;

static int console_fd = -1;

static void
say(const char *format, ...)
{
	char buffer[256];
	va_list arguments;
	int length;

	va_start(arguments, format);
	length = vsnprintf(buffer, sizeof(buffer), format, arguments);
	va_end(arguments);
	if (length <= 0) {
		return;
	}
	if (length > (int)sizeof(buffer)) {
		length = (int)sizeof(buffer);
	}
	(void)write(STDERR_FILENO, buffer, (size_t)length);
	if (console_fd >= 0) {
		(void)write(console_fd, buffer, (size_t)length);
	}
}

__attribute__((constructor))
static void
mondrian_mesa_test(void)
{
	void *library;
	struct osmesa_context *(*create)(unsigned, int, int, int, void *);
	unsigned char (*make_current)(struct osmesa_context *, void *, unsigned,
	    int, int);
	const unsigned char *(*get_string)(unsigned);
	void (*clear_color)(float, float, float, float);
	void (*clear)(unsigned);
	void (*finish)(void);
	void (*read_pixels)(int, int, int, int, unsigned, unsigned, void *);
	unsigned (*get_error)(void);
	void (*viewport)(int, int, int, int);
	unsigned char *pixels;
	unsigned char pixel[4];
	const unsigned char *renderer, *version, *vendor;
	io_service_t service = 0;
	int i;

	console_fd = open("/dev/console", O_WRONLY);
	say("MONDRIAN MESA TEST: start\n");

	/* The GPU has to be up: Mesa's msm backend opens this service. */
	for (i = 0; i < 150 && service == 0; i++) {
		service = IOServiceGetMatchingService(0,
		    IOServiceMatching("MondrianGPU"));
		if (service == 0) {
			usleep(200 * 1000);
		}
	}
	if (service == 0) {
		say("MONDRIAN MESA TEST: no MondrianGPU service\n");
		goto out;
	}
	IOObjectRelease(service);

	/* Buffer layouts are not trusted yet; sysmem keeps every resource in
	 * plain memory where a wrong tiling shows up as wrong pixels instead
	 * of a GPU fault. */
	setenv("FD_MESA_DEBUG", "sysmem", 1);

	library = dlopen(kMesaPath, RTLD_NOW);
	if (library == NULL) {
		say("MONDRIAN MESA TEST: dlopen failed: %s\n", dlerror());
		goto out;
	}
	create = (struct osmesa_context *(*)(unsigned, int, int, int, void *))
	    dlsym(library, "OSMesaCreateContextExt");
	make_current = (unsigned char (*)(struct osmesa_context *, void *,
	    unsigned, int, int))dlsym(library, "OSMesaMakeCurrent");
	get_string = (const unsigned char *(*)(unsigned))
	    dlsym(library, "glGetString");
	clear_color = (void (*)(float, float, float, float))
	    dlsym(library, "glClearColor");
	clear = (void (*)(unsigned))dlsym(library, "glClear");
	finish = (void (*)(void))dlsym(library, "glFinish");
	read_pixels = (void (*)(int, int, int, int, unsigned, unsigned, void *))
	    dlsym(library, "glReadPixels");
	get_error = (unsigned (*)(void))dlsym(library, "glGetError");
	viewport = (void (*)(int, int, int, int))dlsym(library, "glViewport");
	if (create == NULL || make_current == NULL || get_string == NULL ||
	    clear_color == NULL || clear == NULL || finish == NULL ||
	    read_pixels == NULL || get_error == NULL || viewport == NULL) {
		say("MONDRIAN MESA TEST: the library has no OSMesa entry points\n");
		goto out;
	}

	pixels = (unsigned char *)calloc((size_t)kWidth * kHeight, 4);
	if (pixels == NULL) {
		say("MONDRIAN MESA TEST: out of memory\n");
		goto out;
	}
	{
		struct osmesa_context *context =
		    create(GL_RGBA, 24, 8, 0, NULL);

		if (context == NULL) {
			say("MONDRIAN MESA TEST: OSMesaCreateContextExt failed\n");
			free(pixels);
			goto out;
		}
		if (make_current(context, pixels, GL_UNSIGNED_BYTE, kWidth,
		    kHeight) == 0) {
			say("MONDRIAN MESA TEST: OSMesaMakeCurrent failed\n");
			free(pixels);
			goto out;
		}
	}
	vendor = get_string(GL_VENDOR);
	renderer = get_string(GL_RENDERER);
	version = get_string(GL_VERSION);
	say("MONDRIAN MESA TEST: vendor %s\n",
	    vendor != NULL ? (const char *)vendor : "(null)");
	say("MONDRIAN MESA TEST: renderer %s\n",
	    renderer != NULL ? (const char *)renderer : "(null)");
	say("MONDRIAN MESA TEST: version %s\n",
	    version != NULL ? (const char *)version : "(null)");

	viewport(0, 0, kWidth, kHeight);
	clear_color(0.25f, 0.5f, 0.75f, 1.0f);
	clear(GL_COLOR_BUFFER_BIT);
	finish();
	if (get_error() != GL_NO_ERROR) {
		say("MONDRIAN MESA TEST: GL error 0x%x after the clear\n",
		    get_error());
	}
	memset(pixel, 0, sizeof(pixel));
	read_pixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
	say("MONDRIAN MESA TEST: pixel %u %u %u %u\n", pixel[0], pixel[1],
	    pixel[2], pixel[3]);
	if (pixel[0] < 60 || pixel[0] > 68 || pixel[1] < 124 || pixel[1] > 132 ||
	    pixel[2] < 187 || pixel[2] > 195) {
		say("MONDRIAN MESA TEST: FAILED (wrong pixels)\n");
		free(pixels);
		goto out;
	}
	if (renderer != NULL && (strstr((const char *)renderer, "FD") != NULL ||
	    strstr((const char *)renderer, "freedreno") != NULL ||
	    strstr((const char *)renderer, "Adreno") != NULL)) {
		say("MONDRIAN MESA TEST: PASSED (the GPU drew it)\n");
	} else {
		say("MONDRIAN MESA TEST: SOFTWARE (Mesa fell back, no GPU screen)\n");
	}
	free(pixels);

out:
	if (console_fd >= 0) {
		close(console_fd);
	}
}
