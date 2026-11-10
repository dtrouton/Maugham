import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A Research table's versions follow its item** (report plan 9d Task 7):
/// kept while the item is in the Trash and back when it is restored, swept
/// (this device's files only) when the item is deleted for good, carried by
/// promote-to-project, and not copied on duplicate.
@MainActor
final class ResearchVersionLifecycleTests: XCTestCase {

    private var root: URL!
    private let here = DeviceIdentity.author.slug
    private let elsewhere = DeviceSlug.unsafeForTesting("mac-elsewhere")
    private var lockedFolders: [URL] = []

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("rvlifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: root.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: root.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: root.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for folder in lockedFolders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        lockedFolders = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private func openNovel() async throws -> (ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "Novel", in: root)
        let projectStore = try await ProjectStore.load(from: url)
        let store = try await DocumentStore.open(url: url)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (projectStore, store)
    }

    /// Keeps one version for `itemId` from this device and one from another.
    private func keepVersions(_ itemId: String, in url: URL) throws {
        let versions = ResearchVersionStore(projectURL: url)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try versions.keep(priorBytes: Data("a,b\n".utf8), priorSidecar: nil, writtenBy: .writer,
                          itemId: itemId, device: here, at: date)
        try versions.keep(priorBytes: Data("c,d\n".utf8), priorSidecar: nil, writtenBy: .assistant,
                          itemId: itemId, device: elsewhere, at: date)
    }

    /// Dates every file in `itemId`'s versions folder 31 days back: past the Trash's expiry.
    private func ageVersions(_ itemId: String, in url: URL) throws {
        let folder = try ResearchVersionStore(projectURL: url).folderURL(forItem: itemId)
        let longAgo = Date().addingTimeInterval(-TrashStore.expiry - 86_400)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.setAttributes([.modificationDate: longAgo],
                                                  ofItemAtPath: folder.appendingPathComponent(name).path)
        }
    }

    private func counts(_ itemId: String, in url: URL) -> (own: Int, other: Int) {
        let all = ResearchVersionStore(projectURL: url).versions(itemId: itemId)
        return (all.filter { $0.isKept(by: here) }.count, all.filter { $0.isKept(by: elsewhere) }.count)
    }

    // MARK: - Trash keeps, restore brings back

    func test_anItemInTheTrashKeepsItsVersions_andARestoreListsThemAgain() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let item = try await projectStore.addResearchTable(parentId: nil, title: "Budget")
        try keepVersions(item.id, in: projectStore.url)

        try await projectStore.deleteResearchItems(ids: [item.id])
        await projectStore.sweepResearchVersions()
        XCTAssertEqual(counts(item.id, in: projectStore.url).own, 1, "the Trash keeps the versions")
        XCTAssertEqual(counts(item.id, in: projectStore.url).other, 1)

        try await projectStore.restoreTrashEntry(id: try XCTUnwrap(projectStore.trashEntries.first?.id))
        XCTAssertEqual(counts(item.id, in: projectStore.url).own, 1, "restored, the versions list again")
        XCTAssertEqual(counts(item.id, in: projectStore.url).other, 1)
    }

    // MARK: - Permanent delete sweeps this device's files only

    func test_permanentDeleteSweepsOwnFiles_andLeavesAnotherDevicesAlone() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let kept = try await projectStore.addResearchTable(parentId: nil, title: "Kept")
        let gone = try await projectStore.addResearchTable(parentId: nil, title: "Gone")
        try keepVersions(kept.id, in: projectStore.url)
        try keepVersions(gone.id, in: projectStore.url)

        try await projectStore.deleteResearchItems(ids: [gone.id])
        try await projectStore.permanentlyDeleteTrashEntry(id: try XCTUnwrap(projectStore.trashEntries.first?.id))

        XCTAssertEqual(counts(gone.id, in: projectStore.url).own, 0, "own files swept")
        XCTAssertEqual(counts(gone.id, in: projectStore.url).other, 1, "another device's file untouched")
        XCTAssertEqual(counts(kept.id, in: projectStore.url).own, 1, "a live item's versions stay")
    }

    func test_emptyTrashSweeps_andSoDoesProjectOpenForAStraggler() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let item = try await projectStore.addResearchTable(parentId: nil, title: "Budget")
        try keepVersions(item.id, in: projectStore.url)
        try await projectStore.deleteResearchItems(ids: [item.id])
        try await projectStore.emptyTrash()
        XCTAssertEqual(counts(item.id, in: projectStore.url).own, 0)
        XCTAssertEqual(counts(item.id, in: projectStore.url).other, 1)

        // A straggler: versions of an id nothing names, found at open, older than the Trash's expiry.
        try keepVersions("res-straggler", in: projectStore.url)
        try ageVersions("res-straggler", in: projectStore.url)
        let reopened = try await ProjectStore.load(from: projectStore.url)
        XCTAssertEqual(counts("res-straggler", in: reopened.url).own, 0)
        XCTAssertEqual(counts("res-straggler", in: reopened.url).other, 1)
    }

    // MARK: - Final fix wave I2: nothing sweeps a table whose trash entry it can't see

    /// **Permanently Delete takes only the ids it destroyed.** Table B was
    /// trashed on another Mac: its manifest (no B) is here, its trash entry
    /// not yet. Deleting table A for good leaves B's history alone, however
    /// old. Disable experiment: sweep with the global diff
    /// (`sweepResearchVersions`) instead of the destroyed ids, and B's
    /// versions go.
    func test_permanentDeleteSweepsOnlyTheIdsItDestroyed() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let a = try await projectStore.addResearchTable(parentId: nil, title: "A")
        try keepVersions(a.id, in: projectStore.url)
        let inFlight = "res-inflight"   // in no manifest and no trash entry this Mac can see
        try keepVersions(inFlight, in: projectStore.url)
        try ageVersions(inFlight, in: projectStore.url)

        try await projectStore.deleteResearchItems(ids: [a.id])
        try await projectStore.permanentlyDeleteTrashEntry(id: try XCTUnwrap(projectStore.trashEntries.first?.id))

        XCTAssertEqual(counts(a.id, in: projectStore.url).own, 0, "the destroyed table's own versions go")
        XCTAssertEqual(counts(inFlight, in: projectStore.url).own, 1, "a table it didn't destroy keeps its history")
    }

    /// Empty Trash, the same: only what it destroyed.
    func test_emptyTrashSweepsOnlyTheIdsItDestroyed() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let a = try await projectStore.addResearchTable(parentId: nil, title: "A")
        try keepVersions(a.id, in: projectStore.url)
        let inFlight = "res-inflight"
        try keepVersions(inFlight, in: projectStore.url)
        try ageVersions(inFlight, in: projectStore.url)

        try await projectStore.deleteResearchItems(ids: [a.id])
        try await projectStore.emptyTrash()

        XCTAssertEqual(counts(a.id, in: projectStore.url).own, 0)
        XCTAssertEqual(counts(inFlight, in: projectStore.url).own, 1)
    }

    /// **A Trash that won't list is not an empty Trash**: the open sweep
    /// waits, so a trashed table's history stays. Disable experiment: drop
    /// the `entryFolderIds` guard in `liveResearchItemIds`, and the listing
    /// reads the locked folder as empty and the versions go.
    func test_theOpenSweepWaitsWhenTheTrashWontList() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let item = try await projectStore.addResearchTable(parentId: nil, title: "Budget")
        try keepVersions(item.id, in: projectStore.url)
        try ageVersions(item.id, in: projectStore.url)
        try await projectStore.deleteResearchItems(ids: [item.id])
        let trash = projectStore.url.appendingPathComponent(".trash")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash.path)
        lockedFolders.append(trash)

        let live = await projectStore.liveResearchItemIds()
        XCTAssertNil(live, "an unlistable Trash names nothing")
        await projectStore.sweepResearchVersions()

        XCTAssertEqual(counts(item.id, in: projectStore.url).own, 1, "the trashed table keeps its versions")
    }

    /// **A manifest restored from its shadow is not trusted to sweep**: it
    /// can lag the latest save. Disable experiment: sweep at open whatever
    /// the manifest's source, and the old table's versions go.
    func test_theOpenSweepSkipsAManifestRestoredFromItsShadow() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        _ = try await projectStore.addResearchTable(parentId: nil, title: "Saved")   // writes the manifest and its shadow
        let unnamed = "res-unnamed"
        try keepVersions(unnamed, in: projectStore.url)
        try ageVersions(unnamed, in: projectStore.url)
        XCTAssertNotNil(ManifestShadow.recover(in: projectStore.url), "precondition: a shadow")
        try FileManager.default.removeItem(at: projectStore.url.appendingPathComponent(ProjectManifest.fileName))

        let reopened = try await ProjectStore.load(from: projectStore.url)

        XCTAssertNotNil(reopened.manifestRestoredNotice, "precondition: the manifest came from the shadow")
        XCTAssertEqual(counts(unnamed, in: reopened.url).own, 1, "nothing swept against a shadow manifest")
    }

    /// **A young orphan stays at open; an old one goes**: one younger than
    /// the Trash's expiry may have a trash entry still on its way.
    /// Disable experiment: drop the age guard and the young one is swept.
    func test_theOpenSweepKeepsAYoungOrphan_andSweepsAnOldOne() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let young = "res-young", old = "res-old"
        try keepVersions(young, in: projectStore.url)
        try keepVersions(old, in: projectStore.url)
        try ageVersions(old, in: projectStore.url)

        let reopened = try await ProjectStore.load(from: projectStore.url)

        XCTAssertEqual(counts(young, in: reopened.url).own, 1, "a young orphan is kept")
        XCTAssertEqual(counts(old, in: reopened.url).own, 0, "an orphan past the expiry is swept")
        XCTAssertEqual(counts(old, in: reopened.url).other, 1, "another device's file is its own")
    }

    // MARK: - Duplicate copies none

    func test_duplicatingAnItemCopiesNoVersions() async throws {
        let (projectStore, store) = try await openNovel()
        defer { withExtendedLifetime(store) {} }
        let item = try await projectStore.addResearchTable(parentId: nil, title: "Budget")
        try keepVersions(item.id, in: projectStore.url)

        let copy = try await projectStore.duplicateResearchItem(id: item.id)

        XCTAssertNotEqual(copy.id, item.id)
        XCTAssertTrue(ResearchVersionStore(projectURL: projectStore.url).versions(itemId: copy.id).isEmpty)
        XCTAssertEqual(counts(item.id, in: projectStore.url).own, 1, "the original keeps its own")
    }

    // MARK: - Promote carries

    func test_promotingAPieceCarriesItsResearchTablesVersions() async throws {
        let collection = try await ProjectFactory.createCollectionProject(named: "Anthology", in: root)
        let projectStore = try await ProjectStore.load(from: collection)
        let piece = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let store = try await DocumentStore.open(url: collection)
        projectStore.documentStore = store
        store.projectStore = projectStore
        defer { withExtendedLifetime(store) {} }
        let doc = try await Document.load(
            url: collection.appendingPathComponent(try XCTUnwrap(piece.path)),
            actor: .author, session: "boot", presenter: nil)
        doc.setFullText("Words.\n")
        await doc.close()

        let table = try await projectStore.addPieceResearchTable(pieceId: piece.id, title: "Budget")
        try keepVersions(table.id, in: collection)

        let promotion = try await projectStore.promotePieceToProject(
            pieceId: piece.id, destination: root.appendingPathComponent("Promoted Story A"))

        XCTAssertEqual(counts(table.id, in: promotion.url).own, 1, "the version travelled")
        XCTAssertEqual(counts(table.id, in: promotion.url).other, 1, "so did the one that had reached this Mac")
        XCTAssertEqual(counts(table.id, in: collection).own, 0, "and left the Collection")
        XCTAssertEqual(counts(table.id, in: collection).other, 0)
    }

    /// **A note's record travels with it** (note versions plan 2, whole-branch
    /// Minor 3): promote-to-project carries `.maugham/research-notes/<id>.json`
    /// beside the table sidecars and the versions, so a note the assistant
    /// wrote is still labelled the assistant's in the promoted book.
    func test_promotingAPieceCarriesItsNotesRecord() async throws {
        let collection = try await ProjectFactory.createCollectionProject(named: "Anthology", in: root)
        let projectStore = try await ProjectStore.load(from: collection)
        let piece = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let store = try await DocumentStore.open(url: collection)
        projectStore.documentStore = store
        store.projectStore = projectStore
        defer { withExtendedLifetime(store) {} }
        let doc = try await Document.load(
            url: collection.appendingPathComponent(try XCTUnwrap(piece.path)),
            actor: .author, session: "boot", presenter: nil)
        doc.setFullText("Words.\n")
        await doc.close()

        let note = try await projectStore.createResearchNote(scope: .document(piece.id), title: "Harbour")
        let saved = await store.saveResearchNote(itemId: note.id, text: "The assistant's.", by: .assistant)
        XCTAssertEqual(saved, .saved(keptAVersion: false))
        let record = try XCTUnwrap(try ResearchNoteRecord.read(forItem: note.id, in: collection))

        let promotion = try await projectStore.promotePieceToProject(
            pieceId: piece.id, destination: root.appendingPathComponent("Promoted Story A"))

        XCTAssertEqual(try ResearchNoteRecord.read(forItem: note.id, in: promotion.url), record,
                       "the record travelled")
        XCTAssertNil(try ResearchNoteRecord.read(forItem: note.id, in: collection), "and left the Collection")
    }
}
