/*
 * The boot menu of the shim, v0: drawing and a countdown, no keys yet.
 *
 * The band sits at the bottom of the framebuffer, over whatever the
 * diagnostic console printed (the console writes from the top, so nothing
 * is lost), and the countdown returns the default choice: iOS. The keys
 * are a later version -- the power key is not a TLMM gpio, it comes out
 * of the PMIC's PON state machine over SPMI, and one volume key may be a
 * gpio; the stock device tree is the source for where they actually are.
 * What v0 proves is the drawing: the band survives until the kernel's own
 * console takes the framebuffer over, the countdown leaves by itself, and
 * the loader boots the same kernel it always did.
 *
 * No absolute addresses in .rodata (the image is linked at 0 and loaded
 * wherever ABL puts it): the strings are char arrays and the font is
 * reached like console.c reaches it. The geometry uses the board table
 * constants (FB_*), which is what the console itself runs at
 * (BOARD_FB_FROM_DTB is 0 on both boards).
 */
#include <stdint.h>
#include "board.h"
#include "console.h"
#include "font.h"
#include "menu.h"

#define M_BG		0xff14141eU	/* the band behind the choices */
#define M_FG		0xffffffffU
#define M_HI_BG		0xff00c864U	/* the highlighted row's bar */
#define M_HI_FG		0xff001014U	/* its text */
#define M_DIM		0xff8a8a96U	/* the notes under the choices */
#define M_CD		0xffffff00U	/* the countdown */
#define M_EDGE		0xff00c0ffU	/* the band's top edge */

#define M_SCALE_TITLE	5
#define M_SCALE_ITEM	4
#define M_SCALE_NOTE	2
#define M_SCALE_CD	3
#define M_PAD		24		/* side margin inside the band */
#define M_GAP		10		/* between the rows */

/* A filled rectangle. */
static void
m_rect(int x, int y, int w, int h, uint32_t c)
{
	if (!con_fb)
		return;
	if (x + w > FB_W)
		w = FB_W - x;
	if (y + h > FB_H)
		h = FB_H - y;
	for (int i = 0; i < h; i++) {
		volatile uint32_t *line = con_fb +
		    (uint64_t)(y + i) * (FB_STRIDE / 4);
		for (int j = 0; j < w; j++)
			line[x + j] = c;
	}
}

/* One scaled glyph, foreground only (the caller paints the background). */
static void
m_glyph(int x, int y, char ch, int scale, uint32_t fg)
{
	if (ch < 0x20 || ch > 0x7e)
		ch = '?';
	const unsigned char *g = font8x16[ch - 0x20];
	if (x + 8 * scale > FB_W || y + 16 * scale > FB_H)
		return;
	for (int gy = 0; gy < 16; gy++)
		for (int gx = 0; gx < 8; gx++) {
			if (!(g[gy] & (0x80 >> gx)))
				continue;
			for (int sy = 0; sy < scale; sy++) {
				volatile uint32_t *p = con_fb +
				    (uint64_t)(y + gy * scale + sy) *
				    (FB_STRIDE / 4) + x + gx * scale;
				for (int sx = 0; sx < scale; sx++)
					p[sx] = fg;
			}
		}
}

static int
m_w(const char *s, int scale)
{
	int n = 0;

	while (s[n])
		n++;
	return n * 8 * scale;
}

static int
m_str(int x, int y, const char *s, int scale, uint32_t fg)
{
	for (int i = 0; s[i]; i++) {
		m_glyph(x, y, s[i], scale, fg);
		x += 8 * scale;
	}
	return x;
}

/* A line centered on the screen width. */
static void
m_center(int y, const char *s, int scale, uint32_t fg)
{
	int x = (FB_W - m_w(s, scale)) / 2;

	if (x < M_PAD)
		x = M_PAD;
	m_str(x, y, s, scale, fg);
}

static uint64_t
m_ticks(void)
{
	uint64_t t;

	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	return t;
}

static void
m_wait_ms(int ms)
{
	uint64_t f;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	uint64_t end = m_ticks() + f / 1000 * ms;
	while (m_ticks() < end)
		;
}

int
menu_show(void)
{
	static const char title[] = BOARD_NAME " boot menu";
	static const char items[][8] = { "iOS", "Android" };
	static const char notes[][48] = {
		"the root image lives in userdata",
		"not wired yet (v2: misc write)",
	};
	static const char leaving[] = "LEAVES AS IT IS: starting iOS";
	static const char cd_head[] = "starting iOS in ";
	char cd_line[20];
	int sel = MENU_DEFAULT;
	int h = 4			/* the top edge */
		+ 2 * M_PAD		/* above the title and below the countdown */
		+ 16 * M_SCALE_TITLE	/* the title */
		+ 2 * (16 * M_SCALE_ITEM + 16 * M_SCALE_NOTE)	/* two choices */
		+ 16 * M_SCALE_CD	/* the countdown */
		+ 4 * M_GAP;
	int y0, rowh;

	if (!con_fb)
		return sel;

	/* The whole band in one clear, then the edge above it. */
	y0 = FB_H - h;
	m_rect(0, y0, FB_W, h, M_BG);
	m_rect(0, y0, FB_W, 4, M_EDGE);

	int y = y0 + 4 + M_PAD;
	m_center(y, title, M_SCALE_TITLE, M_FG);
	y += 16 * M_SCALE_TITLE + M_GAP;

	for (int i = 0; i < 2; i++) {
		/* The bar behind the current choice is one cell wider
		 * around the text, so it reads as a row and not as
		 * background. */
		int tw = m_w(items[i], M_SCALE_ITEM);

		rowh = 16 * M_SCALE_ITEM + 4;
		if (i == sel)
			m_rect((FB_W - tw) / 2 - 16, y - 2, tw + 32, rowh,
			       M_HI_BG);
		m_center(y, items[i], M_SCALE_ITEM,
			 i == sel ? M_HI_FG : M_FG);
		y += rowh;
		m_center(y, notes[i], M_SCALE_NOTE, M_DIM);
		y += 16 * M_SCALE_NOTE + M_GAP;
	}

	/* The countdown. Each second rewrites only its own row; the rest of
	 * the band keeps what it has, so a photograph cannot come out
	 * mid-clear. */
	int cd_y = y;
	for (int n = MENU_SECONDS; n > 0; n--) {
		char *p = cd_line;
		const char *q = cd_head;

		while (*q)
			*p++ = *q++;
		*p++ = (char)('0' + n);
		*p++ = 's';
		*p = 0;
		m_rect(0, cd_y, FB_W, 16 * M_SCALE_CD, M_BG);
		m_center(cd_y, cd_line, M_SCALE_CD, M_CD);
		m_wait_ms(1000);
	}
	m_rect(0, cd_y, FB_W, 16 * M_SCALE_CD, M_BG);
	m_center(cd_y, leaving, M_SCALE_CD, M_FG);

	/* v0 has no input: the countdown always lands on the default. */
	return sel;
}
