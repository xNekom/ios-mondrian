# Working on ios-mondrian

This is a fork of `dipa-studio/ios-sweet`. The sweet half (Redmi Note 10 Pro,
SM7150) is the reference implementation and works; the mondrian half (POCO F5
Pro, SM8475) is the port being done here.

- Read `NOTES.md` before starting; it contains the project goal, hardware
  facts, current blocker, local artifact locations and the next concrete
  action. The **mondrian handoff** is at the top of the file.
- `docs/MONDIAN_PORT.md` is the work list for the port: the hardware delta
  between the two phones, what is already done and what each remaining
  subsystem needs. Keep it in sync with the code.
- The user switches agents frequently. Update the active handoff in
  `NOTES.md` after each milestone and before stopping. Record commits, CI run
  IDs, exact build/boot results and unfinished work. Distinguish observations
  from guesses.
- Commit completed changes. Use `gh` for GitHub Actions kernel builds and
  logs (`gh workflow run xnu.yml -f board=mondrian`). Local single-file
  cross-compiles are useful before spending a CI run.
- The board table lives in `tools/boards.py`; the shim has its own copy in
  `shim/board.h`. Change both together, and prefer reading the live device
  tree (the shim prints it) over guessing a number.
- **Never flash anything but `userdata`.** `boot`, `init_boot`, `dtbo`,
  `vbmeta`, `abl` and `tz` are not touched: writing them is a hard brick.
  `tools/flash-root.sh` flashes the root into `userdata` and asks first.
- **Never build an image from guessed addresses.** The shim takes the
  framebuffer and the UFS host from the device tree, and `mkadt.py` /
  `mkpayload.py` refuse a board whose values are still provisional
  (`--allow-provisional` is the deliberate way past that).
- Device bring-up uses temporary `fastboot boot` images. Preserve the Android
  installation and partition backups. The iOS root goes into the existing
  `userdata` partition (no GPT changes). Keep bootloaders, recovery, modem,
  persist and the backups intact, and confirm each destructive step with the
  user before running it.
- Keep device dumps, serial numbers and downloaded Apple artifacts out of git.
