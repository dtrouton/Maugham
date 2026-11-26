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

    /// The format a loose piece is shown as is `DocumentFormat.ofManuscript` of
    /// its path (prose for a path-less piece) — the row's icon above, and the
    /// caption at the head of its Brief (`BriefPane.formatCaption`, which took
    /// the old piece inspector's format label).
    func test_pieceFormat_byPath() {
        XCTAssertEqual(DocumentFormat.ofManuscript(path: "pieces/a.fountain"), .fountain)
        XCTAssertEqual(DocumentFormat.ofManuscript(path: "pieces/a.md"), .markdown)
        XCTAssertEqual(DocumentFormat.ofManuscript(path: nil), .markdown)
        let structure = [piece(path: "pieces/a.fountain")]
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: structure,
                                               projectType: .collection),
                       DocumentFormat.fountain.kindLabel)
    }

    func test_pieceFormat_upperCaseFountainShowsAsScreenplay() {
        XCTAssertEqual(DocumentFormat.ofManuscript(path: "pieces/A.FOUNTAIN"), .fountain)
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: [piece(path: "pieces/A.FOUNTAIN")],
                                               projectType: .collection),
                       DocumentFormat.fountain.kindLabel)
    }
}
