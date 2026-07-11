import XCTest
@testable import MaughamCore

final class ResearchRoleTests: XCTestCase {
    func test_legacyJSON_withoutRole_decodesNil() throws {
        let json = #"{"id":"res-1","title":"Palette","type":"group","path":"research/palette"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertNil(item.role)
    }

    func test_unknownRoleRawValue_decodesUnknownSentinel() throws {
        let json = #"{"id":"res-1","title":"X","type":"asset","role":"from_the_future"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.role, .unknown)
    }

    func test_roleRoundTrips() throws {
        let item = ResearchItem(id: "res-1", title: "Palette", type: .group,
                                path: "research/palette", role: .paletteGroup)
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(ResearchItem.self, from: data)
        XCTAssertEqual(back.role, .paletteGroup)
    }

    func test_paletteLookup_roleFirst_beatsPathMatch() {
        let renamed = ResearchItem(id: "res-a", title: "Moods", type: .group,
                                   path: "research/moods", role: .paletteGroup)
        let impostor = ResearchItem(id: "res-b", title: "Palette", type: .group,
                                    path: "research/palette")
        XCTAssertEqual(PaletteLookup.paletteGroup(in: [impostor, renamed])?.id, "res-a")
    }

    func test_paletteLookup_pathFallback_whenNoRole() {
        let legacy = ResearchItem(id: "res-c", title: "Palette", type: .group,
                                  path: "research/palette")
        XCTAssertEqual(PaletteLookup.paletteGroup(in: [legacy])?.id, "res-c")
        XCTAssertNil(PaletteLookup.paletteGroup(in: []))
    }

    func test_craftIntentLookup_roleFirst_thenFilenameFallback_scoped() {
        let renamedIntent = ResearchItem(id: "res-d", title: "What this needs", type: .asset,
                                         kind: .document, path: "research/what-this-needs.md",
                                         role: .craftIntent)
        XCTAssertEqual(PaletteLookup.craftIntentItem(
            in: [renamedIntent], researchPrefix: "research").map(\.id), "res-d")
        let legacy = ResearchItem(id: "res-e", title: "Craft Intent", type: .asset,
                                  kind: .document, path: "research/craft-intent.md")
        XCTAssertEqual(PaletteLookup.craftIntentItem(
            in: [legacy], researchPrefix: "research").map(\.id), "res-e")
        // Piece-scoped doc must NOT match project scope.
        let pieceDoc = ResearchItem(id: "res-f", title: "Craft Intent", type: .asset,
                                    kind: .document,
                                    path: "pieces/01-story/research/craft-intent.md",
                                    role: .craftIntent)
        XCTAssertNil(PaletteLookup.craftIntentItem(in: [pieceDoc], researchPrefix: "research"))
        XCTAssertEqual(PaletteLookup.craftIntentItem(
            in: [pieceDoc], researchPrefix: "pieces/01-story/research").map(\.id), "res-f")
    }
}
