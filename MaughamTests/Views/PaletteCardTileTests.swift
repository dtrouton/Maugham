import XCTest
@testable import Maugham
import MaughamCore

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

    func test_headerMode_thumbnailWins() {
        // A thumbnail always fills the header, even when swatches exist.
        XCTAssertEqual(PaletteCardTile.headerMode(hasThumbnail: true, swatchCount: 0), .image)
        XCTAssertEqual(PaletteCardTile.headerMode(hasThumbnail: true, swatchCount: 3), .image)
    }

    func test_headerMode_swatchOnlyCardShowsBands() {
        // No thumbnail but at least one swatch -> paint the swatch bands.
        XCTAssertEqual(PaletteCardTile.headerMode(hasThumbnail: false, swatchCount: 1), .swatches)
        XCTAssertEqual(PaletteCardTile.headerMode(hasThumbnail: false, swatchCount: 8), .swatches)
    }

    func test_headerMode_placeholderOnlyWhenNeitherImageNorSwatch() {
        XCTAssertEqual(PaletteCardTile.headerMode(hasThumbnail: false, swatchCount: 0), .placeholder)
    }

    func test_kindSymbol_mapping() {
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .location), "mappin.and.ellipse")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .character), "person")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .motif), "sparkles")
        XCTAssertEqual(PaletteCardTile.kindSymbol(for: .other), "square.grid.2x2")
    }
}
