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

    private func lock(_ url: URL, _ permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        lockedPaths.append(url)
    }

    // MARK: - The run

    func test_theFirstSaveOfARunKeepsTheTextBeforeIt_andTheNextSaveInsideTheGapKeepsNothing() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the run.", in: projectStore)
        try read(item, store, projectStore)

        let first = await store.saveResearchNote(itemId: item.id, text: "First pause.")
        XCTAssertEqual(first, .saved(keptAVersion: true))
        XCTAssertEqual(versions(of: item).count, 1)
        XCTAssertEqual(try versionText(try XCTUnwrap(versions(of: item).first)), "Before the run.")
        XCTAssertEqual(versions(of: item).first?.payload, .note)
        XCTAssertEqual(versions(of: item).first?.replacedBy, .writer)

        clock.advance(seconds: 60)
        let second = await store.saveResearchNote(itemId: item.id, text: "Second pause.")
        XCTAssertEqual(second, .saved(keptAVersion: false))
        XCTAssertEqual(versions(of: item).count, 1, "a save inside the run keeps nothing")
        XCTAssertEqual(try text(of: item, projectStore), "Second pause.")
    }

    func test_aSaveAfterTheGapKeepsAgain() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before the run.", in: projectStore)
        try read(item, store, projectStore)
        await store.saveResearchNote(itemId: item.id, text: "First pause.")

        clock.advance(seconds: ResearchSaveRun.gap + 1)
        let later = await store.saveResearchNote(itemId: item.id, text: "After a long pause.")
        XCTAssertEqual(later, .saved(keptAVersion: true))
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
        await store.saveResearchNote(itemId: item.id, text: "Mine.")
        XCTAssertEqual(versions(of: item).count, 1)

        // Another Mac (or a Finder edit) rewrites the note inside the run.
        try Data("From outside.".utf8).write(to: file(try XCTUnwrap(item.path)))
        clock.advance(seconds: 30)
        let saved = await store.saveResearchNote(itemId: item.id, text: "Mine again.")
        XCTAssertEqual(saved, .saved(keptAVersion: true), "bytes the store did not write are kept")
        XCTAssertEqual(versions(of: item).count, 2)
        XCTAssertTrue(try versions(of: item).map(versionText).contains("From outside."))
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

    /// Controller's interim ruling on P3: an edit whose debounce elapsed is
    /// not saved over a version that cannot be kept, and is not dropped
    /// either — the flush still has it.
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

    /// A flush is the last moment the editor's text exists (a note switch,
    /// ⌘S, the mover, the close): it saves even when the version cannot be
    /// kept, and says so — the spec's anti-goal is losing text to a failed keep.
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
        XCTAssertTrue(heard.notices.contains("“Notes”’s previous version couldn’t be kept; your edits were saved anyway."),
                      "\(heard.notices)")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
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
        await store.saveResearchNote(itemId: item.id, text: "The writer's run.")
        XCTAssertEqual(versions(of: item).count, 1)

        clock.advance(seconds: 10)
        let assistants = await store.saveResearchNote(itemId: item.id, text: "The assistant's.", by: .assistant)
        XCTAssertEqual(assistants, .saved(keptAVersion: true), "inside the writer's run, still kept")
        let marked = try XCTUnwrap(versions(of: item).first { (try? versionText($0)) == "The writer's run." })
        XCTAssertEqual(marked.replacedBy, .assistant)
        XCTAssertEqual(marked.writtenBy, .writer)

        clock.advance(seconds: 10)
        let writers = await store.saveResearchNote(itemId: item.id, text: "The writer again.")
        XCTAssertEqual(writers, .saved(keptAVersion: true), "the assistant's save ended the writer's run")
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

    /// P2's default: palette cards are not notes, and neither is a table.
    func test_aNonNoteIsRefused() async throws {
        let (store, projectStore) = try await openBook()
        let table = try await projectStore.addResearchTable(parentId: nil)
        let tableBytes = try Data(contentsOf: file(try XCTUnwrap(table.path)))
        let card = try await projectStore.addPaletteCard(title: "Harbour", kind: .location)
        let cardBytes = try Data(contentsOf: file(try XCTUnwrap(card.path)))

        let onTable = await store.saveResearchNote(itemId: table.id, text: "not,a,note")
        let onCard = await store.saveResearchNote(itemId: card.id, text: "Not a note.")
        let onNothing = await store.saveResearchNote(itemId: "res-00000000", text: "Nothing.")
        XCTAssertEqual([onTable, onCard, onNothing], [.notSaved, .notSaved, .notSaved])
        XCTAssertEqual(try Data(contentsOf: file(try XCTUnwrap(table.path))), tableBytes)
        XCTAssertEqual(try Data(contentsOf: file(try XCTUnwrap(card.path))), cardBytes)
        XCTAssertTrue(versions(of: table).isEmpty)
        XCTAssertTrue(versions(of: card).isEmpty)
        XCTAssertNil(store.researchNoteItem(atPath: try XCTUnwrap(table.path)))
        XCTAssertNil(store.researchNoteItem(atPath: try XCTUnwrap(card.path)))
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
}
