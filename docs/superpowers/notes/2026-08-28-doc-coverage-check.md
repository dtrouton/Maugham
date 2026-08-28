# Doc-coverage check — 2026-08-28 (scoped sweep: is anything shipped missing from `docs/guide/`?)

**Mode:** scoped doc-truth check, not a full sweep — Denver's ask after the 2026-08-27/28 fix-issues run ("let's check if any other recent features are missing from docs"). Window: everything ✓ on the roadmap since the 2026-08-09 full audit, plus the six issues merged 2026-08-27/28 (#33 #43 #40 #41 #42 #35), plus the two shipped surfaces the ⌘S question surfaced (checkpoints, backups). One doc-truth agent (opus, read-only, agent contract) over all 16 guide topics against source; every High coordinator-verified. Tree at `b799c284`.

## Headline

**The recent work is the best-documented part of the guide.** M3 (passes/board/queue), M4 (named editors, This check, Fresh Eyes, intent drift), the references shelf and study column, the publish department P1–P4 + cast management, the recovery ladder, and all six fix-issues branches are described and — spot-checked string by string against `DiagnosticsPane`, `IntentStrip`, `RoundNarrative`, `DepartmentDesk`, `DepartmentCastSheet`, `CanvasStore`, `DocumentRecoveryPane` — **accurate**. No false sentence attributable to #40/#41/#42/#35.

The gaps are older or structural: **Backups has no topic at all** (shipped v0.8.0, 2026-06-07, before the guide's current discipline); **bulk annotation actions are cross-referenced twice and described nowhere**; **History's checkpoint revert gets one clause**; and a small cluster of shortcut/inventory drift, one of which is a self-contradicting paragraph (`right-pane.md:116` says `⌘⌥I` hides the study — `⌘⌥I` is the Inspector and *ends* it; `⌘⌥0` is the column toggle).

**Inverted drift risk:** new features land with their topic; it is the pre-discipline features that never got retrofitted. Nothing tests that a shipped surface has a topic, that a guide file is reachable from `index.json`, that an inter-topic link resolves, or that a non-`⌘⌥` binding is in `reference.md`.

## Trend metrics (this check only)

| Metric | 2026-08-28 |
|---|---|
| Guide topics (`index.json`) | 16 |
| Shipped writer-facing surfaces checked | 10 groups (roadmap ✓ since 2026-08-09 + 6 issues + checkpoints/backups) |
| Surfaces with NO topic | 2 (Backups & restore; bulk annotation actions) |
| Surfaces thin (one clause) | 1 (History checkpoint revert) |
| False sentences | 1 (`right-pane.md:116` ⌘⌥I ×2) |
| Stale mirrored surface | 1 (`KeyboardShortcuts.swift:66-72` cheatsheet labels) |
| `DocSyncTests` pins | 5 (tool count, ⌘⌥ tokens ×2 directions-ish, DetailSegment names, canvas figures, round ring) |

## Findings (all coordinator-verified against source where marked ✔)

**High**
- **H1 ✔ — No Backups topic.** Settings → Backups (`SettingsTabs/BackupSettingsTab.swift`: destinations outside iCloud, 1–50 retention stepper, "run automatically when you save (⌘S)", local-vs-cloud tip), File → Restore from Backup… (`MaughamApp.swift:509-517`), the Restore window (`RestoreWindow.swift`: generations stamped Verified/Corrupt, **Restore a Copy…** — never in place), the "Backups paused — failed an integrity check" banner (`BackupRecoveryBanner.swift:18-24`). `getting-started.md:178,180` point at "Restore from Backup…" with nowhere to land. What ⌘S copies: the ENTIRE project folder (`BackupWriter.relativeFilePaths` — every regular file, no exclusions, symlinks skipped), skip-unchanged via `BackupSignature` (ignores checkpoints/sessions/ui-state/scratch/conflicts). — fix-shape: new topic `backups-and-history.md` + `index.json` row + links from getting-started — **M**
- **H2 ✔ — Bulk annotation actions described nowhere.** `review-passes.md:53-54` sends the reader to Annotations & Suggestions "for … bulk actions"; `annotations-and-suggestions.md:59` only says where the bar *isn't*. Surface: `AnnotationBulkActions.swift` — Accept/Stet/Triage, honest "Accept 4 of 6" counts, stale suggestions and queries excluded from accept, one summary notice, one ⌘Z per batch (and, since #41, one honest sentence when part of a batch can't be undone). — fix-shape: a "Working a batch" section after "Working the queue" — **M**
- **H3 ✔ — History's restore is one clause** (`right-pane.md:134`). Undescribed: filter chips All/Checkpoints/Edits/Annotations/External (`HistoryPane.swift:46-76`), what a checkpoint is (⌘S auto-label vs ⌘⇧S named — `CheckpointCapture.swift`; scope = manuscript text pointers only, no files copied), **Revert to "…"** with the whole-project / one-document scope picker (`PartialRestorePicker.swift:220-241`), the "Some checkpoints can't be read" notice (RULING-54). — fix-shape: fold into the Backups topic (checkpoint → history → revert → backup is one story) — **M**

**Medium**
- **M1 ✔ — `right-pane.md:116` names ⌘⌥I (Inspector; ends the study) where it means ⌘⌥0 (column toggle; hides it), twice** — contradicts its own earlier sentence. Same error in `release-notes/v0.32.0.md` (history; leave). — **S**
- **M2 ✔ — The in-app cheatsheet (⌘/ → Keyboard) labels three deleted panes** "Research pane"/"Outline pane"/"Palette pane" (`KeyboardShortcuts.swift:66,67,72`); `reference.md:5` and `screenplay.md:27` defer to it as "the full list". `DocSyncTests` checks tokens, not labels. — relabel per `reference.md:35-40` — **S**
- **M3 ✔ — ⌘? (Help → Maugham Help, `MaughamApp.swift:548`) is in neither table.** `DocSyncTests` guards only ⌘⌥ tokens; the comments at `KeyboardShortcuts.swift:30-40` record this hole biting three times before. — **S**
- **M4 — `claude-desktop.md:38-47`'s Write list omits publish templates/config (`WritePublishFileTool` et al.) and translations (`WriteTranslationTool`)** — both documented elsewhere; inventory gap on the membrane page. — **S**
- **M5 — `read_edition_brief`'s reason to exist is unstated** (`publish-department.md:130-138`); `read_visual_language` gets the sentence (`right-pane.md:84`) — copy the shape. — **S**
- **M6 — #33's refusal is documented for Send to Canvas (`getting-started.md:154`) but not for Claude's own canvas write** (`canvas_sidecar_unreadable`), on the list at `:158-171`. — **S**

**Low**
- L1 — `reference.md:57-76` on-disk layout omits `ops/`, `checkpoints.*.jsonl`, `Exports/`, `canvas.md` + `canvas_assets/`, `.maugham/publish/`, `.maugham/diagnostics/` — on the page that says "Everything important is plain text." — S
- L2 — `reference.md` Troubleshooting has no "won't open" / "older version back" entry. — S
- L3 — `getting-started.md:180` gives half the app's advice for the unlistable-folder case (omits "check permissions on `.maugham/ops`", which `DocumentRecoveryPane.swift:82-84` leads with). — S
- L4 — `publish-department.md:28` omits that "No translations yet." is deliberately withheld when a chapter is unreadable and there are no editions (`DepartmentPane.swift:233-241`). — S
- L5 — Share for Review… (`MaughamApp.swift:509-517`) is relied on by `annotations-and-suggestions.md:13` and never explained. — S

**Enforcement gap (process, not a doc line)**
- E1 — nothing pins: `docs/guide/*.md` ↔ `index.json` membership; inter-topic link/anchor resolution (H2 is this breaking); non-⌘⌥ bindings in `reference.md` (M3); cheatsheet *labels* (M2). `HelpTopicIndexTests` covers loader mechanics against a temp fixture, never the shipped directory. — fix-shape: three `DocSyncTests` cases (index census both ways; relative-link resolver over `docs/guide`; every `.keyboardShortcut(` in `MaughamApp.swift` has a `reference.md` row) + a planted-offender self-check each — **S–M**

## Binary triage (no defer bucket)

| Batch | Items | Verdict |
|---|---|---|
| **Doc topic: Backups & History** | H1 + H3 + L1 + L2 + L3 | Schedule (M) — one new topic + four small edits in the same branch |
| **Doc section: working a batch** | H2 | Schedule (M) |
| **Doc-truth smalls** | M1, M2, M3, M4, M5, M6, L4, L5 | Schedule (S each; one branch) |
| **Enforcement** | E1 | Schedule (S–M) — lands with the smalls so the ⌘? row and the cheatsheet relabel are pinned the day they're written |

Merit-drops: none. Nothing here is a fuzzy check.

## Refuted / verified-clean (so the next sweep doesn't re-chase)

- All M3/M4/references-shelf/publish-department/recovery-ladder guide sentences spot-checked against source: clean (see the agent's verified list — `DiagnosticsPane.swift:618-1338` four empty-state strings; `IntentStrip.swift:69`; `RoundNarrative.swift:139`; `DepartmentPane.swift:568-570`; `DepartmentCastSheet.swift:307`; `CanvasStore.swift:144`; `DocumentRecoveryPane.swift:62-84,160-190`).
- `reference.md`'s shortcut table: every `MaughamApp.swift` binding has a row EXCEPT ⌘? (M3); no row lacks a binding.
- The round ring's "six" in all guarded docs — pinned by `DocSyncTests` since #40 and clean.
- #35 has no writer-facing string; no doc gap.
- The guide is capability-first, not tool-first (`list_canvas`/`add_canvas_scraps` never named; their capabilities described at `claude-desktop.md:34,46`, `getting-started.md:158-171`) — a deliberate stance, not a gap; it is why M5 slips through and why "is this capability represented?" can't be automated by grepping tool names.

## Process notes

- Scoped check, one agent, ~40 minutes; the agent's territory map of the docs↔code seam (`HelpTopicIndex` as the single gate; three hand-mirrored keyspaces; what `DocSyncTests` does and does not pin) is the reusable part and is summarised in E1.
- The inverted-drift observation is worth carrying: the next full audit should ask "which shipped-before-2026-07 surfaces have a topic?" rather than only sweeping the window.
