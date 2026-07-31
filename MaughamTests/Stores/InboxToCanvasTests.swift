import XCTest
import MaughamCore
@testable import Maugham

/// **A capture reaches the canvas in one act** (spec §8A.4).
///
/// The pipeline is `inbox → canvas → research` and only the first arrow was
/// missing: promotion (§6) has been the second one since 1C-c2. Until this slice
/// the only road out of the inbox built the durable artifact *first* and did the
/// thinking afterwards, which inverts what the canvas is for (§1).
///
/// **Six cases, and the grid is the point.** Three capture kinds — text, voice,
/// photograph — times two routes: the **drag**, which is the third caller of Task
/// 10's drop target and lands the capture where the writer let go of it, and the
/// **command**, which has no drop point and takes the one stated fallback (loose,
/// clear of the writer's work, and never in a region). §8A.4's own ruling is that
/// this ships for all three kinds or it does not ship — *"an action live for text
/// and voice and absent on photos teaches the writer it is broken"* — so a
/// missing kind has to be a red test rather than an absence, and that is what the
/// six cases below are for.
///
/// The other three questions here each have a silent failure behind them:
///
/// - **Is the entry's status flip ordered after every mutating step?** A
///   half-promoted entry is a capture that is gone from the inbox and nowhere
///   else. `promoteToPaletteCard` settled this ordering already and this is its
///   third sibling rather than a new spelling of it.
/// - **Is one send one ⌘Z?** A send can arrive while the writer is inside a scrap
///   with "Edit Scrap" held open, and *nothing on either side closes their
///   bracket* — the command comes from another column and the drag begins in one
///   (tripwire 32). Through the inside verbs it nests, registers nothing, and
///   rides into the writer's next sentence.
/// - **Does the command work with the Plan persona closed?** That is its whole
///   point, so it must exercise the sidecar route as well as the live one.
@MainActor
final class InboxToCanvasTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-to-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Fixtures

    private struct Fixture {
        let url: URL
        let store: ProjectStore
        let inbox: InboxStore
        let documentStore: DocumentStore
    }

    private func openProject(_ name: String) async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(named: name, in: root)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return Fixture(url: url, store: store,
                       inbox: InboxStore(projectURL: url, deviceId: "mac"),
                       documentStore: ds)
    }

    /// An attached model wired to its store — the shape a send meets while the
    /// writer has the Plan persona on screen. The DRAG can only ever meet this
    /// one (you cannot drop on a canvas that is not mounted); the command meets
    /// both.
    private func attached(_ f: Fixture) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: f.url)
        f.store.liveCanvas = model
        return model
    }

    private func seed(_ f: Fixture, _ entries: [InboxEntry]) async throws {
        let file = f.url.appendingPathComponent(".maugham/inbox/inbox.phone.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = JSONLAppendStore<InboxEntry>(fileURL: file)
        for entry in entries { try await store.append(entry) }
        await f.inbox.refresh()
    }

    private func seedImageAsset(_ f: Fixture, name: String) throws -> URL {
        let dir = f.url.appendingPathComponent(".maugham/inbox/images")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asset = dir.appendingPathComponent(name)
        try Data("fake-image".utf8).write(to: asset)
        return asset
    }

    private func textEntry(_ id: String, _ text: String) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: 100),
                   writtenAt: Date(timeIntervalSince1970: 100.001),
                   deviceId: "phone", kind: .text, inlineText: text)
    }

    private func voiceEntry(_ id: String, transcript: String?) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: 100),
                   writtenAt: Date(timeIntervalSince1970: 100.001),
                   deviceId: "phone", kind: .audio, sourceFilename: "\(id).m4a",
                   transcript: transcript,
                   transcriptionState: transcript == nil ? .none : .whisperFinal)
    }

    private func photoEntry(_ id: String, filename: String) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: 100),
                   writtenAt: Date(timeIntervalSince1970: 100.001),
                   deviceId: "phone", kind: .image, sourceFilename: filename)
    }

    /// The one node this send added, found by difference rather than by index —
    /// so a scene that was seeded with cards cannot make a stale node look like
    /// the new one.
    private func addedNode(_ id: CanvasNodeID, in scene: CanvasScene,
                           file: StaticString = #filePath, line: UInt = #line) throws
        -> CanvasNode {
        try XCTUnwrap(scene.node(id), "the send reported an id that is not in the scene",
                      file: file, line: line)
    }

    /// A capture that has left the inbox and is durably `.promoted`.
    private func assertResolved(_ f: Fixture, _ id: String,
                                file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertFalse(f.inbox.entries.contains { $0.id == id },
                       "the capture is still in the triage pane after a send",
                       file: file, line: line)
        // Re-read from disk rather than trusting the in-memory collapse: the flip
        // is what makes a retry impossible, and a flip that never reached the
        // manifest leaves the entry `.new` on the next launch.
        let fresh = InboxStore(projectURL: f.url, deviceId: "mac")
        await fresh.refresh()
        XCTAssertFalse(fresh.entries.contains { $0.id == id },
                       "the `.promoted` flip never reached the manifest — the entry "
                       + "comes back on the next launch with its words already on "
                       + "the canvas",
                       file: file, line: line)
    }

    // MARK: - Route 1: the drag (three kinds)

    func test_aTextCaptureDroppedOnTheCanvasBecomesAScrapWhereItWasDropped() async throws {
        let f = try await openProject("DragText")
        let model = attached(f)
        try await seed(f, [textEntry("t1", "the light on the stairwell")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t1" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .dropped(at: CGPoint(x: 300, y: 220)))

        let node = try addedNode(id, in: model.scene)
        XCTAssertEqual(node.kind, .scrap, "a text capture becomes a scrap, not an item")
        XCTAssertEqual(node.origin, CGPoint(x: 300, y: 220),
                       "the drag lands the capture where it was dropped — the canvas "
                       + "gains no placement rule for this route (§8A.4 amendment)")
        XCTAssertEqual(model.scraps[id], "the light on the stairwell",
                       "the words are in `canvas.md`, keyed by the new node's id, "
                       + "exactly as a typed scrap's are")
        XCTAssertNotNil(node.frame,
                        "born measured, or the card is neither drawn nor clickable "
                        + "and is persisted that way")
        await assertResolved(f, "t1")
    }

    func test_aVoiceCaptureDroppedOnTheCanvasCarriesItsTranscript() async throws {
        let f = try await openProject("DragVoice")
        let model = attached(f)
        _ = try seedVoiceAsset(f, name: "v1.m4a")
        try await seed(f, [voiceEntry("v1", transcript: "tram-rattle through the shutters")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "v1" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .dropped(at: CGPoint(x: 40, y: 90)))

        let node = try addedNode(id, in: model.scene)
        XCTAssertEqual(node.kind, .scrap)
        XCTAssertEqual(model.scraps[id], "tram-rattle through the shutters",
                       "a voice capture becomes a scrap carrying its TRANSCRIPT — "
                       + "the recording itself is not something the canvas can hold")
        await assertResolved(f, "v1")
    }

    func test_aPhotographDroppedOnTheCanvasBecomesAnOwnedItemNode() async throws {
        let f = try await openProject("DragPhoto")
        let model = attached(f)
        let asset = try seedImageAsset(f, name: "p1.png")
        try await seed(f, [photoEntry("p1", filename: "p1.png")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "p1" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .dropped(at: CGPoint(x: 12, y: 34)))

        let node = try addedNode(id, in: model.scene)
        guard case .item(.owned(let path)) = node.kind else {
            return XCTFail("a photograph must become an OWNED item node — the inbox "
                           + "is a queue the writer clears, so a node referencing one "
                           + "dangles the day they tidy up. got: \(node.kind)")
        }
        XCTAssertTrue(path.hasPrefix("canvas_assets/"),
                      "ingested through the one pair, into the canvas's own well. "
                      + "got: \(path)")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: f.url.appendingPathComponent(path).path),
            "the picture has a home of its own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path),
                       "copy-then-remove: the inbox original goes only after the "
                       + "entry is durably `.promoted`")
        XCTAssertNil(model.scraps[id],
                     "a picture has no words in `canvas.md` — a scrap entry here "
                     + "would draw an empty card over the photograph")
        await assertResolved(f, "p1")
    }

    // MARK: - Route 2: the command (three kinds)

    /// The command has no drop point, so it takes the one stated fallback:
    /// `occupied.maxX + gutter`, clear of everything the writer has on the canvas.
    /// Asserted as *clearance from the union*, not as a coordinate — the number is
    /// `CanvasClaudePlacement`'s to tune.
    private func assertLandedClear(_ node: CanvasNode, of scene: CanvasScene,
                                   before occupied: CGRect,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(node.frame, "an unmeasured card has no geometry at "
                                  + "all, so the clearance below would be vacuous",
                                  file: file, line: line)
        XCTAssertFalse(frame.intersects(occupied),
                       "the command's capture landed on top of the writer's work",
                       file: file, line: line)
        XCTAssertGreaterThan(frame.minX, occupied.maxX,
                             "clear of it to the RIGHT, which is the one stated "
                             + "fallback rather than a direction of this test's own",
                             file: file, line: line)
        XCTAssertNil(CanvasMembership.homeRegion(of: node.id, in: scene),
                     "**loose, and never in a region** (§8A.4 amendment). Claude's "
                     + "batch takes a region because a derived scrap must stay tied "
                     + "to its source; a writer sending one capture has already "
                     + "decided what it is, and a container they will delete is "
                     + "friction",
                     file: file, line: line)
    }

    /// Something for the new card to keep clear of: one card and one region the
    /// writer already has. Returns their union.
    @discardableResult
    private func seedExistingWork(_ model: CanvasModel) -> CGRect {
        let card = CanvasNode(id: CanvasNodeID("aa11"), kind: .scrap,
                              origin: CGPoint(x: 0, y: 0), width: 240, cachedHeight: 80)
        let region = CanvasRegion(id: CanvasRegionID("rr11"), label: "Act One",
                                  frame: CGRect(x: 300, y: 0, width: 400, height: 300))
        model.mutate("Seed") {
            $0.insert(card)
            $0.insertRegion(region)
        }
        return card.frame!.union(region.frame)
    }

    func test_aTextCaptureSentByCommandLandsLooseAndClearOfTheWritersWork() async throws {
        let f = try await openProject("CommandText")
        let model = attached(f)
        let occupied = seedExistingWork(model)
        try await seed(f, [textEntry("t2", "she never wrote the letter")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t2" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        let node = try addedNode(id, in: model.scene)
        XCTAssertEqual(node.kind, .scrap)
        XCTAssertEqual(model.scraps[id], "she never wrote the letter")
        try assertLandedClear(node, of: model.scene, before: occupied)
        await assertResolved(f, "t2")
    }

    func test_aVoiceCaptureSentByCommandLandsLooseAndClearOfTheWritersWork() async throws {
        let f = try await openProject("CommandVoice")
        let model = attached(f)
        let occupied = seedExistingWork(model)
        _ = try seedVoiceAsset(f, name: "v2.m4a")
        try await seed(f, [voiceEntry("v2", transcript: "the fog came in")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "v2" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        let node = try addedNode(id, in: model.scene)
        XCTAssertEqual(model.scraps[id], "the fog came in")
        try assertLandedClear(node, of: model.scene, before: occupied)
        await assertResolved(f, "v2")
    }

    func test_aPhotographSentByCommandLandsLooseAndClearOfTheWritersWork() async throws {
        let f = try await openProject("CommandPhoto")
        let model = attached(f)
        let occupied = seedExistingWork(model)
        let asset = try seedImageAsset(f, name: "p2.png")
        try await seed(f, [photoEntry("p2", filename: "p2.png")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "p2" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        let node = try addedNode(id, in: model.scene)
        guard case .item(.owned) = node.kind else {
            return XCTFail("the command route must produce the same OWNED node the "
                           + "drag does — an action that differs by route is the "
                           + "seam §8A.4 refuses to ship. got: \(node.kind)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
        try assertLandedClear(node, of: model.scene, before: occupied)
        await assertResolved(f, "p2")
    }

    // MARK: - The two routes differ in exactly one way

    /// **The control for "never in a region".** Without it the whole assertion
    /// could be passing because membership is broken rather than because the
    /// command declines to join: the same entry, dropped by the DRAG inside the
    /// same region, must join it.
    func test_theDragJoinsARegionItLandsIn_andTheCommandJoinsNothing() async throws {
        let f = try await openProject("JoinControl")
        let model = attached(f)
        let region = CanvasRegion(id: CanvasRegionID("rr22"), label: "Act Two",
                                  frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        model.mutate("Seed") { $0.insertRegion(region) }
        try await seed(f, [textEntry("t3", "inside"), textEntry("t4", "loose")])

        let dragged = try XCTUnwrap(f.inbox.entries.first { $0.id == "t3" })
        let droppedID = try await f.inbox.sendToCanvas(
            dragged, projectStore: f.store, placement: .dropped(at: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(CanvasMembership.homeRegion(of: droppedID, in: model.scene),
                       region.id,
                       "creation absorbs: a card dropped inside a region joins it, by "
                       + "its CENTRE, through the one existing spelling (tripwire 31)")

        let commanded = try XCTUnwrap(f.inbox.entries.first { $0.id == "t4" })
        let looseID = try await f.inbox.sendToCanvas(
            commanded, projectStore: f.store, placement: .loose)
        XCTAssertNil(CanvasMembership.homeRegion(of: looseID, in: model.scene),
                     "the command's capture is loose — and the drag above proves "
                     + "this is a decision rather than membership being broken")
    }

    // MARK: - Refusals and ordering

    /// A voice capture with no transcript is refused and stays in the inbox.
    /// `promoteToPaletteCard` throws on exactly this (`nothingToPromote`), for
    /// exactly this reason: a blank scrap plus a `.promoted` entry is the capture
    /// lost.
    func test_aVoiceCaptureWithNoTranscriptIsRefusedAndStaysInTheInbox() async throws {
        let f = try await openProject("NoTranscript")
        let model = attached(f)
        let before = model.scene
        _ = try seedVoiceAsset(f, name: "v3.m4a")
        try await seed(f, [voiceEntry("v3", transcript: nil)])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "v3" })

        do {
            _ = try await f.inbox.sendToCanvas(
                entry, projectStore: f.store, placement: .loose)
            XCTFail("a capture with nothing to send must not produce a blank card")
        } catch {
            // expected: InboxError.nothingToPromote
        }

        XCTAssertEqual(model.scene, before, "nothing was created")
        XCTAssertTrue(f.inbox.entries.contains { $0.id == "v3" },
                      "the entry stays `.new` so the writer can transcribe and retry")
    }

    /// The same refusal for an empty TEXT capture, which `promoteToPaletteCard`
    /// added after a smoke (S5): a whitespace-only capture is nothing to send.
    func test_anEmptyTextCaptureIsRefusedAndStaysInTheInbox() async throws {
        let f = try await openProject("EmptyText")
        let model = attached(f)
        try await seed(f, [textEntry("t5", "   \n\t ")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t5" })

        do {
            _ = try await f.inbox.sendToCanvas(
                entry, projectStore: f.store, placement: .loose)
            XCTFail("an empty capture must not produce a blank card")
        } catch {}

        XCTAssertTrue(model.scene.unorderedNodes.isEmpty)
        XCTAssertTrue(f.inbox.entries.contains { $0.id == "t5" })
    }

    /// **A failure after the canvas write leaves a recoverable duplicate, never a
    /// lost capture.** The status flip is driven to fail by handing the sibling an
    /// entry the manifest has never seen (`updateStatusThrowing` throws
    /// `entryNotFound`), which is the one mutating step after the picture has been
    /// copied — so this pins the ORDER: copy, write, flip, and only then remove.
    ///
    /// Disable experiment: move the removal above the flip and the last assertion
    /// goes red while every happy-path test stays green.
    func test_aFailedStatusFlipLeavesTheInboxOriginalInPlace() async throws {
        let f = try await openProject("FlipFails")
        let model = attached(f)
        let asset = try seedImageAsset(f, name: "p3.png")
        // Deliberately NOT seeded into the manifest: the entry is a value the
        // caller holds and the store has never heard of.
        let stranger = photoEntry("p3", filename: "p3.png")
        XCTAssertFalse(f.inbox.entries.contains { $0.id == "p3" },
                       "precondition: the manifest has no such row, so the flip throws")

        do {
            _ = try await f.inbox.sendToCanvas(
                stranger, projectStore: f.store, placement: .loose)
            XCTFail("a status flip that cannot persist must surface, or the entry "
                    + "stays `.new` while its picture is already on the canvas")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path),
                      "the inbox original survives a failed send — copy-then-remove "
                      + "means a failure leaves a harmless duplicate rather than "
                      + "losing the writer's photograph")
        XCTAssertEqual(model.scene.unorderedNodes.count, 1,
                       "control: the write DID happen before the flip failed, so the "
                       + "assertion above is about ordering rather than about "
                       + "nothing having run")
    }

    // MARK: - One send is one ⌘Z

    func test_oneSendIsOneNamedUndoStep() async throws {
        let f = try await openProject("OneStep")
        let model = attached(f)
        let before = model.scene
        try await seed(f, [textEntry("t6", "one act, one step")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t6" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains(CanvasCapture.undoStepName),
                      "the send must be one NAMED step: a bare \"Undo\" is a write "
                      + "that registered nothing of its own. found: "
                      + model.undoManager.undoMenuItemTitle)
        model.undo.undo()
        XCTAssertEqual(model.scene, before, "one ⌘Z took the whole send back")
        XCTAssertNil(model.scraps[id], "…and the words went with the card")
    }

    /// **Tripwire 32's repro, made executable for this route.** The writer is
    /// inside a scrap with "Edit Scrap" held open; a send arrives from another
    /// column, and *nothing on either side of the window closes their bracket*.
    /// Through the inside verbs it nests — `beginGesture` takes no snapshot at
    /// depth 2 — so the card reaches no step of its own and rides into the
    /// writer's next sentence, where a ⌘Z aimed at that sentence takes it too.
    ///
    /// Disable experiment: swap `mutateFromInspector` for `mutate` in
    /// `CanvasCapture.send` and this goes red.
    func test_aSendArrivingMidVisitDoesNotJoinTheWritersSentence() async throws {
        let f = try await openProject("MidVisit")
        let model = attached(f)
        let visited = CanvasNodeID("bb22")
        model.mutate("New Scrap") {
            $0.insert(CanvasNode(id: visited, kind: .scrap, origin: .zero,
                                 width: 240, cachedHeight: 80))
        }
        model.beginGesture("Edit Scrap")
        model.setScrapText("The fog came in.", for: visited)

        try await seed(f, [textEntry("t7", "from the inbox")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t7" })
        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains(CanvasCapture.undoStepName),
                      "the send registered no step of its own — nested inside the "
                      + "writer's open gesture it takes no snapshot and registers "
                      + "nothing, so it rides into the writer's next sentence "
                      + "(tripwire 32). found: " + model.undoManager.undoMenuItemTitle)

        model.setScrapText("The fog came in. It stayed.", for: visited)
        model.endGesture()
        model.undo.undo()
        XCTAssertEqual(model.scraps[visited], "The fog came in.",
                       "the ⌘Z was aimed at the sentence")
        XCTAssertNotNil(model.scene.node(id),
                        "a ⌘Z aimed at the writer's sentence took the capture with it")
    }

    // MARK: - The Plan persona closed

    /// **The command's whole point.** A drag needs the canvas on screen; the
    /// command is reachable with the pane closed, from another persona and from
    /// the keyboard, so it must write the sidecar when no canvas is attached —
    /// exactly as `CanvasClaudeWrite`'s second arm does.
    func test_theCommandWritesTheSidecarWhenNoCanvasIsOpen() async throws {
        let f = try await openProject("PersonaClosed")
        XCTAssertNil(f.store.liveCanvas, "precondition: nobody has this canvas open")
        try await seed(f, [textEntry("t8", "written while the persona was closed")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t8" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        let (scene, scraps) = CanvasStore(projectRoot: f.url).load()
        XCTAssertNotNil(scene.node(id),
                        "the capture reached the only canvas there was — a send that "
                        + "answered \"sent\" with nothing on disk has lost it")
        XCTAssertEqual(scraps[id], "written while the persona was closed")
        await assertResolved(f, "t8")
    }

    /// A model that has been attached and DETACHED takes the sidecar route too:
    /// its scene is the snapshot from when the persona closed, so a write into it
    /// vanishes on the next `attach()`. The discriminator is `isAttached`, never
    /// `liveCanvas != nil`.
    func test_aDetachedCanvasTakesTheSidecarRoute() async throws {
        let f = try await openProject("Detached")
        let model = attached(f)
        model.detach()
        XCTAssertNotNil(f.store.liveCanvas, "precondition: the store still holds it")
        try await seed(f, [textEntry("t9", "after the persona closed")])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "t9" })

        let id = try await f.inbox.sendToCanvas(
            entry, projectStore: f.store, placement: .loose)

        XCTAssertNil(model.scene.node(id),
                     "a write into a detached model's stale scene is overwritten "
                     + "wholesale by the next attach()")
        XCTAssertNotNil(CanvasStore(projectRoot: f.url).load().scene.node(id))
    }

    // MARK: - Resolving an id (the drag's payload carries one)

    func test_aDragPayloadNamingNoLiveCaptureIsRefused() async throws {
        let f = try await openProject("UnknownID")
        _ = attached(f)
        do {
            _ = try await f.inbox.sendToCanvas(
                entryID: "nope", projectStore: f.store, placement: .dropped(at: .zero))
            XCTFail("an id no live capture answers to must fail loudly")
        } catch {}
    }

    func test_aDragPayloadResolvesTheEntryItNames() async throws {
        let f = try await openProject("KnownID")
        let model = attached(f)
        try await seed(f, [textEntry("t10", "resolved by id")])

        let id = try await f.inbox.sendToCanvas(
            entryID: "t10", projectStore: f.store, placement: .dropped(at: CGPoint(x: 5, y: 6)))

        XCTAssertEqual(model.scraps[id], "resolved by id")
        await assertResolved(f, "t10")
    }

    // MARK: - Helpers

    private func seedVoiceAsset(_ f: Fixture, name: String) throws -> URL {
        let dir = f.url.appendingPathComponent(".maugham/inbox/audio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asset = dir.appendingPathComponent(name)
        try Data("fake-audio".utf8).write(to: asset)
        return asset
    }
}
