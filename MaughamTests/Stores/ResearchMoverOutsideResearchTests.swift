import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The typed mover never moves a file outside a research root** (note
/// versions plan 2, fix wave 2 round 2). A synced manifest (tripwire 58's
/// untrusted input) can give a Research row the path `manuscript/x.md` or a
/// `.maugham/` file. Renaming the row and moving it (in the app and over MCP)
/// refuse with `outsideResearch`; trashing it takes the ROW only — the file
/// stays exactly where it is — and that entry restores and deletes as a row;
/// a Trash record whose file would land outside a research root is not
/// restored. A loose piece's own Research still renames, moves, trashes and
/// comes back to its piece's folder.
@MainActor
final class ResearchMoverOutsideResearchTests: XCTestCase {

    private var parent: URL!
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        parent = TestTemp.root.appendingPathComponent("moveroutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: parent.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: parent.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: parent.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Fixture

    private func open(_ url: URL) async throws -> ProjectStore {
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        stores.append(ds)
        store.documentStore = ds
        ds.projectStore = store
        return store
    }

    private func novel() async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: "Mover", in: parent)
        return (url, try await open(url))
    }

    /// A row of `kind` naming `path`, the file there holding known bytes.
    private func stray(_ path: String, kind: ResearchItem.AssetKind, n: Int,
                       in url: URL, _ store: ProjectStore) throws -> (ResearchItem, Data) {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = Data("Not Research \(n).\n".utf8)
        try bytes.write(to: file)
        let item = ResearchItem(id: "res-stray00\(n)", title: "Stray \(n)", type: .asset, kind: kind, path: path)
        store.manifest.research.append(item)
        return (item, bytes)
    }

    private let strays: [(String, ResearchItem.AssetKind)] = [
        ("manuscript/x.md", .document), (".maugham/ops/x.jsonl", .document), ("manuscript/t.csv", .table),
    ]

    private func assertUntouched(_ path: String, _ bytes: Data, in url: URL,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try? Data(contentsOf: url.appendingPathComponent(path)), bytes,
                       "\(path) is byte-identical and where it was", file: file, line: line)
    }

    // MARK: - Rename and move refuse

    func test_renamingOrMovingARowOutsideAResearchRootIsRefused_andTheFileStays() async throws {
        let (url, store) = try await novel()
        let group = try await store.addResearchItem(parentId: nil, title: "Folder", kind: nil)
        for (n, (path, kind)) in strays.enumerated() {
            let (item, bytes) = try stray(path, kind: kind, n: n, in: url, store)

            do { try await store.updateResearchItem(id: item.id, title: "Renamed \(n)"); XCTFail("\(path): rename") }
            catch ProjectStoreError.outsideResearch {}
            do { try await store.moveResearchItems(ids: [item.id], to: .group(group.id)); XCTFail("\(path): move") }
            catch ProjectStoreError.outsideResearch {}
            do { try await store.moveResearchItems(ids: [item.id], to: .sharedRoot); XCTFail("\(path): move") }
            catch ProjectStoreError.outsideResearch {}

            assertUntouched(path, bytes, in: url)
            let row = try XCTUnwrap(store.findResearchItem(id: item.id, in: store.manifest.research))
            XCTAssertEqual(row.path, path, "the manifest is unchanged")
            XCTAssertEqual(row.title, item.title, "the manifest is unchanged")
        }
    }

    /// A destination folder outside every research root takes nothing.
    func test_movingIntoAGroupOutsideAResearchRootIsRefused() async throws {
        let (url, store) = try await novel()
        let group = try await store.addResearchItem(parentId: nil, title: "Folder", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "A note")
        let notePath = try XCTUnwrap(note.path)
        store.mutateResearchItem(id: group.id) { $0.path = "manuscript" }
        let before = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("manuscript").path)

        do { try await store.moveResearchItems(ids: [note.id], to: .group(group.id)); XCTFail("expected a refusal") }
        catch ProjectStoreError.outsideResearch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(notePath).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("manuscript").path),
                       before)
    }

    func test_moveResearchItemOverMCPIsRefused_andTheFileStays() async throws {
        let (url, store) = try await novel()
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let (item, bytes) = try stray("manuscript/x.md", kind: .document, n: 0, in: url, store)
        let params = Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\",\"research_ids\":[\"\(item.id)\"],\"target\":\"shared\"}".utf8)
        do {
            _ = try await MoveResearchItemTool.handle(paramsJSON: params, registry: registry)
            XCTFail("expected a refusal")
        } catch ProjectStoreError.outsideResearch {}
        assertUntouched("manuscript/x.md", bytes, in: url)
        XCTAssertEqual(store.findResearchItem(id: item.id, in: store.manifest.research)?.path, "manuscript/x.md")
    }

    // MARK: - Trash takes the row only

    func test_trashingARowOutsideAResearchRootTakesTheRowOnly_andRestoresAndDeletesAsARow() async throws {
        let (url, store) = try await novel()
        for (n, (path, kind)) in strays.enumerated() {
            let (item, bytes) = try stray(path, kind: kind, n: n, in: url, store)

            try await store.deleteResearchItems(ids: [item.id])
            XCTAssertNil(store.findResearchItem(id: item.id, in: store.manifest.research), "\(path): the row is gone")
            assertUntouched(path, bytes, in: url)
            let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == item.title }, path)
            XCTAssertFalse(entry.carriesFile, "\(path): the entry is the row, not the file")

            _ = try await store.restoreTrashEntry(id: entry.id)
            XCTAssertEqual(store.findResearchItem(id: item.id, in: store.manifest.research)?.path, path,
                           "\(path): the row came back as it was")
            assertUntouched(path, bytes, in: url)

            try await store.deleteResearchItems(ids: [item.id])
            let again = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == item.title }, path)
            try await store.permanentlyDeleteTrashEntry(id: again.id)
            assertUntouched(path, bytes, in: url)
        }
    }

    /// A Trash record whose file would come back outside every research root
    /// (here: its group was pointed at the manuscript since) still comes back
    /// — at the top of the shared Research, never in the manuscript folder:
    /// a restore is not refused for want of a home.
    func test_aTrashedFileWhoseHomeIsOutsideAResearchRootComesBackIntoResearch() async throws {
        let (url, store) = try await novel()
        let group = try await store.addResearchItem(parentId: nil, title: "Folder", kind: nil)
        let note = try await store.addResearchTextNote(parentId: group.id, title: "A note")
        try Data("Kept words.\n".utf8).write(to: url.appendingPathComponent(try XCTUnwrap(note.path)))
        try await store.deleteResearchItems(ids: [note.id])
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "A note" })
        XCTAssertTrue(entry.carriesFile)
        store.mutateResearchItem(id: group.id) { $0.path = "manuscript" }
        let before = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("manuscript").path)

        _ = try await store.restoreTrashEntry(id: entry.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("manuscript").path),
                       before, "nothing lands in the manuscript folder")
        let back = try XCTUnwrap(store.manifest.research.first { $0.id == note.id }, "a top-level row")
        XCTAssertEqual(back.path, "research/a-note.md")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("research/a-note.md"), encoding: .utf8),
                       "Kept words.\n")
    }

    // MARK: - Refused before the mover closes anything

    /// A synced row pointing at the chapter the writer has OPEN: the rename,
    /// the move and the (row-only) trash all leave the chapter's Document
    /// open, registered and with its text.
    func test_aRefusedRenameOrMoveAndARowOnlyTrashLeaveAnOpenChapterOpen() async throws {
        let (url, store) = try await novel()
        let ds = try XCTUnwrap(stores.last)
        let path = try XCTUnwrap(store.manifest.structure.first { $0.type == .document }?.path)
        let doc = try await Document.load(url: url.appendingPathComponent(path), actor: .author,
                                          session: "open", presenter: ds.presenter)
        ds.register(document: doc, for: path)
        let text = doc.displayText
        let bytes = try Data(contentsOf: url.appendingPathComponent(path))
        let row = ResearchItem(id: "res-stray009", title: "Stray", type: .asset, kind: .document, path: path)
        store.manifest.research.append(row)

        do { try await store.updateResearchItem(id: row.id, title: "Renamed"); XCTFail("rename") }
        catch ProjectStoreError.outsideResearch {}
        XCTAssertTrue(ds.document(for: path) === doc, "still registered after the rename")
        XCTAssertFalse(doc.isClosed, "still open after the rename")
        do { try await store.moveResearchItems(ids: [row.id], to: .sharedRoot); XCTFail("move") }
        catch ProjectStoreError.outsideResearch {}
        XCTAssertTrue(ds.document(for: path) === doc, "still registered after the move")
        try await store.deleteResearchItems(ids: [row.id])
        XCTAssertTrue(ds.document(for: path) === doc, "still registered after the row-only trash")
        XCTAssertFalse(doc.isClosed)
        XCTAssertEqual(doc.displayText, text)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(path)), bytes)
        await doc.close()
    }

    // MARK: - A path that leaves the project is refused as that

    func test_aRowWhosePathLeavesTheProjectIsRefusedAsUnsafe_forRenameMoveAndTrash() async throws {
        let (url, store) = try await novel()
        let outside = url.deletingLastPathComponent().appendingPathComponent("escape.md")
        try Data("Outside.\n".utf8).write(to: outside)
        let row = ResearchItem(id: "res-escape01", title: "Escape", type: .asset, kind: .document, path: "../escape.md")
        store.manifest.research.append(row)
        func assertUnsafe(_ what: String, _ verb: () async throws -> Void) async {
            do { try await verb(); XCTFail("\(what): expected a refusal") }
            catch ProjectStoreError.unsafeProjectPath {}
            catch { XCTFail("\(what): refused as \(error), not as a path that leaves the project") }
        }
        await assertUnsafe("rename") { try await store.updateResearchItem(id: row.id, title: "Renamed") }
        await assertUnsafe("move") { try await store.moveResearchItems(ids: [row.id], to: .sharedRoot) }
        await assertUnsafe("trash") { try await store.deleteResearchItems(ids: [row.id]) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Outside.\n")
        XCTAssertNotNil(store.findResearchItem(id: row.id, in: store.manifest.research), "the row stays")
    }

    // MARK: - A group outside Research that still holds rows

    func test_aGroupOutsideAResearchRootThatHoldsRowsIsNotTrashed() async throws {
        let (url, store) = try await novel()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Inside")
        let notePath = try XCTUnwrap(note.path)
        var group = ResearchItem(id: "res-grpout01", title: "Out", type: .group, kind: nil, path: "manuscript")
        group.children = [note]
        store.manifest.research.removeAll { $0.id == note.id }
        store.manifest.research.append(group)

        do { try await store.deleteResearchItems(ids: [group.id]); XCTFail("expected a refusal") }
        catch ProjectStoreError.fileSystemError(let message) { XCTAssertTrue(message.contains("Move or delete what is in it first"), message) }
        XCTAssertNotNil(store.findResearchItem(id: note.id, in: store.manifest.research), "the child row stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(notePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("manuscript").path))
    }

    // MARK: - The control: a loose piece's own Research

    func test_aPieceScopedNoteRenamesTrashesRestoresIntoItsPieceAndMoves() async throws {
        let url = try await ProjectFactory.createCollectionProject(named: "Anthology", in: parent)
        let store = try await open(url)
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        let note = try await store.createResearchNote(scope: .document(piece.id), title: "Harbour")
        let pieceFolder = ((try XCTUnwrap(note.path)) as NSString).deletingLastPathComponent
        XCTAssertTrue(pieceFolder.hasPrefix("pieces/") && pieceFolder.hasSuffix("/research"), pieceFolder)

        try await store.updateResearchItem(id: note.id, title: "Quay")
        let renamed = try XCTUnwrap(store.findResearchItem(id: note.id, in: store.manifest.research)?.path)
        XCTAssertEqual(renamed, "\(pieceFolder)/quay.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(renamed).path))

        try await store.deleteResearchItems(ids: [note.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent(renamed).path), "trashed")
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Quay" })
        _ = try await store.restoreTrashEntry(id: entry.id)
        let restored = try XCTUnwrap(store.findResearchItem(id: note.id, in: store.manifest.research)?.path)
        XCTAssertEqual((restored as NSString).deletingLastPathComponent, pieceFolder, "back in its piece's folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(restored).path))

        try await store.moveResearchItems(ids: [note.id], to: .sharedRoot)
        let moved = try XCTUnwrap(store.findResearchItem(id: note.id, in: store.manifest.research)?.path)
        XCTAssertTrue(moved.hasPrefix("research/"), moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(moved).path))
    }

    // MARK: - A piece's note comes back to the piece as it is now

    private func collectionWithAPieceNote(pieces titles: [String] = ["Story A"])
        async throws -> (URL, ProjectStore, [StructureItem], ResearchItem) {
        let url = try await ProjectFactory.createCollectionProject(named: "Anthology", in: parent)
        let store = try await open(url)
        var pieces: [StructureItem] = []
        for title in titles { pieces.append(try await store.addLoosePiece(title: title, format: .markdown)) }
        let note = try await store.createResearchNote(scope: .document(pieces[0].id), title: "Harbour")
        try Data("Harbour words.\n".utf8).write(to: url.appendingPathComponent(try XCTUnwrap(note.path)))
        return (url, store, pieces, note)
    }

    private func restoreHarbour(_ store: ProjectStore) async throws -> String {
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Harbour" })
        _ = try await store.restoreTrashEntry(id: entry.id)
        return try XCTUnwrap(store.findResearchItem(
            id: try XCTUnwrap(store.manifest.research.first { $0.title == "Harbour" }?.id),
            in: store.manifest.research)?.path)
    }

    /// The note sat in a group inside the piece's research; the group was
    /// deleted since. It comes back at the piece's research root, and the
    /// deleted group's folder is not made again.
    func test_aPieceNoteWhoseGroupWasDeletedComesBackAtThePiecesResearchRoot() async throws {
        let (url, store, _, note) = try await collectionWithAPieceNote()
        let pieceRoot = ((try XCTUnwrap(note.path)) as NSString).deletingLastPathComponent
        let group = try await store.addResearchItem(parentId: nil, title: "Shelf", kind: nil)
        try await store.moveResearchItems(ids: [group.id], to: .piece(try XCTUnwrap(store.researchScopePieceId(ofPath: note.path))))
        try await store.moveResearchItems(ids: [note.id], to: .group(group.id))
        let inGroup = try XCTUnwrap(store.findResearchItem(id: note.id, in: store.manifest.research)?.path)
        XCTAssertEqual(inGroup, "\(pieceRoot)/shelf/harbour.md", "premise")
        try await store.deleteResearchItems(ids: [note.id])
        try await store.deleteResearchItems(ids: [group.id])

        let back = try await restoreHarbour(store)
        XCTAssertEqual(back, "\(pieceRoot)/harbour.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("\(pieceRoot)/shelf").path),
                       "the deleted group's folder is not made again")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(back), encoding: .utf8), "Harbour words.\n")
    }

    /// The piece is gone since: the note comes back into the shared Research,
    /// bytes intact — never refused, never left for the sweep.
    func test_aPieceNoteWhosePieceIsGoneComesBackIntoTheSharedResearch() async throws {
        let (url, store, pieces, note) = try await collectionWithAPieceNote()
        try await store.deleteResearchItems(ids: [note.id])
        store.manifest.structure.removeAll { $0.id == pieces[0].id }

        let back = try await restoreHarbour(store)
        XCTAssertEqual(back, "research/harbour.md")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(back), encoding: .utf8), "Harbour words.\n")
    }

    /// A reorder renumbers the piece's folder; the note comes back into the
    /// piece's CURRENT research folder.
    func test_aPieceNoteComesBackIntoItsPiecesRenumberedFolder() async throws {
        let (url, store, pieces, note) = try await collectionWithAPieceNote(pieces: ["Story A", "Story B"])
        let before = ((try XCTUnwrap(note.path)) as NSString).deletingLastPathComponent
        try await store.deleteResearchItems(ids: [note.id])
        try await store.movePiece(pieceId: pieces[0].id, toIndex: 1)
        let piece = try XCTUnwrap(store.manifest.structure.first { $0.id == pieces[0].id })
        let now = String(try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece)).dropLast())
        XCTAssertNotEqual(now, before, "premise: the reorder renumbered the folder")

        let back = try await restoreHarbour(store)
        XCTAssertEqual(back, "\(now)/harbour.md")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(back), encoding: .utf8), "Harbour words.\n")
    }
}
