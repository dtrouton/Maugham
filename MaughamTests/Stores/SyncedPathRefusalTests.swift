import XCTest
import MaughamCore
@testable import Maugham

/// **A synced manifest that names a path outside the project** (report plan
/// 6b Task 2, Review Focus 1; tripwire 58). A structure item, a research note
/// and a statement each say `../outside.md`: every verb that would read,
/// write, move, copy or delete through that path refuses, the writer's
/// `outside.md` beside the project is never touched, nothing new appears
/// beside the project, and the project still opens.
@MainActor
final class SyncedPathRefusalTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var outside: URL!
    private let outsideText = "OUTSIDE: the writer's own file, beside the book\n"
    private let escaping = "../outside.md"

    override func setUp() async throws {
        try await super.setUp()
        base = TestTemp.root.appendingPathComponent("synced-path-\(UUID().uuidString)")
        project = base.appendingPathComponent("Book")
        outside = base.appendingPathComponent("outside.md")
        let fm = FileManager.default
        try fm.createDirectory(
            at: project.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try outsideText.write(to: outside, atomically: true, encoding: .utf8)
        try Data().write(to: project.appendingPathComponent("manuscript/01-good.md"))
        let manifest = ProjectManifest(
            type: .novel, title: "Book", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-good", title: "Good", type: .document,
                              path: "manuscript/01-good.md"),
                StructureItem(id: "doc-evil", title: "Evil", type: .document, path: escaping),
            ],
            research: [
                ResearchItem(id: "res-evil", title: "Evil Note", type: .asset,
                             kind: .document, path: escaping),
            ],
            statements: [
                Statement(id: "stmt-evil", kind: .intent, scope: .project, path: escaping),
            ])
        try ProjectManifest.encodeForDisk(manifest)
            .write(to: project.appendingPathComponent(ProjectManifest.fileName))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        try await super.tearDown()
    }

    private func open() async throws -> (ProjectStore, DocumentStore) {
        let store = try await ProjectStore.load(from: project)
        let documents = try await DocumentStore.open(url: project)
        store.documentStore = documents
        return (store, documents)
    }

    /// `outside.md` holds exactly what it held, and nothing else appeared
    /// beside the project (no copy, no renamed file, no folder).
    private func assertOutsideUntouched(
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), outsideText,
                       message, file: file, line: line)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: base.path)),
            ["Book", "outside.md"], message, file: file, line: line)
    }

    private func assertRefusedAsUnsafe(
        _ error: Error, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case ProjectStoreError.unsafeProjectPath = error else {
            return XCTFail("expected .unsafeProjectPath, got \(error)", file: file, line: line)
        }
    }

    func test_theProjectStillOpens() async throws {
        let (store, documents) = try await open()
        withExtendedLifetime(documents) {}
        XCTAssertEqual(store.manifest.structure.map(\.id), ["doc-good", "doc-evil"])
        XCTAssertEqual(store.manifest.research.map(\.id), ["res-evil"])
        try assertOutsideUntouched("opening the project")
    }

    func test_renamingTheEscapingPieceIsRefused() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        do {
            _ = try await store.renameStructureItem(id: "doc-evil", newTitle: "Renamed")
            XCTFail("a rename through ../outside.md must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        try assertOutsideUntouched("rename")
    }

    /// Renaming an ordinary piece rewrites wiki links in every research note
    /// and piece: the escaping ones are skipped, not written.
    func test_aRenameElsewhereSkipsTheEscapingNoteAndPiece() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        _ = try await store.renameStructureItem(id: "doc-good", newTitle: "Better")
        try assertOutsideUntouched("a rename's wiki-link rewrite")
    }

    func test_duplicatingTheEscapingPieceOrNoteIsRefused() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        do {
            _ = try await store.duplicateStructureItem(id: "doc-evil")
            XCTFail("a duplicate of ../outside.md must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        do {
            _ = try await store.duplicateResearchItem(id: "res-evil")
            XCTFail("a duplicate of a research note at ../outside.md must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        try assertOutsideUntouched("duplicate")
    }

    func test_renamingTheEscapingNoteIsRefused() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        do {
            try await store.updateResearchItem(id: "res-evil", title: "Renamed Note")
            XCTFail("a research rename through ../outside.md must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        try assertOutsideUntouched("research rename")
    }

    func test_researchReplaceIsRefused() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        let match = SearchMatch(
            documentPath: escaping, documentTitle: "Evil Note", documentSource: .research,
            lineNumber: 1, charRangeInDocument: NSRange(location: 0, length: 7),
            linePreview: outsideText, matchRangeInLine: NSRange(location: 0, length: 7))
        do {
            _ = try await store.replaceAll(
                in: SearchResults(query: "OUTSIDE", options: SearchOptions(), matches: [match]),
                with: "REPLACED")
            XCTFail("a replace in ../outside.md must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        try assertOutsideUntouched("research replace")
    }

    func test_deletingTheEscapingStatementIsRefused() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        let statement = try XCTUnwrap(store.manifest.statements.first { $0.id == "stmt-evil" })
        let rolledBack = await store.rollbackUnusedStatement(statement)
        XCTAssertFalse(rolledBack, "a statement at ../outside.md is never deleted")
        try assertOutsideUntouched("statement delete")
    }

    /// The editor's load of the escaping piece refuses before it reads or
    /// bootstraps — `Bootstrap.run` would write its anchored `.md` there — so
    /// no autosave of that path can ever run.
    func test_loadingTheEscapingPieceIsRefusedSoNothingAutosavesThere() async throws {
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        do {
            _ = try await Document.load(
                url: project.appendingPathComponent(escaping), actor: .author,
                session: "synced-path", presenter: documents.presenter)
            XCTFail("a load of ../outside.md must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        XCTAssertThrowsError(try store.resolvedProjectPath(escaping))
        try assertOutsideUntouched("load / autosave")
    }

    /// A research note's debounced save to the escaping path is refused on
    /// every save and logged once, not once per typing pause.
    func test_aResearchNoteSaveIsRefusedAndLoggedOnce() async throws {
        let (_, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        documents.scheduleFileSave(for: escaping, text: "first pause")
        try await documents.flushPendingSave()
        documents.scheduleFileSave(for: escaping, text: "second pause")
        try await documents.flushPendingSave()
        XCTAssertEqual(documents.refusedSavePathsLogged, [escaping])
        try assertOutsideUntouched("research-note autosave")
    }

    /// The autosave guard's own question, beside the load's: a URL with a
    /// `..`, or one through a folder linked out of the project, is not inside.
    func test_isInsideProject_refusesAClimbAndASymlinkedFolder() throws {
        XCTAssertTrue(Document.isInsideProject(
            project.appendingPathComponent("manuscript/01-good.md"), root: project))
        XCTAssertFalse(Document.isInsideProject(
            project.appendingPathComponent(escaping), root: project))
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("linked"), withDestinationURL: base)
        XCTAssertFalse(Document.isInsideProject(
            project.appendingPathComponent("linked/outside.md"), root: project))
    }
}
