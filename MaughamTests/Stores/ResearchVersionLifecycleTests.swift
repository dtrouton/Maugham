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

        // A straggler: versions of an id nothing names, found at open.
        try keepVersions("res-straggler", in: projectStore.url)
        let reopened = try await ProjectStore.load(from: projectStore.url)
        XCTAssertEqual(counts("res-straggler", in: reopened.url).own, 0)
        XCTAssertEqual(counts("res-straggler", in: reopened.url).other, 1)
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
}
