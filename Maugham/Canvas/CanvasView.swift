import AppKit
import SwiftUI

/// The Plan persona's centre column.
///
/// LAYER ORDER IS A HARD CONSTRAINT, not a preference:
///
///   1. `CanvasGround`      — shader, hit testing off
///   2. `Canvas`            — drawn nodes, hit testing off
///   3. `CanvasEventView`   — camera + pointer
///   4. `ScrapEditorHost`   — the one live editor, FRONTMOST
///
/// The ground is a SIBLING BENEATH the content because a shader applied *over* a
/// subtree holding an `NSViewRepresentable` renders a placeholder (spec §7A.4),
/// and this view has two of them. The editor is in FRONT of the event view
/// because that is the only way the writer gets AppKit's own click-to-place-caret,
/// drag-select and double-click-word; with the order reversed the event view
/// swallows all three and the surface reads as "typing does nothing".
/// `CanvasCompositionTests` pins both — and deliberately does NOT count the
/// modifier names written out in this comment, which is why they are described
/// here rather than spelled.
///
/// ---
///
/// FIVE SOURCE-LAYOUT CONTRACTS. `CanvasCompositionTests` and Task 14's
/// accessibility test read this file as TEXT, slicing it on declaration names.
/// Tasks 13, 14 and 15 all edit this file after Task 10, and a reformat can
/// break one of these with a failure message pointing somewhere else entirely —
/// so they are written down here rather than left to be rediscovered:
///
///  1. `private var mountedEditorNodeID` must be declared AFTER `var body: some
///     View`. The body slicer runs from one to the other, and an inverted range
///     CRASHES the test rather than failing it.
///  2. `private func load()` must be the very next declaration after
///     `private var mountedEditor: some View` — the builder slicer runs between
///     those two, and anything inserted between them lands inside the slice.
///  3. `mountedEditorNodeID` and `visibleEditorNodeID` must be separated by a
///     blank line, and neither may contain an internal blank line. The
///     declaration slicer drops comment lines and then takes everything up to
///     the next blank line: a blank line inside one truncates it, and a missing
///     blank line between them merges the two into a single declaration.
///  4. Task 14's test scans this file RAW — comments included — for its
///     accessibility element-list builder, and requires the first occurrence to
///     be the `.onChange` that rebuilds it. So that symbol must not be named in
///     any comment above it. It is deliberately not spelled here either.
///  5. `CanvasCompositionTests.test_theCanvasIsNotHiddenFromAccessibility`
///     ALSO scans this file raw, for the two modifiers that would take the
///     drawn layer out of the accessibility tree — the "hide it" one and the
///     "ignore its children" one. Naming either **in a comment** fails that
///     test exactly as calling it would. It cost Task 14 a red suite; Task 14
///     documented it beside the modifiers and left the promotion to Task 15,
///     the last task to edit this file. Both are therefore described in prose
///     and spelled nowhere in this file, here or below.
struct CanvasView: View {
    let projectRoot: URL
    /// Deferred on purpose: `ProjectStore.paletteSwatchHexes()` reads every
    /// palette card off disk, and evaluating that inside `ProjectWindow.body`
    /// would do file I/O per render. The canvas pulls it once, on appear.
    let paletteSwatchHexes: () -> [String]

    @State private var camera = CanvasCamera()
    @State private var scene = CanvasScene()
    @State private var scraps: [CanvasNodeID: String] = [:]
    @State private var layouts: [CanvasNodeID: ScrapLayout] = [:]
    @State private var editingNodeID: CanvasNodeID?
    @State private var caretIndex: Int?
    @State private var wash: [Color] = []
    @State private var store: CanvasStore?
    /// §7A.5: the focused card animates to level and settles back on blur.
    @State private var straighten = CanvasFocusStraighten()
    /// The live drag or resize, and §7.3's coast after a flick. Both are plain
    /// value types with no clock of their own — the `TimelineView` below is the
    /// only clock on this surface.
    @State private var interaction = CanvasInteraction()
    @State private var momentum = CanvasMomentum()

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
    /// — and it registers only between `beginUndoGrouping` and `endUndoGrouping`.
    @State private var undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    @State private var undo: CanvasUndo?

    /// `layouts` holds ScrapLayout REFERENCES. Typing mutates the object in
    /// place, so `@State` observes no change and the `Canvas` never redraws.
    /// Every path that mutates a layout or the scene in place bumps this, and
    /// `body` READS it — a `@State` read only registers a dependency during body
    /// evaluation, so reading it inside the draw closure would do nothing.
    ///
    /// This is the REDRAW counter and it ticks once per animation frame. Nothing
    /// scene-proportional may key off it — see `sceneRevision`.
    @State private var revision = 0

    /// The STRUCTURAL counter: bumped only when the shape or content of the
    /// scene changes — load, create, delete, undo, the end of a drag or resize,
    /// momentum coming to rest, and leaving a scrap. Task 14's accessibility
    /// tree is rebuilt from this and never from `revision`, which every frame of
    /// every straighten, coast and drag increments.
    @State private var sceneRevision = 0

    /// The synthetic accessibility tree — spec §7A.6's "AX layer mirroring the
    /// scene graph", because drawn content has none of its own.
    ///
    /// Rebuilt from the `.onChange` below and NOT computed in `body`. Building it
    /// sorts the scene into reading order and copies every scrap's string, and
    /// `body` runs on every scroll event, every drag frame and every momentum
    /// tick — so computing it there is scene-proportional work inside the loop
    /// that has to stay proportional to the viewport. Keying it on `revision`
    /// would be the same defect with an extra step: that counter is bumped by
    /// every one of those frames. The elements carry CONTENT frames, so a pan or
    /// a zoom does not invalidate them at all.
    @State private var axElements: [CanvasAXElement] = []

    /// When the writer last folded a keystroke into the model. A gap wider than
    /// `ScrapUndoBeat.idleSeconds` closes the open "Edit Scrap" gesture, so a
    /// long visit to a scrap is several ⌘Z steps rather than one. Cleared
    /// whenever focus moves, so the first keystroke of a visit never closes the
    /// step the PREVIOUS visit left behind.
    ///
    /// Moved only by a real keystroke — see `syncActiveEdit(fromKeystroke:)`.
    @State private var lastKeystrokeAt: Date?

    private let scrapFont = NSFont(name: "Iowan Old Style", size: 13)
        ?? .systemFont(ofSize: 13)

    /// The most any single tick of the timeline may advance an animation.
    ///
    /// **Without this the ~120 ms straighten completes on its FIRST frame, every
    /// time.** `TimelineView(.animation(paused:))` stops issuing dates while it
    /// is paused and holds the last one, so the first `context.date` after
    /// `straighten.focus(_:)` unpauses it is separated from its predecessor by
    /// the whole idle gap — a quarter of a second in a test, thirty seconds on a
    /// canvas someone was reading. `step(elapsed:)` guards a non-positive delta
    /// but takes a large one at face value, so one tick of 0.25 s advances a
    /// 0.12 s animation by 208% and the card snaps level under the writer's
    /// cursor. That is spec §7A.2's text-jump arriving through §7A.5's own
    /// mechanism, and it is invisible to every test that steps the straighten by
    /// hand — `CanvasViewMountingTests.test_theMountedEditorIsInvisibleUntilTheCardHasStraightened`
    /// runs the real clock and is what caught it.
    ///
    /// 1/30 s is longer than a frame at 60 Hz or 120 Hz, so it never shortens a
    /// healthy one; it is a quarter of `CanvasFocusStraighten.secondsToLevel`, so
    /// a resume advances the animation rather than finishing it. Task 13 steps
    /// its momentum from this same timeline and wants the same ceiling: a coast
    /// integrated against a 30-second delta lands the canvas somewhere in the
    /// next county.
    private static let maximumFrameStep: TimeInterval = 1.0 / 30

    var body: some View {
        // Read here, not in the closure — see `revision`.
        let drawRevision = revision

        // No GeometryReader: `Canvas`'s own `size` is the viewport the renderer
        // culls against, and `.position` below resolves in this ZStack's space.
        ZStack {
            CanvasGround(camera: camera, wash: wash)
                // Belt and braces: `CanvasGround` opts out internally too. The
                // ground is the one layer whose whole job is to be behind
                // everything, so it says so at both ends.
                .allowsHitTesting(false)

            // ONE clock, two interpolated models: §7A.5's straightening and
            // §7.3's coast. Paused only when BOTH are settled, so an idle canvas
            // costs nothing. A second `TimelineView` over the same `Canvas`
            // would be two redraw sources fighting for one frame — do not add
            // one. `withAnimation` cannot do either job: it interpolates
            // `Animatable` values through the SwiftUI view graph, and a plain
            // model value read inside a `Canvas` draw closure is not in that
            // graph (see `CanvasMomentum`).
            TimelineView(.animation(paused: straighten.isSettled && momentum.isAtRest)) { context in
                Canvas { cx, size in
                    _ = drawRevision
                    CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten, into: &cx)
                }
                .allowsHitTesting(false)
                // Spec §7A.6: drawn content has no AX tree, so this view owns
                // one. Without these three lines a VoiceOver user meets a blank
                // rectangle where the writer's whole plan is.
                //
                // Hit testing is off on this layer and accessibility is not: the
                // two are different trees, and the layer only leaves the second
                // one if something hides it or tells it to ignore its children.
                // `CanvasCompositionTests` scans this file RAW for both of those
                // modifiers, so they are described here rather than spelled —
                // naming either in a comment fails that test as surely as calling
                // it would. Either would throw the mounted `NSTextView` away
                // along with the drawn cards.
                //
                // The children are EXTRACTED and `.equatable()` rather than an
                // inline `ForEach`: they read the camera, so inline they would be
                // rebuilt on every body pass — N synthetic views per frame for
                // the whole of every straighten, coast and drag, which is the
                // very thing the cached element list above exists to avoid. As an
                // `Equatable` view SwiftUI skips them unless the elements or the
                // camera actually moved.
                .accessibilityLabel(CanvasAccessibility.canvasLabel)
                .accessibilityValue(CanvasAccessibility.summary(scene: scene))
                .accessibilityChildren {
                    CanvasAXChildren(elements: axElements, camera: camera)
                        .equatable()
                }
                .onChange(of: context.date) { previous, now in
                    // Clamped: the first date after this timeline unpauses is a
                    // whole idle gap, not a frame. See `maximumFrameStep`.
                    straighten.step(elapsed: min(now.timeIntervalSince(previous),
                                                 Self.maximumFrameStep))
                    // Momentum needs no elapsed and no clamp: it decays PER
                    // FRAME, so one late tick advances the coast by one frame
                    // rather than by the idle gap. Guarded on `isAtRest` so a
                    // tick that exists only to straighten a card does not reset
                    // the save debounce.
                    if !momentum.isAtRest, !momentum.step(&scene) {
                        store?.scheduleSave(scene: scene, scraps: scraps)
                        // *** The card has come to rest somewhere new, so the
                        // accessibility tree's frames are stale. KEEP THIS. ***
                        // Bumped here and not once per coasting frame:
                        // `sceneRevision` is the STRUCTURAL counter and a coast
                        // is one structural change, at its end.
                        sceneRevision += 1
                    }
                    revision += 1
                }
            }

            CanvasEventView(
                camera: $camera,
                onClick: { viewPoint, clickCount in
                    handleClick(at: camera.contentPoint(fromView: viewPoint),
                                clickCount: clickCount)
                },
                onDrag: { viewPoint, phase in
                    handleDrag(at: camera.contentPoint(fromView: viewPoint), phase: phase)
                },
                // The bare manager, vended down the responder chain so ⌘Z with
                // nothing focused runs the canvas stack rather than the window's.
                //
                // Bare, and not the recorder the editor gets: this path is only
                // reachable with no scrap focused, and every route out of a scrap
                // runs `commitActiveEdit`, so there is never an open gesture here
                // for `CanvasUndo.undo()` to close. A drag's gesture closes at
                // `.ended`, before any ⌘Z can arrive.
                undoManager: undoManager)

            mountedEditor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
        // The STRUCTURAL counter, never `revision`.
        //
        // `initial: true` is belt and braces rather than the load path: `load()`
        // ends in `rebuildLayouts()`, which bumps this counter, so the loaded
        // canvas reaches the tree either way. It is here so that a scene which
        // somehow arrives without a bump still has an accessible canvas rather
        // than a silent one — the failure this whole layer exists to prevent.
        .onChange(of: sceneRevision, initial: true) { _, _ in
            axElements = CanvasAccessibility.elements(scene: scene, scraps: scraps)
        }
        .onDisappear {
            // Fold the live editor's text in BEFORE the write, or a persona
            // switch mid-sentence loses the sentence.
            syncActiveEdit()
            store?.flush()
            // And then let the store go. `beforeFlush` holds a copy of this
            // view, which holds this `@State` box, which holds the store — a
            // cycle, so without this line the store never deinits, its
            // termination observer outlives the window it belonged to, and app
            // quit writes this closed window's stale scene back over whatever
            // replaced it. Cheaper than teaching the store a weak owner.
            store?.beforeFlush = nil
            // The same cycle one layer down, and one edge longer: the recorder's
            // two closures capture this view, which holds the `@State` box that
            // holds the recorder — and the manager retains the recorder once per
            // step on its stack. Without this a closed canvas keeps its scene,
            // every scrap's text and every snapshot of both alive for the life of
            // the app. No gesture is closed here: there is no writer left to
            // press ⌘Z at teardown, and `release()` drops the stack whole.
            undo?.release()
        }
    }

    /// The node whose real editor EXISTS right now — in the hierarchy, first
    /// responder, taking keystrokes. That is from the instant the writer clicks,
    /// with no gate on the straighten.
    ///
    /// **This is deliberately not `visibleEditorNodeID`, and the two must not be
    /// merged back together.** Deferring the *mount* to `isLevel` was a real
    /// defect: for ~120 ms there was no editor to be first responder, so
    /// double-click empty canvas and type immediately and the first character or
    /// two reached nothing at all. §7A.5 says there is "a beat between click and
    /// caret" — a late caret is the accepted cost; discarded keystrokes are not.
    private var mountedEditorNodeID: CanvasNodeID? { editingNodeID }

    /// The node whose editor is the VISIBLE text right now — `nil` for the
    /// ~120 ms the clicked card spends straightening, and `nil` again the moment
    /// focus leaves.
    ///
    /// **The renderer's text suppression and the editor's own visibility both
    /// read THIS**, one property, once per body pass. So the drawn text cannot
    /// be blanked while nothing is drawing it in its place, and the editor
    /// cannot appear over a card that is still tilted: the two flip on the same
    /// frame and the swap reveals nothing that was not already on screen. Spec
    /// §7A.5 requirement 1 is an ordering — caret, then animate, then hand the
    /// text over — and this property is the "then". `straighten.focus(_:)` has
    /// already unpaused the clock, so it arrives on its own about a tenth of a
    /// second later; there is no timer and no completion callback.
    ///
    /// Through that window the card keeps drawing its own text, and it is LIVE
    /// text: `layouts[id]` wraps the same `NSTextStorage` the invisible editor is
    /// mutating, and `syncActiveEdit` bumps `revision` on every keystroke, so the
    /// words appear on the rotating card as they are typed.
    ///
    /// Making the editor visible from the click was the first draft's defect:
    /// axis-aligned glyphs at the unrotated text origin over chrome that was
    /// still up to 0.6° off level, so they snapped straight on the click and the
    /// card caught up behind them — spec §7A.2's failure by §7A.5's own route.
    private var visibleEditorNodeID: CanvasNodeID? {
        guard let id = editingNodeID, straighten.isLevel(id) else { return nil }
        return id
    }

    /// Frontmost, from the click. Invisible — and transparent to the pointer —
    /// until the card it sits on is level.
    ///
    /// The container sits at the card's UNROTATED text origin and is never
    /// rotated. `ScrapEditorGeometry.viewPoint` assumes exactly that and has no
    /// rotation term; place this anywhere else and that function is silently
    /// wrong.
    @ViewBuilder
    private var mountedEditor: some View {
        if let id = mountedEditorNodeID,
           let node = scene.node(id),
           case .scrap = node.kind,
           let layout = layouts[id],
           let frame = node.frame {
            let textSize = CanvasCardMetrics.textSize(inCard: frame)
            let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
            let viewOrigin = camera.viewPoint(fromContent: textOrigin)
            ScrapEditorHost(layout: layout,
                            unscaledSize: textSize,
                            zoom: camera.zoom,
                            caretIndex: caretIndex,
                            // The same property the renderer is handed above, so
                            // the editor appearing and the card ceasing to draw
                            // its text are one event, not two.
                            isEditorVisible: visibleEditorNodeID == id,
                            // The recorder, which drives the SAME stack the event
                            // view vends — so ⌘Z while editing and ⌘Z with
                            // nothing focused are one history in the order things
                            // happened. It is the recorder rather than the
                            // manager because a ⌘Z from in here has an open
                            // gesture to close first.
                            canvasUndo: undo,
                            onScroll: { dx, dy, precise in
                                let factor: CGFloat = precise ? 1 : 8
                                camera.panBy(CGSize(width: dx * factor, height: dy * factor))
                            },
                            onMagnify: { magnification, editorPoint in
                                // The container hands back a point in the
                                // EDITOR's own unzoomed space. Anchoring the
                                // zoom on it directly would zoom about a point
                                // the writer never touched.
                                let anchor = ScrapEditorGeometry.viewPoint(
                                    fromEditorPoint: editorPoint,
                                    textOrigin: textOrigin,
                                    camera: camera)
                                camera.zoom(to: camera.zoom * (1 + magnification),
                                            anchoringViewPoint: anchor)
                            },
                            // The ONE caller that is a real keystroke, and so
                            // the only one allowed to move an undo boundary.
                            onTextChanged: { syncActiveEdit(fromKeystroke: true) })
                .frame(width: textSize.width * camera.zoom,
                       height: textSize.height * camera.zoom)
                .position(x: viewOrigin.x + textSize.width * camera.zoom / 2,
                          y: viewOrigin.y + textSize.height * camera.zoom / 2)
        }
    }

    // MARK: - Loading and measuring

    private func load() {
        let s = CanvasStore(projectRoot: projectRoot)
        // The store's own quit hook writes whatever was last queued; this makes
        // sure what was last queued includes the sentence the writer is halfway
        // through. `.onDisappear` does not fire on ⌘Q.
        s.beforeFlush = { syncActiveEdit() }
        store = s
        let loaded = s.load()
        scene = loaded.scene
        scraps = loaded.scraps
        wash = CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())
        rebuildLayouts()

        // `CanvasUndo` owns no state — it reads and writes this view's through
        // two closures, which is what lets 1C-b Task 4 move the same class onto
        // `CanvasModel` by rebinding them.
        let recorder = CanvasUndo(undoManager: undoManager)
        recorder.readSnapshot = { (scene: scene, scraps: scraps) }
        recorder.applySnapshot = { snapshot in
            // FIRST, before the scene is replaced. A coast steps `scene` directly
            // from the timeline, outside any gesture and after the drag's own
            // snapshot was taken at `.began`. Leave it running and a ⌘Z inside the
            // ~1 s after a flick puts the card back at the pick-up point and the
            // momentum then skates it away from there — so it comes to rest
            // somewhere the writer never put it, and that is the position the
            // save at the bottom of this closure writes.
            momentum.stop()
            scene = snapshot.scene
            scraps = snapshot.scraps
            // The undo may have taken away the scrap the writer is standing in —
            // double-click bare canvas, type, ⌘Z, ⌘Z is three keystrokes to it.
            // `mountedEditor` guards on `scene.node(id)`, so the editor goes;
            // without this line `editingNodeID`, `caretIndex` and `straighten`
            // would go on naming a node that no longer exists. Every mouse-down
            // repairs it in passing — `CanvasEventNSView.applyMouseDown` runs
            // `onClick` strictly before `onDrag(.began)`, so `handleClick` clears
            // the stale id before any drag guard reads it — but the state is
            // wrong in the meantime, and ⇧⌘Z brings the card back and drops the
            // writer into an editor they never clicked into. This is the state
            // `.unenterableNode` in `handleClick` already refuses to leave
            // standing, arriving from the undo path instead of the click path.
            if let id = editingNodeID, scene.node(id) == nil { leaveTheOpenScrap() }
            // Heights are DERIVED, so a restored scene is re-measured rather
            // than trusted — and a scrap whose text the undo changed gets a new
            // `ScrapLayout`, which is what makes `ScrapEditorHost` rebind the
            // mounted editor instead of leaving it showing the discarded words.
            // Replacing the layout under a MOUNTED editor is safe; the
            // measurement is on `rebuildLayouts` below.
            rebuildLayouts()
            store?.scheduleSave(scene: scene, scraps: scraps)
        }
        undo = recorder
    }

    /// Build a layout per scrap and fill in the derived heights the model needs
    /// for hit testing and culling.
    ///
    /// Called from `load`, and again from every path that can leave a node
    /// unmeasured: creating a scrap, finishing a resize, committing an edit. A
    /// node with no `cachedHeight` has no `frame`, so it is invisible to both
    /// hit testing and culling — it is on the canvas and cannot be clicked.
    ///
    /// **Replacing a layout whose editor is MOUNTED is safe**, and this says so
    /// with a measurement because it used to say the opposite with a warning.
    ///
    /// Task 15's undo is the caller that does it: `applySnapshot` restores an
    /// older string into `scraps` while the writer is still in the scrap, so the
    /// reuse branch below (keyed on `existing.text == text`) misses, `layouts[id]`
    /// is overwritten, and the `ScrapLayout` the mounted `NSTextView` was built
    /// from is released **synchronously** — a whole SwiftUI update pass before
    /// `ScrapEditorHost.updateNSView` rebinds. The old warning called that window
    /// a dangling stack, on the theory that the view retains only its
    /// `NSTextContainer`, whose `textLayoutManager` back-link is weak.
    ///
    /// That theory is wrong. Measured 2026-07-26 on macOS 26.5: with the
    /// `ScrapLayout` released and nothing but the text view left alive, the
    /// `NSTextLayoutManager`, the `NSTextContentStorage` and the `NSTextStorage`
    /// are all still alive, `textContainer.textLayoutManager` is non-nil,
    /// `string` reads, and the view lays out and draws. An `NSTextView` built
    /// through `NSTextView(frame:textContainer:)` owns its TextKit 2 stack
    /// itself. `ScrapLayoutTests.test_theMountedEditorOutlivesTheScrapLayoutThatBuiltIt`
    /// is that measurement in isolation, and
    /// `CanvasViewMountingTests.test_anUndoInsideAScrapLeavesItsLiveEditorUsableBeforeTheRebind`
    /// is the same window reached through a real ⌘Z on the real surface.
    ///
    /// What that buys is a window that is safe, not one that is correct: through
    /// it the mounted view still shows the text the undo discarded. Showing the
    /// restored words is the REBIND's job — `updateNSView` sees a new layout
    /// identity and remounts — which is why the replacement has to be a new
    /// `ScrapLayout` rather than the old one mutated in place.
    ///
    /// `unorderedNodes`, not `nodes`: this measures every scrap and does not
    /// care which is in front, and `CanvasScene.nodes` sorts the whole scene on
    /// every access.
    private func rebuildLayouts() {
        for node in scene.unorderedNodes {
            guard case .scrap = node.kind else { continue }
            let existing = layouts[node.id]
            let text = scraps[node.id] ?? ""
            let layout: ScrapLayout
            if let existing, existing.text == text {
                existing.setWidth(CanvasCardMetrics.textWidth(forCardWidth: node.width))
                layout = existing
            } else {
                layout = ScrapLayout(
                    text: text,
                    width: CanvasCardMetrics.textWidth(forCardWidth: node.width),
                    font: scrapFont,
                    textColor: CanvasRenderer.cardInk)
                layouts[node.id] = layout
            }
            scene.setCachedHeight(
                CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight),
                for: node.id)
        }
        // Layouts for nodes that no longer exist would keep their text alive.
        layouts = layouts.filter { scene.node($0.key) != nil }
        revision += 1
        // Every caller of this — load, create, resize-end, undo — has changed the
        // shape of the scene, so the accessibility tree is stale.
        sceneRevision += 1
    }

    // MARK: - The writer's words

    /// Fold the live editor's text back into the model and re-measure the card.
    ///
    /// **Called on EVERY keystroke** (`ScrapEditorHost.onTextChanged`), from
    /// `.onDisappear`, and from `CanvasStore.beforeFlush`. Typing mutates the
    /// `NSTextStorage` inside `ScrapLayout` in place; until this runs, `scraps`
    /// still holds the text as it was before the writer typed, the queued save
    /// payload is stale, and the drawn card never grows past the height it had
    /// when it was last measured. Quit at that moment and the scrap comes back
    /// empty — the words are safe is the one promise this surface cannot break.
    ///
    /// It folds the string and nothing else. `onTextChanged` fires synchronously
    /// inside `textDidChange`, so rebuilding layouts from here would replace an
    /// `NSTextStorage` from inside its own text view's change notification.
    ///
    /// Pushes no undo step of its OWN, deliberately — one per keystroke is the
    /// other failure. What it does instead is move the INNER undo boundaries
    /// inside the open "Edit Scrap" gesture, and **only when the change came from
    /// a real keystroke**:
    ///
    /// - **The idle beat is asked BEFORE the fold**, so the step that closes ends
    ///   where the writer actually stopped rather than one character into what
    ///   they typed next.
    /// - **The sentence rule is asked AFTER the fold**, so the full stop belongs
    ///   to the step it closes rather than opening the following one.
    ///
    /// Swapping either would be invisible in the code and obvious to a writer:
    /// ⌘Z after a pause would take back one extra character, and ⌘Z after a
    /// sentence would leave the full stop stranded at the head of the next step.
    ///
    /// `fromKeystroke` is `false` by default because the other two callers —
    /// `.onDisappear` and `CanvasStore.beforeFlush` — run at teardown and at app
    /// quit. A writer who paused for two seconds and then quit would otherwise
    /// trip the idle break at `beforeFlush`, closing a step and REOPENING a
    /// gesture on a view that is going away: a half-open bracket, arriving from
    /// the save path instead of the focus path. Neither of them may move a
    /// boundary, and neither has to say so.
    private func syncActiveEdit(fromKeystroke: Bool = false) {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        // Read once: `ScrapLayout.text` bridges out of an `NSTextStorage` on
        // every access, and this runs on every keystroke.
        let updated = layout.text
        guard scraps[id] != updated else { return }
        let previous = scraps[id] ?? ""
        let now = Date()

        // BEFORE the fold — see the doc above.
        if fromKeystroke, ScrapUndoBeat.hasGoneIdle(since: lastKeystrokeAt, now: now) {
            undo?.breakGesture()
        }

        scraps[id] = updated
        scene.setCachedHeight(
            CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        revision += 1
        store?.scheduleSave(scene: scene, scraps: scraps)

        // AFTER the fold — see the doc above.
        if fromKeystroke,
           ScrapUndoBeat.completesASentence(before: previous, after: updated) {
            undo?.breakGesture()
        }
        if fromKeystroke { lastKeystrokeAt = now }
    }

    /// The outer undo boundary: focus is leaving the scrap.
    ///
    /// `syncActiveEdit` has folded the text in on every keystroke and broken the
    /// gesture at each sentence and each pause; this closes whatever is still
    /// open. `endGesture` registers nothing when the state has not moved, so
    /// clicking in and straight back out leaves no step behind — and it is a
    /// no-op outside a gesture, which is what makes it safe at the head of
    /// `handleClick`, where most clicks have nothing focused at all.
    ///
    /// Plus the accessibility tree, whose synthetic element for this scrap has
    /// been stale for the whole visit — deliberately, because the real
    /// `NSTextView` was the accessible thing while the writer was in it.
    private func commitActiveEdit() {
        syncActiveEdit()
        undo?.endGesture()
        lastKeystrokeAt = nil
        sceneRevision += 1
    }

    // MARK: - Clicks

    /// What a double click landed on. Three cases, resolved from ONE hit test.
    ///
    /// `CanvasScene.topmostNode(at:)` filters the whole scene, so asking twice in
    /// one click is an avoidable `O(scene)` pass; and asking it in a `guard` with
    /// the other conditions is how the fall-through below went missing in the
    /// first draft. Making the third case a NAMED case is what stops it being
    /// forgotten again.
    private enum ClickTarget {
        /// Bare canvas — make a scrap here.
        case emptyCanvas
        /// A scrap this view has measured and laid out — enter it.
        case scrap(node: CanvasNode, layout: ScrapLayout, frame: CGRect)
        /// A node that cannot be entered: an item node (1C-d gives those their
        /// own behaviour), or a scrap with no layout or no `cachedHeight` yet.
        /// Reachable TODAY — Task 5's codec round-trips item nodes deliberately,
        /// so a sidecar written by a later build opens with them present.
        case unenterableNode
    }

    private func clickTarget(at contentPoint: CGPoint) -> ClickTarget {
        guard let node = scene.topmostNode(at: contentPoint) else { return .emptyCanvas }
        guard case .scrap = node.kind,
              let layout = layouts[node.id],
              let frame = node.frame else { return .unenterableNode }
        return .scrap(node: node, layout: layout, frame: frame)
    }

    /// Single click: leave whatever was being edited. Double click: enter the
    /// scrap under the pointer, or make one on bare canvas.
    ///
    /// The single/double split is the standard canvas idiom, and it is what lets
    /// a single click start a DRAG while the editor is unmounted — with the
    /// editor frontmost, a focused scrap owns its own mouse.
    ///
    /// One accepted gap, from the same fact: a click that lands here while an
    /// editor is already mounted on the SAME scrap updates `caretIndex` but does
    /// not move the caret, because `ScrapEditorHost` re-claims focus only on a
    /// rebind — by design, or every camera nudge would slam the caret back. It
    /// can only happen inside the ~120 ms window where the editor is mounted but
    /// still invisible and therefore not taking its own clicks; once the card is
    /// level AppKit places the caret itself, which is the whole point of putting
    /// the editor in front. A second double-click inside a tenth of a second
    /// keeps the first one's caret.
    private func handleClick(at contentPoint: CGPoint, clickCount: Int) {
        commitActiveEdit()

        guard clickCount >= 2 else {
            leaveTheOpenScrap()
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        switch clickTarget(at: contentPoint) {
        case .scrap(let node, let layout, let frame):
            // §7A.5 requirement 1: resolve the caret in the card's LOCAL,
            // UNROTATED space at CLICK TIME — before the card straightens.
            // Straightening first moves the click point out from under the
            // cursor, and the caret lands somewhere the writer did not aim.
            let angle = CanvasRenderer.drawnAngle(for: node.id, straighten: straighten)
            let local = CanvasRenderer.localPoint(contentPoint, inCard: frame, angle: angle)
            let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
            caretIndex = layout.characterIndex(
                at: CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y))

            editingNodeID = node.id
            lastKeystrokeAt = nil
            // The editor mounts on this line's body pass and takes keystrokes at
            // once; what it does not do yet is SHOW. `visibleEditorNodeID`
            // withholds that until `straighten.isLevel(_:)`, about a tenth of a
            // second from here, and until then the drawn text stays visible,
            // keeps rotating, and grows as the writer types into the editor
            // nobody can see. Spec §7A.5 calls that beat responsiveness rather
            // than lag.
            straighten.focus(node.id)
            // The OUTER undo bracket for this visit. `commitActiveEdit` at the
            // head of this method has already closed the previous one, so a
            // click straight from one scrap into another never nests.
            undo?.beginGesture("Edit Scrap")

        case .emptyCanvas:
            // Creating the card is its own step, closed before the visit opens:
            // one ⌘Z takes back what the writer typed, a second takes back the
            // card. Explicit begin/end rather than `mutate` — the new id has to
            // escape the gesture, and a closure assigning into a `var` declared
            // outside it would leave that var at its sentinel whenever `undo` is
            // nil, which is every moment before `load()` has run.
            undo?.beginGesture("New Scrap")
            let id = CanvasInteraction.createScrap(at: contentPoint, in: &scene)
            scraps[id] = ""
            // A new scrap has no cachedHeight, so it has no frame, so it is
            // invisible to hit testing and culling until it is measured.
            // `rebuildLayouts()` also bumps `sceneRevision`.
            rebuildLayouts()
            // Closed AFTER the measure, so the next gesture's baseline holds a
            // card with a height. Close it before and "Edit Scrap" opens on a
            // scene whose new node has no `cachedHeight`, so undoing the typing
            // would restore a card with no frame — invisible to hit testing, to
            // culling and to the renderer.
            undo?.endGesture()
            editingNodeID = id
            caretIndex = 0
            lastKeystrokeAt = nil
            straighten.focus(id)
            // Whatever the writer now types is a second, separate step.
            undo?.beginGesture("Edit Scrap")

        case .unenterableNode:
            // Nothing to enter, so this behaves like a single click. Falling
            // through instead would leave `editingNodeID` and `straighten`
            // pointing at whatever was open before: the invisible editor stays
            // mounted on the card the writer just clicked AWAY from, and
            // `visibleEditorNodeID` re-reveals it the moment `isLevel` fires.
            leaveTheOpenScrap()
        }
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    /// Focus leaves the canvas's open scrap: unmount the editor and let the card
    /// settle back over ~120 ms. `isSettled` is false the moment focus leaves —
    /// it means "every card is at ITS target", not "every progress value is 1" —
    /// so the clock keeps running until it lands.
    private func leaveTheOpenScrap() {
        editingNodeID = nil
        caretIndex = nil
        straighten.focus(nil)
    }

    // MARK: - Drags

    /// A left-drag that begins over empty canvas (no node under the point) is
    /// intentionally a no-op: `CanvasInteraction.begin` finds nothing to move or
    /// resize and sets its mode to idle, so `.changed`/`.ended` below never
    /// register. Panning is `scrollWheel`/`magnify` (Task 6), not click-and-drag,
    /// and this slice has no marquee-select — that is out of scope here, not
    /// merely unbuilt.
    ///
    /// **A drag that starts inside a FOCUSED scrap belongs to the editor**, which
    /// is in front and takes the mouse itself, so it is a text selection rather
    /// than a card move. Nothing currently lets a writer drag a focused card by
    /// its text; whether that is right is a product question nobody has answered,
    /// and it is flagged rather than decided here.
    private func handleDrag(at contentPoint: CGPoint, phase: CanvasDragPhase) {
        switch phase {
        case .began:
            // ANY press stops a coast — this one included, and one on bare
            // canvas nowhere near the moving card. Above the focus guard
            // deliberately: the press that ENTERS a scrap is the second of a
            // double-click, and if the first one jiggled far enough to launch a
            // flick (the floor is half a point per frame) the card would go on
            // coasting under the mounted editor, dragging the text box with it.
            // The resting place reaches disk without a save of its own here: the
            // `onClick` that preceded this call scheduled one — every branch of
            // `handleClick` does — and `scene` already held every frame the
            // coast had applied.
            momentum.stop()
            // A focused scrap owns its own mouse, so a drag can only start on an
            // unfocused card. `onClick` has already run for this same mouse-down
            // (`CanvasEventNSView.applyMouseDown` pins that order), so this sees
            // the focus state the click just set.
            guard editingNodeID == nil else { return }
            interaction.begin(at: contentPoint, in: scene)
            // Only when `begin` found something. A press on bare canvas leaves
            // the interaction idle, so `.ended` bails on its first guard and
            // would never close a gesture opened here — the next real drag would
            // then nest inside it and two gestures would collapse into one ⌘Z.
            if interaction.isActive {
                undo?.beginGesture(interaction.isResizing ? "Resize Scrap" : "Move Scrap")
            }
        case .changed:
            guard interaction.isActive else { return }
            interaction.update(to: contentPoint, in: &scene)
            revision += 1
        case .ended:
            guard interaction.isActive else { return }
            let wasResizing = interaction.isResizing
            let flick = interaction.end()
            if wasResizing {
                // The rewrap cleared the cached height; re-measure before the
                // card is hit-tested or culled again. `rebuildLayouts()` bumps
                // `sceneRevision` itself.
                //
                // *** UNCONDITIONAL, and NOT behind `hasMoved`. *** The two ask
                // different questions: `hasMoved` is "did the pointer leave the
                // press point", while `CanvasScene.setWidth` clears
                // `cachedHeight` on EVERY `.changed`, including one delivered at
                // exactly the press point with an identical width. Gate this on
                // `hasMoved` and that one sample leaves the card with no height,
                // therefore no `frame`, therefore invisible to `topmostNode(at:)`,
                // to `nodes(intersecting:)` and to the renderer — the card
                // vanishes, and only a reload brings it back.
                //
                // The cost is that a corner press that never moved re-measures
                // and re-queues a save for an unchanged scene, which is cheap
                // and idempotent. It is NOT a licence to push an undo step from
                // here: anything added to this branch that the writer could
                // notice still has to read `interaction.hasMoved`. The gesture
                // closed below is not that — `endGesture` registers nothing at
                // all when the scene did not move.
                rebuildLayouts()
                // AFTER the re-measure, and the ordering is the whole of it.
                // `setWidth` clears `cachedHeight` on EVERY `.changed`, and
                // `CanvasNode` is `Equatable` INCLUDING that field. Close the
                // gesture first and the diff is "card with a height" against
                // "card with none", which differ — so a corner press that never
                // moved registers a step, and the writer's next ⌘Z appears to do
                // nothing while the one after it takes back an edit they had
                // forgotten about. Worse, that step's REDO re-applies the
                // heightless card: no `frame`, so invisible to `topmostNode(at:)`,
                // to `nodes(intersecting:)` and to the renderer at once.
                // `test_aCornerPressThatNeverMovedLeavesNothingToUndo` is the one
                // that fails if these two lines are swapped.
                undo?.endGesture()
            } else {
                // A press that never moved is not a drag. AppKit opens a drag
                // session on EVERY mouse-down, including the first of a
                // double-click, so without this every click into a scrap would
                // write the sidecar and rebuild the accessibility tree for
                // nothing. Safe HERE and not above because a move mutates
                // nothing until the pointer actually moves.
                //
                // The gesture closes ABOVE this bail-out, not below it: the
                // press opened one at `.began` whether or not it turned into a
                // drag, and returning with it still open would leave the next
                // real drag nested inside it — two gestures, one ⌘Z, and the
                // card jumping back further than the writer asked. Nothing
                // moved, so `endGesture` registers no step.
                undo?.endGesture()
                guard interaction.hasMoved else { return }
                // *** KEEP THIS. *** A move is one structural change, recorded at
                // the END of the gesture rather than once per drag frame, and the
                // accessibility tree is rebuilt from this counter alone. If the
                // card is about to coast, the timeline bumps it again when the
                // coast comes to rest.
                sceneRevision += 1
                if let flick { momentum.launch(flick.id, velocity: flick.velocity) }
            }
            store?.scheduleSave(scene: scene, scraps: scraps)
            revision += 1
        }
    }
}
