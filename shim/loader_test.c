/*
 * Host test of the loader's arithmetic: where does the kernel land?
 *
 *   gcc -O1 -Wall -o out/loader_test loader_test.c lz4.c
 *   out/loader_test payload.bin payload.lz4
 *
 * The loader copies the kernel segments to (vmaddr + phys_base - virt_base)
 * and puts the device tree and the boot arguments behind them. If the
 * window the shim picked does not hold the kernel, the copy writes
 * somewhere else, which on the phone shows up as an abort inside the
 * shim. This test does the same arithmetic with the real payload.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "lz4.h"

#define BOOT_LINE_LENGTH	608

struct payload_seg {
	uint64_t vmaddr, vmsize, file_off, file_size;
};

struct payload {
	char magic[8];
	uint32_t version, nsegs;
	uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
	uint64_t phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	struct payload_seg segs[];
};

static uint8_t *slurp(const char *path, long *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *buf = malloc((size_t)n);
	if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n)
		return NULL;
	fclose(f);
	*len = n;
	return buf;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s payload.bin payload.lz4\n", argv[0]);
		return 2;
	}
	long plen = 0, clen = 0;
	uint8_t *raw = slurp(argv[1], &plen);
	uint8_t *comp = slurp(argv[2], &clen);
	if (!raw || !comp)
		return 2;

	/* The window the shim picks: the region with the splash. */
	uint64_t phys_base = 0x80000000UL, mem_size = 0x6a000000UL;
	/* The unpacked payload goes past the kernel image. */
	uint64_t scratch = phys_base + 0x2000000UL;

	uint8_t *out = malloc((size_t)plen);
	long n = lz4_decompress_frame(comp, clen, out, (size_t)plen);
	if (n < 0 || n != plen) {
		fprintf(stderr, "FAIL: the payload does not unpack (%ld of %ld)\n", n, plen);
		return 1;
	}
	if (memcmp(out, raw, (size_t)plen) != 0) {
		fprintf(stderr, "FAIL: the unpacked payload differs from the original\n");
		return 1;
	}
	printf("payload unpacked: %ld bytes, identical\n", n);

	const struct payload *p = (const struct payload *)out;
	printf("virt_base=%016lx entry_va=%016lx nsegs=%u\n", p->virt_base, p->entry_va, p->nsegs);

	uint64_t pa_of_va_base = phys_base - p->virt_base;
	uint64_t lo = ~0ULL, hi = 0;
	for (uint32_t i = 0; i < p->nsegs; i++) {
		uint64_t dst = p->segs[i].vmaddr + pa_of_va_base;
		printf("  seg%u dst=%016lx size=%016lx file=%016lx\n", i, dst,
		       p->segs[i].vmsize, p->segs[i].file_off);
		if (dst < lo)
			lo = dst;
		if (dst + p->segs[i].vmsize > hi)
			hi = dst + p->segs[i].vmsize;
	}
	printf("kernel image: %016lx .. %016lx\n", lo, hi);
	printf("window:       %016lx .. %016lx\n", phys_base, phys_base + mem_size);
	printf("scratch:      %016lx .. %016lx\n", scratch, scratch + plen);
	printf("adt:          %016lx  boot args after it\n", p->kernel_end + pa_of_va_base);

	int bad = 0;
	if (lo < phys_base || hi > phys_base + mem_size) {
		printf("FAIL: the kernel does not fit in the window\n");
		bad = 1;
	}
	if (scratch + plen > phys_base + mem_size) {
		printf("FAIL: the scratch does not fit in the window\n");
		bad = 1;
	}
	if (scratch < hi && scratch + plen > lo) {
		printf("FAIL: the scratch overlaps the kernel image\n");
		bad = 1;
	}
	if (!bad)
		printf("the copy stays inside the window\n");
	return bad;
}
