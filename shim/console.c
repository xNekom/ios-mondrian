/*
 * Minimal text console on the ABL splash framebuffer. With the MMU off
 * every access is Device memory, so stay aligned (-mstrict-align).
 *
 * The framebuffer is not a compile time constant: the shim takes it from
 * the device tree the bootloader passed, and the console stays off until it
 * knows one (see con_enable). Writing to a guessed address could hit a
 * peripheral register, so an unknown framebuffer means no output at all.
 */
#include "console.h"
#include "font.h"

/*
 * The log viewer prints kernel lines, which run to ~90 characters: at scale 2
 * the screen holds 87 columns and 98 rows instead of 58 and 65.
 */
#ifdef LOGVIEW
#define SCALE		2
#else
#define SCALE		3
#endif
#define CH_W		(8 * SCALE)
#define CH_H		(16 * SCALE)
#define MARGIN		24
#define LABEL_COLS	8

volatile uint32_t *con_fb;
static uint32_t con_bg;
static int row;
static int con_w = FB_W;
static int con_h = FB_H;

/* Point the console at the framebuffer the bootloader left. */
void con_enable(uintptr_t base, int w, int h)
{
	con_fb = (volatile uint32_t *)base;
	con_w = w > 0 ? w : FB_W;
	con_h = h > 0 ? h : FB_H;
}

void con_clear(uint32_t bg)
{
	uint64_t pair = ((uint64_t)bg << 32) | bg;

	if (!con_fb)
		return;
	/* With the MMU off every store is its own Device transaction: one
	 * 64-bit store per two pixels halves the number of them. */
	for (int y = 0; y < con_h; y++) {
		volatile uint64_t *line = (volatile uint64_t *)(con_fb +
		    y * (FB_STRIDE / 4));
		for (int x = 0; x < con_w / 2; x++)
			line[x] = pair;
	}
	con_bg = bg;
	row = 0;
}

/*
 * The screen is a fixed grid; when the next line would fall off the
 * bottom, move the visible text up one cell and clear the new last row.
 * It used to drop the line instead, which loses the interesting part of a
 * boot. The copy is the same kind of Device burst as con_clear().
 */
static void con_advance(void)
{
	int rows = (con_h - 2 * MARGIN) / CH_H;

	if (row < rows) {
		row++;
		return;
	}
	if (con_fb) {
		int keep = con_h - CH_H;

		for (int y = 0; y < keep; y++) {
			volatile uint64_t *dst = (volatile uint64_t *)(con_fb +
			    y * (FB_STRIDE / 4));
			volatile uint64_t *src = (volatile uint64_t *)(con_fb +
			    (y + CH_H) * (FB_STRIDE / 4));
			for (int x = 0; x < con_w / 2; x++)
				dst[x] = src[x];
		}
		for (int y = keep; y < con_h; y++) {
			volatile uint64_t *line = (volatile uint64_t *)(con_fb +
			    y * (FB_STRIDE / 4));
			uint64_t pair = ((uint64_t)con_bg << 32) | con_bg;
			for (int x = 0; x < con_w / 2; x++)
				line[x] = pair;
		}
	}
	row = rows - 1;
}

static void put_char(int col, char ch, uint32_t fg)
{
	if (ch < 0x20 || ch > 0x7e)
		ch = '?';
	const unsigned char *g = font8x16[ch - 0x20];
	int x0 = MARGIN + col * CH_W, y0 = MARGIN + row * CH_H;
	if (x0 + CH_W > con_w || y0 + CH_H > con_h)
		return;
	for (int gy = 0; gy < 16; gy++)
		for (int gx = 0; gx < 8; gx++) {
			if (!(g[gy] & (0x80 >> gx)))
				continue;
			for (int sy = 0; sy < SCALE; sy++) {
				volatile uint32_t *p = con_fb + (y0 + gy * SCALE + sy) * (FB_STRIDE / 4)
						       + x0 + gx * SCALE;
				for (int sx = 0; sx < SCALE; sx++)
					p[sx] = fg;
			}
		}
}

static int put_str(int col, const char *s, uint32_t fg)
{
	if (!con_fb)
		return 0;
	while (*s)
		put_char(col++, *s++, fg);
	return col;
}

static void fmt_hex(char *buf, uint64_t v, int digits)
{
	static const char hex[] = "0123456789ABCDEF";
	for (int i = 0; i < digits; i++)
		buf[i] = hex[(v >> (4 * (digits - 1 - i))) & 0xf];
	buf[digits] = 0;
}

void con_skip(void)
{
	con_advance();
}

void con_str(const char *label, const char *s)
{
	put_str(0, label, YELLOW);
	put_str(LABEL_COLS, s, WHITE);
	con_advance();
}

/* A raw line, for machine readable output (the dtb dump). */
void con_line(const char *s)
{
	put_str(0, s, WHITE);
	con_advance();
}

void con_hex(const char *label, uint64_t v)
{
	char buf[17];
	fmt_hex(buf, v, 16);
	con_str(label, buf);
}

void con_hex64(const char *label, uint64_t v)
{
	char buf[19];

	buf[0] = '0';
	buf[1] = 'x';
	fmt_hex(buf + 2, v, 16);
	int col = put_str(0, label, YELLOW);
	col = col < LABEL_COLS ? LABEL_COLS : col + 1;
	put_str(col, buf, WHITE);
	con_advance();
}

void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb)
{
	char buf[9];
	int col = put_str(0, label, YELLOW);
	col = col < LABEL_COLS ? LABEL_COLS : col + 1;
	col = put_str(col, a, YELLOW);
	fmt_hex(buf, va, 8);
	col = put_str(col, buf, WHITE);
	if (b) {
		col = put_str(col + 1, b, YELLOW);
		fmt_hex(buf, vb, 8);
		put_str(col, buf, WHITE);
	}
	con_advance();
}

void con_bytes(const char *label, const void *p, int n)
{
	static const char digits[] = "0123456789abcdef";
	const unsigned char *b = p;
	char buf[3];
	int col = put_str(0, label, YELLOW);
	col = col < LABEL_COLS ? LABEL_COLS : col + 1;
	for (int i = 0; i < n; i++) {
		if (i && !(i & 3)) {
			buf[0] = ' ';
			buf[1] = 0;
			col = put_str(col, buf, WHITE);
		}
		buf[0] = digits[b[i] >> 4];
		buf[1] = digits[b[i] & 15];
		buf[2] = 0;
		col = put_str(col, buf, WHITE);
	}
	con_advance();
}
