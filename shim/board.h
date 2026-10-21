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

/* Qualcomm numbers the architected timer PPIs 1/2/3/0, so the virtual timer
 * XNU uses is INTID 16 + 3 = 19 (same as on sweet). */
#define VTIMER_INTID		19
#define PTIMER_INTID		18
#define SGI_INTID		1

/* The window of RAM the kernel gets, if the device tree does not say.
 * It has to be a region that holds the splash framebuffer: the early
 * console writes to it through the bootstrap V=P map. */
#define BOARD_MEM_BASE		0x80000000UL
#define BOARD_MEM_SIZE		0x6a000000UL

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

#endif	/* BOARD_MONDRIAN */

/*
 * The page size the kernel of this board uses. The shim's MMU has to use
 * the same granule: sweet runs the kernel with 16 KiB pages, mondrian with
 * 4 KiB ones (PAGE_SIZE=4096 in build.config.msm.mondrian).
 */
#if defined(BOARD_MONDRIAN)
#define BOARD_PG_SHIFT		12
#else
#define BOARD_PG_SHIFT		14
#endif

/* The runtime base of the shim image (see start.S). */
extern uint64_t shim_base;
