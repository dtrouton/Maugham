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
    private let outsideText = "OUTSIDE: the writer's own file, beside the book. See [[Good]].\n"
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

    /// An EMPTY file at the escaping path is what an unused mint looks like,
    /// so only the rollback's own path check stands between it and deletion.
    func test_rollingBackAStatementWhoseEmptyFileIsOutsideIsRefused() async throws {
        let empty = base.appendingPathComponent("empty-outside.md")
        try Data().write(to: empty)
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        let statement = Statement(
            id: "stmt-empty", kind: .visualLanguage, scope: .project, path: "../empty-outside.md")
        store.manifest.statements.append(statement)
        let rolledBack = await store.rollbackUnusedStatement(statement)
        XCTAssertFalse(rolledBack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path),
                      "the empty file outside the project is never deleted")
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
        } catch {
            assertRefusedAsUnsafe(error)
            XCTAssertTrue(error.localizedDescription.contains("“../outside.md”"),
                          "the refusal names the manifest's path: \(error.localizedDescription)")
        }
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

    // MARK: - A writer's own links keep working (review I-1)

    /// A chapter file that is a link to somewhere else opens: reads are
    /// lexical, and a link on this disk is the writer's choice, not synced data.
    func test_aLinkedManuscriptOpens() async throws {
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = elsewhere.appendingPathComponent("real.md")
        try "Linked words.\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("manuscript/02-linked.md"), withDestinationURL: real)
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        let url = try store.resolvedProjectPath("manuscript/02-linked.md")
        let doc = try await Document.load(
            url: url, actor: .author, session: "linked", presenter: documents.presenter)
        XCTAssertTrue(doc.displayText.contains("Linked words."))
        await doc.close()
    }

    /// A research note that is a link renames and trashes AS A LINK: the
    /// link moves, its target is untouched.
    func test_aLinkedResearchNoteRenamesAndTrashesAsALink() async throws {
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("notes.md")
        try "My notes\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("research/notes.md"), withDestinationURL: target)
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        let item = ResearchItem(id: "res-linked", title: "Notes", type: .asset,
                                kind: .document, path: "research/notes.md")
        store.manifest.research.append(item)

        XCTAssertEqual(try String(contentsOf: try store.resolvedProjectPath("research/notes.md"),
                                  encoding: .utf8), "My notes\n", "a linked note reads")
        try await store.updateResearchItem(id: "res-linked", title: "Renamed")
        let renamed = try XCTUnwrap(store.manifest.research.first { $0.id == "res-linked" }?.path)
        XCTAssertNotEqual(renamed, "research/notes.md")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: project.appendingPathComponent(renamed).path), target.path,
            "the rename moved the link itself")

        try await store.deleteResearchItem(id: "res-linked")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(renamed).path), "the link went to the Trash")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "My notes\n",
                       "the link's target is untouched")
    }

    /// A write under a folder linked out of the project is refused: the new
    /// file would land outside.
    func test_aWriteUnderAFolderLinkedOutsideIsRefused() async throws {
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("research/away"), withDestinationURL: elsewhere)
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        store.manifest.research.append(ResearchItem(
            id: "res-grp-away", title: "Away", type: .group, kind: nil,
            path: "research/away", children: []))
        let picked = base.appendingPathComponent("picked.png")
        try Data([0x89, 0x50]).write(to: picked)
        do {
            _ = try await store.addResearchAsset(parentId: "res-grp-away", fromURL: picked)
            XCTFail("a copy into a folder linked outside must be refused")
        } catch { assertRefusedAsUnsafe(error) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    /// A binder reorder that renumbers a sibling which is a link moves the
    /// link (relocate checks each step's folder, never follows the leaf).
    func test_aReorderRenumbersALinkedSibling() async throws {
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = elsewhere.appendingPathComponent("real.md")
        try "words\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("manuscript/02-linked.md"), withDestinationURL: real)
        let (_, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        try await documents.relocate(plan: RenamePlan(steps: [
            .init(oldRelativePath: "manuscript/02-linked.md",
                  newRelativePath: "manuscript/03-linked.md"),
        ]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: project.appendingPathComponent("manuscript/03-linked.md").path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "words\n")
    }

    /// An Exports folder the writer linked elsewhere is the writer's choice of
    /// output: the export lands through it. A name with a backslash in it is
    /// cleaned before it is a file name (review M-5).
    func test_aLinkedExportsFolderIsAllowed_andABackslashIsCleaned() throws {
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("Exports"), withDestinationURL: elsewhere)
        XCTAssertEqual(
            try OutputFilenameBuilder.destination(
                filename: "Book-v1.pdf", outputsDirectory: "Exports", projectURL: project),
            project.appendingPathComponent("Exports/Book-v1.pdf"))
        XCTAssertThrowsError(try OutputFilenameBuilder.destination(
            filename: "Book-v1.pdf", outputsDirectory: "../Exports", projectURL: project))
        XCTAssertEqual(OutputFilenameBuilder.sanitizeForFilesystem(#"A\B/C"#), "ABC")
    }

    /// A link already sitting at the path a new statement would take — even a
    /// dangling one pointing out of the project — is never followed: the new
    /// statement steers around it, and the link's target is never created.
    func test_aDanglingLinkAtANewStatementsPathIsNotFollowed() async throws {
        let target = base.appendingPathComponent("target.md")
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(StatementConvention.visualLanguagePath),
            withDestinationURL: target)
        let (store, documents) = try await open()
        defer { withExtendedLifetime(documents) {} }
        let created = try await store.createStatement(kind: .visualLanguage, scope: .project)
        XCTAssertNotEqual(created.path, StatementConvention.visualLanguagePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "the link's outside target was never written")
    }

    /// The load's guard: a URL with a `..` is not inside; a linked folder is.
    func test_isInsideProject_refusesAClimbAndAcceptsALink() throws {
        XCTAssertTrue(Document.isInsideProject(
            project.appendingPathComponent("manuscript/01-good.md"), root: project))
        XCTAssertFalse(Document.isInsideProject(
            project.appendingPathComponent(escaping), root: project))
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("linked"), withDestinationURL: base)
        XCTAssertTrue(Document.isInsideProject(
            project.appendingPathComponent("linked/somewhere.md"), root: project))
    }
}
