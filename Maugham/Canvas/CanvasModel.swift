import AppKit
import Observation

/// What another column can send the writer's camera to.
///
/// **Two cases and not one, because the two things that arrive from outside the
/// canvas land differently.** Claude's batch is always a labelled region (§8A.2
/// constraint 2), so 1C-c3's arrival banner names one. §8A.4's *command* route
/// lands a single loose card and is ruled to be **never in a region**, so it has
/// no region to name — and both land at `CanvasClaudePlacement.looseOrigin`,
/// which is by construction outside the writer's viewport, so both need the
/// camera or the writer is told about something they cannot find.
///
/// Deliberately **not** `CanvasSelection`, though it looks like a subset of it:
/// that type answers *what is selected*, which the canvas draws chrome for and ⌫
/// acts on, and lines are in it. This one answers *what to look at*, and there is
/// nothing to look at a line for — its ends are cards that are already somewhere.
enum CanvasRevealTarget: Equatable {
    case region(CanvasRegionID)
    case node(CanvasNodeID)
}

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
    /// in `CanvasViewMountingEditingTests` were written, run, and failed exactly
    /// that way
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

    /// The view's chance to re-derive after something OUTSIDE the canvas changed
    /// the scene — a write arriving through `mutateFromInspector`, which is the
    /// one verb the other columns have.
    ///
    /// `CanvasView` binds this to a layout rebuild, and the reason is the same
    /// one `rebuildLayouts`'s own doc gives: a node with no `ScrapLayout` has no
    /// measured height, and a node with no `cachedHeight` has no `frame`, so it
    /// is dropped by `nodes(intersecting:)` and `topmostNode(at:)` alike — on the
    /// canvas, drawn as an empty rectangle, and not clickable. **Named symptom:**
    /// an MCP call adds cards to the canvas the writer is looking at and they sit
    /// there blank until the writer happens to click something.
    ///
    /// **It is the same retain cycle as the two callbacks above** — see
    /// `detach()`, which clears all three — and it is deliberately NOT fired by
    /// `mutate`: everything the canvas does to itself is already followed by a
    /// rebuild of its own, and a second one per gesture is work on the gesture
    /// path.
    @ObservationIgnored var onSceneChangedExternally: (() -> Void)?

    /// The view's chance to move the CAMERA to something another column has sent
    /// the writer to — the Show button on Claude's arrival banner is the first
    /// caller (1C-c3).
    ///
    /// **A callback rather than a `MaughamEvent`, and rather than camera state on
    /// this model.** The camera is `@State` on `CanvasView` because it is a
    /// property of one *view* of this scene, and moving it here would make it
    /// something the region inspector could write. A notification would cost a
    /// scope, a receive helper, a zombie-liveness audit note and a tripwire-21
    /// entry to say something that is not an app-wide fact — and it would make
    /// delivery order the correctness argument. The two callbacks above are the
    /// precedent, and `CanvasView` binds all three in one place.
    ///
    /// **It carries an ID and not a point**, which is not the obvious
    /// choice. `CanvasCamera.bring` takes a point, so the caller could resolve
    /// one — and the caller is in another column, where the scene it would read
    /// is exactly the one that can be wrong: `add_canvas_scraps` writes the
    /// SIDECAR when this model is not attached (`isAttached`), so a writer who
    /// has not opened the Plan persona this session holds a scene with no such
    /// region in it and would resolve nothing. Handing over the id lets the point
    /// be resolved on the far side of `attach()`, from the scene that has the
    /// region in it.
    ///
    /// **It is the same retain cycle as those two** — see `detach()`, which
    /// clears all three.
    @ObservationIgnored var onRevealRequested: ((CanvasRevealTarget) -> Void)?

    /// A reveal asked for while no canvas was on screen, kept until one is.
    ///
    /// **This exists because the hook is nil in the ordinary case.** Show sends
    /// the writer to the Plan persona *and* asks for the reveal, and until that
    /// persona switch has mounted `CanvasView` there is no hook to call — so the
    /// version of this that only called the closure dropped the reveal precisely
    /// when the writer was not already looking at the canvas, which is every time
    /// the banner is the thing that told them. Deferring the call by a run-loop
    /// hop instead would make SwiftUI's mount ordering the correctness argument,
    /// which is tripwire 2's shape.
    ///
    /// A *request*, not camera state: it is consumed once and never read back, and
    /// nothing about where the camera IS lives on this model.
    @ObservationIgnored private(set) var pendingReveal: CanvasRevealTarget?

    /// Ask the view to bring `target` into sight — now if a canvas is on screen,
    /// on its next appearance otherwise.
    func reveal(_ target: CanvasRevealTarget) {
        guard let onRevealRequested else {
            pendingReveal = target
            return
        }
        // Cleared, so a mount later in the session does not re-jump to something
        // the writer has since panned away from deliberately.
        pendingReveal = nil
        onRevealRequested(target)
    }

    /// Consume the parked request. `CanvasView.load()` calls this after `attach`,
    /// which is the first moment the scene is guaranteed to hold the target.
    func takePendingReveal() -> CanvasRevealTarget? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// Whether this model has a store and a scene read off disk — true between
    /// `attach(projectRoot:)` and `detach()`, which is to say while the Plan
    /// persona is actually on screen.
    ///
    /// **This is the discriminator a writer from outside the window must consult,
    /// and "does a `CanvasModel` exist" is not it.** The model is created eagerly
    /// with `ProjectWindow`, while `attach` runs from `CanvasView.onAppear` — so
    /// a project window whose writer has never opened the Plan persona holds a
    /// model that is real, addressable and unusable. Either way a write into an
    /// unattached model is accepted and reports real ids, and either way it
    /// **vanishes**, with nothing red. The two routes there are different and
    /// both are worth knowing:
    ///
    /// - **Never attached:** `store` is nil, so `scheduleSave` is a silent no-op.
    ///   The scene is written nowhere, and the writer's first visit to the Plan
    ///   persona calls `attach`, which overwrites it wholesale from disk.
    /// - **Attached and then detached:** `store` survives — `detach` flushes it
    ///   and clears its callback but does not release it, and it is only replaced
    ///   by the next `attach` — so a save here really would reach disk. What is
    ///   stale is the SCENE: it is the snapshot from when the persona closed, and
    ///   it cannot see anything written to the sidecar since. A caller that took
    ///   the sidecar route for one call and this one for the next would silently
    ///   drop the first.
    ///
    /// A caller that finds this false must go to the sidecar instead.
    @ObservationIgnored private(set) var isAttached = false

    @ObservationIgnored private var store: CanvasStore?

    /// How long an edit sits before the debounced save writes it. Production
    /// never touches this; mounted-view tests shorten it so a wait for
    /// "reached disk" is a wait on a fast real timer instead of 750 ms of wall
    /// clock per test. Read once, at `attach` — set it before the view mounts.
    @ObservationIgnored var saveDebounceInterval: TimeInterval =
        CanvasStore.defaultDebounceInterval

    /// How long the writer must be still before `ScrapUndoBeat` closes a
    /// typing step. Same contract as `saveDebounceInterval`: production
    /// default, shortened by mounted-view tests.
    @ObservationIgnored var undoIdleInterval: TimeInterval = ScrapUndoBeat.idleSeconds

    /// Whether the debounced save has been scheduled and not yet written —
    /// the condition mounted tests pump against instead of a fixed wall-clock
    /// wait. False when unattached, because nothing can be pending in a store
    /// that does not exist.
    var hasPendingSave: Bool { store?.hasPendingWrite ?? false }

    // MARK: - Lifecycle

    /// Build a store, read both files, wire the recorder. This is 1C-a's
    /// `CanvasView.load()` moved one object outwards and otherwise unchanged.
    func attach(projectRoot: URL) {
        let s = CanvasStore(projectRoot: projectRoot,
                            debounceInterval: saveDebounceInterval)
        s.beforeFlush = { [weak self] in self?.beforeFlush?() }
        store = s
        var loaded = s.load()
        // Before the assignment, deliberately: this is load-time reconciliation
        // and not a writer gesture, so it mutates the loaded VALUE and reaches no
        // undo bracket (there is none open at attach time, and one opened here
        // would put a repair on the stack a ⌘Z aimed at a sentence could take).
        let repaired = Self.surfaceOrphanScraps(in: &loaded.scene, scraps: &loaded.scraps)
        scene = loaded.scene
        scraps = loaded.scraps
        isAttached = true

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

        // Last, so the payload it queues is the repaired canvas. Debounced
        // rather than written: `CanvasView.load()` calls this on `.onAppear` and
        // a synchronous write there would put file I/O on the mount.
        //
        // **And never over a sidecar this build refused to read.** A file from a
        // newer build, or one whose bytes are damaged, loads as an empty scene
        // with the scraps intact — so every scrap is an orphan and the repair
        // below would otherwise stamp a current-schema sidecar over somebody's
        // whole arrangement 750 ms after the writer merely OPENED the canvas.
        // The words are still surfaced, in memory, where they can be read; the
        // file survives being looked at, and is only replaced if the writer
        // actually edits from this build (which is their own act, in their own
        // undo bracket, and is a save this branch did not invent).
        if repaired && loaded.sidecar.acceptsARepairWrite { scheduleSave() }
    }

    /// Give every orphaned scrap somewhere to be — a card, or nothing at all.
    ///
    /// **An orphan is an id `canvas.md` holds words for that `canvas.json` has no
    /// node for** (F9, issue #28). It is invisible for ever, and
    /// `ScrapText.render` rewrites it into `canvas.md` on every save, so it also
    /// never goes away. Three things produce one and none of them is exotic: a
    /// crash between the two writes (which is why they are ordered content-first),
    /// a node the codec dropped, and `saveSceneOnly`, which writes the sidecar
    /// alone. **The sidecar being absent or unreadable is the fourth and the
    /// loudest**: `CanvasStore.load` answers with an empty scene and the scraps
    /// intact, so every word the writer owns is an orphan at once — and it is
    /// this function that makes "an empty layout with the words intact is a
    /// recoverable state" true rather than aspirational. (Unreadable is also the
    /// one case whose repair is not saved — see the `acceptsARepairWrite` line
    /// at the end of `attach`.)
    ///
    /// **Denver's ruling, 2026-08-12: an orphan is SURFACED — not silently
    /// pruned, and not silently kept.** Words the writer typed come back as a
    /// card they can see, read and decide about; a whitespace-only entry is cruft
    /// with nothing in it to lose and is dropped. Pruning the text-bearing ones
    /// instead would delete exactly the words the crash window left behind, which
    /// is constitution must #1 read backwards.
    ///
    /// **The card is the WRITER'S and it lands loose.** `author` stays nil (nil
    /// *is* the writer) so it leans by at least `minimumTiltDegrees` and true
    /// zero stays reserved for Claude (ADR 0026 §10) — these are the writer's own
    /// words coming back, and a repair that drew them straight and cool would say
    /// Claude wrote them. It joins no region for `CanvasCapture.Placement.loose`'s
    /// reason: membership is something the writer stated, and this function has no
    /// idea what they meant, so inventing one is a container they never asked for.
    /// `CanvasClaudePlacement.looseOrigin` is the one spelling of "clear of the
    /// writer's work" and is re-asked per card, so a canvas whose sidecar has just
    /// been deleted comes back as a row of cards rather than a stack of one.
    ///
    /// **Born measured**, like every other producer on this surface: a node with
    /// no `cachedHeight` has no `frame`, and both `nodes(intersecting:)` and
    /// `topmostNode(at:)` drop one that has none — so an unmeasured resurrection
    /// would be the invisible orphan again, with a node added to it.
    ///
    /// Reports whether anything changed, so an untouched canvas queues no write.
    /// Idempotent by construction: the repaired ids have nodes now, and the
    /// dropped ones have no words.
    private static func surfaceOrphanScraps(in scene: inout CanvasScene,
                                            scraps: inout [CanvasNodeID: String]) -> Bool {
        // Sorted, so a canvas repaired twice from the same files lays its cards
        // out the same way twice — dictionary order is not.
        let orphans = scraps.keys
            .filter { scene.node($0) == nil }
            .sorted { $0.raw < $1.raw }
        guard !orphans.isEmpty else { return false }

        for id in orphans {
            let text = scraps[id] ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                scraps[id] = nil
                continue
            }
            let width = CanvasInteraction.defaultScrapWidth
            scene.insert(CanvasNode(
                id: id, kind: .scrap,
                origin: CanvasClaudePlacement.looseOrigin(in: scene),
                width: width,
                cachedHeight: CanvasScrapMeasure.height(text: text, cardWidth: width),
                z: scene.topZ + 1))
        }
        return true
    }

    /// Write, and then let go of every closure that points back at the owner.
    /// `CanvasView` calls this from `.onDisappear`, which is where 1C-a does the
    /// same work.
    ///
    /// **The callbacks below are the retain cycle, and they are the whole
    /// reason this method exists** — count the `= nil` lines rather than a number
    /// in this sentence; it said "two" over three. `CanvasView` is a struct
    /// captured BY VALUE into each of them, and it holds `let model` — so
    /// `model → beforeFlush → CanvasView → model` is a cycle, and
    /// `onSceneReplacedByUndo`, `onSceneChangedExternally` and (1C-c3)
    /// `onRevealRequested` are each the same cycle again. Left set, a
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
        onSceneChangedExternally = nil
        onRevealRequested = nil
        // Last, and it is the fact the rest of this method establishes: the
        // scene left behind is a snapshot of a canvas nobody is looking at any
        // more, and the next `attach` replaces it from disk. Note that the store
        // is deliberately NOT released here, so this is not "saves go nowhere" —
        // the property's doc says what each case actually costs.
        isAttached = false
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
    func renameGesture(_ name: String) { undo.renameGesture(name) }
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
    ///
    /// **It is also where `onSceneChangedExternally` fires**, because this verb
    /// is the definition of "the scene changed and the canvas did not do it".
    /// Inside the bracket rather than after it, so the derived re-measure the
    /// view does belongs to the step the writer can take back — exactly as the
    /// undo apply folds its own re-measure into the apply. After it, the measure
    /// would land in the "Edit Scrap" gesture `mutateFromOutsideTheCanvas` has
    /// just reopened, i.e. in the writer's next sentence.
    ///
    /// **A caller that writes scrap TEXT as well as scene shape hands the words
    /// to `scrapTexts`** rather than calling `setScrapText` around the call.
    /// Two reasons, and the first is the one with a silent failure behind it:
    ///
    /// - **Written before the call the words land in the WRITER's step; written
    ///   after it, in the writer's NEXT one.** A snapshot is
    ///   `(scene, scraps)` and `endGesture` diffs the whole of it, so text folded
    ///   in before `mutateFromOutsideTheCanvas` closes the open "Edit Scrap"
    ///   gesture is registered under the writer's name, and text folded in after
    ///   the close lands inside the gesture that has just been REOPENED. That is
    ///   exactly the ride-along this verb exists to prevent, arriving through the
    ///   scraps half of the snapshot instead of the scene half — and it is
    ///   invisible to any assertion about the scene alone.
    /// - **Inside the bracket the words go in FIRST**, because
    ///   `onSceneChangedExternally` re-measures each card from the text it finds,
    ///   and a card measured before its words arrive is measured empty.
    ///
    /// One `scheduleSave` covers both halves: `withScene` queues the payload with
    /// the words already in `scraps`.
    func mutateFromInspector(_ name: String,
                             scrapTexts: [CanvasNodeID: String] = [:],
                             _ body: (inout CanvasScene) -> Void) {
        undo.mutateFromOutsideTheCanvas(name) {
            for (id, text) in scrapTexts { scraps[id] = text }
            withScene(body)
            onSceneChangedExternally?()
        }
    }
}
