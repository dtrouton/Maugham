import XCTest
import MaughamCore
@testable import Maugham

/// `RecoveredHistorySheet.append` is a pure-over-its-argument static
/// function precisely so this is testable without mounting the sheet
/// (mirrors `HistoryPane.predecessorIndex`). Covers the append-logic half of
/// task 5: appending an orphan lands as a fresh paragraph at the end of the
/// OPEN document's sequence, and the closed-document copy is pinned
/// separately.
@MainActor
final class RecoveredHistorySheetTests: XCTestCase {

    private func makeDocument(_ initialMd: String = "One.") async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveredHistorySheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Recovered History", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        return try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                       device: "test", session: "s", presenter: nil)
    }

    func test_append_landsTheOrphanTextAtTheEndOfTheSequence() async throws {
        let doc = try await makeDocument("One.\n\nTwo.\n")
        let orphan = RecoveredHistoryReport.Orphan(paragraphId: "orig-id", text: "Recovered paragraph.")

        let newId = RecoveredHistorySheet.append(orphan, to: doc)

        XCTAssertEqual(doc.sequence.last, newId,
                       "the orphan lands after whatever was previously last")
        XCTAssertEqual(doc.paragraph(id: newId), "Recovered paragraph.")
        XCTAssertNotEqual(newId, orphan.paragraphId,
                          "a fresh id — an ordinary op, not a resurrection of the original one")
    }

    func test_append_ordersRepeatedAppendsInClickOrder() async throws {
        let doc = try await makeDocument("One.")
        let first = RecoveredHistoryReport.Orphan(paragraphId: "a", text: "First recovered.")
        let second = RecoveredHistoryReport.Orphan(paragraphId: "b", text: "Second recovered.")

        let firstId = RecoveredHistorySheet.append(first, to: doc)
        let secondId = RecoveredHistorySheet.append(second, to: doc)

        let tail = doc.sequence.suffix(2)
        XCTAssertEqual(Array(tail), [firstId, secondId])
    }

    func test_append_onAnEmptyDocument_stillAppends() async throws {
        let doc = try await makeDocument("")
        let orphan = RecoveredHistoryReport.Orphan(paragraphId: "orig-id", text: "Only paragraph.")

        let newId = RecoveredHistorySheet.append(orphan, to: doc)

        XCTAssertEqual(doc.sequence, [newId])
        XCTAssertEqual(doc.paragraph(id: newId), "Only paragraph.")
    }

    func test_documentClosedReason_isHonestCopy() {
        XCTAssertEqual(RecoveredHistorySheet.documentClosedReason,
                       "Open the document to append")
    }
}
