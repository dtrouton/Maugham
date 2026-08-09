# Milestone (proposed) — research protection

**Status:** recorded 2026-08-02, not scheduled. Ruled into existence by Denver during the
reconciliation interview: *"yes this is a real issue IMO, and I think this is pushing me to a
research protection milestone in future."*

**Where this belongs:** `docs/roadmap.md`. It is recorded here because this experiment has changed
zero production files across 49 phases; moving it is Denver's call.

---

## The finding that produced it

**RULING-24** made Maugham's protection tiers explicit for the first time:

| tier | protection | why |
|---|---|---|
| **The work** — prose, screenplay | op log (every change) + ⌘S checkpoints | protected at all costs |
| **Research** | *intended:* ⌘S + filesystem backups | recoverable, not versioned |
| **Ingested / derived** — promoted voice notes, caches, renders | none | losing them costs annoyance only |

The boundary is **practical economics**: images, audio and PDFs are large, and versioning
everything would be expensive. That reasoning is sound and it explains three things previously
read as inconsistency — why manuscripts have op logs and research notes do not, why three
implementers found hard-deleting an inbox asset acceptable, and why `CheckpointCapture` walks
`manifest.structure` and not `manifest.research`.

**But the middle tier's stated safety net does not exist.** Verified three ways:

1. `allDocIds = ProjectWindow.documentIds(in: store.manifest.structure)` — the manuscript binder.
   `manifest.research` is never enumerated.
2. `Checkpoint.docPointers` is `[docId: opId]` — pointers *into op logs*.
3. Research notes have no op log (`ResearchNoteEditor`: *"not `Document` actors — no op-log, no
   paragraph IDs"*), so a checkpoint could not cover them even if they were enumerated.

**Research's only recovery is filesystem backups — Time Machine, iCloud file versions — entirely
outside Maugham.** The tier is not "recoverable but not versioned". It is "recoverable only by
something Maugham does not control".

## Why it needs a milestone rather than a fix

Three verified defects share this root, and none is fully fixable without deciding what tier-2
protection *means*:

| claim | defect | in-app recovery today |
|---|---|---|
| `M1-C-055` | an unreadable research note opens BLANK; one keystroke atomically replaces the file | none |
| promotion **Rewrite** | `writeBody` whole-file replaces a research note with a canvas card's text | none |
| `M3-TR-041` | a restored research item lands in the manuscript binder, not the research tree | n/a — different defect, same tier |

`M1-C-055` is fixable *today* without any versioning — stop swallowing the read error, which is
`RULING-7` (unreadable is never presented as empty). That should not wait for a milestone. But the
second failure it enables — a silent atomic overwrite with nothing to fall back on — is the tier
gap, and no amount of error handling closes it.

## The design space, respecting the economics

`ResearchItem.AssetKind` is `image, document, pdf, audio, link`. **Research TEXT is already
separable from the heavy assets at the type level**, so the economic argument does not force an
all-or-nothing answer:

1. **Version research text only.** `.document`-kind notes get history; images, audio and PDFs do
   not. Text is cheap — this is the option the economics actually permits.
2. **Snapshot rather than version.** Extend ⌘S to capture research note *content* (not op
   pointers, since there is no op log) so a labelled checkpoint covers the whole project.
3. **Never overwrite, only supersede.** Extend `RULING-15` from delete to overwrite: any
   whole-file replacement of a research note keeps the prior version somewhere recoverable. Cheapest
   of the three, and it closes both the `M1-C-055` and Rewrite paths without a history model.
4. **Ratify the tier as-is** and say so where the writer can see it — research is backed up by
   your filesystem, not by Maugham. Costs nothing to build; makes the promise honest.

## The open questions this milestone would answer

- Does tier 2 mean *versioned*, *snapshotted*, *never-silently-overwritten*, or *documented as
  unprotected*?
- Is the split by **asset kind** (text versus binary) or by **location** (research versus
  manuscript)? Kind is available today and matches the economics; location is what the code
  currently uses.
- Does ⌘S mean "checkpoint the work" or "checkpoint the project"? Its name and its caption say
  project; its implementation says work.
- Do palette cards count as research? They are `.md` under `research/palette/`, they are edited
  directly by the writer, and they have no op log either.

## Related rulings

`RULING-24` (tiering, and the corrected basis) · `RULING-4` (recoverability, now tier-scoped) ·
`RULING-15` (delete is normalised — the candidate extension is to overwrite) · `RULING-7`
(unreadable never presented as empty — closes the first half of `M1-C-055`).
