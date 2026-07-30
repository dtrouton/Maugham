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

    /// One measured card at (20,20)–(260,58), centre (140,39), and one region
    /// wherever the caller wants it — for the two tests that drag a region onto
    /// a card it must not absorb. The card is NOT a member: what those tests
    /// watch is whether a transition makes it one.
    private func cardAndRegionRoot(regionFrame: CGRect) throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 20, y: 20),
                                width: 240, cachedHeight: 38))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: regionFrame))
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText])
    }

    /// The fixture scrap at (60,60), owned by a region at (20,20).
    ///
    /// The card is clear of the region's 24pt chrome bar, so a press on the bar
    /// is unambiguously a press on the region — `topmostNode(at:)` is asked
    /// first and a card overlapping the chrome would win.
    private func regionProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 60, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText])
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
        host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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

        // Below where the 2-line card ends, and clear of BOTH the drop shadow and
        // the tilt.
        //
        // **The tilt term is derived now, and it has to be.** The clearance was a
        // hand-tuned 4pt, which worked only because this card's seed happened to
        // land near level; 1C-c3 gave every card the writer made a minimum lean
        // (`CanvasMaterial.minimumTiltDegrees`, so that *straight* can mean
        // Claude), this card's angle grew several-fold, and its lower corner came
        // down into the band — 33 ink pixels against a precondition of zero. A
        // literal here is a test that depends on one id's hash.
        //
        // `cardBox` is the UNROTATED box (it is read off the mounted editor's
        // frame, which is bounds-scaled and axis-aligned), so the corner furthest
        // from the centre drops by `halfWidth · sin θ` at the calibrated maximum.
        // The remaining 5pt is the shadow, radius 3 at offset (1, 2).
        let tiltDrop = cardBox.width / 2
            * CGFloat(sin(CanvasMaterial.maximumTiltDegrees * .pi / 180))
        let wrapBand = CGRect(x: cardBox.minX, y: cardBox.maxY + tiltDrop + 5,
                              width: 120, height: 24)
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try threeCardProjectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try threeCardProjectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try emptyProjectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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

    /// The other half of what a delete has to reach: `canvas.md` is the ONLY
    /// place a scrap's words live, so a card removed from the scene while its
    /// text stays behind leaves an orphan paragraph in the writer's file.
    private func scrapsOnDisk(_ root: URL) -> [CanvasNodeID: String] {
        CanvasStore(projectRoot: root).load().scraps
    }

    /// A real ⌫, built the way AppKit delivers one. `charactersIgnoringModifiers`
    /// is what `CanvasEventNSView.keyDown` switches on, so it is what this has to
    /// carry, and the window number is what lets `window.sendEvent(_:)` route it.
    private func deleteKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                         isARepeat: false, keyCode: 51)!
    }

    /// A single click on the canvas, plus the first-responder claim that goes
    /// with it.
    ///
    /// `applyMouseDown` is the testable seam and does no event-level responder
    /// work — synthesizing AppKit mouse events is unreliable, which is the whole
    /// reason that seam exists (see `CanvasEventView`) — so the claim
    /// `CanvasEventNSView.mouseDown(with:)` makes is made here in its place.
    /// `test_undoIsReachableFromTheEditMenuWithNoScrapFocused` does the same
    /// thing for the same reason. **The key event itself is not simulated this
    /// way**: it goes through `window.sendEvent(_:)`, which is the point.
    private func clickAndFocusTheCanvas(_ events: CanvasEventNSView,
                                        at point: CGPoint,
                                        in window: NSWindow) {
        events.applyMouseDown(at: point, clickCount: 1)
        events.applyMouseUp(at: point)
        XCTAssertTrue(window.makeFirstResponder(events),
                      "the canvas cannot hold first responder, so no key the "
                      + "writer presses can ever reach it")
        pump()
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: try projectRoot(),
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
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root, paletteSwatchHexes: { [] }))
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

    // MARK: - Regions, through the real event view

    /// **The other half of `CanvasRegionInteractionTests`, and the half that
    /// would have caught both of 1C-a's shipped defects.** That file drives the
    /// state machine directly; these four drive a real `CanvasEventNSView`
    /// through the same `mouseDown`/`mouseDragged`/`mouseUp` seam the AppKit
    /// overrides call, and assert on what reached disk through the real
    /// debounced save. A gesture that never reaches `handleDrag`, or a routing
    /// change that sends it somewhere else, is invisible to the state machine's
    /// own tests and fails here.
    ///
    /// `pump(1.0)`, not `waitOut`: the 750 ms save debounce is itself a
    /// scheduled run-loop source, so `pump` really does wait for it — and
    /// nothing below turns on wall clock elapsing with the loop empty, which is
    /// the one thing `waitOut` is for.
    func test_aDragOnBareCanvasDrawsARegionThatReachesDisk() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 400, y: 300),
             through: [CGPoint(x: 600, y: 460), CGPoint(x: 600, y: 460)])
        pump(1.0)

        let regions = sceneOnDisk(root).regions
        XCTAssertEqual(regions.count, 1,
                       "a drag on bare canvas made no region: 1C-a documents an "
                       + "empty-canvas drag as a no-op, so nothing but this task's "
                       + "wiring can turn it into the create gesture")
        XCTAssertEqual(regions.first?.frame.width, 200)
        XCTAssertEqual(regions.first?.frame.height, 160)
        XCTAssertTrue(regions.first!.homeMembers.isEmpty,
                      "a sweep over BARE canvas took something in. The fixture's "
                      + "card is (20,20)–(260,58) with its centre at (140,39) and "
                      + "this rect starts at (400,300), so there was nothing to "
                      + "absorb — the absorbing case is the test below")
        XCTAssertEqual(model.selection, .region(regions.first!.id),
                       "the region the writer just drew is not selected, so the "
                       + "inspector in the other column has nothing to name it with")
    }

    /// **Creation absorbs, on the delivery path** (Denver, 2026-07-28) — and one
    /// ⌘Z takes back the region and every membership it made, as ONE step.
    ///
    /// The step's NAME is asserted, not only the scene after the undo: a scene
    /// assertion alone cannot tell one step from two that happen to compose, and
    /// two would leave a ⌘Z that appears to do nothing. `canUndo` going false
    /// afterwards is the other half of the same claim — the stack held exactly
    /// one thing.
    func test_sweepingAroundACardTakesItInAndOneUndoTakesBackBoth() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let manager = try XCTUnwrap(events.undoManager)
        XCTAssertFalse(manager.canUndo, "precondition: nothing on the stack yet")

        // The fixture's card is (20,20)–(260,58), centre (140,39). Sweep from
        // bare canvas below-left of it, up and around it — backwards and
        // upwards, so this also drives the normalised rect on the real path.
        drag(events, from: CGPoint(x: 320, y: 240),
             through: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)])
        pump(1.0)

        let region = try XCTUnwrap(sceneOnDisk(root).regions.first,
                                   "the sweep made no region at all")
        XCTAssertTrue(region.livesHere(scrapID),
                      "the writer drew a box around a card and the card did not "
                      + "join it — creation absorbs (2026-07-28); it is move and "
                      + "resize that change nothing")

        XCTAssertTrue(manager.canUndo)
        XCTAssertTrue(manager.undoMenuItemTitle.contains("New Region"),
                      "the Edit menu offers \"\(manager.undoMenuItemTitle)\" — the "
                      + "absorption was registered under some other name, or in a "
                      + "bracket of its own")
        manager.undo()
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0, "⌘Z left the region behind")
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 20, y: 20),
                       "the card was moved by a gesture that only drew a box "
                       + "around it")
        XCTAssertFalse(manager.canUndo,
                       "a second step is on the stack, so the region and the "
                       + "membership it created were TWO ⌘Zs — the writer presses "
                       + "it once, sees the box go, presses it again expecting "
                       + "their last edit back and instead re-runs a membership "
                       + "change they cannot see")
    }

    /// **A scrap made inside a region belongs to it**, on the delivery path.
    ///
    /// The double-click is the create gesture, so this is the second half of the
    /// 2026-07-28 ruling — and the ordering it depends on is invisible from
    /// outside: a new scrap has no measured height until `rebuildLayouts()`, so
    /// asking `joinTarget` one line earlier reads a card with no frame and joins
    /// nothing, on every scrap the writer ever makes.
    func test_aScrapMadeInsideARegionJoinsIt() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // Inside the region (20,20)–(420,300) and clear of its resident card at
        // (60,60)–(300,98), so this is bare canvas *within* the region.
        events.applyMouseDown(at: CGPoint(x: 60, y: 150), clickCount: 2)
        pump(0.3)
        type("Rain.", into: try XCTUnwrap(
            try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                          "the double-click made no scrap").textView))
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.count, 2, "precondition: the new scrap exists")
        let made = try XCTUnwrap(onDisk.unorderedNodes.first { $0.id != scrapID }).id
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.livesHere(made),
                      "a scrap made inside a region did not join it — the likeliest "
                      + "cause is asking joinTarget before rebuildLayouts(), where "
                      + "the new card has no frame and so has no centre")
    }

    /// **The half that did NOT change, asked on the delivery path.** Creation
    /// absorbs; a MOVE still takes nothing in, and neither does a resize.
    ///
    /// This is the property most at risk from the 2026-07-28 ruling: the obvious
    /// way to implement absorption is a rule in `setRegionFrame`, which would
    /// pass every creation test here and quietly hand tldraw's, Obsidian's and
    /// Scapple's bugs back at once.
    func test_draggingARegionOverACardStillTakesNothingIn() throws {
        // The card at (20,20)–(260,58); the region starts clear of it, down and
        // to the right, and is dragged up over it.
        let root = try cardAndRegionRoot(regionFrame: CGRect(x: 300, y: 200,
                                                             width: 300, height: 200))
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Grab the chrome bar at (400,210) — grab offset (100,10) — and carry
        // the region to the origin, where it covers the card entirely.
        drag(events, from: CGPoint(x: 400, y: 210),
             through: [CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 10)])
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        let region = try XCTUnwrap(onDisk.region(CanvasRegionID("r1")))
        XCTAssertEqual(region.frame.origin, CGPoint(x: 0, y: 0),
                       "precondition: the drag landed where this test needs it")
        XCTAssertTrue(region.frame.contains(onDisk.node(scrapID)!.frame!),
                      "precondition: the region was dragged clean over the card")
        XCTAssertFalse(region.livesHere(scrapID),
                       "a region dragged over a card absorbed it — §4.2's firewall "
                       + "still holds for TRANSITIONS, which is the half all three "
                       + "of the tools it cites were bitten on")
    }

    /// The other transition, and the one with a shipped bug behind it: tldraw
    /// #6017 ejected children on resize. This is the same rule from the opposite
    /// side — growing a region over a card must not take it in either.
    func test_resizingARegionOverACardStillTakesNothingIn() throws {
        // A small region at the origin, up and to the left of the card, so
        // growing its bottom-right corner sweeps it over the card's centre.
        let root = try cardAndRegionRoot(regionFrame: CGRect(x: 0, y: 0,
                                                             width: 100, height: 100))
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The corner square is (86,86)–(100,100), which is below the card's
        // bottom edge at y 58, so the press reaches the region rather than the
        // card that overlaps its chrome.
        drag(events, from: CGPoint(x: 94, y: 94),
             through: [CGPoint(x: 300, y: 200), CGPoint(x: 300, y: 200)])
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        let region = try XCTUnwrap(onDisk.region(CanvasRegionID("r1")))
        XCTAssertEqual(region.frame, CGRect(x: 0, y: 0, width: 306, height: 206),
                       "precondition: the corner really was dragged out — a resize "
                       + "holds the origin and moves the far corner")
        XCTAssertTrue(region.frame.contains(onDisk.node(scrapID)!.frame!),
                      "precondition: and the region now covers the card entirely")
        XCTAssertFalse(region.livesHere(scrapID),
                       "a resized region absorbed a card — creation absorbs and "
                       + "transitions do not, and a resize that changes membership "
                       + "is tldraw #6017 with the sign flipped")
    }

    /// **The rubber band is on screen for the WHOLE sweep, not after it.**
    ///
    /// This is the shape of 1C-a's resize defect asked of the new gesture: every
    /// other assertion about drawing a region looks after `.ended`, and the
    /// middle of the gesture is the only part the writer actually steers by.
    /// With nothing drawn there is no way to tell a drag that is sweeping out a
    /// region from a drag that is doing nothing.
    ///
    /// Read in PIXELS because there is nothing else to read: the sweep is not in
    /// the model at all — it lives in `CanvasInteraction`, has no view, no frame
    /// and no accessibility element — so `CanvasRegionRenderTests` can pin the
    /// renderer and only this can pin that anything ever hands it the rect.
    ///
    /// **It does NOT cover the `revision` counter, and an earlier draft of this
    /// comment claimed it did.** Measured: deleting `revision += 1` from
    /// `handleDrag(.changed)` leaves this test and all its neighbours green.
    /// `.changed` mutates `interaction`, which is `@State`, so the mutation is
    /// itself an invalidation and the redraw arrives either way. The band was
    /// never a client of that counter in the first place — `CanvasView` reads it
    /// in `body` and passes it as a view ARGUMENT, so it is recomputed on any
    /// invalidated pass. Nothing here can pin the counter; do not write that it
    /// does.
    func test_theSweptRegionOutlineIsOnScreenForTheWholeDrag() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // A strip along where the sweep's LEFT edge will run — bare ground now,
        // and well clear of the fixture's card at (20,20)–(260,58) and of the
        // corner `ink` samples the ground brightness from.
        let onTheEdge = CGRect(x: 148, y: 220, width: 6, height: 80)
        XCTAssertEqual(try ink(in: onTheEdge, of: hosted), 0,
                       "precondition: nothing is drawn along this line yet, so ink "
                       + "found there during the drag can only be the sweep")

        // Press on bare canvas and drag out a 300×200 rect — and DO NOT release.
        // This is the state the writer steers by, and the state nothing else in
        // this file ever looks at.
        events.applyMouseDown(at: CGPoint(x: 150, y: 150), clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: 450, y: 350))
        pump(0.05)

        XCTAssertGreaterThan(try ink(in: onTheEdge, of: hosted), 0,
                             "the writer is sweeping out a region and the canvas shows "
                             + "nothing at all until they let go — a gesture with no "
                             + "feedback is indistinguishable from a gesture that is "
                             + "not happening")

        // …and it is GONE once the region exists, replaced by the region's own
        // outline. A band that outlived its gesture would leave a dashed ghost
        // on the canvas for the rest of the session.
        events.applyMouseUp(at: CGPoint(x: 450, y: 350))
        pump(1.0)
        XCTAssertEqual(sceneOnDisk(root).regionCount, 1,
                       "precondition: the sweep really did make a region")
    }

    func test_draggingARegionByItsLabelBarCarriesItsResidentToDisk() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Onto the chrome bar, then 100pt right and 40pt down.
        drag(events, from: CGPoint(x: 200, y: 30),
             through: [CGPoint(x: 300, y: 70), CGPoint(x: 300, y: 70)])
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame.origin,
                       CGPoint(x: 120, y: 60))
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 160, y: 100),
                       "the resident travelled — through the real event view, the "
                       + "real gesture routing and the real debounced save")
    }

    /// **A region resize, through the real event view, asserted DURING the drag
    /// as well as after it.**
    ///
    /// Every other region test here drives a move or a sweep, so nothing proved
    /// that a press in a region's corner square is routed to `.resizingRegion`
    /// at all. And 1C-a's shipped defect was precisely a resize whose every test
    /// asserted after `.ended` — the card was gone for the whole gesture and the
    /// suite was green. That is the one shape this slice cannot afford to leave
    /// unasked of a new gesture.
    ///
    /// The fixture's region is (20,20)–(420,320), so its corner square is
    /// (406,306)–(420,320); the drag adds 200pt on each axis.
    func test_resizingARegionByItsCornerKeepsItDrawnAndReachesDisk() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // A strip across where the region's RIGHT edge will land. Bare ground
        // now — the region ends at x = 420 — and the outline is what will cross
        // it. The region's own wash is far below `ink`'s threshold, so what this
        // counts is the stroke.
        let newEdge = CGRect(x: 617, y: 380, width: 6, height: 80)
        XCTAssertEqual(try ink(in: newEdge, of: hosted), 0,
                       "precondition: nothing is drawn out here yet, so ink found "
                       + "during the drag can only be the region having grown")

        events.applyMouseDown(at: CGPoint(x: 414, y: 314), clickCount: 1)
        events.applyMouseDragged(to: CGPoint(x: 614, y: 514))
        pump(0.05)

        XCTAssertGreaterThan(try ink(in: newEdge, of: hosted), 0,
                             "the region is not drawn at its new size while the "
                             + "writer is dragging its corner — a region that only "
                             + "resizes on release tells the writer nothing about "
                             + "the size they are choosing, which is the 1C-a resize "
                             + "defect in a second place")

        events.applyMouseUp(at: CGPoint(x: 614, y: 514))
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame,
                       CGRect(x: 20, y: 20, width: 600, height: 500),
                       "the resized frame did not reach disk — the likeliest cause "
                       + "is a corner press being routed to a MOVE, which would "
                       + "have shifted the origin instead")
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "resizing a region dragged its residents along with it: only "
                       + "a MOVE carries the cards, and a resize that moves them "
                       + "rearranges the writer's canvas behind their back")
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "the resize ejected its resident — tldraw #6017, which §4.2 "
                      + "exists to make impossible")
    }

    /// **Dropping a card outside every region does NOT take it out of its home**
    /// (§4.2: removal is always its own act), and the tether is what makes the
    /// resulting state legible.
    ///
    /// `CanvasRegionInteractionTests` asks this of `joinTarget`, which is a pure
    /// query with no removal in it to omit — so that assertion cannot fail for
    /// the reason it gives. The real constraint is the ABSENCE of an `else`
    /// beside the join in `handleDrag(.ended)`, and nothing would notice one
    /// being added. This is what notices.
    func test_draggingAResidentOutOfItsRegionLeavesItAMemberAndTethered() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Grab the card at (100,80) — on it, clear of its resize corner — and
        // carry it out to the right of the region, which ends at x = 420.
        drag(events, from: CGPoint(x: 100, y: 80),
             through: [CGPoint(x: 700, y: 80), CGPoint(x: 700, y: 80)])
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 660, y: 60),
                       "precondition: the card really was carried out of the region")
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.frame
                        .intersects(onDisk.node(scrapID)!.frame!),
                       "precondition: and it is entirely outside it now")
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "dragging a card out of its region silently took it out of "
                      + "the region: removal is its own act (§4.2), and a drop that "
                      + "quietly unmakes a relationship is how a writer loses track "
                      + "of what belongs where")
        XCTAssertEqual(CanvasRenderer.tethers(in: onDisk).map(\.node), [scrapID],
                       "the card is a member sitting outside its region and no "
                       + "tether explains why — which is the only thing that makes "
                       + "this state readable rather than a bug")
    }

    func test_oneUndoTakesBackARegionDragAndTheCardsItCarried() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 200, y: 30),
             through: [CGPoint(x: 300, y: 70), CGPoint(x: 300, y: 70)])
        pump(1.0)
        XCTAssertEqual(sceneOnDisk(root).node(scrapID)?.origin, CGPoint(x: 160, y: 100),
                       "precondition: the drag really happened")

        // What a click on bare canvas does. The testable seam `drag` goes
        // through does no event-level responder work — synthesizing `NSEvent`s
        // is unreliable, see `CanvasEventNSView` — so the claim
        // `mouseDown(with:)` makes is made here in its place. Without it the
        // chain walk below starts at the window, finds `NSWindow.undo:`, and
        // measures the window's stack rather than the canvas's.
        XCTAssertTrue(window.makeFirstResponder(events))

        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        XCTAssertTrue(undo.isEnabled,
                      "a ⌘Z the Edit menu greys out is a feature the writer cannot reach")
        XCTAssertTrue(undo.item.title.contains("Move Region"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming the "
                      + "gesture it will take back — a region drag opened a bracket "
                      + "under some other gesture's name")
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame.origin, CGPoint(x: 20, y: 20))
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "one ⌘Z takes back the frame AND every resident it carried — "
                       + "which is why the recorder snapshots the scene rather than "
                       + "inverting properties")
    }

    /// **The PREMISE under the region inspector's gate, which nothing pinned.**
    ///
    /// `RegionInspector`'s member lists and its "Cite a Card" offer are rebuilt
    /// only when `(CanvasModel.sceneRevision, regionID)` moves, and
    /// `RegionBindingTests.test_theMemberListsAreRebuiltOnlyOnAStructuralChange`
    /// pins that gate in both directions — by driving the bump BY HAND. Its
    /// docstring then asserted, in prose only, that *"every production path that
    /// changes membership bumps: a drop at `.ended`"*. It did not. The drop
    /// bumped `CanvasView`'s own `@State` copy, the mirror runs model → view and
    /// never back, and every one of the seventeen `sceneRevision` references
    /// across the test tree was either a hand-driven bump or an inspector commit.
    /// So the gate was pinned and its premise was not, and the shipped inspector
    /// read "No cards live in this region yet" over a card the canvas had
    /// already drawn inside the region — still offering it under "Cite a Card",
    /// where choosing it returned on `cite`'s `!region.mentions(node)` guard and
    /// did nothing at all.
    ///
    /// **A test that drove the bump by hand would reproduce that blind spot
    /// exactly**, so this one drops a real card through `CanvasEventNSView` and
    /// then asks the inspector — through `refreshedRows`, the one function the
    /// shipping view drives — what it would now show. Both halves are asserted:
    /// the card is a resident, and it is no longer on offer.
    ///
    /// Mutation, 2026-07-28: restoring `sceneRevision += 1` at the `.ended` bump
    /// leaves `test_droppingACardIntoARegionJoinsItAndOneUndoTakesBackBoth`
    /// green (the join reaches disk either way) and turns this red.
    func test_aDropIntoARegionReachesThatRegionsInspector() throws {
        let region = CanvasRegionID("r1")
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 500, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // What the inspector holds before the drop — the same call its
        // `.onChange(of: currentRowsKey, initial: true)` makes when it appears.
        let inspector = RegionInspector(model: model, regionID: region, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        let before = inspector.refreshedRows(from: RegionInspector.MemberRows())
        XCTAssertTrue(before.residents.isEmpty,
                      "precondition: the card starts outside and unowned")
        XCTAssertEqual(before.candidates.map(\.node), [scrapID],
                       "precondition: and it is what \"Cite a Card\" is offering")

        // Grab the card at (540, 90) and carry it 340pt left, so its centre
        // lands at (250, 130) — squarely inside the region.
        drag(events, from: CGPoint(x: 540, y: 90),
             through: [CGPoint(x: 200, y: 90), CGPoint(x: 200, y: 90)])
        pump(1.0)

        XCTAssertTrue(model.scene.region(region)!.livesHere(scrapID),
                      "precondition: the drop itself joined the card, so what "
                      + "follows is about the inspector being TOLD")

        let after = inspector.refreshedRows(from: before)
        XCTAssertEqual(after.residents.map(\.node), [scrapID],
                       "the drop did not move the counter the inspector's gate "
                       + "reads, so the region still says no cards live in it "
                       + "while the canvas draws one inside it")
        XCTAssertTrue(after.candidates.isEmpty,
                      "and \"Cite a Card\" still offers a card that is already "
                      + "here — a live menu row that silently does nothing, "
                      + "because `cite` returns on its `mentions` guard")
    }

    /// **The same defect on the one path where the writer keeps looking at the
    /// region while a scrap is edited beside it** — and the path that makes
    /// `RegionInspector`'s "it refreshes when the writer leaves the scrap" a
    /// claim rather than a hope.
    ///
    /// **The route is the region's own CHROME BAR, and it is tripwire 32's
    /// documented repro.** Click 1 selects the region; click 2 finds no node
    /// under that point, takes `handleClick`'s `.emptyCanvas` branch, mints a
    /// scrap and opens "Edit Scrap" — and `guard clickCount >= 2` returns before
    /// the selection assignment, so the region is still selected while the
    /// writer types. `test_aRegionStaysSelectedWhileADoubleClickOpensAScrap`
    /// pins that; this reads what the inspector beside it then shows.
    ///
    /// **It is NOT a double-click on a card, and that distinction cost this
    /// slice a wrong repro five times.** AppKit sends `clickCount: 1` first, and
    /// that click selects the card — `test_aDoubleClickOnACardDeselectsTheRegion`
    /// is next door asserting exactly that. So every click here sends the real
    /// two-event sequence rather than jumping straight to `clickCount: 2`, which
    /// would keep the region selected by a shortcut of the test's own and prove
    /// nothing about the surface.
    ///
    /// The observable is the minted scrap's title in the inspector's **residents**
    /// list. It enters that list titled "Empty scrap" and has to be re-read once
    /// the writer leaves it, or the region lists a card by a line it no longer
    /// starts with.
    ///
    /// **It was the CANDIDATES list until 2026-07-28**, when creation began
    /// absorbing: a scrap minted over this region's chrome bar now lands inside
    /// the region's frame and so joins it, which moves it out of the "cards you
    /// could cite" offer and into the residents. Same repro, same subject, same
    /// staleness — one list to the left.
    func test_leavingAScrapRefreshesTheRegionInspectorItIsSittingBeside() throws {
        let region = CanvasRegionID("r1")
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 60, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        let root = try projectRoot(scene: scene, scraps: [scrapID: "Rain."])
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // The chrome bar runs (20,20)–(420,44); the fixture's card starts at
        // y 60, so both points below are on the bar and on no card.
        func click(at point: CGPoint, count: Int) {
            events.applyMouseDown(at: point, clickCount: count)
            events.applyMouseUp(at: point)
        }

        // The real double-click: clickCount 1 THEN 2, as AppKit delivers it.
        let mintPoint = CGPoint(x: 200, y: 30)
        click(at: mintPoint, count: 1)
        click(at: mintPoint, count: 2)
        pump(0.3)
        XCTAssertEqual(model.selection, .region(region),
                       "precondition: click 1 selected the region and click 2 never "
                       + "reassigned it, so the inspector is still open on it")
        XCTAssertEqual(model.scene.count, 2,
                       "precondition: click 2 minted a scrap over the chrome bar")

        // What the inspector holds with the new scrap minted and still empty.
        let inspector = RegionInspector(model: model, regionID: region, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        let before = inspector.refreshedRows(from: RegionInspector.MemberRows())
        let minted = try XCTUnwrap(before.residents.first { $0.node != scrapID }?.node,
                                   "precondition: the minted scrap is a resident — "
                                   + "it was made inside the region's frame, and "
                                   + "creation absorbs (2026-07-28)")
        XCTAssertEqual(before.residents.first { $0.node == minted }?.title,
                       CanvasAccessibility.emptyScrapValue,
                       "precondition: and it is listed as an empty scrap")

        type("Rain at the falls.", into: try XCTUnwrap(
            try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                          "the double-click mounted no editor").textView))
        pump(0.3)

        // Leaving the scrap — back onto the chrome bar, clear of the card the
        // second click minted at x 200. This is a single click, so it DOES
        // reassign the selection: to the same region, which is why the inspector
        // and its cached rows survive it.
        click(at: CGPoint(x: 60, y: 30), count: 1)
        pump(0.5)
        XCTAssertEqual(model.selection, .region(region),
                       "precondition: the writer is still looking at this region")

        let after = inspector.refreshedRows(from: before)
        XCTAssertEqual(after.residents.first { $0.node == minted }?.title,
                       "Rain at the falls.",
                       "the writer left the scrap and the region beside it still "
                       + "lists that card as an empty one — `commitActiveEdit` "
                       + "bumped a counter this gate does not read")
    }

    /// **A press that drifted must not be mistaken for a sweep that minted.**
    ///
    /// `applyMouseDown` opens a drag session on EVERY mouse-down, and on a
    /// trackpad a click routinely drifts a point or two — which takes
    /// `interaction.hasMoved`. `createRegion` still refuses anything under
    /// `CanvasRegionMetrics.minimumSide`, so the scene does not change; before
    /// the guard, the structural counter moved anyway. That is one accessibility
    /// tree rebuilt — a sort of the whole scene and a copy of every scrap's
    /// string — plus, now the bump reaches the model, one rebuild of the region
    /// inspector's member lists and its scene-wide candidate walk, per click on
    /// nothing.
    ///
    /// Both directions, because a guard that simply stopped bumping would pass
    /// the first assertion and take the drop-to-join and the region sweep down
    /// with it.
    func test_aBareCanvasPressThatDriftedIsNotAStructuralChange() throws {
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: try projectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        pump(0.3)

        let atRest = model.sceneRevision
        // One point of drift, well under the 80pt minimum side.
        drag(events, from: CGPoint(x: 600, y: 400), through: [CGPoint(x: 601, y: 400)])
        pump(0.3)
        XCTAssertEqual(model.sceneRevision, atRest,
                       "a click on bare canvas that drifted a point minted no "
                       + "region and changed nothing, and still bumped the "
                       + "structural counter — so every trackpad click on the "
                       + "canvas sorts the scene and rebuilds two cached lists")
        XCTAssertEqual(model.scene.regionCount, 0,
                       "precondition: the drift really did mint nothing, or the "
                       + "assertion above is about a different gesture")

        // The control: a sweep clear of the minimum side, which really does mint.
        drag(events, from: CGPoint(x: 600, y: 400), through: [CGPoint(x: 400, y: 200)])
        pump(0.3)
        XCTAssertEqual(model.scene.regionCount, 1, "precondition: this one minted")
        XCTAssertGreaterThan(model.sceneRevision, atRest,
                             "and a sweep that DID mint a region has to reach the "
                             + "accessibility tree and the inspector — a guard "
                             + "that just stopped bumping would pass the "
                             + "assertion above and lose this one")
    }

    func test_droppingACardIntoARegionJoinsItAndOneUndoTakesBackBoth() throws {
        // The same region, and a scrap that starts OUTSIDE it.
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 500, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        XCTAssertFalse(sceneOnDisk(root).region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "precondition: it starts outside and unowned")

        // Grab the card at (540, 90) and carry it 340pt left, so its centre
        // lands at (250, 130) — squarely inside the region.
        drag(events, from: CGPoint(x: 540, y: 90),
             through: [CGPoint(x: 200, y: 90), CGPoint(x: 200, y: 90)])
        pump(1.0)

        XCTAssertTrue(sceneOnDisk(root).region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "the drop joined it")

        XCTAssertTrue(window.makeFirstResponder(events))
        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 500, y: 60))
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "ONE ⌘Z, because the join lands inside the move's own "
                       + "gesture — a second bracket would leave the card back "
                       + "outside a region that still claimed it")
    }

    /// **A resize is not a drop.** The join is read off `interaction.kind ==
    /// .movingNode`, and dropping that filter is invisible everywhere else: a
    /// region drag reports no `activeNodeID`, so the only gesture the filter
    /// actually excludes is a card RESIZE — where `hasMoved` is true and the
    /// card's centre walks as the width changes.
    ///
    /// The geometry is chosen so it walks across the line: the card starts with
    /// its centre exactly on the region's right edge, and narrowing it to the
    /// floor carries the centre 60pt inside. Without the filter the writer
    /// rewraps a card near a region and it silently changes owner.
    func test_narrowingACardUntilItsCentreIsInsideARegionDoesNotJoinIt() throws {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 300, y: 60),
                                width: 240, cachedHeight: 38))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // 2pt inside the card's bottom-right corner square. The card is 38pt
        // tall — `rewrappingScrapText` records the measurement, and `scrapText`
        // is one line at every width from 240 down to the floor — so the corner
        // is at (540, 98). A press that missed it would leave the width at 240,
        // which the first assertion below reads.
        drag(events, from: CGPoint(x: 538, y: 96),
             through: [CGPoint(x: 100, y: 96)])
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        let card = try XCTUnwrap(onDisk.node(scrapID))
        XCTAssertEqual(card.width, CanvasInteraction.minimumScrapWidth,
                       "precondition: the resize really ran to the floor")
        XCTAssertEqual(card.origin, CGPoint(x: 300, y: 60),
                       "precondition: a resize holds the origin, so the centre "
                       + "moved by half the width it lost and by nothing else")
        XCTAssertTrue(onDisk.region(CanvasRegionID("r1"))!.frame
                        .contains(CGPoint(x: card.frame!.midX, y: card.frame!.midY)),
                      "precondition: the narrowed card's centre really is inside "
                      + "the region, so a missing filter WOULD have joined it")
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "rewrapping a card near a region silently changed its owner "
                       + "— the drop is a DROP, and only a move ends in one")
    }

    /// **What a single click selects**, which nothing pinned until this test:
    /// replacing `selectionTarget`'s body with `return nil` left the whole suite
    /// green. The one existing assertion on `model.selection` pins the *create*
    /// branch's assignment, which is a different line.
    ///
    /// It matters beyond the accent stroke: this value is what the region
    /// inspector reads and what ⌫ will act on, so a selection that names the
    /// wrong thing is an edit to the wrong thing.
    ///
    /// The four presses are one sequence on purpose. Each asserts a different
    /// answer, so an implementation that always returned `nil` fails the first
    /// two and one that never cleared fails the last two.
    func test_aSingleClickSelectsTheThingUnderIt() throws {
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: try regionProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        func click(at point: CGPoint) {
            events.applyMouseDown(at: point, clickCount: 1)
            events.applyMouseUp(at: point)
            pump(0.05)
        }

        // On the card at (60,60)–(300,98), clear of its resize corner.
        click(at: CGPoint(x: 100, y: 80))
        XCTAssertEqual(model.selection, .node(scrapID),
                       "clicking a card does not select it")

        // On the region's chrome bar, (20,20)–(420,44).
        click(at: CGPoint(x: 200, y: 30))
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "clicking a region's label bar does not select the region — "
                       + "which is the only way to reach one, since its interior "
                       + "deliberately belongs to the cards in it")

        // The region's INTERIOR, below the card.
        click(at: CGPoint(x: 200, y: 200))
        XCTAssertNil(model.selection,
                     "clicking inside a region selected it: the interior is not a "
                     + "handle, and a click there that selects the region is the "
                     + "same rule the drag refuses, arriving from the click path")

        click(at: CGPoint(x: 200, y: 30))
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "precondition: something is selected again, so the clear "
                       + "below is a real clear")
        // Bare canvas, outside everything.
        click(at: CGPoint(x: 700, y: 500))
        XCTAssertNil(model.selection, "clicking bare canvas does not clear the "
                     + "selection, so the accent stays on a thing the writer has "
                     + "clicked away from")
    }

    /// **A single click on bare canvas opens a `.drawingRegion` gesture on every
    /// press, including the first of every double-click**, because
    /// `applyMouseDown` fires `onClick` and `onDrag(.began)` together. It ends
    /// immediately with a zero-size rect, which `createRegion` refuses — so the
    /// double-click that makes a scrap must still make exactly one scrap and no
    /// region, and must leave exactly one thing on the undo stack.
    ///
    /// This is the path point 2 of the task brief asks to be traced. It is
    /// asserted rather than reasoned about because the failure is silent: a
    /// `createRegion` with no minimum, or an `endGesture` that registered an
    /// unchanged scene, leaves the writer pressing ⌘Z twice to take back one
    /// card.
    func test_aDoubleClickOnBareCanvasStillMakesOneScrapAndNoRegion() throws {
        let root = try projectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let hosted = try XCTUnwrap(window.contentView)
        let events = try eventView(in: window)

        // The first press of the double-click, released — the whole of the
        // zero-size sweep, on its own.
        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 500, y: 400))
        pump()
        XCTAssertFalse(try XCTUnwrap(events.undoManager).canUndo,
                       "a single click on bare canvas left a step on the stack: the "
                       + "sweep it opened registered a scene that never moved")

        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 2)
        pump(0.3)
        type("Rain.", into: try XCTUnwrap(
            try XCTUnwrap(firstDescendant(ScrapEditorContainer.self, in: hosted),
                          "the double-click made no scrap").textView))
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0,
                       "the zero-size sweep that every press opens minted a region: "
                       + "double-clicking bare canvas now leaves a stray region "
                       + "behind every new scrap")
        XCTAssertEqual(onDisk.count, 2, "precondition: the new scrap is on the canvas")
    }

    // MARK: - ⌫, through the real responder chain

    /// **The delivery path, end to end, and it is the point of this task.**
    ///
    /// 1C-a built `CanvasScene.remove`, its inverse and the "Delete Scrap" undo
    /// step, exercised all three, and shipped no production caller — the same
    /// shape as its undo defect, which was twenty-two green tests deep on a ⌘Z
    /// that could not reach the canvas stack at all, because every one of those
    /// tests drove the recorder directly. So this one presses a real key: an
    /// `NSEvent` handed to `window.sendEvent(_:)`, routed by AppKit to whatever
    /// holds first responder, and asserted on what reached DISK.
    ///
    /// A `deleteSelection()` called by hand would pass this task's model-level
    /// tests and do nothing whatsoever for the writer.
    func test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Single click on the card: selects it and takes first responder.
        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)
        XCTAssertEqual(model.selection, .node(scrapID), "precondition: it is selected")
        XCTAssertTrue(window.firstResponder === events,
                      "precondition: the key will actually arrive here")
        XCTAssertTrue(try axTree(in: window)
            .compactMap { axString($0, "accessibilityValue") }.contains(scrapText),
                      "precondition: the card is in the published accessibility "
                      + "tree, so its absence below is a removal rather than a "
                      + "tree that never had it")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertNil(sceneOnDisk(root).node(scrapID),
                     "⌫ with a card selected did not delete it. The likeliest cause "
                     + "is that the key never reached CanvasEventNSView at all — "
                     + "which is exactly the defect this test exists for, and which "
                     + "every model-level assertion in this task is blind to")
        XCTAssertNil(scrapsOnDisk(root)[scrapID],
                     "the words go with the card — canvas.md is the only place "
                     + "they live, so a scrap left behind is an orphan paragraph in "
                     + "the writer's own file")
        XCTAssertFalse(try axTree(in: window)
            .compactMap { axString($0, "accessibilityValue") }.contains(scrapText),
                       "the deleted card is still in the accessibility tree: the "
                       + "structural bump never arrived, so a VoiceOver user goes on "
                       + "meeting a card that is not on the canvas until some "
                       + "unrelated change happens to rebuild the tree")
    }

    /// ⌫ over an empty selection is a no-op, not a guess.
    ///
    /// The control the assertion needs is the test above: the same key, the same
    /// window, the same first responder, and there it removes the card. So a
    /// scrap still on disk here can only be the empty selection.
    func test_backspaceWithNothingSelectedChangesNothing() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Bare canvas, far from the fixture scrap at (20,20).
        clickAndFocusTheCanvas(events, at: CGPoint(x: 500, y: 400), in: window)
        XCTAssertNil(model.selection, "precondition: clicking nothing selects nothing")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)
        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "⌫ over an empty selection must be a no-op, not a guess — "
                        + "a canvas that deletes the topmost card when nothing is "
                        + "selected loses the writer's work to a stray keystroke")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText)
        XCTAssertFalse(try XCTUnwrap(events.undoManager).canUndo,
                       "a ⌫ that deleted nothing still pushed a step: the writer's "
                       + "next ⌘Z appears to do nothing, and the one after it takes "
                       + "back an edit they had stopped thinking about")
    }

    /// **⌫ never fights the editor.** While a scrap is focused the mounted text
    /// view is frontmost and first responder, so the key deletes a character —
    /// which is what the writer meant. If the event view ever won that race, a
    /// backspace mid-sentence would delete the whole card.
    ///
    /// Pinned rather than assumed, because the two ways it could break are both
    /// invisible from the model: an event view that took first responder back, or
    /// a `keyDown` moved onto a responder the editor's chain walks through.
    ///
    /// **The scrap is SELECTED before it is entered, and that is what makes this
    /// test about the race at all.** A double-click on its own leaves
    /// `model.selection` nil, so the card would survive ⌫ however the key was
    /// routed — the assertion would be vacuous and would stay green with the
    /// editor removed from in front of the event view entirely. Clicking once
    /// first leaves the selection standing through the visit, so this is a canvas
    /// where the event view has something to delete and does not get the chance.
    func test_backspaceInsideAScrapDeletesACharacterAndNotTheCard() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)

        // The helper's own settle already outlasts the straighten, so the editor
        // is level, visible and first responder by the time it returns.
        _ = try doubleClickTheScrap(in: window)
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: the card is still SELECTED while the writer "
                       + "is inside it, so ⌫ reaching the event view would take the "
                       + "whole card")
        let editor = try XCTUnwrap(
            firstDescendant(NSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.firstResponder === editor,
                      "precondition: the editor holds first responder, so the key "
                      + "never reaches CanvasEventNSView at all")

        editor.setSelectedRange(NSRange(location: (scrapText as NSString).length, length: 0))
        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "a backspace mid-sentence deleted the whole card: the event "
                        + "view won the race with the mounted editor")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], String(scrapText.dropLast()),
                       "exactly one character, and it reached disk")
    }

    /// The undo layer has been waiting for this caller since 1C-a. One ⌘Z brings
    /// the card back **with its words** — the scene and the scrap text are one
    /// snapshot, which is why they cannot be restored out of step.
    ///
    /// Driven through the Edit menu's own resolve → validate → send, because that
    /// is the path the 1C-a defect was in.
    func test_undoBringsBackADeletedScrapWithItsWords() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)
        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)
        XCTAssertNil(sceneOnDisk(root).node(scrapID), "precondition: it is gone")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.target === events,
                      "the Edit menu's Undo does not resolve to the canvas after a "
                      + "delete")
        XCTAssertTrue(undo.isEnabled,
                      "a delete left nothing on the undo stack, so the stray ⌫ that "
                      + "takes a card away is permanent")
        XCTAssertTrue(undo.item.title.contains("Delete Scrap"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming "
                      + "what it will take back")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pump(1.0)

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "the words come back with the card — the scene and the "
                       + "scrap text are one snapshot, which is why they cannot "
                       + "be restored out of step")
    }

    /// **A ⌫ pressed while a gesture is open must delete nothing**, because a
    /// delete that happens inside somebody else's bracket cannot be taken back
    /// on its own.
    ///
    /// `CanvasUndo.beginGesture` takes NO snapshot when it nests, and
    /// `endGesture` registers nothing until depth reaches zero — so a delete
    /// opened inside an outer gesture disappears into it. Here the outer gesture
    /// is the "Move Scrap" that `handleDrag(.began)` opens on every press over a
    /// card: press and hold, press ⌫, and the card goes while the Edit menu has
    /// nothing to offer. Release, and it offers **"Undo Move Scrap"** — a move
    /// and a delete collapsed into one step under the wrong name.
    ///
    /// This is the reachable half. The lossy half is the test below.
    func test_backspaceDuringAnOpenDragDeletesNothing() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Press on the card and DO NOT release: `onClick` selects it and
        // `onDrag(.began)` opens "Move Scrap" in the same mouse-down.
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1)
        XCTAssertTrue(window.makeFirstResponder(events))
        pump()
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: the press selected the card, so there is "
                       + "something for ⌫ to take")
        XCTAssertTrue(model.isInGesture,
                      "precondition: the press opened a gesture that is still open")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "⌫ mid-drag deleted the card from inside the drag's own "
                        + "undo bracket: the delete registers no step of its own, "
                        + "so one ⌘Z takes back the move AND the delete together, "
                        + "named after the move")
        events.applyMouseUp(at: CGPoint(x: 60, y: 40))
        pump(1.0)
        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "the card came back only to go again when the drag ended")
    }

    /// **The lossy half, and the reason the guard is not merely tidy.**
    ///
    /// The editor claims first responder from `viewDidMoveToWindow`, so for the
    /// runloop turn after a double-click the EVENT VIEW still holds it, with
    /// "Edit Scrap" open and a live selection behind it. A ⌫ there deletes the
    /// card, registers nothing — and `scheduleSave()` writes it. If the writer
    /// then quits before the gesture closes, `detach()` calls `undo.release()`
    /// and drops the stack whole: **the card is gone from disk and no step was
    /// ever registered.** That is the product constitution's must #1.
    ///
    /// The window is narrow — this test reaches it by not turning the runloop,
    /// which is the only way to stand in it deliberately. It is a real state
    /// rather than a contrived one: the same bracket is open for the whole visit,
    /// and only the editor holding first responder keeps ⌫ away from the canvas.
    func test_backspaceBeforeTheEditorTakesFocusCannotLoseTheCardUnrecoverably() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Click once to select, then enter the scrap — and do NOT pump, so the
        // editor has not yet claimed first responder.
        clickAndFocusTheCanvas(events, at: CGPoint(x: 60, y: 40), in: window)
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 2)
        XCTAssertTrue(window.firstResponder === events,
                      "precondition: the editor has not taken first responder yet, "
                      + "so the canvas is still the one holding the keyboard")
        XCTAssertTrue(model.isInGesture,
                      "precondition: entering the scrap opened \"Edit Scrap\" and it "
                      + "is still open")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        // Quit the way ⌘Q does: flush, then let go of the undo stack.
        let saved = savedScene(after: window, root: root)
        XCTAssertNotNil(saved.node(scrapID),
                        "the card was deleted inside an undo bracket that never "
                        + "closed, and quitting dropped the stack — the writer's "
                        + "words are gone from disk with nothing that could ever "
                        + "have brought them back")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText)
    }

    /// Spec §3.1, generalised: the canvas owns arrangement, not existence.
    ///
    /// Deleting a region takes its membership records and nothing else. The card
    /// it held stays exactly where it was — asserted at its coordinates rather
    /// than merely as "still present", because a region delete that dragged its
    /// residents somewhere would satisfy the weaker question.
    func test_deletingARegionLeavesItsCardsWhereTheyWere() throws {
        let root = try regionProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The region's label bar: frame starts at (20,20), so y=30 is inside the
        // 24pt chrome, and x=200 is clear of the card at (60,60)…(300,120).
        clickAndFocusTheCanvas(events, at: CGPoint(x: 200, y: 30), in: window)
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "precondition: the label bar selected the region")
        XCTAssertEqual(sceneOnDisk(root).regionCount, 1,
                       "precondition: the region is on disk, so the zero below is a "
                       + "removal")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0, "⌫ with a region selected left it there")
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "deleting a region never deletes cards, and never moves them")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "the resident's words went with the region that merely held it")

        // The undo half. It runs a DIFFERENT path from the scrap branch —
        // `CanvasModel.mutate` rather than a hand-rolled bracket — so the scrap
        // half's coverage says nothing about it, and what vanishes here is a
        // container full of cards.
        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.isEnabled,
                      "deleting a region left nothing on the undo stack: a whole "
                      + "arrangement goes on one keystroke and does not come back")
        XCTAssertTrue(undo.item.title.contains("Delete Region"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming "
                      + "what it will take back")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pump(1.0)

        let restored = sceneOnDisk(root)
        XCTAssertEqual(restored.regionCount, 1, "⌘Z did not bring the region back")
        XCTAssertEqual(restored.region(CanvasRegionID("r1"))?.livesHere(scrapID), true,
                       "the region came back without the card it held — a snapshot "
                       + "carries membership, so a region restored empty means the "
                       + "undo restored something other than what was deleted")
    }

    /// **Deleting a card that lives in a region takes its membership with it.**
    ///
    /// `CanvasScene.remove` scrubs the node from every region, and a ghost member
    /// would resurface in the inspector's "lives here" list and in
    /// `RegionBinding.references(forPiece:)` long after the card was gone. Pinned
    /// at the model level and, until this test, nowhere on the real surface —
    /// where the scrub has to survive the save, the reload and the codec.
    func test_deletingACardThatLivesInARegionLeavesNoGhostMember() throws {
        let root = try regionProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        XCTAssertEqual(sceneOnDisk(root).region(CanvasRegionID("r1"))?.livesHere(scrapID),
                       true, "precondition: the fixture's card lives in the region")

        // On the card at (60,60)–(300,120), clear of its resize corner.
        clickAndFocusTheCanvas(events, at: CGPoint(x: 100, y: 80), in: window)
        XCTAssertEqual(model.selection, .node(scrapID), "precondition: the card is selected")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertNil(onDisk.node(scrapID), "precondition: the card went")
        XCTAssertEqual(onDisk.regionCount, 1,
                       "deleting a card took its region with it — the card belongs "
                       + "to the region, not the other way round")
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.mentions(scrapID), false,
                       "the region still remembers a card that no longer exists: a "
                       + "ghost member survives the save and the reload, and shows "
                       + "up in the inspector's \"lives here\" list for a card the "
                       + "writer deleted")
    }


    // MARK: - The inspector edits a scene whose gesture is still open

    /// **The repro for `CanvasUndo.mutateFromOutsideTheCanvas`, driven through
    /// the real click path.**
    ///
    /// Both of the unit tests for that method hand-open the bracket with
    /// `model.beginGesture("Edit Scrap")`, which is the 1C-a lesson in
    /// miniature — a mechanism exercised only by the test that drives it
    /// directly. This one reaches the state the way a writer does, and it is the
    /// test that says the documented repro is real.
    ///
    /// The chrome bar is load-bearing: click 1 selects the region, click 2 finds
    /// no node under the point, takes the `.emptyCanvas` branch, mints a scrap
    /// and opens "Edit Scrap" — and `handleClick`'s `guard clickCount >= 2`
    /// returns before the selection is ever reassigned.
    func test_aRegionStaysSelectedWhileADoubleClickOpensAScrap() throws {
        let root = try regionProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let region = CanvasRegionID("r1")

        // The chrome bar runs y 20..44; the fixture's card starts at y 60.
        let onTheChrome = CGPoint(x: 200, y: 30)
        events.applyMouseDown(at: onTheChrome, clickCount: 1)
        events.applyMouseUp(at: onTheChrome)
        events.applyMouseDown(at: onTheChrome, clickCount: 2)
        events.applyMouseUp(at: onTheChrome)
        pump()

        XCTAssertEqual(model.selection, .region(region),
                       "click 1 selected the region and the double-click never "
                       + "reassigned it — so the inspector is showing this region")
        XCTAssertTrue(model.isInGesture,
                      "and click 2 minted a scrap and opened \"Edit Scrap\" — the "
                      + "bracket an inspector edit must not nest inside")

        // The inspector, in the other column, renames the region while that
        // bracket is open. Through `mutate` this would register nothing at all.
        RegionInspector(model: model, regionID: region, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
            .commitLabel("Falls at night")
        XCTAssertEqual(model.scene.region(region)?.label, "Falls at night")

        // **This is the assertion that sees the nesting, and the scene is not.**
        // Measured (mutation, 2026-07-28): with `mutateFromInspector` swapped for
        // `mutate`, the rename nests, registers nothing of its own, and rides
        // into the open "Edit Scrap" bracket — which the ⌘Z below then closes and
        // undoes, leaving the label back at "Act II fog" and the card in place.
        // Every scene assertion here is satisfied by that coincidence. What
        // differs is the NAME, and the name is what the writer reads off the Edit
        // menu.
        XCTAssertTrue(model.undo.undoMenuItemTitle.contains("Rename Region"),
                      "the rename must be its own named step. Got: "
                      + model.undo.undoMenuItemTitle)

        model.undo.undo()
        XCTAssertEqual(model.scene.region(region)?.label, "Act II fog",
                       "one ⌘Z takes the rename back, which it cannot do if the "
                       + "rename never became a step")
        XCTAssertEqual(model.scene.count, 2,
                       "and the scrap the double-click minted is untouched — the "
                       + "⌘Z landed on the rename, not on the card")
    }

    /// The other half, and the reason the doc says CHROME BAR rather than card:
    /// **a double-click on a CARD cannot reach that state.** AppKit delivers
    /// `clickCount: 1` on the first mouse-down of a double-click, and that click
    /// selects the card — so the region is deselected before the bracket opens
    /// and the inspector is showing its empty state.
    ///
    /// Pinned because the first draft of this slice documented the card version
    /// in four places. A repro nobody can reproduce is worse than none: the next
    /// author tries it, fails, and concludes the rule is stale.
    func test_aDoubleClickOnACardDeselectsTheRegion() throws {
        let root = try regionProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let region = CanvasRegionID("r1")

        let onTheChrome = CGPoint(x: 200, y: 30)
        events.applyMouseDown(at: onTheChrome, clickCount: 1)
        events.applyMouseUp(at: onTheChrome)
        pump()
        XCTAssertEqual(model.selection, .region(region), "the control: it starts selected")

        // The fixture's card sits at (60, 60); its measured height is well under
        // 40pt, so this point is inside it.
        let onTheCard = CGPoint(x: 100, y: 75)
        events.applyMouseDown(at: onTheCard, clickCount: 1)
        events.applyMouseUp(at: onTheCard)
        events.applyMouseDown(at: onTheCard, clickCount: 2)
        events.applyMouseUp(at: onTheCard)
        pump()

        XCTAssertEqual(model.selection, .node(scrapID),
                       "clickCount 1 arrives first and selects the card")
        XCTAssertNil(model.selectedRegion,
                     "so `selectedRegion` is nil, the inspector is showing \"Select "
                     + "a region\", and there is no label field to type into")
    }

    // MARK: - Drawing a line, through real events

    /// Two measured cards, well apart: the fixture scrap at (20,20) and a second
    /// at (400,200), both 240 wide.
    ///
    /// The heights here are the measured ones, but the view re-derives them on
    /// load — so every test below reads the LIVE frame out of the scene rather
    /// than arithmetic of its own. The connect target in particular is clamped
    /// against the card's height, and a test that computed it from the fixture
    /// would be aiming at a card that is not there.
    private func twoCardProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 20, y: 20),
                                width: 240, cachedHeight: 38))
        scene.insert(CanvasNode(id: secondScrapID, kind: .scrap, origin: CGPoint(x: 400, y: 200),
                                width: 240, cachedHeight: 38))
        return try projectRoot(scene: scene,
                               scraps: [scrapID: scrapText, secondScrapID: secondScrapText])
    }

    /// A real AppKit mouse event, in the window's own coordinates.
    ///
    /// `view.convert(_:to: nil)` rather than arithmetic on the window height: the
    /// event view is flipped and sits wherever SwiftUI's hosting hierarchy put
    /// it, and a test that did that sum itself would be asserting about its own
    /// arithmetic.
    private func mouseEvent(_ type: NSEvent.EventType,
                            at viewPoint: CGPoint,
                            in view: NSView,
                            window: NSWindow,
                            shift: Bool = false) -> NSEvent? {
        NSEvent.mouseEvent(with: type,
                           location: view.convert(viewPoint, to: nil),
                           modifierFlags: shift ? [.shift] : [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// A press, a path and a release, as REAL `NSEvent`s through
    /// `window.sendEvent(_:)`.
    ///
    /// Everything else in this file drives `applyMouseDown` — the seam — because
    /// synthesising mouse events was unreliable in the 2026-07-25 spike. This
    /// one has to go the whole way: the ⇧ flag is read off the event inside
    /// `CanvasEventNSView.mouseDown(with:)`, so a test that called the seam would
    /// be handing the modifier in by hand and could not tell whether production
    /// ever reads it. That is the 1C-a defect — a feature twenty-two tests deep
    /// with nothing driving its real entry point.
    ///
    /// All three events are sent synchronously and the loop is pumped once
    /// afterwards: `NSTextView.mouseDown` runs a modal tracking loop, so a
    /// harness that pumped between the press and the release could deadlock.
    private func sendRealDrag(in window: NSWindow,
                              from start: CGPoint,
                              through path: [CGPoint],
                              shift: Bool) throws {
        let events = try eventView(in: window)
        let down = try XCTUnwrap(mouseEvent(.leftMouseDown, at: start, in: events,
                                            window: window, shift: shift))
        XCTAssertTrue(window.contentView?.hitTest(down.locationInWindow) === events,
                      "the press did not land on the canvas event view, so nothing "
                      + "below is about the gesture — check the layer order first")
        window.sendEvent(down)
        for point in path {
            if let dragged = mouseEvent(.leftMouseDragged, at: point, in: events, window: window) {
                window.sendEvent(dragged)
            }
        }
        if let up = mouseEvent(.leftMouseUp, at: path.last ?? start, in: events, window: window) {
            window.sendEvent(up)
        }
        pump()
    }

    /// One real click, which is how a writer selects a card — and therefore the
    /// only honest way to reveal the connect mark in a test whose whole claim is
    /// that a writer can reach the gesture knowing nothing.
    private func sendRealClick(in window: NSWindow, at point: CGPoint) throws {
        try sendRealDrag(in: window, from: point, through: [], shift: false)
    }

    /// Where the connect mark is on a card, read off the live scene.
    private func connectMarkCentre(of id: CanvasNodeID, in model: CanvasModel) throws -> CGPoint {
        let frame = try XCTUnwrap(model.scene.node(id)?.frame,
                                  "the card is unmeasured, so it has no mark and no "
                                  + "frame to put one on")
        let target = CanvasRenderer.connectHandleRect(inCard: frame)
        XCTAssertFalse(target.isNull,
                       "precondition: this card is tall enough to carry a connect "
                       + "mark above its resize corner")
        return CGPoint(x: target.midX, y: target.midY)
    }

    private let insideTheFirstCard = CGPoint(x: 60, y: 30)
    private let insideTheSecondCard = CGPoint(x: 440, y: 215)

    /// **The fast route, end to end.** A real ⇧-flagged `NSEvent` through
    /// `window.sendEvent(_:)`, so the modifier is read where production reads it
    /// and the answer travels the whole way to the scene.
    func test_aShiftDragBetweenTwoCardsReachesTheSceneThroughTheRealEventPath() throws {
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        XCTAssertTrue(model.scene.lines.isEmpty, "precondition: nothing is connected yet")
        let origin = try XCTUnwrap(model.scene.node(scrapID)?.origin)

        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 250, y: 120), insideTheSecondCard],
                         shift: true)

        XCTAssertEqual(model.scene.lines.count, 1,
                       "a ⇧-drag from one card to another made no line — the modifier "
                       + "reached no further than the event")
        let line = try XCTUnwrap(model.scene.lines.first)
        XCTAssertEqual(line.from, scrapID)
        XCTAssertEqual(line.to, secondScrapID)
        XCTAssertNil(line.label)
        XCTAssertEqual(model.scene.node(scrapID)?.origin, origin,
                       "and the source card did not move: without ⇧ this drag is a "
                       + "MOVE, so an unmoved card is what says the flag was read")
        XCTAssertEqual(model.selection, .line(line.id),
                       "the new line is what the writer is left holding, so ⌫ and the "
                       + "inspector are pointed at it")
    }

    /// **The discoverable route, end to end, knowing nothing.** The card is
    /// selected by a real CLICK rather than by assigning `model.selection`,
    /// because the whole claim of this route is that a writer finds it without
    /// being told; a test that set the selection by hand would be told.
    ///
    /// No modifier anywhere in it.
    func test_aDragFromTheSelectedCardsConnectHandleReachesTheSceneTheSameWay() throws {
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))

        try sendRealClick(in: window, at: insideTheFirstCard)
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: a plain click selects the card, and selection is "
                       + "what draws the mark")
        let origin = try XCTUnwrap(model.scene.node(scrapID)?.origin)

        try sendRealDrag(in: window, from: try connectMarkCentre(of: scrapID, in: model),
                         through: [CGPoint(x: 350, y: 150), insideTheSecondCard],
                         shift: false)

        XCTAssertEqual(model.scene.lines.count, 1,
                       "a drag out of the mark on a selected card made no line — the "
                       + "route the writer can SEE is the one that must not be missing")
        let line = try XCTUnwrap(model.scene.lines.first)
        XCTAssertEqual(line.from, scrapID)
        XCTAssertEqual(line.to, secondScrapID)
        XCTAssertEqual(model.scene.node(scrapID)?.origin, origin,
                       "and the card stayed put: a press inside the mark is a line, "
                       + "not a move")
    }

    /// **The press that SELECTS a card must not also draw a line out of it.**
    ///
    /// `applyMouseDown` fires `onClick` strictly before `onDrag(.began)`, so by
    /// the time a drag begins the card under the pointer is already selected —
    /// which is why the gesture asks what was selected when the press ARRIVED.
    /// Without that, a 14 pt patch on the right edge of every unselected card on
    /// the canvas would refuse to move it, and would instead do something the
    /// writer could not have predicted from anything on screen.
    func test_theFirstPressOnAnUnselectedCardsMarkPositionMovesItRatherThanDrawingALine() throws {
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        XCTAssertNil(model.selection, "precondition: nothing is selected, so no mark is drawn")
        let origin = try XCTUnwrap(model.scene.node(scrapID)?.origin)
        // Where the mark WOULD be, if the card were selected.
        let markPosition = try connectMarkCentre(of: scrapID, in: model)

        try sendRealDrag(in: window, from: markPosition,
                         through: [CGPoint(x: 350, y: 150), insideTheSecondCard],
                         shift: false)

        XCTAssertTrue(model.scene.lines.isEmpty,
                      "the mark was not on screen when the writer pressed, so they "
                      + "cannot have aimed at it")
        XCTAssertNotEqual(model.scene.node(scrapID)?.origin, origin,
                          "and the press did what a press on a card does: it moved it")
    }

    /// **A line minted by a press and a release with no drag sample between them
    /// must still reach DISK.**
    ///
    /// `hasMoved` is set by `update`, and `update` runs only on `.changed` — so a
    /// mouse-down on one card and a mouse-up over another with nothing in between
    /// inserts a line under `persist: false` and then meets the `hasMoved`
    /// bail-out, which returns above `model.scheduleSave()`. A line in memory
    /// that never reaches the sidecar, and the writer has no way to know.
    ///
    /// **The sweep is structurally immune and the line path is not**, which is
    /// the non-obvious half: a sweep's rect comes from the mode's own `current`,
    /// so with no `.changed` it is a zero rect and `createRegion` refuses it —
    /// there is nothing to lose. `endLine` reads the RELEASE point directly, so
    /// it is the first gesture on this surface that can mint something without a
    /// single drag sample.
    func test_aLineMadeWithoutASingleDragSampleStillReachesDisk() throws {
        let root = try twoCardProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Down on the first card, up over the second, and no `.changed` at all.
        events.applyMouseDown(at: insideTheFirstCard, clickCount: 1, shiftHeld: true)
        events.applyMouseUp(at: insideTheSecondCard)
        pump()

        XCTAssertEqual(model.scene.lines.count, 1,
                       "precondition: the line is in memory, so a missing line below "
                       + "is a save that never happened rather than a gesture that "
                       + "never landed")
        XCTAssertEqual(savedScene(after: window, root: root).lines.count, 1,
                       "the line never reached the sidecar: the writer drew it, saw "
                       + "it, quit, and it was gone")
    }

    /// **A line drag that minted nothing is not a structural change**, and one
    /// that minted a line is — the sweep's own guard, asked of a third gesture.
    ///
    /// It is reachable exactly the way the sweep's is: every ⇧-press on a card
    /// opens a drag session, a trackpad press routinely drifts a point, and a
    /// release that is still over the source card makes no line. Without the
    /// guard each one sorts the scene, copies every scrap's string and rebuilds
    /// the region inspector's two cached lists in the other column.
    ///
    /// Both directions, because the "no bump" half alone is satisfied by a build
    /// that never bumps at all.
    func test_aShiftPressThatDriftedAndMadeNoLineIsNotAStructuralChange() throws {
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                     paletteSwatchHexes: { [] }))
        let before = model.sceneRevision

        // Pressed with ⇧ on a card and released a point away — still over the
        // card it started from, which is not a line.
        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 61, y: 31)], shift: true)
        XCTAssertTrue(model.scene.lines.isEmpty,
                      "precondition: the release was over the source card, so there "
                      + "is no line")
        XCTAssertEqual(model.sceneRevision, before,
                       "a connect drag that made nothing changed nothing, and must "
                       + "not rebuild the accessibility tree or the inspector's lists")

        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 250, y: 120), insideTheSecondCard],
                         shift: true)
        XCTAssertEqual(model.scene.lines.count, 1, "precondition: this one made a line")
        XCTAssertGreaterThan(model.sceneRevision, before,
                             "and a line that WAS made is a structural change — "
                             + "without this the other column never hears about it")
    }

    /// **The step's NAME, through both routes.**
    ///
    /// An undo test whose only observable is the post-⌘Z scene cannot tell "its
    /// own step" from "folded into the neighbour's" — demonstrated twice in this
    /// area on a nesting bug. So this reads `undoMenuItemTitle`, which is the
    /// string the writer sees in the Edit menu.
    ///
    /// Run through BOTH routes: they share one implementation today, and a later
    /// change is exactly what would give them two.
    func test_drawingALineIsOneUndoStepCalledDrawLine() throws {
        for byShift in [true, false] {
            let route = byShift ? "⇧-drag" : "the connect mark"
            let model = CanvasModel()
            let window = host(CanvasView(model: model, projectRoot: try twoCardProjectRoot(),
                                         paletteSwatchHexes: { [] }))
            var start = insideTheFirstCard
            if !byShift {
                try sendRealClick(in: window, at: insideTheFirstCard)
                start = try connectMarkCentre(of: scrapID, in: model)
            }

            try sendRealDrag(in: window, from: start,
                             through: [CGPoint(x: 350, y: 150), insideTheSecondCard],
                             shift: byShift)
            XCTAssertEqual(model.scene.lines.count, 1,
                           "precondition for \(route): a line was drawn, so an "
                           + "unchanged stack below means the step went missing "
                           + "rather than that nothing happened")

            XCTAssertTrue(model.undo.undoMenuItemTitle.contains("Draw Line"),
                          "drawing a line by \(route) must be its own named step — "
                          + "the Edit menu reads \"Undo Draw Line\". Got: "
                          + model.undo.undoMenuItemTitle)

            model.undo.undo()
            XCTAssertTrue(model.scene.lines.isEmpty,
                          "and one ⌘Z takes the line back (\(route))")
            XCTAssertEqual(model.scene.count, 2,
                           "and takes nothing else with it: both cards are still "
                           + "there (\(route))")
        }
    }

    // MARK: - Selecting a line, and taking it back

    /// A canvas with the two fixture cards and one line between them, drawn the
    /// way the writer draws it — a ⇧-drag through the real event path, which is
    /// also what leaves the line SELECTED.
    ///
    /// Returns the line's id and the midpoint of its segment, both read off the
    /// live scene. The cards' heights are re-derived on load, so a hard-coded
    /// midpoint would be aiming at a line that is not there.
    private func drawALine(in window: NSWindow,
                           _ model: CanvasModel) throws -> (id: CanvasLineID, midpoint: CGPoint) {
        try sendRealDrag(in: window, from: insideTheFirstCard,
                         through: [CGPoint(x: 250, y: 120), insideTheSecondCard],
                         shift: true)
        let line = try XCTUnwrap(model.scene.lines.first,
                                 "the ⇧-drag drew no line, so nothing below is about "
                                 + "clicking one")
        let ends = try XCTUnwrap(model.scene.endpoints(of: line))
        let midpoint = CGPoint(x: (ends.0.x + ends.1.x) / 2, y: (ends.0.y + ends.1.y) / 2)
        XCTAssertNil(model.scene.topmostNode(at: midpoint),
                     "the midpoint has ended up under a card, where a card takes the "
                     + "click — move the fixture's cards apart")
        XCTAssertEqual(CanvasLineHit.line(at: midpoint, in: model.scene), line.id,
                       "the midpoint is not on the line it was derived from")
        return (line.id, midpoint)
    }

    /// **A double click on a line must not mint a scrap under it.**
    ///
    /// Both clicks are sent, `clickCount: 1` and then `clickCount: 2`, exactly as
    /// a hand produces them — and the first one is what makes this a bug rather
    /// than a curiosity: it has already selected the line, so with the line
    /// falling through to the empty-canvas branch the writer gets "Edit Scrap"
    /// open on a brand-new card while the other column is showing a line. That is
    /// tripwire 32's own repro arriving through a new door.
    ///
    /// A test that jumped straight to `clickCount: 2` would prove nothing here:
    /// that shortcut has produced a wrong repro five times in this area.
    func test_aDoubleClickOnALineDoesNotMintAScrapUnderIt() throws {
        let root = try twoCardProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)
        XCTAssertEqual(model.scene.count, 2, "precondition: two cards and no more")

        events.applyMouseDown(at: line.midpoint, clickCount: 1)
        events.applyMouseUp(at: line.midpoint)
        pump(0.05)
        XCTAssertEqual(model.selection, .line(line.id),
                       "precondition: click 1 selected the line — which is what makes "
                       + "click 2 minting a scrap the tripwire-32 state rather than "
                       + "merely a stray card")

        events.applyMouseDown(at: line.midpoint, clickCount: 2)
        events.applyMouseUp(at: line.midpoint)
        pump(0.3)

        XCTAssertEqual(model.scene.count, 2,
                       "the double-click minted a scrap under the writer's own line: "
                       + "the line fell through to the empty-canvas branch")
        XCTAssertNil(firstDescendant(ScrapEditorContainer.self,
                                     in: try XCTUnwrap(window.contentView)),
                     "a double-click on a line opened an editor. It opens none of any "
                     + "kind — a line's label is edited in the other column, where a "
                     + "region's already is")
        XCTAssertFalse(model.isInGesture,
                       "\"Edit Scrap\" is open with no scrap: the next thing the "
                       + "writer does from the inspector nests inside it, registers "
                       + "no step of its own, and rides into their next ⌘Z")
        XCTAssertEqual(model.selection, .line(line.id),
                       "and the line the writer double-clicked is still what they are "
                       + "holding")
        XCTAssertEqual(savedScene(after: window, root: root).count, 2,
                       "a stray scrap reached disk")
    }

    /// **The delivery path for ⌫ on a line, end to end.** A real `NSEvent`
    /// through `window.sendEvent(_:)`, routed by AppKit to whatever holds first
    /// responder, asserted on what reached DISK.
    ///
    /// Not a `deleteSelection()` called by hand: that is precisely the test that
    /// would have passed throughout 1C-a while ⌘Z was greyed out in the Edit
    /// menu, and throughout the slice in which `CanvasScene.remove` had no caller
    /// at all.
    func test_backspaceDeletesTheSelectedLineThroughTheRealResponderChain() throws {
        let root = try twoCardProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)

        XCTAssertEqual(model.selection, .line(line.id),
                       "precondition: the new line is what the writer is holding")
        XCTAssertTrue(window.makeFirstResponder(events),
                      "precondition: the key will actually arrive at the canvas")
        pump(1.0)
        XCTAssertEqual(sceneOnDisk(root).lines.count, 1,
                       "precondition: the line is on disk, so its absence below is a "
                       + "delete rather than a save that never happened")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertTrue(sceneOnDisk(root).lines.isEmpty,
                      "⌫ with a line selected did not delete it. The likeliest cause "
                      + "is that the `.line` arm of `deleteSelection` is still "
                      + "returning false — which every model-level assertion in this "
                      + "task is blind to")
        XCTAssertNil(model.selection, "and nothing is left selected")
    }

    /// **A line delete never touches its cards, and one ⌘Z brings it back.**
    ///
    /// The step's NAME is asserted, not just the scene: an undo test whose only
    /// observable is the post-⌘Z scene cannot tell "its own step" from "folded
    /// into the neighbouring one", and this arm goes through `CanvasModel.mutate`
    /// — a different bracket from the scrap branch's hand-rolled one.
    func test_deleteRemovesTheSelectedLineAndLeavesBothCards() throws {
        let root = try twoCardProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)
        XCTAssertTrue(window.makeFirstResponder(events))

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        let afterDelete = sceneOnDisk(root)
        XCTAssertTrue(afterDelete.lines.isEmpty, "precondition: the line went")
        XCTAssertEqual(afterDelete.count, 2,
                       "deleting a line took a card with it — the writer took back "
                       + "the relationship, not the things related")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "and the words on those cards are untouched")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.isEnabled,
                      "deleting a line left nothing on the undo stack, so a stray ⌫ "
                      + "takes a connection away permanently")
        XCTAssertTrue(undo.item.title.contains("Delete Line"),
                      "the menu item reads \"\(undo.item.title)\" rather than naming "
                      + "what it will take back")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pump(1.0)

        let restored = sceneOnDisk(root)
        XCTAssertEqual(restored.lines.count, 1, "⌘Z did not bring the line back")
        XCTAssertEqual(restored.lines.first?.id, line.id,
                       "and it is the same line rather than a fresh one")
        XCTAssertEqual(restored.count, 2, "and it brought no extra card with it")
    }

    /// **⌫ with a line selected refuses while any gesture is open**, for the
    /// reason the card and region arms do: `beginGesture` takes no snapshot when
    /// it nests and `endGesture` registers nothing above depth 0, so a delete
    /// inside somebody else's bracket collapses into it under the wrong name —
    /// and if that bracket never closes it cannot be taken back at all.
    ///
    /// **The gesture is opened by hand, and that is a deliberate exception with
    /// a reason — read it before "fixing" it to a pointer sequence.**
    ///
    /// This test first drove the state the way the card arm's does: press and
    /// HOLD on the line, which used to leave the line selected while
    /// `onDrag(.began)` opened a "New Region" sweep. **The click/drag agreement
    /// fix closed that door.** A press on a line is now idle, so it opens no
    /// bracket at all — and every OTHER press moves the selection onto whatever
    /// is under it, so there is no pointer sequence left that ends with a line
    /// selected and a gesture open. That is the fix working, not a gap.
    ///
    /// So the bracket is opened directly and the KEY is still a real `NSEvent`
    /// through `window.sendEvent(_:)` — the delivery path is what the 1C-a
    /// defect was in, and it stays real. If a later gesture makes the state
    /// reachable again, the assertion is already here.
    func test_deleteWithALineSelectedMidGestureIsRefused() throws {
        let root = try twoCardProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        let line = try drawALine(in: window, model)

        // The door this used to come through, asserted rather than assumed —
        // so if a press on a line ever opens a bracket again, this says so
        // here rather than leaving the hand-driven setup looking arbitrary.
        var probe = CanvasInteraction()
        probe.begin(at: line.midpoint, in: model.scene, connecting: false)
        XCTAssertFalse(probe.isActive,
                       "a press on a line opens a gesture again — drive this test "
                       + "through the pointer instead of by hand")

        XCTAssertTrue(window.makeFirstResponder(events))
        XCTAssertEqual(model.selection, .line(line.id),
                       "precondition: the line the ⇧-drag made is still selected, so "
                       + "there is something for ⌫ to take")
        model.beginGesture("Move Scrap")
        XCTAssertTrue(model.isInGesture, "precondition: a bracket is open")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertEqual(model.scene.lines.count, 1,
                       "⌫ mid-gesture deleted the line from inside somebody else's "
                       + "undo bracket: it registers no step of its own, and a "
                       + "bracket that never closes takes the line with it")
        model.endGesture()
        pump(1.0)
        XCTAssertEqual(sceneOnDisk(root).lines.count, 1,
                       "the line came back only to go when the gesture ended")
    }

    /// A region at (100,100)–(500,400) with one resident, and a line crossing
    /// its chrome bar (y 100–124) at x = 300.
    ///
    /// The line's two cards sit above and below the region, both 120 wide at
    /// x = 240, so **both centres are at x = 300 whatever height the view
    /// re-derives** — the segment is vertical at that x and meets the bar at one
    /// place only. That is what makes a second sample along the same bar a real
    /// control rather than a second point on the line.
    private func lineCrossingARegionsBarRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 150, y: 200),
                                width: 240, cachedHeight: 38))
        scene.insert(CanvasNode(id: secondScrapID, kind: .scrap, origin: CGPoint(x: 240, y: 20),
                                width: 120, cachedHeight: 54))
        scene.insert(CanvasNode(id: farScrapID, kind: .scrap, origin: CGPoint(x: 240, y: 450),
                                width: 120, cachedHeight: 54))
        scene.insertLine(CanvasLine(id: crossingLineID, from: secondScrapID, to: farScrapID))
        scene.insertRegion(CanvasRegion(id: crossingRegionID, label: "Act II fog",
                                        frame: CGRect(x: 100, y: 100, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        return try projectRoot(scene: scene,
                               scraps: [scrapID: scrapText,
                                        secondScrapID: secondScrapText,
                                        farScrapID: farScrapText])
    }

    private let crossingLineID = CanvasLineID("cross")
    private let crossingRegionID = CanvasRegionID("r1")

    /// **The click and the drag must agree about what the press was.**
    ///
    /// Where a line crosses a region's chrome bar the click selects the LINE —
    /// it is drawn on top, and that is the whole of this slice's precedence
    /// rule. `CanvasInteraction.begin` had no line branch, so the same press
    /// fell through to `regionHit` and opened "Move Region": **select one thing,
    /// drag another.**
    ///
    /// It bites rather than being theoretical, which is why the drag here is one
    /// point. A trackpad press routinely drifts that far, and `endGesture`
    /// registers whenever the state moved — so the writer gets the region and
    /// every resident shifted under a step their next ⌘Z takes, while the
    /// inspector and ⌫ are still pointed at the line.
    ///
    /// **The undo assertion is not decoration.** The frames alone can pass while
    /// a step still lands, and a stray step is the half the writer meets later,
    /// on a ⌘Z aimed at something else.
    ///
    /// The control is the same bar, the same drag, 150 pt along it and clear of
    /// the line: without it "nothing moved" is satisfied by a build where a
    /// region can no longer be dragged at all.
    func test_aPressWhereALineCrossesARegionsBarMovesNeitherAndPushesNoUndoStep() throws {
        let root = try lineCrossingARegionsBarRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        let crossing = CGPoint(x: 300, y: 112)
        XCTAssertEqual(model.scene.selectionTarget(at: crossing),
                       .line(crossingLineID),
                       "precondition: the click resolves to the line here — which is "
                       + "the whole reason the drag must not resolve to the region")
        XCTAssertEqual(CanvasInteraction.regionHit(at: crossing, in: model.scene),
                       .chrome(crossingRegionID),
                       "precondition: and the region's chrome bar is genuinely under "
                       + "the same point, so this is the disagreement and not an "
                       + "absent region")
        let frameBefore = try XCTUnwrap(model.scene.region(crossingRegionID)?.frame)
        let residentBefore = try XCTUnwrap(model.scene.node(scrapID)?.origin)

        // A press with a one-point drift — the ordinary trackpad click.
        drag(events, from: crossing, through: [CGPoint(x: crossing.x + 1, y: crossing.y + 1)])
        pump(1.0)

        XCTAssertEqual(model.scene.region(crossingRegionID)?.frame, frameBefore,
                       "a press on the line moved the REGION: the click selected the "
                       + "line and the drag picked up the region under it")
        XCTAssertEqual(model.scene.node(scrapID)?.origin, residentBefore,
                       "and it carried the region's resident with it — the card the "
                       + "writer was not touching moved because of where they clicked")
        XCTAssertEqual(model.selection, .line(crossingLineID),
                       "and the line is what they are holding, which is exactly why "
                       + "the region moving is a disagreement rather than a choice")
        XCTAssertFalse(try XCTUnwrap(events.undoManager).canUndo,
                       "the press pushed an undo step for a gesture the writer never "
                       + "made: their next ⌘Z takes back a region move instead of "
                       + "whatever they were actually doing")
        XCTAssertEqual(sceneOnDisk(root).region(crossingRegionID)?.frame, frameBefore,
                       "and it reached disk")

        // The control: the same bar, the same drift, clear of the line.
        let alongTheBar = CGPoint(x: crossing.x + 150, y: crossing.y)
        XCTAssertNil(CanvasLineHit.line(at: alongTheBar, in: model.scene),
                     "precondition: this end of the bar is clear of the line")
        drag(events, from: alongTheBar,
             through: [CGPoint(x: alongTheBar.x + 40, y: alongTheBar.y + 30)])
        pump(1.0)

        XCTAssertNotEqual(model.scene.region(crossingRegionID)?.frame, frameBefore,
                          "the region can no longer be dragged by its bar at all — "
                          + "\"the line wins\" must cost the bar the width of the "
                          + "line, not the whole of it")
        XCTAssertTrue(model.undo.undoMenuItemTitle.contains("Move Region"),
                      "and that drag is its own named step. Got: "
                      + model.undo.undoMenuItemTitle)
    }

    /// **A card delete takes its lines, and ONE ⌘Z brings both back** — one
    /// snapshot carries the scene, so they cannot be restored out of step.
    ///
    /// The card half is `CanvasScene.remove`'s line scrub, which is unit tested;
    /// what only this can show is that the scrub survives the delete path, the
    /// save, the reload and the codec — and that it did not become a second undo
    /// step the writer has to press ⌘Z twice for.
    func test_deletingACardTakesItsLinesAndOneUndoBringsBothBack() throws {
        let root = try twoCardProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)
        _ = try drawALine(in: window, model)

        clickAndFocusTheCanvas(events, at: insideTheFirstCard, in: window)
        XCTAssertEqual(model.selection, .node(scrapID),
                       "precondition: the card the line leaves is selected")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        let afterDelete = sceneOnDisk(root)
        XCTAssertNil(afterDelete.node(scrapID), "precondition: the card went")
        XCTAssertTrue(afterDelete.lines.isEmpty,
                      "the line to the deleted card outlived it — it draws from a "
                      + "card that is not there to a card that is")

        let undoSelector = #selector(CanvasEventNSView.undo(_:))
        let undo = try editMenuItem(undoSelector, in: window)
        XCTAssertTrue(undo.item.title.contains("Delete Scrap"),
                      "the menu item reads \"\(undo.item.title)\" — the line scrub "
                      + "must ride inside the card's own step rather than becoming a "
                      + "second one")
        _ = undo.target.perform(undoSelector, with: undo.item)
        pump(1.0)

        let restored = sceneOnDisk(root)
        XCTAssertNotNil(restored.node(scrapID), "⌘Z did not bring the card back")
        XCTAssertEqual(restored.lines.count, 1,
                       "the card came back without its line: one ⌫ is one gesture, so "
                       + "one ⌘Z has to restore both — a second step here means the "
                       + "writer's canvas can be left with a card whose connections "
                       + "are one keystroke behind it")
    }

    /// **A card added from OUTSIDE the canvas is measured by the hosted view**,
    /// which is the whole reason `CanvasModel.onSceneChangedExternally` exists
    /// (1C-c3 Task 4).
    ///
    /// The census in `CanvasLiveSeamTests` proves the binding line is written in
    /// `CanvasView.load()`. It cannot prove the closure ever RUNS — a binding
    /// moved into a branch `load()` does not reach, a `load()` no longer called
    /// from `.onAppear`, or a `rebuildLayouts` that stops measuring new nodes all
    /// leave a text census green. That gap is this area's most expensive recorded
    /// mistake: 1C-a shipped ⌘Z twenty-two green tests deep and greyed out in the
    /// Edit menu, because every one of those tests drove the recorder directly.
    /// So this drives the EMITTER, through a real hosted `CanvasView`.
    ///
    /// What it asserts is the failure, not the mechanism: an unmeasured node has
    /// no `cachedHeight`, so it has no `frame`, so `drawCard` gets a nil layout
    /// and `topmostNode(at:)` drops it — **an empty rectangle the writer cannot
    /// click**, until they happen to do something else that rebuilds.
    ///
    /// Falsified by disabling the binding: comment out
    /// `model.onSceneChangedExternally` in `CanvasView.load()` and the height
    /// assertion goes red with `cachedHeight` nil.
    ///
    /// **The words go IN the bracket, through `scrapTexts:`** — the ordering
    /// `mutateFromInspector`'s doc requires of any caller writing both, and the
    /// only one that is safe. Two things ride on it, and the second is why this
    /// test was rewritten in 1C-c3 Task 5's fix round:
    ///
    /// - The hook measures each card from the words it finds, so a card measured
    ///   before its text arrives is measured empty. Asserting the height equals
    ///   `CanvasScrapMeasure.height(text:cardWidth:)` is what makes that visible —
    ///   a card measured empty is a different number, not a nil.
    /// - Written with `setScrapText` BEFORE the call — which is how this test was
    ///   first written, following the doc as it then stood — the words are folded
    ///   in *before* `beginGesture` takes its snapshot, so undoing "Add Scrap"
    ///   removes the card and **leaves its text in `scraps`**: an orphan entry
    ///   `ScrapText.render` writes into `canvas.md` for good. The census in
    ///   `TripwireGrepTests` scans `Maugham/` only, so a test demonstrating the
    ///   forbidden ordering is invisible to it — which is exactly what happened.
    func test_aCardAddedFromOutsideTheCanvasIsMeasuredByTheHostedView() throws {
        let model = CanvasModel()
        host(CanvasView(model: model, projectRoot: try projectRoot(),
                        paletteSwatchHexes: { [] }))
        XCTAssertNotNil(model.scene.node(scrapID)?.cachedHeight,
                        "precondition: load() measured the fixture's own card")

        let added = CanvasNodeID("mcp1")
        let text = "a card from the other side of the window"
        model.mutateFromInspector("Add Scrap", scrapTexts: [added: text]) {
            $0.insert(CanvasNode(id: added, kind: .scrap,
                                 origin: CGPoint(x: 400, y: 300), width: 240))
        }
        pump()

        let node = try XCTUnwrap(model.scene.node(added), "the applier's own write")
        XCTAssertEqual(node.cachedHeight,
                       CanvasScrapMeasure.height(text: text, cardWidth: 240),
                       "the card arrived unmeasured and stayed that way: it has no "
                       + "frame, so it draws as an empty rectangle and hit testing "
                       + "cannot see it at all")
        let frame = try XCTUnwrap(node.frame)
        XCTAssertEqual(model.scene.topmostNode(at: CGPoint(x: frame.midX, y: frame.midY))?.id,
                       added,
                       "measured but not clickable — which is the same failure the "
                       + "writer meets, reached through hit testing instead of the "
                       + "draw pass")
    }
}
