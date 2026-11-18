/*
 * PAC gate: can this SoC run an arm64e (iOS 27) kernel?
 *
 * The arm64e route needs all of:
 *   1. FEAT_PAuth in ID_AA64ISAR1_EL1 (APA/API, GPA/GPI) or ISAR2 (APA3/GPA3);
 *   2. the five key registers writable at EL1 (a hypervisor that sets
 *      HCR_EL2.APK/API traps them and this write reboots the phone);
 *   3. PACIA/AUTIA actually changing a pointer at EL1 once SCTLR_EL1 EnIA is
 *      set (on a core without PAuth they are NOP-space no-ops).
 *
 * Every step is printed *before* it is taken: if the phone resets, the last
 * line on the panel names the step that killed it.  The probe halts on
 * purpose; this image is a measurement, not a boot.
 *
 * Build: PAC_PROBE=1 BOARD=mondrian shim/build.sh
 */
#include <stdint.h>
#include "console.h"
#include "pac.h"

#define RSR(n) ({ uint64_t _v; __asm__ volatile("mrs %0, " n : "=r"(_v)); _v; })
#define WSR(n, v) __asm__ volatile("msr " n ", %0" :: "r"((uint64_t)(v)))

/* ID_AA64ISAR1_EL1 / ISAR2 are S3_0_C0_C6_1 and S3_0_C0_C6_2. */
#define ISAR1	RSR("S3_0_C0_C6_1")
#define ISAR2	RSR("S3_0_C0_C6_2")

/* Key registers: CRm 1/2/3 for A/B/D/A-G, op2 1..4 lo/hi. */
#define KEY_REGS \
	X(APIA, S3_0_C2_C1_1, S3_0_C2_C1_2) \
	X(APIB, S3_0_C2_C1_3, S3_0_C2_C1_4) \
	X(APDA, S3_0_C2_C2_1, S3_0_C2_C2_2) \
	X(APDB, S3_0_C2_C2_3, S3_0_C2_C2_4) \
	X(APGA, S3_0_C2_C3_1, S3_0_C2_C3_2)

#define X(name, lo, hi) \
	static uint64_t name##_lo(void) { return RSR(#lo); } \
	static uint64_t name##_hi(void) { return RSR(#hi); } \
	static void name##_set(uint64_t l, uint64_t h) { WSR(#lo, l); WSR(#hi, h); }
KEY_REGS
#undef X

/* The modifier is a plain register: gas rejects xzr in that slot. */
static uint64_t pacia(uint64_t p)
{
	uint64_t out, mod = 0;
	__asm__ volatile(
		".arch_extension pauth\n\t"
		"mov x9, %1\n\t"
		"mov x10, %2\n\t"
		"pacia x9, x10\n\t"
		"mov %0, x9"
		: "=&r"(out) : "r"(p), "r"(mod) : "x9", "x10", "memory");
	return out;
}

static uint64_t autia(uint64_t p)
{
	uint64_t out, mod = 0;
	__asm__ volatile(
		".arch_extension pauth\n\t"
		"mov x9, %1\n\t"
		"mov x10, %2\n\t"
		"autia x9, x10\n\t"
		"mov %0, x9"
		: "=&r"(out) : "r"(p), "r"(mod) : "x9", "x10", "memory");
	return out;
}

static int keys_ok(void)
{
	return APIA_lo() == 0x1111111111111111UL && APIA_hi() == 0x2222222222222222UL &&
	       APIB_lo() == 0x3333333333333333UL && APIB_hi() == 0x4444444444444444UL &&
	       APDA_lo() == 0x5555555555555555UL && APDA_hi() == 0x6666666666666666UL &&
	       APDB_lo() == 0x7777777777777777UL && APDB_hi() == 0x8888888888888888UL &&
	       APGA_lo() == 0x9999999999999999UL && APGA_hi() == 0xaaaaaaaaaaaaaaaaUL;
}

void pac_probe(void)
{
	uint64_t isar1 = ISAR1, isar2 = ISAR2;
	uint64_t pfr0 = RSR("id_aa64pfr0_el1");
	uint64_t mmfr0 = RSR("id_aa64mmfr0_el1");
	uint64_t el = RSR("CurrentEL") >> 2;
	uint32_t apa = (isar1 >> 4) & 0xf, api = (isar1 >> 8) & 0xf;
	uint32_t gpa = (isar1 >> 12) & 0xf, gpi = (isar1 >> 16) & 0xf;
	uint32_t apa3 = (isar2 >> 4) & 0xf, gpa3 = (isar2 >> 8) & 0xf;
	uint64_t in = 0x0000000012345678UL, signed_p, restored;
	uint64_t sctlr;

	con_line("PAC: probe (arm64e gate)");
	con_hex2("PAC", "el=", (uint32_t)el, "pfr0=", (uint32_t)pfr0);
	con_hex64("ISAR1", isar1);
	con_hex64("ISAR2", isar2);
	con_hex2("FEAT", "APA", apa, "API", api);
	con_hex2("FEAT", "GPA", gpa, "GPI", gpi);
	con_hex2("FEAT", "APA3", apa3, "GPA3", gpa3);
	con_hex2("MMFR0", "tg4=", (uint32_t)(mmfr0 & 0xf), "tg16=", (uint32_t)((mmfr0 >> 20) & 0xf));

	if (!((apa && api && gpa && gpi) || (apa3 && gpa3))) {
		con_line("PAC: RESULT no FEAT_PAuth -> arm64 only (max iOS 18)");
		goto halt;
	}
	con_line("PAC: FEAT_PAuth present");

	con_line("PAC: writing the five key pairs at EL1 ...");
	APIA_set(0x1111111111111111UL, 0x2222222222222222UL);
	APIB_set(0x3333333333333333UL, 0x4444444444444444UL);
	APDA_set(0x5555555555555555UL, 0x6666666666666666UL);
	APDB_set(0x7777777777777777UL, 0x8888888888888888UL);
	APGA_set(0x9999999999999999UL, 0xaaaaaaaaaaaaaaaaUL);
	__asm__ volatile("isb");
	con_str("KEY RB", keys_ok() ? "ok (read back what was written)" : "MISMATCH");

	sctlr = RSR("sctlr_el1");
	con_hex64("SCTLR before", sctlr);
	sctlr |= (1UL << 31) | (1UL << 30) | (1UL << 29) | (1UL << 28);
	WSR("sctlr_el1", sctlr);
	__asm__ volatile("isb");
	con_hex64("SCTLR after", RSR("sctlr_el1"));

	con_line("PAC: executing PACIA ...");
	signed_p = pacia(in);
	con_hex64("PAC in", in);
	con_hex64("PAC out", signed_p);
	if (signed_p == in) {
		con_line("PAC: RESULT PACIA is a NOP -> no usable PAC at EL1");
		goto halt;
	}
	restored = autia(signed_p);
	con_hex64("AUT out", restored);
	if (restored != in) {
		con_line("PAC: RESULT AUTIA did not restore -> PAC unusable");
		goto halt;
	}
	con_line("PAC: RESULT OK arm64e-capable at EL1");
	con_line("PAC: next: the same check at EL0 (dyld) is F2");

halt:
	con_line("PAC: halted; power+volume-down for fastboot");
	for (;;)
		__asm__ volatile("wfi");
}
