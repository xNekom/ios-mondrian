#pragma once
/*
 * Board description for the shim.
 *
 * These are the only numbers the bare-metal part needs; the same values live
 * in tools/boards.py, which feeds the Apple Device Tree builder. Keep both in
 * sync (tools/boards.py is the reference).
 *
 * Build with BOARD=sweet (default) or BOARD=mondrian (shim/build.sh).
 */

#if defined(BOARD_MONDRIAN)

/* POCO F5 Pro / Redmi K60 ("mondrian", Qualcomm SM8475 / Snapdragon 8+ Gen 1).
 * Sources: MiCode/kernel_devicetree @ mondrian-s-oss (qcom/cape.dtsi,
 * qcom/waipio-qupv3.dtsi) and the mainline qcom/sm8450.dtsi. */
#define BOARD_NAME		"mondrian"
#define BOARD_SOC		"SM8475"

/* GICD/GICR: cape.dtsi and the mainline sm8450.dtsi agree.
 * 8 redistributors, stride 0x40000. */
#define GICD_BASE		0x17100000UL
#define GICR_BASE		0x17180000UL
#define GICR_SIZE		0x200000UL
#define GICR_PE_SIZE		0x40000UL

/* Qualcomm's arm,armv8-timer lists PPI 11 for the virtual timer, so the GIC
 * INTID is 16 + 11 = 27 (sweet's older SoC uses PPI 3 = 19). */
#define VTIMER_INTID		27
#define PTIMER_INTID		18
#define SGI_INTID		1

/* The window of RAM the kernel gets. It holds the splash framebuffer
 * (0xb8000000) and starts above the firmware's own memory at the bottom of
 * the bank (the hypervisor is at 0x80000000; the kernel image written over
 * it resets the phone).
 *
 * It ends at 0xe0000000, the first firmware carve-out (qheebsp_reserved_region).
 * The live device tree says the RAM runs are 0x80000000+0x6a000000 and
 * 0xf4600000+0xba00000 and marks the islands below 0xea000000 no-map, so a
 * window that reaches past 0xe0000000 hands the VM pages that the AP cannot
 * touch: the first access is a synchronous external abort, minutes into the
 * boot. The device tree confirms the window is inside a memory region; the
 * shim prints both so a mismatch is visible on the screen.
 *
 * The wipe below only touches what the device tree says is memory. */
#define BOARD_MEM_BASE		0xb0000000UL
#define BOARD_MEM_SIZE		0x30000000UL

/* Internal UFS host (ufshc@1d84000). Same window as sweet, but this is a
 * UFS 3.1 controller, not the UFSHCI 2.1 sweet drives. */
#define UFS_BASE		0x01d84000UL

/* The splash the ABL leaves for the DSI panel: cont_splash_region at
 * 0xB8000000, 0x2b00000 (43 MiB). Source: the SM8450 display dtsi
 * (cape-sde-display.dtsi, splash_region). The shim prefers the value of the
 * live device tree; this is the documented fallback. */
#define FB_BASE			0xb8000000UL
#define FB_SIZE			0x2b00000UL
#define FB_W			1440
#define FB_H			3200
#define FB_STRIDE		(FB_W * 4)

#define PAYLOAD_MAGIC		"MONDRIAN"

#define NR_CPUS			8

/* The framebuffer of the board is a documented value of the platform, but
 * the device tree is always preferred when it names it. */
#define BOARD_FB_FROM_DTB	0

/*
 * The window has to be wiped before the kernel starts.
 *
 * The real bootloader hands the kernel memory it has scrubbed, and the
 * kernel counts on it: the sweet's window is DRAM that Android never
 * touched, so it is already zero. This phone's window is Android's live
 * memory, full of leftovers, and the kernel read a stale pointer out of it
 * and jumped to it ("Undefined kernel instruction", pc inside its own heap).
 *
 * The firmware's own regions are skipped: they are not holes, but they
 * belong to the secure world (the tags, the QTEe, the trusted UI) and
 * scribbling on them makes the phone reset. The framebuffer is skipped
 * too, so the console stays on the screen.
 */
#define BOARD_WIPE		1
#define BOARD_RESERVED_N	9
static const uint64_t board_reserved[BOARD_RESERVED_N][2] = {
	{ 0xe0000000UL, 0x00600000UL },	/* qheebsp_reserved_region */
	{ 0xe0600000UL, 0x00400000UL },	/* cpusys_vm_region */
	{ 0xe0a00000UL, 0x00100000UL },	/* hyp_reserved_region */
	{ 0xe55f3000UL, 0x00009000UL },	/* trust_ui_vm_qrtr */
	{ 0xe55fc000UL, 0x00004000UL },	/* trust_ui_vm_vblk0_ring */
	{ 0xe5600000UL, 0x00100000UL },	/* trust_ui_vm_swiotlb */
	{ 0xe8800000UL, 0x00100000UL },	/* tz_stat_region */
	{ 0xe8900000UL, 0x01200000UL },	/* tags_region */
	{ 0xe9b00000UL, 0x00500000UL },	/* qtee_region */
};

#else	/* BOARD_SWEET (default) */

/* Redmi Note 10 Pro ("sweet", Qualcomm SM7150 / Snapdragon 732G).
 * Every value was measured on the device; see NOTES.md. */
#define BOARD_NAME		"sweet"
#define BOARD_SOC		"SM7150"

#define GICD_BASE		0x17a00000UL
#define GICR_BASE		0x17a60000UL
#define GICR_SIZE		0x100000UL
#define GICR_PE_SIZE		0x20000UL

#define VTIMER_INTID		19
#define PTIMER_INTID		18
#define SGI_INTID		1

/* The window of RAM the kernel gets, if the device tree does not say.
 * On sweet the device tree always says, so there is no fallback. */
#define BOARD_MEM_BASE		0
#define BOARD_MEM_SIZE		0

/* Internal UFS host (ufshc@1d84000, sweet live FDT). */
#define UFS_BASE		0x01d84000UL

/* reserved-memory cont_splash_region */
#define FB_BASE			0x9c000000UL
#define FB_SIZE			0x1700000UL
#define FB_W			1080
#define FB_H			2400
#define FB_STRIDE		(FB_W * 4)

#define PAYLOAD_MAGIC		"SWEETXNU"

#define NR_CPUS			8

/* The framebuffer of sweet was measured on the device (the ABL leaves it
 * at the cont_splash_region), so the constant may be used if the device
 * tree does not name it. */
#define BOARD_FB_FROM_DTB	0

/* Sweet's window is DRAM that Android never used, so it is already zero
 * and there is nothing to wipe (and 4 GB of wiping would take a while). */
#define BOARD_WIPE		0
#define BOARD_RESERVED_N	0
#if BOARD_RESERVED_N
static const uint64_t board_reserved[BOARD_RESERVED_N][2] = { { 0, 0 } };
#else
static const uint64_t board_reserved[1][2] = { { 0, 0 } };
#endif

#endif	/* BOARD_MONDRIAN */

/*
 * The page size the kernel of this board uses. The shim's MMU has to use
 * the same granule, because the kernel starts on the tables it builds.
 * Both boards run 16 KiB: SM8475 reports TGran16=1 in ID_AA64MMFR0_EL1
 * (measured 2026-10-23) and the iOS userland, its dyld cache and the code
 * signatures are built for 16 KiB pages.
 */
#define BOARD_PG_SHIFT		14

/* The runtime base of the shim image (see start.S). */
extern uint64_t shim_base;
