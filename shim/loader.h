#pragma once
#include <stdint.h>

/* Boot the payload found in the ABL ramdisk; returns only on error.
 *
 * The payload is copied to the window the loader was given (the RAM the
 * bootloader reported), not to the address in the payload header: the header
 * only knows what the image was built for. */
const char *loader_boot(uintptr_t dtb);

/* The window of RAM the kernel gets: base and size, 0 if not set. */
void loader_set_window(uint64_t base, uint64_t size);
