#pragma once
/*
 * Minimal flattened device tree access for the shim.
 *
 * The bootloader hands us the live device tree; everything the port needs to
 * know about the phone (where the MMIO windows are, how much DRAM there is)
 * can be read out of it instead of being hardcoded.
 */
#include <stdint.h>

/* /chosen/<prop> as a 4 or 8 byte integer. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);

/* <path>/<prop> as a 4 or 8 byte integer. */
int fdt_node_u64(uintptr_t fdt, const char *path, const char *prop, uint64_t *out);
int fdt_node_u32(uintptr_t fdt, const char *path, const char *prop, uint32_t *out);

/* Raw property data. The pointer is into the device tree in memory. */
int fdt_node_prop(uintptr_t fdt, const char *path, const char *prop,
    uintptr_t *data, uint32_t *len);

/* Decode a "reg" property into address/size pairs, using the address and
 * size cells of the node (or of the root). Returns the number of pairs. */
int fdt_node_regs(uintptr_t fdt, const char *path, uint64_t *out, int max);
int fdt_node_regs_cells(uintptr_t fdt, const char *path, uint64_t *out, int max,
    int ac, int sc);

/*
 * The carve-outs of /reserved-memory: the addresses the firmware keeps for
 * itself (the hypervisor, the modem, the framebuffer...). Returns the
 * number of base/size pairs written to out[].
 */
int fdt_reserved_regions(uintptr_t fdt, uint64_t *out, int max);

/*
 * The biggest hole inside a memory region once the carve-outs of
 * /reserved-memory are taken out of it. Returns 1 and fills hole_base and
 * hole_size when there is one.
 */
int fdt_biggest_hole(uintptr_t fdt, uint64_t base, uint64_t size,
		uint64_t *hole_base, uint64_t *hole_size);

/* Path of the first node whose name starts with prefix ("memory" matches
 * "memory@80000000"), or of the first node whose "compatible" property
 * contains the given string. Both return 1 and fill out[] on success.
 * fdt_find_name looks at the children of the root, fdt_find_name_depth at
 * the nodes of a given depth (2 = a child of the root). */
int fdt_find_name(uintptr_t fdt, const char *prefix, char *out, int out_len);
int fdt_find_name_depth(uintptr_t fdt, const char *prefix, char *out, int out_len,
    int depth);
int fdt_find_compatible(uintptr_t fdt, const char *compat, char *out, int out_len);

/* First /__symbols__ value containing needle, as a node path string. */
int fdt_symbols_for(uintptr_t fdt, const char *needle, char *out, int out_len);
/* The node path whose "phandle" is the given handle. */
int fdt_find_phandle(uintptr_t fdt, uint32_t want, char *out, int out_len);
