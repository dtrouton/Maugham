import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectSearchReplaceTests: XCTestCase {
    /// ADR 0018: each doc is bootstrapped via Document.load so the op log is
    /// seeded before search runs — search reads from the op log, not the .md.
    private func makeProject(manuscript: [(String, String)]) async throws -> URL {
        let tmp = TestTemp.root
            .appendingPathComponent("SearchReplace-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        var structure: [StructureItem] = []
        for (slug, content) in manuscript {
            let docURL = tmp.appendingPathComponent("manuscript/\(slug).md")
            try content.write(to: docURL, atomically: true, encoding: .utf8)
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
        // Bootstrap each doc so the op log is populated before search runs.
        for (slug, _) in manuscript {
            let docURL = tmp.appendingPathComponent("manuscript/\(slug).md")
            _ = try await Document.load(
                url: docURL, device: "test", session: "s", presenter: nil)
        }
        return tmp
    }

    /// Replacements route through the op log (the source of truth), so the
    /// on-disk `.md` becomes anchored. These tests assert on the DISPLAY form
    /// recovered via a fresh `Document.load`, not exact disk bytes. The search
    /// must be primed via `performSearch` first (matching the real UI), since
    /// `replaceMatch` derives the target occurrence ordinal + query from
    /// `currentSearch`.
    private func displayText(of project: URL, _ slug: String) async throws -> String {
        let doc = try await Document.load(
            url: project.appendingPathComponent("manuscript/\(slug).md"),
            device: "verify", session: "verify", presenter: nil)
        return doc.displayText
    }

    private func search(
        _ store: ProjectStore, _ query: String,
        options: SearchOptions = SearchOptions()
    ) async -> SearchResults {
        let results = await ProjectSearchEngine().search(
            query: query, options: options, in: store)
        // Prime currentSearch so replaceMatch can derive ordinal + query.
        store.currentSearch = results
        return results
    }

    func test_replaceMatch_writesNewContentToDisk() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await search(store, "kitchen").matches
        XCTAssertEqual(matches.count, 1)

        try await store.replaceMatch(matches[0], with: "library")

        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "the library is empty")
    }

    func test_replaceMatch_withEmptyString_deletesMatch() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "the kitchen is empty\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await search(store, "kitchen ").matches
        XCTAssertEqual(matches.count, 1)

        try await store.replaceMatch(matches[0], with: "")

        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "the is empty")
    }

    func test_replaceAll_replacesAllMatchesPerDoc() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "kitchen here\nand kitchen there\n"),
            ("c2", "no kitchen anywhere\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await search(store, "kitchen")
        XCTAssertEqual(results.matchCount, 3)

        try await store.replaceAll(in: results, with: "library")

        let c1 = try await displayText(of: project, "c1")
        let c2 = try await displayText(of: project, "c2")
        XCTAssertEqual(c1, "library here\nand library there")
        XCTAssertEqual(c2, "no library anywhere")
    }

    func test_replaceAll_rightToLeftOrderPreservesOffsets() async throws {
        // Multiple matches on the same line; the op-log path re-finds and
        // replaces all occurrences (right-to-left internally) so longer
        // replacements don't corrupt later matches.
        let project = try await makeProject(manuscript: [
            ("c1", "ab ab ab\n")  // 3 matches of "ab"
        ])
        let store = try await ProjectStore.load(from: project)
        let results = await search(store, "ab")
        XCTAssertEqual(results.matchCount, 3)

        try await store.replaceAll(in: results, with: "XYZ")  // longer than "ab"

        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "XYZ XYZ XYZ")
    }

    /// The matches `store.currentSearch` lists for `slug`, left to right.
    private func listed(_ store: ProjectStore, _ slug: String) -> [SearchMatch] {
        (store.currentSearch?.matches ?? [])
            .filter { $0.documentPath == "manuscript/\(slug).md" }
            .sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
    }

    /// **A single Replace leaves the results fresh, and a stale match is
    /// refused** (#141 follow-up): once the first Replace returns,
    /// `currentSearch` lists what the text holds now; the SAME match value
    /// clicked again — and any other match from the old list — finds its id
    /// gone and says "search again", never hitting the following occurrence;
    /// the match the fresh results list second replaces that one.
    /// `ResearchNoteWritersTests.test_aSecondReplaceOfTheSameStaleMatchInANoteIsRefused_andAFreshMatchLands`
    /// is the research arm's mirror.
    func test_aSecondReplaceOfTheSameStaleMatchIsRefused_andAFreshMatchLands() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "fog one fog two fog three\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await search(store, "fog").matches
            .sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
        XCTAssertEqual(matches.count, 3)

        try await store.replaceMatch(matches[0], with: "mist!!")

        let fresh = listed(store, "c1")
        XCTAssertEqual(fresh.map(\.charRangeInDocument.location), [11, 19],
                       "the results are fresh when the Replace returns")
        XCTAssertTrue(Set(fresh.map(\.id)).isDisjoint(with: matches.map(\.id)))

        for stale in [matches[0], matches[1]] {
            do {
                try await store.replaceMatch(stale, with: "mist!!")
                XCTFail("a match from the old results must be refused")
            } catch ProjectStoreError.staleSearchMatch {
                XCTAssertEqual(ProjectStoreError.staleSearchMatch.localizedDescription,
                               "That match has changed. Search again.")
            }
        }
        let afterRefusals = try await displayText(of: project, "c1")
        XCTAssertEqual(afterRefusals, "mist!! one fog two fog three", "a refused Replace writes nothing")

        try await store.replaceMatch(fresh[1], with: "mist!!")

        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "mist!! one fog two mist!! three")
    }

    /// **Replace clicked twice quickly on the same match** (Review Focus 5):
    /// two presses in flight at once, as two quick clicks make them. One
    /// lands; the other finds the match gone and says so — it never
    /// replaces the next occurrence.
    func test_replaceClickedTwiceQuicklyOnTheSameMatchReplacesOnce() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "fog one fog two fog three\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let found = await search(store, "fog").matches
        let first = try XCTUnwrap(found.min {
            $0.charRangeInDocument.location < $1.charRangeInDocument.location })

        func press() async -> Bool {
            do {
                try await store.replaceMatch(first, with: "mist!!")
                return true
            } catch ProjectStoreError.staleSearchMatch {
                return false
            } catch {
                XCTFail("unexpected: \(error)")
                return false
            }
        }
        let one = Task { await press() }
        let two = Task { await press() }
        let landed = [await one.value, await two.value]

        XCTAssertEqual(landed.filter { $0 }.count, 1, "one press lands, one is refused: \(landed)")
        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "mist!! one fog two fog three")
    }
}
