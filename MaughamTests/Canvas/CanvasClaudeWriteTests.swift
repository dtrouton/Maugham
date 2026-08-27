import XCTest
@testable import Maugham

/// **One definition of how a plan reaches disk, whether or not the writer has the
/// canvas on screen.**
///
/// `CanvasClaudeWrite` is the seam between Task 3's pure planner and the two
/// places a canvas actually lives: the attached `CanvasModel` the Plan persona is
/// drawing, and the derived sidecar under `.maugham/`. Both tools in this slice go
/// through it, so a route that placed cards differently — or lost them — would do
/// so for every caller at once.
///
/// The tests here divide into three questions, and the third is the one with a
/// silent failure behind it:
///
/// - **Does the write land?** On the model when one is attached, on the sidecar
///   otherwise, and on the sidecar for a model that has been attached and
///   detached (whose scene is a stale snapshot the next `attach()` overwrites).
/// - **Do the two routes agree?** The same `Plan` through each produces `==`
///   scenes, which is what "one definition of where Claude puts things" means as
///   an assertion rather than as a sentence in a doc comment.
/// - **Is Claude's batch its own undo step?** An MCP call can arrive while the
///   writer is inside a scrap with "Edit Scrap" held open, and nothing on the far
///   side of the window closes their gesture. Through `mutate` the write nests,
///   registers nothing, and rides into the writer's next sentence (tripwire 32).
///   **The discriminator is the step's NAME**, not the post-⌘Z scene: a test whose
///   only observable is the scene cannot tell "its own step" from "folded into the
///   neighbouring one", and that has produced a false green twice in this area on
///   exactly this bug.
@MainActor
final class CanvasClaudeWriteTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-claude-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Fixtures

    /// A real project, because `ProjectStore` is what carries `liveCanvas` and the
    /// tools are handed one.
    private func project(_ name: String) async throws -> (store: ProjectStore, root: URL) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: root)
        return (try await ProjectStore.load(from: url), url)
    }

    private func request(_ scraps: [String],
                         connections: [(Int, Int)] = []) -> CanvasClaudePlacement.Request {
        CanvasClaudePlacement.Request(scraps: scraps, connections: connections)
    }

    /// An attached model wired to its store, which is the shape a tool meets while
    /// the writer is looking at the Plan persona.
    private func attached(to store: ProjectStore, at projectRoot: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: projectRoot)
        store.liveCanvas = model
        return model
    }

    private func sidecar(at projectRoot: URL) -> (scene: CanvasScene,
                                                  scraps: [CanvasNodeID: String]) {
        let loaded = CanvasStore(projectRoot: projectRoot).load()
        return (loaded.scene, loaded.scraps)
    }

    /// Every node and line a plan describes, present in `scene` with the plan's own
    /// words beside it. Both routes have to satisfy this and the wording of the
    /// failure is the same for both, so it is asked in one place.
    ///
    /// **The non-empty guard is the whole reason this is not just two loops.** Four
    /// tests route their central assertion through here, and over an empty
    /// `plan.scraps` the loop vanishes and the helper degenerates to "the region
    /// exists" while still reading, at each call site, as full coverage. Task 3 of
    /// this slice shipped two assertions that passed that way.
    ///
    /// **Lines are the caller's to count, and deliberately.** Most requests here
    /// name no connections at all, so a non-empty assertion would be false for them
    /// rather than protective; the two tests that plan lines assert
    /// `plan.lines.count` themselves, which says the number rather than merely
    /// "some".
    private func assertLanded(_ plan: CanvasClaudePlacement.Plan,
                              in scene: CanvasScene,
                              scraps: [CanvasNodeID: String],
                              _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(plan.scraps.isEmpty,
                       "\(what): the plan places no cards, so every loop below is a "
                       + "no-op and this helper asserts almost nothing",
                       file: file, line: line)
        XCTAssertNotNil(scene.region(plan.regionID),
                        "\(what): the region Claude's cards live in is missing, so "
                        + "nothing it added is labelled",
                        file: file, line: line)
        for planned in plan.scraps {
            XCTAssertNotNil(scene.node(planned.node.id),
                            "\(what): a planned card never arrived",
                            file: file, line: line)
            XCTAssertEqual(scraps[planned.node.id], planned.text,
                           "\(what): the card is there and its words are not — the "
                           + "plan carries both precisely so they cannot part",
                           file: file, line: line)
        }
        for planned in plan.lines {
            XCTAssertNotNil(scene.line(planned.id),
                            "\(what): a planned line never arrived",
                            file: file, line: line)
        }
    }

    // MARK: - The two routes

    /// The writer is looking at the canvas: the write goes through the model, and
    /// it is **also** on disk when the call returns. `flush()` rather than the
    /// 750 ms debounce, because a tool that answers "added" with the words only in
    /// memory has lied if the app is quit in the next 750 ms — and the canvas has
    /// no op log behind it (`Maugham/Canvas/AREA.md`, "The crash floor").
    ///
    /// **The hook count is asserted here, on the path that ships.** `CanvasView`
    /// binds `onSceneChangedExternally` to a layout rebuild, and it is
    /// `mutateFromInspector` that fires it — inside the bracket, deliberately (Task
    /// 4), which is why this applier does not call it a second time. The only other
    /// `fired == 1` assertion drives `mutateFromInspector` directly, so it cannot
    /// see a future author adding that second call: one change and one rebuild, or
    /// every batch measures the whole canvas twice.
    func test_anAttachedCanvasIsWrittenThroughTheModel() async throws {
        let (store, projectRoot) = try await project("Open")
        let model = attached(to: store, at: projectRoot)
        var fired = 0
        model.onSceneChangedExternally = { fired += 1 }

        let plan = CanvasClaudePlacement.plan(request(["a first thought", "a second"]),
                                              in: model.scene)
        try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot)

        XCTAssertEqual(fired, 1,
                       "the view re-derives once per external change: at 0 Claude's "
                       + "cards have no ScrapLayout and draw as empty rectangles "
                       + "until the writer clicks; above 1 the whole canvas is "
                       + "measured twice for one arrival")
        assertLanded(plan, in: model.scene, scraps: model.scraps, "the live model")

        let onDisk = sidecar(at: projectRoot)
        assertLanded(plan, in: onDisk.scene, scraps: onDisk.scraps,
                     "the sidecar, written by the flush")
    }

    /// Nobody has the Plan persona open: the sidecar is the canvas, and a fresh
    /// store reads back what was written.
    ///
    /// **It is also the control for the two refusals at the foot of this file**
    /// (issue #33): with no `canvas.json` there is nothing to lose, so the write
    /// goes through. An implementation that simply refused every write with no
    /// canvas open would pass both refusal tests and fail this one.
    func test_aClosedCanvasIsWrittenToTheSidecar() async throws {
        let (store, projectRoot) = try await project("Closed")
        XCTAssertNil(store.liveCanvas, "precondition: no window is showing this canvas")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecarURL(projectRoot).path),
            "precondition: no sidecar at all, so there is no arrangement to lose")

        let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectRoot)
        XCTAssertFalse(read.fromOpenCanvas, "precondition: the read came off disk")

        let plan = CanvasClaudePlacement.plan(request(["off the page"]), in: read.scene)
        try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot)

        let onDisk = sidecar(at: projectRoot)
        assertLanded(plan, in: onDisk.scene, scraps: onDisk.scraps, "the sidecar")
    }

    /// **What "one definition" means as an assertion.** The same `Plan` applied
    /// through each route yields the same scene and the same words.
    ///
    /// Two projects, so each route applies the plan to the scene it was planned
    /// against — both empty, and separate. `CanvasClaudePlacement.apply`'s doc
    /// comment warns that a plan is only valid against the scene it was planned
    /// against, and this test is deliberately not the exception to that: the two
    /// starting scenes are `==`, which is the whole premise being tested.
    func test_bothRoutesProduceTheSameScene() async throws {
        let live = try await project("Live")
        let disk = try await project("Disk")
        let model = attached(to: live.store, at: live.root)

        XCTAssertEqual(model.scene, sidecar(at: disk.root).scene,
                       "precondition: both routes start from the same scene")

        let plan = CanvasClaudePlacement.plan(
            request(["one", "two", "three"], connections: [(0, 2)]), in: model.scene)
        XCTAssertEqual(plan.lines.count, 1,
                       "precondition: there is a line for the two routes to agree "
                       + "about — a scene equality over a plan with no lines in it "
                       + "says nothing about how either route writes one")

        try CanvasClaudeWrite.apply(plan, store: live.store, projectRoot: live.root)
        try CanvasClaudeWrite.apply(plan, store: disk.store, projectRoot: disk.root)

        let written = sidecar(at: disk.root)
        XCTAssertEqual(model.scene, written.scene,
                       "the live route and the sidecar route placed the same plan "
                       + "differently — so where Claude's cards land depends on "
                       + "whether the writer happened to have the canvas open")
        XCTAssertEqual(model.scraps, written.scraps, "…and the same for the words")
    }

    /// **`isAttached`, not `liveCanvas != nil`.** A model that has been attached
    /// and detached is still on the store, and its scene is the snapshot from when
    /// the persona closed — it cannot see anything the sidecar route has written
    /// since. Written into that instead, the ids are reported, the tool succeeds,
    /// and the scraps are gone the next time the Plan persona opens.
    func test_aDetachedModelDoesNotSwallowTheWrite() async throws {
        let (store, projectRoot) = try await project("Detached")
        let model = attached(to: store, at: projectRoot)
        model.detach()
        XCTAssertNotNil(store.liveCanvas, "precondition: the store still holds it")
        XCTAssertFalse(model.isAttached, "precondition: it is no longer usable")

        let plan = CanvasClaudePlacement.plan(request(["while the persona was shut"]),
                                              in: sidecar(at: projectRoot).scene)
        try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot)

        let onDisk = sidecar(at: projectRoot)
        assertLanded(plan, in: onDisk.scene, scraps: onDisk.scraps, "the sidecar")
        XCTAssertNil(model.scene.region(plan.regionID),
                     "the write went into the stale scene of a detached model, "
                     + "which the next attach() overwrites wholesale")

        model.attach(projectRoot: projectRoot)
        assertLanded(plan, in: model.scene, scraps: model.scraps,
                     "the writer's next visit to the Plan persona")
    }

    // MARK: - The read

    /// The words the writer typed a second ago are in the model and not yet on
    /// disk, so a tool that read the sidecar would report a canvas nobody is
    /// looking at.
    ///
    /// The divergence is made with `persist: false` — the spelling a live gesture's
    /// frames use — so the sidecar is stale deterministically rather than because
    /// a 750 ms debounce happened not to fire during the test.
    func test_theReadPrefersTheOpenCanvas() async throws {
        let (store, projectRoot) = try await project("Prefers")
        let model = attached(to: store, at: projectRoot)
        let typed = CanvasNodeID("aa11")
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: typed, kind: .scrap, origin: .zero,
                                 width: 240, cachedHeight: 80))
        }

        let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectRoot)

        XCTAssertTrue(read.fromOpenCanvas,
                      "the caller cannot tell the writer's live canvas from the "
                      + "sidecar unless the read says which it was")
        XCTAssertEqual(read.scene, model.scene, "the scene read is the model's")
        XCTAssertNil(sidecar(at: projectRoot).scene.node(typed),
                     "precondition: the sidecar really is behind the model")
    }

    /// The same discriminator on the read side. A detached model's scene is a
    /// stale snapshot, so reading it reports a canvas that no longer exists — and
    /// a caller that then planned against it would place Claude's region on top of
    /// whatever has been written since.
    func test_theReadIgnoresADetachedModel() async throws {
        let (store, projectRoot) = try await project("IgnoresDetached")
        let model = attached(to: store, at: projectRoot)
        model.detach()

        let plan = CanvasClaudePlacement.plan(request(["written while shut"]),
                                              in: sidecar(at: projectRoot).scene)
        try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot)

        let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectRoot)
        XCTAssertFalse(read.fromOpenCanvas, "a detached model is not an open canvas")
        assertLanded(plan, in: read.scene, scraps: read.scraps, "the read")
    }

    // MARK: - Undo

    /// **One bracket for the whole batch**, so one ⌘Z takes back the whole add —
    /// the region, the cards, their words and the lines together.
    ///
    /// The scene assertion alone would pass with the batch split across two steps,
    /// or folded into a neighbour's, so the step is checked by NAME and the stack
    /// is checked for being empty afterwards.
    ///
    /// **The batch is asserted to have landed BEFORE the ⌘Z, and that is what makes
    /// the two equalities afterwards mean anything.** On a fresh project
    /// `beforeScraps` is empty, so `scraps == beforeScraps` after the undo is
    /// empty-against-empty and would hold just as well if the words had never been
    /// written at all — and it is the assertion that catches the orphan `scraps`
    /// entry a write outside the bracket leaves behind.
    func test_theWholeBatchIsOneUndoStep() async throws {
        let (store, projectRoot) = try await project("OneStep")
        let model = attached(to: store, at: projectRoot)
        XCTAssertFalse(model.undoManager.groupsByEvent,
                       "precondition: the canvas's manager brackets explicitly, and "
                       + "an implicit event group would collapse steps this test is "
                       + "counting (CanvasModel.undoManager says why at length)")

        let before = model.scene
        let beforeScraps = model.scraps
        let plan = CanvasClaudePlacement.plan(
            request(["one", "two", "three"], connections: [(0, 1), (1, 2)]),
            in: model.scene)
        try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot)
        XCTAssertEqual(plan.lines.count, 2, "precondition: the plan drew both lines")
        assertLanded(plan, in: model.scene, scraps: model.scraps,
                     "before the ⌘Z, so the equalities after it are not empty "
                     + "against empty")

        XCTAssertTrue(model.undoManager.undoMenuItemTitle
                        .contains(CanvasClaudeWrite.undoStepName),
                      "the batch must be one NAMED step: a bare \"Undo\" is a batch "
                      + "that registered nothing of its own. found: "
                      + model.undoManager.undoMenuItemTitle)

        model.undo.undo()

        XCTAssertEqual(model.scene, before, "one ⌘Z did not take the whole add back")
        XCTAssertEqual(model.scraps, beforeScraps, "…and the words came back with it")
        XCTAssertFalse(model.undoManager.canUndo,
                       "there was more than one step, so a second ⌘Z takes back part "
                       + "of the same arrival — which is the split this bracket exists "
                       + "to prevent")
        XCTAssertTrue(model.undoManager.redoMenuItemTitle
                        .contains(CanvasClaudeWrite.undoStepName),
                      "the step keeps its name through the cycle. found: "
                      + model.undoManager.redoMenuItemTitle)
    }

    /// **The failure this file exists to avoid.** The writer is inside a scrap with
    /// "Edit Scrap" held open and nothing on the far side of the window closes it.
    /// Through `mutate` the write nests — `beginGesture` takes no snapshot at depth
    /// 2, `endGesture` registers nothing above depth 0 — so Claude's nodes reach no
    /// undo step of their own and ride into the writer's next sentence: a ⌘Z aimed
    /// at a sentence takes Claude's whole batch with it.
    ///
    /// Three steps with three names by the end, and the assertions are on the
    /// names: the writer's first run, Claude's batch, the writer's next run.
    func test_aWriteArrivingMidVisitDoesNotJoinTheWritersSentence() async throws {
        let (store, projectRoot) = try await project("MidVisit")
        let model = attached(to: store, at: projectRoot)
        let visited = CanvasNodeID("bb22")
        model.mutate("New Scrap") {
            $0.insert(CanvasNode(id: visited, kind: .scrap, origin: .zero,
                                 width: 240, cachedHeight: 80))
        }

        // The writer is in the card, typing. This is `CanvasView`'s own bracket,
        // opened on focus-in and closed on focus-out.
        model.beginGesture("Edit Scrap")
        model.setScrapText("The fog came in.", for: visited)

        let plan = CanvasClaudePlacement.plan(request(["from Claude"]), in: model.scene)
        try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot)

        XCTAssertTrue(model.undoManager.undoMenuItemTitle
                        .contains(CanvasClaudeWrite.undoStepName),
                      "Claude's batch registered no step of its own — nested inside "
                      + "the writer's open gesture it takes no snapshot and registers "
                      + "nothing, so it rides into the writer's next sentence "
                      + "(tripwire 32). found: " + model.undoManager.undoMenuItemTitle)

        // The writer types on, unaware, and finishes the visit.
        model.setScrapText("The fog came in. It stayed.", for: visited)
        model.endGesture()

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Edit Scrap"),
                      "the writer's second run is its own step. found: "
                      + model.undoManager.undoMenuItemTitle)
        model.undo.undo()
        XCTAssertEqual(model.scraps[visited], "The fog came in.",
                       "the ⌘Z was aimed at the sentence")
        assertLanded(plan, in: model.scene, scraps: model.scraps,
                     "a ⌘Z aimed at the writer's sentence took Claude's batch with it")

        XCTAssertTrue(model.undoManager.undoMenuItemTitle
                        .contains(CanvasClaudeWrite.undoStepName),
                      "Claude's batch is the next step back, under its own name. "
                      + "found: " + model.undoManager.undoMenuItemTitle)
        model.undo.undo()
        XCTAssertNil(model.scene.region(plan.regionID),
                     "the second ⌘Z takes back Claude's batch, whole")
        XCTAssertEqual(model.scraps[visited], "The fog came in.",
                       "…and leaves the writer's words where they were")

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Edit Scrap"),
                      "the writer's first run is underneath, still its own step: "
                      + "three arrivals, three steps, three names. found: "
                      + model.undoManager.undoMenuItemTitle)
    }

    // MARK: - A sidecar this build cannot read (issue #33)

    /// A sidecar from a build we do not have: present, holding somebody's whole
    /// arrangement, and undecodable here. `CanvasStore.load` answers it with an
    /// EMPTY scene — which is what made the sidecar route dangerous, because
    /// `apply` then saved that empty scene plus Claude's cards straight back over
    /// every region, line, position, mark and binding in the file.
    private static let sidecarFromANewerBuild =
        #"{"schemaVersion":999,"nodes":[{"id":"futr","kind":"scrap","x":10,"y":10,"width":240,"z":3}]}"#

    private func sidecarURL(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(CanvasStore.sidecarRelativePath)
    }

    private func scrapsURL(_ projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(CanvasStore.scrapsRelativePath)
    }

    /// Seed a refused sidecar with the writer's words beside it, and hand back the
    /// bytes of BOTH files. `CanvasModelTests` and `InboxToCanvasTests` seed their
    /// twins the same way.
    ///
    /// `canvas.md` is in the comparison because it is *content* (spec §3.2): the
    /// sidecar can be deleted without losing a word, so a refusal that still
    /// rewrote the scraps file would cost the writer the one thing the sidecar's
    /// loss does not.
    private func seedUnreadableSidecar(
        _ projectRoot: URL, _ json: String
    ) throws -> (sidecar: Data, scraps: Data) {
        let sidecar = sidecarURL(projectRoot)
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: sidecar, atomically: true, encoding: .utf8)
        try "\(ScrapText.banner)\n\n## futr\n\nA layout from a build we do not have.\n"
            .write(to: scrapsURL(projectRoot), atomically: true, encoding: .utf8)
        return (try Data(contentsOf: sidecar), try Data(contentsOf: scrapsURL(projectRoot)))
    }

    /// Plan a batch against whatever `readScene` reports, apply it, and assert the
    /// two things a refusal owes the writer: it is *told* — a `SidecarRefused`
    /// naming the project, which is the sentence every caller reads out — and both
    /// canvas files are **byte-identical** to what was there before.
    private func assertRefusedAndUntouched(
        _ store: ProjectStore, _ projectRoot: URL,
        before: (sidecar: Data, scraps: Data),
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectRoot)
        XCTAssertFalse(read.fromOpenCanvas,
                       "precondition: the read came off disk, so the write takes "
                       + "the sidecar route", file: file, line: line)
        let plan = CanvasClaudePlacement.plan(request(["a card worth losing nothing for"]),
                                              in: read.scene)

        XCTAssertThrowsError(
            try CanvasClaudeWrite.apply(plan, store: store, projectRoot: projectRoot),
            "a write onto a sidecar this build cannot read must be refused — saving "
            + "over it costs every region, line, position, mark and binding the "
            + "other build put there",
            file: file, line: line
        ) { error in
            guard let refusal = error as? CanvasStore.SidecarRefused else {
                return XCTFail("expected CanvasStore.SidecarRefused, got \(error)",
                               file: file, line: line)
            }
            XCTAssertEqual(refusal.projectName, projectRoot.lastPathComponent,
                           "the refusal names the project it is about",
                           file: file, line: line)
        }

        XCTAssertEqual(try Data(contentsOf: sidecarURL(projectRoot)), before.sidecar,
                       "the other build's arrangement is byte-identical on disk — a "
                       + "refusal that still wrote is the whole defect",
                       file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: scrapsURL(projectRoot)), before.scraps,
                       "…and canvas.md is untouched too: the words are content, and "
                       + "a refused call may not add Claude's to them",
                       file: file, line: line)
    }

    /// **The defect, in its plainest form** (issue #33). Nobody has the Plan
    /// persona open, so the write takes the sidecar route — and that route used to
    /// `load()` a newer build's file as an empty scene and `save()` its own scene
    /// straight back over it, destroying the writer's whole arrangement to add
    /// three cards.
    func test_aClosedCanvasWithAnUnreadableSidecarRefusesTheWrite() async throws {
        let (store, projectRoot) = try await project("RefusedNewerSchema")
        XCTAssertNil(store.liveCanvas, "precondition: nobody is showing this canvas")
        let before = try seedUnreadableSidecar(projectRoot, Self.sidecarFromANewerBuild)

        try assertRefusedAndUntouched(store, projectRoot, before: before)
    }

    /// Damaged bytes are the same case: present, unreadable, and not ours to stamp
    /// over. A backup or a later repair may still recover it.
    func test_aDamagedSidecarRefusesTheWriteToo() async throws {
        let (store, projectRoot) = try await project("RefusedDamaged")
        XCTAssertNil(store.liveCanvas, "precondition: nobody is showing this canvas")
        let before = try seedUnreadableSidecar(projectRoot, "not json at all")

        try assertRefusedAndUntouched(store, projectRoot, before: before)
    }
}
