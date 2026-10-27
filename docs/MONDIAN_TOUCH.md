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
| TLMM | `qcom,cape-pinctrl` node `0x0f000000+0x1000000`, but the pin registers start at **0x0f100000** (GPIO n at `+0x1000*n`); summary IRQ GIC SPI 208 |

## What the bootloader leaves (measured)

`0117` read the three pads: all come up in the TLMM reset state, function 0
(gpio), pull-down, input, level low, `INTR_CFG 0xe2` with the interrupt
itself disabled. The bootloader does not power the part: AVDD (GPIO71) is an
input and reset (GPIO20) is low. `0119` therefore drives the sequence: AVDD
on, 10 ms with reset held low, release and wait 50 ms, with GPIO21 left an
input and a pull-down. The Goodix asserts IRQ low, so a powered part out of
reset drives the line high; that level is the milestone-1 signal. On a high
line the pad is switched to the vendor's active pull-up.

Measured with `0119`: AVDD and reset read back as outputs high (`0x200/0x3`
and `0x2c0/0x3`), and the IRQ pad reads 0 with the pull-down and 1 with the
pull-up, i.e. the line floats. That fits an unpowered part, but it is not
proof: an open-drain INT also floats when deasserted, so "is it alive" has to
come from the SPI ID read (milestone 3), not from this pin.

## The SE, measured (`0120`/`0121`)

The QUPv3 wrapper answers (`QUPV3_HW_VER 0x30080000`) and the SE reports
`GENI_INIT_CFG_REVISION 0x9`, `CGC 0x7f`, `STATUS 0` and
`GENI_FW_REVISION_RO (=0x68) 0x102`: firmware version 2, protocol **1 = SPI**.
The bootloader left the SE clock off (RCG `CMD 0x80000000`, root off, and the
SE4 branch bit clear); rooting it on the XO (source 0, divider 1, 19.2 MHz)
clears `CMD` to 0 and the registers work.

Do **not** read `0x1000`: the newer GENI layout puts FW_REVISION there, this
SE does not decode it, and the read wedges the interconnect (the console
stops and the watchdog resets the phone). `0x68` is the register that exists.

The SPI bus is on **GPIO16-19** (clk, mosi, miso, cs) with the `qup4`
function (TLMM mux value 1, the group-local function index) and CS0; the
touch's reset/IRQ pads (20/21) are separate.

## The layers, in the order they have to work

1. **The IOVDD rail.** `vdd-supply` is `pm8350c_l2`, an **RPMh VRM**
   (`qcom,rpmh-vrm-regulator`, resource `ldoc2`, 1.8 V, init mode 4), not an
   SPMI-driven LDO: it needs an RPMh (RSC, `apps_rsc@17a00000`) vote, and the
   port has no RPMh driver. The ABL may leave the rail on; check that before
   writing one (the touch IRQ pin stays high when it is powered and out of
   reset). The shim's SPMI is read-only by design, so it cannot set it.
2. **TLMM pins.** Reset (20) low, then high after the part's power-up delay;
   AVDD enable (71) high; IRQ pin (21) as input with pull-down. The pin
   registers are the mainline `pinctrl-msm` layout at `0x0f100000 + 0x1000*n`:
   `GPIO_CFG` (pull 0-1, function 2-4, drive 6-8, output enable 9), `IN_OUT`
   (level 0, output value 1), `INTR_CFG` and `INTR_STATUS`. `0117`/`0119`
   read and drive the three pads from `bsd/dev/mondrian_touch.c`; there is no
   general pinctrl driver yet.
3. **GCC clocks.** The four branches the SE needs are all bits of GCC
   `0x62008`: `m-ahb` bit 6, `s-ahb` bit 7, the wrap core bit 8, core 2x bit 9
   and `se-clk` (clock id 94, `GCC_QUPV3_WRAP0_S4_CLK`) bit 14. The SE clock
   source is an RCG at `0x274e4`; whether the bootloader left it programmed
   (and at what rate) is measured by the first GENI read. The port already
   pokes the UFS branch from `tools/boards.py` (`gcc=0x100000`,
   `ufs_gcc_branch=0x870`, register `branch * 0x100`), but maps only one 4 KB
   page while the branch registers live at `0x87000`: it never ran (the
   bootloader left the UFS clocked), so map the whole `0x70000` window for the
   SE. Nothing may touch the SE before its clocks are on, or the bus hangs.
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

1. AVDD + reset, no SPI traffic: a powered part out of reset holds IRQ
   (GPIO21) high; `0119` drives the pads and prints the level. This proves
   the pins (and, if the level stays low, points at the IOVDD rail) without
   risking the bus.
2. GENI init and `GENI_FW_REVISION` read: proves the SE clock and the register
   window.
3. Goodix product ID over SPI: proves the transport and the protocol.
4. One touch report into `MondrianHIDTouch`: the lock screen unlocks with a
   swipe.
5. Multi-touch, then the buttons (power/volume) through the HID button service.

## Traps

- **The pin registers are not at the DT node's base.** `pinctrl@f000000`
  declares `0x0f000000+0x1000000`, but its first megabyte is a hole: the pin
  registers live at `0x0f100000`, as mainline's `pinctrl-sm8450` has it. A
  read of `0x0f014000` (GPIO20 at the wrong base) does not abort: it wedges
  the interconnect, the timer interrupt stops arriving, and the phone resets
  on the watchdog. Read `0x0f114000` instead, one 4 KB page per pin.
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
