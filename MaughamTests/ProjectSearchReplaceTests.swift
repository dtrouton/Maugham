import XCTest
import MaughamCore
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

    func test_replaceAll_replacesAllMatchesPerDoc() async throws {
        let project = try makeProject(manuscript: [
            ("c1", "kitchen here\nand kitchen there\n"),
            ("c2", "no kitchen anywhere\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store)
        XCTAssertEqual(results.matchCount, 3)

        try await store.replaceAll(in: results, with: "library")

        let c1 = try String(contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        let c2 = try String(contentsOf: project.appendingPathComponent("manuscript/c2.md"))
        XCTAssertEqual(c1, "library here\nand library there\n")
        XCTAssertEqual(c2, "no library anywhere\n")
    }

    func test_replaceAll_rightToLeftOrderPreservesOffsets() async throws {
        // Multiple matches on the same line; offsets must apply right-to-left
        // so earlier matches' ranges stay valid.
        let project = try makeProject(manuscript: [
            ("c1", "ab ab ab\n")  // 3 matches of "ab" at offsets 0, 3, 6
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await ProjectSearchEngine().search(
            query: "ab", options: SearchOptions(), in: store)
        XCTAssertEqual(results.matchCount, 3)

        try await store.replaceAll(in: results, with: "XYZ")  // longer than "ab"

        let content = try String(contentsOf: project.appendingPathComponent("manuscript/c1.md"))
        XCTAssertEqual(content, "XYZ XYZ XYZ\n")
    }
}
