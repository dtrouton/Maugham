import XCTest
import MaughamCore
@testable import Maugham

/// "Rewind to before this…" must land BEFORE the selected op — the state the
/// regretted op destroyed, not the state it produced (RULING-22 disposition,
/// 2026-08-08; claim M4-RW-002 / filing flip). The deep-link achieves that by
/// posting the PREDECESSOR op in the opId-ordered log; `Deriver.derive(upTo:)`
/// keeps its documented inclusive semantics (M4-RW-005).
@MainActor
final class HistoryPaneRewindTargetTests: XCTestCase {

    private struct Harness { let doc: Document }

    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = TestTemp.root
            .appendingPathComponent("HistoryRewindTarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Rewind Target", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        return Harness(doc: doc)
    }

    /// A three-paragraph document with a burst boundary after each paragraph
    /// (the RewindCharacterization fixture shape).
    private func makeThreeParagraphOps() async throws -> [Op] {
        let h = try await makeHarness("One.")
        h.doc.setFullText("One.\n\nTwo.\n"); try await h.doc.flushBurstNow()
        h.doc.setFullText("One.\n\nTwo.\n\nThree.\n"); try await h.doc.flushBurstNow()
        return try await h.doc.opLog()
    }

    func test_predecessorIndex_mapsEachOpToTheOneBefore_andOmitsTheFirst() async throws {
        let ops = try await makeThreeParagraphOps()
        XCTAssertGreaterThanOrEqual(ops.count, 3)

        let index = HistoryPane.predecessorIndex(ops: ops)

        XCTAssertNil(index[ops[0].opId],
                     "the first op has no 'before' — the deep-link is not offered there")
        for i in 1..<ops.count {
            XCTAssertEqual(index[ops[i].opId]?.opId, ops[i - 1].opId,
                           "every later op maps to its immediate predecessor in opId order")
        }
    }

    /// The op index rows resolve a lifecycle op's creation op through: every
    /// op by its id, and a duplicated id answered by the LATER op — what the
    /// per-lookup map it replaced answered (tripwire 4 fix).
    func test_opsIndex_keysEveryOpByItsId_andALaterDuplicateWins() async throws {
        let ops = try await makeThreeParagraphOps()
        XCTAssertGreaterThanOrEqual(ops.count, 3, "premise: three distinct ops")
        let index = HistoryPane.opsIndex(ops)
        XCTAssertEqual(index.count, ops.count)
        for op in ops { XCTAssertEqual(index[op.opId], op) }

        // The last op re-stamped with the first op's id.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try enc.encode(ops[ops.count - 1])) as? [String: Any])
        let idKey = try XCTUnwrap(json.first { ($0.value as? String) == ops[ops.count - 1].opId }?.key)
        json[idKey] = ops[0].opId
        let later = try dec.decode(Op.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(later.opId, ops[0].opId)
        XCTAssertNotEqual(later, ops[0], "premise: same id, different op")
        XCTAssertEqual(HistoryPane.opsIndex(ops + [later])[ops[0].opId], later)
        XCTAssertEqual(HistoryPane.opsIndex([later] + ops)[ops[0].opId], ops[0])
    }

    /// The timeline builds its rows and op index once per body pass; nothing
    /// rebuilds the index per lookup, and `entries` is read in one place.
    func test_theTimelineFiltersAndIndexesOncePerPass() throws {
        let code = SourceScan.codeLines(
            of: try HistoryPaneSource.source(of: "HistoryPaneTimeline.swift"))
            .joined(separator: "\n")
        XCTAssertFalse(HistoryPaneSource.surfaceFiles.contains {
            (try? HistoryPaneSource.source(of: $0))?.contains("opsByOpId") ?? true
        }, "the per-lookup index is gone from every file of the pane")
        XCTAssertEqual(code.components(separatedBy: "entries").count - 1, 2,
                       "`entries` is declared once and read once (`let rows = entries`)")
    }

    func test_rewindBeforeThis_excludesTheTargetOpsOwnEffect() async throws {
        let ops = try await makeThreeParagraphOps()
        let index = HistoryPane.predecessorIndex(ops: ops)

        // The burst that ADDED "Two." — the op a writer regrets in this fixture.
        let target = try XCTUnwrap(ops.first { op in
            op.kind == .typingBurst && op.changes.contains { $0.next.contains("Two") }
        })
        let before = try XCTUnwrap(index[target.opId])

        let state = Deriver.derive(ops: ops, upTo: .atOp(opId: before.opId, at: before.at))
        let text = state.sequence.compactMap { state.paragraphs[$0] }.joined(separator: "\n")

        XCTAssertTrue(text.contains("One"), "what came before the regretted op survives")
        XCTAssertFalse(text.contains("Two"),
                       "'Rewind to before this…' lands BEFORE the op: its own effect is gone")
    }
}
