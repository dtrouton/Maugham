import XCTest
@testable import Maugham
@testable import MaughamCore

/// The inspector's version rows (report plan 9d Task 6): labels, the
/// assistant's mark, and what a view-only share may restore.
final class ResearchVersionsModelTests: XCTestCase {
    private func version(_ name: String, at t: TimeInterval, by w: ResearchWriter?) -> ResearchVersion {
        ResearchVersion(itemId: "t1", name: name, savedAt: Date(timeIntervalSince1970: t), writtenBy: w)
    }

    func test_rowsKeepTheOrderAndMarkOnlyTheAssistantsVersions() {
        let list = [version("b", at: 200, by: .assistant), version("a", at: 100, by: .writer),
                    version("c", at: 50, by: nil)]
        let rows = ResearchVersionsModel.rows(from: list, viewOnly: false) { "T\(Int($0.timeIntervalSince1970))" }
        XCTAssertEqual(rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(rows.map(\.when), ["T200", "T100", "T50"])
        XCTAssertEqual(rows.map(\.mark), ["Written by assistant", nil, nil])
        XCTAssertTrue(rows.allSatisfy(\.canRestore))
        XCTAssertEqual(ResearchVersionsModel.previous(in: rows)?.id, "b", "the newest is the previous version")
    }

    func test_aViewOnlyShareRestoresNothing() {
        let rows = ResearchVersionsModel.rows(from: [version("a", at: 1, by: .writer)], viewOnly: true)
        XCTAssertFalse(rows[0].canRestore)
        XCTAssertNil(ResearchVersionsModel.previous(in: rows))
    }

    func test_noVersionsHasNoPrevious_andOutcomesSpeakInSentences() {
        XCTAssertNil(ResearchVersionsModel.previous(in: []))
        XCTAssertEqual(ResearchVersionsModel.sentence(for: .whole), "Restored.")
        XCTAssertTrue(ResearchVersionsModel.sentence(for: .cellsOnly).contains("couldn’t be restored"))
    }
}
