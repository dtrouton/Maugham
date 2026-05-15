import XCTest
@testable import Maugham

@MainActor
final class DocumentToolsTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter 1\n\nFirst paragraph.\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_getOutline_returnsStructure() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let outline = try JSONDecoder().decode(
            GetOutlineTool.Outline.self, from: json)
        XCTAssertEqual(outline.nodes.count, 1)
        XCTAssertEqual(outline.nodes[0].title, "Ch 1")
        XCTAssertEqual(outline.nodes[0].type, "document")
    }

    func test_readDocument_returnsContent() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let doc = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertEqual(doc.title, "Ch 1")
        XCTAssertTrue(doc.text.contains("First paragraph"))
        XCTAssertEqual(doc.mode, "prose")
    }

    func test_readDocument_missingDoc_throws() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"nope\"}"
        do {
            _ = try await ReadDocumentTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail()
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}
