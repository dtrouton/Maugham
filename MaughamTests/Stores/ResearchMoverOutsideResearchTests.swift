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
    }

    override func tearDown() async throws {
        for store in stores { await store.close() }
        stores = []
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
    /// (here: its group was pointed at the manuscript since) is not restored:
    /// the entry stays, and nothing lands in the manuscript folder.
    func test_aTrashedFileIsNotRestoredOutsideAResearchRoot() async throws {
        let (url, store) = try await novel()
        let group = try await store.addResearchItem(parentId: nil, title: "Folder", kind: nil)
        let note = try await store.addResearchTextNote(parentId: group.id, title: "A note")
        try await store.deleteResearchItems(ids: [note.id])
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "A note" })
        XCTAssertTrue(entry.carriesFile)
        store.mutateResearchItem(id: group.id) { $0.path = "manuscript" }
        let before = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("manuscript").path)

        do { _ = try await store.restoreTrashEntry(id: entry.id); XCTFail("expected a refusal") }
        catch ProjectStoreError.outsideResearch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("manuscript").path),
                       before)
        let still = try await store.trashStore.list()
        XCTAssertTrue(still.contains { $0.id == entry.id }, "the entry stays in the Trash")
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
}
