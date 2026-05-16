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

    func test_findReferences_byResearchTitle_resolvesAndReturnsLinkedChapters() async throws {
        // Same fixture shape as test_findReferences_byResearchId_returnsLinkedChapters,
        // but pass the title "Sarah" instead of the id "res-sarah".
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FRT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah".write(to: tmp.appendingPathComponent("research/sarah.md"),
                           atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document, path: "manuscript/c1.md")
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
        let req = "{\"project_id\":\"\(id)\",\"target\":\"Sarah\"}"
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

    /// Three-document screenplay project; each .fountain has its own scene
    /// heading. list_scenes should aggregate across all docs.
    func test_listScenes_walksAllDocuments() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LS3-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "INT. KITCHEN - DAY\n\nSarah pours coffee.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        try "EXT. PARK - NIGHT\n\nJames waits on a bench.\n".write(
            to: tmp.appendingPathComponent("manuscript/s2.fountain"),
            atomically: true, encoding: .utf8)
        try "INT. CAR - DAY\n\nDriving in silence.\n".write(
            to: tmp.appendingPathComponent("manuscript/s3.fountain"),
            atomically: true, encoding: .utf8)
        let s1 = StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                path: "manuscript/s1.fountain")
        let s2 = StructureItem(id: "doc-2", title: "Scene 2", type: .document,
                                path: "manuscript/s2.fountain")
        let s3 = StructureItem(id: "doc-3", title: "Scene 3", type: .document,
                                path: "manuscript/s3.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1, s2, s3], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 3,
            "expected 3 scenes across 3 docs, got: \(scenes)")
        // document_id is preserved per-scene
        XCTAssertEqual(Set(scenes.map(\.document_id)),
                       Set(["doc-1", "doc-2", "doc-3"]))
        // headings preserved
        XCTAssertTrue(scenes.contains { $0.heading.contains("KITCHEN") })
        XCTAssertTrue(scenes.contains { $0.heading.contains("PARK") })
        XCTAssertTrue(scenes.contains { $0.heading.contains("CAR") })
    }

    /// Short screenplay (well under 1 page total): page_start must start at
    /// 0.0 and page_length must be the fractional length actually occupied
    /// by the scene's lines. The pre-fix behavior was page_start: 1.0,
    /// page_length: 0 — useless for "where am I against page target".
    func test_listScenes_shortScript_hasFractionalPagePositions() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSF-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "INT. KITCHEN - DAY\n\nA brief scene.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        let s1 = StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                path: "manuscript/s1.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 1)
        // First scene starts at the very top — page 0.0, not 1.0.
        XCTAssertEqual(scenes[0].page_start, 0.0, accuracy: 0.0001,
            "first scene should start at 0.0, got \(scenes[0].page_start)")
        // Length must be positive (fractional, since total < 1 page).
        XCTAssertGreaterThan(scenes[0].page_length, 0.0,
            "short scene should still have positive length")
        XCTAssertLessThan(scenes[0].page_length, 1.0,
            "short scene should not exceed 1 page")
    }
}
