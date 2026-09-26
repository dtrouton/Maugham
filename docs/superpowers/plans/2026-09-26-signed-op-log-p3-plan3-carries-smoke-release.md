# Signed op log P3 plan 3 — the carries, the closing smoke, the paired release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every carry P3 still owes (C4, C10+C17, C12, C14, Ruling U's re-stamp, the deferred minors worth doing), then run the closing smoke on the rig and cut the paired Mac + phone release on schema 9.

**Architecture:** No new mechanism. Each task corrects one seam that plans 1–2 left stated as a limit: the admission sheet learns closed documents' held lines from a background sweep; the derived `.md` follows a trust re-read; the starter yield is re-asked on the same re-read that brings text in; the test suites get one temp root per test with a census; tripwire 33 grows a click arm. Tasks 9–10 are docs, smoke and release.

**Tech Stack:** Swift 6, SwiftUI/AppKit/UIKit, XCTest. MaughamCore + the Mac target + MaughamPhone.

**Spec:** `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md`. The work list is `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` → **"Plan 3 — what is left before P3 ships"** (:1022–1128) and the P2 carries (:80–108). Rulings A–AL are in the plan-1 ledger and A–W in the plan-2 ledger (`.superpowers/sdd/…/progress.md`). **Where this plan, the spec and a ruling differ, stop and say so — do not pick.**

## How to read this plan

It gives contracts, the failure each must not have, and **signatures verified at file+line on 2026-09-26 against main `f4e38ca7`**. It gives no function bodies (memory: *a plan's code is a liability*). If a cited line has moved, find the symbol. If a cited signature is WRONG, stop and report: that is a plan defect.

**The disable experiment is required on every negative assertion**: remove the REAL guard, watch the test fail, restore it, and put the failing output in your report. Wrap the experiment in a line containing `EXPERIMENT`.

**State every rule in both directions, and check the ruling, not just the code.** Where a task says "every site", derive the list with a grep census, never from this plan.

## Global Constraints

- **Behaviour-neutral for every book with no narrowing permit**, except C12's re-render (Task 4), which applies to every book, and the test-only tasks. Every existing suite passes untouched except the tests each task names as flipping.
- Tripwires 19 and 38–52 bind. 19: anything both surfaces do is ONE Core implementation. 33: no press-then-wait (Task 2 widens it). 39: every trust closure comes from a `TrustTable`. 46: `OpLogStore.localWritePermit` is the one builder. 51: surfaces ask `Posture`. 52: every manuscript writer outside the editor asks first.
- **Rendering the `.md` is not a text write** (`performAutosave`'s own comment at `Document.swift:838–842`). Whatever `performAutosave`'s guards refuse today stays refused; Task 4 adds triggers, never a second writer.
- MaughamPhone/AREA.md's iOS tripwires bind.
- Hide, don't disable (in-pane verbs).
- The AI actor is never given a product name.
- Fixtures register their roots (after Task 1: through `TestTemp`). Every test asserting *verified* injects the test signer (tripwire 36).
- **Process:** branch `claude/signed-op-log-p3-plan3-2026-09-26` off main. Implementers work SEQUENTIALLY in the main checkout.
  - Commit with `git commit -- <paths>`. Never amend, and every commit must build alone. Run `./gen.sh` in the same step as any file you add or delete.
  - `pgrep -x xcodebuild`, never `-f`. No wait loop with `xcodebuild` in its argv.
  - Never read a gate's exit status through a pipe.
  - **The disk is at 95% (24 GB free on 2026-09-26).** Check `df -h /System/Volumes/Data` before every full gate. Below 15 GB, delete DerivedData folders whose `info.plist` `WorkspacePath` no longer exists, and report it.
  - Gates: Core through `./scripts/test.sh core` (never a bare `swift test` — the `xctest` kill), `./scripts/test.sh`, and `./scripts/test.sh phone` for any Core or phone change. Run `./scripts/test.sh full` plus a Release build on Tasks 1, 3, 4 and 9.
  - **END YOUR TURN WITH THE HAND-BACK.**
- **Models:** opus implementers throughout. Task reviewers are sonnet, except Tasks 3 and 4, which get opus (the held-line union and the re-read seam). The whole-branch review is fable, given all four P3 ledgers (P3a, P3b, P3c plan 1, P3c plan 2) plus this plan's.

## Review Focus

1. **A stranger's lines live only in a CLOSED document.** The root opens the book with no document open. The admission sheet appears with the right count once the sweep lands, and it does not ask twice (Task 3).
2. **A document closes after the sweep ran.** Its held lines must not vanish from the count until the next sweep. They move from the open union into the closed map (Task 3).
3. **A reviewer's Mac, and a narrowed author, after an admission.** The `.md` re-render must not throw, write a signed op, or post a refusal. It goes through `performAutosave`'s existing guards only (Task 4).
4. **The root pressed *Not now*, and then another book author's text arrives by sync.** The yield lifts on that re-read, with no reopen and no trust change (Task 4).
5. **A test creates its fixture in `class func setUp`** and uses it across every test in the class. The per-test temp root must not delete it between tests (Task 1).

## Rulings this plan makes (confirm at plan review)

- **OB-1 — an old build over an un-narrowed book: LEAVE IT** (Denver ruled on 2026-09-26). The paired release is the answer and a mixed fleet is a transient. I4 and the old build's `startedBy` drop become ADR limits and release-note lines (Task 9). No code.
- **C4-1 — the sheet does not wait for the sweep.** The open-time sheet may first describe itself from open documents plus the inbox, then re-describe when the closed-document sweep lands, through the existing `postAdmissionRequested`. *Cost if wrong:* a count that rises once, seconds after open.
- **C12-1 — an OPEN document re-renders its `.md` after any applied external re-read**, not only after a trust change. That re-read is the one place a trust change reaches the text, and "after sync" is the same lag (the survey found `handleExternalLogChange` never schedules an autosave, whereas `handleExternalDiskChange` does at `Document+ExternalChange.swift:46–47`). **A CLOSED document re-renders at its next open**: the load schedules an autosave when the on-disk `.md` differs from the render. The "diverged" conflict backup it already writes stays, as evidence. *Cost if wrong:* every Mac writes the derived `.md` after sync, so iCloud sees more `.md` writes, all of the same bytes.
- **C14-1 — the click arm censuses every SYNTHETIC MOUSE CLICK in a test function, not only click-wait-click.** The waits live inside helpers (`waitOut`, `until:` closures, a `pump` inside `click`) where a body scan cannot see them. Only the click is visible everywhere. *Cost if wrong:* the representative list is longer than tripwire 33's.
- **M-DROP — dropped on merit, stated as limits in Task 9:**
  - Detaching `ProjectStore.mintOpenings` (`ProjectStore+Structure.swift:888`). It bites only when duplicating a group of 65 or more pieces, and `Document.load` is main-actor bound.
  - The headless project-stream door reading the registry on the main actor (`ProjectStore+Tasks.swift:57`). It is test and headless only.
  - Plan 1's per-row posture cost (0.36 ms).

## File structure

New:

| file | one responsibility |
|---|---|
| `MaughamTests/TestSupport/TestTemp.swift` | the Mac suites' one temp root: per test, per worker, swept (Task 1) |
| `Packages/MaughamCore/Tests/MaughamCoreTests/TestSupport/TestTemp.swift` | Core's twin (Task 1) |
| `MaughamPhoneTests/TestSupport/TestTemp.swift` | the phone's twin (Task 1) |
| `Maugham/Stores/DocumentStore+ClosedHeldLines.swift` | the closed-document held-line sweep and its map (Task 3) |

Everything else is a modification, named per task.

---

### Task 1: One temp root for every test, a census, and the TestWorkspace leaves (C10 + C17)

**What is wrong (surveyed 2026-09-26):**
- `$TMPDIR` holds 208,937 entries, and the directory's link count is at its cap (65535).
- MaughamTests names `FileManager.default.temporaryDirectory` 322 times and `NSTemporaryDirectory()` 18 times, across 249 files. Core names the former 79 times in 52 files, and the phone 19 times in 15 files.
- `makeTestProject(prefix:initialMd:)` (`MaughamTests/OpLog/OpLogTestProject.swift:14`) never removes what it makes. It has 97 call sites in 34 files, 23 of which contain no `removeItem` at all.
- `BodyPlanTests.tempDir` (:56) leaks 14 directories a run.
- `TempDirectory` (`MaughamTests/TempDirectory.swift:6`) removes what it made, yet 7,756 `MaughamTests-*` directories survive. The likeliest cause is async writes landing after the `removeItem`; this is unverified.
- `TestWorkspace.reset()` (`Packages/MaughamCore/Sources/MaughamCore/TestWorkspace.swift:52–58`) removes the worker leaf and then recreates it empty, and nothing ever removes the leaves. There are 943 `xctest-worker-*` folders under `~/Library/Application Support/Maugham Dev/TestWorkspace`.

**Files:** the three new `TestTemp.swift` files; `TempDirectory.swift`; `OpLogTestProject.swift`; every test file the census names (mechanical); `TestWorkspace.swift`; `DeviceState.swift:67–81` (`sweepDeadWorkerLeaves(in:isAlive:)`, reuse — do not copy); `Maugham/TestHost.swift` (the launch sweep, near :122); `TripwireGrepTests.swift`; `TripwirePhoneGrepTest.swift`.

**Contract:**
- **`TestTemp.root: URL`** is `$TMPDIR/MaughamTests-worker-<pid>/<per-test-uuid>/`, created lazily.
  - An `XCTestObservation`, registered once per bundle, removes the current test's root at `testCaseDidFinish` and removes the whole worker folder at `testBundleDidFinish`.
  - At bundle start it sweeps every `MaughamTests-worker-<pid>` whose pid is dead, using `sweepDeadWorkerLeaves`' pid rule (generalise its prefix — do not copy it).
- **`TestTemp.workerRoot: URL`** is for class-level fixtures (`class func setUp`). It lives until the bundle ends. Review Focus 5 is pinned in both directions: a class fixture survives across tests, and a per-test fixture is gone after its test.
- `TempDirectory` and `makeTestProject` build under `TestTemp.root`. `BodyPlanTests.tempDir` does too.
- **Migrate every site** with a mechanical rewrite. `FileManager.default.temporaryDirectory`, `NSTemporaryDirectory()` and a local `fm.temporaryDirectory` in a test file become `TestTemp.root` (or `workerRoot` where the fixture is class-level). Existing `removeItem`/`defer` cleanups stay; they are harmless.
- **Census** (Mac, over `MaughamTests/` and `Packages/MaughamCore/Tests/`; the phone twin over `MaughamPhoneTests/`):
  - No `temporaryDirectory` and no `NSTemporaryDirectory(` outside the `TestTemp.swift` files.
  - The allow-list is FILE plus SPELLING, and it is an array. Its expected members are tests that assert on a PRODUCTION temp path, such as `TestHostSocketPathTests`. Derive the list; do not trust this plan's example.
  - Each census gets a planted-offender control, including an `fm.temporaryDirectory` alias. The tripwire self-checks' own planted files go under `TestTemp.root` as well.
- **C17:**
  - The test host's launch sweep (beside `TestHost.swift:122`, on its background queue) runs `sweepDeadWorkerLeaves` over `TestWorkspace`'s base as well as `device/`.
  - `TestWorkspace.reset()` stops recreating the leaf empty when the caller will create it itself. Only if a caller needs the leaf to exist does it stay; decide by reading the seven `reset()` callers.
  - Pin it with a dead-pid leaf removed and a live-pid leaf kept (`DeviceIdentityTests.swift:318–368` is the template).
- **Do NOT delete pre-existing `$TMPDIR` entries**, which include other apps' files. Put a one-off command in your report that lists the Maugham test prefixes the survey found (`MaughamTests-`, `LetterKeep`, `inboxtool`, `SpotCheck`, `PP-`, `DesignerEnv`, `APS`, `ALIGN`, `ARCHIVE`, `ALU`, `BodyPlan-`, `MRB-`, …) with `find … -maxdepth 1 -mtime +1`. Derive the prefixes from the migrated call sites. The controller offers it to Denver.

- [ ] Write `TestTemp` (all three targets) and its observer tests first: a per-test root is removed; the worker root survives until bundle end; a dead worker folder is swept and a live one kept. Run: red.
- [ ] Implement. Run: green.
- [ ] Write the census and its planted-offender control. Run: the census fails and lists the sites.
- [ ] Migrate mechanically, in commits of a few directories each, building between commits. Run `./gen.sh` for the new files. Run: the census is green.
- [ ] C17: sweep and `reset()`, with the pin.
- [ ] **Measure**: note the `$TMPDIR` entry count and the `TestWorkspace` folder count before and after one `./scripts/test.sh full`, and report both. The delta should be about zero.
- [ ] Full gate, Core, phone, Release. Commit(s) `test: …`.

---

### Task 2: Tripwire 33's click arm (C14)

**What is there:**
- `TripwireGrepTests.pressThenWaitTests(under:)` (:1976–2009) is a line-state scanner over `func test_` bodies.
  - `isPressCall` is at :2011 and `isWaitCall` at :2020 (`pumpUntil(`, `waitUntil(`, `pump(` — `waitOut(` is missing).
  - The allow-list is `pressThenWaitRepresentatives` (:1961–1972, 10 entries). The test is at :2025 and its control at :2048.
- **25 test functions synthesise a mouse click.** Most wait inside a helper. The helper definitions that build `.leftMouseDown` are:
  - `TreeTravelTests:823`, `ProjectAltitudeCentreTests:845`, `PaletteWallDoorHitAreaTests:342`, `PaletteWallDoorTests:687`
  - `SectionChevronTests:483`, `ReviewBoardPaneTests:1108`, `ReviewBoardRoutingTests:1026`, `ProjectSubjectReachabilityTests:571`
  - `SceneNavigatorProjectRowTests:540/717`
  - `Canvas/CanvasViewMountingTests:429/946/1056`, `CanvasViewMountingRegionTests:995`, `CanvasViewMountingEditingTests:1123`, `CanvasEventViewTests:358`

**Contract:**
- **Add `waitOut(` to `isWaitCall`.** It is the same defect shape. Re-derive the press arm's list after the change; any new hit is decided like a click below.
- **The click arm.** A test function is a CLICK test if its body does either of these:
  - calls a function defined IN THE SAME FILE whose body builds a `.leftMouseDown`/`.leftMouseUp` `NSEvent` or calls `mouseDown(with:)`;
  - builds or sends such an event itself.

  The helpers are derived per file by the scanner, never listed. Every click test is a named member of `clickRepresentatives: Set<String>` (`"File.swift test_name"`). The test asserts both `found − list` and `list − found` are empty, as the press arm does.
- **The sweep.** Decide each of the 25 on tripwire 33's own rule:
  - A click test stays only where it guards an invariant no windowless test can: a hit area, the real delivery path, or a cold click. That is one representative per wiring per file, with the reason in a comment beside its list entry.
  - Every other click test is DELETED where its decision is already pinned windowlessly. Name the windowless test that pins it in your report.
  - Where no windowless pin exists, write one first, then delete (memory: *a flaky test is worse than none*).
  - The handoff names `TreeTravelTests`, `ProjectAltitudeCentreTests` and `PaletteWallDoorHitAreaTests`. The hit-area sweep in the last of these (`liveBand`) is the clearest keep.
- The control plants a click via an in-file helper, a direct `mouseDown(with:)`, and a helper in ANOTHER file of the same name. An in-file helper is required, so the last must NOT be counted. Say so in the control.
- CLAUDE.md's tripwire 33 row and the flake-triage note need a sentence. Put the text in your report; the controller edits CLAUDE.md.

- [ ] Control first (red), then the arm, then the sweep, one commit per file swept. Mac gate. Commit(s) `test: …`.

---

### Task 3: The admission sheet counts closed documents' held lines (C4)

**What is there:**
- `DocumentStore.heldLines() -> HeldLineUnion` (`DocumentStore+Registry.swift:1397`) unions the open documents' `provenance` with `inboxStore.pendingByDevice`/`pendingStreamsByDevice`. It reads no disk. `heldLinesByDevice()` is at :1379 and `HeldLineUnion` at :1540 (`counts`, `streams`, `startedAPiece`, `waiting`, `captures`).
- **Callers:** `AdmissionModifier.swift:183, 188, 262`; `NewPieceModifier.swift:117`; `ProjectSettingsSheet.swift:514`. The doc comment at `AdmissionModifier.swift:145–156` states the open-only limit.
- **In Core, the per-file counts exist and are thrown away:**
  - `nonisolated static func classify(url:bytes:state:trust:permit:) -> FileClassification` (`OpLogStore.swift:2060`, internal) carries `provenance: FileProvenance`.
  - `loadSyncMerged(forDocId:in:identities:state:trust:statements:amendmentPermits:)` (:2996) keeps only `.ops`.
  - The closest template is `heldLines(in:heldBy:presenter:state:trust:permit:)` (:635, internal), used off-main by `heldLines(forDocId:heldBy:)` (:609).
  - A real load's permit context comes from `permitContext(forDocId:in:trust:statements:amendments:)` (`OpLogPermitContext.swift:577`).
- **The precedent for one off-main trust table and then per-piece work:** `ProjectStore.recountFromOpLogs(_:)` (`ProjectStore.swift:626`), called from `invalidateTrust` (`DocumentStore.swift:1629`).

**Contract:**
- **Core:** add `public nonisolated static func provenance(forDocId: String, in projectURL: URL, trust: TrustTable, state: OpLogDeviceState?) throws -> OpLogProvenance`.
  - It is the same per-file classify a load does, with the SAME permit context, summed the same way `loadDiagnosed` sums it (`OpLogStore.swift:528`).
  - It is pinned against `loadDiagnosed`'s provenance for one fixture holding a stranger's span, a permit-held line and an unsigned tail. The two must agree field by field, in both directions: equal counts, and a line held by only one path fails.
- **Mac:** `DocumentStore+ClosedHeldLines.swift` holds a `closedProvenance: [docId: OpLogProvenance]`, filled by a detached sweep.
  - It runs once at project open, after the silent admission (`DocumentStore.swift:323`), and again after every `invalidateTrust`.
  - The sweep is one trust table resolved off-main, then one closed document at a time, never on the main actor. It skips documents that are open.
  - When it lands, it posts `MaughamEvent.postAdmissionRequested(projectURL:)` only if the union's counts changed (C4-1).
- **`heldLines()`** unions, per docId, the open provenance if the document is open, else the closed map's. It adds the inbox. It still reads no disk.
- **Close:** a closing document's last `provenance` moves into `closedProvenance` (Review Focus 2).
- **Sync into a closed document:** the presenter's `.opLog(docId)` arm (`DocumentStore.swift:1681`) re-classifies that one document when it is closed. Debounce it with the existing presenter debounce, not a new timer.
- Update `AdmissionModifier`'s doc comment. People & Devices (`ProjectSettingsSheet.swift:514`) now sees the same union, so check its pending rows still read correctly.
- **Pins:**
  - A stranger's lines only in a closed document produce a sheet with the right count, and a second recompute does not ask twice (Review Focus 1).
  - Close after the sweep keeps the count.
  - A revocation's `invalidateTrust` re-sweeps, so a refused span stops counting as pending.
  - An un-narrowed book with no strangers sweeps and posts nothing.
  - EXPERIMENT: remove the closed map from `heldLines()` and watch the first pin fail.

- [ ] Core pin first (red), then Core. Then the Mac pins (red), then the sweep. Full gate, Core, phone, Release. Commit(s) `feat(oplog): …`.

---

### Task 4: The `.md` follows a re-read, and the starter yield lifts on the same re-read (C12 + Ruling U)

**What is there:**
- **`Document.handleExternalLogChange()`** (`Document+ExternalChange.swift:50`):
  - The echo guard is at :150 and `externalChangesApplied += 1` at :157.
  - It re-derives at :179–183 and ends with `recomputeDisplayText()` at :276.
  - It never schedules an autosave. `handleExternalDiskChange` does, at :46–47.
- **Trust changes** reach open documents only through `DocumentStore.reReadAfterExternalChange(_:)` (`DocumentStore.swift:930`). It is called from `admit` (:1608–1615), `registryChanged` (:1371–1379), `settle(after:_:)` (`DocumentStore+Registry.swift:715–725`), and the presenter's `.opLog(docId)` arm (:1681).
- **The load** writes a "diverged" conflict backup when the `.md` differs from the render (`Document+Load.swift:613–631`), and does not rewrite the `.md`.
- **Ruling H's re-stamp:**
  - `Document.restampWhereItsStarterArmMayHaveClosed()` (`Document.swift:203`) opens with `guard localWritePermit.writesAsItsStarter else { return }`.
  - It is driven by `withPostureFollowingReStamp(of:_:)` (`DocumentStore+Posture.swift:443`), which runs only when `externalChangesApplied` moved, and then `postureFollowsReStamp(of:from:)` (:460). That clears the cached permit and bumps the epoch when the stamp changed.
  - `unsettledStarter` is set in `OpLogStore.localWritePermit` (`OpLogStore.swift:287–356`) when, among other conditions, `unownedPiece(...) == .nobodyHasWrittenItsText`.
  - The yield is applied in `assemble(_:forDocId:as:)` (`DocumentStore+Posture.swift:196`).

**Contract:**
- **C12, open document (C12-1).** After `handleExternalLogChange` applies a change past its echo guard, it schedules the autosave through `autosaveScheduler.schedule(())`, the same debounce as a keystroke. It never calls `performAutosave` directly.
  - Nothing new is guarded: `performAutosave`'s own guards decide.
  - Pin: after an admission re-derives an open document, the on-disk `.md` holds the admitted text within the debounce.
  - Pin the converse: a re-read the echo guard absorbs writes nothing (compare the `.md`'s mtime).
  - Review Focus 3: a reviewer's Mac and a narrowed author's Mac each re-render without an error, a refusal or a new op. Assert the op-log line count is unchanged.
- **C12, closed document.** When the load finds the `.md` diverged from the render, it keeps the backup and also schedules the autosave.
  - Pin: a trust change on a closed piece, then open, gives a `.md` that equals the render after the debounce.
  - Pin that a load with an equal `.md` schedules nothing.
- **Ruling U.** Widen the guard at `Document.swift:204` to `writesAsItsStarter || unsettledStarter != nil`, and nothing else.
  - Real-disk pin (Review Focus 4): a root's Mac holds an unsettled piece and yields. Another book author's text for that piece arrives as a file, and `reReadAfterExternalChange` runs. The posture no longer yields, and `epoch` moved.
  - The converse: an unrelated external re-read on a yielding document keeps the yield.
  - EXPERIMENT: restore the old guard and watch the first pin fail.
  - The cost is one `unownedPiece` walk per applied re-read, on stamped documents only. Say so in the ADR limit rather than hide it.

- [ ] Pins first (red). Implement. Full gate, Core, phone, Release. Commit(s) `fix(oplog): …`.

---

### Task 5: Restore and reopen — the sentence, the preview, the walk

**Files and facts:**
- **`Permit.refused(_:_:)`** (`Permit.swift:902`) maps `.ownAnnotation` to `.other` (:924–925). The translator and maugham arms of `allows` (:598–613) reach it for `.annotationReopen`. `RefusedWhat.disposition` (:427) already documents "reopen".
- **`Document.requireRestoreHonoured(_:)`** (`Document+Annotations.swift:1418`) throws `PostureRefusal` whenever the note is still withdrawn after her reopen.
  - `AnnotationDeriver.withdrawalStates` (`AnnotationDeriver.swift:319`) orders by `opId` (:332).
  - So when another Mac's withdraw has a later ULID than her fresh reopen (clock skew), she is told "not permitted".
- **`restoreStanding(annotationId:)`** (`Document+Annotations.swift:1452`) walks `_opLogMirror` twice. `AnnotationsPane.swift:1219–1222` calls it per Deleted row per redraw.
- **`RewindWindow`** (`Maugham/Views/RewindWindow.swift:38`) keeps `amendments = .honourEverything` for a closed piece (`load()` :326–342). `RewindImpact.preview` (`RewindImpact.swift:46`) then honours what the load would not.

**Contract:**
- **`refused`** files `.op(.annotationReopen)` as `.disposition`. Pin it for the translator and maugham actors, and pin that edit and withdraw stay `.other`.
- **The skew case has its own sentence.**
  - When the note is still withdrawn after her reopen AND the latest withdraw sorts after `reopen.opId`, the door refuses with a reason that says another device deleted it again. Wording: *"Another device deleted this note after you restored it. Restore it again to keep it."* It is added beside `PostureRefusal`, not a new error type if one fits.
  - The ordinary refusal keeps its sentence. Pin both directions.
  - Do NOT re-mint the reopen's opId to sort later: an opId is its writer's clock, and faking it is a second opinion about order.
- **`restoreStanding`** is memoised per derive: a dictionary cleared wherever `_opLogMirror` or `annotationAmendments` changes. Derive those sites with a grep. Pin: two calls walk once (a test counter, as with `starterRestampsForTesting`), and an append invalidates.
- **`RewindWindow`'s closed branch** builds the same table a load builds (`Document+Load.swift:679–687`: `prepareTrust()`, then `opStore.annotationAmendments(from:documentClass:)`). Pin: a closed piece holding a reviewer's refused disposition previews the same as the open piece.

- [ ] Red per line, a disable experiment each, implement. Mac gate. Commit(s).

---

### Task 6: The posture door — one manifest decode, an honest cache, a pruned book, a true header

**Files and facts:**
- **`OpLogStore.localWritePermit`** (`OpLogStore.swift:287`) decodes the manifest twice in a narrowed book: `documentClass()` → `manifestStatements` (`OpLogPermitContext.swift:385/394`), then `startedBy(ofPiece:in:)` (:432). `Document+Load.swift:382` passes no `startedBy`, and `:686` decodes a third time. So do `PostureDoor.posture(as:…)` (:44), `postureYieldingToItsStarter` (:61) and `Document.restampWhereItsStarterArmMayHaveClosed` (`Document.swift:208`).
- **`postureDocId(forPath:)`** (`DocumentStore+Posture.swift:678`) caches the `?? path` fallback in `docIdOfUnknownPath` (:42, :689–692). It is cleared only in `bumpPostureEpoch(clearing:)` (:474–480).
- **`PostureBook.asked`** (:55) is never pruned. Every refresh re-warms every key in it (:503).
- **`PostureDoor.swift`'s header** (:3–19) says "two convenience entries" and "decides nothing about" the yield.

**Contract:**
- **One decode per ask.** Add one Core helper that decodes the manifest once and answers both the document class and the starter. Pass it through at every call site above: derive them with a grep for `localWritePermit(` and `documentClass(forDocId:`.
  - Pin with a decode counter: one decode per `localWritePermit` in a narrowed book, and zero extra in an un-narrowed book.
  - Pin that the answers are unchanged across the four existing Option A fixtures.
- **The unknown-path cache** stores only a docId that `resolveDocId` actually resolved, never the fallback. Pin: a file created after a miss resolves to its real id on the next ask.
- **`asked`** drops keys whose docId is neither in the manifest nor open, on `postureManifestAdopted`. Pin: a deleted piece's key is gone after adoption, and a live key stays.
- **The header** is rewritten to the three convenience entries plus `posture(permit:yieldingTo:)`, and says the starter yield is decided here from `unsettledStarter` while the root's owner yield stays the Mac's. The comment edit rides in the same commit.

- [ ] Red, implement, Mac gate, Core, phone. Commit(s).

---

### Task 7: The phone — posture before the write, one warm-up in flight, the census gap, the warning

**Files and facts:**
- **`AnnotationDetailView.runWrite`** (`MaughamPhone/Annotations/AnnotationDetailView.swift:580–604`) assigns `posture = outcome.posture` (:593) only when the write returns. `PhonePosture.perform` (`PhonePosture.swift:127–140`) asks again before the write, so a write that throws leaves the view drawing the old answer.
- **`PhonePosture.askAgain`** (:116) and **`warmStore`** (:153) both run a signature scan on the main actor. `OpLogStore.trust()` repeats it (`OpLogStore.swift:166`). Two concurrent asks both prepare.
- **`TripwirePhoneGrepTest.writeOnlyOffenders(in:)`** (:996) checks `storeReads` (:988–991) only in `AnnotationWriter.swift`/`InboxCaptureWriter.swift` (:985). A third file calling `.load(` on a writer's store escapes.
- **`PhoneDeviceRecord.ensure`** has the main-actor default argument `name: String = UIDevice.current.name` (`MaughamPhone/Storage/PhoneDeviceRecord.swift:74`).

**Contract:**
- **`perform`** hands back the fresh posture even when the write throws: return it alongside the error, or take an `onAnswer` closure called before the write. The view assigns it before handling the error. Pin with a throwing write: the verb the fresh answer refuses is no longer drawn.
- **One warm-up in flight per project URL.** Concurrent `askAgain` calls await the same `Task`. Drop the phone-side signature scan and let `prepareTrust` compare; verify first that `prepareTrust` short-circuits on an unchanged signature, and report it. Pin: two concurrent asks prepare once.
- **The census** closes the gap by banning any access to the two writers' store PROPERTY outside their own files (find its name), with a planted offender in a third file. The existing control still lets `DeviceIdentity.load(` through.
- **`name: String? = nil`**, resolved inside the body. Confirm the warning is gone in a clean phone build: `touch` the file first (CLAUDE.md, warning census).

- [ ] Red, implement, phone gate, Core. Commit(s) `fix(phone): …`.

---

### Task 8: People & Devices says what unblocks a stranded piece

**What is there:**
- A piece whose recorded starter (`StructureItem.startedBy`, `StructureItem.swift:61`) is a Mac that vanished without being revoked waits on every other Mac for ever. `TrustTable.starterStanding` (`TrustTable.swift:915`) reads it as `.standing`.
- The only remedy, revoking that Mac, is stated in the ADR and the guide but nowhere on screen.
- `PeopleAndDevicesModel.make(registry:table:…pieces:…)` (`PeopleAndDevicesModel.swift:688`) takes `[PermitControl.Piece]` (`PermitControl.swift:32`: `id`, `title` only). It is loaded detached from `ProjectSettingsSheet.swift:544/569`.
- The `Device` row is at `PeopleAndDevicesModel.swift:184`, `absentRow` at `PeopleAndDevicesSection.swift:550`.

**Contract:**
- `PermitControl.Piece` gains `startedBy: String?`, filled from the manifest.
- The model groups the pieces that are **waiting** by starter. A piece is waiting when the book is narrowed, its starter's standing is `.standing` or `.unknown`, and this Mac is not that starter. Presence of the piece's opening is decided by `OpLogStore.unownedPiece` or by op-log file presence; choose one, say why, and keep it off the main actor. This is inside the existing detached `make`.
- **The Device (or absent) row** of such a starter carries one line: *"N pieces are waiting for this Mac. If it is gone for good, revoke it and they will open."* It is drawn only on the root's Mac (the revoker), and only when N > 0.
- A piece whose starter is `.gone` draws nothing (it already opens). An un-narrowed book draws nothing.
- Pins on the model, windowless: each direction above, plus a starter that is this Mac.

- [ ] Red, implement, Mac gate. Commit `feat(views): …`.

---

### Task 9: Docs, the limits, and the full gate

**Files:**
- **ADR 0032:** a P3 plan-3 addendum.
  - What Tasks 1–8 changed.
  - **Limits:**
    - OB-1: an old build over an un-narrowed book. I4: an old Mac with the book open at narrowing keeps writing until its session ends. And an old build rewriting the manifest drops `startedBy`. Both are a transient of a mixed fleet, answered by the paired release.
    - The M-DROP items.
    - Task 4's `unownedPiece` walk per re-read.
    - C12-1's extra `.md` writes.
  - Strike the limits Tasks 3, 4 and 8 closed.
- **AREA files:** `Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `MaughamPhone/AREA.md`, `Maugham/Stores/AREA.md` (the closed-document sweep).
- **Guides:** `docs/guide/people-and-devices.md` (the stranded-piece line).
- **The P3 handoff:** a *P3 plan 3 OUTCOME* section, and OB-1 recorded as Denver's ruling.
- **The smoke script** as a note, `docs/superpowers/notes/2026-09-26-p3-closing-smoke.md`: the checklist in Task 10, with the rig commands.
- **Release notes draft** (with P3a's, P3b's and plans 1–2's, from the handoff's release-note sections):
  - *A book made on this build starts at schema 9; the first narrowing raises an existing one.*
  - The mixed-fleet sentence (OB-1).
  - The `.md` now follows sync and permission changes.
- **CLAUDE.md edits** from Tasks 1, 2 and 3 (tripwire 33's click arm; the `TestTemp` rule in the build-flow section, replacing the leak bullet's "a census of them is open"; the Stores cell). These go in the report as text, and the controller applies them.

- [ ] Implement. Check `df`. **Full gate**, Core, phone, and a Release build. Commit `docs(oplog): P3 plan 3 — …`.

---

### Task 10: The closing smoke and the paired release (controller, with Denver — not a subagent)

**The smoke**, on the four-Mac rig (`scripts/second-mac.sh [--reset] [--name third|fourth]`) plus the second Apple ID. Record the finds in `docs/superpowers/notes/2026-09-26-p3-closing-smoke.md` as they happen.
- **Option A end to end:**
  - She starts a piece on Mac 1. Her Mac 2 waits, then applies.
  - The root waits, then asks. *Theirs*. A Duplicate of a group.
  - **Ruling U:** the root presses *Not now*, opens the piece, and sees *Sam started this piece — it isn't settled whose it is yet.* Then Edit Anyway, and type: her words are set aside on both Macs.
  - **Task 4:** another book author's text arriving lifts the yield with no reopen.
- **A co-author** writes anywhere. **An author of some pieces** is refused outside hers.
- **A reviewer:**
  - Restore of her own deleted note, on the Mac and seen on the phone. Restore of somebody else's is not offered.
  - A demotion while she is typing.
- **The phone:** a reviewer's phone offers no dispositions and still captures. Settings' role line changes after *Change…* on the Mac.
- **Both Send to Inbox doors.**
- **A truncated file** and its Acknowledge.
- **A later narrowing** on a book with an enclave-less Mac (Ruling Q).
- **Task 3:** a stranger's lines only in a closed document; the root opens the book and the sheet counts them.
- **Task 4:** after the admission, the derived `.md` on disk holds the admitted text.
- **Task 8:** a stranded piece's line in People & Devices, then revoke, then the piece opens.
- **WF1:** participant-side iCloud review on the second Apple ID. It has been unverified since WF1.
- **`scripts/census-load-bursts.sh`**, run from this Mac against each Mac's folders.
- Every find gets a regression pin and a fix on a branch, and the re-smoke passes, before release.

**The release** — follow `docs/RELEASING.md`:
1. Merge the branch to main after the whole-branch review (fable, all ledgers, told to assume a Critical, with the seam list below).
2. Stash the three untracked agent-config entries (`git stash -u`), or the cut refuses a dirty tree.
3. Cut the Mac release and the phone release (schema 9, paired). Push main, then each tag **by name**. Never `--tags`.
4. Watch both release runs. Record the release in memory and the handoff.

---

## Order

Sequential: Task 1 first, because every later task's new tests use `TestTemp`. Then Tasks 2, 3, 4, 5, 6, 7, 8, then Task 9, the whole-branch review and its fix wave, and then Task 10. Run the full gate after Tasks 1, 3, 4 and 9.

## Whole-branch review — seams to name to the reviewer

Give the reviewer all four P3 ledgers, this plan's ledger, the plan-2 handoff sections, and this list. Tell it to assume there is a Critical.

- **T3×T4:** an admission's `invalidateTrust` now re-sweeps closed documents AND re-renders open ones. Do the sweep and the re-read race, and does a document that opens mid-sweep get counted twice or not at all?
- **T4 × Option A:** the `.md` re-render on a Mac that may not mint a piece's opening (`waitingForPiece`). Does a scheduled autosave on such a document write an EMPTY `.md` over the real one? Check `rendersToDisk` and the load's refusal path.
- **T4 × echo guard:** the re-render's own `.md` write fires the presenter's `.otherProjectFile` → `handleExternalDiskChange`. Is it absorbed, or does it loop?
- **T1 × everything:** a migrated test whose fixture outlives its test (a class fixture, a detached Task writing after teardown). Does the per-test removal turn a green test red or flaky?
- **T2:** a click test cut whose decision had no windowless pin.
- **T5 × ruling P / RP-1:** the skew sentence must never be shown for somebody else's note.
- **T6 × Option A:** the single-decode helper answers `startedBy` from the same manifest bytes as the class. A stale live manifest versus the disk manifest (`permitFromTheBuilder`, `DocumentStore+Posture.swift:405–429`).

**The premise check:** grep the diff for *unreachable / never / always / cannot* and test each. Which states does this plan's own code create that a guard calls impossible? A closed document's provenance for a docId the manifest no longer lists. A re-render on a husked document. A `TestTemp.root` asked from `class func setUp`.
