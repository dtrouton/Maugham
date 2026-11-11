import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A palette card keeps versions as a Research note does** (Denver,
/// 2026-11-11, note versions plan 2 wave 3, P2): every writer of a card's
/// text reaches the note door. The card editor's own saves are the writer's
/// typing — one version per editing run; any other writer always keeps what
/// it replaces, ends the run, and moves the card's reload signal so an open
/// card editor re-reads. The versions follow the item id through the Trash.
/// The rename sweep and Replace are pinned in `ResearchNoteWritersTests`,
/// the assistant's promotion in `InboxToolsTests`, the canvas Rewrite in
/// `PromotionPerformerTests`.
@MainActor
final class PaletteCardVersionsTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var lockedPaths: [URL] = []
    private var noticeObservers: [NSObjectProtocol] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("cardversions-\(UUID().uuidString)")
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
        for observer in noticeObservers { NotificationCenter.default.removeObserver(observer) }
        noticeObservers = []
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private final class Clock: @unchecked Sendable {   // touched on the main actor only
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(seconds: Double) { date = date.addingTimeInterval(seconds) }
    }
    private let clock = Clock()

    /// A novel with one chapter and both stores wired both ways, as
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
        store.researchNoteDoor.now = { [clock] in clock.date }
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func card(_ body: String, titled title: String = "Harbour",
                      in projectStore: ProjectStore) async throws -> PaletteCard {
        let item = try await projectStore.addPaletteCard(title: title, kind: .location)
        let made = try XCTUnwrap(projectStore.loadPaletteCards().first { $0.researchItemId == item.id })
        let card = withBody(made, body)
        try await projectStore.updatePaletteCard(card)
        clock.advance(seconds: 60)   // each later version sorts after this one
        return card
    }

    private func withBody(_ card: PaletteCard, _ body: String) -> PaletteCard {
        PaletteCard(researchItemId: card.researchItemId, title: card.title, kind: card.kind,
                    swatches: card.swatches, notes: card.notes, imagePaths: card.imagePaths, body: body)
    }

    private func onDisk(_ id: String, _ projectStore: ProjectStore) throws -> String {
        let path = try XCTUnwrap(projectStore.findResearchItem(id: id, in: projectStore.manifest.research)?.path)
        return String(decoding: try Data(contentsOf: file(path)), as: UTF8.self)
    }

    private func versions(_ id: String) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: id)
    }

    private func versionTexts(_ id: String) throws -> [String] {
        let store = ResearchVersionStore(projectURL: projectURL)
        return try versions(id).sorted { $0.savedAt < $1.savedAt }
            .map { String(decoding: try store.read($0).0, as: UTF8.self) }
    }

    private final class Heard: @unchecked Sendable { var notices: [String] = [] }   // touched on the main actor only

    private func listen() -> Heard {
        let heard = Heard()
        noticeObservers.append(NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                MainActor.assumeIsolated { heard.notices.append(message) }
            }
        })
        return heard
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        lockedPaths.append(url)
    }

    // MARK: - The card editor's own saves: one version per editing run

    func test_theCardEditorsOwnSavesKeepOneVersionPerEditingRun() async throws {
        let (store, projectStore) = try await openBook()
        let first = try await card("The harbour at dawn.", in: projectStore)
        let id = first.researchItemId
        let before = try onDisk(id, projectStore)
        let keptBefore = versions(id).count
        let reloadsBefore = store.researchNoteReloadCount(itemId: id)
        PaletteCardEditor.markRead(id, in: projectStore)

        for body in ["The harbour at dawn. Gulls.", "The harbour at dawn. Gulls, rope.",
                     "The harbour at dawn. Gulls, rope, tar."] {
            let saved = await PaletteCardEditor.persistDraft(
                withBody(first, body), baselineTitle: first.title, in: projectStore)
            XCTAssertEqual(saved, first.title)
            clock.advance(seconds: 5)
        }

        XCTAssertEqual(versions(id).count, keptBefore + 1, "one version for the whole editing run")
        XCTAssertEqual(try versionTexts(id).last, before, "holding the text the run started from")
        XCTAssertEqual(store.researchNoteReloadCount(itemId: id), reloadsBefore,
                       "the editor's own saves never tell it to re-read")

        clock.advance(seconds: ResearchSaveRun.gap + 1)
        let lastRun = try onDisk(id, projectStore)
        _ = await PaletteCardEditor.persistDraft(
            withBody(first, "A new sitting."), baselineTitle: first.title, in: projectStore)
        XCTAssertEqual(versions(id).count, keptBefore + 2, "a pause past the run's gap starts a new run")
        XCTAssertEqual(try versionTexts(id).last, lastRun)
    }

    // MARK: - Anyone else's write: always keeps, ends the run, reloads the editor

    func test_aWriteBehindTheCardKeepsWhatItReplaces_andMovesItsReloadSignal() async throws {
        let (store, projectStore) = try await openBook()
        let first = try await card("Mine.", in: projectStore)
        let id = first.researchItemId
        PaletteCardEditor.markRead(id, in: projectStore)
        _ = await PaletteCardEditor.persistDraft(withBody(first, "Mine, typed."),
                                                 baselineTitle: first.title, in: projectStore)
        let typed = try onDisk(id, projectStore)
        clock.advance(seconds: 5)
        let reloadsBefore = store.researchNoteReloadCount(itemId: id)
        let keptBefore = versions(id).count

        try await projectStore.updatePaletteCard(withBody(first, "Promoted in."))

        XCTAssertEqual(versions(id).count, keptBefore + 1, "inside the writer's run, still kept")
        XCTAssertEqual(try versionTexts(id).last, typed)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: id), reloadsBefore + 1,
                       "an open card editor is told to re-read")
        XCTAssertEqual(versions(id).max(by: { $0.savedAt < $1.savedAt })?.replacedBy, .writer)

        // The run ended: the writer's next typed save keeps again.
        PaletteCardEditor.markRead(id, in: projectStore)
        let promoted = try onDisk(id, projectStore)
        clock.advance(seconds: 5)
        _ = await PaletteCardEditor.persistDraft(withBody(first, "Typed after."),
                                                 baselineTitle: first.title, in: projectStore)
        XCTAssertEqual(try versionTexts(id).last, promoted)
    }

    /// A card a store wired one way only (a load-only context) is still found
    /// by the door: the palette funnel names its own project store.
    func test_aStoreWiredOneWayStillWritesItsCardThroughTheDoor() async throws {
        let (store, projectStore) = try await openBook()
        store.projectStore = nil
        let first = try await card("One way.", in: projectStore)
        try await projectStore.updatePaletteCard(withBody(first, "Still the door."))
        XCTAssertEqual(try versionTexts(first.researchItemId).last.map { $0.contains("One way.") }, true)
    }

    // MARK: - A keep that fails

    /// Anyone else's write is refused when the version cannot be kept: the
    /// card is as it was and the caller is told.
    func test_aWriteWhoseVersionCannotBeKeptIsRefused_andTheCardIsAsItWas() async throws {
        let (_, projectStore) = try await openBook()
        let first = try await card("Kept safe.", in: projectStore)
        let before = try onDisk(first.researchItemId, projectStore)
        try lock(try ResearchVersionStore(projectURL: projectURL).folderURL(forItem: first.researchItemId))
        let heard = listen()

        do {
            try await projectStore.updatePaletteCard(withBody(first, "Over it."))
            XCTFail("a refused card write must throw")
        } catch ProjectStoreError.researchTextNotSaved(let title) {
            XCTAssertEqual(title, "Harbour")
        }
        XCTAssertEqual(try onDisk(first.researchItemId, projectStore), before)
        XCTAssertTrue(heard.notices.contains { $0.contains("previous version couldn’t be kept") }, "\(heard.notices)")
    }

    /// The card editor's typed save lands even then (its draft is the only
    /// other copy of what the writer typed), and says so.
    func test_theCardEditorsSaveLandsWhenItsVersionCannotBeKept_andSaysSo() async throws {
        let (_, projectStore) = try await openBook()
        let first = try await card("Kept safe.", in: projectStore)
        try lock(try ResearchVersionStore(projectURL: projectURL).folderURL(forItem: first.researchItemId))
        let heard = listen()

        let saved = await PaletteCardEditor.persistDraft(withBody(first, "Typed anyway."),
                                                         baselineTitle: first.title, in: projectStore)
        XCTAssertEqual(saved, first.title)
        XCTAssertTrue(try onDisk(first.researchItemId, projectStore).contains("Typed anyway."))
        XCTAssertTrue(heard.notices.contains { $0.contains("couldn’t be kept; your edits were saved anyway") },
                      "\(heard.notices)")
    }

    // MARK: - Restore

    func test_aCardsVersionRestores_andTheRestoreIsItselfUndoable() async throws {
        let (store, projectStore) = try await openBook()
        let first = try await card("The first draft.", in: projectStore)
        let id = first.researchItemId
        let original = try onDisk(id, projectStore)
        try await projectStore.updatePaletteCard(withBody(first, "The second."))
        let version = try XCTUnwrap(versions(id).first {
            (try? ResearchVersionStore(projectURL: projectURL).read($0).0) == Data(original.utf8)
        })

        try await store.restoreResearchNote(itemId: id, to: version, shareIsReadOnly: false)

        XCTAssertEqual(try onDisk(id, projectStore), original)
        XCTAssertEqual(projectStore.loadPaletteCards().first { $0.researchItemId == id }?.body
                           .contains("The first draft."), true)
        XCTAssertTrue(try versionTexts(id).contains { $0.contains("The second.") },
                      "what the restore replaced is kept, so restoring again undoes it")
    }

    // MARK: - The Versions surface

    func test_aCardsInspectorListsVersions_andCallsItACard() async throws {
        let (_, projectStore) = try await openBook()
        let first = try await card("Words.", in: projectStore)
        let item = try XCTUnwrap(projectStore.findResearchItem(id: first.researchItemId,
                                                                in: projectStore.manifest.research))
        let structure = projectStore.manifest.structure
        XCTAssertEqual(ResearchVersionsModel.kind(for: item, structure: structure), .note,
                       "a card's inspector shows the Versions section, restoring through the note door")
        XCTAssertEqual(ResearchVersionsModel.noun(for: item, structure: structure), "card")
        XCTAssertEqual(ProjectWindow.researchCentreRoute(id: item.id, in: projectStore.manifest),
                       .paletteCard(item.id), "and it is still edited as a card, never as a note")
    }

    // MARK: - Versions follow the item id

    func test_aTrashedCardKeepsItsVersions_andPermanentDeleteSweepsThem() async throws {
        let (_, projectStore) = try await openBook()
        let first = try await card("Words.", in: projectStore)
        let id = first.researchItemId
        try await projectStore.updatePaletteCard(withBody(first, "More words."))
        let kept = versions(id).count
        XCTAssertGreaterThan(kept, 0)

        try await projectStore.deleteResearchItems(ids: [id])
        await projectStore.sweepResearchVersions()
        XCTAssertEqual(versions(id).count, kept, "the Trash keeps a card's versions")
        let entry = try XCTUnwrap(projectStore.trashEntries.first)
        try await projectStore.restoreTrashEntry(id: entry.id)
        XCTAssertEqual(versions(id).count, kept, "restored, they list again")

        try await projectStore.deleteResearchItems(ids: [id])
        try await projectStore.permanentlyDeleteTrashEntry(id: try XCTUnwrap(projectStore.trashEntries.first?.id))
        XCTAssertTrue(versions(id).isEmpty, "Permanently Delete sweeps this device's versions of the card")
    }
}
