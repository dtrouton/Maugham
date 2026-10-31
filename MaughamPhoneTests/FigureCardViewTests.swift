import XCTest
@testable import MaughamPhone
import MaughamCore

/// Report plan 9b Task 5: what the phone's figure card draws, asserted on the
/// view's pure plan (`FigureCardPlan`), never on pixels.
final class FigureCardViewTests: XCTestCase {

    private let en = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")

    /// A table of `rows` rows built by Core's own card builder, as the phone's
    /// `PhoneFigureBook` builds it.
    private func model(rows: Int, header: Int = 0, total: Bool = false,
                       cell: (Int, Int) -> CellValue = { r, c in .text("r\(r)c\(c)") }) -> FigureCardModel {
        var table = FigureTable(rows: rows, columns: 2)
        table.headerRows = header
        table.hasTotalRow = total
        for (r, rid) in table.rows.enumerated() {
            for (c, cid) in table.columns.enumerated() {
                table.setCell(Cell(content: .value(cell(r, c))), at: CellKey(row: rid, column: cid))
            }
        }
        let state = FigureState(kind: .table, table: table)
        return FigureCardModel.build(figureId: "f1", state: state, values: { key in
            if case .value(let v)? = state.table[key]?.content { return v }
            return .empty
        }, locale: en, language: nil)
    }

    private func tablePlan(_ plan: FigureCardPlan, file: StaticString = #filePath,
                           line: UInt = #line) -> FigureTablePlan? {
        guard case .table(let table) = plan else {
            XCTFail("expected a table plan, got \(plan)", file: file, line: line)
            return nil
        }
        return table
    }

    private func dotModel(marks: Set<FigureCardModel.Position>) -> FigureCardModel {
        FigureCardModel(kind: .table, headerRows: [["h1", "h2"]],
                        bodyRows: [["a", "b"], ["c", "d"], ["t1", "t2"]],
                        hasTotalRow: true, hasOpenCellNotes: !marks.isEmpty, markedCells: marks)
    }

    func test_aMarkedCellPlansADot_inHeaderBodyAndTotalRows() throws {
        let card = dotModel(marks: [.init(row: 0, column: 1), .init(row: 2, column: 0), .init(row: 3, column: 1)])
        let plan = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: card, imageURL: nil)))
        XCTAssertEqual(plan.headerMarks, [[1]])
        XCTAssertEqual(plan.bodyMarks, [[], [0]])
        XCTAssertEqual(plan.totalMarks, [1])
    }

    func test_anUnmarkedCardPlansNoDot() throws {
        let plan = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: dotModel(marks: []), imageURL: nil)))
        XCTAssertEqual(plan.headerMarks, [[]])
        XCTAssertEqual(plan.bodyMarks, [[], []])
        XCTAssertEqual(plan.totalMarks, [])
    }

    /// Core marks nothing for a row the card cuts short (FigureCellNotesTests), though
    /// the figure still has a live note: the phone draws no dot.
    func test_aNoteOnACutOffRowGivesNoDot() throws {
        let card = FigureCardModel(kind: .table, bodyRows: [["a"]], moreRows: 3, hasOpenCellNotes: true)
        let plan = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: card, imageURL: nil)))
        XCTAssertEqual(plan.bodyMarks, [[]])
        XCTAssertNotNil(plan.more)
    }

    func test_aFifteenRowTablePlansTwelveRowsTheMoreLineAndTheTotalRow() throws {
        let plan = FigureCardPlan.plan(card: model(rows: 15, header: 1, total: true),
                                       imageURL: nil)
        let table = try XCTUnwrap(tablePlan(plan))
        XCTAssertEqual(table.headerRows, [["r0c0", "r0c1"]])
        XCTAssertEqual(table.bodyRows.count, 10)
        XCTAssertEqual(table.bodyRows.first, ["r1c0", "r1c1"])
        XCTAssertEqual(table.bodyRows.last, ["r10c0", "r10c1"])
        XCTAssertEqual(table.more, "+ 3 more rows")
        XCTAssertEqual(table.more, FigureCardText.more(3))
        XCTAssertEqual(table.totalRow, ["r14c0", "r14c1"], "the total row is kept, ruled under the more line")
        XCTAssertEqual(table.headerRows.count + table.bodyRows.count + 1, 12)
    }

    func test_aShortTableHasNoMoreLineAndNoTotal() throws {
        let table = try XCTUnwrap(tablePlan(FigureCardPlan.plan(
            card: model(rows: 3), imageURL: nil)))
        XCTAssertEqual(table.headerRows, [])
        XCTAssertEqual(table.bodyRows.count, 3)
        XCTAssertNil(table.more)
        XCTAssertNil(table.totalRow)
        XCTAssertEqual(table.columnCount, 2)
    }

    func test_eachColumnKeepsItsAlignment_numbersRight() throws {
        let card = model(rows: 3) { _, c in c == 0 ? .text("x") : .number(1) }
        let table = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: card, imageURL: nil)))
        XCTAssertEqual(table.alignments, [.left, .right])
    }

    func test_automaticAlignmentDrawsLeft_andAMissingOneIsLeft() throws {
        var card = model(rows: 1)
        card.columnAlignments = [.automatic]
        let table = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: card, imageURL: nil)))
        XCTAssertEqual(table.alignments, [.left, .left])
    }

    func test_parkedAmbiguousAndEmptyPlanTheirWords() {
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.parked), imageURL: nil),
                       .label(FigureCardText.parked))
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.ambiguous), imageURL: nil),
                       .label(FigureCardText.ambiguous))
        XCTAssertEqual(FigureCardPlan.plan(card: model(rows: 0), imageURL: nil),
                       .label(FigureCardText.empty))
    }

    /// A registered figure whose files have not arrived has no card: it says
    /// so, neutrally — never "Figure removed", never data — and offers Retry.
    func test_noCardAfterALoadIsNotDownloadedYet() {
        let plan = FigureCardPlan.plan(card: nil, imageURL: nil)
        XCTAssertEqual(plan, .label(FigureCardText.notReady))
        XCTAssertNotEqual(plan, .label(FigureCardText.removed))
        XCTAssertTrue(plan.offersRetry)
        XCTAssertFalse(FigureCardPlan.label(FigureCardText.parked).offersRetry)
    }

    /// A `figures/` path the registry does not name may be a figure whose
    /// registration has not synced: the phone never says "Figure removed".
    func test_anUnregisteredFiguresPathIsNotDownloadedYet_neverRemoved() {
        let plan = FigureCardPlan.plan(card: .placeholder(.removed), imageURL: nil)
        XCTAssertEqual(plan, .label(FigureCardText.notReady))
        XCTAssertTrue(plan.offersRetry)
    }

    func test_anImageDrawsItsPicture_andALineWithNoLocalPictureDrawsOnlyItsCaption() {
        let url = URL(fileURLWithPath: "/p/research/shot.jpg")
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.image), imageURL: url),
                       .picture(url))
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.image), imageURL: nil),
                       .captionOnly, "a remote or outside path: no picture to load, no placeholder")
        XCTAssertEqual(FigureCardPlan.picture(url).pictureURL, url)
        XCTAssertNil(FigureCardPlan.captionOnly.pictureURL)
    }

    func test_thePicturesToLoadAreEachDistinctPictureOnce() {
        let a = URL(fileURLWithPath: "/p/a.png"), b = URL(fileURLWithPath: "/p/b.png")
        let plans: [String: FigureCardPlan] = [
            "a": .picture(a), "a2": .picture(a), "b": .picture(b), "t": .label(FigureCardText.parked),
        ]
        XCTAssertEqual(FigureCardPlan.picturesToLoad(plans), [a, b])
    }

    func test_figurePathsAreTopLevelFiguresOnce_aQuotedLineIsText() {
        let blocks = MarkdownBlocks.parse("""
            ![Cash](../figures/cash.csv)

            > ![Map](../figures/map.png)

            ![Cash again](../figures/cash.csv)
            """)
        XCTAssertEqual(DocumentReaderView.figurePaths(blocks), ["../figures/cash.csv"])
        XCTAssertTrue(DocumentReaderView.hasFigureLine(blocks))
        XCTAssertFalse(DocumentReaderView.hasFigureLine(MarkdownBlocks.parse("> ![Map](../figures/map.png)")))
    }
}
