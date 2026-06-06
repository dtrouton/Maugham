import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ListResearchToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research/characters"), withIntermediateDirectories: true)
        try "Sarah is 32.".write(
            to: tmp.appendingPathComponent("research/characters/sarah.md"),
            atomically: true, encoding: .utf8)
        try "general notes".write(
            to: tmp.appendingPathComponent("research/intro.md"),
            atomically: true, encoding: .utf8)

        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/characters/sarah.md", addedAt: Date())
        let characters = ResearchItem(
            id: "grp-characters", title: "Characters", type: .group, kind: nil,
            path: nil, addedAt: Date(),
            children: [sarah])
        let intro = ResearchItem(
            id: "res-intro", title: "Intro", type: .asset, kind: .document,
            path: "research/intro.md", addedAt: Date())

        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [characters, intro])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_listResearch_returnsTopLevelItems() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListResearchTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            ListResearchTool.ResearchTree.self, from: json)
        XCTAssertEqual(result.items.count, 2)
        let titles = Set(result.items.map(\.title))
        XCTAssertEqual(titles, ["Characters", "Intro"])
    }

    func test_listResearch_returnsHierarchicalChildren() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListResearchTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            ListResearchTool.ResearchTree.self, from: json)
        let characters = try XCTUnwrap(result.items.first { $0.title == "Characters" })
        XCTAssertEqual(characters.type, "group")
        XCTAssertEqual(characters.children?.count, 1)
        XCTAssertEqual(characters.children?.first?.title, "Sarah")
        XCTAssertEqual(characters.children?.first?.type, "asset")
        XCTAssertEqual(characters.children?.first?.kind, "document")
        XCTAssertEqual(characters.children?.first?.path, "research/characters/sarah.md")
    }

    func test_listResearch_unknownProject_throwsUnknownProjectID() async throws {
        let reg = ProjectRegistry()
        let req = "{\"project_id\":\"proj_deadbeef\"}"
        do {
            _ = try await ListResearchTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}
