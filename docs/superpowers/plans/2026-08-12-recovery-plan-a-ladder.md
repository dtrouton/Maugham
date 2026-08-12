# Manuscript Recovery Plan A — the ladder pane, wait-and-retry, read-only partial open

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A refused document offers a ladder instead of a dead end — cause-classified copy, iCloud wait-and-retry with auto-reopen, a clearly-labelled read-only partial view that can write nothing, and a Restore-from-Backup pointer.

**Architecture:** The RULING-54 refusal (`EditorHost.loadError`) stays the floor; a new `DocumentRecoveryPane` renders above it, driven by a `RecoveryCause` classifier and a testable `RecoveryPaneModel`. The read-only rung is a recovery mode on `Document.load` itself — mutation entry points widen the existing `rejectMutationIfClosed` choke point, and no autosave scheduler is created. The partial doc is NEVER registered in `DocumentStore`'s registry (that registry is how MCP resolves open docs — spec §4).

**Tech Stack:** Swift / SwiftUI / AppKit, XCTest. No new dependencies.

## Global Constraints

- **Nothing derived from a partial view is ever written over durable state** (spec §1). The read-only doc appends zero ops, writes no `.md`, touches no pending file, seals nothing, checkpoints nothing — including across `close()`.
- **The refusal semantics do not change** — M9-OL-001/002/003's pins must stay green untouched.
- **MCP stays strict** (spec §6): the partial doc is invisible to `DocumentStore`'s registry.
- **The stub path never offers quarantine or read-only** — it waits, downloads, and auto-opens editable (spec §3). Quarantine itself is Plan B; nothing in Plan A may reference it in writer-facing copy.
- **Read-only banner copy**: the return is an OFFER ("Full history is back — Reopen"), never an automatic reload (spec §4). Auto-reopen happens only from the recovery pane.
- **`./gen.sh` after ANY new file**, then verify via test COUNT, never exit code alone (a `-only-testing` run on a class the generated project doesn't know reports TEST SUCCEEDED with zero tests executed).
- Run `./scripts/test.sh` for iteration, `./scripts/test.sh full` before merge. New view files that style text through production typography need `FontWarmup.ensure()` in `setUp` if they mount.
- Two-clone convention: `EditorHost`/`ProjectWindow` are shared surfaces — notify the peer session after any push.

---

### Task 1: `OpLogStore.loadDiagnosedPartial` — the partial read the read-only rung stands on

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift` (beside `loadDiagnosed`)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogStoreDiagnosedTests.swift`

**Interfaces:**
- Consumes: `OpLogStore.loadFileDiagnosed(url:presenter:)` (existing per-file loader), `CheckpointLoad.UnreadableFile` (existing name+reason pair — reuse, don't mint a third).
- Produces: `PartialOpLogLoad { ops: [Op], diagnostics: ParseDiagnostics, unreadableFiles: [CheckpointLoad.UnreadableFile] }` and `func loadDiagnosedPartial(docId: String) async -> PartialOpLogLoad` on `OpLogStore`. Task 3 consumes both.

- [ ] **Step 1: Write the failing tests** (append to `OpLogStoreDiagnosedTests`)

```swift
    // MARK: - the PARTIAL read (recovery spec §4): readable files load,
    // unreadable ones are NAMED — never thrown, never silently dropped.

    /// The read-only rung's substrate: one unreadable device file must not
    /// cost the readable devices' ops, and must be named for the banner.
    func test_loadDiagnosedPartial_unreadableFileIsNamed_readableOpsStillLoad() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
        let bad = DeviceSlug.unsafeForTesting("bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: "doc-1", deviceSlug: bad, in: tmp)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)

        let result = await store.loadDiagnosedPartial(docId: "doc-1")

        XCTAssertEqual(result.ops.map(\.opId), ["01AAAAAAAAAAAAAAAAAAAAAAAA"],
                       "the readable device's ops still load")
        XCTAssertEqual(result.unreadableFiles.map(\.name), [badURL.lastPathComponent],
                       "the unreadable file is named for the banner")
        XCTAssertFalse(result.unreadableFiles[0].reason.isEmpty)
    }

    /// With every file readable, partial == diagnosed (same ops, no names).
    func test_loadDiagnosedPartial_cleanFiles_matchesLoadDiagnosed() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
        let partial = await store.loadDiagnosedPartial(docId: "doc-1")
        let strict = try await store.loadDiagnosed(docId: "doc-1")
        XCTAssertEqual(partial.ops.map(\.opId), strict.ops.map(\.opId))
        XCTAssertTrue(partial.unreadableFiles.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/MaughamCore --filter OpLogStoreDiagnosedTests 2>&1 | tail -5`
Expected: compile FAILURE — `loadDiagnosedPartial` and `PartialOpLogLoad` don't exist.

- [ ] **Step 3: Implement** (in `OpLogStore.swift`, directly under `loadDiagnosed(docId:)`)

```swift
    /// The result of `loadDiagnosedPartial` — the recovery spec §4's read.
    public struct PartialOpLogLoad {
        public let ops: [Op]
        public let diagnostics: ParseDiagnostics
        /// Sorted by filename; reuses the checkpoint slice's pair type.
        public let unreadableFiles: [CheckpointLoad.UnreadableFile]
    }

    /// RULING-54's DELIBERATE partial read, for the read-only recovery rung
    /// ONLY (spec §4): every readable file loads, every unreadable-yet-present
    /// file is NAMED in the result. This must never become a general-purpose
    /// lenient read — `loadDiagnosed` stays the strict default, and the one
    /// production caller is `Document.load(recovery: .readOnlyPartial)`,
    /// whose Document can write nothing.
    public func loadDiagnosedPartial(docId: String) async -> PartialOpLogLoad {
        var all: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var unreadable: [CheckpointLoad.UnreadableFile] = []
        for url in Self.opLogFileURLs(forDocId: docId, in: projectURL) {
            do {
                let result = try await Self.loadFileDiagnosed(url: url, presenter: presenter)
                all.append(contentsOf: result.ops)
                skipped.append(contentsOf: result.diagnostics.skipped)
            } catch {
                unreadable.append(.init(
                    name: url.lastPathComponent,
                    reason: error.localizedDescription))
            }
        }
        return PartialOpLogLoad(
            ops: Self.mergeSortedDedup(all),
            diagnostics: ParseDiagnostics(skipped: skipped),
            unreadableFiles: unreadable.sorted { $0.name < $1.name })
    }
```

NOTE for the implementer: check how `loadDiagnosed(docId:)` merges its per-file ops (the `mergeSortedDedup` call and its exact signature) and mirror it exactly — the partial read must order/dedup identically to the strict read so the derived text differs only by the missing file's ops.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path Packages/MaughamCore --filter OpLogStoreDiagnosedTests 2>&1 | tail -5`
Expected: PASS (all suite tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore
git commit -m "feat(oplog): loadDiagnosedPartial — the named-not-thrown read the recovery rung stands on"
```

---

### Task 2: `RecoveryCause` — classify the refusal before writing the message

**Files:**
- Create: `Maugham/OpLog/RecoveryCause.swift`
- Test: `MaughamTests/OpLog/RecoveryCauseTests.swift` (new file — **run `./gen.sh` after creating both**)

**Interfaces:**
- Consumes: `OpLogStore.ReadError` (`.unreadableFile(name:underlying:)`, `.unlistableOpsDirectory(underlying:)`).
- Produces: `RecoveryCause` enum + `RecoveryCause.classify(loadError:projectURL:isDatalessStub:)`. Tasks 5/7 consume.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/OpLog/RecoveryCauseTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §3: classify the cause BEFORE writing the message. A
/// dataless iCloud stub is transient and gets the wait-and-retry treatment;
/// everything else gets the honest error plus the ladder's actions.
@MainActor
final class RecoveryCauseTests: XCTestCase {
    private let proj = URL(fileURLWithPath: "/tmp/recovery-cause-fixture")

    func test_unreadableFile_thatIsAStub_classifiesAsICloudNotDownloaded() {
        let err = OpLogStore.ReadError.unreadableFile(name: "doc-1.phone.jsonl", underlying: "x")
        let cause = RecoveryCause.classify(
            loadError: err, projectURL: proj, isDatalessStub: { _ in true })
        guard case .icloudNotDownloaded(let name, let url)? = cause else {
            return XCTFail("expected icloudNotDownloaded, got \(String(describing: cause))")
        }
        XCTAssertEqual(name, "doc-1.phone.jsonl")
        XCTAssertEqual(url.lastPathComponent, "doc-1.phone.jsonl")
        XCTAssertTrue(url.path.contains(".maugham/ops"))
    }

    func test_unreadableFile_notAStub_classifiesAsUnreadable_withReason() {
        let err = OpLogStore.ReadError.unreadableFile(name: "doc-1.phone.jsonl", underlying: "permission denied")
        let cause = RecoveryCause.classify(
            loadError: err, projectURL: proj, isDatalessStub: { _ in false })
        guard case .unreadableFile(let name, _, let reason)? = cause else {
            return XCTFail("expected unreadableFile, got \(String(describing: cause))")
        }
        XCTAssertEqual(name, "doc-1.phone.jsonl")
        XCTAssertEqual(reason, "permission denied")
    }

    func test_unlistableDirectory_classifies_andNeverProbesTheStub() {
        let err = OpLogStore.ReadError.unlistableOpsDirectory(underlying: "perm")
        var probed = false
        let cause = RecoveryCause.classify(
            loadError: err, projectURL: proj, isDatalessStub: { _ in probed = true; return true })
        guard case .unlistableOpsDirectory? = cause else {
            return XCTFail("expected unlistableOpsDirectory, got \(String(describing: cause))")
        }
        XCTAssertFalse(probed, "no file to probe — the directory case has no partial view (spec §3)")
    }

    func test_anUnrelatedError_isNotAClassifiedCause() {
        struct Other: Error {}
        XCTAssertNil(RecoveryCause.classify(
            loadError: Other(), projectURL: proj, isDatalessStub: { _ in true }))
    }
}
```

- [ ] **Step 2: `./gen.sh`, then run to verify failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RecoveryCauseTests 2>&1 | tail -5`
Expected: compile FAILURE — `RecoveryCause` doesn't exist. (If it reports TEST SUCCEEDED with zero tests, gen.sh didn't pick the files up — stop and fix that first.)

- [ ] **Step 3: Implement**

```swift
// Maugham/OpLog/RecoveryCause.swift
import Foundation
import MaughamCore

/// Why a document refused to open, classified for the recovery ladder
/// (spec §3). The classifier looks at the REFUSAL error — never at partial
/// content — so classification itself can't leak partial state.
enum RecoveryCause: Equatable {
    /// A dataless iCloud stub: transient. The pane waits, downloads, and
    /// auto-opens editable. Never offers read-only or (Plan B) quarantine.
    case icloudNotDownloaded(fileName: String, fileURL: URL)
    /// Unreadable for a non-stub reason (permissions break, squatting entry).
    case unreadableFile(fileName: String, fileURL: URL, reason: String)
    /// The ops directory itself can't be listed — nothing enumerable, so no
    /// partial view is possible (spec §3).
    case unlistableOpsDirectory(reason: String)

    /// Classify a `Document.load` refusal. Returns nil for errors the ladder
    /// doesn't own (they keep today's bare-message rendering).
    static func classify(
        loadError: Error,
        projectURL: URL,
        isDatalessStub: (URL) -> Bool = RecoveryCause.defaultStubProbe
    ) -> RecoveryCause? {
        guard let readError = loadError as? OpLogStore.ReadError else { return nil }
        switch readError {
        case .unreadableFile(let name, let underlying):
            let url = projectURL
                .appendingPathComponent(".maugham/ops", isDirectory: true)
                .appendingPathComponent(name)
            return isDatalessStub(url)
                ? .icloudNotDownloaded(fileName: name, fileURL: url)
                : .unreadableFile(fileName: name, fileURL: url, reason: underlying)
        case .unlistableOpsDirectory(let underlying):
            return .unlistableOpsDirectory(reason: underlying)
        }
    }

    /// Production stub probe: an item iCloud knows about whose content isn't
    /// current on this machine. Any resource-read failure answers false —
    /// misclassifying a stub as unreadable degrades to the honest generic
    /// message; the reverse (waiting forever on a permissions break) is worse.
    static func defaultStubProbe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:
            [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RecoveryCauseTests 2>&1 | tail -5`
Expected: PASS, 4 tests executed (verify the count).

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/RecoveryCause.swift MaughamTests/OpLog/RecoveryCauseTests.swift project.yml 2>/dev/null; git add -A && git commit -m "feat(recovery): RecoveryCause — classify the refusal before writing the message"
```

---

### Task 3: `Document.load(recovery: .readOnlyPartial)` — the rung that can write nothing

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (recovery state + widened reject helper + close guard)
- Modify: `Maugham/OpLog/Document+Load.swift` (the recovery overload)
- Modify: `Maugham/OpLog/Document+ExternalChange.swift` (widen its two guards)
- Test: `MaughamTests/OpLog/ReadOnlyRecoveryTests.swift` (new file — **`./gen.sh`**)

**Interfaces:**
- Consumes: Task 1's `loadDiagnosedPartial(docId:) -> PartialOpLogLoad`.
- Produces: `DocumentRecoveryMode` (`.readOnlyPartial`), `Document.load(url:device:session:presenter:recovery:)`, `Document.readOnlyRecovery: ReadOnlyRecoveryState?` (`struct ReadOnlyRecoveryState: Equatable { let unreadableFiles: [CheckpointLoad.UnreadableFile] }`), `Document.isReadOnlyRecovery: Bool`. Task 6 consumes.

- [ ] **Step 1: Write the failing test — THE load-bearing pin (spec §7 item 1)**

```swift
// MaughamTests/OpLog/ReadOnlyRecoveryTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §4: the read-only partial view can write NOTHING — zero ops
/// appended, `.md` byte-identical, pending file untouched, no checkpoint, no
/// seal — including across close(). This is the load-bearing rung: every
/// other rung is safe only because this one is.
@MainActor
final class ReadOnlyRecoveryTests: XCTestCase {

    /// Full gauntlet: open partial, hit EVERY mutation entry point, close.
    func test_partialView_writesNothing_evenAcrossClose() async throws {
        let (project, docURL) = try makeTestProject(prefix: "ROREC", initialMd: "One.\n\nTwo.\n")
        // A real session first, so the op log + a pending file exist.
        let doc1 = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
        let docId = doc1.docId
        doc1.setFullText("One.\n\nTwo.\n\nThree.\n")
        try await doc1.flushBurstNow()
        await doc1.close()

        // Squat a second device's file so the strict load refuses…
        let bad = DeviceSlug.make(from: "bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: docId, deviceSlug: bad, in: project)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        do {
            _ = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
            XCTFail("precondition: the strict load must refuse")
        } catch {}

        // …then snapshot every byte the partial view must not change.
        let opsDir = project.appendingPathComponent(".maugham/ops")
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: opsDir.path)
            where !name.hasPrefix(".") {
                // The squatting directory has no data; skip it.
                let url = opsDir.appendingPathComponent(name)
                if let d = try? Data(contentsOf: url) { out[name] = d }
            }
            out["__md__"] = try Data(contentsOf: docURL)
            let pendingDir = project.appendingPathComponent(".maugham/pending")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: pendingDir.path)) ?? [] {
                out["pending/\(name)"] = try? Data(contentsOf: pendingDir.appendingPathComponent(name))
            }
            return out
        }
        let before = try snapshot()

        // The partial open succeeds where the strict load refused…
        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            recovery: .readOnlyPartial)
        XCTAssertTrue(doc.isReadOnlyRecovery)
        XCTAssertEqual(doc.readOnlyRecovery?.unreadableFiles.map(\.name),
                       [badURL.lastPathComponent], "the banner's names ride on the doc")
        XCTAssertTrue(doc.displayText.contains("Three."), "the readable history is all there")

        // …every mutation entry point no-ops…
        doc.setFullText("VANDALISM")
        doc.setParagraph(id: "zzzz", text: "VANDALISM")
        _ = doc.insertParagraph(after: nil, text: "VANDALISM")
        doc.deleteParagraph(id: "zzzz")
        doc.reorder(sequence: [])
        try await doc.flushBurstNow()
        XCTAssertTrue(doc.displayText.contains("Three."), "the view text never took the writes")
        XCTAssertFalse(doc.displayText.contains("VANDALISM"))

        // …and close writes nothing either (no flush, no autosave, no seal,
        // no pending clear).
        await doc.close()
        XCTAssertEqual(try snapshot(), before,
                       "byte-identical durable state after the whole gauntlet")
    }

    /// A clean project refuses the recovery mode: it exists only for the
    /// refusal path, never as a casual lenient open.
    func test_partialView_refusesWhenNothingIsUnreadable() async throws {
        let (_, docURL) = try makeTestProject(prefix: "ROREC2", initialMd: "Fine.\n")
        let doc1 = try await Document.load(url: docURL, device: "m", session: "s", presenter: nil)
        await doc1.close()
        do {
            _ = try await Document.load(
                url: docURL, device: "m", session: "s", presenter: nil,
                recovery: .readOnlyPartial)
            XCTFail("recovery mode on a healthy doc must refuse — use the normal load")
        } catch {}
    }
}
```

NOTE for the implementer: `makeTestProject(prefix:initialMd:)` is the shared fixture `DocumentLoadQuarantineTests` uses — reuse it (find its definition; do not duplicate it).

- [ ] **Step 2: `./gen.sh`, run to verify failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ReadOnlyRecoveryTests 2>&1 | tail -5`
Expected: compile FAILURE — no `recovery:` parameter, no `isReadOnlyRecovery`.

- [ ] **Step 3: Implement**

In `Document.swift`, beside `isClosed`:

```swift
    /// Recovery spec §4: the read-only partial open. Set only by
    /// `Document.load(recovery: .readOnlyPartial)`; a doc carrying this state
    /// can write NOTHING — every mutation entry point refuses through
    /// `rejectMutationIfNotWritable`, no autosave scheduler exists, and
    /// `close()` husks without flushing, sealing, or clearing.
    public struct ReadOnlyRecoveryState: Equatable, Sendable {
        public let unreadableFiles: [CheckpointLoad.UnreadableFile]
    }
    public internal(set) var readOnlyRecovery: ReadOnlyRecoveryState?
    public var isReadOnlyRecovery: Bool { readOnlyRecovery != nil }
```

Rename the choke point (mechanical, ~8 call sites in `Document.swift`, one each in `Document+Annotations.swift` / `Document+Tasks.swift`, two guards in `Document+ExternalChange.swift` switch to calling it too):

```swift
    /// One choke point for "this instance must not mutate": closed (husked,
    /// abandoned) or read-only recovery (spec §4 — nothing derived from a
    /// partial view is ever written). Callers no-op; documentLog records it.
    internal func rejectMutationIfNotWritable(_ site: StaticString) -> Bool {
        if isClosed {
            documentLog.error(
                "\(site, privacy: .public) called on a closed Document \(self.docId, privacy: .public); no-op (the instance is abandoned by contract)")
            return true
        }
        if isReadOnlyRecovery {
            documentLog.error(
                "\(site, privacy: .public) called on a read-only recovery Document \(self.docId, privacy: .public); no-op (nothing derived from a partial view is written)")
            return true
        }
        return false
    }
```

Also in `Document.swift`: `performAutosave` and `flushBurstNow` already guard via the helper or `isClosed` — route BOTH through `rejectMutationIfNotWritable`. Then read `close()`'s existing husk block (the field-drops after the durable writes — `paragraphs`/`sequence`/`displayText`/`_opLogMirror`/caches/`lastDiskEcho`), extract it into `private func huskInMemoryState()`, call it from `close()`'s existing tail so behaviour is unchanged, and add an early husk-only path at the top of `close()`:

```swift
        // A read-only recovery doc closes by husking alone: it has nothing to
        // flush (mutations refused), must not seal (maintenance writes), and
        // must not clear the pending file (it belongs to the REAL open that
        // follows recovery).
        if isReadOnlyRecovery {
            isClosed = true
            huskInMemoryState()
            return
        }
```

In `Document+Load.swift`:

```swift
public enum DocumentRecoveryMode: Equatable, Sendable {
    /// Spec §4: derive from the readable files only; the Document is
    /// read-only and can write nothing.
    case readOnlyPartial
}
```

Add a public overload beside the existing `load`:

```swift
    public static func load(
        url: URL, device: String, session: String,
        presenter: NSFilePresenter?, recovery: DocumentRecoveryMode
    ) async throws -> Document {
        // .readOnlyPartial is the only mode; the switch is here so a second
        // mode can't ship without deciding its load shape explicitly.
        switch recovery {
        case .readOnlyPartial:
            return try await loadReadOnlyPartial(
                url: url, device: device, session: session, presenter: presenter)
        }
    }
```

`loadReadOnlyPartial` mirrors the internal `load` with these differences (the implementer should read the existing `load(url:device:session:presenter:burstIdle:burstMax:)` top to bottom first and copy its docId/projectURL resolution):

1. **No `Bootstrap.run`** — a partial view must not mint anchors. If the doc genuinely needs bootstrap (no op log at all), throw: nothing to recover.
2. **No pending fold** — `pending.loadFromDisk()` is NOT called. The pending file belongs to the real open that follows recovery.
3. **Ops via Task 1**: `let partial = await opStore.loadDiagnosedPartial(docId: docId)`. If `partial.unreadableFiles.isEmpty`, `throw OpLogStore.ReadError.unreadableFile(name: "-", underlying: "recovery mode on a healthy document — use the normal load")` (the second test pins this; pick a cleaner dedicated error if one reads better, and update the test to match).
4. **No quarantine record** for parse skips (the real open already writes those).
5. **No autosave scheduler**: skip the `doc.autosaveScheduler = …` assignment entirely.
6. Stamp `doc.readOnlyRecovery = ReadOnlyRecoveryState(unreadableFiles: partial.unreadableFiles)` before `return doc`.
7. **Do not stamp `unrecoveredPendingFailure`** (its delivery belongs to the real open).

- [ ] **Step 4: Run the new suite AND the neighbours the rename touches**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ReadOnlyRecoveryTests -only-testing:MaughamTests/DocumentLoadQuarantineTests -only-testing:MaughamTests/DocumentDoubleCloseTests 2>&1 | tail -5`
Expected: PASS with the correct counts (2 new + existing).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(recovery): Document.load(recovery: .readOnlyPartial) — the rung that can write nothing"
```

---

### Task 4: EditorSurface read-only posture + the typing-intent signal

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift` (`EditorSurfaceConfiguration`, `makeNSView`, `MaughamTextView`)
- Test: `MaughamTests/Editor/EditorSurfaceReadOnlyTests.swift` (new file — **`./gen.sh`**; if the suite mounts and styles text, wire `FontWarmup.ensure()` in `override class func setUp()`)

**Interfaces:**
- Produces: `EditorSurfaceConfiguration.readOnlyRecovery: Bool` (default `false`) and `EditingCallbacks.onTypingRefused: (() -> Void)?`. Task 6 consumes.

- [ ] **Step 1: Write the failing test**

```swift
// MaughamTests/Editor/EditorSurfaceReadOnlyTests.swift
import XCTest
import AppKit
@testable import Maugham

/// Recovery spec §4: the read-only surface refuses typing at the AppKit level
/// (no display/model divergence to reconcile — tripwires 3/6) and SIGNALS the
/// refusal so the host can surface the next rung's offer.
@MainActor
final class EditorSurfaceReadOnlyTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    func test_readOnlyTextView_refusesTyping_andSignalsIntent() {
        var refusals = 0
        let tv = MaughamTextView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = false
        tv.onTypingRefusedWhileReadOnly = { refusals += 1 }
        tv.string = "Untouchable."

        tv.keyDown(with: Self.keyEvent("a"))

        XCTAssertEqual(tv.string, "Untouchable.", "the keystroke changed nothing")
        XCTAssertEqual(refusals, 1, "…and the host heard about it")
    }

    func test_editableTextView_neverFiresTheRefusalSignal() {
        var refusals = 0
        let tv = MaughamTextView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = true
        tv.onTypingRefusedWhileReadOnly = { refusals += 1 }
        tv.keyDown(with: Self.keyEvent("a"))
        XCTAssertEqual(refusals, 0)
    }

    private static func keyEvent(_ char: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: 0)!
    }
}
```

- [ ] **Step 2: `./gen.sh`, run to verify failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/EditorSurfaceReadOnlyTests 2>&1 | tail -5`
Expected: compile FAILURE — `onTypingRefusedWhileReadOnly` doesn't exist.

- [ ] **Step 3: Implement**

In `MaughamTextView` (`EditorSurface.swift:469`):

```swift
    /// Recovery spec §4: typing in a read-only recovery view is refused AND
    /// answered — the host surfaces the next rung's offer. Fired only when
    /// `isEditable == false`; nil (the default) restores plain AppKit refusal.
    var onTypingRefusedWhileReadOnly: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !isEditable, let onTypingRefusedWhileReadOnly {
            onTypingRefusedWhileReadOnly()
            return
        }
        super.keyDown(with: event)
    }
```

In `EditorSurfaceConfiguration`: add `var readOnlyRecovery: Bool = false` (top level, beside `callbacks`), and in `EditingCallbacks`: `var onTypingRefused: (() -> Void)? = nil`. In `makeNSView`, where `textView.isEditable = true` is set (line ~244):

```swift
        textView.isEditable = !configuration.readOnlyRecovery
        textView.onTypingRefusedWhileReadOnly = configuration.callbacks.onTypingRefused
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/EditorSurfaceReadOnlyTests 2>&1 | tail -5`
Expected: PASS, 2 tests executed.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(editor): read-only recovery posture — typing refused at the AppKit level, and signalled"
```

---

### Task 5: `RecoveryPaneModel` + `DocumentRecoveryPane` — the ladder, testable

**Files:**
- Create: `Maugham/Views/DocumentRecoveryPane.swift` (model + view in one file; the model carries all logic, the view is thin)
- Test: `MaughamTests/RecoveryPaneModelTests.swift` (new file — **`./gen.sh`**)

**Interfaces:**
- Consumes: Task 2's `RecoveryCause`.
- Produces: `@Observable final class RecoveryPaneModel` with `init(cause:projectURL:probeInterval:isReadable:startDownload:onOpenEditable:onOpenReadOnly:)`, `var headline: String`, `var detail: String`, `var offersReadOnly: Bool`, `var offersRestore: Bool`, `func beginWatching()`, `func stopWatching()`; and `struct DocumentRecoveryPane: View` taking the model plus an `openWindow`-driven restore action. Task 7 consumes.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/RecoveryPaneModelTests.swift
import XCTest
@testable import Maugham

/// Recovery spec §3: the pane's behaviour per cause — stub waits/downloads/
/// auto-opens and NEVER offers read-only; unreadable offers the ladder;
/// the directory case offers restore only.
@MainActor
final class RecoveryPaneModelTests: XCTestCase {
    private let proj = URL(fileURLWithPath: "/tmp/rpm-fixture")
    private let fileURL = URL(fileURLWithPath: "/tmp/rpm-fixture/.maugham/ops/doc-1.phone.jsonl")

    func test_stubCause_downloadsWaitsAndAutoOpens_neverOffersReadOnly() async {
        var downloads = 0
        var openedEditable = 0
        var readable = false
        let model = RecoveryPaneModel(
            cause: .icloudNotDownloaded(fileName: "doc-1.phone.jsonl", fileURL: fileURL),
            projectURL: proj,
            probeInterval: .milliseconds(5),
            isReadable: { _ in readable },
            startDownload: { _ in downloads += 1 },
            onOpenEditable: { openedEditable += 1 },
            onOpenReadOnly: { XCTFail("stub path must never open read-only") })

        XCTAssertFalse(model.offersReadOnly, "spec §3: the stub path never offers the partial view")
        XCTAssertTrue(model.offersRestore)
        XCTAssertTrue(model.headline.localizedCaseInsensitiveContains("icloud"))

        model.beginWatching()
        XCTAssertEqual(downloads, 1, "the download is triggered once, up front")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(openedEditable, 0, "still waiting — not readable yet")
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(openedEditable, 1, "auto-open the moment it reads (ruling: auto from the refusal pane)")
        model.stopWatching()
    }

    func test_unreadableCause_offersTheLadder_andAutoOpensOnReadable() async {
        var openedEditable = 0
        var readable = false
        let model = RecoveryPaneModel(
            cause: .unreadableFile(fileName: "doc-1.phone.jsonl", fileURL: fileURL, reason: "permission denied"),
            projectURL: proj,
            probeInterval: .milliseconds(5),
            isReadable: { _ in readable },
            startDownload: { _ in XCTFail("no download for a non-stub cause") },
            onOpenEditable: { openedEditable += 1 },
            onOpenReadOnly: {})

        XCTAssertTrue(model.offersReadOnly)
        XCTAssertTrue(model.offersRestore)
        XCTAssertTrue(model.detail.contains("permission denied"), "the reason reaches the writer")
        model.beginWatching()
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(openedEditable, 1, "a fixed permissions break auto-opens from the refusal pane too")
        model.stopWatching()
    }

    func test_directoryCause_offersRestoreOnly() {
        let model = RecoveryPaneModel(
            cause: .unlistableOpsDirectory(reason: "perm"),
            projectURL: proj, probeInterval: .seconds(1),
            isReadable: { _ in false }, startDownload: { _ in },
            onOpenEditable: {}, onOpenReadOnly: {})
        XCTAssertFalse(model.offersReadOnly, "nothing enumerable — no partial view (spec §3)")
        XCTAssertTrue(model.offersRestore)
    }
}
```

- [ ] **Step 2: `./gen.sh`, run to verify failure**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RecoveryPaneModelTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

```swift
// Maugham/Views/DocumentRecoveryPane.swift
import SwiftUI
import MaughamCore

/// The recovery ladder's brain (spec §3), separated from the view so the
/// per-cause behaviour — what's offered, what's watched, what auto-opens —
/// is unit-testable without a window. The view below is deliberately thin.
@MainActor
@Observable
final class RecoveryPaneModel {
    let cause: RecoveryCause
    let projectURL: URL
    private let probeInterval: Duration
    private let isReadable: (URL) -> Bool
    private let startDownload: (URL) -> Void
    private let onOpenEditable: () -> Void
    let onOpenReadOnly: () -> Void
    private var watcher: Task<Void, Never>?

    init(cause: RecoveryCause, projectURL: URL,
         probeInterval: Duration = .seconds(2),
         isReadable: @escaping (URL) -> Bool = RecoveryPaneModel.defaultReadableProbe,
         startDownload: @escaping (URL) -> Void = RecoveryPaneModel.defaultStartDownload,
         onOpenEditable: @escaping () -> Void,
         onOpenReadOnly: @escaping () -> Void) {
        self.cause = cause
        self.projectURL = projectURL
        self.probeInterval = probeInterval
        self.isReadable = isReadable
        self.startDownload = startDownload
        self.onOpenEditable = onOpenEditable
        self.onOpenReadOnly = onOpenReadOnly
    }

    var offersReadOnly: Bool {
        if case .unreadableFile = cause { return true }
        return false
    }
    var offersRestore: Bool { true }

    var headline: String {
        switch cause {
        case .icloudNotDownloaded:
            return "iCloud hasn’t downloaded part of this document’s history yet"
        case .unreadableFile(let name, _, _):
            return "The history file “\(name)” exists but can’t be read"
        case .unlistableOpsDirectory:
            return "The document’s history folder can’t be listed"
        }
    }

    var detail: String {
        switch cause {
        case .icloudNotDownloaded(let name, _):
            return "Maugham asked iCloud to download “\(name)” and will open the "
                 + "document automatically the moment it arrives. Your words are intact."
        case .unreadableFile(_, _, let reason):
            return "\(reason). Your words are intact inside it — Maugham won’t open a "
                 + "shortened version over them. You can read what’s available, or "
                 + "restore from a backup."
        case .unlistableOpsDirectory(let reason):
            return "\(reason). Check the folder’s permissions (.maugham/ops), then "
                 + "reopen — or restore from a backup."
        }
    }

    /// Start the readability watch. For the stub cause the download is
    /// triggered once, first. The watch auto-opens EDITABLE on readability —
    /// Denver's ruling: auto from the refusal pane, offer from an open view.
    func beginWatching() {
        guard watcher == nil else { return }
        let watchedURL: URL?
        switch cause {
        case .icloudNotDownloaded(_, let url): startDownload(url); watchedURL = url
        case .unreadableFile(_, let url, _): watchedURL = url
        case .unlistableOpsDirectory: watchedURL = nil   // Retry is manual here.
        }
        guard let watchedURL else { return }
        watcher = Task { [probeInterval, isReadable, onOpenEditable] in
            while !Task.isCancelled {
                try? await Task.sleep(for: probeInterval)
                if Task.isCancelled { return }
                if isReadable(watchedURL) { onOpenEditable(); return }
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Cheap readability probe: open-for-reading + read one byte. Never a
    /// whole-file read (a poll must not cost megabytes), never a write.
    nonisolated static func defaultReadableProbe(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // Zero-length is readable (a truthfully empty file); a stub or a
        // permissions break throws above or here.
        return (try? handle.read(upToCount: 1)) != nil
    }

    nonisolated static func defaultStartDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

/// The ladder rendered (spec §3). Thin: every behaviour lives on the model.
struct DocumentRecoveryPane: View {
    let model: RecoveryPaneModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28)).foregroundStyle(.orange)
            Text(model.headline).font(.headline)
                .multilineTextAlignment(.center)
            Text(model.detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                if model.offersReadOnly {
                    Button("Open Read-Only") { model.onOpenReadOnly() }
                }
                if model.offersRestore {
                    Button("Restore from Backup…") {
                        openWindow(id: "backup-restore", value: model.projectURL)
                    }
                }
            }
            if case .icloudNotDownloaded = model.cause {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.beginWatching() }
        .onDisappear { model.stopWatching() }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RecoveryPaneModelTests 2>&1 | tail -5`
Expected: PASS, 3 tests executed. (If the two async tests flake under load, raise the sleep margins — they poll at 5ms and wait 60ms; the wall-clock-family discriminator applies.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(recovery): RecoveryPaneModel + DocumentRecoveryPane — the ladder, testable without a window"
```

---

### Task 6: `RecoveryBanner` + EditorHost's read-only render path

**Files:**
- Create: `Maugham/Views/RecoveryBanner.swift`
- Modify: `Maugham/Views/EditorHost.swift` (read-only branch: configuration + banner + typing signal + Reopen offer)
- Test: `MaughamTests/RecoveryBannerTests.swift` (new file — **`./gen.sh`**)

**Interfaces:**
- Consumes: Task 3's `Document.readOnlyRecovery`, Task 4's `readOnlyRecovery` config + `onTypingRefused`, Task 5's `RecoveryPaneModel.defaultReadableProbe`.
- Produces: `@Observable final class RecoveryBannerModel` (`init(unreadableFiles:opsDirectory:probeInterval:isReadable:)`, `var message: String`, `var offersReopen: Bool`, `var emphasised: Bool`, `func noteTypingRefused()`, `func beginWatching(onAllReadable:)` — sets `offersReopen` true when every named file reads; never auto-reloads). Task 7 wires `onReopen` to the host's retry.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/RecoveryBannerTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §4: the banner names what's missing, OFFERS the return
/// (never yanks), and answers typing with emphasis. Plan B swaps the typing
/// copy for the quarantine offer; Plan A's copy promises nothing unbuilt.
@MainActor
final class RecoveryBannerTests: XCTestCase {
    private let files = [CheckpointLoad.UnreadableFile(name: "doc-1.phone.jsonl", reason: "permission denied")]
    private let opsDir = URL(fileURLWithPath: "/tmp/rb-fixture/.maugham/ops")

    func test_message_namesTheFiles_andReasonRidesInDetail() {
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .seconds(1), isReadable: { _ in false })
        XCTAssertTrue(model.message.contains("doc-1.phone.jsonl"))
        XCTAssertTrue(model.message.localizedCaseInsensitiveContains("read-only"))
        XCTAssertFalse(model.offersReopen)
    }

    func test_reopenIsOffered_whenEveryNamedFileReads_neverBefore() async {
        var readable = false
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .milliseconds(5), isReadable: { _ in readable })
        model.beginWatching()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.offersReopen)
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(model.offersReopen,
            "the offer appears — and `offersReopen` is the model's ONLY output: "
            + "there is no reload callback to misuse, the return is an offer, "
            + "never a yank (ruling 2)")
        model.stopWatching()
    }

    func test_typingRefusal_emphasisesTheBanner() {
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .seconds(1), isReadable: { _ in false })
        XCTAssertFalse(model.emphasised)
        model.noteTypingRefused()
        XCTAssertTrue(model.emphasised)
    }
}
```

DESIGN NOTE (why `beginWatching()` takes no closure): a completion callback on the watcher would be a reload hook waiting to be misused. `offersReopen` is the model's single output; the view renders it as the Reopen button, and only the writer's press reloads. Do not add a callback parameter.

- [ ] **Step 2: `./gen.sh`, run to verify failure** (as before)

- [ ] **Step 3: Implement**

```swift
// Maugham/Views/RecoveryBanner.swift
import SwiftUI
import MaughamCore

/// The read-only partial view's standing banner (spec §4). The model owns
/// the readability watch; the view renders `message` + a Reopen button when
/// `offersReopen` — pressed, the HOST closes the recovery doc and retries
/// the normal load. Nothing here reloads anything by itself.
@MainActor
@Observable
final class RecoveryBannerModel {
    let unreadableFiles: [CheckpointLoad.UnreadableFile]
    private let opsDirectory: URL
    private let probeInterval: Duration
    private let isReadable: (URL) -> Bool
    private(set) var offersReopen = false
    private(set) var emphasised = false
    private var watcher: Task<Void, Never>?

    init(unreadableFiles: [CheckpointLoad.UnreadableFile], opsDirectory: URL,
         probeInterval: Duration = .seconds(5),
         isReadable: @escaping (URL) -> Bool = RecoveryPaneModel.defaultReadableProbe) {
        self.unreadableFiles = unreadableFiles
        self.opsDirectory = opsDirectory
        self.probeInterval = probeInterval
        self.isReadable = isReadable
    }

    var message: String {
        let names = unreadableFiles.map(\.name).joined(separator: ", ")
        let plural = unreadableFiles.count == 1 ? "file" : "files"
        return "Read-only — \(unreadableFiles.count) history \(plural) can’t be read "
             + "(\(names)). What you see may be missing recent work."
    }

    /// Detail for the tooltip: per-file reasons (the checkpoint notice's shape).
    var detail: String {
        unreadableFiles.map { "\($0.name) — \($0.reason)" }.joined(separator: "\n")
    }

    /// Typing was refused (Task 4's signal): emphasise. Plan A's copy stays
    /// on the message; Plan B adds the quarantine offer here.
    func noteTypingRefused() { emphasised = true }

    func beginWatching() {
        guard watcher == nil else { return }
        watcher = Task { [probeInterval, isReadable, opsDirectory, unreadableFiles] in
            while !Task.isCancelled {
                try? await Task.sleep(for: probeInterval)
                if Task.isCancelled { return }
                let allReadable = unreadableFiles.allSatisfy {
                    isReadable(opsDirectory.appendingPathComponent($0.name))
                }
                if allReadable {
                    await MainActor.run { self.offersReopen = true }
                    return
                }
            }
        }
    }

    func stopWatching() { watcher?.cancel(); watcher = nil }
}

struct RecoveryBanner: View {
    let model: RecoveryBannerModel
    let onReopen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(model.offersReopen ? "Full history is back." : model.message)
                .font(.caption)
                .help(model.detail)
            Spacer(minLength: 4)
            if model.offersReopen {
                Button("Reopen") { onReopen() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.emphasised ? .orange.opacity(0.25) : .orange.opacity(0.12))
        // NO fixedSize(horizontal: false, vertical: true) — see
        // ViewOnlyShareNotice's warning: an unbreakable minimum height on a
        // top inset grows the whole split view past the window.
        .task { model.beginWatching() }
        .onDisappear { model.stopWatching() }
    }
}
```

EditorHost wiring (this task wires the BANNER + read-only surface only; the refusal pane is Task 7). In the body's document branch, when `doc.isReadOnlyRecovery`: render `RecoveryBanner` above the surface (`safeAreaInset(edge: .top)` — the `ViewOnlyShareNotice` placement), pass `readOnlyRecovery: true` into the surface configuration, and wire `onTypingRefused` to a `bannerModel.noteTypingRefused()`. Hold the banner model in `@State private var recoveryBannerModel: RecoveryBannerModel?`, created when a recovery doc binds (unreadable names from `doc.readOnlyRecovery`, opsDirectory = `store.url.appendingPathComponent(".maugham/ops")`). `onReopen` calls the Task 7 retry (until Task 7 lands, wire it to the same private func stub `retryFullLoad()` that Task 7 fills — declare it in THIS task as: close recovery doc, nil the markers, `await loadDocumentIfNeeded()`):

```swift
    /// Close whatever is bound (recovery or stale) and run the normal load
    /// again. Reached from RecoveryBanner's Reopen and (Task 7) the pane's
    /// auto-open.
    private func retryFullLoad() async {
        if let doc = document { await doc.close() }
        document = nil
        recoveryBannerModel = nil
        loadedItemId = nil
        priorLoadedPath = nil
        await loadDocumentIfNeeded()
    }
```

NOTE: the recovery doc is NOT `documentStore.register`ed (spec §4 / global constraints) — Task 7's open-read-only path enforces this; nothing in this task registers anything.

- [ ] **Step 4: Run the banner tests + EditorHost neighbours**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RecoveryBannerTests -only-testing:MaughamTests/EditorIntegrationHarnessTests 2>&1 | tail -5`
Expected: PASS with correct counts.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(recovery): RecoveryBanner + EditorHost read-only render — named, offered, never yanked"
```

---

### Task 7: EditorHost refusal wiring — the pane replaces the bare message

**Files:**
- Modify: `Maugham/Views/EditorHost.swift` (catch-path classification, pane render, open-read-only, auto-reopen)
- Test: extend `MaughamTests/OpLog/ReadOnlyRecoveryTests.swift` (wiring census) — plus the existing refusal pins must stay green.

**Interfaces:**
- Consumes: Tasks 2/3/5/6 (`RecoveryCause.classify`, `Document.load(recovery:)`, `RecoveryPaneModel`, `DocumentRecoveryPane`, `retryFullLoad()`).
- Produces: the writer-facing ladder. Plan B extends this pane with the quarantine action.

- [ ] **Step 1: Write the failing wiring census** (append to `ReadOnlyRecoveryTests`)

```swift
    /// Delivery-path census (the M9-OL-010 pattern): the refusal catch must
    /// classify, the body must render the pane for a classified cause, the
    /// read-only action must load `recovery: .readOnlyPartial` and must NOT
    /// register the doc, and the pane's auto-open must route through
    /// retryFullLoad. A mounted pin needs a full window fixture; this census
    /// catches each wire disappearing.
    func test_editorHostRefusalWiring_census() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Maugham/Views/EditorHost.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("RecoveryCause.classify(loadError:"),
                      "the catch classifies the refusal")
        XCTAssertTrue(source.contains("DocumentRecoveryPane("),
                      "a classified cause renders the pane, not the bare message")
        XCTAssertTrue(source.contains("recovery: .readOnlyPartial"),
                      "the read-only action uses the recovery load")
        // The recovery load's registration ban (spec §4): the only register
        // call must remain the normal path's single one.
        XCTAssertEqual(source.components(separatedBy: "documentStore.register(").count - 1, 1,
                      "exactly ONE register call site — the recovery doc is invisible to the registry MCP resolves through")
        XCTAssertTrue(source.contains("onOpenEditable: ") && source.contains("retryFullLoad()"),
                      "the pane's auto-open routes through the one retry path")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ReadOnlyRecoveryTests 2>&1 | tail -5`
Expected: FAIL on the census assertions (wiring absent).

- [ ] **Step 3: Implement**

In `loadDocumentIfNeeded`'s catch (after `loadError = …`, keeping the existing notice post untouched — the refusal semantics do not change):

```swift
            recoveryCause = RecoveryCause.classify(loadError: error, projectURL: store.url)
```

State: `@State private var recoveryCause: RecoveryCause?` (cleared alongside `loadError = nil` on success and in `retryFullLoad()`). In the body where `placeholder(loadError ?? "Loading…")` renders, branch first:

```swift
            } else if currentItem?.type == .document, let cause = recoveryCause {
                DocumentRecoveryPane(model: RecoveryPaneModel(
                    cause: cause,
                    projectURL: store.url,
                    onOpenEditable: { Task { await retryFullLoad() } },
                    onOpenReadOnly: { Task { await openReadOnly() } }))
            } else if currentItem?.type == .document {
                placeholder(loadError ?? "Loading…")
```

CAUTION for the implementer: constructing the model inline in `body` re-creates it (and its watcher) every render pass. Hold it in `@State` keyed on the cause instead — create in the same place `recoveryCause` is set, or `.onChange(of: recoveryCause)`. The census doesn't police this; SwiftUI discipline does. `ProjectWindow.body`-adjacent type-check budget: if `EditorHost.body` stops compiling in reasonable time, extract the branch into a `@ViewBuilder private var recoveryOrPlaceholder`.

The read-only open:

```swift
    /// Rung 1 (spec §4): bind a read-only partial Document. NEVER registered —
    /// DocumentStore's registry is how MCP resolves open docs, and a
    /// registered partial view would hand Claude the partial state §6 forbids.
    private func openReadOnly() async {
        guard let item = currentItem, let path = item.path else { return }
        do {
            let doc = try await Document.load(
                url: store.url.appendingPathComponent(path),
                device: Self.deviceId, session: Self.sessionId,
                presenter: documentStore.presenter,
                recovery: .readOnlyPartial)
            document = doc
            loadedItemId = item.id
            priorLoadedPath = path
            loadError = nil
            recoveryCause = nil
            recoveryBannerModel = RecoveryBannerModel(
                unreadableFiles: doc.readOnlyRecovery?.unreadableFiles ?? [],
                opsDirectory: store.url.appendingPathComponent(".maugham/ops"))
        } catch {
            loadError = error.localizedDescription
        }
    }
```

Also verify: `deliverPendingRecoveryNoticeIfPossible()` must NOT fire for a recovery doc (it can't — Task 3 never stamps `unrecoveredPendingFailure` in recovery mode; add nothing, this is a check).

- [ ] **Step 4: Run the census + the floor's pins + the full editor family**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ReadOnlyRecoveryTests -only-testing:MaughamTests/DocumentLoadQuarantineTests -only-testing:MaughamTests/RecoveryPaneModelTests -only-testing:MaughamTests/RecoveryBannerTests -only-testing:MaughamTests/EditorIntegrationHarnessTests 2>&1 | tail -5`
Expected: PASS, counts verified — especially `DocumentLoadQuarantineTests` (the floor unchanged).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(recovery): the refusal pane becomes the ladder — classify, wait-and-retry, read-only, restore"
```

---

### Task 8: Docs, register rows, full gate

**Files:**
- Modify: `docs/guide/structure-and-binder.md` (or the guide page that documents the editor pane's error states — the implementer greps `docs/guide/` for where the current refusal is described, and adds the ladder there; if nowhere, `docs/guide/getting-started.md`'s troubleshooting section)
- Modify: `Maugham/OpLog/AREA.md` (recovery mode row), `Maugham/Views/AREA.md` (pane + banner rows)
- Modify: `register/reconciliation/OpLog.claims.json` + `.filings.json` (two rows), then `flip-claim.py recompute --module OpLog` + `27-generate-state.py`
- Modify: `docs/roadmap.md` — the recovery entry's rungs 1/2/4 flip to built-by-Plan-A wording; rung 3 stays queued for Plan B

- [ ] **Step 1: Write the two register claims**

M9-OL-013 (POSTCONDITION): the read-only partial view writes nothing across its whole life — pinned by `ReadOnlyRecoveryTests.test_partialView_writesNothing_evenAcrossClose`; the partial doc is invisible to the MCP-resolving registry — pinned by the wiring census. Filed COMPLIES under RULING-54 (the deliberate, surfaced partial read) with the spec cited.

M9-OL-014 (POSTCONDITION): the refusal classifies its cause — a dataless stub gets wait-download-auto-open and never offers the partial view; the return auto-opens from the refusal pane and is offer-only from an open view — pinned by `RecoveryCauseTests` + `RecoveryPaneModelTests` + `RecoveryBannerTests`. Filed COMPLIES under RULING-54 + RULING-7 (the refusal names its real cause).

Statements follow the M9-OL-007..012 house shape (what, the before-state, the fix provenance "born with the milestone", the pinning tests in `source.ref`).

- [ ] **Step 2: Docs sweep** — guide page, both AREA.md files, roadmap entry. Help describes what SHIPS (rungs 1/2/4-lite), not Plan B.

- [ ] **Step 3: Regenerate + verify register**

Run: `python3 register/scripts/flip-claim.py recompute --module OpLog && python3 register/scripts/27-generate-state.py && python3 register/scripts/23-generate-rulings.py && grep -rn PENDING register/ --include='*.json' | wc -l`
Expected: 14 reached / 14 complies; state regenerated; rulings verified; 0 PENDING.

- [ ] **Step 4: Full gate**

Run: `./scripts/test.sh full`
Expected: green, no skips. Apply the flake discriminators by name before blaming the branch.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "docs+register(recovery): Plan A ships — rungs 1, 2 and 4-lite documented and claimed"
```

---

## After the plan

Whole-branch review before merge (rule 9 — dispatch WITH the seams named: the register-invisibility constraint, the no-writes gauntlet's coverage, the two pollers' cancellation, the floor's pins untouched). No-ff merge. Notify the peer session (EditorHost is shared). Denver's smoke (suggested): break a file's permissions under `.maugham/ops/` on a test project → refusal shows the ladder → Open Read-Only shows the text + banner → fix permissions → banner offers Reopen → reopen edits normally. Plan B (quarantine + the return merge) is written only after this lands, against the built code (spec §9).
