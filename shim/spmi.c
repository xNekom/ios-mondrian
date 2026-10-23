/*
 * SPMI master-side observer reads for the boot menu keys.
 *
 * The tree of the phone (the 2026-10-23 spmi@c42d000 dump) decides
 * everything here:
 *   - the arbiter: node by compatible "qcom,spmi-pmic-arb"; its five
 *     regions bind by reg-names: cnfg, core, ... obsrvr.
 *   - the power-on block: the /__symbols__ entry containing "pon_hlos@"
 *     (qcom,pmk8350@0/pon_hlos@1300: periph 0x13, sid 0).
 *   - the volume key: /soc/gpio_keys/vol_up's "gpios" = <phandle index
 *     flag>; the phandle resolves through the tree to the gpio block
 *     (qcom,pm8350@1/pinctrl@8800: periph 0x88, sid 1) and the index is
 *     the second cell.
 *
 * The only constants left (not of the phone) are the peripheral layout
 * rules: a status register sits at +0x10 of its own SPMI peripheral, and
 * the observer command is EXT_READL = (bit27) | (addr << 4), status at
 * +0x08 (bit 0 done, bits 1..3 error), data at +0x18 (the protocol the
 * timer's keys patch already proved on sweet). Every loop is bounded.
 * Nothing in this module ever writes the PMIC configuration.
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
static int sp_why;

static uint16_t ap_gpio_pages[8];
static unsigned char pon_prev = 0xff, gpio_prev[8];
static int sp_ok;

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
 *   ppid (1 << 8) | 0x88:  the pmic node is the parent segment ("...@1");
 *   the peripheral id is the high byte of the node's own reg (0x8800).
 */
static uint16_t
sp_ppid_of(uintptr_t fdt, const char *path)
{
	int n = str_len(path);
	int last = -1, prev = -1;
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
	/* the digits right after the parent's '@' */
	for (int m = prev + 1; m < last; m++)
		if (path[m] == '@') {
			sid = sp_atoi(path + m + 1, &srok);
			break;
		}
	if (!srok)
		return NO_APID;
	uintptr_t rp;
	uint32_t rl;

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
	uint32_t count, version;
	int o = 0, named = 0;
	const char *s;
	char tmp[8];

	sp_ok = 0;
	if (!fdt || !fdt_find_compatible(fdt, "qcom,spmi-pmic-arb",
	    path, sizeof(path))) {
		con_str("SPMI", "no arbiter in the tree");
		sp_why = 1;
		return;
	}
	if (!fdt_node_prop(fdt, path, "reg-names", &data, &len)) {
		con_str("SPMI", "no reg-names");
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
		con_str("SPMI", "five regions expected");
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
		con_str("SPMI", "regions missing");
		sp_why = 4;
		return;
	}
	version = sp_rd(sp_core, 0);
	count = sp_rd(sp_core, 4) & 0x7ffu;
	if (version < 0x50000000u || version >= 0x70000000u ||
	    count == 0 || count > 512) {
		con_hex64("SPMI version-gate", version);
		sp_why = 5;
		return;
	}
	if (!fdt_symbols_for(fdt, "pon_hlos@", path, sizeof(path))) {
		con_str("SPMI", "no pon_hlos");
		sp_why = 6;
		return;
	}
	ap_pon = sp_ppid_of(fdt, path);
	if (ap_pon == NO_APID) {
		con_str("SPMI", "pon ppid refused");
		sp_why = 7;
		return;
	}
	ap_pon = sp_find_apid(ap_pon, count);
	if (ap_pon == NO_APID) {
		con_str("SPMI", "pon apid refused");
		sp_why = 8;
		return;
	}
	/* the gpio block behind /soc/gpio_keys/vol_up */
	if (!fdt_node_prop(fdt, "/soc/gpio_keys/vol_up", "gpios", &data,
	    &len) || len < 8) {
		con_str("SPMI", "no vol_up gpios");
		sp_why = 9;
		return;
	}
	if (!fdt_find_phandle(fdt, be32at(data), path, sizeof(path))) {
		con_str("SPMI", "no phandle of vol_up");
		sp_why = 12;
		return;
	}
	ap_gpio = sp_ppid_of(fdt, path);
	if (ap_gpio == NO_APID) {
		con_str("SPMI", "gpio ppid refused");
		sp_why = 10;
		return;
	}
	ap_gpio = sp_find_apid(ap_gpio, count);
	if (ap_gpio == NO_APID) {
		con_str("SPMI", "gpio apid refused");
		sp_why = 11;
		return;
	}
	/*
	 * The gpio block's page 0x88 is the first gpio; the following
	 * pages (0x89..) exist on this PMIC up to its pin count. Probe
	 * them: a pin that does not exist simply has no APID, and reads
	 * are bounded.
	 */
	for (int i = 0; i < 8; i++) {
		uint16_t ppid = (uint16_t)((ap_gpio & 0xff00u) |
		    (0x88u + (unsigned)i));

		ap_gpio_pages[i] = sp_find_apid(ppid, count);
		if (ap_gpio_pages[i] == NO_APID)
			ap_gpio_pages[i] = (i == 0) ? ap_gpio : NO_APID;
	}
	sp_ok = 1;
	/* the state the edges are taken against */
	(void)sp_read(ap_pon, 0x10u, &pon_prev);
	for (int i = 0; i < 8; i++) {
		gpio_prev[i] = 0;
		if (ap_gpio_pages[i] != NO_APID)
			(void)sp_read(ap_gpio_pages[i], 0x10u, &gpio_prev[i]);
	}
	o = 0;
	hexd(buf + o, pon_prev);
	o += 2;
	buf[o++] = ' ';
	hexd(buf + o, gpio_prev[0]);
	o += 2;
	buf[o++] = ' ';
	hexd(buf + o, (unsigned char)(ap_pon >> 8));
	o += 2;
	buf[o++] = ' ';
	hexd(buf + o, (unsigned char)(ap_gpio >> 8));
	o += 2;
	buf[o] = 0;
	con_str("SPMI", buf);
}

int
spmi_ready(void)
{
	return sp_ok && ap_pon != NO_APID && ap_gpio != NO_APID;
}

/*
 * One byte of the PON's status and one of the gpio's; the changed bytes
 * go out for the menu's key lines. Returns the edges:
 *   1 the PON byte moved (the power key lives there)
 *   2 the gpio byte moved (the volume lives there)
 */
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

int
spmi_why(void)
{
	/* The menu prints it as a number: a string table would need
	 * absolute pointers (see the if-chain note). 1 no arbiter,
	 * 2 no reg-names, 3 regions, 4 regions missing, 5 version gate,
	 * 6 no pon, 7 pon ppid, 8 pon apid, 9 no gpios, 10 gpio ppid,
	 * 11 gpio apid, 12 vol_up phandle. */
	return sp_why;
}
