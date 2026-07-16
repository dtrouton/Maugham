import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ResearchMoveTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// Collection with one loose piece and a wired DocumentStore
    /// (ResearchScopeTests + RenameResearchItemTests patterns combined).
    private func makeCollection() async throws
        -> (URL, ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "MoveTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, ds, piece)
    }

    private func item(_ store: ProjectStore, _ id: String) -> ResearchItem? {
        TreeWalk.find(id: id, in: store.manifest.research)
    }

    // MARK: shared → piece

    func test_sharedNote_toPiece_movesFileAndRewritesPath() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, note.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(moved.path!.hasPrefix(prefix), "got \(moved.path!)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/sarah.md").path))
        // Now derived as the piece's research
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id)
            .contains(where: { $0.id == note.id }))
        await ds.close()
    }

    // MARK: piece → shared

    func test_pieceNote_toSharedRoot_movesFileOut() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Clock Tower")

        try await store.moveResearchItems(ids: [note.id], to: .sharedRoot)

        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(moved.path, "research/clock-tower.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/clock-tower.md").path))
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id).isEmpty)
        await ds.close()
    }

    // MARK: into a group

    func test_move_intoGroup_landsAsChild() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Maps")

        try await store.moveResearchItems(ids: [note.id], to: .group(group.id))

        let g = try XCTUnwrap(item(store, group.id))
        XCTAssertTrue((g.children ?? []).contains(where: { $0.id == note.id }))
        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(moved.path, "\(g.path!)/maps.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        await ds.close()
    }

    // MARK: group with descendants across scope

    func test_group_toPiece_movesFolderAndRewritesDescendants() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Setting", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Harbor")

        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        let movedGroup = try XCTUnwrap(item(store, group.id))
        let movedChild = try XCTUnwrap(item(store, child.id))
        XCTAssertTrue(movedGroup.path!.hasPrefix(prefix))
        XCTAssertTrue(movedChild.path!.hasPrefix(movedGroup.path! + "/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(movedChild.path!).path))
        await ds.close()
    }

    // MARK: link items are manifest-only

    func test_linkItem_moves_manifestOnly() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Ref", url: "https://example.com")

        try await store.moveResearchItems(ids: [link.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, link.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(moved.path!.hasPrefix(prefix))
        XCTAssertEqual(moved.url, "https://example.com")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path),
            "synthetic .link path must not create a file")
        await ds.close()
    }

    // MARK: batch + collapsing + validation

    func test_batch_oneBadId_movesNothing() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Keep")

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(
                ids: [note.id, "res-nope"], to: .piece(piece.id)))

        let kept = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(kept.path, "research/keep.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/keep.md").path))
        await ds.close()
    }

    func test_selectedDescendant_collapsesIntoSelectedGroup() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Cluster", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Inside")

        // Selecting both must not double-move (RenamePlan would reject the
        // ancestor overlap); the group's move carries the child.
        try await store.moveResearchItems(
            ids: [group.id, child.id], to: .piece(piece.id))

        let movedChild = try XCTUnwrap(item(store, child.id))
        XCTAssertTrue(movedChild.path!.hasPrefix("pieces/"))
        await ds.close()
    }

    func test_groupIntoOwnDescendant_throwsCycle() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let outer = try await store.addResearchItem(parentId: nil, title: "Outer", kind: nil)
        let inner = try await store.addResearchItem(parentId: outer.id, title: "Inner", kind: nil)

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [outer.id], to: .group(inner.id))) { error in
            XCTAssertEqual(error as? ProjectStoreError, .cycle)
        }
        await ds.close()
    }

    func test_targetNonGroup_throwsParentNotFound() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [a.id], to: .group(b.id)))
        await ds.close()
    }

    // MARK: role guard

    func test_roleItem_crossScope_refuses() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        // Create the palette group via the convention, then stamp its role
        // the way healRole does.
        let group = try await store.addResearchItem(
            parentId: nil, title: PaletteConvention.groupTitle, kind: nil)
        store.mutateResearchItem(id: group.id) { $0.role = .paletteGroup }

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id)))
        let kept = try XCTUnwrap(item(store, group.id))
        XCTAssertFalse(kept.path!.hasPrefix("pieces/"))
        await ds.close()
    }

    // MARK: arrival name collision

    func test_nameCollisionOnArrival_dedupes() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        _ = try await store.createResearchNote(
            scope: .document(piece.id), title: "Sarah")
        let sharedNote = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        try await store.moveResearchItems(ids: [sharedNote.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, sharedNote.id))
        XCTAssertTrue(moved.path!.hasSuffix("sarah-2.md"), "got \(moved.path!)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        await ds.close()
    }

    // MARK: existing single-item mover — _assets orphan regression

    /// Latent bug: the old cross-group branch built a one-step RenamePlan and
    /// left the note's sibling <slug>_assets/ folder behind. Pin the fix.
    func test_crossGroupMove_carriesAssetsFolder() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Harbor")
        // Simulate an image note: create the sibling assets folder on disk.
        let assetsURL = url.appendingPathComponent("research/harbor_assets")
        try FileManager.default.createDirectory(
            at: assetsURL, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assetsURL.appendingPathComponent("img.png"))

        try await store.moveResearchItem(
            id: note.id, toParentId: group.id, atIndex: 0)

        let groupPath = try XCTUnwrap(item(store, group.id)?.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("\(groupPath)/harbor_assets/img.png").path),
            "assets folder must travel with the note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetsURL.path),
            "old assets folder must be gone")
        await ds.close()
    }

    func test_sameParentReorder_stillManifestOnly() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")

        try await store.moveResearchItem(id: b.id, toParentId: nil, atIndex: 0)

        let topIds = store.manifest.research.map(\.id)
        XCTAssertEqual(topIds.firstIndex(of: b.id)! < topIds.firstIndex(of: a.id)!, true)
        XCTAssertEqual(item(store, a.id)?.path, "research/a.md")
        XCTAssertEqual(item(store, b.id)?.path, "research/b.md")
        await ds.close()
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
