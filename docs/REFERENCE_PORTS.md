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
| [oosexgang/hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel) | the GLES/GPU path, the Mesa patches and the userland dylibs | its phones; the reference behind `docs/MONDIAN_GPU.md` | APSL 2.0 kernel, MIT userland (per its README) |
| [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz) | `SweetSurface`, the `IOMobileFramebuffer`/`AppleCLCD` presenter and the EAGL/OSMesa path | read; `docs/MONDIAN_GPU.md` | no root licence declared; read, do not copy |
| [akshaynexus/OneiOS](https://github.com/akshaynexus/OneiOS) | the VideoToolbox paravirtualization service, the HEVC tile session and the Rust runtime tools | its README marks the iOS 27 tile session host-tested, not booted | no licence file: all rights reserved; read, do not copy |
| [akshaynexus/iOSPlus10](https://github.com/akshaynexus/iOSPlus10) | QCA6490 Wi-Fi, PM8350B hBoost/PBS haptics, WCD938x/LPASS audio and Adreno 730 Metal2Vulkan | the repo's plans report built stages; its Wi-Fi audit says the host side has not run on the chip | MIT |
| [UniXNU/Adreno740](https://github.com/UniXNU/Adreno740), [UniXNU/AdrenoMetal](https://github.com/UniXNU/AdrenoMetal) | the a7xx GPU driver and the Metal-to-Vulkan frontend | device-verified on the Pad 6S Pro | MIT |
| [qiumochen/UniXNU-zizhan](https://github.com/qiumochen/UniXNU-zizhan) | `PongWifi`: QCA6490 PCIe/MHI/ath11k and Apple80211 on the same SM8475 | network device-verified: WPA2 join, DHCP/HTTPS and roaming | BSD-2-Clause-Patent; `PongAth11k.c` derives from Linux ath11k (GPL-2.0), check before mixing |
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
  `docs/progress/2026-11-05-wifi-lifecycle.md` for the device evidence. The
  SoC and the QCA6490 are the same as ours; the board constants still come
  from our live DT.
- **Haptics.** `akshaynexus/iOSPlus10`: `patches/xnu/0300-negroni-haptic-direct-play.patch`,
  `0302` and `0303`, `bsd/dev/negroni_haptic.c` and `docs/haptics-plan.md`. It
  is the same PM8350B block and it supplies the PBS/SDAM hBoost vote that our
  `docs/MONDIAN_POWER.md` names as missing.
- **Audio.** `akshaynexus/iOSPlus10`: `patches/xnu/0243..0249` and `0400`,
  `bsd/dev/negroni_adsp.c`, `negroni_audio.c` and
  `userland/audio/NegroniAudio.c`. Our codec is the same WCD938x, but our
  speaker amps are AW882xx, not the TFA9874 of the OnePlus, so the amp driver
  is the part to replace.
- **Video and HEVC.** `DenialOfGravity/ios-redfin`: `phone/video/vtvenc.c`
  registers a VideoToolbox hardware encoder, and `venusd.c` plus `venus_*`
  drive the Venus block. This is the native path; `akshaynexus/OneiOS`
  (`kernel/patches/oneios-hosted/codec` and `runtime/bridges/encoder`) is the
  hosted MediaCodec alternative and the reference for iOS 27's tile session.
- **Metal.** `akshaynexus/iOSPlus10` has the Adreno 730 Metal2Vulkan path
  (`userland/metal/`, `patches/xnu/0298-negroni-gpu-kgsl-parity.patch`), the
  same GPU as ours, and steelbrain's `metal2vulkan` runtime is the userland
  half (`docs/MONDIAN_GPU.md`). `DenialOfGravity/ios-redfin`'s `phone/hmetal/`
  is a complete native Metal driver for a6xx, not a drop-in for the a730; its
  CoreAnimation plug-in also has a licence that its README says is unverified.
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
