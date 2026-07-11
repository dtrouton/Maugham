import XCTest
@testable import Maugham
import MaughamCore

final class PalettePaneTests: XCTestCase {
    func test_senseSymbol_coversAllSenses() {
        for sense in PaletteCard.Sense.allCases {
            XCTAssertFalse(PalettePane.senseSymbol(for: sense).isEmpty)
        }
        XCTAssertEqual(PalettePane.senseSymbol(for: .sight), "eye")
        XCTAssertEqual(PalettePane.senseSymbol(for: .touch), "hand.raised")
    }

    func test_groupedNotes_ordersTaggedBySenseThenUntagged() {
        let notes: [PaletteCard.SensoryNote] = [
            .init(sense: nil, text: "loose"),
            .init(sense: .taste, text: "salt"),
            .init(sense: .sight, text: "green light"),
        ]
        let groups = PalettePane.groupedNotes(notes)
        XCTAssertEqual(groups.map(\.sense), [.sight, .taste, nil])
        XCTAssertEqual(groups.first?.notes.map(\.text), ["green light"])
    }
}

/// Pane-level interaction coverage over a real `ProjectStore` — mirrors
/// `PaletteCardEditorRenameTests`'s store-driven style (no UI automation). Each
/// test exercises the exact store call the corresponding pane makes so a break
/// in that seam (wall reload, editor seed, wall/binder ordering) fails here
/// without standing up SwiftUI.
@MainActor
final class PalettePaneInteractionTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "PalettePane", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    // MARK: - Add card: PaletteWallView.reload() reads `store.loadPaletteCards()`

    func test_addCard_wallGainsTileAndFileCreated() async throws {
        let (url, store, ds) = try await makeNovel()

        XCTAssertTrue(store.loadPaletteCards().isEmpty)

        let item = try await store.addPaletteCard(title: "Rain-slick alley", kind: .location)

        // What PaletteWallView.reload() calls to build its grid: the new card
        // must be present, same seam PaletteBinderList's card list reads too.
        let cards = store.loadPaletteCards()
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.researchItemId, item.id)
        XCTAssertEqual(cards.first?.title, "Rain-slick alley")

        let path = try XCTUnwrap(store.paletteCardItems().first { $0.id == item.id }?.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(path).path))

        await ds.close()
    }

    // MARK: - Edit card: PaletteCardEditor.seed() reads
    // `store.loadPaletteCards().first { $0.researchItemId == cardId }`

    func test_selectingCard_seedsEditorStateForThatCard() async throws {
        let (_, store, ds) = try await makeNovel()

        let first = try await store.addPaletteCard(title: "Widow Character", kind: .character)
        let second = try await store.addPaletteCard(title: "Broken Clock Motif", kind: .motif)

        // Selecting the SECOND card must seed the editor's draft from the
        // second card, not the first — exactly PaletteCardEditor.seed()'s call.
        let selectedCardId = second.id
        let seeded = store.loadPaletteCards().first { $0.researchItemId == selectedCardId }
        XCTAssertEqual(seeded?.researchItemId, second.id)
        XCTAssertEqual(seeded?.title, "Broken Clock Motif")
        XCTAssertEqual(seeded?.kind, .motif)
        XCTAssertNotEqual(seeded?.researchItemId, first.id)

        await ds.close()
    }

    // MARK: - Reorder: PaletteBinderList / PaletteWallView both read cards in
    // manifest (wall) order via `paletteCardItems()` / `loadPaletteCards()`

    func test_reorderCard_persistsManifestOrder() async throws {
        let (_, store, ds) = try await makeNovel()

        let a = try await store.addPaletteCard(title: "A", kind: .location)
        let b = try await store.addPaletteCard(title: "B", kind: .location)
        let c = try await store.addPaletteCard(title: "C", kind: .location)
        XCTAssertEqual(store.paletteCardItems().map(\.id), [a.id, b.id, c.id])

        let group = try XCTUnwrap(store.paletteGroup())
        // Drag "C" to the front — a same-parent (sibling) reorder, manifest-only.
        try await store.moveResearchItem(id: c.id, toParentId: group.id, atIndex: 0)

        XCTAssertEqual(store.paletteCardItems().map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(store.loadPaletteCards().map(\.researchItemId), [c.id, a.id, b.id])

        // Order must survive a fresh manifest load, i.e. it's actually persisted,
        // not just held in the in-memory `manifest.research` of this store instance.
        let reloaded = try await ProjectStore.load(from: store.url)
        XCTAssertEqual(reloaded.paletteCardItems().map(\.id), [c.id, a.id, b.id])

        await ds.close()
    }
}
