import XCTest
@testable import Maugham

final class CanvasModelTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")

    private func loadedModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: self.a, kind: .scrap,
                                origin: CGPoint(x: 100, y: 100), width: 240, cachedHeight: 80))
            s.insertRegion(CanvasRegion(id: self.r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return model
    }

    /// The canary for the mounted suite's shortened clocks: a model nobody
    /// configured runs the production intervals. `CanvasViewMountingTests`
    /// shortens both on every model it mints; if either default here drifts,
    /// it is the APP's save rhythm or undo beat that moved, not a test's.
    func test_anUnconfiguredModelRunsTheProductionClocks() {
        let model = CanvasModel()
        XCTAssertEqual(model.saveDebounceInterval, 0.75,
                       "the save debounce no longer matches DocumentStore's "
                       + "autosave rhythm")
        XCTAssertEqual(model.undoIdleInterval, 1.5,
                       "the idle beat that closes a typing step moved")
    }

    /// The seam, end to end: an edit made through the model — which is the ONLY
    /// thing the inspector holds — lands in the sidecar on disk.
    func test_aRegionEditThroughTheModelReachesDisk() {
        let model = loadedModel()
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        model.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.label, "Falls")
    }

    /// `selectedRegion` resolves a REGION selection and nothing else — the case
    /// guard, which is what stops ⌫ and the inspector treating a selected card
    /// as a selected region.
    func test_selectedRegionResolvesARegionSelectionAndNothingElse() {
        let model = loadedModel()
        model.selection = .region(r1)
        XCTAssertEqual(model.selectedRegion?.displayLabel, "Act II fog")
        model.selection = .node(a)
        XCTAssertNil(model.selectedRegion, "a selected NODE is not a selected region")
    }

    /// **An undo that takes back the selected thing must take back the
    /// selection with it.** A snapshot carries the scene and the scrap text and
    /// not the selection, so without this the model hands out an id that
    /// resolves to nothing — and every reader of it (`selectedRegion`, which is
    /// what ⌫ and the region inspector both go through) has to guess.
    ///
    /// Both halves are asserted. The second is the control: an undo that cleared
    /// the selection unconditionally would satisfy the first and quietly deselect
    /// the writer's card on every ⌘Z.
    func test_anUndoThatRemovesTheSelectedThingClearsTheSelection() {
        let model = loadedModel()
        let drawn = CanvasRegionID("drawn")
        model.mutate("New Region") {
            $0.insertRegion(CanvasRegion(id: drawn, label: "",
                                         frame: CGRect(x: 700, y: 0, width: 200, height: 200)))
        }
        model.selection = .region(drawn)

        model.undo.undo()
        XCTAssertNil(model.scene.region(drawn), "precondition: the undo took the region back")
        XCTAssertNil(model.selection,
                     "the selection still names a region that is no longer in the "
                     + "scene — `selectedRegion` resolves to nil and the inspector "
                     + "and ⌫ are both left guessing what is selected")

        // The control: a selection that STILL resolves must survive an undo.
        model.selection = .node(a)
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        model.undo.undo()
        XCTAssertEqual(model.selection, .node(a),
                       "an undo that had nothing to do with the selected card "
                       + "deselected it anyway")
    }

    /// `mutate` registers a step, and its undo puts the label back.
    ///
    /// Deliberately NOT named for "no second undo stack" — this would pass
    /// against a hand-rolled duplicate that happened to work. The thing that
    /// genuinely forbids a second registrant is the area-wide census in
    /// `CanvasCompositionTests.test_theCanvasRegistersUndoInExactlyOnePlace`.
    func test_mutateRegistersAStepWhoseUndoRestoresTheLabel() {
        let model = loadedModel()
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        XCTAssertTrue(model.undo.canUndo)
        model.undo.undo()
        XCTAssertEqual(model.scene.region(r1)?.label, "Act II fog")
    }

    /// `endGesture` registers nothing when the state did not move — the property
    /// that stops a stray click leaving a ⌘Z that appears to do nothing.
    func test_aGestureThatChangedNothingLeavesNothingToUndo() {
        let model = loadedModel()
        model.mutate("Rename Region") { _ in }
        XCTAssertFalse(model.undo.canUndo)
    }

    /// `breakGesture` is what gives a long visit more than one ⌘Z. A hand-rolled
    /// duplicate loses it silently, so this asks for it directly.
    func test_aBrokenGestureIsTwoStepsRatherThanOne() {
        let model = loadedModel()
        model.beginGesture("Edit Scrap")
        model.setScrapText("one.", for: a)
        model.breakGesture()
        model.setScrapText("one. two.", for: a)
        model.endGesture()

        model.undo.undo()
        XCTAssertEqual(model.scraps[a], "one.")
        model.undo.undo()
        XCTAssertEqual(model.scraps[a] ?? "", "")
    }

    func test_aNestedGestureIsAbsorbedRatherThanUnbalancingTheManager() {
        let model = loadedModel()
        model.beginGesture("Move Region")
        model.beginGesture("Move Scrap")
        model.withScene { $0.move(self.a, to: CGPoint(x: 500, y: 500)) }
        model.endGesture()
        // Asked of the MANAGER, not the recorder. `CanvasUndo.canUndo` carries a
        // second term for the run still inside an open gesture — deliberately,
        // so the Edit menu is not greyed out halfway through the first sentence
        // typed into a scrap — and the outer bracket here is still open. What
        // "absorbed" means is that nothing reached the STACK.
        XCTAssertFalse(model.undoManager.canUndo,
                       "the inner close must not register a step")
        XCTAssertTrue(model.undo.canUndo,
                      "…and the open outer gesture is still offered as undoable")
        model.endGesture()
        XCTAssertTrue(model.undoManager.canUndo)

        model.undo.undo()
        XCTAssertEqual(model.scene.node(a)?.origin, CGPoint(x: 100, y: 100),
                       "one ⌘Z, one gesture — the whole outer bracket")
    }

    func test_theStructuralCounterMovesOnAStructuralChangeAndNotOnASave() {
        let model = loadedModel()
        let before = model.sceneRevision
        model.withScene { $0.move(self.a, to: CGPoint(x: 1, y: 1)) }
        XCTAssertEqual(model.sceneRevision, before,
                       "a move is not structural until its gesture ends — the view "
                       + "bumps it there, exactly as 1C-a does")
        model.bumpSceneRevision()
        XCTAssertEqual(model.sceneRevision, before + 1)
    }

    /// There is exactly ONE path from `detach` to the fold —
    /// `CanvasStore.flush` → the `[weak self]` hop `attach` wired →
    /// `model.beforeFlush` — so deleting that wiring turns this red. While
    /// `detach` also called `beforeFlush` itself, this test stayed green with
    /// the wiring gone and was falsifiable only for its own redundant call.
    func test_detachFoldsTheLiveEditInBeforeItWrites() {
        let model = loadedModel()
        model.beforeFlush = { model.setScrapText("the sentence in flight", for: self.a) }
        model.withScene { $0.move(self.a, to: CGPoint(x: 7, y: 7)) }  // queues a save
        model.detach()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[a],
                       "the sentence in flight",
                       "⌘Q mid-sentence must write the sentence")
    }

    /// `detach` drops the two callbacks that point back at the owner. They are
    /// a retain cycle — `CanvasView` is a struct captured BY VALUE and holds
    /// `let model` — and left set, a closed Plan persona keeps its scene, every
    /// scrap's text, its `UndoManager`, its `CanvasStore` (whose termination
    /// observer then outlives the window) and, through the captured view's
    /// palette closure, one whole `ProjectStore`.
    func test_detachLetsGoOfTheCallbacksThatPointBackAtTheOwner() {
        let model = loadedModel()
        model.beforeFlush = { }
        model.onSceneReplacedByUndo = { }
        model.detach()
        XCTAssertNil(model.beforeFlush,
                     "beforeFlush still captures the owner, which owns the model")
        XCTAssertNil(model.onSceneReplacedByUndo,
                     "onSceneReplacedByUndo is the same cycle a second time")
    }

    /// One structural bump per ⌘Z, whatever the wired view does inside the
    /// apply. The counter exists because rebuilding the accessibility tree
    /// sorts the scene and copies every scrap's string; a writer holding ⌘Z
    /// pays that per step.
    func test_anUndoMovesTheStructuralCounterExactlyOnce() {
        let model = loadedModel()
        model.mutate("Move Scrap") { $0.move(self.a, to: CGPoint(x: 400, y: 400)) }
        // What `CanvasView` binds: re-measuring the restored cards, which
        // mutates the scene again from inside the apply.
        model.onSceneReplacedByUndo = {
            model.withScene(persist: false) { $0.setCachedHeight(90, for: self.a) }
        }
        let before = model.sceneRevision
        model.undo.undo()
        XCTAssertEqual(model.sceneRevision, before + 1,
                       "an undo is one structural change, and the re-measure the "
                       + "view does inside the apply is part of it")
    }

    func test_reattachingReadsWhatDetachWrote() {
        let model = loadedModel()
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        model.detach()
        model.attach(projectRoot: root)
        XCTAssertEqual(model.scene.region(r1)?.label, "Falls")
    }

    /// **A probe, not a bound on the machine.** `@Observable` generates a
    /// `_modify` accessor, so `withScene` should mutate the stored scene in
    /// place; if it ever compiles down to get-modify-set instead, every drag
    /// frame copies the whole node dictionary. At 2,000 nodes that is ~2,000
    /// element copies per frame, so the two timings below diverge by orders of
    /// magnitude rather than by a few percent — which is why the bound can be
    /// generous and still catch it.
    func test_aSceneMutationThroughTheModelDoesNotCopyTheWholeScene() {
        let count = CanvasPerformanceProbeTests.supportedNodeCount
        let target = CanvasNodeID("n\(count / 2)")
        var bare = CanvasScene()
        for i in 0..<count {
            bare.insert(CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                                   origin: .zero, width: 240, cachedHeight: 40))
        }
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene(persist: false) { $0 = bare }

        func seconds(_ body: () -> Void) -> TimeInterval {
            let start = Date(); body(); return -start.timeIntervalSinceNow
        }
        let iterations = 10_000
        let bareTime = seconds {
            for i in 0..<iterations { bare.move(target, to: CGPoint(x: CGFloat(i), y: 0)) }
        }
        let modelTime = seconds {
            for i in 0..<iterations {
                model.withScene(persist: false) { $0.move(target, to: CGPoint(x: CGFloat(i), y: 0)) }
            }
        }
        print("[probe] \(iterations) moves over \(count) nodes — "
              + "bare \(String(format: "%.1f", bareTime * 1000)) ms, "
              + "through the model \(String(format: "%.1f", modelTime * 1000)) ms")
        XCTAssertLessThan(modelTime, max(bareTime * 20, 0.1),
                          "withScene is copying the scene per mutation")
    }
}
