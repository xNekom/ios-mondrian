# What the working Android exposes, per subsystem

Measured on this phone running LineageOS 24 (kernel 5.10.269, vendor modules
from `vendor_dlkm`), with `tools/android-capture.sh` and `tracefs`. This is the
reference for the subsystems the port has not reached yet: the node, the
address and the userspace interface the working system uses. The touch has its
own document, `docs/MONDIAN_TOUCH.md`.

Keep it as a table of facts, not a plan; the work items are in
`docs/MONDIAN_PORT.md`.

## Buttons

| Key | Path | Details |
| --- | --- | --- |
| Power | PMK8350 PON, SPMI `0-00`, base `0x1300` | `pwrkey`, code 116, IRQ `pmic_pwrkey` (pmic_arb 20382103) |
| Volume down | PMK8350 PON | `resin`, code 114, IRQ `pmic_resin` (pmic_arb 20316567) |
| Volume up | PM8350 GPIO 6 (SPMI `0-02`, base `0x8800`) | active low, code 115, `gpio_keys` input device |
| Long press | PMK8350 PON | `pwrkey-resin-bark`, `pwrkey_bark` |

The PON also owns the reset reasons (`pmic_pon_log`) and the power-off path.

## Battery and charging

- Data path: `qcom,pmic_glink` -> ADSP (`qcom,battery_charger`,
  `qcom,ucsi`), not SPMI.
- `/sys/class/power_supply/battery`: `capacity`, `voltage_now`/`voltage_ocv`
  (uV), `current_now` (uA), `temp` (0.1 C), `charge_full`/`charge_counter`
  (uAh), `model_name` (`M11A_5160mah`), `technology` (Li-poly).
- `usb` (USB_PD), `wireless`, `ucsi-source-psy-...:qcom,ucsi1` are the other
  supplies.
- Shortcut for iOS: stub `IOPMPowerSource` from these values; the real path
  needs the GLINK channel.

## Brightness and display

- Panel: `qcom,mdss_dsi_m11a_42_02_0a_dsc_cmd` (DSC, command mode), from the
  kernel command line.
- Brightness is `bl_ctrl_dcs`: a DCS command to the panel, scale 0..4095
  (`/sys/class/backlight/panel0-backlight`), not a PWM.
- AMOLED rails: `qcom,qpnp-amoled-regulator`, `oledb@fa00` (5.0-8.0 V).
- Display blocks: MDP `ae00000.qcom,mdss_mdp`, DSI ctrl/phy `ae94000`/
  `ae94400` and `ae96000`/`ae96400`, RSCC `af20000.qcom,sde_rscc`; the
  display GDSCs hang off `pm8450_s4_level`.
- `tracefs` has `sde`, `drm` and `kgsl` events.

## GPU

- `Adreno730v3`, node `3d00000.qcom,kgsl-3d0`, `msm-adreno-tz` governor,
  220-900 MHz (table in `/sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies`).
- Firmware: `a730_sqe.fw`, `a730_zap.*`, `gmu_gen70000.bin` in
  `/vendor/firmware`.
- A Metal driver is out of scope for now; the port renders in software.

## Audio

- Card `waipio-mtp-snd-card` (LPASS + ADSP `q6`), 37 PCMs (CODEC_DMA, VA
  macro, MI2S, TDM, USB audio).
- Codec WCD938x over SoundWire (`wcd938x-codec`, `rx_swr_ctrl`,
  `tx_swr_ctrl`, `va_swr_ctrl`).
- Two AW882xx speaker amps on I2C `2-0034`/`2-0035` with reset, irq and
  `spksw` GPIOs.

## Camera

- CAMSS `ac13000.qcom,cam-cpas`, camera clock controller `ade0000`,
  GDSCs over `pm8350c_s2_mmcx_voter_level`.
- Sensors `qcom,cam-sensor0..3` on CCI0/CCI1 (`ac15000`, `ac16000`), with
  MCLK/reset/CCI in the device tree.
- Rails: `CAMERA_ULTRA_AVDD`, `CAMERA_MACRO_AVDD`/`IOVDD` from `pm8350c_bob`,
  `camera_wide_dvdd_ldo` from `pm8350_s12`.

## Connectivity

- WiFi/BT: `cnss2` + `phy0` (QCA6490), firmware under `/vendor/firmware`.
- NFC: `sn-nci` on I2C, irq 347, ven 335, dwl-req 346, clk-req 336.
- IR: `ir-spi` on `a94000.spi`.
- Fingerprint: `goodix_tee` V1.2.01 (`/sys/class/goodix_fp`).

## Storage, sensors, thermal, time

- UFS: host `1d84000.ufshc`, PHY `1d80000`, devfreq 75-850 MHz.
- Sensors: SSC at `/dev/sensors` (`sensors_ssc`, `qti_qmi_sensor_v2`), ADSP
  backed; the kernel exposes no per-sensor sysfs.
- Thermal: 60+ zones (`pa`, `cpuss-*`, `gpuss-*`, `cpu-*`, `aoss-*`), values
  in millidegrees.
- RTC: `rtc-pm8xxx` on the PMK8350 (`rtc@6100`), `/dev/rtc0`.

## Where the raw data is

`tools/android-capture.sh` writes one tarball with dmesg, logcat, kernel
config, FDT, interrupts, iomem, regulators, input devices, power supply, GPU,
thermal and devfreq. The touch frames come from
`/sys/kernel/tracing/events/spi` and are described in `docs/MONDIAN_TOUCH.md`.
Keep the tarball out of git; it is a device dump.
