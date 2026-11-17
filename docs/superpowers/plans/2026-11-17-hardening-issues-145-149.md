# Hardening 2026-11-17 (issues #145–#149) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the fixable findings of issues #145–#149 so Maugham 0.48.0 can ship them.

**Architecture:** Nine small, independent fixes at existing seams: two MCP tool guards, the in-flight span around the piece verbs, compare-and-clear on the pending file, two Search & Replace refinements, and four note-door residuals. No new types beyond what a task names; no task consumes another task's API.

**Tech Stack:** Swift, SwiftUI/AppKit, XCTest; `./scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-17-hardening-issues-145-149-design.md` (ids F1–F9). The GitHub issue named in each task holds the reviewer's finding and fix-shape: read it with `gh issue view <n>`.

## Global Constraints

- Branch `claude/hardening-2026-11-17`. Commit per task; never push, never merge, never tag.
- Read the area guide for every path you edit (CLAUDE.md "Per-area pointers") and the module's claims and filings under `register/reconciliation/` before changing behaviour.
- Test first: write the failing test, run it and see it fail for the stated reason, then fix.
- Gates run in the FOREGROUND, as ONE command, and you wait for the result: `./scripts/test.sh only <Class> …` while iterating, `./scripts/test.sh` (fast) before you report. Never a bare `swift test` or `xcodebuild`; never a backgrounded gate.
- Run `./gen.sh` after adding any source or test file.
- `Packages/MaughamCore` changes also need `./scripts/test.sh core`.
- Docs have word ceilings (`DocBudgetTests`): an `AREA.md` or CLAUDE.md edit must not raise the count. If CLAUDE.md changes, run `scripts/gen-agents-md.sh`.
- A claim edit that changes a module's counts needs `python3 register/scripts/flip-claim.py recompute --module <Module>` and the matching row and totals in `register/START-HERE.md` (`swift test --package-path register/ExperimentTests` checks them; run it only when no `xcodebuild` is running: `pgrep -x xcodebuild`).
- Exact error text and names in this plan are verbatim requirements.
- Writer-facing sentences are plain English, no jargon, curly quotes around titles as the neighbouring messages use.

## Review Focus

1. A note save landing during a piece reorder's TEMP-suffix phase (two-phase swap): the span must cover both phases, not only the final move.
2. A second quit/close of the same document after its reopen wrote the pending file: the file survives, and a clean single close still leaves no pending file (M9-OL-019 must stay true).
3. A Replace fallback must never pick a different occurrence: two matches on identical lines in one file differ only by range.
4. A failed `add_note` cleanup must not delete a note the writer already had (only the row and file this call created).
5. An unreadable publish folder versus an absent one versus an empty one: three different answers.

---

### Task 1: MCP publish tools refuse instead of crashing or lying (F1, F2; #149 M1, M2)

**Files:**
- Modify: `Maugham/MCP/Tools/PublishConfigTools.swift` (`SetPublishConfigTool.handle`, the `patch` guard)
- Modify: `Maugham/MCP/Tools/PublishFileTools.swift` (`ListPublishFilesTool.handle`)
- Test: the existing test files for these two tools under `MaughamTests/MCP/Tools/`

Reference shape: `git show 4218bcdc` (a stale branch; port the idea, write the tests fresh against main).

- [ ] Test `test_setPublishConfig_nonObjectPatchIsRefusedNotCrashing`: for `"patch": null`, `"patch": 3`, `"patch": "x"`, `"patch": []` the call throws `MCPError.invalidArgument` with the spec's F1 text and the stored config is unchanged; `"patch": {"title": null}` still deletes the key. Before the fix the first case aborts the test host: see that, then guard.
- [ ] Guard `patchObj is [String: Any]` before `JSONSerialization.data(withJSONObject:)`.
- [ ] Test `test_listPublishFiles_unreadableDirectoryRefusesNotEmpty`: chmod 000 the publish folder (restore in `defer`), expect an error whose code/message carries `publish_dir_unreadable`; an absent folder returns the empty tree; an empty readable folder returns the empty tree.
- [ ] Implement with `FileManager.isReadableFile(atPath:)` on an existing directory. Use the tool's existing error style (look at how its neighbours name an error code).
- [ ] `./scripts/test.sh only <the two test classes>`, then `./scripts/test.sh`. Commit.

### Task 2: Piece verbs enter the in-flight span (F3; #145)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift` (`movePiece`, `renamePiece`), `Maugham/Stores/ProjectStore+Trash.swift` (the piece trash/restore paths near `pieceResearchPrefix`), and any other caller the census below finds
- Modify: `MaughamTests/TripwireGrepTests.swift` (census)
- Test: `MaughamTests/` beside the existing #142 T2 in-flight tests (find them with `grep -rn "withResearchItemsInFlight\|beingMoved" MaughamTests`)

**Interfaces consumed:** `ProjectStore.withResearchItemsInFlight(_ ids: [String], _ body:)` (`ProjectStore+Research.swift`), `ResearchScope.pieceResearchPrefix(for:)`, `pieceResearchSectionRoots(forDocumentId:)`.

- [ ] Add one helper on `ProjectStore`: `func researchIds(underPieces pieceIds: [String]) -> [String]` returning the ids of every Research item whose path lies under those pieces' research prefixes (the span adds descendants itself).
- [ ] Test (red first): hold a piece reorder open mid-move (use the mover's existing test hook, as the #142 T2 test does), save a note inside that piece through `ResearchNoteDoor`, finish the move. Assert: no file at the old or temp path, the door's outcome is the "being moved" one, a conflict copy exists. Same for `renamePiece` and the piece trash.
- [ ] Wrap each verb's mover calls (BOTH phases of the reorder's temp-suffix swap) in `withResearchItemsInFlight(researchIds(underPieces: …))`. `movePiece` renumbers several pieces: the span covers every piece whose folder moves.
- [ ] Census in `TripwireGrepTests`: every production function in `Maugham/Stores` that calls `relocateUserContent` is in a named array, classified `entersSpan` or `holdsNoResearch("<why>")`; an unlisted caller fails. Follow the file's existing counted-list style.
- [ ] Update the claims this touches (M5-AN-082 family / the Trash and Stores claims naming the span) and the 0.47.0 known issue it removes.
- [ ] Gates. Commit.

### Task 3: Compare-and-clear on the pending recovery file (F4; #146 first half)

**Files:**
- Modify: `Maugham/OpLog/PendingBuffer.swift`, `Maugham/OpLog/Document.swift` (`performClose`'s clean clear, near `isClosed = true`)
- Test: beside the existing pending/close tests (`grep -rn "closeWillFinishForTesting\|pending.clear" MaughamTests`)

- [ ] Test (red first): load a document, type, let the pending file be written; start its close and hold it at `closeWillFinishForTesting`; load the same path again, type, let ITS pending file be written; release the first close. Assert the pending file still exists and holds the second instance's bytes. Second test: a single clean close still leaves no pending file (M9-OL-019).
- [ ] `PendingBuffer` remembers the bytes (or their SHA-256) it last wrote; add `func clearIfUnchanged() async throws` which removes the file only when its current bytes match, and otherwise only clears memory. `performClose`'s clean clear calls it. The load-time clears in `Document+Load.swift` are unchanged.
- [ ] Update M9-OL-019 and add the claim for the new rule; read `Maugham/OpLog/AREA.md` first.
- [ ] Gates. Commit.

### Task 4: A Replace click after a refresh finds its match (F5; #147 R1)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Search.swift` (`replaceMatch`, `replaceOneMatch`) and the Search view that calls it (`grep -rn "replaceMatch(" Maugham/Views`)
- Test: the existing Search & Replace tests (`grep -rln "staleSearchMatch" MaughamTests`)

- [ ] Test (red first): search, Replace match A in document 1, then Replace the still-held (old id) match B in document 2: B is replaced, no error. Second test: two matches on identical lines in one file: the fallback picks the one with the same range, never the other. Third: a refusal refreshes the results (the view model's results change after a `staleSearchMatch`).
- [ ] When the id is not in the current results, look up by `(path, range, line preview)`; exactly one hit proceeds through `ClickedOccurrence.range` as usual; zero or several throw `staleSearchMatch`. On `staleSearchMatch` the caller runs the same refresh a successful Replace runs (`refreshAfterReplace()`).
- [ ] Update M3/M5 search claims and remove the 0.47.0 known issue it fixes.
- [ ] Gates. Commit.

### Task 5: Replace in a note is compare-and-swap (F6; #147 R2)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Search.swift` (the Research-note Replace write), `Maugham/Stores/ResearchNoteDoor.swift` (the save entry Replace uses)
- Test: the door's and Replace's existing tests

- [ ] Test (red first): hook between Replace's read and its write (`searchWillLandForTesting` or the door's existing hook), change the file on disk, let Replace continue. Assert: `staleSearchMatch` thrown, the outside bytes are on disk untouched, no version was made.
- [ ] Give the door's save an optional expectation `expectingBytesHash: String?` (SHA-256 of what the caller read); when present and the door's re-read differs, the door writes nothing and returns a new outcome case that Replace maps to `ProjectStoreError.staleSearchMatch`. Every other caller passes nil and behaves as before. Replace All uses it per note and skips (does not abort) a note that fails it, counting it with the notes it already skips.
- [ ] Update the door claims (M5-AN-07x/08x) for the new outcome.
- [ ] Gates. Commit.

### Task 6: A failed create leaves no blank note (F7; #148 D1)

**Files:**
- Modify: the three sites that create a note then save its body through the door: `add_note` (`Maugham/MCP/Tools/`), the MCP inbox promotion, `LetterKeep.keep` (`grep -rn "guard case .saved" Maugham`)
- Test: `AddNoteToolTests` and the inbox-promotion and letter tests

- [ ] Test (red first), per site: make the door refuse the body save (the tests for the `guard case .saved` arm show how); assert the error is thrown AND the Research tree has no new row AND no new file. Inbox: a retry after the failure makes exactly one note. A note that existed before the call is untouched.
- [ ] On refusal, remove what this call created through the existing delete path that makes no Trash entry (a permanent delete of the just-created id; do not write a second raw remover), then throw the original error. If the cleanup itself fails, throw the original error with "; the empty note “<title>” was left in Research" appended.
- [ ] Update M5-AN-088/089/090 family claims and remove the 0.47.0 known issue.
- [ ] Gates. Commit.

### Task 7: A failed picture-link rewrite is shown (F8; #148 D2)

**Files:**
- Modify: `Maugham/Stores/` where `rewriteMovedNoteAssetRefs` / `rewriteAssetRefsBestEffort` live, and the rename/move outcome that already carries `linksLeftIn`
- Test: the Research move/rename tests

- [ ] Test (red first): rename a note with a picture; make the ref rewrite's write fail (read-only file or the door's refusal hook); assert the rename succeeds, and its outcome names the note in a new field `assetRefsLeftIn: [String]` (titles), surfaced where `linksLeftIn` is surfaced. Same for a move.
- [ ] Make the rewrite report failure to its caller instead of swallowing it; keep the log line. The writer-facing sentence follows the `linksLeftIn` sentence's pattern: "Renamed “X”, but the picture links in “X” could not be updated." (one note) / "… in N notes could not be updated."
- [ ] Update the claim that states the residual (M5-AN-084 area).
- [ ] Gates. Commit.

### Task 8: Note folder from the group's real folder; the remaining pins (F9; #148 D4 part)

**Files:**
- Modify: `Maugham/Stores/` `addResearchTextNote`
- Modify: `register/reconciliation/Trash.claims.json` / `Trash.filings.json` (M3-TR-066 filing, M3-TR-068)
- Test: Research add tests; `ResearchNoteDoorTests`; `ResearchMoverOutsideResearchTests`

- [ ] Test (red first): a group whose folder was deduped on rename (`notes-2/`) receives a new note: the file lands in the group's actual folder. A subgroup beneath the Palette: likewise its actual folder. A group with no child on disk yet keeps today's slug-derived folder.
- [ ] Derive the folder from the parent's existing children's common directory (or the group's recorded path if the model has one), falling back to the title slug only when the group is empty.
- [ ] Test: save a real note through the door (so its record files exist), permanently delete it, assert the record files are gone (N7's production path, today pinned only with planted files).
- [ ] Pin M3-TR-068's missing-group arm with a test; file M3-TR-066 (read `register/RECONCILE.md` for the filing shape; `flip-claim.py recompute --module Trash`; START-HERE counts).
- [ ] Gates. Commit.

### Task 9: Release notes, guides, and the issue ledger

**Files:**
- Create: `docs/release-notes/v0.48.0.md` (template `docs/release-notes/_template.md`; voice of `v0.47.0.md`)
- Modify: user-facing guide pages that describe Replace, Research notes, or the assistant's tools where a fixed behaviour is described (`grep -rn "That match has changed" Maugham/Resources docs`)

- [ ] Release notes: one line per fix a writer can notice (F1, F3, F5, F7, F8, F9's folder), grouped as 0.47.0's are; Known issues carries over only what is still true (check each 0.47.0 known issue against the built code).
- [ ] Sweep sibling docs for now-false claims (CLAUDE.md default workflow item 10).
- [ ] `./scripts/test.sh full`. Commit.
