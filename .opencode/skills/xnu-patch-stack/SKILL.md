---
name: xnu-patch-stack
description: Add, reorder, rebase and validate the numbered 00NN patch series in xnu/patches-mondrian, and drive the CI that builds the kernel. Use when creating or fixing a patch, when a patch stops applying, when porting a sweet patch to mondrian, or when a CI run must be dispatched and its artifact flashed.
---

# The patch stack

The kernel is not edited in place. Everything is a numbered patch applied to
pristine XNU 8796; CI applies the series, builds, and ships an artifact.
`xnu/patches/` is sweet's series, `xnu/patches-mondrian/` is this one. Both
start at `0001`; a number is only comparable inside its own series.

## The trap that costs the most

**CI applies each patch with a skip-on-failure, so a patch that does not apply
is skipped with a warning and the build still succeeds.** A green run can
therefore mean "your feature is not in this kernel". 0010 (the early
framebuffer) was lost this way for a day. Always run the local check before
pushing:

```sh
tools/check-patches.sh                 # xnu/patches-mondrian, exits 1 on failure
tools/check-patches.sh xnu/patches     # sweet
NO_STAGE=1 tools/check-patches.sh      # skip the 00XX-stage-*.sh scripts
XNU_SRC=/private/tmp/xnu-full tools/check-patches.sh   # reuse a tree
```

The word to look for is the final `NN/NN patches apply`; when the second number
grows, the first must grow with it. 0085 lives on the `display` branch, so
`mondrian` legitimately reports 85 while the tree has 86 patch files.

## Authoring a patch

Keep a staged tree of the current series state and derive the patch from a
diff, never from an editor buffer:

```sh
cp -Rc /private/tmp/xnu-full /private/tmp/st87        # APFS clone, instant
$EDITOR /private/tmp/st87/bsd/dev/mondrian_ufs.c
diff -u --label a/bsd/dev/mondrian_ufs.c --label b/bsd/dev/mondrian_ufs.c \
     /private/tmp/xnu-full/bsd/dev/mondrian_ufs.c \
     /private/tmp/st87/bsd/dev/mondrian_ufs.c \
  > xnu/patches-mondrian/0087-<slug>.patch
```

- Prepend `diff --git a/<path> b/<path>` and a short rationale in the patch
  header. A new file needs `new file mode 100644` instead of the `---` line,
  otherwise `git apply` / `patch -p1` disagree.
- One patch, one reason. "Add X and also fix Y" cannot be bisected later.
- The commit message mirrors the patch title (`xnu 0086: ...`), and the body
  says what the previous boot proved and what the new build answers.
- Keep `NOTES.md` (handoff) and `docs/MONDIAN_PORT.md` (work list) in the same
  commit when a patch changes the plan.

Reordering or rebasing: edit the staged tree until it matches the target
state, then regenerate every patch that moved. `tools/apply-series.py` and
`tools/port-series.py` exist for bulk work; the latter carries a sweet patch
across to the mondrian series and is the right tool when porting `0030`
(writes) or `0047` (persistent log).

## CI

```sh
gh workflow run xnu.yml --repo xNekom/ios-mondrian --ref mondrian -f board=mondrian
gh run list  --repo xNekom/ios-mondrian --limit 3
gh run watch <id> --repo xNekom/ios-mondrian
```

- A push builds only on branches `main` and `mondrian`. Any other branch needs
  the explicit dispatch above.
- `--repo` is mandatory: without it the command targets `dipa-studio/ios-sweet`
  and returns HTTP 403.
- Concurrency is per ref with `cancel-in-progress`. Pushing to `mondrian`
  cancels an in-flight `mondrian` run, and **a cancelled job reports
  `conclusion: failure`**. Before believing a compile error, check
  `gh run view <id> --json jobs`: `cancelled` is not `failure`. The same view
  distinguishes a real error from GitHub infrastructure noise ("The job was
  not acquired by Runner of type hosted", "Internal server error").
- Artifact: `xnu-kernel-mondrian/kernel.development.mondrian` plus
  `SHA256SUMS`.

## From artifact to screen

```sh
gh run download <id> --repo xNekom/ios-mondrian -D /tmp/mk87
cd /tmp/mk87/xnu-kernel-mondrian && shasum -a 256 -c SHA256SUMS
cd - && KERNEL=/tmp/mk87/xnu-kernel-mondrian/kernel.development.mondrian \
     bash tools/phone-deploy.sh build          # -> /tmp/boot-mondrian.img
```

Then flash `boot_b` and reboot, and read the photo with the
`xnu-fb-console-triage` skill. Never flash anything except `userdata` and the
temporary `boot_b` image; `boot`, `init_boot`, `dtbo`, `vbmeta`, `abl`, `tz`
are hard-brick territory.
