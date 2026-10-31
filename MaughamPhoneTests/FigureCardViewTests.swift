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

    func test_aFifteenRowTablePlansTwelveRowsTheMoreLineAndTheTotalRow() throws {
        let plan = FigureCardPlan.plan(card: model(rows: 15, header: 1, total: true),
                                       imageURL: nil, loaded: true)
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
            card: model(rows: 3), imageURL: nil, loaded: true)))
        XCTAssertEqual(table.headerRows, [])
        XCTAssertEqual(table.bodyRows.count, 3)
        XCTAssertNil(table.more)
        XCTAssertNil(table.totalRow)
        XCTAssertEqual(table.columnCount, 2)
    }

    func test_eachColumnKeepsItsAlignment_numbersRight() throws {
        let card = model(rows: 3) { _, c in c == 0 ? .text("x") : .number(1) }
        let table = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: card, imageURL: nil, loaded: true)))
        XCTAssertEqual(table.alignments, [.left, .right])
    }

    func test_automaticAlignmentDrawsLeft_andAMissingOneIsLeft() throws {
        var card = model(rows: 1)
        card.columnAlignments = [.automatic]
        let table = try XCTUnwrap(tablePlan(FigureCardPlan.plan(card: card, imageURL: nil, loaded: true)))
        XCTAssertEqual(table.alignments, [.left, .left])
    }

    func test_parkedRemovedAmbiguousAndEmptyPlanTheirWords() {
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.parked), imageURL: nil, loaded: true),
                       .label(FigureCardText.parked))
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.removed), imageURL: nil, loaded: true),
                       .label(FigureCardText.removed))
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.ambiguous), imageURL: nil, loaded: true),
                       .label(FigureCardText.ambiguous))
        XCTAssertEqual(FigureCardPlan.plan(card: model(rows: 0), imageURL: nil, loaded: true),
                       .label(FigureCardText.empty))
    }

    /// A registered figure whose files have not arrived has no card: it says
    /// so, neutrally — never "Figure removed", never data — and offers Retry.
    func test_noCardAfterALoadIsNotDownloadedYet() {
        let plan = FigureCardPlan.plan(card: nil, imageURL: nil, loaded: true)
        XCTAssertEqual(plan, .label(FigureCardText.notReady))
        XCTAssertNotEqual(plan, .label(FigureCardText.removed))
        XCTAssertTrue(plan.offersRetry)
        XCTAssertFalse(FigureCardPlan.label(FigureCardText.parked).offersRetry)
    }

    func test_beforeTheCardsLoadTheFigureIsLoading() {
        XCTAssertEqual(FigureCardPlan.plan(card: nil, imageURL: nil, loaded: false), .loading)
        XCTAssertEqual(FigureCardPlan.plan(card: model(rows: 3), imageURL: nil, loaded: false), .loading)
    }

    func test_anImageDrawsItsPicture_andALineWithNoLocalPictureDrawsOnlyItsCaption() {
        let url = URL(fileURLWithPath: "/p/research/shot.jpg")
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.image), imageURL: url, loaded: true),
                       .picture(url))
        XCTAssertEqual(FigureCardPlan.plan(card: .placeholder(.image), imageURL: nil, loaded: true),
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

    func test_figurePathsIncludeQuotedFigures_once() {
        let cash = MarkdownBlocks.Block.figure(caption: "Cash", path: "../figures/cash.csv", label: nil)
        let blocks: [MarkdownBlocks.Block] = [
            cash,
            .quote([.figure(caption: "Map", path: "../figures/map.png", label: nil)]),
            .paragraph("between"),
            .figure(caption: "Cash again", path: "../figures/cash.csv", label: nil),
        ]
        XCTAssertEqual(DocumentReaderView.figurePaths(blocks), ["../figures/cash.csv", "../figures/map.png"])
    }
}
