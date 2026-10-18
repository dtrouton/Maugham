import XCTest
import MaughamCore
@testable import Maugham

/// A Collection's loose piece is shown and inspected by its format
/// (`DocumentFormat.ofManuscript(path:)`). Exception 1 of plan 7: the
/// extension is compared case-insensitively, so a hand-imported `.FOUNTAIN`
/// shows as Fountain, as the op log already parses it.
final class PieceFormatDisplayTests: XCTestCase {

    private func piece(path: String?, kind: PieceKind? = .loose) -> StructureItem {
        StructureItem(id: "p1", title: "Piece", type: .document, path: path, pieceKind: kind)
    }

    func test_pieceRowIcon_byFormat() {
        XCTAssertEqual(PieceRow.iconName(for: piece(path: "pieces/a.fountain")), "film")
        XCTAssertEqual(PieceRow.iconName(for: piece(path: "pieces/a.md")), "doc.text")
        XCTAssertEqual(PieceRow.iconName(for: piece(path: nil)), "doc.text")
        XCTAssertEqual(PieceRow.iconName(for: piece(path: "pieces/a.md", kind: nil)), "doc.text")
        XCTAssertEqual(PieceRow.iconName(for: piece(path: "pieces/a.fountain", kind: .reference)), "link")
    }

    func test_pieceRowIcon_upperCaseFountainShowsFilm() {
        XCTAssertEqual(PieceRow.iconName(for: piece(path: "pieces/A.FOUNTAIN")), "film")
    }

    func test_pieceInspectorFormat_byPath() {
        XCTAssertEqual(RightColumn.pieceInspectorFormat(path: "pieces/a.fountain"), .fountain)
        XCTAssertEqual(RightColumn.pieceInspectorFormat(path: "pieces/a.md"), .markdown)
        XCTAssertEqual(RightColumn.pieceInspectorFormat(path: nil), .markdown)
    }

    func test_pieceInspectorFormat_upperCaseFountainInspectsAsScreenplay() {
        XCTAssertEqual(RightColumn.pieceInspectorFormat(path: "pieces/A.FOUNTAIN"), .fountain)
    }
}
