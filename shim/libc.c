/*
 * The four libc functions a freestanding build can still need: the compiler
 * emits calls to them for struct initialisation and copies, and the
 * bare-metal toolchain (aarch64-elf) does not provide a libc.
 */
#include <stddef.h>
#include <stdint.h>

void *
memset(void *dst, int c, size_t n)
{
	volatile uint8_t *d = (volatile uint8_t *)dst;
	while (n--)
		*d++ = (uint8_t)c;
	return dst;
}

void *
memcpy(void *dst, const void *src, size_t n)
{
	volatile uint8_t *d = (volatile uint8_t *)dst;
	const uint8_t *s = (const uint8_t *)src;
	while (n--)
		*d++ = *s++;
	return dst;
}

void *
memmove(void *dst, const void *src, size_t n)
{
	uint8_t *d = (uint8_t *)dst;
	const uint8_t *s = (const uint8_t *)src;
	if (d < s) {
		while (n--)
			*d++ = *s++;
	} else {
		d += n;
		s += n;
		while (n--)
			*--d = *--s;
	}
	return dst;
}

int
memcmp(const void *a, const void *b, size_t n)
{
	const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
	for (size_t i = 0; i < n; i++) {
		if (x[i] != y[i])
			return x[i] - y[i];
	}
	return 0;
}
