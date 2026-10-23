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
