# Battery, heat and idle

The port boots to SpringBoard with the GPU drawing; what it does not have is a
battery reading, and it gets hot. Both are measured here, not guessed. This is
the work list for `docs/MONDIAN_PORT.md` §5.

## Battery

**There is no SPMI fuel gauge on this board.** `pm8350b@3` carries only the
temp alarm, PBS, pinctrl, BCL, haptics and AMOLED blocks; the charger is
`qcom,battery_charger`, a child of `pmic_glink` on the ADSP's
`PMIC_RTR_ADSP_APPS` rpmsg, and the percentage normally comes from ADSP
firmware that XNU never starts (`docs/MONDIAN_REFERENCE.md`).

What the AP can read over SPMI, through PMK8350's VADC (SID 0, peripheral
`0x31`, register `0x3100`, mapping `0x0c42d000`; arbiter v7 layout in
`shim/spmi.c`):

| channel | ADC | channel code | prescale | use |
| --- | --- | --- | --- | --- |
| `pm8350b_vbat_sns` | ADC7 | `0x38f` | 1/3 | pack voltage → percentage |
| `pm8350b_usb_in_v_div_16` | — | `0x311` | 1/16 | `ExternalConnected` |
| `pm8350b_chg_temp` | — | `0x310` | — | `Temperature` |

Pack capacity is **5160 mAh** (`M11A_5160mah` in the vendor model), not
sweet's 5020. Charging state needs the PM8350B CHGR/QBG registers, which are
not in the tree and are not documented by the vendor capture yet: publish
`IsCharging = false` and `ExternalConnected` from `usb_in_v_div_16` until they
are mapped.

What iOS asks for: a subclass of `IOPMPowerSource` (matching is
subclass-aware, so no `AppleSmartBattery` is needed) with
`BatteryInstalled`, `CurrentCapacity`, `MaxCapacity`, `ExternalConnected`,
`ExternalChargeCapable`, `IsCharging`, `AtWarnLevel`, `AtCriticalLevel`,
`Voltage`, `Amperage`, `TimeRemaining` (-1 when unknown), `CycleCount`, and
`Temperature` in centi-°C, flushed with `updateStatus()` so powerd gets
`kIOPMMessageBatteryStatusHasChanged`. Sweet's working copy is
`xnu/patches/0062-sweet-touch-power-battery.patch` (`SweetBattery.cpp`
618-938 and `sweet_spmi.c` 472-599).

Order of work. The first draft of step 1 (`MondrianBattery.cpp`, an
`IOPMPowerSource` subclass publishing 100 %/external before `registerService`,
registered from `KernelConfigTables`) **compiled but did not boot**: with it
the kernel returned to fastboot after 24 s, while the same kernel without it
boots (A/B, same image, same blob). `IOPMPowerSource::init()` does create its
dictionary, so the cause is not the obvious one and needs its own boot cycle;
the patch was withdrawn from the series rather than shipped (a kernel that
does not boot is worse than a missing battery). The code is in the history of
this file's commit.

1. Re-do step 1 with the failing path understood: match `IOResources` the way
   `MondrianHIDButtons` does, publish after `registerService()` instead of
   inside `start()`, and log at every step so the 24 s failure names itself.
2. `bsd/dev/mondrian_spmi.c` with an observer for the three VADC channels
   above; then the percentage replaces the static value.
3. A read-only probe first prints `SPMI adc ppid apid type sub chsel st1 d0
   d1` for SID 0 peripheral `0x31` (ADC5 user registers: STATUS1 `0x08`,
   CH_SEL `0x0a`, DATA0/1) to see whether ABL left a `vbat_sns` conversion
   live. ADC5 offsets come from mainline `qcom-spmi-adc5.c` and are not
   verified on this part yet.

## Heat

**The heat is static, not load.** In the last two ring dumps the boot CPU's
sampled PC is inside `_machine_idle` (WFI) in 43/62 and 34/49 samples (~69 %),
and the busiest window-server thread is at 0-3 % CPU once SpringBoard has
settled (`MONDRIAN UI: sample …` lines). In order of contribution:

1. **The GPU subdomain stays powered, clocked and held for the whole boot.**
   The probe votes the mx/cx/mxc/gfx rails (0x1a0), clears the CX and GX GDSC
   collapse bits, starts the GMU and the CP, and nothing releases any of it:
   no IFPC, no GMU power collapse, no unvote, no hold drop. Either boot
   without it (`gpu=0`) or add a release after `MondrianGPUStart()` that
   unvotes the RPMh batch, sets `GDSC_SW_COLLAPSE` on both GDSCRs, stops the
   SQE and drops the hold. The GPU is needed for the UI, so this is the
   release path, not `gpu=0`.
2. **The panel and MDSS are never blanked.** `MondrianFramebuffer.cpp` has no
   power-state or `RequestPowerChange` path, a 60 Hz vsync timer runs forever
   and every swap rescales the full canvas. Blanking needs the MDSS/DSI and
   backlight driver (`docs/MONDIAN_PORT.md` §3).
3. **All eight cores sit at the top EPSS row** (1804 / 2496 / 2995 MHz) and
   are never lowered; idle is WFI only, with no core power collapse and no
   `cpu_idle_notify` consumer. `cpufreqrow=N` (write a low row in
   `mondrian_cpufreq.c`) and `cpus=4` (keep the two big clusters in PSCI
   reset) are the cheap experiments.

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
- no `cpufreq=1`: no `MONDRIAN CPUFREQ:` line.

Temperature itself has no in-XNU reader. Measure it after a fixed-duration
boot from Android recovery (`/sys/class/thermal/thermal_zone*/temp`,
`gpuss-*`/`cpuss-*`, and `/sys/class/power_supply/battery/temp`), or with an
IR thermometer on the same spot. An in-OS number needs the PMIC ADC read from
the battery work above.
