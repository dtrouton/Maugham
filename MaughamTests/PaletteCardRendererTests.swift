import XCTest
@testable import Maugham

final class PaletteCardRendererTests: XCTestCase {
    private func roundTrip(_ card: PaletteCard, dir: String = "research/palette") -> PaletteCard {
        let md = PaletteCardRenderer.render(card, cardDirectory: dir)
        return PaletteCardParser.parse(
            markdown: md, itemId: card.researchItemId,
            fallbackTitle: "fallback", cardDirectory: dir)
    }

    func test_roundTrip_fullCard() {
        let card = PaletteCard(
            researchItemId: "res-1", title: "The Flat", kind: .location,
            swatches: ["#8A6F4D", "#2F3B4C"],
            notes: [.init(sense: .smell, text: "turpentine"),
                    .init(sense: nil, text: "cold quarry tile")],
            imagePaths: ["research/palette/the-flat_assets/image-1.png",
                         "research/paris.jpg"],
            body: "Third-floor walk-up.\n\nThe light goes green before rain.")
        XCTAssertEqual(roundTrip(card), card)
    }

    func test_roundTrip_emptyEverything() {
        let card = PaletteCard(researchItemId: "res-2", title: "Bare", kind: .other,
                               swatches: [], notes: [], imagePaths: [], body: "")
        XCTAssertEqual(roundTrip(card), card)
    }

    func test_render_imagePathsAreCardRelativeWithDotSlash() {
        let card = PaletteCard(researchItemId: "res-3", title: "X", kind: .motif,
                               swatches: [], notes: [],
                               imagePaths: ["research/palette/x_assets/a.png"], body: "")
        let md = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        XCTAssertTrue(md.contains("- ./x_assets/a.png"))
        XCTAssertFalse(md.contains("research/palette/x_assets"))
    }

    func test_render_normalizesSwatchCase() {
        let card = PaletteCard(researchItemId: "res-4", title: "X", kind: .other,
                               swatches: ["#8a6f4d"], notes: [], imagePaths: [], body: "")
        XCTAssertTrue(PaletteCardRenderer.render(card, cardDirectory: "research/palette")
            .contains("- #8A6F4D"))
    }

    func test_relativize() {
        XCTAssertEqual(PaletteCardRenderer.relativize(
            "research/palette/x_assets/a.png", from: "research/palette"), "./x_assets/a.png")
        XCTAssertEqual(PaletteCardRenderer.relativize(
            "research/paris.jpg", from: "research/palette"), "../paris.jpg")
    }
}
