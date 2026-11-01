# WiFi and Bluetooth on mondrian

Neither works, and neither has anything in the kernel yet: the built kernel
exports no `IO80211`, `IOBluetooth`, `IOEthernet` or `IOSerial` symbol
(measured with `nm`). The phone carries a Qualcomm **QCA6490** combo, whose two
halves are separate buses and separate projects.

This document records the hardware, what the iOS userland expects, what the
existing ports teach, and the order to attack it. It is a plan, not a status
report.

## The hardware

From the live device tree (`/private/tmp/live.dtb`, `bluetooth` and `wlan`
aliases):

| Half | Bus | Nodes | Linux driver |
| --- | --- | --- | --- |
| WiFi | PCIe 0, `pcie@1c00000` endpoint | `qcom,cnss-qca6490@b0000000`, `cnss_pci`, `cnss_pins` | `cnss2` loads the firmware and brings up MHI; `ath11k` drives the WLAN |
| Bluetooth | QUP UART (`hci_qca`) | `bt_qca6490`: reset, sw-ctrl and xo GPIOs, eight rails, `mboxes` | `hci_qca` (UART), `btqca` (power) |

- The WiFi part is a WCN6855-class device (the QCA6490 is its board-level
  name). Linux firmware: `ath11k/WCN6855/hw2.0/amss.bin`, `m3.bin`,
  `board-2.bin`, `regdb.bin`. `board-2.bin` is board-specific; the stock
  vendor partition has the calibrated copy.
- The Bluetooth part is the same die's BT core, reached over its own UART.
  Firmware is a RAM patch plus an NVM file from the `qca/` family
  (`nvm_00190200.bin` and the matching `rampatch_*`; the ROM version read from
  the chip selects the exact file).
- Both halves need the PMIC rails in the DT and the `cnss`/`bt` reset GPIOs.
  Nothing powers them today: there is no PCIe host driver and no QUP UART
  driver in this kernel.

## What iOS expects

Measured strings in the iOS 16.7.16 root:

- **WiFi.** `wifid` matches an `IO80211SkywalkInterface` service and speaks
  `Apple80211Get/Set(APPLE80211_IOC_*)`; the kernel side is Apple's closed
  `IO80211Family`, which this XNU build does not contain. A Wi-Fi menu
  therefore needs either that family (binary from an iPhone kernelcache, same
  build; ABI and symbol risk) or a compatible reimplementation of the
  controller/interface, its event channel and its data path.
- **Bluetooth.** `bluetoothd` is the whole stack, in user space. It supports
  `H4`, `H4BC`, `H4DS` and `H5` transports, opens `/dev/cu.bluetooth`, and
  looks for an `AppleBluetoothModule` service. The kernel only has to provide
  an HCI transport and the firmware loader; no Bluetooth protocol code is
  needed in the kernel. The transport and the vendor checks live in
  `bluetoothd`, and this root is ours to patch.

## What other ports teach

| Project | What it does | Lesson for mondrian |
| --- | --- | --- |
| [itlwm](https://github.com/OpenIntelWireless/itlwm) | Intel WiFi as an `IOEthernetController` plus the HeliPort app | A fake Ethernet interface plus a userland supplicant works without `IO80211`, but there is no native Wi-Fi UI |
| [AirportItlwm](https://github.com/OpenIntelWireless/itlwm), [SimpleMtkWlan](https://github.com/pengubow/SimpleMtkWlan), [AirportWCN7850](https://github.com/razvanccr/AirportWCN7850) | Implement `IO80211Controller`/WCL on top of Apple's family | Native menu achievable; version-sensitive; **AirportWCN7850 is the closest precedent**: a Qualcomm WCN7850 (same MHI/QMI/WMI generation as our WCN6855) working at 11ac |
| [BluetoothWCN7850](https://github.com/razvanccr/BluetoothWCN7850) | QCA firmware loader kext; Apple's userspace stack drives HCI afterwards | The proven pattern: load firmware at match time, before userspace can seize the device; read the status bits and send only what is missing |
| [IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware), [BrcmPatchRAM](https://github.com/acidanthera/BrcmPatchRAM) | Firmware loaders for other vendors | Same pattern; the stack does the rest |
| `BlueToolFixup`, `IntelBTPatcher` | Patch `bluetoothd` transport selection/vendor list; fix LE scan address | Apple's transport choice and vendor whitelist are the real gate, not the HCI link |
| Project Sandcastle (Android on iPhone) | The reverse port | Even there, Bluetooth, GPU and cellular were never brought up: radios are not a shortcut |

Concrete traps paid for by those ports, all relevant here:

- `AirportWCN7850`/`BluetoothWCN7850` bring-up notes: `IOCommandGate::runAction`
  passes the gate's owner; `mbuf_pullup` always splits a cluster mbuf; the
  WCN7850 reaches only the first 4 GB (bounce buffers); one MSI vector is
  enough, but its CE interrupt mask must be set; the vdev is created on the
  first interface-up.
- AWDL/AirDrop is not coming on a Qualcomm fullMAC: the firmware owns channel
  timing, and it has no AWDL engine
  ([feasibility study](https://github.com/razvanccr/AirportWCN7850/blob/main/docs/awdl-feasibility.md)).
- The Bluetooth loader must run before `bluetoothd` enumerates the transport
  (kext matching does this; a launch daemon loses the race), and firmware held
  in RAM does not survive a power cycle.

## The order to do it

Bluetooth first: it exercises the QCA firmware, power and reset sequence
without PCIe, MHI or a 802.11 stack, and it produces a visible result
(CoreBluetooth, AirPods) from a comparatively small driver.

1. Power the chip from `bt_qca6490` (rails, reset/sw-ctrl/xo GPIOs) and read
   the ROM version over the QUP UART, the way `hci_qca` starts.
2. Download the RAM patch and NVM, reset, and check that HCI Reset and Read
   Local Version answer.
3. Expose the port as `/dev/cu.bluetooth` and make `bluetoothd` use `H4`
   (its plist environment is ours). Measure whether it reaches
   `StackStarted`, and whether the Broadcom `BlueTool` script is skipped on
   the third-party-chipset path.
4. Pairing and A2DP. SCO audio needs the SLIMbus/PCM route, which is a
   separate piece of work.

WiFi after that, and only with a decision made up front:

- The driver work is PCIe enumeration (PERST, wake, clocks) → MHI → QMI
  (`cnss2`) → `ath11k` WMI (scan, join, keys). The `qwz` port in
  `AirportWCN7850` is the map for the macOS side; our chip is `ath11k`, not
  `ath12k`, so the Linux driver is the reference.
- The userland interface is the fork in the road. **(a)** Implement the
  `IO80211SkywalkInterface` surface `wifid` matches, giving the real Wi-Fi
  menu; this is the expensive path. **(b)** Give iOS an IP interface (a
  custom `ifnet` or `utun`) fed by a userland supplicant; connectivity works,
  the Wi-Fi menu does not.
- Do not plan on AWDL/AirDrop either way.

Estimate from the precedents: Bluetooth is weeks to months; WiFi with the
native interface is six to twelve months of driver and compatibility work,
and the IP-only path is shorter but still needs the full firmware/MHI/WMI
bring-up first.
