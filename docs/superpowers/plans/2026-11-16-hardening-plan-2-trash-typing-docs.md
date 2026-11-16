# Hardening 11-16, plan 2: trash, typing loop, doc truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A delete gesture completes as one undoable gesture or says exactly what it did; the note door never writes at a path a verb is still moving; a stale `.md` Maugham itself left is not reported as an outside edit; a second Replace cannot hit the wrong occurrence; the docs the sweep found stale are true. Closes #142, #143, #144, and finishes #141's deferred items.

**Architecture:** `deleteResearchItems` gains a row-only trash for a missing file and a partial-failure path that saves, arms and names both halves (RULING-63). `ProjectStore` holds the ids of items whose files a verb is moving, and the door asks it before writing afresh. `Document.load` compares the stored `.md` against the render before the pending fold as well as after it. The search view awaits a fresh search before it accepts another Replace.

**Tech Stack:** Swift, SwiftUI + AppKit, the local `MaughamCore` package, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-16-hardening-sweep-11-15-design.md` (§6, §7, §8; ruling R-F / RULING-63). Read it before any task; R-F is Denver's and is not reopened here. Plan 1 (`2026-11-16-hardening-plan-1-note-door.md`) is built; this plan was derived against the code at `a7a326c8`.

Branch `claude/hardening-2026-11-16`. Sources: `gh issue view 142`, `gh issue view 143`, `gh issue view 144`. **Line numbers in the issues have drifted: find code by symbol.**

## Global Constraints

- Read the area guide `CLAUDE.md` names for each path before editing it (`Maugham/Stores/AREA.md`, `Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `Maugham/MCP/AREA.md`), and the rows in `docs/tripwires.md` your change rhymes with (14, 20, 33, 52, 58 most of all).
- Before changing behaviour a claim pins, read the claim: Trash's are in `register/reconciliation/Trash.claims.json` (M3-TR-008, 009, 034, 036, 037, 056, 066 bear on Task 1); the door's are M5-AN-070, 071, 084, 088, 089 in `Annotations.claims.json`. **Claim, filing and guide text is updated in Task 8, not piecemeal**; a task that makes a sentence false says so in its report.
- Test first: write the failing test, watch it fail for the stated reason, then fix.
- **Disable experiment on every negative assertion** ("writes nothing", "no backup", "is refused", "leaves no folder"): remove the guard, watch the test fail, restore it, and put the output in your report.
- **Gates run in the foreground, as one command, and you stay on it until it returns.** Never in the background, never behind a wait loop, never end a turn with a gate pending. `./scripts/test.sh`; when `Packages/MaughamCore` changes, also `./scripts/test.sh core` and `./scripts/test.sh phone`. Never raw `swift test` or `xcodebuild test`. Run `./gen.sh` after adding any file.
- Tests are windowless where possible; no press-then-wait (tripwire 33): drive an interleaving through an awaited seam, never a sleep. Temp roots through `TestTemp`; windows through `TestWindow`.
- A census in `TripwireGrepTests` that counts what you touch (`rawResearchTextWrites`, `otherWritesInResearchFiles`, `researchNoteDoorCallers`, `StructuralVerbCensusTests`) is updated in the same commit, same count discipline; no entry is loosened.
- Notices go through `MaughamEvent.postNotice(_:projectURL:)`. Errors a writer reads are sentences, in the voice of the ones beside them.
- **#106:** `DocumentStore.swift` (2,8xx lines) and `Document.swift` (2,1xx) are on its list. Tasks 2, 4 and 5 keep their additions there small (a lookup, a reorder, one hook); if either file would grow by more than about twenty lines across this plan, stop and tell the coordinator.
- `Maugham/OpLog/AREA.md` is at its word ceiling and `Maugham/Stores/AREA.md` at its (lowered) one: guide edits happen in Task 8 and are word-neutral; no ceiling is raised.
- One commit per task, message `hardening 11-16 task 2.N — …`, ending with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Don't push.
- Report: files changed, tests added with their disable-experiment output, the gate result with counts, any claim or guide sentence you made false, and anything you judged that the coordinator should check.

## Review Focus

1. **A batch whose every file is missing**, and a batch of one such row: the gesture completes, ⌘⌥Z brings the rows back (still without files), and nothing is left in `.trash/` that `list()` cannot see. → Task 1.
2. **A delete that fails on the first item** (nothing trashed yet): nothing is saved or armed that was not already, the previously armed deletion is untouched, and the error does not claim anything was deleted. → Task 1.
3. **An editor save of a note whose file was deleted outside Maugham**, with no verb running: it still recreates the file, as today. Only an item a verb is moving is held. → Task 2.
4. **A real outside edit made while a pending file also exists** (the `.md` equals neither render): still backed up as `diverged`, once. → Task 4.
5. **Replace clicked twice quickly on the same match**: the second click finds the match gone and says so; it never replaces the next occurrence. → Task 6.

---

### Task 1 — a delete gesture completes as one, or says what it did (#142 T1; RULING-63) [opus]

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Research.swift` (`deleteResearchItems`, `trashResearchItemCore`), `Maugham/Stores/TrashStore.swift` (`moveToTrash`), `Maugham/Stores/ProjectStore+Trash.swift` (`restoreResearchItem`, `restoreStructureItem`), the file defining `ProjectStoreError`
- Test: `MaughamTests/Stores/ResearchMoverOutsideResearchTests.swift` (beside `test_aBatchDeleteWithARefusedItemTrashesNothing`), `MaughamTests/Claims/TrashCharacterization.swift`

**Interfaces — Produces:**
- `trashResearchItemCore`: a row whose file does not exist at its resolved path is trashed with the existing `TrashStore.recordManifestOnlyTrash(…)` (the row-only route M3-TR-066 describes) instead of `moveToTrash`. A group is "missing" only if its folder is; its children follow the existing group route.
- `ProjectStoreError.deletedInPart(trashed: [String], failed: String, underlying: String)`, `LocalizedError`: "Moved N to the Trash (“A”, “B”), then “C” could not be deleted: <underlying>. ⌘⌥Z puts the N back." With `trashed` empty the original error is rethrown unchanged.
- `deleteResearchItems`: a throw from item k (k > 1) is caught; then `manifest.modified`, `saveManifest()`, the `trashEntries` refresh and `armDeletion(trashIds:label:)` run for the entries already made, and `.deletedInPart` is thrown. If that `saveManifest()` itself throws, its error is thrown with the titles trashed named in it.
- `TrashStore.moveToTrash` removes the entry folder it minted when it throws after the mint (unsafe path, failed move).
- `restoreResearchItem` / `restoreStructureItem` refuse an entry whose item id is already in the tree: `TrashError` case with the sentence "“X” is already in the project; nothing was restored." (find the neighbouring refusal's shape and reuse it).

- [ ] **Probe first** (the register's rule): run the two characterization tests that pin the litter (`test_moveToTrash_refusesUnsafePaths_butLeavesTheEntryFolderBehind`, `test_moveToTrash_missingSource_leavesAnEntryFolderListCannotSee`, and `test_deleteStructureItem_withNoPath_throws_andLeavesTheRowAndALitterFolder`) and record what they assert today.
- [ ] Tests first, fixture `novel()` / `makeResearchProject()` with three notes, the second's file removed with `FileManager.removeItem`:
  - `test_aBatchDeleteWhoseSecondFileIsMissingDeletesAllThree_andUndoesAsOne`: three Trash entries (one row-only), manifest saved, `restoreLastDeletion()` returns all three rows.
  - Review Focus 1: a batch of one missing row; a batch where all are missing.
  - `test_aBatchDeleteThatFailsPartwaySavesWhatItTrashed_armsIt_andNamesBothHalves`: make item 2's move fail for a reason other than a missing file (an unwritable `.trash` entry is the existing injection; else a path made unsafe after validation); expect `.deletedInPart` with one trashed title and the failed one; the manifest on disk lacks row 1 and has rows 2 and 3; `restoreLastDeletion()` restores row 1.
  - Review Focus 2: failure on item 1 → the original error, `lastDeletion` unchanged from before the call.
  - `test_aRestoreOfAnItemAlreadyInTheProjectIsRefused` for both restore routes.
  - The three characterization tests are rewritten to what the probe shows after the fix: no entry folder is left behind. Their claims (M3-TR-008, 009, the litter half of 034) change in Task 8.
- [ ] M3-TR-036, 037 and 056 stay green unchanged (the armed record is still one gesture; a partial arm names exactly what landed).
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 2 — the door never writes at a path a verb is moving (#142 T2) [opus]

> **Correction (2026-11-16, as built).** The door does not wait on a verb, and there is no `waitUntilNotInFlight`. `ProjectStore.withResearchItemsInFlight` spans each verb over a counted dictionary; a save that reads `.missing` for a note in the span, and is not the verb's own (`ResearchItemsMoving.byThisTask`), either stays pending (a timer save, re-armed when the span ends) or is turned away with `NoteLookup.beingMoved` (a flush keeps its text as a conflict backup). Two rounds of review found wait cycles; a hang of ⌘S or close is worse than a named backup (commits 422d46d5, 7ca238dd). The text below is the original plan.

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` (state), `Maugham/Stores/ProjectStore+ResearchMove.swift` (`moveResearchItems`), `Maugham/Stores/ProjectStore+Research.swift` (`updateResearchItem`'s rename, `trashResearchItemCore`), `Maugham/Stores/ResearchNoteDoor.swift` (`write`)
- Test: `MaughamTests/Stores/ResearchNoteDoorTests.swift`

**Interfaces — Produces:**
- `ProjectStore.researchItemsInFlight: Set<String>` (`@ObservationIgnored`, internal) with `func withResearchItemsInFlight<T>(_ ids: [String], _ body: () async throws -> T) async rethrows -> T`: inserts the ids (a group's descendants too) before `body`, removes them when `body` returns or throws. Each verb wraps **only** the span from just before it calls the mover/trash until the in-memory manifest names the new place (or the row is removed); the asset-ref rewrite and `saveManifest()` are outside it.
- `func waitUntilNotInFlight(_ itemId: String) async` on `ProjectStore`: returns at once when the id is not in the set; otherwise resumes when it leaves (continuations resumed by the wrapper's exit; no polling).
- Door: in `write`, when the prior read is `.missing` and `owner.researchItemsInFlight.contains(itemId)`: a `.editorTimer` save returns `.stoppedTextStaysPending`; any other source awaits `waitUntilNotInFlight` and re-enters `write` once (the existing `secondRead`-style single retry; never a loop). `.missing` for an id **not** in the set behaves as today.

- [ ] Tests first, building the gap by hand as `test_aNoteMovedDuringTheKeepIsWrittenWhereItNowIs` does (move the file, leave the manifest, mark the id in flight through the wrapper with a body that awaits a test continuation):
  - `test_aTimerSaveOfANoteAVerbIsMovingWritesNothingAtTheOldPath_andStaysPending`.
  - `test_aFlushOfANoteAVerbIsMovingWaits_andLandsAtTheNewPath`: after the wrapper's body updates the manifest and returns, the text is at the new path and nothing exists at the old.
  - `test_aDirectSaveDuringATrashWritesNothing_andSaysTheNoteIsGone` (the row is removed inside the wrapper → the retry meets `.gone` → `unreachable`, as today).
  - Review Focus 3: `test_anEditorSaveOfANoteDeletedOutsideStillRecreatesIt`.
  - `test_theMoversOwnFlushIsNeverHeld`: a real `moveResearchItems` of a note with a pending edit completes (no deadlock) and the edit is in the moved file.
- [ ] `StructuralVerbCensusTests` stays exact. `DocumentStore.swift` is not edited.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 3 — asset refs are rewritten before the manifest save (#142 T3) [sonnet]

**Files:**
- Modify: `Maugham/Stores/ProjectStore+ResearchMove.swift` (`moveResearchItems`), `Maugham/Stores/ProjectStore+Research.swift` (`updateResearchItem`)
- Test: `MaughamTests/RenameWithAssetsTests.swift`, `MaughamTests/ResearchMoveTests.swift`

- [ ] Tests first, with the existing save-failure injection (`withUnwritableProjectFolder` in `FigureRenameTests`; lift it to a shared test helper if it is file-private): a rename of a note with an `_assets` folder whose `saveManifest()` throws still leaves `./<new>_assets/` refs in the moved note; the same for a move whose dedup renamed the stem.
- [ ] Move each `rewriteMovedNoteAssetRefs` call to just before `manifest.modified = Date()` / `saveManifest()`, after the in-memory manifest names the new path (and outside Task 2's in-flight span). Correct the two comments that say "now that the manifest names where the note is" to say the in-memory manifest.
- [ ] Gate: `./scripts/test.sh`. Commit. Report: `Stores/AREA.md`'s "asset refs follow manifest saves" is now false (Task 8).

### Task 4 — a stale `.md` Maugham left is not an outside edit (#143 Q1) [opus]

**Files:**
- Modify: `Maugham/OpLog/Document+Load.swift` (the divergence check)
- Test: `MaughamTests/OpLog/LoadDivergenceSnapshotTests.swift`, `MaughamTests/OpLog/AutosaveOffMainTests.swift`

**Interfaces:**
- Consumes: the pending fold in `Document.load` (it appends a `.pendingRecovery` op before `initial` is derived), `MarkdownDisplayFilter.stripAnchors`, `Materializer.materialize`, `Document.writeConflictBackup(forFileAt:docId:text:kind:)`, the re-render the load schedules when the disk diverged, `WriteGate(fail:)` and `conflictBackups(of:)` in `AutosaveOffMainTests`.
- Produces: the load keeps the render of the state **before** the pending fold (only when a pending file was folded). The stored `.md` is `diverged` only if it equals neither that render nor the post-fold render. When it equals the pre-fold render, no backup is written and the re-render is still scheduled. No new stored state, no new file.

- [ ] Tests first:
  - `test_anAutosaveCutBetweenTheMirrorAndTheWriteLeavesNoDivergedBackup`: `makeDoc`; `setFullText`; `WriteGate(fail: [1])`; `performAutosave()` throws after the mirror is flushed; drop the document without closing; `Document.load` the same URL with the same device; no `diverged` file under `.maugham/conflicts`, the text is the typed text, and the `.md` is re-rendered after the scheduled autosave.
  - Review Focus 4: `test_anOutsideEditBesideAPendingFileIsStillBackedUpOnce` (plant a pending file as `PendingBasisFoldTests` does, then write a third text to the `.md`).
  - The three existing `LoadDivergenceSnapshotTests` stay green unchanged.
- [ ] Gate: `./scripts/test.sh`. Commit. Report the residual for #143: a kill between `performClose`'s burst append and its trailing autosave leaves the log ahead of the `.md` with no pending file, which this does not cover.

### Task 5 — a clean close leaves no pending file; the off-main test probes the render (#143 Q2, Q3) [opus]

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (`performClose`, `runAutosave`)
- Test: `MaughamTests/OpLog/PendingBasisFoldTests.swift`, `MaughamTests/OpLog/AutosaveOffMainTests.swift`

**Interfaces — Produces:**
- `performClose` order: the final `drainAutosaveRuns()`, then `isClosed = true` with **no suspension between them** (the existing comment's invariant), then `try? await pending.clear()` under the same `burstFlushSucceeded && mayWriteThePendingFile` condition, then `huskInMemoryState()`. The earlier clear is removed. `mayWriteThePendingFile` stays one expression at four sites.
- `@ObservationIgnored internal var autosaveRenderHook: (@Sendable () -> Void)?`, called inside the `offMain` render closure. `internal var closeWillFinishForTesting: (() async -> Void)?`, awaited after the seals and before the final drain (the seam the Q2 test needs).

- [ ] Tests first:
  - `test_anAutosaveArrivingDuringTheSealsLeavesNoPendingFileAfterAClose`: through `closeWillFinishForTesting`, call `performAutosave()`; after `close()` returns, no pending file exists (`pendingFileURL`). Disable experiment: restore the old order.
  - `test_cleanClose_leavesNoPendingFile` and `test_closeAwaitsTheWriteInFlight_andNothingWritesAfter` stay green; a failed burst flush still keeps the pending file.
  - `test_theRenderAndWriteRunOffTheMainThread` records `Thread.isMainThread` in both hooks and asserts both false. Disable experiment: render on the main actor.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 6 — a second Replace waits for a fresh search; one ordinal, one sentence (#141 follow-up from plan 1 Task 3) [opus]

> **Correction (2026-11-16, as built).** Replace All is on the chain, not untouched: single Replaces and Replace All run one at a time through one chain (`takingTheReplaceTurn`), each ends by refreshing `currentSearch` undebounced, a match whose id is not in the current results throws `.staleSearchMatch` ("That match has changed. Search again."), searches land only if newer, and `clearSearch` drops in-flight searches (commits 7407bf5b, 231d60c0). The plan's `researchOrdinal(of:)` is now `ordinal(of:)`, one helper for both arms. In the final fix wave a single Replace also refuses (and refreshes) when the text holds a different count of occurrences than the results listed, or a different line at the ordinal, found by the search engine's own matcher (`ClickedOccurrence.range`). The text below is the original plan.

**Files:**
- Modify: `Maugham/Views/ProjectSearchView.swift` (`runReplaceMatch`, the Replace controls), `Maugham/Stores/ProjectStore+Search.swift` (`performSearch`, `replaceMatch`, `researchOrdinal(of:)`, the manuscript arm's ordinal)
- Test: `MaughamTests/Stores/ResearchNoteWritersTests.swift`, `MaughamTests/ProjectSearchReplaceTests.swift`

**Interfaces — Produces:**
- `func searchNow(query: String, options: SearchOptions) async` on `ProjectStore`: runs the search with no debounce and returns when `currentSearch` holds the fresh results (the debounced `performSearch` stays for typing).
- `ProjectStore.replaceMatch` ends by awaiting `searchNow` itself, so `currentSearch` never holds results older than the last replace; the view's own re-search after a single Replace is removed.
- `private func ordinal(of match: SearchMatch) -> Int?` — one helper for both arms (the manuscript arm's inline logic and `researchOrdinal(of:)` both call it); nil when the match's id is not in `currentSearch`'s results for that document.
- A match whose id is no longer in the results throws `ProjectStoreError.staleSearchMatch`, `LocalizedError`: "That match has changed. Search again." Both arms use it in place of "Match range out of bounds" (and of the count-below fallback that guessed an ordinal).

- [ ] Tests first:
  - The two tests plan 1 pinned to "the second click hits the following occurrence" (`test_twoSingleReplacesInOneNoteWithoutASearchBetweenThemBothLand` and its manuscript mirror) are rewritten: after the first Replace returns, `currentSearch` is fresh; replacing the **same stale match value** again throws `.staleSearchMatch` and the text is unchanged (Review Focus 5); replacing the match the fresh results now list second replaces that one.
  - `test_replaceMatchWhoseQueryIsGoneFromTheNoteThrowsAndWritesNothing` and the fewer-matches test expect the new error.
  - The manuscript arm's other tests stay green.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 7 — the last raw body write; the one question, counted (#141 follow-ups from plan 1 Tasks 7 and 8) [sonnet]

**Files:**
- Modify: `Maugham/Views/LetterKeep.swift` (`keep`), `Maugham/Stores/ResearchNoteDoor.swift` (`holdResearchNoteOpen`), `MaughamTests/TripwireGrepTests.swift`
- Test: the suite covering `LetterKeep`, `MaughamTests/MCP/Tools/AddNoteToolTests.swift`, `MaughamTests/InboxPromoteTests.swift`, `MaughamTests/TripwireGrepTests.swift`

- [ ] `LetterKeep.keep`: with a `DocumentStore`, the kept letter's body goes through `saveResearchNote(itemId:text:by:mustLand: true, from:)` and a save that is not `.saved` throws (the `add_note` shape). Ask who the writer is from how `keep` is reached: a letter the assistant wrote is `.assistant`; say in the report what you chose and why. With no store, the existing raw write stays, asks `rawNoteWriteWithNoDoor()`, and its marker becomes `no-door fallback`. Test: the kept note's first edit keeps the letter's text as a version marked with that writer.
- [ ] `TripwireGrepTests.rawNoteWriteQuestionSites: [String: Int]`: every call of `rawNoteWriteWithNoDoor()` by file, and a test that every file with a `// raw-research-text: no-door fallback` marker is in it with a matching count.
- [ ] `test_addNoteOnAStoreThatLostItsDocumentStoreIsRefused`, `test_anInboxPromotionOnAStoreThatLostItsDocumentStoreIsRefused` (the existing lost-store fixture; the note file's bytes are unchanged and, for the inbox, the entry is still in the inbox).
- [ ] `holdResearchNoteOpen`: replace the hourly `Task.sleep` loop with one suspension that ends on cancellation (`withTaskCancellationHandler` around a continuation, or an `AsyncStream` that never yields). The open/let-go tests from plan 1 Task 7 stay green.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 8 — doc truth, claims, and the register's last ruling note (#144 D3, D4; the AREA sentences; RULING-63) [sonnet]

**Files:**
- Modify: `CLAUDE.md` + generated `AGENTS.md`, `Maugham/Stores/TrashStore.swift` (a comment), `Maugham/OpLog/AREA.md`, `Maugham/Stores/AREA.md`, `register/01-claims-ledger.json`, `register/reconciliation/Trash.{claims,filings}.json`, `Annotations.{claims,filings}.json`, `OpLog.{claims,filings}.json`
- Generated: `register/RULINGS.md`, `ruling-hashes.json`, `register/START-HERE.md` (between its markers)

- [ ] **D3.** CLAUDE.md's Releases line: add "push `main` and wait for a green `CI` run on that commit first (`cut-release.sh` checks it)". CLAUDE.md is at its 3,087-word ceiling: pay for the words by trimming the parenthetical list in the same line; the line stays under its 515-character longest-line ceiling or the list is trimmed further. Regenerate `AGENTS.md` with `scripts/gen-agents-md.sh`.
- [ ] **D4.** `TrashStore.swift`, the prior-version `TrashSubject` doc comment: "research FILES are recoverable but not versioned (RULING-24's middle tier); research TEXT is versioned since 2026-11-11", consistent with the paragraph above it.
- [ ] **AREA truth**, word-neutral: `OpLog/AREA.md`'s "Quit never runs `close()`, so a quit leaves a basis-stamped file by design" → what ⌘Q does since 11-11 (`QuitCoordinator`: stores closed, bounded at ten seconds; a statement still closes without being awaited) and that a stale `.md` the load recognises as its own gets no backup; `Stores/AREA.md`: "asset refs follow manifest saves" → before; `deleteResearchItems`' one-pass sentence gains the row-only and partial-failure arms; the door line gains the in-flight hold.
- [ ] **Claims**, each checked against the built code with the tests that pin it: M3-TR-008, 009 and the litter half of 034 rewritten (no folder left); new Trash claims for the row-only delete of a missing file, the partial-failure report and arm, and the duplicate-id refusal, filed COMPLIES under RULING-63 (and RULING-52 / RULING-40 where their scope reaches); M3-TR-066 gains the new route in its sources. OpLog: new claims for Q1 (the pre-fold render is not diverged; the burst-variant residual stated) and Q2 (close order), filed by what a ruling reaches or `NO_RULING_REACHES`. Annotations: M5-AN-070 (the in-flight hold; a kept letter goes through the door), the Replace claim (a stale match is refused, results are fresh after each replace). Coordinator's calls are marked as such.
- [ ] RULING-63 gains its `mechanism_note`; run `23-generate-rulings.py` and `27-generate-state.py`; recompute each `_summary`.
- [ ] Gate: `./scripts/test.sh core`, `swift test --package-path register/ExperimentTests --filter StartHereCountsTests` (the one place a raw `swift test` is allowed: no `test.sh` mode hosts that package; run it only when `pgrep -x xcodebuild` prints nothing), then `./scripts/test.sh full`. Commit.

---

After Task 8: the whole-branch review (it triages every `minor (deferred)` line in both plans' ledgers), `./scripts/test.sh full` and `./scripts/test.sh phone` on the final tree, a Release build if `ProjectWindow.body` changed (it should not have), comments on #106 and #141–#144, and Denver's go for the merge.
