import XCTest
import MaughamCore
@testable import Maugham

/// **What the tree's research door tells the writer when a move leaves
/// picture links behind** (v0.48.0 merge, #148 D2 through the shell's one
/// move door). Four routes: a direct move (no question), a held move once
/// answered, a held delete whose lifts leave links, and lifts that land
/// before the move itself fails.
///
/// Asked of the functions that make the sentence — `BinderTreeVerbs.said`
/// over `performPlan` / `performHeld`, exactly what `requestMove`,
/// `confirmHeld` and `performSaying` hand to the alert — never a mounted
/// press and a wait (tripwire 33).
@MainActor
final class ResearchMoveDoorSaysTests: XCTestCase {

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []
    /// The folders a failed rewrite made read-only, made writable again by
    /// the door's notice and at teardown.
    private final class Locked: @unchecked Sendable {
        var folders: [URL] = []
        func unlockAll() {
            for folder in folders {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
        }
    }
    private let lockedBox = Locked()
    private var locked: [URL] { lockedBox.folders }
    private var noticeToken: NSObjectProtocol?

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        lockedBox.unlockAll()
        lockedBox.folders.removeAll()
        if let noticeToken { NotificationCenter.default.removeObserver(noticeToken) }
        noticeToken = nil
        for ds in documentStores {
            ds.researchNoteDoor.keepWillRunForTesting = nil
            await ds.close()
        }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Fixtures

    private func novel() async throws -> (ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store   // both ways: the note door finds notes through it
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return (store, ds)
    }

    private func path(_ id: String, _ store: ProjectStore) throws -> String {
        try XCTUnwrap(TreeWalk.find(id: id, in: store.manifest.research)?.path)
    }

    /// `note` gets a picture in its own `<stem>_assets` folder and a link to
    /// it; a `<stem>_assets` already taken in `destinationFolder` (relative
    /// to the project) dedups the moved note's stem, so its links need
    /// rewriting.
    private func picture(_ note: ResearchItem, takenIn destinationFolder: String,
                         _ store: ProjectStore, _ ds: DocumentStore) async throws {
        let noteURL = store.url.appendingPathComponent(try path(note.id, store))
        let stem = noteURL.deletingPathExtension().lastPathComponent
        let assets = noteURL.deletingLastPathComponent().appendingPathComponent("\(stem)_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assets.appendingPathComponent("img.png"))
        try await ds.coordinatedWrite(text: "![img](./\(stem)_assets/img.png)", to: noteURL)
        try FileManager.default.createDirectory(
            at: store.url.appendingPathComponent(destinationFolder).appendingPathComponent("\(stem)_assets"),
            withIntermediateDirectories: true)
    }

    /// The next note-door keep (the rewrite's) runs with the note's folder
    /// read-only, so the rewrite cannot land; the door's "Couldn’t save"
    /// notice makes the folder writable again, so what follows the rewrite
    /// (a delete's Trash, a manifest save) runs on a writable disk.
    private func failTheNextRewrite(of noteId: String, _ store: ProjectStore, _ ds: DocumentStore) {
        let box = lockedBox
        ds.researchNoteDoor.keepWillRunForTesting = { [box, store, ds] in
            ds.researchNoteDoor.keepWillRunForTesting = nil
            guard let path = TreeWalk.find(id: noteId, in: store.manifest.research)?.path else { return }
            let folder = store.url.appendingPathComponent(path).deletingLastPathComponent()
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            box.folders.append(folder)
        }
        noticeToken = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { [box] note in
            guard let said = note.userInfo?[MaughamEvent.noticeMessageKey] as? String,
                  said.hasPrefix("Couldn’t save") else { return }
            box.unlockAll()
        }
    }

    private func verbs(_ store: ProjectStore, _ state: BinderTreeSectionsState) -> BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state, subject: .constant(.book))
    }

    /// "World" holds Maps (Chapter One's) and Coast (the book's).
    private func worldOverAChapter(_ store: ProjectStore)
        async throws -> (world: ResearchItem, maps: ResearchItem, coast: ResearchItem) {
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        let maps = try await store.addResearchTextNote(parentId: world.id, title: "Maps")
        let coast = try await store.addResearchTextNote(parentId: world.id, title: "Coast")
        let one = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: maps.id, toDocumentId: one.id)
        return (world, maps, coast)
    }

    private func folder(of note: ResearchItem, _ store: ProjectStore) throws -> String {
        try path(note.id, store).components(separatedBy: "/").dropLast().joined(separator: "/")
    }

    // MARK: - (a) A direct move: no question, the sentence said

    func test_aDirectMoveThatLeavesPictureLinksSaysSo() async throws {
        let (store, ds) = try await novel()
        let state = BinderTreeSectionsState()
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let sarah = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        let probe = try await store.addResearchTextNote(parentId: places.id, title: "Probe")
        let placesFolder = try folder(of: probe, store)
        try await picture(sarah, takenIn: placesFolder, store, ds)
        failTheNextRewrite(of: sarah.id, store, ds)

        let plan = BinderTreeVerbs.plan([sarah.id], to: .group(places.id), linkTo: nil, unlinks: nil,
                                        store: store, state: state)
        XCTAssertNil(BinderTreeVerbs.moveAct(plan, landing: .end, sources: [:], store: store, state: state),
                     "premise: a whole-book note's move asks nothing — requestMove's direct path")
        let said = await BinderTreeVerbs.said {
            try await BinderTreeVerbs.performPlan(plan, landing: .end, afterLift: "", store: store)
        }

        XCTAssertFalse(locked.isEmpty, "premise: the rewrite reached the door's write")
        XCTAssertEqual(said, "Moved “Sarah”, but the picture links in “Sarah” could not be updated.")
        XCTAssertTrue(try path(sarah.id, store).hasPrefix(placesFolder + "/"), "the move stands")
    }

    // MARK: - (b) A held move, answered: the lift's links said

    func test_aHeldMoveWhoseLiftLeavesPictureLinksSaysSo() async throws {
        let (store, ds) = try await novel()
        let state = BinderTreeSectionsState()
        let (world, maps, _) = try await worldOverAChapter(store)
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let root = try await store.addResearchTextNote(parentId: nil, title: "Root")
        try await picture(maps, takenIn: try folder(of: root, store), store, ds)
        failTheNextRewrite(of: maps.id, store, ds)

        let act = try XCTUnwrap(verbs(store, state).moveAct([world.id], to: .group(places.id), sources: [:]),
                                "premise: a group over a chapter's note asks")
        XCTAssertEqual(act.lifts, [HeldResearchAct.Lift(ids: [maps.id], to: .sharedRoot)])
        let said = await BinderTreeVerbs.said { try await BinderTreeVerbs.performHeld(act, store: store) }

        XCTAssertFalse(locked.isEmpty, "premise: the lift's rewrite reached the door's write")
        XCTAssertEqual(said, "Moved “Maps”, but the picture links in “Maps” could not be updated.")
        XCTAssertTrue(store.manifest.research.contains { $0.id == maps.id }, "the lift stands")
    }

    // MARK: - (c) A held delete whose lifts leave links

    func test_aHeldDeleteWhoseLiftLeavesPictureLinksSaysSo() async throws {
        let (store, ds) = try await novel()
        let state = BinderTreeSectionsState()
        let (world, maps, coast) = try await worldOverAChapter(store)
        let root = try await store.addResearchTextNote(parentId: nil, title: "Root")
        try await picture(maps, takenIn: try folder(of: root, store), store, ds)
        failTheNextRewrite(of: maps.id, store, ds)

        let act = try XCTUnwrap(verbs(store, state).deleteAct([world.id]), "premise: Delete asks first")
        XCTAssertEqual(act.take.held, [maps.id])
        let said = await BinderTreeVerbs.said { try await BinderTreeVerbs.performHeld(act, store: store) }

        XCTAssertFalse(locked.isEmpty, "premise: the lift's rewrite reached the door's write")
        XCTAssertEqual(said, "Moved “Maps”, but the picture links in “Maps” could not be updated.")
        XCTAssertNil(TreeWalk.find(id: coast.id, in: store.manifest.research), "the delete stands")
        XCTAssertTrue(store.manifest.research.contains { $0.id == maps.id }, "Maps was lifted out")
    }

    // MARK: - (d) The lifts land, then the move fails

    func test_aMoveThatFailsAfterALiftThatLeftPictureLinksNamesThemToo() async throws {
        let (store, ds) = try await novel()
        let state = BinderTreeSectionsState()
        let (world, maps, _) = try await worldOverAChapter(store)
        let inside = try await store.addResearchItem(parentId: world.id, title: "Inside", kind: nil)
        let root = try await store.addResearchTextNote(parentId: nil, title: "Root")
        try await picture(maps, takenIn: try folder(of: root, store), store, ds)
        failTheNextRewrite(of: maps.id, store, ds)

        // A group cannot go inside itself: the move throws after the lift.
        let act = try XCTUnwrap(verbs(store, state).moveAct([world.id], to: .group(inside.id), sources: [:]))
        let answer = await BinderTreeVerbs.said {
            try await BinderTreeVerbs.performHeld(act, store: store)
        }
        let said = try XCTUnwrap(answer)

        XCTAssertFalse(locked.isEmpty, "premise: the lift's rewrite reached the door's write")
        XCTAssertTrue(said.hasPrefix(
            "The chapters’ notes were lifted out of “World”, but “World” couldn’t be moved: "), said)
        XCTAssertTrue(said.hasSuffix(". The picture links in “Maps” could not be updated."), said)
        XCTAssertTrue(store.manifest.research.contains { $0.id == maps.id }, "the lift stands")
    }

    // MARK: - The control: nothing left, nothing said

    func test_aHeldMoveWithNothingLeftSaysNothing() async throws {
        let (store, _) = try await novel()
        let state = BinderTreeSectionsState()
        let (world, _, _) = try await worldOverAChapter(store)
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let act = try XCTUnwrap(verbs(store, state).moveAct([world.id], to: .group(places.id), sources: [:]))
        let said = await BinderTreeVerbs.said { try await BinderTreeVerbs.performHeld(act, store: store) }
        XCTAssertNil(said)
    }
}
