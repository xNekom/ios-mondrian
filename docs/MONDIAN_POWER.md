# Battery, heat and idle

The port boots to SpringBoard with the GPU drawing, shows a battery level in the
status bar, and still gets hot. Nothing on the AP turns charging on or off, so
the level is a measurement and the charger is the bootloader's business. Both
are measured here, not guessed. This is the work list for
`docs/MONDIAN_PORT.md` §5. It also covers the two other PMIC blocks the port
drives: the thermal sensors and the haptics driver.

## Battery

**There is no SPMI fuel gauge on this board.** `pm8350b@3` carries only the
temp alarm, PBS, pinctrl, BCL, haptics and AMOLED blocks; the charger is
`qcom,battery_charger`, a child of `pmic_glink` on the ADSP's
`PMIC_RTR_ADSP_APPS` rpmsg, and the percentage normally comes from ADSP
firmware that XNU never starts (`docs/MONDIAN_REFERENCE.md`).

What the AP can read over SPMI, through PMK8350's VADC (peripheral `0x31`,
register base `0x3100`, mapping `0x0c42d000`; arbiter v7 layout in
`shim/spmi.c`). The ADC itself sits on SID 0 and an `ADC_APP_SID` write picks
the PMIC whose channel is converted - 3 for the PM8350B, which is why the codes
below read `0x3xx`:

| channel | ADC | channel code | prescale | use |
| --- | --- | --- | --- | --- |
| `pm8350b_vbat_sns` | ADC7 | `0x38f` | 1/3 | pack voltage → percentage |
| `pm8350b_usb_in_v_div_16` | — | `0x311` | 1/16 | `ExternalConnected` |
| `pm8350b_chg_temp` | — | `0x310` | — | `Temperature` |

Pack capacity is **5160 mAh** (`M11A_5160mah` in the vendor model), not
sweet's 5020. Measured against the vendor kernel (an OrangeFox boot, where the
gauge answers): `charge_full` 4900 mAh, `voltage_max` 4.42 V, `cycle_count` 9,
and **3.701 V reads 18 %** while charging at 229 mA. The board's `battfix`
table is those anchors plus the device tree's 3.35 V shutdown point
(`3350:0,3701:18,4420:100`); the table it replaced (4.15 V full, 3.80 V = 36 %)
read the same pack as 1 % on iOS. With the new one the same pack reads **20 %**
at 3.724 V, which is where Android's 18 % at 3.701 V puts it.

What the port publishes (`MondrianPowerSource`, sampled once every 2 s by the
SPMI thread): `BatteryInstalled`, `CurrentCapacity`/`MaxCapacity` **in mAh**,
`ExternalConnected` and `IsCharging` from `usb_in_v_div_16` (a cable is the
only charger fact the AP has; there is no charge-status register to read), and
the `AppleRaw*` pair plus the legacy `IOBatteryInfo` dictionary, because that
is what iOS 16's status bar reads.

`MaxCapacity = 100` with a 0..100 percentage looks right and is not what powerd
uses; with the mAh pair the icon tracks the value. One bad ADC sample is enough
to spoil it for the rest of the boot - 816 mV read once, the curve answered 1%,
and the icon stayed there - so the reader range-checks vbat (3.0-4.6 V) and
drops anything outside. The ceiling is 4.6 V, not the 4.4 V a single cell
usually sees: a full pack on a charger reads 4.42 V, measured 2026-11-11, and
at 4.4 every sample of a charging phone was dropped, nothing was published and
the status bar drew the empty battery with the red sliver that means "no
data". The cable is read before the level so a dropped vbat sample cannot
freeze `ExternalConnected` either.

One sample is not a level either: the pack sags with the load and 20 mV of that
is three points of this curve, so the value is smoothed with alpha 1/4 and the
published percentage keeps its number until the reading is two points away. A
steady 3.86 V walked 68-71 % before that.

`keys` on the USB channel answers with the button poller's state and one live
read of both registers (`pon`, the volume-up pin), which tells a dead button
from a dead bus: the poller shares the arbiter with the conversion, and a
collision is a busy bus, not a fault — the code that treated one as fatal ended
button polling for the rest of the boot.

### Reading the VADC

`mondrian_spmi_adc_mv(sid, chan, div)` and the live `sa SID CHAN DIV` command
over the USB channel share one path; `sav` is the same conversion with its
internals on the ring (the seven writes, STATUS1, the data bytes). The channel
number is the **low byte of the device tree's `reg`**: this tree packs the PMIC
in the high byte, so `pm8350b_vbat_sns` reads `<3 0x8f>` (SID 3, channel 0x8f)
and `pmk8350_die_temp` reads `<0 3>` (SID 0, channel **3**, not the 6 that
mainline's ADC5 binding numbers it). A wrong channel does not read junk: the
arbiter sets its fault bit and the driver prints `adc conversion fault`. ADC7 has no
polling mode, so the reader sleeps `MONDRIAN_SPMI_ADC_US` (5 ms) after the
writes and then requires STATUS1 `EOC` set with `REQ_STS` clear and no fault
bit: polling earlier returns the previous conversion, which is where 816 mV,
3.2 V and 11 V in one series came from. `DATA0` (`0x50`) is the **low** byte and
`DATA1` (`0x51`) the high one -- the old kernel builds `(byte 0x51) << 8 |
(byte 0x50)`, and swapping them moves a junk low byte into the high one. A
sample is published only when two conversions agree (120 mV for vbat, 800 for
vbus). The divider is not a register: it comes from the channel's
`qcom,pre-scaling`, 3 for `vbat_sns` and 16 for `usb_in_v_div_16`, and one code
is 1875 mV / 28900. A cable counts as present above 4.3 V and gone below 4.0 V,
the gap being what keeps the icon from flapping.

### Die temperatures

Every PMIC answers its own die temperature on channel 3 of its own SID
(`pmk8350_die_temp` = `<0 3>`, `pm8350` `<1 3>`, `pm8350b` `<3 3>`,
`pmr735a` `<4 3>`). `tools/usb-ring.py temp` prints the pmk8350's, and
`sa SID 3 1` reads any of them. Measured with the cable attached and the phone
idle: SID 1, 3 and 4 answer 673, 664 and 655 mV, i.e. 63, 59 and 54 °C, while
SID 0 (the ADC's own PMIC) answers 794 mV, 124 °C — double the others. All five
`die_temp` channels declare the same `qcom,pre-scaling` (1 1), so this is not a
missing divider.

**SID 0 reads the right channel but is not a temperature.** The pmk8350 owns
the ADC and answers its own die_temp on channel 3 like the others. A sweep of
all sixteen channels of that SID shows references at 1226 mV (channel 1) and
1915 mV (2 and 7), floating pins at about 40 mV (4-15) and channel 3 alone in
between -- so channel 6, which mainline's ADC7 table calls `die_temp`, is a
dead pin here (58 mV) and must not be used. What the channel does answer
tracks the three PMICs (794 to 772 mV as the phone cooled, the same 22 mV they
lost) but sits about 155 mV high: 113 °C on a phone the vendor kernel puts at
34. `temp` therefore prints SID 1, 3 and 4 in degrees and SID 0 as a voltage,
labelled as a value that moves but is not a temperature.

The vendor's own VADC agrees the channel works in its hands
(`in_temp_pmk8350_die_temp_input` = 34.1 °C on the same PMIC), so this is the
ADC's own-die path and not a broken sensor: it is the one channel where the
port knows the reading is off and by how much, and nothing depends on it.

Cold and charging, the vendor reads 36.5 (`pm8350`), 40.6 (`pm8350b`) and
35.8 °C (`pmr735a`); our VADC reads 59-63 °C for the same three on a phone that
has been in iOS for half an hour with the panel on. Part of that is real (iOS
does not throttle anything yet) and part may be the 0.5 °C/LSB scale, so treat
SID 1/3/4 as monotonic until a same-moment A/B exists. The reading is
quantised in 0.5 °C steps (1 mV) and wanders 1 °C over minutes; the charger
PMIC is the one to watch.

Cold and charging, the vendor reads 36.5 (`pm8350`), 40.6 (`pm8350b`) and
35.8 °C (`pmr735a`); our VADC reads 59-63 °C for the same three on a phone that
has been in iOS for half an hour with the panel on. Part of that is real (iOS
does not throttle anything yet) and part may be the 0.5 °C/LSB scale, so treat
SID 1/3/4 as monotonic until a same-moment A/B exists. The reading is
quantised in 0.5 °C steps (1 mV) and wanders 1 °C over minutes; the charger
PMIC (`sa 3 3 1`) is the one to watch.

### The SoC's own sensors (TSENS)

Two `qcom,tsens-v2` blocks of sixteen sensors each: TM at `0xc263000` and
`0xc265000`, SROT at `0xc222000` and `0xc223000`. Sensor *n* is at TM + `0xa0` +
4*n*, the code in bits 11:0 (sign in bit 11) and VALID at bit 21; `TM_TRDY` is
at `0xe4` and the SROT CTRL register at +`0x4`. The block is already enabled by
the time we run: CTRL reads `0x9d67fff9`, whose low bits are exactly mainline's
EN (bit 0) plus the sixteen per-sensor enables (bits 3-18), and TRDY bit 3 is
set.

`tools/usb-ring.py tsens` logs all 32 sensors, one flushed line each (`MONDRIAN
TSENS: <block>.<n> code <c> valid <v> raw <hex>`), so a read of an unclocked
block cannot be mistaken for a hang. Measured 2026-11-16 with the phone idle in
iOS: every sensor `valid 1`, codes from 410 to 463, block 0 the warm one.

Those codes are **not degrees**. `tsens.c` turns a code into °C with
`(code * 1000 - offset) / slope`, and both numbers are per-sensor calibration
from the SoC's efuse; the live device tree carries no calibration cells (no
`qfprom`, no `nvmem-cells`), and mainline's fallback (`slope 3200`, offset 0)
would put these codes at 128-145 °C, which is impossible here. The vendor gets
that calibration from a source outside the AP's device tree.

Two things make the codes usable anyway. The vendor's tree maps every zone to a
controller and a sensor index (`thermal-sensors = <&tsens0 N>`, where phandle
`0x5f` is `@c263000` and `0x6d` is `@c265000`): block 0 carries `cpuss-0..3`
(N 1-4), `cpu-1-0..8` (5-13) and `gpuss-0/1` (14-15); block 1 carries
`cpu-0-0..3` (1-4), `ddr` (9), `mdmss-0..3` (10-13) and `camera-0/1` (14-15).
And an idle pair of reads against the vendor's cold numbers fits a straight
line of **about 0.1 °C per code** (residual ±2 °C): with `gpuss` at 40.5-41.3 °C
reading 416-424 and `cpu-0` at 43.0-43.8 reading 434-446, `T ≈ code/10 - 1.6`.
So `tsens` prints `~24.6 C` next to each code, with the tilde: it is a fit that
gates a thermal decision, not a calibrated degree.

### Thermal pressure

The sensors drive something. A thread samples the hottest block-0 sensor twice
a second and caps the CPU through the EPSS governor: at 62 °C every domain is
held to three fifths of its rows, at 72 °C to the lowest row, and below 55 °C
the ceiling is released, with the same band as hysteresis so a phone sitting on
the threshold does not flap. The governor keeps running underneath, so releasing
gives the frequency back to the load instead of to a value chosen here.

`tools/usb-ring.py thermal` prints the decision and the p-states behind it
(`thermal 45.1 C level 0 d0 4/14 806 MHz …`) and each change is one ring line
(`MONDRIAN THERM: 63.4 C level 1 capped`). `mondriantherm=0` turns the loop off
and `thermalthr=N` moves the first threshold to N °C (hard cap at N+10, release
at N-7), which is how the mechanism is exercised on a phone at 40 °C.

Measured 2026-11-16 on a boot that runs iOS to SpringBoard: at 63.4 °C the
level-1 cap landed on three fifths of each domain's rows — `domain 0 row 13 -> 8
(1228 MHz)`, `domain 1 16 -> 10 (1766 MHz)`, `domain 2 19 -> 12 (2246 MHz)` —
and at 51.0 °C it released and the governor climbed again (`domain 0 8 -> 9`).
With `thermalthr=30` the same loop takes level 2 on a 40 °C phone and `thermal`
reports every domain at row 0 (300/633/787 MHz) with `cap 0`.

`tools/usb-ring.py burn N` keeps one core busy for N seconds from a kernel
thread (`delay()` in a loop), because the port cannot run a spinner in userland
yet. One core is not a load test: 60 s of it moved the hottest reading from
40.4 to 42.0 °C, inside the ±1 °C the estimate wanders by itself, which is why
the cap is verified by the boot's own load and by moving the thresholds.

### The charger is behind the ADSP

`qcom,battery_charger` hangs off `qcom,pmic_glink`, and `pm8350b@3` in the live
tree has no `chgr@1000` node at all. The AP's APID table has 540 entries and
none is `ppid 0x310` (SMB5, SID 3, page 0x10); `sf 0x310` answers that over the
USB channel. Adding the entry by hand is not a way in - `smw APID MAP OWNER`
wedges the arbiter, measured twice, and the SPMI command thread never returns -
so this AP cannot read the charge status or the input current limit, and cannot
turn charging on. VBUS and vbat are the only charger facts available.

What remains:

1. The pack does reach full: measured 2026-11-11 with the cable in, iOS
   running and the panel on, vbat sat at 4.42-4.43 V for minutes, which is a
   full cell on a charger. Whether the AP is charging it or the charger the
   bootloader set up is still running is not established; blank the panel,
   watch vbat for ten minutes and pair it with `sa 3 0x11 16` to tell the two
   apart.
2. A real charger driver means `pmic_glink` (ADSP firmware and an rpmsg
   protocol), which is the same piece `docs/MONDIAN_REFERENCE.md` lists as
   absent; nothing on the AP side substitutes for it.

## Heat

**The heat is static, not load.** In the last two ring dumps the boot CPU's
sampled PC is inside `_machine_idle` (WFI) in 43/62 and 34/49 samples (~69 %),
and the busiest window-server thread is at 0-3 % CPU once SpringBoard has
settled (`MONDRIAN UI: sample …` lines). In order of contribution:

1. **The GPU subdomain stays powered, clocked and held for the whole boot.**
   The probe votes the mx/cx/mxc/gfx rails (0x1a0), clears the CX and GX GDSC
   collapse bits, starts the GMU and the CP, and nothing releases any of it:
   no IFPC, no GMU power collapse, no unvote, no hold drop. The command line
   also used to pin the GMU's default vote to index 13 (900 MHz); the board now
   leaves kgsl's index 2 (285 MHz), which the frame-rate work measured is not
   the limit. Either boot without the GPU (`gpu=0`) or add a release after
   `MondrianGPUStart()` that unvotes the RPMh batch, sets `GDSC_SW_COLLAPSE` on
   both GDSCRs, stops the SQE and drops the hold. The GPU is needed for the UI,
   so this is the release path, not `gpu=0`.

   Two attempts, and what each proved (`0317`, `docs/MONDIAN_GPU.md`):

   - **Dropping the hold on a running system works.** `0317` adds
     `gpukeep 0|1|2` on the USB channel; `gpukeep 0` (kgsl's raise-before and
     drop-after, plus a 2 ms wait after the raise) survives 45 s idle and still
     draws a Control Center frame. The boot-time death of `gpukeep=0` is the
     first client access, not the mode itself.
   - **Dropping it when the panel blanks does not.** A release tied to the blank
     faults within seconds: submissions keep arriving while the panel is black
     (`MONDRIAN GPU: uc prog seq ...` still prints after the blank), one of their
     writes reaches a collapsed core, and the CPU takes a data abort (console
     `KDBRT: esr 0x96000047`, `far 0xffffffa0...`) with the panel stuck black
     until a reset. The release has to bracket the *submit* path -- every ring
     write as well, not only the client's register reads -- before a timer, a
     blank or a frame may drop the hold.
2. **Brightness, and the MDSS idle path.** Measured 2026-11-09: the power key
   reaches SpringBoard and the compositor stops presenting (`present 0/s`,
   `panel 0/60 sampled ticks changed`). `0302` turns that into a black panel;
   `0303` makes it follow the user: the power key blanks it on the press itself
   (the lock animation's frames are dropped for 1.2 s), the fallback is
   `mondrianfb_blank` seconds without a present (the board sets 30), and the
   first frame after a key or a touch wakes it; a touch or wake also gets five
   seconds of grace before the timer can blank a still lock screen or a
   launching app, and a lone housekeeping frame does not wake it. So a
   sleeping AMOLED no longer shows the last frame. The DCS write exists
   (`0305`, `usb-ring.py bl LEVEL`: DCS `0x51`, max `0xfff`, inverted DBV),
   but iOS does not drive it: the Display & Brightness slider moves nothing.
   The MDSS/DSI driver would also stop the 120 Hz timer and the full-canvas
   rescale (`docs/MONDIAN_PORT.md` §3).
3. **The EPSS rows are no longer pinned** (`0299`): `cpufreq=2` runs a
   governor that follows each cluster's busy fraction from the idle hook
   around WFI (`processor_idle`, sampled at 50 Hz), so a quiet cluster reaches
   its bottom row in about two seconds. A 690 s SpringBoard boot logs domain 0
   between rows 4 and 6 (806-1056 MHz) once the UI is idle; the top rows appear
   only in short bursts. What remains is core power collapse:
   idle is WFI only, with no `cpu_idle_notify` consumer beyond that accounting
   (the A510 at Aff1 0 is parked with the firmware,
   `docs/MONDIAN_PORT.md`). `cpufreqrow=N` pins row N for a one-boot
   experiment and `cpus=4` stays the cheap check.

Suspend (S2R) is a project of its own and would not cool anything today:
nothing registers `IOPlatformSleepAction`, nothing calls
`setSleepSupported`, and `ml_arm_sleep` has no caller, so a
`IOPMSleepSystem` would suspend tasks with the panel and GPU still on and no
wake source. It needs a platform sleep driver, PSCI `SYSTEM_SUSPEND`, GIC
save/restore with wake masks, `CNTVOFF`/`CVAL` save, PMIC wake and an RPMh
DDR self-refresh vote.

## Haptics

The vibrator is not an I²C part. SM8475 drives an LRA from the PMIC's HV
haptics block on `pm8350b@3`, three SPMI pages (`reg = <0xf000 0xf100 0xf200>`):
CFG at 0xf000 (enable 0x46 bit 7, VMAX 0x48 = mV/50, play 0x4c = source | 0x80,
autoresonance 0x63 bit 7), PTN at 0xf100 (waveform FIFO at 0x20 and the
direct-play amplitude at 0x26) and HBST at 0xf200 (read-only boost status,
0x46 bit 7). The I²C scan of a vendor boot has no haptic address, and
the vendor's three matching modules (AW86927, AW862xx, QCOM_HV_HAPTICS) are
`=m` because only the last one matches this board.

**The PPID carries the SID.** A peripheral is `(sid << 8) | page`, measured with
`tools/usb-ring.py spmimap`: the three pages above are `0x3f0`, `0x3f1` and
`0x3f2` — APID 465 and 466 are owner 0 (this AP), while `0x3f2` is APID 400,
owner 3, the charger firmware. Addressing the block as `0xf0` finds nothing,
which reads exactly like "the block is not there". `mondrian_spmi_reg_read()/
reg_write(ppid, reg, val)` are the primitives, gated on the owner bits, because
a write to a channel another EE owns is refused by the arbiter. Reads are not
restricted the same way (`qcom-hv-haptics.c` reads HBST on every play), and
`mondrian_spmi_reg_read_raw()` exists for that one page.

The boost is the PMIC's own PBS sequencer, not an HBST write and not the enable
bit: PMK8350 SDAM `0x9d00` byte `0x42` selects on (`1`) or off (`2`), then byte
`0xe5 = 1` triggers it. CFG 0x46 bit 7 only enables the module. The vendor's
`qcom,pbs-client` handle is for the charger ISC event, not for this haptics vote.

`tools/usb-ring.py haps` walks the block one register at a time and stops at the
first one that does not answer, `hapr BLOCK REG` reads a single byte and `hapw
BLOCK REG VAL` writes one. The first boot that read it (16:45) reported the
state the bootloader left: `cfg-rev 0x00 ptn-rev 0x02 status 0x04 hpwr 0x00
fault 0x00 vmax 0x1c amp 0xff play 0x01` — the block answers, no fault, PTN
revision 2 (the vendor's own log agrees), the direct-play source selected and
idle, VMAX at 1.4 V, and `hpwr` at 0, which the vendor's masks read as
`HPWR_DISABLED`: the PMIC's boost is not up. The vendor reads two bytes from
0x00 and takes the second, so its CFG revision is register 0x01, not 0x00:
measured 0x02, and PTN 0x01 is 0x02 too. That pair is the vendor's **HAP520**
(cfg V2 + ptn V2, PM8350B), not HAP525_HV.

**Measured: the AP can configure the block, but a direct HBST write is
forbidden.** The vendor kernel reports `HAP_HBST 0x1` and the live map puts that
page on the charger firmware (owner 3). An older build's `vib 100 64 2` wrote
HBST 0x46 and never answered; neither did any later command. The current series
keeps HBST read-only: `hapw` refuses block 2 and `vib`'s third argument is
force-VSET, not a boost vote.

`0413` takes the vendor's actual boost path: owner-gated writes to SDAM `0x9d00`
bytes `0x42` and `0xe5`, then a read-only poll of HBST. `hapb 1` performs just
that vote, `hapr 3 REG` reads the SDAM, and `haps` includes both pages. `0414`
adds `hapv MV` so VMAX can be changed from the live ring without a rebuild;
the command is capped at 2000 mV. The first boot must show `spmimap` PPID
`0x09d` with owner 0 before `hapb` is used; a foreign owner closes this path
without a store. Measured 2026-11-25: APID 428 answers PPID `0x09d` with
owner 0. An off→on vote (`hapb 0`, then `hapb 1`) lifts `hbst-vreg` to `0x80`
and `hbst-status4` to `0x01`; a `vib` votes it off again, so a zero read after
a play only means the driver already dropped the boost. The SDAM bytes read
back as zero even though the trigger runs, so the boost status is the proof.
Measured again 2026-11-26: `hapb 0`, `hapb 1`, `haps` read `hbst-vreg 0x80`,
then `vib 120 64` logged `playing amp 0x40`, `stopped` and `buzz 120 ms ...
sent`; the ring holds the verdict even when the host's two-second command
timeout expires first.

`0421` gives the drive its open-loop period: CFG 0x5c is the high nibble and
0x5d the low byte (the two defines were swapped), and the play writes the DT's
5882 us as `0x498`. It forces VREG-ready only while the boost is up; bit 1 of
VSET belongs to HAP525_HV, which this part is not. The play clears the fault
latch and disables auto-resonance, as the stock's `DIRECT_PLAY` path does.
`impedance 0x00` is not a measurement on this part: register 0x0e exists only
on HAP525_HV, and `status 0x04` is the multiplexed `STATUS_DATA_MSB`, not a
fault: fault reads 0. SDAM `0x46/0x47` returns `0x04/0x6E`, a measured count distinct from
the open-loop `0x498`, so the block does see the LRA. Measured: two 2 s tones
at `0xff` produced no motion (felt), so direct play is silent on this LRA; the
stock PTN click is the next drive, and its first attempt is the trap below.
**2700 mV is unsafe in
this sequence:** the following readback returned corrupted CFG/TLRA/HBST values,
`vbat 825 mV out of range` appeared, and SpringBoard stopped presenting
(`fps 0`, `DL total 0/0`). Do not repeat it.

`vib [ms [amp [force]]]` plays a constant tone: a deliberately low 1.25 V VMAX,
amplitude 0x40 of 0xff and 100 ms by default for the first drive. It sets
sine drive, disables auto-resonance, clears faults, starts PLAY and then votes
hBoost; stop clears PLAY, leaves EN_CTL set and votes hBoost off two seconds
later. It logs impedance and status 20 ms in. The DT's `effect_0..5` tables are
a click waveform, not filler: eight samples of (amplitude, period, f_lra_x2) =
(0x1f,0,0) (0x3f,0,0) (0x5f,0,0) (0x7f,0,0) (0x17f,0,0) (0x15f,0,0)
(0x13f,0,0) (0x11f,0,0), written as 24 bytes at PTN 0x34 with TLRA 0x30 =
period/5 and the source field set to PATTERN1.

`0433` implements that click as `hapclick [mv]` (default 3600 mV, the effect's
VMAX) and votes the boost up before forcing VREG-ready, which is the vendor's
order rather than `vib`'s. Measured 2026-11-26: the first live `hapclick 1800`
never answered and took the ring command thread with it; ICMP to 192.168.7.2
still answered, so the kernel itself stayed up and one SPMI transaction is the
suspect. The PTN block had never been written past 0x26 before this test.
Replaying all 24 bytes in one command hides which register did it: stage the
sequence with one `hapw 1 REG VAL` per line, first PTN 0x30/0x31, then each
0x34.. byte, with `haps` between groups. The cycle log names the last command
that ran, so the register that wedges is the one after the last entry that
answered.

The walk settled the block itself: all 24 bytes at PTN 0x34, TLRA
0x30/0x31 = 0x535, VMAX 0x48 and a PATTERN1 play complete and answer on a live
boot; the block does not wedge on the pattern or the play. The first click's
`fault 0x01` is `HPWR_RDY_FAULT`: it played without the boost. `hapb 1` after
`0x66=0x07` raises `hbst-vreg` to `0x80` and `hapb 0` drops it to `0x00`;
`hbst-status4` bit 0 is already 1 with the boost off, so it is not proof of the
rail. Gate the play on `hbst-vreg == 0x80` and keep `hpwr 0x0b` (READY is 3)
as the in-play check.

Measured during the 53 ms PATTERN1 play: CFG 0x4c reads 0x82 (engine active),
fault stays 0, and HPWR 0x0b stays 0 in every sample; the vendor treats
HPWR_DISABLED as a valid terminal state, so that alone does not prove the rail
is down. `hbst-follow` reads 0xe0 (hardware follow), the SDAM status pair
0x46/0x47 stays 0x0470 before and during drive, and impedance 0x0e stays 0
because the register is HAP525_HV-only. Motion is still unproven by registers,
so the next evidence has to be mechanical (feel, or a current/accelerometer
trace).

The HAP520 impedance path is the vendor's `haptics_detect_lra_impedance`:
square drive, 10 V VMAX, no headroom, a DIRECT_PLAY amplitude sweep, and the SC
flag at 0x0c brackets the LRA. Measured 2026-11-26 with amplitudes 0x10 to
0xff: SC stayed 0 at every step. That zero is not conclusive, because the
HAP520 branch first triggers the PBS ISC event (250 mA), this port cannot
trigger PBS events yet, and the default SC threshold is unmeasured.

## Measuring it

One change per boot, same `mondrianreset`, and read the ring
(`tools/mondrian-boot-log.sh`, `tools/decode-mondrian-log.py`):

- `gpu=0`: proof is the absence of any `MONDRIAN GPU:` line; if the probe
  still reports `gpucc cx … on`, the bootloader left the GPU up and this alone
  saves nothing.
- `cpus=4`: `MONDRIAN CPU: requested=4 selected=4`.
- no `cpufreq=2`: no `MONDRIAN CPUFREQ: governor` line; `cpufreq=0` leaves the
  bootloader's rows alone and `cpufreqrow=N` prints the row it pinned.

Temperature itself has no in-XNU reader. Measure it after a fixed-duration
boot from Android recovery (`/sys/class/thermal/thermal_zone*/temp`,
`gpuss-*`/`cpuss-*`, and `/sys/class/power_supply/battery/temp`), or with an
IR thermometer on the same spot. An in-OS number needs the PMIC ADC read from
the battery work above.
