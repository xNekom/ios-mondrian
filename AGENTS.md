# Working on ios-mondrian

This is a fork of `dipa-studio/ios-sweet`. The sweet half (Redmi Note 10 Pro,
SM7150) is the reference implementation and works; the mondrian half (POCO F5
Pro, SM8475) is the port being done here.

- Read `NOTES.md` first: the port state, the measured hardware facts and the
  traps that already cost time. `docs/MONDIAN_PORT.md` is the work list (the
  hardware delta, what is done, what each remaining subsystem needs). Keep both
  in sync with the code.
- Commit completed changes. Kernel builds go through GitHub Actions (`gh
  workflow run xnu.yml -f board=mondrian`); `tools/apply-series.py` and
  `tools/check-patches.sh` validate a series locally in seconds, and a patch
  that does not apply fails the CI run. A local single-file cross-compile is
  cheaper than a CI run.
- The board table lives in `tools/boards.py`; the shim has its own copy in
  `shim/board.h`. Change both together, and prefer reading the live device
  tree (the shim prints it) over guessing a number.
- **Search before experimenting blind (policy, 2026-10-29).** When a register
  value, a sequence or a fault does not match the references, read mainline
  (`drm/msm` a6xx/a7xx, Mesa freedreno), the vendor kernel and the XNU drivers
  in the local research trees, and search the web, before changing the driver
  again. Most of the traps here are already documented somewhere: the 64-bit
  `CP_SQE_INSTR_BASE` write, `a7xx_hw_init` running `CP_ME_INIT` before the
  secure-mode switch, and `CP_SET_SECURE_MODE` for the trusted→nonsecure
  transition all came from a patch or a driver that already solved them. A
  boot cycle costs minutes; the answer is often one search away.
- **Instrument before you poke (policy, 2026-11-13).** A boot costs five minutes
  and a wrong conclusion costs more. One dump that answers the whole question --
  full view depth, `userInteractionEnabled`/`hidden`/`alpha` per view, and
  `-[UIApplication sendEvent:]` for where a touch actually lands -- settles in
  one boot what a dozen narrow probes cannot. Guard every generic selector sent
  from a dump with `respondsToSelector:` (one unguarded `contentSize` on
  `_UIScrollViewScrollIndicator` aborted SpringBoard and cost the boot), never
  trust a truncation (a depth cap of nine made the Control Center look empty
  when its content hangs below ten), and pick touch targets from the frames,
  not from the pixels.
- **Hardware safety outranks persistence (policy, 2026-10-25).** This phone is
  a dedicated test unit: the high-level partitions may be erased and flashed
  freely — including `userdata`, which holds the iOS root — without a
  workstation backup, because a reachable fastboot restores the device. The
  firmware-level partition set (`xbl`, `xbl_config`, `abl`, `tz`, `hyp`,
  `modem*`, `persist`, `uefi*`/`uefisecapp` and every other low-level image the
  stock ROM ships) is still never written: a cooked image there bricks the boot
  chain irreversibly. Writable storage is the high-level set only — `boot_<slot>`
  (the shim boots from slot b; `boot_a` keeps the stock Android escape hatch and
  the deploy tooling refuses it), `vendor_boot` (only with a verified dump
  first: the shim reads its live device tree), `init_boot`/`recovery` if
  present, and `userdata` (the iOS root; wiping Android data there is
  acceptable and recoverable). Before any `boot_<slot>` write, prove the same
  image with `fastboot boot` and pin the target with `fastboot getvar
  current-slot`; `tools/flash-root.sh` (userdata) still asks before every
  flash. Keep the stock fastboot ROM available when convenient, but fastboot
  access is the real disaster baseline.
- **Never build an image from guessed addresses.** The shim takes the
  framebuffer and the UFS host from the device tree, and `mkadt.py` /
  `mkpayload.py` refuse a board whose values are still provisional
  (`--allow-provisional` is the deliberate way past that).
- **A mondrian image must carry `usb=2`.** Without it `mondrian_usb_probe`
  stops at the probe (`usb=1`): the phone boots to SpringBoard with no USB at
  all — no console ring, no control channel — and the only way back to
  fastboot is the hardware buttons. The board's command line in
  `tools/boards.py` carries it and `mkpayload.py` refuses a mondrian payload
  without it (`--allow-silent-boot` is the way past for a deliberate test);
  never assemble that command line by hand.
- Device bring-up uses temporary `fastboot boot` images. Preserve the Android
  installation and the partition backups. The iOS root goes into the existing
  `userdata` partition (no GPT changes). Keep bootloaders, recovery, modem,
  persist and the backups intact, and confirm each destructive step with the
  user before running it.
- Keep device dumps, serial numbers and downloaded Apple artifacts out of git.
- Project skills live in `.github/skills/<id>/SKILL.md` (Copilot's Agent Skills
  path; `.opencode/opencode.json` points OpenCode at the same directory, so
  there is exactly one copy) and encode the traps that have already cost time
  (console-photo triage, arm64 board porting, the patch stack + CI, Qualcomm
  device trees, mondrian UFS). Update the relevant one when a new trap is paid
  for; load it before re-deriving it.

## The development loop (hard rules; each one has already cost a boot)

- **One command per experiment.** `tools/wsl/cycle.sh haps "vib 150 64"`
  builds the image, boots it from RAM, proves which kernel is running and runs
  the ring commands. A build is ~10-15 minutes and a boot ~2.5, so a second
  question in the same boot is free while a repeated boot is not.
- **Publish from Windows, not from WSL.** `git push` inside WSL stops at
  `could not read Username for 'https://github.com'`: WSL has no credential
  helper. The same push from PowerShell (`git -C
  C:\Users\Pedro\Documents\GitHub\ios-mondrian push origin HEAD:mondrian`) uses
  Git Credential Manager and succeeds. CI only sees what is in
  `origin/mondrian`, so push before dispatching a run.
- **Never pipe a build script.** `bash mkimg.sh | head -1` killed it with
  SIGPIPE and left the previous image: the phone booted the old kernel twice
  and the new command "did not exist". Read the exit status, not the first
  line. The same goes for editing a script that is still running: bash reads
  the file as it goes, so a mid-run edit corrupts the next line it parses
  (`line 93: -3: command not found`), and the run then lies about why it
  failed.
- **Prove the kernel before trusting any answer.** A RAM boot that dies falls
  back to `boot_b`, so "command not found" means "old kernel" as often as
  "bug". `cycle.sh` compares the ring's `Darwin Kernel Version` with the
  kernel on disk first. The same applies to checking a build: a `grep -c
  "MONDRIAN HAP" kernel` written inline in PowerShell comes back 0 because the
  quotes never reach grep — put the check in a script file.
- **Every WSL script attaches the phone itself.** WSL shuts down between tool
  calls, so `usbipd attach --wsl` and the `192.168.7.1` address must be redone
  inside each script or the first send fails with `Errno 99`.
- **SPMI: the map is the truth.** A peripheral's PPID is `(sid << 8) |
  peripheral`, not its DT address: pm8350b's haptics at `0xf000` is `0x3f0`,
  while the SID-0 VADC is `0x031`. `tools/usb-ring.py spmimap` dumps the 540
  entries the bootloader left; check the owner bits before touching anything,
  because reading a peripheral another processor owns wedges the arbiter and
  costs the boot.
- **Ask the vendor before writing a driver.** The live device tree and the
  vendor source answer in minutes what a boot cannot.
  `raw.githubusercontent.com` rate-limits (429); `cdn.jsdelivr.net/gh/
  <owner>/<repo>@<sha>/<path>` serves the same file. An OrangeFox boot from RAM
  (`fastboot boot`, ten seconds, writes nothing) answers anything the kernel
  can: `tools/vendor-dump.sh` collects its clocks, regulators, thermal zones,
  UFS gear, panel, SPMI state and dmesg into `/root/vendor-dump` in one boot,
  and `tools/ofox-leave-and-cycle.sh` gets the phone back out of the recovery
  (OrangeFox ignores `adb reboot bootloader`; `adb shell reboot bootloader`
  works, and `adb devices` reports its state as `recovery`).
- **Declare before you build.** A missing `extern`/prototype (`delay`, `hz`,
  `sp_apid_owner`) is the commonest failure and costs a ten-minute build.
- **Patches come from a diff of the staged series.** Hand-counted hunks have
  failed four times. Stage the series with `tools/wsl/series-stage.sh <last>`
  (a copy of the pristine cache under `/root`, patches applied in order) and
  `diff -u` the files before and after the change: diffing against the *build*
  cache duplicates whatever the last build already applied, which is how 0341
  stopped applying the moment 0340 grew a function. `tools/check-patches.sh`
  must report every patch applying before a build is worth starting.

## Documentation rules (hard requirements)

The `.md` files are for the next developer, not for the session that wrote
them. A fact that only mattered while debugging is not documentation.

- **Edit in place, never append.** `NOTES.md` has no changelog: rewrite its
  state section when the state changes, and delete what it replaces. A new
  dated entry is only justified if the date itself carries meaning (a policy
  decision, the first boot of a subsystem). When in doubt, fold the fact into
  the existing section.
- **Dates only, never times.** Write `2026-10-23`; never add the hour of the
  day, never append a wall-clock time or a timezone (`UTC`, `CEST`, "local").
  Durations are fine ("about four minutes").
- **No session ephemera.** No CI run ids, workflow job numbers, image or kernel
  hashes, byte sizes, `/tmp` paths, `adb`/`fastboot` transcripts, "photo
  pending", "waiting for the user", to-do notes to yourself, or narration of
  what you tried and discarded. If a number is needed to reproduce something,
  it belongs in `tools/` (board table, constants) and the doc points there.
  A commit hash is allowed only when it is the sole pointer to a piece of work
  that is not in the tree (e.g. a branch's tip).
- **Every paragraph must answer "what do I do with this?"** Keep: measured
  hardware values, invariants that break silently, symptoms paired with their
  cause and fix, the commands a newcomer needs, pointers to the source of a
  number. Drop: reasoning that only justifies a decision already made, dead
  ends without a reusable lesson, and anything duplicated from another doc.
- **One home per fact.** Hardware facts and traps in `NOTES.md`, work items and
  the hardware delta in `docs/MONDIAN_PORT.md`, procedures and layout in
  `README.md`, per-patch state in `xnu/patches-mondrian/README.md`, the
  emulator in `docs/QEMU_TESTING.md`. Cross-link instead of repeating; if two
  files disagree, fix the wrong one rather than adding a third statement.
- **Length budgets.** `NOTES.md` ≤ 350 lines, `docs/MONDIAN_PORT.md` ≤ 300,
  `README.md` ≤ 250, `docs/QEMU_TESTING.md` ≤ 90, each `README.md` under
  `xnu/` ≤ 80. Do not grow a file to record a change: if new text would exceed
  the budget, delete or merge something old in the same edit.
- **Write for the reader, in English, in the present tense.** Observations and
  guesses are labelled (`measured`, `expected`, `TODO`), not woven into prose.
