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
| Reset | TLMM **GPIO 20**, active low: low holds the part in reset, high runs |
| IRQ | TLMM **GPIO 21**, active low (`interrupts = <0x2008>`, ONESHOT + TRIGGER_LOW) |
| AVDD enable | TLMM **GPIO 71** |
| IOVDD | PMIC regulator, phandle `0x301` (`vdd-supply`) |
| Coordinates | `panel-max-x = 14400`, `-y = 32000` (0.1 mm units) |
| Panels | two panel phandles; the touch node is shared |
| TLMM | `qcom,cape-pinctrl` node `0x0f000000+0x1000000`, but the pin registers start at **0x0f100000** (GPIO n at `+0x1000*n`); summary IRQ GIC SPI 208 |

## What the bootloader leaves (measured)

`0117` read the three pads: all come up in the TLMM reset state, function 0
(gpio), pull-down, input, level low, `INTR_CFG 0xe2` with the interrupt
itself disabled. The bootloader does not power the part: AVDD (GPIO71) is an
input and reset (GPIO20) is low. The sequence is AVDD on, reset **asserted**
(GPIO20 low), IOVDD up, then reset released high and 150 ms before the first
transfer. The DT's flag cell (`flags 0`) does not describe the line: the vendor
driver uses the raw gpio API and drives it high to run, low to reset.

The part drives INT low once it has booted, so with GPIO21 as an input and the
vendor's pull-up (`mi_ts_active`) a level of 0 is the milestone-1 signal and 1
means unpowered, held in reset, or dead.

Measured with `0140`: driving MISO high with the pad's own output stage reads
back 1, so no ESD diode clamps the pin and **IOVDD really reaches the part**.
The part still never drives MISO nor pulls INT low, with both read framings,
at 600 kHz and 2.5 MHz, at every AVDD/reset level, after a full IOVDD power
cycle (`0141`-`0146`). What is left is the part's own supply or state, not the
port's pads.

## What the working system says

LineageOS 24 runs on this phone with the vendor driver (`goodix_core.ko` from
`vendor_dlkm`) and logs `brl_dev_confirm: device connected`; its sysfs reads
the part (`rom_pid:BERLIN`, `config_version:46`). Its SPI frames, captured
with `tracefs` (`/sys/kernel/tracing/events/spi`), are exactly the ones this
driver builds: read `f1` + 32-bit address + `ff ff ff`, write `f0` + 32-bit
address + data, zeros during the read data phase. A plain read of `0x00010014`
returns `42 45 52 4c 49 4e` ("BERLIN") and `0x00010070` returns `0xc1`, so the
part answers reads with no write first.

The input device reports ABS 0..14400 x 0..32000 (the HID service must divide
by those, not by 1440/3200) and the touch IRQ is GPIO21 (GIC 305, `msmgpio`,
edge). Only `pm8350c_l2` is enabled for the touch; `l7` is off in the working
system too.

Conclusion: the frame is right, the part is alive, and what separates this
port from the working system is the transport itself (bit-banged pads versus
the QUP), not the protocol.

The rest of the reference is captured by `tools/android-capture.sh`: dmesg,
logcat, kernel config, FDT, interrupts, iomem, regulators, input devices,
power supply, GPU (Adreno730v3, 220-900 MHz), thermal zones, devfreq (UFS
75-850 MHz) and the module list.

The working reference is LineageOS, which supports this device officially:
`drivers/input/touchscreen/goodix_berlin_driver` in
`LineageOS/android_kernel_xiaomi_sm8450` (branch `lineage-24.0`) is the same
driver, open, and `qcom/mondrian-sm8475.dtsi` in
`android_kernel_xiaomi_sm8450-devicetrees` is its device tree (compatible
`goodix,gt9916S`, same GPIOs and supplies as the live tree). Its read frame,
power order and confirm are what `0141` follows. Its kernel is 5.10.269 and
the shipped `goodix_core.ko` is built for 5.10.160, so the vendor module
cannot be loaded into another kernel to compare. Measured with `0119` (which had the
polarity backwards and no IOVDD): the line read 1 both ways, which is exactly
what a part held in reset looks like.

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

## The SPI transfer (`0122`)

The engine runs FIFO mode, 8-bit words packed four per FIFO word, MSB first,
mode 0, CS0, 1.2 MHz (XO 19.2 MHz / divider 16). Per transfer: CS assert
(`M_CMD0 = 8 << 27`), lengths in `SE_SPI_TX/RX_TRANS_LEN` (in FIFO words),
`M_CMD0 = 7 << 27` for TX/RX, push the TX words, poll `M_IRQ_STATUS` bit 0
(done), 3 (failure) or 5 (abort), drain `RX_FIFO`, CS deassert (`9 << 27`).
`SE_SPI_WORD_LEN` is `bits - 4` (8 bits -> 4); the packing words are
`0x7f8fe`/`0xffefe` (`geni_se_config_packing(8, 4, true, true, true)`).

The vendor touch driver is **not** in the MiCode OSS kernel (`mondrian-s-oss`
only carries mainline's I2C Goodix), but it ships in Android's `vendor_dlkm`
as `goodix_core.ko` (mount it from recovery: `mount -t erofs
/dev/block/by-name/vendor_dlkm /mnt/vd`). It is the **GT9916 (BerlinA)**
driver: `goodix_spi_read` builds `0xF1` + 32-bit big-endian address + three
dummy bytes in one `spi_sync`, and `brl_dev_confirm` echoes eight bytes at
`0x10000`. `goodix_spi_read_bra` is the same with a nine-byte prefix.
`brl_power_on` drives three GPIOs high (3/15/5 ms) and then writes 1 to
`0xC900` (`brl_select_spi_mode`).

## The IOVDD rail, if the part is unpowered

`pm8350c_l2` is an RPMh VRM, so the vote is a TCS command for `ldoc2`. The
RSC node is `rsc@17a00000` (drv-2), `qcom,tcs-offset = 0xd00`, TCS config
WAKE 3 / ACTIVE 2 / SLEEP 2 / CONTROL 0 / FAST 1. The resource address comes
from the AOP command DB (`aop_cmd_db_region@80860000`, 0x20000; entries are
`{u8 id[8], u32 priority[2], u32 addr, u16 len, u16 offset}`, key `"ldoc2"`).
Measured with `0131`-`0143`: the command DB answers `ldoc2` = `0x42c00` and
`ldoc7` = `0x41300`; both votes land and the read-back through the same TCS
returns `0x80000001` (enable) and `0x80000708` / `0x80000bb8` (1800 / 3000 mV).
`ldoc7` is the rail Lineage's tree leaves commented as the touch's AVDD feed. Behind that
address the VRM has +0x0 voltage in **millivolts** (`DIV_ROUND_UP(uV, 1000)` in
the vendor driver, so 1800), +0x4 enable (1) and +0x8 mode (PMIC5 LDO HPM is
**7**, not the DT's RPMH mode 4).

The vote must go to an **ACTIVE** TCS. `qcom,tcs-config` is `<WAKE 3, ACTIVE 2,
SLEEP 2, CONTROL 0, FAST 1>` and the driver assigns offsets in that order, so
TCS 0-2 are WAKE and the first ACTIVE TCS is **3** (`0xd00 + 3*672`). A command
left in a WAKE TCS is applied when the AP votes for sleep, which never
happens here, so the rail never moves.

The RSC is the **2.7** layout: TCS 672 bytes, commands 20 apart, `CONTROL`
0x14, `STATUS` 0x18, `CMD_ENABLE` 0x1C, `CMD_MSGID` 0x30, `ADDR` 0x34, `DATA`
0x38, `CMD_STATUS` 0x3C, `RESP_DATA` 0x40. Mainline's 3.0 offsets (stride 24,
MSGID 0x34) write past every command: `CMD_ENABLE` at 0x2C reads zero, the
completion poll passes instantly and nothing reaches the PMIC. The trigger is
also not `CONTROL = 1`: clear TRIGGER (bit 24) and ENABLE (bit 16), write
ENABLE, then ENABLE|TRIGGER.

## The layers, in the order they have to work

1. **The IOVDD rail.** `vdd-supply` is `pm8350c_l2`, an **RPMh VRM**
   (`qcom,rpmh-vrm-regulator`, resource `ldoc2`, 1800 mV), not an
   SPMI-driven LDO: it needs an RPMh (RSC, `apps_rsc@17a00000`) vote, which
   `0131`/`0132` implement. The shim's SPMI is read-only by design, so it
   cannot set it.
2. **TLMM pins.** Reset (20) low while AVDD settles and IOVDD comes up, then
   high; AVDD enable (71) high; IRQ pin (21) as input with the vendor's pull-up.
   The pin
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
5. **Goodix over SPI.** Not the I2C register protocol: Goodix's SPI parts use
   a frame of `0xF1` (read) or `0xF0` (write), the register address as 32-bit
   big endian, and for a read three dummy bytes, all inside one CS frame
   (`drivers/hid/hid-goodix-spi.c` upstream). Data starts at byte 8. The
   Berlin family answers a memory echo at `0x10000` (write eight `0xAA` bytes,
   read them back), which proves power, reset and framing in one transfer;
   the classic product ID is at `0x8140`.
6. **HID wiring.** `MondrianHIDTouch` already publishes a digitizer service
   (`0048`); feed it from the touch thread with `IOHIDEventCreateDigitizerEvent`
   style collections in the same way `MondrianHIDButtons` feeds keys.

## Milestones, each one testable in a single boot

1. AVDD, IOVDD and reset, no SPI traffic: a part out of reset pulls IRQ
   (GPIO21) low within 150 ms; the probe prints the level. A level of 1 points
   at the rail, the reset line or the part.
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
- **SPI mode matters**: mode 0, MSB first. Bit-bang it at about 600 kHz until
  the echo answers; the part tolerates 15 MHz once the framing is right.
- **The reset line is active low**, whatever the DT's flag cell says: the
  vendor driver drives it high to run and low to reset, so an "asserted high"
  sequence holds the part in reset and looks exactly like an unpowered part.
- **The VRM mode is the PMIC5 one**: 7 = HPM for an LDO, not the DT's RPMH
  mode 4. `CMD_MSGID_LEN` is 8 in rpmh-rsc, and the voltage register takes
  millivolts, not a selector index.
- **The RSC layout is 2.7 on this SoC** (the vendor tree has no 3.0 table).
  Using mainline's newer offsets fails silently: every write lands in the
  wrong register and the TCS never triggers.
- **The touch IC is a GT9916** (`goodix,gt9916`, "BerlinA"), not a
  register-compatible gt9xx: the id register at `0x8140` may not exist, the
  liveness test is the eight-byte echo at `0x10000`.
