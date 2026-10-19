# Batch F: words never written over, backups that find and keep their book (#88, #92, #90, #91) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A canvas whose files can't be read right now is never written over. Restore and backups find the right book, and a restored copy is its own book. A missing project file is put back from its safety copy. A named save point backs up. History stops promising what nothing records.

**Architecture:** Each fix sits where its decision lives. **Read `docs/superpowers/notes/2026-10-19-batch-f-research.md` first.** It was written on main 4b20d96c. The foundations integration (53cf6880) has since split `ProjectWindow.swift` (CentreColumn/RightColumn/CentreRoute/ProjectSession…), so **re-find every line the note cites**. Its facts and fix shapes stand.

**Tech Stack:** Swift, SwiftUI, XCTest; MaughamCore.

**Spec:** issues #88, #92, #90, #91, plus Denver's rulings (2026-10-19).

## Rulings

- **Denver (#92.2):** a restored copy is a separate book with its own identity and backups. `BackupRestore.restoreBeside` mints a new manifest id and rewrites the manifest shadow to match. The research found nothing in the signed op log, the register or permits keyed on the manifest id. The phone keys captures and recents on it, which is exactly why a copy must not share it.
- **Denver (#92, missing manifest):** if `project.maugham.json` is missing and its shadow is intact, Maugham restores the file from the shadow and opens the project. It shows one line: *"This project's settings file was missing, so Maugham put it back from its safety copy."* Use the window's existing notice surface; find the one the integration's ProjectSession/CentreColumn uses for one-time notices. A corrupt manifest already self-heals (research). Only "missing and shadow good" is new.
- **Denver (#92.3):** restoring asks for a FOLDER (`NSOpenPanel`, directories only). Maugham names the copy itself: *"<project> (restored)"*, then *"(restored 2)"*, *"(restored 3)"*…, never an existing name. `RestoreTarget`'s refusal stays as a backstop.
- **Denver (#90):** a named save point (⌘⇧S) runs the same backup ⌘S does. The drafted patch on issue #90 predates the split, so re-derive it. ⌘S's backup now lives in `Maugham/Views/CheckpointModifier.swift`.
- **Denver (#91):** History's **External** filter is removed: the chip, its icon, its filter arm and its empty-state line. The trash-path AREA line is the oplog session's (plan 5); this batch fixes only the code comments and `EmissionContract.swift` (regenerate `EMISSION.md` by running its test).
- **Controller (#88):** the new reason is `.unreadable`. It covers EITHER file (`canvas.json` or `canvas.md`) existing but unreadable, including an iCloud placeholder or a dataless file that can't download. It is checked without blocking the main thread on a download. It is read-only, with no Start a Fresh Layout. Sentence: *"Maugham couldn't read this canvas's files just now, so it can't be changed yet. If the project is in iCloud they may still be downloading — Maugham will keep trying."* Add a **Try Again** button, which the integration has unblocked. Maugham also retries on its own (bounded, e.g. every 10 s while the canvas is shown), and the canvas becomes editable in-session once both files read.

## Global Constraints

- **Coordination:** the oplog session is running plan 5, which slims every AREA.md. Keep AREA edits to small sentences, and do NOT touch the Stores AREA trash line (theirs). Whoever lands second rebases. Ping oplog before merge. If `DocBudgetTests` reds on an AREA edit, raise that file's ceiling with a reason.
- New tripwires: 55 asks by capability, never `ProjectType ==`/`DocumentFormat ==`. Tripwire allow-lists are keyed `type:<Name>` via `SourceTree`. Read `docs/tripwires.md` for anything you touch.
- Tripwire 14 (typed mover) for user content. Tripwire 33 (no clicks, no press-then-wait).
- Tests build fixtures under `TestTemp.root` only. An unreadable file is simulated with `chmod 000`, a directory at the file's path, or an injected reader seam.
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`, and run `./scripts/test.sh full` before the PR. Never `pgrep -f xcodebuild`. If Core fails with only a `started.` line, re-run.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. **An unreadable `canvas.md` never becomes an empty `canvas.md`.** Neither does an unreadable `canvas.json`. Both files are byte-identical after any interaction, and after a quit.
2. **The unreadable check never blocks the main thread** waiting for iCloud.
3. **A restored copy's backups never touch the original's.** They go to a different backup key, and retention counts separately.
4. **Restoring a missing manifest never overwrites a present one.** It happens only when the file is absent and the shadow decodes.
5. **⌘⇧S backs up through the same call as ⌘S**, with the same integrity check and skip-if-unchanged.

---

### Task 1: The canvas store refuses a file it can't read (#88)
Research §#88. In `CanvasStore`, distinguish *absent* from *present but unreadable* for both `canvas.json` and `canvas.md`. Reuse the app's existing iCloud stub/placeholder probe (named in the research), so nothing blocks on a download. Add `SidecarRefused.Reason.unreadable` with the Ruling sentence. The store refuses writes after it; the model is read-only (existing #44 machinery). Claude's tools give `canvas_sidecar_unreadable` with a hint for this reason. `list_canvas` reports `layout_readable: false`. `setDamagedSidecarAside` and `loadForTransientWrite` see it too.
- Tests: unreadable `canvas.json` (and, separately, unreadable `canvas.md`) give `.unreadable`. Every write verb then leaves both files byte-identical. An absent file is still `.absent`. A placeholder file is `.unreadable`.
- Commit: `fix(canvas): a canvas file that can't be read right now is never written over (#88)`

### Task 2: Try Again, and retrying on its own (#88)
For `.unreadable` only:
- `CanvasReadOnlyNotice` shows **Try Again**. It calls one model verb that re-attaches, so a successful read lifts every read-only layer in-session (the #44 lift path).
- A bounded automatic retry runs while the canvas is shown and the reason is `.unreadable`.
- Add one sentence to the guide's *When the canvas is read-only* section (`docs/guide/getting-started.md`), and one to Canvas AREA.

Tests: the verb lifts read-only once the file becomes readable, and stays read-only while it isn't. The retry schedule is a pure, testable decision. Windowless only.
- Commit: `feat(canvas): a canvas that couldn't be read tries again (#88)`

### Task 3: Restore finds the book, and a missing project file comes back (#92.1, Denver's missing-manifest ruling)
Research §#92.1:
- `BackupCoordinator.projectKey` tries the manifest id, then the shadow's id, then the folder name.
- `RestoreWindow` offers "Show All Backups" as a last resort when none are found for this project.
- On open, when `project.maugham.json` is missing and its shadow decodes, restore the file from the shadow (never over a present file), open, and show the Ruling's one line once.

Tests: projectKey order; restore-from-shadow only when absent and the shadow is good, never over a present or corrupt file (a corrupt one already self-heals); the notice sentence.
- Commit: `fix(backups): restore finds a book whose project file is gone, and a missing project file is put back (#92)`

### Task 4: A restored copy is its own book, and you pick a folder (#92.2, #92.3)
- `BackupRestore.restoreBeside` mints a new manifest id and rewrites the shadow to match (Core).
- The Restore window asks for a folder (`NSOpenPanel`, directories only) and names the copy itself (pure naming function, with the collision sequence from the Rulings).
- Keep `RestoreTarget` as a backstop.
- Update `docs/guide/backups-and-history.md`'s restore paragraph (the save-panel wording and the "Restore failed: Something named…" sentence change; a copy now has its own backups).

Tests: the new id differs and the shadow matches; the copy's backup key differs from the original's; the naming sequence.
- Commit: `feat(backups): a restored copy is its own book, restored into a folder you pick (#92)`

### Task 5: A named save point backs up (#90)
Route ⌘⇧S's confirm path through the SAME backup call ⌘S uses (`CheckpointModifier.swift`; re-derive the patch on issue #90). Update `BackupSettingsTab`'s "(⌘S)" sentence to name both. Update the guide (`backups-and-history.md#checkpoints`, `reference.md`'s ⌘⇧S row, the Backups ⌘S wording, `editor-and-focus.md` if it says only ⌘S backs up).
- Tests: a named checkpoint writes a backup generation to a temp destination, through the same call (windowless).
- Commit: `feat(backups): a named save point backs up too (#90)`

### Task 6: History stops promising external edits; trash path in code (#91)
- Remove the **External** filter: its `HistoryPane` cases (chip, icon, filter arm, empty-state line `"No external edits"` and its hint) and any test that pins it. Update the guide's History filter list.
- Fix the `.maugham/trash/` mentions in `MaughamSidecarPath.swift` comments and `EmissionContract.swift`, then regenerate `EMISSION.md` via its test.
- Leave the Stores AREA trash line alone (it belongs to oplog plan 5).
- Commit: `fix(history): no External filter; the trash path is right in code (#91)`

### Finish
- [ ] `./scripts/test.sh full`, green.
- [ ] Whole-branch review (opus), told not to build.
- [ ] Ping oplog before merge.
- [ ] PR closing #88, #92, #90 and #91, with Denver's smoke steps.
