import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ListDocumentsByTagToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDBT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        for name in ["c1.md", "c2.md", "c3.md"] {
            try "x".write(to: tmp.appendingPathComponent("manuscript/\(name)"),
                           atomically: true, encoding: .utf8)
        }
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md", tags: ["pov:sarah", "act-one"])
        let ch2 = StructureItem(id: "ch-2", title: "Ch 2", type: .document,
                                 path: "manuscript/c2.md", tags: ["pov:james"])
        let ch3 = StructureItem(id: "ch-3", title: "Ch 3", type: .document,
                                 path: "manuscript/c3.md", tags: ["pov:sarah"])
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1, ch2, ch3], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_listByTag_returnsMatchingDocs() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"tag\":\"pov:sarah\"}"
        let json = try await ListDocumentsByTagTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let docs = try JSONDecoder().decode(
            [ListDocumentsByTagTool.Doc].self, from: json)
        XCTAssertEqual(Set(docs.map(\.id)), ["ch-1", "ch-3"])
    }

    func test_listByTag_caseInsensitive() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"tag\":\"POV:SARAH\"}"
        let json = try await ListDocumentsByTagTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let docs = try JSONDecoder().decode(
            [ListDocumentsByTagTool.Doc].self, from: json)
        XCTAssertEqual(docs.count, 2)
    }
}
