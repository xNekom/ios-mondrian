# The mondrian touch screen: bring-up plan

The panel's digitizer is a Goodix part on **SPI**, wired to QUPv3 SE4. This
file is the register-level record: what the live device tree says
(`/sys/firmware/fdt`, dumped with `dtc -I dtb -O dts`), what the working
system's driver measures, and what the port has proved with the bit-banged
transport in `bsd/dev/mondrian_touch.c`. The work list entry is
`docs/MONDIAN_PORT.md` §5.

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

The part does **not** pull INT low after reset here: with GPIO21 as an input it
reads 1 against both the internal pull-down and the vendor's pull-up, so its
level says nothing about power. What proves the part is alive is the bus: with
the right pad order the 0xAA boot-option echo at `0x10000` comes straight back
and `0x10014` answers the version block (`0151`).

The earlier runs (`0140`-`0146`) found no answer because the pad order was
wrong: the same frames read zeros at every AVDD/reset level, both read
framings and every speed, and the pad self-test only proved that the SoC drives
its own pins, not that the part was powered.

## What the working system says

LineageOS 24 runs on this phone with the vendor driver (`goodix_core.ko` from
`vendor_dlkm`) and logs `brl_dev_confirm: device connected`; its sysfs reads
the part (`rom_pid:BERLIN`, `config_version:46`). Its SPI frames, captured
with `tracefs` (`/sys/kernel/tracing/events/spi`), are exactly the ones this
driver builds: read `f1` + 32-bit address + `ff ff ff`, write `f0` + 32-bit
address + data, zeros during the read data phase. A plain read of `0x00010014`
returns `42 45 52 4c 49 4e` ("BERLIN") and `0x00010070` returns `0xc1`, so the
part answers reads with no write first.

The part is a **Berlin D**, not a Berlin A: `goodix_get_ic_type` logs
`ic type is BerlinD` and the firmware package calls itself `GT9916R`. That
matters for the frame, because the two generations differ in the read prefix:
Berlin A sends four dummy bytes and takes the data from byte 9
(`goodix_spi_read_bra`), Berlin D sends three and takes it from byte 8
(`goodix_spi_read`). This driver builds the Berlin D frame, and the `tracefs`
capture above is that frame, so the protocol is not where the silence comes
from.

After a power cycle the part always comes back in ROM mode, and the first
thing it answers is the boot-option echo: the driver writes eight `0xAA` bytes
to `0x10000` and reads them back (`brl_dev_confirm`, about 120 ms after the
reset release), then loads the ISP and rewrites the firmware over the same bus
(`0x55` at `0x10000`, `fw_version equal` yet `need to upgrade`). Any probe has
to start with that write, not with a read of `0x10014`.

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

The SPI bus is on **GPIO16-19** with the `qup4` function (TLMM mux value 1,
the group-local function index) and CS0; the touch's reset/IRQ pads (20/21)
are separate. **The order is not the one the tree implies** (measured with
`0151`, confirmed by reading the product id):

| Pad | Signal |
| --- | --- |
| gpio16 | MISO |
| gpio17 | MOSI |
| gpio18 | CLK |
| gpio19 | CS |

With 16/17/18/19 as clk/mosi/miso/cs every read returns zeros; with the table
above the 0xAA boot-option echo comes back and `0x00010014` answers the version
block: `42 45 52 4c 49 4e` ("BERLIN") at the first byte of the payload,
`rom_vid 02 00 04`, `patch_pid "9916R"`.

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

## The report block, from the working system's IC info

`goodix_core.ko` prints the whole `goodix_ic_info` block it reads at `0x10070`
(`print_ic_info` in the working dmesg); that dump is where these numbers come
from. The blob is 193 bytes on this part, config version `0x46`.

| Field | Value |
| --- | --- |
| `touch_data_addr` | `0x00010308` |
| `touch_data_head_len` | 8 |
| `point_struct_len` | 8 |
| `cmd_addr` | `0x00010174`, 16 bytes |
| `fw_state_addr` | `0x00010218`, 92 bytes |
| `fw_buffer_addr` | `0x0001205c`, 4200 bytes |
| `esd_addr` | `0x00010170` |
| panel mapping | 18 x 40, sensor id 255 |

In the packed `goodix_ic_info` the fields sit at fixed offsets:
`misc.touch_data_addr` at 161, `touch_data_head_len` at 165 and
`point_struct_len` at 167, so one 200-byte read recovers them from the part
instead of hardcoding the constant.

A report is an 8-byte head, `touch_num = head[2] & 0x0f`, then `touch_num`
points of 8 bytes (id in the high nibble of byte 0, x/y/w little-endian 16-bit
at +2/+4/+6), then a 2-byte checksum. After reading, write **one zero byte**
back to `touch_data_addr`: that clears the report and releases IRQ (GPIO21,
active low, GIC 305).

## Loading the firmware (the part runs from RAM)

The chip has no firmware of its own: `goodix_core.ko` writes the 223744-byte
image (223736 payload bytes: an ISP stage plus five firmware subsystems) into
it over SPI on every boot, and only then does the part scan. This is the
sequence from `goodix_brl_fwupdate.c` for Berlin D (`CHIP_TYPE_BRD 0x98`):

| Step | Register or address |
| --- | --- |
| ISP code | `0x23800` (`ISP_RAM_ADDR_BRD`), write then read back |
| boot option | `0x10000`, eight `0x55` bytes |
| flash command | `0x12400` (`FLASH_CMD_REG_BRD`), 16 bytes |
| ISP buffer | `0x12410` (`HW_REG_ISP_BUFFER_BRD`) |
| configuration | `0x3E000` (`CONFIG_DATA_ADDR_BRD`) |
| `misctl` | `0xD804` = `0x20700000` |
| watchdog | `0xD040` |
| config id | `0x10076` (`GOODIX_CFG_ID_ADDR_BRD`) |

After the ISP goes in, reset and read `0x10014`: `patch_pid[3..5]` must be
`ISP`. Each firmware chunk (4096 bytes) is written to the ISP buffer with a
16-bit little-endian checksum appended, then a command is written to
`0x12400`: `status 0`, `ack 0`, `len 11`, `cmd 0xBB`, `fw_type`, `fw_len`
(LE16, data + 4), `fw_addr` (LE32) and a byte checksum over bytes 2..10. Poll
until `ack == 0xEE`, wait 50 ms, then until `status == 0xEE`.

The quirks already paid for: the firmware is RAM, so a power cycle loses it;
`goodix_update_prepare` holds the CPU (`0x0002 = 01 00`, read `0x2000` until
three reads agree) before enabling the clocks (`0xD807 = 0xFF`,
`0xD806 = 0x77`, `0xD006 = 0x3C`), and the part only answers the boot option
after a reset pulse of at least 15 ms.

The package itself, checked against `goodix_firmware_m11a.bin` (223744 bytes,
the header says 223736): `size` and a 32-bit `checksum` of the 16-bit words
from offset 8, then a 512-byte header, a subsystem count at `0x1D`, a table of
10-byte entries at offset 42 (`type`, `size` LE32, `flash_addr` LE32, one
reserved byte) and the section data in order from 512. Section 0 is the ISP
(2048 bytes, address `0xffffffff`, ignored: it goes to `0x23800`); sections
1-5 are types 3/2/2/2/2 at `0x1c000` (8192), `0x1000` (12288), `0x4000`
(98304), `0x26000` (98304) and `0x0` (4096).

The sensor config is a second file, not a section of that package:
`goodix_cfg_group_m11a.bin` ends with one 1488-byte group (a 64-byte head
whose U8 checksum and `cfg_len` identify it, then 1424 bytes of body), which
the vendor flashes as type 4 at `0x3E000` **before** the firmware sections.
`tools/mk-touch-blob.py` appends it as table entry 6, sets the count at `0x1D`
to 7 and recomputes the package checksum, because the kernel validates one
contiguous package. Each flash packet carries its own type and address, so
the order of the writes does not matter; the config (`0x3e000..0x3e5cf`) and
the firmware (`0x0..0x3dfff`) do not overlap.

The kernel gets the package without a file system: the 64 blocks in front of
the log ring at the end of `userdata` are reserved for it, `tools/
flash-touch-firmware.sh FIRMWARE.bin [CONFIG_GROUP.bin]` repacks it and writes
it there from recovery with `dd`, and `mondrian_reserved_read()` in
`bsd/dev/mondrian_ufs.c` reads it back. Nothing else in `userdata` moves, and
no sudo is needed.

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

1. AVDD, IOVDD and reset: nothing here proves power by itself. IRQ stays high
   after reset on this part, and the pad self-test only proves the SoC drives
   its own pins. The first real proof is the echo in item 3.
2. GENI init and `GENI_FW_REVISION` read: proves the SE clock and the register
   window.
3. The pad order and the product ID: a read of `0x00010014` returns "BERLIN".
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
- **A QUP's four pads are not in signal order.** The device tree lists
  gpio16-19 for `qup4` without saying which SPI signal each one carries, and
  the obvious guess (16 clk, 17 mosi, 18 miso, 19 cs) reads zeros for ever.
  The measured order on this board is **gpio16 MISO, gpio17 MOSI, gpio18 CLK,
  gpio19 CS**. Do not try to identify MISO by pulling each pad down: the part
  pulls CS up, so the CS pad reads high and looks like a driven output. Sweep
  the 24 assignments and keep the one whose read of `0x10014` starts with
  "BERLIN" — on the first payload byte, because `mondrian_goodix_read()`
  already strips the 8-byte prefix (the raw trace shows it at byte 8).
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
- **The touch IC is a GT9916R, and the driver resolves it to Berlin D**, not
  the Berlin A that the older `gt9916` DTs name; the two differ in the read
  prefix length. It is not a register-compatible gt9xx either: the id register
  at `0x8140` does not exist, and the liveness test is the eight-byte echo at
  `0x10000`.
- **The TLMM bit layout is the sm8450 one**, not the msm8998 one: mux in bits
  2-4, pull in bits 0-1 (0 none, 1 down, 3 up), drive in bits 6-8, output
  enable in bit 9 (`pinctrl-sm8450.c`'s `PINGROUP`). Inside `IN_OUT`, bit 0 is
  the pin level and bit 1 is the output value, so driving a pad and reading it
  back is `write 2`, then `read & 1`.
