import XCTest
import MaughamCore
@testable import Maugham

/// Integration coverage for Task 2.2: Find-Replace must route manuscript
/// edits THROUGH the op log (the source of truth), not raw-write the `.md`.
///
/// Before this fix `replaceMatch`/`replaceAll` spliced bytes straight into
/// the `.md` and `.write(to:atomically:)`, bypassing the op log entirely
/// (so the change was invisible to ops and clobbered on re-render) AND
/// racing the 750ms autosave on any open document. These tests pin the
/// contract: closed docs go through `Document.load` -> `setFullText` ->
/// persist; open docs apply via the live `Document`; the `.md` and op log
/// never diverge.
@MainActor
final class FindReplaceOpLogTests: XCTestCase {

    /// Build a temp Novel project with a single manuscript doc.
    /// The `.md` is written WITHOUT inline ¶id anchors; `Document.load`
    /// bootstraps it (minting anchors) the first time it's loaded.
    private func makeProject(
        body: String, slug: String = "c1"
    ) throws -> (project: URL, docPath: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindReplaceOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/\(slug).md"
        try body.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-\(slug)", title: slug, type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    /// Build a project whose manuscript doc is ALREADY bootstrapped: the `.md`
    /// carries the given (id, text) paragraphs as canonical anchored content,
    /// AND the op log holds a matching `.bootstrap` op capturing every
    /// paragraph's initial text. This mirrors how a real doc reaches disk
    /// (the editor's first load bootstraps it) — without it, a partial change
    /// to a doc that has no bootstrap op loses the unchanged paragraphs at
    /// re-derive (they never appear in any op's `changes`). Lets a test choose
    /// paragraph ids so a query can collide with an anchor substring.
    private func makeBootstrappedProject(
        paragraphs: [(id: String, text: String)], slug: String = "c1"
    ) async throws -> (project: URL, docPath: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindReplaceOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/\(slug).md"

        var map: [String: String] = [:]
        var sequence: [String] = []
        var changes: [Op.ParagraphChange] = []
        for p in paragraphs {
            map[p.id] = p.text
            sequence.append(p.id)
            changes.append(.init(paragraphId: p.id, prior: nil, next: p.text))
        }
        let stored = Materializer.materialize(paragraphs: map, sequence: sequence)
        try stored.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))

        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-\(slug)", title: slug, type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // Seed the bootstrap op so the doc is properly tracked.
        let docId = try resolveDocId(for: tmp.appendingPathComponent(docPath))
        let op = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: "bootstrap", session: "bootstrap", kind: .bootstrap,
            changes: changes, sequence: sequence, provenance: nil)
        try await OpLogStore(projectURL: tmp).append(op)
        return (tmp, docPath)
    }

    /// replaceAll on a CLOSED document (no DocumentStore registry entry)
    /// must persist via the op log: a fresh `Document.load` after the
    /// replacement sees the new text, and the op log carries a typing_burst
    /// op (proving it went through ops, not a raw byte-splice).
    func test_replaceAll_closedDoc_goesThroughOpLog_and_survivesReload() async throws {
        let (project, docPath) = try makeProject(
            body: "The cat sat.\n\nThe cat ran.\n")
        let store = try await ProjectStore.load(from: project)
        XCTAssertNil(store.documentStore,
            "Precondition: doc is closed (no DocumentStore registry).")

        await store.performSearch(query: "cat", options: SearchOptions())
        // performSearch debounces 300ms + runs async; wait for it to land.
        try await pollUntil { store.currentSearch?.matchCount == 2 }
        let results = try XCTUnwrap(store.currentSearch)
        XCTAssertEqual(results.matchCount, 2)

        try await store.replaceAll(in: results, with: "dog")

        // The op log must now carry a typing_burst op for this doc.
        let docId = try resolveDocId(
            for: project.appendingPathComponent(docPath))
        let opStore = OpLogStore(projectURL: project)
        let ops = try await opStore.load(docId: docId)
        XCTAssertTrue(ops.contains { $0.kind == .typingBurst },
            "replaceAll must append a typing_burst op (went through the op log).")

        // A FRESH load must reflect the replacement in display form.
        let reloaded = try await Document.load(
            url: project.appendingPathComponent(docPath),
            device: "verify", session: "verify", presenter: nil)
        XCTAssertTrue(reloaded.displayText.contains("dog"),
            "Reloaded displayText should contain the replacement.")
        XCTAssertFalse(reloaded.displayText.contains("cat"),
            "Reloaded displayText should no longer contain the original.")
    }

    /// replaceMatch on an OPEN document (in the DocumentStore registry) must
    /// mutate the live Document so the editor reflects it immediately, and
    /// (after flushBurstNow) the op log carries the change.
    func test_replaceMatch_openDoc_reflectsImmediately_andRecordsOp() async throws {
        let (project, docPath) = try makeProject(
            body: "The cat sat.\n\nThe cat ran.\n")
        let store = try await ProjectStore.load(from: project)

        // Open the doc through the DocumentStore so it's in the registry.
        let ds = try await DocumentStore.open(url: project)
        store.documentStore = ds
        let doc = try await Document.load(
            url: project.appendingPathComponent(docPath),
            device: "editor", session: "editor",
            presenter: ds.presenter)
        ds.register(document: doc, for: docPath)
        let docId = doc.docId

        await store.performSearch(query: "cat", options: SearchOptions())
        try await pollUntil { store.currentSearch?.matchCount == 2 }
        let results = try XCTUnwrap(store.currentSearch)
        XCTAssertEqual(results.matchCount, 2)

        // Replace the FIRST occurrence only.
        let first = results.matches
            .filter { $0.documentPath == docPath }
            .min { $0.charRangeInDocument.location < $1.charRangeInDocument.location }!
        try await store.replaceMatch(first, with: "dog")

        // The LIVE document reflects the replacement immediately.
        XCTAssertTrue(doc.displayText.contains("dog"),
            "Open doc should reflect the replacement immediately.")
        // Only the first "cat" replaced — one "cat" remains.
        let catCount = doc.displayText.components(separatedBy: "cat").count - 1
        XCTAssertEqual(catCount, 1,
            "Exactly one occurrence should have been replaced.")

        // After flushing the burst, the op log carries the change.
        try await doc.flushBurstNow()
        let opStore = OpLogStore(projectURL: project)
        let ops = try await opStore.load(docId: docId)
        XCTAssertTrue(ops.contains { $0.kind == .typingBurst },
            "replaceMatch on an open doc must record a typing_burst op.")

        await doc.close()
        ds.unregister(path: docPath)
        await ds.close()
    }

    /// Regression for the anchor-substring bug: a BOOTSTRAPPED doc (anchors
    /// present in the stored `.md`) whose paragraph id contains the search
    /// substring must NOT surface an anchor-internal match, and replace must
    /// hit the correct BODY occurrence — never the invisible anchor.
    ///
    /// Id `abcd` is a valid 4-char ParagraphID; querying "abc" matches inside
    /// `<!-- ¶abcd -->` in the RAW stored bytes. Against the old raw-bytes
    /// search this anchor match shifts every body ordinal (and has no
    /// display-form counterpart), so replaceMatch hit the wrong occurrence or
    /// threw "Match range out of bounds". After the fix the engine searches
    /// display form, so only the two body "abc" occurrences exist.
    func test_search_doesNotMatchInsideParagraphAnchors_andReplaceHitsBody() async throws {
        // Properly bootstrapped doc. The first paragraph's id is `abcd` — its
        // anchor `<!-- ¶abcd -->` contains the query substring "abc".
        let (project, docPath) = try await makeBootstrappedProject(paragraphs: [
            (id: "abcd", text: "The abc word here."),
            (id: "mnpq", text: "Another abc line."),
        ])
        let store = try await ProjectStore.load(from: project)

        await store.performSearch(query: "abc", options: SearchOptions())
        try await pollUntil { store.currentSearch != nil }
        let results = try XCTUnwrap(store.currentSearch)

        // Exactly TWO body matches — the anchor-internal "abc" is invisible.
        XCTAssertEqual(results.matchCount, 2,
            "Anchor-internal 'abc' (inside <!-- ¶abcd -->) must not be matched.")
        for m in results.matches {
            XCTAssertFalse(m.linePreview.contains("¶"),
                "No match preview should be an anchor line: \(m.linePreview)")
        }

        // Replace the FIRST (body) occurrence only.
        let first = results.matches
            .min { $0.charRangeInDocument.location
                < $1.charRangeInDocument.location }!
        try await store.replaceMatch(first, with: "XYZ")

        let reloaded = try await Document.load(
            url: project.appendingPathComponent(docPath),
            device: "verify", session: "verify", presenter: nil)
        // First body "abc" → "XYZ"; second body "abc" untouched; both
        // paragraphs survive.
        XCTAssertTrue(reloaded.displayText.contains("The XYZ word here."),
            "First body occurrence should be replaced. Got: \(reloaded.displayText)")
        XCTAssertTrue(reloaded.displayText.contains("Another abc line."),
            "Second body occurrence should be untouched. Got: \(reloaded.displayText)")
        // The paragraph id `abcd` must survive (anchor not corrupted by the edit).
        XCTAssertTrue(reloaded.materialize().contains("¶abcd"),
            "Paragraph anchor must be intact after replace.")
    }

    /// Same collision, but replaceAll: both BODY occurrences replaced, the
    /// anchor-internal substring never touched.
    func test_replaceAll_doesNotTouchAnchorSubstring() async throws {
        let (project, docPath) = try await makeBootstrappedProject(paragraphs: [
            (id: "abcd", text: "The abc word here."),
            (id: "mnpq", text: "Another abc line."),
        ])
        let store = try await ProjectStore.load(from: project)

        await store.performSearch(query: "abc", options: SearchOptions())
        try await pollUntil { store.currentSearch?.matchCount == 2 }
        let results = try XCTUnwrap(store.currentSearch)
        XCTAssertEqual(results.matchCount, 2)

        try await store.replaceAll(in: results, with: "XYZ")

        let reloaded = try await Document.load(
            url: project.appendingPathComponent(docPath),
            device: "verify", session: "verify", presenter: nil)
        XCTAssertTrue(reloaded.displayText.contains("The XYZ word here."))
        XCTAssertTrue(reloaded.displayText.contains("Another XYZ line."))
        XCTAssertFalse(reloaded.displayText.contains("abc"))
        // Anchor id `abcd` intact — its "abc" substring was never a match.
        XCTAssertTrue(reloaded.materialize().contains("¶abcd"))
    }

    /// Poll a predicate up to ~3s, yielding between checks. Used because
    /// `performSearch` debounces + runs on a detached Task.
    private func pollUntil(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 3.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("pollUntil timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
