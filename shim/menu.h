#pragma once
#include <stdint.h>

/*
 * The boot menu of the shim. v0.2 draws the full-screen selector with
 * the two logo cards and counts down to the default (iOS); the keys are
 * polled through shim/spmi.c (PON + PM8350 gpio, addresses from the live
 * tree): a rising edge moves the selection, the PON's power bit
 * confirms. Both the running boot (the legal timeout) and the failure
 * mode (spmi off -> countdown only) end on a defined choice.
 */

/* The countdown, in seconds. */
#define MENU_SECONDS	5

/* The pick the countdown falls back to: 0 = iOS, 1 = Android. */
#define MENU_DEFAULT	0

/*
 * Draw the selector, poll the keys and run the countdown; the return
 * value is the index of the choice. Without a framebuffer (con_enable()
 * not called, or a board the tree did not give us the splash of) it
 * draws nothing and returns the default at once, so the boot behind it
 * is unchanged.
 */
int menu_show(uintptr_t fdt);
