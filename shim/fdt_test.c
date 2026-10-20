/*
 * Host test of the device tree parser (shim/fdt.c).
 *
 *   gcc -O1 -Wall -o out/fdt_test fdt.c fdt_test.c && ./out/fdt_test
 *
 * It builds a small flattened device tree in memory, exactly like the
 * bootloader hands to the shim, and checks that the parser finds the memory
 * banks and the peripherals the board table needs.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "fdt.h"

#define FDT_MAGIC	0xd00dfeed
#define FDT_BEGIN_NODE	1
#define FDT_END_NODE	2
#define FDT_PROP	3
#define FDT_END		9

#define STRUCT_SIZE	4096
#define STRINGS_SIZE	1024

static uint8_t blob[sizeof(uint32_t) + STRUCT_SIZE + STRINGS_SIZE];
static uint32_t struct_off, strings_off, struct_len, strings_len;
static uint32_t *strings;

static void be32(uint32_t v)
{
	uint32_t *p = (uint32_t *)(blob + struct_off + struct_len);
	*p = __builtin_bswap32(v);
	struct_len += 4;
}

static void bytes(const void *data, uint32_t len)
{
	memcpy(blob + struct_off + struct_len, data, len);
	struct_len += len;
}

static void pad4(void)
{
	while (struct_len & 3) {
		uint8_t z = 0;
		bytes(&z, 1);
	}
}

static void begin_node(const char *name)
{
	be32(FDT_BEGIN_NODE);
	bytes(name, strlen(name) + 1);
	pad4();
}

static void end_node(void)
{
	be32(FDT_END_NODE);
}

static uint32_t name_off(const char *name)
{
	uint32_t off = strings_len;
	memcpy(blob + strings_off + strings_len, name, strlen(name) + 1);
	strings_len += strlen(name) + 1;
	return off;
}

static void prop(const char *name, const void *value, uint32_t len)
{
	uint32_t off = name_off(name);
	be32(FDT_PROP);
	be32(len);
	be32(off);
	if (len)
		bytes(value, len);
	pad4();
}

static void prop_u32(const char *name, uint32_t v)
{
	uint32_t be = __builtin_bswap32(v);
	prop(name, &be, 4);
}

static void prop_u32x2(const char *name, uint32_t a, uint32_t b)
{
	uint32_t v[2] = { __builtin_bswap32(a), __builtin_bswap32(b) };
	prop(name, v, 8);
}

static void prop_u32x4(const char *name, uint32_t a, uint32_t b, uint32_t c, uint32_t d)
{
	uint32_t v[4] = { __builtin_bswap32(a), __builtin_bswap32(b),
			  __builtin_bswap32(c), __builtin_bswap32(d) };
	prop(name, v, 16);
}

static void prop_str(const char *name, const char *s)
{
	prop(name, s, strlen(s) + 1);
}

/* A tree like the one the Qualcomm bootloader hands over. */
static uintptr_t build_tree(void)
{
	uint32_t header[10];

	memset(blob, 0, sizeof(blob));
	struct_off = 40;			/* the FDT header is 10 words */
	strings_off = struct_off + STRUCT_SIZE;
	strings_len = 0;
	struct_len = 0;

	begin_node("");
	prop_u32("#address-cells", 2);
	prop_u32("#size-cells", 2);

	begin_node("memory@80000000");
	prop_str("device_type", "memory");
	prop_u32x4("reg", 0, 0x80000000, 0, 0x40000000);
	end_node();

	begin_node("soc");
	begin_node("intc");
	prop_str("compatible", "arm,gic-v3");
	prop_u32x4("reg", 0, 0x17100000, 0, 0x10000);
	prop_u32x4("reg2", 0, 0x17180000, 0, 0x200000);
	end_node();

	begin_node("ufs_mem");
	prop_str("compatible", "qcom,ufshc");
	prop_u32x4("reg", 0, 0x01d84000, 0, 0x3000);
	end_node();
	end_node();

	begin_node("chosen");
	prop_u32x2("linux,initrd-start", 0, 0x1000000);
	prop_u32x2("linux,initrd-end", 0, 0x2000000);
	end_node();

	be32(FDT_END);
	pad4();

	header[0] = FDT_MAGIC;
	header[1] = strings_off + strings_len;	/* totalsize */
	header[2] = struct_off;		/* off_dt_struct */
	header[3] = strings_off;		/* off_dt_strings */
	header[4] = strings_off;		/* mem reserve map: empty */
	header[5] = 17;			/* version */
	header[6] = 16;			/* last compatible version */
	header[7] = 0;			/* boot cpu */
	header[8] = strings_len;
	header[9] = struct_len;
	for (int i = 0; i < 10; i++)
		header[i] = __builtin_bswap32(header[i]);
	memcpy(blob, header, sizeof(header));
	(void)strings;
	return (uintptr_t)blob;
}

static int failures;

static void check(int ok, const char *what)
{
	printf("%-40s %s\n", what, ok ? "ok" : "FAILED");
	if (!ok)
		failures++;
}

int main(void)
{
	uintptr_t dtb = build_tree();
	char path[64];
	uint64_t regs[32];
	uint32_t v;
	uint64_t u;
	int n;

	check(fdt_chosen_u64(dtb, "linux,initrd-start", &u) && u == 0x1000000,
	      "fdt_chosen_u64 initrd-start");
	check(fdt_chosen_u64(dtb, "linux,initrd-end", &u) && u == 0x2000000,
	      "fdt_chosen_u64 initrd-end");
	check(!fdt_chosen_u64(dtb, "nope", &u), "fdt_chosen_u64 missing property");

	check(fdt_find_name(dtb, "memory", path, sizeof(path)) &&
	      strcmp(path, "/memory@80000000") == 0, "fdt_find_name memory");
	check(fdt_find_name(dtb, "intc", path, sizeof(path)) == 0,
	      "fdt_find_name only looks at root level");

	n = fdt_node_regs(dtb, "/memory@80000000", regs, 8);
	check(n == 1 && regs[0] == 0x80000000 && regs[1] == 0x40000000,
	      "fdt_node_regs memory");

	check(fdt_find_compatible(dtb, "qcom,ufshc", path, sizeof(path)) &&
	      strcmp(path, "/soc/ufs_mem") == 0, "fdt_find_compatible ufshc");
	n = fdt_node_regs(dtb, path, regs, 8);
	check(n == 1 && regs[0] == 0x01d84000 && regs[1] == 0x3000,
	      "fdt_node_regs ufs_mem");

	check(fdt_find_compatible(dtb, "arm,gic-v3", path, sizeof(path)) &&
	      strcmp(path, "/soc/intc") == 0, "fdt_find_compatible gic");
	check(fdt_node_u32(dtb, "/soc/intc", "#nothing", &v) == 0,
	      "fdt_node_u32 missing property");

	printf("%s\n", failures ? "FAILED" : "all checks passed");
	return failures ? 1 : 0;
}
