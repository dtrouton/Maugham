# Hardening 11-11, plan 2: Research tables, updates, doc truth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Research table's edits are never dropped at ⌘S, a grid leave, a window close or ⌘Q; a table host is never registered closed; no save lands over bytes it did not read; the phone's figure cache follows trust; a background update check never wipes a state that carried information. Closes #138, #137, and #139's D2.

**Architecture:** `ResearchTableHost.write` learns which kind of save it is (the debounce timer or a flush) and answers with a value saying what it did, mirroring `ResearchNoteDoor.SaveSource`. A flush that may not write over the file keeps the held CSV through `Document.writeConflictBackup(kind: "unsaved")`, exactly as the note door's flush does. The expected-hash check lives inside the one coordinated write, shared by the table and the note door. The update checker's background entry becomes an exhaustive switch that restores the state it began from.

**Tech Stack:** Swift, SwiftUI + AppKit, the local `MaughamCore` package, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-11-hardening-open-issues-design.md` (§5, §6, §7; ruling R-C). Read it before any task; R-C is Denver's and is not reopened here. Plan 1 (`2026-11-11-hardening-plan-1-figure-notes.md`) is built; this plan was derived against the code at `e88514ef`.

Branch `claude/hardening-2026-11-11`. Sources: `gh issue view 138`, `gh issue view 137`, `gh issue view 139`. **Line numbers in the issues have drifted: find code by symbol.**

## Global Constraints

- Read the area guide `CLAUDE.md` names for each path before editing it (`Maugham/Editor/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/Updates/AREA.md`, `MaughamPhone/AREA.md`, `Packages/MaughamCore/Sources/MaughamCore/AREA.md`), and the tripwire rows in `docs/tripwires.md` your change rhymes with (19, 33, 58 most of all).
- Test first: write the failing test, watch it fail for the stated reason, then fix.
- **Disable experiment on every negative assertion** ("writes nothing over the file", "no second backup", "is not registered", "is skipped"): remove the guard, watch the test fail, restore it, and put the output in your report.
- Run `./gen.sh` after adding any file. Gate with `./scripts/test.sh`; when `Packages/MaughamCore` or `MaughamPhone` changes, also `./scripts/test.sh core` and `./scripts/test.sh phone`. Never raw `swift test` or `xcodebuild test`. Run gates in the foreground, after your last edit.
- Tests are windowless where possible; no press-then-wait (tripwire 33): drive an interleaving through an awaited seam, never a sleep. Temp roots through `TestTemp`.
- A census test in `TripwireGrepTests` that names a function this plan re-signs (`researchFileSaveFunctions`, `researchTableWriteSites`) is updated in the same commit, to the new key and the same count discipline; no entry is loosened.
- Notices go through `MaughamEvent.postNotice(_:projectURL:)`, in the voice of the sentences beside them. Nothing is silent: every arm that does not save says so once.
- MCP's table writes (`assistantEdit`, `by: .assistant`) and `restore` are **not flushes**: their refusals are unchanged by this plan.
- Register files are updated in Task 7, not piecemeal.
- One commit per task, message `hardening 11-11 task 2.N — …`, ending with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Don't push.
- Report: files changed, tests added with their disable-experiment output, the gate result, and anything you judged that the coordinator should check.

## Review Focus

1. **`settle` then `close()` on the way out** (⌘Q runs both): a flush that ended in a backup leaves the host clean, so the second flush writes no second copy and says nothing twice. → Task 2.
2. **A flush with nothing held** over a file that is gone, unreadable or outside Research: no backup, no notice. → Task 2.
3. **An open cell edit at ⌘Q** (`settle(commitOpenEdits: true)`): the edit still in the cell editor is in the saved file, or in the backup when the file may not be written. → Task 2.
4. **The file changes twice** between the read and the write (the retry also meets new bytes): nothing is written over it; a flush keeps the edits aside, the timer stays dirty. → Task 4.
5. **A background check that fails from `.error` or `.newerBuildNeedsNewerSystem`** restores that exact state, payload included, not `.idle`. → Task 6.

---

### Task 1 — `write` says what it did, and knows whether it is the timer or a flush (#138 R1, first half) [opus]

**Files:**
- Modify: `Maugham/Editor/ResearchTableHost.swift` (`write`, `save`, `flush`, `scheduleSave`, `assistantEdit`, `restore`), `MaughamTests/TripwireGrepTests.swift` (the census key for `write`)
- Test: `MaughamTests/Editor/ResearchTableVersionTests.swift`, `ResearchTableGridTests.swift`, `ResearchTableOutsideResearchTests.swift`

**Interfaces — Produces (Tasks 2 and 4 rely on these names):**
- `enum ResearchTableHost.SaveSource: Equatable { case timer, flush, direct }` — `timer` is the debounced save; `flush` is `settle`, the grid's leave and `close()`; `direct` is `assistantEdit`, `restore`, and the pre-flush each of those runs to land the writer's pending edits.
- `enum ResearchTableHost.WriteOutcome: Equatable { case wrote, refused(Refusal) }` with `enum Refusal: Equatable { case noStore, itemGone, outsideResearch, fileGone, priorUnreadable, outsideVersionNotKept, versionNotKept, saveFailed }`.
- `write(_:by:restoring:source:) async -> WriteOutcome` (private); `func flush() async` keeps its name and passes `.flush`; a new `private func landPendingEdits() async -> WriteOutcome` (source `.direct`) replaces the `flush()` calls inside `assistantEdit` and `restore`.
- A test entry for the debounced path that needs no sleep: `func saveAsTheTimerForTesting() async` (cancels the scheduled save and runs the `.timer` save).

- [ ] Tests first. For `.timer` and `.direct`, every refusal leaves `isDirty` true and posts today's sentence once — including the three arms that today leave it clear (`itemGone`, `outsideResearch`, `fileGone`); `noStore` stays silent but dirty. Move the existing refusal tests that call `host.flush()` and expect "refused and dirty" onto `saveAsTheTimerForTesting()`; `test_anAssistantWriteRefusesWhenTheWritersPendingEditCannotBeSaved` and `test_aRestoreThatCannotSaveLeavesTheTableAsItWas` stay as they are and stay green.
- [ ] In this task `.flush` behaves exactly as `.timer` (Task 2 changes it). `test_aSaveWhoseFileHasGoneDoesNotRecreateIt` keeps "the file is not made again" and now expects the host dirty.
- [ ] `save()` no longer clears `isDirty` before it knows the outcome in a way a refusal can leave clear: the host is clean iff the outcome is `.wrote`.
- [ ] Census: `researchFileSaveFunctions`' key becomes `ResearchTableHost.swift:write(_:by:restoring:source:)`; counts unchanged.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 2 — a flush never drops the edits (#138 R1; ruling R-C) [opus]

**Files:**
- Modify: `Maugham/Editor/ResearchTableHost.swift`
- Test: `MaughamTests/Editor/ResearchTableVersionTests.swift` (the arms hang off `test_aVersionThatCannotBeKeptWritesNothing`), `ResearchTableGridTests.swift`

**Interfaces:**
- Consumes: Task 1's `SaveSource`, `WriteOutcome`, `Refusal`; `Document.writeConflictBackup(forFileAt:docId:text:kind:at:)` with `kind: "unsaved"`; the note door's `keepTheFlushedText` / `unreachable` as the model for wording and for the fallback anchor.
- Produces: `WriteOutcome` gains `case keptAside(URL)` and `case notKept` (a flush whose backup also failed). `private func keepTheFlushedTable(_ table: FigureTable, couldNot: String, anchor: URL) -> WriteOutcome`.

What a `.flush` does with each refusal (spec §5 R1, binding):

| Refusal | A flush… |
|---|---|
| `versionNotKept` | saves anyway; notice says the previous version was not kept (the note door's "…couldn't be kept; saved anyway" shape) |
| `priorUnreadable`, `itemGone`, `outsideResearch`, `outsideVersionNotKept`, `saveFailed` | writes nothing over the file; the held table's CSV goes to `.maugham/conflicts/*-unsaved-*.csv`; the notice names the file |
| `fileGone` | the file is **not made again**; the CSV goes to the same backup |
| the backup itself fails | says in plain words that the edits were not saved and could not be kept anywhere else |
| `noStore` | unchanged (nothing to write through) |

- [ ] The backup's anchor is the item's own resolved path when it has one ending `.csv`; otherwise `<project>/research/table.csv` with `// local-path:` as the note door's fallback does (tripwire 58), so the name always ends `-unsaved-<stamp>.csv`. The backup holds the CSV text only; the notice does not promise formats.
- [ ] After `keptAside` or `notKept` the host is **clean** (Review Focus 1): `settle` then `close()` writes one backup and one notice. Test it through `DocumentStore.flushPendingSave(commitOpenEdits: true)` followed by `releaseResearchTable`.
- [ ] One test per row of the table, each ending in either the edits on disk or a `.maugham/conflicts/*-unsaved-*.csv` whose rows are the held table's, plus the notice text. Force the arms as the existing tests do (a file planted at `ResearchVersionStore.folder`; `chmod 0o000` on the CSV; `lock` the folder; `mutateResearchItem` to a stray path; `removeItem`; `removeResearchItem(id:)`; `.maugham/conflicts` locked for the backup-fails arm). `outsideVersionNotKept` needs a seam, because the outside backup and the unsaved backup share a folder: add `static var outsideBackupForTesting: ((Data) -> URL?)?` consulted by `keepTheOutsideVersion`, reset in tearDown like the file's other seams.
- [ ] Review Focus 2: a flush on a clean host over a gone / unreadable / stray file writes no backup and posts nothing. Review Focus 3: mount a grid with an open cell edit, run `flushPendingSave(commitOpenEdits: true)` with the file's folder locked; the backup's rows include the open edit.
- [ ] The grid's leave (`ResearchTableMount.leave()`) and `close()` reach the same arms: one test each for the save-anyway row.
- [ ] `.timer` and `.direct` are untouched: the Task 1 tests stay green unchanged. Replace the "dropped and said" comment above the file-gone branch.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 3 — a closing or closed host is never registered or handed back (#138 R2) [opus]

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (`openResearchTable`, `releaseResearchTable`), `Maugham/Editor/ResearchTableHost.swift` (a load seam)
- Test: `MaughamTests/Editor/ResearchTableGridTests.swift` (or a new `ResearchTableOpeningTests.swift`; `./gen.sh`)

**Interfaces — Produces:** `static var duringLoadForTesting: (() async -> Void)?` on `ResearchTableHost`, awaited inside `load(itemId:store:)` after the host is built, mirroring `duringReloadForTesting`.

- [ ] Tests first, driven through the seam (no sleeps): (a) two opens share one opening task; while it is suspended the first caller's use is released; when the task resolves the second caller gets a live, registered host, and `researchTables[itemId]` is that same host; (b) a host that closed while the opening was suspended is never registered, and a closed entry found in the registry is replaced; (c) every caller of one opening gets the identical instance, and its use count equals the number of callers still holding it; (d) an opening that throws leaves no entry and no use count.
- [ ] Fix: after the shared opening task resolves, re-check the closings and the registry: await a closing in flight; if the registered host is live return **it**; if the resolved host is closed or closing, load again (bounded: one fresh load, then throw the load's error) rather than registering it. `releaseResearchTable` on a host that is not the registered one stays a no-op.
- [ ] MCP's open/release pairs in `Maugham/MCP/Tools/ResearchTableTools.swift` need no change; say in the report that you checked each pairs its release on every path.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 4 — a save re-checks the bytes inside the coordinated write (#138 R3) [opus]

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (`performFileSave`), `Maugham/Editor/ResearchTableHost.swift`, `Maugham/Stores/ResearchNoteDoor.swift`, `MaughamTests/TripwireGrepTests.swift`
- Test: `MaughamTests/Editor/ResearchTableVersionTests.swift`, `MaughamTests/Stores/ResearchNoteDoorTests.swift`

**Interfaces — Produces:**
- `func performFileSave(path: String, text: String, expecting: FileExpectation) async throws`, where `enum FileExpectation { case anything; case bytesHashing(String); case absent }`; the existing two-argument form forwards `.anything` (the `fileSaveScheduler` closure keeps it). Inside the `NSFileCoordinator` block, before the write, it reads the file and throws `FileSaveError.changedSinceRead` on a mismatch. The hash is the one each door already computes for its prior bytes.
- A test seam to land outside bytes after the door's read and before its write: `static var beforeCoordinatedWriteForTesting: (() -> Void)?` on `DocumentStore`, called just before the coordinator is entered.

- [ ] Table: `write` passes `.bytesHashing(onDiskHash)`. On `changedSinceRead` it runs its door again from the read, **once**: the new bytes take the existing outside-change branch (`keepTheOutsideVersion`, then write, then the "changed outside Maugham… kept in .maugham/conflicts" notice). A second mismatch is `saveFailed` (Review Focus 4): the timer stays dirty, a flush keeps the edits aside (Task 2).
- [ ] Note door: it has no outside-change branch; unknown prior bytes are kept as a **version** (`keepsAVersion(overOwnBytes:)`). On `changedSinceRead` it likewise re-runs its `write` once from `PriorBytes.read`, so the new bytes are kept as a version before the note is saved; a second mismatch follows its existing save-failure arm for that `SaveSource` (flush → `keepTheFlushedText`).
- [ ] Tests, both doors: outside bytes landed through the seam are never overwritten unseen — after the save, the outside bytes exist as a conflict backup (table) or a kept version (note) and the door's text is on disk; landing bytes on the retry too leaves the file as the outside wrote it. Disable experiment: pass `.anything` and watch the outside bytes vanish.
- [ ] Census: `researchTableWriteSites`' `.performFileSave(` counts per type are unchanged if the call is re-labelled in place; update `researchFileSaveFunctions` only if a signature moved. No new raw write.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 5 — the phone's figure cache follows trust (#138 R4) [sonnet]

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureCache.swift`, `MaughamPhone/Read/PhoneFigureBook.swift`; `Maugham/Stores/DocumentStore+Figures.swift` only if adopting the Core call there is a one-line change that keeps `figureTrustChanged`'s other work
- Test: Core `FigureCacheTests`, `MaughamPhoneTests/PhoneFigureBookTests.swift`

**Interfaces — Produces:** `public func FigureCache.noteTrust(_ trust: TrustTable)` — remembers the last table it was given and calls `invalidateAll()` when a later one differs (`TrustTable` is `Equatable`); the first call invalidates nothing.

- [ ] Core tests: same table twice → `deriveCount` does not move on a re-read; a different table → the next read derives again; first call → no invalidation.
- [ ] `PhoneFigureBook.load` calls `cache.noteTrust(trust)` right after `resolveTrust` answers. Phone test with the injected `resolveTrust`: load, change the table the closure returns, load again → the card is derived again (observe through the book's public surface or `deriveCount` exposed for tests); unchanged trust → not derived again.
- [ ] Say in the report whether the Mac adopted `noteTrust` or kept its event path, and why.
- [ ] Gates: `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone`. Commit.

### Task 6 — a background check never wipes a state that carried information (#137 U1, U2) [sonnet]

**Files:**
- Modify: `Maugham/Updates/UpdateChecker.swift` (`checkInBackgroundIfDue`, `performCheck`'s background failure exits, `startBackgroundLoop`), `Maugham/Updates/GitHubReleasesAPI.swift` (the stale "24h poll" comment)
- Test: `MaughamTests/Updates/UpdateScheduleTests.swift`; share `UpdateCheckerTests`' `makeChecker` / `release` helpers by moving them to an internal test helper file (`./gen.sh`)

**Interfaces — Produces:** `startBackgroundLoop(workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter, appCenter: NotificationCenter = .default, enabled: Bool = BuildVariant.current.updaterEnabled)`.

- [ ] U1. `checkInBackgroundIfDue` decides by an exhaustive `switch` with no `default`: `.idle`, `.upToDate`, `.error`, `.newerBuildNeedsNewerSystem` check; `.checking`, `.downloading`, `.readyToInstall`, `.installing` skip. A `.background` check that ends at any of `performCheck`'s failure/decline exits restores the state it began from (payload included) where today it sets `.idle`; a manual check is unchanged.
- [ ] One test per state (eight), reaching each through the public surface (`performCheck`, `installNow` with `performInstall` nil, a `systemVersion` plus body marker): the skip states make no fetch and keep their state; the check states fetch once; a failing fetch from `.error("x")` ends `.error("x")`, from `.newerBuildNeedsNewerSystem` ends equal to the starting value, from `.upToDate` ends `.upToDate` (Review Focus 5). `test_backgroundFailureRevertsToIdle` stays green (it starts idle).
- [ ] U2. The wake and activation observers use the injected centers. Test: `startBackgroundLoop(workspaceCenter: a, appCenter: b, enabled: true)` on a due checker; post `NSWorkspace.didWakeNotification` on `a` → exactly one fetch; make it due again, post `NSApplication.didBecomeActiveNotification` on `b` → one more. Await the fetch through the injected closure (a continuation), never a sleep. `stopBackgroundLoop()` is the tests' teardown and is asserted to remove both observers (a post after it fetches nothing); it stays, and its doc comment says who calls it.
- [ ] Gate: `./scripts/test.sh`. Commit.

### Task 7 — the register, the docs, D2 [sonnet]

**Files:** `register/RULINGS.md`, `register/reconciliation/Annotations.claims.json` + `.filings.json` (Research claims live there, beside M5-AN-067 and M5-AN-070), `ruling-hashes.json`, `register/START-HERE.md` (by the generator; `StartHereCountsTests` must stay green), `Maugham/Editor/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/Updates/AREA.md`, `MaughamPhone/AREA.md`, `docs/guide/reference.md`, `docs/guide/research.md`, `scripts/test.sh`. Follow `register/reconciliation/PROTOCOL.md`; scripts only for `_summary`, hashes and the table.

- [ ] R-C as the next free ruling number (RULING-60 unless one was added since), `RATIFIED_FROM_OPTIONS`, statement verbatim from the spec's R-C, provenance note in RULING-57's form. Only Denver's ruling is a ruling: every call listed under the spec's "Calls made here that are not Denver's rulings", and any the coordinator's ledger adds, appears only as claim text marked "coordinator's call, hardening 2026-11-11, not yet ruled by Denver", filed `NO_RULING_REACHES` where no ruling reaches it.
- [ ] Claims, each naming an existing, passing pinning test (grep the exact name): the table close arms (one claim per row of Task 2's table, or one claim listing them, as the module's style has it); the host registry rule (Task 3); the expected-hash save for both doors (Task 4). Update M5-AN-067 / M5-AN-070 where Tasks 1–4 changed what they state.
- [ ] Docs: `docs/guide/reference.md` says every six hours, on wake, and on switching back to Maugham (replacing "once a day"); `docs/guide/research.md` gains the sentence on edits kept aside at close; `Maugham/Updates/AREA.md` gains a testability row for the schedule and names `UpdateScheduleTests` in its Tests list; `Maugham/Editor/AREA.md` and `Maugham/Stores/AREA.md` (its `.maugham/conflicts/` row) describe the table and note doors' `unsaved` and `outside` backups; `MaughamPhone/AREA.md` notes the trust rule. Mind any doc word-budget test in the core gate.
- [ ] D2: `scripts/test.sh` line 4's header says three slow suites, matching lines 33–34 and `CLAUDE.md`.
- [ ] Post nothing to GitHub and close no issue.
- [ ] Gates: `./scripts/test.sh core`, `./scripts/test.sh`, and the claims package the way `register/README.md` says. Commit.
