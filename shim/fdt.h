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
 * size cells of the root. Returns the number of pairs. */
int fdt_node_regs(uintptr_t fdt, const char *path, uint64_t *out, int max);

/* Path of the first node whose name starts with prefix ("memory" matches
 * "memory@80000000"), or of the first node whose "compatible" property
 * contains the given string. Both return 1 and fill out[] on success. */
int fdt_find_name(uintptr_t fdt, const char *prefix, char *out, int out_len);
int fdt_find_compatible(uintptr_t fdt, const char *compat, char *out, int out_len);
