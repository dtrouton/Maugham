import XCTest
@testable import MaughamCore

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

    func test_parse_bodyLocalImage_notHarvested_bodyRoundTripsVerbatim() {
        let md = """
        # The Flat

        kind: location

        Body prose with an inline image ![alt](./x_assets/a.png) inline.

        ## Swatches

        ## Senses

        ## Images

        """
        let card = PaletteCardParser.parse(
            markdown: md, itemId: "res-body-1", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.body, "Body prose with an inline image ![alt](./x_assets/a.png) inline.")
        XCTAssertTrue(card.imagePaths.isEmpty)

        let rendered = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        let reparsed = PaletteCardParser.parse(
            markdown: rendered, itemId: "res-body-1", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(reparsed, card)
    }

    func test_parse_bodyRemoteImage_notHarvested_bodyRoundTripsVerbatim() {
        let md = """
        # The Flat

        kind: location

        Body prose with a remote image ![alt](https://example.com/y.png) inline.

        ## Swatches

        ## Senses

        ## Images

        """
        let card = PaletteCardParser.parse(
            markdown: md, itemId: "res-body-2", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.body, "Body prose with a remote image ![alt](https://example.com/y.png) inline.")
        XCTAssertTrue(card.imagePaths.isEmpty)

        let rendered = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        let reparsed = PaletteCardParser.parse(
            markdown: rendered, itemId: "res-body-2", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(reparsed, card)
    }

    func test_parse_imagesSectionInlineImage_stillHarvested() {
        let md = """
        # The Flat

        kind: location

        ## Swatches

        ## Senses

        ## Images

        Inline in images section ![alt](./b_assets/b.png).
        """
        let card = PaletteCardParser.parse(
            markdown: md, itemId: "res-img-1", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(card.imagePaths, ["research/palette/b_assets/b.png"])
    }

    // MARK: - Body byte preservation (A6)
    //
    // The renderer always wraps a non-empty body in exactly one structural
    // blank line before it and one after (separating it from `kind:` and the
    // first `##` section). That single pair is framing, not body content, and
    // is the one thing the parser strips. Anything else the writer typed —
    // indentation, trailing spaces, extra blank-line runs, or additional
    // leading/trailing blank lines beyond that structural pair — round-trips
    // byte-for-byte.

    func test_parse_render_bodyRoundTrip_preservesIndentAndBlankLineRun_byteForByte() {
        let body = "    Third-floor walk-up.\n\n\n\nThe light goes green before rain."
        let card = PaletteCard(
            researchItemId: "res-body-3", title: "The Flat", kind: .location,
            swatches: [], notes: [], imagePaths: [], body: body)
        let rendered = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        let reparsed = PaletteCardParser.parse(
            markdown: rendered, itemId: "res-body-3", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(reparsed.body, body)
    }

    func test_parse_render_bodyRoundTrip_preservesTrailingSpacesOnBodyLines_byteForByte() {
        let body = "Third-floor walk-up.   \n\nThe light goes green before rain.   "
        let card = PaletteCard(
            researchItemId: "res-body-4", title: "The Flat", kind: .location,
            swatches: [], notes: [], imagePaths: [], body: body)
        let rendered = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        let reparsed = PaletteCardParser.parse(
            markdown: rendered, itemId: "res-body-4", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(reparsed.body, body)
    }

    // Boundary rule: a body-content blank line beyond the single structural
    // leading separator is preserved (only the structural one is stripped).
    func test_parse_render_bodyRoundTrip_preservesLeadingBlankLineBeyondStructuralSeparator_byteForByte() {
        let body = "\nFirst real line."
        let card = PaletteCard(
            researchItemId: "res-body-5", title: "The Flat", kind: .location,
            swatches: [], notes: [], imagePaths: [], body: body)
        let rendered = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        let reparsed = PaletteCardParser.parse(
            markdown: rendered, itemId: "res-body-5", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(reparsed.body, body)
    }

    // Boundary rule: a body-content blank line beyond the single structural
    // trailing separator is preserved (only the structural one is stripped).
    func test_parse_render_bodyRoundTrip_preservesTrailingBlankLineBeyondStructuralSeparator_byteForByte() {
        let body = "Last real line.\n"
        let card = PaletteCard(
            researchItemId: "res-body-6", title: "The Flat", kind: .location,
            swatches: [], notes: [], imagePaths: [], body: body)
        let rendered = PaletteCardRenderer.render(card, cardDirectory: "research/palette")
        let reparsed = PaletteCardParser.parse(
            markdown: rendered, itemId: "res-body-6", fallbackTitle: "x",
            cardDirectory: "research/palette")
        XCTAssertEqual(reparsed.body, body)
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
