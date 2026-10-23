#pragma once

/*
 * The boot menu of the shim. v0 draws a band and counts down to the
 * default (iOS); the volume and power keys are polled in a later version,
 * once their sources (PMIC PON over SPMI, maybe a TLMM gpio for one of the
 * volumes) have been read out of the stock device tree.
 */

/* The countdown, in seconds. */
#define MENU_SECONDS	5

/* The pick the countdown falls back to: 0 = iOS, 1 = Android. */
#define MENU_DEFAULT	0

/*
 * Draw the selector and run the countdown; the return value is the index
 * of the choice. Without a framebuffer (con_enable() not called, or a
 * board the tree did not give us the splash of) it draws nothing and
 * returns the default at once, so the boot behind it is unchanged.
 */
int menu_show(void);
