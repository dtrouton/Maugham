# Note Versions (plan 2 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Research note keeps earlier versions the way a Research table does, restorable from the inspector, and the assistant can rewrite a note through a door that keeps and marks what it replaced.

**Architecture:** `ResearchVersionStore` (Core) learns a second payload kind. One note door on `DocumentStore` keeps the prior text off the main actor, then writes; every writer of an existing note's text goes through it. The open note editor learns to take text written behind its back. The inspector's Versions section and a new MCP tool sit on the door.

**Tech Stack:** Swift, SwiftUI, AppKit, MaughamCore (SPM); XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-10-typing-loop-and-note-versions-design.md` ("Plan 2 — note versions" and the Plan 2 calls). Verified facts this plan is written against: `.superpowers/sdd/plan2-recon.md` (2026-11-10, branch head 92e29c47); every task brief cites the sections it needs.

## Global Constraints

- A note is what `ProjectWindow.researchCentreRoute(id:in:)` routes as `.note`: `type == .asset`, `kind == .document`, a path, and not under `ProjectStore.paletteFolderPath`. Palette cards, tables, pictures and PDFs are not notes.
- Version rules are the table's, unchanged: `ResearchSaveRun` (gap 10 minutes), `ResearchVersionStore.retention` (50 per item per device), orphans swept after `TrashStore.expiry`. The folder stays `.maugham/research-versions/<itemId>/`, spelled once.
- Table versions already on disk keep listing and restoring. No migration, no schema bump.
- The keep runs off the main actor and is awaited before the write.
- A note's path reaches the disk through `SafeRelativePath` (`resolvedProjectPathToChange`; tripwire 58). A new file name minted locally says `// local-path: <why>`.
- The editor binding contract holds: one `Binding`, no parallel observable text state, one production caller of `applyExternalText`, reloads keyed on the path (tripwires 2, 3, 6, 7, 22).
- MCP never writes manuscript text. One catalogue: `MCPToolCatalog.all`.
- Core is shared with the phone: a Core change is tested against Core, the Mac scheme and `./scripts/test.sh phone`. Nothing in `MaughamPhone/` changes.
- Word ceilings (`DocBudgetTests`): `Maugham/Views/AREA.md` has zero headroom, `Stores/AREA.md` 16 words, `MCP/AREA.md` 2, `OpLog/AREA.md` 1. A new line is paid for by moving prose to `docs/history/` in the same commit. A new Swift file is named in its folder's AREA Map; run `./gen.sh`.
- `TripwireGrepTests.researchTableWriteSites` (~15549) pins the `.keep(priorBytes:` and `.performFileSave(` call sites by type; a task that adds or moves one updates the dictionary in the same commit.
- No test types into a mounted view and then waits on a timer (tripwire 33). `TestTemp` is the one temp root.
- Every task ends with `./scripts/test.sh` green and states its disable experiment.

## Pending Denver (asked 2026-11-10; ANSWERED 2026-11-11 — see `docs/superpowers/notes/2026-11-10-ruling-24-amendment-draft.md`: P1 drop the Trash entry, a version guaranteed; P2 cards keep versions; P3 as built; P4 in the register)

| # | Question | Default built |
|---|---|---|
| P1 | A canvas Rewrite keeps the replaced text as a Trash `priorVersion` entry (claim M6-PR-037, whose own comment expects versioning to replace it). Replace it with a version, or keep both? | Keep both |
| P2 | Do palette cards get versions? | No |
| P3 | When the previous version cannot be kept, is the save stopped (as tables; at close the edit is dropped) or made anyway with a notice? | Stopped, as tables |
| P4 | RULING-24 says Research is "recoverable but not versioned". Record the 2026-11-10 ruling as an amendment in `register/RULINGS.md`? | Draft in Task 7, not committed to the register until he confirms the wording |

## Review Focus

1. **A note open in the editor is written behind its back** (a restore, the assistant, a wiki rename, Search & Replace). The editor shows the new text and its next keystroke does not put the old text back. (Task 3; exercised again in Tasks 4, 5, 6)
2. **Two notes edited inside one debounce window.** Both are saved, and each version lands under its own item id. (Task 3)
3. **A note moved or renamed between the schedule and the save.** It is written where it now is; the version belongs to the id. (Task 2)
4. **The prior file is missing, empty or not UTF-8.** Missing or empty keeps nothing and saves; unreadable is never saved over (RULING-7 behaviour stays). (Task 2)
5. **A second Mac's versions.** They list and restore here; pruning removes only this device's; a half-arrived pair is not listed. (Task 1)

---

### Task 1: The version store takes a note

Model: sonnet. Single review. Recon §1, §2, §12.4.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Table/ResearchVersionStore.swift`
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/ResearchNoteRecord.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AREA.md`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ResearchVersionStoreTests.swift`, `…/ResearchNoteRecordTests.swift` (create)

**Interfaces (produces):**
```swift
public enum ResearchVersionPayload: String, Sendable, CaseIterable { case table = "csv"; case note = "note" }  // rawValue is the file extension
public struct ResearchVersion { … public let payload: ResearchVersionPayload }   // init gains `payload: ResearchVersionPayload = .table`
public func keep(priorBytes: Data, priorSidecar: ResearchTableSidecar?, writtenBy: ResearchWriter?,
                 replacedBy: ResearchWriter? = nil, payload: ResearchVersionPayload = .table,
                 itemId: String, device: DeviceSlug, at date: Date) throws -> ResearchVersion
public func read(_ version: ResearchVersion) throws -> (Data, ResearchTableSidecar?)   // reads the version's own payload file

public struct ResearchNoteRecord: Codable, Equatable, Sendable {   // who wrote the text now on disk
    public var contentHash: String?; public var writtenBy: ResearchWriter?
    public static let folder = ".maugham/research-notes"
    public static func read(forItem itemId: String, in projectURL: URL) throws -> ResearchNoteRecord?
    public static func write(_ record: ResearchNoteRecord, forItem itemId: String, in projectURL: URL) throws
}
```

**Contract:**
- `versions(itemId:)` lists a version when its `.json` and exactly one payload file (`.csv` or `.note`) exist; the payload kind comes from the extension. Existing `.csv` versions list as `.table` with no change on disk.
- `prune`, `sweepOrphans`, `removeVersions`, `sweepLeftovers` and the staging names treat both extensions alike; retention counts versions, whatever their payload.
- `ResearchNoteRecord` mirrors `ResearchTableSidecar`'s read/write (tolerant decoding, atomic write, item-id validation through `SafeRelativePath.requireDocId`).

- [ ] **Step 1: Failing tests.** In `ResearchVersionStoreTests`: `test_aNoteVersionRoundTripsItsBytesAndListsAsANote`; `test_aTableVersionWrittenBeforeThisChangeStillListsAsATable` (write the two files by hand in the old names); `test_pruneCountsBothPayloadsTogether_andTouchesOnlyItsOwnDevice` (Review Focus 5: two devices, mixed payloads, `keep: 2`); `test_aPayloadWithoutItsMetaIsNotListed_forEitherKind`; `test_sweepOrphansAndRemoveVersionsTakeNotePayloadsToo`. In `ResearchNoteRecordTests`: round trip; a missing file reads nil; a hostile item id is refused and nothing is written.
- [ ] **Step 2: Run; fail** (`./scripts/test.sh core`).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Make `contents(itemId:)` ignore `.note`; the first test fails; revert.
- [ ] **Step 5: `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone` green; Core AREA Map names the new file; commit.**

---

### Task 2: The note door

Model: opus. Dual review. Recon §3 (the table door is the model), §4, §7, §12.5, §12.10.

**Files:**
- Create: `Maugham/Stores/ResearchNoteDoor.swift`
- Modify: `Maugham/Stores/DocumentStore.swift` (owns the door; `FileSavePayload`; the debounce action at ~524), `Maugham/Stores/MaughamSidecarPath.swift` (a route for `ResearchNoteRecord.folder`, as `researchTable`)
- Modify: `Maugham/Stores/AREA.md`
- Test: `MaughamTests/Stores/ResearchNoteDoorTests.swift` (create), `MaughamTests/TripwireGrepTests.swift`

**Interfaces:**
- Consumes: Task 1's `keep(… payload: .note …)`, `ResearchNoteRecord`.
- Produces (on `DocumentStore`):
```swift
enum ResearchNoteSave: Equatable { case saved(keptAVersion: Bool); case notSaved }
@discardableResult
func saveResearchNote(itemId: String, text: String, by writer: ResearchWriter = .writer,
                      restoring: Bool = false) async -> ResearchNoteSave
func researchNoteWasRead(itemId: String, bytes: Data)        // records the bytes as known
func scheduleNoteSave(itemId: String, text: String)           // the editor's debounced save
func researchNoteItem(atPath path: String) -> ResearchItem?   // the one path → note lookup; nil for a non-note
```

**Contract** (the table door, `ResearchTableHost.write`, step for step, for a note):
- The item is found by id and its path asked at the save. No such item or no path: nothing is written, a notice says so.
- The prior bytes are read off the main actor. A file that is missing or empty keeps nothing and the save proceeds. A file that cannot be read is not saved over (notice).
- Per note, in memory, for the store's life: the known hash, a `ResearchSaveRun`, the last kept hash. `researchNoteWasRead` sets the known hash. A save over bytes that are not the known hash keeps a version (an outside change, or a caller that never read the note).
- A version is kept when `restoring`, or when the run says so, and the prior hash is not the last kept hash. The keep and the prune run detached, payload `.note`, `replacedBy: writer`, `writtenBy` from the `ResearchNoteRecord` when its hash matches the prior bytes.
- A keep that fails stops the save (P3 default), posts the table's notice wording for a note, and returns `.notSaved`.
- The write is `performFileSave`. Then: the known hash moves, the `ResearchNoteRecord` is written (`writtenBy: writer`), `researchVersionsRevision` bumps when a version was kept.
- An assistant's save, and a restore, end the writer's run.
- `scheduleNoteSave` replaces the editor's use of `scheduleFileSave`: its payload carries the item id, and the debounce action calls the door. `scheduleFileSave(for:text:)` stays for `PartialRestorePicker` (a manuscript render, not a note). A second arrival of the same text for the same note (the scheduler's flush racing its own run) writes once and keeps once.
- The door has an injectable clock, as `ResearchTableHost.now`.

- [ ] **Step 1: Failing tests** in `ResearchNoteDoorTests` (a real project in `TestTemp.root`, a note made through `createResearchNote`):

| Test | Asserts |
|---|---|
| `test_theFirstSaveOfARunKeepsTheTextBeforeIt_andTheNextSaveInsideTheGapKeepsNothing` | versions count 1 then still 1; the version's bytes are the pre-run text |
| `test_aSaveAfterTheGapKeepsAgain` | clock moved 10 min + 1 s: count 2 |
| `test_aSaveOverBytesTheStoreNeverReadKeepsAVersion` | no `researchNoteWasRead`: kept |
| `test_anOutsideChangeIsKept` | file rewritten on disk between two saves in one run: count 2 |
| `test_aMissingOrEmptyFileKeepsNothingAndSaves` | `.saved(keptAVersion: false)`, file holds the text |
| `test_anUnreadableFileIsNotSavedOver` | invalid UTF-8 on disk… the door reads bytes, so "unreadable" is a file the read throws on (a directory at the path): `.notSaved`, nothing written |
| `test_aNoteMovedBetweenScheduleAndSaveIsWrittenWhereItNowIs` | Review Focus 3: move the item through the typed mover, then save by id |
| `test_aKeepThatFailsStopsTheSave` | versions folder made unwritable: `.notSaved`, file unchanged |
| `test_theAssistantsSaveAlwaysKeeps_marksTheVersion_andEndsTheRun` | `replacedBy == .assistant`; the writer's next save keeps again, and that version's `writtenBy == .assistant` |
| `test_theSameTextArrivingTwiceWritesAndKeepsOnce` | two concurrent `saveResearchNote` calls with one text |
| `test_aNonNoteIsRefused` | a table id and a palette card id: `.notSaved`, nothing kept (P2 default) |

- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Census.** `researchTableWriteSites` gains the door's `.keep(priorBytes:` and `.performFileSave(` sites; the planted-offender test still fires.
- [ ] **Step 5: Disable experiment.** Remove the known-hash comparison; `test_anOutsideChangeIsKept` fails; revert.
- [ ] **Step 6: Stores AREA (Map + one rule, paid for); `./scripts/test.sh` green; commit.**

---

### Task 3: The editor saves through the door and takes text written behind it

Model: opus. Dual review (the binding). Recon §5, §12.1, §12.6.

**Files:**
- Modify: `Maugham/Views/ResearchNoteEditor.swift`, `Maugham/Views/ResearchSubjectColumns.swift` (~268: pass `shareIsReadOnly`)
- Modify: `Maugham/Stores/ResearchNoteDoor.swift` (the reload signal)
- Modify: `Maugham/Views/AREA.md`, `Maugham/Editor/AREA.md`
- Test: `MaughamTests/Views/ResearchNoteEditorReloadTests.swift` (create)

**Interfaces:**
- Consumes: Task 2's `scheduleNoteSave`, `researchNoteWasRead`, `saveResearchNote`.
- Produces (on `DocumentStore`): `func researchNoteReloadCount(itemId: String) -> Int` (observed) — it moves when the door wrote a note for anyone but the editor's own debounced save. Tasks 4, 5 and 6 rely on it without calling it.

**Contract:**
- The binding setter calls `scheduleNoteSave(itemId:text:)`. `loadDocument()` reports the bytes it read through `researchNoteWasRead`.
- When the reload count for its item moves, the editor re-reads the file into `documentText` and schedules no save. The text reaches the text view through the existing binding and the one `applyExternalText` call.
- A door write for a note that has a pending debounced save flushes that save first, so the pending text is the version the write replaces.
- A view-only share locks the note editor as Review does (`lockEditing`).
- Known and accepted: the debounce has one slot; `loadDocument()`'s flush before a switch is what keeps the first note's save. That flush stays.

- [ ] **Step 1: Failing tests** (mount `ResearchNoteEditor` through `TestWindow.mount`; drive saves by `flushPendingSave`, never by waiting):

| Test | Asserts |
|---|---|
| `test_aDoorWriteBehindTheEditorIsShown_andTheNextKeystrokeKeepsIt` | Review Focus 1: door-save "B" as `.assistant` while the editor shows "A"; the text view shows "B"; type "x"; flush; the file is "Bx" |
| `test_theEditorsOwnSaveDoesNotReloadIt` | reload count unchanged across a typed save; `applyExternalText` count unchanged |
| `test_aPendingEditIsSavedBeforeADoorWriteReplacesIt` | type "A1" (unflushed), door-save "B": the newest version's bytes are "A1" |
| `test_twoNotesEditedInsideOneWindowAreBothSaved_eachUnderItsOwnId` | Review Focus 2 |
| `test_aViewOnlyShareLocksTheNoteEditor` | typing is refused; no save is scheduled |

- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Remove the reload; the first test fails with the file "Ax"; revert.
- [ ] **Step 5: AREA lines (Views has zero headroom: pay for them); `./scripts/test.sh` green; commit.**

---

### Task 4: Every other writer of a note goes through the door

Model: opus. Dual review. Recon §6 (the table of writers), §11 (claims).

**Files:**
- Modify: `Maugham/Canvas/PromotionPerformer.swift` (Rewrite `writeBody`/`write(_:toPath:)` ~948–1002; link appends ~716–734, ~909–927), `Maugham/Stores/ProjectStore+Structure.swift` (wiki rename ~722–762), `Maugham/Stores/ProjectStore+Search.swift` (~136–151, ~187–203), `Maugham/Stores/ProjectStore+Research.swift` (~943) and `ProjectStore+ResearchMove.swift` (~266, ~337)
- Modify: the AREA guides of the folders touched
- Test: `MaughamTests/Stores/ResearchNoteWritersTests.swift` (create), `MaughamTests/TripwireGrepTests.swift`

**Interfaces:** Consumes `saveResearchNote(itemId:text:by:)`, `researchNoteItem(atPath:)`.

**Contract:**
- Each writer in recon §6 rows 2–6 that overwrites an existing note calls the door as `.writer`. A row whose target is not a note (a palette card: rows 4 and 7) keeps the write it has today (P2 default).
- Create-time fills (rows 8–10: `LetterKeep`, `InboxStore.promote`, `AddNoteTool`) are not overwrites and are left alone.
- Search & Replace's research arm stops writing raw: it flushes pending saves, then goes through the door.
- Where there is no `DocumentStore` (the existing fallbacks), the write stays as it is and keeps nothing.
- The Rewrite still makes its Trash `priorVersion` entry (P1 default).
- A census names the callers of `saveResearchNote` by type and count, with a planted offender: a raw `.write(to:` on a research note path outside the allowed files fails it.

- [ ] **Step 1: Failing tests,** one per writer: after the write, the note's newest version holds the text before it; and for Search & Replace, a note open with an unflushed edit is not clobbered. `test_aWikiRenameThatRewritesAPaletteCardKeepsNoVersion`.
- [ ] **Step 2: Run; fail.** 
- [ ] **Step 3: Implement.** 
- [ ] **Step 4: Census + `researchTableWriteSites` counts.** 
- [ ] **Step 5: Run `PromotionCharacterization`, `PromotionPerformerTests`, the search and rename suites; green.**
- [ ] **Step 6: Disable experiment** (put one raw write back; its test and the census fail; revert). **`./scripts/test.sh` green; commit.**

---

### Task 5: Versions in the inspector, and Restore

Model: sonnet. Single review. Recon §8.

**Files:**
- Modify: `Maugham/Views/InspectorResearchPanel.swift` (~83), `Maugham/Views/ResearchVersionsSection.swift`, `Maugham/Stores/ResearchNoteDoor.swift`
- Modify: `Maugham/Views/AREA.md`
- Test: `MaughamTests/Views/ResearchVersionsModelTests.swift`, `MaughamTests/Stores/ResearchNoteRestoreTests.swift` (create)

**Interfaces:**
- Produces: `DocumentStore.restoreResearchNote(itemId: String, to version: ResearchVersion, shareIsReadOnly: Bool) async throws` — refuses a view-only share as `restoreResearchTable` does; refuses a version whose `payload != .note`; reads the version; goes through the door with `restoring: true`.

**Contract:**
- The Versions section shows for a note as it does for a table, with the same headline, buttons, marks and refusal sentences.
- A version whose payload is not the item's current kind is listed with Restore off.
- A note restore says "Restored." A restore that could not be made says why and leaves the note as it was.
- Restoring the text the note already holds writes and keeps nothing.

- [ ] **Step 1: Failing tests:** `test_restoringPutsTheVersionBack_andKeepsWhatItReplaced_soRestoringAgainUndoesIt`; `test_restoringTheSameTextWritesNothing`; `test_aViewOnlyShareRefusesANoteRestore`; `test_aTablePayloadIsNotRestoredIntoANote`; model: `test_aVersionOfAnotherKindIsListedButNotOffered`; `test_theSectionShowsForANote` (the panel's condition as a pure function).
- [ ] **Step 2–3: Run; fail; implement.**
- [ ] **Step 4: Disable experiment** (drop `restoring: true`; the first test fails); **`./scripts/test.sh` green; commit.**

---

### Task 6: The assistant's note tool

Model: opus. Dual review. Recon §10; `Maugham/MCP/AREA.md` "Add a tool" (steps 1–10).

**Files:**
- Create: `Maugham/MCP/Tools/UpdateNoteTool.swift`, `docs/adr/00NN-the-assistant-may-rewrite-a-research-note.md` (next free number)
- Modify: `Maugham/MCP/MCPTool.swift` (the catalogue), `Maugham/MCP/AREA.md` (list, `## Tool catalogue (67)`, the write-destinations rule), `docs/skills/maugham-bootstrap/SKILL.md`, `docs/guide/claude-desktop.md`
- Test: `MaughamTests/MCP/Tools/UpdateNoteToolTests.swift` (create), `MaughamTests/MCP/MCPProtocolHandlersTests.swift` (name set), `MaughamTests/CompilerAllowlistTests.swift` (`writeTools`)

**Interfaces:** Consumes `saveResearchNote(itemId:text:by: .assistant)`.

**Contract:**
- `method = "update_note"`; params `project_id`, `research_id`, `body`; result `id`, `title`, `path`, `kept_previous_version: Bool`.
- Order: resolve the project; refuse a view-only share (`MCPShareLock`, sentence "This share is view-only, so a research note can’t be changed."); find the item ("No Research item with id '…'. Use list_research for the ids."); refuse a non-note with what it is ("'<title>' (<id>) is a Research table, not a note; use write_research_cells." and the like for a picture, a PDF, a palette card, a group); need the project's `DocumentStore` (the table tools' sentence, for a note); save through the door as the assistant.
- `.notSaved` is an `MCPError` saying the note was not changed.
- The description says the previous text is kept and can be restored from the inspector, and names `read_document` and `list_research` as its companions.
- It is not in `CompilerAllowlist`. Its response is far under 1 MB (tripwire 10).

- [ ] **Step 1: Failing tests:** `test_itReplacesTheBody_keepsTheWritersText_andMarksTheVersion` (`replacedBy == .assistant`); `test_aNoteOpenWithAnUnflushedEditKeepsThatEditAsTheVersion`; `test_itRefusesATable_APicture_APaletteCard_AGroup_sayingWhatEachIs`; `test_itRefusesAViewOnlyShare_andWritesNothing`; `test_anUnknownIdSaysToUseListResearch`; the three hand lists.
- [ ] **Step 2–3: Run; fail; implement; write the ADR** (why: an attributed, versioned door beats the assistant editing files on disk; scope: Research notes only).
- [ ] **Step 4: Disable experiment** (save as `.writer`; the mark test fails); **`./scripts/test.sh` green; commit.**

---

### Task 7: The guide, the claims and the ruling

Model: sonnet. Single review. Recon §11.

**Files:**
- Modify: `docs/guide/research.md` (the line "Research notes, pictures and PDFs are not versioned" is now false), `docs/guide/backups-and-history.md` if it speaks of Research
- Modify: `register/reconciliation/*.claims.json` and filings (read `register/START-HERE.md` and `register/reconciliation/PROTOCOL.md` first): new claims for note versions, each pinned by a test from Tasks 2–6; `M1-C-055`'s second half; `M6-PR-037` (unchanged under P1's default; say so)
- Create: `docs/superpowers/notes/2026-11-10-ruling-24-amendment-draft.md` (P4: the proposed wording, for Denver; `register/RULINGS.md` and its hash file are not touched)
- Modify: `docs/INDEX.md`, and the roadmap if it lists research protection

- [ ] **Step 1: Sweep** `grep -rn "not versioned\|research-versions\|Research table.*version" docs Maugham/*/AREA.md register --include="*.md"` for now-false claims; fix each.
- [ ] **Step 2: Claims and filings per the protocol; `DocSyncTests`, `DocBudgetTests` and the register's own tests green.**
- [ ] **Step 3: `./scripts/test.sh full` green; commit.**
