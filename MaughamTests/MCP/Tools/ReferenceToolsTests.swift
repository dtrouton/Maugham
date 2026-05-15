import XCTest
@testable import Maugham

@MainActor
final class ReferenceToolsTests: XCTestCase {
    fileprivate func makeProject(type: ProjectType = .novel) async throws -> (URL, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "She walked into the kitchen. He followed.\n\nKitchen scene continued.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, reg)
    }

    func test_searchText_findsMatches() async throws {
        let (url, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"query\":\"kitchen\"}"
        let json = try await SearchTextTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let matches = try JSONDecoder().decode(
            [SearchTextTool.Match].self, from: json)
        XCTAssertGreaterThanOrEqual(matches.count, 2)
    }

    func test_listScenes_nonScreenplay_returnsEmpty() async throws {
        let (url, reg) = try await makeProject(type: .novel)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 0)
    }
}

extension ReferenceToolsTests {
    func test_findReferences_byResearchId_returnsLinkedChapters() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah\n".write(to: tmp.appendingPathComponent("research/sarah.md"),
                             atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"target\":\"res-sarah\"}"
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].from_id, "ch-1")
        XCTAssertEqual(refs[0].kind, "linked_research")
    }

    func test_getSessionStats_returnsAggregate() async throws {
        let (url, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetSessionStatsTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let stats = try JSONDecoder().decode(
            GetSessionStatsTool.SessionStats.self, from: json)
        XCTAssertGreaterThanOrEqual(stats.daily.count, 0)
        XCTAssertGreaterThanOrEqual(stats.total_minutes, 0)
    }
}
