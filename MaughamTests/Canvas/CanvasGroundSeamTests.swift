import XCTest
@testable import Maugham
import MaughamCore

/// **The last link in the ground's wash: the store vends the hexes and the one
/// parser accepts them.**
///
/// This file was `CanvasSegmentTests`, and everything else in it was about
/// `BinderSegment.canvas` — its picker symbol, its display name, its
/// transience, its `UIState` round trip, and the census that held
/// `BinderSegment.allCases` to a named set. All of it died with the enum in
/// shell-finish stage 2b Task 7.
///
/// **One of those tests was about a real capability rather than the segment**,
/// and it is worth saying where the capability went: it pinned, at the source,
/// that both binder toggles rendered the RESEARCH tree beside the canvas,
/// because §8A.1's drag-in route (1C-d) needs somewhere to drag a note FROM.
/// Every tree carries a Research section at its foot now
/// (`BinderTreeSections`), in every persona, and the pairing census that keeps
/// a host from mounting those rows without their presentations is
/// `TripwireGrepTests.test_everyBinderTreeMountsBothHalvesOfTheSections`.
@MainActor
final class CanvasGroundSeamTests: XCTestCase {

    /// The seam between the store and the ground: the store vends hex strings
    /// off REAL project data (one palette card, two swatches), and
    /// `CanvasGroundPalette` — the one parser — accepts every one of them
    /// unchanged. Task 8 built the wash seam and Task 10 wired it;
    /// `paletteSwatchHexes()` is the last link, so this is the one test in the
    /// slice that actually calls it.
    func test_theGroundAcceptsTheHexesTheStoreVends() async throws {
        let temp = TempDirectory()
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasPaletteSeam", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)
        let documentStore = try await DocumentStore.open(url: projectURL)
        store.documentStore = documentStore

        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        var card = store.loadPaletteCards()[0]
        card = PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: ["#8A6F4D", "#2F3B4C"], notes: card.notes,
            imagePaths: card.imagePaths, body: card.body)
        try await store.updatePaletteCard(card)

        let hexes = store.paletteSwatchHexes()
        XCTAssertEqual(hexes, ["#8A6F4D", "#2F3B4C"])
        XCTAssertEqual(CanvasGroundPalette.validHexes(hexes), hexes,
                       "every hex the store vends must be one the ground can consume")

        await documentStore.close()
    }
}
