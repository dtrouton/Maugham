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
/// FOUR SOURCE-LAYOUT CONTRACTS. `CanvasCompositionTests` and Task 14's
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

    /// When the writer last folded a keystroke into the model. A gap wider than
    /// `ScrapUndoBeat.idleSeconds` closes the open "Edit Scrap" gesture, so a
    /// long visit to a scrap is several ⌘Z steps rather than one. Cleared
    /// whenever focus moves. **Written in this task, read in Task 15** — like
    /// `undoManager: nil`, it is a placed seam rather than a forgotten one.
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

            // The clock §7A.5's straightening runs on. Paused the moment nothing
            // is animating, so an idle canvas costs nothing. Task 13 adds
            // momentum to THIS timeline — do not create a second one.
            TimelineView(.animation(paused: straighten.isSettled)) { context in
                Canvas { cx, size in
                    _ = drawRevision
                    CanvasRenderer.draw(scene: scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten, into: &cx)
                }
                .allowsHitTesting(false)
                .onChange(of: context.date) { previous, now in
                    // Clamped: the first date after this timeline unpauses is a
                    // whole idle gap, not a frame. See `maximumFrameStep`.
                    straighten.step(elapsed: min(now.timeIntervalSince(previous),
                                                 Self.maximumFrameStep))
                    revision += 1
                }
            }

            CanvasEventView(
                camera: $camera,
                onClick: { viewPoint, clickCount in
                    handleClick(at: camera.contentPoint(fromView: viewPoint),
                                clickCount: clickCount)
                },
                // Task 13 drives CanvasInteraction from this. Until then a drag
                // is a no-op, deliberately — not a forgotten stub.
                onDrag: { _, _ in },
                // Task 15 supplies the canvas undo manager.
                undoManager: nil)

            mountedEditor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
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
                            undoManager: nil,          // Task 15
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
                            onTextChanged: { syncActiveEdit() })
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
    }

    /// Build a layout per scrap and fill in the derived heights the model needs
    /// for hit testing and culling.
    ///
    /// Called from `load`, and again from every path that can leave a node
    /// unmeasured: creating a scrap, finishing a resize, committing an edit. A
    /// node with no `cachedHeight` has no `frame`, so it is invisible to both
    /// hit testing and culling — it is on the canvas and cannot be clicked.
    ///
    /// **A layout whose editor is mounted must not be replaced here**, and today
    /// nothing replaces one: the reuse branch is keyed on `existing.text ==
    /// text`, and `syncActiveEdit` keeps `scraps[id]` equal to the live layout's
    /// text on every keystroke, so an edit in progress always takes it.
    /// `ScrapEditorContainer.mountedLayout` is `weak`, so a caller that DOES
    /// break that — Task 15's undo restoring an older string into `scraps` while
    /// the writer is still in the scrap is the shape to watch — leaves the
    /// container holding a text view whose `NSTextStorage` has been deallocated
    /// underneath it. `unmount()` first, or clear `editingNodeID` first.
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
    /// other failure. Task 15 gives it a `fromKeystroke:` flag and, behind that
    /// flag, the two inner undo boundaries: a beat of stillness or a finished
    /// sentence closes the open gesture and opens the next (`ScrapUndoBeat`). The
    /// flag exists because the other two callers below run at teardown and at
    /// app quit, where moving an undo boundary would leave a half-open bracket.
    /// In Task 10 the body is the six lines below and there is no flag yet.
    private func syncActiveEdit() {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        guard scraps[id] != layout.text else { return }
        scraps[id] = layout.text
        scene.setCachedHeight(
            CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight), for: id)
        revision += 1
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    /// The outer undo boundary: focus is leaving the scrap. Task 15 closes the
    /// "Edit Scrap" gesture here; until then it is the same work as
    /// `syncActiveEdit`, plus the accessibility tree, whose synthetic element for
    /// this scrap has been stale for the whole visit — deliberately, because the
    /// real `NSTextView` was the accessible thing while the writer was in it.
    private func commitActiveEdit() {
        syncActiveEdit()
        lastKeystrokeAt = nil
        sceneRevision += 1
    }

    // MARK: - Clicks

    /// Single click: leave whatever was being edited. Double click: enter the
    /// scrap under the pointer (Task 13 adds "or make one here").
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

        guard clickCount >= 2,
              let node = scene.topmostNode(at: contentPoint),
              case .scrap = node.kind,
              let layout = layouts[node.id],
              let frame = node.frame else {
            editingNodeID = nil
            caretIndex = nil
            straighten.focus(nil)
            store?.scheduleSave(scene: scene, scraps: scraps)
            return
        }

        // §7A.5 requirement 1: resolve the caret in the card's LOCAL, UNROTATED
        // space at CLICK TIME — before the card straightens. Straightening first
        // moves the click point out from under the cursor, and the caret lands
        // somewhere the writer did not aim.
        let angle = CanvasRenderer.drawnAngle(for: node.id, straighten: straighten)
        let local = CanvasRenderer.localPoint(contentPoint, inCard: frame, angle: angle)
        let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
        caretIndex = layout.characterIndex(
            at: CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y))

        editingNodeID = node.id
        lastKeystrokeAt = nil
        // The editor mounts on this line's body pass and takes keystrokes at
        // once; what it does not do yet is SHOW. `visibleEditorNodeID` withholds
        // that until `straighten.isLevel(_:)`, about a tenth of a second from
        // here, and until then the drawn text stays visible, keeps rotating, and
        // grows as the writer types into the editor nobody can see. Spec §7A.5
        // calls that beat responsiveness rather than lag.
        straighten.focus(node.id)
        store?.scheduleSave(scene: scene, scraps: scraps)
    }
}
