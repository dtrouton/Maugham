import XCTest
import MaughamCore
@testable import Maugham

/// **F7 (P3b smoke, 2026-09-23): an open window adopts a manifest another
/// device wrote, and the copy it replaces is the one archived.**
///
/// Until this fix `DocumentStore.handleManifestChanged` archived the INCOMING
/// manifest as a conflict and never assigned `projectStore.manifest`, so a
/// chapter another Mac added never appeared here and this Mac's next
/// structural save wrote its stale copy straight over it — last-writer-wins
/// with the wrong loser. The master spec's rule is: *"Last-writer-wins; the
/// loser is `.maugham/conflicts/manifest-<ts>.json`."*
@MainActor
final class ManifestAdoptionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// The window's two stores, wired both ways exactly as `ProjectWindow.load`
    /// wires them.
    private func openWindow() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Adoption", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        return (url, store, ds)
    }

    private func manifestURL(_ url: URL) -> URL {
        url.appendingPathComponent(ProjectManifest.fileName)
    }

    private func manifestOnDisk(_ url: URL) throws -> ProjectManifest {
        try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: manifestURL(url)))
    }

    private func archives(in url: URL) -> [URL] {
        let dir = url.appendingPathComponent(".maugham/conflicts")
        return ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("manifest-") }
    }

    /// Another Mac, holding its own copy of the book, adds a chapter through
    /// the ordinary store verb. With no `DocumentStore` wired it writes the
    /// manifest directly — which is what arriving through sync looks like to
    /// this window's presenter.
    private func anotherMacAddsAChapter(
        _ url: URL, title: String = "Chapter Three"
    ) async throws -> StructureItem {
        let other = try await ProjectStore.load(from: url)
        return try await other.addStructureItem(
            parentId: nil, title: title, kind: .document(extension: "md"))
    }

    // MARK: - The headline

    func test_aManifestAnotherMacWroteIsAdopted() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacAddsAChapter(url)
        XCTAssertNil(TreeWalk.find(id: added.id, in: store.manifest.structure))

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure),
                        "the chapter another Mac added must appear in this window")
        await ds.close()
    }

    /// The consequence that made F7 a data-loss defect rather than a stale
    /// view: this Mac's next structural save must carry the other Mac's
    /// chapter, not write the stale copy over it.
    func test_theNextOwnStructuralSaveKeepsTheAdoptedChapter() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacAddsAChapter(url)
        ds.presenterDidChangeSubitem(at: manifestURL(url))

        let mine = try await store.addStructureItem(
            parentId: nil, title: "Chapter Four", kind: .document(extension: "md"))

        let disk = try manifestOnDisk(url)
        XCTAssertNotNil(TreeWalk.find(id: added.id, in: disk.structure),
                        "the other Mac's chapter survived this Mac's save")
        XCTAssertNotNil(TreeWalk.find(id: mine.id, in: disk.structure))
        await ds.close()
    }

    /// The archive is the LOSER — the in-memory manifest the adoption replaced
    /// — and not the winner, which is already on disk and in the window.
    func test_theArchiveHoldsTheReplacedManifestNotTheIncomingOne() async throws {
        let (url, store, ds) = try await openWindow()
        let before = store.manifest
        let added = try await anotherMacAddsAChapter(url)

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        let archived = archives(in: url)
        XCTAssertEqual(archived.count, 1, "\(archived)")
        let loser = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: archived[0]))
        XCTAssertNil(TreeWalk.find(id: added.id, in: loser.structure),
                     "the archive must not be the manifest that won")
        XCTAssertEqual(loser.structure.map(\.id), before.structure.map(\.id))
        await ds.close()
    }

    /// Bytes that differ but decode to the manifest this window already holds
    /// replace nothing, so there is no loser and nothing is archived.
    func test_aManifestThatSaysWhatThisWindowHoldsArchivesNothing() async throws {
        let (url, store, ds) = try await openWindow()
        let object = try JSONSerialization.jsonObject(
            with: ProjectManifest.makeEncoder().encode(store.manifest))
        // Same content, different bytes: compact rather than pretty-printed.
        try JSONSerialization.data(withJSONObject: object)
            .write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertTrue(archives(in: url).isEmpty, "\(archives(in: url))")
        await ds.close()
    }

    // MARK: - What the adoption refuses

    /// A manifest from a LATER build is refused, never adopted: this build
    /// would decode it lossily and its next save would drop what it could not
    /// represent. The incoming bytes are archived so they outlive that save,
    /// which is today's behaviour for this case, kept.
    func test_aTooNewManifestIsNotAdoptedAndIsArchivedWhole() async throws {
        let (url, store, ds) = try await openWindow()
        let before = store.manifest
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ProjectManifest.makeEncoder().encode(store.manifest)) as? [String: Any])
        object["schemaVersion"] = ProjectManifest.currentSchemaVersion + 1
        object["title"] = "Written by a later build"
        let incoming = try JSONSerialization.data(withJSONObject: object)
        try incoming.write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertEqual(store.manifest, before, "a too-new manifest is never adopted")
        let archived = archives(in: url)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try Data(contentsOf: archived[0]), incoming)
        await ds.close()
    }

    /// **A structural change of this window's own that has not reached disk
    /// yet is not thrown away.** Every structural verb mutates the manifest and
    /// then awaits its save — a rename moves files in between — so a manifest
    /// arriving in that window would, if adopted, lose the change whose file
    /// surgery has already happened. This window's save is about to land, which
    /// makes it the later writer: the incoming manifest is the loser, and is
    /// what gets archived.
    func test_anUnsavedChangeOfThisWindowsOwnIsKeptAndTheIncomingIsArchived() async throws {
        let (url, store, ds) = try await openWindow()
        let firstId = store.manifest.structure[0].id
        store.mutateItem(id: firstId) { $0.title = "Renamed Here, Not Yet Saved" }
        let added = try await anotherMacAddsAChapter(url)

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertEqual(TreeWalk.find(id: firstId, in: store.manifest.structure)?.title,
                       "Renamed Here, Not Yet Saved")
        let archived = archives(in: url)
        XCTAssertEqual(archived.count, 1)
        let loser = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: archived[0]))
        XCTAssertNotNil(TreeWalk.find(id: added.id, in: loser.structure),
                        "the incoming manifest lost, so it is the one kept aside")
        await ds.close()
    }

    /// And once the window's own save has landed it is settled again, so the
    /// NEXT manifest from elsewhere is adopted rather than refused for ever.
    func test_afterItsOwnSaveTheWindowAdoptsAgain() async throws {
        let (url, store, ds) = try await openWindow()
        let firstId = store.manifest.structure[0].id
        store.mutateItem(id: firstId) { $0.title = "Renamed Here" }
        try await store.saveManifest()
        ds.presenterDidChangeSubitem(at: manifestURL(url))  // our own echo

        let added = try await anotherMacAddsAChapter(url, title: "Later Chapter")
        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure))
        await ds.close()
    }

    // MARK: - Edges, pinned

    /// A remote rename of the chapter this window has open arrives as a new
    /// PATH for the same id. The editor's reload keys on path (tripwire 22), so
    /// adopting the manifest is what makes `EditorHost` re-bind at the new
    /// path rather than keep a Document writing to the old one.
    func test_aRemoteRenameReachesTheEditorsPathKeyedReload() async throws {
        let (url, store, ds) = try await openWindow()
        let item = store.manifest.structure[0]
        let oldPath = try XCTUnwrap(item.path)
        var external = store.manifest
        external.structure[0].path = "01-renamed-elsewhere.md"
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        let adopted = try XCTUnwrap(TreeWalk.find(id: item.id, in: store.manifest.structure))
        XCTAssertEqual(adopted.path, "01-renamed-elsewhere.md")
        XCTAssertTrue(EditorHost.needsReload(
            itemId: item.id, path: try XCTUnwrap(adopted.path),
            loadedItemId: item.id, loadedPath: oldPath))
        await ds.close()
    }

    /// **The adoption closes nothing.** A chapter another Mac trashed or
    /// renamed while it is open here stays open, and registered, until this
    /// window lets go of it — the words already typed are in the op log, and
    /// closing a Document out from under the writer's cursor is a product
    /// decision this fix does not make (reported with F7).
    func test_theAdoptionLeavesAnOpenDocumentOpen() async throws {
        let (url, store, ds) = try await openWindow()
        let item = store.manifest.structure[0]
        let path = try XCTUnwrap(item.path)
        let doc = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "adoption-test", presenter: ds.presenter)
        ds.register(document: doc, for: path)
        var external = store.manifest
        external.structure.removeAll { $0.id == item.id }
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNil(TreeWalk.find(id: item.id, in: store.manifest.structure))
        XCTAssertTrue(ds.document(for: path) === doc)
        XCTAssertFalse(doc.isClosed)
        await ds.close()
    }
}
