import XCTest
@testable import MaughamCore

final class ResearchRoleTests: XCTestCase {
    func test_legacyJSON_withoutRole_decodesNil() throws {
        let json = #"{"id":"res-1","title":"Palette","type":"group","path":"research/palette"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertNil(item.role)
    }

    func test_unknownRoleRawValue_decodesUnknownSentinel_preservingRaw() throws {
        let json = #"{"id":"res-1","title":"X","type":"asset","role":"from_the_future"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.role, .unknown("from_the_future"))
    }

    func test_knownRoleRoundTrips_stable() throws {
        let item = ResearchItem(id: "res-1", title: "Palette", type: .group,
                                path: "research/palette", role: .paletteGroup)
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(ResearchItem.self, from: data)
        XCTAssertEqual(back.role, .paletteGroup)
    }

    /// ADR-0015 safe round-trip: a role from a newer build must survive
    /// decode→encode on an older reader with its ORIGINAL raw string intact —
    /// never clobbered to the literal "unknown" (S7). `role` is identity-bearing,
    /// so a lossy re-encode would destroy the forward build's marker on resave.
    func test_unknownRole_reEncodesLosslessly_preservingOriginalRaw() throws {
        let json = #"{"id":"res-1","title":"X","type":"asset","role":"palette_group_v2"}"#
        let item = try JSONDecoder().decode(ResearchItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.role, .unknown("palette_group_v2"))

        // Re-encode (what a lazy heal / manifest save does) and re-decode.
        let reEncoded = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(ResearchItem.self, from: reEncoded)
        XCTAssertEqual(back.role, .unknown("palette_group_v2"),
            "unknown role must round-trip losslessly, not collapse to \"unknown\"")

        // The exact original string must appear on the wire (no "unknown" literal).
        let wire = String(decoding: reEncoded, as: UTF8.self)
        XCTAssertTrue(wire.contains(#""role":"palette_group_v2""#),
            "re-encoded manifest must carry the original raw role string")
        XCTAssertFalse(wire.contains(#""role":"unknown""#),
            "re-encoded manifest must NOT clobber the newer role to literal \"unknown\"")
    }

    /// Directly pin the `.unknown` payload encode contract at the enum level.
    func test_unknownRole_encodesAsItsPreservedRaw() throws {
        let role = ResearchRole.unknown("some_future_role")
        let encoded = String(decoding: try JSONEncoder().encode(role), as: UTF8.self)
        XCTAssertEqual(encoded, #""some_future_role""#)
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

    // MARK: - Shared palette-card filter (S10)

    func test_paletteCards_returnsDirectDocumentChildren_inOrder_filteringNonDocuments() {
        let group = ResearchItem(
            id: "pg", title: "Palette", type: .group, path: "research/palette",
            children: [
                ResearchItem(id: "c1", title: "The Flat", type: .asset, kind: .document,
                             path: "research/palette/the-flat.md"),
                ResearchItem(id: "im", title: "Mood", type: .asset, kind: .image,
                             path: "research/palette/mood.png"),
                ResearchItem(id: "c2", title: "The Harbour", type: .asset, kind: .document,
                             path: "research/palette/the-harbour.md"),
                // Nested group's document is NOT a direct child — excluded.
                ResearchItem(id: "sub", title: "Sub", type: .group, children: [
                    ResearchItem(id: "nested", title: "Nested", type: .asset, kind: .document,
                                 path: "research/palette/sub/nested.md"),
                ]),
            ],
            role: .paletteGroup)
        XCTAssertEqual(
            PaletteLookup.paletteCards(in: [group]).map(\.id), ["c1", "c2"],
            "only direct .asset/.document children, in manifest order")
    }

    func test_paletteCards_roleRenamedGroup_stillFound_viaRoleFirstLookup() {
        let group = ResearchItem(
            id: "pg", title: "Sensory Bank", type: .group, path: "research/sensory-bank",
            children: [
                ResearchItem(id: "c1", title: "The Flat", type: .asset, kind: .document,
                             path: "research/sensory-bank/the-flat.md"),
            ],
            role: .paletteGroup)
        XCTAssertEqual(PaletteLookup.paletteCards(in: [group]).map(\.id), ["c1"])
    }

    func test_paletteCards_noPaletteGroup_isEmpty() {
        let other = ResearchItem(id: "o", title: "Characters", type: .group,
                                 path: "research/characters")
        XCTAssertTrue(PaletteLookup.paletteCards(in: [other]).isEmpty)
        XCTAssertTrue(PaletteLookup.paletteCards(in: []).isEmpty)
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
