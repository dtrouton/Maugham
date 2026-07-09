import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class CraftIntentToolTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "IntentMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    func test_absentIntent_returnsExistsFalse_notError() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        let id = ProjectIdentifier.id(for: url)
        let json = try await ReadCraftIntentTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ReadCraftIntentTool.Result.self, from: json)
        XCTAssertFalse(result.exists)
        XCTAssertNil(result.markdown)
        await ds.close()
    }

    func test_presentIntent_returnsMarkdown() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let item = try await store.createCraftIntent(forPieceId: nil)
        try "This story lives in the body. The port scenes should smell."
            .data(using: .utf8)!
            .write(to: url.appendingPathComponent(item.path!))
        let id = ProjectIdentifier.id(for: url)
        let json = try await ReadCraftIntentTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ReadCraftIntentTool.Result.self, from: json)
        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.markdown,
            "This story lives in the body. The port scenes should smell.")
        XCTAssertEqual(result.path, "research/craft-intent.md")
        await ds.close()
    }

    func test_unknownProject_throwsToolError() async throws {
        let reg = ProjectRegistry()
        do {
            _ = try await ReadCraftIntentTool.handle(
                paramsJSON: Data("{\"project_id\":\"nope\"}".utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }
}
