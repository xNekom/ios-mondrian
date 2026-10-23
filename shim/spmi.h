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
 * Poll. Returns the edges observed since the last call, or 0:
 *   SPMI_PON_ANY  a PON status byte moved (power or resin candidate)
 *   SPMI_GPIO_ANY a gpio status byte moved (a volume candidate)
 * The changed bytes are copied out for the menu's screen line.
 */
#define SPMI_PON_ANY	1
#define SPMI_GPIO_ANY	2
int spmi_poll(unsigned char *pon, unsigned char *gpio);

/* 1 when the init found and gated the regions */
int spmi_ready(void);
