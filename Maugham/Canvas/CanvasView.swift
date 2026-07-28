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
    /// The scene, the scrap text, the selection, the sidecar store and the undo
    /// recorder — owned by `ProjectWindow` because the region inspector in the
    /// right-hand column reads and mutates the same scene this view draws.
    /// Everything below is a property of one *view* of that state and stays here.
    let model: CanvasModel
    let projectRoot: URL
    /// Deferred on purpose: `ProjectStore.paletteSwatchHexes()` reads every
    /// palette card off disk, and evaluating that inside `ProjectWindow.body`
    /// would do file I/O per render. The canvas pulls it once, on appear.
    let paletteSwatchHexes: () -> [String]

    @State private var camera = CanvasCamera()
    @State private var layouts: [CanvasNodeID: ScrapLayout] = [:]
    @State private var editingNodeID: CanvasNodeID?
    @State private var caretIndex: Int?
    @State private var wash: [Color] = []
    /// §7A.5: the focused card animates to level and settles back on blur.
    @State private var straighten = CanvasFocusStraighten()
    /// The live drag or resize, and §7.3's coast after a flick. Both are plain
    /// value types with no clock of their own — the `TimelineView` below is the
    /// only clock on this surface.
    @State private var interaction = CanvasInteraction()
    @State private var momentum = CanvasMomentum()

    /// `layouts` holds ScrapLayout REFERENCES. Typing mutates the object in
    /// place, so `@State` observes no change and the `Canvas` never redraws.
    /// Every path that mutates a layout or the scene in place bumps this, and
    /// `body` READS it — a `@State` read only registers a dependency during body
    /// evaluation, so reading it inside the draw closure would do nothing.
    ///
    /// This is the REDRAW counter and it ticks once per animation frame. Nothing
    /// scene-proportional may key off it — see `sceneRevision`.
    @State private var revision = 0

    /// The STRUCTURAL counter: moved only when the shape or content of the
    /// scene changes — load, create, delete, undo, the end of a drag or resize,
    /// a coast ending (at rest, or truncated by a press), and leaving a scrap.
    /// Task 14's accessibility tree is rebuilt from this and never from
    /// `revision`, which every frame of every straighten, coast and drag
    /// increments.
    ///
    /// **This copy is written in exactly ONE place: the mirror in `body`.**
    /// Nothing on this view bumps it directly any more, and that is the point —
    /// `CanvasModel.sceneRevision` is the one counter, and the right-hand
    /// column's region inspector reads *that* one. A view-side bump would move
    /// the accessibility tree and leave the inspector showing the membership as
    /// of the last edit made from the other column: the drop-to-join at
    /// `handleDrag(.ended)` shipped that way, and the writer met a region that
    /// still said "No cards live in this region yet" over a card the canvas had
    /// already drawn inside it, with the same card still offered under "Cite a
    /// Card" where choosing it did nothing at all.
    ///
    /// It keeps its name and its home here because
    /// `CanvasAccessibilityTests.test_theTreeIsBuiltOnChangeRatherThanInsideBody`
    /// slices this file as text for `.onChange(of: sceneRevision`.
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
        // The same rule, and the same reason: `interaction` is `@State`, and a
        // `@State` read only registers a dependency during body evaluation. Read
        // inside the draw closure it would register nothing, and the rubber band
        // would appear a frame late or not at all.
        let sweep = interaction.pendingRegionDraw

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
                    CanvasRenderer.draw(scene: model.scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        scraps: model.scraps,
                                        selection: model.selection,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten,
                                        pendingRegionDraw: sweep, into: &cx)
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
                .accessibilityValue(CanvasAccessibility.summary(scene: model.scene))
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
                    if !momentum.isAtRest {
                        // `persist: false`: a coast emits a position per frame
                        // and only the rest branch below queues a save. `step`
                        // calls `stop()` on its last frame, so `isAtRest` cannot
                        // be re-asked afterwards — the return value is the one
                        // reading of "still coasting" there is.
                        var coasting = false
                        model.withScene(persist: false) { coasting = momentum.step(&$0) }
                        if !coasting {
                            model.scheduleSave()
                            // *** The card has come to rest somewhere new, so the
                            // accessibility tree's frames are stale. KEEP THIS. ***
                            // Bumped here and not once per coasting frame: this is
                            // the STRUCTURAL counter and a coast is one structural
                            // change, at its end.
                            model.bumpSceneRevision()
                        }
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
                onDeleteKey: { deleteSelection() },
                // The bare manager, vended down the responder chain so ⌘Z with
                // nothing focused runs the canvas stack rather than the window's.
                //
                // Bare, and not the recorder the editor gets: this path is only
                // reachable with no scrap focused, and every route out of a scrap
                // runs `commitActiveEdit`, so there is never an open gesture here
                // for `CanvasUndo.undo()` to close. A drag's gesture closes at
                // `.ended`, before any ⌘Z can arrive.
                //
                // *** That last sentence is weaker than it reads, and ⌫ is what
                // found out. *** A press opens "Move Scrap" at `.began` and holds
                // it until the writer lets go, and the turn after a double-click
                // has "Edit Scrap" open while this view still holds first
                // responder — so a KEY can arrive here with a gesture open. It is
                // survivable for ⌘Z, which closes the open gesture through the
                // recorder either way; it was not survivable for delete, which
                // registered into a bracket that was not its own. Hence the
                // `isInGesture` guard at the head of `deleteSelection()`. Anything
                // new hung off a key here inherits the same problem and needs the
                // same answer.
                undoManager: model.undoManager)

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
            axElements = CanvasAccessibility.elements(scene: model.scene, scraps: model.scraps)
        }
        // MIRRORED, not replaced. The model's counter is bumped by the inspector
        // from the other column; the view's is what the grep-pinned rebuild above
        // watches, and it must keep both its name and its home here.
        .onChange(of: model.sceneRevision) { _, _ in sceneRevision += 1 }
        .onDisappear {
            // Fold the live editor's text in BEFORE the write, or a persona
            // switch mid-sentence loses the sentence.
            syncActiveEdit()
            // Flush, drop `beforeFlush` and release the recorder — the three
            // edges of the cycle, all one layer out now. `beforeFlush` holds a
            // copy of this view, which holds the model, which holds the store, so
            // without the clear the store never deinits, its termination observer
            // outlives the window it belonged to, and app quit writes this closed
            // window's stale scene back over whatever replaced it. The recorder's
            // two closures are the same cycle one layer down, and the manager
            // retains the recorder once per step on its stack. No gesture is
            // closed here: there is no writer left to press ⌘Z at teardown, and
            // `release()` drops the stack whole.
            model.detach()
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
    /// still up to 1.2° off level, so they snapped straight on the click and the
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
           let node = model.scene.node(id),
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
                            canvasUndo: model.undo,
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
        // The model reads both files and wires the recorder's two closures to
        // itself. What is left here is what only a VIEW can do.
        model.attach(projectRoot: projectRoot)
        // The store's own quit hook writes whatever was last queued; this makes
        // sure what was last queued includes the sentence the writer is halfway
        // through. `.onDisappear` does not fire on ⌘Q.
        model.beforeFlush = { syncActiveEdit() }
        model.onSceneReplacedByUndo = {
            // FIRST. A coast steps the scene directly from the timeline, outside
            // any gesture and after the drag's own snapshot was taken at
            // `.began`. Leave it running and a ⌘Z inside the ~1 s after a flick
            // puts the card back at the pick-up point and the momentum then
            // skates it away from there — so it comes to rest somewhere the
            // writer never put it, and that is the position the save at the end
            // of the model's apply writes. This whole closure is called
            // synchronously inside that apply, a whole timeline tick before the
            // coast could take another step.
            momentum.stop()
            // The undo may have taken away the scrap the writer is standing in —
            // double-click bare canvas, type, ⌘Z, ⌘Z is three keystrokes to it.
            // `mountedEditor` guards on `model.scene.node(id)`, so the editor
            // goes; without this line `editingNodeID`, `caretIndex` and
            // `straighten` would go on naming a node that no longer exists. Every
            // mouse-down repairs it in passing —
            // `CanvasEventNSView.applyMouseDown` runs `onClick` strictly before
            // `onDrag(.began)`, so `handleClick` clears the stale id before any
            // drag guard reads it — but the state is wrong in the meantime, and
            // ⇧⌘Z brings the card back and drops the writer into an editor they
            // never clicked into. This is the state `.unenterableNode` in
            // `handleClick` already refuses to leave standing, arriving from the
            // undo path instead of the click path.
            if let id = editingNodeID, model.scene.node(id) == nil { leaveTheOpenScrap() }
            // Heights are DERIVED, so a restored scene is re-measured rather
            // than trusted — and a scrap whose text the undo changed gets a new
            // `ScrapLayout`, which is what makes `ScrapEditorHost` rebind the
            // mounted editor instead of leaving it showing the discarded words.
            // Replacing the layout under a MOUNTED editor is safe; the
            // measurement is on `rebuildLayouts` below.
            //
            // The ONE call site that does not bump the structural counter, and
            // the argument is spelled out rather than defaulted so it cannot be
            // lost. The model bumps its own counter on the line after this
            // closure returns, and the mirror below turns that into the view's
            // bump — so bumping here as well rebuilds the whole accessibility
            // tree TWICE for one ⌘Z, and a writer holding ⌘Z pays a scene sort
            // and a copy of every scrap's string per step, twice.
            rebuildLayouts(bumpsStructuralCounter: false)
        }
        wash = CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())
        rebuildLayouts()
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
    ///
    /// `bumpsStructuralCounter` is `false` for the two callers that have a bump
    /// arriving by another route — the undo apply and `deleteSelection()`, both
    /// of which bump the model's counter on their own line. Every other caller
    /// has changed the shape of the scene with nothing else about to say so.
    /// **Keeping the suppression is what makes one ⌫ or one ⌘Z rebuild the
    /// accessibility tree once rather than twice**, and a writer holding ⌘Z pays
    /// a scene sort and a copy of every scrap's string per step.
    /// The test that catches a mirror which stops delivering is
    /// `CanvasViewMountingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`,
    /// which asks the published accessibility tree whether the deleted card has
    /// left it.
    private func rebuildLayouts(bumpsStructuralCounter: Bool = true) {
        // ONE `withScene` around the whole loop rather than one per node, and
        // `persist: false` because the caller owns the save.
        let scraps = model.scraps
        model.withScene(persist: false) { scene in
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
        }
        // Layouts for nodes that no longer exist would keep their text alive.
        layouts = layouts.filter { model.scene.node($0.key) != nil }
        revision += 1
        // Every caller of this — load, create, resize-end, undo — has changed the
        // shape of the scene, so the accessibility tree is stale. Undo and delete
        // are the two that bump the model's counter themselves; see the
        // parameter's doc above.
        if bumpsStructuralCounter { model.bumpSceneRevision() }
    }

    /// Re-derive ONE scrap's height from its live layout, for the resize path.
    ///
    /// This is `rebuildLayouts()`'s reuse branch for a single node, and it is
    /// deliberately the same two calls in the same order — `setWidth` on the
    /// layout, then `cardHeight(forTextHeight:)` into the scene — so there is
    /// one spelling of card geometry. A second measurement path is precisely how
    /// drawn and edited text end up on different rects (spec §7A.2).
    ///
    /// A resize never changes the text, so the layout is always the reused one;
    /// the guard is for an item node or a scrap whose layout has not been built,
    /// neither of which can be resized.
    ///
    /// Does NOT touch `revision` or `sceneRevision` — the caller owns both, and
    /// the structural counter must not move per frame.
    private func remeasure(_ id: CanvasNodeID) {
        guard let node = model.scene.node(id),
              case .scrap = node.kind,
              let layout = layouts[id] else { return }
        layout.setWidth(CanvasCardMetrics.textWidth(forCardWidth: node.width))
        model.withScene(persist: false) {
            $0.setCachedHeight(
                CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight),
                for: id)
        }
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
        guard model.scraps[id] != updated else { return }
        let previous = model.scraps[id] ?? ""
        let now = Date()

        // BEFORE the fold — see the doc above.
        if fromKeystroke, ScrapUndoBeat.hasGoneIdle(since: lastKeystrokeAt, now: now) {
            model.breakGesture()
        }

        model.withScene(persist: false) {
            $0.setCachedHeight(
                CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        }
        // The fold, and the save that carries both it and the height above.
        model.setScrapText(updated, for: id)
        revision += 1

        // AFTER the fold — see the doc above.
        if fromKeystroke,
           ScrapUndoBeat.completesASentence(before: previous, after: updated) {
            model.breakGesture()
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
    ///
    /// **That bump is guarded on there having BEEN a visit, and the guard is the
    /// point of it.** This runs at the head of `handleClick`, and
    /// `CanvasEventNSView.applyMouseDown` emits `onClick` before `onDrag(.began)`
    /// — so bumping unconditionally rebuilds the whole tree on every mouse-down
    /// the canvas ever sees, including the press that begins a drag, which is the
    /// moment the surface most needs to feel instant. With nothing focused there
    /// is nothing to fold in either: `syncActiveEdit` returns on its first guard
    /// and `endGesture` registers nothing. Every path that changes the scene with
    /// no scrap focused bumps the counter where the change happens — `load` and
    /// the create branch through `rebuildLayouts()`, the two `.ended` branches of
    /// `handleDrag`, and a coast at `.began` or at rest — so nothing depends on
    /// this one to notice a change it did not make.
    private func commitActiveEdit() {
        syncActiveEdit()
        model.endGesture()
        lastKeystrokeAt = nil
        if editingNodeID != nil { model.bumpSceneRevision() }
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

    /// What a single click selects. The SAME precedence the drag uses — a card
    /// beats the region chrome under it — so clicking a thing and dragging it
    /// never disagree about which thing it was.
    ///
    /// A click on a region's interior selects nothing, for the same reason the
    /// interior is not a grab handle: it belongs to the cards in it.
    private func selectionTarget(at contentPoint: CGPoint) -> CanvasSelection? {
        if let node = model.scene.topmostNode(at: contentPoint) { return .node(node.id) }
        switch CanvasInteraction.regionHit(at: contentPoint, in: model.scene) {
        case .chrome(let id), .resizeCorner(let id): return .region(id)
        case nil: return nil
        }
    }

    private func clickTarget(at contentPoint: CGPoint) -> ClickTarget {
        guard let node = model.scene.topmostNode(at: contentPoint) else { return .emptyCanvas }
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
            model.selection = selectionTarget(at: contentPoint)
            // The selection is read INSIDE the draw closure, where a model value
            // is not in SwiftUI's dependency graph — that is what this counter
            // is for. `revision` and never `sceneRevision`: a selection change
            // is not a structural one.
            //
            // **No test can see this line today, and that is measured rather
            // than assumed** (mutation, 2026-07-27: removing it leaves the
            // mounting and composition suites entirely green). `leaveTheOpenScrap()`
            // on the next line writes three pieces of `@State`, which invalidates
            // `body` and gets the redraw for free — so the bump is currently
            // belt and braces. It stays because that cover is incidental: a
            // selection set from anywhere that does NOT also move focus — the
            // inspector in the other column, a keyboard selection — has nothing
            // else to invalidate on, and the symptom is an accent that appears
            // whenever something unrelated next redraws.
            revision += 1
            leaveTheOpenScrap()
            model.scheduleSave()
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
            model.beginGesture("Edit Scrap")

        case .emptyCanvas:
            // Creating the card is its own step, closed before the visit opens:
            // one ⌘Z takes back what the writer typed, a second takes back the
            // card. Explicit begin/end rather than `mutate` — the new id has to
            // escape the gesture, and `mutate`'s closure returns nothing.
            model.beginGesture("New Scrap")
            // The sentinel is never read: `withScene`'s closure is non-escaping
            // and runs unconditionally, so `createScrap` has always assigned by
            // the line below. (In 1C-a the equivalent `var` was genuinely
            // reachable at its sentinel, because the recorder was optional and
            // nil until `load()` had run; the model never is.)
            var id = CanvasNodeID("")
            model.withScene(persist: false) {
                id = CanvasInteraction.createScrap(at: contentPoint, in: &$0)
            }
            model.setScrapText("", for: id)
            // A new scrap has no cachedHeight, so it has no frame, so it is
            // invisible to hit testing and culling until it is measured.
            // `rebuildLayouts()` also bumps `sceneRevision`.
            rebuildLayouts()
            // A card made inside a region belongs to it (Denver, 2026-07-28:
            // creation absorbs, transitions do not). AFTER the measure and not
            // before it, because `joinTarget` reads the card's CENTRE and an
            // unmeasured card has no frame to take one from — asked a line
            // earlier this silently joins nothing, on every scrap the writer
            // ever makes. Inside the "New Scrap" gesture, so one ⌘Z takes back
            // the card and the membership together.
            model.withScene(persist: false) {
                if let home = CanvasInteraction.joinTarget(for: id, in: $0) {
                    CanvasMembership.join(id, home: home, in: &$0)
                }
            }
            // Closed AFTER the measure, so the next gesture's baseline holds a
            // card with a height. Close it before and "Edit Scrap" opens on a
            // scene whose new node has no `cachedHeight`, so undoing the typing
            // would restore a card with no frame — invisible to hit testing, to
            // culling and to the renderer.
            model.endGesture()
            editingNodeID = id
            caretIndex = 0
            lastKeystrokeAt = nil
            straighten.focus(id)
            // Whatever the writer now types is a second, separate step.
            model.beginGesture("Edit Scrap")

        case .unenterableNode:
            // Nothing to enter, so this behaves like a single click. Falling
            // through instead would leave `editingNodeID` and `straighten`
            // pointing at whatever was open before: the invisible editor stays
            // mounted on the card the writer just clicked AWAY from, and
            // `visibleEditorNodeID` re-reveals it the moment `isLevel` fires.
            leaveTheOpenScrap()
        }
        model.scheduleSave()
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

    // MARK: - Delete

    /// ⌫, from `CanvasEventNSView.keyDown`. The one thing the canvas has never
    /// had: 1C-a built `CanvasScene.remove`, its inverse and the "Delete Scrap"
    /// undo step and shipped no caller for any of them, so a stray double-click
    /// left an empty card that ⌘Z took back only until the writer clicked away.
    ///
    /// The region case is the one with a rule behind it: **deleting a region
    /// never deletes cards** — the canvas owns arrangement, not existence (spec
    /// §3.1, generalised). Its membership records die with it, which is all
    /// `CanvasScene.removeRegion` touches.
    ///
    /// Nothing selected is a no-op rather than a guess — and it says so, by
    /// returning **whether anything was actually deleted**. `CanvasEventNSView`
    /// sends the key on to `super` when this is `false`, so a ⌫ over an empty
    /// selection beeps rather than being silently swallowed; the reasoning is on
    /// `keyDown`. A selection that no longer resolves is the same answer for the
    /// same reason: nothing went, so nothing was used.
    ///
    /// **It refuses outright while any gesture is open, and that is a
    /// correctness guard rather than a nicety.** `CanvasUndo.beginGesture` takes
    /// no snapshot when it nests and `endGesture` registers nothing until depth
    /// reaches zero, so a delete opened inside somebody else's bracket cannot be
    /// taken back on its own — at best it collapses into that gesture under the
    /// wrong name, and if the bracket never closes it is not recoverable at all.
    /// Both states are reachable: press and hold on a card (which opens "Move
    /// Scrap") and press ⌫; or press ⌫ in the runloop turn after a double-click,
    /// before the editor has claimed first responder, while "Edit Scrap" is open
    /// — then quit, and `detach()` drops the stack with the card already written
    /// away. `test_backspaceBeforeTheEditorTakesFocusCannotLoseTheCardUnrecoverably`
    /// measured exactly that: the card and its words gone from disk with nothing
    /// that could have brought them back.
    ///
    /// Refusing rather than closing the bracket first is also the honest
    /// semantics: mid-gesture the writer is holding something, so what a delete
    /// means is genuinely ambiguous. Returning `false` sends the key to `super`,
    /// and the beep says so.
    private func deleteSelection() -> Bool {
        guard !model.isInGesture else { return false }
        switch model.selection {
        case .region(let id):
            guard model.scene.region(id) != nil else { return false }
            model.mutate("Delete Region") { $0.removeRegion(id) }
        case .node(let id):
            guard model.scene.node(id) != nil else { return false }
            // The writer cannot be standing in it — a single click both selected
            // it and left the open scrap — but an undo can have moved focus
            // since, and an editor bound to a node that no longer exists is the
            // state `.unenterableNode` already refuses to leave standing.
            if editingNodeID == id { leaveTheOpenScrap() }
            model.beginGesture("Delete Scrap")
            model.withScene(persist: false) { $0.remove(id) }
            model.removeScrapText(id)
            model.endGesture()
            // The SECOND caller that does not bump the structural counter, for
            // the same reason as the first: `model.bumpSceneRevision()` below
            // reaches this view through the mirror in `body`, so bumping here as
            // well rebuilds the whole accessibility tree twice for one ⌫. The
            // deleted card leaving that tree is what
            // `CanvasViewMountingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`
            // asserts, so the delivery of that single bump is pinned rather than
            // assumed.
            //
            // **No test can see this CALL today, and that is measured rather
            // than assumed** (mutation, 2026-07-28: removing it leaves the whole
            // mounting suite green). What it does that nothing observes is drop
            // the deleted node's `ScrapLayout` — the filter at the end of
            // `rebuildLayouts` — which otherwise keeps that scrap's whole
            // `NSTextStorage` alive until some later structural change happens
            // to run one.
            rebuildLayouts(bumpsStructuralCounter: false)
        case .none:
            return false
        }
        model.selection = nil
        // A delete IS a structural change. `CanvasView`'s own doc for
        // `sceneRevision` used to say deletion was absent from the list because
        // 1C-a had no delete path; this is the line that changes that.
        model.bumpSceneRevision()
        model.scheduleSave()
        return true
    }

    // MARK: - Drags

    /// What the Edit menu will call this gesture. The writer reads these — the
    /// item says "Undo Move Region", not "Undo" — so every mode `begin` can
    /// enter needs one, and the compiler is what says so.
    ///
    /// `nil` cannot arrive: the one caller asks only when `isActive`. It has a
    /// name anyway rather than a `!`, because the alternative to a harmless
    /// fallback here is a crash on a surface the writer is dragging.
    private static func gestureName(for kind: CanvasInteraction.Kind?) -> String {
        switch kind {
        case .movingNode: return "Move Scrap"
        case .resizingNode: return "Resize Scrap"
        case .movingRegion: return "Move Region"
        case .resizingRegion: return "Resize Region"
        case .drawingRegion: return "New Region"
        case nil: return "Canvas"
        }
    }

    /// A left-drag that begins over empty canvas now DRAWS A REGION, and one
    /// that begins inside an existing region's interior is still a no-op:
    /// `CanvasInteraction.begin` leaves the mode idle there, so `.changed` and
    /// `.ended` below never register. Nested regions are out of scope (§9).
    /// Panning is `scrollWheel`/`magnify`, not click-and-drag, and there is no
    /// marquee-select — that is out of scope here, not merely unbuilt.
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
            //
            // A press TRUNCATES the coast, so the card comes to rest HERE and
            // never reaches the timeline's rest branch — the only other place
            // that bumps the structural counter for a coast. Leave this out and
            // the accessibility tree keeps the frame the card had when the writer
            // let go of it, for as long as it takes some other structural change
            // to come along. This is the one path `commitActiveEdit`'s formerly
            // unconditional bump covered by accident, which is why it arrived
            // with the guard that removed it.
            // `CanvasViewMountingTests.test_aPressThatStopsACoastRefreshesTheAccessibilityFrame`
            // reads 40 against a card drawn at 64 without it.
            let wasCoasting = !momentum.isAtRest
            momentum.stop()
            if wasCoasting { model.bumpSceneRevision() }
            // A focused scrap owns its own mouse, so a drag can only start on an
            // unfocused card. `onClick` has already run for this same mouse-down
            // (`CanvasEventNSView.applyMouseDown` pins that order), so this sees
            // the focus state the click just set.
            guard editingNodeID == nil else { return }
            interaction.begin(at: contentPoint, in: model.scene)
            // Only when `begin` found something. A press on bare canvas INSIDE a
            // region leaves the interaction idle, so `.ended` bails on its first
            // guard and would never close a gesture opened here — the next real
            // drag would then nest inside it and two gestures would collapse
            // into one ⌘Z.
            if interaction.isActive {
                model.beginGesture(Self.gestureName(for: interaction.kind))
            }
        case .changed:
            guard interaction.isActive else { return }
            // `persist: false`: a drag emits a position per frame and the save
            // it owns is the one at `.ended`.
            model.withScene(persist: false) { interaction.update(to: contentPoint, in: &$0) }
            // A resize rewraps, and `CanvasScene.setWidth` clears the cached
            // height to say so. Re-derive it NOW, not at `.ended`: a node with
            // no `cachedHeight` has no `frame`, and a node with no frame is
            // invisible to `nodes(intersecting:)` — so without this the card
            // blinks out for the whole drag and reappears on release, which is
            // what the writer reported. Re-measuring live is also the point of
            // a resize handle: the text visibly rewraps under the pointer.
            //
            // ONE node, not `rebuildLayouts()`, which measures every scrap on
            // the canvas and runs at drag-frame rate here. And deliberately no
            // `sceneRevision` bump — that is the STRUCTURAL counter and the
            // accessibility tree is gated on it (tripwire 30); bumping it per
            // frame would sort the scene and copy every scrap's string at
            // 60–120 Hz. The end of the resize bumps it once, via
            // `rebuildLayouts()`.
            if interaction.isResizing, let id = interaction.activeNodeID {
                remeasure(id)
            }
            revision += 1
        case .ended:
            guard interaction.isActive else { return }
            let wasResizing = interaction.isResizing
            // Both read BEFORE `end()` clears the mode. The swept rect lives in
            // the interaction and nowhere else, so there is no second copy of it
            // to go stale.
            let drawnRegion = interaction.pendingRegionDraw
            let movedNode = interaction.kind == .movingNode ? interaction.activeNodeID : nil
            let flick = interaction.end()

            // Whether the sweep actually minted a region, read below. A sweep
            // that minted nothing changed no part of the scene, and it must not
            // be mistaken for one that did — see the bump in the `else` branch.
            var mintedRegion = false

            if let drawnRegion {
                // A sweep under `minimumSide` mints nothing — which is what
                // every single click on bare canvas is, since `applyMouseDown`
                // opens a drag session on every mouse-down.
                model.withScene(persist: false) {
                    if let id = CanvasInteraction.createRegion(drawnRegion, in: &$0) {
                        model.selection = .region(id)
                        mintedRegion = true
                    }
                }
            } else if let movedNode, interaction.hasMoved {
                // The drop, INSIDE the move's own gesture — so one ⌘Z takes back
                // the move and the join together. Dropping outside every region
                // removes nothing: removal is always its own act (§4.2), and the
                // tether is what makes the resulting state legible.
                model.withScene(persist: false) {
                    if let target = CanvasInteraction.joinTarget(for: movedNode, in: $0) {
                        CanvasMembership.join(movedNode, home: target, in: &$0)
                    }
                }
            }

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
                model.endGesture()
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
                model.endGesture()
                guard interaction.hasMoved else { return }
                // *** KEEP THIS, AND KEEP ITS GUARD. *** A move is one structural
                // change, recorded at the END of the gesture rather than once per
                // drag frame, and both the accessibility tree and the region
                // inspector's member lists are rebuilt from this counter alone. If
                // the card is about to coast, the timeline bumps it again when the
                // coast comes to rest.
                //
                // The guard is the sweep that minted nothing. `hasMoved` asks
                // whether the pointer left the press point, and on a trackpad a
                // press that drifted one point takes it — so on bare canvas that
                // is MOST clicks, since `applyMouseDown` opens a drag session on
                // every mouse-down and `createRegion` refuses anything under
                // `CanvasRegionMetrics.minimumSide`. Bumping there sorts the whole
                // scene and copies every scrap's string to rebuild a tree for a
                // scene that did not change, and rebuilds the inspector's lists
                // beside it, once per click on nothing.
                //
                // `drawnRegion == nil` is the other half of the same question and
                // not a second rule: outside a sweep, `hasMoved` and a live
                // interaction together mean a card or a region really moved.
                if drawnRegion == nil || mintedRegion { model.bumpSceneRevision() }
                if let flick { momentum.launch(flick.id, velocity: flick.velocity) }
            }
            model.scheduleSave()
            revision += 1
        }
    }
}
