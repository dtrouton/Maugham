# Manuscript Recovery Plan B — quarantine-and-continue, and the return merge

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The writer can set an unreadable history file aside untouched and keep writing; when it becomes readable it merges back by the sync rules with every not-in-draft paragraph surfaced — nothing overwritten, nothing silent.

**Architecture:** `OpLogQuarantine` (MaughamCore) owns the byte-identical move, the sidecar record, and the verified return; `RecoveredHistory` (MaughamCore) is the pure orphan computation, property-tested for totality. The return's live-doc reconciliation rides the EXISTING ADR 0012 presenter machinery (`handleExternalLogChange` fires when the file reappears in `.maugham/ops/`). Surfaces: the recovery pane and banner gain the quarantine action; the History pane carries the standing notice, Retry, and the orphan report. ⌘S's save flash becomes honest as the rung's companion fix.

**Tech Stack:** Swift / SwiftUI, XCTest. No new dependencies.

## Global Constraints

- **Nothing is ever overwritten or destroyed** (spec §5): the quarantine move is byte-identical (hash-pinned); the return NEVER overwrites an existing destination file (ADR 0012 single-writer: if the device's file reappeared via sync, the quarantined copy stays as an archive and the report is computed without a move).
- **The stub path never offers quarantine** (spec §3) — and `OpLogQuarantine.quarantine` itself refuses a dataless stub as a belt.
- **Plan A's surfaces stay pinned**: the writer census, the wiring census, the height census, and the M9-OL floor pins must stay green untouched. A new op-log-writing function in `Maugham/OpLog/Document*.swift` must open with the writability guard or the census goes red.
- **Orphan totality**: every paragraph in the returned file's own derivation is either in the merged sequence or in the orphan report — the union is total (property-pinned).
- **Append to End lands as ordinary ops** — rewindable, undoable, via the OPEN Document only; no direct `opStore.append` of synthetic content (sequence-keyframe integrity).
- **`./gen.sh` after ANY new file**; verify executed-test COUNTS, never exit codes; `tr -d '\000'` before grepping xcodebuild logs; `./scripts/test.sh` to iterate, `full` before merge.
- Writer-facing copy: the quarantine verb is "set aside", the promise is "kept safe, merged back when it returns" — never the word "quarantine" in UI copy (it's a code term; the History notice says "set aside" too).

---

### Task 1: `OpLogQuarantine` — the byte-identical move and its record

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/OpLogQuarantine.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogQuarantineTests.swift`

**Interfaces:**
- Consumes: `OpLogStore.opLogFileURL(forDocId:deviceSlug:in:)` naming conventions; `JSONLAppendStore` date coding for the record.
- Produces (Tasks 3/4/5/6 consume):

```swift
public struct QuarantineRecord: Codable, Equatable, Sendable {
    public let docId: String
    public let originalName: String   // e.g. "doc-x.phone.jsonl"
    public let quarantinedAt: Date
    public let reason: String         // the read error at quarantine time
    public var status: Status
    public enum Status: String, Codable, Sendable {
        case held           // set aside, not yet returnable
        case superseded     // sync delivered the same history; archive kept
        case returned       // moved back into .maugham/ops/
    }
}

@MainActor
public enum OpLogQuarantine {
    public static func quarantine(fileURL: URL, docId: String, reason: String,
                                  in projectURL: URL,
                                  isDatalessStub: (URL) -> Bool = OpLogQuarantine.defaultStubProbe)
        throws -> QuarantineRecord
    public static func records(forDocId: String, in projectURL: URL) -> [QuarantineRecord]
    public static func quarantinedFileURL(for record: QuarantineRecord, in projectURL: URL) -> URL
    // dir: .maugham/conflicts/quarantined-ops/
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// OpLogQuarantineTests.swift (package)
import XCTest
@testable import MaughamCore

final class OpLogQuarantineTests: XCTestCase {
    private var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("olq-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    /// Spec §5: the move is byte-identical — the bytes are never opened, only
    /// relocated — and the record beside it says what and why.
    @MainActor
    func test_quarantine_movesBytesIdentically_andRecordsWhy() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        let bytes = Data("torn \u{0} garbage the reader refused".utf8)  // arbitrary bytes, not JSON
        try bytes.write(to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "permission denied",
            in: tmp, isDatalessStub: { _ in false })

        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "out of the glob")
        let dest = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)
        XCTAssertEqual(try Data(contentsOf: dest), bytes, "byte-identical")
        XCTAssertEqual(record.docId, "doc-1")
        XCTAssertEqual(record.originalName, "doc-1.phone.jsonl")
        XCTAssertEqual(record.reason, "permission denied")
        XCTAssertEqual(record.status, .held)
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 1,
                       "the record round-trips through the ledger")
    }

    /// The stub belt (spec §3): a dataless iCloud stub must never be moved —
    /// moving it fights the download the wait-and-retry rung triggered.
    @MainActor
    func test_quarantine_refusesADatalessStub() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try Data("x".utf8).write(to: src)
        XCTAssertThrowsError(try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "r", in: tmp,
            isDatalessStub: { _ in true }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "nothing moved")
    }

    /// Two quarantines of same-named files (the writer hit this twice across
    /// weeks) must not collide: the stamp separates them, both records held.
    @MainActor
    func test_twoQuarantines_ofTheSameName_bothSurvive() throws {
        for content in ["first", "second"] {
            let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
            try Data(content.utf8).write(to: src)
            _ = try OpLogQuarantine.quarantine(
                fileURL: src, docId: "doc-1", reason: "r", in: tmp,
                isDatalessStub: { _ in false })
        }
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 2)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --package-path Packages/MaughamCore --filter OpLogQuarantineTests` → compile FAILURE.

- [ ] **Step 3: Implement.** Move via `FileManager.moveItem` inside an `NSFileCoordinator` write-for-moving coordination on the source (mirror `sealTailIfNeeded`'s coordinator usage — one coordinator per operation). Destination `.maugham/conflicts/quarantined-ops/<originalName>.<stamp>` with `<originalName>.<stamp>.quarantine.json` beside it (ISO8601 stamp via `ISO8601DateFormatter.quarantineStamp` if visible from MaughamCore — it lives where `IntegrityQuarantine` uses it; reuse, don't duplicate). `defaultStubProbe` mirrors `RecoveryCause.defaultStubProbe` (that one is app-layer; implement the same 5 lines here and note the mirror in a comment — MaughamCore cannot import the app). `records` decodes every `*.quarantine.json`, filters by docId, sorts by `quarantinedAt`. The doc comment cites tripwire 14's spirit: this IS the typed verb for op-log sidecar moves; raw `moveItem` on op-log files stays forbidden elsewhere.

- [ ] **Step 4: Run to verify pass** (package filter, then full package suite).

- [ ] **Step 5: Commit** — `feat(recovery): OpLogQuarantine — the byte-identical set-aside and its record`

---

### Task 2: `RecoveredHistory` — the orphan computation, property-tested

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/RecoveredHistory.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/RecoveredHistoryTests.swift`

**Interfaces:**
- Consumes: `Deriver.deriveWithSequenceFallback(ops:)`, `OpLogStore.mergeSortedDedup` (check its access level — if internal, expose the need through a small public wrapper or compute the union locally by opId; do NOT widen internals casually — prefer a local opId-keyed union that mirrors the documented first-occurrence-wins semantics and cite it).
- Produces (Tasks 3/5 consume):

```swift
public struct RecoveredHistoryReport: Equatable, Sendable {
    public struct Orphan: Equatable, Sendable, Identifiable {
        public var id: String { paragraphId }
        public let paragraphId: String
        public let text: String
    }
    /// Recovered paragraphs NOT in the merged draft's sequence, in the
    /// returned file's own order.
    public let orphans: [Orphan]
    /// True when every returned op already exists in the current log —
    /// sync delivered the history while it was set aside.
    public let redundant: Bool
}

public enum RecoveredHistory {
    public static func report(currentOps: [Op], returnedOps: [Op]) -> RecoveredHistoryReport
}
```

- [ ] **Step 1: Write the failing tests** — three example-based + one property:

```swift
    /// Spec §5 rule 3: a paragraph superseded by the writer's newer keyframes
    /// is an orphan; one that survives the merge is not.
    func test_supersededParagraphIsAnOrphan_survivorIsNot() { /* build ops:
        returned file has paragraphs a,b with sequence [a,b]; current ops have a
        NEWER (higher opId) keyframe with sequence [a] and new text for a.
        Expect: orphans == [b with b's returned text]; redundant == false. */ }

    func test_fullyRedundantReturn_reportsRedundant_noOrphans() { /* returnedOps
        ⊂ currentOps by opId → redundant true, orphans empty */ }

    func test_returnedOnlyOps_mergeIn_lastWriterWinsPerParagraph() { /* returned
        file holds an OLDER edit to paragraph a; current has newer — a is not an
        orphan and the report has no claim about its text (the merge owns it) */ }

    /// THE TOTALITY PROPERTY (global constraint): for randomized op sets,
    /// every paragraph in derive(returnedOps).sequence is EITHER in
    /// derive(merged).sequence OR in the orphan list — never lost, never both.
    func test_property_everyReturnedParagraphIsAccountedFor() {
        var rng = SystemRandomNumberGenerator()  // seed-log the failure case
        for trial in 0..<200 { /* generate 2-30 ops across two device streams
            with random paragraph ids from a small pool, random sequences and
            occasional keyframes; split into current/returned; assert the union
            property + no duplicate between the two sets; on failure print the
            two op arrays so the case is reproducible */ }
    }
```

The implementer writes real op-construction helpers (mirror `OpLogStoreDiagnosedTests.makeOp`'s shape; paragraph ids from the valid 4-char alphabet — tripwire 8 — use `ParagraphID.mint()` or literals from `[0-9a-hjkmnp-tv-z]`).

- [ ] **Step 2: RED** — package filter compile failure.
- [ ] **Step 3: Implement.** Derivation: `merged = union-by-opId(currentOps, returnedOps)` sorted by opId (first-occurrence-wins matches `mergeSortedDedup`'s documented dedup); `mergedState = Deriver.deriveWithSequenceFallback(ops: merged)`; `returnedState = Deriver.deriveWithSequenceFallback(ops: returnedOps)`. Orphans = ids in `returnedState.sequence` minus ids in `mergedState.sequence`, text from `returnedState.paragraphs`, ordered by `returnedState.sequence`. `redundant` = every returned opId ∈ current opId set.
- [ ] **Step 4: GREEN** (filter + full package).
- [ ] **Step 5: Commit** — `feat(recovery): RecoveredHistory — the orphan report, total by property`

---

### Task 3: `OpLogQuarantine.attemptReturn` — verified, never overwriting

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogQuarantine.swift`
- Test: extend `OpLogQuarantineTests.swift`

**Interfaces:**
- Consumes: Task 2's `RecoveredHistory.report`, `JSONLAppendStore<Op>.parse`, `OpLogStore.load(docId:)`.
- Produces (Tasks 5/6 consume):

```swift
public enum ReturnOutcome: Equatable, Sendable {
    /// Moved back into .maugham/ops/; the report describes the merge.
    case returned(RecoveredHistoryReport)
    /// The device's file reappeared via sync; the archive stays, the report
    /// covers whatever the archive held beyond the current log.
    case supersededBySync(RecoveredHistoryReport)
    /// Still can't be read cleanly — stays held. Reason for the notice.
    case stillUnreadable(reason: String)
    /// Readable but a line fails to decode — stays held; salvage is the
    /// integrity path's job, not a merge input (spec §5 step 1).
    case corrupt(reason: String)
}

extension OpLogQuarantine {
    public static func attemptReturn(record: QuarantineRecord, in projectURL: URL,
                                     presenter: NSFilePresenter?) async -> ReturnOutcome
}
```

- [ ] **Step 1: Failing tests** — four:

```swift
    // destination absent: verified read → move back → .returned, file at
    //   .maugham/ops/<originalName>, record.status == .returned on disk,
    //   quarantined copy GONE from quarantined-ops (it moved, not copied).
    func test_return_destinationAbsent_movesBackAndReports() async { … }

    // destination present (sync recreated the device file, quarantined content
    //   a strict subset): NO move, quarantined file still in place,
    //   .supersededBySync(report.redundant == true), record.status == .superseded.
    func test_return_destinationPresent_neverOverwrites_archiveStays() async { … }

    // torn line in the quarantined file: .corrupt, nothing moves, status .held.
    func test_return_tornLine_staysHeld() async { … }

    // unreadable quarantined file (dir squat on the quarantined path): 
    //   .stillUnreadable, nothing moves.
    func test_return_unreadable_staysHeld() async { … }
```

Build the fixtures with real encoded `Op` lines (reuse the encode helper shape from `BackupSignatureTests`).

- [ ] **Step 2: RED.** 
- [ ] **Step 3: Implement.** Order matters: (1) read quarantined bytes strictly (coordinated read; failure → `.stillUnreadable`); (2) `JSONLAppendStore<Op>.parse(bytes:dedupKey:sortedBy:)` — any `diagnostics.skipped` → `.corrupt`; (3) `currentOps = (try? await OpLogStore(projectURL:presenter:).load(docId:)) ?? []` — NOTE: a throwing current-log read (another unreadable file) must abort as `.stillUnreadable("the live history is itself unreadable")`, never proceed on a partial current picture (use do/catch, not `try?` — the ?? [] above is a sketch, write the honest version); (4) `report = RecoveredHistory.report(currentOps:returnedOps:)`; (5) destination = `.maugham/ops/<originalName>`: absent → coordinated move back, rewrite record `.returned`; present → leave archive, rewrite record `.superseded`, outcome `.supersededBySync(report)`. Record rewrite = rewrite the `.quarantine.json` atomically.
- [ ] **Step 4: GREEN** (filter + full package suite).
- [ ] **Step 5: Commit** — `feat(recovery): the return — verified, merged by the sync rules, never overwriting`

---

### Task 4: the quarantine actions reach the pane and the banner

**Files:**
- Modify: `Maugham/Views/DocumentRecoveryPane.swift` (model gains the offer + action), `Maugham/Views/RecoveryBanner.swift` (the typing-offer swap), `Maugham/Views/EditorHost.swift` (`quarantineAndContinue()`), `Maugham/Editor/EditorSurface.swift` (Control-chord polish, see below)
- Test: extend `RecoveryPaneModelTests`, `RecoveryBannerTests`, `EditorSurfaceReadOnlyTests`; extend the wiring census in `ReadOnlyRecoveryTests`

**Interfaces:**
- Consumes: Task 1's `OpLogQuarantine.quarantine`; Plan A's `RecoveryCause`, `retryFullLoad()`, `recoveryActionIsCurrent`.
- Produces: `RecoveryPaneModel.offersSetAside: Bool` + `onSetAside: () -> Void` (init param, identity-guarded like the other two); `RecoveryBannerModel.setAsideOffered: Bool` (true once typing was refused) + the banner's button wired to an `onSetAside` closure; `EditorHost.quarantineAndContinue()`.

- [ ] **Step 1: Failing tests.**
  - Pane: `.unreadableFile` cause → `offersSetAside == true`; `.icloudNotDownloaded` and `.unlistableOpsDirectory` → false (the stub rule and the nothing-enumerable rule).
  - Banner: `noteTypingRefused()` flips `setAsideOffered` (replacing the bare emphasis assertion — emphasis stays); copy census: the banner's offer string contains "set" + "aside" + "kept safe" and NOT "quarantine".
  - EditorSurface: extend the discriminator matrix — a ⌃-chord (control modifier, plain character) is NOT an insertion event (falls through to super for emacs-style navigation).
  - Wiring census additions: `OpLogQuarantine.quarantine(` present in EditorHost; `quarantineAndContinue` consulted by BOTH the pane's and the banner's action; `recoveryActionIsCurrent` count moves 2 → 3 (the new pane action is guarded like its siblings; the banner action is per-render like Reopen — decide and pin whichever shape you implement, with a comment saying why).
- [ ] **Step 2: RED** (counts verified).
- [ ] **Step 3: Implement.** `quarantineAndContinue()` in EditorHost: resolve every file to set aside — from the pane path: the cause's single fileURL; from the banner path: every `readOnlyRecovery.unreadableFiles` name resolved against `.maugham/ops/` — quarantine each via `OpLogQuarantine.quarantine` (reason = the cause's reason or the per-file recorded reason), then `await retryFullLoad()`. On a quarantine throw: `loadError` + `MaughamEvent.postNotice` (the `openReadOnly` catch shape). Banner copy when `setAsideOffered`: "Keep writing anyway — set the unreadable history aside (kept safe, merged back when it returns)" with the button "Set Aside and Keep Writing". Pane button: "Set the File Aside and Keep Writing". Control-chord: add `.control` to the modifier exclusion in `isTextInsertionEvent`.
- [ ] **Step 4: GREEN** — the four extended suites + `DocumentLoadQuarantineTests` + `EditorHostRecoveryActionGuardTests` + Release build (body-adjacent changes).
- [ ] **Step 5: Commit** — `feat(recovery): set-aside reaches the pane and the banner — the writer keeps writing`

---

### Task 5: the History pane's standing notice, Retry, and the orphan report

**Files:**
- Modify: `Maugham/Views/HistoryPane.swift`
- Create: `Maugham/Views/RecoveredHistorySheet.swift` (the View list + Append to End)
- Test: extend `MaughamTests/OpLog/CheckpointStoreTests`-adjacent HistoryPane statics OR a new `MaughamTests/RecoveredHistorySheetTests.swift` (implementer picks; new file → `./gen.sh`)

**Interfaces:**
- Consumes: `OpLogQuarantine.records/attemptReturn`, `ReturnOutcome`, `RecoveredHistoryReport`; HistoryPane's existing notice pattern (the checkpoint notice at ~line 209) and its `documentStore`/`activeDocId` context.
- Produces: the standing notice ("Part of this document's history is set aside (couldn't be read when it was). Retry"), the post-return notice ("N paragraphs from the recovered history aren't in your draft — View"), `RecoveredHistorySheet` (read-only copyable list + per-orphan and Append-All "Append to End").

- [ ] **Step 1: Failing tests** — static-copy pins (the `unreadableCheckpointNotice` pattern): notice text for held records names "set aside" and carries Retry; report notice for N orphans; zero-orphan outcome text "Recovered history merged — nothing was missing"; sheet append logic: appending an orphan calls `insertParagraph(after: <last sequence id>, text:)` on the OPEN document and is disabled with honest copy when the doc isn't open.
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement.** `reload()` also loads `OpLogQuarantine.records(forDocId: activeDocId, in: projectURL)` filtered `.held`; the notice sits under the checkpoint notice (same Label style, `arrow.uturn.backward.circle` icon). Retry → `attemptReturn` for each held record → outcome notices via `MaughamEvent.postNotice` + local state for the report → sheet presents `RecoveredHistorySheet(report:document:)`. Append to End: through `documentStore.document(forDocId: activeDocId)` — the OPEN doc only (the register's Append constraint); when nil, the button explains ("Open the document to append"). After append, the orphan row shows appended-state (disable + checkmark).
- [ ] **Step 4: GREEN** — new/extended suites + full HistoryPane neighbours (`HistoryPaneRewindTargetTests`).
- [ ] **Step 5: Commit** — `feat(recovery): the set-aside history is visible, retryable, and its orphans land as ordinary ops`

---

### Task 6: the return runs itself at document open

**Files:**
- Modify: `Maugham/Views/EditorHost.swift` (post-bind hook), `Maugham/OpLog/OpLogQuarantine.swift` only if a convenience is needed
- Test: extend `ReadOnlyRecoveryTests` (census) + a logic-level test if extractable

**Interfaces:** consumes Tasks 1/3; produces the auto-return: after a successful NORMAL bind (`loadDocumentIfNeeded` success path, after `deliverPendingRecoveryNoticeIfPossible()`), if `OpLogQuarantine.records(forDocId:).contains(.held)` → fire-and-forget Task: `attemptReturn` each; on `.returned`/`.supersededBySync` post the outcome notice (orphan count or nothing-was-missing) — the presenter machinery reconciles the open doc when the file lands (`handleExternalLogChange`); on `.stillUnreadable`/`.corrupt` post NOTHING (silence is right here: the writer did not ask, and the standing History notice already shows held records).

- [ ] Steps: census RED (the hook's presence + its placement AFTER the pending-notice delivery), implement (guard: never on a recovery bind — `!doc.isReadOnlyRecovery`), GREEN (ReadOnlyRecoveryTests + DocumentLoadQuarantineTests + EditorIntegrationHarnessTests), commit — `feat(recovery): a held history tries itself on every open`

---

### Task 7: ⌘S tells the truth

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` (both `CheckpointCapture.run` sites, ~239 and ~2838)
- Test: `MaughamTests/SaveFlashHonestyTests.swift` (new — `./gen.sh`) or extend the checkpoint-capture census suite (`CheckpointSubjectRecordTests` neighbours); implementer picks the cheapest honest pin

**Interfaces:** none new. Both sites currently `_ = try? await CheckpointCapture.run(...)` then flash unconditionally — the whole-branch review's finding: in a read-only recovery state ⌘S writes nothing and the flash lies.

- [ ] Steps: RED (pin: a throwing capture → no flash + a notice naming why; a succeeding capture → flash, no notice), implement (do/catch replacing `try?`; on catch → `MaughamEvent.postNotice("Couldn't save a checkpoint — \(error.localizedDescription)")`, no flash; keep both sites textually parallel — they are the same two-site family the breadcrumb census already counts), GREEN + Release build (`ProjectWindow.body`-adjacent → the Release type-check rule applies), commit — `fix(publish/checkpoints): the save flash fires only when a checkpoint landed`

---

### Task 8: docs, register, full gate

**Files:**
- Modify: `docs/guide/getting-started.md` (the troubleshooting section grows rung 3, writer-voiced, "set aside" language), `Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `docs/roadmap.md` (recovery entry: rung 3 built; the milestone's remaining residuals restated), `register/START-HERE.md` narrative
- Modify: `register/reconciliation/OpLog.claims.json` + `.filings.json` — M9-OL-015 (the set-aside act: byte-identical, recorded, stub-refused, editable reopen), M9-OL-016 (the return: verified read, never overwrites, orphan totality by property, append-as-ordinary-ops), M9-OL-017 (⌘S honest flash — cite RULING-52's family: an operation that changed nothing says so). All COMPLIES, born with the milestone, house shape.
- Then: `flip-claim.py recompute --module OpLog` (expect 17/17) + `27-generate-state.py` + `23-generate-rulings.py` + PENDING grep = 0. Full gate `./scripts/test.sh full` with the flake ledger's discriminators.

- [ ] Steps: claims/filings → docs sweep → regenerate → full gate → commit — `docs+register(recovery): Plan B ships — the ladder is whole`

---

## After the plan

Whole-branch review (seams: the never-overwrite guarantee end-to-end; the auto-return racing the presenter reconciliation on an open doc; quarantine composing with Plan A's watchers; append-path undo behaviour; copy sweep for the word "quarantine" in UI strings). No-ff merge, push, notify the peer (EditorHost + ProjectWindow are shared). Suggested smoke for Denver: break a file → Set Aside → keep typing → restore the file's readability → History pane Retry → orphan report → Append to End → ⌘Z takes back exactly the append.
