/*
 * And OpenGL ES? The page loaded, the GPU process created its surface, locked
 * it, wrote nothing and reached neither Metal nor these CoreGraphics entry
 * points. Each GLES entry point dies with a different signal so the ring's
 * `CRASH ... sig N` names it: SIGILL for glClear, SIGTRAP for glDrawArrays,
 * SIGABRT for glTexImage2D.
 */
#import <Foundation/Foundation.h>
#import <OpenGLES/ES2/gl.h>
#include <signal.h>
#include <unistd.h>

static void
mondrian_gl_die(int sig)
{
	raise(sig);
	for (;;) {
		sleep(1);
	}
}

static void
mondrian_gl_clear(GLbitfield mask)
{
	(void)mask;
	mondrian_gl_die(SIGILL);
}

static void
mondrian_gl_arrays(GLenum mode, GLint first, GLsizei count)
{
	(void)mode; (void)first; (void)count;
	mondrian_gl_die(SIGTRAP);
}

static void
mondrian_gl_tex(GLenum target, GLint level, GLint internalformat,
    GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type,
    const void *pixels)
{
	(void)target; (void)level; (void)internalformat; (void)width; (void)height;
	(void)border; (void)format; (void)type; (void)pixels;
	mondrian_gl_die(SIGABRT);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
	const void *replacement;
	const void *replaced;
} mondrian_gl_interpose[] = {
	{ (const void *)mondrian_gl_clear, (const void *)glClear },
	{ (const void *)mondrian_gl_arrays, (const void *)glDrawArrays },
	{ (const void *)mondrian_gl_tex, (const void *)glTexImage2D },
};
