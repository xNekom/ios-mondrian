#pragma once
#include <stdint.h>
#include "board.h"

#define FB_PHYS	FB_BASE

struct mmu_info {
	uint64_t img_lo, img_hi, ttbr;
	uint64_t sctlr_before, sctlr_after;
	int n_l3;
};

int mmu_enable(struct mmu_info *info);
uint64_t mmu_probe(uintptr_t va);

/*
 * Temporary map for the wipe of the kernel's window: the image and the
 * device-tree memory regions are Normal non-cacheable, everything else stays
 * Device. No store is cached, so `mmu_wipe_end` needs no cache maintenance.
 */
int mmu_wipe_begin(uint64_t lo, uint64_t hi, const uint64_t *regs, int nregs);
void mmu_wipe_end(void);
