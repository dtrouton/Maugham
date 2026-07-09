import XCTest
@testable import Maugham

final class PaletteCardTileTests: XCTestCase {
    func test_snippet_prefersTaggedNotes_andCapsAtLimit() {
        let notes: [PaletteCard.SensoryNote] = [
            .init(sense: nil, text: "untagged line"),
            .init(sense: .smell, text: "turpentine"),
            .init(sense: .sound, text: "tram-rattle"),
        ]
        XCTAssertEqual(
            PaletteCardTile.snippet(for: notes, limit: 2),
            "smell: turpentine\nsound: tram-rattle")
    }

    func test_snippet_fallsBackToUntagged_andEmpty() {
        XCTAssertEqual(
            PaletteCardTile.snippet(for: [.init(sense: nil, text: "just a line")], limit: 2),
            "just a line")
        XCTAssertEqual(PaletteCardTile.snippet(for: [], limit: 2), "")
    }

    func test_kindSymbol_mapping() {
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .location), "mappin.and.ellipse")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .character), "person")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .motif), "sparkles")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .other), "square.grid.2x2")
    }
}
