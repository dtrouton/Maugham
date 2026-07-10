import XCTest
@testable import Maugham

final class PaletteCardParserTests: XCTestCase {

    private let fullCard = """
    # The Flat

    kind: location

    ## Swatches

    - #8A6F4D
    - #2F3B4C
    - not-a-swatch

    ## Senses

    - smell: turpentine and cold ash
    - SOUND: tram-rattle through the shutters
    - cold quarry tile underfoot

    ## Images

    - ../paris-flat.jpg

    Some prose with an inline image ![view](window.jpg).
    """

    func test_parse_fullCard() {
        let card = PaletteCardParser.parse(
            markdown: fullCard, itemId: "res-1", fallbackTitle: "fallback",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.researchItemId, "res-1")
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, .location)
        XCTAssertEqual(card.swatches, ["#8A6F4D", "#2F3B4C"])
        XCTAssertEqual(card.notes.count, 3)
        XCTAssertEqual(card.notes[0], .init(sense: .smell, text: "turpentine and cold ash"))
        XCTAssertEqual(card.notes[1], .init(sense: .sound, text: "tram-rattle through the shutters"))
        XCTAssertEqual(card.notes[2], .init(sense: nil, text: "cold quarry tile underfoot"))
        XCTAssertEqual(card.imagePaths, ["research/paris-flat.jpg", "research/palette/window.jpg"])
    }

    func test_parse_missingKindAndTitle_usesFallbacks() {
        let card = PaletteCardParser.parse(
            markdown: "just prose", itemId: "res-2", fallbackTitle: "Untitled Card",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.title, "Untitled Card")
        XCTAssertEqual(card.kind, .other)
        XCTAssertTrue(card.swatches.isEmpty)
        XCTAssertTrue(card.notes.isEmpty)
        XCTAssertTrue(card.imagePaths.isEmpty)
    }

    func test_parse_unknownKind_isOther() {
        let card = PaletteCardParser.parse(
            markdown: "# X\n\nkind: banana\n", itemId: "res-3", fallbackTitle: "X",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.kind, .other)
    }

    func test_template_parsesBackToItsOwnFields() {
        let md = PaletteCardParser.template(title: "Harbor at Dawn", kind: .location)
        let card = PaletteCardParser.parse(
            markdown: md, itemId: "res-4", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.title, "Harbor at Dawn")
        XCTAssertEqual(card.kind, .location)
    }

    func test_parse_capturesFreeformBodyBeforeSections() {
        let md = """
        # The Flat

        kind: location

        Third-floor walk-up.

        The light goes green before rain.

        ## Swatches

        - #8A6F4D
        """
        let card = PaletteCardParser.parse(
            markdown: md, itemId: "res-b", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.body, "Third-floor walk-up.\n\nThe light goes green before rain.")
        XCTAssertEqual(card.swatches, ["#8A6F4D"])
    }

    func test_parse_noBody_isEmptyString() {
        let md = PaletteCardParser.template(title: "T", kind: .other)
        XCTAssertEqual(PaletteCardParser.parse(
            markdown: md, itemId: "res-c", fallbackTitle: "x",
            cardDirectory: "research/palette").body, "")
    }

    func test_hexColor_parsing() {
        XCTAssertNotNil(PaletteCard.color(fromHex: "#8A6F4D"))
        XCTAssertNotNil(PaletteCard.color(fromHex: "#fff"))
        XCTAssertNil(PaletteCard.color(fromHex: "8A6F4D"))
        XCTAssertNil(PaletteCard.color(fromHex: "#GGGGGG"))
        let rgb = PaletteCard.color(fromHex: "#FF0000")
        XCTAssertEqual(rgb?.r ?? 0, 1.0, accuracy: 0.001)
    }
}
