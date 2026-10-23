/*
 * SPMI master-side observer reads for the boot menu keys.
 *
 * The live tree decides every number: the arbiter node by compatible
 * "qcom,spmi-pmic-arb" with its five regions bound by reg-names (cnfg,
 * core, chnls, obsrvr, intr); the power-on block through the /__symbols__
 * entry containing "pon_hlos@"; the volume key through
 * /soc/gpio_keys/vol_up's "gpios" = <phandle index flag>, with the
 * phandle resolved to the PMIC's pinctrl node.
 *
 * One structural fact does not come from the tree: a QC PMIC gpio is its
 * own SPMI peripheral, the block starting at the pinctrl node's reg
 * address and the pins following at +0x100 each, so the eight pages
 * after the base are scanned and the first ones that exist are used. The
 * peripheral status register sits at +0x10 (real-time status), which is
 * where the timer's proven keys patch (sweet) reads KPDPWR/RESIN.
 *
 * The protocol is EXT_READL, one byte: command (1<<27)|(addr<<4) written
 * to the observer slot, status at +0x08 (bit 0 done, bits 1..3 error),
 * data at +0x18. Every loop is bounded; nothing here writes the PMIC
 * configuration, and a version that is not the v5 one is recorded and
 * tried anyway -- the reads are read-only and bounded, so the worst case
 * is "no keys", never a dead shim.
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "spmi.h"

typedef volatile uint32_t *sp_reg;

#define OBS_PER_APID	0x80u
#define NO_APID		0xffffu

static sp_reg sp_core, sp_cnfg, sp_obs;
static uint16_t ap_pon = NO_APID, ap_gpio = NO_APID;
static uint16_t ap_gpio_pages[8];
static uint32_t sp_version;
static unsigned char pon_prev = 0xff, gpio_prev[8];
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
		uint32_t map = sp_rd(sp_core, 0x900u + 4u * i);

		if (map == 0 || ((map >> 8) & 0xfffu) != ppid)
			continue;
		uint32_t owner = sp_rd(sp_cnfg, 0x700u + 4u * i) & 7u;
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
	uintptr_t q = (uintptr_t)sp_obs + (uintptr_t)apid * OBS_PER_APID;
	uint32_t cmd = (1u << 27) | ((off & 0xffu) << 4);

	*(volatile uint32_t *)q = cmd;
	__asm__ volatile("dsb osh" ::: "memory");
	for (unsigned i = 0; i < 1000; ++i) {
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

/*
 * "/soc/qcom,spmi@c42d000/qcom,pm8350@1/pinctrl@8800" ->
 *   ppid (1 << 8) | 0x88:  the pmic node is the parent segment, its '@'
 *   carries the sid; the peripheral id is the high byte of the node's own
 *   reg (0x8800 -> 0x88).
 */
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

void
spmi_init(uintptr_t fdt)
{
	char path[128], buf[64];
	uintptr_t data;
	uint32_t len, acc = 0;
	uint64_t regs[10];
	char names[5][8];
	uint32_t count;
	int o = 0, named = 0, found = 0;
	const char *s;
	char tmp[8];
	uint16_t gpio_ppid;

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
	count = sp_rd(sp_core, 4) & 0x7ffu;
	/* A count the map cannot hold means this is not the arbiter the
	 * protocol knows; the version itself is only recorded. */
	if (count == 0 || count > 512) {
		sp_why = 5;
		return;
	}
	/* the PON: the tree's power-on block */
	if (!fdt_symbols_for(fdt, "pon_hlos@", path, sizeof(path))) {
		sp_why = 6;
		return;
	}
	ap_pon = sp_ppid_of(fdt, path);
	if (ap_pon == NO_APID) {
		sp_why = 7;
		return;
	}
	ap_pon = sp_find_apid(ap_pon, count);
	if (ap_pon == NO_APID) {
		sp_why = 8;
		return;
	}
	/* the gpio block: what /soc/gpio_keys/vol_up points at */
	if (!fdt_node_prop(fdt, "/soc/gpio_keys/vol_up", "gpios", &data,
	    &len) || len < 8) {
		sp_why = 9;
		return;
	}
	if (!fdt_find_phandle(fdt, be32at(data), path, sizeof(path))) {
		sp_why = 12;
		return;
	}
	gpio_ppid = sp_ppid_of(fdt, path);
	if (gpio_ppid == NO_APID) {
		sp_why = 10;
		return;
	}
	/* a gpio is its own peripheral page: scan the block's eight pages */
	for (int i = 0; i < 8; i++) {
		ap_gpio_pages[i] = sp_find_apid(
		    (uint16_t)((gpio_ppid & 0xff00u) + (gpio_ppid & 0xffu) + i),
		    count);
		if (ap_gpio_pages[i] != NO_APID) {
			found = 1;
			gpio_prev[i] = 0;
			if (ap_gpio == NO_APID)
				ap_gpio = ap_gpio_pages[i];
		}
	}
	if (!found) {
		sp_why = 11;
		return;
	}
	sp_ok = 1;
	(void)sp_read(ap_pon, 0x10u, &pon_prev);
	for (int i = 0; i < 8; i++)
		if (ap_gpio_pages[i] != NO_APID)
			(void)sp_read(ap_gpio_pages[i], 0x10u, &gpio_prev[i]);
	o = 0;
	hexd(buf + o, pon_prev);
	o += 2;
	buf[o++] = ' ';
	hexd(buf + o, gpio_prev[0]);
	o += 2;
	buf[o++] = ' ';
	buf[o++] = ' ';
	hexd(buf + o, (unsigned char)(gpio_ppid >> 8));
	o += 2;
	buf[o] = 0;
	con_str("SPMI ok", buf);
}

int
spmi_ready(void)
{
	return sp_ok && ap_pon != NO_APID;
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

int
spmi_poll(unsigned char *pon, unsigned char *gpio, int *page)
{
	unsigned char v = pon_prev;
	int rc = 0;

	if (!spmi_ready())
		return 0;
	/* a rising bit is a press; a falling one is a release and is only
	 * recorded, so one press cannot cycle twice */
	if (sp_read(ap_pon, 0x10u, &v)) {
		if (v & ~pon_prev) {
			rc |= SPMI_PON_ANY;
			*gpio = v & ~pon_prev;	/* the bits that rose */
		}
		pon_prev = v;
	}
	for (int i = 0; i < 8; i++) {
		unsigned char g = gpio_prev[i];

		if (ap_gpio_pages[i] == NO_APID)
			continue;
		if (sp_read(ap_gpio_pages[i], 0x10u, &g)) {
			if (g & ~gpio_prev[i]) {
				rc |= SPMI_GPIO_ANY;
				*gpio = g;
				*page = i;
			}
			gpio_prev[i] = g;
		}
	}
	*pon = pon_prev;
	return rc;
}
