/*
 * Host test of the device tree parser against a real device tree.
 *
 *   gcc -O1 -Wall -o out/fdt_live_test fdt.c fdt_live_test.c
 *   out/fdt_live_test mondrian-live.dtb
 *
 * The shim reads the phone's device tree to know the memory banks, the
 * framebuffer and the UFS host. This test replays that against a tree
 * captured from the phone, so a parsing problem shows up on the host
 * instead of on the screen of a phone.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "fdt.h"

static uint8_t *slurp(const char *path, long *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "cannot open %s\n", path);
		return NULL;
	}
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *buf = malloc((size_t)n);
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
	if (argc < 2) {
		fprintf(stderr, "usage: %s file.dtb\n", argv[0]);
		return 2;
	}
	long len = 0;
	uint8_t *dtb = slurp(argv[1], &len);
	if (!dtb)
		return 2;

	char path[64];
	uint64_t regs[64];
	uint32_t ac = 2, sc = 2;
	int n;

	if (!fdt_find_name((uintptr_t)dtb, "memory", path, sizeof(path))) {
		printf("memory: NOT FOUND\n");
	} else {
		printf("memory: %s\n", path);
		printf("  #address-cells: %s (%u)\n",
		       fdt_node_u32((uintptr_t)dtb, path, "#address-cells", &ac) ? "node" : "root", ac);
		printf("  #size-cells:    %s (%u)\n",
		       fdt_node_u32((uintptr_t)dtb, path, "#size-cells", &sc) ? "node" : "root", sc);
		n = fdt_node_regs_cells((uintptr_t)dtb, path, regs, 32, (int)ac, (int)sc);
		printf("  fdt_node_regs_cells: %d regions\n", n);
		for (int i = 0; i < n; i++)
			printf("    %016lx + %016lx\n", regs[i * 2], regs[i * 2 + 1]);
		n = fdt_node_regs((uintptr_t)dtb, path, regs, 32);
		printf("  fdt_node_regs: %d regions\n", n);
		for (int i = 0; i < n; i++)
			printf("    %016lx + %016lx\n", regs[i * 2], regs[i * 2 + 1]);
	}

	if (fdt_find_compatible((uintptr_t)dtb, "qcom,ufshc", path, sizeof(path))) {
		n = fdt_node_regs((uintptr_t)dtb, path, regs, 4);
		printf("ufshc: %s, %d regions\n", path, n);
		for (int i = 0; i < n; i++)
			printf("    %016lx + %016lx\n", regs[i * 2], regs[i * 2 + 1]);
	} else {
		printf("ufshc: NOT FOUND\n");
	}

	uint64_t start = 0, end = 0;
	printf("chosen/linux,initrd-start: %s\n",
	       fdt_chosen_u64((uintptr_t)dtb, "linux,initrd-start", &start) ? "yes" : "no");
	printf("chosen/linux,initrd-end:   %s\n",
	       fdt_chosen_u64((uintptr_t)dtb, "linux,initrd-end", &end) ? "yes" : "no");
	return 0;
}
