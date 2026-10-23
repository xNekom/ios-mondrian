#pragma once
#include <stdint.h>

/*
 * Read-only SPMI PMIC access for the shell menu's keys.
 *
 * The spmi@c42d000 arbiter of the live tree gives its regions by reg-names
 * (cnfg core chnls obsrvr intr); the PON and the gpio block of the PM8350
 * are found through the tree's /__symbols__ entries, and their peripheral
 * ids come from the reg properties of the found nodes -- nothing per phone
 * is hardcoded. Reads go through the EXT_READL observer command of the
 * v5 protocol (the same first bytes of the timer's patch): a WRITE to the
 * arbiter's command slot only, never a PMIC configuration write.
 */

/* 0 = the tree gave nothing usable; keys stay off and the menu counts down */
void spmi_init(uintptr_t fdt);

/*
 * Poll. Returns the RISING edges observed since the last call, or 0:
 *   SPMI_PON_ANY   a PON status bit went up (bit 0 is KPDPWR)
 *   SPMI_GPIO_ANY  a bit of the PM8350 gpio block went up (a volume)
 * The current PON byte, the gpio byte that rose and its page index are
 * copied out for the menu's screen line.
 */
#define SPMI_KEY_POWER		0x1	/* KPDPWR (PON bit 7) went down */
#define SPMI_KEY_VOLDOWN	0x2	/* RESIN (PON bit 6) went down */
#define SPMI_KEY_VOLUP		0x4	/* GPIO6 pulled low (its level fell) */
int spmi_poll(unsigned char *pon, unsigned char *gpio, int *page);

/* 1 when the init found and gated the regions */
int spmi_ready(void);

/* Why the init refused, as a code for the menu line (0 = it did not). */
int spmi_why(void);

/* The arbiter version word as read (for the diagnostic line). */
uint32_t spmi_version(void);
