# Batch C: annotation-undo honesty and run edges (#79, #51, #63, #77) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the yield gap in suggestion-accept undo (#79). Make reject/archive undo say when it can't act (#51). Stop a retired session's late failure from clobbering a newer run (#63.1). Refuse a round whose editor vanished mid-hop (#77 G1/F6). Make each loop show only its own run, and say when the other loop's run is busy (#77 F7). Keep what a cancelled translation mint already did (#77 F8). Stop MCP `write_translation` storing an empty translation as done (#77 F9).

**Architecture:** Each fix sits where its decision already lives. Every task's file:line evidence, fix shape, model tests and gotchas are in the research note. **Read your task's section of `docs/superpowers/notes/2026-10-17-batch-c-research.md` first.** It is the spec for that task's details; this plan carries only the decisions.

**Tech Stack:** Swift, XCTest.

**Spec:** issues #79, #51, #63 and #77, as verified on main 43a505fe in `docs/superpowers/notes/2026-10-17-batch-c-research.md`.

## Rulings (Denver's and the controller's)

- **F7 (Denver, 2026-10-17):** each loop shows only its own run. While a CHECK runs, the Review round cockpit shows its own state plus the line **"Author's check is running — Run waits until it finishes."**, and its Run stays refused. Applied symmetrically (controller): while a ROUND runs, Author's Diagnostics header shows **"Review's round is running — ⌘R waits until it finishes."**
- **#79 decline sentence (controller):** reuse `UndoDecline.restoreNotPermitted` (the closest existing sentence: this Mac can no longer change this piece's text). No new case.
- **Dropped, and closed on their issues with the research's reason:** #63 item 2 (perf only, milliseconds), #77 G4 (no collision possible), F10 and F11 (no path; every caller validates).

## Global Constraints

- Tripwire 51: `Document`/`Document+Annotations` never ask the posture. A yield-aware check arrives as a `mayWrite` closure from the view host, which asks `documentStore.posture(forDocId:).allows(.writeText)` (PR #80's `InlineToggleUndo` shape). Windowless and `undoManager: nil` callers keep the default `nil`.
- Tripwire 52: no new manuscript-writer call sites; census counts must not change, though reason strings may be updated.
- Tripwire 33: no synthesised clicks and no press-then-wait tests.
- Register: #51 behaviour sits under RULING-22. Add or update the claim in `register/01-claims-ledger.json` and regenerate per `register/RECONCILE.md`, if a claim covers it.
- Sweep `Maugham/OpLog/AREA.md` and `Maugham/Compiler/AREA.md` for sentences the change makes false (workflow rule 10).
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`, and run `./scripts/test.sh full` before the PR. Never `pgrep -f xcodebuild`. If Core fails with only a `started.` line and no assertion, another session's build killed it, so re-run.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. **Edit Anyway** still lets a suggestion accept, its undo and its redo write (#79).
2. **A textless accept** (comment or query) and its redo are never refused for `.writeText` (#79: suggestion arm only).
3. **"Undo Reject" never reopens an archived note and never resurrects a withdrawn one** (#51).
4. **F7:** a check's FAILURE no longer reads as a round failure in the cockpit, and the reverse holds too.
5. **#63.1:** a newer run's live stream preview survives a retired session's late failure.

---

### Task 1: Suggestion-accept undo/redo asks the yield-aware posture (#79)
Research section: `## #79`. Add `mayWrite: (@MainActor () -> Bool)? = nil` to `acceptAnnotation(id:userResponse:undoManager:)` and `revertAcceptedAnnotation(id:undoManager:)`, checked in the suggestion arm only, before the append. Thread it through all three re-entries (accept-undo, accept-redo, pane-revert-undo). Refusal throws `PostureRefusal`, which `refusingLoudly` turns into `declineUndo(.restoreNotPermitted)` (see Rulings). Wire the hosts the research lists (EditorHost margin card and reply, AnnotationsPane performAccept/performRevert, AnnotationBulkActions via the pane).
- Tests (model on the research's named ones): `test_aSuggestionAcceptUndoneAfterTheYieldBeginsLeavesTheWordsAndSaysSo`, `test_aSuggestionAcceptRedoneAfterTheYieldBeginsIsRefused`, `test_aPaneRevertUndoneAfterTheYieldBeginsIsRefused`, `test_editAnywayLetsASuggestionAcceptAndItsUndoWrite`, `test_aCommentAcceptsRedoIsNeverRefusedForWriteText`.
- Commit: `fix(posture): a suggestion accept, its undo and redo ask the yield-aware posture (#79)`

### Task 2: Reject/archive undo checks before it reopens (#51)
Research section: `## #51`. The reject and archive undo closures re-check the live status (`.rejected` / `.archived`). On drift they decline via new `UndoDecline` cases `.reject` / `.archive` (singular and plural lines, house style), then `refusingLoudly { reopenAnnotation }`. Don't change `reopenAnnotation`. Give the pane Reopen's undo (re-applying reject/archive/stet) the same guard, that the note is still `.open`.
- Tests: `test_aDriftedRejectUndoDeclinesToTheWriter`, `test_aDriftedArchiveUndoDeclinesToTheWriter`, `test_undoRejectNeverReopensAnArchivedNote`, `test_undoRejectNeverResurrectsAWithdrawnNote`, `test_aReopenUndoneAfterTheNoteMovedDeclines`.
- Sweep OpLog `AREA.md`'s `notifyWriter`/`declineUndo` paragraph; add the register claim under RULING-22.
- Commit: `fix(annotations): reject, archive and reopen undos say when the note moved (#51)`

### Task 3: Compiler run edges: late failure, vanished editor (#63.1, #77 G1/F6)
Research sections: `## #63 item 1`, `## #77 G1/F6`. `CompilerOrchestrator.finish`'s `.failed` arm AND its unusable-output arm get the same `runGeneration == generation` guard the result arm has, so a retired session's late failure changes neither `runState`, `endLiveRun()` nor `discardStreamPreview`. At the top of `beginRun`, a ROUND whose `roundEditor` resolves nil refuses exactly as `runRequested` does (`Acknowledgment.noEditor`, nothing started).
- Tests: `test_aRetiredSessionsLateFailureLeavesTheNewerRunAlone` (retire mid-turn, start another, resolve the old failure; check runState, clock and preview), the same for unusable output, and `test_aRoundWhoseStageVanishedDuringTheHopIsRefused`.
- Commit: `fix(compiler): a retired session's late failure and an editor-less round are refused (#63, #77)`

### Task 4: Each loop shows its own run, and names the other's (#77 F7)
Research section: `## #77 F7`. Add `kind: RunKind` to `RunState.running`/`.nothingNew`/`.failed` and update every set site. `DiagnosticsPane.headerState` matches `.check` only; `ReviewRoundCockpit.phase` matches `.round` only. Each gains a pure "the other loop is busy" state carrying the exact Rulings sentence. Run/⌘R stays refused as today.
- Tests (pure, on `phase(runState:docId:)` and `headerState`): `test_theCockpitDoesNotShowAChecksRunAsARound`, `test_theCockpitSaysAuthorsCheckIsRunning`, `test_aChecksFailureIsNotARoundFailure`, `test_theDiagnosticsHeaderSaysReviewsRoundIsRunning`, `test_aRoundsFailureIsNotACheckFailure`. Update the ~20 existing construction sites.
- Commit: `fix(compiler): each loop shows its own run and says when the other's is running (#77 F7)`

### Task 5: Translation edges: a cancelled mint keeps its outcomes; no empty translation via MCP (#77 F8, F9)
Research sections: `## #77 F8`, `## #77 F9`. F8: when the generation check fires after `mintDeclinedQueries` returned, apply the outcomes it returned (annotation links, rewrite records, summary), and record the leg as finished if it finished, before honouring the cancel. Follow the research's exact shape. F9: `write_translation` refuses a non-verbatim entry whose text is empty or whitespace, with an error naming the paragraph, matching the pipeline ingest's existing refusal.
- Tests: `test_aCancelLandingAfterTheMintKeepsWhatItMinted`, `test_writeTranslationRefusesAnEmptyParagraph`.
- Commit: `fix(translation): a cancelled mint keeps what it minted; write_translation refuses empty text (#77)`

### Finish
- [ ] `./scripts/test.sh full`, green.
- [ ] Whole-branch review (opus), told not to build.
- [ ] PR closing #79 and #51. #63 and #77: close them with a comment listing what shipped and why each dropped item was dropped.
