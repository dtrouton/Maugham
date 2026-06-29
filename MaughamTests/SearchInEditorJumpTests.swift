import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class SearchInEditorJumpTests: XCTestCase {
    func test_findMatchSelected_resolvesPathToManuscriptItem() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindJump-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        try "kitchen here\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // ADR 0018: bootstrap the doc so the op log is seeded before search.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)

        let store = try await ProjectStore.load(from: tmp)
        let matches = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store).matches
        XCTAssertEqual(matches.count, 1)
        let match = matches[0]

        // Verify lookup: match path → manifest item id
        let id = store.manifest.structure.first(where: { $0.path == match.documentPath })?.id
        XCTAssertEqual(id, "ch-1")
    }
}
