# Working on ios-mondrian

This is a fork of `dipa-studio/ios-sweet`. The sweet half (Redmi Note 10 Pro,
SM7150) is the reference implementation and works; the mondrian half (POCO F5
Pro, SM8475) is the port being done here.

- Read `NOTES.md` first: the port state, the measured hardware facts and the
  traps that already cost time. `docs/MONDIAN_PORT.md` is the work list (the
  hardware delta, what is done, what each remaining subsystem needs). Keep both
  in sync with the code.
- Load the skill for the subsystem before re-deriving a trap
  (`.github/skills/<id>/SKILL.md`, the one directory both Copilot and OpenCode
  read). Update it in the same commit that pays for a new trap.
- `tools/boards.py` is the reference for every number the shim and the kernel
  patches share; `shim/board.h` is its copy for the bare-metal half. Change
  both together, and prefer reading the live device tree (the shim prints it)
  over guessing a value.

## Repository checks

`python3 tools/check-agent.py` is the whole gate; it fails when a rule declared
in this file has no check, so a rule cannot be prose only.

| Id | Check |
| --- | --- |
| R01 | Relative links in the root docs and `docs/*.md` resolve |
| R02 | The length budgets below are not exceeded |
| R03 | No tracked text file carries CRLF |
| R04 | No device capture or disk image is tracked |
| R05 | No credential in a first-party file |
| R06 | `tools/boards.py` and `shim/board.h` carry the same numbers |
| R07 | Every `.github/skills/*/SKILL.md` names its own directory |
| R08 | Patch numbering, hunk headers and tool syntax (`tools/validate-repo.py`) |

`--only R06` runs one check, `--list` prints the ids, `--verbose` adds detail.
CI runs the same file (`.github/workflows/validate.yml`), so a local pass is
the same reading as a red workflow.

## Safety: what can and cannot brick the phone

This phone is a dedicated test unit: the high-level partitions may be erased
and flashed freely, `userdata` (the iOS root) included and without a
workstation backup, because a reachable fastboot restores the device.

- **Never written:** `xbl`, `xbl_config`, `abl`, `tz`, `hyp`, `modem*`,
  `persist`, `uefi*`, `uefisecapp` and every other low-level image the stock
  ROM ships. A cooked image there bricks the boot chain irreversibly.
- **Writable:** `boot_<slot>` (the shim boots slot b; `boot_a` keeps the stock
  Android escape hatch and the deploy tooling refuses it), `vendor_boot` (only
  after a verified dump: the shim reads its live device tree), `init_boot` /
  `recovery` if present, and `userdata`, which the iOS root occupies in place -
  no GPT changes.
- Prove a `boot_<slot>` image with `fastboot boot` and pin the target with
  `fastboot getvar current-slot` first. `tools/flash-root.sh` still asks before
  every write, and every destructive step waits for the user. Fastboot access
  is the real disaster baseline.

## Never build an image from guessed addresses

The shim takes the framebuffer and the UFS host from the device tree, and
`mkadt.py` / `mkpayload.py` refuse a board whose values are still provisional
(`--allow-provisional` is the deliberate way past that).

- **A mondrian image must carry `usb=2`.** With `usb=1` `mondrian_usb_probe`
  stops at the probe: the phone boots to SpringBoard with no USB at all - no
  console ring, no control channel - and only the hardware buttons reach
  fastboot. `tools/boards.py` carries it and `mkpayload.py` refuses a mondrian
  payload without it (`--allow-silent-boot` for a deliberate test); never
  assemble that command line by hand.
- The boot arguments live in `tools/boards.py`; the non-obvious ones, including
  the 607-byte ceiling, are explained in `docs/MONDIAN_PORT.md`.
- Keep device dumps, serial numbers and downloaded Apple artifacts out of git.

## The development loop

- **One command per experiment.** `tools/wsl/cycle.sh haps "vib 150 64"` builds
  the image, boots it from RAM, proves which kernel is running and runs the
  ring commands. A build is ~10-15 minutes and a boot ~2.5, so a second
  question in the same boot is free while a repeated boot is not.
- **A failed boot disables RAM boots until the slot is re-activated.** After a
  boot that dies, ABL marks the active slot unbootable and then refuses *every*
  `fastboot boot` with `Failed to load/authenticate boot image: Not Found` - a
  4 KB stub is refused the same way, and so is an image that booted an hour
  earlier. `fastboot --set-active=<current-slot>` clears it. `cycle.sh` does
  this before every boot; without it, the refusal reads as a kernel that
  crashes, and the ring answering with the previous kernel's banner "confirms"
  it.
- **Prove the kernel before trusting any answer.** A RAM boot that dies falls
  back to `boot_b`, so "command not found" means "old kernel" as often as
  "bug". `cycle.sh` compares the ring's `Darwin Kernel Version` with the kernel
  on disk first. The same applies to checking a build: a
  `grep -c "MONDRIAN HAP" kernel` written inline in PowerShell comes back 0
  because the quotes never reach grep - put the check in a script file.
- **Never pipe a build or flash script.** `bash mkimg.sh | head -1` dies of
  SIGPIPE and leaves the previous image - the phone then boots the old kernel
  and the new command "does not exist" - and `bash tools/flash-root.sh IMG |
  tail -6` throws away the `fastboot flash` progress and its failure, so a
  flash that never started looks like one that finished and the image gets
  blamed. Log to a file and read the exit status. The same goes for editing a
  script that is still running.
- **Every WSL script attaches the phone itself.** WSL shuts down between tool
  calls, so `usbipd attach --wsl` and the `192.168.7.1` address must be redone
  inside each script or the first send fails with `Errno 99`. The bus id moves
  with the port: look it up by USB id
  (`usbipd list | grep -E '1209:0001|18d1:d00d'`), never trust a hardcoded
  `enx...`, and wait for `cdc_ether` to create the netdev instead of sleeping.
- **Search before experimenting blind.** When a register value, a sequence or a
  fault does not match the references, read mainline (`drm/msm` a6xx/a7xx,
  Mesa freedreno), the vendor kernel and the XNU drivers in the local research
  trees, and search the web, before changing a driver again. The GPU bring-up
  traps were all solved already in a patch or a driver that shipped.
- **Ask the vendor before writing a driver.** The live device tree and the
  vendor source answer in minutes what a boot cannot.
  `raw.githubusercontent.com` rate-limits (429), so
  `cdn.jsdelivr.net/gh/<owner>/<repo>@<sha>/<path>` serves the same file.
  Vendor blobs and configs come from the stock ROM on the PC
  (`tools/super-extract.py`), not from the phone. **A recovery is not an option
  on this unit** (measured twice): `fastboot boot` refuses our OrangeFox images
  with `Bad Buffer Size`.
- **Instrument before you poke.** One dump that answers the whole question -
  full view depth, `userInteractionEnabled`/`hidden`/`alpha` per view,
  `-[UIApplication sendEvent:]` for where a touch lands - settles in one boot
  what a dozen narrow probes cannot. Guard every generic selector with
  `respondsToSelector:` (an unguarded `contentSize` aborted SpringBoard), never
  trust a truncation (a depth cap hid the Control Center's content), and pick
  touch targets from the frames, not the pixels.
- **SPMI: the map is the truth.** A peripheral's PPID is `(sid << 8) |
  peripheral`, not its DT address: pm8350b's haptics at `0xf000` is `0x3f0`,
  while the SID-0 VADC is `0x031`. `tools/usb-ring.py spmimap` dumps the 540
  entries the bootloader left; check the owner bits before touching anything,
  because reading a peripheral another processor owns wedges the arbiter.
- **Declare before you build.** A missing `extern`/prototype (`delay`, `hz`,
  `sp_apid_owner`) is the commonest failure and costs a ten-minute build.
- **Patches come from a diff of the staged series.** Stage it with
  `tools/wsl/series-stage.sh <last>` (a pristine copy of the cache under
  `/root`, patches applied in order) and `diff -u` the files before and after:
  diffing against the *build* cache duplicates whatever the last build already
  applied, and a later patch then stops applying the moment an earlier one
  grows. `tools/check-patches.sh` must report every patch applying before a
  build is worth starting.

## Documentation rules

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
  it belongs in `tools/` (board table, constants) and the doc points there. A
  commit hash is allowed only when it is the sole pointer to a piece of work
  that is not in the tree (e.g. a branch's tip).
- **Every paragraph must answer "what do I do with this?"** Keep: measured
  hardware values, invariants that break silently, symptoms paired with their
  cause and fix, the commands a newcomer needs, pointers to the source of a
  number. Drop: reasoning that only justifies a decision already made, dead
  ends without a reusable lesson, and anything duplicated from another doc.
- **One home per fact.** Hardware facts and traps in `NOTES.md`, work items and
  the hardware delta in `docs/MONDIAN_PORT.md`, procedures and layout in
  `README.md`, per-patch state in `xnu/patches-mondrian/README.md`, the
  emulator in `docs/QEMU_TESTING.md`, boot arguments in `tools/boards.py`.
  Cross-link instead of repeating; if two files disagree, fix the wrong one
  rather than adding a third statement.
- **Write for the reader, in English, in the present tense.** Observations and
  guesses are labelled (`measured`, `expected`, `TODO`), not woven into prose.

| File | Max lines |
| --- | --- |
| `NOTES.md` | 350 |
| `docs/MONDIAN_PORT.md` | 320 |
| `README.md` | 250 |
| `AGENTS.md` | 240 |
| `docs/QEMU_TESTING.md` | 90 |
| `xnu/README.md` | 80 |
| `xnu/patches-mondrian/README.md` | 80 |

A budget is a ceiling, not a target: if new text would exceed one, delete or
merge something old in the same edit. `docs/MONDIAN_PORT.md` is 15 lines over
its old 300 until the safety section folds into this file; it is capped at 320
in the meantime.

## Repository hygiene

- **Nothing durable outside the repository.** `out/`, `shim/out/` and
  `xnu/out*/` hold build products and are ignored; a script that passes a check
  belongs in `tools/` in the same turn, never in a temporary directory.
- **Commit completed changes, then push from Windows.** `git push` inside WSL
  stops at `could not read Username for 'https://github.com'` (no credential
  helper); the same push from PowerShell uses Git Credential Manager. CI only
  sees `origin/mondrian`, so push before dispatching a run.
- **One branch per change:** `feat/`, `fix/`, `docs/`, `chore/`, `test/`.
  Messages are English and `type(scope): lowercase summary`, no trailing
  period. Do not rewrite published history. Code and documentation are
  separate commits.
- **Import code with attribution:** `git cherry-pick -x <sha>`, or
  `Co-authored-by: Name <email>` when copying by hand.
- **One checkout, one owner.** Work in your own clone or worktree. In a tree you
  do not own, never run `git checkout -- <path>`, `restore`, `reset --hard`,
  `clean -f` or `stash`: `git stash` is not a backup and the work it hides is
  not recoverable by anyone else. `git status --porcelain` before anything
  destructive, and a snapshot (`git diff > patch`, untracked files copied out)
  before the first delete.
- **A tag marks a proven state.** Only `boot-proven-YYYYMMDD`, on a commit
  whose image reached SpringBoard; the message carries the ring's
  `Darwin Kernel Version` line and the console excerpt. Per-session and
  per-round tags are noise: the rollback anchor is the pushed commit.

## Skills

- `mondrian-ufs-debug` - a boot that leaves no log, or stops before the UFS
  root; UPIU/OCS/sense decoding.
- `qualcomm-device-tree` - pulling numbers out of the live DTB or the vendor
  dtsi into `boards.py` and `shim/board.h`.
- `xnu-arm64-board-port` - memory window, pmap, GIC, timer, early console, and
  "why does XNU not get past <milestone>".
- `xnu-fb-console-triage` - reading a boot photo or a screen transcript,
  including the colour-bar self-test.
- `xnu-patch-stack` - authoring, rebasing and validating `00NN` patches, and
  the CI run that builds them.
- `mondrian-device-cycle` - one experiment end to end: slot recovery, proving
  the kernel, attaching the phone to WSL, never piping a build.
