import XCTest
import AppKit
import ApplicationServices
import SwiftUI
@testable import Maugham

/// `CanvasCompositionTests` reads this view's source. These tests run it: a real
/// `CanvasView` in a real window, clicked through `CanvasEventNSView`'s testable
/// seam.
///
/// The distinction earns its keep three times over.
///
/// Task 9 proved the editor container is reachable in the hierarchy IT builds —
/// a container added straight to a window's content view. What nothing has
/// covered is whether SwiftUI's own hosting hierarchy preserves that, and that
/// is the hierarchy the writer meets: an `NSViewRepresentable` is wrapped in
/// SwiftUI host views, and the mount is a `@ViewBuilder` branch on private
/// `@State` that only a click can flip.
///
/// Task 5 proved `CanvasStore.flush()` calls `beforeFlush` and that app
/// termination calls `flush()`. What no test in Task 5 could reach is whether
/// this view ever BINDS `beforeFlush` — and if it does not, the smoke that gates
/// this slice ("type a sentence, ⌘Q without clicking away first, relaunch, the
/// sentence is there") fails while every unit test in the plan stays green.
///
/// And Task 8's shader reads the camera and the wash it is handed. Both are
/// private `@State` here; what is observable from outside is whether the
/// deferred palette closure is ever pulled.
final class CanvasViewMountingTests: XCTestCase {

    /// Keep the window alive for the length of the test — a released window
    /// drops first responder and the assertion becomes a coin flip.
    private var windows: [NSWindow] = []
    private var roots: [URL] = []

    private let scrapID = CanvasNodeID("s1")
    private let scrapText = "the falls at night"

    /// A second card, down and to the right of the first, and a third far outside
    /// any viewport. Both exist so the published FRAMES can be compared against
    /// each other — see `test_twoCardsInDifferentPlacesPublishDifferentFrames`.
    private let secondScrapID = CanvasNodeID("s2")
    private let secondScrapText = "and the lit bridge"
    private let farScrapID = CanvasNodeID("far")
    private let farScrapText = "ninety thousand points east"

    /// A scrap chosen so that NARROWING it to the resize floor actually rewraps.
    ///
    /// `scrapText` cannot do that job and no assertion should pretend otherwise:
    /// measured through `ScrapLayout`'s own stack at Iowan Old Style 13, "the
    /// falls at night" is 94.62pt wide, so it still sits on ONE line inside the
    /// 100pt text box of a card at `CanvasInteraction.minimumScrapWidth`. Its
    /// card is 38pt tall at every width from 240 down to the floor.
    ///
    /// This string, measured the same way: 2 lines and a 54pt card at the
    /// fixture's 240pt width, 4 lines and an 88pt card once narrowed. The 34pt
    /// of new card below the old bottom edge is what
    /// `test_aCardBeingResizedStaysOnTheCanvasForTheWholeDrag` reads, and the
    /// margin is deliberate — the height is 88 at every card width from 124 down
    /// to the 120 floor, so the exact pixel the drag lands on does not decide the
    /// result.
    private let rewrappingScrapText = "the falls at night seen from the road below the town"

    override func tearDown() {
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    /// A project on disk holding one measured scrap at a known place. Written
    /// through `CanvasStore` itself, so the fixture cannot drift from the format
    /// the view will read.
    private func projectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap,
                                origin: CGPoint(x: 20, y: 20), width: 240,
                                cachedHeight: 60))
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText])
    }

    /// `projectRoot()`'s scene with `rewrappingScrapText` in the scrap — same id,
    /// same origin, same width, so `doubleClickTheScrap` still lands on it and
    /// only the wrapping differs. `cachedHeight` is the measured 54; the view
    /// re-derives it on load either way, so it is here as documentation of the
    /// starting shape rather than as an input.
    private func rewrappingScrapProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap,
                                origin: CGPoint(x: 20, y: 20), width: 240,
                                cachedHeight: 54))
        return try projectRoot(scene: scene, scraps: [scrapID: rewrappingScrapText])
    }

    /// An empty directory — no canvas on disk at all, which is the state a writer
    /// meets the first time they open the Plan persona on a project.
    private func emptyProjectRoot() throws -> URL {
        try makeRoot()
    }

    private func projectRoot(scene: CanvasScene,
                             scraps: [CanvasNodeID: String]) throws -> URL {
        let root = try makeRoot()
        CanvasStore(projectRoot: root).save(scene: scene, scraps: scraps)
        return root
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// SwiftUI mounts representables and applies state changes on the main
    /// runloop, so nothing here is observable until the loop has turned.
    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Pump for at least `seconds` of WALL CLOCK.
    ///
    /// `RunLoop.run(until:)` returns as soon as it has nothing left to service,
    /// so `pump(1.8)` really waits for the last scheduled timer and no longer.
    /// Measured 2026-07-26: a `pump(1.8)` after a keystroke returned 0.76 s later
    /// — the 750 ms save debounce, the last source on the loop. Anything that
    /// asserts on `ScrapUndoBeat.idleSeconds` having ELAPSED has to use this;
    /// with `pump` the beat silently does not pass and the test measures nothing.
    private func waitOut(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { pump(0.1) }
    }

    @discardableResult
    private func host(_ view: CanvasView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        windows.append(window)
        // The timeline that drives the straighten only advances when the window
        // is producing frames.
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    private func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstDescendant(type, in: sub) { return hit }
        }
        return nil
    }

    private func eventView(in window: NSWindow) throws -> CanvasEventNSView {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(firstDescendant(CanvasEventNSView.self, in: root),
                             "the canvas event view never reached the hosted "
                             + "hierarchy, so nothing on this surface can be clicked")
    }

    /// A press, an optional path, and a release — the real `mouseDown` →
    /// `mouseDragged` → `mouseUp` sequence, through the same seam the AppKit
    /// overrides call.
    ///
    /// No pumping between the samples: a real drag delivers them a frame apart,
    /// and turning the runloop in between would age them past
    /// `CanvasInteraction.maximumFlickAge` and quietly disarm every flick these
    /// tests are about.
    private func drag(_ events: CanvasEventNSView,
                      from start: CGPoint,
                      through path: [CGPoint]) {
        events.applyMouseDown(at: start, clickCount: 1)
        for point in path { events.applyMouseDragged(to: point) }
        events.applyMouseUp(at: path.last ?? start)
    }

    /// Take the canvas down so `.onDisappear` flushes the store, then read what
    /// reached disk.
    private func savedScene(after window: NSWindow, root: URL) -> CanvasScene {
        window.contentView = NSView(frame: .zero)
        pump()
        return CanvasStore(projectRoot: root).load().scene
    }

    /// Double-click the scrap the fixture put at (20, 20)–(260, 80). The camera
    /// is at identity, so a view point IS a content point.
    ///
    /// - Parameter settle: how long to let the runloop turn afterwards. The
    ///   straighten takes ~120 ms, so a caller that wants to see the editor
    ///   BEFORE it becomes visible has to ask for less than that.
    @discardableResult
    private func doubleClickTheScrap(in window: NSWindow,
                                     settle: TimeInterval = 0.3) throws -> ScrapEditorContainer {
        let root = try XCTUnwrap(window.contentView)
        let events = try XCTUnwrap(firstDescendant(CanvasEventNSView.self, in: root),
                                   "the canvas event view never reached the hosted "
                                   + "hierarchy, so nothing on this surface can be clicked")
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 2)
        pump(settle)
        return try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: root),
                             "a double-click on a scrap mounted no editor into the "
                             + "hosted hierarchy — the writer clicks into a scrap "
                             + "and typing does nothing")
    }

    // MARK: - The seams

    /// Task 8 built `CanvasGroundPalette.wash(fromHex:)` and left the seam
    /// unwired; this view is what pulls it. `CanvasCompositionTests` pins that
    /// the pulled value reaches the ground — this pins that anything pulls it at
    /// all. An unpulled palette and a correctly dosed 4% wash look identical.
    func test_theProjectsPaletteIsPulledWhenTheCanvasAppears() throws {
        var asked = 0
        host(CanvasView(projectRoot: try projectRoot(),
                        paletteSwatchHexes: { asked += 1; return ["#33aa88"] }))
        XCTAssertGreaterThan(asked, 0,
                             "the canvas never asked the project for its palette, so "
                             + "the ground is untinted for every project — and a wash "
                             + "that never arrives looks exactly like one dosed right")
    }

    /// The editor exists, is focused, and — crucially — ⌘Z from inside it can
    /// still reach the canvas's own undo stack. Task 9 measured that chain in the
    /// hierarchy it built by hand; this is the hierarchy SwiftUI builds.
    func test_aDoubleClickMountsAFocusedEditorReachableFromTheResponderChain() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let root = try XCTUnwrap(window.contentView)
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: root),
                     "precondition: nothing is mounted before anything is clicked")

        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView,
                                   "the container mounted with no text view in it")
        XCTAssertEqual(editor.string, scrapText,
                       "the editor mounted on some other scrap's layout")
        XCTAssertTrue(window.firstResponder === editor,
                      "the mounted editor is not first responder in the real "
                      + "hierarchy, so every keystroke goes somewhere else")

        // The route ⌘Z takes: NSTextView does not implement undo:, so the action
        // walks nextResponder until something does.
        var responder: NSResponder? = editor
        var handler: NSResponder?
        while let r = responder {
            if r.responds(to: #selector(ScrapEditorContainer.undo(_:))) { handler = r; break }
            responder = r.nextResponder
        }
        XCTAssertTrue(handler === container,
                      "the responder chain out of the mounted editor does not reach "
                      + "the canvas container, so ⌘Z inside a scrap drives SwiftUI's "
                      + "undo stack instead of the canvas's")
    }

    /// §7A.5's ordering, end to end and on the clock this task owns: the editor
    /// is mounted and focused immediately and is NOT the visible text until the
    /// card is level. Nothing else in the plan can see this — Task 7 owns the
    /// interpolated value, Task 9 owns what `isEditorVisible` does, and only
    /// this view's `TimelineView` connects the two.
    ///
    /// It caught the defect `CanvasView.maximumFrameStep` now fixes: a paused
    /// `TimelineView` holds its last date, so the first delta after a click is
    /// the whole idle gap and an unclamped `step(elapsed:)` finished the whole
    /// straighten on frame one. Every test that steps the straighten by hand
    /// passed throughout — the animation simply never ran on the real surface.
    func test_theMountedEditorIsInvisibleUntilTheCardHasStraightened() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        // Less than the ~120 ms straighten, so this is the middle of it.
        let container = try doubleClickTheScrap(in: window, settle: 0.04)
        XCTAssertEqual(container.alphaValue, 0,
                       "the editor is the visible text before the card is level: "
                       + "axis-aligned glyphs over a card still up to 1.2° off, so "
                       + "the words snap straight the instant the writer clicks. "
                       + "The likeliest cause is a frame delta that is really a "
                       + "resume — see CanvasView.maximumFrameStep")
        XCTAssertTrue(window.firstResponder === container.textView,
                      "invisible must not mean unfocused — that is the whole "
                      + "reason the mount is not gated on the straighten")

        pump(0.4)
        XCTAssertEqual(container.alphaValue, 1,
                       "the editor never became visible: the straighten clock this "
                       + "view owns is not running, so the writer is typing into an "
                       + "editor that stays invisible for the whole visit")
    }

    /// The container's box in SwiftUI's coordinate space — top-left origin, y
    /// downward, which is the space `CanvasCamera` maps into. `CanvasView`
    /// positions the container at `camera.viewPoint(fromContent: textOrigin)` and
    /// sizes it `textSize * camera.zoom`, so this one rect carries both camera
    /// terms and a before/after pair recovers the zoom.
    private func swiftUIFrame(of view: NSView, in root: NSView) -> CGRect {
        let f = view.convert(view.bounds, to: root)
        guard !root.isFlipped else { return f }
        return CGRect(x: f.minX, y: root.bounds.height - f.maxY,
                      width: f.width, height: f.height)
    }

    /// How many pixels inside `box` are something other than bare ground.
    ///
    /// The drawn layer is a `Canvas`: a card is not a view, has no frame and is
    /// not in the hierarchy at all, so "is the card on the canvas" can only be
    /// asked of the pixels. Card paper and the ground resolve to nearly the same
    /// colour, so what this actually counts is the card's border stroke and its
    /// glyphs — which is the right thing to count, since both are absent exactly
    /// when the card is not drawn.
    ///
    /// `box` is in the same SwiftUI space `swiftUIFrame` returns. The hosting
    /// view is flipped, so a bitmap row IS a point y; the scale comes from the
    /// rep rather than from `backingScaleFactor` so a Retina and a 1x machine
    /// both read the same box.
    private func ink(in box: CGRect, of hosted: NSView) throws -> Int {
        let rep = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds),
                                "the hosted canvas could not be rasterised")
        hosted.cacheDisplay(in: hosted.bounds, to: rep)
        XCTAssertTrue(hosted.isFlipped,
                      "the hosting view is no longer flipped, so bitmap rows and "
                      + "SwiftUI y no longer agree and every box below is upside down")
        let scale = CGFloat(rep.pixelsWide) / hosted.bounds.width

        func brightness(_ x: Int, _ y: Int) -> CGFloat? {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        // Bare ground, read from a corner the fixture puts no card near.
        let ground = try XCTUnwrap(brightness(rep.pixelsWide - 8, rep.pixelsHigh - 8),
                                   "could not read the canvas ground")

        var count = 0
        let x0 = max(0, Int(box.minX * scale)), x1 = min(rep.pixelsWide, Int(box.maxX * scale))
        let y0 = max(0, Int(box.minY * scale)), y1 = min(rep.pixelsHigh, Int(box.maxY * scale))
        // Every other pixel in each axis: a quarter of the reads, and the border
        // stroke and the glyph stems are both wider than one pixel at 2x.
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                if let b = brightness(x, y), abs(b - ground) > 0.04 { count += 1 }
            }
        }
        return count
    }

    /// A pinch inside the MOUNTED editor must zoom about the canvas point under
    /// the writer's fingers.
    ///
    /// `CanvasCompositionTests.test_theFocusedEditorsPinchAnchorGoesThroughTheGeometryMapper`
    /// greps this view's source for the name `ScrapEditorGeometry.viewPoint`.
    /// That grep passes just as happily if the mapped point is computed and then
    /// dropped and the raw editor-space point is handed to the camera — which
    /// compiles, and zooms about a point the writer never touched. Nothing else
    /// in the plan drives `applyMagnify` on a mounted container at all, so the
    /// mapper could be reduced to dead code without a single test going red.
    ///
    /// The invariant is stated rather than the arithmetic reproduced: the canvas
    /// point under the fingers does not move on screen. Under the wiring this
    /// pins, the anchor is the container's origin plus the editor point scaled by
    /// the zoom, and that lands on the same view point before and after. Handing
    /// the camera the raw editor point instead anchors at (100,10) rather than
    /// (130,40) and shifts it by 15 points in each axis.
    func test_pinchingInsideAMountedEditorAnchorsOnTheCanvasPointUnderTheFingers() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let root = try XCTUnwrap(window.contentView)
        let container = try doubleClickTheScrap(in: window)
        XCTAssertEqual(container.alphaValue, 1,
                       "precondition: the straighten has finished, so this editor "
                       + "is the view a real pinch would land on")

        let before = swiftUIFrame(of: container, in: root)
        // The fixture's card is at (20,20) 240 wide, so its text box is 220 wide
        // at a text origin of (30,30). Seeing exactly that is what says the
        // camera is still at identity, and therefore that the pre-pinch zoom
        // below is 1.
        XCTAssertEqual(before.origin.x, 30, accuracy: 0.5)
        XCTAssertEqual(before.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(before.width, 220, accuracy: 0.5,
                       "precondition: nothing has moved the camera off identity")

        // Inside the editor, well away from its own origin — an anchor bug that
        // drops the text-origin translation is invisible at (0,0).
        let editorPoint = CGPoint(x: 100, y: 10)
        container.applyMagnify(magnification: 0.5, atEditorPoint: editorPoint)
        pump()

        let after = swiftUIFrame(of: container, in: root)
        let zoom = after.width / before.width
        XCTAssertEqual(zoom, 1.5, accuracy: 0.01,
                       "precondition: the pinch never reached the camera at all")

        XCTAssertEqual(after.origin.x + editorPoint.x * zoom,
                       before.origin.x + editorPoint.x, accuracy: 0.5,
                       "the pinch anchored somewhere other than the canvas point "
                       + "under the fingers — the editor hands back a point in its "
                       + "OWN space and it has to go through "
                       + "ScrapEditorGeometry.viewPoint first")
        XCTAssertEqual(after.origin.y + editorPoint.y * zoom,
                       before.origin.y + editorPoint.y, accuracy: 0.5,
                       "the pinch anchored somewhere other than the canvas point "
                       + "under the fingers, on the y axis")
    }

    // MARK: - Drags, and what a card does after one

    /// **A press in the resize corner that never moves must not delete the card
    /// from the canvas.**
    ///
    /// `CanvasScene.setWidth` clears `cachedHeight` on every `.changed`,
    /// identical width or not, and a node with no height has no `frame` — so it
    /// is invisible to `topmostNode(at:)`, to `nodes(intersecting:)` and to the
    /// renderer at once. The card is still in the scene and gone from the
    /// surface, and `rebuildLayouts()` has three call sites, none of which the
    /// writer can reach without reloading the view.
    ///
    /// It takes a `mouseDragged:` delivered at exactly the `mouseDown` point to
    /// get there, which is why the unit test that describes the state —
    /// `CanvasInteractionTests.test_aResizeSampleAtThePressPointStillClearsTheCachedHeight`
    /// — cannot see the consequence. This drives the whole path and asks the
    /// question the writer asks: click the card again, is it the same card?
    func test_aCornerPressThatNeverMovedLeavesTheCardOnTheCanvas() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Where the corner square is depends on the card's MEASURED height, so
        // read it off the surface rather than writing the font metrics down
        // twice: the mounted editor's box is the card's text box, inset on all
        // four sides.
        let textBox = swiftUIFrame(of: try doubleClickTheScrap(in: window), in: hosted)
        let cardCorner = CGPoint(x: textBox.maxX + CanvasCardMetrics.inset,
                                 y: textBox.maxY + CanvasCardMetrics.inset)
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)   // click away
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump()

        // Press inside the corner square, deliver one drag sample at exactly the
        // press point, release.
        let press = CGPoint(x: cardCorner.x - 2, y: cardCorner.y - 2)
        drag(events, from: press, through: [press])
        pump()

        let editor = try XCTUnwrap(try doubleClickTheScrap(in: window).textView)
        XCTAssertEqual(editor.string, scrapText,
                       "the card vanished: a zero-distance resize left it with no "
                       + "measured height, so the hit test no longer finds it and "
                       + "double-clicking where it sits makes a NEW scrap on top of "
                       + "the writer's words")
        XCTAssertEqual(savedScene(after: window, root: root).count, 1,
                       "the canvas has two scraps where the writer made one")
    }

    /// **The card must stay on the canvas for the WHOLE of a resize, not just
    /// after the writer lets go.**
    ///
    /// Every other resize test in this file asserts after `.ended`, and the
    /// re-measure that lands there hides the middle of the gesture completely.
    /// What the writer reported from the 1C-a smoke is the middle: "the entire
    /// card disappears and suddenly reappears when released". `setWidth` clears
    /// `cachedHeight` on every `.changed`, so between the first drag sample and
    /// the release the node has no `frame` — invisible to `topmostNode(at:)`, to
    /// `nodes(intersecting:)` and to the renderer at once — and a card that
    /// vanishes while being resized tells the writer nothing about the size they
    /// are choosing.
    ///
    /// Read in PIXELS because there is nothing else to read: the cards are drawn
    /// into a `Canvas`, so a card has no view, no frame and no accessibility
    /// element that is fresh mid-gesture (the tree is keyed on `sceneRevision`,
    /// which a drag frame must not bump). `ScrapEditorHostTests` rasterises the
    /// same way.
    ///
    /// The drag NARROWS the card, so the last assertion can ask a stronger
    /// question than "is anything drawn": the fixture rewraps from 2 lines to 4
    /// at the floor, so ink below where the 2-line card used to end can only be
    /// there if the height was re-derived from a real re-layout during the drag.
    /// That is the live rewrap the handle exists to show, and the band is
    /// asserted EMPTY first so the ink found during the drag is provably new.
    ///
    /// It uses `rewrappingScrapProjectRoot()`, not the shared fixture, and that
    /// is load-bearing: `scrapText` is 94.62pt wide and fits on one line even in
    /// the 100pt text box of a card at the floor, so against it this assertion
    /// would be demanding a rewrap the fixture cannot produce. See
    /// `rewrappingScrapText` for both measurements.
    func test_aCardBeingResizedStaysOnTheCanvasForTheWholeDrag() throws {
        let root = try rewrappingScrapProjectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // The card's box, read off the surface rather than recomputed from font
        // metrics: the mounted editor's frame IS the text box, inset on all four
        // sides. Then click away so the drag below is a resize and not a text
        // selection inside a focused scrap.
        let textBox = swiftUIFrame(of: try doubleClickTheScrap(in: window), in: hosted)
        let cardBox = textBox.insetBy(dx: -CanvasCardMetrics.inset,
                                      dy: -CanvasCardMetrics.inset)
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump()

        XCTAssertGreaterThan(try ink(in: cardBox, of: hosted), 0,
                             "precondition: the card is drawn at all before anything "
                             + "is dragged")

        // Below where the 2-line card ends, and clear of the tilt (a card sits up
        // to 0.6° off level, which moves an edge by ~2pt over this width).
        let wrapBand = CGRect(x: cardBox.minX, y: cardBox.maxY + 4, width: 120, height: 24)
        XCTAssertEqual(try ink(in: wrapBand, of: hosted), 0,
                       "precondition: nothing is drawn below the card yet, so ink "
                       + "found there during the drag can only be the card having "
                       + "grown")

        // Press in the corner square and drag left to the narrow end — and DO NOT
        // release. This is the state the writer complained about, and the state
        // no other test in this file ever looks at.
        //
        // The press is 2pt inside the corner, so the width this lands on is 122,
        // not the 120 floor itself. Measured: the card is 88pt tall at every
        // width from 124 down to 120, so the band below reads the same either
        // way — see `rewrappingScrapText`.
        let press = CGPoint(x: cardBox.maxX - 2, y: cardBox.maxY - 2)
        events.applyMouseDown(at: press, clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: cardBox.minX + 120, y: press.y))
        pump(0.05)

        let narrowed = CGRect(x: cardBox.minX, y: cardBox.minY,
                              width: 120, height: cardBox.height)
        XCTAssertGreaterThan(try ink(in: narrowed, of: hosted), 0,
                             "the card is not on the canvas while the writer is "
                             + "resizing it: `setWidth` cleared the cached height on "
                             + "the first `.changed` and nothing refills it until "
                             + "`.ended`, so the card blinks out for the whole drag "
                             + "and reappears on release")

        XCTAssertGreaterThan(try ink(in: wrapBand, of: hosted), 0,
                             "the card is drawn at its old height while being "
                             + "narrowed, so the writer cannot see the text rewrap "
                             + "as they drag — the height has to be re-derived from "
                             + "the live re-layout, not carried over")

        events.applyMouseUp(at: CGPoint(x: cardBox.minX + 120, y: press.y))
        pump()
    }

    /// §7.3, on the real surface: a card let go while moving carries on and comes
    /// to rest, rather than stopping dead where the pointer released it.
    ///
    /// This is also the control for the two tests around it. A staleness guard on
    /// the flick velocity (`CanvasInteraction.maximumFlickAge`) has a failure mode
    /// that no "the card did not move" assertion can see: set it too tight and
    /// nothing ever flicks, which passes those tests and deletes the feature.
    ///
    /// The arithmetic is a geometric series and therefore frame-rate independent:
    /// 10 pt/frame decaying by 0.8 carries `10 * (1 - 0.8^14) / 0.2` ≈ 47.8 pt
    /// past the release point, wherever the clock happens to tick. A coast that
    /// had not finished would leave the drag's own payload queued — the card at
    /// exactly 40 — so a short pump fails this rather than fudging it.
    func test_aFlickCarriesTheCardOnPastWhereThePointerLetGo() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Grab the card at (60,40) — on it, and well clear of the resize corner —
        // and throw it 20pt right, the last frame carrying 10.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        pump(1.0)

        let node = try XCTUnwrap(savedScene(after: window, root: root).node(scrapID))
        XCTAssertEqual(node.origin.x, 87.8, accuracy: 1.0,
                       "the card stopped dead at 40, where the pointer let go — "
                       + "§7.3's coast is the one thing this surface exists to get "
                       + "right, and a velocity guard that disarms it is worse than "
                       + "no guard at all")
        XCTAssertEqual(node.origin.y, 20, accuracy: 0.5,
                       "a flick along x sent the card off its own line")
    }

    /// **Any press stops a coast, including the one that enters a scrap.**
    ///
    /// The press that enters is the SECOND of a double-click, and the first can
    /// itself launch a flick: AppKit opens a drag session on every mouse-down,
    /// its double-click distance tolerance is wider than nothing, and the launch
    /// floor is half a point per frame. Miss this and the editor is mounted on a
    /// card that is still travelling — the text box slides across the canvas
    /// under the writer's cursor as `body` recomputes.
    ///
    /// That the flick this test relies on really does launch is
    /// `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo`, immediately above,
    /// on the identical gesture.
    func test_thePressThatEntersAScrapStopsTheCardCoastingUnderIt() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        // No pump: enter the card before the coast has carried it anywhere, the
        // way the second press of a double-click arrives.
        events.applyMouseDown(at: CGPoint(x: 100, y: 40), clickCount: 2)
        events.applyMouseUp(at: CGPoint(x: 100, y: 40))
        pump(0.05)

        let container = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                      "the double-click mounted no editor")
        let mounted = swiftUIFrame(of: container, in: hosted)
        // The card was released at x = 40 and the editor sits at its text origin,
        // one inset in.
        XCTAssertEqual(mounted.origin.x, 50, accuracy: 0.5,
                       "the card was already travelling when the editor mounted on "
                       + "it — the press that entered the scrap did not stop the "
                       + "coast")

        pump(0.5)
        XCTAssertEqual(swiftUIFrame(of: container, in: hosted).origin.x,
                       mounted.origin.x, accuracy: 0.5,
                       "the editor is sliding across the canvas while the writer "
                       + "types into it: the card kept coasting underneath the "
                       + "mounted editor")
    }

    // MARK: - Accessibility, §7A.6

    /// Attach an assistive client to this process, once.
    ///
    /// **Nothing below can see anything without this, and it is not a formality.**
    /// SwiftUI does not build an accessibility tree until something asks for one.
    /// Measured 2026-07-26: an `NSHostingView` whose subtree contains a real,
    /// mounted `NSTextView` reports ZERO accessibility children, and reports both
    /// that text view and its synthetic nodes the instant an accessibility
    /// request reaches the process. So a walk run without this reports an empty
    /// canvas whatever `CanvasView` installs — it would fail this task's tests
    /// while the feature worked, and would go on failing them if the feature were
    /// deleted. In the app the client is VoiceOver; in a unit test there is none,
    /// so the test is the client.
    ///
    /// One attribute query against our OWN pid is the whole lever, and it needs
    /// no permission: `AXIsProcessTrusted()` is false in this process and the
    /// query still succeeds, because trust gates reading OTHER applications.
    /// Three cheaper things were measured and do NOT work — waiting (any
    /// duration), `NSAccessibility.unignoredDescendant(of:)`, and the legacy
    /// `accessibilityAttributeValue:` selector, which answers a request without
    /// realising the tree behind it.
    ///
    /// `static let` so it happens once: enabling accessibility is process-global
    /// and cannot be undone.
    private static let assistiveClientIsAttached: Bool = {
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                          kAXRoleAttribute as CFString, &role)
        return true
    }()

    /// Every accessibility element under the window's content view, in tree
    /// order — the tree an assistive client walks, which is the only place the
    /// question "can a VoiceOver user reach this" can honestly be asked.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        _ = Self.assistiveClientIsAttached
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        return [root] + axChildren(of: root)
            .flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// Read through the ObjC selectors rather than `NSAccessibilityProtocol`, and
    /// not for convenience.
    ///
    /// SwiftUI's synthetic elements are `SwiftUI.AccessibilityNode`: not
    /// `NSView`s, so `firstDescendant` above cannot see them, and — measured —
    /// not satisfying `as? NSAccessibilityProtocol` either, so a walk written
    /// against that protocol drops silently exactly the elements this task
    /// exists to publish. It answers the informal `NSAccessibility` selectors
    /// every `NSObject` vends, which is how the accessibility runtime asks.
    private func axChildren(of element: AnyObject) -> [AnyObject] {
        axAttribute(element, "accessibilityChildren") as? [AnyObject] ?? []
    }

    private func axString(_ element: AnyObject, _ attribute: String) -> String? {
        axAttribute(element, attribute) as? String
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    /// Three cards at known, different places, so the published frames have
    /// something to be compared against — including one at (90 000, 90 000),
    /// which no viewport will ever hold.
    private func threeCardProjectRoot() throws -> URL {
        var scene = CanvasScene()
        for (id, origin) in [(scrapID, CGPoint(x: 20, y: 20)),
                             (secondScrapID, CGPoint(x: 400, y: 300)),
                             (farScrapID, CGPoint(x: 90_000, y: 90_000))] {
            scene.insert(CanvasNode(id: id, kind: .scrap, origin: origin,
                                    width: 240, cachedHeight: 60))
        }
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText,
                                                      secondScrapID: secondScrapText,
                                                      farScrapID: farScrapText])
    }

    private func axElement(valued value: String, in tree: [AnyObject]) throws -> AnyObject {
        try XCTUnwrap(tree.first { axString($0, "accessibilityValue") == value },
                      "no element in the published accessibility tree carries "
                      + "\"\(value)\", so that card is not reachable at all")
    }

    /// Where an assistive client would actually point, in the space
    /// `CanvasAXElement.viewFrame(in:)` speaks.
    ///
    /// A published `accessibilityFrame` is in SCREEN coordinates with y UP; the
    /// element list is in the hosted root's SwiftUI space with y DOWN. Both
    /// conversions are here rather than in the assertions so that a test reading
    /// `(20, 20)` is reading the same numbers the fixture wrote.
    private func viewFrame(ofPublished element: AnyObject, in window: NSWindow) throws -> CGRect {
        let boxed = try XCTUnwrap(axAttribute(element, "accessibilityFrame") as? NSValue,
                                  "the element publishes no accessibilityFrame at all, "
                                  + "so an assistive client has a label and a value and "
                                  + "nowhere to point")
        let root = try XCTUnwrap(window.contentView)
        let inRoot = root.convert(window.convertFromScreen(boxed.rectValue), from: nil)
        guard !root.isFlipped else { return inRoot }
        return CGRect(x: inRoot.minX, y: root.bounds.height - inRoot.maxY,
                      width: inRoot.width, height: inRoot.height)
    }

    /// **Where, not just what.** Every other assertion on this layer reads a
    /// label, a value or a role — words. The one thing an assistive client needs
    /// beyond the words is the rectangle to point at, and until this test nothing
    /// read one.
    ///
    /// The failure it exists to catch is silent: `CanvasAXChildren` places each
    /// child with `.position`, at coordinates that routinely fall far outside the
    /// container's bounds. If SwiftUI resolved those positions to nothing, every
    /// element would land on the same rect, every word-reading test above would
    /// still pass, and VoiceOver would read the canvas out perfectly while
    /// pointing its cursor at one spot for all of it. The plan declined the
    /// `.scaleEffect` alternative for being unverified on exactly this point; this
    /// is the chosen mechanism meeting the same standard.
    ///
    /// The fixture's card is at content (20, 20) 240 wide and the camera is at
    /// identity, so the view frame IS the content frame. Height is asserted only
    /// to be real: it is measured from the font at load, not written by the
    /// fixture.
    func test_aCardsPublishedFrameLandsWhereTheCardIsDrawn() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let card = try axElement(valued: scrapText, in: try axTree(in: window))
        let frame = try viewFrame(ofPublished: card, in: window)

        XCTAssertEqual(frame.origin.x, 20, accuracy: 0.5,
                       "the published frame is not where the card is drawn, so an "
                       + "assistive cursor points somewhere the writer's card is not")
        XCTAssertEqual(frame.origin.y, 20, accuracy: 0.5,
                       "the published frame is not where the card is drawn on the y "
                       + "axis — the likeliest cause is a flip between SwiftUI's "
                       + "y-down space and AppKit's y-up screen coordinates")
        XCTAssertEqual(frame.width, 240, accuracy: 0.5,
                       "the published frame is not the size of the card")
        XCTAssertGreaterThan(frame.height, 0,
                             "the card publishes a zero-height rectangle: reachable "
                             + "in the tree and impossible to point at")
    }

    /// The same failure from the other side, and the cheaper half of it: if
    /// `.position` inside an `.accessibilityChildren` builder were ignored, every
    /// card would resolve to one rect. Two cards the fixture put in different
    /// places must not publish the same rectangle.
    func test_twoCardsInDifferentPlacesPublishDifferentFrames() throws {
        let window = host(CanvasView(projectRoot: try threeCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let tree = try axTree(in: window)
        let first = try viewFrame(ofPublished: try axElement(valued: scrapText, in: tree),
                                  in: window)
        let second = try viewFrame(ofPublished: try axElement(valued: secondScrapText, in: tree),
                                   in: window)

        XCTAssertNotEqual(first, second,
                          "two cards 380pt apart publish the SAME accessibility "
                          + "frame — VoiceOver reads the canvas out correctly and "
                          + "points its cursor at one spot for the whole of it")
        XCTAssertGreaterThan(second.minX, first.minX,
                             "the card the fixture placed to the right does not "
                             + "publish a frame to the right")
        XCTAssertGreaterThan(second.minY, first.minY,
                             "the card the fixture placed below does not publish a "
                             + "frame below")
    }

    /// A press that stops a coast leaves the card somewhere the tree has never
    /// heard of, and this is what makes it hear.
    ///
    /// `sceneRevision` is bumped for a coast in exactly two places: when the
    /// timeline's rest branch runs, and — because a press truncates the coast so
    /// that branch never runs — at `handleDrag(.began)`. Until the fix wave that
    /// added this test the second was covered by accident: `commitActiveEdit`
    /// bumped the counter on EVERY mouse-down, which is the per-click tree
    /// rebuild that guard now prevents. Take the `.began` bump out and this test
    /// reads the card at the point the writer let go, up to `maximumLaunchSpeed`
    /// away from where it is drawn.
    ///
    /// Both preconditions are load-bearing and fail loudly rather than passing
    /// vacuously: the card must have MOVED since the release (or nothing was
    /// coasting) and must be short of the ~87.8 that
    /// `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo` measures for the
    /// identical throw (or the coast finished on its own and the rest branch,
    /// not this one, refreshed the tree).
    func test_aPressThatStopsACoastRefreshesTheAccessibilityFrame() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The throw the flick test measures: released at x = 40, ~47.8 pt of
        // coast ahead of it over ~14 frames.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        // A few frames of it, and no more — a live coast keeps the runloop fed,
        // so this really does return after 30 ms rather than when it runs dry.
        pump(0.03)
        // Bare canvas, far from the card: the press stops the coast and starts
        // no drag of its own.
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump(0.2)

        let published = try viewFrame(
            ofPublished: try axElement(valued: scrapText, in: try axTree(in: window)),
            in: window)
        let drawn = try XCTUnwrap(savedScene(after: window, root: root).node(scrapID))

        XCTAssertGreaterThan(drawn.origin.x, 44,
                             "precondition: the flick never carried the card past "
                             + "the point it was released at, so there was no coast "
                             + "for the press to stop and this test measures nothing")
        XCTAssertLessThan(drawn.origin.x, 82,
                          "precondition: the coast reached its own resting place "
                          + "before the press arrived, so the timeline's rest branch "
                          + "refreshed the tree and the press had nothing to do")
        XCTAssertEqual(published.origin.x, drawn.origin.x, accuracy: 1.0,
                       "the accessibility frame is where the writer LET GO of the "
                       + "card, not where the press stopped it — an assistive cursor "
                       + "points at empty ground, and stays wrong until some other "
                       + "structural change happens to rebuild the tree")
    }

    /// Decision 1, asked of the published tree rather than of the list.
    /// `CanvasAccessibilityTests.test_offscreenNodesAreStillInTheTree` proves
    /// `elements` returns the far card; that says nothing about whether SwiftUI
    /// keeps a synthetic child whose frame is 90 000 points outside the
    /// container's bounds. Culling is a drawing optimisation, and a node you
    /// cannot see is still a node you must be able to reach.
    func test_aCardFarOutsideTheViewportIsStillInThePublishedTree() throws {
        let window = host(CanvasView(projectRoot: try threeCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        XCTAssertNoThrow(try axElement(valued: farScrapText, in: try axTree(in: window)),
                         "the card at (90 000, 90 000) is in the element list and not "
                         + "in the tree the window publishes, so a VoiceOver user can "
                         + "only reach what happens to be on screen — and cannot pan "
                         + "to the rest without being able to reach it first")
    }

    /// The state a new writer meets first, and the one state where the synthetic
    /// layer has nothing to publish. An `.accessibilityChildren` builder that
    /// produces ZERO children must still leave the canvas itself in the tree,
    /// saying what it is and how to start — otherwise the empty canvas is the
    /// blank rectangle §7A.6 is about, on the one screen where a writer most
    /// needs to be told where they are.
    ///
    /// **`accessibilityValueDescription`, and not `accessibilityValue` — and that
    /// is a fact about AppKit rather than a weakened assertion.** Measured against
    /// a hosted window on 2026-07-26: a view carrying `.accessibilityChildren`
    /// publishes role `AXGroup`, and that group *responds* to `accessibilityValue`
    /// and answers **nil**, while `accessibilityValueDescription` holds the whole
    /// of the string `.accessibilityValue(_:)` was given. Four spellings were
    /// tried to move it — `.isStaticText` before the children modifier,
    /// `.isStaticText` after it, `.accessibilityElement(children: .contain)`, and
    /// value-with-no-label — and all four publish `AXGroup` with the string in the
    /// same slot. The only thing that changes the role at all is dropping
    /// `.accessibilityChildren`, which deletes every card from the tree.
    ///
    /// It is **not** a zero-children effect, and the neighbouring test rather than
    /// this comment is what says so: a canvas holding one scrap files its own
    /// summary in the identical slot, and
    /// `test_theCanvasReadsOutItsScrapsRatherThanBeingABlankRectangle` asserts that
    /// beside a card's `accessibilityValue`. So the two are different slots for
    /// different roles, not a right one and a wrong one — `AXValue` is where an
    /// `AXStaticText` card's words go (that is what `CanvasAXChildren`'s trait is
    /// for), and `AXValueDescription` is the only value slot a group has.
    func test_anEmptyCanvasStillAnnouncesItselfInThePublishedTree() throws {
        let window = host(CanvasView(projectRoot: try emptyProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let canvas = try XCTUnwrap(
            try axTree(in: window).first {
                axString($0, "accessibilityLabel") == CanvasAccessibility.canvasLabel
            },
            "an empty canvas is not in the accessibility tree at all: a children "
            + "builder that produced no children took the canvas element with it, so "
            + "a VoiceOver user opening a new project lands on nothing")
        XCTAssertEqual(axString(canvas, "accessibilityValueDescription"),
                       CanvasAccessibility.emptyCanvasValue,
                       "the empty canvas is in the tree but says nothing — the one "
                       + "screen where a writer needs to be told how to begin")
    }

    /// **The whole of spec §7A.6 in one assertion.** Everything on this surface
    /// is drawn into a `Canvas`, and drawn content has no accessibility tree —
    /// so without the synthetic one a VoiceOver user meets a blank rectangle
    /// where the writer's entire plan is. Nothing else in the plan can see this:
    /// `CanvasAccessibilityTests` proves the element LIST is right, and the fact
    /// that a list is right says nothing about whether SwiftUI's hosting
    /// hierarchy ever publishes it.
    func test_theCanvasReadsOutItsScrapsRatherThanBeingABlankRectangle() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let all = try axTree(in: window)

        let canvas = try XCTUnwrap(
            all.first { axString($0, "accessibilityLabel") == CanvasAccessibility.canvasLabel },
            "the canvas itself is not in the accessibility tree, so there "
            + "is nothing for a VoiceOver user to land on and walk")
        // The canvas's own SUMMARY, and the only assertion anywhere that it
        // reaches the tree at all. `accessibilityValueDescription` because this
        // element carries `.accessibilityChildren` and is therefore an AXGroup,
        // whose `accessibilityValue` is nil however the value is spelled — the
        // measurement is written out on
        // `test_anEmptyCanvasStillAnnouncesItselfInThePublishedTree`. Asserting it
        // HERE, on a canvas that is not empty, is what makes that test's reading of
        // the same slot a fact about groups rather than about emptiness.
        //
        // The literal, not `CanvasAccessibility.summary(scene:)`: the words a
        // writer hears are the thing under test, and deriving them from the
        // implementation would assert nothing.
        XCTAssertEqual(axString(canvas, "accessibilityValueDescription"), "1 item",
                       "the canvas is in the tree and does not say how much is on "
                       + "it — a VoiceOver user lands on \"Planning canvas\" with no "
                       + "idea whether there is one card here or forty")
        // `accessibilityValue`, deliberately, and not "wherever the words ended
        // up". It is the slot the real NSTextView publishes its text in and the
        // slot VoiceOver reads; an element that files the writer's sentence under
        // AXValueDescription instead announces "Scrap" and stops. See the trait
        // in `CanvasAXChildren` — that failure was real, and this is what caught it.
        XCTAssertTrue(all.compactMap { axString($0, "accessibilityValue") }.contains(scrapText),
                      "the writer's scrap is drawn and nothing else — its synthetic "
                      + "element never reached the accessibility tree, so VoiceOver "
                      + "reads this canvas out as a blank rectangle (spec §7A.6)")
    }

    /// The other half of the slice's hand-smoke: *entering one lands you in a
    /// real text field*.
    ///
    /// Task 9 proved the mounted text view is among `ScrapEditorContainer`'s
    /// accessibility children, and said plainly that this is NOT evidence it is
    /// usefully reachable. Three things separate the two, and each is a way a
    /// writer using VoiceOver would be stuck on a surface whose unit tests are
    /// all green:
    ///
    ///  1. the editor is reachable from the hosted WINDOW, not merely from the
    ///     container that built it — `.accessibilityChildren` on the drawn layer
    ///     replaces children, and applying it a level too high would replace the
    ///     editor's;
    ///  2. it announces itself as EDITABLE TEXT, not as an unlabelled group;
    ///  3. it is where the keyboard focus actually is, so entering a scrap moves
    ///     an assistive client's focus into it rather than leaving it parked on
    ///     the synthetic twin of the card.
    func test_enteringAScrapLandsAssistiveFocusInARealTextField() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)

        let reachable = try axTree(in: window).contains { $0 === editor }
        XCTAssertTrue(reachable,
                      "the mounted editor is not reachable in the accessibility "
                      + "tree the window publishes — the synthetic children have "
                      + "been installed somewhere that replaces it, so entering a "
                      + "scrap lands a VoiceOver user on nothing they can type into")

        XCTAssertEqual(editor.accessibilityRole(), .textArea,
                       "the thing entering a scrap lands on does not announce "
                       + "itself as editable text")
        XCTAssertEqual(editor.accessibilityValue() as? String, scrapText,
                       "the editor is reachable but says nothing — a text field "
                       + "that reads out empty is no better than the drawn card")

        // Read through KVC, and not for convenience. `accessibilityFocusedUIElement`
        // is an ObjC @property on the informal NSAccessibility protocol, and in
        // Swift a STATIC member of the same name shadows it on every instance:
        // `window.accessibilityFocusedUIElement()` fails with "static member
        // cannot be used on instance of type 'NSWindow'", and casting to
        // `NSAccessibilityProtocol` fails with "has no member" because the Swift
        // protocol does not surface it at all. Both spellings were tried.
        //
        // KVC reaches the real published property rather than a stand-in for it,
        // which matters here: asserting `window.firstResponder` instead would test
        // the INPUT to AX focus rather than what assistive technology is actually
        // handed. Verified against a standalone probe: with an NSTextView as first
        // responder, this returns that text view.
        //
        // Through `axAttribute` rather than a bare `value(forKey:)`, and for the
        // reason the rest of this file goes through it: on a key that ever stops
        // existing, bare KVC raises NSUnknownKeyException, which Swift cannot
        // catch — so the failure mode is this whole test process dying and taking
        // every other test in it down, instead of this one assertion failing with
        // the message below.
        let focused = axAttribute(window, "accessibilityFocusedUIElement").map { $0 as AnyObject }
        XCTAssertTrue(focused === editor,
                      "assistive focus is not in the editor after entering the "
                      + "scrap, so a VoiceOver user is left on the synthetic twin "
                      + "of a card whose real text field is elsewhere")
    }

    // MARK: - The words are safe

    /// The product constitution's must #1 and the smoke that gates this slice:
    /// type a sentence and quit WITHOUT clicking away first.
    ///
    /// `.onDisappear` does not fire on ⌘Q, so this passes only if this view binds
    /// `CanvasStore.beforeFlush` — the one commit point no other test can reach.
    /// Without it the store writes whatever the last debounce queued, which is
    /// the scrap as it was before the writer typed.
    func test_typingThenQuittingWithoutClickingAwayKeepsTheSentence() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)

        editor.insertText(" — and nobody there",
                          replacementRange: NSRange(location: (editor.string as NSString).length,
                                                    length: 0))
        pump(0.05)

        let scrapsURL = root.appendingPathComponent(CanvasStore.scrapsRelativePath)
        XCTAssertFalse(try String(contentsOf: scrapsURL, encoding: .utf8).contains("nobody there"),
                       "precondition: the 750 ms debounce has not fired yet, so what "
                       + "follows tests the quit hook rather than the timer")

        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event — this is what CanvasStore observes for quit
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared)

        XCTAssertTrue(try String(contentsOf: scrapsURL, encoding: .utf8).contains("nobody there"),
                      "quitting mid-sentence lost the sentence — the store wrote the "
                      + "last debounced payload instead of the live editor's text")
    }

    /// The other teardown, and the one the plan flagged for review: closing a
    /// single window relies on `.onDisappear` running before the store dies. ⌘Q
    /// is covered above by the store's own termination hook; this is the path
    /// that has nothing but `.onDisappear`.
    func test_typingThenLeavingTheCanvasKeepsTheSentence() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)

        editor.insertText(" — sodium light",
                          replacementRange: NSRange(location: (editor.string as NSString).length,
                                                    length: 0))
        pump(0.05)

        let scrapsURL = root.appendingPathComponent(CanvasStore.scrapsRelativePath)
        XCTAssertFalse(try String(contentsOf: scrapsURL, encoding: .utf8).contains("sodium light"),
                       "precondition: the debounce has not fired yet")

        window.contentView = NSView(frame: .zero)
        pump()

        XCTAssertTrue(try String(contentsOf: scrapsURL, encoding: .utf8).contains("sodium light"),
                      "leaving the canvas mid-sentence lost the sentence — a persona "
                      + "switch or a closed window drops whatever was being typed")
    }

    // MARK: - ⌘Z, on the real surface

    /// One character at a time, at the end of the text, so every keystroke fires
    /// its own `textDidChange` — which is where `syncActiveEdit` asks
    /// `ScrapUndoBeat` its two questions. A single `insertText` of the whole run
    /// would be ONE change and would test nothing about coalescing.
    private func type(_ text: String, into editor: NSTextView) {
        for character in text {
            let end = (editor.string as NSString).length
            editor.insertText(String(character), replacementRange: NSRange(location: end, length: 0))
        }
    }

    /// Whatever the writer is looking at, after a rebind has replaced the text
    /// view underneath the container.
    private func mountedText(in window: NSWindow) throws -> String {
        let hosted = try XCTUnwrap(window.contentView)
        let container = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                      "the editor is no longer mounted — an undo that "
                                      + "throws the writer out of the scrap is not the "
                                      + "behaviour any of this describes")
        return try XCTUnwrap(container.textView).string
    }

    /// Read what the debounce has written, WITHOUT taking the window down. The
    /// undo path schedules a save of its own, so a pump past the 750 ms debounce
    /// is enough — and unlike `savedScene(after:root:)` it can be asked twice in
    /// one test, which is what makes the drag assertions below non-vacuous.
    private func sceneOnDisk(_ root: URL) -> CanvasScene {
        CanvasStore(projectRoot: root).load().scene
    }

    /// `ScrapUndoBeat`'s sentence rule, running for real. The rule itself is unit
    /// tested in `CanvasUndoTests`; what only this view can show is that anything
    /// ASKS it, and that it is asked AFTER the keystroke is folded in.
    ///
    /// Three sentences typed in one visit must be three ⌘Z steps, and the first
    /// ⌘Z must leave the earlier sentences standing. Every pump here is a
    /// twentieth of `ScrapUndoBeat.idleSeconds`, so the idle rule cannot fire and
    /// the boundaries under test are the full stops and nothing else.
    ///
    /// ⌘Z is pressed WITHOUT clicking away first, so this also drives the
    /// mid-visit re-baseline and the layout swap: `applySnapshot` rebuilds the
    /// focused scrap's `ScrapLayout`, and the mounted editor has to come back
    /// bound to the new one rather than showing the words the undo discarded.
    func test_undoInsideAScrapTakesBackASentenceAtATime() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        type(".", into: editor)                       // finishes the fixture's line
        pump(0.05)
        type(" Rain on the ponchos.", into: editor)
        pump(0.05)
        type(" Nobody buying them.", into: editor)
        pump(0.05)

        let whole = scrapText + ". Rain on the ponchos. Nobody buying them."
        XCTAssertEqual(try mountedText(in: window), whole,
                       "precondition: all three sentences were typed, so an "
                       + "unchanged string below means ⌘Z did nothing rather than "
                       + "that there was nothing to take back")

        container.undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText + ". Rain on the ponchos.",
                       "one ⌘Z inside a scrap did not take back exactly one "
                       + "sentence: the whole visit collapsing into one step is the "
                       + "per-visit granularity this task rejected, and a single "
                       + "character is the per-keystroke one")

        container.undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText + ".")

        container.undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText,
                       "the third ⌘Z did not reach the text the writer clicked into "
                       + "the scrap with")
    }

    /// The idle rule, running for real — and specifically that it is asked BEFORE
    /// the keystroke is folded in.
    ///
    /// Nothing here ends a sentence, so the full-stop rule cannot fire and the
    /// only thing that can put a boundary between the two runs is the pause. The
    /// step that closes must end exactly where the writer stopped: ask the rule
    /// after the fold instead and it ends one character later, swallowing the
    /// first keystroke of what came next.
    func test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        type(" and the sodium light", into: editor)
        // `waitOut`, not `pump`: this is the one assertion in the file that turns
        // on WALL CLOCK elapsing. `pump` returns when the loop runs dry — measured
        // 0.76 s for a requested 1.8 — and then the idle beat never passes, one ⌘Z
        // takes back both runs, and the test below fails on a machine that is
        // merely busy.
        waitOut(ScrapUndoBeat.idleSeconds + 0.3)       // the writer sits back
        type(" on the wet stone", into: editor)
        pump(0.05)

        XCTAssertEqual(try mountedText(in: window),
                       scrapText + " and the sodium light on the wet stone",
                       "precondition: both runs were typed")

        container.undo(nil)
        pump()
        let afterUndo = try mountedText(in: window)
        XCTAssertEqual(afterUndo, scrapText + " and the sodium light",
                       "a pause mid-sentence did not end the undo step — with no "
                       + "full stop anywhere in this visit, the idle beat is the "
                       + "only thing that can, and without it one ⌘Z takes back "
                       + "everything typed since the writer clicked in")
        XCTAssertFalse(afterUndo.hasSuffix(" "),
                       "the step that closed swallowed the first character of what "
                       + "came after the pause — the idle rule was asked AFTER the "
                       + "keystroke was folded in rather than before it")
    }

    /// The drag bracket, and the decision that the coast lives outside it: one ⌘Z
    /// returns the card to where the writer picked it up, not to where it stopped
    /// skating.
    ///
    /// Read through the debounce rather than by taking the window down, so the
    /// moved position and the restored one can both be asserted — otherwise "the
    /// card is at 20" passes just as well on a drag that never happened.
    func test_undoAfterADragPutsTheCardBackWhereTheWriterPickedItUp() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        pump(1.2)                                   // the coast finishes, then the debounce

        let moved = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertGreaterThan(moved.origin.x, 60,
                             "precondition: the card really moved, so the assertion "
                             + "below is about the undo rather than about a drag that "
                             + "never took")

        let manager = try XCTUnwrap(events.undoManager,
                                    "the event view vends no undo manager, so ⌘Z with "
                                    + "nothing focused reaches the window's stack")
        XCTAssertTrue(manager.canUndo, "the drag registered no undo step at all")
        manager.undo()
        pump(1.2)

        let restored = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(restored.origin.x, 20, accuracy: 0.5,
                       "⌘Z did not put the card back where it was picked up — a drag "
                       + "that scatters an arrangement with no way back is the single "
                       + "most likely way this surface loses a writer's trust")
        XCTAssertEqual(restored.origin.y, 20, accuracy: 0.5)
    }

    /// A press that never became a drag opened a gesture at `.began` all the same.
    /// If that gesture is not closed, the next real drag nests inside it and two
    /// gestures collapse into one ⌘Z; if it IS closed but registers a step, ⌘Z
    /// after a stray click undoes the writer's last real edit while appearing to
    /// do nothing.
    ///
    /// Both are the same assertion from outside: after a press that moved
    /// nothing, there is nothing to undo.
    func test_aPressThatNeverMovedLeavesNothingToUndo() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // On the card, well clear of the resize corner, and released without ever
        // leaving the press point.
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 60, y: 40))
        pump()

        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo,
                       "a click that moved nothing left a step on the stack: the "
                       + "writer's next ⌘Z appears to do nothing, and the one after "
                       + "it takes back an edit they had forgotten about")

        // And the gesture it opened really did close — a second press that DOES
        // move must be a step of its own rather than a continuation of the first.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 65, y: 40), CGPoint(x: 66, y: 40)])
        pump()
        XCTAssertTrue(manager.canUndo,
                      "the drag that followed the stray press registered nothing — "
                      + "it was swallowed by a gesture the press left open")
    }

    /// **The live editor stays usable through the window where its `ScrapLayout`
    /// has been replaced and SwiftUI has not rebound yet.**
    ///
    /// ⌘Z inside a scrap runs `applySnapshot` → `rebuildLayouts()`, which
    /// overwrites `layouts[id]` and releases the `ScrapLayout` the mounted
    /// `NSTextView` was built from — synchronously, a whole update pass before
    /// `ScrapEditorHost.updateNSView` sees the new identity and remounts. A
    /// display or layout pass landing in that window meets whatever the view was
    /// left holding, and `test_undoInsideAScrapTakesBackASentenceAtATime` only
    /// ever looks after a `pump()`, so it says nothing about it.
    ///
    /// `ScrapLayoutTests.test_theMountedEditorOutlivesTheScrapLayoutThatBuiltIt`
    /// is the isolated measurement — an `NSTextView` owns its TextKit 2 stack, so
    /// nothing is dangling. This is the same claim through a real ⌘Z on the real
    /// surface, which is where a SwiftUI or AppKit change would show up first.
    /// Between them they are why `rebuildLayouts` documents this as safe rather
    /// than warning against it.
    func test_anUndoInsideAScrapLeavesItsLiveEditorUsableBeforeTheRebind() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type(". Rain.", into: editor)
        pump(0.05)
        let textContainer = try XCTUnwrap(editor.textContainer)

        container.undo(nil)
        // NO pump. Everything below is inside the window.

        XCTAssertTrue(container.textView === editor,
                      "precondition: SwiftUI has not rebound yet, so this really is "
                      + "the window between the layout swap and the remount")
        XCTAssertNotNil(textContainer.textLayoutManager,
                        "the mounted view's container lost its layout manager when "
                        + "the undo replaced the scrap's ScrapLayout, so anything "
                        + "that lays this view out in the next moment has nothing "
                        + "to lay it out with")
        XCTAssertNotNil(editor.textStorage,
                        "the storage the writer is typing into was deallocated "
                        + "underneath the live editor")
        XCTAssertEqual(editor.string, scrapText + ". Rain.",
                       "the mounted view cannot read its own text mid-window — it "
                       + "still shows the words the undo discarded, which is right, "
                       + "and the rebind below is what replaces them")

        // A display and a layout pass, which is what would actually arrive here.
        editor.layoutSubtreeIfNeeded()
        editor.needsDisplay = true
        editor.displayIfNeeded()
        _ = editor.selectedRange()

        pump()
        XCTAssertEqual(try mountedText(in: window), scrapText + ".",
                       "the rebind never happened, so the writer is looking at the "
                       + "sentence ⌘Z was supposed to take back")
    }

    /// **Undoing away the focused scrap must take the writer out of it**, which
    /// is the smoke's own three-keystroke sequence: double-click bare canvas,
    /// type, ⌘Z, ⌘Z.
    ///
    /// The second ⌘Z removes the node the writer is standing in. `mountedEditor`
    /// guards on `scene.node(id)`, so the editor unmounts and the strandedness is
    /// invisible — `editingNodeID`, `caretIndex` and `straighten` all go on naming
    /// a node that no longer exists. ⇧⌘Z is where it becomes visible: the card
    /// comes back and that stale focus silently drops the writer inside a text
    /// editor they never clicked into, caret placed, with the next keystroke
    /// going into the scrap rather than to the canvas.
    ///
    /// This is the state `handleClick`'s `.unenterableNode` case already refuses
    /// to leave standing, reached from the undo path instead of the click path.
    func test_undoingAwayTheFocusedScrapTakesTheWriterOutOfIt() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Bare canvas, well clear of the fixture's card at (20,20)–(260,80).
        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 2)
        pump(0.3)
        let created = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                    "a double-click on bare canvas made no scrap, so "
                                    + "there is no New Scrap step to undo past")
        type("Rain.", into: try XCTUnwrap(created.textView))
        pump(0.05)

        // ⌘Z — takes back the typing. The editor is still mounted afterwards, on a
        // rebound text view, so the container is re-found rather than reused.
        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump()
        XCTAssertEqual(try mountedText(in: window), "",
                       "precondition: the first ⌘Z took back the typing and left the "
                       + "writer in the new, empty scrap")

        // ⌘Z again — takes back the card the writer is standing in.
        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump(1.0)
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: hosted),
                     "precondition: the second ⌘Z removed the focused scrap, so the "
                     + "editor is gone")
        XCTAssertEqual(sceneOnDisk(root).count, 1,
                       "precondition: the new card really is off the canvas, so the "
                       + "redo below is a real redo")

        // ⇧⌘Z, through the manager the event view vends — there is no editor left
        // to route it, which is the writer's position too.
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertTrue(manager.canRedo, "precondition: there is something to redo")
        manager.redo()
        pump(1.0)

        XCTAssertEqual(sceneOnDisk(root).count, 2,
                       "precondition: ⇧⌘Z brought the card back")
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: hosted),
                     "⇧⌘Z brought the card back and put the writer inside it, caret "
                     + "and all, without their ever clicking into it: the undo that "
                     + "removed the scrap left `editingNodeID` naming it, so the "
                     + "editor remounts the moment the node exists again and the "
                     + "next keystroke goes into the scrap instead of to the canvas")
    }

    /// The same sequence asked the other way: after undoing away the scrap the
    /// writer was in, the canvas still responds to a drag.
    ///
    /// **This passes with the focus reconciliation removed, and saying so is the
    /// point.** The reconciliation looks, from outside, like the thing that keeps
    /// drags alive — `handleDrag`'s `.began` bails at
    /// `guard editingNodeID == nil`, so a stranded id reads like a canvas that
    /// ignores every drag until the writer clicks. It is not, and measured
    /// against the unfixed code this test was green: `CanvasEventNSView`'s
    /// `applyMouseDown` runs `onClick` strictly before `onDrag(.began)` — a
    /// documented contract in that file — so a drag cannot BEGIN without
    /// `handleClick` having cleared the stale id microseconds earlier, in the
    /// same call. The sibling test above is the one that can fail on the
    /// reconciliation.
    ///
    /// What this pins is that the two defences do not BOTH go. Measured by
    /// mutation: reordering those two callbacks alone leaves it green (the
    /// reconciliation covers it), removing the reconciliation alone leaves it
    /// green (the ordering covers it), and removing both fails it here with
    /// `("20.0") is not equal to ("60.0")` — the card never moved.
    /// The sequence is the hand-smoke's, which is why it is asked at all.
    func test_undoingBackPastANewScrapLeavesTheCanvasRespondingToDrags() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 2)
        pump(0.3)
        let created = try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                                    "a double-click on bare canvas made no scrap")
        type("Rain.", into: try XCTUnwrap(created.textView))
        pump(0.05)

        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump()
        try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted)).undo(nil)
        pump()

        // Drag the fixture's card 40pt right, with the last two samples identical
        // so nothing flicks and the assertion is about the drag alone.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 40)])
        pump(1.0)

        let dragged = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(dragged.origin.x, 60, accuracy: 0.5,
                       "the card did not move after an undo took away the scrap the "
                       + "writer was in — the likeliest cause is `onClick` no longer "
                       + "running before `onDrag(.began)`, which is what clears the "
                       + "stale `editingNodeID` before the drag guard reads it")
    }

    /// **⌘Z during a coast must not leave the card somewhere the writer never put
    /// it.** The coast steps `scene` directly, frame by frame, outside any
    /// gesture; an undo that restores the pick-up point without stopping it hands
    /// the momentum a fresh starting position and the card skates off from there —
    /// and that resting place is what reaches disk.
    ///
    /// The window is the ~1 s after a flick, which is exactly when a writer who
    /// did not mean that throw reaches for ⌘Z.
    func test_undoDuringACoastLeavesTheCardWhereTheWriterPickedItUp() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The flick `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo` measures:
        // 10 pt on the last frame, carrying ≈47.8 pt past the release point.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 70, y: 40), CGPoint(x: 80, y: 40)])
        // NO pump: the coast is live and has travelled nothing yet, which is the
        // moment this test is about.
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertTrue(manager.canUndo, "precondition: the drag registered a step")
        manager.undo()
        pump(1.2)                       // a surviving coast finishes, then the debounce

        let restored = try XCTUnwrap(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(restored.origin.x, 20, accuracy: 0.5,
                       "⌘Z put the card back and the coast then carried it away "
                       + "again, so it came to rest somewhere the writer never put "
                       + "it — and that is the position that reached disk")
    }

    /// The same rule in the RESIZE branch, where it is easier to get wrong.
    ///
    /// `CanvasScene.setWidth` clears `cachedHeight` on every `.changed`, identical
    /// width or not, so between the press and `rebuildLayouts()` the card has no
    /// height — and `CanvasNode` is `Equatable` including that field. Close the
    /// gesture before the re-measure rather than after and the snapshot diff is
    /// "card with a height" against "card with none", which are different, so a
    /// corner press that never moved leaves a step behind.
    ///
    /// The geometry is `test_aCornerPressThatNeverMovedLeavesTheCardOnTheCanvas`'s,
    /// which is the same gesture asked a different question: that one asks whether
    /// the card survives, this one asks whether ⌘Z was quietly spent on it.
    func test_aCornerPressThatNeverMovedLeavesNothingToUndo() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Read the corner off the surface rather than writing the font metrics
        // down twice — the mounted editor's box is the card's text box, inset.
        let textBox = swiftUIFrame(of: try doubleClickTheScrap(in: window), in: hosted)
        let cardCorner = CGPoint(x: textBox.maxX + CanvasCardMetrics.inset,
                                 y: textBox.maxY + CanvasCardMetrics.inset)
        events.applyMouseDown(at: CGPoint(x: 600, y: 500), clickCount: 1)   // click away
        events.applyMouseUp(at: CGPoint(x: 600, y: 500))
        pump()

        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo, "precondition: nothing on the stack yet")

        let press = CGPoint(x: cardCorner.x - 2, y: cardCorner.y - 2)
        drag(events, from: press, through: [press])
        pump()

        XCTAssertFalse(manager.canUndo,
                       "a corner press that never moved left a step on the stack — "
                       + "⌘Z is spent on it and appears to do nothing, and its redo "
                       + "re-applies a card with no measured height, which has no "
                       + "frame and so vanishes from the canvas entirely")

        // The positive control. Without it a resize path that registered NOTHING
        // EVER — no `beginGesture` in `.began`, say — would satisfy the assertion
        // above and delete ⌘Z from the corner handle in silence. Its sibling
        // `test_aPressThatNeverMovedLeavesNothingToUndo` has had one since it was
        // written; this one did not.
        drag(events, from: press, through: [CGPoint(x: press.x + 40, y: press.y)])
        pump()
        XCTAssertTrue(manager.canUndo,
                      "a resize that really widened the card registered nothing, so "
                      + "the assertion above passes for the wrong reason: the corner "
                      + "handle has no undo at all")
    }

    // MARK: - ⌘Z, through the Edit menu

    /// Find the object AppKit would send a nil-targeted Edit-menu action to.
    ///
    /// **`NSApp.target(forAction:to:from:)` cannot be used here, and that is a
    /// fact about the test process rather than a shortcut.** It resolves through
    /// `NSApp.keyWindow`, and a test host that is never activated has none —
    /// measured 2026-07-27: it returns nil with the canvas first responder in an
    /// ordered-front window. So this does the walk AppKit does, from the window's
    /// first responder up `nextResponder` to the first object that RESPONDS to
    /// the selector. That object is the one AppKit validates against and the one
    /// it sends to, which is the whole of what a menu item does.
    private func editMenuTarget(_ selector: Selector, in window: NSWindow) -> NSObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: selector) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    /// The Edit menu item for `selector`, resolved and validated the way AppKit
    /// does — including letting the validator rewrite the item's `title`, which
    /// is how "Undo" becomes "Undo Move Scrap".
    private func editMenuItem(_ selector: Selector,
                              in window: NSWindow) throws -> (item: NSMenuItem,
                                                              target: NSObject,
                                                              isEnabled: Bool) {
        let item = NSMenuItem(title: "Undo", action: selector, keyEquivalent: "z")
        let target = try XCTUnwrap(editMenuTarget(selector, in: window),
                                   "nothing in the responder chain responds to "
                                   + "\(selector) at all, so AppKit greys the Edit "
                                   + "menu item out and the keystroke does nothing")
        item.target = target
        guard let validator = target as? NSUserInterfaceValidations else {
            return (item, target, true)
        }
        return (item, target, validator.validateUserInterfaceItem(item))
    }

    /// **⌘Z must be reachable with NO scrap focused**, which is the 1C-a
    /// hand-smoke defect: "undo is available but only when a scrap is focussed
    /// and in edit mode".
    ///
    /// Every other undo test in this slice drives the recorder or the manager
    /// directly — `container.undo(nil)`, `manager.undo()` — so twenty-two of them
    /// pass while the writer's ⌘Z does nothing at all. What is untested is the
    /// app's real delivery path: an Edit-menu item with a nil target, resolved
    /// against the responder chain, VALIDATED, and only then sent. All three
    /// steps are asked here, because the failure was in the first two.
    ///
    /// The measured before-state, with the drag below on the stack: the chain
    /// walk found `NSWindow` (nothing nearer responded to `undo:`),
    /// `NSWindow.validateUserInterfaceItem` returned **false**, and performing
    /// the action left the card where the drag had put it. `CanvasEventNSView`
    /// held an `undoManager` override and nothing else, and an `undoManager`
    /// override alone does not put an action in the responder chain.
    func test_undoIsReachableFromTheEditMenuWithNoScrapFocused() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // A real step on the canvas's own stack: 40pt right, last two samples
        // identical so nothing flicks and the assertion is about the undo.
        drag(events, from: CGPoint(x: 60, y: 40),
             through: [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 40)])
        pump(1.0)
        XCTAssertEqual(try XCTUnwrap(sceneOnDisk(root).node(scrapID)).origin.x, 60,
                       accuracy: 0.5,
                       "precondition: the card really moved, so there is something "
                       + "for the menu to take back")
        XCTAssertTrue(try XCTUnwrap(events.undoManager).canUndo,
                      "precondition: the drag left a step on the canvas's own stack, "
                      + "so what follows is about REACHING it rather than about "
                      + "whether it exists")

        // What a click on bare canvas does. `CanvasEventNSView.mouseDown(with:)`
        // claims first responder; the testable seam `drag` goes through does no
        // event-level responder work (synthesizing `NSEvent`s is unreliable — see
        // that file), so the claim is made here in its place.
        XCTAssertTrue(window.makeFirstResponder(events),
                      "the canvas cannot hold first responder, so a writer who "
                      + "clicks out of a scrap has no ⌘Z at all")
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self, in: hosted),
                     "precondition: no scrap is focused — this is exactly the state "
                     + "the writer reported undo greyed out in")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.target === events,
                      "the Edit menu's Undo resolves to \(undo.target) rather "
                      + "than to the canvas: an `undoManager` override does not put "
                      + "`undo:` in the responder chain, so the action walks past the "
                      + "canvas to the window and drives the window's stack instead")
        XCTAssertTrue(undo.isEnabled,
                      "Undo is greyed out on a canvas with a move on its stack — the "
                      + "writer's report, exactly: the feature is built, tested and "
                      + "unreachable unless a scrap happens to be focused")
        XCTAssertTrue(undo.item.title.contains("Move Scrap"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming the "
                      + "gesture it will take back — the action never reaches "
                      + "NSWindow, so nothing else retitles it")

        // Sent the way the menu sends it, to the target the walk found.
        _ = undo.target.perform(undoSelector, with: undo.item)
        pump(1.2)
        XCTAssertEqual(try XCTUnwrap(sceneOnDisk(root).node(scrapID)).origin.x, 20,
                       accuracy: 0.5,
                       "the Edit menu's Undo was enabled and did nothing to the "
                       + "canvas — it is wired to some other stack")

        // The other half of the pair, which nothing else asks through the menu.
        let redo = try editMenuItem(#selector(CanvasEventNSView.redo(_:)), in: window)
        XCTAssertTrue(redo.target === events,
                      "⇧⌘Z does not resolve to the canvas even though ⌘Z does")
        XCTAssertTrue(redo.isEnabled,
                      "there is nothing to redo straight after an undo, so ⇧⌘Z is "
                      + "greyed out and the writer cannot take the undo back")
        XCTAssertTrue(redo.item.title.contains("Move Scrap"),
                      "the Redo item reads \"\(redo.item.title)\" rather than naming the "
                      + "gesture it will re-apply")
    }

    /// **The undo stack is bounded.** `UndoManager`'s default `levelsOfUndo` is
    /// 0, meaning unlimited, and every step here retains a whole `CanvasScene`
    /// plus every scrap's text — at one step per SENTENCE typed. Unbounded, a
    /// long session's stack is tens of megabytes that nothing gives back until
    /// the window closes.
    ///
    /// Asked of the manager the surface actually vends, not of a manager the test
    /// built: a cap set on the wrong object bounds nothing.
    func test_theCanvasUndoStackIsBounded() throws {
        let window = host(CanvasView(projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let manager = try XCTUnwrap(try eventView(in: window).undoManager)
        XCTAssertGreaterThan(manager.levelsOfUndo, 0,
                             "levelsOfUndo is 0 — UndoManager's default, which means "
                             + "UNLIMITED. Every canvas step retains a copy of the "
                             + "whole scene and of every scrap's string, and nothing "
                             + "drops any of it until the window closes")
        XCTAssertFalse(manager.groupsByEvent,
                       "the shipping manager is not the one the unit tests exercise: "
                       + "with groupsByEvent on, two gestures landing in one pass of "
                       + "the event loop collapse into a single ⌘Z")
    }

    /// **`syncActiveEdit`'s `fromKeystroke` default is `false`, and quitting is
    /// what it is for.**
    ///
    /// `CanvasStore.beforeFlush` runs at app quit and folds the live editor's
    /// text in — that is how a sentence typed and never clicked away from reaches
    /// disk. What it must NOT do is move an undo boundary: a writer who paused
    /// for two seconds and then pressed ⌘Q would trip the idle rule there,
    /// closing a step and REOPENING a gesture on a view that is going away.
    ///
    /// **The setup has to make the model STALE, and that is the whole difficulty.**
    /// `syncActiveEdit` returns at its "nothing changed" guard when `scraps[id]`
    /// already equals the live layout's text — which it does after every
    /// keystroke, because `onTextChanged` folds on every one. So the boundary
    /// rules are simply never reached at flush time on the ordinary path, and
    /// that is exactly why flipping the default left the whole suite green: there
    /// was nothing to fold, so nothing to break a step on.
    ///
    /// The state `beforeFlush` is written for is text sitting in the shared
    /// `NSTextStorage` that never came through `onTextChanged`, so this test
    /// constructs it the only honest way — by detaching the delegate for the
    /// duration of the edit, which is what "the model is behind the storage"
    /// means in one line. Everything after that is the production path.
    ///
    /// The ORDER of the two waits is load-bearing and was measured, not guessed.
    /// `CanvasStore`'s 750 ms save debounce calls the same `beforeFlush` hook, and
    /// 750 ms is inside `ScrapUndoBeat.idleSeconds` — so a stale edit made before
    /// the debounce fires is folded at 0.75 s, with the beat not yet elapsed, and
    /// the rule under test is never reached. Let the debounce go first; the stale
    /// edit that follows schedules none of its own, so the next fold is the quit.
    func test_quittingAfterAPauseFoldsTheTextInWithoutMovingAnUndoBoundary() throws {
        let root = try projectRoot()
        let window = host(CanvasView(projectRoot: root, paletteSwatchHexes: { [] }))
        let container = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(container.textView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        // One run, no terminator anywhere, so only a pause could ever close it.
        type(" and the sodium light", into: editor)
        waitOut(1.0)                                   // the save debounce goes first
        let manager = try XCTUnwrap(try eventView(in: window).undoManager)
        XCTAssertFalse(manager.canUndo,
                       "precondition: the whole visit is still inside the open "
                       + "gesture, so the manager's stack is empty")

        // Behind the delegate's back, so the model is left holding the text as it
        // was — the condition the quit hook exists to fold in.
        let delegate = editor.delegate
        editor.delegate = nil
        editor.insertText(" on the wet stone",
                          replacementRange: NSRange(
                            location: (editor.string as NSString).length, length: 0))
        editor.delegate = delegate
        waitOut(ScrapUndoBeat.idleSeconds + 0.3)       // the writer sits back
        XCTAssertFalse(manager.canUndo, "precondition: still nothing registered")

        NotificationCenter.default.post(   // adr-0021-ok: AppKit lifecycle notification, not a maugham.* event — this is what CanvasStore observes for quit
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared)

        let scrapsURL = root.appendingPathComponent(CanvasStore.scrapsRelativePath)
        XCTAssertTrue(try String(contentsOf: scrapsURL, encoding: .utf8).contains("wet stone"),
                      "precondition: the quit hook really did fold the text in, so "
                      + "the assertion below is about what it did NOT do")
        XCTAssertFalse(manager.canUndo,
                       "quitting after a pause closed an undo step and reopened a "
                       + "gesture on a view that is going away — `beforeFlush` took "
                       + "`fromKeystroke: true`, and only a real keystroke may move "
                       + "an undo boundary")
    }
}
