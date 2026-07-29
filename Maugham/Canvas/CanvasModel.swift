import AppKit
import Observation

/// The canvas's state, owned by `ProjectWindow` because two columns read it.
///
/// **What lives here:** the scene, the scrap text, the selection, the sidecar
/// store and the undo recorder. **What deliberately does not:** camera, layouts,
/// editing focus, the straighten, momentum and the redraw counters — those are
/// properties of one *view* of the canvas and stay in `CanvasView`.
///
/// **This class hosts `CanvasUndo`; it does not reimplement it.** 1C-a built the
/// recorder to reach its state through two closures precisely so ownership could
/// move here. A second snapshot mechanism silently loses `breakGesture`
/// (per-sentence ⌘Z inside a scrap), the deferred `beginUndoGrouping` (a group
/// cannot span an event boundary), the nesting depth counter, and the
/// mid-gesture re-baseline. Named symptom for the last: type in A, click into B,
/// ⌘Z, type in B, click out — and the next ⌘Z resurrects A's discarded text.
@Observable
final class CanvasModel {

    private(set) var scene = CanvasScene()
    private(set) var scraps: [CanvasNodeID: String] = [:]

    /// One selection for both primitives, so ⌫ has a single meaning and the
    /// inspector has a single thing to read.
    var selection: CanvasSelection?

    var selectedRegion: CanvasRegion? {
        guard case .region(let id) = selection else { return nil }
        return scene.region(id)
    }

    /// The selected line, RESOLVED through the scene rather than reconstructed
    /// from the selection — so a stale id left behind by an undo answers nil here
    /// rather than being handed out as a line that no longer exists.
    ///
    /// Through `scene.line(_:)` and never `scene.lines.first { … }`: the ordered
    /// accessor sorts the whole set, and the line inspector reads this per body
    /// evaluation. Off the frame path is not the same as off the render path.
    var selectedLine: CanvasLine? {
        guard case .line(let id) = selection else { return nil }
        return scene.line(id)
    }

    /// The selected card, RESOLVED through the scene — the same discipline
    /// `selectedLine` follows, and for the same reason: a stale id left behind
    /// by an undo answers nil here rather than being handed out as a card that
    /// is no longer in the scene.
    var selectedNode: CanvasNode? {
        guard case .node(let id) = selection else { return nil }
        return scene.node(id)
    }

    /// The STRUCTURAL counter. `CanvasView` keeps its own `@State` copy — that
    /// name is grepped by `CanvasAccessibilityTests` — and mirrors this one.
    /// Never bumped per frame (tripwire 30).
    private(set) var sceneRevision = 0

    /// ⌘Z, scoped to the canvas. `@Environment(\.undoManager)` would give a
    /// window-lifetime manager shared with the manuscript editor's op-log stack
    /// (ADR 0023), and a persona switch mid-drag would leave a half-open group
    /// on it. `CanvasUndo` is the only thing that ever registers here — the
    /// mounted `NSTextView` has `allowsUndo == false` and registers nothing.
    ///
    /// **`groupsByEvent` is off, and that is not a test affordance.** Left at its
    /// default it wraps everything registered during one pass of the event loop
    /// in an implicit top-level group. `CanvasUndo` already brackets every
    /// gesture explicitly, so that group can only take granularity away: two
    /// gestures that happen to land in one pass — a sentence finished by the same
    /// keystroke that a pause has already closed a step on — collapse into a
    /// single ⌘Z, and which pairs collapse depends on how AppKit batched the
    /// events. One gesture is one step, always, and that is what this line buys.
    ///
    /// It is also the only way the behaviour is observable. That implicit group
    /// is closed by `NSApplication`'s event loop and NOT by a run-loop turn —
    /// measured 2026-07-26 on macOS 26.5: `groupingLevel` is 1 after a
    /// registration and still 1 after `RunLoop.run(until:)`, twice over. So with
    /// the default, every canvas step a test makes lands in ONE group that never
    /// closes and one ⌘Z unwinds the whole test; the sentence-granularity tests
    /// in `CanvasViewMountingTests` were written, run, and failed exactly that way
    /// before this line existed. Leaving it on would also mean the shipping
    /// manager is configured differently from every manager the tests exercise,
    /// since `undo()` called synchronously against an open implicit group raises
    /// `NSInternalInconsistencyException` and the unit tests must turn it off
    /// regardless.
    ///
    /// The cost is that a registration outside an explicit group would now raise
    /// rather than being quietly absorbed. `CanvasUndo` is the only registrant —
    /// pinned by `CanvasUndoTests.test_typingIntoTheMountedEditorRegistersNothingOfItsOwn`
    /// for the text view, by `CanvasCompositionTests.test_theCanvasRegistersUndoInExactlyOnePlace`
    /// for the area as a whole, and by the `groupingLevel` assertion in
    /// `CanvasUndo.register` — and it registers only between `beginUndoGrouping`
    /// and `endUndoGrouping`.
    ///
    /// **`levelsOfUndo` is capped, because `UndoManager`'s default is
    /// unlimited.** Every step here retains a whole `CanvasScene` AND a whole
    /// `[CanvasNodeID: String]` — every scrap's text, copied — and the
    /// granularity is one step per SENTENCE typed, not per visit. Unbounded,
    /// nothing gives any of it back until `release()` at window close.
    ///
    /// 200 is chosen from both ends. From the writer's: at one step per sentence
    /// it is a long afternoon's worth of sentences, and orders of magnitude more
    /// than a session's drags — nobody ⌘Zs past 200 steps meaning to arrive
    /// somewhere. From memory's: a 200-scrap canvas of paragraph-sized scraps is
    /// on the order of 10 KB of copied dictionary per step, so the stack is
    /// bounded at roughly 2 MB per canvas rather than at the length of the
    /// session.
    @ObservationIgnored let undoManager: UndoManager
    @ObservationIgnored let undo: CanvasUndo

    /// Written out rather than using property initialisers, because `undo`
    /// needs `undoManager` and a property initialiser cannot see a sibling.
    init() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 200
        undoManager = manager
        undo = CanvasUndo(undoManager: manager)
    }

    /// The view's chance to re-derive its own state after an undo has replaced
    /// the scene underneath it: stop a coast, leave a scrap that no longer
    /// exists, re-measure. Called synchronously, inside the apply.
    @ObservationIgnored var onSceneReplacedByUndo: (() -> Void)?

    /// The owner's last synchronous chance to fold the live editor's text into
    /// the payload before it is written. Forwarded to `CanvasStore.beforeFlush`
    /// — drop it and ⌘Q loses the sentence in flight.
    @ObservationIgnored var beforeFlush: (() -> Void)?

    @ObservationIgnored private var store: CanvasStore?

    // MARK: - Lifecycle

    /// Build a store, read both files, wire the recorder. This is 1C-a's
    /// `CanvasView.load()` moved one object outwards and otherwise unchanged.
    func attach(projectRoot: URL) {
        let s = CanvasStore(projectRoot: projectRoot)
        s.beforeFlush = { [weak self] in self?.beforeFlush?() }
        store = s
        let loaded = s.load()
        scene = loaded.scene
        scraps = loaded.scraps

        undo.readSnapshot = { [unowned self] in (scene, scraps) }
        undo.applySnapshot = { [unowned self] snapshot in
            scene = snapshot.scene
            scraps = snapshot.scraps
            // A snapshot carries the scene and the scrap text, NOT the
            // selection — so an undo that takes back a region or a card can
            // leave `selection` naming something that is no longer in the scene.
            // The renderer shrugs (it compares ids against what it is drawing),
            // and every READER does not: `selectedRegion` resolves it, and the
            // ⌫ path and the region inspector both go through that. Cleared
            // here rather than at each reader, because a model that hands out a
            // dangling id is the thing that is wrong.
            clearSelectionIfItNoLongerResolves()
            // Synchronous, and before any timeline tick can run: the view stops
            // its coast, drops focus on a scrap the undo took away, and
            // re-measures every card. Heights are DERIVED, so a restored scene
            // is re-measured rather than trusted.
            onSceneReplacedByUndo?()
            // UNCONDITIONAL, and deliberately not "only when nothing is wired".
            // Every reader of this counter must see an undo, whether or not a
            // canvas happens to be on screen — a model that under-counts while a
            // view is attached is a model that is no longer correct on its own.
            // The view's own bump is suppressed on this one path instead; see
            // `CanvasView.rebuildLayouts(bumpsStructuralCounter:)`.
            sceneRevision += 1
            scheduleSave()
        }
    }

    /// Write, and then let go of every closure that points back at the owner.
    /// `CanvasView` calls this from `.onDisappear`, which is where 1C-a does the
    /// same work.
    ///
    /// **The two callbacks below are the retain cycle, and they are the whole
    /// reason this method exists.** `CanvasView` is a struct captured BY VALUE
    /// into each of them, and it holds `let model` — so
    /// `model → beforeFlush → CanvasView → model` is a cycle, and
    /// `onSceneReplacedByUndo` is the same cycle a second time. Left set, a
    /// closed Plan persona never deallocates its `CanvasModel`: the scene, every
    /// scrap's text, the `UndoManager` and the `CanvasStore` all stay alive,
    /// `CanvasStore.deinit` never runs so its `willTerminateNotification`
    /// observer outlives the window, and the captured view's
    /// `paletteSwatchHexes` closure pins one `ProjectStore` per closed project
    /// window.
    ///
    /// `store.beforeFlush` is cleared too, but it is NOT part of that cycle —
    /// it captures `[weak self]`. It is cleared so a store that outlives this
    /// detach (it is only released when the next `attach` replaces it) cannot
    /// call back into a canvas that is gone.
    ///
    /// `undo.release()` covers the third and fourth edges: the recorder's two
    /// closures, and the manager's retain of the recorder once per step.
    ///
    /// `CanvasView.load()` re-sets both callbacks on the next `.onAppear`, so a
    /// persona switch back is unaffected.
    func detach() {
        // No `beforeFlush?()` of our own: `CanvasStore.flush` calls it first
        // thing, through the `[weak self]` hop `attach` wired. One path, so
        // `CanvasModelTests.test_detachFoldsTheLiveEditInBeforeItWrites` fails
        // if that wiring is ever dropped — with a second call here it could not.
        store?.flush()
        store?.beforeFlush = nil
        undo.release()
        beforeFlush = nil
        onSceneReplacedByUndo = nil
    }

    // MARK: - Mutation

    /// The one way the scene changes.
    ///
    /// `persist: false` is for the frames of a live gesture, which queue their
    /// own save at `.ended` — a drag emits a position per frame and must not
    /// emit a write per frame.
    func withScene(persist: Bool = true, _ body: (inout CanvasScene) -> Void) {
        body(&scene)
        if persist { scheduleSave() }
    }

    func setScrapText(_ text: String, for id: CanvasNodeID) {
        scraps[id] = text
        scheduleSave()
    }

    func removeScrapText(_ id: CanvasNodeID) {
        scraps[id] = nil
        scheduleSave()
    }

    func scheduleSave() { store?.scheduleSave(scene: scene, scraps: scraps) }

    func flush() { store?.flush() }

    /// Bumped by whoever finished a structural change — the end of a gesture,
    /// the end of a coast, a create, a delete. Never per frame.
    func bumpSceneRevision() { sceneRevision += 1 }

    /// Drop a selection whose subject has left the scene.
    ///
    /// Called from the undo apply, which is the one path that replaces the scene
    /// wholesale underneath a selection that was made against the old one.
    private func clearSelectionIfItNoLongerResolves() {
        switch selection {
        case .node(let id) where scene.node(id) == nil: selection = nil
        case .region(let id) where scene.region(id) == nil: selection = nil
        // A snapshot carries the SCENE, not the selection, so an undo that takes
        // back a line otherwise leaves the inspector holding a dangling id.
        case .line(let id) where scene.line(id) == nil: selection = nil
        case .node, .region, .line, nil: break
        }
    }

    // MARK: - Undo, forwarded

    /// Whether an undo bracket is open right now.
    ///
    /// Read by `CanvasView.deleteSelection()`, which refuses mid-gesture: a
    /// nested `beginGesture` takes no snapshot and a nested `endGesture`
    /// registers nothing, so a delete opened inside somebody else's bracket
    /// cannot be taken back on its own — and if that bracket never closes, not
    /// at all.
    var isInGesture: Bool { undo.isInGesture }

    func beginGesture(_ name: String) { undo.beginGesture(name) }
    func endGesture() { undo.endGesture() }
    func breakGesture() { undo.breakGesture() }
    func mutate(_ name: String, _ body: (inout CanvasScene) -> Void) {
        undo.beginGesture(name)
        withScene(body)
        undo.endGesture()
    }

    /// The region inspector's ONLY way to change the scene.
    ///
    /// It is not `mutate` because the inspector is in the window's *other*
    /// column and the canvas may be holding "Edit Scrap" open the whole time the
    /// writer is in it — see `CanvasUndo.mutateFromOutsideTheCanvas`, where the
    /// failure is written out. `CanvasView` must keep using `mutate`: everything
    /// it does is already inside its own bracket by construction.
    func mutateFromInspector(_ name: String, _ body: (inout CanvasScene) -> Void) {
        undo.mutateFromOutsideTheCanvas(name) { withScene(body) }
    }
}
