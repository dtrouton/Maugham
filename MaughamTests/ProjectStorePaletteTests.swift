import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class ProjectStorePaletteTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_ensurePaletteGroup_createsFolderAndManifestGroup_once() async throws {
        let (url, store, ds) = try await makeNovel()
        XCTAssertNil(store.paletteGroup())
        let group = try await store.ensurePaletteGroup()
        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.path, ProjectStore.paletteFolderPath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(ProjectStore.paletteFolderPath).path))
        let again = try await store.ensurePaletteGroup()
        XCTAssertEqual(again.id, group.id)   // idempotent — no duplicate group
        await ds.close()
    }

    func test_addPaletteCard_writesTemplateAndManifestEntry() async throws {
        let (url, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        XCTAssertEqual(item.kind, .document)
        XCTAssertTrue(item.path?.hasPrefix("research/palette/") ?? false)
        let fileURL = url.appendingPathComponent(item.path ?? "")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let card = PaletteCardParser.parse(
            markdown: contents, itemId: item.id, fallbackTitle: "x",
            cardDirectory: ProjectStore.paletteFolderPath)
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, .location)
        await ds.close()
    }

    func test_loadPaletteCards_returnsParsedCardsInManifestOrder() async throws {
        let (_, store, ds) = try await makeNovel()
        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        _ = try await store.addPaletteCard(title: "Marlowe", kind: .character)
        let cards = store.loadPaletteCards()
        XCTAssertEqual(cards.map(\.title), ["The Flat", "Marlowe"])
        XCTAssertEqual(cards.map(\.kind), [.location, .character])
        XCTAssertEqual(store.paletteCardItems().count, 2)
        await ds.close()
    }

    func test_loadPaletteCards_emptyWithoutGroup() async throws {
        let (_, store, ds) = try await makeNovel()
        XCTAssertTrue(store.loadPaletteCards().isEmpty)
        XCTAssertTrue(store.paletteCardItems().isEmpty)
        await ds.close()
    }
}
