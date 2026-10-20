/*
 * Milestone 4: act as iBoot for xnu.
 *
 * mkpayload.py already resolved the kernel's chained fixups and built the
 * ADT, so this only has to: find the payload in the ABL ramdisk, copy the
 * segments to phys_base + (vmaddr - virt_base), place the ADT and
 * boot_args behind the kernel, and jump to the entry point with the MMU
 * and caches off, x0 = boot_args (physical).
 */
#include <stdint.h>
#include "board.h"
#include "console.h"
#include "fdt.h"
#include "loader.h"
#include "lz4.h"

#define BOOT_LINE_LENGTH	608
#define PAGE_16K		0x4000UL

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

/* pexpert/pexpert/arm64/boot.h, Revision/Version 2 */
struct boot_video {
	uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	uint64_t bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload header layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

/* MMU off: everything is Device memory, so copy in aligned 8-byte words. */
static void copy64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile const uint64_t *s = (volatile const uint64_t *)src;
	for (uint64_t i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(uintptr_t dst, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	for (uint64_t i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int magic_ok(const char *m)
{
	static const char want[] = PAYLOAD_MAGIC;
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

/* The window of RAM the kernel gets. The device tree of the phone is the
 * truth about it; the payload header only knows what the image was built
 * for. */
static uint64_t win_base, win_size;

void loader_set_window(uint64_t base, uint64_t size)
{
	win_base = base;
	win_size = size;
}

/* The memory regions of the phone, from the device tree. */
static uint64_t mem_regs[64];
static int n_mem_regs;

void loader_set_regions(const uint64_t *regs, int n)
{
	if (n > 32)
		n = 32;
	for (int i = 0; i < n * 2; i++)
		mem_regs[i] = regs[i];
	n_mem_regs = n;
}

/* The memory regions, so the console can show what the shim picked. */
void loader_report_regions(void)
{
	for (int i = 0; i < n_mem_regs; i++)
		con_hex2("MEM", "at=", (uint32_t)(mem_regs[i * 2] >> 32),
			 "size=", (uint32_t)mem_regs[i * 2]);
}

typedef void (*xnu_entry_t)(uint64_t boot_args_pa);

/* How much of the ramdisk the payload takes. */
static uint64_t
payload_size(const struct payload *p)
{
	uint64_t end = p->adt_off + p->adt_size;

	for (uint32_t i = 0; i < p->nsegs; i++) {
		uint64_t e = p->segs[i].file_off + p->segs[i].file_size;
		if (e > end)
			end = e;
	}
	return end;
}

/*
 * The bootloader does not always tell us where it put the ramdisk: it
 * publishes the address in the device tree, and only when the image carries
 * a tree for it to patch. Look for the payload ourselves.
 */
static uintptr_t
loader_scan_payload(void)
{
	uint64_t want = 0;

	for (int k = 0; k < 8; k++)
		want |= (uint64_t)(unsigned char)PAYLOAD_MAGIC[k] << (8 * k);

	for (int i = 0; i < n_mem_regs; i++) {
		uint64_t base = mem_regs[i * 2], size = mem_regs[i * 2 + 1];
		con_hex2("SCAN", "at=", (uint32_t)(base >> 32), "size=", (uint32_t)base);
		for (uint64_t a = base; a + 64 <= base + size; a += 64) {
			if (*(volatile uint64_t *)a == want)
				return (uintptr_t)a;
		}
	}
	return 0;
}

/* The end of the shim image: the payload is appended right after it. */
extern char _end[];	/* the payload follows it: the compiler cannot know */

/* The appended payload, LZ4 compressed: the build cannot send 15MB over
 * the USB link of this phone. The header is read as bytes because the
 * compiler does not know that the payload follows _end.
 *
 *   0  "LZ4P"      4  version   8  raw size   16  compressed size   24 data
 */
#define BLOB_RAW	8
#define BLOB_COMP	16
#define BLOB_DATA	24

static uint64_t
blob_u64(const uint8_t *p)
{
	uint64_t v = 0;

	for (int i = 7; i >= 0; i--)
		v = (v << 8) | p[i];
	return v;
}

static uint32_t
blob_u32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int
blob_ok(const uint8_t *p)
{
	return p[0] == 'L' && p[1] == 'Z' && p[2] == '4' && p[3] == 'P' &&
	       blob_u32(p + 4) == 1;
}

const char *loader_boot(uintptr_t dtb)
{
	uint64_t rd_start, rd_end;

	/* The payload the build appended to this image, unpacked in place. */
	if (blob_ok((const uint8_t *)&_end[0])) {
		const uint8_t *b = (const uint8_t *)&_end[0];
		uint64_t raw = blob_u64(b + BLOB_RAW);
		uint64_t comp = blob_u64(b + BLOB_COMP);
		uint64_t scratch = win_base + 0x2000000UL;	/* past the kernel */

		if (!win_size || scratch + raw > win_base + win_size)
			return "no room to unpack the payload";
		long n = lz4_decompress_frame(b + BLOB_DATA, comp,
					      (uint8_t *)(uintptr_t)scratch, raw);
		if (n < 0 || (uint64_t)n != raw)
			return "cannot unpack the payload";
		con_hex2("UNPACK", "n=", (uint32_t)n, "at=", (uint32_t)(scratch >> 32));
		rd_start = scratch;
		rd_end = scratch + raw;
	} else if (!fdt_chosen_u64(dtb, "linux,initrd-start", &rd_start) ||
	    !fdt_chosen_u64(dtb, "linux,initrd-end", &rd_end))
		return "no initrd in /chosen";
	con_hex2("INITRD", "lo=", rd_start, "hi=", rd_end);

	const struct payload *p = (const struct payload *)rd_start;
	if (!magic_ok(p->magic)) {
		/* Not there: show what is, and go looking for the payload. */
		con_bytes("RD", (const void *)rd_start, 32);
		uintptr_t found = loader_scan_payload();
		if (!found)
			return "no payload (" PAYLOAD_MAGIC ")";
		con_hex("FOUND", found);
		rd_start = found;
		p = (const struct payload *)rd_start;
		if (!magic_ok(p->magic))
			return "no payload (" PAYLOAD_MAGIC ")";
		rd_end = rd_start + payload_size(p);
	}
	if (p->version != 1 || (p->adt_off & 7) || (rd_start & 7))
		return "bad payload header";

	uint64_t phys_base = p->phys_base, mem_size = p->mem_size;

	/* The window the bootloader reported wins over the payload header. */
	if (win_size)
		phys_base = win_base, mem_size = win_size;

	uint64_t pa_of_va_base = phys_base - p->virt_base;	/* pa = va + this */
	con_hex2("PHYS", "base=", phys_base, "size=", mem_size);
	con_hex("VIRT", p->virt_base);
	con_hex("ENTRY", p->entry_va);
	/*
	 * The payload must not overlap where the kernel goes. Compare with
	 * the kernel image, not with the whole window: the window is the
	 * 885MB region the device tree describes, and the unpacked payload
	 * lives in it, past the kernel image.
	 */
	uint64_t kern_pa = p->kernel_end + pa_of_va_base;
	if (rd_end > kern_pa && rd_start < kern_pa + 0x100000)
		return "ramdisk overlaps kernel memory";

	for (uint32_t i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = &p->segs[i];
		uintptr_t dst = s->vmaddr + pa_of_va_base;
		copy64(dst, rd_start + s->file_off, s->file_size);
		if (s->vmsize > s->file_size)
			zero64(dst + ((s->file_size + 7) & ~7UL), s->vmsize - ((s->file_size + 7) & ~7UL));
	}
	con_hex2("SEGS", "n=", p->nsegs, "end=", p->kernel_end + pa_of_va_base);
	/* What is at the entry point now: proof that the copy worked. */
	con_bytes("KERN", (const void *)(p->entry_va + pa_of_va_base), 16);

	/* ADT, then boot_args, behind the kernel; everything below topOfKernelData is ours. */
	uintptr_t adt_pa = p->kernel_end + pa_of_va_base;
	copy64(adt_pa, rd_start + p->adt_off, p->adt_size);
	uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uintptr_t top = ba_pa + PAGE_16K;

	zero64(ba_pa, PAGE_16K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = phys_base;
	ba->memSize = mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = FB_BASE;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = FB_STRIDE;
	ba->Video.v_width = FB_W;
	ba->Video.v_height = FB_H;
	ba->Video.v_depth = 32;
	ba->deviceTreeP = adt_pa - pa_of_va_base;	/* xnu reads it with the MMU on: a VA */
	ba->deviceTreeLength = (uint32_t)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = mem_size;
	con_hex2("BOOTARG", "pa=", ba_pa, "top=", top);

	uintptr_t entry_pa = p->entry_va + pa_of_va_base;
	con_hex("JUMP", entry_pa);

	/*
	 * A verdict in words: the console is read from a photograph, so the
	 * numbers are hard to make out but short words are not.
	 */
	{
		int fb_ok = FB_BASE >= phys_base && FB_BASE < phys_base + mem_size;
		int jmp_ok = entry_pa >= phys_base && entry_pa < phys_base + mem_size;
		const uint32_t *k = (const uint32_t *)entry_pa;
		int kern_ok = (k[0] | k[1] | k[2] | k[3]) != 0;

		/* Which window: the low bank (the one with the splash) or above 4G. */
		con_str("VERDICT", phys_base == 0x80000000UL ? "window-low-bank" :
			(phys_base == 0x800000000UL ? "window-above-4g" : "window-other"));
		con_str("VERDICT", fb_ok ? "fb-inside" : "FB-OUTSIDE");
		con_str("VERDICT", jmp_ok ? "jump-inside" : "JUMP-OUTSIDE");
		con_str("VERDICT", kern_ok ? "kernel-copied" : "KERN-EMPTY");
	}
	con_str("XNU", "jumping (fbcon clears screen)");

	/* Everything was written with the MMU and caches off; drop any stale I-cache lines too. */
	__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((xnu_entry_t)entry_pa)(ba_pa);
	return "xnu returned";
}
