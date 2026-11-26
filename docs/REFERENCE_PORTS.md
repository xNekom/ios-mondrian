# Reference ports and credits

The mondrian half of this repository is a fork of
[dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet). The projects
below are the main donors; the table says what each answers, what the evidence
is, and what may be reused. The per-subsystem docs credit the smaller
references they use. A README claim is not a device proof: the evidence column
separates a device-verified result from code that was only read.

| Project | What it gives | Evidence | Licence |
| --- | --- | --- | --- |
| [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) | the base XNU/shim/root tooling and the sweet patch series | works on sweet; this fork's base | MIT |
| [oosexgang/hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel) | the GLES/GPU path, the Mesa patches, the userland dylibs and the virtual audio HAL plug-in | its phones; the reference behind `docs/MONDIAN_GPU.md` | APSL 2.0 kernel, MIT userland (per its README) |
| [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz) | `SweetSurface`, the `IOMobileFramebuffer`/`AppleCLCD` presenter and the EAGL/OSMesa path | read; `docs/MONDIAN_GPU.md` | no root licence declared; read, do not copy |
| [akshaynexus/OneiOS](https://github.com/akshaynexus/OneiOS) | the VideoToolbox paravirtualization service, the HEVC tile session and the Rust runtime tools | its README marks the iOS 27 tile session host-tested, not booted | no licence file: all rights reserved; read, do not copy |
| [akshaynexus/iOSPlus10](https://github.com/akshaynexus/iOSPlus10) | QCA6490 Wi-Fi, PM8350B hBoost/PBS haptics and Adreno 730 Metal2Vulkan | the repo's plans report built stages; its Wi-Fi audit says the host side has not run on the chip; the haptics PBS sequence raised `hbst-vreg` on mondrian (`0413`), motion pending; its audio path never played and never started the WCD938x | MIT |
| [UniXNU/Adreno740](https://github.com/UniXNU/Adreno740), [UniXNU/AdrenoMetal](https://github.com/UniXNU/AdrenoMetal) | the a7xx GPU driver and the Metal-to-Vulkan frontend | device-verified on the Pad 6S Pro | MIT |
| [qiumochen/UniXNU-zizhan](https://github.com/qiumochen/UniXNU-zizhan) | `PongWifi`: QCA6490 PCIe/MHI/ath11k and Apple80211 on the same SM8475 | network device-verified: WPA2 join, DHCP/HTTPS and roaming; its PCIe cold-link sequence also reached Gen2 x1 and endpoint `17cb:1103` on mondrian (`0415`) | BSD-2-Clause-Patent; `PongAth11k.c` derives from Linux ath11k (GPL-2.0), check before mixing |
| [Chengdong-Yu/pong-wifi](https://github.com/Chengdong-Yu/pong-wifi) | the QCA6490 transport `UniXNU-zizhan` vendors, standalone: the SMMU takeover in `PongWifiPlatform.cpp` and the host `tests/mhi_host_test.c` | read; Pong (Nothing Phone 2) is the same SM8475 and QCA6490, and this is the upstream of the zizhan result above | BSD-2-Clause-Patent |
| [Denis0x00/UniXNU-j716f](https://github.com/Denis0x00/UniXNU-j716f) | a QCA6390 (same ath11k/MHI/BHI family) taken to `en0`, `wifid` and a host `wpa_supplicant` | listed device-verified on the tracker (`unixnu.com/devices/j716f`, iPadOS 17.7.11); code not read here | not checked |
| [Mesa](https://gitlab.freedesktop.org/mesa/mesa) (`freedreno`, `turnip`) | the GLES driver on the Adreno and the Vulkan driver behind Metal2Vulkan | `FD725` GLES and `Turnip Adreno (TM) 725` measured on the phone | MIT |
| [DenialOfGravity/ios-redfin](https://github.com/DenialOfGravity/ios-redfin) | native `HakiosMetal`, the Venus video encoder/decoder, MPSS/IPA/QRTR, camera and sensor services | device-verified on the Pixel 5 | MIT |
| [Emilelu/UniXNU-mondrian](https://github.com/Emilelu/UniXNU-mondrian) | a sibling port for the same phone: boot args, IOSurface pitch, PMIC-GLINK battery | read 2026-11-20; facts only, no code imported | BSD-2-Clause-Patent |
| [cotunjr/hakios-xnu-kernel](https://github.com/cotunjr/hakios-xnu-kernel) (`mayfly-port`) | the `minisandbox` container path, the `miniamfi` policy and entitlement grants | `0354` and `0108` in this series | APSL 2.0 kernel, MIT userland |
| [rui12366B/UniXNU-gts7xlwifi](https://github.com/rui12366B/UniXNU-gts7xlwifi) | GPU-fault recovery on the Adreno 650 | device-verified on the Tab S7+ | BSD-2-Clause-Patent |

## What to take for the open areas

- **Wi-Fi.** Start with `qiumochen/UniXNU-zizhan`: `drivers/PongWifi/`
  (`PongWifiPlatform.cpp` for PCIe0/PHY/rails/MSI, `ath11k/PongAth11k.c` for
  the real ath11k PCI/MHI/QMI and `PongWifiNet.cpp` for the ifnet/Apple80211
  side), `configs/zizhan-wifi-sm8475.json` for the board facts, and
  `docs/progress/2026-11-03-wifi-bringup.md` plus `2026-11-05-wifi-lifecycle.md`
  for the device evidence. The SoC and the QCA6490 are the same as ours; the
  board constants still come from our live DT.
- **The donor's Wi-Fi ladder is the same wall.** g272 stopped on
  `ArmSmmu4KStateMismatch` with `SCTLR=0` until the context used the shared ASID
  (`0x1c01` in TTBR0), a low-32-bit TBI policy and a lease against UFS, and
  wrote TCR2/TCR before TTBR0 (`SCTLR=0x27`, `TCR2=0x38071` once working); g274
  then reached QCN6855 hw2.1 and QMI, g275 scanned. Its WMI stall was a
  `wait_event_timeout` whose condition sent twice. Two limits: its RX is
  polled rather than a real GIC MSI, and native Settings joins took two more
  days of `wifid` work.
- **BHI is not hand-written there.** The donor compiles Linux v7.0.14
  `drivers/bus/mhi/host/boot.c`, so that file is the authority for the split we
  implement: the first `min(sbl_size, file)` bytes over BHI, the remaining
  segments over BHIe, `BHI_STATUS` cleared before the doorbell, a random
  non-zero 30-bit session id, success at the top two bits `0x2`, and a 50 s
  timeout.
- **Haptics.** `akshaynexus/iOSPlus10`: `patches/xnu/0300-negroni-haptic-direct-play.patch`,
  `0302` and `0303`, `bsd/dev/negroni_haptic.c` and `docs/haptics-plan.md`. It
  is the same PM8350B block and it supplies the PBS/SDAM hBoost vote that our
  `docs/MONDIAN_POWER.md` names as missing.
- **Audio.** Start the ADSP/graph path from `qiumochen/UniXNU-zizhan`:
  `drivers/PongPower/PongAudio.cpp`, `ShengAudioReach.c`, `QcomGlink.c`,
  `QcomSmp2p.c` and the live DT's `remoteproc-adsp`. Its ADSP/PRM/AudioReach
  ladder is device-verified on the same SM8475, though its README still calls
  the speaker path silent data awaiting listening. `akshaynexus/iOSPlus10` is
  not a WCD938x donor: its own `docs/audio-plan.md` calls the codec "nothing,
  weeks", its amp is a TFA9874 and its audio never played. For the AW88261,
  take the protocol facts from mainline `aw88261.c` (GPL, facts only) and the
  stock vendor `aw882xx` driver; the ACF profile is mandatory and the live DT
  has no `firmware-name`. The HAL side has a working reference:
  `oosexgang/hakios-xnu-kernel`'s `userland/src/audio_plugin.c` is a virtual
  `AudioServerPlugIn` (MIT) that presents Speaker, Actuator and Codec, and
  `open-mapple/mapple_userland/audio` installs it beside `VirtualAudio.plugin`
  and uses it in its realme 8i release (iOS 16.7.16). Our kernel still needs the
  `/dev` sink that drives the WCD938x and the AW882xx. The AW88261 identity
  probe now reads `0x2113` from both speaker amps on mondrian (`0416`).
- **Video and HEVC.** `DenialOfGravity/ios-redfin`: `phone/video/venus_core.c`
  is the whole sequence to copy before writing power or HFI code (PAS 9,
  `init_image`/`mem_setup`/`auth_and_reset`, SMMU, HFI), and it records the two
  traps that cost mondrian builds: a GDSC in `HW_CONTROL` ignores
  `SW_COLLAPSE` until the domain is taken back to SW mode, and a CBCR reading
  `0x0` has `CLK_OFF` clear, so it is running, not dead. `vtvenc.c` registers
  the VideoToolbox hardware encoder and `venusd.c` plus `venus_*` drive the
  block. This is the native path; `akshaynexus/OneiOS`
  (`kernel/patches/oneios-hosted/codec` and `runtime/bridges/encoder`) is the
  hosted MediaCodec alternative and the reference for iOS 27's tile session.
- **Metal.** `akshaynexus/iOSPlus10` has the Adreno 730 Metal2Vulkan path
  (`userland/metal/`, `patches/xnu/0298-negroni-gpu-kgsl-parity.patch`), the
  same GPU as ours, and steelbrain's `metal2vulkan` runtime is the userland
  half (`docs/MONDIAN_GPU.md`). `DenialOfGravity/ios-redfin`'s `phone/hmetal/`
  is a complete native Metal driver for a6xx, not a drop-in for the a730; its
  CoreAnimation plug-in also has a licence that its README says is unverified.
  `open-mapple/mapple_gpu_mali` (viva-gpu, GPL-3.0 with attribution) is a
  native Metal front-end on Mesa for Mali; its Adreno overlay is host-tested
  only and expects the `sweetgpuabi` client, so read the AIR/NIR path, do not
  drop it in.
- **Cellular, camera, brightness and sensors.** `DenialOfGravity/ios-redfin`
  has the native MPSS/IPA/QRTR path (`xnu/patches/1295-1297`, `1067`, `1072`,
  `1076`, `1124`, `phone/wifi/ipa*`), the camera services and the TCS3701
  auto-brightness/True Tone work (`1298`). The modem and the camera sensors
  are different hardware; the auto-brightness path only applies if our ALS is
  the same chip. Our sensors are behind SSC/ADSP, so treat these as
  architecture references, not drop-in drivers.

## Licence rules

- MIT and BSD code can be reused with its notice and attribution.
- APSL 2.0 code stays under APSL 2.0 when it is copied into XNU; keep the file
  headers.
- GPL code (Linux ath11k, `hci_qca` and most vendor drivers) is a reference,
  not code to paste into this tree. Check the file's own SPDX header rather
  than the repository name.
- No Apple IPSW, firmware or device dump is committed. Cite the source, not a
  copy.
