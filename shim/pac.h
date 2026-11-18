#pragma once

/*
 * Pointer-authentication gate for the arm64e (iOS 27) route.
 *
 * The shim runs at EL1 before XNU, so it is the cheapest place to ask the
 * silicon whether it implements FEAT_PAuth and whether the hypervisor leaves
 * the key registers and the PAC instructions usable.  Built only with
 * PAC_PROBE=1.
 */
void pac_probe(void);
