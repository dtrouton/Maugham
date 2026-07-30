import XCTest
@testable import Maugham

/// **The seam an MCP tool crosses to reach the canvas the writer is looking at.**
///
/// A tool is handed a `ProjectRegistry.Entry` — an id, a URL and a
/// `ProjectStore` — and nothing else. The `CanvasModel` is `@State` on
/// `ProjectWindow`, so no store owns it; `ProjectStore.liveCanvas` is the weak
/// back-reference that closes that gap, exactly as `ProjectStore.documentStore`
/// does for a live `Document`.
///
/// Two halves, and the second is the one that is easy to get wrong:
///
/// - **`isAttached`, not "is there a model".** The model is created eagerly with
///   the window and is only *attached* while the canvas is actually on screen.
///   A detached model has no store, so `scheduleSave` is a silent no-op, and its
///   scene is whatever was last loaded — which the next `attach()` overwrites
///   wholesale. Write into one and the write is accepted, reports real ids, and
///   **vanishes the next time the writer opens the Plan persona**, with nothing
///   red anywhere.
/// - **`onSceneChangedExternally`**, because adding nodes to an attached model
///   leaves `CanvasView.layouts` with no entry for them, so the draw pass gets a
///   nil layout and the new cards draw as empty rectangles until the writer
///   happens to click something.
@MainActor
final class CanvasLiveSeamTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-live-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let a = CanvasNodeID("a")

    private func loadedModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: self.a, kind: .scrap,
                                origin: CGPoint(x: 100, y: 100), width: 240, cachedHeight: 80))
        }
        return model
    }

    // MARK: - Attachment

    /// The discriminator a write tool has to consult. A model exists from the
    /// moment the window does; it is only usable between `attach` and `detach`.
    func test_aFreshModelIsNotAttached() {
        XCTAssertFalse(CanvasModel().isAttached,
                       "a model that has never been attached has no store, so a "
                       + "write into it is accepted, saves nothing, and is thrown "
                       + "away by the next attach()")
    }

    func test_attachThenDetachFlipsIt() {
        let model = CanvasModel()
        XCTAssertFalse(model.isAttached)
        model.attach(projectRoot: root)
        XCTAssertTrue(model.isAttached, "attach() gave it a store and a loaded scene")
        model.detach()
        XCTAssertFalse(model.isAttached,
                       "the Plan persona has gone; the scene here is now a stale "
                       + "copy the next attach() will overwrite")
    }

    // MARK: - The hook

    /// `mutateFromInspector` is the verb for a change made from outside the
    /// canvas, so it is where the view is told to re-derive. Driven here through
    /// the real applier, which is what the write tool will hand it.
    func test_theHookRunsWhenSomethingOutsideTheCanvasChangesTheScene() {
        let model = loadedModel()
        var fired = 0
        model.onSceneChangedExternally = { fired += 1 }

        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: ["a thought", "and another"]),
            in: model.scene)
        model.mutateFromInspector("Add Scraps") { CanvasClaudePlacement.apply(plan, to: &$0) }

        XCTAssertEqual(fired, 1,
                       "without this the new cards have no ScrapLayout, so the draw "
                       + "pass gets a nil layout and they are empty rectangles until "
                       + "the writer happens to click something")
        XCTAssertEqual(plan.scraps.count, 2, "precondition: the plan placed both cards")
        for planned in plan.scraps {
            XCTAssertNotNil(model.scene.node(planned.node.id),
                            "precondition: the applier really did write the scene")
        }
    }

    /// The canvas rebuilds its own layouts on every path that can leave a node
    /// unmeasured, so firing here as well would put a second whole-scene measure
    /// on the gesture path.
    func test_theHookIsNotCalledByAnOrdinaryCanvasEdit() {
        let model = loadedModel()
        var fired = 0
        model.onSceneChangedExternally = { fired += 1 }
        model.mutate("Move Scrap") { $0.move(self.a, to: CGPoint(x: 400, y: 400)) }

        XCTAssertEqual(model.scene.node(a)?.origin, CGPoint(x: 400, y: 400),
                       "precondition: the edit landed")
        XCTAssertEqual(fired, 0,
                       "a mutation from the canvas's own path is already inside a "
                       + "rebuild of its own")
    }

    /// The third edge of the cycle `detach`'s doc comment describes. `CanvasView`
    /// is a struct captured BY VALUE into this closure and it holds `let model`,
    /// so `model → onSceneChangedExternally → CanvasView → model` keeps a closed
    /// window's whole canvas alive: the scene, every scrap's text, the
    /// `UndoManager` and the `CanvasStore`, whose termination observer then
    /// outlives the window and writes this stale scene over whatever replaced it.
    func test_detachClearsTheHook() {
        let model = loadedModel()
        model.beforeFlush = { }
        model.onSceneReplacedByUndo = { }
        model.onSceneChangedExternally = { }
        model.detach()
        XCTAssertNil(model.onSceneChangedExternally,
                     "the new callback is the same retain cycle a third time")
        XCTAssertNil(model.beforeFlush, "control: the two that were already cleared")
        XCTAssertNil(model.onSceneReplacedByUndo)
    }

    // MARK: - The store's reference

    /// `weak`, for the same reason `documentStore` is: the window owns the model,
    /// and a strong reference from a `ProjectStore` that outlives the window
    /// would keep a closed Plan persona's whole canvas alive.
    func test_theStoresReferenceDoesNotKeepAClosedCanvasAlive() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Seam", in: root)
        let store = try await ProjectStore.load(from: url)

        weak var released: CanvasModel?
        func openAndClose() {
            let model = CanvasModel()
            released = model
            store.liveCanvas = model
            XCTAssertNotNil(store.liveCanvas, "precondition: the seam is wired")
        }
        openAndClose()

        XCTAssertNil(released, "the window's model outlived the window")
        XCTAssertNil(store.liveCanvas,
                     "a strong reference here would pin the scene, every scrap's "
                     + "text, the UndoManager and the CanvasStore of every project "
                     + "window that was ever opened on the Plan persona")
    }

    // MARK: - Caller census

    /// **The check that would have caught five built-and-unreachable halves in
    /// this area, every one of which was found by counting callers and none of
    /// them by a test** — 1C-a's ⌘Z, `CanvasScene.remove`,
    /// `CanvasMembership.addAppearance`, `CanvasScene.lines(touching:)` and the
    /// item placeholder. Both halves of this seam are the same shape: a property
    /// that compiles, persists nothing and is read by nobody.
    ///
    /// The two are counted by ASSIGNMENT rather than by mention, so a later slice
    /// adding a *reader* of `liveCanvas` — which is the whole point of it — does
    /// not have to edit this expectation. An assigner appearing that is not
    /// `ProjectWindow` is a second opinion about which canvas is live, and that
    /// is a deliberate edit here.
    func test_theExternalChangeHookHasAProductionCaller() throws {
        XCTAssertEqual(try assigners(of: "onSceneChangedExternally",
                                     excluding: "CanvasModel.swift"),
                       ["CanvasView.swift"],
                       "if this is empty, the hook is declared, cleared on detach "
                       + "and bound to nothing: Claude's cards land in the scene "
                       + "and draw as empty rectangles until the writer clicks")
        XCTAssertEqual(try assigners(of: "liveCanvas", excluding: "ProjectStore.swift"),
                       ["ProjectWindow.swift"],
                       "if this is empty, the store's reference is never set and "
                       + "every tool sees nil — so every write goes to the sidecar "
                       + "behind the writer's back, including while they are "
                       + "looking at the canvas")
    }

    /// The house self-check (`RegionBindingTests.test_theGateScanFiresOnAPlantedBypass`
    /// and `test_applyExternalTextCensusFiresOnPlantedSecondCallSite` are the
    /// precedents). **A census over a token that is REQUIRED to be present is
    /// exactly the shape that passes while blind**, and this repo has shipped
    /// one. So the token is deleted from a copy of each real file and the
    /// predicate must go false.
    ///
    /// **Deletion alone does not demonstrate the predicate's strictness, and the
    /// first draft of this test claimed it did.** Each token occurs exactly once
    /// outside comments in its file, so after a deletion a bare
    /// `contains(token)` also goes false — the arms below prove the census sees a
    /// missing wire, and nothing more. The strictness is proved by the two
    /// *downgrade* arms: a file that merely READS the property is not an
    /// assigner, which is the case a bare `contains` would miscount and the case
    /// a later slice actually produces (Task 5 reads `liveCanvas`).
    func test_theCensusFiresOnAPlantedRemoval() throws {
        let view = try CanvasSourceCensus.source(at: "Maugham/Canvas/CanvasView.swift")
        XCTAssertTrue(assigns("onSceneChangedExternally", in: view),
                      "control: the real file binds the hook")
        XCTAssertFalse(
            assigns("onSceneChangedExternally",
                    in: view.replacingOccurrences(of: "model.onSceneChangedExternally =",
                                                  with: "// the binding, deleted")),
            "the scan cannot see a binding that is gone, so it proves nothing")

        let window = try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(assigns("liveCanvas", in: window),
                      "control: the real file assigns the store's reference")
        XCTAssertFalse(
            assigns("liveCanvas",
                    in: window.replacingOccurrences(of: "s.liveCanvas =",
                                                    with: "// the assignment, deleted")),
            "the scan cannot see an assignment that is gone")

        // **The arms that prove the STRICTNESS**, which the deletions above
        // cannot: the real assignment is downgraded to a READ, so the token is
        // still there and a bare `contains(token)` would still call the file a
        // caller. This is the case a later slice really produces — Task 5 reads
        // `liveCanvas` and must not have to edit the expectation above.
        XCTAssertFalse(
            assigns("liveCanvas",
                    in: window.replacingOccurrences(of: "s.liveCanvas = canvasModel",
                                                    with: "_ = s.liveCanvas")),
            "a file that only reads the property is being counted as the one that "
            + "sets it — so the census would stay green with nothing wired, which "
            + "is exactly the blind shape it exists to avoid")
        XCTAssertFalse(
            assigns("onSceneChangedExternally",
                    in: view.replacingOccurrences(
                        of: "model.onSceneChangedExternally = { rebuildLayouts(bumpsStructuralCounter: false) }",
                        with: "_ = model.onSceneChangedExternally")),
            "same, for the hook: declared, read once, bound to nothing")

        // Two spellings that are the same assignment. Neither is how the source
        // is written today, and both must count, or a reformat empties the census
        // silently — which goes red rather than green here, but with a message
        // about a missing production caller instead of about whitespace.
        for spelling in ["s.liveCanvas=canvasModel", "s.liveCanvas   = canvasModel"] {
            XCTAssertTrue(assigns("liveCanvas", in: spelling),
                          "`\(spelling)` is an assignment and the scan cannot see it")
        }

        // And the comparison, which is the spelling a naive
        // `contains("liveCanvas =")` counts because the range matches inside `==`.
        XCTAssertFalse(assigns("liveCanvas", in: "guard entry.store.liveCanvas == nil else { return }"),
                       "a reader counted as an assigner makes the census grow for "
                       + "the wrong reason, and the next author deletes the "
                       + "expectation rather than the bug")
        XCTAssertFalse(assigns("liveCanvas", in: "guard store.liveCanvas != nil else { return }"),
                       "…and the other comparison")
        XCTAssertFalse(assigns("liveCanvas", in: "let x = store.liveCanvasSnapshot = y"),
                       "a longer identifier that merely starts with the token is "
                       + "not the token")
    }

    /// Every production file under `Maugham/` that ASSIGNS `token`, by name.
    private func assigners(of token: String, excluding definer: String) throws -> [String] {
        try CanvasSourceCensus.productionFiles()
            .filter { $0.name != definer && assigns(token, in: $0.source) }
            .map(\.name)
            .sorted()
    }

    /// Whether `source` contains `token = …` — an assignment, not a comparison
    /// and not a mention in prose. Comments are stripped because this area's
    /// files discuss each other's properties at length, which is the point of
    /// them.
    ///
    /// Three things it has to get right, each with an arm in
    /// `test_theCensusFiresOnAPlantedRemoval`:
    ///
    /// - **Whitespace is not load-bearing.** Any run of spaces or tabs, or none
    ///   at all, is the same assignment; an aligned `=` in a reformat must not
    ///   empty the census.
    /// - **`==`, `!=` and friends are READS.** `range(of: token + " =")` matches
    ///   inside `token ==`, so the character after the `=` decides.
    /// - **The token must end where it ends.** `liveCanvasSnapshot = x` is a
    ///   different property, so the next character may not continue an
    ///   identifier.
    private func assigns(_ token: String, in source: String) -> Bool {
        CanvasSourceCensus.commentsStripped(source)
            .components(separatedBy: "\n")
            .contains { line in
                var searched = line[...]
                while let hit = searched.range(of: token) {
                    let after = line[hit.upperBound...]
                    let continuesTheIdentifier = after.first
                        .map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
                    let operatorAndOn = after.drop { $0 == " " || $0 == "\t" }
                    if !continuesTheIdentifier,
                       operatorAndOn.first == "=",
                       operatorAndOn.dropFirst().first != "=" {
                        return true
                    }
                    searched = line[hit.upperBound...]
                }
                return false
            }
    }
}
