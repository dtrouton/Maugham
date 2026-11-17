import XCTest
import Observation
@testable import Maugham
@testable import MaughamCore

/// **Every save of a Research note keeps the previous version** (note
/// versions plan 2, Task 2): `DocumentStore.saveResearchNote` — the note
/// door — keeps the bytes on disk before it writes, as the table door does
/// (`ResearchTableHost.write`): a writer's run keeps one (`ResearchSaveRun`),
/// every assistant save one, bytes the store never read or an outside change
/// one. The run rule's clock is the door's `now`, never the wall.
@MainActor
final class ResearchNoteDoorTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var lockedPaths: [URL] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("notedoor-\(UUID().uuidString)")
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
        DocumentStore.beforeCoordinatedWriteForTesting = nil
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

    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
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

    /// A note made the way the writer makes one, holding `text` on disk.
    private func note(_ text: String, in projectStore: ProjectStore) async throws -> ResearchItem {
        let item = try await projectStore.createResearchNote(scope: .shared, title: "Notes")
        try Data(text.utf8).write(to: file(try XCTUnwrap(item.path)))
        return item
    }

    /// The note's item as the manifest has it now (its path may have moved).
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

    private func versionText(_ version: ResearchVersion) throws -> String {
        String(decoding: try ResearchVersionStore(projectURL: projectURL).read(version).0, as: UTF8.self)
    }

    /// The store read the note's bytes as they are on disk now.
    private func read(_ item: ResearchItem, _ store: DocumentStore, _ projectStore: ProjectStore) throws {
        store.researchNoteWasRead(itemId: item.id, bytes: Data(try text(of: item, projectStore).utf8))
    }

    private final class Clock: @unchecked Sendable {   // touched on the main actor only
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(seconds: Double) { date = date.addingTimeInterval(seconds) }
    }
    private let clock = Clock()

    private final class Heard: @unchecked Sendable { var notices: [String] = [] }   // touched on the main actor only
    private var noticeObservers: [NSObjectProtocol] = []

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

    /// The editor's own save of `text` (its debounced edit, flushed now):
    /// the writer's typing run, which a direct save is not.
    private func typed(_ text: String, into item: ResearchItem, _ store: DocumentStore) async throws {
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: text)
        try await store.flushPendingSave()
    }

    private func lock(_ url: URL, _ permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        lockedPaths.append(url)
    }

    // MARK: - The run

    func test_theFirstSaveOfARunKeepsTheTextBeforeIt_andTheNextSaveInsideTheGapKeepsNothing() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the run.", in: projectStore)
        try read(item, store, projectStore)

        try await typed("First pause.", into: item, store)
        XCTAssertEqual(versions(of: item).count, 1)
        XCTAssertEqual(try versionText(try XCTUnwrap(versions(of: item).first)), "Before the run.")
        XCTAssertEqual(versions(of: item).first?.payload, .note)
        XCTAssertEqual(versions(of: item).first?.replacedBy, .writer)

        clock.advance(seconds: 60)
        try await typed("Second pause.", into: item, store)
        XCTAssertEqual(versions(of: item).count, 1, "a save inside the run keeps nothing")
        XCTAssertEqual(try text(of: item, projectStore), "Second pause.")
    }

    func test_aSaveAfterTheGapKeepsAgain() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the run.", in: projectStore)
        try read(item, store, projectStore)
        try await typed("First pause.", into: item, store)

        clock.advance(seconds: ResearchSaveRun.gap + 1)
        try await typed("After a long pause.", into: item, store)
        XCTAssertEqual(versions(of: item).count, 2)
    }

    func test_aSaveOverBytesTheStoreNeverReadKeepsAVersion() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Never read here.", in: projectStore)
        // A caller that never read the note (no `researchNoteWasRead`).
        let saved = await store.saveResearchNote(itemId: item.id, text: "Over it.")
        XCTAssertEqual(saved, .saved(keptAVersion: true))
        XCTAssertEqual(try versions(of: item).map(versionText), ["Never read here."])
    }

    func test_anOutsideChangeIsKept() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the run.", in: projectStore)
        try read(item, store, projectStore)
        try await typed("Mine.", into: item, store)
        XCTAssertEqual(versions(of: item).count, 1)

        // Another Mac (or a Finder edit) rewrites the note inside the run.
        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        clock.advance(seconds: 30)
        try await typed("Mine again.", into: item, store)
        XCTAssertEqual(versions(of: item).count, 2, "bytes the store did not write are kept")
        XCTAssertTrue(try versions(of: item).map(versionText).contains("From outside."))
    }

    // MARK: - Hardening 11-11 task 2.4: the bytes read are the bytes written over (#138 R3)

    /// Lands each of `landings` in turn on the file at `path` as the save
    /// enters its coordinated write (after the door read it), one per save
    /// attempt; nothing once they run out.
    private func landOutside(_ landings: [String], at path: URL) {
        var left = landings
        DocumentStore.beforeCoordinatedWriteForTesting = {
            guard !left.isEmpty else { return }
            try? Data(left.removeFirst().utf8).write(to: path)
        }
    }

    private func unsavedBackups(of item: ResearchItem) -> [URL] {
        let folder = file(".maugham/conflicts")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.contains("-\(item.id)-unsaved-") }.sorted().map { folder.appendingPathComponent($0) }
    }

    private static let changedWhileSaving = "it changed outside Maugham while it was being saved."

    /// **Bytes written outside between the door's read and its write are
    /// never written over unseen**: the save finds them inside its
    /// coordinated write, reads again, keeps them as a version, then saves.
    func test_bytesWrittenOutsideAfterTheReadAreKeptAsAVersionBeforeTheSave() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        landOutside(["From outside."], at: file(try XCTUnwrap(item.path)))

        try await typed("Mine.", into: item, store)

        XCTAssertEqual(try text(of: item, projectStore), "Mine.", "the editor's text is saved")
        XCTAssertEqual(Set(try versions(of: item).map(versionText)), ["Before.", "From outside."],
                       "the run's start and the outside bytes, each kept once")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
        XCTAssertEqual(heard.notices, [Self.changedWhileEditing], "said once, across the retry")
    }

    private static let changedWhileEditing =
        "“Notes” changed outside Maugham while you were editing it. That version is kept in its Versions; yours was saved."
    private static let reloaded = "Reloaded “Notes” — the file changed outside Maugham."

    // MARK: - Hardening 11-16 task 1.7: an outside change is heard (#141 N3, RULING-62)

    /// The window's file presenter hears `item`'s file change, and the
    /// door's answer to it is awaited.
    private func presenterHears(_ item: ResearchItem, _ store: DocumentStore,
                                _ projectStore: ProjectStore) async throws {
        let url = file(try XCTUnwrap(current(item, projectStore).path))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.heardForTesting = { id in
                guard id == item.id else { return }
                store.researchNoteDoor.heardForTesting = nil
                done.resume()
            }
            store.presenterDidChangeSubitem(at: url)
        }
    }

    func test_anOutsideChangeToACleanNoteReloadsItAndSaysSo() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        store.researchNoteOpened(itemId: item.id)
        let reloads = store.researchNoteReloadCount(itemId: item.id)

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        try await presenterHears(item, store, projectStore)

        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads + 1, "the open editor is told to read it")
        XCTAssertEqual(heard.notices, [Self.reloaded])
        // The same change heard again (a presenter burst) is not a second change.
        try await presenterHears(item, store, projectStore)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads + 1)
        XCTAssertEqual(heard.notices, [Self.reloaded], "said once")
        // The outside text ended the writer's run: their next typing keeps it.
        try await typed("Mine.", into: item, store)
        XCTAssertTrue(try versions(of: item).map(versionText).contains("From outside."))
    }

    /// **Review Focus 3**: what the door itself wrote (a typed save, anyone
    /// else's save, a card's template) and bytes it read with a BOM are its
    /// own: heard back, they reload nothing and say nothing.
    func test_theDoorsOwnSaveComingBackIsNotAnOutsideChange() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("", in: projectStore)
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("With a BOM.\r\n".utf8)
        try bom.write(to: file(try XCTUnwrap(item.path)))
        store.researchNoteWasRead(itemId: item.id, bytes: bom)
        store.researchNoteOpened(itemId: item.id)
        let reloads = store.researchNoteReloadCount(itemId: item.id)

        try await presenterHears(item, store, projectStore)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads, "the BOM file as read")

        try await typed("Typed.", into: item, store)
        try await presenterHears(item, store, projectStore)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads, "the editor's own save")

        await store.saveResearchNote(itemId: item.id, text: "The assistant's.", by: .assistant)
        let afterDirect = store.researchNoteReloadCount(itemId: item.id)
        try await presenterHears(item, store, projectStore)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), afterDirect, "anyone else's save")

        let card = try await projectStore.addPaletteCard(title: "Harbour", kind: .location)
        store.researchNoteOpened(itemId: card.id)
        let cardReloads = store.researchNoteReloadCount(itemId: card.id)
        try await presenterHears(card, store, projectStore)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: card.id), cardReloads, "a card's template")

        XCTAssertEqual(heard.notices, [], "nothing is said")
    }

    /// Anyone else's save over an outside change keeps it, as it always
    /// has, and is not "you were editing it": nothing of the writer's was.
    func test_anotherWritersSaveOverAnOutsideChangeIsNotSaidAsTheWritersEdit() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        let saved = await store.saveResearchNote(itemId: item.id, text: "The assistant's.", by: .assistant)

        XCTAssertEqual(saved, .saved(keptAVersion: true))
        XCTAssertEqual(try versions(of: item).map(versionText), ["From outside."])
        XCTAssertEqual(heard.notices, [])
    }

    /// **Review Focus 4**: a note this store never read has nothing on
    /// screen to be stale; a change to it is not news.
    func test_anOutsideChangeToANoteNobodyReadSaysNothing() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Never read.", in: projectStore)
        store.researchNoteOpened(itemId: item.id)   // open, but its bytes were never read
        let reloads = store.researchNoteReloadCount(itemId: item.id)

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        try await presenterHears(item, store, projectStore)

        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads)
        XCTAssertEqual(heard.notices, [])
    }

    /// **The open hold is one suspension that cancellation ends, and it is
    /// balanced**: two editors holding a note keep it open until both are
    /// cancelled; a hold cancelled before it ever starts raises and lowers
    /// once each, leaving the count where it was.
    /// Disable experiment: lower the count twice (or not at all) in
    /// `holdResearchNoteOpen` and a step below fails.
    func test_theOpenHoldEndsOnCancellationAndIsBalanced() async throws {
        let (store, _) = try await openBook()
        let door = store.researchNoteDoor
        let first = Task { await store.holdResearchNoteOpen(itemId: "n1") }
        let second = Task { await store.holdResearchNoteOpen(itemId: "n1") }
        while !door.isOpen("n1") { await Task.yield() }
        first.cancel()
        await first.value
        XCTAssertTrue(door.isOpen("n1"), "the second editor still holds it")
        second.cancel()
        await second.value
        XCTAssertFalse(door.isOpen("n1"), "both let go: not open")

        let early = Task { await store.holdResearchNoteOpen(itemId: "n2") }
        early.cancel()
        await early.value
        XCTAssertFalse(door.isOpen("n2"), "raised then lowered once, even cancelled before it started")
        let again = Task { await store.holdResearchNoteOpen(itemId: "n2") }
        while !door.isOpen("n2") { await Task.yield() }
        again.cancel()
        await again.value
        XCTAssertFalse(door.isOpen("n2"), "and the count did not go negative: one hold, one release")
    }

    /// **Review Focus 4, a note known but not open**: one the writer read
    /// and has left. Nothing is on screen to reload, so nothing moves and
    /// nothing is said; the next save still keeps the outside bytes.
    func test_anOutsideChangeToANoteNoLongerOpenSaysNothing_andTheNextSaveKeepsIt() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        store.researchNoteOpened(itemId: item.id)
        store.researchNoteLetGo(itemId: item.id)
        let reloads = store.researchNoteReloadCount(itemId: item.id)

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        try await presenterHears(item, store, projectStore)

        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads)
        XCTAssertEqual(heard.notices, [])
        await store.saveResearchNote(itemId: item.id, text: "Later.")
        XCTAssertTrue(try versions(of: item).map(versionText).contains("From outside."),
                      "the outside bytes were not made the door's own")
    }

    /// The same for a note only the assistant's `add_note` wrote (its body
    /// through the door, by the assistant, must land): known, never open.
    func test_anOutsideChangeToANoteOnlyAddNoteWroteSaysNothing() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        await store.saveResearchNote(itemId: item.id, text: "The assistant's note.", by: .assistant, mustLand: true)
        let reloads = store.researchNoteReloadCount(itemId: item.id)

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        try await presenterHears(item, store, projectStore)

        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads)
        XCTAssertEqual(heard.notices, [])
        await store.saveResearchNote(itemId: item.id, text: "Later.")
        XCTAssertTrue(try versions(of: item).map(versionText).contains("From outside."))
    }

    /// And for a new card's template (known, never opened).
    func test_anOutsideChangeToANewCardNobodyOpenedSaysNothing() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let card = try await projectStore.addPaletteCard(title: "Harbour", kind: .location)
        let reloads = store.researchNoteReloadCount(itemId: card.id)

        try Data("# Harbour\n\nFrom outside.\n".utf8).write(to: file(try XCTUnwrap(current(card, projectStore).path)))
        try await presenterHears(card, store, projectStore)

        XCTAssertEqual(store.researchNoteReloadCount(itemId: card.id), reloads)
        XCTAssertEqual(heard.notices, [])
    }

    /// **A save that starts and ends while the door reads the file** (the
    /// assistant's, needing no pending edit) is no outside change: the
    /// bytes read are stale, and the door asks again.
    func test_aSaveDuringTheDoorsReadIsNotAnOutsideChange() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        store.researchNoteOpened(itemId: item.id)
        let reloads = store.researchNoteReloadCount(itemId: item.id)
        // The presenter fires (a burst; nothing changed); the door reads
        // "Before.", and the assistant's save lands before that read resumes.
        store.researchNoteDoor.outsideReadWillResumeForTesting = {
            store.researchNoteDoor.outsideReadWillResumeForTesting = nil
            await store.saveResearchNote(itemId: item.id, text: "The assistant's.", by: .assistant)
        }
        try await presenterHears(item, store, projectStore)

        XCTAssertEqual(try text(of: item, projectStore), "The assistant's.")
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads + 1, "only the assistant's own reload")
        XCTAssertEqual(heard.notices, [], "nothing is said")
    }

    /// **The writer typed between the "Reloaded" notice and the editor's
    /// re-read**: the editor kept their text, so the save that covers the
    /// outside bytes says so, once.
    func test_typingBeforeAnOutsideReloadLandsIsSaidWhenItsSaveKeepsTheOutsideBytes() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        store.researchNoteOpened(itemId: item.id)

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        try await presenterHears(item, store, projectStore)
        // No `researchNoteWasRead`: the editor had an edit pending and did not reload.
        try await typed("Before. Mine.", into: item, store)

        XCTAssertTrue(try versions(of: item).map(versionText).contains("From outside."))
        XCTAssertEqual(heard.notices, [Self.reloaded, Self.changedWhileEditing])
        try await typed("Before. Mine, more.", into: item, store)
        XCTAssertEqual(heard.notices, [Self.reloaded, Self.changedWhileEditing], "said once")
    }

    /// A presenter path whose case differs from the manifest's (a
    /// case-insensitive volume) still finds the note.
    func test_aPresenterPathInAnotherCaseFindsTheNote() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        store.researchNoteOpened(itemId: item.id)
        let path = try XCTUnwrap(item.path)
        _ = try XCTUnwrap(store.researchNoteItem(atPath: path.uppercased()), "the lookup ignores case")

        try Data("From outside.".utf8).write(to: file(path))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.heardForTesting = { id in
                guard id == item.id else { return }
                store.researchNoteDoor.heardForTesting = nil
                done.resume()
            }
            store.presenterDidChangeSubitem(at: file(path.uppercased()))
        }
        XCTAssertEqual(heard.notices, [Self.reloaded])
    }

    /// The writer's pending edit is never discarded: the change heard under
    /// it waits for the save, which keeps the outside bytes (here, a change
    /// before its read and another during its write: the retry) and says so
    /// once, when the writer's text has landed.
    func test_anOutsideChangeUnderAPendingEditIsKeptAsAVersion_andSaidOnce() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        store.researchNoteOpened(itemId: item.id)
        let reloads = store.researchNoteReloadCount(itemId: item.id)
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: "Mine.")

        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        try await presenterHears(item, store, projectStore)
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads, "the edit is not reloaded over")
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id), "the edit is still pending")
        XCTAssertEqual(heard.notices, [], "nothing is said before the save")

        landOutside(["Again outside."], at: file(try XCTUnwrap(item.path)))
        try await store.flushPendingSave()
        try await presenterHears(item, store, projectStore)

        XCTAssertEqual(try text(of: item, projectStore), "Mine.", "the writer's text is saved")
        XCTAssertEqual(Set(try versions(of: item).map(versionText)), ["From outside.", "Again outside."])
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), reloads)
        XCTAssertEqual(heard.notices, [Self.changedWhileEditing], "said once, across the retry")
    }

    /// A note file that was missing at the read and made outside before the
    /// write (`FileExpectation.absent`) is kept too, not written over.
    func test_aFileMadeOutsideWhereNoneWasReadIsKeptBeforeTheSave() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await projectStore.createResearchNote(scope: .shared, title: "Missing")
        let path = file(try XCTUnwrap(item.path))
        try FileManager.default.removeItem(at: path)
        landOutside(["Made outside."], at: path)

        let saved = await store.saveResearchNote(itemId: item.id, text: "Into the missing note.")

        XCTAssertEqual(saved, .saved(keptAVersion: true))
        XCTAssertEqual(try text(of: item, projectStore), "Into the missing note.")
        XCTAssertEqual(try versions(of: item).map(versionText), ["Made outside."])
    }

    /// **A second change on the retry is not written over either**; a
    /// flush's text — the last copy there is — is kept aside and named, and
    /// the first change is kept as a version.
    func test_aSecondChangeOnAFlushesRetryKeepsTheEditAside() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        landOutside(["First outside.", "Second outside."], at: file(try XCTUnwrap(item.path)))

        try await typed("The only copy of this.", into: item, store)

        XCTAssertEqual(try text(of: item, projectStore), "Second outside.", "the file is as the outside last wrote it")
        XCTAssertEqual(Set(try versions(of: item).map(versionText)), ["Before.", "First outside."],
                       "the run's start and the first change, each kept once")
        let backups = unsavedBackups(of: item)
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "The only copy of this.")
        XCTAssertEqual(heard.notices, [
            "Couldn’t save “Notes”: \(Self.changedWhileSaving) Your edits were kept in the project’s "
                + ".maugham/conflicts folder as “\(backup.lastPathComponent)”."
        ])
    }

    /// A timer's text stays pending on a second change, said once.
    func test_aSecondChangeOnATimersRetryLeavesTheEditPending() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        landOutside(["First outside.", "Second outside."], at: file(try XCTUnwrap(item.path)))

        store.researchNoteDoor.saveDelay = .zero
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.timerSaveFinishedForTesting = { _ in done.resume() }
            store.scheduleNoteSave(itemId: item.id, text: "Typed.")
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil

        XCTAssertEqual(try text(of: item, projectStore), "Second outside.", "nothing written over it")
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id), "the edit is still pending")
        XCTAssertEqual(heard.notices, [
            "Couldn’t save “Notes” yet: \(Self.changedWhileSaving) Your edits stay in the editor and are saved when you leave the note."
        ])
        try await store.flushPendingSave()
        XCTAssertEqual(try text(of: item, projectStore), "Typed.", "the flush saves it")
        XCTAssertTrue(try versions(of: item).map(versionText).contains("Second outside."), "over a kept version")
    }

    /// Anyone else's write is not made on a second change, and said.
    func test_aSecondChangeOnADirectSavesRetryIsNotMade() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        landOutside(["First outside.", "Second outside."], at: file(try XCTUnwrap(item.path)))

        let saved = await store.saveResearchNote(itemId: item.id, text: "Over it.", by: .assistant)

        XCTAssertEqual(saved, .notSaved)
        XCTAssertEqual(try text(of: item, projectStore), "Second outside.")
        XCTAssertEqual(heard.notices, ["Couldn’t save “Notes”: \(Self.changedWhileSaving)"])
    }

    // MARK: - Hardening 11-17 task 5: a caller's expectation is compare-and-swap (#147 R2)

    /// A caller that made its text from bytes no longer on disk is turned
    /// away: nothing written, nothing kept, nothing said, no reload.
    func test_aSaveExpectingOtherBytesWritesNothing_andAnswersChangedSinceTheCallerRead() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("From outside.", in: projectStore)

        let saved = await store.saveResearchNote(itemId: item.id, text: "Replaced.",
                                                 expectingBytesHash: ContentHash.of(Data("Before.".utf8)))

        XCTAssertEqual(saved, .changedSinceTheCallerRead)
        XCTAssertEqual(try text(of: item, projectStore), "From outside.")
        XCTAssertTrue(versions(of: item).isEmpty, "nothing was kept")
        XCTAssertEqual(heard.notices, [], "the caller answers for it")
        XCTAssertEqual(store.researchNoteReloadCount(itemId: item.id), 0)
    }

    /// The expectation met, the save is made as any direct save is.
    func test_aSaveExpectingTheBytesOnDiskIsMade() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)

        let saved = await store.saveResearchNote(itemId: item.id, text: "Replaced.",
                                                 expectingBytesHash: ContentHash.of(Data("Before.".utf8)))

        XCTAssertEqual(saved, .saved(keptAVersion: true))
        XCTAssertEqual(try text(of: item, projectStore), "Replaced.")
        XCTAssertEqual(try versions(of: item).map(versionText), ["Before."])
    }

    /// Bytes landing after the door's own read are found by the coordinated
    /// write; the door's retry reads them, and they fail the caller's
    /// expectation: they stand, and are not kept. The first pass had already
    /// kept the bytes the caller read (a direct save always keeps what it
    /// replaces), so that version remains though nothing was written.
    func test_aChangeLandingAfterTheDoorsReadFailsTheCallersExpectationOnTheRetry() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        landOutside(["From outside."], at: file(try XCTUnwrap(item.path)))

        let saved = await store.saveResearchNote(itemId: item.id, text: "Replaced.",
                                                 expectingBytesHash: ContentHash.of(Data("Before.".utf8)))

        XCTAssertEqual(saved, .changedSinceTheCallerRead)
        XCTAssertEqual(try text(of: item, projectStore), "From outside.")
        XCTAssertEqual(try versions(of: item).map(versionText), ["Before."],
                       "the first pass's version of the bytes read remains; the outside bytes were not kept")
        XCTAssertEqual(heard.notices, [])
    }

    // MARK: - The prior file

    func test_aMissingOrEmptyFileKeepsNothingAndSaves() async throws {
        let (store, projectStore) = try await openBook()
        // Empty: a note just made.
        let empty = try await projectStore.createResearchNote(scope: .shared, title: "Empty")
        let first = await store.saveResearchNote(itemId: empty.id, text: "Into the empty note.")
        XCTAssertEqual(first, .saved(keptAVersion: false))
        XCTAssertEqual(try text(of: empty, projectStore), "Into the empty note.")
        XCTAssertTrue(versions(of: empty).isEmpty)

        // Missing: the file is not there at all.
        let missing = try await projectStore.createResearchNote(scope: .shared, title: "Missing")
        try FileManager.default.removeItem(at: file(try XCTUnwrap(missing.path)))
        let second = await store.saveResearchNote(itemId: missing.id, text: "Into the missing note.")
        XCTAssertEqual(second, .saved(keptAVersion: false))
        XCTAssertEqual(try text(of: missing, projectStore), "Into the missing note.")
        XCTAssertTrue(versions(of: missing).isEmpty)
    }

    /// RULING-7's behaviour stays: a file that is there but will not read is
    /// never saved over. The door reads bytes (UTF-8 is not its question), so
    /// "will not read" is a file the read throws on: one with no read
    /// permission, and a directory where the note's file should be.
    func test_anUnreadableFileIsNotSavedOver() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()

        let locked = try await note("Not readable.", in: projectStore)
        let lockedURL = file(try XCTUnwrap(locked.path))
        try lock(lockedURL, 0o000)
        let refused = await store.saveResearchNote(itemId: locked.id, text: "Over it.")
        XCTAssertEqual(refused, .notSaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedURL.path)
        XCTAssertEqual(try text(of: locked, projectStore), "Not readable.", "nothing written over it")
        XCTAssertTrue(versions(of: locked).isEmpty)

        let folder = try await projectStore.createResearchNote(scope: .shared, title: "Folder")
        let folderURL = file(try XCTUnwrap(folder.path))
        try FileManager.default.removeItem(at: folderURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        let alsoRefused = await store.saveResearchNote(itemId: folder.id, text: "Over it.")
        XCTAssertEqual(alsoRefused, .notSaved)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the directory is left as it was")

        XCTAssertEqual(heard.notices.filter { $0.contains("couldn’t read “") }.count, 2,
                       "each refusal is said: \(heard.notices)")
    }

    // MARK: - Where and what

    /// Review Focus 3: the path is asked at the save, so a note moved between
    /// the schedule and the save is written where it now is, and its version
    /// belongs to its id.
    func test_aNoteMovedBetweenScheduleAndSaveIsWrittenWhereItNowIs() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the move.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        let group = try await projectStore.addResearchItem(parentId: nil, title: "World", kind: nil)
        try await projectStore.moveResearchItems(ids: [item.id], to: .group(group.id))
        let newPath = try XCTUnwrap(current(item, projectStore).path)
        XCTAssertNotEqual(newPath, oldPath, "precondition: the note moved")

        let saved = await store.saveResearchNote(itemId: item.id, text: "After the move.")
        XCTAssertEqual(saved, .saved(keptAVersion: true))
        XCTAssertEqual(String(decoding: try Data(contentsOf: file(newPath)), as: UTF8.self), "After the move.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(oldPath).path),
                       "nothing is written where it was")
        XCTAssertEqual(try versions(of: item).map(versionText), ["Before the move."])
    }

    /// The move lands while the keep is off the main actor: the door asks
    /// the path again after it, so the text is written where the note now is
    /// — not at the stale path, which would make a second file. The bytes
    /// kept were read at the old path; a move carries the same bytes, so
    /// they are exactly what the write replaces.
    func test_aNoteMovedDuringTheKeepIsWrittenWhereItNowIs() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the move.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        let newPath = "research/moved-during-the-keep.md"
        // The typed mover flushes (and so waits for this save) before it moves,
        // so it cannot run inside the keep; the move is made by hand here, as
        // the manifest and the disk would show it.
        store.researchNoteDoor.keepWillRunForTesting = { [self] in
            try? FileManager.default.moveItem(at: file(oldPath), to: file(newPath))
            projectStore.manifest.research = projectStore.manifest.research.map { top in
                var top = top
                if top.id == item.id { top.path = newPath }
                return top
            }
        }

        let saved = await store.saveResearchNote(itemId: item.id, text: "After the move.")
        XCTAssertEqual(saved, .saved(keptAVersion: true))
        XCTAssertEqual(try current(item, projectStore).path, newPath, "premise: the note moved")
        XCTAssertEqual(String(decoding: try Data(contentsOf: file(newPath)), as: UTF8.self), "After the move.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(oldPath).path),
                       "nothing is written at the path it had when the save began")
        XCTAssertEqual(try versions(of: item).map(versionText), ["Before the move."])
    }

    /// P3 (Denver, 2026-11-11: as built; RULING-24's amendment): an edit whose
    /// debounce elapsed is not saved over a version that cannot be kept, and is
    /// not dropped either — the flush still has it.
    func test_aTimerSaveWhoseKeepFailsStops_andTheTextIsStillPendingForTheFlush() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Kept or not saved over.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(ResearchVersionStore.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lock(folder, 0o555)

        // The debounce's own timer, at no delay, awaited by its hook — no
        // clock. Two typing pauses: the notice is said once, not per pause.
        store.researchNoteDoor.saveDelay = .zero
        for typed in ["Typ", "Typed."] {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.researchNoteDoor.timerSaveFinishedForTesting = { _ in done.resume() }
                store.scheduleNoteSave(itemId: item.id, text: typed)
            }
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil
        XCTAssertEqual(heard.notices.filter { $0.contains("aren’t saved yet") }.count, 1,
                       "said once, not once per typing pause: \(heard.notices)")

        XCTAssertEqual(try text(of: item, projectStore), "Kept or not saved over.", "the timer's save stopped")
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id), "the edit is still pending")
        XCTAssertTrue(heard.notices.contains(
            "“Notes”’s previous version couldn’t be kept, so your edits aren’t saved yet. They stay in the editor and are saved when you leave the note."),
            "\(heard.notices)")

        try await store.flushPendingSave()
        XCTAssertEqual(try text(of: item, projectStore), "Typed.", "the flush saved what the timer could not")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    /// Fix round 1: a flush takes each note out of `pending` only as its own
    /// save begins. A door write to a note still waiting its turn flushes
    /// that note's edit first (kept as the version it replaces) — never the
    /// stale edit written over the door's text afterwards.
    func test_aDoorWriteDuringAFlushToANoteNotYetReachedKeepsItsEditAndIsNotOverwritten() async throws {
        let (store, projectStore) = try await openBook()
        let one = try await note("One.", in: projectStore)
        let two = try await note("Two.", in: projectStore)
        try read(one, store, projectStore)
        try read(two, store, projectStore)
        let (first, second) = one.id < two.id ? (one, two) : (two, one)
        store.scheduleNoteSave(itemId: first.id, text: "First, typed.")
        store.scheduleNoteSave(itemId: second.id, text: "T")

        var fired = false
        var direct: ResearchNoteSave?
        store.researchNoteDoor.keepWillRunForTesting = {
            guard !fired else { return }
            fired = true   // the first note's keep: the second has not been reached
            direct = await store.saveResearchNote(itemId: second.id, text: "B")
        }
        try await store.flushPendingSave()

        XCTAssertEqual(direct, .saved(keptAVersion: true))
        XCTAssertEqual(try text(of: second, projectStore), "B", "the stale edit was not written over B")
        XCTAssertEqual(try versions(of: second).first.map(versionText), "T",
                       "the edit is the version B replaced")
        XCTAssertEqual(try text(of: first, projectStore), "First, typed.")
    }

    /// A flush is the last moment the editor's text exists (a note switch,
    /// ⌘S, the mover, the close): it saves even when the version cannot be
    /// kept, and says so — the spec's anti-goal is losing text to a failed keep.
    func test_aFlushSavesEvenWhenTheVersionCannotBeKept_andSaysSo() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Not kept.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(ResearchVersionStore.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lock(folder, 0o555)

        store.scheduleNoteSave(itemId: item.id, text: "Saved anyway.")
        try await store.flushPendingSave()

        XCTAssertEqual(try text(of: item, projectStore), "Saved anyway.")
        XCTAssertEqual(heard.notices, ["“Notes”’s previous version couldn’t be kept; your edits were saved anyway."])
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    /// **"Saved anyway" is said once, after the write lands** (task 2.4 fix
    /// round 1): a keep that fails, then an outside change that makes the
    /// door read again (whose keep fails too) — the note lands and the
    /// sentence is posted exactly once.
    func test_aSaveAnywayRetriedAfterAnOutsideChangeSaysSoOnce() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Not kept.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(ResearchVersionStore.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lock(folder, 0o555)
        landOutside(["From outside."], at: file(try XCTUnwrap(item.path)))

        try await typed("Saved anyway.", into: item, store)

        XCTAssertEqual(try text(of: item, projectStore), "Saved anyway.")
        XCTAssertEqual(heard.notices, ["“Notes”’s previous version couldn’t be kept; your edits were saved anyway."])
    }

    /// **And never when the write does not land**: a keep that fails, then
    /// a change on the retry too — the flush's text is kept aside and only
    /// that is said; nothing claims it was saved.
    func test_aSaveAnywayWhoseWriteNeverLandsNeverSaysSaved() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Not kept.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(ResearchVersionStore.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lock(folder, 0o555)
        landOutside(["First outside.", "Second outside."], at: file(try XCTUnwrap(item.path)))

        try await typed("The only copy of this.", into: item, store)

        XCTAssertEqual(try text(of: item, projectStore), "Second outside.")
        let backup = try XCTUnwrap(unsavedBackups(of: item).first)
        XCTAssertEqual(heard.notices, [
            "Couldn’t save “Notes”: \(Self.changedWhileSaving) Your edits were kept in the project’s "
                + ".maugham/conflicts folder as “\(backup.lastPathComponent)”."
        ])
    }

    /// Controller ruling 4: a reader of one note's reload count is
    /// invalidated by another writer's save of THAT note only — not by a save
    /// of another note, and not by the editor's own debounced save.
    func test_theReloadCountIsObservedPerNote_andTheEditorsOwnSaveDoesNotMoveIt() async throws {
        let (store, projectStore) = try await openBook()
        let watched = try await note("Watched.", in: projectStore)
        let other = try await projectStore.createResearchNote(scope: .shared, title: "Other")
        try read(watched, store, projectStore)
        final class Fired: @unchecked Sendable { var count = 0 }   // touched on the main actor only
        let fired = Fired()
        func observe() {
            withObservationTracking {
                _ = store.researchNoteReloadCount(itemId: watched.id)
            } onChange: { fired.count += 1 }
        }

        observe()
        await store.saveResearchNote(itemId: other.id, text: "Another note.", by: .assistant)
        store.scheduleNoteSave(itemId: watched.id, text: "The editor's own.")
        try await store.flushPendingSave()
        XCTAssertEqual(fired.count, 0, "another note's write and the editor's own save invalidate nothing")
        XCTAssertEqual(store.researchNoteReloadCount(itemId: watched.id), 0)

        await store.saveResearchNote(itemId: watched.id, text: "Written behind.", by: .assistant)
        XCTAssertEqual(fired.count, 1, "a write behind the editor reaches its reader")
        XCTAssertEqual(store.researchNoteReloadCount(itemId: watched.id), 1)
    }

    func test_aKeepThatFailsStopsTheSave() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Kept or not saved over.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(ResearchVersionStore.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lock(folder, 0o555)

        let saved = await store.saveResearchNote(itemId: item.id, text: "Not landed.")
        XCTAssertEqual(saved, .notSaved, "P3's default: a keep that fails stops the save")
        XCTAssertEqual(try text(of: item, projectStore), "Kept or not saved over.")
        XCTAssertTrue(heard.notices.contains("“Notes”’s previous version couldn’t be kept, so your edits weren’t saved over it."),
                      "\(heard.notices)")
    }

    func test_theAssistantsSaveAlwaysKeeps_marksTheVersion_andEndsTheRun() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("The writer's.", in: projectStore)
        try read(item, store, projectStore)
        try await typed("The writer's run.", into: item, store)
        XCTAssertEqual(versions(of: item).count, 1)

        clock.advance(seconds: 10)
        let assistants = await store.saveResearchNote(itemId: item.id, text: "The assistant's.", by: .assistant)
        XCTAssertEqual(assistants, .saved(keptAVersion: true), "inside the writer's run, still kept")
        let marked = try XCTUnwrap(versions(of: item).first { (try? versionText($0)) == "The writer's run." })
        XCTAssertEqual(marked.replacedBy, .assistant)
        XCTAssertEqual(marked.writtenBy, .writer)

        clock.advance(seconds: 10)
        try await typed("The writer again.", into: item, store)
        XCTAssertEqual(try text(of: item, projectStore), "The writer again.")
        XCTAssertEqual(versions(of: item).count, 3, "the assistant's save ended the writer's run")
        let assistantsVersion = try XCTUnwrap(versions(of: item).first { (try? versionText($0)) == "The assistant's." })
        XCTAssertEqual(assistantsVersion.writtenBy, .assistant)
        XCTAssertEqual(assistantsVersion.replacedBy, .writer)
    }

    /// The scheduler's `flush()` can run a payload its own debounce task is
    /// already running (recon §4): the same text for the same note arrives
    /// twice at once, and lands once.
    func test_theSameTextArrivingTwiceWritesAndKeepsOnce() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        var writes: [String] = []
        store.researchNoteDoor.wroteForTesting = { id, _ in writes.append(id) }

        async let one = store.saveResearchNote(itemId: item.id, text: "Once.")
        async let two = store.saveResearchNote(itemId: item.id, text: "Once.")
        let results = await [one, two]

        XCTAssertEqual(results.filter { $0 == .saved(keptAVersion: true) }.count, 1, "\(results)")
        XCTAssertEqual(writes, [item.id], "written once")
        XCTAssertEqual(versions(of: item).count, 1, "kept once")
        XCTAssertEqual(try text(of: item, projectStore), "Once.")
    }

    /// A table is not the note door's, nor is an id that names nothing; a
    /// palette card is (cards keep versions as notes do, 2026-11-11).
    func test_aTableIsRefused_andACardIsTaken() async throws {
        let (store, projectStore) = try await openBook()
        let table = try await projectStore.addResearchTable(parentId: nil)
        let tableBytes = try Data(contentsOf: file(try XCTUnwrap(table.path)))
        let card = try await projectStore.addPaletteCard(title: "Harbour", kind: .location)

        let onTable = await store.saveResearchNote(itemId: table.id, text: "not,a,note")
        let onCard = await store.saveResearchNote(itemId: card.id, text: "# Harbour\n\nA card.\n")
        let onNothing = await store.saveResearchNote(itemId: "res-00000000", text: "Nothing.")
        XCTAssertEqual([onTable, onCard, onNothing], [.notSaved, .saved(keptAVersion: false), .notSaved])
        XCTAssertEqual(try Data(contentsOf: file(try XCTUnwrap(table.path))), tableBytes)
        XCTAssertEqual(try text(of: card, projectStore), "# Harbour\n\nA card.\n")
        XCTAssertTrue(versions(of: table).isEmpty)
        XCTAssertTrue(versions(of: card).isEmpty, "the card is taken, and keeps nothing over its blank template")
        XCTAssertNil(store.researchNoteItem(atPath: try XCTUnwrap(table.path)))
        XCTAssertEqual(store.researchNoteItem(atPath: try XCTUnwrap(card.path))?.id, card.id)
    }

    // MARK: - The debounced save and the lookup

    /// The editor's debounced save carries the item id, and its action is the door.
    func test_aScheduledNoteSaveGoesThroughTheDoor() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the pause.", in: projectStore)
        try read(item, store, projectStore)

        store.scheduleNoteSave(itemId: item.id, text: "After the pause.")
        try await store.flushPendingSave()

        XCTAssertEqual(try text(of: item, projectStore), "After the pause.")
        XCTAssertEqual(try versions(of: item).map(versionText), ["Before the pause."])
        XCTAssertEqual(try ResearchNoteRecord.read(forItem: item.id, in: projectURL),
                       ResearchNoteRecord(contentHash: ContentHash.of(Data("After the pause.".utf8)),
                                          writtenBy: .writer))
    }

    func test_aNotesPathFindsItsItem() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Here.", in: projectStore)
        XCTAssertEqual(store.researchNoteItem(atPath: try XCTUnwrap(item.path))?.id, item.id)
        XCTAssertNil(store.researchNoteItem(atPath: "research/nothing-here.md"))
    }

    /// The store's close waits for a save in flight (it settles the door).
    func test_flushPendingSaveWaitsForASaveInFlight() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)

        // The flush starts once the save is in flight (at its keep), so it
        // finds the save there whatever order the main actor runs them in.
        var flushing: Task<String?, Error>?
        store.researchNoteDoor.keepWillRunForTesting = { [self] in
            flushing = Task {
                try await store.flushPendingSave()
                return try? self.text(of: item, projectStore)   // what the flush left on disk
            }
        }
        let saved = await store.saveResearchNote(itemId: item.id, text: "Landed.")
        XCTAssertEqual(saved, .saved(keptAVersion: true))
        let onDiskWhenFlushed = try await XCTUnwrap(flushing).value
        XCTAssertEqual(onDiskWhenFlushed, "Landed.", "the flush returned only once the save had landed")
    }

    // MARK: - A file that will not take the text keeps the editor's (whole-branch Minor 2)

    /// A timer save whose WRITE fails (the note's folder will not take a
    /// file) leaves the edit pending, as a stopped keep does: the flush still
    /// has the text once the folder takes it.
    func test_aTimerSaveWhoseWriteFailsLeavesTheEditPending() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder, 0o555)

        store.researchNoteDoor.saveDelay = .zero
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.timerSaveFinishedForTesting = { _ in done.resume() }
            store.scheduleNoteSave(itemId: item.id, text: "Typed.")
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil
        XCTAssertEqual(try text(of: item, projectStore), "Before.", "premise: the write failed")
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id), "the edit is still pending")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try await store.flushPendingSave()
        XCTAssertEqual(try text(of: item, projectStore), "Typed.", "the flush saved what the timer could not")
    }

    /// A FLUSH whose write fails (a note switch, close, ⌘S: the last moment
    /// the editor's text exists) keeps that text as a conflict backup, and
    /// the notice names it — the text is not gone after the notice.
    func test_aFlushWhoseWriteFailsKeepsTheEditInAConflictBackup_andSaysSo() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder, 0o555)

        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: "The only copy of this.")
        try await store.flushPendingSave()

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertEqual(try text(of: item, projectStore), "Before.", "premise: the write failed")
        let conflicts = file(".maugham/conflicts")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: conflicts.path)) ?? []
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertTrue(backup.contains(item.id), backup)
        XCTAssertEqual(try String(contentsOf: conflicts.appendingPathComponent(backup), encoding: .utf8),
                       "The only copy of this.")
        XCTAssertTrue(heard.notices.contains { $0.contains("Couldn’t save “Notes”") && $0.contains(backup) },
                      "\(heard.notices)")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    /// **An edit whose note left Research is not dropped** (wave 2, round 2):
    /// the timer's save keeps it pending, and the flush keeps it as a conflict
    /// backup and names it. The note's file is not written.
    func test_anEditWhoseNoteLeftResearchIsKeptAsAConflictBackupAtTheFlush() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        projectStore.manifest.research.removeAll { $0.id == item.id }

        store.researchNoteDoor.saveDelay = .zero
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.timerSaveFinishedForTesting = { _ in done.resume() }
            store.scheduleNoteSave(itemId: item.id, text: "The only copy of this.")
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id), "the timer kept the edit")

        try await store.flushPendingSave()
        XCTAssertEqual(try String(contentsOf: file(try XCTUnwrap(item.path)), encoding: .utf8), "Before.")
        let conflicts = file(".maugham/conflicts")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: conflicts.path)) ?? []
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try String(contentsOf: conflicts.appendingPathComponent(backup), encoding: .utf8),
                       "The only copy of this.")
        XCTAssertTrue(heard.notices.contains { $0.contains("no longer in Research") && $0.contains(backup) },
                      "\(heard.notices)")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    /// A timer's save of a note that has stopped being one (a synced manifest
    /// pointed it at the manuscript) writes nothing there, keeps the edit
    /// pending and says, truthfully, that Maugham holds it.
    func test_aTimerSaveOfANoteThatStoppedBeingOneHoldsTheEdit_andWritesNothing() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let manuscript = try Data(contentsOf: file("manuscript/a.md"))
        projectStore.mutateResearchItem(id: item.id) { $0.path = "manuscript/a.md" }

        store.researchNoteDoor.saveDelay = .zero
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.timerSaveFinishedForTesting = { _ in done.resume() }
            store.scheduleNoteSave(itemId: item.id, text: "Typed.")
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id))
        XCTAssertEqual(try Data(contentsOf: file("manuscript/a.md")), manuscript)
        XCTAssertTrue(heard.notices.contains {
            $0.contains("no longer a Research note") && $0.contains("Maugham is holding your edits")
        }, "\(heard.notices)")
        store.researchNoteDoor.saveDelay = .seconds(3600)
    }

    /// A flush to a note whose path the project refuses (a folder link
    /// inside `research/` that leaves the project) keeps the text as a
    /// conflict backup and names it; nothing is written through the link.
    func test_aFlushToARefusedPathKeepsTheEditInAConflictBackup() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        let elsewhere = TestTemp.root.appendingPathComponent("elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: file("research/linked"), withDestinationURL: elsewhere)
        projectStore.mutateResearchItem(id: item.id) { $0.path = "research/linked/x.md" }

        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: "The only copy of this.")
        try await store.flushPendingSave()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing written there")
        let conflicts = file(".maugham/conflicts")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: conflicts.path)) ?? []
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try String(contentsOf: conflicts.appendingPathComponent(backup), encoding: .utf8),
                       "The only copy of this.")
        XCTAssertTrue(heard.notices.contains { $0.contains("isn’t a place inside this project") && $0.contains(backup) },
                      "\(heard.notices)")
    }

    /// A flush whose write fails AND whose conflict backup cannot be written
    /// says plainly that the edits were not saved.
    func test_aFlushWhoseWriteAndBackupBothFailSaysTheEditsWereNotSaved() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let conflicts = file(".maugham/conflicts")
        try FileManager.default.createDirectory(at: conflicts, withIntermediateDirectories: true)
        try lock(conflicts, 0o555)
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder, 0o555)

        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: "Typed.")
        try await store.flushPendingSave()

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: conflicts.path)
        XCTAssertEqual(try text(of: item, projectStore), "Before.", "premise: the write failed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: conflicts.path), [], "premise: no backup")
        XCTAssertTrue(heard.notices.contains {
            $0.contains("Couldn’t save “Notes”") && $0.contains("weren’t saved, and they couldn’t be kept anywhere else")
        }, "\(heard.notices)")
    }

    /// RULING-7 stays: a flush never saves over a file that will not read.
    /// The editor's text is the last copy there is, so it is kept as a
    /// conflict backup, and the notice says where.
    func test_aFlushOverAnUnreadableFileKeepsTheEditInAConflictBackup_andSaysSo() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Not readable.", in: projectStore)
        let noteURL = file(try XCTUnwrap(item.path))
        try lock(noteURL, 0o000)

        store.scheduleNoteSave(itemId: item.id, text: "The only copy of this.")
        try await store.flushPendingSave()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noteURL.path)
        XCTAssertEqual(try text(of: item, projectStore), "Not readable.", "nothing written over it")
        let conflicts = file(".maugham/conflicts")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: conflicts.path)) ?? []
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertTrue(backup.contains(item.id), backup)
        XCTAssertEqual(try String(contentsOf: conflicts.appendingPathComponent(backup), encoding: .utf8),
                       "The only copy of this.")
        XCTAssertTrue(heard.notices.contains { $0.contains("couldn’t read “Notes”") && $0.contains(backup) },
                      "\(heard.notices)")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    // MARK: - Only a note inside a research root (whole-branch C2)

    /// A synced manifest (stale, corrupt, or another Mac's) can list a
    /// `.document` Research item whose path is the manuscript or Maugham's
    /// own files. The door writes none of them, keeps no version, and the
    /// path → note lookup does not find them. A near miss (`research-old/`)
    /// and a dot component inside `research/` are refused too.
    func test_theDoorRefusesAPathOutsideAResearchRoot() async throws {
        let (store, projectStore) = try await openBook()
        let paths = ["manuscript/a.md", ".maugham/ops/stray.jsonl", "research-old/x.md",
                     "research/.hidden.md", "research/../manuscript/a.md"]
        var planted: [ResearchItem] = []
        for (n, path) in paths.enumerated() {
            let url = file(path)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("Not a note \(n).".utf8).write(to: url)
            }
            let item = ResearchItem(id: "res-stray00\(n)", title: "Stray \(n)", type: .asset,
                                    kind: .document, path: path)
            projectStore.manifest.research.append(item)
            planted.append(item)
        }
        for item in planted {
            let path = try XCTUnwrap(item.path)
            let before = try Data(contentsOf: file(path))
            for writer in [ResearchWriter.writer, .assistant] {
                let saved = await store.saveResearchNote(itemId: item.id, text: "Over it.", by: writer)
                XCTAssertEqual(saved, .notSaved, path)
            }
            XCTAssertEqual(try Data(contentsOf: file(path)), before, "\(path) is untouched")
            XCTAssertTrue(versions(of: item).isEmpty, "\(path): no version kept")
            XCTAssertNil(store.researchNoteItem(atPath: path), path)
            XCTAssertNil(ResearchTextRole.of(item, structure: projectStore.manifest.structure,
                                             research: projectStore.manifest.research), path)
        }
    }

    // MARK: - A verb moving the note (#142 T2)

    /// A structural verb's span over some Research items, built by hand as
    /// `test_aNoteMovedDuringTheKeepIsWrittenWhereItNowIs` builds its move:
    /// entered (`withResearchItemsInFlight`), then held open at its body's
    /// first line until `end()`, when the body runs its rest (the manifest
    /// naming the new place, or the row removed) and the span ends.
    @MainActor private final class Span {
        var release: CheckedContinuation<Void, Never>?
        var verb: Task<Void, Never>?
        func end() async {
            release?.resume()
            release = nil
            await verb?.value
        }
    }

    private func spanHeldOpen(over ids: [String], _ projectStore: ProjectStore,
                              then rest: @escaping @MainActor () async throws -> Void) async -> Span {
        let span = Span()
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            span.verb = Task { @MainActor in
                try? await projectStore.withResearchItemsInFlight(ids) {
                    await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                        span.release = gate
                        entered.resume()
                    }
                    try await rest()
                }
            }
        }
        return span
    }

    @MainActor private final class Box<T> { var value: T? }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: file(path).path) }
    private func contents(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: file(path)), as: UTF8.self)
    }

    /// The editor's debounced save of `text`, run by its own timer at no
    /// delay and awaited by the door's hook — no clock.
    private func timerSave(_ text: String, of item: ResearchItem, _ store: DocumentStore) async {
        store.researchNoteDoor.saveDelay = .zero
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.timerSaveFinishedForTesting = { _ in done.resume() }
            store.scheduleNoteSave(itemId: item.id, text: text)
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil
    }

    private func conflictBackups() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: file(".maugham/conflicts").path)) ?? []
    }

    static let beingMoved = "it was being moved or deleted just then"

    /// A timer's save that finds the note's file gone while a verb is moving
    /// it writes nothing at the old path: its text stays pending, and when
    /// the span ends its timer is set again, so it lands where the note now
    /// is without another keystroke.
    func test_aTimerSaveOfANoteAVerbIsMovingWritesNothingAtTheOldPath_andStaysPending() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before the move.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        let newPath = "research/moved-by-a-verb.md"
        let span = await spanHeldOpen(over: [item.id], projectStore) {
            projectStore.mutateResearchItem(id: item.id) { $0.path = newPath }
        }
        try FileManager.default.moveItem(at: file(oldPath), to: file(newPath))

        await timerSave("Typed during the move.", of: item, store)
        XCTAssertFalse(exists(oldPath), "nothing is written at the path the verb is moving it from")
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id), "the edit stays pending")
        XCTAssertEqual(try contents(newPath), "Before the move.")
        XCTAssertEqual(heard.notices, [], "a timer's stop mid-move says nothing: its text lands after")

        // The span ends: the timer is set again (no keystroke), and its own
        // save lands at the new path. Asked directly first, so a timer that
        // is not set again fails here rather than leaving the test waiting.
        let landed = Box<Bool>()
        let waiter = Box<CheckedContinuation<Void, Never>>()
        store.researchNoteDoor.timerSaveFinishedForTesting = { _ in
            landed.value = true
            waiter.value?.resume()
            waiter.value = nil
        }
        await span.end()
        let setAgain = store.researchNoteDoor.timerIsSetForTesting(item.id) || landed.value == true
        XCTAssertTrue(setAgain, "the span's end set the timer again")
        guard setAgain else { return }
        if landed.value != true {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in waiter.value = done }
        }
        store.researchNoteDoor.timerSaveFinishedForTesting = nil
        XCTAssertEqual(try contents(newPath), "Typed during the move.")
        XCTAssertFalse(exists(oldPath))
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    /// A flush (a note switch, ⌘S) that finds the file gone mid-move writes
    /// nothing at the old path and never waits on the verb: the writer's text
    /// is kept as a conflict backup and named, once.
    func test_aFlushOfANoteAVerbIsMovingWritesNothingAtTheOldPath_andKeepsTheTextAside() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before the move.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        let newPath = "research/moved-by-a-verb.md"
        store.researchNoteDoor.saveDelay = .seconds(3600)
        let span = await spanHeldOpen(over: [item.id], projectStore) {
            projectStore.mutateResearchItem(id: item.id) { $0.path = newPath }
        }
        try FileManager.default.moveItem(at: file(oldPath), to: file(newPath))
        store.scheduleNoteSave(itemId: item.id, text: "Flushed during the move.")

        try await store.flushPendingSave()   // returns with the span still open
        XCTAssertFalse(exists(oldPath), "nothing is written at the path the verb is moving it from")
        XCTAssertEqual(try contents(newPath), "Before the move.")
        let backups = conflictBackups()
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try contents(".maugham/conflicts/\(backup)"), "Flushed during the move.")
        XCTAssertEqual(heard.notices,
            ["Couldn’t save “Notes”: \(Self.beingMoved). Your edits were kept in the project’s .maugham/conflicts folder as “\(backup)”."])
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))

        await span.end()
        XCTAssertFalse(exists(oldPath))
        XCTAssertEqual(try contents(newPath), "Before the move.")
    }

    /// A direct save (the assistant, Replace) landing while the note is being
    /// trashed is not made and is said; no file is made at the old path.
    func test_aDirectSaveDuringATrashWritesNothing_andSaysTheNoteIsGone() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before the trash.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        let span = await spanHeldOpen(over: [item.id], projectStore) {
            projectStore.removeResearchItem(id: item.id)
        }
        try FileManager.default.removeItem(at: file(oldPath))

        let saved = await store.saveResearchNote(itemId: item.id, text: "The assistant's change.", by: .assistant)
        XCTAssertEqual(saved, .notSaved)
        XCTAssertFalse(exists(oldPath), "a note being trashed has no file made again")
        XCTAssertEqual(heard.notices, ["Couldn’t save “Notes”: \(Self.beingMoved)."])

        await span.end()
        XCTAssertFalse(exists(oldPath))
        XCTAssertTrue(conflictBackups().isEmpty, "a direct write is not the writer's text: nothing kept aside")
    }

    /// Review Focus 3: with no verb moving it, a note whose file was deleted
    /// outside Maugham is written afresh by the editor's save, as before.
    func test_anEditorSaveOfANoteDeletedOutsideStillRecreatesIt() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let path = try XCTUnwrap(item.path)
        try FileManager.default.removeItem(at: file(path))

        await timerSave("Typed by the timer.", of: item, store)
        XCTAssertEqual(try contents(path), "Typed by the timer.", "the timer's save writes it afresh")

        try FileManager.default.removeItem(at: file(path))
        try await typed("Flushed.", into: item, store)
        XCTAssertEqual(try contents(path), "Flushed.", "so does a flush")
    }

    /// A real move of a note with an edit pending: the mover's own flush runs
    /// inside the verb's span and is not turned away by it, and the edit is
    /// in the moved file.
    func test_theMoversOwnFlushIsNeverHeld() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before the move.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        let group = try await projectStore.addResearchItem(parentId: nil, title: "World", kind: nil)
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: "Pending when the move began.")

        try await projectStore.moveResearchItems(ids: [item.id], to: .group(group.id))
        let newPath = try XCTUnwrap(current(item, projectStore).path)
        XCTAssertNotEqual(newPath, oldPath, "premise: the note moved")
        XCTAssertEqual(try contents(newPath), "Pending when the move began.")
        XCTAssertFalse(exists(oldPath))
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
        XCTAssertTrue(conflictBackups().isEmpty)
        XCTAssertEqual(heard.notices, [])
    }

    /// The same, for a note whose file was deleted outside Maugham before the
    /// move: the mover's own flush finds it missing INSIDE the span and is
    /// still its own (`ResearchItemsMoving`): it writes the file afresh, as
    /// before, and the move carries it.
    func test_theMoversOwnFlushOfANoteDeletedOutsideIsNeverHeld() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        try FileManager.default.removeItem(at: file(oldPath))
        let group = try await projectStore.addResearchItem(parentId: nil, title: "World", kind: nil)
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: "Pending when the move began.")

        try await projectStore.moveResearchItems(ids: [item.id], to: .group(group.id))
        let newPath = try XCTUnwrap(current(item, projectStore).path)
        XCTAssertNotEqual(newPath, oldPath, "premise: the note moved")
        XCTAssertEqual(try contents(newPath), "Pending when the move began.")
        XCTAssertFalse(exists(oldPath))
        XCTAssertTrue(conflictBackups().isEmpty, "the mover's own flush was written, not kept aside")
        XCTAssertEqual(heard.notices, [])
    }

    /// Review finding 1 (fix round 1): an outside save of a note deleted
    /// outside Maugham, enqueued before the verb and parked before its read,
    /// is the save the mover's own flush waits for — and its own pending
    /// edit's save is queued behind it. Released once the verb's span is
    /// open, it reads the file missing inside the span: it is not made (no
    /// phantom at the old path), it waits on nothing, and the move completes
    /// with the edit the mover's flush saved.
    func test_anOutsideSaveThatReadsInsideTheSpanNeitherWaitsNorWritesAtTheOldPath() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let oldPath = try XCTUnwrap(item.path)
        try FileManager.default.removeItem(at: file(oldPath))
        let group = try await projectStore.addResearchItem(parentId: nil, title: "World", kind: nil)
        store.researchNoteDoor.saveDelay = .seconds(3600)

        // T0, the assistant's save, parked between its lookup and its read.
        let parked = Box<CheckedContinuation<Void, Never>>()
        let t0Saved = Box<ResearchNoteSave>()
        var outside: Task<Void, Never>!
        await withCheckedContinuation { (atTheRead: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.willReadForTesting = { _ in
                await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                    parked.value = gate
                    atTheRead.resume()
                }
            }
            outside = Task { @MainActor in
                t0Saved.value = await store.saveResearchNote(
                    itemId: item.id, text: "The assistant's change.", by: .assistant)
            }
        }
        store.researchNoteDoor.willReadForTesting = nil
        // The writer types after it: the mover's flush saves this, queued behind T0.
        store.scheduleNoteSave(itemId: item.id, text: "Typed after it.")

        // The move begins; its flush enqueues the pending edit inside the span.
        let moveError = Box<Error>()
        var move: Task<Void, Never>!
        await withCheckedContinuation { (flushing: CheckedContinuation<Void, Never>) in
            store.researchNoteDoor.enqueuedForTesting = { id in
                if id == item.id, projectStore.researchItemsInFlight.contains(id) { flushing.resume() }
            }
            move = Task { @MainActor in
                do { try await projectStore.moveResearchItems(ids: [item.id], to: .group(group.id)) }
                catch { moveError.value = error }
            }
        }
        store.researchNoteDoor.enqueuedForTesting = nil
        XCTAssertTrue(projectStore.researchItemsInFlight.contains(item.id), "premise: the span is open")

        parked.value?.resume()
        await outside.value
        await move.value

        XCTAssertNil(moveError.value, "the move completes")
        XCTAssertEqual(t0Saved.value, .notSaved, "T0 is not made")
        XCTAssertEqual(heard.notices, ["Couldn’t save “Notes”: \(Self.beingMoved)."])
        let newPath = try XCTUnwrap(current(item, projectStore).path)
        XCTAssertNotEqual(newPath, oldPath, "premise: the note moved")
        XCTAssertFalse(exists(oldPath), "nothing is left at the old path")
        XCTAssertEqual(try contents(newPath), "Typed after it.", "the mover's flush saved the newer edit")
        XCTAssertFalse(try versions(of: item).map(versionText).contains("The assistant's change."),
                       "T0's text was never written anywhere")
    }

    // MARK: - A destroyed note takes its files with it (#148 D4; N7's production path)

    /// The record and versions a real save made — not files planted by the
    /// test — go when the note is destroyed for good: deleted to the Trash,
    /// they stay; Permanently Delete removes them (M3-TR-067).
    func test_aNoteSavedThroughTheDoorThenDestroyedLeavesNoRecordOrVersions() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try read(item, store, projectStore)
        let saved = await store.saveResearchNote(itemId: item.id, text: "The assistant's.", by: .assistant)
        XCTAssertEqual(saved, .saved(keptAVersion: true))
        let record = try ResearchNoteRecord.fileURL(forItem: item.id, in: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "premise: the save wrote its record")
        XCTAssertEqual(try ResearchNoteRecord.read(forItem: item.id, in: projectURL)?.writtenBy, .assistant)
        XCTAssertEqual(versions(of: item).count, 1, "premise: the save kept a version")

        try await projectStore.deleteResearchItems(ids: [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "an item in the Trash keeps its record")
        XCTAssertEqual(versions(of: item).count, 1, "and its versions")
        try await projectStore.permanentlyDeleteTrashEntry(id: try XCTUnwrap(projectStore.trashEntries.first?.id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path), "the record is gone")
        XCTAssertTrue(versions(of: item).isEmpty, "the versions are gone")
    }
}
