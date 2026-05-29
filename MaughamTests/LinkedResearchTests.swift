import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class LinkedResearchTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedResearch-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Chapter 1 content\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Sarah\n".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document,
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
        return (tmp, store)
    }

    func test_linkResearch_addsIdToDocument() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let ids = store.linkedResearchIds(forDocumentId: "ch-1")
        XCTAssertEqual(ids, ["res-sarah"])
    }

    func test_linkResearch_isIdempotent() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let ids = store.linkedResearchIds(forDocumentId: "ch-1")
        XCTAssertEqual(ids, ["res-sarah"])
    }

    func test_unlinkResearch_removesId() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        try await store.unlinkResearch(researchId: "res-sarah", fromDocumentId: "ch-1")
        let ids = store.linkedResearchIds(forDocumentId: "ch-1")
        XCTAssertEqual(ids, [])
    }

    func test_unlinkResearch_idempotentOnAbsent() async throws {
        let (_, store) = try await makeProject()
        try await store.unlinkResearch(researchId: "res-sarah", fromDocumentId: "ch-1")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [])
    }

    func test_resolveResearchLinks_returnsItemsInOrder() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let resolved = store.resolveResearchLinks(["res-sarah"])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].id, "res-sarah")
        XCTAssertEqual(resolved[0].title, "Sarah")
    }

    func test_resolveResearchLinks_skipsOrphans() async throws {
        let (_, store) = try await makeProject()
        let resolved = store.resolveResearchLinks(["res-sarah", "missing-id", "also-missing"])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].id, "res-sarah")
    }
}
