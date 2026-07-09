# Unified ⌘Z Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ⌘Z span every writer-initiated mutation — annotation reject/archive/edit/withdraw, all task ops, inline checkbox flips, and History Rewind restores — by appending compensating ops (never truncating), plus a phone Reopen action on resolved annotations.

**Architecture:** A typed inverse-op seam in two homes (`AnnotationInverse` in MaughamCore, shared with the phone; `TaskInverse` Mac-side beside `TaskDeriver`), consumed by one small `OpUndoRegistrar` that encodes the v0.17.0 accept-undo NSUndoManager dance. One new op kind (`annotationReopen`) + one new `SynthesisSource` case (`.undoRewind`) → schema v3, paired Mac+phone release.

**Tech Stack:** Swift, AppKit `NSUndoManager`, SwiftUI `@Environment(\.undoManager)`, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-09-unified-undo-design.md`. Two confirmed deviations from the spec's assumptions, both reflected below: (1) inline `- [ ]` toggles emit no task op — text-is-state — so their undo is a guarded text flip-back, not a `taskStatusChange`; (2) there is no grep-tripwire pattern for op kinds — the real guard is the compile-time exhaustive switches, which the new case triggers automatically.

## Global Constraints

- **Schema pairing:** this milestone bumps `ProjectManifest.currentSchemaVersion` 2 → 3. Mac and phone MUST release together (v0.17.0/phone-v0.4.0 precedent).
- **Append-only:** undo appends compensating ops. Never truncate, never rewrite the op log.
- **MaughamCore is UndoManager-free** and Apple-frameworks-only. All `NSUndoManager` code stays in the Mac target.
- **Do not refactor `acceptAnnotation`/`revertAcceptedAnnotation`** (`Maugham/OpLog/Document+Annotations.swift`) — regression-scarred v0.17.0 code; mirror its pattern, don't restructure it.
- Tripwires (CLAUDE.md): 2/3/6/7 (Editor binding contract — no new observable state on EditorHost, no 4th `applyExternalText` caller, no heavy work in binding setters); 8 (4-char alphabet-restricted paragraph ids in tests crossing the `.md` ↔ op-log boundary — `[0-9a-hjkmnp-tv-z]`); 11 (no test-data migration); 12 (typed enums, additive cases only); 19 (phone never reimplements shared logic).
- Read `Maugham/Editor/AREA.md`, `Maugham/OpLog/AREA.md`, `MaughamPhone/AREA.md` before editing those areas.
- Build/test commands:
  - Mac: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (append `-only-testing:MaughamTests/<Class>` or `-only-testing:MaughamCoreTests/<Class>` to scope).
  - Phone: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`. Simulator "Busy / failed preflight" is a flake — re-run.
  - `ProjectWindow.body` changes in Task 7 ⇒ Task 9 MUST run a local Release build (`-configuration Release build`).
- Commit after every task with a conventional-commits message.

---

### Task 1: Core — `annotationReopen` op kind, `.undoRewind` synthesis source, deriver reopen semantics, schema v3

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpKind.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/SynthesisSource.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift:29`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Deriver.swift` (exhaustive `appliesToManuscript` switch — compiler will point at it)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationReopenOpTests.swift` (new)

**Interfaces:**
- Produces: `OpKind.annotationReopen = "annotation_reopen"`; `SynthesisSource.undoRewind = "undo_rewind"`; `ProjectManifest.currentSchemaVersion == 3`; deriver semantics: latest `annotationReopen` lifecycle op → status `.open`; a reopen newer than a withdraw cancels the withdrawal.

- [ ] **Step 1: Write the failing tests**

Create `AnnotationReopenOpTests.swift`. Mirror the style of `AcceptRevertOpTests.swift` in the same directory (it has op-builder helpers — copy its `makeOp`-style helper). Paragraph ids: 4-char literals like `"ab2c"` (tripwire 8).

```swift
import XCTest
@testable import MaughamCore

final class AnnotationReopenOpTests: XCTestCase {

    private func op(_ id: String, kind: OpKind, source: String? = nil,
                    userResponse: String? = nil, body: String? = nil,
                    changes: [Op.ParagraphChange] = []) -> Op {
        Op(opId: id, docId: "d1", at: Date(timeIntervalSince1970: 1_000),
           device: "mac", session: "s1", kind: kind, changes: changes,
           sequence: nil,
           provenance: Op.Provenance(sessionId: "s1",
                                     annotationBody: body,
                                     sourceAnnotationId: source,
                                     userResponse: userResponse))
    }

    func test_rawValue_roundTrip() throws {
        XCTAssertEqual(OpKind.annotationReopen.rawValue, "annotation_reopen")
        let data = try JSONEncoder().encode(OpKind.annotationReopen)
        XCTAssertEqual(try JSONDecoder().decode(OpKind.self, from: data), .annotationReopen)
    }

    func test_synthesisSource_undoRewind_rawValue() throws {
        XCTAssertEqual(SynthesisSource.undoRewind.rawValue, "undo_rewind")
    }

    func test_schemaVersion_bumped() {
        XCTAssertGreaterThanOrEqual(ProjectManifest.currentSchemaVersion, 3)
    }

    func test_rejectThenReopen_derivesOpen() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let reject = op("01B", kind: .claudeReject, source: "01A", userResponse: "no thanks")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        let derived = AnnotationDeriver.derive(ops: [creation, reject, reopen],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.first?.status, .open)
    }

    func test_archiveThenReopen_derivesOpen() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let archive = op("01B", kind: .claudeArchive, source: "01A")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        let derived = AnnotationDeriver.derive(ops: [creation, archive, reopen],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.first?.status, .open)
    }

    func test_reopenThenReReject_derivesRejected_withUserResponse() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let reject = op("01B", kind: .claudeReject, source: "01A", userResponse: "no")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        let rereject = op("01D", kind: .claudeReject, source: "01A", userResponse: "no")
        let derived = AnnotationDeriver.derive(ops: [creation, reject, reopen, rereject],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.first?.status, .rejected)
        XCTAssertEqual(derived.first?.userResponse, "no")
    }

    func test_withdrawThenReopen_annotationReappears() {
        let creation = op("01A", kind: .claudeComment, body: "note",
                          changes: [.init(paragraphId: "ab2c", prior: "text", next: "text")])
        let withdraw = op("01B", kind: .annotationWithdraw, source: "01A")
        let reopen = op("01C", kind: .annotationReopen, source: "01A")
        // Withdraw alone drops it:
        XCTAssertTrue(AnnotationDeriver.derive(ops: [creation, withdraw],
                                               paragraphs: ["ab2c": "text"]).isEmpty)
        // Reopen newer than withdraw cancels the withdrawal:
        let derived = AnnotationDeriver.derive(ops: [creation, withdraw, reopen],
                                               paragraphs: ["ab2c": "text"])
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.status, .open)
    }

    func test_reopen_neverAppliesToManuscript() {
        // The derive loop only folds op.changes; annotationReopen always has [].
        // Guard the classification so a future change can't make it text-mutating.
        XCTAssertFalse(Deriver.appliesToManuscript(.annotationReopen))
    }
}
```

Note: if `Annotation`'s field for the reply is not named `userResponse`, or `Deriver.appliesToManuscript` is not a public static, check the neighboring tests (`AcceptRevertOpTests.swift`, `AnnotationEditWithdrawTests.swift`) for the accessor they use and match it. If `appliesToManuscript` is internal, the test is still valid via `@testable import`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/AnnotationReopenOpTests`
Expected: compile FAILURE — `annotationReopen` / `undoRewind` don't exist.

- [ ] **Step 3: Implement**

In `OpKind.swift`, after the `annotationWithdraw` case (line 38), add with a doc comment in the file's established voice:

```swift
    /// Reopens a resolved annotation: the compensating inverse of
    /// `claudeReject` / `claudeArchive` / `annotationWithdraw`. References the
    /// creation op via `provenance.sourceAnnotationId`. Carries NO `changes`
    /// (never applies to the manuscript — an accepted suggestion's text
    /// reversal always goes through `claudeAcceptRevert` instead). The log
    /// stays append-only; earlier resolutions are never mutated.
    case annotationReopen = "annotation_reopen"
```

In `SynthesisSource.swift`, after `case rewind` (line 12):

```swift
    /// Ops synthesized by ⌘Z-undoing a History Rewind restore (or another
    /// compound undo that rebuilds document state): the restore-back plus its
    /// lifecycle compensations. Distinct from `.rewind` so HistoryPane can
    /// tell "the writer rewound" from "the writer undid a rewind".
    case undoRewind = "undo_rewind"
```

In `ProjectManifest.swift:29`: `public static let currentSchemaVersion = 3`.

In `AnnotationDeriver.swift`:
1. `isLifecycleKind` (lines 132–137): add `.annotationReopen` to the `return true` case list.
2. `resolution(creation:lifecycle:)` (lines 139–157): extend the existing `claudeAcceptRevert` special case:
```swift
        if lifecycle.kind == .claudeAcceptRevert || lifecycle.kind == .annotationReopen {
            return (.open, creation.provenance?.userResponse, nil)
        }
```
3. Withdraw indexing (lines 26–42): replace the `withdrawn: Set<String>` build with latest-wins between withdraw and reopen:
```swift
        var withdrawState: [String: Op] = [:]
        for op in ops {
            guard op.kind == .annotationWithdraw || op.kind == .annotationReopen,
                  let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = withdrawState[src] {
                if op.opId > prior.opId { withdrawState[src] = op }
            } else {
                withdrawState[src] = op
            }
        }
        let withdrawn = Set(withdrawState.filter { $0.value.kind == .annotationWithdraw }.keys)
```
(Keep the existing `latestEdit` build untouched; keep the existing `withdrawn.contains` consumption at line 52.)

In `Deriver.swift`: the exhaustive switch(es) over `OpKind` (e.g. `appliesToManuscript`) now fail to compile — add `.annotationReopen` to the non-manuscript branch (same branch as `.claudeReject`/`.claudeArchive`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/AnnotationReopenOpTests`
Expected: PASS.

- [ ] **Step 5: Run the full Core + schema-tolerance suites (the bump touches them)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests`
Expected: PASS. If `SchemaEvolutionToleranceTests` pins the literal version `2`, update the pin to `3` — that test exists to force this conscious touch.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): annotationReopen op kind + undoRewind synthesis source (schema v3)"
```

---

### Task 2: Core — `AnnotationInverse` factory

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/AnnotationInverse.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AnnotationInverseTests.swift` (new)

**Interfaces:**
- Consumes: Task 1's `OpKind.annotationReopen`.
- Produces (exact API, later tasks call these):
```swift
public enum AnnotationInverse {
    public enum Decline: Equatable, Sendable {
        case noInverse(OpKind)          // e.g. .claudeAccept — use claudeAcceptRevert instead
        case stateDrifted               // current status no longer matches what's being undone
    }
    public enum Outcome { case op(Op), declined(Decline) }

    /// Compensating reopen for undoing a resolution. `currentStatus == nil`
    /// means the annotation is currently withdrawn (absent from projection).
    public static func reopenOp(
        undoing kind: OpKind,
        annotationId: String,
        currentStatus: AnnotationStatus?,
        docId: String, device: String, session: String,
        appVersion: String? = nil, osVersion: String? = nil
    ) -> Outcome

    /// Compensating edit for undoing an annotationEdit: another edit carrying
    /// the prior body (and prior suggested replacement, when present).
    public static func editRevertOp(
        annotationId: String,
        priorBody: String,
        priorSuggested: (paragraphId: String, prior: String?, next: String)?,
        authorSourceKind: String?, authorDisplayName: String?, authorCollaboratorId: String?,
        docId: String, device: String, session: String
    ) -> Op
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MaughamCore

final class AnnotationInverseTests: XCTestCase {

    func test_undoReject_currentRejected_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .rejected,
            docId: "d1", device: "mac", session: "s1")
        guard case .op(let op) = outcome else { return XCTFail("expected op") }
        XCTAssertEqual(op.kind, .annotationReopen)
        XCTAssertEqual(op.provenance?.sourceAnnotationId, "01A")
        XCTAssertTrue(op.changes.isEmpty)
        XCTAssertEqual(op.docId, "d1")
    }

    func test_undoArchive_currentArchived_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeArchive, annotationId: "01A", currentStatus: .archived,
            docId: "d1", device: "mac", session: "s1")
        guard case .op = outcome else { return XCTFail("expected op") }
    }

    func test_undoWithdraw_currentAbsent_producesReopen() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .annotationWithdraw, annotationId: "01A", currentStatus: nil,
            docId: "d1", device: "mac", session: "s1")
        guard case .op = outcome else { return XCTFail("expected op") }
    }

    func test_statusDrift_declines() {
        // Undoing a reject when the annotation is meanwhile .open (someone
        // else already reopened it) must decline, not double-reopen.
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .open,
            docId: "d1", device: "mac", session: "s1")
        guard case .declined(.stateDrifted) = outcome else { return XCTFail("expected drift decline") }
    }

    func test_undoAccept_declines_noInverse() {
        // Accept reversal is claudeAcceptRevert's job (v0.17.0), not reopen's.
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeAccept, annotationId: "01A", currentStatus: .accepted,
            docId: "d1", device: "mac", session: "s1")
        guard case .declined(.noInverse) = outcome else { return XCTFail("expected noInverse") }
    }

    func test_phoneForensicFields_carried() {
        let outcome = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .rejected,
            docId: "d1", device: "phone", session: "s1",
            appVersion: "0.5.0", osVersion: "iOS 19")
        guard case .op(let op) = outcome else { return XCTFail("expected op") }
        XCTAssertEqual(op.provenance?.appVersion, "0.5.0")
        XCTAssertEqual(op.provenance?.osVersion, "iOS 19")
    }

    func test_editRevert_carriesPriorBodyAndSuggestion() {
        let op = AnnotationInverse.editRevertOp(
            annotationId: "01A", priorBody: "old body",
            priorSuggested: (paragraphId: "ab2c", prior: "was", next: "old suggestion"),
            authorSourceKind: "human", authorDisplayName: "Denver", authorCollaboratorId: nil,
            docId: "d1", device: "mac", session: "s1")
        XCTAssertEqual(op.kind, .annotationEdit)
        XCTAssertEqual(op.provenance?.annotationBody, "old body")
        XCTAssertEqual(op.changes.first?.next, "old suggestion")
        XCTAssertEqual(op.provenance?.sourceAnnotationId, "01A")
    }

    func test_derivedRoundTrip_rejectThenFactoryReopen_isOpen() {
        let creation = Op(opId: "01A", docId: "d1", at: Date(timeIntervalSince1970: 1_000),
                          device: "mac", session: "s1", kind: .claudeComment,
                          changes: [.init(paragraphId: "ab2c", prior: "t", next: "t")],
                          sequence: nil,
                          provenance: Op.Provenance(sessionId: "s1", annotationBody: "n",
                                                    sourceAnnotationId: nil))
        let reject = Op(opId: "01B", docId: "d1", at: Date(timeIntervalSince1970: 1_001),
                        device: "mac", session: "s1", kind: .claudeReject, changes: [],
                        sequence: nil,
                        provenance: Op.Provenance(sessionId: "s1", sourceAnnotationId: "01A"))
        guard case .op(let reopen) = AnnotationInverse.reopenOp(
            undoing: .claudeReject, annotationId: "01A", currentStatus: .rejected,
            docId: "d1", device: "mac", session: "s1") else { return XCTFail() }
        let derived = AnnotationDeriver.derive(ops: [creation, reject, reopen],
                                               paragraphs: ["ab2c": "t"])
        XCTAssertEqual(derived.first?.status, .open)
    }
}
```

Adjust `Op.Provenance` initializer labels to the real memberwise init (all fields have defaults — see existing usage `Op.Provenance(sessionId: session, synthesisSource: .rewind, sourceAnnotationId: src)` in `Document+Rewind.swift:213-239`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/AnnotationInverseTests`
Expected: compile FAILURE — `AnnotationInverse` doesn't exist.

- [ ] **Step 3: Implement `AnnotationInverse.swift`**

```swift
import Foundation

/// The inverse-op factory for annotation lifecycle undo — the single place
/// that knows which compensating op undoes which resolution. Pure: no I/O,
/// no UndoManager (MaughamCore stays UndoManager-free). Consumed by the Mac
/// ⌘Z registrar AND the phone's Reopen action so neither reimplements the
/// decision (cross-surface contract, tripwire 19).
public enum AnnotationInverse {
    public enum Decline: Equatable, Sendable {
        case noInverse(OpKind)
        case stateDrifted
    }
    public enum Outcome { case op(Op), declined(Decline) }

    public static func reopenOp(
        undoing kind: OpKind,
        annotationId: String,
        currentStatus: AnnotationStatus?,
        docId: String, device: String, session: String,
        appVersion: String? = nil, osVersion: String? = nil
    ) -> Outcome {
        // Which resolutions have a reopen inverse, and what current status
        // each expects. Accept is deliberately excluded: its inverse is
        // claudeAcceptRevert (v0.17.0), which also restores text.
        let expected: AnnotationStatus?
        switch kind {
        case .claudeReject:       expected = .rejected
        case .claudeArchive:      expected = .archived
        case .annotationWithdraw: expected = nil   // withdrawn = absent from projection
        default:                  return .declined(.noInverse(kind))
        }
        guard currentStatus == expected else { return .declined(.stateDrifted) }
        return .op(Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationReopen, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: annotationId,
                appVersion: appVersion,
                osVersion: osVersion)))
    }

    public static func editRevertOp(
        annotationId: String,
        priorBody: String,
        priorSuggested: (paragraphId: String, prior: String?, next: String)?,
        authorSourceKind: String?, authorDisplayName: String?, authorCollaboratorId: String?,
        docId: String, device: String, session: String
    ) -> Op {
        let changes: [Op.ParagraphChange] = priorSuggested.map {
            [.init(paragraphId: $0.paragraphId, prior: $0.prior, next: $0.next)]
        } ?? []
        return Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationEdit, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                annotationBody: priorBody,
                sourceAnnotationId: annotationId,
                authorSourceKind: authorSourceKind,
                authorDisplayName: authorDisplayName,
                authorCollaboratorId: authorCollaboratorId))
    }
}
```

Match `Op.Provenance`'s real init labels/order (check `Op.swift` lines 33–142).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamCoreTests/AnnotationInverseTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(core): AnnotationInverse — shared inverse-op factory for lifecycle undo"
```

---

### Task 3: Mac — `OpUndoRegistrar` + reject/archive/withdraw/edit undo + `reopenAnnotation`

**Files:**
- Create: `Maugham/OpLog/OpUndoRegistrar.swift`
- Modify: `Maugham/OpLog/Document+Annotations.swift` (`rejectAnnotation:502`, `archiveAnnotation:511`, `editReviewerAnnotation:177`, `withdrawReviewerAnnotation:221`; add `reopenAnnotation`)
- Modify: `Maugham/Views/AnnotationsPane.swift` (reject call sites lines 281, 289; the archive call site nearby)
- Modify: `Maugham/Views/EditorHost.swift` (review handlers: `reviewRejectHandler:201`, `reviewEditHandler:213`, `reviewWithdrawHandler:220`)
- Modify: `Maugham/Views/HistoryPane.swift` + `Maugham/Views/RewindWindow.swift` (render the new op kind — mirror how commit `ddd5c9f` added `claudeAcceptRevert` rows; grep `claudeAcceptRevert` in `Maugham/Views/` and add a sibling label like "Reopened annotation")
- Test: `MaughamTests/AnnotationLifecycleUndoTests.swift` (new)

**Interfaces:**
- Consumes: `AnnotationInverse.reopenOp` / `.editRevertOp` (Task 2).
- Produces (later tasks call these):
```swift
// OpUndoRegistrar.swift
@MainActor
enum OpUndoRegistrar {
    /// Encodes the v0.17.0 accept-undo dance: synchronous nested registration
    /// so NSUndoManager routes the redo correctly; the mutations themselves
    /// hop to async tasks. `workTaskSink` receives the hop task so tests can
    /// await completion (mirror: `Document._lastUndoWorkTask`).
    static func register<T: AnyObject>(
        _ um: UndoManager?, actionName: String, target: T,
        workTaskSink: ((Task<Void, Never>) -> Void)? = nil,
        undo: @escaping @MainActor (T) async -> Void,
        redo: @escaping @MainActor (T) async -> Void)
}
// Document+Annotations.swift additions
public func reopenAnnotation(id: String) async throws          // appends factory op; loud no-op on decline
// signature changes (added trailing param, default nil — source-compatible):
public func rejectAnnotation(id: String, userResponse: String? = nil, undoManager: UndoManager? = nil) async throws
public func archiveAnnotation(id: String, undoManager: UndoManager? = nil) async throws
public func editReviewerAnnotation(id:newBody:newSuggestedText:authorName:authorId:undoManager:) async throws
public func withdrawReviewerAnnotation(id:authorName:authorId:undoManager:) async throws
```

- [ ] **Step 1: Write the failing tests**

Mirror `MaughamTests/AnnotationAcceptUndoTests.swift` — copy its Document/fixture setup verbatim (it builds a real `Document` and an `UndoManager` with `groupsByEvent` defaults, and awaits `_lastUndoWorkTask`). Test cases:

```swift
// AnnotationLifecycleUndoTests.swift — setup copied from AnnotationAcceptUndoTests.
final class AnnotationLifecycleUndoTests: XCTestCase {

    func test_reject_undo_reopens() async throws {
        // fixture: doc with one comment annotation (creation op id CID)
        let um = UndoManager()
        try await doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um)
        XCTAssertEqual(try status(of: cid), .rejected)
        um.undo()
        await doc._lastUndoWorkTask?.value
        XCTAssertEqual(try status(of: cid), .open)
        // and the compensating op is in the log:
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)
    }

    func test_reject_undo_redo_reRejects_preservingUserResponse() async throws {
        let um = UndoManager()
        try await doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um)
        um.undo(); await doc._lastUndoWorkTask?.value
        um.redo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(try status(of: cid), .rejected)
        XCTAssertEqual(try userResponse(of: cid), "no")
    }

    func test_archive_undo_reopens() async throws { /* same shape, archiveAnnotation */ }

    func test_withdraw_undo_restoresAnnotation() async throws {
        let um = UndoManager()
        try await doc.withdrawReviewerAnnotation(id: cid, authorName: "Denver", undoManager: um)
        XCTAssertNil(try? status(of: cid))            // dropped from projection
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(try status(of: cid), .open)    // back
    }

    func test_edit_undo_restoresPriorBody() async throws {
        let um = UndoManager()
        try await doc.editReviewerAnnotation(id: cid, newBody: "new", newSuggestedText: nil,
                                             authorName: "Denver", undoManager: um)
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(try body(of: cid), originalBody)
        um.redo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(try body(of: cid), "new")
    }

    func test_reopen_onDriftedStatus_isLoudNoOp() async throws {
        // reject, then reopen once (simulating another device), then fire the
        // stale undo action: must not append a second reopen or crash.
        let um = UndoManager()
        try await doc.rejectAnnotation(id: cid, userResponse: nil, undoManager: um)
        try await doc.reopenAnnotation(id: cid)              // status now .open
        let opCount = doc._opLogMirror.count
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(doc._opLogMirror.count, opCount)      // declined, nothing appended
    }
}
```

(`status(of:)` / `body(of:)` helpers query `doc.annotations(AnnotationFilter(statuses: nil))` — the unfiltered query `revertAcceptedAnnotation` uses at `Document+Annotations.swift:418-423`; match the real accessor name found there.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/AnnotationLifecycleUndoTests`
Expected: compile FAILURE (no `undoManager:` params, no `reopenAnnotation`).

- [ ] **Step 3: Implement `OpUndoRegistrar.swift`**

```swift
import AppKit

/// One home for the NSUndoManager registration dance every op-log undo uses.
/// Pattern is v0.17.0's accept-undo (Document+Annotations.swift:292-366),
/// which is deliberately NOT refactored onto this helper — it carries extra
/// text-apply choreography and is regression-scarred. New registrations use
/// this; accept keeps its own.
@MainActor
enum OpUndoRegistrar {
    static func register<T: AnyObject>(
        _ um: UndoManager?, actionName: String, target: T,
        workTaskSink: ((Task<Void, Never>) -> Void)? = nil,
        undo: @escaping @MainActor (T) async -> Void,
        redo: @escaping @MainActor (T) async -> Void
    ) {
        guard let um, !um.isUndoing, !um.isRedoing else { return }
        um.registerUndo(withTarget: target) { [weak um] t in
            // Nested registration runs SYNCHRONOUSLY inside undo, so
            // NSUndoManager routes it to the REDO stack (same trick as
            // acceptAnnotation). The mutation itself hops to a task.
            if let um {
                um.registerUndo(withTarget: t) { t2 in
                    let task = Task { @MainActor in await redo(t2) }
                    workTaskSink?(task)
                }
                um.setActionName(actionName)
            }
            let task = Task { @MainActor in await undo(t) }
            workTaskSink?(task)
        }
        um.setActionName(actionName)
    }
}
```

If `Document._lastUndoWorkTask`'s type doesn't match `Task<Void, Never>` (check its declaration), adapt the sink type to it.

- [ ] **Step 4: Implement `reopenAnnotation` + registration in the four mutators**

In `Document+Annotations.swift`:

```swift
    /// Appends the compensating reopen for a rejected/archived/withdrawn
    /// annotation. Loud no-op (log + return) when the current derived status
    /// no longer matches — a stale ⌘Z after another device already acted.
    public func reopenAnnotation(id: String) async throws {
        let current = annotations(AnnotationFilter(statuses: nil)).first { $0.id == id }
        let undoneKind: OpKind
        switch current?.status {
        case .rejected: undoneKind = .claudeReject
        case .archived: undoneKind = .claudeArchive
        case nil:
            // Absent from projection — withdrawn iff the latest withdraw/reopen
            // op for this id is a withdraw; otherwise the id is unknown.
            let latest = _opLogMirror
                .filter { ($0.kind == .annotationWithdraw || $0.kind == .annotationReopen)
                          && $0.provenance?.sourceAnnotationId == id }
                .max { $0.opId < $1.opId }
            guard latest?.kind == .annotationWithdraw else {
                Log.oplog.info("reopenAnnotation: \(id) unknown or not withdrawn — no-op")
                return
            }
            undoneKind = .annotationWithdraw
        default:
            Log.oplog.info("reopenAnnotation: \(id) status drifted — no-op")
            return
        }
        guard case .op(let op) = AnnotationInverse.reopenOp(
            undoing: undoneKind, annotationId: id, currentStatus: current?.status,
            docId: docId, device: device, session: session) else {
            Log.oplog.info("reopenAnnotation: factory declined for \(id) — no-op")
            return
        }
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
    }
```

(Match the file's actual logging idiom — grep how `revertAcceptedAnnotation` logs its loud no-ops and use the same call.)

Add `undoManager: UndoManager? = nil` to `rejectAnnotation` and register after the successful append (these ops never touch manuscript text, so no `removeAllActions`/coherent-flag choreography is needed):

```swift
        // (existing body: appendLifecycleOp(kind: .claudeReject, ...))
        OpUndoRegistrar.register(undoManager, actionName: "Reject Annotation", target: self,
            workTaskSink: { self._lastUndoWorkTask = $0 },
            undo: { doc in try? await doc.reopenAnnotation(id: id) },
            redo: { doc in try? await doc.rejectAnnotation(id: id, userResponse: userResponse,
                                                           undoManager: nil) })
```

Same for `archiveAnnotation` ("Archive Annotation", redo → `archiveAnnotation(id:undoManager:nil)`), and `withdrawReviewerAnnotation` ("Withdraw Annotation", undo → `reopenAnnotation(id:)`, redo → `withdrawReviewerAnnotation(id:authorName:authorId:undoManager:nil)`).

For `editReviewerAnnotation`: BEFORE appending, capture the prior state from the current derived annotation (unfiltered query): `priorBody = current.body`, and for a suggestion the prior replacement (the derived suggested text — same field the pane displays). Register "Edit Annotation": undo appends `AnnotationInverse.editRevertOp(annotationId: id, priorBody: priorBody, priorSuggested: ..., authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue, authorDisplayName: authorName, authorCollaboratorId: authorId, docId: docId, device: device, session: session)` then invalidates caches (append via the same `opStore.append` + mirror pattern — add a tiny private `appendAnnotationOpInternal(_ op: Op)` if the repetition itches, used by reopen + edit-revert only); redo re-invokes `editReviewerAnnotation` with the new values and `undoManager: nil`.

- [ ] **Step 5: Wire the call sites**

- `AnnotationsPane.swift`: it already has `@Environment(\.undoManager)` (line 11). Pass `undoManager: undoManager` at the reject call sites (lines 281, 289) and the archive call site (grep `archiveAnnotation(` in the file).
- `EditorHost.swift`: the snapshot `let um = undoManager` at line 70 already exists for accept. Thread `um` into `reviewRejectHandler` (line 201→ `doc.rejectAnnotation(id: id, undoManager: um)`), `reviewEditHandler` (line 213), `reviewWithdrawHandler` (line 220).
- `HistoryPane.swift` / `RewindWindow.swift`: add display handling for `.annotationReopen` (label "Annotation reopened") wherever `.claudeAcceptRevert` got its row treatment in commit `ddd5c9f` — `git show ddd5c9f --stat` lists the exact spots.

- [ ] **Step 6: Run the new tests + the v0.17.0 pins**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/AnnotationLifecycleUndoTests -only-testing:MaughamTests/AnnotationAcceptUndoTests -only-testing:MaughamTests/Editor/EditorUndoStackClearTests`
Expected: PASS (accept-undo pins must stay green — untouched code, but the shared file changed).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(oplog): ⌘Z undo of annotation reject/archive/withdraw/edit via OpUndoRegistrar + reopenAnnotation"
```

---

### Task 4: Mac — `TaskInverse` + pane-task op undo

**Files:**
- Create: `Maugham/OpLog/TaskInverse.swift`
- Modify: `Maugham/OpLog/Document+Tasks.swift` (`createPaneTask:221`, `setTaskStatus:248`, `setTaskPriority:262`, `setTaskParent:276`, `editPaneTaskBody:293`, `archiveTask:307` — this task covers the OP side only; inline-archive text restore is Task 6)
- Modify: `Maugham/Stores/ProjectStore+Tasks.swift` (`createProjectPaneTask:36`)
- Test: `MaughamTests/TaskUndoTests.swift` (new)

**Interfaces:**
- Consumes: `OpUndoRegistrar` (Task 3), `WriterTask`/`TaskStatus` (`Maugham/OpLog/Task.swift`).
- Produces:
```swift
// TaskInverse.swift
public enum TaskInverse {
    /// Inverse op for a task mutation, built from the PRE-mutation snapshot.
    /// Task ops carry only NEW values (no priors on Op.Provenance), so the
    /// prior must be captured from derived state at mutation time.
    /// Returns nil for kinds with no op-level inverse.
    public static func inverse(
        undoing kind: OpKind, prior: WriterTask,
        docId: String, device: String, session: String, sessionId: String?
    ) -> Op?
}
// Document+Tasks.swift — all six mutators gain `undoManager: UndoManager? = nil`
// ProjectStore+Tasks.swift:
public func createProjectPaneTask(body: String, parentTaskId: String? = nil,
                                  undoManager: UndoManager? = nil) -> WriterTask
```

- [ ] **Step 1: Write the failing tests**

Mirror `MaughamTests/TaskDeriverTests.swift`'s `makeOp` helper style for pure factory tests, and `MaughamTests/DocumentTasksTests.swift`'s fixture for Document-level tests.

```swift
final class TaskUndoTests: XCTestCase {

    // — TaskInverse pure factory —

    func test_inverse_statusChange_carriesPriorStatus() {
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0)
        let op = TaskInverse.inverse(undoing: .taskStatusChange, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskStatusChange)
        XCTAssertEqual(op?.provenance?.taskStatus, "open")
        XCTAssertEqual(op?.provenance?.taskId, "t1")
    }

    func test_inverse_priorityChange_carriesPriorPriority() { /* .taskPriorityChange → taskPriority == 3.0 */ }

    func test_inverse_parentChange_nilPrior_emitsClearSentinel() {
        // TaskDeriver treats "" as clear-parent (Document+Tasks.swift:276 convention)
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0, parentTaskId: nil)
        let op = TaskInverse.inverse(undoing: .taskParentChange, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.provenance?.taskParentId, "")
    }

    func test_inverse_bodyEdit_carriesPriorBody() { /* .taskBodyEdit → taskBody == prior.body */ }

    func test_inverse_create_isArchive_carryingBodyAndKind() {
        // archiveTask's convention: taskArchive carries taskBody + taskKind (Document+Tasks.swift:307)
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0, kind: .paneCreated)
        let op = TaskInverse.inverse(undoing: .taskCreate, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskArchive)
        XCTAssertEqual(op?.provenance?.taskKind, "pane_created")
    }

    func test_inverse_archive_isStatusChange_toPriorStatus() {
        let prior = makeWriterTask(id: "t1", status: .done, priority: 3.0)
        let op = TaskInverse.inverse(undoing: .taskArchive, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskStatusChange)
        XCTAssertEqual(op?.provenance?.taskStatus, "done")
    }

    func test_deriveRoundTrip_forwardPlusInverse_returnsToBaseline() {
        // build: create op → status op (done) → inverse (open); derive; status == .open
        // reuse TaskDeriverTests.makeOp; ids "t1"; assert derived task status.
    }

    // — Document-level NSUndoManager integration —

    func test_setTaskStatus_undo_restoresPriorStatus() async throws {
        // fixture doc + pane task created via doc.createPaneTask
        let um = UndoManager()
        doc.setTaskStatus(id: task.id, status: .done, undoManager: um)
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(currentStatus(task.id), .open)
        um.redo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(currentStatus(task.id), .done)
    }

    func test_createPaneTask_undo_archives() async throws { /* create → ⌘Z → derived status .archived */ }

    func test_undo_onVanishedTask_isLoudNoOp() async throws {
        // register undo for a status change, archive the task out from under it,
        // fire undo: mirror count unchanged beyond the archive — guard declined.
    }
}
```

(`makeWriterTask` is a local helper constructing `WriterTask` with the memberwise init — all fields per `Task.swift:27-53`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TaskUndoTests`
Expected: compile FAILURE.

- [ ] **Step 3: Implement `TaskInverse.swift`**

```swift
import Foundation
import MaughamCore

/// Inverse-op factory for task undo — Mac-side sibling of MaughamCore's
/// AnnotationInverse (task types are Mac-only; the phone has no tasks
/// surface). Pure function; the caller captures `prior` from derived state
/// BEFORE the forward mutation, because task ops carry only new values.
public enum TaskInverse {
    public static func inverse(
        undoing kind: OpKind, prior: WriterTask,
        docId: String, device: String, session: String, sessionId: String?
    ) -> Op? {
        var provenance = Op.Provenance(sessionId: sessionId, taskId: prior.id)
        let inverseKind: OpKind
        switch kind {
        case .taskStatusChange:
            inverseKind = .taskStatusChange
            provenance.taskStatus = prior.status.rawValue
        case .taskPriorityChange:
            inverseKind = .taskPriorityChange
            provenance.taskPriority = prior.priority
        case .taskParentChange:
            inverseKind = .taskParentChange
            provenance.taskParentId = prior.parentTaskId ?? ""   // "" = clear sentinel
        case .taskBodyEdit:
            inverseKind = .taskBodyEdit
            provenance.taskBody = prior.body
        case .taskCreate:
            inverseKind = .taskArchive
            provenance.taskBody = prior.body
            provenance.taskKind = prior.kind.rawValue
        case .taskArchive:
            inverseKind = .taskStatusChange
            provenance.taskStatus = prior.status.rawValue
        default:
            return nil
        }
        return Op(opId: ULID.generate(), docId: docId, at: Date(),
                  device: device, session: session,
                  kind: inverseKind, changes: [], sequence: nil,
                  provenance: provenance)
    }
}
```

If `Op.Provenance` fields are `let` (immutable), build the provenance in one init per case instead of mutating.

- [ ] **Step 4: Add capture + registration to the six mutators**

Pattern for each `Document+Tasks.swift` mutator (shown for `setTaskStatus`; the others are the same shape with their own action names):

```swift
    public func setTaskStatus(id: String, status: TaskStatus, undoManager: UndoManager? = nil) {
        // Capture the pre-mutation snapshot the inverse needs (task ops carry
        // only new values). Same _tasksCache read archiveTask already does.
        let prior = _tasksCache.first(where: { $0.id == id })
        // (existing body: build + appendTaskOpInternal the forward op)
        if let prior,
           let inverse = TaskInverse.inverse(undoing: .taskStatusChange, prior: prior,
                                             docId: docId, device: device,
                                             session: session, sessionId: session) {
            OpUndoRegistrar.register(undoManager, actionName: "Change Task Status", target: self,
                workTaskSink: { self._lastUndoWorkTask = $0 },
                undo: { doc in
                    // Fire-time guard: the task must still exist and still hold
                    // the value the forward mutation wrote; else loud no-op.
                    guard let now = doc._tasksCache.first(where: { $0.id == id }),
                          now.status == status else { return }
                    doc.appendTaskOpInternal(inverse)
                },
                redo: { doc in doc.setTaskStatus(id: id, status: status, undoManager: undoManager) })
        }
    }
```

Note on the capture: `archiveTask` (line 307) reads `_tasksCache` directly, so the precedent is established — but if `_tasksCache` can be nil/stale at this point, first call the same cache-populating accessor `TasksPane` uses to list tasks (grep the file for where `_tasksCache` is filled and mirror). `appendTaskOpInternal` (line 192) may need `internal` visibility for the closure — it's the same file/extension, so it's already reachable.

Action names: `setTaskStatus` "Change Task Status" · `setTaskPriority` "Reorder Task" · `setTaskParent` "Nest Task" · `editPaneTaskBody` "Edit Task" · `createPaneTask` "New Task" (capture is the returned preview `WriterTask`; undo appends the archive inverse; redo re-creates — note redo mints a NEW task id, which is acceptable and should be asserted in a test comment) · `archiveTask` "Archive Task" (op-side only here; for `.paneCreated` tasks this is complete — inline text restore lands in Task 6).

`ProjectStore+Tasks.swift` `createProjectPaneTask`: same registration with `target: self` (ProjectStore), undo → `self.appendProjectTaskOp(inverse)` (line 73), redo → `self.createProjectPaneTask(body:parentTaskId:undoManager:)`. ProjectStore has no `_lastUndoWorkTask`; add one (`var _lastUndoWorkTask: Task<Void, Never>?`) for test awaiting.

- [ ] **Step 5: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TaskUndoTests -only-testing:MaughamTests/TaskDeriverTests -only-testing:MaughamTests/DocumentTasksTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(oplog): TaskInverse + ⌘Z undo of pane-task mutations"
```

---

### Task 5: Mac — TasksPane / editor wiring + inline checkbox toggle undo

**Files:**
- Modify: `Maugham/Views/TasksPane.swift` (`toggleStatus:306`, `archive:355`, `deleteIfPaneCreated:360`, `archiveAllDone:374`, `apply(intent:):509`, `commitNewTask:576`)
- Modify: `Maugham/Views/EditorHost.swift` (checkbox click handler, lines 134–149)
- Test: `MaughamTests/InlineTaskToggleUndoTests.swift` (new)

**Interfaces:**
- Consumes: Task 4's `undoManager:` params; `Document.setParagraph(id:text:)` (`Document.swift:740`); `flipInlineCheckbox` (`TasksPane.swift:606`), `flipFountainTodoDone` (`TasksPane.swift:625`); the undo-coherent apply flag (`_undoCoherentApplyPending`, set in `acceptAnnotation`, consumed by the editor update pass — grep `_undoCoherentApplyPending` for the exact plumbing).
- Produces: every TasksPane action and the editor checkbox click registers undo. Spec deviation honored: inline toggles are text-is-state (`setParagraph` → `.typingBurst`, NO task op — confirmed in `toggleStatus` and `EditorHost.swift:137`), so their undo is a guarded paragraph-text flip-back.

- [ ] **Step 1: Write the failing tests**

```swift
final class InlineTaskToggleUndoTests: XCTestCase {
    // Fixture: real Document whose text contains "- [ ] buy milk" with a
    // 4-char ¶id anchor (use ParagraphID.mint() / Bootstrap fixture like
    // DocumentTasksTests does).

    func test_inlineToggle_undo_restoresUncheckedText() async throws {
        let um = UndoManager()
        // simulate the pane/editor toggle path:
        let prior = doc.paragraph(id: pid)!            // "- [ ] buy milk"
        let flipped = flipInlineCheckbox(prior)        // "- [x] buy milk"
        InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                 prior: prior, flipped: flipped, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), flipped)
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(doc.paragraph(id: pid), prior)
        um.redo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(doc.paragraph(id: pid), flipped)
    }

    func test_inlineToggle_undo_afterParagraphEdited_isLoudNoOp() async throws {
        let um = UndoManager()
        let prior = doc.paragraph(id: pid)!
        let flipped = flipInlineCheckbox(prior)
        InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                 prior: prior, flipped: flipped, undoManager: um)
        doc.setParagraph(id: pid, text: "- [x] buy oat milk")   // drift
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(doc.paragraph(id: pid), "- [x] buy oat milk")  // declined
    }
}
```

(`InlineToggleUndo` is the small helper defined in Step 3 — the test drives it directly so it doesn't need a SwiftUI harness. If `flipInlineCheckbox` is `private`, make it `internal` — `TasksPane.swift` already marks test-reached helpers `internal`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InlineTaskToggleUndoTests`
Expected: compile FAILURE (`InlineToggleUndo` doesn't exist).

- [ ] **Step 3: Implement `InlineToggleUndo` (in `Maugham/OpLog/OpUndoRegistrar.swift`, below the registrar)**

```swift
/// Undo for inline checkbox flips. Inline tasks are text-is-state (a toggle
/// is a plain setParagraph → .typingBurst, no task op), so undo is a guarded
/// flip-back of the paragraph text. The undo-coherent flag keeps the editor's
/// external apply from wiping the just-registered action (v0.17.0 D2 rule).
@MainActor
enum InlineToggleUndo {
    static func perform(on doc: Document, paragraphId: String,
                        prior: String, flipped: String, undoManager: UndoManager?) {
        doc._undoCoherentApplyPending = true          // match acceptAnnotation's flag use
        doc.setParagraph(id: paragraphId, text: flipped)
        OpUndoRegistrar.register(undoManager, actionName: "Toggle Checkbox", target: doc,
            workTaskSink: { doc._lastUndoWorkTask = $0 },
            undo: { d in
                guard d.paragraph(id: paragraphId) == flipped else { return }  // drift → no-op
                d._undoCoherentApplyPending = true
                d.setParagraph(id: paragraphId, text: prior)
            },
            redo: { d in
                guard d.paragraph(id: paragraphId) == prior else { return }
                InlineToggleUndo.perform(on: d, paragraphId: paragraphId,
                                         prior: prior, flipped: flipped, undoManager: undoManager)
            })
    }
}
```

IMPORTANT: verify the flag mechanics first — grep `_undoCoherentApplyPending` (set in `Document+Annotations.swift` accept path, discharged per commit `4ab8d85` "on every update pass"). If the flag is consumed via a different route (e.g. `applyExternalText(preserveUndoStack:)` driven from `EditorHost`), set whatever accept sets, in the same order accept sets it. The regression pin is Step 5's harness test.

- [ ] **Step 4: Wire the call sites**

- `TasksPane.swift`: add `@Environment(\.undoManager) private var undoManager`. In `toggleStatus` (line 306): `.paneCreated` branch → pass `undoManager:` to `setTaskStatus`; `.inlineMarkdown` / `.fountainBoneyard` branches → replace the bare `doc.setParagraph(...)` with `InlineToggleUndo.perform(on: doc, paragraphId: pid, prior: current, flipped: flipped, undoManager: undoManager)`. In `archive`/`deleteIfPaneCreated` → pass `undoManager:` to `archiveTask`. In `apply(intent:)` (line 509) → pass `undoManager:` to `setTaskParent`/`setTaskPriority`. In `commitNewTask` (line 576) → pass to `createPaneTask`/`createProjectPaneTask`.
- `archiveAllDone` (line 374): bulk — wrap the loop in `undoManager?.beginUndoGrouping()` / `undoManager?.endUndoGrouping()` and `undoManager?.setActionName("Archive Done Tasks")` so one ⌘Z reverses the batch; pass `undoManager:` to each `archiveTask`; the project-scope branch captures each task's inverse via `TaskInverse` and registers with `target: store`.
- `EditorHost.swift` checkbox handler (lines 134–149): replace the bare `doc.setParagraph(id:text:)` with `InlineToggleUndo.perform(..., undoManager: um)` using the existing `um` snapshot (line 70).

- [ ] **Step 5: Add the interleaving harness test**

Append to `InlineTaskToggleUndoTests` (or `EditorIntegrationHarnessTests` if the fixture fits better there — it owns the editor-binding regression pins):

```swift
    func test_type_toggle_type_undoWalksBackInOrder_noCrash() async throws {
        // 1. typing-built undo state (simulate a keystroke via the harness's
        //    established typing path), 2. InlineToggleUndo.perform, 3. more
        //    typing, 4. ⌘Z ×3: last typing undone (native), toggle undone
        //    (op), first typing undone (native) — assert text at each step,
        //    and no fault (the B3 class). Mirror EditorUndoStackClearTests'
        //    harness setup for the NSTextView + coordinator pair.
    }
```

- [ ] **Step 6: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InlineTaskToggleUndoTests -only-testing:MaughamTests/Editor/EditorUndoStackClearTests -only-testing:MaughamTests/Integration/TasksPaneIntegrationTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(tasks): ⌘Z undo for inline checkbox toggles + TasksPane undo wiring"
```

---

### Task 6: Mac — inline-archive undo (compound: status + text restore)

**Files:**
- Modify: `Maugham/OpLog/Document+Tasks.swift` (`archiveTask:307`)
- Modify: `Maugham/OpLog/Document+Rewind.swift` (extract the append/fold core into a reusable helper)
- Test: `MaughamTests/InlineArchiveUndoTests.swift` (new)

**Interfaces:**
- Consumes: `Restore.buildRestoreOp(current:target:scope:docId:device:session:sourceCheckpoint:synthesisSource:)` (`Maugham/OpLog/Restore.swift:13-22`), `Deriver.derive(ops:)`, `TaskInverse` (Task 4), `SynthesisSource.undoRewind` (Task 1).
- Produces:
```swift
// Document+Rewind.swift — extracted from restoreToOp's L52-141 core, reused by
// restoreToOp itself and by compound undos that must rebuild document state:
internal func applyRestore(target: Deriver.DerivedState, sourceCheckpoint: String,
                           synthesisSource: SynthesisSource) async throws -> Op?
```

Why: archiving an INLINE task is compound — a `.taskArchive` op PLUS a paragraph rewrite or delete (`spliceArchivedTask` → `setParagraph`/`deleteParagraph`). Restoring text needs to handle the deleted-paragraph case, which means re-inserting into `sequence` — exactly what `Restore.buildRestoreOp` already does correctly. Reuse it rather than inventing paragraph re-insertion.

- [ ] **Step 1: Write the failing tests**

```swift
final class InlineArchiveUndoTests: XCTestCase {
    // Fixtures: (a) doc where the inline task shares a paragraph with other
    // text (archive rewrites), (b) doc where the paragraph IS the task
    // (archive deletes the paragraph). 4-char ¶ids via Bootstrap fixture.

    func test_inlineArchive_undo_restoresParagraphAndOpenStatus() async throws {
        let um = UndoManager()
        doc.archiveTask(id: inlineTaskId, undoManager: um)
        XCTAssertNil(doc.paragraph(id: pid))                    // deleted case
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(doc.paragraph(id: pid), originalText)    // paragraph back
        XCTAssertEqual(derivedStatus(inlineTaskId), .open)      // status override countered
    }

    func test_inlineArchive_undo_redo_reArchives() async throws { /* undo then redo → archived + text gone again */ }

    func test_inlineArchive_undo_afterForeignOp_isLoudNoOp() async throws {
        // archive, then append an external_edit-style op changing another
        // paragraph (simulating a cross-device merge), then undo:
        // guard declines (document state advanced beyond our capture).
    }

    func test_paneArchive_stillSimple() async throws {
        // .paneCreated archive keeps Task 4's op-only undo (no text machinery).
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InlineArchiveUndoTests`
Expected: FAIL (undo restores nothing yet / helper missing).

- [ ] **Step 3: Extract `applyRestore` in `Document+Rewind.swift`**

Pure extraction of `restoreToOp`'s existing L52–141 core (build via `Restore.buildRestoreOp` → pure-deletion fallback → stamp `sequence` → `opStore.append` + mirror → fold into `paragraphs`/`sequence` → `recomputeDisplayText()` → invalidate caches), parameterized by `target: Deriver.DerivedState`, `sourceCheckpoint: String`, `synthesisSource: SynthesisSource`. `restoreToOp` then calls it with `(targetState, targetOpId, .rewind)`. NO behavior change — the existing `RewindRestoreResult` tests (`TaskRewindTests`, the B4 pins) must stay green, which is the extraction's acceptance gate.

- [ ] **Step 4: Compound capture + undo in `archiveTask`**

In `archiveTask(id:undoManager:)`, for the inline branch (after the existing capture `archived = _tasksCache.first(...)`), BEFORE the text splice:

```swift
        // Compound undo capture: the inline archive is a task op + a text
        // mutation, so the undo must restore both. Capture the full derived
        // state (cheap: user-action frequency, not keystroke frequency) and
        // the pre-archive tip for the restore op's sourceCheckpoint.
        let preState = Deriver.derive(ops: _opLogMirror)
        let preTip = _opLogMirror.last?.opId
```

After the forward mutation completes, register (only when both captures and `archived` exist):

```swift
        OpUndoRegistrar.register(undoManager, actionName: "Archive Task", target: self,
            workTaskSink: { self._lastUndoWorkTask = $0 },
            undo: { doc in
                // Guard: no foreign ops may have advanced the doc past our own
                // appended ops (archive op + splice burst). Every op after the
                // captured tip must be ours (device+session match).
                let appended = doc._opLogMirror.drop(while: { $0.opId != preTip }).dropFirst()
                guard appended.allSatisfy({ $0.device == doc.device && $0.session == doc.session })
                else { return }   // loud no-op: log via the file's idiom
                // 1. text back (handles the deleted-paragraph case via sequence):
                _ = try? await doc.applyRestore(target: preState,
                                                sourceCheckpoint: preTip ?? "",
                                                synthesisSource: .undoRewind)
                // 2. counter the archive's status override (the deriver folds
                //    later ops over earlier, so a fresh statusChange wins):
                if let inverse = TaskInverse.inverse(undoing: .taskArchive, prior: archived,
                                                     docId: doc.docId, device: doc.device,
                                                     session: doc.session, sessionId: doc.session) {
                    doc.appendTaskOpInternal(inverse)
                }
            },
            redo: { doc in doc.archiveTask(id: id, undoManager: undoManager) })
```

Also set the undo-coherent flag before `applyRestore`'s text application (same rule as Task 5) so the editor push doesn't wipe the stack mid-undo.

Note: this REPLACES Task 4's simpler op-only registration inside `archiveTask` for the inline branch; the `.paneCreated` branch keeps Task 4's version. Structure the function so the two branches register their own shapes.

- [ ] **Step 5: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/InlineArchiveUndoTests -only-testing:MaughamTests/TaskRewindTests -only-testing:MaughamTests/DocumentArchiveTextMutationTests`
Expected: PASS (including the untouched rewind pins — the extraction gate).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(tasks): compound ⌘Z undo of inline-task archive via extracted applyRestore"
```

---

### Task 7: Mac — rewind-undo

**Files:**
- Create: `Maugham/OpLog/Document+RewindUndo.swift`
- Modify: `Maugham/OpLog/Document+Rewind.swift` (add `synthesisSource` passthrough param to `restoreToOp`, default `.rewind`)
- Modify: `Maugham/Views/ProjectWindow.swift` (rewindSheet call site, lines 1195–1199; add `@Environment(\.undoManager)`)
- Test: `MaughamTests/RewindUndoTests.swift` (new)

**Interfaces:**
- Consumes: `restoreToOp(opId:) -> RewindRestoreResult` and its result fields (`restoreOp`, `reopenedAnnotationOpIds` — creation-op ids, `archivedAnnotationOpIds` — archive OP ids, `removedParagraphIds`); `currentFoldBasis` (`Document.swift:335`, internal — same target, reachable); `reopenAnnotation` (Task 3); `appendLifecycleOp` (`Document+Annotations.swift:520` — change `private` → `internal` for cross-file use within the target).
- Produces:
```swift
public func restoreToOpUndoable(opId: String, undoManager: UndoManager?) async throws -> RewindRestoreResult
```

- [ ] **Step 1: Write the failing tests**

```swift
final class RewindUndoTests: XCTestCase {
    // Fixture: doc with ops: create suggestion → accept (text applied) →
    // typing burst — then restore to before the accept.

    func test_restore_undo_returnsTextAndStatusesToPreRestoreState() async throws {
        let um = UndoManager()
        let preParagraphs = doc.paragraphs
        let preStatus = derivedStatus(annotationId)              // .accepted
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)
        XCTAssertNotEqual(doc.paragraphs, preParagraphs)         // rewound
        XCTAssertEqual(derivedStatus(annotationId), .open)      // D3 reopened
        um.undo(); await doc._lastUndoWorkTask?.value
        XCTAssertEqual(doc.paragraphs, preParagraphs)            // text back
        XCTAssertEqual(derivedStatus(annotationId), preStatus)  // re-accepted
        // and the re-accept preserved the original userResponse:
        XCTAssertEqual(derivedUserResponse(annotationId), originalUserResponse)
    }

    func test_restore_undo_reopensSweepArchivedAnnotations() async throws {
        // Fixture where the rewind REMOVES a paragraph carrying an open
        // annotation (orphan sweep archives it). Undo → paragraph back →
        // annotation derives .open again.
    }

    func test_restore_undo_redo_reRunsRestore() async throws {
        // undo then redo: doc equals the post-restore state again (fresh
        // restoreToOp run, not a replay).
    }

    func test_restore_undo_afterForeignOps_isLoudNoOp() async throws {
        // restore, then append a foreign-device op, then undo: paragraphs
        // unchanged (guard declined), no crash.
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RewindUndoTests`
Expected: compile FAILURE.

- [ ] **Step 3: Implement `Document+RewindUndo.swift`**

```swift
import AppKit
import MaughamCore

extension Document {
    /// restoreToOp + a single grouped ⌘Z action that reverses the whole
    /// rewind: text back to the pre-restore tip, D3-reopened accepts
    /// re-accepted (status-only, preserving each original userResponse),
    /// sweep-archived annotations reopened. Redo re-runs restoreToOp from
    /// scratch so it can never disagree with a fresh rewind.
    public func restoreToOpUndoable(
        opId targetOpId: String, undoManager: UndoManager?
    ) async throws -> RewindRestoreResult {
        // — capture BEFORE —
        let preTip = currentFoldBasis
        // Original userResponse per reopened accept, keyed by creation id:
        var acceptResponses: [String: String?] = [:]
        for op in _opLogMirror where op.kind == .claudeAccept {
            if let src = op.provenance?.sourceAnnotationId {
                acceptResponses[src] = op.provenance?.userResponse
            }
        }
        // A restore replaces the buffer, which makes stale typing actions
        // unsound: clear first, register after (accept's D1/D2 ordering).
        if let um = undoManager, !um.isUndoing, !um.isRedoing { um.removeAllActions() }
        _undoCoherentApplyPending = true

        let result = try await restoreToOp(opId: targetOpId)
        guard result.restoreOp != nil, let preTip else { return result }

        // — capture AFTER (for the fire-time guard) —
        let postParagraphs = paragraphs
        let reopened = result.reopenedAnnotationOpIds
        // archivedAnnotationOpIds are the appended claudeArchive OP ids;
        // resolve each to its annotation (creation) id for reopening:
        let sweepArchivedAnnotationIds: [String] = result.archivedAnnotationOpIds.compactMap { aid in
            _opLogMirror.first(where: { $0.opId == aid })?.provenance?.sourceAnnotationId
        }

        OpUndoRegistrar.register(undoManager, actionName: "Restore from History", target: self,
            workTaskSink: { self._lastUndoWorkTask = $0 },
            undo: { doc in
                // Guard: current text must equal the post-restore state (native
                // typing actions above us already unwound; anything else —
                // a cross-device merge — means decline, History Rewind is the
                // tool for that tangle).
                guard doc.paragraphs == postParagraphs else { return }
                doc._undoCoherentApplyPending = true
                _ = try? await doc.restoreToOp(opId: preTip, synthesisSource: .undoRewind)
                for src in reopened {
                    // status-only re-accept, mirror of D3's empty-changes revert:
                    try? await doc.appendLifecycleOp(kind: .claudeAccept,
                                                     sourceAnnotationId: src,
                                                     userResponse: acceptResponses[src] ?? nil,
                                                     synthesisSource: .undoRewind)
                }
                for src in sweepArchivedAnnotationIds {
                    try? await doc.reopenAnnotation(id: src)
                }
            },
            redo: { doc in
                _ = try? await doc.restoreToOpUndoable(opId: targetOpId, undoManager: undoManager)
            })
        return result
    }
}
```

Supporting changes:
- `restoreToOp` gains `synthesisSource: SynthesisSource = .rewind` and threads it to `Restore.buildRestoreOp` / the fallback op constructions / `SweepReason` cause (grep `.rewind` inside `Document+Rewind.swift` and thread the param; the default keeps every existing caller and test identical).
- `appendLifecycleOp` (`Document+Annotations.swift:520`): `private` → `internal`; verify its parameter list matches (it already takes `synthesisSource` — the orphan sweep uses it).
- Check `appendLifecycleOp`'s reachability of the D3 semantic: a `claudeAccept` with empty changes derives `.accepted` (deriver folds only `changes`) — this is asserted by Step 1's first test.

- [ ] **Step 4: Wire ProjectWindow**

`ProjectWindow.swift`: add `@Environment(\.undoManager) private var undoManager` and snapshot it before the escaping closure (the `let um = undoManager` idiom from `EditorHost.swift:70`). Replace the L1195–1199 call:

```swift
case .restoreHere(let opId):
    let um = undoManager
    Task { @MainActor in
        _ = try? await documentStore.document(forDocId: docId)?
            .restoreToOpUndoable(opId: opId, undoManager: um)
    }
```

CAUTION: `ProjectWindow.body` is at the SwiftUI type-checker ceiling — if the compile slows or fails to type-check, put the change inside the existing extracted `rewindSheet` helper only (it already is a separate `var`), and do NOT add new inline closures to `body` itself. This change triggers the Release-build gate in Task 9.

- [ ] **Step 5: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RewindUndoTests -only-testing:MaughamTests/TaskRewindTests`
Expected: PASS. Also re-run the B4 pins (grep for the rewind-reopen tests added in v0.17.0, e.g. in `MaughamTests` matching `Rewind.*Reopen|reopen.*rewind`).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(rewind): ⌘Z undo of History Rewind restore — grouped compensating restore + lifecycle re-accepts"
```

---

### Task 8: Phone — Reopen on resolved annotations

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationWriter.swift` (add `makeReopen`/`makeAcceptRevert` + async wrappers)
- Modify: `MaughamPhone/Annotations/AnnotationDetailView.swift` (Reopen affordance in the resolved region, lines 91–104 / 237–271; drift-confirm dialog)
- Test: `MaughamPhoneTests/PhoneAnnotationReopenTests.swift` (new)

**Interfaces:**
- Consumes: `AnnotationInverse` (Task 2, via MaughamCore); `AnnotationWriter.makeLifecycleOp` pattern (`AnnotationWriter.swift:139-163`); the detail view's `rederive()` (lines 415–427) which already loads the doc's ops.
- Produces:
```swift
// AnnotationWriter.swift
func makeReopen(for annotation: Annotation) throws -> Op
/// Full revert of an accepted suggestion — same behavior as Mac's pane
/// Revert: restores pre-accept text AND reopens (user decision 2026-07-09).
func makeAcceptRevert(for annotation: Annotation, acceptOp: Op, currentParagraph: String?) throws -> Op
@discardableResult func reopen(_ annotation: Annotation) async throws -> Op
@discardableResult func revertAccept(_ annotation: Annotation, acceptOp: Op, currentParagraph: String?) async throws -> Op
```

- [ ] **Step 1: Write the failing tests**

Mirror `MaughamPhoneTests/PhoneAnnotationIntegrationTests.swift` (real JSONL round-trips through `OpLogStore.load` → `AnnotationDeriver`):

```swift
final class PhoneAnnotationReopenTests: XCTestCase {

    func test_phoneReopen_ofRejected_derivesOpen_roundTrip() async throws {
        // seed: creation + claudeReject ops on disk → writer.reopen(annotation)
        // → OpLogStore.load → derive → status .open; op kind == .annotationReopen;
        // provenance carries phone forensic appVersion/osVersion (the
        // AnnotationWriter stamping convention).
    }

    func test_phoneReopen_ofArchived_derivesOpen_roundTrip() async throws { /* same, claudeArchive */ }

    func test_phoneRevertAccept_restoresTextAndReopens_roundTrip() async throws {
        // seed: suggestion creation + claudeAccept-with-changes (accepted text
        // applied) → writer.revertAccept(annotation, acceptOp:, currentParagraph:)
        // → derive: paragraph text == pre-accept, status .open. Mirrors the Mac
        // fixture in test_macAcceptRevertWithChanges_phoneReadsBack (same file
        // neighborhood) but the PHONE writes the op.
    }

    func test_phoneReopen_ofOpen_throwsOrDeclines() async throws {
        // status drift: factory declines → writer surfaces WriteError (assert
        // no op appended to the stream).
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/PhoneAnnotationReopenTests`
Expected: compile FAILURE.

- [ ] **Step 3: Implement the writer methods**

In `AnnotationWriter.swift` (mirror `makeLifecycleOp`'s stamping — docId/device/session and the forensic `appVersion`/`osVersion` fields the phone populates):

```swift
    /// Reopen a rejected/archived annotation. The inverse DECISION lives in
    /// MaughamCore.AnnotationInverse (cross-surface contract, tripwire 19);
    /// this only adds the phone's write-path stamping.
    func makeReopen(for annotation: Annotation) throws -> Op {
        let undone: OpKind
        switch annotation.status {
        case .rejected: undone = .claudeReject
        case .archived: undone = .claudeArchive
        default: throw WriteError.notReopenable
        }
        guard case .op(let op) = AnnotationInverse.reopenOp(
            undoing: undone, annotationId: annotation.id,
            currentStatus: annotation.status,
            docId: annotation.docId, device: deviceSlug, session: sessionId,
            appVersion: appVersion, osVersion: osVersion) else {
            throw WriteError.notReopenable
        }
        return op
    }

    /// Full revert of an accepted suggestion (Mac Revert parity): text back
    /// to pre-accept + status .open, via claudeAcceptRevert WITH changes.
    func makeAcceptRevert(for annotation: Annotation, acceptOp: Op,
                          currentParagraph: String?) throws -> Op {
        guard let change = acceptOp.changes.first else { throw WriteError.malformedSuggestion }
        let restored = change.prior ?? ""
        return Op(opId: ULID.generate(), docId: annotation.docId, at: Date(),
                  device: deviceSlug, session: sessionId,
                  kind: .claudeAcceptRevert,
                  changes: [.init(paragraphId: change.paragraphId,
                                  prior: currentParagraph, next: restored)],
                  sequence: nil,
                  provenance: Op.Provenance(sessionId: sessionId,
                                            sourceAnnotationId: annotation.id,
                                            appVersion: appVersion,
                                            osVersion: osVersion))
    }
```

Adapt property names (`deviceSlug`/`sessionId`/`appVersion`/`osVersion`) to what `makeLifecycleOp` actually uses — copy its stamping verbatim. Add the two `WriteError` cases and the async append wrappers following the existing `accept/reject/archive` wrapper shape (lines 167–180). Mac's revert semantics reference: `revertAcceptedAnnotation`, `Document+Annotations.swift:439-442` (`prior: currentText, next: acceptChange.prior ?? ""`).

- [ ] **Step 4: Implement the detail-view affordance**

In `AnnotationDetailView.swift`, in the resolved region (where `resolvedNotice`/read-only branches render, lines 91–104 / 280–305):
- Rejected/archived (from the local re-derive — `rederive()` already computes fresh status): a `Reopen` button → `writer.reopen(current)` → refresh (`rederive()` again).
- Accepted suggestion: a `Reopen & Revert` button. Drift check first: locate the latest `claudeAccept` op for this annotation in the ops `rederive()` loaded; if `currentParagraphText != acceptOp.changes.first?.next` → `confirmationDialog("The paragraph has changed since this was accepted. Revert anyway?")` before calling `writer.revertAccept(current, acceptOp: acceptOp, currentParagraph: currentParagraphText)`. (Mac parity: `acceptedTextDrifted`, `Document+Annotations.swift:381` + `AnnotationsPane.revert` lines 305–311.)
- Reuse the existing `runWrite` re-entrancy guard (lines 389–403) for both actions.
- Face-ID gate: reopen/revert are writes — route through the same gate the existing accept/reject/archive actions use (whatever wraps them in this view).

- [ ] **Step 5: Run the phone suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: PASS (full phone suite — the deriver change from Task 1 flows in via MaughamCore).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(phone): Reopen on resolved annotations — reject/archive reopen + accepted full revert"
```

---

### Task 9: Cross-surface round-trips, docs, full suites, Release gate

**Files:**
- Test: `MaughamPhoneTests/PhoneAnnotationIntegrationTests.swift` (extend), `MaughamTests/` (one Mac-side round-trip)
- Modify: `docs/superpowers/notes/cross-surface-contracts.md` (registry row)
- Modify: `docs/guide/` undo topic (grep `docs/guide/*.md` for the v0.17.0 undo section added in commit `24b22b6`) — cover: undo of reject/archive/edit/withdraw, task undo, checkbox-toggle undo, rewind undo, phone Reopen. Ships-not-planned rule: describe exactly what the branch does.
- Modify: `Maugham/MCP/` — NO tool changes; verify `add_suggested_change`/`list_annotations` descriptions don't contradict reopen (read, don't rewrite).

**Interfaces:** none new — this task is verification + documentation.

- [ ] **Step 1: Cross-surface round-trip tests**

In `PhoneAnnotationIntegrationTests.swift` add: `test_macReopen_phoneReadsBack_derivesOpen` (Mac-shaped `annotationReopen` op written to a Mac-style stream file → phone loads + derives `.open`). In a Mac test file add the mirror: phone-shaped reopen op (with forensic fields) in a phone-slug stream → Mac `Document.load` derives `.open` (mirror the existing cross-device fixture style in `CrossDeviceIntegrationTests` or the closest equivalent — grep `deviceSlug` in `MaughamTests` for the seeding pattern).

- [ ] **Step 2: Registry + guide docs**

- `cross-surface-contracts.md`: add a row for `annotationReopen` / `AnnotationInverse` — shared-impl tier (MaughamCore factory; Mac ⌘Z + phone Reopen are both consumers); note the paired schema-v3 release constraint.
- `docs/guide/`: update the undo topic. Keep the v0.17.0 prose about accepted suggestions; add the new coverage and the phone Reopen behavior (full revert on accepted). Mention that undo appends history (visible in History pane), never erases it.

- [ ] **Step 3: Full Mac suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS. Pay attention to: `TripwireGrepTests` (whole-tree ADR 0018/0021 guards over the new files), `BootstrapWiringTests`, MCP tools-list tests (should be untouched — no new tool).

- [ ] **Step 4: Full phone suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 5: Release build gate (ProjectWindow.body changed in Task 7)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. A "compiler is unable to type-check this expression in reasonable time" here is REAL (CLAUDE.md) — if it fires, extract the rewindSheet change into a `ViewModifier` per the ProjectWindow pattern.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test+docs: cross-surface reopen round-trips, contracts registry, guide undo topic"
```

---

## Post-implementation (user-facing, not agent tasks)

- **User smoke script** (Mac): accept, reject, archive an annotation; edit + withdraw an own review note; toggle an inline checkbox (pane AND editor click); create/reorder/nest/archive tasks; rewind-restore — then ⌘Z all the way back and ⇧⌘Z all the way forward. Check Edit-menu action names read correctly at each step.
- **Phone smoke**: reject on phone → Reopen; accept on phone → Reopen & Revert (incl. the drifted-paragraph confirm).
- **Release**: paired Mac + phone tags (schema v3 — old phone against new project must show the schema-too-new failure, not crash). Roadmap + release notes at cut time: closes Group 1 "Comprehensive ⌘Z undo", the History-Rewind "un-archive" carry-forward, and Group 5 "Annotations undo / reopen".
