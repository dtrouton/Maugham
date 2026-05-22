import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreEditorTextWriteTests: XCTestCase {

    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// Builds a real DocumentStore + ProjectStore pair via ProjectFactory.
    /// Returns both stores and the docId of the single document in the manifest.
    /// The doc isn't loaded as a Document; these tests exercise the helper's
    /// side-effects directly via `recordEditorTextWrite`, which doesn't need
    /// a Document instance.
    private func makeStores() async throws -> (
        documentStore: DocumentStore,
        store: ProjectStore,
        docId: String
    ) {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "DSETW-\(UUID().uuidString.prefix(8))",
            in: temp.url)
        let ds = try await DocumentStore.open(url: projectURL)
        let ps = try await ProjectStore.load(from: projectURL)
        // The manifest's first document item carries the auto-generated docId.
        let docId = ps.manifest.structure
            .first(where: { $0.type == .document })!.id
        return (ds, ps, docId)
    }

    func test_recordEditorTextWrite_updatesProjectWordCount() async throws {
        let (ds, ps, docId) = try await makeStores()
        // ProjectStore.load seeds the cache from the empty file → 0.
        XCTAssertEqual(ps.projectWordCount, 0)

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "Hello world.",
            mode: ProseMode(),
            store: ps)

        XCTAssertEqual(ps.projectWordCount, 2,
            "projectWordCount should reflect the 2 words in newText")
        await ds.close()
    }

    func test_recordEditorTextWrite_startsLiveSession() async throws {
        let (ds, ps, docId) = try await makeStores()

        XCTAssertNil(ds.currentSessionStart,
            "no session active before any text write")
        XCTAssertEqual(ds.liveSessionWordsNet, 0)

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "First sentence here.",
            mode: ProseMode(),
            store: ps)

        XCTAssertNotNil(ds.currentSessionStart,
            "first text write should start a session")
        await ds.close()
    }

    func test_recordEditorTextWrite_accumulatesAcrossEdits() async throws {
        let (ds, ps, docId) = try await makeStores()

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "One two three.",
            mode: ProseMode(),
            store: ps)
        let after3 = ps.projectWordCount

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "One two three four five six.",
            mode: ProseMode(),
            store: ps)
        let after6 = ps.projectWordCount

        XCTAssertEqual(after3, 3)
        XCTAssertEqual(after6, 6,
            "later writes overwrite the per-doc cache, not append")
        await ds.close()
    }

    func test_recordEditorTextWrite_liveSessionDeltaTracksGrowth() async throws {
        let (ds, ps, docId) = try await makeStores()

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "One.",
            mode: ProseMode(),
            store: ps)
        // First write seeds the session with startWordCount = 1, so the
        // delta should be 0 (no growth yet — the session started with this
        // word count). Confirmed by SessionTrackerTests: startWordCount is
        // captured on the FIRST call only and stays fixed for subsequent
        // calls until the session ends.
        XCTAssertEqual(ds.liveSessionWordsNet, 0,
            "first write establishes the session baseline; delta is 0")

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "One two three four five.",
            mode: ProseMode(),
            store: ps)
        XCTAssertEqual(ds.liveSessionWordsNet, 4,
            "second write added 4 words on top of the seeded baseline of 1")
        await ds.close()
    }

    func test_recordEditorTextWrite_screenplayWordCountSameAsProse() async throws {
        // Spot-check that ScreenplayMode's metrics produce the same word
        // count for plain text as ProseMode would — they should, because
        // the screenplay parser still counts words by whitespace.
        let (ds, ps, docId) = try await makeStores()

        ds.recordEditorTextWrite(
            documentId: docId,
            newText: "Hello world.",
            mode: ScreenplayMode(),
            store: ps)
        XCTAssertEqual(ps.projectWordCount, 2)
        await ds.close()
    }
}
