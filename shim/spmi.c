/*
 * SPMI master-side observer reads for the boot menu keys, with the shield
 * of the numbers the live tree gives and the key map the HackiOS reference
 * driver documents for the same PMIC family (bsd/dev/redwood_buttons.c):
 *
 *   power        KPDPWR_N of the PON block (bit 7 of its real-time status)
 *   volume down  RESIN_N of the same block (bit 6)
 *   volume up    GPIO6 of the PMIC (level bit 0 of its page, pulled up:
 *                the key pulls it LOW)
 *
 * The tree decides the addresses: the arbiter by compatible
 * "qcom,spmi-pmic-arb" (five regions by reg-names); the PON by the first
 * node whose compatible contains "pon"; the gpio block by resolving
 * /soc/gpio_keys/vol_up's phandle. A PMIC gpio is its own peripheral page
 * at the block's reg address + 0x100 per pin, so gpio 6 is reg + 5 * 0x100;
 * the status of a peripheral is its register 0x10.
 *
 * The transfer protocol is the arbiter's version 5: EXT_READL, one byte,
 * command (1<<27) | (reg<<4), status at +0x08 (bit 0 done, bits 1..3
 * error), data at +0x18, observer window base + 0x80 per channel. Every
 * loop is bounded; nothing writes the PMIC configuration.
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "spmi.h"

typedef volatile uint32_t *sp_reg;

#define OBS_PER_APID	0x80u
#define NO_APID		0xffffu
#define REG_RT_STATUS	0x10u	/* the inputs as they are now */
#define PON_KPDPWR	0x80u
#define PON_RESIN	0x40u
#define GPIO_LEVEL	0x01u	/* 0 while the key is held */

static sp_reg sp_core, sp_cnfg, sp_obs;
/* v5 and v7 place the three tables differently (Linux spmi-pmic-arb.c):
 *            observer stride  APID map in core  owner in cnfg
 *   v5       0x80 per apid    0x900 + 4n        0x700 + 4n
 *   v7       0x20 per apid    0x2000 + 4n       4n  (per-bus numbering) */
static uint32_t sp_obs_stride = 0x20, sp_map_off = 0x2000, sp_owner_off = 0;
static uint16_t ap_pon = NO_APID, ap_gpio = NO_APID;
static uint32_t sp_version;
static unsigned char pon_prev = 0xff, gpio_prev = 0xff;
static int sp_ok, sp_why;

static uint32_t
be32at(uintptr_t p)
{
	return ((uint32_t)*(const unsigned char *)p << 24) |
	    ((uint32_t)*(const unsigned char *)(p + 1) << 16) |
	    ((uint32_t)*(const unsigned char *)(p + 2) << 8) |
	    (uint32_t)*(const unsigned char *)(p + 3);
}

static uint32_t
sp_rd(sp_reg base, uint32_t byte_off)
{
	uint32_t v = base[byte_off / 4];

	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

static int
str_len(const char *s)
{
	int n = 0;

	while (*s)
		n++, s++;
	return n;
}

static void
str_copy(char *dst, const char *src, int cap)
{
	int o = 0;

	while (src[o] && o < cap - 1)
		dst[o] = src[o], o++;
	dst[o] = 0;
}

static void
hexd(char *p, unsigned char b)
{
	static const char hex[] = "0123456789abcdef";

	p[0] = hex[b >> 4];
	p[1] = hex[b & 15];
}

static unsigned
sp_atoi(const char *s, int *ok)
{
	unsigned v = 0;

	*ok = 0;
	while (*s >= '0' && *s <= '9')
		v = v * 10 + (*s - '0'), s++, *ok = 1;
	return v;
}

/* v5 can map one peripheral more than once; prefer the apps-owned entry. */
static uint16_t
sp_find_apid(uint16_t ppid, uint32_t count)
{
	uint16_t found = NO_APID;

	for (uint32_t i = 0; i < count; ++i) {
		uint32_t map = sp_rd(sp_core, sp_map_off + 4u * i);

		if (map == 0 || ((map >> 8) & 0xfffu) != ppid)
			continue;
		uint32_t owner = sp_rd(sp_cnfg, sp_owner_off + 4u * i) & 7u;
		if (found == NO_APID || owner == 0)
			found = (uint16_t)i;
	}
	return found;
}

static int
sp_read(uint16_t apid, uint16_t off, unsigned char *out)
{
	if (apid == NO_APID || !sp_ok)
		return 0;
	uintptr_t q = (uintptr_t)sp_obs + (uintptr_t)apid * sp_obs_stride;
	uint32_t cmd = (1u << 27) | ((off & 0xffu) << 4);

	*(volatile uint32_t *)q = cmd;
	__asm__ volatile("dsb osh" ::: "memory");
	for (unsigned i = 0; i < 2000; ++i) {
		uint32_t st = sp_rd((sp_reg)q, 0x08u);

		if (st & 1u) {
			if (st & 0x0eu)
				return 0;
			*out = (unsigned char)sp_rd((sp_reg)q, 0x18u);
			return 1;
		}
	}
	return 0;
}

/* "…/qcom,pm8350@1/pinctrl@8800" -> (1 << 8) | (reg >> 8). */
static uint16_t
sp_ppid_of(uintptr_t fdt, const char *path)
{
	int n = str_len(path);
	int last = -1, prev = -1;
	uintptr_t rp;
	uint32_t rl;
	unsigned sid;
	int srok = 0, k;

	for (k = n - 1; k >= 0; k--)
		if (path[k] == '/') {
			last = k;
			break;
		}
	if (k < 0)
		return NO_APID;
	for (k = last - 1; k >= 0; k--)
		if (path[k] == '/') {
			prev = k;
			break;
		}
	if (k < 0)
		return NO_APID;
	for (int m = prev + 1; m < last; m++)
		if (path[m] == '@') {
			sid = sp_atoi(path + m + 1, &srok);
			break;
		}
	if (!srok)
		return NO_APID;
	if (!fdt_node_prop(fdt, path, "reg", &rp, &rl) || rl < 4)
		return NO_APID;
	uint16_t per = (uint16_t)(be32at(rp) >> 8);

	if (per == 0 || per > 0xa0)
		return NO_APID;
	return (uint16_t)(sid << 8 | per);
}

/* What kind of peripheral is there: 2 bytes at 0x04 (type, subtype). */
static int
sp_identify(uint16_t apid, unsigned char type, unsigned char sub_lo,
    unsigned char sub_hi)
{
	unsigned char t = 0, s = 0;

	if (!sp_read(apid, 0x04u, &t) || !sp_read(apid, 0x05u, &s))
		return 0;
	return t == type && s >= sub_lo && s <= sub_hi;
}

void
spmi_init(uintptr_t fdt)
{
	char path[128], buf[64];
	uintptr_t data;
	uint32_t len, acc = 0;
	uint64_t regs[10];
	char names[5][8];
	uint32_t count;
	int o = 0, named = 0;
	const char *s;
	char tmp[8];
	uint16_t gpio_ppid, ppid;
	uint32_t idx = 0;

	sp_ok = 0;
	sp_why = 0;
	if (!fdt || !fdt_find_compatible(fdt, "qcom,spmi-pmic-arb",
	    path, sizeof(path)))
		return;	/* 1: no arbiter */
	if (!fdt_node_prop(fdt, path, "reg-names", &data, &len)) {
		sp_why = 2;
		return;
	}
	while (acc < len && named < 5) {
		int o2 = 0;

		s = (const char *)(data + acc);
		while (*s && o2 < 7)
			tmp[o2++] = *s++;
		tmp[o2] = 0;
		str_copy(names[named], tmp, 8);
		named++;
		acc += str_len(tmp) + 1;
	}
	/*
	 * The node's #address-cells describe its PMIC children (a sid);
	 * its own five reg pairs are one address and one size cell each.
	 */
	if (named != 5 || fdt_node_regs_cells(fdt, path, regs, 5, 1, 1) < 5) {
		sp_why = 3;
		return;
	}
	for (int i = 0; i < 5; i++) {
		if (names[i][0] == 'o' && names[i][1] == 'b')
			sp_obs = (sp_reg)(uintptr_t)regs[i * 2];
		else if (names[i][0] == 'c' && names[i][1] == 'o')
			sp_core = (sp_reg)(uintptr_t)regs[i * 2];
		else if (names[i][0] == 'c' && names[i][1] == 'n')
			sp_cnfg = (sp_reg)(uintptr_t)regs[i * 2];
	}
	if (!sp_core || !sp_cnfg || !sp_obs) {
		sp_why = 4;
		return;
	}
	sp_version = sp_rd(sp_core, 0);
	/*
	 * The layout of the tables follows the arbiter's version: this
	 * phone reports 0x70000000 (v7: observer 0x20 per channel, the
	 * APID map at core+0x2000, the owner table at cnfg+4n). Older
	 * systems report 0x5xxxxxxx (the layout the timer's driver uses).
	 */
	if (sp_version >= 0x70000000u) {
		sp_obs_stride = 0x20;
		sp_map_off = 0x2000;
		sp_owner_off = 0;
	} else if (sp_version >= 0x50000000u) {
		sp_obs_stride = 0x80;
		sp_map_off = 0x900;
		sp_owner_off = 0x700;
	} else {
		sp_why = 5;
		return;
	}
	count = sp_rd(sp_core, 4) & 0x7ffu;
	if (count == 0 || count > 1024) {
		sp_why = 5;
		return;
	}
	/*
	 * The PON. Its node has no /__symbols__ label on this tree, so it
	 * is found by compatible ("qcom,pm8998-pon"); the symbols entry
	 * stays as a second chance.
	 */
	if (!fdt_find_compatible_part(fdt, "pon", path, sizeof(path)) &&
	    !fdt_symbols_for(fdt, "pon_hlos@", path, sizeof(path))) {
		sp_why = 6;
		return;
	}
	ppid = sp_ppid_of(fdt, path);
	if (ppid == NO_APID) {
		sp_why = 7;
		return;
	}
	ap_pon = sp_find_apid(ppid, count);
	if (ap_pon == NO_APID) {
		sp_why = 8;
		return;
	}
	/* the gpio block: what /soc/gpio_keys/vol_up points at */
	if (!fdt_node_prop(fdt, "/soc/gpio_keys/vol_up", "gpios", &data,
	    &len) || len < 12) {
		sp_why = 9;
		return;
	}
	idx = be32at(data + 4);		/* the pin inside the block (1-based) */
	if (!fdt_find_phandle(fdt, be32at(data), path, sizeof(path))) {
		sp_why = 12;
		return;
	}
	gpio_ppid = sp_ppid_of(fdt, path);
	if (gpio_ppid == NO_APID) {
		sp_why = 10;
		return;
	}
	/* a pin is its own peripheral page: the block's base + (pin - 1) */
	if (idx == 0 || idx > 8)
		idx = 1;
	ap_gpio = sp_find_apid((uint16_t)(gpio_ppid + idx - 1), count);
	if (ap_gpio == NO_APID) {
		/* the pin map of this PMIC may number them otherwise: look
		 * at the block's pages until one answers */
		for (unsigned i = 0; i < 8 && ap_gpio == NO_APID; i++)
			ap_gpio = sp_find_apid(
			    (uint16_t)(gpio_ppid + i), count);
	}
	if (ap_gpio == NO_APID) {
		sp_why = 11;
		return;
	}
	sp_ok = 1;
	/* the keys are read whatever the identify says (reads only); a
	 * mismatch is said in the log so the line explains itself */
	if (!sp_identify(ap_pon, 0x01, 0x09, 0x09))
		sp_why = 13;
	else {
		unsigned char g[2];

		if (!sp_read(ap_gpio, 0x04u, &g[0]) ||
		    !sp_read(ap_gpio, 0x05u, &g[1]) ||
		    g[0] != 0x10 || g[1] < 0x10 || g[1] > 0x13)
			sp_why = 14;
	}
	(void)sp_read(ap_pon, REG_RT_STATUS, &pon_prev);
	(void)sp_read(ap_gpio, REG_RT_STATUS, &gpio_prev);
	o = 0;
	hexd(buf + o, pon_prev);
	o += 2;
	buf[o++] = ' ';
	hexd(buf + o, gpio_prev);
	o += 2;
	buf[o] = 0;
	con_str("SPMI ok", buf);
}

int
spmi_ready(void)
{
	return sp_ok && ap_pon != NO_APID && ap_gpio != NO_APID;
}

int
spmi_why(void)
{
	return sp_why;
}

uint32_t
spmi_version(void)
{
	return sp_version;
}

/*
 * The three keys, by their edges (the map of the HackiOS reference): the
 * PON's status has KPDPWR in bit 7 and RESIN in bit 6, both set while the
 * key is held; the gpio's level bit 0 is 0 while the key is held (the pin
 * is pulled up). A press is the bit going down for the PON and the level
 * going LOW for the gpio, so each press reports once.
 */
int
spmi_poll(unsigned char *pon, unsigned char *gpio, int *page)
{
	unsigned char p = pon_prev, g = gpio_prev;
	int rc = 0;

	(void)page;
	if (!spmi_ready())
		return 0;
	if (sp_read(ap_pon, REG_RT_STATUS, &p)) {
		if ((p & PON_KPDPWR) && !(pon_prev & PON_KPDPWR))
			rc |= SPMI_KEY_POWER;
		if ((p & PON_RESIN) && !(pon_prev & PON_RESIN))
			rc |= SPMI_KEY_VOLDOWN;
		pon_prev = p;
	}
	if (sp_read(ap_gpio, REG_RT_STATUS, &g)) {
		if (!(g & GPIO_LEVEL) && (gpio_prev & GPIO_LEVEL))
			rc |= SPMI_KEY_VOLUP;
		gpio_prev = g;
	}
	*pon = pon_prev;
	*gpio = gpio_prev;
	return rc;
}
