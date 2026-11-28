/*
 * sweet boot shim entry: arm64 Linux Image header so Qualcomm ABL treats
 * us like a kernel. ABL enters at EL1, MMU/D-cache off, x0 = DTB pointer.
 */
	.section .text.head, "ax"
	.globl _head
_head:
	b	_start			/* code0 */
	.long	0			/* code1 */
	.quad	0			/* text_offset */
	.quad	_end			/* image_size (linked at 0) */
	.quad	0xa			/* flags: LE, 4K pages, place anywhere */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (PE offset) */

	.text
	.globl _start
_start:
	msr	daifset, #0xf
	mov	x19, x0			/* DTB pointer from ABL */
	msr	spsel, #1
	adr	x1, _stack_top
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	/* zero .bss */
	adr	x1, _bss_start
	adr	x2, _bss_end
1:	cmp	x1, x2
	b.hs	2f
	str	xzr, [x1], #8
	b	1b
2:	/*
	 * The runtime base of this image. ABL loads it wherever it wants (it
	 * puts it at 0xA8000000), and the image is linked at 0, so anything
	 * that hands an address to a device (DMA) has to add this.
	 */
	adrp	x0, _head
	add	x0, x0, #:lo12:_head
	adrp	x1, shim_base
	add	x1, x1, #:lo12:shim_base
	str	x0, [x1]
	mov	x0, x19
	bl	shim_main
3:	wfe
	b	3b

/* PSCI CPU_ON target. x0 = context id = cpu index (1..7). */
	.globl secondary_entry
secondary_entry:
	msr	daifset, #0xf
	msr	spsel, #1
	adr	x1, _sec_stacks
	add	x1, x1, x0, lsl #12
	add	x1, x1, #0x1000
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	bl	secondary_main
4:	wfe
	b	4b

/*
 * The kernel on the boot core the board names (BOARD_BOOT_CORE, the X2),
 * started by PSCI CPU_ON from the core the firmware runs on. x0 = the
 * handoff block (shim/loader.c): the state the firmware left on this core
 * before it ever jumped to the shim, read from the running core. With the
 * MMU off, every reference below is the same physical address.
 *
 * A core that PSCI has just switched on has none of it: CPACR_EL1 is 0, so
 * the first NEON instruction in the kernel would trap; VBAR_EL1 is 0, so an
 * early fault would be lost; and the identity table the kernel starts on is
 * only reachable through TTBR0/TCR/MAIR/SCTLR.
 *
 * The firmware hands a CPU_ON core to EL2, not EL1 (the port's secondary
 * entry, mondrian_secondary_entry, drops it the same way). At EL2 the writes
 * below would configure EL1 and nothing else: SCTLR_EL1.M does not turn the
 * MMU on, SPSel selects SP_EL2, and the kernel would then run untranslated
 * at EL2, where every kernel VA is unmapped (panic with cpsr 0x...9, EL2h).
 * So the first thing here is the EL2 -> EL1 transition, never the reverse.
 */
	.balign	64
	.globl	kernel_handoff_entry
kernel_handoff_entry:
	msr	daifset, #0xf
	mrs	x9, currentel
	cmp	x9, #0x8			/* EL2? */
	b.ne	kernel_handoff_el1
	adr	x1, _sec_stacks
	add	x1, x1, #0x8000
	mov	sp, x1				/* SP_EL2, for the eret path */
	adr	x1, vectors
	msr	vbar_el2, x1
	mov	x1, #(1 << 31)			/* HCR_EL2: AArch64 EL1, no stage 2 */
	msr	hcr_el2, x1
	msr	vttbr_el2, xzr
	msr	cptr_el2, xzr
	msr	mdcr_el2, xzr
	mov	x1, #3				/* CNTHCTL_EL2: EL1 timer access */
	msr	cnthctl_el2, x1
	msr	cntvoff_el2, xzr
	mrs	x1, icc_sre_el2
	orr	x1, x1, #1			/* ICC_SRE_EL2: system register access */
	orr	x1, x1, #8
	msr	icc_sre_el2, x1
	movz	x1, #0x0800			/* SCTLR_EL1: MMU and caches off */
	movk	x1, #0x30d0, lsl #16
	msr	sctlr_el1, x1
	isb
	adr	x1, kernel_handoff_el1
	msr	elr_el2, x1
	mov	x1, #0x3c5			/* EL1h, DAIF masked */
	msr	spsr_el2, x1
	eret

kernel_handoff_el1:
	msr	daifset, #0xf
	msr	spsel, #1
	adr	x1, _sec_stacks
	add	x1, x1, #0x8000
	mov	sp, x1
	ldr	x1, [x0, #8]		/* vbar_el1: the shim's vectors */
	msr	vbar_el1, x1
	ldr	x1, [x0, #16]		/* cpacr_el1: FP/SIMD allowed */
	msr	cpacr_el1, x1
	ldr	x1, [x0, #24]		/* mair_el1 */
	msr	mair_el1, x1
	ldr	x1, [x0, #32]		/* tcr_el1 */
	msr	tcr_el1, x1
	ldr	x1, [x0, #40]		/* ttbr0_el1: the shim's table */
	msr	ttbr0_el1, x1
	dsb	sy
	tlbi	vmalle1
	dsb	nsh
	isb
	ldr	x1, [x0, #48]		/* sctlr_el1: MMU and caches on */
	msr	sctlr_el1, x1
	isb
	mov	x1, #1
	str	x1, [x0, #0]		/* stage: about to enter the kernel */
	dsb	sy
	ldr	x2, [x0, #56]		/* the kernel's entry point */
	ldr	x0, [x0, #64]		/* its boot_args, in x0 as core 0 had */
	br	x2

/*
 * Exception vectors. Each slot stashes x29/x30, loads its slot number
 * and jumps to the common path, which saves x0-x28 and calls
 * exc_handler(slot, regs). IRQs return; everything else ends in the
 * on-screen panic.
 */
.macro vent slot
	.balign	0x80
	stp	x29, x30, [sp, #-16]!
	mov	x29, #\slot
	b	exc_common
.endm

	.balign	0x800
	.globl vectors
vectors:
	vent 0
	vent 1
	vent 2
	vent 3
	vent 4
	vent 5
	vent 6
	vent 7
	vent 8
	vent 9
	vent 10
	vent 11
	vent 12
	vent 13
	vent 14
	vent 15

exc_common:
	/*
	 * The frame holds x0-x28 and, at the end, the x29/x30 that the
	 * vector stashed below the original stack pointer.
	 */
	sub	sp, sp, #(34 * 8)
	stp	x0, x1, [sp, #0]
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	str	x28, [sp, #224]
	ldp	x2, x3, [sp, #272]		/* the stashed x29/x30 */
	stp	x2, x3, [sp, #232]		/* the frame's slots 29 and 30 */
	mov	x0, x29
	mov	x1, sp
	bl	exc_handler
	ldp	x0, x1, [sp, #0]
	ldp	x2, x3, [sp, #16]
	ldp	x4, x5, [sp, #32]
	ldp	x6, x7, [sp, #48]
	ldp	x8, x9, [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldr	x28, [sp, #224]
	add	sp, sp, #(34 * 8)
	ldp	x29, x30, [sp], #16
	eret
