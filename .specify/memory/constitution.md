# ios-mondrian constitution

`AGENTS.md` is the project constitution: read it first and treat it as
normative. This file only states the rules the Spec Kit workflows enforce; it
does not repeat the hardware facts.

## Evidence before claims

- A subsystem is "working" only when a boot produced the line that proves it
  (the ring or the `prev` console) and the boot proved which kernel answered.
  The `Darwin Kernel Version` line in the ring decides that; a command that
  "does not exist" usually means the old kernel answered.
- A hypothesis is labelled as one. Unproven stays `unknown`.
- One experiment per boot, and the tool returns the phone to fastboot.

## One home per fact

- Hardware facts and traps: `NOTES.md`.
- Work items and the hardware delta: `docs/MONDIAN_PORT.md`.
- Wi-Fi contract and W-series state: `docs/MONDIAN_WIRELESS.md`.
- Spec Kit artifacts are process, not documentation: `specs/` holds an
  executable milestone plan, `.specify/bugs/` holds a defect record. When the
  work lands, fold the durable fact into the docs above and delete the
  artifact. Never cite a spec as the only home of a measured value.

## Safety

- Never write `xbl`, `abl`, `tz`, `hyp`, `modem*`, `persist`, `uefi*`. Only
  `boot_<slot>` (the shim boots slot b), `userdata` and a verified
  `vendor_boot`.
- `fastboot --set-active=<current-slot>` before every RAM boot.
- Never build an image from guessed addresses, and a mondrian image carries
  `usb=2`.

## Workflow

- `/speckit.bug.assess|fix|test` records a defect from symptom to a verified
  verdict. Use it for a boot that fails or a milestone that regresses.
- `/speckit.specify|plan|tasks` is for a milestone that needs a plan with
  measurable acceptance.
- Neither replaces `AGENTS.md`, the docs or the subsystem skill.
