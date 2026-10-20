/*
 * Just enough flattened-device-tree parsing to find what ABL put in the
 * device tree: nodes, properties and the addresses of the interesting
 * peripherals. Big-endian, 4-byte aligned tokens.
 *
 * The shim uses it to dump the live tree of the phone it is running on, so
 * the board table (tools/boards.py) can be filled in from the device instead
 * of from guesswork.
 */
#include "fdt.h"

#define FDT_MAGIC	0xd00dfeed
#define FDT_BEGIN_NODE	1
#define FDT_END_NODE	2
#define FDT_PROP	3
#define FDT_NOP		4
#define FDT_END		9

#define PATH_MAX	256

static uint32_t be32(uintptr_t a)
{
	return __builtin_bswap32(*(volatile uint32_t *)a);
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static uintptr_t align4(uintptr_t a)
{
	return (a + 3) & ~3UL;
}

static uintptr_t skip_str(uintptr_t p)
{
	/* byte loads are fine on Device memory as long as it is aligned to 1 */
	while (*(volatile char *)p)
		p++;
	return p + 1;
}

/* strlen/strncmp, without libc. The device tree is read as Device memory,
 * so the pointers are volatile byte accesses. */
static uint32_t strlen_(const char *p)
{
	uint32_t n = 0;
	while (*(volatile char *)(p + n))
		n++;
	return n;
}

static int strncmp_(const char *a, const char *b, int n)
{
	while (n-- > 0) {
		if (*a != *b)
			return 1;
		if (!*a)
			return 0;
		a++, b++;
	}
	return 0;
}

/* Does a NUL separated string list (a "compatible" property) contain s? */
static int strlist_has(uintptr_t data, uint32_t len, const char *s)
{
	for (uint32_t off = 0; off < len; off += strlen_((const char *)(data + off)) + 1) {
		if (off >= len)
			break;
		if (streq((const char *)(data + off), s))
			return 1;
	}
	return 0;
}

/*
 * Walk the tree. The callback is called for every property with the path of
 * the node it belongs to; it returns 1 to stop the walk.
 */
struct fdt_walk {
	uintptr_t fdt;
	uintptr_t strings;
	char path[PATH_MAX];
	int len;
	int depth;
};

static void path_push(struct fdt_walk *w, const char *name)
{
	if (w->len == 0) {
		w->path[w->len++] = '/';
		w->path[w->len] = 0;
	} else if (w->path[w->len - 1] != '/') {
		if (w->len < PATH_MAX - 1) {
			w->path[w->len++] = '/';
			w->path[w->len] = 0;
		}
	}
	while (*name && w->len < PATH_MAX - 1) {
		w->path[w->len++] = *name++;
		w->path[w->len] = 0;
	}
}

static void path_pop(struct fdt_walk *w)
{
	while (w->len > 0 && w->path[w->len - 1] != '/')
		w->len--;
	if (w->len > 0)
		w->len--;
	w->path[w->len] = 0;
}

int fdt_node_prop(uintptr_t fdt, const char *path, const char *prop,
    uintptr_t *data, uint32_t *plen)
{
	struct fdt_walk w = { .fdt = fdt, .strings = 0, .len = 0, .depth = 0 };
	uintptr_t p, strings;
	int target = -1;

	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	p = fdt + be32(fdt + 8);
	strings = fdt + be32(fdt + 12);
	w.strings = strings;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			w.depth++;
			path_push(&w, name);
			p = align4(skip_str(p));
			if (target < 0 && streq(w.path, path))
				target = w.depth;
			break;
		}
		case FDT_END_NODE:
			if (target == w.depth) {
				path_pop(&w);
				return 0;
			}
			path_pop(&w);
			w.depth--;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (target == w.depth &&
			    streq((const char *)(strings + nameoff), prop)) {
				*data = val;
				*plen = len;
				return 1;
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:	/* FDT_END or garbage */
			return 0;
		}
	}
}

int fdt_node_u64(uintptr_t fdt, const char *path, const char *prop, uint64_t *out)
{
	uintptr_t data;
	uint32_t len;

	if (!fdt_node_prop(fdt, path, prop, &data, &len))
		return 0;
	if (len == 4) {
		*out = be32(data);
		return 1;
	}
	if (len == 8) {
		*out = (uint64_t)be32(data) << 32 | be32(data + 4);
		return 1;
	}
	return 0;
}

int fdt_node_u32(uintptr_t fdt, const char *path, const char *prop, uint32_t *out)
{
	uint64_t v;

	if (!fdt_node_u64(fdt, path, prop, &v) || v > 0xffffffffULL)
		return 0;
	*out = (uint32_t)v;
	return 1;
}

int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out)
{
	return fdt_node_u64(fdt, "/chosen", prop, out);
}

int fdt_node_regs_cells(uintptr_t fdt, const char *path, uint64_t *out, int max,
    int ac, int sc)
{
	uintptr_t data;
	uint32_t len;
	int cells, n = 0;

	if (!fdt_node_prop(fdt, path, "reg", &data, &len))
		return 0;
	if (ac == 0 || ac > 2 || sc == 0 || sc > 2)
		return 0;
	cells = ac + sc;
	for (uint32_t off = 0; off + cells * 4 <= len && n < max; off += cells * 4) {
		uint64_t base = 0, size = 0;
		for (int c = 0; c < ac; c++)
			base = (base << 32) | be32(data + off + c * 4);
		for (int c = 0; c < sc; c++)
			size = (size << 32) | be32(data + off + ac * 4 + c * 4);
		out[n * 2] = base;
		out[n * 2 + 1] = size;
		n++;
	}
	return n;
}

int fdt_node_regs(uintptr_t fdt, const char *path, uint64_t *out, int max)
{
	uint32_t ac = 2, sc = 1;

	/* The node may override the cells of the root. */
	if (!fdt_node_u32(fdt, path, "#address-cells", &ac) &&
	    !fdt_node_u32(fdt, "/", "#address-cells", &ac))
		ac = 2;
	if (!fdt_node_u32(fdt, path, "#size-cells", &sc) &&
	    !fdt_node_u32(fdt, "/", "#size-cells", &sc))
		sc = 1;
	return fdt_node_regs_cells(fdt, path, out, max, (int)ac, (int)sc);
}

int fdt_find_name(uintptr_t fdt, const char *prefix, char *out, int out_len)
{
	return fdt_find_name_depth(fdt, prefix, out, out_len, 2);
}

/* Search a node by name at a given depth (2 = a child of the root). */
int fdt_find_name_depth(uintptr_t fdt, const char *prefix, char *out, int out_len,
    int depth_wanted)
{
	struct fdt_walk w = { .fdt = fdt, .strings = 0, .len = 0, .depth = 0 };
	uintptr_t p, strings;
	int found = 0;

	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	p = fdt + be32(fdt + 8);
	strings = fdt + be32(fdt + 12);
	w.strings = strings;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			w.depth++;
			path_push(&w, name);
			p = align4(skip_str(p));
			if (!found && w.depth == depth_wanted) {
				/* compare the name up to '@' */
				const char *at = name;
				while (*at && *at != '@')
					at++;
				if ((int)(at - name) == (int)strlen_(prefix) &&
				    !strncmp_(name, prefix, (int)(at - name))) {
					int n = 0;
					const char *s = w.path;
					while (*s && n < out_len - 1) {
						out[n] = *s++;
						n++;
					}
					out[n] = 0;
					found = 1;
				}
			}
			break;
		}
		case FDT_END_NODE:
			path_pop(&w);
			w.depth--;
			if (found)
				return 1;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p);
			uintptr_t val = p + 8;
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:
			return found;
		}
	}
}

int fdt_find_compatible(uintptr_t fdt, const char *compat, char *out, int out_len)
{
	struct fdt_walk w = { .fdt = fdt, .strings = 0, .len = 0, .depth = 0 };
	uintptr_t p, strings;
	int found = 0;

	if (!fdt || be32(fdt) != FDT_MAGIC)
		return 0;
	p = fdt + be32(fdt + 8);
	strings = fdt + be32(fdt + 12);
	w.strings = strings;

	for (;;) {
		uint32_t tok = be32(p);
		p += 4;
		switch (tok) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			w.depth++;
			path_push(&w, name);
			p = align4(skip_str(p));
			break;
		}
		case FDT_END_NODE:
			path_pop(&w);
			w.depth--;
			break;
		case FDT_PROP: {
			uint32_t len = be32(p), nameoff = be32(p + 4);
			uintptr_t val = p + 8;
			if (!found && streq((const char *)(strings + nameoff), "compatible") &&
			    strlist_has(val, len, compat)) {
				int n = 0;
				const char *s = w.path;
				while (*s && n < out_len - 1) {
					out[n] = *s++;
					n++;
				}
				out[n] = 0;
				found = 1;
			}
			p = align4(val + len);
			break;
		}
		case FDT_NOP:
			break;
		default:
			return found;
		}
	}
}
