import XCTest
@testable import MaughamPhone
import MaughamCore

/// Unit tests for the pure core of the Capture aim row (Task 5):
/// `PaletteAimPicker.cardTitles(in:)` — the project's palette-card titles pulled
/// straight from the already-decoded research tree (NO file reads). Mirrors the
/// Mac's card filter `children.filter { .asset && .document }` (ProjectStore+Palette),
/// resolved through the shared role-first `PaletteLookup`.
final class PaletteAimTests: XCTestCase {

    // MARK: - Builders

    private func group(
        title: String = PaletteConvention.groupTitle,
        path: String? = PaletteConvention.folderPath,
        role: ResearchRole? = nil,
        children: [ResearchItem]
    ) -> ResearchItem {
        ResearchItem(id: "grp-\(title)", title: title, type: .group,
                     path: path, children: children, role: role)
    }

    private func card(_ title: String) -> ResearchItem {
        ResearchItem(id: "card-\(title)", title: title, type: .asset,
                     kind: .document, path: "research/palette/\(title).md")
    }

    private func image(_ title: String) -> ResearchItem {
        ResearchItem(id: "img-\(title)", title: title, type: .asset,
                     kind: .image, path: "research/palette/\(title).png")
    }

    // MARK: - cardTitles

    func test_cardTitles_returnsOnlyDocumentAssets_inManifestOrder() {
        let research = [
            group(children: [
                card("The Flat"),
                image("Mood Board"),        // .image asset — excluded
                card("The Harbour"),
                ResearchItem(id: "sub", title: "Subgroup", type: .group, children: [card("Nested")]),  // nested group — excluded (not a direct document child)
                card("The Market"),
            ])
        ]
        XCTAssertEqual(
            PaletteAimPicker.cardTitles(in: research),
            ["The Flat", "The Harbour", "The Market"],
            "only direct .asset/.document children, in manifest order")
    }

    func test_cardTitles_noPaletteGroup_isEmpty() {
        let research = [
            ResearchItem(id: "other", title: "Characters", type: .group,
                         path: "research/characters", children: [card("Not palette")])
        ]
        XCTAssertTrue(PaletteAimPicker.cardTitles(in: research).isEmpty,
            "no palette group (by role or path) → no card titles")
    }

    func test_cardTitles_emptyResearch_isEmpty() {
        XCTAssertTrue(PaletteAimPicker.cardTitles(in: []).isEmpty)
    }

    /// The durable identity is `role`, not the folder path or title. A group the
    /// writer renamed (title "Sensory Bank", moved to a non-canonical path) is
    /// still the palette group when `role == .paletteGroup`, so its cards surface.
    func test_cardTitles_roleRenamedGroup_stillFound() {
        let research = [
            group(title: "Sensory Bank", path: "research/sensory-bank",
                  role: .paletteGroup,
                  children: [card("The Flat"), card("The Harbour")])
        ]
        XCTAssertEqual(
            PaletteAimPicker.cardTitles(in: research),
            ["The Flat", "The Harbour"],
            "role-first lookup finds the group even when path/title diverge from the convention")
    }
}
