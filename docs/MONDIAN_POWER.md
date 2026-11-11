# Battery, heat and idle

The port boots to SpringBoard with the GPU drawing, shows a battery level in the
status bar, and still gets hot. What it cannot do is charge. Both are measured
here, not guessed. This is the work list for `docs/MONDIAN_PORT.md` §5.

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
sweet's 5020.

What the port publishes (`MondrianPowerSource`, ticked from the framebuffer
every 2 s): `BatteryInstalled`, `CurrentCapacity`/`MaxCapacity` **in mAh**,
`ExternalConnected` from `usb_in_v_div_16`, and the `AppleRaw*` pair plus the
legacy `IOBatteryInfo` dictionary, because that is what iOS 16's status bar
reads. `IsCharging` stays false: nothing on this AP can see the charger.

`MaxCapacity = 100` with a 0..100 percentage looks right and is not what powerd
uses; with the mAh pair the icon tracks the value. One bad ADC sample is enough
to spoil it for the rest of the boot - 816 mV read once, the curve answered 1%,
and the icon stayed there - so the reader range-checks vbat (3.0-4.4 V) and
drops anything outside.

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
internals on the ring (the seven writes, STATUS1, the data bytes). ADC7 has no
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

### The charger is behind the ADSP

`qcom,battery_charger` hangs off `qcom,pmic_glink`, and `pm8350b@3` in the live
tree has no `chgr@1000` node at all. The AP's APID table has 540 entries and
none is `ppid 0x310` (SMB5, SID 3, page 0x10); `sf 0x310` answers that over the
USB channel. Adding the entry by hand is not a way in - `smw APID MAP OWNER`
wedges the arbiter, measured twice, and the SPMI command thread never returns -
so this AP cannot read the charge status or the input current limit, and cannot
turn charging on. VBUS and vbat are the only charger facts available.

What remains, in order:

1. Measure whether the PMIC still charges after the jump from fastboot: vbat
   with the panel blanked is the discriminator, and `sa 3 0x11 16` says whether
   the cable carries 5 V.
2. Publish `IsCharging` if that measurement shows a rise, and say plainly that
   a PC port's 500 mA cannot feed a booted phone.
3. A real charger driver means `pmic_glink` (ADSP firmware and an rpmsg
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
2. **Brightness, and the MDSS idle path.** Measured 2026-11-09: the power key
   reaches SpringBoard and the compositor stops presenting (`present 0/s`,
   `panel 0/60 sampled ticks changed`). `0302` turns that into a black panel;
   `0303` makes it follow the user: the power key blanks it on the press itself
   (the lock animation's frames are dropped for 1.2 s), the fallback is
   `mondrianfb_blank` seconds without a present (default 1), and the first
   frame after a key or a touch wakes it; a touch or wake also gets five
   seconds of grace before the timer can blank a still lock screen or a
   launching app, and a lone housekeeping frame does not wake it. So a
   sleeping AMOLED no longer shows the last frame. Brightness is
   still missing: the panel is `bl_ctrl_dcs` (DCS `0x51`,
   max `0xfff`, inverted DBV) and sending it needs the DSI command path. The
   MDSS/DSI driver would also stop the 60 Hz timer and the full-canvas rescale
   (`docs/MONDIAN_PORT.md` §3).
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
