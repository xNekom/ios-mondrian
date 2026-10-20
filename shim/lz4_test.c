/*
 * Host test for the LZ4 decompressor: unpack a payload and compare it
 * with the original. Run from shim/:
 *
 *     gcc -O1 -Wall -o out/lz4_test lz4.c lz4_test.c
 *     out/lz4_test payload.lz4 payload.bin
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"

static unsigned char *slurp(const char *path, long *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "cannot open %s\n", path);
		return NULL;
	}
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char *buf = malloc((size_t)n);
	if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
		fprintf(stderr, "cannot read %s\n", path);
		return NULL;
	}
	fclose(f);
	*len = n;
	return buf;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s compressed.lz4 original.bin\n", argv[0]);
		return 2;
	}
	long clen = 0, olen = 0;
	unsigned char *comp = slurp(argv[1], &clen);
	unsigned char *orig = slurp(argv[2], &olen);
	if (!comp || !orig)
		return 2;

	unsigned char *out = malloc((size_t)olen);
	long n = lz4_decompress_frame(comp, (size_t)clen, out, (size_t)olen);
	if (n < 0) {
		fprintf(stderr, "FAIL: the decompressor rejected the input\n");
		return 1;
	}
	if (n != olen) {
		fprintf(stderr, "FAIL: %ld bytes out, %ld expected\n", n, olen);
		return 1;
	}
	if (memcmp(out, orig, (size_t)olen) != 0) {
		fprintf(stderr, "FAIL: the output differs from the original\n");
		return 1;
	}
	printf("lz4: %ld bytes in, %ld bytes out, identical\n", clen, n);
	return 0;
}
