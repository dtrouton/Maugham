import XCTest
@testable import Maugham
@testable import MaughamCore

/// The inspector's version rows (report plan 9d Task 6 and its final fix
/// wave): labels, the assistant's two marks, and when Restore is off and why.
final class ResearchVersionsModelTests: XCTestCase {
    private func version(_ name: String, at t: TimeInterval, by w: ResearchWriter?,
                         replacedBy r: ResearchWriter? = nil) -> ResearchVersion {
        ResearchVersion(itemId: "t1", name: name, savedAt: Date(timeIntervalSince1970: t), writtenBy: w, replacedBy: r)
    }

    func test_rowsKeepTheOrderAndMarkOnlyTheAssistantsVersions() {
        let list = [version("b", at: 200, by: .assistant), version("a", at: 100, by: .writer),
                    version("c", at: 50, by: nil)]
        let rows = ResearchVersionsModel.rows(from: list, refusal: nil) { "T\(Int($0.timeIntervalSince1970))" }
        XCTAssertEqual(rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(rows.map(\.when), ["T200", "T100", "T50"])
        XCTAssertEqual(rows.map(\.mark), ["Written by assistant", nil, nil])
        XCTAssertTrue(rows.allSatisfy(\.canRestore))
        XCTAssertEqual(ResearchVersionsModel.previous(in: rows)?.id, "b", "the newest is the previous version")
    }

    /// **The state an assistant's write replaced reads "Before the
    /// assistant’s change"**, beside "Written by assistant" for bytes Claude
    /// wrote (final review I1). Disable experiment: drop `replacedMark` from
    /// `rows`, and the version right after Claude's write is unmarked.
    func test_theStateBeforeAnAssistantsWriteIsMarkedSo() {
        let list = [version("after", at: 300, by: .assistant, replacedBy: .writer),
                    version("before", at: 200, by: .writer, replacedBy: .assistant),
                    version("old", at: 100, by: nil)]
        let rows = ResearchVersionsModel.rows(from: list, refusal: nil)
        XCTAssertEqual(rows.map(\.replacedMark), [nil, "Before the assistant’s change", nil])
        XCTAssertEqual(rows.map(\.mark), ["Written by assistant", nil, nil])
    }

    /// **A view-only share lists the versions with Restore off, and says why**
    /// (final review M2): the reason is the grid's own.
    func test_aViewOnlyShareListsButRestoresNothing() {
        let refusal = ResearchVersionsModel.restoreRefusal(shareIsReadOnly: true, reviewing: false)
        XCTAssertEqual(refusal, .viewOnlyShare)
        let rows = ResearchVersionsModel.rows(from: [version("a", at: 1, by: .writer)], refusal: refusal)
        XCTAssertEqual(rows.count, 1, "the version is listed")
        XCTAssertFalse(rows[0].canRestore)
        XCTAssertNil(ResearchVersionsModel.previous(in: rows))
        XCTAssertEqual(refusal?.sentence, "This share is view-only, so the table can’t be changed.")
    }

    /// **Review reads the table; its Restore is off, with the review reason.**
    /// Disable experiment: answer nil for `reviewing` in `restoreRefusal`, and
    /// Review restores.
    func test_reviewListsButRestoresNothing() {
        let refusal = ResearchVersionsModel.restoreRefusal(shareIsReadOnly: false, reviewing: true)
        XCTAssertEqual(refusal, .reviewMode)
        let rows = ResearchVersionsModel.rows(from: [version("a", at: 1, by: .writer)], refusal: refusal)
        XCTAssertFalse(rows[0].canRestore)
        XCTAssertNil(ResearchVersionsModel.previous(in: rows))
        XCTAssertEqual(refusal?.sentence, "You’re reviewing — the table can be read, not changed.")
        XCTAssertEqual(ResearchVersionsModel.restoreRefusal(shareIsReadOnly: true, reviewing: true), .viewOnlyShare,
                       "a view-only share is said first")
        XCTAssertNil(ResearchVersionsModel.restoreRefusal(shareIsReadOnly: false, reviewing: false))
    }

    /// **Nothing flashes while the first listing loads** (final review M1):
    /// the empty line waits for a listing that came back empty.
    func test_theEmptyLineWaitsForTheListing() {
        XCTAssertNil(ResearchVersionsModel.emptyLine(for: nil), "loading says nothing")
        XCTAssertEqual(ResearchVersionsModel.emptyLine(for: []), "No earlier versions yet.")
        XCTAssertNil(ResearchVersionsModel.emptyLine(
            for: ResearchVersionsModel.rows(from: [version("a", at: 1, by: nil)], refusal: nil)))
    }

    func test_noVersionsHasNoPrevious_andOutcomesSpeakInSentences() {
        XCTAssertNil(ResearchVersionsModel.previous(in: []))
        XCTAssertEqual(ResearchVersionsModel.sentence(for: .whole), "Restored.")
        XCTAssertTrue(ResearchVersionsModel.sentence(for: .cellsOnly).contains("couldn’t be restored"))
    }

    /// A version of another kind is listed with Restore off, and "Restore
    /// previous version" skips to the newest that can be restored.
    func test_aVersionOfAnotherKindIsListedButNotOffered() {
        let list = [ResearchVersion(itemId: "n", name: "b", savedAt: Date(timeIntervalSince1970: 2),
                                    writtenBy: nil, payload: .table),
                    ResearchVersion(itemId: "n", name: "a", savedAt: Date(timeIntervalSince1970: 1),
                                    writtenBy: nil, payload: .note)]
        let rows = ResearchVersionsModel.rows(from: list, refusal: nil, kind: .note)
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
        XCTAssertEqual(rows.map(\.canRestore), [false, true])
        XCTAssertEqual(ResearchVersionsModel.previous(in: rows)?.id, "a")
    }

    func test_theSectionShowsForANote() {
        func item(_ kind: ResearchItem.AssetKind, _ path: String?) -> ResearchItem {
            ResearchItem(id: "i", title: "T", type: .asset, kind: kind, path: path)
        }
        XCTAssertEqual(ResearchVersionsModel.kind(for: item(.document, "research/n.md"), structure: []), .note)
        XCTAssertEqual(ResearchVersionsModel.kind(for: item(.table, "research/t.csv"), structure: []), .table)
        XCTAssertNil(ResearchVersionsModel.kind(for: item(.image, "research/p.png"), structure: []))
        XCTAssertNil(ResearchVersionsModel.kind(for: item(.document, nil), structure: []))
        XCTAssertNil(ResearchVersionsModel.kind(for: item(.document, "manuscript/a.md"), structure: []),
                     "a text file outside a research root is not a note: no Versions section")
    }

    /// A refusal names what it refuses: a note's section says "note", a
    /// table's sentence is unchanged.
    func test_refusalsNameTheNoteOrTheTable() {
        XCTAssertEqual(FigureGridGate.Reason.viewOnlyShare.sentence,
                       "This share is view-only, so the table can’t be changed.")
        XCTAssertEqual(FigureGridGate.Reason.viewOnlyShare.sentence(noun: "note"),
                       "This share is view-only, so the note can’t be changed.")
        XCTAssertEqual(FigureGridGate.Reason.reviewMode.sentence(noun: "note"),
                       "You’re reviewing — the note can be read, not changed.")
        XCTAssertEqual(FigureGridGate.Reason.reviewMode.sentence,
                       "You’re reviewing — the table can be read, not changed.")
        XCTAssertEqual(ResearchTableHost.Refused(reason: .viewOnlyShare, noun: "note").errorDescription,
                       "This share is view-only, so the note can’t be changed.")
        XCTAssertEqual(ResearchTableHost.Refused(reason: .viewOnlyShare).errorDescription,
                       "This share is view-only, so the table can’t be changed.")
    }
}
