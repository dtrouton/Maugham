import XCTest
@testable import Maugham
import MaughamCore

/// Coverage for the `paletteCoordinatedWrite(_:to:)` funnel (A1-High,
/// `Maugham/Stores/ProjectStore+Palette.swift`): both the coordinated
/// (`documentStore` wired, real projects) and fallback (`documentStore ==
/// nil`, unit-test contexts) branches must produce the exact same on-disk
/// content as the pre-fix raw `.write(to:)` calls did. The funnel changes
/// HOW the bytes reach disk, never WHAT gets written.
@MainActor
final class PaletteWriteCoordinationTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    /// `addPaletteCard`'s underlying `addResearchTextNote` requires a
    /// `documentStore` for the note's own coordinated creation (independent
    /// of this task), so the funnel's fallback branch can only be exercised
    /// on an EXISTING card — this creates both cards identically with
    /// `documentStore` wired, then nils it on one store before the update,
    /// forcing that write through `paletteCoordinatedWrite`'s direct-write
    /// fallback. The two resulting files must be byte-identical: the funnel
    /// changes HOW the bytes reach disk, never WHAT gets written.
    func test_updatePaletteCard_coordinatedAndFallbackWrites_areByteIdentical() async throws {
        let coordinatedURL = try await ProjectFactory.createNovelProject(
            named: "PaletteCoordinated", in: temp.url)
        let coordinatedStore = try await ProjectStore.load(from: coordinatedURL)
        let coordinatedDS = try await DocumentStore.open(url: coordinatedURL)
        coordinatedStore.documentStore = coordinatedDS
        let coordinatedItem = try await coordinatedStore.addPaletteCard(
            title: "The Flat", kind: .location)
        try await coordinatedStore.updatePaletteCard(
            makeSwatchCard(from: coordinatedStore.loadPaletteCards()[0]))
        let coordinatedContents = try String(
            contentsOf: coordinatedURL.appendingPathComponent(coordinatedItem.path!),
            encoding: .utf8)
        await coordinatedDS.close()

        let fallbackURL = try await ProjectFactory.createNovelProject(
            named: "PaletteFallback", in: temp.url)
        let fallbackStore = try await ProjectStore.load(from: fallbackURL)
        let fallbackDS = try await DocumentStore.open(url: fallbackURL)
        fallbackStore.documentStore = fallbackDS
        let fallbackItem = try await fallbackStore.addPaletteCard(
            title: "The Flat", kind: .location)
        fallbackStore.documentStore = nil   // forces the direct-write fallback branch
        try await fallbackStore.updatePaletteCard(
            makeSwatchCard(from: fallbackStore.loadPaletteCards()[0]))
        let fallbackContents = try String(
            contentsOf: fallbackURL.appendingPathComponent(fallbackItem.path!), encoding: .utf8)
        await fallbackDS.close()

        XCTAssertEqual(coordinatedContents, fallbackContents)
    }

    private func makeSwatchCard(from card: PaletteCard) -> PaletteCard {
        PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: .location,
            swatches: ["#8A6F4D"], notes: [.init(sense: .smell, text: "turpentine")],
            imagePaths: [], body: "Walk-up.")
    }

    func test_updatePaletteCard_coordinatedWrite_landsFullContent() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "PaletteUpdateCoordinated", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        let card = makeSwatchCard(from: store.loadPaletteCards()[0])
        try await store.updatePaletteCard(card)

        let onDisk = try String(
            contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- smell: turpentine"))
        XCTAssertEqual(store.loadPaletteCards()[0], card)
        await ds.close()
    }
}
