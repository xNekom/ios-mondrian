#pragma once
void test_ufs(void);

/*
 * Print the tail of the persistent kernel console log (xnu 0096), which lives
 * in the last 4 MiB of userdata. test_ufs() has to have run first: it is what
 * finds the partition in the GPT.
 */
void log_dump(void);

/* Point the UFS probe at the host the device tree names. */
void ufs_set_base(uintptr_t base);
