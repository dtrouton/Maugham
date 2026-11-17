import XCTest
import MaughamCore
@testable import Maugham

/// **The piece verbs enter the in-flight span** (#145, F3).
///
/// A Collection piece's reorder and rename move the piece's whole folder,
/// its `research/` folder included, through `relocateUserContent`. From just
/// before the mover until the in-memory manifest names the new place, a note
/// save from anyone but the verb finds the note's file missing; inside
/// `ProjectStore.withResearchItemsInFlight` it takes the note door's
/// "being moved" route (`NoteLookup.beingMoved`, #142 T2) and is never
/// written afresh at the old path. Each test holds the verb open between two
/// of its coordinated moves (`DocumentStore.afterCoordinatedMoveForTesting`)
/// and saves from outside the verb's task, as the assistant or the writer's
/// ⌘S would.
@MainActor
final class PieceVerbSpanTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var noticeObservers: [NSObjectProtocol] = []

    override func tearDown() async throws {
        DocumentStore.afterCoordinatedMoveForTesting = nil
        for observer in noticeObservers { NotificationCenter.default.removeObserver(observer) }
        noticeObservers = []
        for store in stores { await store.close() }
        stores = []
        try await super.tearDown()
    }

    static let beingMoved = "it was being moved or deleted just then"

    // MARK: - Fixture

    /// A Collection of two loose pieces, Alpha (01) and Beta (02), with a
    /// note "Notes" in Alpha's research folder holding `Before.`, read by the
    /// door.
    private func collection() async throws -> (DocumentStore, ProjectStore, alpha: StructureItem,
                                               beta: StructureItem, note: ResearchItem) {
        let parent = TestTemp.root.appendingPathComponent("piece-span-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createCollectionProject(named: "Span", in: parent)
        let projectStore = try await ProjectStore.load(from: projectURL)
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let alpha = try await projectStore.addLoosePiece(title: "Alpha", format: .markdown)
        let beta = try await projectStore.addLoosePiece(title: "Beta", format: .markdown)
        let note = try await projectStore.addPieceResearchNote(pieceId: alpha.id, title: "Notes")
        let path = try XCTUnwrap(note.path)
        try Data("Before.".utf8).write(to: file(path))
        store.researchNoteWasRead(itemId: note.id, bytes: Data("Before.".utf8))
        return (store, projectStore, alpha, beta, note)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: file(path).path) }
    private func contents(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: file(path)), as: UTF8.self)
    }

    private func pathNow(_ item: ResearchItem, _ projectStore: ProjectStore) throws -> String {
        try XCTUnwrap(projectStore.findResearchItem(id: item.id, in: projectStore.manifest.research)?.path)
    }

    private func conflictBackups() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: file(".maugham/conflicts").path)) ?? []
    }

    /// Every `.md` file under `pieces/` named like the note, wherever it is.
    private func copiesOfTheNote(named leaf: String) -> [String] {
        let pieces = file("pieces").resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: pieces, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == leaf }
            .map { "pieces/" + String($0.resolvingSymlinksInPath().path.dropFirst(pieces.path.count + 1)) }
            .sorted()
    }

    @MainActor private final class Box<T> { var value: T? }
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

    /// A verb started in its own task and held after the first coordinated
    /// move `parkAfter` accepts, until `release()`. The test's own saves run
    /// outside the verb's task, so they are never the verb's own.
    @MainActor private final class HeldVerb {
        var gate: CheckedContinuation<Void, Never>?
        var task: Task<Void, Never>?
        var error: Error?
        func release() async {
            gate?.resume()
            gate = nil
            await task?.value
        }
    }

    private func hold(parkAfter parks: @escaping (URL, URL) -> Bool,
                      _ verb: @escaping @MainActor () async throws -> Void) async -> HeldVerb {
        let held = HeldVerb()
        let parked = Box<Bool>()
        await withCheckedContinuation { (atTheMove: CheckedContinuation<Void, Never>) in
            DocumentStore.afterCoordinatedMoveForTesting = { from, to in
                guard parked.value == nil, parks(from, to) else { return }
                parked.value = true
                await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                    held.gate = gate
                    atTheMove.resume()
                }
            }
            held.task = Task { @MainActor in
                do { try await verb() } catch { held.error = error }
            }
        }
        DocumentStore.afterCoordinatedMoveForTesting = nil
        return held
    }

    // MARK: - Reorder (both phases of the temp-name swap)

    /// Review Focus 1: a flush landing while the reorder's folders sit at
    /// their TEMP names (between phase A and phase B) writes nothing at the
    /// old path or the temp path; the writer's text is kept as a conflict
    /// backup and the door says the note was being moved.
    func test_aFlushDuringAReordersTempPhaseWritesNothing_andSaysTheNoteIsBeingMoved() async throws {
        let (store, projectStore, alpha, _, note) = try await collection()
        let heard = listen()
        let oldPath = try XCTUnwrap(note.path)
        let leaf = (oldPath as NSString).lastPathComponent
        let alphaFolder = ((try XCTUnwrap(alpha.path)) as NSString).deletingLastPathComponent

        // Phase A moves Beta's folder, then Alpha's, to their temp names.
        let held = await hold(parkAfter: { from, to in
            from.path.hasSuffix(alphaFolder) && to.lastPathComponent.contains("-mv-")
        }) {
            try await projectStore.movePiece(pieceId: alpha.id, toIndex: 1)
        }
        XCTAssertFalse(exists(oldPath), "premise: the folder is at its temp name")

        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: note.id, text: "Flushed mid-reorder.")
        try await store.flushPendingSave()
        XCTAssertFalse(exists(oldPath), "nothing is written at the old path")
        let backups = conflictBackups()
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try contents(".maugham/conflicts/\(backup)"), "Flushed mid-reorder.")
        XCTAssertEqual(heard.notices,
            ["Couldn’t save “Notes”: \(Self.beingMoved). Your edits were kept in the project’s .maugham/conflicts folder as “\(backup)”."])

        await held.release()
        XCTAssertNil(held.error, "the reorder completes")
        let newPath = try pathNow(note, projectStore)
        XCTAssertNotEqual(newPath, oldPath, "premise: the piece was renumbered")
        XCTAssertEqual(copiesOfTheNote(named: leaf), [newPath],
                       "one copy of the note, where the manifest says; none at the old or temp path")
        XCTAssertEqual(try contents(newPath), "Before.")
        XCTAssertTrue(projectStore.researchItemsInFlight.isEmpty, "the span ended")
    }

    /// The same span covers phase B: the assistant's save landing after the
    /// first folder reached its new name, before the rest have, is not made
    /// and is said; no file appears at the old path.
    func test_aDirectSaveDuringAReordersSecondPhaseIsNotMade_andSaysTheNoteIsBeingMoved() async throws {
        let (store, projectStore, alpha, _, note) = try await collection()
        let heard = listen()
        let oldPath = try XCTUnwrap(note.path)
        let leaf = (oldPath as NSString).lastPathComponent

        let held = await hold(parkAfter: { from, _ in from.lastPathComponent.contains("-mv-") }) {
            try await projectStore.movePiece(pieceId: alpha.id, toIndex: 1)
        }

        let saved = await store.saveResearchNote(itemId: note.id, text: "The assistant's change.", by: .assistant)
        XCTAssertEqual(saved, .notSaved)
        XCTAssertFalse(exists(oldPath), "nothing is written at the old path")
        XCTAssertEqual(heard.notices, ["Couldn’t save “Notes”: \(Self.beingMoved)."])

        await held.release()
        XCTAssertNil(held.error, "the reorder completes")
        let newPath = try pathNow(note, projectStore)
        XCTAssertEqual(copiesOfTheNote(named: leaf), [newPath])
        XCTAssertEqual(try contents(newPath), "Before.")
        XCTAssertTrue(conflictBackups().isEmpty, "a direct write is not the writer's text: nothing kept aside")
    }

    /// The span covers every piece whose folder the reorder renumbers, not
    /// only the one dragged: moving Beta to the top renumbers Alpha's folder
    /// too, and a save of Alpha's note mid-move takes the same route.
    func test_aReorderHoldsTheNotesOfEveryPieceItRenumbers() async throws {
        let (store, projectStore, alpha, beta, note) = try await collection()
        let oldPath = try XCTUnwrap(note.path)
        let alphaFolder = ((try XCTUnwrap(alpha.path)) as NSString).deletingLastPathComponent

        let held = await hold(parkAfter: { from, _ in from.path.hasSuffix(alphaFolder) }) {
            try await projectStore.movePiece(pieceId: beta.id, toIndex: 0)
        }
        XCTAssertTrue(projectStore.researchItemsInFlight.contains(note.id),
                      "Alpha's note is in the span though Beta was the piece moved")

        let saved = await store.saveResearchNote(itemId: note.id, text: "The assistant's change.", by: .assistant)
        XCTAssertEqual(saved, .notSaved)
        XCTAssertFalse(exists(oldPath))

        await held.release()
        XCTAssertNil(held.error)
        XCTAssertEqual(try contents(try pathNow(note, projectStore)), "Before.")
    }

    // MARK: - Rename

    /// A flush landing after a rename moved the piece's folder, before the
    /// manifest names the new place, writes nothing at the old path and keeps
    /// the text aside; once the rename ends, a save lands at the new path.
    func test_aFlushDuringAPieceRenameWritesNothingAtTheOldPath_andSaysTheNoteIsBeingMoved() async throws {
        let (store, projectStore, alpha, _, note) = try await collection()
        let heard = listen()
        let oldPath = try XCTUnwrap(note.path)
        let leaf = (oldPath as NSString).lastPathComponent

        let held = await hold(parkAfter: { _, _ in true }) {
            try await projectStore.renamePiece(pieceId: alpha.id, newTitle: "Omega")
        }
        XCTAssertFalse(exists(oldPath), "premise: the folder has moved")

        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: note.id, text: "Flushed mid-rename.")
        try await store.flushPendingSave()
        XCTAssertFalse(exists(oldPath), "nothing is written at the old path")
        let backups = conflictBackups()
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try contents(".maugham/conflicts/\(backup)"), "Flushed mid-rename.")
        XCTAssertEqual(heard.notices,
            ["Couldn’t save “Notes”: \(Self.beingMoved). Your edits were kept in the project’s .maugham/conflicts folder as “\(backup)”."])

        await held.release()
        XCTAssertNil(held.error, "the rename completes")
        let newPath = try pathNow(note, projectStore)
        XCTAssertTrue(newPath.contains("omega"), newPath)
        XCTAssertEqual(copiesOfTheNote(named: leaf), [newPath])
        XCTAssertTrue(projectStore.researchItemsInFlight.isEmpty, "the span ended")

        let after = await store.saveResearchNote(itemId: note.id, text: "After the rename.", by: .assistant)
        XCTAssertEqual(after, .saved(keptAVersion: true))
        XCTAssertEqual(try contents(newPath), "After the rename.")
        XCTAssertEqual(copiesOfTheNote(named: leaf), [newPath])
    }

    // MARK: - Trash

    /// A piece's Delete moves only its manuscript file to the Trash: its
    /// research folder stays where it is, so it moves no Research file and
    /// holds no span. Its note is byte-identical at its path afterwards, and
    /// nothing named like it appears anywhere else.
    func test_trashingAPieceMovesNoResearchFile() async throws {
        let (_, projectStore, alpha, _, note) = try await collection()
        let path = try XCTUnwrap(note.path)
        let leaf = (path as NSString).lastPathComponent

        try await projectStore.deleteStructureItem(id: alpha.id)
        XCTAssertFalse(exists(try XCTUnwrap(alpha.path)), "premise: the piece's file went to the Trash")
        XCTAssertEqual(try contents(path), "Before.")
        XCTAssertEqual(copiesOfTheNote(named: leaf), [path])
        XCTAssertTrue(projectStore.researchItemsInFlight.isEmpty)
    }
}
