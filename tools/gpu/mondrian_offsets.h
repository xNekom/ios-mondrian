/*
 * Every number in this port's userland GPU code that is a property of the iOS build, in one
 * place: the addresses of CoreAnimation's GLES renderer in the shared cache, and the offsets of
 * the calls it makes through EAGLContext's function table.
 *
 * This file is NOT generic. It was filled in for the iPhone X 16.7.16 (20H392) userland this
 * port runs, from the same build a working a6xx port already used (its values are repeated
 * below with how to check them). docs/COREANIMATION_GLES.md has the procedure to re-derive
 * every one of them from a shared cache; tools/gpu/mondrian-offsets.py does the mechanical part.
 * When the phone's userland changes, this file is the only one to change.
 *
 * Nothing here has been run on hardware. The two function addresses are used as an assertion:
 * mondrian_inject.c replaces a vtable slot only if it still holds the address named here, and
 * prints what it found instead -- so a wrong number leaves the window server alone instead of
 * patching a stranger.
 */
#ifndef MONDIAN_OFFSETS_H
#define MONDIAN_OFFSETS_H

/* ---- the shared cache ---------------------------------------------------------------------- */

/*
 * The address the cache is built for; the slide is (where dyld put it) - this. Every other
 * address below is an unslid cache address, i.e. an offset from the first image of the cache.
 * 0x180000000 is the arm64 cache's base; a cache dumped with a different base shows it in its
 * first __TEXT segment (tools/gpu/mondrian-offsets.py --base).
 */
#define MONDIAN_CACHE_BASE                      0x180000000UL

/*
 * CoreAnimation's OpenGL ES context, the class whose two methods are hooked (see
 * mondrian_inject.c): __ZTVN2CA4OGL11GLESContextE, the vtable symbol of
 * CA::OGL::GLESContext, in QuartzCore.
 */
#define MONDIAN_CA_GLESCONTEXT_VTABLE           0x1d5b2f6e8UL

/*
 * The two entries of that vtable, as byte offsets from the vtable's first entry (the vtable's
 * own header is two words: offset-to-top and the typeinfo pointer, so the first entry is at
 * vtable + 0x10):
 *
 *   MONDIAN_CA_VSLOT_FUNCTION_SUPPORTED   CA::OGL::GLContext::function_supported() const
 *   MONDIAN_CA_VSLOT_FUNCTION_UNIFORM     CA::OGL::GLContext::function_uniform(unsigned,
 *                                         unsigned long, unsigned long, float const*)
 *
 * They are measured, not assumed: tools/gpu/mondrian-offsets.py reads the vtable and finds the
 * two entries that hold the two functions (see docs/COREANIMATION_GLES.md).
 */
#define MONDIAN_CA_VSLOT_FUNCTION_SUPPORTED     0x378
#define MONDIAN_CA_VSLOT_FUNCTION_UNIFORM       0x388

/* What those two slots hold, i.e. the functions the hooks stand in front of. */
#define MONDIAN_CA_FN_FUNCTION_SUPPORTED        0x1884b2164UL
#define MONDIAN_CA_FN_FUNCTION_UNIFORM          0x1884b21acUL

/*
 * Where a GLESContext keeps the "function" it is drawing with (mondrian_inject.c reads it to
 * tell eagl.c which function refused):
 *
 *     *(*(uint8_t **)((char *)context + MONDIAN_CA_CONTEXT_STATE)) + MONDIAN_CA_FUNCTION_FIELD
 *
 * with the second offset in units of bytes and the field an unsigned int. If -function_supported
 * is seen with a function number CoreAnimation does not have (>= 90), this pair is wrong for the
 * build.
 */
#define MONDIAN_CA_CONTEXT_STATE                0x10
#define MONDIAN_CA_FUNCTION_FIELD               0x10

/* ---- the call table behind -[EAGLContext getMacroContextPrivate] ---------------------------- */

/*
 * CoreAnimation calls every OpenGL ES function as entry(table[0], arguments...) where the entry
 * is at (offset / 8) of the table iOS's own GLES handed it. The offsets are properties of this
 * build's OpenGLES: a table entry the port places at the wrong offset is a call that goes
 * nowhere (or into another function). The 30 below are the ones eagl.c names while it works;
 * tools/gpu/eagl_slots.txt is the whole table, with the names to put at each entry.
 *
 * The values are the ones this build's table has; eagl_slots.txt and this file must agree, and
 * tools/gpu/mkeagl.py refuses to generate a header when they do not.
 */
#define MONDIAN_GL_TABLE_SLOTS                  0x440   /* entries; more than this build's table has */

#define MONDIAN_GL_BIND_TEXTURE                 0x30
#define MONDIAN_GL_CLEAR                        0x58
#define MONDIAN_GL_COPY_TEX_SUB_IMAGE_2D        0x1c8
#define MONDIAN_GL_DELETE_TEXTURES              0x1e0
#define MONDIAN_GL_DRAW_ARRAYS                  0x210
#define MONDIAN_GL_DRAW_ELEMENTS                0x220
#define MONDIAN_GL_FINISH                       0x2d0
#define MONDIAN_GL_FLUSH                        0x2d8
#define MONDIAN_GL_GET_INTEGERV                 0x348
#define MONDIAN_GL_GET_STRING                   0x3b0
#define MONDIAN_GL_TEX_IMAGE_2D                 0x970
#define MONDIAN_GL_TEX_SUB_IMAGE_2D             0x9a0
#define MONDIAN_GL_ACTIVE_TEXTURE               0xab8
#define MONDIAN_GL_COMPRESSED_TEX_IMAGE_2D      0xbe8
#define MONDIAN_GL_FINISH_OBJECT_APPLE          0xeb8
#define MONDIAN_GL_VERTEX_ATTRIB_POINTER        0x1000
#define MONDIAN_GL_DELETE_PROGRAM               0x1280
#define MONDIAN_GL_CREATE_SHADER                0x1298
#define MONDIAN_GL_SHADER_SOURCE                0x12a0
#define MONDIAN_GL_COMPILE_SHADER               0x12a8
#define MONDIAN_GL_LINK_PROGRAM                 0x12c0
#define MONDIAN_GL_USE_PROGRAM                  0x12c8
#define MONDIAN_GL_UNIFORM_MATRIX_4FV           0x1368
#define MONDIAN_GL_BIND_FRAMEBUFFER             0x1508
#define MONDIAN_GL_DELETE_FRAMEBUFFERS          0x1510
#define MONDIAN_GL_FRAMEBUFFER_TEXTURE_2D       0x1530
#define MONDIAN_GL_INSERT_EVENT_MARKER_EXT      0x1988
#define MONDIAN_GL_PUSH_GROUP_MARKER_EXT        0x1990
#define MONDIAN_GL_POP_GROUP_MARKER_EXT         0x1998
#define MONDIAN_GL_FRAMEBUFFER_PARAMETERI_APPLE 0x2008

/* ---- what the window server's EAGLContext is replaced with --------------------------------- */

/* The library mondrian_inject.c loads into backboardd before it hooks anything. */
#define MONDIAN_GL_LIBRARY                      "/usr/libexec/mondrian-gl.dylib"

#endif
