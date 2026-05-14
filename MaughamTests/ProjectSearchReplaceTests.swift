import XCTest
@testable import Maugham

@MainActor
final class ProjectSearchReplaceTests: XCTestCase {
    private func makeProject(manuscript: [(String, String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchReplace-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        var structure: [StructureItem] = []
        for (slug, content) in manuscript {
            try content.write(
                to: tmp.appendingPathComponent("manuscript/\(slug).md"),
                atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: "ms-\(slug)", title: slug, type: .document,
                path: "manuscript/\(slug).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_replaceMatch_writesNewContentToDisk() async throws {
        let project = try makeProject(manuscript: [
            ("c1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store).matches
        XCTAssertEqual(matches.count, 1)

        try await store.replaceMatch(matches[0], with: "library")

        let content = try String(
            contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        XCTAssertEqual(content, "the library is empty\n")
    }

    func test_replaceMatch_withEmptyString_deletesMatch() async throws {
        let project = try makeProject(manuscript: [
            ("c1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await ProjectSearchEngine().search(
            query: "kitchen ", options: SearchOptions(), in: store).matches
        XCTAssertEqual(matches.count, 1)

        try await store.replaceMatch(matches[0], with: "")

        let content = try String(
            contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        XCTAssertEqual(content, "the is empty\n")
    }
}
