# Session handoff — "compiler / author / review split", 2026-09-05: spec + P1 plan written, nothing built

## State

- **Branch `claude/compiler-author-review-split-x5tv61`** (pushed to origin) carries docs only: the spec, the P1 plan, this note, supersession notes on two prior specs, and a roadmap line. **No code has changed.** The branch was cut from `origin/main` at `189e73e` (the tripwire-33 flake work). It was written in a cloud session with no Xcode; the laptop with the dev environment is where P1 gets built.
- Origin's `main` is `189e73e`. Local `main` on the laptop may be ahead (the editorial-letter handoff said the milestone shipped unpushed, then v0.35.0 was released — check `git log origin/main..main` before assuming anything).

## First ten minutes on the laptop

```
git fetch origin claude/compiler-author-review-split-x5tv61
git checkout main && git merge --ff-only origin/claude/compiler-author-review-split-x5tv61   # docs only; if not FF, rebase the four doc commits — nothing else is on it
git checkout -b claude/two-loops-p1-2026-09-05
./gen.sh && ./scripts/test.sh          # green baseline before a line moves
```

Then read, in this order:

1. `docs/superpowers/specs/2026-09-05-two-loops-two-readers-design.md` — the spec. §1 is the finding (read it even if you think you know it: the one-loop §7.0 → letter §4.1 reversal is the whole story), §3 the decisions, §4 the model, §7 the sequencing.
2. `docs/superpowers/plans/2026-09-05-two-loops-p1-the-two-verbs.md` — P1, ten tasks, subagent-driven. **Its `file:line` references were taken from `189e73e` and are already approximate** — every task says so; re-derive by grep before editing.
3. `Maugham/Compiler/AREA.md` §"who reads a piece" (`:227-263`) and `Maugham/Compiler/CompilerOrchestrator.swift` `beginRun` — the two places P1 cuts.
4. `docs/superpowers/notes/2026-09-02-editorial-letter-handoff.md` — the previous milestone's table of where things live; still accurate for everything P1 does not move.
5. This note's "Decisions made on Denver's behalf" and "Carries".

Add a memory entry at `~/.claude/projects/-Users-denver-src-Maugham/memory/` for this milestone (the cloud session cannot write there): the finding, the spec path, the three-plan shape, and that P1 is the first plan.

## The finding, in one paragraph (so a fresh session does not re-derive it)

`CompilerOrchestrator.runRequested` is one act serving two intentions and the persona is not an input to it. Author's ⌘R and Review's Run round build the same delta, send the same six-section prompt, resolve the same reader off `ActivePassMemory` (written only by Review's board chip and cockpit picker), file into the same lane, mint the same pass-stamped notes, and differ only in which pane draws the answer. The one-loop spec's §7.0 (Denver, 2026-08-17) ruled *wet-ink feedback is not a pass; the byline in Author stays "Claude"*; the letter spec's §4.1 (2026-08-29) bound the coach to "any piece with no active pass" and thereby let a stage editor sign Author's checks and number them as rounds — a reversal never recorded as one. Norman's name for the result is a mode error. The fix is two verbs over one substrate, with the coach as Author's reader full stop.

## Decisions made on Denver's behalf (in the spec and plan; rework any he disagrees with)

1. **The sidecar gets two standing slots** (check and round) rather than one, so neither loop's standing run overwrites the other's. Legacy sidecars load by `passId` (nil → check). This is P1's one storage-shape change and it is per-device, derived, and needs no migration.
2. **The ask is per tempo** — keyed `(docId, kind)`. Existing asks migrate to the check slot. The guide's "both homes show the same field over the same sentence" is rewritten in Task 6.
3. **Author's ⌘⇧R is *Reread*** (same reader, whole piece, cold, no round) rather than being withdrawn from Author. The alternative — Author has one key and a whole-piece verdict is Review's business — was considered and rejected because a writer returning after two weeks away wants exactly that from Le Guin, and the cold-start offer already promises a whole read on first contact. Denver did not rule on this explicitly; he agreed the spec as a whole.
4. **A round needs an editor**: no stage set → the cockpit's buttons are disabled with a reason and ⌘R in Review flashes *Set a pass to run a round.* and starts nothing. The chip menu is unaffected (a chip always names a pass).
5. **In P1 the Author reader line is a plain label** ("Le Guin reads this piece" / "Claude reads this piece"), not yet a picker — with only coach/nobody there is nothing to pick between. P2 turns it into the picker when the first reader gives it a second arm. The travel-to-Review click is removed in P1 because it IS the mode-error patch.
6. **The File menu keeps "Check Writing" and "Fresh Eyes" for both personas in P1.** A per-persona menu title is awkward under SwiftUI `Commands` (the key window's persona is not in scope there); P3 decides whether to rename to "Check / Reread" and "Run Round / Fresh Eyes" via a focused-value, or leave it.
7. **A round's conformance strains are recorded in the round slot and drawn nowhere in P1.** Today the Diagnostics pane in Author draws whatever the single standing run's strains are, which after P1 is the check's. Review has no strain surface. See carry #1.
8. **The rounds ring is rounds-only.** A superseded check never enters it. `latestRound` and the since-line are unaffected by checks — that is the point.
9. **`DraftStage` survives, doses checks only.** The spec is honest that persona (which loop) and stage (how far along the draft is) are two axes; a round is always the full letter.

## Carries (open, deliberate, not P1's)

1. **A round's strains have no Review surface.** Conformance is the substrate's under both verbs, but only Author draws strains. Options for P2/P3: the cockpit's letter disclosure grows a Conformance part; or a round's strains mint as annotations (contradicts one-loop §2's "strains stay report-side"). Denver to rule. Until then a round records them and nobody sees them.
2. **The menu titles** (#6 above).
3. **The first reader is P2** — spec §4.3 in full: `firstReaderName`, `Statement.Kind.firstReader`, the Project Settings row, the picker's arm, the four reader kinds (`belief`/`dream_break`/`drag`/`lost`), the short reader-form letter, `readerSection`, `read_first_reader`. P2 is written AFTER P1 is built (rule 11) and against the built `AuthorReader`.
4. **The editing-pass skill** (`docs/skills/editing-pass/SKILL.md`) and the register's rulings that cite the coach seat — P3's sweep.
5. **The book letter** (letter spec §10) is now clearly a *round* at project altitude; its brainstorm should start from `RunKind.round` with a project-scoped whole-piece section.
6. **Warm session across kinds.** One session per window still serves both verbs; a round after a check re-sends the pass section (already per-run). If Denver finds a round after a long check session reads "tired", the fix is `retireSession()` on a kind change — one line in `ensureRunner`, deliberately not done in P1.

## What P1 must leave true (the smoke, in Denver's hands)

Open Playlist → Author → a chapter with a stage set in Review → ⌘R → header *Le Guin reads this piece*, no since-line; Review's cockpit still shows the round number it showed before → Review → Run round → *Reading the whole piece…* → round N+1, notes signed by the editor, since-line present → Author → ⌘R → still Le Guin, no round → board: clear the piece's pass → cockpit says *Set a pass to run a round*, buttons dead with a reason → ⌘R in Review → capsule *Set a pass to run a round.*, nothing runs → Project Settings → Vacate → Author ⌘R → *Claude reads this piece*, notes signed Claude → Restore.

## P1 built — 2026-09-05 (appended by the implementing session; Task 10)

**Branch `claude/two-loops-p1-2026-09-05`**, nine task commits (b5fc3d46..fe72ee14, two with fix rounds) plus the whole-branch fix wave (333ca85a — the review found the milestone's Critical, see Ruling 8), merged to local `main` UNPUSHED. Every task had a green `./scripts/test.sh`; the whole branch had `./scripts/test.sh full` green (0 failures, the known baseline skips only), a Release build green, and a touched-file warning census with zero warnings in any branch file. ADR: `docs/adr/0031-the-persona-is-an-input-to-the-run.md`.

### What landed, by file

- `Maugham/Compiler/RunKind.swift` (new) — `check`/`round`; `RunKind.of(persona:)` minted in ONE production file, `Maugham/Views/CompilerRunModifier.swift` (census). `runRequested(docId:kind:freshEyes:)` — `kind` required. `CompilerRun.kind` + `effectiveKind` (legacy: `passId == nil` OR `passId == workshop` → check; see fix wave).
- `Maugham/Models/AuthorReader.swift` (new; `coach`/`nobody`; `ProjectManifest.authorReader` per PROJECT) and `Maugham/Models/RoundEditor.swift` (new; `roundEditor(forPiece:memory:)` via `validatedActivePass`, never the coach). `PieceReader.swift` DELETED. `Environment.reader(docId, kind)`. `Acknowledgment.noEditor` — a round with no stage flashes "Set a pass to run a round." and starts nothing. Censuses: `activePassMemory` absent from `AuthorReader.swift`; `effectiveCoach` absent from `RoundEditor.swift`/`CompilerEnvironment+Project.swift`; `passlessEditorName`'s one use is `AuthorReader.swift`.
- `Maugham/Compiler/CompilerPrompt.swift` — `checkMessage`/`roundMessage` over `runMessageV2(kind:)`; round = "The piece, whole:" + prior-round section, no stage, no process; check = delta + stage + process; `passSection` on BOTH kinds (the coach's frame is `ActivePass.isCoach`). `RoundNarrative.checkingCopy(_:kind:)` → "Reading the whole piece…".
- `Maugham/Compiler/CompilerOrchestrator.swift` — a round's delta is `since: nil`, moves no marker, records the marker it found; `DraftStage` derived and dosing CHECKS only; Reread (`.check, freshEyes`) and Fresh Eyes (`.round, freshEyes`) both retire the warm session; `previousRound` round-only.
- `Maugham/Compiler/DiagnosticsStore.swift` — `FileContent.check`/`.round` (`Standing { run, diagnostics }`), legacy `run`/`diagnostics` keys read never written; `lastCheck`/`lastRound`; `lastRun` = newer-of-two (only `IntentDrift.mayTrailDraft`); ring/`standingRound`/`latestRound` rounds-only; `lastOpId`/`live`/`dismiss` check-slot; `unread` per `SlotKey`; the `.diagnostics` badge counts the CHECK slot only and Author's pane marks only `.check` read; asks keyed `docId#kind`, legacy bare key → check.
- `Maugham/Views/DiagnosticsPane.swift` — plain reader label ("Le Guin reads this piece"/"Claude reads this piece"), **Reread** button, no round/fresh-eyes/since lines, no travel; `DetailPaneToggle.openBoardInReview` deleted. `MaughamTests/RoundNarrativeTests.swift` (new) holds the moved narrative tests.
- `Maugham/Views/Review/ReviewRoundCockpit.swift` — stages only; "Set a pass to run a round"; `noEditorReason`; both buttons disabled without a pass; `emptyQueueTeaching` nil arm rewritten. `AnnotationsPane` — `letterVoice` resolves the letter verbs' byline from the ROUND slot's own `passId`; `cockpitStage`/`coach:` gone. `ReviewBoardPane` — no seat row. `LetterKeep` keeps the coach-lane heading for kept letters over historical `workshop` rounds (legacy).
- `Maugham/Views/AskField.swift` — `Input.kind`; Author `.check`, cockpit `.round`.
- Docs: ADR 0031 + index row (+ a one-line amendment back-link under ADR 0029); `CLAUDE.md` Compiler cell + tripwire 34; both AREA.md files; `docs/guide/compiler.md` (Who reads a check, Reread, per-tempo ask), `review-passes.md`, `annotations-and-suggestions.md`, `right-pane.md`; roadmap rows; spec status + §4.9 P1 note.

### Rulings made on Denver's behalf during the build (rework any he disagrees with)

1. Task 2 left `onOpenBoard`; Task 7 removed it. 2. Task 2 left the cockpit's `coach:`/`stage:`; Task 8 removed them.
3. **P1 keeps `CompilerPrompt.passSection` as the coach's frame on a check** (`isCoach: true`); the spec's `readerSection` arrives with P2's first reader.
4. The cockpit's empty-queue teaching takes the bare optional editor name ("Run Claude's round" is never drawn).
5. **The cockpit's letter verbs take their byline from the round slot's own `passId`** (`AnnotationsPane.letterVoice`), never the current selection.
6. **The `process` section is the check's alone** — spec §4.9's round list omits it; an editor reads the manuscript, not the writer's habits. `roundMessage` takes no `signals`.
7. ADR 0029 carries a one-line amendment back-link to 0031 though house precedent adds none.
8. **A legacy `passId == workshop` sidecar record is a CHECK** (`effectiveKind`) — the spec's §1 says every coach-lane run was a wet-ink check. Found by the whole-branch review against two real sidecars on this Mac (Playlist Test, 2026-09-03/04); without it Author's pane went blank over a piece checked yesterday, a standing strain vanished, the marker reset, and the cockpit drew Le Guin's letter as a standing round.
9. **The unread badge on the `.diagnostics` segment is Author's** — counts the check slot only; Author's pane marks only `.check` read. A round's per-slot count is recorded but no P1 surface counts it (its notes are open rows in Review's queue).
10. **Accepted carry → P2:** a check's `CompilerRun` carries no reader identity, so after Vacate a standing Le Guin letter / a kept note / a ruling's provenance re-sign "Claude". P2 stamps `CompilerRun.readerName` at record and reads it at every Author display site, mirroring `letterVoice`.
11. "Notes in your queue" stays (names no persona).

### Carries for P2/P3 (beyond the spec's list)

- `CompilerRun.readerName` (Ruling 10). - A Review-side unread badge for a round's `mintedNotes` (Ruling 9), if wanted. - `readerSection` replaces `passSection` as the check's frame when the first reader lands (Ruling 3). - A round's conformance strains are recorded in the round slot and drawn nowhere (spec carry #1). - Menu titles (carry #2). - Deferred minors ridden per the final review's triage: `DiagnosticsStore.load`'s unreadable-file branch can leave a discarded preview in the other slot (latent; one preview at a time); `runHelp`'s nil arm unreachable from the view; the cockpit mount census's bare "coach" assertion is case-sensitive; `wholePieceSection`'s empty wording differs from `deltaSection`'s.

### Smoke (Denver, on the laptop)

Open Playlist → Author → a chapter that has a stage set in Review → ⌘R → the Diagnostics header names *Le Guin reads this piece*, the report has no since-line, and Review's cockpit shows the SAME round number it showed before → Review → the cockpit shows the stage; Run round → *Reading the whole piece…* → round N+1, notes signed by the editor, since-line present → Author → ⌘R again → still Le Guin, still no round → board: clear the piece's pass → Review's cockpit says *Set a pass to run a round*, both buttons dead with a reason → ⌘R in Review over that piece → the capsule says *Set a pass to run a round.*, nothing runs → Project Settings → Vacate → Author ⌘R → *Claude reads this piece*, notes signed Claude → Restore. **Also open Playlist Test** (it holds the two `workshop`-stamped legacy sidecars): the chapters checked on 2026-09-03/04 should show their last check in Author, not the cold-start offer, and Review's cockpit should show no standing round for them.
