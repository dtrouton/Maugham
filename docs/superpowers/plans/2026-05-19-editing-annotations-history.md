# Editing — Annotations + History Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship annotations (comment / suggested_change / query / craft_note kinds, open → accepted/rejected/archived lifecycle) and the extended History pane (unified op-stream view replacing CheckpointBrowserPane).

**Architecture:** Annotations are first-class ops in the per-document op log. Document gains a derived annotations cache rebuilt on every annotation-affecting op append. A new Annotations pane (right-pane segment ⌘⌥A) provides lifecycle actions; HistoryPane replaces CheckpointBrowserPane with a unified op + checkpoint timeline filtered by pills. Claude proposes via 4 MCP creation tools; the user disposes via the Annotations pane.

**Tech Stack:** Swift 6, SwiftUI, AppKit, NSFileCoordinator/NSFilePresenter, MCP over Unix socket. Spec: `docs/superpowers/specs/2026-05-19-editing-annotations-history-design.md`.

**Conformance contract:** The 715-test suite (and the 10 EditorIntegrationHarness tests in particular) must stay green between every task. New work adds 10 annotation tests + 1 end-to-end integration test.

---

## File Structure

### New files
- `Maugham/OpLog/Annotation.swift` — `AnnotationKind`, `AnnotationStatus`, `Annotation`, `AnnotationFilter`.
- `Maugham/OpLog/AnnotationDeriver.swift` — pure function `derive(ops:paragraphs:) -> [Annotation]`.
- `Maugham/MCP/Tools/AnnotationCreationTools.swift` — 4 creation tools.
- `Maugham/MCP/Tools/AnnotationReadTools.swift` — 2 read tools.
- `Maugham/Views/AnnotationsPane.swift` — main pane + `AnnotationRow` + 2 sheets.
- `Maugham/Views/HistoryPane.swift` — replaces CheckpointBrowserPane; unified row rendering.
- `MaughamTests/OpLog/AnnotationTests.swift` — 9 unit tests.
- `MaughamTests/EndToEnd/AnnotationFlowTests.swift` — 1 end-to-end integration test.

### Modified files
- `Maugham/OpLog/OpKind.swift` — +4 cases.
- `Maugham/OpLog/Op.swift` — Provenance gains 3 fields.
- `Maugham/OpLog/Document.swift` — annotation cache, mutation API, sweep, `opLog()` accessor.
- `Maugham/MCP/MCPToolsListHandler.swift` — +6 tool schemas.
- `Maugham/MaughamApp.swift` — +6 router registrations + new ⌘⌥A command.
- `Maugham/Models/DetailSegment.swift` — `.annotations` case.
- `Maugham/Views/DetailPaneToggle.swift` — picker + content routing for `.annotations`; rewires history → HistoryPane.
- `Maugham/Views/ProjectWindow.swift` — `.maughamSetDetailSegment` already handles raw-value dispatch; no logic change needed.

### Deleted files
- `Maugham/Views/CheckpointBrowserPane.swift`.

### Files left strictly untouched
- `Maugham/Views/PartialRestorePicker.swift`, `Maugham/Views/CheckpointLabelPromptSheet.swift`, `Maugham/OpLog/CheckpointStore.swift`, `Maugham/OpLog/OpLogStore.swift`.

---

## Branching

First action of T1 is creating branch `feat/milestone-editing` from `main`.

Commits are scoped per task; the implementer commits at the end of every task.

---

## Stage A — Schema additions

### Task 1: Create branch, verify baseline

**Files:**
- (none modified)

- [ ] **Step 1: Confirm clean working tree**

```bash
git status
```

Expected: only `.gitignore` and `UserInterfaceState.xcuserstate` modified (carry-overs from prior session). No untracked source files.

- [ ] **Step 2: Create + switch to branch**

```bash
git checkout -b feat/milestone-editing
```

- [ ] **Step 3: Run baseline test suite**

```bash
xcodebuild test \
  -scheme Maugham \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **` and final test count `≥ 715`. Record the exact count in the commit message of Task 2 so subsequent tasks can verify no test loss.

- [ ] **Step 4: No commit on this task** (branch + baseline only). Proceed to Task 2.

---

### Task 2: Add 4 new OpKind cases

**Files:**
- Modify: `Maugham/OpLog/OpKind.swift`
- Test: `MaughamTests/OpLog/OpKindCodingTests.swift` (add a test method to the existing file if present, else create)

- [ ] **Step 1: Write the failing test**

Inspect `MaughamTests/OpLog/` first. If `OpKindCodingTests.swift` exists, append the test; otherwise create it.

```swift
import XCTest
@testable import Maugham

final class OpKindCodingTests: XCTestCase {
    func test_newAnnotationKinds_encodeWithSnakeCaseRawValues() throws {
        let pairs: [(OpKind, String)] = [
            (.claudeComment,   "claude_comment"),
            (.claudeQuery,     "claude_query"),
            (.claudeCraftNote, "claude_craft_note"),
            (.claudeArchive,   "claude_archive"),
        ]
        let enc = JSONEncoder()
        for (kind, raw) in pairs {
            let data = try enc.encode(kind)
            let str = String(data: data, encoding: .utf8)
            XCTAssertEqual(str, "\"\(raw)\"")
            XCTAssertEqual(try JSONDecoder().decode(OpKind.self, from: data), kind)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test \
  -scheme Maugham \
  -destination 'platform=macOS' \
  -only-testing:MaughamTests/OpKindCodingTests/test_newAnnotationKinds_encodeWithSnakeCaseRawValues \
  -quiet 2>&1 | tail -10
```

Expected: compile error — symbols `OpKind.claudeComment` etc. do not exist.

- [ ] **Step 3: Add the four cases**

Replace `Maugham/OpLog/OpKind.swift` with:

```swift
import Foundation

public enum OpKind: String, Codable, Equatable, Sendable {
    case typingBurst = "typing_burst"
    case claudeSuggestion = "claude_suggestion"
    case claudeAccept = "claude_accept"
    case claudeReject = "claude_reject"
    case externalEdit = "external_edit"
    case checkpoint
    case checkpointRestore = "checkpoint_restore"
    case bootstrap

    // NEW — annotation creation kinds
    case claudeComment = "claude_comment"
    case claudeQuery = "claude_query"
    case claudeCraftNote = "claude_craft_note"

    // NEW — annotation lifecycle (accept/reject already exist above)
    case claudeArchive = "claude_archive"
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test \
  -scheme Maugham \
  -destination 'platform=macOS' \
  -only-testing:MaughamTests/OpKindCodingTests \
  -quiet 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Run the full suite to confirm no regressions**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. Test count = baseline + 1.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/OpKind.swift MaughamTests/OpLog/OpKindCodingTests.swift
git commit -m "feat: add 4 annotation OpKind cases (comment/query/craft_note/archive)"
```

---

### Task 3: Add 3 Provenance fields

**Files:**
- Modify: `Maugham/OpLog/Op.swift`
- Test: `MaughamTests/OpLog/OpCodingTests.swift` (create or extend)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class OpProvenanceCodingTests: XCTestCase {
    func test_provenance_encodesAnnotationFields_withSnakeCase() throws {
        let prov = Op.Provenance(
            sessionId: "s1",
            annotationBody: "consider showing instead of telling",
            sourceAnnotationId: "01HXYZ",
            userResponse: "tried it; original lands harder")
        let data = try JSONEncoder().encode(prov)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["annotation_body"] as? String,
                       "consider showing instead of telling")
        XCTAssertEqual(json["source_annotation_id"] as? String, "01HXYZ")
        XCTAssertEqual(json["user_response"] as? String,
                       "tried it; original lands harder")
    }

    func test_provenance_decodes_existingLogsWithoutAnnotationFields() throws {
        let oldJSON = #"{"session_id":"s1"}"#
        let prov = try JSONDecoder().decode(
            Op.Provenance.self, from: Data(oldJSON.utf8))
        XCTAssertNil(prov.annotationBody)
        XCTAssertNil(prov.sourceAnnotationId)
        XCTAssertNil(prov.userResponse)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/OpProvenanceCodingTests -quiet 2>&1 | tail -10
```

Expected: compile error — `annotationBody`/`sourceAnnotationId`/`userResponse` don't exist on `Op.Provenance.init`.

- [ ] **Step 3: Update Provenance**

Replace the `Provenance` struct in `Maugham/OpLog/Op.swift` (currently lines 33–62) with:

```swift
    public struct Provenance: Codable, Equatable, Sendable {
        public let sessionId: String?
        public let prompt: String?
        public let toolArgs: String?
        public let sourceCheckpoint: String?
        public let synthesisSource: String?
        public let orphanRecoveryMethod: String?

        // NEW — annotation semantics
        public let annotationBody: String?
        public let sourceAnnotationId: String?
        public let userResponse: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case prompt
            case toolArgs = "tool_args"
            case sourceCheckpoint = "source_checkpoint"
            case synthesisSource = "synthesis_source"
            case orphanRecoveryMethod = "orphan_recovery_method"
            case annotationBody = "annotation_body"
            case sourceAnnotationId = "source_annotation_id"
            case userResponse = "user_response"
        }

        public init(
            sessionId: String? = nil, prompt: String? = nil,
            toolArgs: String? = nil, sourceCheckpoint: String? = nil,
            synthesisSource: String? = nil, orphanRecoveryMethod: String? = nil,
            annotationBody: String? = nil, sourceAnnotationId: String? = nil,
            userResponse: String? = nil
        ) {
            self.sessionId = sessionId
            self.prompt = prompt
            self.toolArgs = toolArgs
            self.sourceCheckpoint = sourceCheckpoint
            self.synthesisSource = synthesisSource
            self.orphanRecoveryMethod = orphanRecoveryMethod
            self.annotationBody = annotationBody
            self.sourceAnnotationId = sourceAnnotationId
            self.userResponse = userResponse
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/OpProvenanceCodingTests -quiet 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. The two added tests should be visible; existing Op tests should still pass because all new Provenance fields are optional and defaulted.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Op.swift MaughamTests/OpLog/OpCodingTests.swift
git commit -m "feat: add annotation_body/source_annotation_id/user_response to Provenance"
```

---

### Task 4: Annotation types (data model only)

**Files:**
- Create: `Maugham/OpLog/Annotation.swift`
- Test: `MaughamTests/OpLog/AnnotationTypeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class AnnotationTypeTests: XCTestCase {
    func test_annotationKind_encodesSnakeCase() throws {
        let pairs: [(AnnotationKind, String)] = [
            (.comment, "comment"),
            (.suggestedChange, "suggested_change"),
            (.query, "query"),
            (.craftNote, "craft_note"),
        ]
        for (kind, raw) in pairs {
            XCTAssertEqual(kind.rawValue, raw)
        }
    }

    func test_annotationStatus_allCases() {
        XCTAssertEqual(
            Set(AnnotationStatus.allCases.map(\.rawValue)),
            ["open", "accepted", "rejected", "archived"])
    }

    func test_filter_defaults_toOpenOnly() {
        let f = AnnotationFilter()
        XCTAssertEqual(f.statuses, [.open])
        XCTAssertNil(f.kinds)
        XCTAssertNil(f.paragraphId)
    }

    func test_annotation_isIdentifiable_byOpId() {
        let a = Annotation(
            id: "01HXYZ", kind: .comment, paragraphId: "p1",
            body: "hi", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false)
        XCTAssertEqual(a.id, "01HXYZ")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationTypeTests -quiet 2>&1 | tail -10
```

Expected: compile errors — none of these types exist yet.

- [ ] **Step 3: Create `Maugham/OpLog/Annotation.swift`**

```swift
import Foundation

public enum AnnotationKind: String, Codable, Equatable, Sendable, CaseIterable {
    case comment
    case suggestedChange = "suggested_change"
    case query
    case craftNote = "craft_note"
}

public enum AnnotationStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case open
    case accepted
    case rejected
    case archived
}

public struct Annotation: Equatable, Sendable, Identifiable {
    public let id: String                  // = op_id of the creation op
    public let kind: AnnotationKind
    public let paragraphId: String?        // nil only for .craftNote
    public let body: String                // Claude's prose
    public let suggestedText: String?      // .suggestedChange only
    public let priorText: String?          // captured at suggestion time
    public let createdAt: Date
    public let createdBySession: String?
    public let status: AnnotationStatus
    public let userResponse: String?
    public let resolvedAt: Date?
    public let isStale: Bool

    public init(
        id: String, kind: AnnotationKind, paragraphId: String?,
        body: String, suggestedText: String?, priorText: String?,
        createdAt: Date, createdBySession: String?,
        status: AnnotationStatus, userResponse: String?,
        resolvedAt: Date?, isStale: Bool
    ) {
        self.id = id; self.kind = kind; self.paragraphId = paragraphId
        self.body = body; self.suggestedText = suggestedText
        self.priorText = priorText; self.createdAt = createdAt
        self.createdBySession = createdBySession
        self.status = status; self.userResponse = userResponse
        self.resolvedAt = resolvedAt; self.isStale = isStale
    }
}

public struct AnnotationFilter: Equatable, Sendable {
    public var kinds: Set<AnnotationKind>?
    public var statuses: Set<AnnotationStatus>?
    public var paragraphId: String?

    public init(
        kinds: Set<AnnotationKind>? = nil,
        statuses: Set<AnnotationStatus>? = [.open],
        paragraphId: String? = nil
    ) {
        self.kinds = kinds
        self.statuses = statuses
        self.paragraphId = paragraphId
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationTypeTests -quiet 2>&1 | tail -10
```

Expected: PASS (4 tests).

- [ ] **Step 5: Add file to the Xcode target**

Maugham's Xcode project picks up new files in `Maugham/OpLog/` automatically because the group is folder-referenced. Confirm by running:

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. If the build fails with "no such module" or "cannot find Annotation in scope", the file needs to be added manually via Xcode → File → Add Files; flag it as BLOCKED in the implementer report.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Annotation.swift MaughamTests/OpLog/AnnotationTypeTests.swift
git commit -m "feat: add Annotation/AnnotationKind/AnnotationStatus/AnnotationFilter types"
```

---

## Stage B — Document API

### Task 5: Expose `Document.opLog()` accessor

The opStore is private. HistoryPane needs read access to the per-doc op stream; annotation derivation likewise. Add a thin async read accessor.

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: `MaughamTests/OpLog/DocumentOpLogAccessorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class DocumentOpLogAccessorTests: XCTestCase {
    func test_opLog_returnsLogIncludingBootstrap() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "First paragraph.\n\nSecond paragraph.")
        let doc = env.document
        let ops = try await doc.opLog()
        XCTAssertFalse(ops.isEmpty)
        XCTAssertTrue(ops.contains(where: { $0.kind == .bootstrap }))
    }

    func test_opLog_reflectsAppendedBurst() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let doc = env.document
        let countBefore = (try await doc.opLog()).count
        doc.setFullText("Hello world.")
        try await doc.flushBurstNow()
        let countAfter = (try await doc.opLog()).count
        XCTAssertEqual(countAfter, countBefore + 1)
        XCTAssertEqual((try await doc.opLog()).last?.kind, .typingBurst)
    }
}
```

`TestProjectEnvironment.makeWithSingleDoc` is the existing harness used by the document-first-class tests. If unsure of its location, grep:

```bash
grep -rn "TestProjectEnvironment" MaughamTests | head -5
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentOpLogAccessorTests -quiet 2>&1 | tail -10
```

Expected: compile error — `Document.opLog()` does not exist.

- [ ] **Step 3: Add the accessor**

In `Maugham/OpLog/Document.swift`, after the `materialize()` method (around line 203), add:

```swift
    /// Returns the full op log for this document, ordered by `op_id`
    /// (ULID timestamp-prefixed → chronologically stable across devices).
    /// Reads from disk via `OpLogStore.load(docId:)` each call; the log
    /// is small enough that caching is unnecessary for v1.
    public func opLog() async throws -> [Op] {
        try await opStore.load(docId: docId)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentOpLogAccessorTests -quiet 2>&1 | tail -10
```

Expected: PASS (2 tests).

- [ ] **Step 5: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentOpLogAccessorTests.swift
git commit -m "feat: expose Document.opLog() read accessor"
```

---

### Task 6: AnnotationDeriver — pure function

**Files:**
- Create: `Maugham/OpLog/AnnotationDeriver.swift`
- Test: `MaughamTests/OpLog/AnnotationDeriverTests.swift`

The deriver walks the op log; for each creation op (the four kinds), it finds the latest lifecycle op (accept/reject/archive) whose `provenance.sourceAnnotationId` matches that creation op's `op_id`. Status is derived from the latest. `isStale` compares captured priorText against the current paragraph text.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class AnnotationDeriverTests: XCTestCase {
    private func makeOp(
        id: String, kind: OpKind,
        changes: [Op.ParagraphChange] = [],
        provenance: Op.Provenance? = nil,
        at: Date = Date()
    ) -> Op {
        Op(opId: id, docId: "d", at: at,
           device: "test", session: "s",
           kind: kind, changes: changes,
           sequence: nil, provenance: provenance)
    }

    func test_creationOp_derivesOpenAnnotation() {
        let op = makeOp(
            id: "01A", kind: .claudeComment,
            changes: [.init(paragraphId: "p1", prior: nil, next: "")],
            provenance: .init(annotationBody: "consider X"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["p1": "current"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "01A")
        XCTAssertEqual(result[0].kind, .comment)
        XCTAssertEqual(result[0].paragraphId, "p1")
        XCTAssertEqual(result[0].body, "consider X")
        XCTAssertEqual(result[0].status, .open)
    }

    func test_acceptOp_setsAcceptedStatus() {
        let create = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "old", next: "new")],
            provenance: .init(annotationBody: "rewrite"))
        let accept = makeOp(
            id: "01B", kind: .claudeAccept,
            provenance: .init(sourceAnnotationId: "01A"))
        let result = AnnotationDeriver.derive(
            ops: [create, accept], paragraphs: ["p1": "new"])
        XCTAssertEqual(result[0].status, .accepted)
        XCTAssertNotNil(result[0].resolvedAt)
    }

    func test_rejectOp_setsRejectedStatus_andCapturesUserResponse() {
        let create = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "x", next: "y")],
            provenance: .init(annotationBody: "rewrite"))
        let reject = makeOp(
            id: "01B", kind: .claudeReject,
            provenance: .init(sourceAnnotationId: "01A",
                              userResponse: "original lands harder"))
        let result = AnnotationDeriver.derive(
            ops: [create, reject], paragraphs: ["p1": "x"])
        XCTAssertEqual(result[0].status, .rejected)
        XCTAssertEqual(result[0].userResponse, "original lands harder")
    }

    func test_archiveOp_setsArchivedStatus() {
        let create = makeOp(
            id: "01A", kind: .claudeComment,
            changes: [.init(paragraphId: "p1", prior: nil, next: "")],
            provenance: .init(annotationBody: "x"))
        let archive = makeOp(
            id: "01B", kind: .claudeArchive,
            provenance: .init(sourceAnnotationId: "01A"))
        let result = AnnotationDeriver.derive(
            ops: [create, archive], paragraphs: [:])
        XCTAssertEqual(result[0].status, .archived)
    }

    func test_isStale_true_whenPriorTextDoesNotMatchCurrentParagraph() {
        let op = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "OLD", next: "new")],
            provenance: .init(annotationBody: "x"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["p1": "DIFFERENT"])
        XCTAssertTrue(result[0].isStale)
    }

    func test_isStale_false_whenPriorMatches() {
        let op = makeOp(
            id: "01A", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "p1", prior: "SAME", next: "new")],
            provenance: .init(annotationBody: "x"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: ["p1": "SAME"])
        XCTAssertFalse(result[0].isStale)
    }

    func test_craftNote_hasNilParagraphId_andIsNeverStale() {
        let op = makeOp(
            id: "01A", kind: .claudeCraftNote,
            changes: [],
            provenance: .init(annotationBody: "voice rule"))
        let result = AnnotationDeriver.derive(
            ops: [op], paragraphs: [:])
        XCTAssertNil(result[0].paragraphId)
        XCTAssertFalse(result[0].isStale)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationDeriverTests -quiet 2>&1 | tail -10
```

Expected: compile error — `AnnotationDeriver` does not exist.

- [ ] **Step 3: Create the deriver**

```swift
// Maugham/OpLog/AnnotationDeriver.swift
import Foundation

public enum AnnotationDeriver {

    /// Build the annotation projection from an op log + current paragraph map.
    /// Pure function: same inputs → same output.
    public static func derive(
        ops: [Op],
        paragraphs: [String: String]
    ) -> [Annotation] {
        // 1. Index lifecycle ops by sourceAnnotationId, latest wins.
        var latestLifecycle: [String: Op] = [:]
        for op in ops {
            guard isLifecycleKind(op.kind),
                  let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = latestLifecycle[src] {
                if op.opId > prior.opId { latestLifecycle[src] = op }
            } else {
                latestLifecycle[src] = op
            }
        }

        // 2. Walk creation ops; build annotations.
        var result: [Annotation] = []
        for op in ops {
            guard let kind = annotationKind(forCreationOpKind: op.kind) else {
                continue
            }
            let change = op.changes.first
            let paragraphId: String? = (kind == .craftNote) ? nil : change?.paragraphId
            let priorText = change?.prior
            let suggested: String? = (kind == .suggestedChange) ? change?.next : nil
            let body = op.provenance?.annotationBody ?? ""

            let lifecycle = latestLifecycle[op.opId]
            let (status, userResponse, resolvedAt) = resolution(
                creation: op, lifecycle: lifecycle)

            let isStale: Bool = {
                guard kind != .craftNote, let pid = paragraphId,
                      let captured = priorText else { return false }
                return paragraphs[pid] != captured
            }()

            result.append(Annotation(
                id: op.opId,
                kind: kind,
                paragraphId: paragraphId,
                body: body,
                suggestedText: suggested,
                priorText: priorText,
                createdAt: op.at,
                createdBySession: op.provenance?.sessionId,
                status: status,
                userResponse: userResponse,
                resolvedAt: resolvedAt,
                isStale: isStale))
        }
        // Sort: newest first by createdAt, ties by op_id for stability.
        result.sort { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id > b.id
        }
        return result
    }

    // MARK: - Helpers

    private static func annotationKind(forCreationOpKind kind: OpKind) -> AnnotationKind? {
        switch kind {
        case .claudeComment:    return .comment
        case .claudeSuggestion: return .suggestedChange
        case .claudeQuery:      return .query
        case .claudeCraftNote:  return .craftNote
        default:                return nil
        }
    }

    private static func isLifecycleKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeAccept, .claudeReject, .claudeArchive: return true
        default: return false
        }
    }

    private static func resolution(
        creation: Op, lifecycle: Op?
    ) -> (AnnotationStatus, String?, Date?) {
        guard let lifecycle else {
            return (.open, creation.provenance?.userResponse, nil)
        }
        let status: AnnotationStatus = {
            switch lifecycle.kind {
            case .claudeAccept:  return .accepted
            case .claudeReject:  return .rejected
            case .claudeArchive: return .archived
            default:             return .open
            }
        }()
        return (status, lifecycle.provenance?.userResponse, lifecycle.at)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationDeriverTests -quiet 2>&1 | tail -10
```

Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/AnnotationDeriver.swift MaughamTests/OpLog/AnnotationDeriverTests.swift
git commit -m "feat: AnnotationDeriver derives projection from op log + paragraphs"
```

---

### Task 7: Document annotation cache + `annotations(filter:)`

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift`

Document gains:
1. A private `_annotationsCache: [Annotation]` rebuilt on demand.
2. A private `_annotationsRebuildNeeded: Bool` flag flipped by mutation methods.
3. A public `annotationsVersion` observable counter (so SwiftUI views observing the annotations re-render without coupling to `displayText`).
4. A public `annotations(filter:)` method.

Per spec §2.7: the cache rebuild flag is flipped, and `annotationsVersion` is incremented exactly once per mutation that affects annotations. No `_displayText` write on annotation-only mutations.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class DocumentAnnotationCacheTests: XCTestCase {
    func test_initially_no_annotations() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        XCTAssertEqual(env.document.annotations(), [])
    }

    func test_filterByKind() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "P1.\n\nP2.")
        let doc = env.document
        let pids = try await doc.opLog()
            .compactMap { $0.changes.first?.paragraphId }
        guard let p1 = pids.first else {
            return XCTFail("no paragraph ids")
        }
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: p1, body: "comment body")
        _ = try await doc.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: "craft body")

        let comments = doc.annotations(
            filter: .init(kinds: [.comment]))
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].kind, .comment)

        let craft = doc.annotations(
            filter: .init(kinds: [.craftNote], statuses: nil))
        XCTAssertEqual(craft.count, 1)
        XCTAssertEqual(craft[0].kind, .craftNote)
    }

    func test_filterByStatus_defaultsToOpenOnly() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let doc = env.document
        let pid = try await doc.opLog()
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id1 = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "first")
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "second")
        try await doc.archiveAnnotation(id: id1)

        // Default filter = open only.
        XCTAssertEqual(doc.annotations().count, 1)
        // All statuses → 2.
        XCTAssertEqual(doc.annotations(filter: .init(statuses: nil)).count, 2)
    }

    func test_annotationsVersion_incrementsOnMutation() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let doc = env.document
        let v0 = doc.annotationsVersion
        _ = try await doc.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: "x")
        XCTAssertEqual(doc.annotationsVersion, v0 + 1)
    }
}
```

(`addAnnotation` and `archiveAnnotation` are defined in Tasks 8/10 — the test will fail to compile until those exist. Order of implementation: implementer must add stubs for `addAnnotation` and `archiveAnnotation` here so the cache test compiles, then fill them in Tasks 8 and 10. Practical alternative: write only the `test_initially_no_annotations` and `test_annotationsVersion_incrementsOnMutation` tests now, defer the filter tests until after Tasks 8/10 land. The implementer picks; either is acceptable. Cleaner approach is the latter: keep Task 7 about the cache mechanism + read API only.)

**Revised step 1 — minimal failing tests just for the read surface:**

```swift
import XCTest
@testable import Maugham

final class DocumentAnnotationCacheTests: XCTestCase {
    func test_initially_no_annotations() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        XCTAssertEqual(env.document.annotations(), [])
    }

    func test_annotationsVersion_startsAtZero() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        XCTAssertEqual(env.document.annotationsVersion, 0)
    }
}
```

Filter + mutation-incrementing tests get added in Tasks 8/10.

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: compile error — `Document.annotations` and `annotationsVersion` don't exist.

- [ ] **Step 3: Add cache + accessor to Document**

In `Maugham/OpLog/Document.swift`, add these stored properties after `lastWrittenText` (around line 33):

```swift
    /// Annotation projection — cached, rebuilt lazily after mutations.
    private var _annotationsCache: [Annotation] = []
    private var _annotationsCacheValid: Bool = false
    /// Observable counter; SwiftUI views observe this rather than the
    /// annotation array directly to avoid coupling to `displayText`.
    public private(set) var annotationsVersion: Int = 0
```

Inside the existing `Document` declaration body (between `materialize()` and `// === Mutation API`), add:

```swift
    // MARK: - Annotation read API

    public func annotations(
        filter: AnnotationFilter = AnnotationFilter()
    ) -> [Annotation] {
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        return _annotationsCache.filter { ann in
            if let kinds = filter.kinds, !kinds.contains(ann.kind) {
                return false
            }
            if let statuses = filter.statuses, !statuses.contains(ann.status) {
                return false
            }
            if let pid = filter.paragraphId, ann.paragraphId != pid {
                return false
            }
            return true
        }
    }

    /// Marks the cache stale. Mutation methods that affect annotations
    /// call this then bump `annotationsVersion` once.
    fileprivate func invalidateAnnotationsCache() {
        _annotationsCacheValid = false
        annotationsVersion &+= 1
    }

    private func rebuildAnnotationsCache() {
        // Synchronously load the op log via a stored projection. Since
        // mutations append to the same opStore the Document owns, the
        // cache can be rebuilt by re-reading on demand. For UI calls on
        // the main actor, we synchronously snapshot by reading from a
        // mirrored in-memory log; we maintain that mirror via the same
        // mutation paths that append to opStore (see Task 8+).
        let ops = _opLogMirror
        _annotationsCache = AnnotationDeriver.derive(
            ops: ops, paragraphs: paragraphs)
        _annotationsCacheValid = true
    }

    /// Mirror of every op append for synchronous annotation derivation.
    /// Populated at `load(...)` with the result of `opStore.load`, then
    /// kept in sync by every mutation path that calls `opStore.append`.
    fileprivate var _opLogMirror: [Op] = []
```

Then update `load(...)` (around line 122) to populate `_opLogMirror` and prime the cache. Right after the line `var initial = Deriver.derive(ops: ops)`:

```swift
        // Capture ops for synchronous annotation derivation.
        let opsForMirror = ops
```

And after the `Document(...)` initializer call but before `return doc`:

```swift
        doc._opLogMirror = opsForMirror
        doc._annotationsCacheValid = false   // force rebuild on first read
```

Finally, every existing path that calls `try await opStore.append(op)` must mirror the append. Find them via:

```bash
grep -n "opStore.append" Maugham/OpLog/Document.swift
```

Expected locations (verify):
- `load(...)` after the crash-recovery `recovered` op (around line 117).
- `flushBurstNow()` after appending the burst op (around line 334).
- `handleExternalDiskChange` silentIngest case (around line 367).
- `handleExternalDiskChangeForceIngest` (around line 457).

For each, immediately after `try await opStore.append(op)` insert:

```swift
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
```

(The mirror keeps `_opLogMirror` consistent so annotation-bearing ops appended elsewhere are visible; the cache invalidation handles the case where typing-burst ops change paragraphs and thus `isStale`.)

Also update `handleExternalLogChange()` (around line 386–397) so the mirror is replaced with the merged log:

```swift
    public func handleExternalLogChange() async throws {
        let ops = try await opStore.load(docId: docId)
        let state = Deriver.derive(ops: ops)
        self.paragraphs = state.paragraphs
        self.sequence = state.sequence
        self._opLogMirror = ops
        invalidateAnnotationsCache()
        recomputeDisplayText()
    }
```

- [ ] **Step 4: Update `opLog()` to read from mirror (avoids disk hit)**

Replace the `opLog()` method added in Task 5:

```swift
    public func opLog() async throws -> [Op] {
        // Prefer the in-memory mirror; fall back to disk if uninitialized
        // (shouldn't happen after load() succeeds).
        if !_opLogMirror.isEmpty { return _opLogMirror }
        return try await opStore.load(docId: docId)
    }
```

- [ ] **Step 5: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: PASS (2 tests).

- [ ] **Step 6: Run full suite to confirm no regressions**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. The `_opLogMirror` plumbing is a load-bearing change to existing paths — if any harness test regresses, the implementer should debug carefully (most likely cause: a path that appends to `opStore` but forgets to mirror).

- [ ] **Step 7: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "feat: Document annotation cache + annotations(filter:) accessor"
```

---

### Task 8: `Document.addAnnotation`

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: extend `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `DocumentAnnotationCacheTests.swift`:

```swift
    func test_addComment_appendsClaudeCommentOp() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "First paragraph.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "consider showing")

        let log = try await doc.opLog()
        let creation = log.first { $0.opId == id }
        XCTAssertNotNil(creation)
        XCTAssertEqual(creation?.kind, .claudeComment)
        XCTAssertEqual(creation?.changes.first?.paragraphId, pid)
        XCTAssertEqual(creation?.provenance?.annotationBody, "consider showing")
    }

    func test_addSuggestedChange_includesPriorAndSuggested() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "She was angry.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "telling not showing", suggestedText: "Her jaw clenched.")

        let log = try await doc.opLog()
        let creation = log.first { $0.opId == id }
        XCTAssertEqual(creation?.kind, .claudeSuggestion)
        let change = creation?.changes.first
        XCTAssertEqual(change?.paragraphId, pid)
        XCTAssertEqual(change?.prior, "She was angry.")
        XCTAssertEqual(change?.next, "Her jaw clenched.")
    }

    func test_addCraftNote_hasNoParagraphAnchor() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let doc = env.document
        let id = try await doc.addAnnotation(
            kind: .craftNote, paragraphId: nil,
            body: "Lisa never uses contractions with her father.")
        let log = try await doc.opLog()
        let creation = log.first { $0.opId == id }
        XCTAssertEqual(creation?.kind, .claudeCraftNote)
        XCTAssertTrue(creation?.changes.isEmpty ?? false)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: compile error — `addAnnotation` does not exist.

- [ ] **Step 3: Add `addAnnotation` to Document**

In `Maugham/OpLog/Document.swift`, after `reorder(sequence:)` (around line 320), add:

```swift
    // MARK: - Annotation mutation API

    @discardableResult
    public func addAnnotation(
        kind: AnnotationKind,
        paragraphId: String?,
        body: String,
        suggestedText: String? = nil,
        prompt: String? = nil,
        toolArgs: String? = nil
    ) async throws -> String {
        let opKind: OpKind = {
            switch kind {
            case .comment:         return .claudeComment
            case .suggestedChange: return .claudeSuggestion
            case .query:           return .claudeQuery
            case .craftNote:       return .claudeCraftNote
            }
        }()
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .craftNote: return []
            case .suggestedChange:
                guard let pid = paragraphId else { return [] }
                let prior = paragraphs[pid]
                return [.init(paragraphId: pid,
                              prior: prior,
                              next: suggestedText ?? "")]
            case .comment, .query:
                guard let pid = paragraphId else { return [] }
                let prior = paragraphs[pid]
                // Capture priorText in `prior` so deriver can stale-check.
                return [.init(paragraphId: pid, prior: prior, next: "")]
            }
        }()
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: opKind, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                prompt: prompt,
                toolArgs: toolArgs,
                annotationBody: body))
        try await opStore.append(op)
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
        return op.opId
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: PASS (5 tests now in the file).

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "feat: Document.addAnnotation appends creation op + invalidates cache"
```

---

### Task 9: `Document.acceptAnnotation` — with suggestedChange manuscript mutation

This is the most subtle method: a `claude_accept` of a `.suggestedChange` carries the same `changes` as the originating suggestion AND applies them to `paragraphs`/`displayText`. Other kinds: empty `changes`, status-only.

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: extend `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift`

- [ ] **Step 1: Write the failing tests**

Append:

```swift
    func test_acceptSuggestedChange_appliesChangeToDocument() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "She was angry.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "tighter", suggestedText: "Her jaw clenched.")
        try await doc.acceptAnnotation(id: id)

        XCTAssertEqual(doc.displayText, "Her jaw clenched.")
        let anns = doc.annotations(filter: .init(statuses: nil))
        XCTAssertEqual(anns.first(where: { $0.id == id })?.status, .accepted)
    }

    func test_acceptComment_doesNotChangeDisplayText() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Original prose.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"
        let before = doc.displayText

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "noted")
        try await doc.acceptAnnotation(id: id)

        XCTAssertEqual(doc.displayText, before)
    }

    func test_acceptQuery_capturesUserResponse() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .query, paragraphId: pid, body: "ambiguous?")
        try await doc.acceptAnnotation(id: id, userResponse: "yes, intended")

        let anns = doc.annotations(filter: .init(statuses: nil))
        let a = anns.first { $0.id == id }
        XCTAssertEqual(a?.status, .accepted)
        XCTAssertEqual(a?.userResponse, "yes, intended")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: compile error — `acceptAnnotation` does not exist.

- [ ] **Step 3: Add `acceptAnnotation` to Document**

After `addAnnotation`:

```swift
    public func acceptAnnotation(
        id: String,
        userResponse: String? = nil
    ) async throws {
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              let kind = AnnotationKind.fromOpKind(creation.kind) else {
            return  // unknown id or non-annotation op — no-op
        }

        // Determine the changes to attach. Only suggestedChange mutates the
        // manuscript on accept.
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .suggestedChange:
                return creation.changes  // re-applies prior/next to manuscript
            case .comment, .query, .craftNote:
                return []
            }
        }()

        let acceptOp = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .claudeAccept,
            changes: changes,
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id,
                userResponse: userResponse))
        try await opStore.append(acceptOp)
        _opLogMirror.append(acceptOp)

        // Apply manuscript mutation for suggestedChange.
        if kind == .suggestedChange, let change = changes.first {
            paragraphs[change.paragraphId] = change.next
            pending.recordChange(
                paragraphId: change.paragraphId,
                prior: change.prior, next: change.next)
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())
            recomputeDisplayText()  // writes _displayText
        }

        // Always invalidate the annotation cache. annotationsVersion bumps
        // exactly once per call — for suggestedChange this is the second
        // observable write, but it's a distinct surface (annotationsVersion)
        // from displayText, so the single-observable-write rule still holds:
        // one mutation = one update per observed surface, and the two
        // surfaces drive different views.
        invalidateAnnotationsCache()
    }
```

The `AnnotationKind.fromOpKind` helper doesn't exist yet. Add it as a static method on `AnnotationKind` in `Maugham/OpLog/Annotation.swift`:

```swift
extension AnnotationKind {
    static func fromOpKind(_ kind: OpKind) -> AnnotationKind? {
        switch kind {
        case .claudeComment:    return .comment
        case .claudeSuggestion: return .suggestedChange
        case .claudeQuery:      return .query
        case .claudeCraftNote:  return .craftNote
        default:                return nil
        }
    }
}
```

(Also refactor `AnnotationDeriver`'s `annotationKind(forCreationOpKind:)` to call this helper — but it works either way; only refactor if the implementer sees fit.)

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: PASS (8 tests in this file).

- [ ] **Step 5: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Document.swift Maugham/OpLog/Annotation.swift \
        MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "feat: Document.acceptAnnotation — applies suggestedChange to manuscript"
```

---

### Task 10: `Document.rejectAnnotation` + `archiveAnnotation`

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: extend `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
    func test_rejectWithUserResponse_capturesReasoning() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "She was angry.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "rewrite", suggestedText: "Her jaw clenched.")
        try await doc.rejectAnnotation(
            id: id, userResponse: "original lands harder")

        let anns = doc.annotations(filter: .init(statuses: nil))
        let a = anns.first { $0.id == id }
        XCTAssertEqual(a?.status, .rejected)
        XCTAssertEqual(a?.userResponse, "original lands harder")
        // Manuscript untouched.
        XCTAssertEqual(doc.displayText, "She was angry.")
    }

    func test_archive_leavesAnnotationInHistoryButOutOfDefaultView() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "x")
        try await doc.archiveAnnotation(id: id)

        // Default (open only) excludes it.
        XCTAssertTrue(doc.annotations().isEmpty)
        // All statuses includes it as archived.
        let all = doc.annotations(filter: .init(statuses: nil))
        XCTAssertEqual(all.first(where: { $0.id == id })?.status, .archived)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: compile error — `rejectAnnotation` / `archiveAnnotation` don't exist.

- [ ] **Step 3: Add the two methods**

After `acceptAnnotation`:

```swift
    public func rejectAnnotation(
        id: String, userResponse: String? = nil
    ) async throws {
        try await appendLifecycleOp(
            kind: .claudeReject,
            sourceAnnotationId: id,
            userResponse: userResponse)
    }

    public func archiveAnnotation(id: String) async throws {
        try await appendLifecycleOp(
            kind: .claudeArchive,
            sourceAnnotationId: id,
            userResponse: nil)
    }

    private func appendLifecycleOp(
        kind: OpKind,
        sourceAnnotationId: String,
        userResponse: String?,
        synthesisSource: String? = nil
    ) async throws {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: kind, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                synthesisSource: synthesisSource,
                sourceAnnotationId: sourceAnnotationId,
                userResponse: userResponse))
        try await opStore.append(op)
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests -quiet 2>&1 | tail -10
```

Expected: PASS (10 tests in file).

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "feat: Document.rejectAnnotation + archiveAnnotation lifecycle ops"
```

---

### Task 11: Stale detection — verify the end-to-end path

The deriver already implements `isStale` (Task 6). This task is a guard test that proves the cache reflects current paragraph state.

**Files:**
- Test only: extend `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift`

- [ ] **Step 1: Write the test**

```swift
    func test_annotation_isMarkedStaleWhenParagraphChanges() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "She was angry.")
        let doc = env.document
        let pid = (try await doc.opLog())
            .first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "p1"

        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "tighter", suggestedText: "Her jaw clenched.")

        // Verify not stale immediately after creation.
        XCTAssertFalse(doc.annotations()
            .first(where: { $0.id == id })?.isStale ?? true)

        // User edits the paragraph directly.
        doc.setFullText("She fumed silently.")

        // Cache should now reflect the staleness.
        let anns = doc.annotations()
        XCTAssertTrue(anns.first(where: { $0.id == id })?.isStale ?? false,
                      "annotation should be flagged stale after paragraph edit")
    }
```

- [ ] **Step 2: Run test**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests/test_annotation_isMarkedStaleWhenParagraphChanges \
  -quiet 2>&1 | tail -10
```

Expected: PASS *iff* `setFullText` invalidates the annotation cache. If FAIL, modify `Maugham/OpLog/Document.swift`'s `setFullText` (line 248-251 area, the `if !changes.isEmpty || sequenceChanged` block) to add cache invalidation:

```swift
        if !changes.isEmpty || sequenceChanged {
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())
            invalidateAnnotationsCache()
        }
```

Re-run; should now PASS.

- [ ] **Step 3: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "feat: invalidate annotation cache on paragraph edit (stale check)"
```

---

### Task 12: Paragraph-deletion auto-archive sweep

When a paragraph is removed from `sequence` via any path, auto-archive open annotations anchored to it.

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: extend `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
    func test_paragraphDeletion_autoArchivesAnnotations() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "First paragraph.\n\nSecond paragraph.")
        let doc = env.document
        let log = try await doc.opLog()
        let bootstrap = log.first(where: { $0.kind == .bootstrap })!
        let pids = bootstrap.changes.map(\.paragraphId)
        XCTAssertEqual(pids.count, 2)
        let p1 = pids[0]

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: p1, body: "on first")
        XCTAssertEqual(doc.annotations().count, 1)

        doc.deleteParagraph(id: p1)

        // After deletion, annotation should be archived (not open).
        XCTAssertTrue(doc.annotations().isEmpty)
        let all = doc.annotations(filter: .init(statuses: nil))
        let a = all.first(where: { $0.id == id })
        XCTAssertEqual(a?.status, .archived)

        // The archive op should carry the synthesisSource flag.
        let newLog = try await doc.opLog()
        let archiveOp = newLog.first {
            $0.kind == .claudeArchive
                && $0.provenance?.sourceAnnotationId == id
        }
        XCTAssertEqual(
            archiveOp?.provenance?.synthesisSource, "paragraph_deleted")
    }

    func test_setFullText_dropsParagraph_autoArchivesAnnotations() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "First.\n\nSecond.")
        let doc = env.document
        let log = try await doc.opLog()
        let pids = log.first(where: { $0.kind == .bootstrap })!
            .changes.map(\.paragraphId)
        let p2 = pids[1]

        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: p2, body: "on second")

        // Edit removing the second paragraph entirely.
        doc.setFullText("First.")

        let a = doc.annotations(filter: .init(statuses: nil))
            .first { $0.id == id }
        XCTAssertEqual(a?.status, .archived)
    }
```

- [ ] **Step 2: Run test**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests \
  -quiet 2>&1 | tail -10
```

Expected: FAIL — paragraphs are dropped but annotations stay open.

- [ ] **Step 3: Add a private sweep helper**

In `Maugham/OpLog/Document.swift`, alongside the other annotation methods, add:

```swift
    /// Auto-archive any open annotations anchored to paragraphs no longer
    /// present in `sequence`. Synthesizes claude_archive lifecycle ops with
    /// provenance.synthesisSource = "paragraph_deleted" for forensic context.
    /// Caller must hold MainActor (we already do — Document is @MainActor).
    private func sweepOrphanedAnnotations() async {
        let presentIds = Set(sequence)
        // Read currently-open annotations without forcing a cache rebuild on
        // every iteration: rebuild once up front, then iterate the snapshot.
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        let orphans = _annotationsCache.filter { ann in
            ann.status == .open
                && ann.kind != .craftNote
                && (ann.paragraphId.map { !presentIds.contains($0) } ?? false)
        }
        for orphan in orphans {
            // Append archive op directly so we can set synthesisSource.
            let op = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .claudeArchive,
                changes: [],
                sequence: nil,
                provenance: Op.Provenance(
                    sessionId: session,
                    synthesisSource: "paragraph_deleted",
                    sourceAnnotationId: orphan.id))
            try? await opStore.append(op)
            _opLogMirror.append(op)
        }
        if !orphans.isEmpty {
            invalidateAnnotationsCache()
        }
    }
```

- [ ] **Step 4: Wire the sweep into every sequence-changing path**

The implementer should grep for sequence mutation sites:

```bash
grep -n "self.sequence\|sequence.removeAll\|sequence.append\|sequence.insert\|sequence = newSequence" Maugham/OpLog/Document.swift
```

Expected sites (verify):
- `setFullText` — after `self.sequence = newSequence` (~line 244).
- `insertParagraph` — after `sequence.insert/append` (~line 287–291).
- `deleteParagraph` — after `sequence.removeAll` (~line 303).
- `reorder` — after `self.sequence = sequence` (~line 314).
- `handleExternalLogChange` — after `self.sequence = state.sequence` (~line 393).
- `handleExternalDiskChangeForceIngest` — after `self.sequence = newSequence` (~line 459).
- `handleExternalDiskChange` silentIngest — that path only mutates `paragraphs`, not `sequence`, so no sweep needed there.

For each *sync* method (`setFullText`, `insertParagraph`, `deleteParagraph`, `reorder`), invoke the sweep via:

```swift
        Task { @MainActor in await self.sweepOrphanedAnnotations() }
```

placed immediately before `recomputeDisplayText()`. (The sweep is async because op append is async; we fire-and-forget the sweep on the main actor — the cache update from `invalidateAnnotationsCache()` inside the sweep triggers a separate UI re-render.)

For the *async* methods (`handleExternalLogChange`, `handleExternalDiskChangeForceIngest`), invoke synchronously:

```swift
        await sweepOrphanedAnnotations()
```

immediately before `recomputeDisplayText()`.

- [ ] **Step 5: Re-write the test if it can race**

The sync-mutation path fires the sweep as a `Task`. The test calls `doc.deleteParagraph(...)` then immediately asserts. There's no `await` between them, so the sweep Task may not have run.

Fix: after `doc.deleteParagraph(id: p1)`, add an explicit yield:

```swift
        doc.deleteParagraph(id: p1)
        // Allow the fire-and-forget sweep Task to run.
        try await Task.sleep(for: .milliseconds(50))
```

Apply the same fix to `test_setFullText_dropsParagraph_autoArchivesAnnotations`.

Alternative (cleaner — preferred): instead of fire-and-forget, make `deleteParagraph` etc. await the sweep before returning. But that requires making them `async`, which ripples through callers (NSViewRepresentable bindings). Tradeoff: the existing methods are sync, so use the fire-and-forget pattern + explicit yield in tests. Document this in a comment on `sweepOrphanedAnnotations`:

```swift
    /// Note: sync mutation paths schedule this via Task { } and return
    /// immediately. Tests that depend on observing the post-sweep state
    /// must `await Task.sleep(for: .milliseconds(50))` (or similar yield)
    /// after the mutation. UI re-renders naturally on the next render pass
    /// when the cache invalidation flips `annotationsVersion`.
```

- [ ] **Step 6: Run tests**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/DocumentAnnotationCacheTests \
  -quiet 2>&1 | tail -10
```

Expected: PASS (12 tests in file).

- [ ] **Step 7: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. The EditorIntegrationHarness tests in particular must stay green — the sweep is asynchronous and additive, so it shouldn't disturb them.

- [ ] **Step 8: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "feat: auto-archive annotations anchored to deleted paragraphs"
```

---

## Stage C — MCP tools

### Task 13: Four annotation creation tools

**Files:**
- Create: `Maugham/MCP/Tools/AnnotationCreationTools.swift`
- Test: `MaughamTests/MCP/AnnotationCreationToolsTests.swift`

Follow the `AddNoteTool` pattern (Codable Params, static `method`, `@MainActor handle(...)` reading from `ProjectRegistry`). Each tool resolves project → DocumentStore → Document via the existing `document(forDocId:)` accessor.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

@MainActor
final class AnnotationCreationToolsTests: XCTestCase {
    func test_addComment_appendsClaudeCommentOp() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let registry = ProjectRegistry()
        registry.register(url: env.projectURL, store: env.projectStore)

        let pid = (try await env.document.opLog())
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        let projectId = ProjectIdentifier.id(for: env.projectURL)

        let params: [String: Any] = [
            "project_id": projectId,
            "document_id": env.document.docId,
            "paragraph_id": pid,
            "body": "consider showing not telling"
        ]
        let data = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddCommentTool.handle(
            paramsJSON: data, registry: registry)
        let result = try JSONDecoder().decode(
            AddCommentTool.Result.self, from: resultData)
        XCTAssertFalse(result.annotation_id.isEmpty)

        let log = try await env.document.opLog()
        let creation = log.first { $0.opId == result.annotation_id }
        XCTAssertEqual(creation?.kind, .claudeComment)
        XCTAssertEqual(creation?.provenance?.annotationBody,
                       "consider showing not telling")
    }

    func test_addSuggestedChange_capturesPriorAndSuggested() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "She was angry.")
        let registry = ProjectRegistry()
        registry.register(url: env.projectURL, store: env.projectStore)
        let pid = (try await env.document.opLog())
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        let projectId = ProjectIdentifier.id(for: env.projectURL)

        let params: [String: Any] = [
            "project_id": projectId,
            "document_id": env.document.docId,
            "paragraph_id": pid,
            "body": "telling not showing",
            "suggested_text": "Her jaw clenched."
        ]
        let data = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddSuggestedChangeTool.handle(
            paramsJSON: data, registry: registry)
        let result = try JSONDecoder().decode(
            AddSuggestedChangeTool.Result.self, from: resultData)

        let log = try await env.document.opLog()
        let creation = log.first { $0.opId == result.annotation_id }
        XCTAssertEqual(creation?.kind, .claudeSuggestion)
        XCTAssertEqual(creation?.changes.first?.prior, "She was angry.")
        XCTAssertEqual(creation?.changes.first?.next, "Her jaw clenched.")
    }

    func test_addCraftNote_acceptsNoParagraphId() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let registry = ProjectRegistry()
        registry.register(url: env.projectURL, store: env.projectStore)
        let projectId = ProjectIdentifier.id(for: env.projectURL)

        let params: [String: Any] = [
            "project_id": projectId,
            "document_id": env.document.docId,
            "body": "Lisa avoids contractions with her father."
        ]
        let data = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await AddCraftNoteTool.handle(
            paramsJSON: data, registry: registry)
        let result = try JSONDecoder().decode(
            AddCraftNoteTool.Result.self, from: resultData)

        let log = try await env.document.opLog()
        let creation = log.first { $0.opId == result.annotation_id }
        XCTAssertEqual(creation?.kind, .claudeCraftNote)
        XCTAssertTrue(creation?.changes.isEmpty ?? false)
    }
}
```

`TestProjectEnvironment` needs a `projectStore` accessor exposed and the existing `document(forDocId:)` registry path wired (it should already be from milestone-document-first-class). If unsure, the implementer should grep for `TestProjectEnvironment` and check what it exposes.

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationCreationToolsTests -quiet 2>&1 | tail -10
```

Expected: compile errors — none of `AddCommentTool` etc. exist.

- [ ] **Step 3: Create the four tools**

```swift
// Maugham/MCP/Tools/AnnotationCreationTools.swift
import Foundation

// MARK: - add_comment

public enum AddCommentTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_comment"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, paragraph_id, body required")
        let doc = try resolveDoc(
            projectId: params.project_id,
            documentId: params.document_id, registry: registry)
        let id = try await doc.addAnnotation(
            kind: .comment,
            paragraphId: params.paragraph_id,
            body: params.body,
            toolArgs: toolArgsJSON(params))
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_suggested_change

public enum AddSuggestedChangeTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
        public let suggested_text: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_suggested_change"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, paragraph_id, body, suggested_text required")
        let doc = try resolveDoc(
            projectId: params.project_id,
            documentId: params.document_id, registry: registry)
        let id = try await doc.addAnnotation(
            kind: .suggestedChange,
            paragraphId: params.paragraph_id,
            body: params.body,
            suggestedText: params.suggested_text,
            toolArgs: toolArgsJSON(params))
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_query

public enum AddQueryTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_query"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, paragraph_id, body required")
        let doc = try resolveDoc(
            projectId: params.project_id,
            documentId: params.document_id, registry: registry)
        let id = try await doc.addAnnotation(
            kind: .query,
            paragraphId: params.paragraph_id,
            body: params.body,
            toolArgs: toolArgsJSON(params))
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_craft_note

public enum AddCraftNoteTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_craft_note"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, body required")
        let doc = try resolveDoc(
            projectId: params.project_id,
            documentId: params.document_id, registry: registry)
        let id = try await doc.addAnnotation(
            kind: .craftNote,
            paragraphId: nil,
            body: params.body,
            toolArgs: toolArgsJSON(params))
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - Shared helpers (file-private)

private func decodeParams<T: Decodable>(
    _ type: T.Type, from data: Data?, required: String
) throws -> T {
    guard let data, let decoded = try? JSONDecoder().decode(T.self, from: data)
    else { throw MCPError.invalidArgument(required) }
    return decoded
}

@MainActor
private func resolveDoc(
    projectId: String, documentId: String, registry: ProjectRegistry
) throws -> Document {
    guard let entry = registry.lookup(id: projectId) else {
        throw MCPError.projectNotOpen
    }
    guard let ds = entry.store.documentStore,
          let doc = ds.document(forDocId: documentId) else {
        throw MCPError.invalidArgument(
            "document_id not open: \(documentId)")
    }
    return doc
}

private func toolArgsJSON<T: Encodable>(_ params: T) -> String? {
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    return (try? enc.encode(params)).flatMap {
        String(data: $0, encoding: .utf8)
    }
}
```

The `MCPError.projectNotOpen` and `MCPError.invalidArgument(_:)` cases exist (used in `AddNoteTool`).

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationCreationToolsTests -quiet 2>&1 | tail -10
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/AnnotationCreationTools.swift \
        MaughamTests/MCP/AnnotationCreationToolsTests.swift
git commit -m "feat: 4 MCP creation tools (add_comment/suggested_change/query/craft_note)"
```

---

### Task 14: Two annotation read tools

**Files:**
- Create: `Maugham/MCP/Tools/AnnotationReadTools.swift`
- Test: `MaughamTests/MCP/AnnotationReadToolsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

@MainActor
final class AnnotationReadToolsTests: XCTestCase {
    func test_listAnnotations_filtersByKindAndStatus() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let registry = ProjectRegistry()
        registry.register(url: env.projectURL, store: env.projectStore)
        let pid = (try await env.document.opLog())
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        let projectId = ProjectIdentifier.id(for: env.projectURL)

        let c = try await env.document.addAnnotation(
            kind: .comment, paragraphId: pid, body: "comment")
        _ = try await env.document.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: "craft")
        try await env.document.archiveAnnotation(id: c)

        // Default (open only) — should not include the archived comment.
        let allOpenParams: [String: Any] = [
            "project_id": projectId,
            "document_id": env.document.docId
        ]
        let allOpenData = try JSONSerialization.data(
            withJSONObject: allOpenParams)
        let openResult = try await ListAnnotationsTool.handle(
            paramsJSON: allOpenData, registry: registry)
        let openList = try JSONDecoder().decode(
            [ListAnnotationsTool.Item].self, from: openResult)
        XCTAssertEqual(openList.count, 1)
        XCTAssertEqual(openList[0].kind, "craft_note")

        // Filter for archived.
        let archivedParams: [String: Any] = [
            "project_id": projectId,
            "document_id": env.document.docId,
            "statuses": ["archived"]
        ]
        let archivedData = try JSONSerialization.data(
            withJSONObject: archivedParams)
        let archivedResult = try await ListAnnotationsTool.handle(
            paramsJSON: archivedData, registry: registry)
        let archivedList = try JSONDecoder().decode(
            [ListAnnotationsTool.Item].self, from: archivedResult)
        XCTAssertEqual(archivedList.count, 1)
        XCTAssertEqual(archivedList[0].kind, "comment")
        XCTAssertEqual(archivedList[0].status, "archived")
    }

    func test_getAnnotation_returnsFullRecord() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "Hello.")
        let registry = ProjectRegistry()
        registry.register(url: env.projectURL, store: env.projectStore)
        let pid = (try await env.document.opLog())
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        let projectId = ProjectIdentifier.id(for: env.projectURL)

        let id = try await env.document.addAnnotation(
            kind: .comment, paragraphId: pid, body: "specific text")

        let params: [String: Any] = [
            "project_id": projectId,
            "document_id": env.document.docId,
            "annotation_id": id
        ]
        let data = try JSONSerialization.data(withJSONObject: params)
        let resultData = try await GetAnnotationTool.handle(
            paramsJSON: data, registry: registry)
        let result = try JSONDecoder().decode(
            GetAnnotationTool.Result.self, from: resultData)
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.body, "specific text")
        XCTAssertEqual(result.status, "open")
    }
}
```

- [ ] **Step 2: Run test (FAIL)**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationReadToolsTests -quiet 2>&1 | tail -10
```

- [ ] **Step 3: Create the read tools**

```swift
// Maugham/MCP/Tools/AnnotationReadTools.swift
import Foundation

// MARK: - list_annotations

public enum ListAnnotationsTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let kinds: [String]?
        public let statuses: [String]?
        public let paragraph_id: String?
    }
    public struct Item: Codable, Equatable {
        public let id: String
        public let kind: String
        public let paragraph_id: String?
        public let body: String
        public let suggested_text: String?
        public let status: String
        public let user_response: String?
        public let created_at: Date
        public let resolved_at: Date?
        public let is_stale: Bool
    }
    public static let method = "list_annotations"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data)
        else {
            throw MCPError.invalidArgument(
                "project_id, document_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        guard let ds = entry.store.documentStore,
              let doc = ds.document(forDocId: params.document_id) else {
            throw MCPError.invalidArgument(
                "document_id not open: \(params.document_id)")
        }

        let kindFilter: Set<AnnotationKind>? = params.kinds.flatMap { raws in
            let set = Set(raws.compactMap(AnnotationKind.init(rawValue:)))
            return set.isEmpty ? nil : set
        }
        // Default in tool is "all statuses" — explicit nil means no filter.
        let statusFilter: Set<AnnotationStatus>? = params.statuses.flatMap { raws in
            let set = Set(raws.compactMap(AnnotationStatus.init(rawValue:)))
            return set.isEmpty ? nil : set
        } ?? [.open]   // default = open only

        let filter = AnnotationFilter(
            kinds: kindFilter,
            statuses: statusFilter,
            paragraphId: params.paragraph_id)
        let items: [Item] = doc.annotations(filter: filter).map(Item.init)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(items)
    }
}

// MARK: - get_annotation

public enum GetAnnotationTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let annotation_id: String
    }
    public struct Result: Codable, Equatable {
        public let id: String
        public let kind: String
        public let paragraph_id: String?
        public let body: String
        public let suggested_text: String?
        public let prior_text: String?
        public let status: String
        public let user_response: String?
        public let created_at: Date
        public let resolved_at: Date?
        public let is_stale: Bool
        public let history: [HistoryEntry]

        public struct HistoryEntry: Codable, Equatable {
            public let op_id: String
            public let kind: String
            public let at: Date
            public let user_response: String?
        }
    }
    public static let method = "get_annotation"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data)
        else {
            throw MCPError.invalidArgument(
                "project_id, document_id, annotation_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        guard let ds = entry.store.documentStore,
              let doc = ds.document(forDocId: params.document_id) else {
            throw MCPError.invalidArgument(
                "document_id not open: \(params.document_id)")
        }
        let all = doc.annotations(filter: .init(statuses: nil))
        guard let ann = all.first(where: { $0.id == params.annotation_id })
        else {
            throw MCPError.invalidArgument(
                "annotation_id not found: \(params.annotation_id)")
        }
        let ops = try await doc.opLog()
        let history: [Result.HistoryEntry] = ops
            .filter {
                $0.opId == params.annotation_id
                || $0.provenance?.sourceAnnotationId == params.annotation_id
            }
            .map { op in
                Result.HistoryEntry(
                    op_id: op.opId,
                    kind: op.kind.rawValue,
                    at: op.at,
                    user_response: op.provenance?.userResponse)
            }
        let result = Result(
            id: ann.id, kind: ann.kind.rawValue,
            paragraph_id: ann.paragraphId, body: ann.body,
            suggested_text: ann.suggestedText, prior_text: ann.priorText,
            status: ann.status.rawValue, user_response: ann.userResponse,
            created_at: ann.createdAt, resolved_at: ann.resolvedAt,
            is_stale: ann.isStale, history: history)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(result)
    }
}

// MARK: - Helpers

extension ListAnnotationsTool.Item {
    init(_ ann: Annotation) {
        self.init(
            id: ann.id, kind: ann.kind.rawValue,
            paragraph_id: ann.paragraphId, body: ann.body,
            suggested_text: ann.suggestedText, status: ann.status.rawValue,
            user_response: ann.userResponse, created_at: ann.createdAt,
            resolved_at: ann.resolvedAt, is_stale: ann.isStale)
    }
}
```

- [ ] **Step 4: Run test (PASS)**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationReadToolsTests -quiet 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/AnnotationReadTools.swift \
        MaughamTests/MCP/AnnotationReadToolsTests.swift
git commit -m "feat: 2 MCP read tools (list_annotations, get_annotation)"
```

---

### Task 15: Register the 6 tools

**Files:**
- Modify: `Maugham/MCP/MCPToolsListHandler.swift`
- Modify: `Maugham/MaughamApp.swift`

This is mechanical wiring — no new test for this task; the tool tests above already cover handler behavior. The smoke at Task 22 verifies registration via `tools/list`.

- [ ] **Step 1: Add 6 schemas to MCPToolsListHandler.swift**

Append to the schemas array (after the existing `list_all_links` entry, around line 65):

```swift
            ("add_comment",
             "Attach an editorial comment to a manuscript paragraph. Comments do not modify the manuscript; the user accepts or rejects them via the Annotations pane. Reject reasoning is captured for future sessions.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"paragraph_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"paragraph_id\",\"body\"]}"),

            ("add_suggested_change",
             "Propose a specific replacement for a paragraph. `body` is the editorial justification; `suggested_text` is the proposed new paragraph. The user accepts (applies the change) or rejects (with reasoning).",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"paragraph_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"suggested_text\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"paragraph_id\",\"body\",\"suggested_text\"]}"),

            ("add_query",
             "Ask the writer a question about a paragraph (intent, ambiguity, character motivation). The writer replies via the Annotations pane; the reply is persisted in the annotation history.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"paragraph_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"paragraph_id\",\"body\"]}"),

            ("add_craft_note",
             "Record a document-scoped craft observation (e.g., character voice rule, structural pattern). Doc-scoped; no paragraph anchor. Accepted craft notes surface in `list_annotations(kind: craft_note, status: accepted)` for next-session reference.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"body\"]}"),

            ("list_annotations",
             "List annotations on a document. Defaults to status=open. Filter by `kinds` (any of comment/suggested_change/query/craft_note), `statuses` (open/accepted/rejected/archived), `paragraph_id`. Use this to check prior editorial conversation on a paragraph before adding new suggestions.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"kinds\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"statuses\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"paragraph_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\"]}"),

            ("get_annotation",
             "Return a full annotation record including its lifecycle history (creation + accept/reject/archive ops).",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"annotation_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"annotation_id\"]}")
```

- [ ] **Step 2: Register the 6 handlers in MaughamApp.swift**

Append to `registerTools(...)` (after the existing `ListAllLinksTool` registration, around line 270):

```swift
        router.register(method: AddCommentTool.method) { params in
            try await AddCommentTool.handle(paramsJSON: params, registry: registry)
        }
        router.register(method: AddSuggestedChangeTool.method) { params in
            try await AddSuggestedChangeTool.handle(paramsJSON: params, registry: registry)
        }
        router.register(method: AddQueryTool.method) { params in
            try await AddQueryTool.handle(paramsJSON: params, registry: registry)
        }
        router.register(method: AddCraftNoteTool.method) { params in
            try await AddCraftNoteTool.handle(paramsJSON: params, registry: registry)
        }
        router.register(method: ListAnnotationsTool.method) { params in
            try await ListAnnotationsTool.handle(paramsJSON: params, registry: registry)
        }
        router.register(method: GetAnnotationTool.method) { params in
            try await GetAnnotationTool.handle(paramsJSON: params, registry: registry)
        }
```

- [ ] **Step 3: Build + smoke via the schema endpoint**

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Optional unit smoke**

If the harness exposes a way to invoke `MCPToolsListHandler.handle(...)` directly, add a small test that decodes the result and verifies tool count is 20 (14 existing + 6 new):

```swift
final class MCPToolsListSmokeTest: XCTestCase {
    func test_toolsList_includesAnnotationTools() async throws {
        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        let tools = json["tools"] as! [[String: Any]]
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: [
            "add_comment", "add_suggested_change", "add_query",
            "add_craft_note", "list_annotations", "get_annotation"
        ]))
        XCTAssertEqual(tools.count, 20)
    }
}
```

Place in `MaughamTests/MCP/MCPToolsListSmokeTest.swift`.

- [ ] **Step 5: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/MCP/MCPToolsListHandler.swift Maugham/MaughamApp.swift \
        MaughamTests/MCP/MCPToolsListSmokeTest.swift
git commit -m "feat: register 6 annotation MCP tools (registry 14 → 20)"
```

---

## Stage D — Annotations pane (SwiftUI)

### Task 16: DetailSegment + UIState + ⌘⌥A command

**Files:**
- Modify: `Maugham/Models/DetailSegment.swift`
- Modify: `Maugham/MaughamApp.swift` (command insert)

UIState already persists `detailSegment` via DocumentStore (see `DetailPaneToggle.onChange` at line 58-60 of that file). Adding the new case is sufficient — UIState codable will encode/decode it via raw value automatically because `DetailSegment` is already `Codable`.

- [ ] **Step 1: Add `.annotations` case**

Replace `Maugham/Models/DetailSegment.swift`:

```swift
import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable {
    case inspector
    case annotations
    case research
    case outline
    case history
}
```

- [ ] **Step 2: Add the ⌘⌥A command to MaughamApp.swift**

In `MaughamApp.swift`, in the View commands group (after the existing `Outline` button, around line 161), add:

```swift
                Button("Annotations") {
                    NotificationCenter.default.post(
                        name: .maughamSetDetailSegment,
                        object: nil,
                        userInfo: ["segment": "annotations"])
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED. The `ProjectWindow`'s `.maughamSetDetailSegment` handler (verified earlier at line 287) already dispatches by raw value via `DetailSegment(rawValue:)`, so no extra wiring needed.

Note: `DetailPaneToggle.segmentContent` still has no `.annotations` case — its `switch segment` is exhaustive over the old enum. Build will FAIL with a Swift compile error: "switch must be exhaustive." Add a temporary stub in `DetailPaneToggle.swift`:

```swift
        case .annotations:
            ContentUnavailableView(
                "Annotations pane coming online",
                systemImage: "bubble.left.and.bubble.right")
```

This stub is replaced in Task 21. Same for the `segmentPicker` — add a placeholder image:

```swift
            Image(systemName: "bubble.left.and.bubble.right")
                .tag(DetailSegment.annotations)
```

after the existing `inspector` tag (around line 75).

- [ ] **Step 4: Rebuild + run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. No regressions.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/DetailSegment.swift Maugham/MaughamApp.swift \
        Maugham/Views/DetailPaneToggle.swift
git commit -m "feat: add .annotations DetailSegment case + ⌘⌥A command (stub view)"
```

---

### Task 17: AnnotationsPane main view + AnnotationRow + sheets

**Files:**
- Create: `Maugham/Views/AnnotationsPane.swift`

UI-only task; no unit tests. The end-to-end test in Task 21 exercises lifecycle through the Document API which the pane drives.

- [ ] **Step 1: Create `Maugham/Views/AnnotationsPane.swift`**

```swift
import SwiftUI

/// Right-pane segment for editorial actions: accept/reject/archive
/// annotations created by Claude via MCP.
@MainActor
struct AnnotationsPane: View {
    @Bindable var document: Document

    @State private var kindFilter: KindOption = .all
    @State private var showResolved: Bool = false
    @State private var rejectSheet: Annotation?
    @State private var querySheet: Annotation?
    @State private var staleConfirm: Annotation?

    enum KindOption: String, CaseIterable, Identifiable {
        case all, comments, suggestions, queries, craft
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .comments: return "Comments"
            case .suggestions: return "Suggestions"
            case .queries: return "Queries"
            case .craft: return "Craft"
            }
        }
        var kind: AnnotationKind? {
            switch self {
            case .all: return nil
            case .comments: return .comment
            case .suggestions: return .suggestedChange
            case .queries: return .query
            case .craft: return .craftNote
            }
        }
    }

    private var filter: AnnotationFilter {
        let kinds: Set<AnnotationKind>? = kindFilter.kind.map { Set([$0]) }
        let statuses: Set<AnnotationStatus>? = showResolved ? nil : [.open]
        return AnnotationFilter(kinds: kinds, statuses: statuses)
    }

    private var visibleAnnotations: [Annotation] {
        // Observing annotationsVersion triggers re-render.
        _ = document.annotationsVersion
        return document.annotations(filter: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if visibleAnnotations.isEmpty {
                ContentUnavailableView(
                    "No annotations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Claude proposes; you dispose. Ask Claude for editorial feedback to see annotations here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleAnnotations) { ann in
                            AnnotationRow(
                                annotation: ann,
                                onAccept: { accept(ann) },
                                onReject: { rejectSheet = ann },
                                onArchive: { archive(ann) },
                                onReply: { querySheet = ann },
                                onJumpToParagraph: { jump(ann) })
                            Divider()
                        }
                    }
                }
            }
        }
        .sheet(item: $rejectSheet) { ann in
            RejectReasoningSheet(annotation: ann) { reason in
                Task { try? await document.rejectAnnotation(
                    id: ann.id, userResponse: reason) }
                rejectSheet = nil
            } onCancel: { rejectSheet = nil }
        }
        .sheet(item: $querySheet) { ann in
            QueryReplySheet(annotation: ann) { reply in
                Task { try? await document.acceptAnnotation(
                    id: ann.id, userResponse: reply) }
                querySheet = nil
            } onCancel: { querySheet = nil }
        }
        .alert(
            "Paragraph has changed since this suggestion",
            isPresented: Binding(
                get: { staleConfirm != nil },
                set: { if !$0 { staleConfirm = nil } })
        ) {
            Button("Apply anyway") {
                if let ann = staleConfirm {
                    Task { try? await document.acceptAnnotation(id: ann.id) }
                }
                staleConfirm = nil
            }
            Button("Cancel", role: .cancel) { staleConfirm = nil }
        } message: {
            Text("Applying this suggestion will replace the current paragraph text with the originally-proposed replacement.")
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(KindOption.allCases) { opt in
                Button(opt.label) {
                    kindFilter = opt
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(opt == kindFilter
                    ? Color.secondary.opacity(0.3)
                    : Color.clear)
                .clipShape(Capsule())
                .font(.caption)
            }
            Spacer()
            Toggle("Resolved", isOn: $showResolved)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    // MARK: - Actions

    private func accept(_ ann: Annotation) {
        if ann.kind == .suggestedChange && ann.isStale {
            staleConfirm = ann
            return
        }
        Task { try? await document.acceptAnnotation(id: ann.id) }
    }

    private func archive(_ ann: Annotation) {
        Task { try? await document.archiveAnnotation(id: ann.id) }
    }

    private func jump(_ ann: Annotation) {
        guard let pid = ann.paragraphId else { return }
        NotificationCenter.default.post(
            name: .maughamNavigateToParagraph,
            object: nil,
            userInfo: ["paragraph_id": pid])
    }
}

// MARK: - AnnotationRow

@MainActor
private struct AnnotationRow: View {
    let annotation: Annotation
    let onAccept: () -> Void
    let onReject: () -> Void
    let onArchive: () -> Void
    let onReply: () -> Void
    let onJumpToParagraph: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(annotation.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if annotation.kind == .suggestedChange {
                diffCard
            }
            actionRow
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onJumpToParagraph() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(kindLabel, systemImage: kindIcon)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            if annotation.isStale {
                Text("Stale")
                    .font(.caption2.smallCaps())
                    .padding(.horizontal, 4)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(relativeTimestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var diffCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let prior = annotation.priorText {
                Text("− \(prior)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            if let suggested = annotation.suggestedText {
                Text("+ \(suggested)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            switch annotation.kind {
            case .comment:
                Button("Got it", action: onAccept).buttonStyle(.borderedProminent)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .suggestedChange:
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                Button("Reject…", action: onReject).buttonStyle(.bordered)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .query:
                Button("Reply…", action: onReply).buttonStyle(.borderedProminent)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            case .craftNote:
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                Button("Reject…", action: onReject).buttonStyle(.bordered)
                Button("Archive", action: onArchive).buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var kindLabel: String {
        switch annotation.kind {
        case .comment: return "Comment"
        case .suggestedChange: return "Suggestion"
        case .query: return "Query"
        case .craftNote: return "Craft note"
        }
    }
    private var kindIcon: String {
        switch annotation.kind {
        case .comment: return "bubble.left"
        case .suggestedChange: return "wand.and.stars"
        case .query: return "questionmark.circle"
        case .craftNote: return "ruler"
        }
    }
    private var kindColor: Color {
        switch annotation.kind {
        case .comment: return .blue
        case .suggestedChange: return .orange
        case .query: return .purple
        case .craftNote: return .yellow
        }
    }
    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: annotation.createdAt, relativeTo: Date())
    }
}

// MARK: - Sheets

@MainActor
private struct RejectReasoningSheet: View {
    let annotation: Annotation
    let onReject: (String) -> Void
    let onCancel: () -> Void
    @State private var reason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why are you rejecting this?")
                .font(.headline)
            Text("Your reasoning is saved with the annotation so Claude can see it in future sessions.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $reason)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reject") {
                    onReject(reason.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

@MainActor
private struct QueryReplySheet: View {
    let annotation: Annotation
    let onReply: (String) -> Void
    let onCancel: () -> Void
    @State private var reply: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply")
                .font(.headline)
            Text(annotation.body)
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $reply)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reply") {
                    onReply(reply.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}
```

The `Notification.Name.maughamNavigateToParagraph` is new. It will be defined in Task 18 (or the implementer may grep for an existing scroll-to-paragraph notification; if one exists, use that instead and adjust the userInfo key accordingly).

- [ ] **Step 2: Build (will fail until Task 18 declares the notification name; that's fine)**

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -10
```

If `maughamNavigateToParagraph` is undefined, the build fails. Quick fix: add it provisionally to whichever file declares the other `maugham*` notification names. Grep:

```bash
grep -rn "maughamSetDetailSegment.*Notification.Name\|extension Notification.Name" Maugham | head -5
```

Add an extension in the same file:

```swift
extension Notification.Name {
    static let maughamNavigateToParagraph = Notification.Name(
        "maughamNavigateToParagraph")
}
```

- [ ] **Step 3: Build succeeds**

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED. The pane file is not yet wired into DetailPaneToggle — that happens in Task 18.

- [ ] **Step 4: Run full suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. No regressions; the pane file just sits unused.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/AnnotationsPane.swift Maugham/  # plus the Notification.Name file
git commit -m "feat: AnnotationsPane view + AnnotationRow + reject/reply sheets"
```

(The implementer fills in the exact paths for `git add` based on where they added the Notification.Name extension.)

---

### Task 18: Wire AnnotationsPane into DetailPaneToggle + handle navigate notification

**Files:**
- Modify: `Maugham/Views/DetailPaneToggle.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

The pane needs the active `Document` instance. DetailPaneToggle currently routes `activeDocId` and `documentStore` for the history pane; reuse those.

- [ ] **Step 1: Replace the stub in DetailPaneToggle.swift**

Replace the `.annotations` case in `segmentContent` (added as a placeholder in Task 16) with:

```swift
        case .annotations:
            annotationsPane
```

Then add this private property (next to `historyPane`):

```swift
    @ViewBuilder
    private var annotationsPane: some View {
        if let ds = documentStore,
           let docId = activeDocId,
           docId != "__no-selection__",
           let doc = ds.document(forDocId: docId) {
            AnnotationsPane(document: doc)
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "doc.text",
                description: Text("Open a manuscript to see and act on annotations."))
        }
    }
```

Also update `segmentPicker` to use a better SF Symbol than the placeholder. Replace the `bubble.left.and.bubble.right` line with:

```swift
            Image(systemName: "checklist")
                .tag(DetailSegment.annotations)
                .keyboardShortcut("a", modifiers: [.command, .option])
```

(The `.keyboardShortcut` on the picker tag is the SwiftUI idiom for binding a shortcut to a particular segment when the picker is visible — equivalent to the command-menu entry. Both are safe to register.)

- [ ] **Step 2: Handle `.maughamNavigateToParagraph` in ProjectWindow**

ProjectWindow already handles `.maughamNavigateToDocument`. Add a sibling handler near it (around line 304-309 in `ProjectWindow.swift`). The behaviour: select the document if not already selected, then scroll the editor to the paragraph anchor.

For v1, scrolling support inside the editor view isn't strictly required — the spec for Annotations pane just says "clicking on a card jumps the editor to that paragraph." Minimal implementation: select the document. Add a `TODO_FOLLOWUP` comment noting scroll-to-paragraph as a later refinement (anchored on the existing `.maughamNavigateToDocument`):

```swift
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamNavigateToParagraph)) { note in
                    // For v1, just ensure focus on the active manuscript;
                    // anchored scroll to paragraph_id is a follow-up.
                    _ = note.userInfo?["paragraph_id"] as? String
                    binderSegment = .manuscript
                }
```

- [ ] **Step 3: Build + run suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual UI smoke (single check)**

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -configuration Debug -quiet 2>&1 | tail -5
```

Open the app; open a project; press ⌘⌥A. Expected: Annotations pane visible, "No annotations" placeholder shown.

This is a sanity check only — no automated UI tests for the pane.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/DetailPaneToggle.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: wire AnnotationsPane into DetailPaneToggle + navigate handler"
```

---

## Stage E — HistoryPane (replaces CheckpointBrowserPane)

### Task 19: HistoryPane — unified op + checkpoint timeline

**Files:**
- Create: `Maugham/Views/HistoryPane.swift`
- Test: `MaughamTests/Views/HistoryEntryMergeTests.swift` (only the entry-merge logic; the SwiftUI body is UI-only)

The view extends what CheckpointBrowserPane does today (loads checkpoints from `CheckpointStore`), adds reading `document.opLog()`, merges into a unified `HistoryEntry` list, filters via pills, and renders per-kind rows.

- [ ] **Step 1: Write the merge-logic failing test**

```swift
import XCTest
@testable import Maugham

final class HistoryEntryMergeTests: XCTestCase {
    func test_merge_orderReverseChronological() {
        let now = Date()
        let opEarly = Op(
            opId: "01A", docId: "d", at: now.addingTimeInterval(-60),
            device: "x", session: "s", kind: .typingBurst,
            changes: [], sequence: nil, provenance: nil)
        let opLate = Op(
            opId: "01C", docId: "d", at: now.addingTimeInterval(-10),
            device: "x", session: "s", kind: .claudeComment,
            changes: [], sequence: nil,
            provenance: .init(annotationBody: "x"))
        let cpMid = Checkpoint(
            checkpointId: "cp1", at: now.addingTimeInterval(-30),
            label: "midpoint", manuscriptWordCount: 100,
            activeDoc: "doc.md", docPointers: [:])

        let merged = HistoryEntry.merge(
            ops: [opEarly, opLate], checkpoints: [cpMid])

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].timestamp, opLate.at)
        XCTAssertEqual(merged[1].timestamp, cpMid.at)
        XCTAssertEqual(merged[2].timestamp, opEarly.at)
    }

    func test_filter_annotationsPill_includesAllClaudeOps() {
        let now = Date()
        let comment = Op(opId: "1", docId: "d", at: now, device: "x",
                        session: "s", kind: .claudeComment, changes: [],
                        sequence: nil, provenance: nil)
        let accept = Op(opId: "2", docId: "d", at: now.addingTimeInterval(1),
                        device: "x", session: "s", kind: .claudeAccept,
                        changes: [], sequence: nil, provenance: nil)
        let burst = Op(opId: "3", docId: "d", at: now.addingTimeInterval(2),
                       device: "x", session: "s", kind: .typingBurst,
                       changes: [], sequence: nil, provenance: nil)
        let merged = HistoryEntry.merge(
            ops: [comment, accept, burst], checkpoints: [])
        let annotations = merged.filter {
            HistoryFilter.annotations.matches($0)
        }
        XCTAssertEqual(annotations.count, 2)
    }

    func test_filter_editsPill_includesTypingBurstAndBootstrap() {
        let now = Date()
        let burst = Op(opId: "1", docId: "d", at: now, device: "x",
                      session: "s", kind: .typingBurst, changes: [],
                      sequence: nil, provenance: nil)
        let bs = Op(opId: "2", docId: "d", at: now, device: "x",
                    session: "s", kind: .bootstrap, changes: [],
                    sequence: nil, provenance: nil)
        let ext = Op(opId: "3", docId: "d", at: now, device: "x",
                    session: "s", kind: .externalEdit, changes: [],
                    sequence: nil, provenance: nil)
        let merged = HistoryEntry.merge(ops: [burst, bs, ext], checkpoints: [])
        let edits = merged.filter { HistoryFilter.edits.matches($0) }
        XCTAssertEqual(edits.count, 2)  // burst + bootstrap, not external
    }
}
```

- [ ] **Step 2: Run test (FAIL)**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/HistoryEntryMergeTests -quiet 2>&1 | tail -10
```

- [ ] **Step 3: Create HistoryPane.swift with the merge logic + view**

```swift
import SwiftUI

// MARK: - History entry + filter

public enum HistoryEntry: Identifiable {
    case op(Op)
    case checkpoint(Checkpoint)

    public var id: String {
        switch self {
        case .op(let op): return "op:\(op.opId)"
        case .checkpoint(let cp): return "cp:\(cp.checkpointId)"
        }
    }
    public var timestamp: Date {
        switch self {
        case .op(let op): return op.at
        case .checkpoint(let cp): return cp.at
        }
    }

    public static func merge(
        ops: [Op], checkpoints: [Checkpoint]
    ) -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        all.append(contentsOf: ops.map(HistoryEntry.op))
        all.append(contentsOf: checkpoints.map(HistoryEntry.checkpoint))
        all.sort { $0.timestamp > $1.timestamp }
        return all
    }
}

public enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case checkpoints
    case edits
    case annotations
    case external

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All"
        case .checkpoints: return "Checkpoints"
        case .edits: return "Edits"
        case .annotations: return "Annotations"
        case .external: return "External"
        }
    }

    public func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .checkpoints:
            switch entry {
            case .checkpoint: return true
            case .op(let op):
                return op.kind == .checkpointRestore
            }
        case .edits:
            if case .op(let op) = entry {
                return op.kind == .typingBurst || op.kind == .bootstrap
            }
            return false
        case .annotations:
            if case .op(let op) = entry {
                switch op.kind {
                case .claudeComment, .claudeSuggestion, .claudeAccept,
                     .claudeReject, .claudeArchive, .claudeQuery,
                     .claudeCraftNote:
                    return true
                default: return false
                }
            }
            return false
        case .external:
            if case .op(let op) = entry {
                return op.kind == .externalEdit
            }
            return false
        }
    }
}

// MARK: - HistoryPane view

@MainActor
struct HistoryPane: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?

    @State private var filter: HistoryFilter = .all
    @State private var checkpoints: [Checkpoint] = []
    @State private var ops: [Op] = []
    @State private var expanded: Set<String> = []
    @State private var selectedCheckpoint: Checkpoint?
    @State private var showingRestorePicker: Bool = false

    private var entries: [HistoryEntry] {
        HistoryEntry.merge(ops: ops, checkpoints: checkpoints)
            .filter { filter.matches($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterToolbar
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HistoryRow(
                                entry: entry,
                                expanded: expanded.contains(entry.id),
                                onToggle: {
                                    if expanded.contains(entry.id) {
                                        expanded.remove(entry.id)
                                    } else {
                                        expanded.insert(entry.id)
                                    }
                                },
                                onJump: { jump(entry) },
                                onRevert: {
                                    if case .checkpoint(let cp) = entry {
                                        selectedCheckpoint = cp
                                        showingRestorePicker = true
                                    }
                                })
                            Divider()
                        }
                    }
                }
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(
            for: .maughamCheckpointSaved)) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingRestorePicker) {
            if let cp = selectedCheckpoint {
                PartialRestorePicker(
                    checkpoint: cp,
                    projectURL: projectURL,
                    activeDocId: activeDocId,
                    allDocIds: allDocIds,
                    device: device,
                    session: session,
                    docPaths: docPaths,
                    documentStore: documentStore,
                    onComplete: {
                        showingRestorePicker = false
                        Task { await reload() }
                    },
                    onCancel: { showingRestorePicker = false }
                )
            }
        }
    }

    @ViewBuilder
    private var filterToolbar: some View {
        HStack(spacing: 6) {
            ForEach(HistoryFilter.allCases) { f in
                Button(f.label) { filter = f }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(f == filter
                    ? Color.secondary.opacity(0.3) : Color.clear)
                .clipShape(Capsule())
                .font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func reload() async {
        if let loaded = try? await CheckpointStore(
            projectURL: projectURL).load() {
            checkpoints = loaded.filter { cp in
                // Show checkpoints relevant to the active doc, or
                // project-scoped (always shown).
                cp.docPointers[activeDocId] != nil || cp.docPointers.isEmpty
            }
        }
        if let ds = documentStore,
           let doc = ds.document(forDocId: activeDocId) {
            ops = (try? await doc.opLog()) ?? []
        } else {
            ops = []
        }
    }

    private func jump(_ entry: HistoryEntry) {
        guard case .op(let op) = entry,
              let pid = op.changes.first?.paragraphId else { return }
        NotificationCenter.default.post(
            name: .maughamNavigateToParagraph,
            object: nil,
            userInfo: ["paragraph_id": pid])
    }
}

// MARK: - HistoryRow

@MainActor
private struct HistoryRow: View {
    let entry: HistoryEntry
    let expanded: Bool
    let onToggle: () -> Void
    let onJump: () -> Void
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded {
                expandedDetail
            } else {
                collapsedPreview
            }
            if case .checkpoint = entry {
                Button("Revert here…", action: onRevert)
                    .controlSize(.small).buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { _ in onJump() })
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(kindLabel, systemImage: kindIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            Spacer()
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collapsedPreview: some View {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") edited")
                    .font(.caption).foregroundStyle(.secondary)
            case .claudeComment, .claudeQuery, .claudeCraftNote, .claudeSuggestion:
                Text(op.provenance?.annotationBody ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .claudeAccept:
                Text("Accepted suggestion")
                    .font(.caption).foregroundStyle(.secondary)
            case .claudeReject:
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .claudeArchive:
                Text(op.provenance?.synthesisSource == "paragraph_deleted"
                     ? "paragraph deleted" : "archived")
                    .font(.caption).foregroundStyle(.secondary)
            case .externalEdit:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") changed externally")
                    .font(.caption).foregroundStyle(.secondary)
            case .checkpoint, .checkpointRestore, .bootstrap:
                EmptyView()
            }
        case .checkpoint(let cp):
            Text("\(cp.manuscriptWordCount) words · \(cp.label)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch entry {
        case .op(let op):
            if op.kind == .claudeAccept || op.kind == .claudeSuggestion {
                ForEach(Array(op.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 1) {
                        if let prior = change.prior {
                            Text("− \(prior)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08))
                        }
                        Text("+ \(change.next)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                    }
                }
            } else if let body = op.provenance?.annotationBody {
                Text(body).font(.callout)
            } else if let resp = op.provenance?.userResponse {
                Text("\"\(resp)\"").italic().font(.callout)
            } else {
                collapsedPreview
            }
        case .checkpoint(let cp):
            Text(cp.label).font(.callout)
        }
    }

    private var kindLabel: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "Typed"
            case .claudeComment: return "Comment"
            case .claudeSuggestion: return "Suggestion"
            case .claudeAccept: return "Accepted"
            case .claudeReject: return "Rejected"
            case .claudeArchive: return "Archived"
            case .claudeQuery: return "Query"
            case .claudeCraftNote: return "Craft"
            case .externalEdit: return "External edit"
            case .checkpoint: return "Checkpoint"
            case .checkpointRestore: return "Reverted"
            case .bootstrap: return "Initial"
            }
        case .checkpoint:
            return "Checkpoint"
        }
    }
    private var kindIcon: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "pencil"
            case .claudeComment: return "bubble.left"
            case .claudeSuggestion: return "wand.and.stars"
            case .claudeAccept: return "checkmark.circle"
            case .claudeReject: return "xmark.circle"
            case .claudeArchive: return "archivebox"
            case .claudeQuery: return "questionmark.circle"
            case .claudeCraftNote: return "ruler"
            case .externalEdit: return "arrow.down.doc"
            case .checkpoint, .checkpointRestore: return "flag"
            case .bootstrap: return "circle.dashed"
            }
        case .checkpoint: return "flag"
        }
    }
    private var kindColor: Color {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst, .bootstrap: return .blue
            case .claudeComment: return .blue
            case .claudeSuggestion: return .orange
            case .claudeAccept: return .green
            case .claudeReject: return .red
            case .claudeArchive: return .gray
            case .claudeQuery: return .purple
            case .claudeCraftNote: return .yellow
            case .externalEdit: return .purple
            case .checkpoint, .checkpointRestore: return .green
            }
        case .checkpoint: return .green
        }
    }
}
```

Two notification names are referenced: `.maughamNavigateToParagraph` (added in Task 17) and `.maughamCheckpointSaved`. The latter may not exist yet; grep for it:

```bash
grep -rn "maughamCheckpointSaved\|Checkpoint.*saved" Maugham | head -5
```

If absent, add it to the same Notification.Name file you used in Task 17:

```swift
extension Notification.Name {
    static let maughamCheckpointSaved = Notification.Name(
        "maughamCheckpointSaved")
}
```

And — separately — find the existing checkpoint-save site and post the notification when checkpoints are saved (search for `CheckpointStore.*save\|saveCheckpoint`). If that adds scope, simply skip the auto-reload-on-save behaviour for v1 (the user can switch segments and back, or the next ⌘S triggers it). In that case, remove the `.onReceive(...maughamCheckpointSaved)` block from HistoryPane. The implementer chooses.

- [ ] **Step 4: Run merge tests**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/HistoryEntryMergeTests -quiet 2>&1 | tail -10
```

Expected: PASS (3 tests).

- [ ] **Step 5: Build the app**

```bash
xcodebuild build -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED. The pane is created but DetailPaneToggle still references CheckpointBrowserPane — that's swapped in Task 20.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/HistoryPane.swift \
        MaughamTests/Views/HistoryEntryMergeTests.swift \
        Maugham/  # plus notification-name file if updated
git commit -m "feat: HistoryPane with unified op + checkpoint timeline + filter pills"
```

---

### Task 20: Swap DetailPaneToggle → HistoryPane; delete CheckpointBrowserPane

**Files:**
- Modify: `Maugham/Views/DetailPaneToggle.swift`
- Delete: `Maugham/Views/CheckpointBrowserPane.swift`

- [ ] **Step 1: Replace `historyPane` in DetailPaneToggle**

In `Maugham/Views/DetailPaneToggle.swift` lines 113-131, replace the `historyPane` body:

```swift
    @ViewBuilder
    private var historyPane: some View {
        if let url = projectURL {
            HistoryPane(
                projectURL: url,
                activeDocId: activeDocId ?? "__no-selection__",
                allDocIds: allDocIds,
                device: device,
                session: session,
                docPaths: docPaths,
                documentStore: documentStore
            )
        } else {
            ContentUnavailableView(
                "History unavailable",
                systemImage: "clock.arrow.circlepath"
            )
        }
    }
```

- [ ] **Step 2: Delete CheckpointBrowserPane**

```bash
rm Maugham/Views/CheckpointBrowserPane.swift
```

If any other file references `CheckpointBrowserPane`, the build will fail and the implementer must clean up the references. Grep first to verify:

```bash
grep -rn "CheckpointBrowserPane" Maugham MaughamTests
```

Expected: only the DetailPaneToggle reference (which Step 1 just removed). If others exist, remove them.

- [ ] **Step 3: Build + run suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Manual UI smoke**

Open app → open project → click History segment in right pane. Expected: HistoryPane visible with filter pills + entries. Click a checkpoint row → "Revert here…" button appears → opens PartialRestorePicker as before.

- [ ] **Step 5: Commit**

```bash
git rm Maugham/Views/CheckpointBrowserPane.swift
git add Maugham/Views/DetailPaneToggle.swift
git commit -m "feat: replace CheckpointBrowserPane with HistoryPane"
```

---

## Stage F — End-to-end test + smoke

### Task 21: End-to-end annotation flow integration test

**Files:**
- Create: `MaughamTests/EndToEnd/AnnotationFlowTests.swift`

Spec test #10: "Claude adds via MCP → annotation appears in Document.annotations → user accepts via Document.acceptAnnotation → manuscript reflects change → list_annotations shows accepted state."

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

@MainActor
final class AnnotationFlowTests: XCTestCase {
    func test_end_to_end_addSuggestion_userAccepts_listShowsAccepted() async throws {
        let env = try await TestProjectEnvironment.makeWithSingleDoc(
            initialText: "She was angry.")
        let registry = ProjectRegistry()
        registry.register(url: env.projectURL, store: env.projectStore)

        let pid = (try await env.document.opLog())
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        let projectId = ProjectIdentifier.id(for: env.projectURL)
        let docId = env.document.docId

        // 1. Claude adds a suggestion via MCP.
        let mcpAddParams: [String: Any] = [
            "project_id": projectId,
            "document_id": docId,
            "paragraph_id": pid,
            "body": "show, don't tell",
            "suggested_text": "Her jaw clenched."
        ]
        let addData = try JSONSerialization.data(withJSONObject: mcpAddParams)
        let addResult = try JSONDecoder().decode(
            AddSuggestedChangeTool.Result.self,
            from: try await AddSuggestedChangeTool.handle(
                paramsJSON: addData, registry: registry))
        let annotationId = addResult.annotation_id

        // 2. Annotation appears in Document.annotations.
        let openList = env.document.annotations()
        XCTAssertEqual(openList.count, 1)
        XCTAssertEqual(openList[0].id, annotationId)
        XCTAssertEqual(openList[0].kind, .suggestedChange)
        XCTAssertEqual(openList[0].status, .open)

        // 3. User accepts via Document.acceptAnnotation.
        try await env.document.acceptAnnotation(id: annotationId)

        // 4. Manuscript reflects the change.
        XCTAssertEqual(env.document.displayText, "Her jaw clenched.")

        // 5. list_annotations (via MCP) shows accepted state.
        let listParams: [String: Any] = [
            "project_id": projectId,
            "document_id": docId,
            "statuses": ["accepted"]
        ]
        let listData = try JSONSerialization.data(withJSONObject: listParams)
        let listResult = try JSONDecoder().decode(
            [ListAnnotationsTool.Item].self,
            from: try await ListAnnotationsTool.handle(
                paramsJSON: listData, registry: registry))
        XCTAssertEqual(listResult.count, 1)
        XCTAssertEqual(listResult[0].id, annotationId)
        XCTAssertEqual(listResult[0].status, "accepted")
    }
}
```

- [ ] **Step 2: Run test**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/AnnotationFlowTests -quiet 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/EndToEnd/AnnotationFlowTests.swift
git commit -m "test: end-to-end annotation flow (MCP add → accept → manuscript update)"
```

---

### Task 22: Final smoke + EditorIntegrationHarness verification

The conformance contract is the 10 EditorIntegrationHarness tests + the original 715-test baseline. Final sweep confirms nothing regressed.

**Files:** (none modified)

- [ ] **Step 1: Run the entire test suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' 2>&1 | tail -30
```

Expected output:
- `** TEST SUCCEEDED **`
- Test count >= 715 + new tests. Tally per task:
  - T2: +1
  - T3: +2
  - T4: +4
  - T5: +2
  - T6: +7
  - T7: +2
  - T8: +3
  - T9: +3
  - T10: +2
  - T11: +1
  - T12: +2
  - T13: +3
  - T14: +2
  - T15: +1
  - T19: +3
  - T21: +1
  - Total: +39 → final ≈ 754.

If the number is lower, a test was deleted; the implementer should investigate.

- [ ] **Step 2: Specifically verify the EditorIntegrationHarness suite**

```bash
xcodebuild test -scheme Maugham -destination 'platform=macOS' \
  -only-testing:MaughamTests/EditorIntegrationHarness -quiet 2>&1 | tail -10
```

Expected: all 10 tests pass. If the exact name differs, find it via:

```bash
grep -rn "class.*Harness.*XCTestCase\|EditorIntegrationHarness" MaughamTests | head -5
```

- [ ] **Step 3: Manual UI smoke checklist** (5 minutes; record in commit message)

Open the app and walk through:

1. ⌘N → create a new project → open it.
2. Right pane: confirm 5 segments visible (Inspector, Annotations, Research, Outline, History).
3. ⌘⌥A → Annotations pane opens with "No annotations" placeholder.
4. Use Claude Desktop (or a manual MCP probe) to call `add_comment` against the active document → expect the comment to appear in the pane within 1 second.
5. Click "Got it" → comment disappears from default view; toggle "Resolved" → comment reappears with accepted status.
6. ⌘⌥4 → HistoryPane: confirm filter pills (All / Checkpoints / Edits / Annotations / External). Click each pill; rows filter as expected. Click a checkpoint row → "Revert here…" button → PartialRestorePicker opens.
7. Edit the manuscript by hand → ⌘S → confirm typing_burst entry appears in History under "Edits" filter.

- [ ] **Step 4: Commit final smoke note**

```bash
git commit --allow-empty -m "chore: final smoke pass — 754 tests passing; UI walk verified"
```

- [ ] **Step 5: Tag**

```bash
git tag milestone-editing
```

Push the tag after the user reviews and merges the branch (do not push without confirmation).

---

## Self-Review Checklist

This section is a record of the self-review performed after writing the plan.

### Spec coverage

- §1.1 OpKind +4 cases → Task 2 ✓
- §1.2 Provenance +3 fields → Task 3 ✓
- §1.3 changes/sequence reuse → covered by Task 9 (suggestedChange accept replays the change) ✓
- §2.1 Annotation types → Task 4 ✓
- §2.2 Document API: addAnnotation/acceptAnnotation/rejectAnnotation/archiveAnnotation/annotations(filter:) → Tasks 7, 8, 9, 10 ✓
- §2.3 derived-state mechanics + annotationsVersion → Task 7 ✓
- §2.4 membrane semantics → Task 9 (suggestedChange replays, other kinds status-only) ✓
- §2.5 stale handling → Task 11 (deriver computes isStale; UI confirm in Task 17) ✓
- §2.6 paragraph-deletion auto-archive → Task 12 ✓
- §2.7 single-observable-write discipline → annotated in Task 7 + 9 ✓
- §3.1 four creation tools → Task 13 ✓
- §3.2 two read tools → Task 14 ✓
- §3.3 registration → Task 15 ✓
- §3.4 no lifecycle tools — confirmed not implemented ✓
- §4.1–4.4 AnnotationsPane + rows + sheets → Task 17 ✓
- §4.5 DetailSegment integration → Task 16 ✓
- §4.6 ⌘⌥A → Task 16 ✓
- §4.7 ProjectWindow wiring → Task 18 ✓
- §5.1–5.5 HistoryPane replaces CheckpointBrowserPane → Tasks 19, 20 ✓
- §5.6 read-only annotations in History → encoded in HistoryRow (no accept/reject buttons) ✓
- §5.7 LazyVStack performance → Task 19 ✓
- §5.8 file mechanics: delete + create + keep + update DetailPaneToggle → Task 20 ✓
- §6.1 migration (additive) → no migration task needed ✓
- §6.2 10 new tests → distributed across Tasks 8, 9, 10, 11, 12, 14, 21 ✓
- §7 decisions table → encoded throughout ✓

### Placeholder scan

Searched for forbidden patterns:
- `TBD`, `TODO`, `implement later`, `fill in details`, `Add appropriate error handling`, `Similar to Task N` (verbatim): **none found in plan source text**.
- One `TODO_FOLLOWUP` exists in Task 18 (scroll-to-paragraph deferred) — this is an explicit deferral with rationale, not a plan placeholder.

### Type consistency

Methods named consistently across tasks:
- `addAnnotation(kind:paragraphId:body:suggestedText:prompt:toolArgs:) async throws -> String` (Task 8 definition; used in Tasks 9, 12, 13, 17, 21).
- `acceptAnnotation(id:userResponse:) async throws` (Task 9 definition; used in Tasks 10, 17, 21).
- `rejectAnnotation(id:userResponse:) async throws` (Task 10 definition; used in Task 17).
- `archiveAnnotation(id:) async throws` (Task 10 definition; used in Tasks 14, 17).
- `annotations(filter:) -> [Annotation]` (Task 7 definition; used in Tasks 8–14, 17).
- `opLog() async throws -> [Op]` (Task 5 definition; used in Tasks 7, 14, 19, 21).
- `annotationsVersion: Int` (Task 7 definition; used in Task 17).
- `sweepOrphanedAnnotations()` (Task 12 only; private).

MCP tool symbols consistent: `AddCommentTool` / `AddSuggestedChangeTool` / `AddQueryTool` / `AddCraftNoteTool` / `ListAnnotationsTool` / `GetAnnotationTool` — same names in Tasks 13, 14, 15, 21.

`HistoryEntry` / `HistoryFilter` — defined Task 19, used same file only.

`AnnotationKind` raw values: `comment` / `suggested_change` / `query` / `craft_note` — consistent in Tasks 4, 13, 14, 15, 17.

### Notable risks captured in-plan

- Task 7 — `_opLogMirror` plumbing touches every existing `opStore.append` call site. Risk: missing a site → cache drift. Mitigation: explicit grep step in implementer instructions.
- Task 12 — sweep is fire-and-forget on sync mutation paths. Risk: tests race the sweep. Mitigation: explicit `Task.sleep` yield in tests + comment on the sweep method.
- Task 17 — `maughamNavigateToParagraph` is new. Risk: notification namespace collision. Mitigation: grep step in Task 17.
- Task 19 — `maughamCheckpointSaved` may not exist. Mitigation: explicit grep + skip behaviour if absent.
- Task 20 — `CheckpointBrowserPane` may have unexpected references. Mitigation: explicit grep step.

---

## Plan complete

The plan above implements the approved spec at `docs/superpowers/specs/2026-05-19-editing-annotations-history-design.md` across 22 tasks organized into 6 stages (A–F). Tasks 1–4 establish the schema, 5–12 build the Document API, 13–15 add the MCP surface, 16–18 ship the Annotations pane, 19–20 replace CheckpointBrowserPane with HistoryPane, and 21–22 verify end-to-end + run final smoke.

**Execution:** subagent-driven (recommended). Model assignment per task:
- haiku: 1, 2, 3, 15, 16, 20, 22
- sonnet: 4, 5, 6, 8, 10, 11, 13, 14, 18, 21
- opus: 7, 9, 12, 17, 19

Skip full two-stage review for the haiku tasks (per project convention).







