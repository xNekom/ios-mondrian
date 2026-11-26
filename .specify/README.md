# `.specify` — bug records

This tree keeps one workflow: the three-step bug record. Planning does not live
here: `AGENTS.md` carries the rules, `NOTES.md` the measured hardware facts and
`docs/MONDIAN_PORT.md` the work list. The SDD commands
(`/speckit.specify|plan|tasks|implement`) are absent on purpose; a second plan
document drifts from those files.

## The workflow

| Command | Report |
| --- | --- |
| `/speckit.bug.assess` | `.specify/bugs/<slug>/assessment.md` |
| `/speckit.bug.fix` | `.specify/bugs/<slug>/fix.md` |
| `/speckit.bug.test` | `.specify/bugs/<slug>/test.md` |

The commands run from `.opencode/commands/speckit.bug.*.md`. Their source
templates are `.specify/extensions/bug/commands/`; `extension.yml` declares the
extension and `.specify/extensions/.registry` records it as installed. Each
command reads `.specify/extensions.yml` for hooks before and after its stage;
the file registers none.

A record holds the reports of the stages that ran, in one directory per slug
(lowercase kebab-case). `.specify/bugs/wifi-premap-io-map/` is the exemplar: an
assessment and a test report for a defect fixed by a kernel patch, with no
separate `fix.md`.

## What a record is for

A record is evidence for one defect, not documentation. The assessment states
the symptom, the suspected code path and the proposed remediation; the fix
report lists what changed; the test report lists the checks that actually ran
and the verdict. When the defect closes, fold the durable fact into `NOTES.md`
or `docs/MONDIAN_PORT.md`; the record stays the evidence trail for the patch it
names, not the home of a measured value.

`AGENTS.md` is the project constitution; this directory has no second one.
