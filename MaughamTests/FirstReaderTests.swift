import XCTest
@testable import Maugham
import MaughamCore

/// The first reader's substrate (two loops P2, Task 1): her NAME on the
/// manifest and her STATEMENT at the project root.
///
/// The two are deliberately separate things and are asserted separately here.
/// The name is metadata every surface that mentions her renders; the statement
/// is prose the writer edits in a pane. Clearing one must not touch the other.
@MainActor
final class FirstReaderTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func loadedNovel(named name: String) async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    // MARK: - The name

    /// CONTROL: a project starts with no first reader, and stays that way until
    /// the writer names one. There is no default — a reader the writer did not
    /// choose would be a stranger with opinions about their book.
    func test_aNewProjectHasNoFirstReader() async throws {
        let (_, store) = try await loadedNovel(named: "NoReaderYet")
        XCTAssertNil(store.manifest.firstReaderName)
    }

    /// The name is trimmed on the way in and survives a manifest round trip,
    /// like every other metadata verb in this store.
    func test_setFirstReaderName_trimsAndPersistsThroughAManifestRoundTrip() async throws {
        let (url, store) = try await loadedNovel(named: "NamedReader")

        try await store.setFirstReaderName("  Tabitha ")
        XCTAssertEqual(store.manifest.firstReaderName, "Tabitha",
                       "surrounding whitespace is not part of anybody's name")

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.firstReaderName, "Tabitha",
                       "the name must reach disk, not just the in-memory manifest")
    }

    /// **A blank is `nil`, not `""`.** Both would mean "no first reader", and
    /// two reachable states meaning one thing is how a surface comes to render
    /// an empty name where it meant to render nothing.
    func test_setFirstReaderName_mapsAnEmptyOrBlankNameToNil() async throws {
        let (url, store) = try await loadedNovel(named: "BlankReader")

        try await store.setFirstReaderName("Tabitha")
        XCTAssertEqual(store.manifest.firstReaderName, "Tabitha")

        try await store.setFirstReaderName("   ")
        XCTAssertNil(store.manifest.firstReaderName, "whitespace is not a name")

        try await store.setFirstReaderName("Tabitha")
        try await store.setFirstReaderName("")
        XCTAssertNil(store.manifest.firstReaderName)

        try await store.setFirstReaderName("Tabitha")
        try await store.setFirstReaderName(nil)
        XCTAssertNil(store.manifest.firstReaderName)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertNil(reloaded.manifest.firstReaderName,
                     "clearing must reach disk too")
    }

    /// Naming a reader is a project edit and moves the modified stamp, like
    /// `setCoachVacated` and `setReviewPasses` beside it.
    func test_setFirstReaderName_movesTheProjectsModifiedStamp() async throws {
        let (_, store) = try await loadedNovel(named: "ReaderStamp")
        let before = store.manifest.modified

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await store.setFirstReaderName("Tabitha")

        XCTAssertGreaterThan(store.manifest.modified, before)
    }

    // MARK: - The statement

    /// Her statement mints at the project root as `first-reader.md`, the way the
    /// ledger mints `lessons.md` — one file in the open, carried as an ordinary
    /// document from there on.
    func test_createStatement_mintsFirstReaderMdAtTheProjectRoot() async throws {
        let (url, store) = try await loadedNovel(named: "ReaderStatement")

        let created = try await store.createStatement(kind: .firstReader, scope: .project)

        XCTAssertEqual(created.path, "first-reader.md")
        XCTAssertEqual(created.kind, .firstReader)
        XCTAssertEqual(created.scope, .project)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("first-reader.md").path),
            "the mint must leave a real file, not just a manifest row")

        let again = try await store.createStatement(kind: .firstReader, scope: .project)
        XCTAssertEqual(again.id, created.id, "find-or-create must find before it creates")
        XCTAssertEqual(store.manifest.statements.filter { $0.kind == .firstReader }.count, 1)
    }

    /// CONTROL for the mint above: she is project-scope only. A per-chapter
    /// first reader would be a second reader wearing the first one's name, so
    /// the store refuses with the table's own error rather than minting one
    /// under a folder.
    func test_createStatement_refusesAFirstReaderAtDocumentScope() async throws {
        let (url, store) = try await loadedNovel(named: "ReaderScope")
        let chapter = try XCTUnwrap(store.manifest.structure.first)

        do {
            _ = try await store.createStatement(
                kind: .firstReader, scope: .document(chapter.id))
            XCTFail("expected a throw: the first reader is project-scope only")
        } catch let error as ProjectStoreError {
            guard case .statementHasNoStorage(let kind, _) = error else {
                return XCTFail("expected .statementHasNoStorage, got \(error)")
            }
            XCTAssertEqual(kind, "first_reader")
        }

        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "a refusal must register nothing")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("first-reader.md").path),
            "a refusal must reach no disk either")
    }

    /// The name and the statement are independent: clearing the name leaves her
    /// words alone. A reader who is unnamed is not a reader whose words are gone.
    func test_clearingTheNameLeavesHerStatementStanding() async throws {
        let (url, store) = try await loadedNovel(named: "ReaderIndependence")

        try await store.setFirstReaderName("Tabitha")
        let created = try await store.createStatement(kind: .firstReader, scope: .project)

        try await store.setFirstReaderName(nil)

        XCTAssertNil(store.manifest.firstReaderName)
        XCTAssertEqual(store.manifest.statements.first(where: { $0.kind == .firstReader })?.id,
                       created.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("first-reader.md").path))
    }
}
