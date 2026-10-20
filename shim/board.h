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

/* Internal UFS host (ufshc@1d84000). Same window as sweet, but this is a
 * UFS 3.1 controller, not the UFSHCI 2.1 sweet drives. */
#define UFS_BASE		0x01d84000UL

/* TODO(mondrian): the ABL leaves no simple framebuffer behind on a DSI
 * panel. sweet's LCD kept one at 0x9c000000 (cont_splash_region); on SM8475
 * the display subsystem is MDSS (0x0ae00000) with the DPU at 0x0ae01000 and
 * the panel is driven over DSI D-PHY. The address and the geometry have to be
 * read from the device (see the "dtb dump" in the shim). */
#define FB_BASE			0x9c000000UL
#define FB_SIZE			0x1700000UL
#define FB_W			1440
#define FB_H			3200
#define FB_STRIDE		(FB_W * 4)

#define PAYLOAD_MAGIC		"MONDXNU"

#define NR_CPUS			8

/* The framebuffer address of this board is not measured yet: the shim must
 * take it from the device tree and must not fall back to the constant. */
#define BOARD_FB_FROM_DTB	1

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
