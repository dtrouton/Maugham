import XCTest
import MaughamCore

/// PHASE 15 — scoring the extension.
///
/// The implementer warned (its TRAP 7) that a round-trip property over cards
/// built from `TextureNote(...)!` is vacuous: the failable init already refused
/// everything that could have failed it. So these are the tests it said would
/// actually carry weight — the negative cases, and the two UNIVERSAL properties
/// that check `init?` is not merely *a* filter but the *right* one.
final class TextureExtensionTests: XCTestCase {

    private let dir = "research/palette"

    private func card(_ textures: [PaletteCard.TextureNote],
                      body: String = "") -> PaletteCard {
        PaletteCard(researchItemId: "res-1", title: "The Flat", kind: .location,
                    swatches: [], notes: [], imagePaths: [], textures: textures, body: body)
    }
    private func roundTrip(_ c: PaletteCard) -> PaletteCard {
        PaletteCardParser.parse(markdown: PaletteCardRenderer.render(c, cardDirectory: dir),
                                itemId: c.researchItemId, fallbackTitle: "FB", cardDirectory: dir)
    }

    // MARK: - THE TRAP: does the design actually close it?

    func test_theDesignedTrap_anUntaggedNoteContainingAColonIsRefused() {
        // The trap this feature is made of. An ordinary implementation splits on
        // the first colon with no vocabulary check (the tag set is open), which
        // silently reclassifies the writer's sentence as a material tag.
        XCTAssertNil(PaletteCard.TextureNote(
            material: nil, text: "everything here is gritty: even the light"),
            "an untagged note that would read back as tagged must be refused (RULING-1)")
    }

    func test_theDesignedTrap_isNotClosedByAccidentButByAStatedReason() {
        let p = PaletteCard.TextureNote.problem(
            material: nil, text: "everything here is gritty: even the light")
        XCTAssertNotNil(p, "the refusal must carry a reason the entry point can show")
    }

    // MARK: - THE UNIVERSAL PROPERTY (the implementer's own suggested test)
    //
    // `init?` non-nil  ==>  the whole-card round trip holds.
    // If this shatters, the validator is the WRONG filter, not merely a filter.

    func test_universalProperty_everyAcceptedTextureNoteRoundTrips() {
        var rng = SeededRNG(seed: 0x7E7C0DE)
        let materials: [String?] = [nil, "slate", "horsehair plaster", "brick", "",
                                    " leading", "trailing ", "a: b", "Slate", "n\nl"]
        let texts = ["cold underfoot", "", "   ", "a: b", "gritty: even the light",
                     "line\nbreak", "trailing   ", "  leading", "- dashy",
                     "## Textures", "kind: location", "smell: turpentine",
                     "#8A6F4D", "![alt](x.png)", "a\r\nb", ":", ": x", "x:"]
        var accepted = 0, refused = 0

        for _ in 0..<20_000 {
            let m = rng.pick(materials)
            let t = rng.pick(texts)
            guard let note = PaletteCard.TextureNote(material: m, text: t) else {
                refused += 1; continue
            }
            accepted += 1
            let c = card([note])
            let out = roundTrip(c)
            XCTAssertEqual(out, c,
                """
                UNIVERSAL PROPERTY SHATTERED — init? accepted a note that does not \
                round-trip. material=\(String(describing: m)) text=\(t.debugDescription)
                """)
            if out != c { return }
        }
        print("PROP | TX-universal | accepted=\(accepted) refused=\(refused) | held=true")
        XCTAssertGreaterThan(accepted, 0, "the property must not be vacuous")
        XCTAssertGreaterThan(refused, 0, "the validator must actually refuse things")
    }

    // MARK: - THE CONVERSE CENSUS
    //
    // Every TextureNote the PARSER produces from arbitrary markdown must itself
    // be constructible. If the parser can produce a note `init?` would refuse,
    // then reading a file yields a model that cannot be rebuilt — and RULING-2's
    // tolerance has quietly become a hole in RULING-1's guarantee.

    func test_converseCensus_everyParsedTextureNoteIsItselfConstructible() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        let lines = ["- slate: cold underfoot", "- gritty", "- a: b: c", "-", "- ",
                     "-   spaced   ", "- : leading colon", "- x:", "- #8A6F4D",
                     "- ## Textures", "- kind: location", "  - indented",
                     "not a dash line", "", "   "]
        for _ in 0..<5_000 {
            let n = rng.int(1...5)
            let body = (0..<n).map { _ in rng.pick(lines) }.joined(separator: "\n")
            let md = "# T\n\nkind: location\n\n## Textures\n\n\(body)\n"
            let parsed = PaletteCardParser.parse(markdown: md, itemId: "i",
                                                 fallbackTitle: "F", cardDirectory: dir)
            for note in parsed.textures {
                XCTAssertNotNil(
                    PaletteCard.TextureNote(material: note.material, text: note.text),
                    """
                    CONVERSE CENSUS SHATTERED — the parser produced a note that \
                    init? refuses: material=\(String(describing: note.material)) \
                    text=\(note.text.debugDescription). Reading a file yields a model \
                    that cannot be rebuilt.
                    """)
            }
        }
    }

    // MARK: - Regression: the extension must not have broken what it could not see

    func test_existingSectionsStillRoundTripAlongsideTextures() {
        let c = PaletteCard(
            researchItemId: "res-1", title: "The Flat", kind: .location,
            swatches: ["#8A6F4D"],
            notes: [.init(sense: .smell, text: "turpentine"),
                    .init(sense: nil, text: "cold quarry tile")],
            imagePaths: ["research/palette/x_assets/a.png"],
            textures: [PaletteCard.TextureNote(material: "slate", text: "cold underfoot")!,
                       PaletteCard.TextureNote(material: nil, text: "gritty")!],
            body: "Third-floor walk-up.\n\nThe light goes green before rain.")
        XCTAssertEqual(roundTrip(c), c)
    }

    func test_texturesSectionAppearsInTheRenderedCard() {
        let md = PaletteCardRenderer.render(
            card([PaletteCard.TextureNote(material: "slate", text: "cold underfoot")!]),
            cardDirectory: dir)
        XCTAssertTrue(md.contains("## Textures"), "the section must be emitted")
        XCTAssertTrue(md.contains("- slate: cold underfoot"))
    }

    /// The implementer's TRAP 2: adding a KNOWN heading retroactively eats bodies
    /// that used to round-trip. Pinned so the migration cost is visible.
    func test_TRAP2_aBodyContainingTexturesHeadingNoLongerRoundTrips() {
        let c = card([], body: "A first thought.\n\n## Textures\n\nprose under it.")
        let out = roundTrip(c)
        XCTAssertNotEqual(out, c,
            "before this change that body round-tripped (M1-T-037: unknown heading in body)")
        XCTAssertEqual(out.body, "A first thought.",
                       "the body is truncated at the now-known heading; the prose under it is gone")
    }
}
