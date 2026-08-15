import XCTest
import MaughamCore
@testable import Maugham

/// **The Review board's row derivation** (M3 P1 Task 7) — `ReviewBoardRows`
/// is pure, so its whole truth table is exercised here with no store, no
/// window and no project on disk. That is the point of the shape: every
/// question about WHICH rows the board draws is answered without mounting
/// anything, and `ReviewBoardPaneTests` is left to be about how they are drawn.
///
/// The walk is new (no existing view keeps groups as rows), so these cases are
/// exhaustive over the shapes a manifest can actually hold: flat, nested,
/// deeply nested, an empty group, a group holding only Collection references,
/// and the empty project.
final class ReviewBoardRowsTests: XCTestCase {

    // MARK: - Fixtures

    private func doc(_ id: String, _ title: String? = nil,
                     kind: PieceKind? = nil,
                     children: [StructureItem]? = nil) -> StructureItem {
        StructureItem(id: id, title: title ?? id, type: .document,
                      path: "\(id).md", pieceKind: kind, children: children)
    }

    private func group(_ id: String, _ children: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: id, type: .group, children: children)
    }

    private func kinds(_ rows: [ReviewBoardRows.Row]) -> [ReviewBoardRows.Row.Kind] {
        rows.map(\.kind)
    }

    // MARK: - The empty project

    /// No structure, no rows — the case the pane answers with its
    /// `ContentUnavailableView`. The derivation does not invent a placeholder
    /// row for it; "there is nothing to review" is the PANE's sentence to write.
    func test_anEmptyStructureDerivesNoRows() {
        XCTAssertTrue(ReviewBoardRows.derive(structure: []).isEmpty)
    }

    // MARK: - Order

    /// **Tree order, parent before children.** A reviewer reads the board the
    /// way they read the binder; a walk that emitted groups first, or sorted by
    /// title, would put the chips in an order the writer never arranged.
    func test_rowsArePreOrderAndKeepTheTreesOwnOrder() {
        let structure = [
            doc("front"),
            group("PartOne", [doc("ch1"), doc("ch2")]),
            group("PartTwo", [doc("ch3")]),
            doc("back"),
        ]

        XCTAssertEqual(ReviewBoardRows.derive(structure: structure).map(\.id),
                       ["front", "PartOne", "ch1", "ch2", "PartTwo", "ch3", "back"])
    }

    /// The row carries the ITEM, not a copy of the two or three fields the
    /// board happens to draw today — the chips read `passStates` off it, and
    /// Task 8's navigation reads its id.
    func test_eachRowCarriesTheItemItself() {
        let chapter = doc("ch1", "Chapter One")
        let rows = ReviewBoardRows.derive(structure: [chapter])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item, chapter)
        XCTAssertEqual(rows.first?.id, "ch1", "identity is the item's own id")
    }

    // MARK: - Depth

    /// Root groups are depth 0 and each level of nesting adds one.
    func test_groupDepthCountsTheNesting() {
        let structure = [
            group("PartOne", [
                doc("ch1"),
                group("Act", [
                    doc("ch2"),
                    group("Scene", [doc("ch3")]),
                ]),
            ]),
        ]
        let rows = ReviewBoardRows.derive(structure: structure)

        XCTAssertEqual(kinds(rows), [
            .group(depth: 0), .piece,
            .group(depth: 1), .piece,
            .group(depth: 2), .piece,
        ])
    }

    /// **Depth is a fact about GROUPS, and pieces share one left edge.** The
    /// board's chip columns line up down the whole pane, so a chapter three
    /// groups deep is drawn at the same left edge as a chapter at the root —
    /// otherwise its Structural chip would sit under the next pass's column.
    /// The header row above it is what says where it is in the tree.
    ///
    /// This is the assertion that fails the moment someone "fixes" the
    /// derivation by giving `.piece` a depth and indenting it.
    func test_pieceRowsCarryNoDepthHoweverDeepTheyAreFiled() {
        let deep = [group("A", [group("B", [group("C", [doc("ch")])])])]
        let flat = [doc("ch")]

        let deepPiece = ReviewBoardRows.derive(structure: deep).last
        let flatPiece = ReviewBoardRows.derive(structure: flat).last

        XCTAssertEqual(deepPiece?.kind, .piece)
        XCTAssertEqual(deepPiece?.kind, flatPiece?.kind,
                       "a nested piece and a root piece are the same kind of "
                       + "row, or the chip columns stop lining up")
    }

    // MARK: - Groups the writer has made but not filled

    /// An empty group still gets its header. A part created and not yet
    /// written into is a fact about the manuscript — dropping it would make the
    /// board disagree with the binder about what the project contains.
    func test_anEmptyGroupStillEmitsItsHeader() {
        let rows = ReviewBoardRows.derive(structure: [group("PartOne", [])])

        XCTAssertEqual(kinds(rows), [.group(depth: 0)])
        XCTAssertEqual(rows.first?.item.title, "PartOne")
    }

    /// …and a group with no children ARRAY at all (nil, not empty) is the same
    /// row. The manifest can spell an empty group either way.
    func test_aGroupWithNoChildrenArrayAtAllStillEmitsItsHeader() {
        let nilChildren = StructureItem(id: "PartOne", title: "Part One", type: .group)

        XCTAssertEqual(kinds(ReviewBoardRows.derive(structure: [nilChildren])),
                       [.group(depth: 0)])
    }

    // MARK: - Collection references

    /// A `.reference` piece is another project on disk; its passes are
    /// adjudicated in ITS window, so the board draws it thin and chip-less and
    /// the row kind says so.
    func test_aReferencePieceIsItsOwnKindOfRow() {
        let rows = ReviewBoardRows.derive(structure: [
            doc("loose", kind: .loose),
            doc("ref", kind: .reference),
            doc("plain"),
        ])

        XCTAssertEqual(kinds(rows), [.piece, .reference, .piece],
                       "`.loose` and an absent `pieceKind` are both ordinary "
                       + "pieces; only `.reference` is the thin row")
    }

    /// **A group holding only references** — the brief's named case, and the
    /// one a Collection actually produces. The header is still a header; every
    /// child is still chip-less.
    func test_aGroupHoldingOnlyReferencesKeepsItsHeaderAndNoChips() {
        let rows = ReviewBoardRows.derive(structure: [
            group("Anthology", [doc("a", kind: .reference), doc("b", kind: .reference)]),
        ])

        XCTAssertEqual(kinds(rows), [.group(depth: 0), .reference, .reference])
    }

    /// A group's TYPE decides the row, not its `pieceKind`. A group is never a
    /// reference row even if a stray `pieceKind` rides along on it — the board
    /// would otherwise lose a header and put its children under the one above.
    func test_aGroupIsAGroupEvenCarryingAStrayPieceKind() {
        let odd = StructureItem(id: "g", title: "g", type: .group,
                                pieceKind: .reference, children: [doc("ch")])

        XCTAssertEqual(kinds(ReviewBoardRows.derive(structure: [odd])),
                       [.group(depth: 0), .piece])
    }

    // MARK: - Nothing is dropped

    /// A document carrying children is malformed — but representable, and the
    /// walk must not silently lose the pieces filed under it. They are walked
    /// at the same depth, because depth is about group nesting.
    func test_childrenOfADocumentAreStillWalked() {
        let rows = ReviewBoardRows.derive(structure: [
            doc("parent", children: [doc("hidden")]),
        ])

        XCTAssertEqual(rows.map(\.id), ["parent", "hidden"],
                       "a piece filed under a document must not vanish from "
                       + "the board")
        XCTAssertEqual(kinds(rows), [.piece, .piece])
    }

    /// Every node in the tree gets exactly one row — the property behind all of
    /// the above, asserted over a shape that mixes all four cases.
    func test_everyNodeGetsExactlyOneRow() {
        let structure = [
            doc("front"),
            group("PartOne", [
                doc("ch1"),
                group("Empty", []),
                doc("ref", kind: .reference),
            ]),
        ]
        let rows = ReviewBoardRows.derive(structure: structure)

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count,
                       "…and no row is emitted twice")
    }
}
