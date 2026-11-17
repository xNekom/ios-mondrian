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

### The Bluetooth UART, as the live tree has it

Measured on `dtb/mondrian-live.dtb` with `tools/dtb-dump.py` (the host has no
`dtc`; the phandles are resolved because a pin number and a regulator are the
part that is easy to misread):

```
tools/dtb-dump.py dtb/mondrian-live.dtb 'qup_uart@894000'
tools/dtb-dump.py dtb/mondrian-live.dtb 'bt_qca6490'
```

- **High-speed UART**: `/soc/qcom,qup_uart@894000`, `qcom,msm-geni-serial-hs`,
  `reg` **0x894000 + 0x4000**, `status` ok, `qcom,wakeup-byte` **0xfd**. It sits
  in the `qupv3_2` GENI wrapper at **0x8C0000** (`qcom,wrapper-core`), with
  `gcc` (`clock-controller@100000`) clocks `0x82` (se), `0x8a` (m-ahb), `0x8b`
  (s-ahb). Four pinctrl states: default, active, sleep, shutdown.
- **Interrupts**: GIC SPI **587**, level high, plus a wakeup line from
  `pinctrl@f000000` GPIO **79** (`interrupts-extended` = `<gic 0 587 4>`
  `<pinctrl 79 4>`).
- **The console UART is the other one**: `/soc/qcom,qup_uart@99c000`,
  `qcom,msm-geni-console`, SPI **608**. Do not bring that one up for Bluetooth.
- **BT node** `/soc/bt_qca6490` (`qcom,qca6490`): reset GPIO **81**, switch
  control GPIO **82**, WLAN reset GPIO **80**, XO clock GPIO **204**, all on
  `pinctrl@f000000`; `mboxes` = `qmp-aop` index 0.
- **Rails**, with the DT's own min/max/load/enable and the regulator each names:
  `vdd-aon`, `vdd-dig`, `vdd-rfa-0p8` and `vdd-rfacmn` → `pm8350 S11`
  (0.966–1.17 V); `vdd-io` → `pm8350 S10` (1.8 V); `vdd-asd` → `pmr735a L7`
  (2.8 V); `vdd-rfa1` → `pm8350c S1` (1.9–2.04 V); `vdd-rfa2` → `pm8350 S12`
  (1.35–2.024 V); `vreg_ipa` → `pmr735a S3` (2.2 V).

The QUP side now exists in the kernel (`0343`, below); nothing powers the chip
yet — no rail and none of the three GPIOs — so the firmware load is still the
step after that.

### The engine, the UART and the wire (measured)

`0343` maps wrapper 2, SE5 and GCC, votes the five bits of 0x62010 and reads the
identity registers; `tools/usb-ring.py` runs it from the host. Three stages,
each one proof for the next:

```
btuart         identity registers with the clocks voted
btuart loop    programs 8N1 and sends a byte into its own loopback
btuart hci     sends HCI_Reset (01 03 0c 00) and prints the answer
```

Measured on the kernel of 2026-11-16, with the control channel still answering
afterwards (`pos` and `thermal` both came back, so the reads do not wedge the
bus):

```
btuart: vote 0x0 -> 0x20f want 0x20f granted
btuart: rcgr cmd 0x0 cfg 0x100000 (was already rooted)
btuart: halt se5 0x4220 m-ahb 0x0 s-ahb 0x80000002
btuart: wrapper2 hw ver 0x30080000
btuart: se init 0xa
btuart: se cgc 0x7f
btuart: se clk 0x1
btuart: se fw 0x204
```

Read it as: the vote register came back **0 with nothing set** (no earlier boot
or bootloader step powers this engine), the write sticks (`0x20f` = core 2x,
core, m-ahb, s-ahb, SE5), the SE clock root was **already on** so the XO
fallback did not run, bit 0 of the SE5 halt register is clear (the engine is not
halted), and the engine reports a GENI init-config revision of **0xa**, `CGC_CTRL`
0x7f, `CLK_CTRL_RO` 1 and a firmware revision of **0x204** (protocol UART, already
loaded).

The UART stage, measured on the kernel of 2026-11-17 with `pos` answering
afterwards (`269963`):

```
btuart: fifo tx 16 words x 32 bits, rx 32 words
btuart: uart 8n1 div 10 (xo 19.2MHz -> 120000 baud) loopback 1 status 0x41000
btuart: m_cmd0 0x8000000 status 0x41000 -> 0x41041
btuart: tx fifo filled 0x10000000
btuart: tx 1 bytes done 1 irq 0x40000001 tx_fifo left 0x0
btuart: rx fifo status 0x90000001, 1 bytes
btuart: rx data: 5a
```

`btuart hci` prints the same lines with `4 bytes` and `rx data: (nothing)`: the
`HCI_Reset` leaves the wire and the engine completes, but nothing answers,
because nothing powers the chip yet.

Four traps in that sequence, each one a boot when it was wrong, all settled by
mainline `qcom_geni_serial.c` / `qcom-geni-se.c`:

- `SE_UART_TX_TRANS_CFG` (0x25c) bit 1 (`UART_CTS_MASK`) must be **set** with no
  hardware flow control. Cleared, the TX command latches (`M_GENI_CMD_ACTIVE`
  comes on, `status …41`) and never completes: `done 0`, `M_IRQ_STATUS` 0.
- The TX command starts **before** the FIFO is filled: `SE_UART_TX_TRANS_LEN`,
  `M_CMD0` = `UART_START_TX << 27`, then the FIFO. Filling first leaves
  `TX_FIFO_STATUS` at 0 — the writes do not land.
- `SE_GENI_BYTE_GRAN` (0x254) is 0 for 8-bit words (`bpw / 16`). What the
  bootloader leaves there swallows byte writes.
- Depths come from `SE_HW_PARAM_0/1` bits 21:16 (16 TX words of 32 bits, 32 RX),
  not a guessed 62; `SE_GENI_RX_STALE_CNT` (0x294) is 160 (`10 * 16`); packing is
  8 bits, four words per entry, lsb first (`TX_PACKING_CFG0` 0x4380e, `CFG1`
  0xc3e0e), and the TX FIFO holds four bytes per 32-bit entry.

The loopback proves the engine and the framing, **not** the baud: div 10 off the
XO is 120000, 4 % high. The ROM needs 115200 exactly, and the QUP source table
already has it: `F(14745600, P_GCC_GPLL0_OUT_EVEN, 1, 768, 15625)` in
`gcc-sm8450.c`, and `14745600 / (8 * 16) = 115200`. `gcc_qupv3_wrap2_s5_clk_src`
has `mnd_width = 16`, so the SE root takes the fractional M/N, and the SER
divider is 8.

`btuart baud` programs that and reads it back exactly (measured):

```
btuart: rcg cmd 0x2 cfg 0x102601 m 0x300 n 0xc5f6 d 0xc2f6 -> 14745600 Hz
```

`cmd 0x2` is `ROOT_EN` with the update latched, `cfg 0x102601` keeps the hardware
clock-control bit (20) and sets parent 6, pre divider 1 and dual-edge mode, and
the M/N/D fields are `~(N - M)` and `~N` as `clk-rcg2.c` writes them. The write
must be a read-modify-write of `CMD_UPDATE`: a plain write of `0x1` clears
`ROOT_EN`.

Its loopback, measured after the fix that cancels the previous stage's secondary
command (`btuart baud` twice in a row, and 5a both times):

```
btuart: uart 8n1 div 8 (root 14745600 -> 115200 baud) loopback 1 status 0x41000
btuart: tx 1 bytes done 1 irq 0x40000001 tx_fifo left 0x0
btuart: rx data: 5a
```

So the engine frames at the rate the RCG was set to. 115200 itself is derived
from that readback (14745600 / (8 × 16)), not measured against a chip.

`btuart hci` — the only stage that drives the physical TX pin (loopback off) —
must not be run yet. Twice it left the phone answering ICMP with 19-38 ms latency
(a spinning kernel) and nothing on UDP 5141: mainline enables
`SE_IRQ_EN`'s four sources because it has a handler for SPI 587, and driving a
line whose far end is an unpowered chip is what produces the event. Both
`SE_IRQ_EN` and `M_IRQ_EN` now stay 0 and the completion is polled, but the wire
test waits until the pins and that interrupt are ours.

### What powering the chip needs

The eight rails are RPMh resources, not SPMI registers: the live tree's
`qcom,bt-vdd-*-supply` resolves to `qcom,rpmh-vrm-regulator` nodes under
`/soc/rsc@17a00000` with `qcom,resource-name` **smpb11** (S11: aon, dig,
rfa-0p8, rfacmn), **smpb10** (S10: io, 1.8 V), **smpb12** (S12: rfa2),
**smpc1** (pm8350c S1: rfa1), **ldoe7** (pmr735a L7: asd, 2.8 V) and **smpe3**
(pmr735a S3: ipa), all with `qcom,set 3` (active and sleep). That is an AOP vote
with a voltage and a mode, the same door the GPU votes in `0170` use, not
`mondrian_spmi_reg_write()`.

The three GPIOs are `qcom,bt-reset-gpio` **81**, `qcom,bt-sw-ctrl-gpio` **82** and
`qcom,xo-clk-gpio` **204** on `/soc/pinctrl@f000000`, which is
`qcom,cape-pinctrl` (`reg` 0xf000000 + 0x1000000) and uses mainline's tiled
layout: per-pin offsets come from the SoC's pinctrl table, so a guessed
`0x1000 * gpio` is wrong here. `bt_en_sleep` in that node is
`bias-pull-down, drive-strength 2, output-low`, i.e. the tree's own idea of the
chip being off.

Before writing either, dump what the vendor kernel leaves behind: an OrangeFox
`fastboot boot` (ten seconds, writes nothing) reports the rails
(`/sys/class/regulator/*/state`) and the pin state
(`/sys/kernel/debug/pinctrl/*/pinconf-pins`) of the same hardware.

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
