/*
 * What tools/gpu/eagl.c asks of the OpenGL ES library behind it besides the gl* functions:
 * see tools/gpu/gl_osmesa.c, the one implementation there is.
 */
#ifndef MONDIAN_GL_H
#define MONDIAN_GL_H

#include <stdint.h>

struct mondrian_gl;

struct mondrian_gl *mondrian_gl_create(int version);            /* a context of OpenGL ES 2 or 3; NULL: none to be had */
int mondrian_gl_make_current(struct mondrian_gl *gl);
int mondrian_gl_is_current(struct mondrian_gl *gl);           /* ... the calling thread's (NULL: none); 0 on failure */
void mondrian_gl_destroy(struct mondrian_gl *gl);
const char *mondrian_gl_library(void);                          /* for the log */

/*
 * The texture bound to GL_TEXTURE_2D made of an IOSurface's own memory: what is drawn into the
 * texture is in the surface, what is in the surface is what the texture shows, and nobody copies.
 * For a library whose driver can do that (a GPU's) and a surface it can do it with. 0: not done;
 * the texture is to be filled and read back with OpenGL ES calls.
 *
 * `surface` is IOSurfaceGetID() of the surface. How that number reaches the GPU's memory is
 * gl_osmesa.c's business and the kernel's: see the comment there.
 */
int mondrian_gl_surface_texture(struct mondrian_gl *gl, uint32_t surface);

/*
 * CoreAnimation draws a layer's pixels with one of ninety "functions" (a fragment shader each);
 * these are the names its Metal renderer has for them, four characters a function, in their order.
 * (eagl.c's census and the vibrant-colour-matrix program are indexed by the same numbers.)
 */
#define MONDIAN_CA_FUNCTIONS \
	"clr img ida cim cid mua m1a lrp lrc lra add spl s1a cma bds bco bim c33 c3b c4b c4p c3a c3x c4x bia grl ds4 ds6 " \
	"ds8 ups db2 db4 nb7 n11 n15 n19 n23 n27 vrd vrb sb3 axl rad rac con vcm vdk vlt map mpc crv hue clm hom opa met " \
	"srl ega sdr alt p3c edr hrm lut ovr ovl lub aup alm stl pc0 pc1 prc psl ps0 ps1 psm psr pcr pbl peo bib asg a75 " \
	"a50 atc ipc apl 3dl cst "

#endif
