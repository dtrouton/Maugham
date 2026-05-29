import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ResearchLinkToolsTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RL-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah".write(to: tmp.appendingPathComponent("research/sarah.md"),
                           atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                     path: "manuscript/c1.md")
        let sarah = ResearchItem(id: "res-sarah", title: "Sarah", type: .asset,
                                  kind: .document, path: "research/sarah.md",
                                  addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_linkResearch_addsLink() async throws {
        let (url, store, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"research_id\":\"res-sarah\",\"document_id\":\"ch-1\"}"
        _ = try await LinkResearchTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), ["res-sarah"])
    }

    func test_unlinkResearch_removesLink() async throws {
        let (url, store, reg) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"research_id\":\"res-sarah\",\"document_id\":\"ch-1\"}"
        _ = try await UnlinkResearchTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [])
    }
}
