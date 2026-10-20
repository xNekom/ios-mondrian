#pragma once
#include <stdint.h>
#include "board.h"

#define RED	0xffff0000U
#define BLUE	0xff0000a0U
#define WHITE	0xffffffffU
#define YELLOW	0xffffff00U
#define GREEN	0xff00ff00U

extern volatile uint32_t *con_fb;

/* The console writes nothing until it is pointed at a framebuffer. */
void con_enable(uintptr_t base, int w, int h);
void con_clear(uint32_t bg);
void con_skip(void);
void con_str(const char *label, const char *s);
void con_line(const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
/* label, then n bytes of memory as hex */
void con_bytes(const char *label, const void *p, int n);
