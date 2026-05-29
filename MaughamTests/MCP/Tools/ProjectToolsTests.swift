import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectToolsTests: XCTestCase {
    private func makeProject(title: String = "Demo") async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let item = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                  path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: title, author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    func test_listProjects_returnsRegisteredProjects() async throws {
        let (u1, s1) = try await makeProject(title: "A")
        let (u2, s2) = try await makeProject(title: "B")
        let reg = ProjectRegistry()
        reg.register(url: u1, store: s1)
        reg.register(url: u2, store: s2)
        let json = try await ListProjectsTool.handle(paramsJSON: nil, registry: reg)
        let result = try JSONDecoder().decode([ListProjectsTool.Project].self, from: json)
        XCTAssertEqual(Set(result.map(\.title)), ["A", "B"])
        XCTAssertEqual(Set(result.map(\.id)),
                       Set([ProjectIdentifier.id(for: u1), ProjectIdentifier.id(for: u2)]))
    }

    func test_getMetadata_returnsTitleAndType() async throws {
        let (url, store) = try await makeProject(title: "Mine")
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetMetadataTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(GetMetadataTool.Metadata.self, from: json)
        XCTAssertEqual(meta.title, "Mine")
        XCTAssertEqual(meta.type, "novel")
    }

    func test_getMetadata_unknownProject_throwsProjectNotOpen() async throws {
        let reg = ProjectRegistry()
        let req = "{\"project_id\":\"proj_deadbeef\"}"
        do {
            _ = try await GetMetadataTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw")
        } catch MCPError.projectNotOpen {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}

extension ProjectToolsTests {
    func test_listProjects_includesCollection() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-coll-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let data = try await ListProjectsTool.handle(paramsJSON: nil, registry: reg)
        let projects = try JSONDecoder().decode(
            [ListProjectsTool.Project].self, from: data)
        XCTAssertTrue(projects.contains { $0.type == "collection" })
    }

    func test_getOutline_Collection_returnsPiecesFlat() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-out-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addLoosePiece(title: "Story A", mode: .prose)
        _ = try await store.addLoosePiece(title: "Story B", mode: .screenplay)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)

        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let data = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outline = try decoder.decode(
            GetOutlineTool.Outline.self, from: data)
        XCTAssertEqual(outline.nodes.count, 2)
        XCTAssertNil(outline.nodes[0].children)
    }
}
