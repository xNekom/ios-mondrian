/*
 * Mesa on the Adreno 730, without CoreAnimation.
 *
 * Creates an OSMesa context on freedreno's msm backend (this port's
 * MondrianGPU service through tools/mesa/mondrian-drm), draws one full-screen
 * triangle through a vertex buffer and a pair of shaders, reads the centre
 * pixel back and logs the renderer string. No clear anywhere: the clear path
 * is the one that ends in CP_BLIT, the packet this board's CP refuses, while
 * drawing is what CoreAnimation needs.
 *
 * Built as a dylib (tools/build-mondrian-mesa-test.sh) and dlopened by
 * mondrian-ui-hook.dylib. Everything is resolved with dlopen/dlsym so a
 * missing or broken Mesa is a logged line, not a process that will not load.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <IOKit/IOKitLib.h>

#define kMesaPath	"/usr/lib/libOSMesa.8.dylib"
#define kWidth		256
#define kHeight		256

/* The few GL constants this file needs, so it builds against the SDK alone. */
#define GL_UNSIGNED_BYTE	0x1401
#define GL_FLOAT		0x1406
#define GL_RGBA			0x1908
#define GL_VENDOR		0x1F00
#define GL_RENDERER		0x1F01
#define GL_VERSION		0x1F02
#define GL_VERTEX_SHADER	0x8B31
#define GL_FRAGMENT_SHADER	0x8B30
#define GL_ARRAY_BUFFER		0x8892
#define GL_STATIC_DRAW		0x88E4
#define GL_TRIANGLES		0x0004
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

struct gl {
	void (*viewport)(int, int, int, int);
	const unsigned char *(*get_string)(unsigned);
	void (*finish)(void);
	unsigned (*get_error)(void);
	void (*read_pixels)(int, int, int, int, unsigned, unsigned, void *);
	unsigned (*create_shader)(unsigned);
	void (*shader_source)(unsigned, int, const char **, const int *);
	void (*compile_shader)(unsigned);
	unsigned (*create_program)(void);
	void (*attach_shader)(unsigned, unsigned);
	void (*link_program)(unsigned);
	void (*use_program)(unsigned);
	void (*gen_buffers)(int, unsigned *);
	void (*bind_buffer)(unsigned, unsigned);
	void (*buffer_data)(unsigned, long, const void *, unsigned);
	void (*enable_vertex_attrib_array)(unsigned);
	void (*vertex_attrib_pointer)(unsigned, int, unsigned, unsigned char,
	    int, const void *);
	void (*draw_arrays)(unsigned, int, int);
};

#define RESOLVE(field, name)						\
	do {								\
		*(void **)(&gl->field) = dlsym(library, name);		\
		if (gl->field == NULL) {				\
			say("MONDRIAN MESA TEST: no %s\n", name);	\
			return NULL;					\
		}							\
	} while (0)

static struct gl *
resolve(void *library)
{
	static struct gl table;
	struct gl *gl = &table;

	RESOLVE(viewport, "glViewport");
	RESOLVE(get_string, "glGetString");
	RESOLVE(finish, "glFinish");
	RESOLVE(get_error, "glGetError");
	RESOLVE(read_pixels, "glReadPixels");
	RESOLVE(create_shader, "glCreateShader");
	RESOLVE(shader_source, "glShaderSource");
	RESOLVE(compile_shader, "glCompileShader");
	RESOLVE(create_program, "glCreateProgram");
	RESOLVE(attach_shader, "glAttachShader");
	RESOLVE(link_program, "glLinkProgram");
	RESOLVE(use_program, "glUseProgram");
	RESOLVE(gen_buffers, "glGenBuffers");
	RESOLVE(bind_buffer, "glBindBuffer");
	RESOLVE(buffer_data, "glBufferData");
	RESOLVE(enable_vertex_attrib_array, "glEnableVertexAttribArray");
	RESOLVE(vertex_attrib_pointer, "glVertexAttribPointer");
	RESOLVE(draw_arrays, "glDrawArrays");
	return gl;
}

/* A full-screen triangle through a VBO and two trivial shaders. */
static int
draw_triangle(struct gl *gl)
{
	const float vertices[] = {
		-1.0f, -1.0f, 0.0f,
		 3.0f, -1.0f, 0.0f,
		-1.0f,  3.0f, 0.0f,
	};
	const char *vertex_source =
	    "#version 120\nvoid main(void) { gl_Position = gl_Vertex; }\n";
	const char *fragment_source =
	    "#version 120\nvoid main(void) { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }\n";
	unsigned vertex, fragment, program, buffer;

	vertex = gl->create_shader(GL_VERTEX_SHADER);
	gl->shader_source(vertex, 1, &vertex_source, NULL);
	gl->compile_shader(vertex);
	fragment = gl->create_shader(GL_FRAGMENT_SHADER);
	gl->shader_source(fragment, 1, &fragment_source, NULL);
	gl->compile_shader(fragment);
	program = gl->create_program();
	gl->attach_shader(program, vertex);
	gl->attach_shader(program, fragment);
	gl->link_program(program);
	gl->use_program(program);

	gl->gen_buffers(1, &buffer);
	gl->bind_buffer(GL_ARRAY_BUFFER, buffer);
	gl->buffer_data(GL_ARRAY_BUFFER, (long)sizeof(vertices), vertices,
	    GL_STATIC_DRAW);
	gl->enable_vertex_attrib_array(0);
	gl->vertex_attrib_pointer(0, 3, GL_FLOAT, 0, 0, NULL);
	gl->draw_arrays(GL_TRIANGLES, 0, 3);
	return 0;
}

__attribute__((constructor))
static void
mondrian_mesa_test(void)
{
	void *library;
	struct osmesa_context *(*create)(unsigned, int, int, int, void *);
	unsigned char (*make_current)(struct osmesa_context *, void *, unsigned,
	    int, int);
	struct gl *gl;
	unsigned char *pixels;
	unsigned char pixel[4];
	const unsigned char *renderer, *version, *vendor;
	io_service_t service = 0;
	int i;

	console_fd = open("/dev/console", O_WRONLY);
	say("MONDRIAN MESA TEST: start\n");

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

	/*
	 * sysmem keeps resources in plain memory; noblit is what makes the
	 * driver skip the CP_BLIT surface clear (patched in tools/mesa to be a
	 * no-op under that flag), because this board's CP answers CP_BLIT with
	 * an opcode error.
	 */
	setenv("FD_MESA_DEBUG", "sysmem,noblit", 1);

	library = dlopen(kMesaPath, RTLD_NOW);
	if (library == NULL) {
		say("MONDRIAN MESA TEST: dlopen failed: %s\n", dlerror());
		goto out;
	}
	create = (struct osmesa_context *(*)(unsigned, int, int, int, void *))
	    dlsym(library, "OSMesaCreateContextExt");
	make_current = (unsigned char (*)(struct osmesa_context *, void *,
	    unsigned, int, int))dlsym(library, "OSMesaMakeCurrent");
	if (create == NULL || make_current == NULL) {
		say("MONDRIAN MESA TEST: the library has no OSMesa entry points\n");
		goto out;
	}
	gl = resolve(library);
	if (gl == NULL) {
		goto out;
	}

	pixels = (unsigned char *)calloc((size_t)kWidth * kHeight, 4);
	if (pixels == NULL) {
		say("MONDRIAN MESA TEST: out of memory\n");
		goto out;
	}
	{
		struct osmesa_context *context = create(GL_RGBA, 24, 8, 0, NULL);

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
	vendor = gl->get_string(GL_VENDOR);
	renderer = gl->get_string(GL_RENDERER);
	version = gl->get_string(GL_VERSION);
	say("MONDRIAN MESA TEST: vendor %s\n",
	    vendor != NULL ? (const char *)vendor : "(null)");
	say("MONDRIAN MESA TEST: renderer %s\n",
	    renderer != NULL ? (const char *)renderer : "(null)");
	say("MONDRIAN MESA TEST: version %s\n",
	    version != NULL ? (const char *)version : "(null)");

	gl->viewport(0, 0, kWidth, kHeight);
	if (draw_triangle(gl) != 0) {
		say("MONDRIAN MESA TEST: the draw path did not run\n");
		free(pixels);
		goto out;
	}
	gl->finish();
	if (gl->get_error() != GL_NO_ERROR) {
		say("MONDRIAN MESA TEST: GL error 0x%x after the draw\n",
		    gl->get_error());
	}
	memset(pixel, 0, sizeof(pixel));
	gl->read_pixels(kWidth / 2, kHeight / 2, 1, 1, GL_RGBA,
	    GL_UNSIGNED_BYTE, pixel);
	say("MONDRIAN MESA TEST: pixel %u %u %u %u\n", pixel[0], pixel[1],
	    pixel[2], pixel[3]);
	if (pixel[0] < 250 || pixel[1] > 6 || pixel[2] > 6) {
		say("MONDRIAN MESA TEST: FAILED (wrong pixels)\n");
		free(pixels);
		goto out;
	}
	if (renderer != NULL && (strstr((const char *)renderer, "FD") != NULL ||
	    strstr((const char *)renderer, "freedreno") != NULL ||
	    strstr((const char *)renderer, "Adreno") != NULL)) {
		say("MONDRIAN MESA TEST: PASSED (the GPU drew a triangle)\n");
	} else {
		say("MONDRIAN MESA TEST: SOFTWARE (Mesa fell back, no GPU screen)\n");
	}
	free(pixels);

out:
	if (console_fd >= 0) {
		close(console_fd);
	}
}
