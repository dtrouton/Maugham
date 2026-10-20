import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
/// **`@MainActor` on the whole struct** *(1C-d)*. Every method here is reached
/// from `body` or from a closure `body` created, so this says out loud what was
/// already true — and it is what lets the measurement pass read
/// `CanvasThumbnails`, which is main-actor-isolated because asking it for an
/// image RECORDS a miss. Without it the isolation has to be crossed somewhere,
/// and every place to cross it is worse: a nonisolated closure that captures the
/// cache does not compile, and dropping the cache's own isolation would trade a
/// checked guarantee for a convention.
@MainActor
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

    /// What the window's tree names, resolved against the manifest by
    /// `ProjectWindow` (spec §4). Selecting a chapter lights what is bound to it
    /// and dims the rest of the board.
    ///
    /// **A `let` handed in, and NOT a stored property on `CanvasModel`.** The
    /// model is `@Observable` with the whole scene in one property that every
    /// drag frame writes, which is exactly why the right-hand column reads
    /// nothing off it; a value that has nothing to do with the scene, written
    /// from the other column, would make the inspector a writer into the drag
    /// loop's object. Here it is an input to one *view* of that state, which is
    /// what everything else on this side of the declaration list is.
    ///
    /// Defaulted for `itemIndex`'s reason (~70 test hosts, no window between
    /// them) and censused for `itemIndex`'s reason too: `.wholeProject` is a
    /// real state that compiles and runs, so dropping the argument at the one
    /// production site would leave every canvas test green while the tree's
    /// selection changed nothing the writer can see. The census is in
    /// `PromotionCommandTests`.
    var subject: CanvasSubject = .wholeProject

    /// The way OUT of the dim, asked for from the canvas: Escape (§4.1, *"Escape
    /// is the keyboard spelling of the project row"*).
    ///
    /// **A one-way ask rather than a `Binding`, and the name is the contract.**
    /// §4.1 does not say Escape produces a state like the project row's; it says
    /// it IS that row, so the window answers it by writing the value the row's
    /// own `.tag` carries and everything downstream — the canvas's subject, the
    /// persisted UI state, the tree's own highlight — is then identical by
    /// construction rather than by resemblance. Handing down a
    /// `Binding<BinderSubject?>` instead would give the canvas the window's
    /// selection to read as well, which is exactly what tasks 1–3 kept it away
    /// from: the canvas is handed the ANSWER (`CanvasSubject`), never the
    /// question.
    ///
    /// Defaulted and censused for `itemIndex`'s reasons — `{}` is a real state
    /// that compiles and runs, so dropping the argument at the one production
    /// site would leave every test here green while Escape did nothing. The
    /// census is in `PromotionCommandTests`, and it pins the VALUE the window
    /// writes as well as the wiring.
    var selectTheProjectRow: () -> Void = {}

    /// Item id → title, kind and thumbnail path, for every research item in the
    /// project — built in `ProjectWindow` beside `pieceChoices` and handed down.
    ///
    /// **Eager and handed in, exactly like `pieceChoices`, and for its reason.**
    /// It walks the manifest once per manifest change on that window's body path;
    /// building it here instead would put the walk on this view's own body, which
    /// re-evaluates on every drag, coast and straighten frame — tripwire 4's
    /// per-row manifest walk arriving on the frame path.
    ///
    /// It defaults to `.empty` for the same reason the accessibility tree's own
    /// item parameter does (named in that file rather than here, because a raw
    /// source scan on this one takes the FIRST mention of that builder as the
    /// call site — contract 4 in the header above): the call sites are ~70 test
    /// hosts and one production window, and the production one is censused by
    /// name in
    /// `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`
    /// — a required token, which is what this directory uses where a default
    /// would otherwise let wiring go missing with nothing red.
    var itemIndex: CanvasItemIndex = .empty

    /// Piece id → the title the binder shows, for every row in the project —
    /// built in `ProjectWindow` beside `pieceChoices` and handed down, exactly as
    /// `itemIndex` is and for its reasons (§4.2).
    ///
    /// **What it is for is one sentence**: on a dimmed board a region bound to a
    /// piece other than the subject draws that piece's name, so the writer can
    /// tell the rectangle a sweep will bind from the one where it will silently
    /// do nothing. The canvas is handed the ANSWER and never the question — it
    /// holds no manifest, and `CanvasPieceTitles` carries why at length.
    ///
    /// Defaulted for `itemIndex`'s reason (~70 test hosts, no window between
    /// them) and censused for `itemIndex`'s reason too: `.empty` is a real state
    /// that compiles and runs, so dropping the argument at the one production
    /// site would name every bound region "Missing piece" on the writer's canvas
    /// while the binder shows the chapter in front of them. The census is in
    /// `CanvasBoundPieceTests`.
    var pieceTitles: CanvasPieceTitles = .empty

    /// The canvas's asset well, handed in by `ProjectWindow` — the two halves of
    /// `ProjectStore.ingestCanvasAsset`, which is what gives a photograph dropped
    /// from the Finder or a browser a home the writer cannot tidy away.
    ///
    /// **Defaulted for the reason `itemIndex` is** (~70 test hosts, no store
    /// between them) and censused for the same one: `.unavailable` is a real
    /// state that compiles and runs, so dropping the argument at the one
    /// production call site would refuse every external drop with nothing red.
    /// The census is in `PromotionCommandTests`.
    var assetIngest: CanvasAssetIngest = .unavailable

    /// An inbox row dropped on the canvas (spec §8A.4), handed in by
    /// `ProjectWindow` — the whole act is `InboxStore.sendToCanvas`, which this
    /// view has no store to reach.
    ///
    /// Defaulted and censused for `assetIngest`'s reasons, and its `.unavailable`
    /// throws for the same one: a wiring omission must reach the writer as a
    /// refusal rather than as a drag that springs back saying nothing.
    var captureDrop: CanvasCaptureDrop = .unavailable

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

    /// The canvas's decoded thumbnails, bounded and keyed by path (tripwire 22).
    ///
    /// A reference type in `@State`, exactly like `layouts` and for the same
    /// reason: it is a cache whose identity has to survive a body pass, and
    /// mutating it does not redraw anything by itself.
    ///
    /// **Its byte budget is injectable, and the seam is not a convenience.** The
    /// behaviour that matters most about this cache — what the surface does when
    /// a canvas holds more photographs than the budget can keep — is unreachable
    /// from a test at 64 MiB, which is roughly 85 resident thumbnails at the size
    /// an item card asks for. N1 (an unbounded decode loop above that line) was
    /// found by reading and could not be reproduced until this existed.
    @State private var thumbnails = CanvasThumbnails()

    /// The thumbnail cache a test hands in — **the seam, and it is the whole
    /// cache rather than only its budget.**
    ///
    /// Two things about this surface are unreachable from a test without it, and
    /// N1 was both. What a canvas does when it holds more photographs than the
    /// budget can keep needs a budget a fixture can cross (64 MiB is roughly 85
    /// resident thumbnails at the size an item card asks for). And whether the
    /// servicing schedule feeds itself can only be read off `decodeCount` — the
    /// instrument every test in `CanvasThumbnailTests` uses, and the only one that
    /// is exact: the alternative is watching a counter fail to move, which passes
    /// just as happily when the harness has stopped delivering updates. It does
    /// stop; that was measured while writing this.
    ///
    /// A stored property rather than an initialiser argument for a stated reason:
    /// a hand-written `init` on a `@MainActor` `View` cannot assign its own
    /// stored properties from the nonisolated contexts its ~70 callers construct
    /// it in, and making the initialiser main-actor-isolated moves that problem
    /// to every one of them.
    var thumbnailCache: CanvasThumbnails?

    /// What every item node in the scene says it is, and the picture to draw on
    /// it — resolved in `rebuildLayouts` and read by the draw pass, the
    /// measurement and the accessibility tree.
    ///
    /// **Resolved on the structural path and never in `body`.** It rides
    /// `rebuildLayouts` rather than an invalidation key of its own because the
    /// measurement *needs* it — an item card's height is its picture's aspect
    /// ratio plus a line of label — so the two cannot be scheduled apart without
    /// one of them being a frame behind the other.
    @State private var itemPresentation = CanvasItemPresentation.empty

    /// Bumped by `rebuildLayouts` whenever a resolve missed a thumbnail — the
    /// `.task` trigger in `body`, which is where the whole reasoning lives.
    ///
    /// **A monotonic ticket, not the pending count.** It was the count for one
    /// commit and stalled on a failed decode: `rebuildLayouts` is its only writer
    /// and only runs after a service that reported something landed, so a failed
    /// one left the count frozen and the next miss producing the same count moved
    /// no id. A ticket cannot collide with itself.
    ///
    /// **And it must not be `revision`** (tripwire 30): a decode has nothing to do
    /// with a frame, and keying it on the redraw counter would restart a servicing
    /// task on every drag frame. This moves only when a resolve found work.
    @State private var thumbnailServiceTicket = 0

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

    /// What the tree's subject lights, and by omission what is dimmed (§4).
    ///
    /// **Cached here for the reason the element list above is cached here**, and
    /// it is the same defect one primitive over: resolving it walks every region
    /// and unions every region's `homeMembers`, and `body` runs on every scroll
    /// event, every drag frame and every momentum tick. Keying it on `revision`
    /// would be that defect with an extra step.
    ///
    /// Its inputs are the scene's bindings, its membership and the tree's
    /// subject — so it is rebuilt on `sceneRevision` (the inspector's bind, a
    /// drop-join and a swept region all bump it; drag and coast frames
    /// deliberately do not) **and** on `subject`, which moves on a click rather
    /// than on a frame.
    @State private var highlight = CanvasHighlight.undimmed

    /// What an external drop could not do, shown in an alert.
    ///
    /// **An alert and not a fourth transient banner.** Three
    /// `.overlay(alignment: .top)` banners already share this window and two on
    /// screen at once draw over each other; one banner host for the window is the
    /// honest fix and is its own slice. The inbox's `.alert("Couldn't promote", …)`
    /// over a `@State` `String?` is the nearest precedent, and `ResearchView`'s
    /// import alert is the same shape on the same kind of failure.
    @State private var dropError: String?

    /// When the writer last folded a keystroke into the model. A gap wider than
    /// `ScrapUndoBeat.idleSeconds` closes the open "Edit Scrap" gesture, so a
    /// long visit to a scrap is several ⌘Z steps rather than one. Cleared
    /// whenever focus moves, so the first keystroke of a visit never closes the
    /// step the PREVIOUS visit left behind.
    ///
    /// Moved only by a real keystroke — see `syncActiveEdit(fromKeystroke:)`.
    @State private var lastKeystrokeAt: Date?

    /// What was selected when the current mouse-down arrived — which is what the
    /// writer could SEE when they aimed it.
    ///
    /// **The connect mark is selection chrome, so the gesture that starts from it
    /// has to ask about the selection as DRAWN, and `model.selection` is already
    /// the new one by the time a drag begins.** `CanvasEventNSView.applyMouseDown`
    /// fires `onClick` strictly before `onDrag(.began)` — a contract that file
    /// states outright — and `handleClick` reassigns the selection to whatever is
    /// under the pointer. Read live at `.began`, the first press on an *unselected*
    /// card would therefore find that card selected and start a line out of a mark
    /// that was not on screen when the writer pressed: a 14 pt patch on the right
    /// edge of every card on the canvas that refuses to move it. Click, then
    /// press, is two gestures, and this is the one value that keeps them two.
    ///
    /// Written in exactly one place — the head of `handleClick`, before anything
    /// can move the selection — and read in exactly one, `handleDrag(.began)`. A
    /// stale value is harmless: `pressStartsALine` also requires the selected card
    /// to be the one under the pointer.
    @State private var selectionWhenPressed: CanvasSelection?

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
    /// hand — `CanvasViewMountingSurfaceTests.test_theMountedEditorIsInvisibleUntilTheCardHasStraightened`
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
        // The line being pulled, read here for the same reason and beside it.
        let band = interaction.pendingLine

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
                                        items: itemPresentation,
                                        selection: model.selection,
                                        highlight: highlight,
                                        pieceTitles: pieceTitles,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten,
                                        pendingRegionDraw: sweep,
                                        pendingLine: band, into: &cx)
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

            // §4's third row: a document with nothing bound — or, since stage 3b,
            // a research item whose card is not here (`CanvasBindingOffer`, whose
            // one decision function chooses which of the two sentences to say).
            //
            // **Beneath the event view on purpose.** It needs no
            // `.allowsHitTesting(false)` there — the transparent
            // `CanvasEventNSView` above it takes every click, exactly as it does
            // over the drawn `Canvas` — and `CanvasCompositionTests` counts the
            // two opt-outs above this line, so adding a third would say the
            // ground or the drawn layer had stopped opting out. It also keeps
            // the mounted editor frontmost with nothing between them.
            if let offer = CanvasBindingOffer.message(subject: subject, highlight: highlight) {
                CanvasBindingOfferView(message: offer)
            }

            CanvasEventView(
                camera: $camera,
                onClick: { viewPoint, clickCount in
                    handleClick(at: camera.contentPoint(fromView: viewPoint),
                                clickCount: clickCount)
                },
                onDrag: { viewPoint, phase, shiftHeld, timestamp in
                    dragHandler.handleDrag(at: camera.contentPoint(fromView: viewPoint), phase: phase,
                                           shiftHeld: shiftHeld, timestamp: timestamp)
                },
                onDeleteKey: { deleteSelection() },
                onEscape: { escapeAsksForTheWholeBoard() },
                // The one condition `CanvasEscapeMonitor` is installed under —
                // and it is the SUBJECT's dim rather than
                // `escapeAsksForTheWholeBoard`'s full answer, because the monitor
                // asks that closure at event time anyway. What this decides is
                // only how long an app-global monitor exists.
                dimsTheBoard: subject.dimsTheBoard,
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
                // found out. *** A press opens "Move Card" at `.began` and holds
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
        // Spec §8A.1: the research tree sits beside the canvas in the Plan
        // persona, and a row dragged out of it lands here as a card.
        //
        // **Mounted AFTER the frame above, deliberately.** The drop `location`
        // arrives in the modified view's own space, and the modified view here is
        // the filled rect — which is also exactly the rect `CanvasEventNSView`
        // occupies, and that view is `isFlipped`. So one point means the same
        // thing to a drop as it does to a click, and `contentPoint(fromView:)` is
        // the one inverse transform either of them goes through. Attached to the
        // bare `ZStack` instead, the drop space is whatever the stack sized itself
        // to before filling, which is not a rect anything else on this surface
        // measures against.
        //
        // `for: String.self` is the app's established internal-drag pattern, the
        // other end of `ResearchRow`'s `.draggable(item.id)`. **Not**
        // `.dropDestination(for: URL.self)`, which silently rejects a browser's
        // rendered-bitmap drag; external drops are their own route through
        // `DropClassification` and are not this modifier's business.
        //
        // *** THE ORDER OF THE NEXT TWO MODIFIERS IS NOT A PREFERENCE. It is the
        // only order in which both routes work, and it was settled by a smoke
        // rather than by reasoning — the reasoning was written down here first
        // and was WRONG. ***
        //
        // `.dropDestination(for: String.self)` FIRST (innermost), the provider
        // `.onDrop` after it. Written the other way round, `.onDrop(of:)` claims
        // the drag session **on hover, before any payload is examined**, so the
        // string destination behind it is never offered the drop at all: a
        // photograph from the Finder landed correctly while a research drag and
        // an inbox drag both did nothing whatever, and the Inbox's "Send to
        // Canvas" *command* — which touches no drop target — went on working,
        // which is what identified the modifiers rather than the routers.
        //
        // The comment that used to sit here claimed a research row's
        // `.draggable(item.id)` "carries neither a file URL nor an image, so it
        // never matches this one and falls through to the router below". **It
        // does not fall through.** A typed destination does not decline a session
        // on the strength of its payload type; the outer one simply never sees it.
        //
        // `ResearchRow.swift:69`/`:79` is the shipped precedent and ships THIS
        // order — an id drag and a browser image drag both land on that row
        // today. **No general depth rule should be read off the tree**:
        // `ResearchView` and `PaletteCardEditor` mount the provider `.onDrop`
        // with no typed destination beside it at all, so what matters is the
        // PAIRING rather than which kind goes outermost. (`CollectionResearchPane`
        // has the same pairing on its sections in the OTHER order — recorded in
        // this task's report, not fixed here: its inner per-row and per-header
        // destinations narrow the exposure to the blank space between rows, and
        // that fix wants its own smoke rather than the reasoning that failed
        // here.) `TripwireGrepTests
        // .test_theCanvasStringDropDestinationIsMountedBeforeTheProviderDrop`
        // pins this one, because no test in this repo can drive a drag session —
        // which is why it reached a smoke in the first place.
        .dropDestination(for: String.self) { payloads, location in
            handleDrop(payloads, at: location)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, viewPoint in
            handleExternalDrop(providers, at: viewPoint)
        }
        .alert(dropError ?? "",
               isPresented: Binding(get: { dropError != nil },
                                    set: { if !$0 { dropError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { load() }
        // §4's lit set AND the accessibility tree that speaks it — the STRUCTURAL
        // counter and the SUBJECT, never `revision`. Two triggers because there
        // are two inputs and they move on different occasions: the bindings and
        // the membership change with the scene, and what the tree names changes
        // with a click in the other column.
        //
        // ONE handler, deliberately, and never one of these each — see
        // `rebuildHighlightAndTree()`. A tree rebuilt from a trigger of its own
        // reads the `@State` `highlight` at whatever moment SwiftUI runs it, and
        // nothing orders two handlers on one update pass.
        //
        // `initial: true` sits on the subject's, which fires at mount: it covers
        // a window restored onto a chapter, and it is what guarantees a scene
        // arriving without a structural bump still has an accessible canvas
        // rather than a silent one — the failure this whole layer exists to
        // prevent. (`load()` ends in `rebuildLayouts()`, which bumps the counter,
        // so the ordinary path reaches both either way.)
        .onChange(of: sceneRevision) { _, _ in rebuildHighlightAndTree() }
        .onChange(of: subject, initial: true) { _, _ in rebuildHighlightAndTree() }
        // …and a THIRD input, for §4.2's borrowed name: the writer renamed the
        // chapter a dimmed region is bound to. The DRAWN name follows for free —
        // `pieceTitles` is a property of this view, so a new value re-runs `body`
        // — but the spoken one is cached in `axElements` against the two counters
        // above, neither of which moves when a manifest title changes, so without
        // this the region is announced under the old title for the rest of the
        // session. That is tripwire 22's rule (key on the thing that identifies
        // it, not on an id that outlives a rename) arriving on a name, and
        // `itemIndex.fingerprint` below is the same trigger for the same reason
        // one primitive over. Keyed on the FINGERPRINT and never on the map: a
        // dictionary comparison per body pass is what the key exists to avoid.
        .onChange(of: pieceTitles.fingerprint) { _, _ in rebuildHighlightAndTree() }
        // A research subject ARRIVING brings its card into view (stage 3b, §4).
        // Lighting a card the writer cannot see is a dimmed board and no answer,
        // which is the state the standing chrome above exists for — and the card
        // being on the canvas is exactly when that chrome is silent.
        //
        // **A SEPARATE observer, and not a fourth line inside
        // `rebuildHighlightAndTree()`.** That function answers *what is lit*; this
        // moves the writer's viewport. Folding a camera write into it would put
        // one on `sceneRevision` and on every rename fingerprint as well — so a
        // save, a bind from the other column or a manifest edit would yank the
        // camera back mid-arrangement. `CanvasHighlightTests`' caller census
        // still reads 4 for that reason.
        //
        // **No `initial:`, deliberately** — a restored subject is not an arrival.
        // A window reopened onto a research item dims exactly as it dims onto a
        // chapter, and the camera stays where the writer left it
        // (`ResearchRevealModifier`'s own rule, one column over).
        //
        // Tripwire 30: keyed on the SUBJECT, which moves on a click, and never on
        // `revision` or `sceneRevision` — off either, dragging the card would
        // re-centre it under the writer's own hand, once per frame.
        .onChange(of: subject) { _, arrived in bringArrivingResearchCardIntoView(arrived) }
        // The manifest moved under a canvas that did not: the writer renamed the
        // research note a card points at, or deleted it. Nothing on the canvas
        // changed, so no structural counter budged — and the card would show the
        // old title for the rest of the session. Keyed on the FINGERPRINT and
        // never on the index itself: a dictionary comparison per body pass is the
        // cost this key exists to avoid (`CanvasItemIndex.fingerprint`).
        //
        // **The model's copy is written HERE, before the rebuild** (issue #57).
        // This handler is created fresh on every body pass, so `itemIndex` here is
        // the window's latest; the model-held callbacks that `load()` wired are
        // not, and `rebuildLayouts` resolves through the model's copy for exactly
        // that reason. Miss this line and the callbacks go on resolving against
        // whatever index this canvas first appeared with.
        .onChange(of: itemIndex.fingerprint) { _, _ in
            model.itemIndex = itemIndex
            layoutPass.rebuildLayouts()
        }
        // The thumbnails the last resolve missed, decoded OFF the frame path.
        //
        // `CanvasThumbnails.resolved` never decodes — it records a miss and
        // returns nil — so this is the only thing that ever turns a photograph
        // into pixels, and it re-measures afterwards because an item card's height
        // follows its picture. `.task(id:)` rather than a `Task {}` from a
        // callback: SwiftUI cancels it when this view goes away.
        //
        // **The id is a monotonic TICKET, and it was a pending COUNT for one
        // commit — which stalled on a failed decode.** `rebuildLayouts` is the
        // only writer, and it only runs after a service when `servicePending()`
        // reports that something landed; a decode that FAILS (the writer deleted
        // the photograph in the Finder) drains the queue, reports false, and
        // leaves the count where it was. The next miss that happens to produce
        // *the same count* then changes no id and schedules nothing at all — so
        // the next photograph the writer drops on that canvas never decodes, for
        // the rest of the session, silently. Found by the Task 5 review, which
        // reproduced it through the real hosted view.
        //
        // A ticket says the honest thing: the trigger is **that there is work**,
        // not how much of it there is. It cannot collide with itself, so no state
        // of the queue can be mistaken for another, and a task that was cancelled
        // before it ran is picked up by the next rebuild that sees work rather
        // than only by one that sees a *different amount* of work.
        .task(id: thumbnailServiceTicket) {
            // No guard: the ticket only moves when a resolve missed something, and
            // `servicePending` on an empty queue is a no-op returning false. The
            // one call it costs is the initial mount, at ticket 0.
            //
            // **`bumpsThumbnailTicket: false` is what stops this feeding itself**,
            // and without it the ticket turns a bounded cache into an unbounded
            // decode loop — see the parameter's own doc. The re-measure still
            // happens, because a picture that has just landed for the FIRST time
            // has taught the cache a shape its card was not measured with.
            if await thumbnails.servicePending() {
                layoutPass.rebuildLayouts(bumpsThumbnailTicket: false)
            }
        }
        // MIRRORED, not replaced. The model's counter is bumped by the inspector
        // from the other column; the view's is what the grep-pinned rebuild above
        // watches, and it must keep both its name and its home here.
        .onChange(of: model.sceneRevision) { _, _ in sceneRevision += 1 }
        .onDisappear {
            // Fold the live editor's text in BEFORE the write, or a persona
            // switch mid-sentence loses the sentence.
            editFocus.syncActiveEdit()
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
    /// still up to `CanvasMaterial.maximumTiltDegrees` off level, so they snapped straight on the click and the
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
                            onTextChanged: { editFocus.syncActiveEdit(fromKeystroke: true) })
                .frame(width: textSize.width * camera.zoom,
                       height: textSize.height * camera.zoom)
                .position(x: viewOrigin.x + textSize.width * camera.zoom / 2,
                          y: viewOrigin.y + textSize.height * camera.zoom / 2)
        }
    }

    // MARK: - Loading and measuring

    private func load() {
        // FIRST, and before a single closure below is wired: the index those
        // closures resolve item nodes through (issue #57). They capture this
        // view's VALUE, so the copy that lives on the model is the one they can
        // still reach after the window has handed the view a newer one —
        // `CanvasModel.itemIndex` carries the whole argument. Kept current by the
        // `.onChange(of: itemIndex.fingerprint)` in `body`.
        model.itemIndex = itemIndex
        // The model reads both files and wires the recorder's two closures to
        // itself. What is left here is what only a VIEW can do.
        model.attach(projectRoot: projectRoot)
        // The store's own quit hook writes whatever was last queued; this makes
        // sure what was last queued includes the sentence the writer is halfway
        // through. `.onDisappear` does not fire on ⌘Q.
        model.beforeFlush = { editFocus.syncActiveEdit() }
        // Something in another column changed the scene — today the region and
        // line inspectors, a promotion writing its mark, and 1C-c3's write tool
        // adding cards to the canvas the writer is looking at.
        //
        // Nodes that arrive that way have no `ScrapLayout` here, so they have no
        // measured height, and a node with no `cachedHeight` has no `frame`:
        // `drawCard` gets a nil layout and draws an empty rectangle, and
        // `topmostNode(at:)` and `nodes(intersecting:)` drop it, so the card
        // cannot be clicked either. It stays that way until the writer happens
        // to touch something that rebuilds.
        //
        // NOT bumping the structural counter, because a bump is already on its
        // way: every writer through `mutateFromInspector` calls
        // `model.bumpSceneRevision()` on its own line, and the mirror in `body`
        // turns that into the view's bump. Bumping here as well would sort the
        // scene, copy every scrap's string and rebuild the region inspector's
        // cached lists twice for one change. (That is the RULE the argument
        // exists for; `grep "bumpsStructuralCounter: false"` for who takes it.)
        //
        // **This pass runs under a MOUNTED editor on exactly tripwire 32's
        // repro** — a focused scrap holding "Edit Scrap" open while the writer
        // commits something in the other column — and it is safe only because
        // the fold is per-keystroke. `ScrapLayout.text` is the shared
        // `NSTextStorage`'s own string and `onTextChanged` keeps
        // `model.scraps[id]` equal to it at every event boundary, so the reuse
        // branch below hits and the layout the live `NSTextView` is bound to is
        // not replaced. Make that fold debounced and this line swaps the stack
        // under the writer mid-sentence and shows them the model's older text.
        model.onSceneChangedExternally = { layoutPass.rebuildLayouts(bumpsStructuralCounter: false) }
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
            if let id = editingNodeID, model.scene.node(id) == nil { editFocus.leaveTheOpenScrap() }
            // Heights are DERIVED, so a restored scene is re-measured rather
            // than trusted — and a scrap whose text the undo changed gets a new
            // `ScrapLayout`, which is what makes `ScrapEditorHost` rebind the
            // mounted editor instead of leaving it showing the discarded words.
            // Replacing the layout under a MOUNTED editor is safe; the
            // measurement is on `rebuildLayouts` below.
            //
            // A call site that does not bump the structural counter, and the
            // argument is spelled out rather than defaulted so it cannot be
            // lost. The model bumps its own counter on the line after this
            // closure returns, and the mirror below turns that into the view's
            // bump — so bumping here as well rebuilds the whole accessibility
            // tree TWICE for one ⌘Z, and a writer holding ⌘Z pays a scene sort
            // and a copy of every scrap's string per step, twice.
            layoutPass.rebuildLayouts(bumpsStructuralCounter: false)
        }
        // Another column asking the camera to move — the arrival banner's Show
        // (1C-c3), and §8A.4's Send to Canvas (1C-d). `momentum.stop()` above is
        // the precedent for writing `@State` from inside a model callback; the
        // target is resolved HERE rather than by the caller because this is the
        // first point past `attach()`, and a caller in another column may be
        // holding a scene that predates the write (see
        // `CanvasModel.onRevealRequested`).
        //
        // A region is brought by its frame's origin and a card by its own, which
        // is the same point in both cases: the top-left of the thing, put at
        // `revealViewPoint`.
        model.onRevealRequested = { target in
            let origin: CGPoint?
            switch target {
            case .region(let id): origin = model.scene.region(id)?.frame.origin
            case .node(let id): origin = model.scene.node(id)?.origin
            }
            guard let origin else { return }
            camera.bring(origin, toViewPoint: CanvasCamera.revealViewPoint)
        }
        // A test's cache, before the first resolve can miss anything. Production
        // passes nothing and keeps the one `@State` made for it.
        if let thumbnailCache { thumbnails = thumbnailCache }
        wash = CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())
        layoutPass.rebuildLayouts()
        // A reveal asked for while this view was not mounted — which is the
        // ordinary case, because Show switches persona and asks in one act. Last,
        // so it runs against the attached scene.
        if let parked = model.takePendingReveal() {
            model.onRevealRequested?(parked)
        }
    }

    /// The writer clicked a research row, so the card that answers to it comes
    /// into view (stage 3b, spec §4).
    ///
    /// **The same path a drop-reveal drives** — `camera.bring(_:toViewPoint:)` at
    /// `CanvasCamera.revealViewPoint`, zoom untouched. Nothing here is new
    /// geometry: the join to the board is `CanvasNodeID.item(id)`, derived and
    /// O(1), and this is the third caller of the one reveal spelling
    /// (`onRevealRequested` and `handleDrop`'s `.reveal` arm are the others).
    ///
    /// **Nothing is selected.** A drop selects because a drop is a placement the
    /// writer just made and the inspector should show it; this is a click in the
    /// tree, which is the window's subject-picker — the dim is what says *this
    /// one*, and writing the canvas's own selection from here would be a second
    /// answer to what the window is about.
    ///
    /// **The camera moves even when the card is already on screen**, which is
    /// `handleDrop`'s cost for `handleDrop`'s reason: this view has no
    /// `GeometryReader` (the viewport exists only inside the `Canvas` closure), so
    /// *"is it visible already"* is not a question it can ask.
    ///
    /// No `revision` bump: `camera` is `@State` this view reads in `body`, so a
    /// write to it redraws by itself. The scene did not move, so no structural
    /// bump either.
    private func bringArrivingResearchCardIntoView(_ arrived: CanvasSubject) {
        guard case .research(let id) = arrived,
              let node = model.scene.node(.item(id)) else { return }
        camera.bring(node.origin, toViewPoint: CanvasCamera.revealViewPoint)
    }

    /// Re-derive §4's lit set **and the accessibility tree that speaks it**, from
    /// ONE resolution, in one pass.
    ///
    /// **The only writer of `highlight`** and the only writer of `axElements`,
    /// called from the three `.onChange`s in `body` and from nowhere else — a
    /// fourth call site on a per-frame path is the whole of what tripwire 30
    /// forbids here, and it would be invisible on screen because the answer would
    /// be right every time. (It was two triggers until §4.2 gave the spoken
    /// region a piece TITLE to carry; a manifest rename moves neither the scene
    /// nor the subject, so the third trigger is the only thing that can refresh
    /// it. Count the `.onChange`s, not this sentence.)
    ///
    /// **The two rebuilds are one function because they were nearly two, and the
    /// two-function shape has a hole with no symptom.** The tree used to be
    /// rebuilt from its own `.onChange(of: sceneRevision)`; once a label depends
    /// on the dim it depends on the subject too, so that trigger needed the
    /// subject as well — and a *second* `.onChange` reading the `@State`
    /// `highlight` reads whatever value that property holds when SwiftUI happens
    /// to run it. SwiftUI does not order two handlers on the same update pass,
    /// and there is no third trigger to correct it, so a tree built before the
    /// dim was re-resolved describes the board as it was **before the writer's
    /// last click, for as long as nothing else moves the scene**. Resolving into
    /// a local and handing the same value to both makes the stale read
    /// unspellable rather than unlikely, and it is the same guarantee `items`
    /// already has one layer down: the card a writer looks at and the sentence a
    /// listener hears cannot come to different conclusions about the same board.
    ///
    /// The tree costs a sort of the whole scene and a copy of every scrap's
    /// string, so it rides `sceneRevision` exactly as it did — never `revision`,
    /// which every animation frame bumps. Rebuilding it on a subject change as
    /// well is new work, and it is once per tree click.
    private func rebuildHighlightAndTree() {
        let resolved = CanvasHighlight.resolve(subject: subject, in: model.scene)
        highlight = resolved
        axElements = CanvasAccessibility.elements(scene: model.scene, scraps: model.scraps,
                                                  items: itemPresentation, highlight: resolved,
                                                  pieceTitles: pieceTitles)
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
        /// A line. Nothing to enter and nothing to make — see the switch below.
        case line
    }

    private func clickTarget(at contentPoint: CGPoint) -> ClickTarget {
        guard let node = model.scene.topmostNode(at: contentPoint) else {
            // The SAME precedence as `CanvasScene.selectionTarget`, and it has
            // to be:
            // the `clickCount: 1` AppKit sends first has already selected
            // whatever this resolves to, so a double click that answered a
            // different question would act on something the writer is not
            // looking at.
            return CanvasLineHit.line(at: contentPoint, in: model.scene) != nil
                ? .line : .emptyCanvas
        }
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
        // FIRST, above everything else in this method: the selection as the
        // writer saw it when they pressed. The connect-mark drag reads it at
        // `.began`, which runs after this whole method — see
        // `selectionWhenPressed`.
        selectionWhenPressed = model.selection
        editFocus.commitActiveEdit()

        // A read-only canvas (issue #44) takes a double click as a single one:
        // it selects, and makes, enters and mounts nothing.
        guard CanvasEditGate.clickCount(clickCount, isReadOnly: model.isReadOnly) >= 2 else {
            model.selection = model.scene.selectionTarget(at: contentPoint)
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
            editFocus.leaveTheOpenScrap()
            model.scheduleSave()
            return
        }

        switch clickTarget(at: contentPoint) {
        case .scrap(let node, let layout, let frame):
            // §7A.5 requirement 1: resolve the caret in the card's LOCAL,
            // UNROTATED space at CLICK TIME — before the card straightens.
            // Straightening first moves the click point out from under the
            // cursor, and the caret lands somewhere the writer did not aim.
            let angle = CanvasRenderer.drawnAngle(for: node, straighten: straighten)
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
            layoutPass.rebuildLayouts()
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
                    // The membership changed AFTER `rebuildLayouts()` bumped the
                    // structural counter, and that bump is the only one on this
                    // path — so without this the region inspector in the other
                    // column is reading a scene from before the join, and the
                    // new card is missing from "Lives here" until some unrelated
                    // structural change happens along. It works today only
                    // because SwiftUI reads the post-join scene in a later body
                    // pass, which is an accident of ordering rather than a
                    // guarantee: this is the exact shape of the stale-inspector
                    // defect the first whole-branch review caught.
                    model.bumpSceneRevision()
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

        case .unenterableNode, .line:
            // Nothing to enter, so this behaves like a single click. Falling
            // through instead would leave `editingNodeID` and `straighten`
            // pointing at whatever was open before: the invisible editor stays
            // mounted on the card the writer just clicked AWAY from, and
            // `visibleEditorNodeID` re-reveals it the moment `isLevel` fires.
            //
            // **A line shares this arm rather than falling to `.emptyCanvas`,
            // and that is a real bug rather than a tidiness.** There it would
            // mint a scrap UNDER the writer's own line — and AppKit sends
            // `clickCount: 1` first, so that click has already selected the line
            // and the other column is showing it. "Edit Scrap" open over a line
            // selection is tripwire 32's own repro arriving through a new door.
            // A double click on a line therefore opens no editor of any kind;
            // its label is edited in the other column, which is where a region's
            // label already is.
            editFocus.leaveTheOpenScrap()
        }
        model.scheduleSave()
    }

    // MARK: - Drops

    /// A research row dropped on the canvas (spec §8A.1).
    ///
    /// **This method decides nothing.** `CanvasDrop.decide` is a pure function
    /// over the payload, the scene and the item index, and `CanvasDrop.apply` owns
    /// the undo bracket and the membership — because SwiftUI's drop delivery has
    /// no seam a test can post into, so what a drop *means* has to be answerable
    /// somewhere a test can reach exhaustively. What is left here is the camera
    /// (a view's own state) and the selection, and that this modifier is mounted
    /// at all is pinned by a census rather than by a test.
    ///
    /// **The first payload only, which is the house pattern rather than a
    /// shortcut.** `ResearchRow`'s own `.dropDestination` takes `ids.first`, and
    /// every `.draggable(id)` source in the app sends exactly one — the research
    /// tree's multi-selection is expanded by the *receiver* (`ResearchView`'s
    /// `ResearchSelectionSync.expandedDragIds`) rather than travelling in the
    /// payload, and this receiver deliberately does not expand it: the canvas
    /// cannot see the binder's selection, and inventing a rule from it would be a
    /// second answer to "what did the writer drag". A batch that really does
    /// arrive as several payloads is the external file drop, which is its own
    /// modifier with its own arrangement rule.
    ///
    /// Returns whether anything happened, so a payload this canvas has no card for
    /// is declined and the drag springs back rather than reporting success.
    ///
    /// **Two id spaces arrive here as of 1C-d Task 12, and `CanvasDrop.payload`
    /// tells them apart before anything else runs** (spec §8A.4). An inbox
    /// capture's ULID and a research item id are not tellable apart, so the inbox
    /// row sends a PREFIXED payload; without the destructuring, `decide` would
    /// look the ULID up in `CanvasItemIndex`, not find it, and refuse the drag
    /// with nothing said. See `CanvasDrop`'s own doc comment for why the prefix
    /// breaks the house's raw-id pattern deliberately.
    private func handleDrop(_ payloads: [String], at viewPoint: CGPoint) -> Bool {
        guard let payload = payloads.first else { return false }
        if case .capture(let entryID) = CanvasDrop.payload(payload) {
            // Read-only (issue #44): springs back before the send, so no asset is
            // copied and the entry stays new; the canvas's notice says why.
            guard CanvasEditGate.accepts(.capture, isReadOnly: model.isReadOnly)
            else { return false }
            return handleCaptureDrop(entryID, at: viewPoint)
        }
        switch CanvasDrop.decide(payload: payload,
                                 at: camera.contentPoint(fromView: viewPoint),
                                 in: model.scene, index: itemIndex) {
        case .ignored:
            return false

        case .reveal(let id):
            // Not gated (issue #44): a reveal selects and moves the camera and
            // changes nothing, so it works on a read-only canvas too.
            // The item is already here. Say so by SHOWING it — a drop that
            // silently did nothing is indistinguishable from a broken surface,
            // which is this task's named failure. The card is not moved: that
            // would be a geometry-driven change to something the writer placed.
            //
            // The camera moves even when the card was already on screen, and that
            // is a real cost rather than an oversight: this view has no viewport
            // outside the `Canvas` closure (no `GeometryReader`, by design), so
            // "is it visible already" is not a question it can ask.
            guard let node = model.scene.node(id) else { return false }
            model.selection = .node(id)
            camera.bring(node.origin, toViewPoint: CanvasCamera.revealViewPoint)
            // The selection is read inside the draw closure, where a model value
            // is not in SwiftUI's dependency graph — `handleClick`'s single-click
            // arm bumps for the same reason. `revision` and never `sceneRevision`:
            // nothing structural happened.
            revision += 1
            return true

        case .create(let node):
            guard CanvasEditGate.accepts(.place, isReadOnly: model.isReadOnly)
            else { return false }
            CanvasDrop.apply(node, in: model)
            // Selected, so the right-hand column shows the reference's own arm and
            // the writer can see what landed. Outside the bracket: a snapshot
            // carries the scene and the scrap text, never the selection.
            model.selection = .node(node.id)
            return true
        }
    }

    /// An inbox capture dropped on the canvas (spec §8A.4) — the **third** caller
    /// of this drop target, beside the research drag and the external file drop.
    ///
    /// **This method decides nothing either.** Everything the send does — reading
    /// the capture, refusing one with nothing in it, ingesting a photograph,
    /// writing the canvas inside one undo bracket and flipping the entry
    /// `.promoted` only after all of it has succeeded — is
    /// `InboxStore.sendToCanvas`, which a test can reach without a window. What is
    /// left here is the drop point, the selection and the alert.
    ///
    /// **The capture lands where it was dropped, and the canvas gains no placement
    /// rule for it** (§8A.4's amendment). That is the whole reason the drag is the
    /// primary route: the writer has already said where.
    ///
    /// **The camera does NOT move**, unlike the command route's `CanvasCapture.show`
    /// — the card arrived under the pointer, so a jump would be to somewhere the
    /// writer is already looking.
    ///
    /// The content point is resolved **before** the await, exactly as the external
    /// drop does it: `camera` can move under a drop that takes a moment (a coast
    /// finishing, a rewind), and the capture belongs where the writer let go of it.
    private func handleCaptureDrop(_ entryID: String, at viewPoint: CGPoint) -> Bool {
        let contentPoint = camera.contentPoint(fromView: viewPoint)
        Task {
            do {
                let id = try await captureDrop.send(entryID, contentPoint)
                // Selected so the right-hand column shows the capture's own
                // inspector arm. Outside the bracket: a snapshot carries the scene
                // and the scrap text, never the selection.
                model.selection = .node(id)
            } catch {
                dropError = error.localizedDescription
            }
        }
        return true
    }

    /// A photograph dropped from the Finder or a browser (spec §8A.1).
    ///
    /// **This method decides nothing either.** Classification is
    /// `DropClassification`'s — the canvas is its fifth adopter and adds no rule
    /// of its own — and everything after it is `CanvasExternalDrop`'s, which is
    /// where a test can reach it. What is left here is the camera, the selection
    /// and the alert, which are this view's own state.
    ///
    /// **The return value is synchronous and the work is not**, which is what the
    /// modifier's signature requires: `accepts` is a pasteboard question with an
    /// immediate answer, so a drag carrying neither a file nor an image is
    /// declined outright and springs back — a refusal the writer can see — while
    /// the ingestion, which reads and writes files, runs in a `Task`.
    ///
    /// The content point is resolved **before** the await: `camera` can move
    /// under a drop that takes a moment (a coast finishing, a rewind), and the
    /// photograph belongs where the writer let go of it.
    private func handleExternalDrop(_ providers: [NSItemProvider],
                                    at viewPoint: CGPoint) -> Bool {
        // Read-only (issue #44): refused BEFORE `ingest`, which copies into
        // `canvas_assets/` first — a refused drop must strand no copy there.
        guard CanvasEditGate.accepts(.external, isReadOnly: model.isReadOnly)
        else { return false }
        let accepted = providers.filter { CanvasExternalDrop.accepts($0) }
        guard !accepted.isEmpty else { return false }
        let contentPoint = camera.contentPoint(fromView: viewPoint)
        Task {
            let outcome = await CanvasExternalDrop.ingest(providers: accepted,
                                                          using: assetIngest)
            let made = CanvasExternalDrop.apply(paths: outcome.paths,
                                                at: contentPoint, in: model)
            // Selected so the right-hand column shows the picture's own inspector
            // arm. Outside the bracket: a snapshot carries the scene and the
            // scrap text, never the selection.
            if let first = made.first { model.selection = .node(first) }
            dropError = outcome.message
        }
        return true
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
    /// `CanvasScene.removeRegion` touches. **Deleting a line is the same rule in
    /// a second id space**: the relationship goes and both cards stay.
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
        // Read-only (issue #44): the card arm's `withScene(persist: false)`
        // would remove the card from memory, unguarded by the model.
        guard CanvasEditGate.deletes(isReadOnly: model.isReadOnly) else { return false }
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
            if editingNodeID == id { editFocus.leaveTheOpenScrap() }
            // "Card" and not "Scrap": this arm deletes an item node too, and a
            // writer who removed a photograph read *Undo Delete Scrap*. The noun
            // is uniform across all three node steps for the reason recorded on
            // `gestureName`, which is where the argument lives.
            model.beginGesture("Delete Card")
            model.withScene(persist: false) { $0.remove(id) }
            model.removeScrapText(id)
            model.endGesture()
            // Another caller that does not bump the structural counter, for the
            // same reason as the rest of them: `model.bumpSceneRevision()` below
            // reaches this view through the mirror in `body`, so bumping here as
            // well rebuilds the whole accessibility tree twice for one ⌫. The
            // deleted card leaving that tree is what
            // `CanvasViewMountingEditingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`
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
            layoutPass.rebuildLayouts(bumpsStructuralCounter: false)
        case .line(let id):
            guard model.scene.line(id) != nil else { return false }
            // **A line delete never touches its cards.** The writer took back
            // the relationship, not the things related — the mirror of a card
            // delete, which DOES take its lines with it (`CanvasScene.remove`),
            // because a line to a card that is gone draws into nowhere. One
            // gesture either way, so one ⌘Z either way.
            model.mutate("Delete Line") { $0.removeLine(id) }
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

    /// **Escape: the way out of the dim** (§4.1). Returns whether the canvas used
    /// the key — see `CanvasEventNSView.keyDown`.
    ///
    /// Two refusals, and neither is defensive:
    ///
    /// - **A mounted scrap keeps its Escape.** §4.1 rules that the canvas may
    ///   only see the key with no editor mounted, and the responder chain
    ///   delivers that on its own for as long as the editor holds first
    ///   responder. This guard covers the window it does not: a scrap can be open
    ///   while the event view still has the keyboard, which is the same window
    ///   `deleteSelection`'s `isInGesture` guard exists for.
    /// - **An undimmed board has nothing to leave**, so the key travels on.
    ///   Escape means something to a great many responders above this one and a
    ///   canvas that swallowed every one of them would look identical from here.
    ///
    /// It does not clear the canvas SELECTION, and that is what "the keyboard
    /// spelling of the project row" means taken literally: clicking that row
    /// leaves the selected card selected, so this must too. It asks the window to
    /// name the project and stops there — the dim, the standing text and the
    /// sweep's binding all follow from the subject, so there is exactly one
    /// thing to change.
    private func escapeAsksForTheWholeBoard() -> Bool {
        guard editingNodeID == nil, subject.dimsTheBoard else { return false }
        selectTheProjectRow()
        return true
    }

    // MARK: - Helpers, built per call

    /// The layout pass over this view's own `@State`, built fresh on every call
    /// and never stored, so each call sees the latest view value. Built here and
    /// nowhere else (`CanvasSourceCensus.surfaceFiles`, tripwire 32's surface
    /// census), which is what lets tripwire 57's walk see its inputs: the walk
    /// follows this property, so a changing view value handed in below is caught.
    ///
    /// **`itemIndex: model.itemIndex` and not this view's own** (issue #57): two
    /// of `rebuildLayouts`' callers are closures the model holds, and through
    /// them this view's `itemIndex` is the one the canvas first appeared with.
    private var layoutPass: CanvasLayoutPass {
        CanvasLayoutPass(model: model,
                         itemIndex: model.itemIndex,
                         projectRoot: projectRoot,
                         thumbnails: $thumbnails,
                         layouts: $layouts,
                         itemPresentation: $itemPresentation,
                         thumbnailServiceTicket: $thumbnailServiceTicket,
                         revision: $revision)
    }

    /// The open scrap — folding the writer's words in, the outer undo boundary,
    /// and leaving — over this view's own `@State`, built per call like
    /// `layoutPass`.
    private var editFocus: CanvasEditFocus {
        CanvasEditFocus(model: model,
                        editingNodeID: $editingNodeID,
                        caretIndex: $caretIndex,
                        straighten: $straighten,
                        lastKeystrokeAt: $lastKeystrokeAt,
                        layouts: $layouts,
                        revision: $revision)
    }

    /// The drags — every gesture's press, move and release and the undo bracket
    /// each opens and closes — over this view's own `@State`, built per call
    /// like `layoutPass`. `editingNodeID` and `selectionWhenPressed` are only
    /// read there, and are bindings anyway so a read is never a stale copy.
    private var dragHandler: CanvasDragHandler {
        CanvasDragHandler(model: model,
                          subject: subject,
                          layoutPass: layoutPass,
                          interaction: $interaction,
                          momentum: $momentum,
                          revision: $revision,
                          editingNodeID: $editingNodeID,
                          selectionWhenPressed: $selectionWhenPressed)
    }
}
