import XCTest
import MaughamCore
@testable import Maugham

/// **The book's figure index** (report plan 8a Task 2): every registered
/// figure numbered by its first line in publishing order, unlabelled lines
/// counting, a figure with no line "—", a line naming no record unlisted, and
/// the cross-references to each figure collected.
final class FigureListingTests: XCTestCase {

    private static func record(_ id: String, _ name: String, kind: FigureKind = .table) -> FigureRecord {
        FigureRecord(id: id, name: name, kind: kind, piece: nil,
                     path: kind == .table ? "figures/\(name).csv" : "figures/\(name).png")
    }

    private static let cash = record("fig-0a0a0a0a", "cash")
    private static let debt = record("fig-1b1b1b1b", "debt")
    private static let chart = record("fig-2c2c2c2c", "chart", kind: .image)
    private static let spare = record("fig-3d3d3d3d", "spare")
    private static let aside = record("fig-4e4e4e4e", "aside")

    /// Pieces `(docId, text)` in publishing order, each at `manuscript/<docId>.md`.
    private func listing(_ pieces: [(String, String)], records: [FigureRecord],
                         words: ElementWords = .english) -> [FigureListing.Row] {
        let index = ReferenceIndex.build(
            pieces: pieces.map { (docId: $0.0, summary: ReferenceIndex.PieceSummary(text: $0.1)) },
            research: [], words: words)
        return FigureListing.build(index: index, records: records,
                                   documentPathOf: { "manuscript/\($0).md" })
    }

    private func use(_ docId: String, _ line: Int) -> FigureListing.Use {
        FigureListing.Use(docId: docId, lineIndex: line)
    }

    func test_numbersCountAcrossTwoPiecesByKind() {
        let rows = listing([
            ("a", "Opening.\n\n![Cash](../figures/cash.csv){#tbl:cash}\n\n![Chart](../figures/chart.png){#fig:chart}"),
            ("b", "![Debt](../figures/debt.csv){#tbl:debt}"),
        ], records: [Self.debt, Self.chart, Self.cash])
        XCTAssertEqual(rows.map(\.figureId), [Self.cash.id, Self.chart.id, Self.debt.id],
                       "reading order of the pieces, not the registry's")
        XCTAssertEqual(rows.map(\.number), ["Table 1", "Figure 1", "Table 2"])
        XCTAssertEqual(rows.map(\.caption), ["Cash", "Chart", "Debt"])
        XCTAssertEqual(rows.map(\.pieceOfLine), ["a", "a", "b"])
        XCTAssertEqual(rows.map(\.usedIn), [[use("a", 2)], [use("a", 4)], [use("b", 0)]])
        XCTAssertEqual(rows.map(\.kind), [.table, .image, .table])
        XCTAssertEqual(rows.map(\.name), ["cash", "chart", "debt"])
    }

    /// The book's own words, as the caption bar and the PDF say them.
    func test_theNumberIsInTheBooksWords() {
        let rows = listing([("a", "![Cash](../figures/cash.csv)\n\n![Chart](../figures/chart.png)")],
                           records: [Self.cash, Self.chart],
                           words: ElementWords.builtIn(language: "sr"))
        XCTAssertEqual(rows.map(\.number), ["Tabela 1", "Slika 1"])
    }

    /// An unlabelled figure line numbers, and so does a pipe table, which
    /// is no figure: the numbers are publishing's plain counting.
    func test_anUnlabelledLineAndAPipeTableNumberToo() {
        let rows = listing([
            ("a", "| x |\n|---|\n| 1 |\n\n![](../figures/cash.csv)\n\n![Debt](../figures/debt.csv){#tbl:debt}"),
        ], records: [Self.cash, Self.debt])
        XCTAssertEqual(rows.map(\.number), ["Table 2", "Table 3"])
        XCTAssertEqual(rows.first?.caption, "", "an unlabelled, uncaptioned line")
        XCTAssertEqual(rows.map(\.usedIn), [[use("a", 4)], [use("a", 6)]])
    }

    func test_aFigureWithNoLineIsListedLastWithADash() {
        let rows = listing([("a", "![Cash](../figures/cash.csv){#tbl:cash}")],
                           records: [Self.spare, Self.cash])
        XCTAssertEqual(rows.map(\.figureId), [Self.cash.id, Self.spare.id])
        let unused = try? XCTUnwrap(rows.last)
        XCTAssertEqual(unused?.number, "—")
        XCTAssertEqual(unused?.number, FigureListing.unusedNumber)
        XCTAssertEqual(unused?.usedIn, [])
        XCTAssertEqual(unused?.referencedFrom, [])
        XCTAssertNil(unused?.pieceOfLine)
        XCTAssertEqual(unused?.caption, "")
        XCTAssertEqual(unused?.isUnused, true)
    }

    /// A line whose path names no record is not listed, but it is still a
    /// table the book prints, so the next one is Table 2.
    func test_aLineWhosePathNamesNoRecordIsNotListed() {
        let rows = listing([
            ("a", "![Gone](../figures/gone.csv){#tbl:gone}\n\n![Cash](../figures/cash.csv){#tbl:cash}\n\n![Pic](../research/p.png)"),
        ], records: [Self.cash])
        XCTAssertEqual(rows.map(\.figureId), [Self.cash.id])
        XCTAssertEqual(rows.map(\.number), ["Table 2"])
    }

    /// A piece whose path the window cannot answer lists nothing from it.
    func test_aPieceWithNoPathListsNothing() {
        let index = ReferenceIndex.build(
            pieces: [(docId: "a", summary: ReferenceIndex.PieceSummary(text: "![C](../figures/cash.csv)"))],
            research: [], words: .english)
        let rows = FigureListing.build(index: index, records: [Self.cash], documentPathOf: { _ in nil })
        XCTAssertEqual(rows.map(\.number), ["—"])
    }

    /// Two records on one path are ambiguous (the store refuses to render
    /// them): the line names neither.
    func test_aLineNamingTwoRecordsNamesNeither() {
        let twin = FigureRecord(id: "fig-5f5f5f5f", name: "cash2", kind: .table, piece: nil,
                                path: "figures/cash.csv")
        let rows = listing([("a", "![Cash](../figures/cash.csv)")], records: [Self.cash, twin])
        XCTAssertEqual(rows.map(\.number), ["—", "—"])
    }

    func test_twoLinesNamingOneFigureAreOneRowWithTwoUses() {
        let rows = listing([
            ("a", "![First](../figures/cash.csv){#tbl:cash}"),
            ("b", "Prose.\n\n![Again](../figures/cash.csv)\n\n![Debt](../figures/debt.csv)"),
        ], records: [Self.cash, Self.debt])
        XCTAssertEqual(rows.map(\.figureId), [Self.cash.id, Self.debt.id])
        XCTAssertEqual(rows.first?.usedIn, [use("a", 0), use("b", 2)])
        XCTAssertEqual(rows.first?.number, "Table 1", "the first line's number")
        XCTAssertEqual(rows.first?.caption, "First", "the first line's caption")
        XCTAssertEqual(rows.first?.pieceOfLine, "a")
        XCTAssertEqual(rows.last?.number, "Table 3", "the second use still counts as a table")
    }

    /// Every cross-reference to a label the figure's lines registered, in
    /// reading order; one inside fenced code, to another label, or to a label
    /// that never registered (wrong kind) is not collected.
    func test_crossReferencesAreCollected() {
        let rows = listing([
            ("a", "See @tbl:cash.\n\n![Cash](../figures/cash.csv){#tbl:cash}\n\n![Chart](../figures/chart.png){#tbl:chart}"),
            ("b", "Prose.\nAgain [@tbl:cash] and @tbl:chart.\n\n```\n@tbl:cash\n```\n\nLast @tbl:cash."),
        ], records: [Self.cash, Self.chart])
        let cash = rows.first { $0.figureId == Self.cash.id }
        XCTAssertEqual(cash?.referencedFrom, [use("a", 0), use("b", 1), use("b", 7)])
        let chart = rows.first { $0.figureId == Self.chart.id }
        XCTAssertEqual(chart?.referencedFrom, [],
                       "a picture labelled tbl: is a figure; its label does not register")
    }

    func test_crossReferencesAreReadIntoThePieceSummary() {
        let summary = ReferenceIndex.PieceSummary(text: "A @fig:one.\n\nB [@tbl:two; @fig:one].\n")
        XCTAssertEqual(summary.referencedLabels.map(\.label.reference), ["fig:one", "tbl:two", "fig:one"])
        XCTAssertEqual(summary.referencedLabels.map(\.line), [0, 2, 2])
    }

    /// Used figures in reading order of their FIRST line; then the unused by
    /// name, ignoring case, numbers compared as numbers.
    func test_ordering() {
        let a10 = Self.record("fig-6a6a6a6a", "Appendix 10"), a9 = Self.record("fig-7a7a7a7a", "appendix 9")
        let rows = listing([
            ("b", "![Debt](../figures/debt.csv)"),
            ("a", "![Cash](../figures/cash.csv)\n\n![Debt](../figures/debt.csv)"),
        ], records: [Self.cash, Self.spare, a10, Self.debt, Self.aside, a9])
        XCTAssertEqual(rows.map(\.name), ["debt", "cash", "appendix 9", "Appendix 10", "aside", "spare"])
        XCTAssertEqual(rows.map(\.number), ["Table 1", "Table 2", "—", "—", "—", "—"])
    }

    /// Lines moving with nothing else changing is a new listing but not a new
    /// editor-facing index: `hasSameLines` sees it, `hasSameContents` does not.
    func test_aMovedLineChangesTheLinesOnly() {
        func index(_ text: String) -> ReferenceIndex {
            ReferenceIndex.build(pieces: [(docId: "a", summary: ReferenceIndex.PieceSummary(text: text))],
                                 research: [], words: .english)
        }
        let before = index("![Cash](../figures/cash.csv){#tbl:cash}")
        let after = index("Prose above.\n\n![Cash](../figures/cash.csv){#tbl:cash}")
        XCTAssertTrue(after.hasSameContents(as: before))
        XCTAssertFalse(after.hasSameLines(as: before))
    }
}
