import XCTest
@testable import Maugham

final class HistoryEntryMergeTests: XCTestCase {

    private func makeOp(
        id: String, kind: OpKind, at: Date,
        provenance: Op.Provenance? = nil
    ) -> Op {
        Op(opId: id, docId: "d", at: at, device: "x", session: "s",
           kind: kind, changes: [], sequence: nil, provenance: provenance)
    }

    private func makeCheckpoint(id: String, at: Date, label: String) -> Checkpoint {
        Checkpoint(
            checkpointId: id, label: label, labelSource: .user,
            at: at, device: "x", activeDoc: "doc.md",
            docPointers: [:], manuscriptWordCount: 100)
    }

    func test_merge_orderReverseChronological() {
        let now = Date()
        let opEarly = makeOp(id: "01A", kind: .typingBurst,
            at: now.addingTimeInterval(-60))
        let opLate = makeOp(id: "01C", kind: .claudeComment,
            at: now.addingTimeInterval(-10),
            provenance: Op.Provenance(annotationBody: "x"))
        let cpMid = makeCheckpoint(id: "cp1",
            at: now.addingTimeInterval(-30), label: "midpoint")

        let merged = HistoryEntry.merge(
            ops: [opEarly, opLate], checkpoints: [cpMid])

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].timestamp, opLate.at)
        XCTAssertEqual(merged[1].timestamp, cpMid.at)
        XCTAssertEqual(merged[2].timestamp, opEarly.at)
    }

    func test_filter_annotationsPill_includesAllClaudeOps() {
        let now = Date()
        let comment = makeOp(id: "1", kind: .claudeComment, at: now)
        let accept = makeOp(id: "2", kind: .claudeAccept,
            at: now.addingTimeInterval(1))
        let burst = makeOp(id: "3", kind: .typingBurst,
            at: now.addingTimeInterval(2))
        let merged = HistoryEntry.merge(
            ops: [comment, accept, burst], checkpoints: [])
        let annotations = merged.filter {
            HistoryFilter.annotations.matches($0)
        }
        XCTAssertEqual(annotations.count, 2)
    }

    func test_filter_editsPill_includesTypingBurstAndBootstrap() {
        let now = Date()
        let burst = makeOp(id: "1", kind: .typingBurst, at: now)
        let bs = makeOp(id: "2", kind: .bootstrap, at: now)
        let ext = makeOp(id: "3", kind: .externalEdit, at: now)
        let merged = HistoryEntry.merge(ops: [burst, bs, ext], checkpoints: [])
        let edits = merged.filter { HistoryFilter.edits.matches($0) }
        XCTAssertEqual(edits.count, 2)  // burst + bootstrap, not external
    }
}
