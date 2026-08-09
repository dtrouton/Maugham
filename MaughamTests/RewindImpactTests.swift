import XCTest
import MaughamCore
@testable import Maugham

/// RULING-28 — the collateral report has two halves, and both derive from one
/// source of numbers: `RewindImpact`. The confirm-time preview mirrors what
/// `restoreToOp` will actually do (archives, reopens, re-accepts, words); the
/// after-toast renders what it actually did. Naming one class of collateral
/// and omitting another is worse than naming none. `changesAnything` is
/// RULING-37's view half: Restore is not offered when there is nothing to do.
@MainActor
final class RewindImpactTests: XCTestCase {

    private struct Harness { let doc: Document; let pid: String }

    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindImpact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Impact", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid)
    }

    private func paragraphId(in doc: Document, containing needle: String) async throws -> String {
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        return try XCTUnwrap(burst?.changes.first { $0.next.contains(needle) }?.paragraphId)
    }

    func test_preview_namesTheArchiveTheSweepWillPerform() async throws {
        let h = try await makeHarness("First.")
        try await h.doc.flushBurstNow()
        let early = try await h.doc.opLog().last!.opId
        h.doc.setFullText("First.\n\nSecond.\n"); try await h.doc.flushBurstNow()
        let p2 = try await paragraphId(in: h.doc, containing: "Second")
        _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: p2, body: "note")
        let ops = try await h.doc.opLog()

        let p = RewindImpact.preview(ops: ops, cursorOpId: early)

        XCTAssertEqual(p.annotationsToArchive, 1,
                       "the open comment on the paragraph being rewound away")
        XCTAssertEqual(p.paragraphsRemoved, 1)
        XCTAssertGreaterThan(p.wordsUndone, 0)
        XCTAssertTrue(p.changesAnything)
    }

    func test_preview_atTheTip_hasNothingToDo() async throws {
        let h = try await makeHarness("First.")
        h.doc.setFullText("First.\n\nSecond.\n"); try await h.doc.flushBurstNow()
        let ops = try await h.doc.opLog()
        let tip = ops.last!.opId

        let p = RewindImpact.preview(ops: ops, cursorOpId: tip)

        XCTAssertFalse(p.changesAnything,
                       "RULING-37's view half: Restore is not offered when nothing would change")
        XCTAssertEqual(p.annotationsToArchive, 0)
    }

    func test_preview_namesTheReopenTheReturnJourneyWillPerform() async throws {
        let h = try await makeHarness("First.")
        try await h.doc.flushBurstNow()
        let early = try await h.doc.opLog().last!.opId
        h.doc.setFullText("First.\n\nSecond.\n"); try await h.doc.flushBurstNow()
        let p2 = try await paragraphId(in: h.doc, containing: "Second")
        _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: p2, body: "note")
        try await h.doc.flushBurstNow()
        let later = try await h.doc.opLog().last!.opId
        _ = try await h.doc.restoreToOp(opId: early)   // sweep archives the comment
        let ops = try await h.doc.opLog()

        let p = RewindImpact.preview(ops: ops, cursorOpId: later)

        XCTAssertEqual(p.annotationsToReopen, 1,
                       "travelling forward will reopen what the sweep archived (RULING-25)")
        XCTAssertEqual(p.annotationsToArchive, 0)
    }

    func test_confirmSummary_namesEveryNonZeroClass_andOmitsZeroOnes() {
        var p = RewindImpact.Preview(
            wordsUndone: 240, paragraphsRemoved: 3, annotationsToArchive: 2,
            annotationsToReopen: 1, acceptsToReopen: 0, acceptsToRestore: 0,
            changesAnything: true)
        var s = RewindImpact.confirmSummary(p)
        XCTAssertTrue(s.contains("240 words"))
        XCTAssertTrue(s.contains("2 notes will be archived"))
        XCTAssertTrue(s.contains("1 note will be reopened"))
        XCTAssertFalse(s.contains("suggestion"), "zero classes are not mentioned")

        p.annotationsToArchive = 0; p.annotationsToReopen = 0; p.acceptsToReopen = 1
        s = RewindImpact.confirmSummary(p)
        XCTAssertTrue(s.contains("1 accepted suggestion reopened"))
        XCTAssertFalse(s.contains("archived"))
    }

    func test_toast_reportsWhatActuallyHappened_andNamesANearestResolution() {
        let done = RewindRestoreResult(
            restoreOp: Op(opId: "01X", docId: "d", at: Date(), device: "t", session: "s",
                          kind: .checkpointRestore, changes: [], sequence: nil, provenance: nil),
            archivedAnnotationOpIds: ["a1", "a2", "a3"],
            removedParagraphIds: ["p1"],
            priorSequenceCount: 3, newSequenceCount: 2,
            reopenedAnnotationOpIds: [],
            travelReopenedAnnotationIds: ["r1"],
            targetResolution: .exact)
        let t = try? XCTUnwrap(RewindImpact.toast(for: done))
        XCTAssertTrue(t!.hasPrefix("Restored."))
        XCTAssertTrue(t!.contains("3 notes auto-archived"))
        XCTAssertTrue(t!.contains("1 note reopened"))

        let nearest = RewindRestoreResult(
            restoreOp: nil, archivedAnnotationOpIds: [], removedParagraphIds: [],
            priorSequenceCount: 3, newSequenceCount: 3, reopenedAnnotationOpIds: [],
            targetResolution: .nearest(requested: "01GONE", restoredTo: "01HERE"))
        let n = try? XCTUnwrap(RewindImpact.toast(for: nearest))
        XCTAssertTrue(n!.contains("That exact moment is gone"),
                      "the substitution is named (RULING-27)")

        let noOp = RewindRestoreResult(
            restoreOp: nil, archivedAnnotationOpIds: [], removedParagraphIds: [],
            priorSequenceCount: 3, newSequenceCount: 3, reopenedAnnotationOpIds: [],
            targetResolution: .exact)
        XCTAssertNil(RewindImpact.toast(for: noOp),
                     "a genuine no-op has nothing to report")
    }
}
