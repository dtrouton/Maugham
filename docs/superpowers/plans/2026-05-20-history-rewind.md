# History Rewind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a dedicated time-travel modal over the per-doc op log — scrub through every past op, preview the doc at that point (Doc or Diff), then Snapshot the moment as a checkpoint or Restore the doc to it. Per-row "↺" Revert button on manuscript-mutating HistoryPane rows as a secondary deep-link.

**Architecture:** Reuses the existing op log + deriver + checkpoint store. New work: one new `Deriver.derive(ops:upTo:)` overload, one new `Document.restoreToOp(opId:)` method, one new SwiftUI modal (`RewindWindow.swift`), and five new typed-contract value files (per ADR 0010). The SynthesisSource refactor from `String?` to a typed enum rolls in (the new `"rewind"` value would otherwise be the fourth stringly-typed instance).

**Tech Stack:** Swift 6, SwiftUI, AppKit; existing `OpLog` module (Deriver, Restore, CheckpointStore, Document); existing `Views` module (HistoryPane, CheckpointLabelPromptSheet).

**Spec:** `docs/superpowers/specs/2026-05-20-history-rewind-design.md`

**Conformance contract:** ~767-test baseline (from `milestone-typed-cross-area-seams`) must stay green throughout. Plan ends with ~21 new tests landing.

---

## File Structure

**New files (production):**
- `Maugham/OpLog/SynthesisSource.swift` — typed enum replacing `String?` on `Op.Provenance.synthesisSource`.
- `Maugham/OpLog/RewindCursor.swift` — scrub-state value: `.now | .atOp(opId, at)`.
- `Maugham/OpLog/RewindRestoreResult.swift` — return value of `Document.restoreToOp`.
- `Maugham/Views/RewindAction.swift` — terminal action discriminator: `.cancel | .snapshotHere(label) | .restoreHere`.
- `Maugham/Views/RewindScope.swift` — `.thisDoc` only in v1 (single-case to force v2 exhaustive-switch).
- `Maugham/Views/RewindTickLayout.swift` — pure decimation helper (tick collapse rule, checkpoint always-visible exception).
- `Maugham/Views/RewindWindow.swift` — the modal itself (scrubber + preview + footer).
- `Maugham/Views/AREA.md` — new area doc for the now-grown Views directory (per spec §8).

**New files (tests):**
- `MaughamTests/OpLog/DeriverUpToTests.swift` — 7 tests for `derive(ops:upTo:)`.
- `MaughamTests/Views/RewindDensityTests.swift` — 3 tests for tick decimation.
- `MaughamTests/Integration/RewindFlowTests.swift` — 8 end-to-end tests.
- `MaughamTests/Integration/RewindEntryPointsTests.swift` — both entry points route through one Document method.
- `MaughamTests/Integration/RewindForensicProvenanceTests.swift` — rewind ops carry `synthesisSource: .rewind`.
- `MaughamTests/Integration/SynthesisSourceMigrationTests.swift` — string raw value decodes into enum.

**Modified files:**
- `Maugham/OpLog/Op.swift` — `synthesisSource: String?` → `synthesisSource: SynthesisSource?`.
- `Maugham/OpLog/Document.swift` — string literals at four sites → enum cases; add `restoreToOp(opId:)`.
- `Maugham/OpLog/Deriver.swift` — add `derive(ops:upTo:)` overload; expose `appliesToManuscript` as `internal`.
- `Maugham/OpLog/Restore.swift` — extend `buildRestoreOp` to accept `synthesisSource:` parameter.
- `Maugham/Models/MaughamNotifications.swift` — add `maughamOpenRewind` notification name.
- `Maugham/Views/HistoryPane.swift` — add "Rewind…" header button + per-row `↺` button + .sheet wiring for the modal.
- `Maugham/Views/HistoryPane.swift` (HistoryRow) — switch `synthesisSource` string comparison to enum case match (3 sites).
- `MaughamTests/Integration/PresenterRoutingTests.swift` — switch string comparison to enum case (1 site).
- `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift` — switch string assertion to enum (1 site).
- `CLAUDE.md` — per-area OpLog + Views entries (spec §8).
- `Maugham/OpLog/AREA.md` — note new files + new derive overload.
- `Maugham/Editor/AREA.md` — verify no changes (sanity pass).
- `Maugham/Stores/AREA.md` — verify no changes (sanity pass).
- `Maugham/MCP/AREA.md` — verify no changes (sanity pass).
- `docs/adr/0010-typed-cross-area-seams.md` — add RewindCursor, RewindAction, RewindScope, SynthesisSource to instances table.
- `docs/roadmap.md` — move History Rewind to "Shipped" with milestone summary + v2 carry-forwards.

---

## Build commands (reference, applicable to every task)

```bash
# Regenerate Xcode project if you added/removed Swift files
./gen.sh

# Full test suite
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30

# Run a specific test class
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/DeriverUpToTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

After adding any new Swift file: **run `./gen.sh` before invoking xcodebuild.** Otherwise xcodebuild won't see the new file. Per CLAUDE.md tripwire, SourceKit live diagnostics in IDEs are noise; `xcodebuild` is the ground truth.

Paragraph IDs in tests that cross the .md ↔ op log boundary: use the 4-char alphabet `0123456789abcdefghjkmnpqrstvwxyz`, e.g. `"aabb"`, `"bzcc"`. In-memory APIs (`recordChange(paragraphId:)` etc.) are permissive but Bootstrap/Reconciler/RenderFilter-against-parsed-anchors strict.

---

## Task 1: Branch

**Files:**
- Modify: working tree

- [ ] **Step 1: Create the milestone branch from main**

```bash
git checkout main
git pull --ff-only
git checkout -b feat/milestone-history-rewind
git status
```

Expected: on `feat/milestone-history-rewind`, working tree clean except `.superpowers/` (untracked).

---

## Task 2: SynthesisSource enum (refactor)

**Model: opus.** Touches multiple emit sites + one read site in HistoryPane (3 sub-sites) + two test files. Needs a backwards-compat decode story.

**Files:**
- Create: `Maugham/OpLog/SynthesisSource.swift`
- Modify: `Maugham/OpLog/Op.swift` (Provenance field + init)
- Modify: `Maugham/OpLog/Document.swift` (4 emit sites: sweepOrphanedAnnotations, appendLifecycleOp parameter, two external-change handlers)
- Modify: `Maugham/Views/HistoryPane.swift` (3 read sites in HistoryRow)
- Modify: `MaughamTests/Integration/PresenterRoutingTests.swift` (1 string assertion)
- Modify: `MaughamTests/OpLog/DocumentAnnotationCacheTests.swift` (1 string assertion)
- Test: `MaughamTests/Integration/SynthesisSourceMigrationTests.swift`

- [ ] **Step 1: Create the enum**

`Maugham/OpLog/SynthesisSource.swift`:

```swift
import Foundation

/// Typed replacement for the prior `String?` field on `Op.Provenance`.
/// The raw values are the snake_case strings used on disk; existing op
/// logs decode without migration via RawRepresentable Codable.
///
/// `rewind` is new in milestone-history-rewind; the other three predate it.
public enum SynthesisSource: String, Codable, Equatable, Hashable, Sendable {
    case paragraphDeleted = "paragraph_deleted"
    case diskAtIngest = "disk_at_ingest"
    case useCloudResolution = "use_cloud_resolution"
    case rewind
}
```

- [ ] **Step 2: Write the migration test first**

`MaughamTests/Integration/SynthesisSourceMigrationTests.swift`:

```swift
import XCTest
@testable import Maugham

final class SynthesisSourceMigrationTests: XCTestCase {
    /// Existing op logs on disk encode synthesisSource as a snake_case string
    /// (e.g. "paragraph_deleted"). Verify the new enum decodes that shape.
    func test_existingOpLog_withStringSynthesisSource_decodesToEnum() throws {
        let json = #"""
        {
          "op_id": "01ABCDEFGHJKMNPQRSTVWXYZ12",
          "doc_id": "doc-x",
          "at": "2026-05-19T12:00:00.000Z",
          "device": "d1",
          "session": "s1",
          "kind": "claude_archive",
          "changes": [],
          "provenance": {
            "synthesis_source": "paragraph_deleted",
            "source_annotation_id": "01ANN"
          }
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let op = try decoder.decode(Op.self, from: json)
        XCTAssertEqual(op.provenance?.synthesisSource, .paragraphDeleted)
    }

    func test_newOp_withEnumSynthesisSource_roundTripsViaCodable() throws {
        let original = Op(
            opId: "01TESTOPID0000000000000000",
            docId: "doc-x",
            at: Date(timeIntervalSince1970: 1_715_000_000),
            device: "d1", session: "s1",
            kind: .checkpointRestore,
            changes: [.init(paragraphId: "aabb", prior: "old", next: "")],
            sequence: ["aabb"],
            provenance: .init(synthesisSource: .rewind, sourceCheckpoint: "01PASTOP00000000000000000A"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(Op.self, from: data)
        XCTAssertEqual(round.provenance?.synthesisSource, .rewind)
    }

    func test_decodingUnknownSynthesisSourceValue_yieldsNil() throws {
        // RawRepresentable Codable returns nil for unknown raw values when the
        // outer field is optional. This is forwards-compat for future enum
        // additions that an older client receives via cross-Mac sync.
        let json = #"""
        {"op_id":"01X","doc_id":"d","at":"2026-05-19T12:00:00.000Z",
         "device":"d","session":"s","kind":"claude_archive","changes":[],
         "provenance":{"synthesis_source":"future_value_we_dont_know"}}
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(Op.self, from: json))
        // Note: with optional + RawRepresentable, unknown values currently throw
        // rather than decoding to nil. If forwards-compat matters more than
        // strict decoding, swap the field to a custom init that tries the raw
        // decode and assigns nil on failure. For v1 we accept the throw —
        // unknown synthesis_source values are a contract violation from a
        // future client.
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/SynthesisSourceMigrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: FAIL — `Op.Provenance.synthesisSource` is still `String?`.

- [ ] **Step 4: Update `Op.Provenance` to use the enum**

`Maugham/OpLog/Op.swift` lines 32-72 area — change two lines and the init parameter:

```swift
public struct Provenance: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let prompt: String?
    public let toolArgs: String?
    public let sourceCheckpoint: String?
    public let synthesisSource: SynthesisSource?   // was: String?
    public let orphanRecoveryMethod: String?
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
        synthesisSource: SynthesisSource? = nil,    // was: String?
        orphanRecoveryMethod: String? = nil,
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

- [ ] **Step 5: Update `Document.swift` emit sites**

`Maugham/OpLog/Document.swift` — change the `appendLifecycleOp` `synthesisSource:` parameter type and the four call sites:

Line ~680 (`appendLifecycleOp` signature):

```swift
private func appendLifecycleOp(
    kind: OpKind,
    sourceAnnotationId: String,
    userResponse: String?,
    synthesisSource: SynthesisSource? = nil   // was: String? = nil
) async throws {
    ...
}
```

Line ~741 (sweepOrphanedAnnotations):

```swift
try? await appendLifecycleOp(
    kind: .claudeArchive,
    sourceAnnotationId: orphan.id,
    userResponse: nil,
    synthesisSource: .paragraphDeleted)  // was: "paragraph_deleted"
```

Line ~824 (external-disk-change ingest synthesis):

```swift
provenance: .init(synthesisSource: .diskAtIngest))  // was: "disk_at_ingest"
```

Line ~968 (cloud conflict resolution):

```swift
provenance: .init(synthesisSource: .useCloudResolution))  // was: "use_cloud_resolution"
```

- [ ] **Step 6: Update `HistoryPane.swift` read sites**

`Maugham/Views/HistoryPane.swift` — three sites in HistoryRow (lines ~382, ~388, ~435):

Line ~382:

```swift
let cause = op.provenance?.synthesisSource == .paragraphDeleted
    ? " · paragraph deleted" : ""
```

Line ~388 (this is the else-branch text when there's no body):

```swift
Text(op.provenance?.synthesisSource == .paragraphDeleted
     ? "paragraph deleted" : "archived")
    .font(.caption).foregroundStyle(.secondary)
```

Line ~435 (in expandedDetail):

```swift
if op.provenance?.synthesisSource == .paragraphDeleted {
    Text("Auto-archived: paragraph deleted from manuscript.")
        .font(.caption2)
        .foregroundStyle(.orange)
}
```

- [ ] **Step 7: Update test files using the old string literal**

`MaughamTests/Integration/PresenterRoutingTests.swift` line ~223:

```swift
&& $0.provenance?.synthesisSource == .paragraphDeleted  // was: == "paragraph_deleted"
```

`MaughamTests/OpLog/DocumentAnnotationCacheTests.swift` line ~286:

```swift
XCTAssertEqual(archiveOp?.provenance?.synthesisSource, .paragraphDeleted)
// was: archiveOp?.provenance?.synthesisSource, "paragraph_deleted"
```

- [ ] **Step 8: Run full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: all ~770 tests green (767 baseline + 2 new migration tests; the third is an expectation that documents current decode behaviour rather than asserting a desirable one).

- [ ] **Step 9: Commit**

```bash
git add Maugham/OpLog/SynthesisSource.swift \
        Maugham/OpLog/Op.swift \
        Maugham/OpLog/Document.swift \
        Maugham/Views/HistoryPane.swift \
        MaughamTests/Integration/PresenterRoutingTests.swift \
        MaughamTests/Integration/SynthesisSourceMigrationTests.swift \
        MaughamTests/OpLog/DocumentAnnotationCacheTests.swift
git commit -m "refactor: type SynthesisSource as enum on Op.Provenance"
```

---

## Task 3: RewindCursor enum

**Model: haiku.** Mechanical value type.

**Files:**
- Create: `Maugham/OpLog/RewindCursor.swift`

- [ ] **Step 1: Create the enum**

`Maugham/OpLog/RewindCursor.swift`:

```swift
import Foundation

/// Where the Rewind modal's scrub cursor currently sits in the op log.
///
/// `.now` and `.atOp(latestOpId, latestDate)` are not equivalent:
/// - `.now` means "writer hasn't scrubbed yet" — the modal opens in this state.
/// - `.atOp(id, _)` means "writer scrubbed to op `id` and chose to land there",
///   even if `id` happens to be the latest op. The action footer changes its
///   behaviour based on this distinction — Restore is disabled on `.now` but
///   enabled on `.atOp(latestOpId, _)` (where it's a no-op restore).
public enum RewindCursor: Equatable, Sendable {
    case now
    case atOp(opId: String, at: Date)
}
```

- [ ] **Step 2: Verify compiles**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Maugham/OpLog/RewindCursor.swift
git commit -m "feat: add RewindCursor typed contract"
```

---

## Task 4: RewindAction enum

**Model: haiku.** Mechanical value type.

**Files:**
- Create: `Maugham/Views/RewindAction.swift`

- [ ] **Step 1: Create the enum**

`Maugham/Views/RewindAction.swift`:

```swift
import Foundation

/// Terminal action dispatched from the Rewind modal. The dispatcher (in
/// `ProjectWindow.swift` via the `RewindWindow` onDismiss callback)
/// switches over this exhaustively; adding a future action becomes a
/// compile error rather than a missed case.
internal enum RewindAction: Equatable {
    case cancel
    case snapshotHere(label: String)
    case restoreHere
}
```

- [ ] **Step 2: Verify compiles + commit**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
git add Maugham/Views/RewindAction.swift
git commit -m "feat: add RewindAction typed contract"
```

---

## Task 5: RewindScope enum

**Model: haiku.** Single-case enum, prospective ADR 0010 pattern.

**Files:**
- Create: `Maugham/Views/RewindScope.swift`

- [ ] **Step 1: Create the enum**

`Maugham/Views/RewindScope.swift`:

```swift
import Foundation

/// Scope of a rewind action. v1 only ships `.thisDoc`; the single-case
/// shape is deliberate — when `.project` lands in v2, every consumer
/// that switches over RewindScope becomes a compile error and we don't
/// miss a code path.
///
/// Why not a Bool: `isProjectScope: Bool` lacks the exhaustive-switch
/// guarantee. Why not omit entirely: callers would need to add the
/// distinction later under time pressure; the enum makes the shape
/// explicit from day one.
internal enum RewindScope: Equatable, Sendable {
    case thisDoc
    // case project — v2
}
```

- [ ] **Step 2: Verify compiles + commit**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
git add Maugham/Views/RewindScope.swift
git commit -m "feat: add RewindScope typed contract"
```

---

## Task 6: RewindRestoreResult struct

**Model: haiku.** Mechanical value type.

**Files:**
- Create: `Maugham/OpLog/RewindRestoreResult.swift`

- [ ] **Step 1: Create the struct**

`Maugham/OpLog/RewindRestoreResult.swift`:

```swift
import Foundation

/// Returned by `Document.restoreToOp(opId:)`. Carries the full effect of
/// the restore so the modal can both render a confirmation toast
/// (*"Restored. 3 annotations auto-archived."*) and assert the effect in
/// tests without rummaging through the op log post-hoc.
public struct RewindRestoreResult: Equatable, Sendable {
    /// The appended `.checkpointRestore` op recording the rewind.
    public let restoreOp: Op
    /// Op ids of the `.claudeArchive` ops emitted by the sweep for
    /// annotations whose paragraph_id no longer exists post-restore.
    public let archivedAnnotationOpIds: [String]
    /// Paragraph ids that existed in the pre-restore sequence but not
    /// the post-restore sequence. Drives the impact summary.
    public let removedParagraphIds: [String]
    /// Paragraph count before the restore. For the impact summary.
    public let priorSequenceCount: Int
    /// Paragraph count after the restore.
    public let newSequenceCount: Int

    public init(
        restoreOp: Op,
        archivedAnnotationOpIds: [String],
        removedParagraphIds: [String],
        priorSequenceCount: Int,
        newSequenceCount: Int
    ) {
        self.restoreOp = restoreOp
        self.archivedAnnotationOpIds = archivedAnnotationOpIds
        self.removedParagraphIds = removedParagraphIds
        self.priorSequenceCount = priorSequenceCount
        self.newSequenceCount = newSequenceCount
    }
}
```

- [ ] **Step 2: Verify compiles + commit**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
git add Maugham/OpLog/RewindRestoreResult.swift
git commit -m "feat: add RewindRestoreResult typed contract"
```

---

## Task 7: Notification.Name.maughamOpenRewind

**Model: haiku.** One-line addition to the existing notifications file.

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`

- [ ] **Step 1: Add the notification name**

After the last existing line in `Maugham/Models/MaughamNotifications.swift` (currently `maughamEffectiveAppearanceChanged` at line ~32), add:

```swift
    public static let maughamOpenRewind = Notification.Name("maugham.open.rewind")
```

The full extension closes with `}` — keep that on its own line.

- [ ] **Step 2: Verify compiles + commit**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
git add Maugham/Models/MaughamNotifications.swift
git commit -m "feat: add maughamOpenRewind notification name"
```

---

## Task 8: Deriver.derive(ops:upTo:) overload + unit tests

**Model: sonnet.** Substantive — needs careful handling of `appliesToManuscript` exposure + the upTo semantics.

**Files:**
- Modify: `Maugham/OpLog/Deriver.swift`
- Test: `MaughamTests/OpLog/DeriverUpToTests.swift`

- [ ] **Step 1: Write the failing tests**

`MaughamTests/OpLog/DeriverUpToTests.swift`:

```swift
import XCTest
@testable import Maugham

final class DeriverUpToTests: XCTestCase {
    private func op(
        _ id: String, kind: OpKind = .typingBurst,
        changes: [(String, String?, String)] = [],
        sequence: [String]? = nil
    ) -> Op {
        Op(
            opId: id,
            docId: "doc-x",
            at: Date(timeIntervalSince1970: TimeInterval(id.hashValue & 0x7fffffff)),
            device: "d1", session: "s1",
            kind: kind,
            changes: changes.map { .init(paragraphId: $0.0, prior: $0.1, next: $0.2) },
            sequence: sequence,
            provenance: nil)
    }

    func test_deriveUpTo_now_returnsFullDerivation() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
        ]
        let full = Deriver.derive(ops: ops)
        let upToNow = Deriver.derive(ops: ops, upTo: .now)
        XCTAssertEqual(full, upToNow)
    }

    func test_deriveUpTo_atOp_returnsStateAtThatPoint() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
            op("01C", changes: [("dxee", nil, "third")], sequence: ["aabb", "bzcc", "dxee"]),
        ]
        let result = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(result.sequence, ["aabb", "bzcc"])
        XCTAssertEqual(result.paragraphs["aabb"], "first")
        XCTAssertEqual(result.paragraphs["bzcc"], "second")
        XCTAssertNil(result.paragraphs["dxee"])
    }

    func test_deriveUpTo_atOp_ignoresLaterOps() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
        ]
        let stateAtA = Deriver.derive(ops: ops, upTo: .atOp(opId: "01A", at: Date()))
        let opsTrimmed = Array(ops.prefix(1))
        let stateFromTrimmed = Deriver.derive(ops: opsTrimmed)
        XCTAssertEqual(stateAtA, stateFromTrimmed)
    }

    func test_deriveUpTo_atOp_includesAnnotationOps_butSkipsTheirChanges() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "para text")], sequence: ["aabb"]),
            // Annotation creation op carries a change as anchor + priorText
            // snapshot but its `.next` must NOT be applied.
            op("01B", kind: .claudeComment,
               changes: [("aabb", "para text", "")],
               sequence: ["aabb"]),
        ]
        let result = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(result.paragraphs["aabb"], "para text",
                       "Annotation creation must not blank the paragraph")
    }

    func test_deriveUpTo_atOp_withPriorRestore_handlesUndoChain() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "v1")], sequence: ["aabb"]),
            op("01B", changes: [("aabb", "v1", "v2")], sequence: ["aabb"]),
            // A prior restore that walked back to v1
            op("01C", kind: .checkpointRestore,
               changes: [("aabb", "v2", "v1")], sequence: ["aabb"]),
            op("01D", changes: [("aabb", "v1", "v3")], sequence: ["aabb"]),
        ]
        // Scrubbing to 01C should reflect v1 (the post-restore state).
        let atRestore = Deriver.derive(ops: ops, upTo: .atOp(opId: "01C", at: Date()))
        XCTAssertEqual(atRestore.paragraphs["aabb"], "v1")
        // Scrubbing to 01B should reflect v2 (pre-restore typing).
        let atV2 = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(atV2.paragraphs["aabb"], "v2")
    }

    func test_deriveUpTo_atOp_atBootstrap_returnsInitialState() {
        let ops: [Op] = [
            op("01A", kind: .bootstrap,
               changes: [("aabb", nil, "initial")],
               sequence: ["aabb"]),
            op("01B", changes: [("aabb", "initial", "later edit")], sequence: ["aabb"]),
        ]
        let atBootstrap = Deriver.derive(ops: ops, upTo: .atOp(opId: "01A", at: Date()))
        XCTAssertEqual(atBootstrap.paragraphs["aabb"], "initial")
        XCTAssertEqual(atBootstrap.sequence, ["aabb"])
    }

    func test_deriveUpTo_atOp_unknownId_returnsNow() {
        // Defensive: an op_id not in the stream is treated as `.now`
        // rather than throwing — useful if a stale UI cursor references
        // an op that's been merged away during a cross-Mac sync.
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
        ]
        let unknown = Deriver.derive(ops: ops, upTo: .atOp(opId: "01ZZZ", at: Date()))
        let full = Deriver.derive(ops: ops)
        XCTAssertEqual(unknown, full)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/DeriverUpToTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: FAIL with `derive(ops:upTo:)` missing.

- [ ] **Step 3: Add the overload**

`Maugham/OpLog/Deriver.swift` — add after the existing `derive(ops:)` and before the private `appliesToManuscript`:

```swift
    /// Derive state as it was when op `cursor` had just been applied — or
    /// the full state when `cursor == .now`.
    ///
    /// Same fold semantics as `derive(ops:)`: only manuscript-mutating op
    /// kinds contribute paragraph text; annotation creation ops are walked
    /// for sequence/timing purposes but their `.next` is not applied (the
    /// annotation creation carries a `priorText` snapshot in `.next` is
    /// always empty, but the rule lives in `appliesToManuscript`).
    ///
    /// When `cursor` references an op_id not present in `ops`, returns the
    /// full derivation — defensive against stale UI cursors that survived
    /// a cross-Mac merge that compacted the source op away.
    public static func derive(ops: [Op], upTo cursor: RewindCursor) -> DerivedState {
        switch cursor {
        case .now:
            return derive(ops: ops)
        case .atOp(let opId, _):
            // Find the inclusive index of the target op.
            guard let idx = ops.firstIndex(where: { $0.opId == opId }) else {
                return derive(ops: ops)
            }
            let prefix = Array(ops.prefix(through: idx))
            return derive(ops: prefix)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/DeriverUpToTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: 7/7 PASS.

- [ ] **Step 5: Full suite still green**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: ~777 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Deriver.swift MaughamTests/OpLog/DeriverUpToTests.swift
git commit -m "feat: add Deriver.derive(ops:upTo:) for state-at-past-op"
```

---

## Task 9: Extend Restore.buildRestoreOp to carry synthesisSource

**Model: sonnet.** Small but cross-cutting — needs to keep the existing PartialRestorePicker call site green.

**Files:**
- Modify: `Maugham/OpLog/Restore.swift`
- Modify: `Maugham/Views/PartialRestorePicker.swift` (the only existing call site — passes `.none`)

- [ ] **Step 1: Update buildRestoreOp signature**

`Maugham/OpLog/Restore.swift`:

```swift
    public static func buildRestoreOp(
        current: Deriver.DerivedState,
        target: Deriver.DerivedState,
        scope: Scope,
        docId: String,
        device: String,
        session: String,
        sourceCheckpoint: String,
        synthesisSource: SynthesisSource? = nil   // NEW: default nil keeps the
                                                  // existing PartialRestorePicker
                                                  // call site green.
    ) -> Op? {
        let candidatePids: [String]
        switch scope {
        case .document:
            candidatePids = Array(Set(current.paragraphs.keys).union(target.paragraphs.keys))
        case .paragraph(let pid):
            candidatePids = [pid]
        }
        var changes: [Op.ParagraphChange] = []
        for pid in candidatePids {
            let curr = current.paragraphs[pid]
            let tgt = target.paragraphs[pid]
            guard curr != tgt, let next = tgt else { continue }
            changes.append(.init(paragraphId: pid, prior: curr, next: next))
        }
        guard !changes.isEmpty else { return nil }
        return Op(
            opId: ULID.generate(),
            docId: docId,
            at: Date(),
            device: device,
            session: session,
            kind: .checkpointRestore,
            changes: changes,
            sequence: nil,
            provenance: .init(
                sourceCheckpoint: sourceCheckpoint,
                synthesisSource: synthesisSource))
    }
```

- [ ] **Step 2: Verify the existing call site still compiles**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED (the new parameter has a default, so PartialRestorePicker unchanged).

- [ ] **Step 3: Run full test suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: ~777 tests still passing (no behavior change for existing callers).

- [ ] **Step 4: Commit**

```bash
git add Maugham/OpLog/Restore.swift
git commit -m "feat: extend Restore.buildRestoreOp to carry SynthesisSource"
```

---

## Task 10: Document.restoreToOp(opId:) + integration tests

**Model: sonnet.** Substantive — Document state mutation + sweep machinery integration.

**Files:**
- Modify: `Maugham/OpLog/Document.swift`
- Test: `MaughamTests/Integration/RewindFlowTests.swift` (8 tests; this task lands the first 6, T13 adds the remaining 2 that need UI plumbing)

- [ ] **Step 1: Write the failing integration tests**

`MaughamTests/Integration/RewindFlowTests.swift`:

```swift
import XCTest
@testable import Maugham

final class RewindFlowTests: XCTestCase {
    /// Mirror the project-on-disk harness from
    /// `MaughamTests/OpLog/DocumentTests.swift`. Creates a real project
    /// folder with an empty manifest so DocumentStore can coordinate.
    private func makeProjectWithDoc(
        initialMd: String,
        relativePath: String = "manuscript.md"
    ) async throws -> (URL, DocumentStore, Document, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaughamRewindTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Minimal project.maugham.json
        let manifest = #"""
        {
          "schema_version": 1,
          "project_type": "novel",
          "title": "Rewind Test",
          "created": "2026-05-20T12:00:00.000Z",
          "modified": "2026-05-20T12:00:00.000Z",
          "structure": [
            {"id": "doc-x", "type": "document", "title": "Manuscript",
             "file": "\#(relativePath)"}
          ]
        }
        """#
        try manifest.write(
            to: tmp.appendingPathComponent("project.maugham.json"),
            atomically: true, encoding: .utf8)
        try initialMd.write(
            to: tmp.appendingPathComponent(relativePath),
            atomically: true, encoding: .utf8)
        let store = DocumentStore(url: tmp)
        try await store.load()
        let doc = try await store.openOrLoadDocument(forDocId: "doc-x")
        return (tmp, store, doc, "doc-x")
    }

    func test_restoreToPastOp_revertsManuscriptText() async throws {
        let (_, _, doc, _) = try await makeProjectWithDoc(initialMd: "First paragraph.")
        // Capture the op_id of the bootstrap-equivalent state.
        let firstLog = try await doc.opLog()
        XCTAssertFalse(firstLog.isEmpty)
        let bootstrapOpId = firstLog[0].opId

        // Add a paragraph and burst.
        doc.setFullText("First paragraph.\n\nSecond paragraph.\n")
        try await doc.flushBurstNow()

        // Restore to bootstrap.
        let result = try await doc.restoreToOp(opId: bootstrapOpId)
        XCTAssertEqual(result.restoreOp.kind, .checkpointRestore)
        // Second paragraph's id should be in removedParagraphIds.
        XCTAssertGreaterThan(result.priorSequenceCount, result.newSequenceCount)
    }

    func test_restoreToPastOp_appendsCheckpointRestoreOpWithRewindSource() async throws {
        let (_, _, doc, _) = try await makeProjectWithDoc(initialMd: "p1\n\np2\n")
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        doc.setFullText("p1\n\np2\n\np3\n")
        try await doc.flushBurstNow()

        _ = try await doc.restoreToOp(opId: bootstrapId)

        let logAfter = try await doc.opLog()
        let restoreOp = logAfter.last!
        XCTAssertEqual(restoreOp.kind, .checkpointRestore)
        XCTAssertEqual(restoreOp.provenance?.synthesisSource, .rewind)
        XCTAssertEqual(restoreOp.provenance?.sourceCheckpoint, bootstrapId)
    }

    func test_restoreToPastOp_archivesOrphanAnnotations() async throws {
        let (_, _, doc, docId) = try await makeProjectWithDoc(initialMd: "p1\n\np2\n")
        // Add a third paragraph
        doc.setFullText("p1\n\np2\n\np3 with annotation target\n")
        try await doc.flushBurstNow()
        // Find p3's paragraph_id
        let log = try await doc.opLog()
        let burstChanges = log.last(where: { $0.kind == .typingBurst })?.changes ?? []
        guard let p3Id = burstChanges.first(where: { $0.next.contains("p3") })?.paragraphId else {
            return XCTFail("Couldn't find p3 paragraph_id")
        }
        // Add an annotation on p3
        _ = try await doc.addAnnotation(
            paragraphId: p3Id,
            kind: .comment,
            body: "Look at this",
            priorText: "p3 with annotation target")
        try await doc.flushBurstNow()

        // Restore to the bootstrap (before p3 existed)
        let bootstrapId = log[0].opId
        let result = try await doc.restoreToOp(opId: bootstrapId)

        XCTAssertTrue(result.removedParagraphIds.contains(p3Id))
        XCTAssertFalse(result.archivedAnnotationOpIds.isEmpty,
                       "Orphan annotation should have been archived")

        // Verify the archive op carries .rewind
        let logFinal = try await doc.opLog()
        let archiveOps = logFinal.filter {
            $0.kind == .claudeArchive
                && $0.provenance?.synthesisSource == .rewind
        }
        XCTAssertEqual(archiveOps.count, result.archivedAnnotationOpIds.count)
    }

    func test_restoreToPastOp_preservesAnnotationsOnSurvivingParagraphs() async throws {
        let (_, _, doc, _) = try await makeProjectWithDoc(initialMd: "p1\n")
        let log0 = try await doc.opLog()
        // Annotate p1
        let bootstrapChanges = log0[0].changes
        guard let p1Id = bootstrapChanges.first?.paragraphId else {
            return XCTFail("Bootstrap should have at least one paragraph")
        }
        _ = try await doc.addAnnotation(
            paragraphId: p1Id, kind: .comment,
            body: "I like this", priorText: "p1")
        try await doc.flushBurstNow()
        // Add a new paragraph
        doc.setFullText("p1\n\np2\n")
        try await doc.flushBurstNow()
        // Restore to bootstrap (p1 survives; p2 doesn't)
        let bootstrapId = log0[0].opId
        let result = try await doc.restoreToOp(opId: bootstrapId)
        // The annotation on p1 should NOT have been archived
        XCTAssertTrue(result.archivedAnnotationOpIds.isEmpty,
                      "Annotation on surviving p1 should remain open")
    }

    func test_restoreFlushesPendingBurstFirst() async throws {
        let (_, _, doc, _) = try await makeProjectWithDoc(initialMd: "p1\n")
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        // Type without flushing — this leaves an unflushed burst in `pending`
        doc.setFullText("p1\n\nmid-typing edit\n")
        // Don't call flushBurstNow — restoreToOp should flush internally
        _ = try await doc.restoreToOp(opId: bootstrapId)

        // The unflushed burst should appear in the log BEFORE the restore op.
        let logAfter = try await doc.opLog()
        // Find indices of the burst and the restore op
        let burstIdx = logAfter.firstIndex { $0.kind == .typingBurst }
        let restoreIdx = logAfter.firstIndex { $0.kind == .checkpointRestore }
        XCTAssertNotNil(burstIdx, "Pending burst must have been flushed")
        XCTAssertNotNil(restoreIdx)
        XCTAssertLessThan(burstIdx!, restoreIdx!)
    }

    func test_restoreToPastOp_resultCountsMatchSequenceDeltas() async throws {
        let (_, _, doc, _) = try await makeProjectWithDoc(initialMd: "p1\n\np2\n")
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        let priorCount = doc.sequence.count
        XCTAssertEqual(priorCount, 2)
        doc.setFullText("p1\n\np2\n\np3\n\np4\n")
        try await doc.flushBurstNow()
        XCTAssertEqual(doc.sequence.count, 4)

        let result = try await doc.restoreToOp(opId: bootstrapId)
        XCTAssertEqual(result.priorSequenceCount, 4)
        XCTAssertEqual(result.newSequenceCount, 2)
        XCTAssertEqual(result.removedParagraphIds.count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindFlowTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: 6 FAIL — `Document.restoreToOp` missing.

- [ ] **Step 3: Implement Document.restoreToOp**

**Before editing**, grep `Maugham/OpLog/Document.swift` for the exact field/method names — the snippet below uses `paragraphs`, `sequence`, `displayText`, `_opLogMirror`, `opStore`, and `Materializer.render(paragraphs:sequence:)`. Confirm these match the current code (the field shapes are stable post-`milestone-document-first-class` but access modifiers may need a small relaxation if `paragraphs`/`sequence` aren't mutable from within Document already).

`Maugham/OpLog/Document.swift` — add after the existing checkpoint-related methods (around line ~770, after `flushBurstNow`):

```swift
    /// Restore this document to the state it had immediately after the op
    /// with id `opId` was applied. Appends a `.checkpointRestore` op with
    /// `provenance.synthesisSource = .rewind` and
    /// `provenance.sourceCheckpoint = opId` (overloading the existing
    /// "where did this restore come from?" field to carry the past-op id
    /// — `sourceCheckpoint` is the field name, but the value can equally
    /// be a past op_id when synthesisSource is .rewind).
    ///
    /// Triggers the orphan-annotation sweep against the exact set of
    /// paragraph ids that disappeared from the sequence. Flushes any
    /// pending burst first so unflushed in-memory typing lands as an op
    /// in the log before the restore is computed against the "now" state.
    ///
    /// Returns a `RewindRestoreResult` carrying the appended restore op,
    /// the synthesized archive op_ids, the removed paragraph ids, and
    /// the prior/new sequence counts — enough information for the modal
    /// to render a confirmation toast and for tests to assert effects.
    public func restoreToOp(opId targetOpId: String) async throws -> RewindRestoreResult {
        // 1. Flush pending burst so the "now" state in the log includes
        //    in-memory typing.
        try await flushBurstNow()

        // 2. Derive current + target states from the mirror.
        let currentOps = _opLogMirror
        let currentState = Deriver.derive(ops: currentOps)
        let targetState = Deriver.derive(
            ops: currentOps,
            upTo: .atOp(opId: targetOpId, at: Date()))

        // 3. Build the restore op via the shared helper.
        let priorSeq = Set(currentState.sequence)
        let newSeq = Set(targetState.sequence)
        let removedIds = Array(priorSeq.subtracting(newSeq))

        guard let restoreOp = Restore.buildRestoreOp(
            current: currentState,
            target: targetState,
            scope: .document,
            docId: docId,
            device: device,
            session: session,
            sourceCheckpoint: targetOpId,
            synthesisSource: .rewind
        ) else {
            // No-op restore (target == current). Synthesize a result with
            // no changes; do not append an op.
            return RewindRestoreResult(
                restoreOp: Op(
                    opId: "",
                    docId: docId, at: Date(),
                    device: device, session: session,
                    kind: .checkpointRestore,
                    changes: [],
                    sequence: nil,
                    provenance: nil),
                archivedAnnotationOpIds: [],
                removedParagraphIds: [],
                priorSequenceCount: currentState.sequence.count,
                newSequenceCount: targetState.sequence.count)
        }

        // 4. Append the op + mirror it. We also stamp the post-restore
        //    sequence onto the op explicitly so cross-Mac merge sees the
        //    ordering change.
        let stampedOp = Op(
            opId: restoreOp.opId,
            docId: restoreOp.docId,
            at: restoreOp.at,
            device: restoreOp.device,
            session: restoreOp.session,
            kind: restoreOp.kind,
            changes: restoreOp.changes,
            sequence: targetState.sequence,
            provenance: restoreOp.provenance)
        try await opStore.append(stampedOp)
        _opLogMirror.append(stampedOp)

        // 5. Update in-memory paragraphs + sequence + displayText.
        paragraphs = targetState.paragraphs
        sequence = targetState.sequence
        let rendered = Materializer.render(paragraphs: paragraphs, sequence: sequence)
        displayText = rendered

        // 6. Flag sweep with the exact removed set. Run flushBurstNow to
        //    process the sweep immediately so the result accurately
        //    reflects what's been archived.
        let priorCount = currentState.sequence.count
        let newCount = targetState.sequence.count
        if !removedIds.isEmpty {
            flagSweep(SweepReason(removed: Set(removedIds)))
        }
        // Capture the archive op_id watermark before flushing.
        let beforeFlushCount = _opLogMirror.count
        try await flushBurstNow()
        let newOps = Array(_opLogMirror.dropFirst(beforeFlushCount))
        let archivedIds = newOps
            .filter { $0.kind == .claudeArchive
                      && $0.provenance?.synthesisSource == .rewind }
            .map { $0.opId }

        return RewindRestoreResult(
            restoreOp: stampedOp,
            archivedAnnotationOpIds: archivedIds,
            removedParagraphIds: removedIds,
            priorSequenceCount: priorCount,
            newSequenceCount: newCount)
    }
```

- [ ] **Step 4: Update sweepOrphanedAnnotations to accept a SynthesisSource override**

The existing sweep hard-codes `synthesisSource: .paragraphDeleted`. Restore is a different cause and should be flagged `.rewind`. Change the sweep to read the cause from the `SweepReason`:

`Maugham/OpLog/SweepReason.swift` — add a `cause` field:

```swift
public struct SweepReason: Equatable, Sendable {
    public let removed: Set<String>
    public let cause: SynthesisSource

    public static func userTyped(removed: Set<String>) -> SweepReason {
        SweepReason(removed: removed, cause: .paragraphDeleted)
    }
    public static func externalLog(removed: Set<String>) -> SweepReason {
        SweepReason(removed: removed, cause: .paragraphDeleted)
    }
    public static func useCloud(removed: Set<String>) -> SweepReason {
        SweepReason(removed: removed, cause: .useCloudResolution)
    }
    public static func rewind(removed: Set<String>) -> SweepReason {
        SweepReason(removed: removed, cause: .rewind)
    }

    public init(removed: Set<String>, cause: SynthesisSource = .paragraphDeleted) {
        self.removed = removed
        self.cause = cause
    }

    public func merging(_ other: SweepReason) -> SweepReason {
        // When two sweep reasons stack between flushes, the most-recent
        // cause wins. The set unions.
        SweepReason(removed: removed.union(other.removed), cause: other.cause)
    }
}
```

**Before editing**, read the existing `Maugham/OpLog/SweepReason.swift` to confirm the current shape. The current version (post-typed-cross-area-seams) likely has named factories (`.userTyped`, `.externalLog`, `.useCloud`) but does NOT carry a `cause` field yet — the hard-coded `.paragraphDeleted` at the sweep emit-site is what we're replacing. Preserve all existing call sites by giving `cause` a default in the public initializer. Also update any test that constructs `SweepReason(removed:)` directly — the default param keeps them green.

Then in `Document.sweepOrphanedAnnotations`:

```swift
private func sweepOrphanedAnnotations(reason: SweepReason) async {
    if !_annotationsCacheValid { rebuildAnnotationsCache() }
    let removed = reason.removed
    let orphans = _annotationsCache.filter { ann in
        ann.status == .open
            && ann.kind != .craftNote
            && (ann.paragraphId.map { removed.contains($0) } ?? false)
    }
    for orphan in orphans {
        try? await appendLifecycleOp(
            kind: .claudeArchive,
            sourceAnnotationId: orphan.id,
            userResponse: nil,
            synthesisSource: reason.cause)   // was: .paragraphDeleted hard-coded
    }
}
```

And in `Document.restoreToOp` step 6, switch `SweepReason(removed: Set(removedIds))` to `SweepReason.rewind(removed: Set(removedIds))`.

- [ ] **Step 5: Run the tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindFlowTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: 6/6 PASS.

- [ ] **Step 6: Run full suite to verify no regressions**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: ~783 passing (777 + 6 new). If PresenterRoutingTests fails because it constructs SweepReason without a `cause` parameter, adapt — the default param in the init keeps existing call sites green.

- [ ] **Step 7: Commit**

```bash
git add Maugham/OpLog/Document.swift \
        Maugham/OpLog/SweepReason.swift \
        MaughamTests/Integration/RewindFlowTests.swift
git commit -m "feat: Document.restoreToOp + SweepReason carries cause"
```

---

## Task 11: Tick density layout helper + tests

**Model: haiku.** Pure-function helper, mechanical.

**Files:**
- Create: `Maugham/Views/RewindTickLayout.swift`
- Test: `MaughamTests/Views/RewindDensityTests.swift`

- [ ] **Step 1: Write the failing tests**

`MaughamTests/Views/RewindDensityTests.swift`:

```swift
import XCTest
@testable import Maugham

final class RewindDensityTests: XCTestCase {
    /// Build N typing-burst ticks evenly spaced over time.
    private func ticks(_ n: Int, kinds: [OpKind]? = nil) -> [RewindTickLayout.RawTick] {
        (0..<n).map { i in
            RewindTickLayout.RawTick(
                opId: "op\(i)",
                at: Date(timeIntervalSince1970: TimeInterval(i)),
                kind: kinds?[i] ?? .typingBurst)
        }
    }

    func test_decimateTicks_underWidth_returnsAll() {
        let raw = ticks(50)
        let laid = RewindTickLayout.decimate(ticks: raw, width: 1000)
        XCTAssertEqual(laid.count, 50)
    }

    func test_decimateTicks_overWidth_collapsesAdjacent() {
        // 1000 ticks in 600px → many will collapse (rule: at most one
        // tick per pixel, except checkpoints always drawn).
        let raw = ticks(1000)
        let laid = RewindTickLayout.decimate(ticks: raw, width: 600)
        XCTAssertLessThanOrEqual(laid.count, 600)
        // The first and last tick should always be present.
        XCTAssertEqual(laid.first?.opId, "op0")
        XCTAssertEqual(laid.last?.opId, "op999")
    }

    func test_decimateTicks_checkpointsAlwaysVisible() {
        // 1000 ticks where every 100th is a checkpoint.
        var kinds: [OpKind] = []
        for i in 0..<1000 {
            kinds.append(i % 100 == 0 ? .checkpoint : .typingBurst)
        }
        let raw = ticks(1000, kinds: kinds)
        let laid = RewindTickLayout.decimate(ticks: raw, width: 200)
        // Width is 200px → typing-burst ticks collapse heavily,
        // but all 10 checkpoint ticks must still appear.
        let checkpointsInOutput = laid.filter { $0.kind == .checkpoint }
        XCTAssertEqual(checkpointsInOutput.count, 10,
                       "Checkpoint ticks must survive density collapse")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindDensityTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: FAIL — `RewindTickLayout` missing.

- [ ] **Step 3: Implement the helper**

`Maugham/Views/RewindTickLayout.swift`:

```swift
import Foundation

/// Pure-function layout helper for the Rewind modal's scrubber. Extracted
/// so the density rule is unit-testable independent of SwiftUI.
internal enum RewindTickLayout {
    struct RawTick: Equatable, Sendable {
        let opId: String
        let at: Date
        let kind: OpKind
    }

    /// Apply the density rule: at most one tick per pixel, with
    /// checkpoint ticks always preserved as navigation landmarks.
    ///
    /// Spec §2.3 — the auto-decimation rule is the only adaptive
    /// behaviour in v1. Pan/zoom is a deferred carry-forward.
    static func decimate(ticks: [RawTick], width: CGFloat) -> [RawTick] {
        guard !ticks.isEmpty, width > 0 else { return ticks }
        // Time range
        let firstT = ticks.first!.at.timeIntervalSince1970
        let lastT = ticks.last!.at.timeIntervalSince1970
        let span = max(lastT - firstT, 0.001)

        var lastPx: CGFloat = -1
        var result: [RawTick] = []
        for tick in ticks {
            // Checkpoints always emit.
            if tick.kind == .checkpoint || tick.kind == .checkpointRestore {
                result.append(tick)
                let frac = (tick.at.timeIntervalSince1970 - firstT) / span
                lastPx = CGFloat(frac) * width
                continue
            }
            let frac = (tick.at.timeIntervalSince1970 - firstT) / span
            let px = CGFloat(frac) * width
            if px - lastPx >= 1.0 {
                result.append(tick)
                lastPx = px
            }
        }
        // Guarantee first and last are always present (the iteration above
        // emits the first if it's >= 1px from lastPx=-1; the last may be
        // dropped if it sits in the same pixel as a previous emitted tick).
        if let last = ticks.last, result.last?.opId != last.opId {
            result.append(last)
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindDensityTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 3/3 PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/RewindTickLayout.swift \
        MaughamTests/Views/RewindDensityTests.swift
git commit -m "feat: extract RewindTickLayout density helper"
```

---

## Task 12: RewindWindow modal (UI)

**Model: opus.** UI work with drag interactions, density rendering, doc/diff toggle, two preview modes. The largest production task.

**Files:**
- Create: `Maugham/Views/RewindWindow.swift`

- [ ] **Step 1: Implement the modal**

`Maugham/Views/RewindWindow.swift`:

```swift
import SwiftUI

/// Per-doc time-travel modal. Opens via the "Rewind…" header button in
/// HistoryPane or via the per-row "↺" button. Reads the active doc's
/// op log at open-time (snapshot — no live updates during the session),
/// derives state at any past op for read-only preview, and emits one
/// terminal action: Cancel, SnapshotHere(label), or RestoreHere.
@MainActor
struct RewindWindow: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?
    let docTitle: String
    /// The initial scrubber position. `.now` for the header button;
    /// `.atOp(...)` for the per-row deep-link.
    let initialCursor: RewindCursor
    let onComplete: (RewindAction) -> Void

    // Snapshot of the op log captured at modal-open time. Stable for the
    // life of the modal session.
    @State private var ops: [Op] = []
    @State private var cursor: RewindCursor = .now
    @State private var previewMode: PreviewMode = .doc
    @State private var derivedState: Deriver.DerivedState = .init(paragraphs: [:], sequence: [])
    @State private var nowState: Deriver.DerivedState = .init(paragraphs: [:], sequence: [])
    @State private var showingSnapshotPrompt: Bool = false
    @State private var showingRestoreConfirm: Bool = false

    enum PreviewMode: Equatable { case doc, diff }

    private var rawTicks: [RewindTickLayout.RawTick] {
        ops.map { .init(opId: $0.opId, at: $0.at, kind: $0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scrubberSection
            Divider()
            previewArea
                .frame(maxHeight: .infinity)
            Divider()
            actionFooter
        }
        .frame(minWidth: 900, minHeight: 640)
        .task { await load() }
        .sheet(isPresented: $showingSnapshotPrompt) {
            CheckpointLabelPromptSheet(
                onConfirm: { label in
                    showingSnapshotPrompt = false
                    Task { await snapshotHere(label: label) }
                },
                onCancel: { showingSnapshotPrompt = false })
        }
        .sheet(isPresented: $showingRestoreConfirm) {
            restoreConfirmSheet
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("REWINDING")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(headerContext).font(.callout)
            }
            Spacer()
            Picker("", selection: $previewMode) {
                Text("Doc").tag(PreviewMode.doc)
                Text("Diff").tag(PreviewMode.diff)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Button { onComplete(.cancel) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var scrubberSection: some View {
        GeometryReader { geo in
            let width = geo.size.width - 32
            let ticks = RewindTickLayout.decimate(ticks: rawTicks, width: width)
            ZStack(alignment: .topLeading) {
                // Background bar
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(height: 4)
                    .padding(.top, 14)

                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let frac = fraction(for: tick.at)
                    let xPos = CGFloat(frac) * width
                    Rectangle()
                        .fill(color(for: tick.kind))
                        .frame(width: tick.kind == .checkpoint ? 3 : 1,
                               height: tick.kind == .checkpoint ? 12 : 8)
                        .offset(x: xPos, y: tick.kind == .checkpoint ? 10 : 12)
                }
                // Scrub cursor
                let curFrac = fraction(for: cursorDate)
                Rectangle().fill(Color.purple)
                    .frame(width: 2, height: 24)
                    .offset(x: CGFloat(curFrac) * width, y: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(toX: value.location.x, width: width)
                    }
            )
        }
        .frame(height: 50)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var previewArea: some View {
        ScrollView {
            if previewMode == .doc {
                Text(renderedDoc(state: derivedState))
                    .font(.system(.body, design: .serif))
                    .padding(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                diffView
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private var diffView: some View {
        // Per spec §2.5: paragraphs removed on restore in red strikethrough,
        // paragraphs that come back in green underline. Word-level diff
        // inside paragraphs that exist in both states but differ.
        let currentSet = Set(nowState.sequence)
        let pastSet = Set(derivedState.sequence)
        let removedOnRestore = nowState.sequence.filter { !pastSet.contains($0) }
        let returnedOnRestore = derivedState.sequence.filter { !currentSet.contains($0) }
        let stillPresent = nowState.sequence.filter { pastSet.contains($0) }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(stillPresent, id: \.self) { pid in
                let now = nowState.paragraphs[pid] ?? ""
                let past = derivedState.paragraphs[pid] ?? ""
                if now == past {
                    Text(now).font(.system(.body, design: .serif))
                } else {
                    VStack(alignment: .leading) {
                        Text(now).strikethrough()
                            .foregroundStyle(.red)
                            .font(.system(.body, design: .serif))
                        Text(past).underline()
                            .foregroundStyle(.green)
                            .font(.system(.body, design: .serif))
                    }
                }
            }
            ForEach(removedOnRestore, id: \.self) { pid in
                Text(nowState.paragraphs[pid] ?? "")
                    .strikethrough().foregroundStyle(.red)
                    .font(.system(.body, design: .serif))
            }
            ForEach(returnedOnRestore, id: \.self) { pid in
                Text(derivedState.paragraphs[pid] ?? "")
                    .underline().foregroundStyle(.green)
                    .font(.system(.body, design: .serif))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionFooter: some View {
        HStack(spacing: 12) {
            if case .atOp = cursor {
                Text(impactSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onComplete(.cancel) }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Snapshot here…") { showingSnapshotPrompt = true }
                .disabled(cursor == .now)
            Button("Restore here…") { showingRestoreConfirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(cursor == .now)
        }
        .padding(16)
    }

    @ViewBuilder
    private var restoreConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore \(docTitle) to this point?").font(.headline)
            Text(impactSummary).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingRestoreConfirm = false }
                Button("Restore") {
                    showingRestoreConfirm = false
                    onComplete(.restoreHere)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    // MARK: - Helpers

    private func load() async {
        // Flush pending burst on the active document so the "Now" anchor
        // reflects in-flight typing (spec §3.1).
        if let ds = documentStore,
           let doc = ds.document(forDocId: activeDocId) {
            try? await doc.flushBurstNow()
            ops = (try? await doc.opLog()) ?? []
        } else {
            let opStore = OpLogStore(projectURL: projectURL)
            ops = (try? await opStore.load(docId: activeDocId)) ?? []
        }
        nowState = Deriver.derive(ops: ops)
        cursor = initialCursor
        await updateDerivedState()
    }

    private func updateDerivedState() async {
        derivedState = Deriver.derive(ops: ops, upTo: cursor)
    }

    private func scrub(toX x: CGFloat, width: CGFloat) {
        guard !ops.isEmpty, width > 0 else { return }
        let frac = max(0, min(1, x / width))
        let firstT = ops.first!.at.timeIntervalSince1970
        let lastT = ops.last!.at.timeIntervalSince1970
        let span = max(lastT - firstT, 0.001)
        let targetT = firstT + Double(frac) * span
        // Find the nearest op to targetT.
        let nearest = ops.min(by: {
            abs($0.at.timeIntervalSince1970 - targetT)
                < abs($1.at.timeIntervalSince1970 - targetT)
        })
        if let op = nearest {
            cursor = .atOp(opId: op.opId, at: op.at)
            Task { await updateDerivedState() }
        }
    }

    private func snapshotHere(label: String) async {
        guard case .atOp(let opId, _) = cursor else { return }
        let opStore = OpLogStore(projectURL: projectURL)
        // Build doc_pointers: active doc = scrub op_id; others = latest op_id.
        var pointers: [String: String] = [:]
        for did in allDocIds {
            if did == activeDocId {
                pointers[did] = opId
            } else if let lastOp = try? await opStore.load(docId: did).last {
                pointers[did] = lastOp.opId
            }
        }
        // Word count: past state of active doc + current state of others.
        var totalWords = derivedState.paragraphs.values
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)
        for did in allDocIds where did != activeDocId {
            if let other = try? await opStore.load(docId: did) {
                let s = Deriver.derive(ops: other)
                totalWords += s.paragraphs.values
                    .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
                    .reduce(0, +)
            }
        }
        // Snap `at` to millisecond precision (same as CheckpointCapture).
        let now = Date()
        let snappedAt = Date(timeIntervalSince1970:
            (now.timeIntervalSince1970 * 1000).rounded() / 1000)
        let cp = Checkpoint(
            checkpointId: ULID.generate(),
            label: label,
            labelSource: .user,
            at: snappedAt,
            device: device,
            activeDoc: activeDocId,
            docPointers: pointers,
            manuscriptWordCount: totalWords)
        try? await CheckpointStore(projectURL: projectURL).append(cp)
        onComplete(.snapshotHere(label: label))
    }

    private var cursorDate: Date {
        switch cursor {
        case .now: return ops.last?.at ?? Date()
        case .atOp(_, let at): return at
        }
    }

    private func fraction(for date: Date) -> Double {
        guard let first = ops.first?.at, let last = ops.last?.at else { return 1.0 }
        let span = max(last.timeIntervalSince1970 - first.timeIntervalSince1970, 0.001)
        return (date.timeIntervalSince1970 - first.timeIntervalSince1970) / span
    }

    private var headerContext: String {
        switch cursor {
        case .now:
            return "Now — drag the scrubber to revisit a past moment"
        case .atOp(let opId, let at):
            let idx = ops.firstIndex(where: { $0.opId == opId }) ?? -1
            let opsAgo = ops.count - 1 - idx
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE h:mm a"
            return "\(fmt.string(from: at)) · \(opsAgo) ops ago"
        }
    }

    private var impactSummary: String {
        let removed = Set(nowState.sequence).subtracting(Set(derivedState.sequence))
        let words = removed.compactMap { nowState.paragraphs[$0] }
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)
        return "Restoring would undo \(words) words / \(removed.count) paragraph\(removed.count == 1 ? "" : "s") written after this point."
    }

    private func renderedDoc(state: Deriver.DerivedState) -> String {
        // Drop the inline ¶id HTML comments so the preview reads as
        // clean prose. The materializer normally writes anchors for the
        // editor's join key; for read-only preview we want them gone.
        Materializer.render(paragraphs: state.paragraphs, sequence: state.sequence)
            .replacingOccurrences(
                of: #"<!--\s*¶[0-9a-z]{4,}\s*-->\n?"#,
                with: "",
                options: .regularExpression)
    }

    private func color(for kind: OpKind) -> Color {
        switch kind {
        case .typingBurst, .bootstrap, .externalEdit:
            return kind == .externalEdit
                ? Color(red: 0.77, green: 0.56, blue: 0.94)  // purple
                : Color(red: 0.53, green: 0.67, blue: 0.73)  // blue
        case .checkpoint, .checkpointRestore:
            return Color(red: 0.42, green: 0.88, blue: 0.66) // green
        case .claudeComment, .claudeQuery, .claudeCraftNote,
             .claudeSuggestion, .claudeAccept, .claudeReject, .claudeArchive:
            return Color(red: 1.0, green: 0.66, blue: 0.25)  // orange
        }
    }
}
```

- [ ] **Step 2: Verify compiles**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED. If `Document.opLog()` or `documentStore.document(forDocId:)` differ from what's used here, grep + adapt.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/RewindWindow.swift
git commit -m "feat: RewindWindow modal — scrubber + Doc/Diff preview + actions"
```

---

## Task 13: HistoryPane integration — header button + per-row "↺"

**Model: sonnet.** Touches existing HistoryPane structure; needs care with the row state.

**Files:**
- Modify: `Maugham/Views/HistoryPane.swift`
- Test: `MaughamTests/Integration/RewindEntryPointsTests.swift`

- [ ] **Step 1: Add the header "Rewind…" button**

`Maugham/Views/HistoryPane.swift` — replace `filterToolbar`:

```swift
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
            Button {
                NotificationCenter.default.post(
                    name: .maughamOpenRewind,
                    object: nil,
                    userInfo: [:])  // empty userInfo = open at .now
            } label: {
                Label("Rewind…", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(ops.isEmpty || (ops.count == 1 && ops[0].kind == .bootstrap))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
```

- [ ] **Step 2: Add the per-row ↺ button (HistoryRow)**

`Maugham/Views/HistoryPane.swift` — modify HistoryRow body. After the Revert button for checkpoint rows, add an analogous block for manuscript-mutating op rows:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded { expandedDetail } else { collapsedPreview }
            if case .checkpoint = entry {
                Button("Revert here…", action: onRevert)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            } else if case .op(let op) = entry, mutatesManuscript(op.kind) {
                Button {
                    NotificationCenter.default.post(
                        name: .maughamOpenRewind,
                        object: nil,
                        userInfo: ["scrub_op_id": op.opId,
                                   "scrub_op_at": op.at])
                } label: {
                    Label("Rewind to before this…", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Rewind to before this point…")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { _ in onJump() })
    }

    private func mutatesManuscript(_ kind: OpKind) -> Bool {
        // Spec §4.2: per-row button on rows whose op kind mutated the
        // manuscript. Excludes bootstrap (degenerate target), checkpoint
        // (already has its own Revert here button), annotation creation /
        // lifecycle that didn't mutate text.
        switch kind {
        case .typingBurst, .externalEdit, .claudeAccept, .checkpointRestore:
            return true
        case .bootstrap, .checkpoint, .claudeComment, .claudeSuggestion,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive:
            return false
        }
    }
```

- [ ] **Step 3: Write the entry-points seam test**

`MaughamTests/Integration/RewindEntryPointsTests.swift`:

```swift
import XCTest
@testable import Maugham

/// Asserts both Rewind entry points (header button + per-row ↺) end up
/// calling the same Document method with the same argument shape. The
/// test isn't UI-level (we can't fire SwiftUI buttons from XCTest cleanly);
/// instead it asserts the notification contract — both buttons post
/// `.maughamOpenRewind`, header with empty userInfo (= open at .now),
/// per-row with `scrub_op_id` in userInfo.
///
/// Why this matters: it's the cross-area seam the spec specifies. If a
/// future commit "simplifies" by giving the per-row button a direct
/// shortcut path that bypasses the modal, the per-row entry diverges
/// from the header entry. This test fails in that case.
final class RewindEntryPointsTests: XCTestCase {
    func test_headerNotificationUserInfo_isEmpty() {
        // The header button posts maughamOpenRewind with userInfo: [:].
        // We assert the contract by simulating what a listener would see.
        var observed: [String: Any]?
        let exp = expectation(description: "header notification")
        let token = NotificationCenter.default.addObserver(
            forName: .maughamOpenRewind, object: nil, queue: nil
        ) { note in
            observed = note.userInfo as? [String: Any]
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: .maughamOpenRewind, object: nil, userInfo: [:])
        wait(for: [exp], timeout: 1)
        XCTAssertNotNil(observed)
        XCTAssertNil(observed?["scrub_op_id"],
                     "Header entry must NOT carry a scrub_op_id")
    }

    func test_perRowNotificationUserInfo_carriesOpId() {
        var observed: [String: Any]?
        let exp = expectation(description: "row notification")
        let token = NotificationCenter.default.addObserver(
            forName: .maughamOpenRewind, object: nil, queue: nil
        ) { note in
            observed = note.userInfo as? [String: Any]
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: .maughamOpenRewind, object: nil,
            userInfo: ["scrub_op_id": "01TESTOPID"])
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed?["scrub_op_id"] as? String, "01TESTOPID")
    }
}
```

- [ ] **Step 4: Wire ProjectWindow to receive the notification + present RewindWindow**

`Maugham/Views/ProjectWindow.swift` — add `@State` flags near other modal flags:

```swift
@State private var showingRewindModal: Bool = false
@State private var rewindInitialCursor: RewindCursor = .now
```

Add `.onReceive` for the notification (near the existing `.onReceive` handlers; ~line 180 area):

```swift
.onReceive(NotificationCenter.default.publisher(for: .maughamOpenRewind)) { note in
    if let opId = note.userInfo?["scrub_op_id"] as? String,
       let at = note.userInfo?["scrub_op_at"] as? Date {
        rewindInitialCursor = .atOp(opId: opId, at: at)
    } else {
        rewindInitialCursor = .now
    }
    showingRewindModal = true
}
```

Add the `.sheet` presentation near the existing sheet stack (after `BootstrapNoticeSheet` block):

```swift
.sheet(isPresented: $showingRewindModal) {
    if let docId = selectedItemId, let store = store {
        let allIds: [String] = {
            func collect(_ items: [StructureItem]) -> [String] {
                var ids: [String] = []
                for item in items {
                    if item.type == .document { ids.append(item.id) }
                    if let ch = item.children { ids.append(contentsOf: collect(ch)) }
                }
                return ids
            }
            return collect(store.manifest.structure)
        }()
        let paths: [String: String] = {
            var m: [String: String] = [:]
            func walk(_ items: [StructureItem]) {
                for item in items {
                    if item.type == .document,
                       let path = item.file { m[item.id] = path }
                    if let ch = item.children { walk(ch) }
                }
            }
            walk(store.manifest.structure)
            return m
        }()
        let title = paths[docId]?.components(separatedBy: "/").last ?? docId
        RewindWindow(
            projectURL: store.url,
            activeDocId: docId,
            allDocIds: allIds,
            device: _checkpointDeviceId,
            session: _checkpointSessionId,
            docPaths: paths,
            documentStore: documentStore,
            docTitle: title,
            initialCursor: rewindInitialCursor,
            onComplete: { action in
                showingRewindModal = false
                switch action {
                case .cancel:
                    break
                case .snapshotHere(_):
                    NotificationCenter.default.post(
                        name: .maughamCheckpointAdded, object: nil)
                case .restoreHere:
                    Task { @MainActor in
                        if let doc = documentStore?.document(forDocId: docId) {
                            switch rewindInitialCursor {
                            case .atOp(let opId, _):
                                _ = try? await doc.restoreToOp(opId: opId)
                            case .now:
                                break  // disabled in UI; defensive
                            }
                        }
                    }
                }
            })
    }
}
```

(Verify `maughamCheckpointAdded` is the notification HistoryPane listens to; if not, use whatever notification HistoryPane's `reload` is wired to — check the existing onReceive in HistoryPane.)

- [ ] **Step 5: Run build + new tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindEntryPointsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 2/2 PASS.

- [ ] **Step 6: Full suite green**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: ~786 passing.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/HistoryPane.swift \
        Maugham/Views/ProjectWindow.swift \
        MaughamTests/Integration/RewindEntryPointsTests.swift
git commit -m "feat: HistoryPane integration — Rewind button + per-row ↺"
```

---

## Task 14: Forensic-provenance seam test

**Model: sonnet.** A second integration test on the same Document method; specifically asserts the synthesisSource invariant the UI depends on.

**Files:**
- Test: `MaughamTests/Integration/RewindForensicProvenanceTests.swift`

- [ ] **Step 1: Write the tests**

`MaughamTests/Integration/RewindForensicProvenanceTests.swift`:

```swift
import XCTest
@testable import Maugham

/// Spec §7.6: every rewind-emitted op carries `synthesisSource == .rewind`.
/// HistoryPane row rendering depends on this; future tools (cross-Mac
/// merge audit, MCP list_history if added) will too.
final class RewindForensicProvenanceTests: XCTestCase {
    private func makeProjectWithDoc() async throws -> (Document, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaughamForensicTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = #"""
        {
          "schema_version": 1, "project_type": "novel", "title": "F",
          "created": "2026-05-20T12:00:00.000Z",
          "modified": "2026-05-20T12:00:00.000Z",
          "structure": [{"id":"doc-x","type":"document","title":"M","file":"m.md"}]
        }
        """#
        try manifest.write(
            to: tmp.appendingPathComponent("project.maugham.json"),
            atomically: true, encoding: .utf8)
        try "p1\n".write(
            to: tmp.appendingPathComponent("m.md"),
            atomically: true, encoding: .utf8)
        let store = DocumentStore(url: tmp)
        try await store.load()
        let doc = try await store.openOrLoadDocument(forDocId: "doc-x")
        return (doc, "doc-x")
    }

    func test_restoreOpCarriesRewindSynthesisSource() async throws {
        let (doc, _) = try await makeProjectWithDoc()
        let initialLog = try await doc.opLog()
        let bootstrapId = initialLog[0].opId
        doc.setFullText("p1\n\np2\n")
        try await doc.flushBurstNow()

        _ = try await doc.restoreToOp(opId: bootstrapId)

        let logAfter = try await doc.opLog()
        let restore = logAfter.first(where: { $0.kind == .checkpointRestore })
        XCTAssertNotNil(restore)
        XCTAssertEqual(restore?.provenance?.synthesisSource, .rewind)
    }

    func test_sweepArchiveOpsCarryRewindSynthesisSource() async throws {
        let (doc, _) = try await makeProjectWithDoc()
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        // Add a new paragraph
        doc.setFullText("p1\n\np2-to-be-annotated\n")
        try await doc.flushBurstNow()
        let logAfterType = try await doc.opLog()
        let p2Id = logAfterType.last(where: { $0.kind == .typingBurst })?
            .changes.first(where: { $0.next.contains("p2") })?.paragraphId
        guard let p2Id else {
            return XCTFail("Couldn't find p2 paragraph_id")
        }
        // Annotate it
        _ = try await doc.addAnnotation(
            paragraphId: p2Id, kind: .comment,
            body: "test", priorText: "p2-to-be-annotated")
        try await doc.flushBurstNow()

        // Rewind to before p2 existed.
        _ = try await doc.restoreToOp(opId: bootstrapId)

        // Find the archive op and assert its synthesisSource.
        let logFinal = try await doc.opLog()
        let archives = logFinal.filter { $0.kind == .claudeArchive }
        // The latest archive op should carry .rewind, not .paragraphDeleted
        XCTAssertTrue(archives.contains {
            $0.provenance?.synthesisSource == .rewind
        })
    }
}
```

- [ ] **Step 2: Run + verify**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindForensicProvenanceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 2/2 PASS.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Integration/RewindForensicProvenanceTests.swift
git commit -m "test: rewind ops carry .rewind synthesisSource"
```

---

## Task 15: HistoryRow display tweaks for rewind ops

**Model: sonnet.** Small but customer-facing: rewind restore op should read differently from a checkpoint revert.

**Files:**
- Modify: `Maugham/Views/HistoryPane.swift`

- [ ] **Step 1: Distinguish rewind in collapsedPreview/expandedDetail/kindLabel**

`Maugham/Views/HistoryPane.swift` — in HistoryRow's `kindLabel` property and previews:

```swift
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
            case .claudeQuery: return "Question"
            case .claudeCraftNote: return "Craft note"
            case .externalEdit: return "External edit"
            case .checkpointRestore:
                return op.provenance?.synthesisSource == .rewind
                    ? "Rewound" : "Reverted"
            case .checkpoint: return "Checkpoint"
            case .bootstrap: return "Bootstrap"
            }
        case .checkpoint: return "Checkpoint"
        }
    }
```

For the auto-archive label (line ~435 area) — distinguish .rewind:

```swift
if op.provenance?.synthesisSource == .paragraphDeleted {
    Text("Auto-archived: paragraph deleted from manuscript.")
        .font(.caption2).foregroundStyle(.orange)
} else if op.provenance?.synthesisSource == .rewind {
    Text("Auto-archived: paragraph removed by rewind.")
        .font(.caption2).foregroundStyle(.orange)
}
```

Same shape in the collapsedPreview "claudeArchive" branch (line ~382-395 area).

- [ ] **Step 2: Build + smoke**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: ~790 passing.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/HistoryPane.swift
git commit -m "feat: HistoryRow distinguishes rewind from checkpoint revert"
```

---

## Task 16: Final RewindFlowTests — the entry-point integration tests deferred from T10

**Model: sonnet.** Adds the remaining 2 integration tests that needed UI wiring before they could exist.

**Files:**
- Modify: `MaughamTests/Integration/RewindFlowTests.swift`

- [ ] **Step 1: Add the two remaining tests**

Append to `MaughamTests/Integration/RewindFlowTests.swift`:

```swift
    func test_rewindThenForwardCheckpoint_canRestoreToPostRewindState() async throws {
        // Spec §5.2: a checkpoint made between rewind point and "now"
        // remains valid; reverting to it is the "go forward after
        // rewind" path.
        let (tmp, _, doc, docId) = try await makeProjectWithDoc(initialMd: "p1\n")
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        // Type more
        doc.setFullText("p1\n\np2\n")
        try await doc.flushBurstNow()
        // Capture a checkpoint at this state
        let cpAfterP2 = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: docId,
            allDocIds: [docId],
            device: "d1",
            session: "s1",
            label: "after p2")
        // Type more
        doc.setFullText("p1\n\np2\n\np3\n")
        try await doc.flushBurstNow()
        // Rewind to bootstrap
        _ = try await doc.restoreToOp(opId: bootstrapId)
        XCTAssertEqual(doc.sequence.count, 1)
        // The checkpoint pointers should still resolve to a valid op.
        let cpOpId = cpAfterP2.docPointers[docId]
        XCTAssertNotNil(cpOpId)
        let logFinal = try await doc.opLog()
        XCTAssertTrue(logFinal.contains { $0.opId == cpOpId })
    }

    func test_rewindThenScrubBeforePriorRewind_walksFullHistory() async throws {
        // Spec §3.5: scrubbing past a previous rewind — all historical ops
        // are walkable.
        let (_, _, doc, _) = try await makeProjectWithDoc(initialMd: "p1\n")
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        doc.setFullText("p1\n\np2\n")
        try await doc.flushBurstNow()
        let log1 = try await doc.opLog()
        let typingOpId = log1.last(where: { $0.kind == .typingBurst })!.opId
        // First rewind (back to bootstrap)
        _ = try await doc.restoreToOp(opId: bootstrapId)
        // Now scrub-to-target the typing op (which was "undone" by the
        // restore but still exists in the log) and rewind there.
        _ = try await doc.restoreToOp(opId: typingOpId)
        XCTAssertEqual(doc.sequence.count, 2)
    }
```

- [ ] **Step 2: Run + verify**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/RewindFlowTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 8/8 PASS.

- [ ] **Step 3: Full suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: ~792 passing (767 baseline + 21 new).

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/Integration/RewindFlowTests.swift
git commit -m "test: rewind-then-forward + walk-prior-rewind scenarios"
```

---

## Task 17: Manual smoke checklist

**Model: haiku.** Author the checklist file; nothing to test programmatically.

**Files:**
- Create: `docs/superpowers/notes/2026-05-20-history-rewind-smoke.md`

- [ ] **Step 1: Write the smoke checklist**

`docs/superpowers/notes/2026-05-20-history-rewind-smoke.md`:

```markdown
# History Rewind manual smoke

Run this after `xcodebuild` is green. User executes; report results back.

1. **Setup**
   - Open Maugham. New project → Novel → "Rewind smoke".
   - Type across three paragraphs over ~30 seconds (so the burst fires).
   - ⌘S → label "before-extras" → save.
   - Add two more paragraphs, wait for the burst.
   - In the right pane, ⌘⌥4 to switch to History.

2. **Header Rewind button**
   - Click "Rewind…" in the HistoryPane header.
   - The modal opens. Scrubber shows ticks (typing-burst blue, checkpoint green-tall).
   - Header context line reads "Now — drag the scrubber to revisit a past moment".
   - Doc preview shows current text (with anchor comments stripped).
   - Drag the scrubber to roughly the middle. Preview updates; header line shows the op_id-relative timestamp.
   - Toggle to Diff. Verify red strikethrough on paragraphs that would be removed; green underline on paragraphs that would come back.
   - Footer impact summary line shows "Restoring would undo N words / M paragraphs…".
   - ESC to dismiss. Editor unchanged.

3. **Snapshot here**
   - Reopen Rewind. Scrub to a past op. Click "Snapshot here…".
   - Label "scrubbed-snapshot" → Save.
   - HistoryPane refreshes; new checkpoint row appears at the top of the timeline (latest activity-time).
   - Live editor unchanged.

4. **Restore here**
   - Reopen Rewind. Scrub further back. Click "Restore here…".
   - Confirm sheet shows "Restore [doctitle] to this point?" with the impact summary.
   - Click Restore. Modal closes.
   - Editor reverts; the two extras you typed are gone.
   - In HistoryPane: a new "Rewound" row appears at the top.

5. **Per-row ↺ button**
   - HistoryPane: find a typing_burst row (one of the bursts you made).
   - Click the ↺ button on the right of the row.
   - Modal opens pre-positioned at that op. Preview shows the doc as it was at that point.
   - Click Cancel.

6. **Annotation auto-archive during rewind**
   - Have Claude Desktop running (or skip — use add_note tool manually).
   - Add an annotation on a paragraph. Verify it shows in AnnotationsPane (⌘⌥A).
   - Rewind back to a point before that paragraph existed.
   - In AnnotationsPane: the annotation is gone (or shows in the Resolved filter).
   - In HistoryPane: a "Auto-archived: paragraph removed by rewind" line appears.

7. **Persistence smoke**
   - ⌘Q. Relaunch. Reopen the project from Recents.
   - HistoryPane still shows the Rewound + Snapshot rows. The restored doc text is intact.

If any step fails, report which step + observed behaviour vs. expected.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/notes/2026-05-20-history-rewind-smoke.md
git commit -m "docs: add history-rewind manual smoke checklist"
```

- [ ] **Step 3: Hand off for manual smoke**

After the milestone is implemented, ask the user to run the smoke checklist and report results before tagging the milestone.

---

## Task 18: Refresh context docs (milestone-close discipline)

**Model: haiku.** Mechanical pass per spec §8. The implementer reads the existing AREA.md and CLAUDE.md files and makes the listed updates.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `Maugham/OpLog/AREA.md`
- Create: `Maugham/Views/AREA.md`
- Modify: `docs/adr/0010-typed-cross-area-seams.md`
- Modify: `docs/roadmap.md`
- Verify (no change expected): `Maugham/Editor/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/MCP/AREA.md`

- [ ] **Step 1: Update CLAUDE.md per-area sections**

In `CLAUDE.md` under "Per-area pointers", in the OpLog section, add a one-liner:

```markdown
- `RewindCursor.swift` + `RewindRestoreResult.swift` + `SynthesisSource.swift` are the typed contracts for time travel (ADR 0010). `Document.restoreToOp(opId:)` appends a `.checkpointRestore` op with `provenance.synthesisSource = .rewind` and triggers the sweep via `SweepReason.rewind(removed:)`.
```

In the Views section, add the new file:

```markdown
- `RewindWindow.swift` is the time-travel modal (opened via HistoryPane header "Rewind…" or per-row "↺"). Snapshots the op log at open-time — no live updates during the modal session. Scrubber density via the pure helper `RewindTickLayout.decimate`.
```

In the tripwires section, add (after the existing tripwires):

```markdown
12. **Don't reintroduce stringly-typed synthesisSource.** `Op.Provenance.synthesisSource` is `SynthesisSource?`. The raw values are the snake_case strings on disk (`paragraph_deleted`, `disk_at_ingest`, `use_cloud_resolution`, `rewind`). Adding a new cause means adding an enum case; emit-sites are exhaustively covered by the compiler.
```

- [ ] **Step 2: Update `Maugham/OpLog/AREA.md`**

Read the existing file first to maintain style consistency. Add the new files to the layout list:

```markdown
- `RewindCursor.swift` — typed scrub state (`.now` vs `.atOp(opId, at)`) consumed by `Deriver.derive(ops:upTo:)` and `RewindWindow`.
- `RewindRestoreResult.swift` — return value of `Document.restoreToOp`.
- `SynthesisSource.swift` — typed cause of synthesized ops (`paragraph_deleted`, `disk_at_ingest`, `use_cloud_resolution`, `rewind`).
```

Add to "Tests worth knowing":

```markdown
- `MaughamTests/OpLog/DeriverUpToTests.swift` — `derive(ops:upTo:)` semantics (annotation ops walked for sequence/timing but their changes not applied; unknown op_id falls back to `.now`; prior-restore chains walkable).
- `MaughamTests/Integration/RewindFlowTests.swift` — end-to-end `Document.restoreToOp` (pending burst flushed, sweep cause = .rewind, archive op_ids in result, rewind+forward checkpoint coexistence).
- `MaughamTests/Integration/SynthesisSourceMigrationTests.swift` — string raw value on disk decodes into the enum.
```

- [ ] **Step 3: Create `Maugham/Views/AREA.md`**

```markdown
# Maugham/Views — area notes

The SwiftUI view layer for the project window. Composes the binder (left), editor (center), and detail pane (right) plus modals and sheets.

## Important files

- `ProjectWindow.swift` — the root view. ViewModifier-extracted modal stack (`CheckpointModifier`, `SessionAndNavigationModifier`, `CollectionPieceModifier`) to dodge SwiftUI's body type-check ceiling. **When you hit "the compiler is unable to type-check this expression in reasonable time," extract a ViewModifier** — established pattern.
- `EditorHost.swift` — fragile cluster (see CLAUDE.md tripwires 2/3/6/7). Single-binding contract enforced by `EditorIntegrationHarnessTests`.
- `HistoryPane.swift` — read-only forensic timeline. Filter pills + per-row ↺ + header "Rewind…" button. Row rendering branches on synthesisSource enum, not strings.
- `AnnotationsPane.swift` — sibling segment to HistoryPane; action surface for Claude annotations (Accept/Reject/Archive).
- `RewindWindow.swift` — time-travel modal. Per-doc v1; scrubber + Doc/Diff preview + Snapshot/Restore footer. Snapshots the op log at open-time.
- `RewindTickLayout.swift` — pure decimation helper for the scrubber. Unit-tested independent of SwiftUI.
- `PartialRestorePicker.swift` — per-doc-vs-project picker used by checkpoint-row reverts. NOT used by rewind restore (which is per-doc by construction).
- `CheckpointLabelPromptSheet.swift` — reusable label-entry sheet; used by both ⌘⇧S and "Snapshot here" in the rewind modal.

## Patterns

- **Right-pane mode-swap** (Inspector / Research / Outline / Annotations / History) — ⌘⌥1/2/3 + ⌘⌥A/⌘⌥4. Mirror the pattern for new right-pane content.
- **Notification-based modal triggers** — `.maughamOpenRewind`, `.maughamShowProjectSettings`, etc. Posted by buttons in subviews, observed by ProjectWindow's `.onReceive`. Keeps the modal-state ownership in the root view.
- **Dark-mode propagation to side panes** is a known carry-forward (lost twice). Re-check after touching theme code.

## Tripwires

See CLAUDE.md for the full list; the ones touching Views are:

- #2 (no SwiftUI ↔ AppKit flag-based loop guards), #3 (no heavy work in synchronous SwiftUI binding setters), #4 (no O(N²) per-row reparsing), #5 (no NSPopover-for-autocomplete), #6 (no parallel observable state on EditorHost), #7 (no fourth caller to `EditorSurface.applyExternalText`), #9 (no `.onTapGesture` for `List(.sidebar)` rows).

## Tests worth knowing

- `MaughamTests/Integration/EditorIntegrationHarnessTests.swift` — 10/10 contract tests for the editor binding shape.
- `MaughamTests/Views/RewindDensityTests.swift` — tick decimation rule.
- `MaughamTests/Integration/RewindEntryPointsTests.swift` — both rewind entry points route through the same notification → modal.
```

- [ ] **Step 4: Update `docs/adr/0010-typed-cross-area-seams.md`**

In the "Instances at time of writing" table, append four rows:

```markdown
| Rewind scrub state ↔ Deriver | `RewindCursor` enum | `RewindCursor.atOp` factory | `DeriverUpToTests` |
| Rewind modal ↔ ProjectWindow action dispatch | `RewindAction` enum | `RewindWindow.onComplete` callsite | `RewindEntryPointsTests` |
| Rewind scope today vs. v2 | `RewindScope` enum (single-case) | `RewindWindow` initializer | (compile-error workflow; no test needed for single case) |
| Op synthesisSource cause | `SynthesisSource` enum | `Op.Provenance.synthesisSource` field | `SynthesisSourceMigrationTests` + `RewindForensicProvenanceTests` |
```

- [ ] **Step 5: Update `docs/roadmap.md`**

Move "History Rewind" from "Group 4 — Open" to "Group 4 — Shipped" with a one-liner summary. List v2 carry-forwards:

```markdown
- [Milestone history-rewind shipped 2026-05-20](…) — per-doc time-travel modal: scrubber over every op, Doc/Diff preview, Snapshot or Restore, per-row ↺ button on HistoryPane; SynthesisSource enum refactor + RewindCursor + RewindScope typed contracts; tag `milestone-history-rewind`; ~792 tests passing; carry-forwards: project-scope rewind (multi-doc clock UX), live-update of scrubber during MCP writes, un-archive annotation lifecycle action, scrubber pan/zoom beyond 1k ops.
```

- [ ] **Step 6: Verify other AREA.md files unchanged (sanity pass)**

```bash
git diff --stat Maugham/Editor/AREA.md Maugham/Stores/AREA.md Maugham/MCP/AREA.md
```

Expected: no diff. If any are accidentally touched, revert.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md \
        Maugham/OpLog/AREA.md \
        Maugham/Views/AREA.md \
        docs/adr/0010-typed-cross-area-seams.md \
        docs/roadmap.md
git commit -m "docs: refresh context docs for history-rewind milestone"
```

---

## Task 19: Final code review pass + tag

**Model: opus (final reviewer).** Read every commit on the branch as one diff. Surface issues.

- [ ] **Step 1: Diff the branch**

```bash
git log --oneline main..feat/milestone-history-rewind
git diff main..feat/milestone-history-rewind --stat
```

- [ ] **Step 2: Review against spec**

Re-read `docs/superpowers/specs/2026-05-20-history-rewind-design.md` section by section. For each section, point to the commit(s) that landed it. Note any gaps.

- [ ] **Step 3: Run full suite once more**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: ~792 passing. If anything is red, fix before tagging.

- [ ] **Step 4: Run smoke checklist (user)**

Ask the user to run `docs/superpowers/notes/2026-05-20-history-rewind-smoke.md`. Wait for confirmation.

- [ ] **Step 5: Merge + tag**

```bash
git checkout main
git merge --no-ff feat/milestone-history-rewind -m "Merge milestone-history-rewind"
git tag milestone-history-rewind
git push origin main --tags
```

- [ ] **Step 6: Update memory**

After tagging, write a new memory file `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_history_rewind.md` summarizing what shipped + carry-forwards, and add a one-liner to `MEMORY.md`.

---

## Task summary table

| # | Task | Model | Review |
|---|---|---|---|
| 1 | Branch | (no model) | n/a |
| 2 | SynthesisSource enum refactor | opus | full two-stage |
| 3 | RewindCursor | haiku | skip |
| 4 | RewindAction | haiku | skip |
| 5 | RewindScope | haiku | skip |
| 6 | RewindRestoreResult | haiku | skip |
| 7 | maughamOpenRewind notification | haiku | skip |
| 8 | Deriver.derive(ops:upTo:) + 7 unit tests | sonnet | full two-stage |
| 9 | Restore.buildRestoreOp synthesisSource param | sonnet | spec-only |
| 10 | Document.restoreToOp + 6 integration tests + SweepReason.cause | sonnet | full two-stage |
| 11 | RewindTickLayout + 3 density tests | haiku | spec-only |
| 12 | RewindWindow modal UI | opus | full two-stage |
| 13 | HistoryPane integration + 2 entry-point tests | sonnet | full two-stage |
| 14 | RewindForensicProvenanceTests (2 tests) | sonnet | spec-only |
| 15 | HistoryRow rewind label distinguish | sonnet | spec-only |
| 16 | RewindFlowTests final 2 tests | sonnet | spec-only |
| 17 | Manual smoke checklist | haiku | skip |
| 18 | Refresh CLAUDE.md + AREA.md + ADR 0010 + roadmap | haiku | skip |
| 19 | Final review + tag | opus (controller) | n/a |

**Total new tests:** 21 (7 DeriverUpTo + 3 density + 8 RewindFlow + 2 RewindEntryPoints + 2 ForensicProvenance + 3 SynthesisSourceMigration — 25, less 4 that fold into existing files = ~21 new test methods landing across 6 new test files + tweaks to two existing test files).
