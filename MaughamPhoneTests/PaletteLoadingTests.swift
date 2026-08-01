import XCTest
@testable import MaughamPhone
import MaughamCore

/// Unit tests for the pure core of the Read-tab Palette section (Task 6):
/// which research items are palette cards, which leaves to hide from the
/// ordinary Research section, and how sensory notes group for display.
final class PaletteLoadingTests: XCTestCase {

    // MARK: - Builders

    private func card(_ id: String, _ title: String, path: String) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .document, path: path)
    }
    private func image(_ id: String, _ title: String, path: String) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .image, path: path)
    }
    private func group(
        _ id: String, _ title: String, path: String?, role: ResearchRole?,
        _ kids: [ResearchItem]
    ) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .group, path: path, children: kids, role: role)
    }

    // MARK: - paletteCards

    func test_paletteCards_returnsGroupDocumentsInManifestOrder_filteringNonDocuments() {
        let research = [
            group("pg", "Palette", path: "research/palette", role: .paletteGroup, [
                card("c1", "The Flat", path: "research/palette/the-flat.md"),
                image("im", "loose image", path: "research/palette/x.png"),
                card("c2", "The Square", path: "research/palette/the-square.md"),
            ]),
            card("wb", "World Bible", path: "research/world-bible.md"),
        ]
        let cards = PaletteLoading.paletteCards(in: research)
        XCTAssertEqual(cards.map(\.id), ["c1", "c2"],
            "only the group's document children, in manifest order (the image is not a card)")
    }

    func test_paletteCards_noPaletteGroup_isEmpty() {
        let research = [card("wb", "World Bible", path: "research/world-bible.md")]
        XCTAssertTrue(PaletteLoading.paletteCards(in: research).isEmpty)
    }

    func test_paletteCards_foundByPathFallback_whenRoleAbsent() {
        // Legacy manifest: no role stamped, identity falls back to the folder path.
        let research = [
            group("pg", "Palette", path: "research/palette", role: nil, [
                card("c1", "The Flat", path: "research/palette/the-flat.md"),
            ]),
        ]
        XCTAssertEqual(PaletteLoading.paletteCards(in: research).map(\.id), ["c1"])
    }

    // MARK: - excludingPalette

    /// `statements: []` throughout this suite — the legacy arm. The intent
    /// exclusion is conditional as of M1A (it follows what the Craft Intent row
    /// actually shows); `PhoneStatementReadTests` owns both sides of that.
    func test_excludingPalette_removesGroupDescendantsAndIntent_keepsOrdinaryResearch() {
        let research = [
            group("pg", "Palette", path: "research/palette", role: .paletteGroup, [
                card("c1", "The Flat", path: "research/palette/the-flat.md"),
                card("c2", "The Square", path: "research/palette/the-square.md"),
            ]),
            ResearchItem(id: "ci", title: "Craft Intent", type: .asset, kind: .document,
                         path: "research/craft-intent.md", role: .craftIntent),
            card("wb", "World Bible", path: "research/world-bible.md"),
        ]
        // The leaves the binder would compute (readable research), palette cards
        // + intent flattened in — the pre-existing duplication this fixes.
        let leaves = [
            card("c1", "The Flat", path: "research/palette/the-flat.md"),
            card("c2", "The Square", path: "research/palette/the-square.md"),
            ResearchItem(id: "ci", title: "Craft Intent", type: .asset, kind: .document,
                         path: "research/craft-intent.md", role: .craftIntent),
            card("wb", "World Bible", path: "research/world-bible.md"),
        ]
        let kept = PaletteLoading.excludingPalette(leaves, research: research, statements: [])
        XCTAssertEqual(kept.map(\.id), ["wb"],
            "palette cards and the craft-intent doc leave the Research section; ordinary research stays")
    }

    func test_excludingPalette_roleRenamedGroup_stillExcludesDescendants() {
        // Group renamed on disk (path no longer the convention), but role marks
        // it as the palette group — its cards must still be excluded.
        let research = [
            group("pg", "My Textures", path: "research/my-textures", role: .paletteGroup, [
                card("c1", "The Flat", path: "research/my-textures/the-flat.md"),
            ]),
            card("wb", "World Bible", path: "research/world-bible.md"),
        ]
        let leaves = [
            card("c1", "The Flat", path: "research/my-textures/the-flat.md"),
            card("wb", "World Bible", path: "research/world-bible.md"),
        ]
        XCTAssertEqual(PaletteLoading.excludingPalette(leaves, research: research, statements: []).map(\.id), ["wb"])
    }

    func test_excludingPalette_noPaletteOrIntent_isIdentity() {
        let research = [card("wb", "World Bible", path: "research/world-bible.md")]
        let leaves = [card("wb", "World Bible", path: "research/world-bible.md")]
        XCTAssertEqual(PaletteLoading.excludingPalette(leaves, research: research, statements: []).map(\.id), ["wb"])
    }

    // MARK: - groupedNotes

    private func note(_ sense: PaletteCard.Sense?, _ text: String) -> PaletteCard.SensoryNote {
        PaletteCard.SensoryNote(sense: sense, text: text)
    }

    func test_groupedNotes_ordersBySenseAllCases_untaggedLast_skippingEmpty() {
        let notes = [
            note(nil, "a general impression"),
            note(.smell, "turpentine"),
            note(.sight, "grey light"),
            note(.smell, "cold ash"),
        ]
        let groups = PaletteLoading.groupedNotes(notes)
        // Sense.allCases order is sight, sound, smell, touch, taste — sound/touch/
        // taste are empty and skipped; untagged sorts last.
        XCTAssertEqual(groups.map(\.sense), [.sight, .smell, nil])
        XCTAssertEqual(groups[0].notes.map(\.text), ["grey light"])
        XCTAssertEqual(groups[1].notes.map(\.text), ["turpentine", "cold ash"])
        XCTAssertEqual(groups[2].notes.map(\.text), ["a general impression"])
    }

    func test_groupedNotes_empty_isEmpty() {
        XCTAssertTrue(PaletteLoading.groupedNotes([]).isEmpty)
    }

    func test_groupedNotes_onlyUntagged_singleTrailingGroup() {
        let groups = PaletteLoading.groupedNotes([note(nil, "x"), note(nil, "y")])
        XCTAssertEqual(groups.map(\.sense), [nil])
        XCTAssertEqual(groups[0].notes.map(\.text), ["x", "y"])
    }
}
