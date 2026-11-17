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

    // MARK: - Replace refuses when the occurrences changed since the search (final fix wave)

    /// The writer's edit of `slug`, made through the document (the op log),
    /// as typing makes it.
    private func edit(_ project: URL, _ slug: String, to text: String) async throws {
        let doc = try await Document.load(
            url: project.appendingPathComponent("manuscript/\(slug).md"),
            device: "test", session: "edit", presenter: nil)
        doc.setFullText(text)
        await doc.close()
    }

    /// `match` is refused as stale; `slug` holds exactly `edited` (the
    /// writer's edit, untouched by Replace); and the refusal refreshed the
    /// results to `fresh` matches, none of them the clicked one.
    private func assertReplaceIsRefused(
        _ match: SearchMatch, _ store: ProjectStore, _ project: URL, _ slug: String,
        leaving edited: String, fresh: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            try await store.replaceMatch(match, with: "Z")
            XCTFail("a Replace whose occurrences changed since the search must be refused",
                    file: file, line: line)
        } catch ProjectStoreError.staleSearchMatch {}
        let text = try await displayText(of: project, slug)
        XCTAssertEqual(text, edited, "Replace wrote nothing", file: file, line: line)
        let listedNow = listed(store, slug)
        XCTAssertEqual(listedNow.count, fresh, "the refusal refreshed the results", file: file, line: line)
        XCTAssertTrue(listedNow.allSatisfy { $0.id != match.id }, file: file, line: line)
    }

    /// One more "Anna." typed before the clicked (second) one: ordinal 1 now
    /// names the line just typed — the same words, so only the count tells.
    func test_replaceAfterAnOccurrenceWasAddedBeforeTheClickedOneIsRefused() async throws {
        let project = try await makeProject(manuscript: [("c1", "Anna.\nAnna.\n")])
        let store = try await ProjectStore.load(from: project)
        let matches = listedAfterSearch(await search(store, "Anna"))
        XCTAssertEqual(matches.count, 2)
        try await edit(project, "c1", to: "Anna.\nAnna.\nAnna.")

        try await assertReplaceIsRefused(matches[1], store, project, "c1",
                                         leaving: "Anna.\nAnna.\nAnna.", fresh: 3)
    }

    /// One occurrence added before the clicked one and one removed after
    /// it: the count is as the search found it, but ordinal 1 now names a
    /// line the result never showed.
    func test_replaceAfterOneOccurrenceWasAddedAndAnotherRemovedIsRefused() async throws {
        let project = try await makeProject(manuscript: [("c1", "Anna one.\nAnna two.\nAnna three.\n")])
        let store = try await ProjectStore.load(from: project)
        let matches = listedAfterSearch(await search(store, "Anna"))
        XCTAssertEqual(matches.count, 3)
        let edited = "Anna one.\nAnna new.\nAnna two.\nBob three."
        try await edit(project, "c1", to: edited)

        try await assertReplaceIsRefused(matches[1], store, project, "c1", leaving: edited, fresh: 3)
    }

    /// The control: a line typed above moves every offset and line number
    /// but neither adds nor removes an occurrence and leaves the clicked
    /// line alone, so the clicked occurrence is replaced.
    func test_replaceAfterAnEditThatLeavesTheOccurrencesAloneStillReplacesTheClickedOne() async throws {
        let project = try await makeProject(manuscript: [("c1", "Anna one.\nAnna two.\n")])
        let store = try await ProjectStore.load(from: project)
        let matches = listedAfterSearch(await search(store, "Anna"))
        XCTAssertEqual(matches.count, 2)
        try await edit(project, "c1", to: "Prologue.\nAnna one.\nAnna two.")

        try await store.replaceMatch(matches[1], with: "Z")

        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "Prologue.\nAnna one.\nZ two.")
    }

    /// `results`' matches, left to right.
    private func listedAfterSearch(_ results: SearchResults) -> [SearchMatch] {
        results.matches.sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
    }

    // MARK: - Replace All takes its turn and refreshes (fix round 1)

    /// **A single Replace of an old match after Replace All is refused**:
    /// Replace All leaves the results fresh, so a match from before it —
    /// here one whose occurrence now sits inside a replacement that holds
    /// the query — says "search again" and changes nothing.
    func test_aSingleReplaceOfAnOldMatchAfterReplaceAllIsRefused() async throws {
        let project = try await makeProject(manuscript: [("c1", "Tom met Tom.\n")])
        let store = try await ProjectStore.load(from: project)
        let results = await search(store, "Tom")
        let old = results.matches
            .sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
        XCTAssertEqual(old.count, 2)

        try await store.replaceAll(in: results, with: "Tommy")

        XCTAssertEqual(listed(store, "c1").map(\.charRangeInDocument.location), [0, 10],
                       "the results are fresh when Replace All returns")
        do {
            try await store.replaceMatch(old[1], with: "Tommy")
            XCTFail("a match from before Replace All must be refused")
        } catch ProjectStoreError.staleSearchMatch {}
        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "Tommy met Tommy.", "the text is as Replace All left it")
    }

    /// **Replace All and a single Replace issued together run in turn**,
    /// in the order issued, and neither is dropped silently: the single
    /// Replace, judged after Replace All, finds its match gone and says so.
    func test_replaceAllAndASingleReplaceIssuedTogetherRunInTurn() async throws {
        let project = try await makeProject(manuscript: [("c1", "Tom met Tom.\n")])
        let store = try await ProjectStore.load(from: project)
        let results = await search(store, "Tom")
        let second = try XCTUnwrap(results.matches
            .max { $0.charRangeInDocument.location < $1.charRangeInDocument.location })

        let all = Task { try await store.replaceAll(in: results, with: "Tommy") }
        let single = Task { () -> Bool in
            do {
                try await store.replaceMatch(second, with: "Tommy")
                return true
            } catch ProjectStoreError.staleSearchMatch {
                return false
            }
        }
        let outcome = try await all.value
        let singleLanded = try await single.value

        XCTAssertEqual(outcome.leftAlone, [])
        XCTAssertFalse(singleLanded, "the single Replace ran after Replace All and was refused")
        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "Tommy met Tommy.")
    }

    // MARK: - A click from before a refresh finds its match (#147 R1)

    /// **A Replace in one document leaves another document's matches
    /// clickable** (#147 R1): every Replace refreshes the results and mints
    /// new ids, but a match still shown for an untouched document is the
    /// same occurrence — same path, range and line — so it is replaced,
    /// not refused with "That match has changed".
    func test_aMatchInAnotherDocumentStillHeldAfterAReplaceIsReplaced() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "fog in the hall\n"),
            ("c2", "the fog lifts\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await search(store, "fog").matches
        let inC1 = try XCTUnwrap(matches.first { $0.documentPath == "manuscript/c1.md" })
        let inC2 = try XCTUnwrap(matches.first { $0.documentPath == "manuscript/c2.md" })

        try await store.replaceMatch(inC1, with: "mist")
        XCTAssertFalse((store.currentSearch?.matches ?? []).contains { $0.id == inC2.id },
                       "the premise: the Replace refreshed the results, so c2's old id is gone")

        try await store.replaceMatch(inC2, with: "mist")

        let c1 = try await displayText(of: project, "c1")
        let c2 = try await displayText(of: project, "c2")
        XCTAssertEqual(c1, "mist in the hall")
        XCTAssertEqual(c2, "the mist lifts")
        XCTAssertEqual(store.currentSearch?.matches.count, 0, "the results are fresh")
    }

    /// **Review Focus 3: the fallback never picks a different occurrence.**
    /// Two matches on identical lines in one file differ only by range; the
    /// old click on the second is the second, never the first.
    func test_theFallbackForAMatchOnARepeatedLinePicksTheOneWithTheSameRange() async throws {
        let project = try await makeProject(manuscript: [
            ("c1", "Anna in the hall.\n"),
            ("c2", "Anna.\nAnna.\n")
        ])
        let store = try await ProjectStore.load(from: project)
        let matches = await search(store, "Anna").matches
        let inC1 = try XCTUnwrap(matches.first { $0.documentPath == "manuscript/c1.md" })
        let inC2 = matches.filter { $0.documentPath == "manuscript/c2.md" }
            .sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
        XCTAssertEqual(inC2.count, 2)
        XCTAssertEqual(inC2[0].linePreview, inC2[1].linePreview, "the premise: identical lines")

        try await store.replaceMatch(inC1, with: "Z")
        try await store.replaceMatch(inC2[1], with: "Z")

        let c2 = try await displayText(of: project, "c2")
        XCTAssertEqual(c2, "Anna.\nZ.", "the second occurrence was replaced, never the first")
    }

    /// **A refusal refreshes the results** (#147 R1): a click whose id is
    /// gone and whose occurrence has moved is refused, and the results it
    /// leaves are freshly searched — the same refresh a Replace runs.
    func test_aRefusedStaleClickRefreshesTheResults() async throws {
        let project = try await makeProject(manuscript: [("c1", "fog one\n")])
        let store = try await ProjectStore.load(from: project)
        let found = await search(store, "fog").matches
        let old = try XCTUnwrap(found.first)
        try await edit(project, "c1", to: "Prologue.\nfog one")
        // The results the window shows were searched again since the click's
        // results (typing's search): the old id is gone, the occurrence moved.
        _ = await search(store, "fog")
        let shownBefore = Set((store.currentSearch?.matches ?? []).map(\.id))

        do {
            try await store.replaceMatch(old, with: "Z")
            XCTFail("a click whose occurrence moved must be refused")
        } catch ProjectStoreError.staleSearchMatch {}

        let shownAfter = Set((store.currentSearch?.matches ?? []).map(\.id))
        XCTAssertEqual(shownAfter.count, 1)
        XCTAssertTrue(shownAfter.isDisjoint(with: shownBefore), "the refusal refreshed the results")
        let text = try await displayText(of: project, "c1")
        XCTAssertEqual(text, "Prologue.\nfog one", "a refused Replace writes nothing")
    }

    // MARK: - Which search lands (fix round 1)

    /// **An older, slower search that finishes after a newer one is
    /// dropped**: `currentSearch` keeps the newer results.
    func test_anOlderSearchFinishingAfterANewerOneIsDropped() async throws {
        let project = try await makeProject(manuscript: [("c1", "fog and rain\n")])
        let store = try await ProjectStore.load(from: project)
        let gate = SearchGate(holding: "fog")
        store.searchWillLandForTesting = { await gate.pass($0) }

        let older = Task { await store.searchNow(query: "fog", options: SearchOptions()) }
        await gate.untilHeld()
        await store.searchNow(query: "rain", options: SearchOptions())
        XCTAssertEqual(store.currentSearch?.query, "rain")
        gate.release()
        await older.value

        XCTAssertEqual(store.currentSearch?.query, "rain", "the older search did not land over the newer")
    }

    /// **`clearSearch` drops a search still in flight**: closing the
    /// overlay leaves no results behind, whenever that search finishes.
    func test_clearSearchDropsASearchStillInFlight() async throws {
        let project = try await makeProject(manuscript: [("c1", "fog and rain\n")])
        let store = try await ProjectStore.load(from: project)
        let gate = SearchGate(holding: "fog")
        store.searchWillLandForTesting = { await gate.pass($0) }

        let inFlight = Task { await store.searchNow(query: "fog", options: SearchOptions()) }
        await gate.untilHeld()
        store.clearSearch()
        gate.release()
        await inFlight.value

        XCTAssertNil(store.currentSearch, "a search started before the close did not land after it")
    }

    /// **A Replace's refresh is not overwritten by a debounced search that
    /// was already in flight when the Replace began** — one that read the
    /// text before the write and finishes after the refresh.
    func test_aReplacesRefreshIsNotOverwrittenByAnEarlierDebouncedSearch() async throws {
        let project = try await makeProject(manuscript: [("c1", "fog one fog two fog three\n")])
        let store = try await ProjectStore.load(from: project)
        let matches = await search(store, "fog").matches
            .sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
        let gate = SearchGate(holding: "fog", times: 1)
        store.searchWillLandForTesting = { await gate.pass($0) }

        await store.performSearch(query: "fog", options: SearchOptions())
        await gate.untilHeld()   // the debounced search has read the old text
        try await store.replaceMatch(matches[0], with: "mist!!")
        XCTAssertEqual(listed(store, "c1").map(\.charRangeInDocument.location), [11, 19])
        gate.release()
        await store.searchTask?.value

        XCTAssertEqual(listed(store, "c1").map(\.charRangeInDocument.location), [11, 19],
                       "the debounced search that read the old text did not land over the refresh")
        XCTAssertFalse(store.searchInProgress)
    }
}

/// Holds the first `times` searches for `query` just before they land,
/// until `release()`; `untilHeld()` returns once one is held. Main-actor
/// only, so no step races another.
@MainActor
private final class SearchGate {
    private let query: String
    private var remaining: Int
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var arrived = false

    init(holding query: String, times: Int = 1) {
        self.query = query
        self.remaining = times
    }

    func pass(_ searched: String) async {
        guard searched == query, remaining > 0 else { return }
        remaining -= 1
        arrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { held = $0 }
    }

    func untilHeld() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
