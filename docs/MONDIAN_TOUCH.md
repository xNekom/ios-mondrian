# The mondrian touch screen: bring-up plan

The panel's digitizer is a Goodix part on **SPI**, wired to QUPv3 SE4. Nothing
of the transport exists in the kernel yet: this file is the register-level plan
and the facts measured from the live device tree (`/sys/firmware/fdt`, dumped
with `dtc -I dtb -O dts`). The work list entry is `docs/MONDIAN_PORT.md` §5.

## What the device tree says

| Fact | Value |
| --- | --- |
| SPI controller | `qcom,spi-geni` at **0x00990000** (SE4), 0x4000 bytes |
| SPI interrupt | GIC **SPI 605** (INTID 637), level |
| SPI clocks | `se-clk` gcc id **94**, `m-ahb` **134**, `s-ahb` **135** |
| Wrapper | `qcom,qupv3_1_geni_se@ac0000` (QUPv3 wrapper 1) |
| Chip select / speed | CS0, 15 MHz max (`spi-max-frequency = <0xe4e1c0>`) |
| Touch node | `xiaomi,m11a-spi` at `spi@990000/xiaomi_touch@0` |
| Reset | TLMM **GPIO 20**, active low |
| IRQ | TLMM **GPIO 21**, edge rising (`0x2008`), pull down |
| AVDD enable | TLMM **GPIO 71** |
| IOVDD | PMIC regulator, phandle `0x301` (`vdd-supply`) |
| Coordinates | `panel-max-x = 14400`, `-y = 32000` (0.1 mm units) |
| Panels | two panel phandles; the touch node is shared |
| TLMM | `qcom,cape-pinctrl` at **0x0f000000**, summary IRQ GIC SPI 208 |

## The layers, in the order they have to work

1. **The IOVDD rail.** `vdd-supply` is `pm8350c_l2`, an **RPMh VRM**
   (`qcom,rpmh-vrm-regulator`, resource `ldoc2`, 1.8 V, init mode 4), not an
   SPMI-driven LDO: it needs an RPMh (RSC, `apps_rsc@17a00000`) vote, and the
   port has no RPMh driver. The ABL may leave the rail on; check that before
   writing one (the touch IRQ pin stays high when it is powered and out of
   reset). The shim's SPMI is read-only by design, so it cannot set it.
2. **TLMM pins.** Reset (20) low, then high after the part's power-up delay;
   AVDD enable (71) high; IRQ pin (21) as input with pull-down. The TLMM
   register layout is mainline `pinctrl-msm` (GPIO_CFG at `0x1000 * n`,
   `INTR_CFG`, `INTR_STATUS`); the kernel has no TLMM driver yet.
3. **GCC clocks.** `se-clk` (branch 94) and the two AHB branches (134, 135).
   The port already pokes the UFS branch from `tools/boards.py`
   (`gcc=0x100000`, `ufs_gcc_branch=0x870`) and the shim does it at boot; the
   SE needs the same treatment, in the kernel this time, before the first
   register access or the bus hangs.
4. **GENI SE as SPI.** Mainline `spi-geni-qcom.c` + `qcom-geni-se.h` give the
   sequence: set `GENI_CFG` (protocol SPI, FIFO mode, CS), program
   `GENI_IO_MUX`/`SPI_CONFIG` (CPOL/CPHA, CS polarity, word length), write the
   address/length into the TX FIFO, then `GENI_GO` with the DMA/FIFO bit and
   wait for `GENI_IRQ_STATUS` done. The SE firmware version must be read first
   (`GENI_FW_REVISION`) and logged: this SoC's SE firmware is version 3.
5. **Goodix over SPI.** The protocol (command byte, register address, read
   length, ACK from the part) is the same one sweet implements over GENI I2C
   (`xnu/patches/0063-sweet-goodix-geni-packing.patch`): the transport changes,
   the register map does not. Start by reading the product ID (`0x8140`,
   four bytes ASCII) and the config version; log them and stop there.
6. **HID wiring.** `MondrianHIDTouch` already publishes a digitizer service
   (`0048`); feed it from the touch thread with `IOHIDEventCreateDigitizerEvent`
   style collections in the same way `MondrianHIDButtons` feeds keys.

## Milestones, each one testable in a single boot

1. TLMM reset + IOVDD on + SE clock on, no SPI traffic: the part's IRQ pin
   must go high (read `INTR_STATUS`). This proves power, pins and clocks
   without risking a bus hang.
2. GENI init and `GENI_FW_REVISION` read: proves the SE clock and the register
   window.
3. Goodix product ID over SPI: proves the transport and the protocol.
4. One touch report into `MondrianHIDTouch`: the lock screen unlocks with a
   swipe.
5. Multi-touch, then the buttons (power/volume) through the HID button service.

## Traps

- **The SE bus hangs the CPU when its clock is gated.** Every register access
  after a failed clock enable spins forever with interrupts off; the beacon in
  the timer interrupt stops. Enable the clocks first, and keep a spin-counted
  timeout on every poll.
- **GPIO numbers in the DT are TLMM numbers**, not Linux global numbers. The
  pin table is 1:1.
- **The live tree is the source of truth.** Two panels share the touch node;
  the panel-max values are the same for both, so the touch works with either
  panel without a panel-specific table.
- **SPI mode matters**: the vendor driver uses mode 0 at 15 MHz; the Goodix
  ACK window is short, so start at 1 MHz until the ID reads.
