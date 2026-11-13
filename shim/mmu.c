/*
 * Milestone 3: EL1 stage-1 MMU with the granule XNU uses.
 *
 * T0SZ=28 gives a 36-bit VA whose walk starts at level 2: one table of
 * 2048 blocks covers 64GB, identity mapped (VA == PA).
 *
 * Qualcomm XPUs fault on speculative reads of protected carve-outs (TZ,
 * hyp, modem...), so nothing is mapped cacheable except our own image:
 *   - default: Device-nGnRnE, execute-never (same as MMU off)
 *   - the block(s) holding the image get an L3 table: image pages are
 *     Normal write-back, the rest of the block stays Device
 *   - the splash framebuffer block is Normal non-cacheable (write-combining)
 *
 * The granule is the one of the board (shim/board.h): 16 KiB for sweet,
 * 4 KiB for mondrian. With 16 KiB a level 2 block covers 32MB, with 4 KiB
 * it covers 8MB.
 */
#include <stdint.h>
#include "board.h"
#include "mmu.h"

#define PG_SHIFT	BOARD_PG_SHIFT
#define PG_SIZE		(1UL << PG_SHIFT)
#define BLK_SHIFT	(PG_SHIFT + 11)		/* 2048 entries of one granule */
#define BLK_SIZE	(1UL << BLK_SHIFT)
#define NENT		2048

#define ATTR_DEV	0	/* MAIR attr0 = 0x00 Device-nGnRnE */
#define ATTR_WB		1	/* MAIR attr1 = 0xff Normal WB RW-alloc */
#define ATTR_NC		2	/* MAIR attr2 = 0x44 Normal non-cacheable */
#define MAIR_VAL	0x44ff00UL

#define D_BLOCK		1UL
#define D_TABLE		3UL
#define D_PAGE		3UL
#define D_ATTR(i)	((uint64_t)(i) << 2)
#define D_SH_OUTER	(2UL << 8)
#define D_SH_INNER	(3UL << 8)
#define D_AF		(1UL << 10)
#define D_PXN		(1UL << 53)
#define D_UXN		(1UL << 54)

#define DEV_FLAGS	(D_ATTR(ATTR_DEV) | D_AF | D_PXN | D_UXN)
#define WB_FLAGS	(D_ATTR(ATTR_WB) | D_SH_INNER | D_AF | D_UXN)
#define NC_FLAGS	(D_ATTR(ATTR_NC) | D_SH_OUTER | D_AF | D_PXN | D_UXN)

/* TCR: T0SZ=28, IRGN0/ORGN0=WBWA, SH0=inner, TG0/TG1=the board's granule,
 * IPS=36 bit. TG0: 0b10 = 16 KiB, 0b00 = 4 KiB. TG1: 0b01 = 16 KiB, 0b00 =
 * 4 KiB. */
#if PG_SHIFT == 14
#define TCR_VAL		(28UL | (1UL << 8) | (1UL << 10) | (3UL << 12) | (2UL << 14) | \
			 (28UL << 16) | (1UL << 23) | (1UL << 30) | (1UL << 32))
#else
#define TCR_VAL		(28UL | (1UL << 8) | (1UL << 10) | (3UL << 12) | \
			 (28UL << 16) | (1UL << 30) | (1UL << 32))
#endif

#define SCTLR_M		(1UL << 0)
#define SCTLR_A		(1UL << 1)
#define SCTLR_C		(1UL << 2)
#define SCTLR_I		(1UL << 12)
#define SCTLR_WXN	(1UL << 19)

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })
#define wsr(r, v) __asm__ volatile("msr " r ", %0" : : "r"((uint64_t)(v)))

extern char _head[], _end[];

/* 1 L2 + up to 2 L3 tables, plus slack to align to 16K at runtime */
static uint64_t pt_pool[4 * NENT] __attribute__((aligned(4096)));

static void dcache_inval_range(uintptr_t start, uintptr_t end)
{
	uint64_t line = 4UL << ((rsr("ctr_el0") >> 16) & 0xf);

	for (uintptr_t a = start & ~(line - 1); a < end; a += line)
		__asm__ volatile("dc ivac, %0" : : "r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static void zero_table(uint64_t *t)
{
	for (int i = 0; i < NENT; i++)
		t[i] = 0;
}

int mmu_enable(struct mmu_info *info)
{
	uintptr_t img_lo = (uintptr_t)_head & ~(PG_SIZE - 1);
	uintptr_t img_hi = ((uintptr_t)_end + PG_SIZE - 1) & ~(PG_SIZE - 1);
	uintptr_t pool = ((uintptr_t)pt_pool + PG_SIZE - 1) & ~(PG_SIZE - 1);
	uint64_t *l2 = (uint64_t *)pool;
	int n_l3 = 0;

	info->img_lo = img_lo;
	info->img_hi = img_hi;
	info->ttbr = pool;
	if (((img_hi - 1) >> BLK_SHIFT) - (img_lo >> BLK_SHIFT) > 1)
		return -1;	/* only room for two L3 tables */

	/* L2: Device everywhere RAM or MMIO can be (first 8GB), rest unmapped */
	zero_table(l2);
	for (uint64_t i = 0; i < (8UL << 30) >> BLK_SHIFT; i++)
		l2[i] = (i << BLK_SHIFT) | DEV_FLAGS | D_BLOCK;
	l2[FB_PHYS >> BLK_SHIFT] = (FB_PHYS & ~(BLK_SIZE - 1)) | NC_FLAGS | D_BLOCK;

	/* L3 for each block that holds part of the image */
	for (uint64_t blk = img_lo >> BLK_SHIFT; blk <= (img_hi - 1) >> BLK_SHIFT; blk++) {
		uint64_t *l3 = (uint64_t *)(pool + (1 + n_l3++) * PG_SIZE);
		uint64_t base = blk << BLK_SHIFT;
		for (int i = 0; i < NENT; i++) {
			uint64_t pa = base + ((uint64_t)i << PG_SHIFT);
			int ours = pa >= img_lo && pa < img_hi;
			l3[i] = pa | (ours ? WB_FLAGS : DEV_FLAGS) | D_PAGE;
		}
		l2[blk] = (uintptr_t)l3 | D_TABLE;
	}
	info->n_l3 = n_l3;

	/* Image lines may be stale in the cache from ABL; we wrote memory directly. */
	dcache_inval_range(img_lo, img_hi);
	__asm__ volatile("ic iallu; dsb sy; isb" ::: "memory");

	wsr("mair_el1", MAIR_VAL);
	wsr("tcr_el1", TCR_VAL);
	wsr("ttbr0_el1", pool);
	__asm__ volatile("isb; tlbi vmalle1; dsb nsh; isb" ::: "memory");

	uint64_t sctlr = rsr("sctlr_el1");
	info->sctlr_before = sctlr;
	sctlr &= ~(SCTLR_A | SCTLR_WXN);
	sctlr |= SCTLR_M | SCTLR_C | SCTLR_I;
	wsr("sctlr_el1", sctlr);
	__asm__ volatile("isb" ::: "memory");
	info->sctlr_after = rsr("sctlr_el1");
	return 0;
}

/* Translate a VA with AT S1E1R; returns PAR_EL1. */
uint64_t mmu_probe(uintptr_t va)
{
	__asm__ volatile("at s1e1r, %0; isb" : : "r"(va) : "memory");
	return rsr("par_el1");
}

/*
 * ---- the wipe map ----
 *
 * The kernel's window has to be scrubbed before the kernel starts, and with
 * the MMU off every store is Device-nGnRnE: one transaction each, nothing
 * merged, and nine gibibytes of window cost minutes (measured: ~175 s of a
 * boot, with the kernel itself entering 15 ms after arm_init).
 *
 * Mapped Normal non-cacheable the stores merge into full-width bursts and
 * nothing is cached, so turning the MMU back off needs no clean and leaves
 * no dirty line behind for the kernel. The image is non-cacheable but
 * executable; every region the device tree does not call memory, and the
 * firmware carve-outs, stay Device exactly as they are with the MMU off.
 */
#define NCX_FLAGS	(D_ATTR(ATTR_NC) | D_SH_OUTER | D_AF | D_UXN)

/* IPS 36 bits: the window lives above 4 GiB and TCR_VAL says 32. */
#define TCR_WIPE	((TCR_VAL & ~(7UL << 32)) | (2UL << 32))

static int
wipe_is_mem(uint64_t pa, uint64_t lo, uint64_t hi, const uint64_t *regs,
    int nregs)
{
	if (pa < lo || pa >= hi)
		return 0;
	for (int i = 0; i < nregs; i++) {
		uint64_t r = regs[i * 2], s = regs[i * 2 + 1];

		if (pa >= r && pa < r + s)
			return 1;
	}
	return 0;
}

static int
mmu_temp_on(uint64_t *ttbr, uint64_t tcr)
{
	uint64_t sctlr;

	wsr("mair_el1", MAIR_VAL);
	wsr("tcr_el1", tcr);
	wsr("ttbr0_el1", (uint64_t)(uintptr_t)ttbr);
	__asm__ volatile("isb; tlbi vmalle1; dsb nsh; isb" ::: "memory");

	sctlr = rsr("sctlr_el1");
	sctlr &= ~(SCTLR_A | SCTLR_WXN);
	sctlr |= SCTLR_M | SCTLR_C | SCTLR_I;
	wsr("sctlr_el1", sctlr);
	__asm__ volatile("isb" ::: "memory");
	return 0;
}

void
mmu_wipe_end(void)
{
	/* Nothing was cached; the barrier only retires the merged stores. */
	__asm__ volatile("dsb sy" ::: "memory");
	wsr("sctlr_el1", rsr("sctlr_el1") & ~SCTLR_M);
	__asm__ volatile("isb" ::: "memory");
}

#if PG_SHIFT == 12
/* 4 KiB granule: T0SZ=28 starts the walk at level 1 (512 blocks of 1 GiB);
 * the entries that hold the image or the window get a level 2 table of
 * 2 MiB blocks. */
#define WIPE_L1_SHIFT	30
#define WIPE_L2_SHIFT	21
#define WIPE_L2_NENT	512
#define WIPE_L2_MAX	20

static uint64_t wipe_l1[512] __attribute__((aligned(16384)));
static uint64_t wipe_l2[WIPE_L2_MAX][WIPE_L2_NENT] __attribute__((aligned(16384)));

int
mmu_wipe_begin(uint64_t lo, uint64_t hi, const uint64_t *regs, int nregs)
{
	uintptr_t img_lo = (uintptr_t)_head & ~(PG_SIZE - 1);
	uintptr_t img_hi = ((uintptr_t)_end + PG_SIZE - 1) & ~(PG_SIZE - 1);
	int nl2 = 0;

	for (uint64_t e = 0; e < 512; e++)
		wipe_l1[e] = (e << WIPE_L1_SHIFT) | DEV_FLAGS | D_BLOCK;

	for (uint64_t e = 0; e < 512; e++) {
		uint64_t base = e << WIPE_L1_SHIFT;
		int want = base < img_hi && base + (1UL << WIPE_L1_SHIFT) > img_lo;

		for (int i = 0; !want && i < nregs; i++) {
			uint64_t r = regs[i * 2], s = regs[i * 2 + 1];
			uint64_t a = r > lo ? r : lo;
			uint64_t b = (r + s) < hi ? (r + s) : hi;

			if (a < b && a < base + (1UL << WIPE_L1_SHIFT) && b > base)
				want = 1;
		}
		if (!want)
			continue;
		if (nl2 >= WIPE_L2_MAX)
			return -1;

		uint64_t *l2 = wipe_l2[nl2++];

		for (int i = 0; i < WIPE_L2_NENT; i++) {
			uint64_t pa = base + ((uint64_t)i << WIPE_L2_SHIFT);
			uint64_t f = DEV_FLAGS;

			if (pa >= img_lo && pa < img_hi)
				f = NCX_FLAGS;
			else if (wipe_is_mem(pa, lo, hi, regs, nregs))
				f = NC_FLAGS;
			l2[i] = pa | f | D_BLOCK;
		}
		wipe_l1[e] = (uint64_t)(uintptr_t)l2 | D_TABLE;
	}

	return mmu_temp_on(wipe_l1, TCR_WIPE);
}
#else
/* 16 KiB granule: T0SZ=28 starts at level 2, whose 2048 blocks of 32 MiB are
 * the whole address space that leaves, so the table is the map. */
#define WIPE_BLK_SHIFT	25
#define WIPE_BLK_NENT	2048

static uint64_t wipe_blocks[WIPE_BLK_NENT] __attribute__((aligned(16384)));

int
mmu_wipe_begin(uint64_t lo, uint64_t hi, const uint64_t *regs, int nregs)
{
	uintptr_t img_lo = (uintptr_t)_head & ~(PG_SIZE - 1);
	uintptr_t img_hi = ((uintptr_t)_end + PG_SIZE - 1) & ~(PG_SIZE - 1);

	for (int i = 0; i < WIPE_BLK_NENT; i++) {
		uint64_t pa = (uint64_t)i << WIPE_BLK_SHIFT;
		uint64_t f = DEV_FLAGS;

		if (pa >= img_lo && pa < img_hi)
			f = NCX_FLAGS;
		else if (wipe_is_mem(pa, lo, hi, regs, nregs))
			f = NC_FLAGS;
		wipe_blocks[i] = pa | f | D_BLOCK;
	}

	return mmu_temp_on(wipe_blocks, TCR_WIPE);
}
#endif
