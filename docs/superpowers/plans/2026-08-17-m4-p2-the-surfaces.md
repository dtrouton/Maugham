# M4 P2 — The Surfaces: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author gets its wet-ink feedback back (§7.0's "This check" section — the latest run's minted notes, in place, one-gesture dispositions); Review gets the round cockpit (pass + editor + round + Run affordance + progress + the comparison, in the queue where the reviewer lives) and a board chip that can start a round; Desktop's reader gets the pass briefs through `get_outline` and a rewritten editing-pass skill; the guide catches up; P1's carried items close.

**Architecture:** No new `DetailSegment`, no registry change — "This check" is a section inside `.diagnostics`, the cockpit is a strip inside `.annotations` (below the toolbar's `Divider()`, the `passOrderNudge` precedent — NEVER in the width-census-bound toolbar). The round narrative and progress copy hoist from `DiagnosticsPane` statics to a free type so Review reads them without a Review→Pane dependency. The orchestrator/diagnostics stores already reach `DetailPaneToggle`; they thread one hop further into `AnnotationsPane`. All dispositions are the annotation layer's own verbs — nothing new is stored anywhere.

**Tech Stack:** Swift / SwiftUI / AppKit; MaughamCore SPM; XCTest.

**Spec:** `docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md` §7.0 (This check — Denver's smoke correction), §7 (cockpit), §4 (briefs served to both readers), plus the P1 ledger's carried items (recorded in `docs/superpowers/notes/`? — no: carried in this plan's Global Constraints below).

## Global Constraints

- **Persona = tempo (Denver's ruling, §7.0).** Author imports NO queue machinery — no triage, no bulk, no backlog; "This check" shows only the latest run's mints and shrinks as the writer disposes. Review's cockpit imports no editor-surface behavior. Adding `.annotations` to Author's registry was considered and REJECTED by Denver — do not resurrect it.
- **One home, many viewports**: every row anywhere is a live VIEW of the annotation (`document.annotations(...)` + `annotationsVersion` observation); dispositions are `Document.accept/reject/…Annotation` with the window's `undoManager`; nothing is cached or mirrored.
- **The toolbar width census binds**: `AnnotationsQueueToolbarWidthTests` measures every variant inside `detailColumnWidthRange` (240–480pt). The cockpit strip lives BELOW the divider and wraps freely; it never joins `oneRow`/`twoRows`.
- **Run-state reading is docId-scoped** (`headerState`'s `where runDocId == docId` pattern) — the cockpit is the second reader of `orchestrator.runState`; a run on another document must read as idle.
- **⌘R's semantics do not move**: the cockpit's Run button and the chip's Run item post through the SAME paths (`orchestrator.runRequested` directly, the pane-"Read"-button precedent, or the `MaughamEvent` — one spelling per site, stated in the task). Keystroke-only constitution intact — every new affordance is a writer's click.
- **Chip-run timing hazard (named)**: `runRequested(docId:)` silently refuses when the document isn't open (`reading(docId) == nil`); a chip click navigates first and the open is async. The chip's Run item must not race it — the task specifies the deferral and its test.
- **MCP**: `PassInfo` gains `brief` only (via `ReviewPass.effectiveBrief` — the ONE resolution spelling, never `$0.brief` raw); no new tools; the count does not move.
- **Gates**: `./scripts/test.sh` iterating; `./scripts/test.sh full` (no skips) pre-merge; package tests after touching MaughamCore (only T4 might); Release build after any `ProjectWindow.body` change (T2/T3 touch its wiring — check). `grep -a` on gate logs.
- **Dispatch notes**: FOREGROUND gates only — do NOT background the gate and idle; poll with repeated Read calls; a turn ended without a tool call in flight is a stall (this stalled three dispatches in P1 — it is the first thing checked on your report). Reviewers report, don't fix. Falsifications shown red in reports. Opus for Tasks 1, 3, 4; sonnet for 2, 5, 6, 7, 8.
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Carried from P1's ledger, closed by this plan**: seam-(a) census (T7); round-1/passless empty-state copy (T1 closes the Author side; T3's cockpit closes Review's); prompt-cost measurement (T7); `DiagnosticsPaneTests:978` stale `readerSection` comment (T7); the guide's board/queue/what-Claude-sees sections (T8). NOT carried (stands as ruled): `compilerFreshEyes` earns-its-keep re-ask waits for M4 close.

---

### Task 1: "This check" — Author's wet-ink view (§7.0)

**Files:**
- Modify: `Maugham/Views/DiagnosticsPane.swift`
- Test: `MaughamTests/DiagnosticsPaneTests.swift`, `MaughamTests/CompilerRunCommandTests.swift`

**Interfaces:**
- Consumes (verified): `queueAnnotations` (`:190-194` — activeDocument + docId guard + `annotationsVersion` observation + `AnnotationFilter(statuses: nil)`); `lastRun` (`:125`); `Annotation.compilerRunId/isCompilerAuthored`; `content`'s `LazyVStack` order `freshEyesLine → roundLine → driftLine → conformanceSection` (`:593-620`) and the empty-report arm (`:597-608`); `DiagnosticRow`'s shape (`:1306-1371` — private and typed to `Diagnostic`: COPY the shape as a sibling struct, don't widen the type); `PaneSectionHeader` (`:1217`); the disposition verbs `Document.acceptAnnotation/rejectAnnotation(id:userResponse:undoManager:)` (`Document+Annotations.swift:437/:729`) and AnnotationsPane's executor discipline (`performAccept` `:988` — catch `.suggestionAnchorLost` explicitly, never `try?`; moot here since the compiler mints no suggestions, but keep the shape).
- Produces:
  - `thisCheckAnnotations: [Annotation]` — `queueAnnotations` filtered to `compilerRunId == lastRun?.id && status == .open` (a disposed note leaves the view; the next run's `lastRun` swap replaces it wholesale).
  - A **"This check"** section rendering between `roundLine` and `driftLine`, AND in the empty-report arm (a no-intent run's notes must show — this is the state that started §7.0). Each row: the note's body, kind glyph, `ExcerptChip`-style jump for its anchor, and two `.bordered .small` verbs — **Got it** → `acceptAnnotation`, **Not this** → `rejectAnnotation` (no reason field — one gesture; the reason-carrying decline lives in Review's queue). Byline not shown (Author's view; the author column is Review's).
  - `offersDurableActions` gates the verbs exactly as it gates Answer/Promote (a streaming run's half-arrived state must not dispose).
- [ ] **Step 1: Failing tests.** Mounted: a run minting two notes on a no-intent piece renders the section above the empty state with both rows; **Got it** on one (real button through the accessibility tree) → the row leaves, the note's status is `.accepted` in the op log, the queue in Review sees it settled; **Not this** → `.rejected`; the section is empty (absent) for a run that minted nothing, for a superseded run's notes (mint run 1, run 2 mints different → only run 2's show), and for another document's notes (docId guard). The next round's briefing lists the rejected note as settled (end-to-end, CompilerRunCommandTests). Undo: ⌘Z after Got it reopens (existing machinery — assert it fires through the pane's undoManager). Live update pinned: dispose AFTER mount+pump, assert the row left (the T5 observation-seam discipline).
- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement.**  **Step 4: `./scripts/test.sh`** — green.  **Step 5: Commit** — `feat(author): This check — the wet-ink view of what the run just raised`

---

### Task 2: Hoist the round narrative — `RoundNarrative`, one home for the copy

**Files:**
- Create: `Maugham/Compiler/RoundNarrative.swift`
- Modify: `Maugham/Views/DiagnosticsPane.swift` (statics move out; call sites re-point)
- Test: mechanical relocation — existing tests re-point (`DiagnosticsPaneTests`' direct static calls), no behavior change

**Interfaces:**
- Consumes (verified): the statics on `DiagnosticsPane` today — `sinceLastRoundLine(history:run:annotations:)` (`:878-894`), `freshEyesHeader(run:)` (`:913`), `checkingCopy(_:)` (`:481`), `paragraphPhrase(_:)` (`:489`), and `queuedNotesSentence` if referenced across (check). Review may not depend on DiagnosticsPane (the survey's named hazard).
- Produces: `enum RoundNarrative` in the compiler area carrying those functions verbatim (same signatures, same tests, moved not rewritten); `DiagnosticsPane` delegates. No copy changes whatsoever in this task — byte-identical strings, pinned by the existing tests passing with only the receiver renamed.
- [ ] **Step 1: Move + re-point; run the two suites; `./scripts/test.sh`** — green (this task is transcription; a failing test means the move changed behavior — stop and look).
- [ ] **Step 2: Commit** — `refactor(compiler): the round narrative hoists to RoundNarrative — one home for the copy both personas read`

---

### Task 3: The round cockpit — Review's strip

**Files:**
- Modify: `Maugham/Views/AnnotationsPane.swift` (the strip, below the toolbar divider)
- Modify: `Maugham/Views/DetailPaneToggle.swift` (`annotationsPane` threads `compilerOrchestrator`/`diagnosticsStore`/`activeDocId`/`onSetActivePass`)
- Modify: `Maugham/Views/ProjectWindow.swift` (the `onSetActivePass` closure — calls the existing private `recordActivePass(forPiece:passId:)` `:3049`, the ONE writer)
- Test: `MaughamTests/AnnotationsPaneTests`-family + a mounted cockpit suite; `AnnotationsQueueToolbarWidthTests` must pass UNMODIFIED (the strip is not in the toolbar)

**Interfaces:**
- Consumes (verified): the mount point between `Divider()` (`:346`) and `passOrderNudge` (`:347`; the strip precedent `:481-498`); `resolvedPassId` (`:230`), `reviewPasses` (`:207`), `activePassMemory` (`:211`); `ReviewPass.effectiveEditorName`; `DiagnosticsStore.roundHistory(docId:)`/`lastRun(docId:)`; `orchestrator.runState` (SECOND reader — docId-scope with `headerState`'s `where` pattern or a small pure helper beside `RoundNarrative`); `RoundNarrative` (T2); `orchestrator.runRequested(docId:freshEyes:)` (the pane-"Read"-button precedent `:646`); `DetailPaneToggle` already holds `compilerOrchestrator`/`diagnosticsStore`/`persona` (`:35-36/:13`).
- Produces, in the strip (document scope only; project scope shows nothing — the cockpit is a piece's):
  - The lane line: `"<Pass> · <Editor> · round N"` (round from the lane's newest record; "round —" before any); when no pass is active, a **pass picker** ("Set a pass ▾" menu over `effectiveReviewPasses`) whose selection calls `onSetActivePass(docId, passId)` — the write stays `ProjectWindow.recordActivePass`, one spelling.
  - **Run round (⌘R)** and **Fresh Eyes (⌘⇧R)** buttons → `orchestrator.runRequested(docId:, freshEyes:)`; disabled + reason while `runState` is running for this doc.
  - While running: `RoundNarrative.checkingCopy` ("Checking N paragraphs…"); after: the since-last-round line (`RoundNarrative.sinceLastRoundLine`) or the fresh-eyes header — the same mutual exclusion the pane keeps.
  - Empty-queue teaching (closes the Review copy carry): when the filtered queue is empty in document scope, the empty state names the two ways it fills — "Run <Editor>'s round (⌘R), or ask Claude in Claude Desktop."
- [ ] **Step 1: Failing tests.** Mounted: cockpit shows lane/editor/round for a piece with an active pass; the picker appears exactly when no pass is active and its selection records through the window's one writer (assert `uiState.activePassMemory`); Run button drives a real run end-to-end (notes land authored by the editor — the Gould-not-Claude smoke, pinned); running state shows the checking copy and disables the buttons; another document's run leaves this cockpit idle (scope falsification: drop the docId scope → red); project scope renders no cockpit; toolbar width tests untouched-and-green.
- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement.**  **Step 4: `./scripts/test.sh` + Release build if ProjectWindow.body moved** — green.  **Step 5: Commit** — `feat(review): the round cockpit — pass, editor, round, run, and the comparison where the reviewer lives`

---

### Task 4: The chip runs a round + the board teaches

**Files:**
- Modify: `Maugham/Views/Review/ReviewBoardPane.swift` (`ReviewBoardChipVerbs` widens; chip context menu)
- Modify: `Maugham/Views/ProjectWindow.swift` (the run-from-chip closure: record pass → navigate → deferred run)
- Test: `ReviewBoardPane`'s suites (the truth-table discipline `:356-366` — the menu's contents are tested via `chipMenuItems`, never the headless `.contextMenu`); `CompilerRunCommandTests` for the deferred run

**Interfaces:**
- Consumes (verified): `chipMenuItems(for:passId:current:) -> [ChipVerb]` (`:406-415`), `ChipVerb` (`:375-386`, `id = title`); the chip's `.contextMenu` `ForEach` (`:320-350`); `onNavigate` mount wiring (`ProjectWindow.swift:1894-1897`); **the timing hazard**: `runRequested` silently refuses while the doc is unopened — the deferral must wait for the subject's document to be open before running.
- Produces:
  - `ReviewBoardChipVerbs` gains the run verb (a separate `runVerb(for:passId:) -> ChipVerb`-shaped entry or a widened item list with a divider — testable truth table either way): title `"Run <Editor>'s round"`.
  - The window's run-from-chip closure: `recordActivePass` → `selectedSubject = .item(pieceId)` → run once the document is open — the deferral is a bounded poll/observation on the document's availability (NOT a fixed sleep; state its bound), then `orchestrator.runRequested(docId:)`. A doc that never opens (load failure) drops the run silently-with-log, never crashes.
  - The board's rows-empty state stays; the per-piece teaching lives in T3's queue empty state (no board change beyond the verb).
- [ ] **Step 1: Failing tests.** Truth table: the run verb present per chip with the editor's name; performing it records the pass, sets the subject, and a real run lands (end-to-end — the note authored by that pass's editor); the deferral falsification: run immediately without waiting → the refusal reproduces (shows the hazard is real), with the deferral → green; a load-failure drops the run without hanging.
- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement.**  **Step 4: `./scripts/test.sh` + Release build check** — green.  **Step 5: Commit** — `feat(review): a board chip can start the editor's round`

---

### Task 5: `get_outline` serves the briefs

**Files:**
- Modify: `Maugham/MCP/Tools/ProjectTools.swift` (`PassInfo` + emission + description)
- Modify: `Maugham/MCP/AREA.md` (one line: the widening)
- Test: `MaughamTests/MCP/Tools/ProjectToolsTests.swift` (raw-JSON, the `:71-124` rubric + `makeReviewProject(reviewPasses:)` fixture)

**Interfaces:**
- Consumes (verified): `PassInfo { id, name }` (`:105-108`, deliberately local — the wire must not move because a model type grew a field); emission `:218-220` off `effectiveReviewPasses`; `ReviewPass.effectiveBrief` (the ONE spelling — a preset-id stored pass with nil brief must serve the preset's brief).
- Produces: `PassInfo.brief: String?` (init param defaulted for source-compat), emitted via `effectiveBrief` — present for presets and briefed customs, JSON `null` for a briefless custom (encode, not encodeIfPresent — the uniform-null house rule); the tool description gains one sentence (each pass's editorial brief, writer-editable). NOT `editorName` — the wire serves doctrine, not personas (spec §4).
- [ ] **Step 1: Failing tests** (raw JSON): a preset ladder serves four non-null briefs; a customized pass with its own brief serves it; a briefless custom serves `"brief": null` (key present — falsification: encodeIfPresent → red); a stored preset-id pass without the field serves the PRESET's brief (the effectiveBrief discriminator).
- [ ] **Step 2: Run** — FAIL.  **Step 3: Implement.**  **Step 4: `./scripts/test.sh`** — green.  **Step 5: Commit** — `feat(mcp): get_outline serves each pass's editorial brief`

---

### Task 6: The editing-pass skill reads the ladder

**Files:**
- Modify: `docs/skills/editing-pass/SKILL.md`
- Test: none mechanical (the SkillsExtension serves bundled content; `./scripts/test.sh` covers the index)

**Interfaces:**
- Consumes (verified): the skill's current five-item structure; item 2's three hardcoded registers + status-inference (the contradiction: the Tools section already says nothing writes `status`); `get_outline` now serving `review_passes[].brief` (T5) beside `pass_states`/`review_status`.
- Produces: item 2 rewritten — *read the project's own ladder*: `get_outline`'s `review_passes` (order + briefs) and the piece's `pass_states`; run the pass the writer names, else the piece's most-advanced in-progress pass, else propose from the states and ASK; **attend per that pass's `brief`** (the writer's own doctrine — it overrides the generic registers, which are deleted); still open by declaring the chosen pass. Items 1/3/4/5 and Constraints/Tools stay (Tools gains one sentence on `brief`). Register: the skill's existing professional-editor voice.
- [ ] **Step 1: Rewrite; self-review against the shipped T5 wire; `./scripts/test.sh`.**  **Step 2: Commit** — `docs(skills): the editing pass reads the writer's own ladder and briefs`

---

### Task 7: P1's carried closures — census, cost, comment

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift` (seam-(a) census), `MaughamTests/CompilerPromptTests.swift` (cost measurement), `MaughamTests/DiagnosticsPaneTests.swift` (`:978` stale comment)
- Test: they ARE tests

**Interfaces & content:**
- **Seam-(a) census**: exactly one production site joins fingerprint fields with `\u{001F}` (`RoundFingerprint.stringValue`) — a grep census over `Maugham/` + `Packages/` with a planted-offender comment, the house pattern (a second join site = a second identity spelling = the dedupe silently forks).
- **Prompt cost**: one assertion that the standing per-run instruction additions (three disciplines + form instruction + a representative pass brief) total under a stated word budget (pick ~450 words with the measured current value in the assertion message) — so the number stops being folklore and growth is a conscious edit.
- The `:978` comment: reword to name the deleted `readerSection` honestly (the T7-P1 fix's sibling).
- [ ] **Step 1: Write all three (census red-tested via planted offender); `./scripts/test.sh`** — green.  **Step 2: Commit** — `test(m4): the fingerprint census, the prompt-cost measurement, and a stale citation`

---

### Task 8: The guide and the roadmap catch up

**Files:**
- Modify: `docs/guide/review-passes.md` (the cockpit; the chip's Run item — the "four states directly" sentence moves; briefs + EDITORS surface here for the first time: who Perkins/Lish/Gould/Argus are, renameable, brief-editable in P2? — no: brief editing UI did not ship; say what ships: presets carry briefs, custom passes fall back honestly), `docs/guide/compiler.md` (the This-check section; the pane's remaining shape), `docs/guide/right-pane.md` (the still-describes-the-old-pane flag lifts where now true), `docs/guide/annotations-and-suggestions.md` (the cockpit's mention if it names the toolbar's controls), `docs/roadmap.md` (author the M4 row: P1+P2 shipped, what remains), `README.md` (one line: named editors + the loop)
- Test: `./scripts/test.sh` (DocSync family); every quoted line verified before editing
- [ ] **Step 1: Sweep with the verify-quote-first discipline; grep for now-false neighbors (`grep -rn "Nothing to flag\|three sections\|Claude Desktop" docs/guide/` — read every hit).**  **Step 2: Gate; commit** — `docs(m4): the guide meets the cockpit, This check, and the editors`

---

## Self-review record

§7.0 → T1 (including the empty-report arm — the exact state Denver smoked). §7 cockpit → T2+T3; trigger affordances → T3+T4; progress in place → T3; empty-state teaching → T3. §4 briefs to both readers → T5+T6. Carried items → T1 (Author copy), T3 (Review copy), T7 (census/cost/comment), T8 (guide). Editors reach the guide → T8. No registry/DetailSegment change anywhere (survey-confirmed). Cross-task names: `RoundNarrative` (T2) ← T3; `onSetActivePass` one-writer threading (T3) and the chip closure (T4) both end at `recordActivePass`; `PassInfo.brief` (T5) ← T6's skill prose.

Whole-branch seams for the final review: (a) T1×T3 — a disposition in This-check moves the cockpit's counts and the queue identically (one projection, three viewports); (b) T3×T4 — the chip's run and the cockpit's run land in the same lane with the same editor (one recordActivePass writer); (c) the second runState reader's scoping (T3) against the pane's first — same docId discipline, no cross-doc bleed; (d) width: the strip under every pane width in `detailColumnWidthRange`.
