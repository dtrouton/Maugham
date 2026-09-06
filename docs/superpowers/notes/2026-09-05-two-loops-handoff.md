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

### Smoke (Denver, on the laptop) — PASSED 2026-09-05, all fourteen steps, both projects

Open Playlist → Author → a chapter that has a stage set in Review → ⌘R → the Diagnostics header names *Le Guin reads this piece*, the report has no since-line, and Review's cockpit shows the SAME round number it showed before → Review → the cockpit shows the stage; Run round → *Reading the whole piece…* → round N+1, notes signed by the editor, since-line present → Author → ⌘R again → still Le Guin, still no round → board: clear the piece's pass → Review's cockpit says *Set a pass to run a round*, both buttons dead with a reason → ⌘R in Review over that piece → the capsule says *Set a pass to run a round.*, nothing runs → Project Settings → Vacate → Author ⌘R → *Claude reads this piece*, notes signed Claude → Restore. **Also open Playlist Test** (it holds the two `workshop`-stamped legacy sidecars): the chapters checked on 2026-09-03/04 should show their last check in Author, not the cold-start offer, and Review's cockpit should show no standing round for them.

## P2 built — 2026-09-06 (appended by the implementing session; overnight autonomous run)

**Branch `claude/two-loops-p2-2026-09-05`**, eight task commits (several with fix rounds, 3d685319..a66b9720) plus the whole-branch fix wave (fa8f242d — the review found no Critical; two Importants and the raw-value spelling, Rulings P2-10/11), merged to local `main` UNPUSHED. Plan: `docs/superpowers/plans/2026-09-05-two-loops-p2-the-first-reader.md`. Every task had a green `./scripts/test.sh`; Core tasks ran the package tests and the phone gate; the whole branch had `./scripts/test.sh full`, `./scripts/test.sh phone`, a Release build and a touched-file warning census (three warnings, all pre-existing on main — `DocumentStore.swift:821`, `StatementPane.swift:466/479` — for P3's sweep). ADR 0031 carries a dated *Amended* paragraph.

### What landed, by file

- **Core:** `Statement.Kind.firstReader` (raw `first-reader`, `StatementConvention.firstReaderPath = "first-reader.md"`, project scope only); `ProjectManifest.firstReaderName: String?` (tolerated-missing). Mac: `ProjectStore.setFirstReaderName(_:)` (trims; empty → nil).
- **`Maugham/Models/AuthorReader.swift`:** `coach` / `firstReader(FirstReader { name; statement })` / `nobody`; the CHOICE is `UIState.authorReaderChoice: AuthorReaderChoice?` (nil = default rule: coach while held, else first reader if named, else nobody); the ONE resolution `ProjectManifest.authorReader(choice:statementText:)`; `DocumentStore.setAuthorReaderChoice`. `activePass`/`heldPass` deleted.
- **`Maugham/Compiler/CompilerPrompt.swift`:** `readerSection(_:)` is the check's frame for all three arms — the coach's teacher frame moved here from `passSection` (byte-identical, pinned); the first reader gets her frame + the essay half of her statement + "Standing instructions from the writer:" from her `## Rulings` + `firstReaderInstruction` (names the four kinds in the schema's order; ends with the shelf rule). `checkMessage` has no `pass:`. `ActivePass.isCoach` GONE (census `test_isCoachIsGone`). Reader kinds: `dream_break|belief|drag|lost` (`DiagnosticIngest.readerKinds`; labels Dream break / Belief / Drag / Lost).
- **`Maugham/Compiler/DraftStage.swift`:** `LetterDosage.reader` — answer, about, working, ≤1 question; `allowsOneThing/allowsHabits/allowsProcess/allowsExercise/allowsScenes` false; enforced at ingest.
- **`Maugham/Compiler/CompilerOrchestrator.swift`:** `Environment.authorReader(docId)` / `roundEditor(docId)` replace `reader(docId, kind)`; the reader and her statement are read at the keystroke; a first reader is briefed with `stage: nil`, `signals: nil`, `lessons: nil` and dosed `.reader` whatever the stage or Reread; `CompilerRun.readerName` stamped on every check ("Claude" for nobody), nil for rounds; `StreamingRun.readerName`. Author's standing-run sites (signature, Keep, Add-to-intent provenance ×2) read `run.readerName ?? reader.editorName` — **P1's Ruling 10 carry is CLOSED**; the header and empty state read the live reader.
- **`Maugham/Views/FirstReaderRuling.swift` (new):** "Answer as ruling…" in Review's queue on her open, unstamped, untagged `.comment`/`.query`/`.craftNote` notes files a dated ruling into `first-reader.md` via `RulingPerformer` (single-writer census + planted `rule`/`edit`/`revoke` offenders); `RulingDestination` is the one decision shared by row, sheet and commit; `QueryRulingSheet` generalised to a confirmation sentence; `AnnotationRow.manifest` undefaulted.
- **`Maugham/Views/ProjectSettingsSheet.swift`:** **First reader** section beneath the coach's — name field committing on submit, focus loss, Done AND Escape (`.onDisappear`), through `nameNeedsCommitting(draft:stored:)` (trimmed both sides); **Describe…** / **Edit description…** (keyed on the statement's existence in the manifest) creates the statement, dismisses, and `ProjectWindow` writes `.firstReader` directly (a `.keyWindow` post is dropped at `onDismiss`, smoke 2026-09-06) only when Project Settings itself was the dismissed sheet (`opensFirstReader(requested:dismissed:)`, `presentedSheet` mirror, flag cleared on every presentation).
- **`Maugham/Views/DiagnosticsPane.swift`:** the header's reader line is a `Menu` — items from `readerMenuItems(manifest:)` (coach if held, first reader if named, Claude); "Define a first reader…" opens Project Settings; empty state "Press ⌘R and <reader> reads what you've written."
- **`DetailSegment.firstReader`** — "First Reader", **⌘⌥Y** (every letter of "first reader" is taken; the keyspace test demands a key), after `.lessons` in Author's and Review's panes; hosted by `StatementPane` (title "First reader", rulings stratum titled **Instructions**). Three extra exhaustive `Statement.Kind` switches took the conservative arm (not proposable, no bible, not a promotion target).
- **MCP:** `read_first_reader` (`Maugham/MCP/Tools/FirstReaderTools.swift`; `Result { exists, name, markdown, path }`; catalogue **60**); `CompilerAllowlistTests.statementWriters.subjects` gained `first_reader` AND `lessons` (a pre-existing census gap).
- **Docs:** the four guides, both AREA.md, CLAUDE.md (Compiler + MCP cells, tripwire 34), ADR 0031 amended, roadmap, problem-map row, spec status, `docs/skills/maugham-bootstrap/SKILL.md`.

### Rulings made on Denver's behalf (P2-1 … P2-11; rework any he disagrees with)

1. `DetailSegment.firstReader` is bound to **⌘⌥Y** — the keyspace test demands a key and every letter of "first reader" is taken (⌘⌥S was also free; Y chosen as "Your reader", S neighbours the ⌘S reflex).
2. `statementWriters.subjects` gained `"lessons"` as well as `"first_reader"`.
3. The CHOICE is UI state (`UIState.authorReaderChoice`); the NAME is manifest identity.
4. **`LetterDosage.reader` wins over the draft stage AND over Fresh Eyes/Reread** — a first reader is always the short reader form (§4.8's "always full on a cold read" is the coach's/editors' rule).
5. Author's Diagnostics pane gained NO "Answer as ruling" verb; the offer lives in Review's queue only.
6. `.reader` also drops `Letter.process`, and a first reader is briefed with no process section.
7. A first reader is NOT briefed on the lessons ledger (`lessons: nil`).
8. A `.nobody` check stamps `readerName: "Claude"` (non-nil) — the record says who signed; nil would mean "unknown" and fall to the live reader (Ruling 10's defect).
9. Her ANCHORLESS findings (minted `.craftNote`) ARE offered "Answer as ruling…" — a whole-piece observation is exactly what a standing instruction answers.
10. **A first reader's check judges no intent drift** — her briefing omits the `intent_drift` schema line and her run records no verdict, so the intent strip's mark is never hers (found by the whole-branch review: the one report section nobody had decided for her).
11. **`Statement.Kind.firstReader`'s raw value is `first_reader`** (snake, like `visual_language`), fixed before first ship; the FILE stays `first-reader.md` (files are kebab).

### Carries for P3

- The `read_first_reader` description and `docs/skills/maugham-bootstrap/SKILL.md` tell Claude to respond "in her position"; the **editing-pass skill** (`docs/skills/editing-pass/SKILL.md`) still describes the coach as the reader of unassigned pieces — P3's sweep (already listed).
- Three pre-existing warnings in branch files (above).
- The whole-branch review's ridden minors: dispositions are briefed to her unfiltered (prior coach/editor notes reach her with their craft vocabulary); switching reader changes the briefing hash (`lessons` nil for her) so the next check re-embeds the declared world — tokens only.
- Deferred minors ridden per the reviews: `readerMenuTitle(.firstReader)` answers "" when unnamed (unreachable); `try? createStatement` in Describe… is quiet on failure (consistent with the sheet); the two `roundEditor` reads per round press straddle `await prepareForRun` (P1's shape); the trim rule is spelled on write and on read (codebase precedent).
- Denver's picker only offers readers the project HAS; a first reader per piece, personality dials and a Review-side unread badge remain out of scope (spec §8).

### Smoke (Denver, on the laptop)

1. Playlist → Project Settings → **First reader** → type "Tabitha" → press **Escape** (not Done) → reopen Settings → the name is still there. *(pins the on-disappear commit)*
2. **Describe…** → the sheet closes and the right column lands on **First reader** (⌘⌥Y). Write three sentences and one `## Rulings` line ("always tell me where you got bored"). The rulings stratum is titled **Instructions**. *(pins the hand-off)*
3. Author → the header's reader line is now a menu: Le Guin · Tabitha · Claude → choose Tabitha → header *Tabitha reads this piece*; empty state names her.
4. ⌘R → her letter has answer/about/what she loved and at most one question — no habits, no one-thing, no scenes, no process line; notes signed Tabitha, unstamped (Review's queue shows them under every pass); a report may be labelled Drag or Lost.
5. ⌘⇧R (Reread) with Tabitha → still the short form.
6. Review → queue → **Answer as ruling…** on one of her notes (including one with no paragraph anchor) → the sheet's confirmation names her → `first-reader.md` gains a dated line under `## Rulings`.
7. Author → choose Le Guin → ⌘R → the coach's letter, full form, signed "— Le Guin"; then choose Claude → ⌘R → signed "— Claude". Switch the picker back to Le Guin WITHOUT running: the standing letter still signs "— Claude" (the record remembers who read).
8. Project Settings → Vacate the coach → the picker offers Tabitha · Claude and defaults to Tabitha → clear her name → the picker offers Claude and **Define a first reader…** (which opens Settings) → Restore.
9. Claude Desktop: `read_first_reader` returns `exists`, `name`, the markdown and `first-reader.md`.
10. Review → a chapter with a stage → Run round → unchanged from P1 (the editor's letter, since-line, numbered round).

## P3 built — 2026-09-06 — MILESTONE COMPLETE (appended by the implementing session; overnight autonomous run)

**Branch `claude/two-loops-p3-2026-09-06`**, four tasks. Plan: `docs/superpowers/plans/2026-09-06-two-loops-p3-the-polish.md`.

### What landed

- **The File menu names each persona's own verb** (Task 1, `4d43339c` + `14f51e75`): `RunMenuTitles` (`Maugham/Models/RunMenuTitles.swift`, two switches exhaustive over `Persona?` with no `default`) — Author, Plan and Publish and no focused window all read **Check Writing** / **Reread**; Review reads **Run Round** / **Fresh Eyes**. `nil` is Author's wording because `Persona.default` is `.author`, not as a fallback. `FocusedPersonaKey` + `FocusedValues.persona` (`MaughamApp.swift`) are published from `PersonaModifier.body` and read by `FocusedRunButtons` in the File menu; a first placement on `CanvasPromotionModifier` was moved there by review, and `RunMenuTitlesTests.test_theWindowPublishesItsPersonaFromThePersonaModifierAlone` is now the census. The two events are unchanged and each is posted exactly once from the menu (censused), so the run kind is still minted at the receiver — a title, never a decision. `docs/guide/{compiler,review-passes,right-pane,reference}.md`, the in-app cheatsheet (`KeyboardShortcuts.swift`) and CLAUDE.md's Compiler cell carry both titles per key.
- **The two skills know the split** (Task 2, `04815dba`): `docs/skills/editing-pass/SKILL.md` gained a **Two loops** section — a pass-voiced review is a round's editor and reads the whole piece rather than a diff; a reader response is a check's reader and reports what happened in the reading, never a fix — which also closes P2's carry that this skill still described the coach as the reader of unassigned pieces. `docs/skills/maugham-bootstrap/SKILL.md` says the lessons ledger is never briefed to the first reader; `Maugham/MCP/AREA.md` gained one clause on the check's reader against the round's editor.
- **Hygiene** (Task 3, `5709a71c` + `3bf58912`) — **two commits, and the second is a correction the review caught.** `DocumentStore.swift`'s unused `case .inbox(let kind, _)` binding is underscored. `StatementPane.swift`'s two catch sites had been switched to an unconditional `error as CustomStringConvertible` cast to silence the compiler's "always succeeds" warning, and that warning is statically wrong: for a plain Swift error with no conformance of its own the unconditional cast does not trap, it bridges through `__SwiftNativeNSError` and prints a case dump, where the `as?` it replaced correctly returned nil and fell through to `localizedDescription`. The fix is `StatementPane.userFacingMessage(_:)`, which casts through `Any` first — `(error as Any) as? CustomStringConvertible` — keeping the real dynamic check while dropping only the incorrect warning; both sites call it and `StatementPaneUserFacingMessageTests` pins it. **One correction to the review's own example, verified rather than assumed:** a real `NSError` natively conforms to `CustomStringConvertible` (bridged off `NSObject.description`), so the original pre-branch code and this fix both take the `.description` branch for it, and that description is the verbose domain/code/userInfo dump rather than `localizedDescription` — a mismatch that predates this branch and is not Task 3's to fix. Warning grep with both files touched is zero. P2's fix wave had already removed the literal catalogue count, so that bullet of Task 3 was a no-op.
- **The docs close** (Task 4): the roadmap's two-loops row flips •→✓ with P3's own paragraph and the milestone's open carries named; `docs/product.md` gains a **Getting read** paragraph (Author's check against Review's round, the coach and the first reader, `read_first_reader`); `docs/problem-map.md` gains a ✓ row for asking for feedback at the tempo you're working at; `CLAUDE.md`'s Compiler cell, `Maugham/Compiler/AREA.md` and `Maugham/Views/AREA.md` carry no forward reference to P3; the spec's status line reads COMPLETE with the carries named; ADR 0031 gains a **P3 built** amendment retiring its "two triggers keep their menu titles for now" consequence.

### Rulings made on Denver's behalf (the ledger's P3-1 … P3-3 plus the implementers' own, all recorded here)

1. Task 3's literal-count bullet was already done by P2's fix wave, so Task 3 is the two warning files only.
2. **The Review surface for a round's conformance strains is NOT built.** Spec carry #1 says Denver rules between two options; P3 records the choice with a recommendation rather than making it.
3. **`docs/constitution.md` is untouched** — it names neither the coach nor unassigned pieces anywhere, so no falsification condition moved with the seat.
4. **The `register/` sweep, listed as a P2 carry, is a no-op** — nothing under `register/` cites §4.1, the coach, `PieceReader` or Le Guin. Recorded rather than silently dropped.
5. **Two adjacent stale claims were corrected in the same pass** (CLAUDE.md's rule 10). `docs/product.md` claimed the MCP server exposes "55 tools" — a count neither `DocSyncTests` census covers, wrong since the catalogue reached 60 — and it now names no number at all. `docs/problem-map.md` still had "keep the lessons from feedback" at `~` with "a writer-readable, curatable digest is still open", which the lessons ledger shipped in the editorial letter's P2; it is ✓ and names the ledger.

### Denver decisions owed (the milestone's open carries)

1. **Where a ROUND's conformance strains are drawn.** Today a round records them in the round slot and no Review surface reads them (Author's Diagnostics pane draws the CHECK's). Options: (a) the cockpit's letter disclosure grows a **Conformance** part reading `lastRound`'s strains — report-side, matching one-loop §2's rule that strains stay report-side; (b) a round's strains **mint as annotations** into the queue, so the writer disposes of them like notes, which contradicts §2. **Recommendation: (a)** — it keeps conformance where every other surface has it and is a small slice (`ReviewRoundCockpit` plus `DiagnosticsStore.lastRound(docId:)`'s diagnostics, already stored).
2. **`retireSession()` on a kind change.** One warm `claude` session per window still serves both verbs, so a round after a long check re-sends the pass section but inherits that session's context. If a round ever reads tired, the fix is one line in `CompilerOrchestrator.ensureRunner` — retire when `kind` differs from the last run's. Not done; there is no evidence yet.
3. **Tag.** The milestone is whole once P2 and P3 are smoked. No paired release is needed: `firstReaderName` and `Statement.Kind.firstReader` are additive and tolerated-missing, and the phone decodes them through shared Core. Suggested `v0.36.0`, Mac-only, after the smoke.
4. Ridden minors from the reviews, if any of them bother him: dispositions are briefed to the first reader unfiltered, so prior coach and editor notes reach her carrying their craft vocabulary; switching reader re-embeds the declared world, because the briefing hash includes `lessons` and hers is nil; `LetterDosage` carries `judgesIntentDrift`, a reader fact living on a letter-dosage type (documented — a rename to a "reading's dose" type would be the honest shape); `try? createStatement` in Describe… is quiet on failure.

### Consolidated smoke (P2 + P3, one pass) — PASSED 2026-09-06 (after the Describe… hand-off fix caace2d0; one environmental find recorded in memory: a test gate run while the dev app is open unlinks its MCP socket, so checks fail "couldn't be read as notes" until the app is relaunched — fix owed: the test host must not bind the production socket path)

Build the dev app from local `main`.

1. Playlist → **Author** → the File menu reads *Check Writing* / *Reread*. ⌘2 → **Review** → it reads *Run Round* / *Fresh Eyes*. ⌘1 back → Author's titles return. Open a second project window, put it in Review beside the Author one: each window's menu reads its own persona when it is key.
2. Project Settings → **First reader** → type "Tabitha" → press **Escape** (not Done) → reopen Settings → the name is there.
3. **Describe…** → the sheet closes and the right column lands on **First reader** (⌘⌥Y). Write three sentences and one `## Rulings` line ("always tell me where you got bored"). The rulings stratum is titled **Instructions**.
4. Author → the header's reader line is a menu: Le Guin · Tabitha · Claude → choose Tabitha → header *Tabitha reads this piece*; the empty state names her.
5. ⌘R → her letter has answer/about/what she loved and at most one question — no habits, no one-thing, no scenes, no process line; the intent strip's drift mark does not change; notes signed Tabitha, unstamped (Review's queue shows them under every pass); a report may be labelled Drag or Lost.
6. ⌘⇧R (*Reread*) with Tabitha → still the short form.
7. Review → queue → **Answer as ruling…** on one of her notes (including one with no paragraph anchor) → the sheet's confirmation names her → `first-reader.md` gains a dated line under `## Rulings`.
8. Author → choose Le Guin → ⌘R → the coach's letter, full form, signed "— Le Guin"; choose Claude → ⌘R → signed "— Claude". Switch the picker back to Le Guin WITHOUT running: the standing letter still signs "— Claude".
9. Project Settings → Vacate the coach → the picker offers Tabitha · Claude and defaults to Tabitha → clear her name → the picker offers Claude and **Define a first reader…** (opens Settings) → Restore.
10. Claude Desktop: `read_first_reader` returns `exists`, `name`, the markdown and `first-reader.md`; ask for a pass-voiced review of a chapter and confirm the skill has it read the whole piece as a round's editor; ask for a first-reader response and confirm it never proposes a fix.
11. Review → a chapter with a stage → *Run Round* → unchanged from P1 (the editor's letter, since-line, numbered round). Playlist Test's two legacy `workshop` chapters still show their last check in Author and no standing round in Review.
