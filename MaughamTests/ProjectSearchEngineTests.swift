import XCTest
@testable import Maugham

final class SearchTypesTests: XCTestCase {
    func test_SearchMatch_isIdentifiable() {
        let m = SearchMatch(
            id: UUID(),
            documentPath: "manuscript/foo.md",
            documentTitle: "Foo",
            documentSource: .manuscript,
            lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo bar",
            matchRangeInLine: NSRange(location: 0, length: 3))
        XCTAssertEqual(m.documentSource, .manuscript)
    }

    func test_SearchResults_countsMatchesAndDocuments() {
        let m1 = SearchMatch(
            id: UUID(), documentPath: "a.md", documentTitle: "A",
            documentSource: .manuscript, lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let m2 = SearchMatch(
            id: UUID(), documentPath: "a.md", documentTitle: "A",
            documentSource: .manuscript, lineNumber: 2,
            charRangeInDocument: NSRange(location: 10, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let m3 = SearchMatch(
            id: UUID(), documentPath: "b.md", documentTitle: "B",
            documentSource: .research, lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let r = SearchResults(
            query: "foo", options: SearchOptions(), matches: [m1, m2, m3])
        XCTAssertEqual(r.matchCount, 3)
        XCTAssertEqual(r.documentCount, 2)
    }

    func test_SearchOptions_defaultsCaseInsensitiveNoWholeWord() {
        let o = SearchOptions()
        XCTAssertFalse(o.caseSensitive)
        XCTAssertFalse(o.wholeWord)
    }
}

@MainActor
final class ProjectSearchEngineTests: XCTestCase {
    /// Build a project on disk with manuscript items, return its URL.
    private func makeProject(manuscript: [(slug: String, content: String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngine-\(UUID())")
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

    private func makeProjectWithResearch(
        manuscript: [(String, String)],
        research: [(String, String)]
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchEngineFull-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)

        var structure: [StructureItem] = []
        for (slug, content) in manuscript {
            try content.write(
                to: tmp.appendingPathComponent("manuscript/\(slug).md"),
                atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: "ms-\(slug)", title: slug, type: .document,
                path: "manuscript/\(slug).md"))
        }

        var researchItems: [ResearchItem] = []
        for (slug, content) in research {
            try content.write(
                to: tmp.appendingPathComponent("research/\(slug).md"),
                atomically: true, encoding: .utf8)
            researchItems.append(ResearchItem(
                id: "res-\(slug)", title: slug, type: .asset, kind: .document,
                path: "research/\(slug).md", addedAt: Date()))
        }

        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: researchItems)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_search_findsMatchInOneDocument() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "She walked to the kitchen.\nIt was empty.\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let engine = ProjectSearchEngine()
        let results = await engine.search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 1)
        XCTAssertEqual(results.matches[0].documentPath, "manuscript/chapter-1.md")
        XCTAssertEqual(results.matches[0].lineNumber, 1)
        XCTAssertEqual(results.matches[0].documentSource, .manuscript)
        XCTAssertEqual(results.matches[0].linePreview, "She walked to the kitchen.")
        XCTAssertEqual(results.matches[0].matchRangeInLine.length, 7)
    }

    func test_search_findsMultipleMatchesAcrossDocuments() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "kitchen scene one.\nkitchen scene two.\n"),
            ("chapter-2", "another kitchen.\nno match here.\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let engine = ProjectSearchEngine()
        let results = await engine.search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 3)
        XCTAssertEqual(results.documentCount, 2)
        // Sorted: chapter-1 lines 1,2 then chapter-2 line 1
        XCTAssertEqual(results.matches[0].documentPath, "manuscript/chapter-1.md")
        XCTAssertEqual(results.matches[0].lineNumber, 1)
        XCTAssertEqual(results.matches[1].lineNumber, 2)
        XCTAssertEqual(results.matches[2].documentPath, "manuscript/chapter-2.md")
    }

    func test_search_emptyQuery_returnsEmptyResults() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "some content\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let results = await ProjectSearchEngine().search(
            query: "", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 0)
        XCTAssertEqual(results.query, "")
    }

    func test_search_caseInsensitiveByDefault() async throws {
        let project = try makeProject(manuscript: [
            ("c", "Kitchen\nKITCHEN\nkitchen\n")
        ])
        let store = try await ProjectStore.load(from: project)

        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 3)
    }

    func test_search_findsInResearchNotes() async throws {
        let project = try makeProjectWithResearch(
            manuscript: [("c1", "kitchen\n")],
            research: [("sarah", "Sarah hates the kitchen.\n")])
        let store = try await ProjectStore.load(from: project)

        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 2)
        XCTAssertEqual(results.documentCount, 2)
        let manuscriptMatches = results.matches.filter { $0.documentSource == .manuscript }
        let researchMatches = results.matches.filter { $0.documentSource == .research }
        XCTAssertEqual(manuscriptMatches.count, 1)
        XCTAssertEqual(researchMatches.count, 1)
    }

    func test_search_caseSensitive_excludesMismatchedCase() async throws {
        let project = try makeProject(manuscript: [
            ("c", "Kitchen\nKITCHEN\nkitchen\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let options = SearchOptions(caseSensitive: true, wholeWord: false)
        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: options, in: store)

        XCTAssertEqual(results.matchCount, 1)
        XCTAssertEqual(results.matches[0].lineNumber, 3)
    }

    func test_search_wholeWord_excludesSubstringMatches() async throws {
        let project = try makeProject(manuscript: [
            ("c", "kitchenette is not it\nkitchen is\nfit kitchen there\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let options = SearchOptions(caseSensitive: false, wholeWord: true)
        let results = await ProjectSearchEngine().search(
            query: "kitchen", options: options, in: store)

        XCTAssertEqual(results.matchCount, 2,
            "expected kitchenette excluded (substring); kitchen lines 2 + 3 matched")
        XCTAssertEqual(results.matches[0].lineNumber, 2)
        XCTAssertEqual(results.matches[1].lineNumber, 3)
    }

    func test_search_regexSpecialCharsInQuery_treatedLiterally() async throws {
        let project = try makeProject(manuscript: [
            ("c", "a.b matches dot literal\nacb does not\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await ProjectSearchEngine().search(
            query: "a.b", options: SearchOptions(), in: store)

        XCTAssertEqual(results.matchCount, 1)
        XCTAssertEqual(results.matches[0].lineNumber, 1)
    }

    func test_store_performSearch_populatesCurrentSearch() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)

        await store.performSearch(query: "kitchen", options: SearchOptions())
        // Wait for debounce + execution
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNotNil(store.currentSearch)
        XCTAssertEqual(store.currentSearch?.matchCount, 1)
    }

    func test_store_clearSearch_resetsCurrentSearch() async throws {
        let project = try makeProject(manuscript: [
            ("chapter-1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)

        await store.performSearch(query: "kitchen", options: SearchOptions())
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotNil(store.currentSearch)

        store.clearSearch()
        XCTAssertNil(store.currentSearch)
    }
}
