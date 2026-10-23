# Working on ios-mondrian

This is a fork of `dipa-studio/ios-sweet`. The sweet half (Redmi Note 10 Pro,
SM7150) is the reference implementation and works; the mondrian half (POCO F5
Pro, SM8475) is the port being done here.

- Read `NOTES.md` first: the port state, the measured hardware facts and the
  traps that already cost time. `docs/MONDIAN_PORT.md` is the work list (the
  hardware delta, what is done, what each remaining subsystem needs). Keep both
  in sync with the code.
- Work moves between sessions: update the state section of `NOTES.md` after
  each milestone and before stopping. Say what was tried, what the exact
  build/boot result was, and what is unfinished. Distinguish observations from
  guesses, and write dates, not times.
- Commit completed changes. Kernel builds go through GitHub Actions (`gh
  workflow run xnu.yml -f board=mondrian`); `tools/apply-series.py` and
  `tools/check-patches.sh` validate a series locally in seconds, and the CI
  silently skips a patch that does not apply. A local single-file cross-compile
  is cheaper than a CI run.
- The board table lives in `tools/boards.py`; the shim has its own copy in
  `shim/board.h`. Change both together, and prefer reading the live device
  tree (the shim prints it) over guessing a number.
- **Hardware safety outranks persistence (policy, 2026-10-23).** The
  firmware-level partition set (`xbl`, `xbl_config`, `abl`, `tz`, `hyp`,
  `modem*`, `persist`, `uefi*`/`uefisecapp` and every other low-level image the
  stock ROM ships) is never written: a cooked image there bricks the boot chain
  irreversibly. Writable storage is the high-level set only — `boot_<slot>`
  (the shim boots from slot b; `boot_a` keeps the stock Android escape hatch
  and the deploy tooling refuses it), `vendor_boot` (only with a verified dump
  first: the shim reads its live device tree), `init_boot`/`recovery` if
  present, and `userdata` (the iOS root; wiping Android data there is
  acceptable and recoverable). Every definitive write needs the graded
  safeguards: a proven `fastboot boot` of the same image, `fastboot getvar
  current-slot` to name the target, and verified originals in `backup/`
  (`SHA256SUMS`). The stock fastboot ROM is the disaster-recovery baseline.
  `tools/flash-root.sh` (userdata) still asks before every flash.
- **Never build an image from guessed addresses.** The shim takes the
  framebuffer and the UFS host from the device tree, and `mkadt.py` /
  `mkpayload.py` refuse a board whose values are still provisional
  (`--allow-provisional` is the deliberate way past that).
- Device bring-up uses temporary `fastboot boot` images. Preserve the Android
  installation and the partition backups. The iOS root goes into the existing
  `userdata` partition (no GPT changes). Keep bootloaders, recovery, modem,
  persist and the backups intact, and confirm each destructive step with the
  user before running it.
- Keep device dumps, serial numbers and downloaded Apple artifacts out of git.
- Project skills live in `.opencode/skills/<id>/SKILL.md` and encode the traps
  that have already cost time (console-photo triage, arm64 board porting, the
  patch stack + CI, Qualcomm device trees, mondrian UFS). Update the relevant
  one when a new trap is paid for; load it before re-deriving it.
