import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The read-only table card under a figure line (report plan 7a Task 6),
/// asserted as its drawing plan: rows, rules, the "+ N more rows" line, the
/// banner, the corner and the labelled cards, as rectangles and strings. No
/// pixels; the mounted cases live in `FigureThumbnailTests`.
@MainActor
final class FigureCardDrawingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the room is measured in the production card font
    }

    /// Ten points a character, bold or not: widths are exact.
    private func measure(_ text: String, _ bold: Bool) -> CGFloat { CGFloat(text.count) * 10 }

    private let row: CGFloat = 20

    private func plan(_ model: FigureCardModel, width: CGFloat = 600) -> FigureCardDrawing.Plan? {
        FigureCardDrawing.plan(for: model, lineBottom: 100, columnX: 40, columnWidth: width,
                               rowHeight: row, measure: measure)
    }

    private func table(rows body: Int, more: Int = 0, total: Bool = false) -> FigureCardModel {
        FigureCardModel(
            kind: .table, headerRows: [["Year", "Cash"]],
            bodyRows: (0..<body).map { ["\(2020 + $0)", "\($0 * 100)"] },
            moreRows: more, hasTotalRow: total, columnAlignments: [.left, .right])
    }

    func test_anImageHasNoCardPlan() {
        XCTAssertNil(plan(.placeholder(.image)), "today's thumbnail draws an image")
    }

    func test_theCardHangsAGapBelowTheLineAtTheColumnsEdge() throws {
        let p = try XCTUnwrap(plan(table(rows: 2)))
        XCTAssertEqual(p.card.minX, 40)
        XCTAssertEqual(p.card.minY, 100 + FigureCardMetrics.verticalPadding)
        XCTAssertEqual(p.card.height, 3 * row, "one header and two body rows")
    }

    func test_theHeaderIsBoldAndRuledAndAlignmentsAreHonoured() throws {
        let p = try XCTUnwrap(plan(table(rows: 2)))
        XCTAssertEqual(p.cells.map(\.string), ["Year", "Cash", "2020", "0", "2021", "100"])
        XCTAssertEqual(p.cells.map(\.bold), [true, true, false, false, false, false])
        XCTAssertEqual(p.cells.map(\.alignment), [.left, .right, .left, .right, .left, .right])
        XCTAssertEqual(p.rules, [p.card.minY + row], "one rule, under the header")
        XCTAssertEqual(p.cells[2].rect.minY, p.card.minY + row)
        XCTAssertNil(p.more); XCTAssertNil(p.banner); XCTAssertNil(p.corner); XCTAssertNil(p.label)
    }

    /// Each column is as wide as its widest cell plus the insets; the card is
    /// no wider than its columns, and a short fall pads the last column.
    func test_columnsTakeTheirWidestCell() throws {
        let p = try XCTUnwrap(plan(table(rows: 2)))
        let inset = FigureCardDrawing.cellInset
        XCTAssertEqual(p.cells[0].rect.width, 40, "\"Year\" and \"2020\" are four characters")
        XCTAssertEqual(p.cells[1].rect.minX, 40 + 40 + 2 * inset + inset)
        XCTAssertEqual(p.card.width, (40 + 2 * inset) + (40 + 2 * inset))
    }

    func test_aCardWiderThanTheColumnShrinksToIt() throws {
        let p = try XCTUnwrap(plan(table(rows: 2), width: 50))
        XCTAssertEqual(p.card.width, 50)
        XCTAssertLessThanOrEqual(p.cells[1].rect.maxX, p.card.maxX)
    }

    /// A cut table draws "+ N more rows" BEFORE its kept total row (Task 1
    /// keeps the total as the last shown row), with a rule over the total.
    func test_aCutTableDrawsItsMoreLineBeforeTheRuledTotal() throws {
        let model = table(rows: 11, more: 28, total: true)
        let p = try XCTUnwrap(plan(model))
        let more = try XCTUnwrap(p.more)
        XCTAssertEqual(more.string, "+ 28 more rows")
        let top = p.card.minY
        XCTAssertEqual(more.rect.minY, top + 11 * row, "after the header and ten body rows")
        let totalCell = try XCTUnwrap(p.cells.last)
        XCTAssertEqual(totalCell.string, "1000", "the total is the last body row")
        XCTAssertEqual(totalCell.rect.minY, more.rect.maxY, "the total row comes after the more line")
        XCTAssertEqual(p.rules, [top + row, more.rect.maxY], "under the header, over the total")
        XCTAssertEqual(p.card.height, 13 * row, "twelve shown rows and the more line")
    }

    func test_oneMoreRowIsSingular() {
        XCTAssertEqual(FigureCardDrawing.moreText(1), "+ 1 more row")
        XCTAssertEqual(FigureCardDrawing.moreText(2), "+ 2 more rows")
    }

    func test_flags_aTintedCornerAndAnAmberBanner() throws {
        var model = table(rows: 1)
        model.readsResearch = true
        var p = try XCTUnwrap(plan(model))
        let corner = try XCTUnwrap(p.corner)
        XCTAssertEqual(corner.maxX, p.card.maxX); XCTAssertEqual(corner.minY, p.card.minY)
        XCTAssertNil(p.banner)

        model = table(rows: 1); model.fromResearchSource = true
        XCTAssertNotNil(try XCTUnwrap(plan(model)).corner, "made from a Research item")

        // A changed pin implies a pin, so the corner is drawn beside the banner.
        model = table(rows: 1, more: 3); model.readsResearch = true; model.pinChanged = true
        p = try XCTUnwrap(plan(model))
        let banner = try XCTUnwrap(p.banner)
        XCTAssertEqual(banner.string, "Research has changed")
        XCTAssertEqual(banner.rect.maxY, p.card.maxY, "the card's last line, its own room")
        XCTAssertEqual(banner.rect.width, p.card.width)
        XCTAssertEqual(p.card.height, 4 * row, "header, one row, the more line and the banner")
        for cell in p.cells { XCTAssertFalse(banner.rect.intersects(cell.rect), "covers no cell") }
        XCTAssertFalse(banner.rect.intersects(try XCTUnwrap(p.more).rect), "nor the more line")
        XCTAssertFalse(banner.rect.intersects(try XCTUnwrap(p.corner)), "nor the corner")
        XCTAssertGreaterThanOrEqual(p.card.width, 200, "the card holds its banner's words")
    }

    /// The card is painted inside the room the layout holds now: a card taller
    /// than that room (grown mid-burst) is clipped to it, and a trailing
    /// figure's room runs to the text view's bottom.
    func test_theHeldRoomBoundsThePainting() {
        let card = CGRect(x: 40, y: 106, width: 200, height: 260)
        let held = FigureCardDrawing.heldRoom(lineBottom: 100, fragmentBottom: 240,
                                              isTrailing: false, viewBottom: 900)
        XCTAssertEqual(held, 140)
        let clip = FigureCardDrawing.clip(for: card, lineBottom: 100, heldRoom: held)
        XCTAssertEqual(clip.maxY, 240, "clipped to the old room, not the card's 366")
        XCTAssertLessThan(clip.maxY, card.maxY)
        XCTAssertEqual(clip.minX, 39); XCTAssertEqual(clip.width, 202)
        XCTAssertEqual(FigureCardDrawing.heldRoom(lineBottom: 100, fragmentBottom: 120,
                                                  isTrailing: true, viewBottom: 500), 400,
                       "a trailing figure's room is the view's own height")
        XCTAssertEqual(FigureCardDrawing.heldRoom(lineBottom: 100, fragmentBottom: 90,
                                                  isTrailing: false, viewBottom: 500), 0)
    }

    func test_labelledCards() throws {
        for (kind, words) in [(FigureCardModel.Kind.removed, "Figure removed"),
                              (.ambiguous, "Two figures share this path"),
                              (.parked, "In Research")] {
            let p = try XCTUnwrap(plan(.placeholder(kind)))
            XCTAssertEqual(p.label?.string, words)
            XCTAssertEqual(p.card.height, FigureThumbnailLayout.placeholderHeight)
            XCTAssertTrue(p.cells.isEmpty)
            XCTAssertLessThanOrEqual(p.card.height + 2 * FigureCardMetrics.verticalPadding,
                                     FigureThumbnailLayout.reservedHeight, "it fits the placeholder room")
        }
    }

    /// **Drawn height == reserved height**: with the production metrics, the
    /// card plus its gap above and below is exactly the room its line holds.
    func test_theDrawnCardFillsExactlyTheRoomItsLineReserves() throws {
        let typography = TypographySettings.defaults
        let rowHeight = FigureCardMetrics.rowHeight(for: typography)
        for model in [table(rows: 0), table(rows: 3), table(rows: 11, more: 28, total: true),
                      FigureCardModel(kind: .table, bodyRows: [["a"]], moreRows: 4),
                      FigureCardModel(kind: .table, bodyRows: [["a"]], moreRows: 4,
                                      readsResearch: true, pinChanged: true),
                      FigureCardModel(kind: .table, bodyRows: [["a"]], pinChanged: true)] {
            let p = try XCTUnwrap(FigureCardDrawing.plan(
                for: model, lineBottom: 0, columnX: 0, columnWidth: 500, rowHeight: rowHeight,
                measure: measure))
            XCTAssertEqual(p.card.height + 2 * FigureCardMetrics.verticalPadding,
                           FigureCardMetrics.room(for: model, typography: typography), "\(model)")
        }
    }
}
