import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Every writer of an existing Research note's text goes through the note
/// door** (note versions plan 2, Task 4): a wiki rename's link sweep, Search &
/// Replace, and a note's asset refs rewritten after a rename or a move each
/// keep the text they replace as a version, and none is undone by an edit the
/// editor had queued. A palette card keeps the write it had and no version
/// (P2's default). The promotion writers are pinned in
/// `PromotionPerformerTests` beside their fixture.
@MainActor
final class ResearchNoteWritersTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var lockedPaths: [URL] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("notewriters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for path in lockedPaths {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        lockedPaths = []
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A novel with one chapter, "Alpha", and both stores wired both ways, as
    /// `ProjectSession.open` wires them.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Alpha", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A note made the way the writer makes one, holding `text` on disk.
    private func note(_ text: String, titled title: String = "Notes",
                      in projectStore: ProjectStore) async throws -> ResearchItem {
        let item = try await projectStore.createResearchNote(scope: .shared, title: title)
        try Data(text.utf8).write(to: file(try XCTUnwrap(item.path)))
        return item
    }

    private func current(_ item: ResearchItem, _ projectStore: ProjectStore) throws -> ResearchItem {
        try XCTUnwrap(projectStore.findResearchItem(id: item.id, in: projectStore.manifest.research))
    }

    private func text(of item: ResearchItem, _ projectStore: ProjectStore) throws -> String {
        String(decoding: try Data(contentsOf: file(try XCTUnwrap(current(item, projectStore).path))),
               as: UTF8.self)
    }

    private func versions(of item: ResearchItem) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: item.id)
    }

    /// The text of the newest version kept for `item`.
    private func newestVersionText(of item: ResearchItem) throws -> String {
        let newest = try XCTUnwrap(versions(of: item).max(by: { $0.savedAt < $1.savedAt }),
                                   "no version was kept")
        XCTAssertEqual(newest.payload, .note)
        return String(decoding: try ResearchVersionStore(projectURL: projectURL).read(newest).0,
                      as: UTF8.self)
    }

    /// An edit the open editor has queued and not yet saved (its debounce
    /// never fires on its own inside the test).
    private func queueEdit(_ text: String, of item: ResearchItem, _ store: DocumentStore) {
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: text)
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id))
    }

    private func search(_ query: String, _ projectStore: ProjectStore) async -> SearchResults {
        await ProjectSearchEngine().search(query: query, options: SearchOptions(), in: projectStore)
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        lockedPaths.append(url)
    }

    // MARK: - The rename's link sweep (recon §6 row 4)

    func test_aWikiRenameKeepsTheLinkingNotesTextAsAVersion() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("See [[Alpha]] for the fog.", in: projectStore)

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")

        XCTAssertEqual(try text(of: item, projectStore), "See [[Omega]] for the fog.")
        XCTAssertEqual(try newestVersionText(of: item), "See [[Alpha]] for the fog.",
                       "the text the rename replaced is a version")
        XCTAssertGreaterThan(store.researchNoteReloadCount(itemId: item.id), 0,
                             "an editor open on the note re-reads it")
    }

    func test_aWikiRenameOverAQueuedEditKeepsTheEdit() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("See [[Alpha]].", in: projectStore)
        queueEdit("See [[Alpha]]. Typed a moment ago.", of: item, store)

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")
        try await store.flushPendingSave()

        XCTAssertEqual(try text(of: item, projectStore), "See [[Omega]]. Typed a moment ago.",
                       "the queued edit is saved first and renamed with the rest")
    }

    func test_aWikiRenameThatRewritesAPaletteCardKeepsNoVersion() async throws {
        let (_, projectStore) = try await openBook()
        let card = try await projectStore.addPaletteCard(title: "Fog", kind: .other)
        let cardText = "# Fog\n\nThe light in [[Alpha]].\n"
        try Data(cardText.utf8).write(to: file(try XCTUnwrap(card.path)))

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")

        XCTAssertEqual(try text(of: card, projectStore), "# Fog\n\nThe light in [[Omega]].\n",
                       "the card is still rewritten")
        XCTAssertTrue(versions(of: card).isEmpty, "P2: a palette card keeps no version")
    }

    // MARK: - Search & Replace (recon §6 row 5)

    func test_replaceAllKeepsTheNotesTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("The fog came in. The fog stayed.", in: projectStore)

        let results = await search("fog", projectStore)
        XCTAssertEqual(results.matches.filter { $0.documentSource == .research }.count, 2)
        try await projectStore.replaceAll(in: results, with: "mist")

        XCTAssertEqual(try text(of: item, projectStore), "The mist came in. The mist stayed.")
        XCTAssertEqual(try newestVersionText(of: item), "The fog came in. The fog stayed.")
    }

    func test_replaceMatchKeepsTheNotesTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("The fog came in.", in: projectStore)

        let results = await search("fog", projectStore)
        projectStore.currentSearch = results
        let match = try XCTUnwrap(results.matches.first { $0.documentSource == .research })
        try await projectStore.replaceMatch(match, with: "mist")

        XCTAssertEqual(try text(of: item, projectStore), "The mist came in.")
        XCTAssertEqual(try newestVersionText(of: item), "The fog came in.")
    }

    /// The editor's queued edit used to land AFTER the raw write and put the
    /// unreplaced text back: Replace now flushes first and writes through the
    /// door, so both the edit and the replacement stand.
    func test_replaceAllOverANoteWithAnUnflushedEditDoesNotClobberIt() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("The fog came in.", in: projectStore)
        let results = await search("fog", projectStore)
        queueEdit("The fog came in. Then the rain.", of: item, store)

        try await projectStore.replaceAll(in: results, with: "mist")
        try await store.flushPendingSave()

        XCTAssertEqual(try text(of: item, projectStore), "The mist came in. Then the rain.")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    func test_replaceAllInAPaletteCardKeepsNoVersion() async throws {
        let (_, projectStore) = try await openBook()
        let card = try await projectStore.addPaletteCard(title: "Weather", kind: .other)
        try Data("# Weather\n\nCold fog.\n".utf8).write(to: file(try XCTUnwrap(card.path)))

        try await projectStore.replaceAll(in: await search("fog", projectStore), with: "mist")

        XCTAssertEqual(try text(of: card, projectStore), "# Weather\n\nCold mist.\n")
        XCTAssertTrue(versions(of: card).isEmpty, "P2: a palette card keeps no version")
    }

    /// `.notSaved` is not swallowed: Replace throws as any failed write of
    /// it does, and the note is as it was.
    func test_aReplaceWhoseVersionCannotBeKeptThrowsAndLeavesTheNote() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("The fog came in.", in: projectStore)
        try lock(file(".maugham/research-versions"))

        do {
            try await projectStore.replaceAll(in: await search("fog", projectStore), with: "mist")
            XCTFail("a replace the door refused must say so")
        } catch ProjectStoreError.fileSystemError(let reason) {
            XCTAssertTrue(reason.contains("Notes"), reason)
        }
        XCTAssertEqual(try text(of: item, projectStore), "The fog came in.")
    }

    // MARK: - Asset refs after a rename or a move (recon §6 row 6)

    func test_renamingANoteWithAssetsKeepsItsTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("![](./harbor_assets/img.png)", titled: "Harbor", in: projectStore)
        let assets = file("research/harbor_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assets.appendingPathComponent("img.png"))

        try await projectStore.updateResearchItem(id: item.id, title: "Quay")

        XCTAssertEqual(try current(item, projectStore).path, "research/quay.md")
        XCTAssertEqual(try text(of: item, projectStore), "![](./quay_assets/img.png)")
        XCTAssertEqual(try newestVersionText(of: item), "![](./harbor_assets/img.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("research/harbor.md").path),
                       "the write lands where the note now is, not at its old path")
    }

    func test_movingANoteWhoseStemDedupsKeepsItsTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let group = try await projectStore.addResearchItem(parentId: nil, title: "World", kind: nil)
        let groupPath = try XCTUnwrap(current(group, projectStore).path)
        let item = try await note("![](./sarah_assets/img.png)", titled: "Sarah", in: projectStore)
        let assets = file("research/sarah_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assets.appendingPathComponent("img.png"))
        // An orphaned `sarah_assets` at the destination makes the stem dedup.
        try FileManager.default.createDirectory(
            at: file("\(groupPath)/sarah_assets"), withIntermediateDirectories: true)

        try await projectStore.moveResearchItems(ids: [item.id], to: .group(group.id))

        XCTAssertEqual(try current(item, projectStore).path, "\(groupPath)/sarah-2.md")
        XCTAssertEqual(try text(of: item, projectStore), "![](./sarah-2_assets/img.png)")
        XCTAssertEqual(try newestVersionText(of: item), "![](./sarah_assets/img.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("research/sarah.md").path))
    }
}
