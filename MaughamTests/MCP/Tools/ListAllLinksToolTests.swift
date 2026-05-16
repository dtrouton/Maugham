import XCTest
@testable import Maugham

@MainActor
final class ListAllLinksToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        // ch-1 wiki-links to "Sarah" and "Ch 2"; ch-2 has no wiki links.
        try "Sarah arrives. See [[Sarah]] for backstory. Also [[Ch 2]].".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Continued.".write(
            to: tmp.appendingPathComponent("manuscript/c2.md"),
            atomically: true, encoding: .utf8)
        try "Sarah profile.".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let ch2 = StructureItem(id: "ch-2", title: "Ch 2", type: .document,
                                 path: "manuscript/c2.md")
        let sarah = ResearchItem(id: "res-sarah", title: "Sarah", type: .asset,
                                  kind: .document, path: "research/sarah.md",
                                  addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1, ch2], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_listAllLinks_emitsLinkedResearchEdges() async throws {
        let (url, store, reg) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "res-sarah" && $0.kind == "linked_research"
        })
    }

    func test_listAllLinks_emitsWikiEdges_resolvedAndUnresolved() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        // ch-1's body contains [[Sarah]] (resolves to res-sarah) and [[Ch 2]] (resolves to ch-2).
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "res-sarah" && $0.kind == "wiki"
        }, "expected wiki edge ch-1 → res-sarah")
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "ch-2" && $0.kind == "wiki"
        }, "expected wiki edge ch-1 → ch-2")
    }

    func test_listAllLinks_unresolvedWikiLink_emittedAsUnresolved() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALU-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "References to [[Nonexistent]] linger here.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        // An unresolved wiki target is reported with kind "wiki_unresolved"
        // and the literal target title in to_title; to_id is null.
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" &&
            $0.to_id == nil &&
            $0.to_title == "Nonexistent" &&
            $0.kind == "wiki_unresolved"
        }, "expected unresolved wiki edge for [[Nonexistent]], got: \(edges)")
    }
}
