import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class PaletteToolsTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    func makeProjectWithCard() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry, ResearchItem) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try """
        # The Flat

        kind: location

        ## Swatches

        - #8A6F4D

        ## Senses

        - smell: turpentine
        - sound: tram-rattle
        """.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg, item)
    }

    func test_listPaletteCards_returnsSummaries() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        let id = ProjectIdentifier.id(for: url)
        let json = try await ListPaletteCardsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ListPaletteCardsTool.Result.self, from: json)
        XCTAssertEqual(result.cards.count, 1)
        let card = try XCTUnwrap(result.cards.first)
        XCTAssertEqual(card.id, item.id)
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, "location")
        XCTAssertEqual(card.swatches, ["#8A6F4D"])
        XCTAssertEqual(card.note_count, 2)
        XCTAssertTrue(card.image_paths.isEmpty)
        await ds.close()
    }

    func test_listPaletteCards_emptyProject_returnsEmpty() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Empty", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let json = try await ListPaletteCardsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}".utf8),
            registry: reg)
        let result = try JSONDecoder().decode(ListPaletteCardsTool.Result.self, from: json)
        XCTAssertTrue(result.cards.isEmpty)
        await ds.close()
    }
}
