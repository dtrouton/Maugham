import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The shared harness for the `CanvasViewMounting…` family. This class holds
/// the window plumbing, the fixtures and every shared helper; it deliberately
/// holds NO tests, because XCTest runs a base class's tests once per subclass.
/// The 105 tests live in three subclasses, split so Xcode's per-class parallel
/// scheduling can spread them across workers rather than pinning the whole
/// suite's wall time to one:
///
/// - `CanvasViewMountingSurfaceTests` — the mount itself, the cards it draws,
///   and the accessibility tree it publishes.
/// - `CanvasViewMountingEditingTests` — typing, undo, save, Escape, ⌫ and
///   selection.
/// - `CanvasViewMountingRegionTests` — sweeps, regions, membership and lines.
///
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
class CanvasViewMountingCase: XCTestCase {

    /// Keep the window alive for the length of the test — a released window
    /// drops first responder and the assertion becomes a coin flip.
    var windows: [NSWindow] = []
    var roots: [URL] = []

    let scrapID = CanvasNodeID("s1")
    let scrapText = "the falls at night"

    /// A second card, down and to the right of the first, and a third far outside
    /// any viewport. Both exist so the published FRAMES can be compared against
    /// each other — see `test_twoCardsInDifferentPlacesPublishDifferentFrames`.
    let secondScrapID = CanvasNodeID("s2")
    let secondScrapText = "and the lit bridge"
    let farScrapID = CanvasNodeID("far")
    let farScrapText = "ninety thousand points east"

    /// A scrap chosen so that NARROWING it to the resize floor actually rewraps.
    ///
    /// `scrapText` cannot do that job and no assertion should pretend otherwise:
    /// measured through `ScrapLayout`'s own stack at Iowan Old Style 13, "the
    /// falls at night" is 94.62pt wide, so it still sits on ONE line inside the
    /// 100pt text box of a card at `CanvasInteraction.minimumCardWidth`. Its
    /// card is 38pt tall at every width from 240 down to the floor.
    ///
    /// This string, measured the same way: 2 lines and a 54pt card at the
    /// fixture's 240pt width, 4 lines and an 88pt card once narrowed. The 34pt
    /// of new card below the old bottom edge is what
    /// `test_aCardBeingResizedStaysOnTheCanvasForTheWholeDrag` reads, and the
    /// margin is deliberate — the height is 88 at every card width from 124 down
    /// to the 120 floor, so the exact pixel the drag lands on does not decide the
    /// result.
    let rewrappingScrapText = "the falls at night seen from the road below the town"

    /// A test's own planted key monitors. Removed here rather than at the end of
    /// each test because a leaked one eats Escapes for the rest of the suite, and
    /// an eaten Escape is exactly the defect these tests are about.
    var probeTokens: [Any] = []

    override func tearDown() {
        for token in probeTokens { NSEvent.removeMonitor(token) }
        probeTokens.removeAll()
        windows.removeAll()
        models.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    /// A project on disk holding one measured scrap at a known place. Written
    /// through `CanvasStore` itself, so the fixture cannot drift from the format
    /// the view will read.
    func projectRoot() throws -> URL {
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
    func rewrappingScrapProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap,
                                origin: CGPoint(x: 20, y: 20), width: 240,
                                cachedHeight: 54))
        return try projectRoot(scene: scene, scraps: [scrapID: rewrappingScrapText])
    }

    /// An empty directory — no canvas on disk at all, which is the state a writer
    /// meets the first time they open the Plan persona on a project.
    func emptyProjectRoot() throws -> URL {
        try makeRoot()
    }

    /// **A board that already has an arrangement on it** — which is the state
    /// §4.1's assign case is about, and the one no other fixture here provides.
    ///
    /// - `r1` at (300,300)–(500,450), centre **(400,375)**.
    /// - The fixture card at (320,330)–(560,368), centre **(440,349)**, living
    ///   in `r1`. It overhangs `r1`'s right edge on purpose: membership is
    ///   stored and geometry means nothing, so a test that watched a card
    ///   neatly inside its region could not tell the two apart.
    /// - A second card at (300,452)–(540,490), centre **(420,471)**, LOOSE —
    ///   just below `r1`'s bottom edge, so it is inside the swept rect and in
    ///   no region. It is what a create-instead-of-assign would absorb.
    ///
    /// Every centre is inside the rect swept from (280,280) to (600,500), and
    /// (280,280) itself is outside every region — `CanvasInteraction.begin`
    /// refuses to start a sweep inside one.
    func arrangedBoardRoot(bound piece: String? = nil) throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 320, y: 330),
                                width: 240, cachedHeight: 38))
        scene.insert(CanvasNode(id: secondScrapID, kind: .scrap,
                                origin: CGPoint(x: 300, y: 452),
                                width: 240, cachedHeight: 38))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 300, y: 300, width: 200, height: 150),
                                        homeMembers: [scrapID],
                                        boundPieceID: piece))
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText,
                                                      secondScrapID: secondScrapText])
    }

    /// Two unbound regions, far apart, both caught by a sweep from (60,60) to
    /// (760,560) — `r1`'s centre is (175,160) and `r2`'s is (575,410). No cards:
    /// what this fixture is for is *several regions bound in one act*.
    func twoRegionBoardRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act I",
                                        frame: CGRect(x: 100, y: 100, width: 150, height: 120)))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Act II",
                                        frame: CGRect(x: 500, y: 350, width: 150, height: 120)))
        return try projectRoot(scene: scene, scraps: [:])
    }

    /// One measured card at (20,20)–(260,58), centre (140,39), and one region
    /// wherever the caller wants it — for the two tests that drag a region onto
    /// a card it must not absorb. The card is NOT a member: what those tests
    /// watch is whether a transition makes it one.
    func cardAndRegionRoot(regionFrame: CGRect) throws -> URL {
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
    func regionProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 60, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText])
    }

    func projectRoot(scene: CanvasScene,
                             scraps: [CanvasNodeID: String]) throws -> URL {
        let root = try makeRoot()
        CanvasStore(projectRoot: root).save(scene: scene, scraps: scraps)
        return root
    }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// SwiftUI mounts representables and applies state changes on the main
    /// runloop, so nothing here is observable until the loop has turned.
    func pump(_ seconds: TimeInterval = 0.2) {
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
    func waitOut(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { pump(0.1) }
    }

    /// The suite's clocks: the REAL timers on the REAL paths, only shorter —
    /// the same debounce mechanism `CanvasStore` runs in production, at 50 ms
    /// instead of 750, and the same idle beat at 0.5 s instead of 1.5. The
    /// ORDER is preserved (debounce < idle), which
    /// `test_quittingAfterAPauseFoldsTheTextInWithoutMovingAnUndoBoundary`
    /// depends on exactly the way production does. The idle beat is the less
    /// aggressive of the two on purpose: the sentence-boundary test types
    /// with 0.05 s pumps between runs that must NOT read as pauses, and 0.5
    /// keeps that a 10× margin under load. The production defaults stay
    /// covered where they are read: `CanvasModelTests` pins them.
    static let testDebounce: TimeInterval = 0.05
    static let testUndoIdle: TimeInterval = 0.5

    /// Every model this test minted, so `pumpUntilSaved()` can ask all of
    /// them without each call site having to name one.
    var models: [CanvasModel] = []

    func makeModel() -> CanvasModel {
        let model = CanvasModel()
        model.saveDebounceInterval = Self.testDebounce
        model.undoIdleInterval = Self.testUndoIdle
        models.append(model)
        return model
    }

    /// Pump until `condition` holds, giving up after `timeout` of wall clock.
    /// Giving up does NOT fail the test — the assertion that follows owns the
    /// failure and its message; this only stops a wait from hanging a run.
    func pump(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Wait for the debounced save to reach disk — the CONDITION the old
    /// `pump(1.0)` guessed at with wall clock. Two conditions, in order.
    ///
    /// First, nothing is still moving: a flick's coast writes a frame into
    /// the scene on every timeline tick, and the tick only happens while the
    /// loop is pumped — a save-only condition would return between mouse-up's
    /// debounce firing and the first coast frame, with the card still where
    /// the pointer let go. Stillness for 50 ms — three-plus ticks at any
    /// display rate — outlasts any coast that is going to continue.
    ///
    /// Then, no model holds a pending write. `flush()` writes synchronously,
    /// so "nothing pending" means "on disk". A test that scheduled nothing
    /// passes straight through, which is what the negative assertions
    /// ("nothing reached disk") want.
    func pumpUntilSaved() {
        // One short drain so an action whose save (or coast) starts on a
        // later run-loop turn has started before the conditions are read.
        pump(0.03)
        var snapshots = models.map(\.scene)
        var stillSince = Date()
        pump(until: {
            let now = models.map(\.scene)
            if now != snapshots { snapshots = now; stillSince = Date() }
            return Date().timeIntervalSince(stillSince) >= 0.05
        }, timeout: 3.0)
        pump(until: { models.allSatisfy { !$0.hasPendingSave } })
    }

    /// The words-are-safe tests keep the PRODUCTION clocks: each asserts the
    /// debounce has NOT fired in the beat between typing and quitting or
    /// leaving, and the shortened 50 ms debounce loses that race by design.
    /// Neither ever waits for the timer — they quit before it fires — so the
    /// slow interval costs them nothing.
    func makeModelOnProductionClocks() -> CanvasModel {
        let model = CanvasModel()
        models.append(model)
        return model
    }

    @discardableResult
    func host(_ view: CanvasView) -> CanvasHostWindow {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window = CanvasHostWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        windows.append(window)
        // The timeline that drives the straighten only advances when the window
        // is producing frames.
        //
        // **Key, not merely ordered front** — measured 2026-08-04:
        // `NSApp.sendEvent(_:)` routes a key event to the KEY window and drops it
        // when there is none, so with `orderFront` alone every assertion about an
        // Escape REACHING this window is vacuously true.
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    /// A canvas with a rename `TextField` beside it in the same window — the
    /// binder's inline rename (tripwire 16) reduced to the one thing that matters
    /// to a key monitor: a real AppKit text responder in the window the dim is in.
    @discardableResult
    func hostBesideARenameField(_ view: CanvasView) -> CanvasHostWindow {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hosting = NSHostingView(rootView: CanvasBesideARenameField(canvas: view))
        hosting.frame = frame
        let window = CanvasHostWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        windows.append(window)
        // Key for the reason `host` records.
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    /// A canvas whose subject the test can change afterwards — the tree selecting
    /// the project row, from outside. `CanvasView.subject` is a value handed in on
    /// every body pass, so nothing else can drive an undim for real.
    @discardableResult
    func hostSwitchable(subject: MutableSubject,
                                root: URL,
                                selectTheProjectRow: @escaping () -> Void) -> CanvasHostWindow {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hosting = NSHostingView(rootView: CanvasWithASwitchableSubject(
            subject: subject, model: makeModel(), root: root,
            selectTheProjectRow: selectTheProjectRow))
        hosting.frame = frame
        let window = CanvasHostWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        windows.append(window)
        // Key for the reason `host` records.
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    /// A counterfactual monitor — what a production monitor missing a guard would
    /// do, in the same position, read by the same instrument.
    ///
    /// This is what makes the two scope/guard tests falsifiable: without a plant
    /// they pass identically against a monitor that was never installed.
    ///
    /// **Order-independent, and that is not free.** Local monitor invocation order
    /// is NOT stable — measured 2026-08-04 on macOS 26.5, the same two monitors
    /// installed in the same order in one process were invoked B,A and then A,B.
    /// So nothing here may depend on running before or after the production one.
    /// It does not have to: ANY monitor returning nil stops the event before a
    /// window sees it, and the window is what `CanvasHostWindow` counts.
    func plantAMonitor(_ decide: @escaping (NSEvent) -> NSEvent?) {
        let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers == CanvasEventNSView.escape else {
                return event
            }
            return decide(event)
        }
        if let token { probeTokens.append(token) }
    }

    func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstDescendant(type, in: sub) { return hit }
        }
        return nil
    }

    func eventView(in window: NSWindow) throws -> CanvasEventNSView {
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
    func drag(_ events: CanvasEventNSView,
                      from start: CGPoint,
                      through path: [CGPoint]) {
        events.applyMouseDown(at: start, clickCount: 1)
        for point in path { events.applyMouseDragged(to: point) }
        events.applyMouseUp(at: path.last ?? start)
    }

    /// Take the canvas down so `.onDisappear` flushes the store, then read what
    /// reached disk.
    func savedScene(after window: NSWindow, root: URL) -> CanvasScene {
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
    func doubleClickTheScrap(in window: NSWindow,
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

    /// The container's box in SwiftUI's coordinate space — top-left origin, y
    /// downward, which is the space `CanvasCamera` maps into. `CanvasView`
    /// positions the container at `camera.viewPoint(fromContent: textOrigin)` and
    /// sizes it `textSize * camera.zoom`, so this one rect carries both camera
    /// terms and a before/after pair recovers the zoom.
    func swiftUIFrame(of view: NSView, in root: NSView) -> CGRect {
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
    func ink(in box: CGRect, of hosted: NSView) throws -> Int {
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

    /// Two owned item nodes, the second added while the canvas is on screen. The
    /// first one's file is written or not, which is the only difference.
    func assertTheSecondPhotographDecodes(firstImageIsReadable: Bool) throws {
        let firstPath = "canvas_assets/image-20260731-000001.png"
        let secondPath = "canvas_assets/image-20260731-000002.png"
        let firstID = CanvasNodeID("owned-1"), secondID = CanvasNodeID("owned-2")

        var fixture = CanvasScene()
        fixture.insert(CanvasNode(id: firstID, kind: .item(.owned(path: firstPath)),
                                  origin: CGPoint(x: 40, y: 40), width: 240,
                                  cachedHeight: nil))
        let root = try projectRoot(scene: fixture, scraps: [:])
        if firstImageIsReadable {
            try writeCanvasFixtureImage(width: 400, height: 300,
                                        to: root.appendingPathComponent(firstPath))
        }

        let model = makeModel()
        host(CanvasView(model: model, projectRoot: root, paletteSwatchHexes: { [] }))
        pump()
        XCTAssertEqual(try XCTUnwrap(model.scene.node(firstID)).cachedHeight
                           == CanvasCardMetrics.itemLabelOnlyHeight,
                       !firstImageIsReadable,
                       "precondition: the first card is at the floor exactly when its "
                       + "photograph was unreadable, so the two arms of this test "
                       + "differ in the thing they claim to")

        // The second photograph is written BEFORE the node arrives, so the only
        // question this asks is whether the servicing schedule woke up.
        try writeCanvasFixtureImage(width: 400, height: 300,
                                    to: root.appendingPathComponent(secondPath))
        model.mutateFromInspector("Add Card") { scene in
            scene.insert(CanvasNode(id: secondID, kind: .item(.owned(path: secondPath)),
                                    origin: CGPoint(x: 400, y: 40), width: 240,
                                    cachedHeight: nil))
        }
        pump()

        let height = try XCTUnwrap(try XCTUnwrap(model.scene.node(secondID)).cachedHeight)
        XCTAssertGreaterThan(height, CanvasCardMetrics.itemLabelOnlyHeight,
                             "the second photograph never decoded (height \(height)) — "
                             + "the servicing schedule stalled, and every photograph "
                             + "dropped on this canvas from here on is a blank card")
        XCTAssertEqual(height,
                       CanvasCardMetrics.itemCardHeight(forCardWidth: 240,
                                                        pictureAspect: 4.0 / 3.0),
                       accuracy: 1.5,
                       "the second card's height is not its photograph's shape")
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
    ///
    /// **It reports what actually happened, and until 2026-07-31 it did not.**
    /// The query's result was discarded and the closure returned `true`
    /// unconditionally — a check that could not fail. Every caller below was
    /// therefore told the client was attached whatever the process answered, and
    /// on a machine with no GUI session that call failing is exactly the expected
    /// outcome: the tests would have gone on asserting against a tree that was
    /// never built, and reported the attachment as fine while doing it.
    private struct AssistiveClient {
        let error: AXError
        let role: String?

        var isAttached: Bool { error == .success }

        /// Spelled out in full, because this string is the whole of what a CI run
        /// gets to tell us about a machine nobody can log in to and watch.
        var description: String {
            "AXUIElementCopyAttributeValue(kAXRoleAttribute) returned "
                + "\(error.rawValue) (\(error == .success ? "success" : "failure")), "
                + "role \(role.map { "\"\($0)\"" } ?? "nil")"
        }
    }

    private static let assistiveClient: AssistiveClient = {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                  kAXRoleAttribute as CFString, &role)
        return AssistiveClient(error: error, role: role as? String)
    }()

    /// Every accessibility element under the window's content view, in tree
    /// order — the tree an assistive client walks, which is the only place the
    /// question "can a VoiceOver user reach this" can honestly be asked.
    ///
    /// It SKIPS rather than failing when no client could be attached, and the
    /// reason names the failure the query returned. A tree that was never built
    /// is not evidence about this view: every assertion below would fail, all of
    /// them for the same reason, and none of them about the canvas.
    func axTree(in window: NSWindow) throws -> [AnyObject] {
        let client = Self.assistiveClient
        guard client.isAttached else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never builds the tree these tests read and there is nothing here "
                + "to ask. \(client.description)")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
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
    func axChildren(of element: AnyObject) -> [AnyObject] {
        axAttribute(element, "accessibilityChildren") as? [AnyObject] ?? []
    }

    func axString(_ element: AnyObject, _ attribute: String) -> String? {
        axAttribute(element, attribute) as? String
    }

    func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    /// Three cards at known, different places, so the published frames have
    /// something to be compared against — including one at (90 000, 90 000),
    /// which no viewport will ever hold.
    func threeCardProjectRoot() throws -> URL {
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

    /// The role every card is published under. Naming it in the lookup is not
    /// extra strictness — it is the same contract `CanvasAXChildren` applies
    /// `.isStaticText` for, and that modifier's own comment records what happens
    /// without it: role `AXUnknown`, and the writer's sentence filed under
    /// `accessibilityValueDescription` where nothing reads it.
    static let cardRole = NSAccessibility.Role.staticText.rawValue

    /// The synthetic element standing for one card.
    ///
    /// **Matching on the value alone was a real hole, and it is the shape of the
    /// 2026-07-31 CI failure.** `axElements` walks from the content view down, so
    /// `first` reaches the two AXGroups that span the whole window — the hosting
    /// view and the canvas itself — before it reaches any card. An ancestor that
    /// carries a descendant's value for any reason is therefore matched FIRST,
    /// and answers with the container's rectangle: the exact reading these tests
    /// exist to catch, produced by the lookup rather than by the code under test.
    /// Naming the role asks for the element an assistive client would actually
    /// land on.
    func axCard(valued value: String, in tree: [AnyObject]) throws -> AnyObject {
        let sameValue = tree.filter { axString($0, "accessibilityValue") == value }
        let cards = sameValue.filter { axString($0, "accessibilityRole") == Self.cardRole }
        return try XCTUnwrap(
            cards.first,
            "no element under role \(Self.cardRole) carries \"\(value)\", so that "
            + "card is not separately reachable — an assistive client has the "
            + "words and whatever rectangle the container it was folded into "
            + "happens to have. \(sameValue.count) element(s) carry that value at "
            + "any role.\n\(describe(tree))")
    }

    /// The element standing for the canvas itself — the container every card is
    /// published inside, and the rectangle a folded card comes back carrying.
    ///
    /// Found by its LABEL rather than by its position in the walk: the walk's
    /// first element is the `NSHostingView`, which is SwiftUI's wrapper rather
    /// than anything this view declared, and on the platform where the fold was
    /// measured all three elements report the same rect anyway. Asking for the
    /// one carrying `CanvasAccessibility.canvasLabel` names the container this
    /// view actually built.
    func axCanvas(in tree: [AnyObject]) throws -> AnyObject {
        try XCTUnwrap(
            tree.first { axString($0, "accessibilityLabel") == CanvasAccessibility.canvasLabel },
            "the canvas itself is not in the published tree, so there is no "
            + "container to compare a card against.\n\(describe(tree))")
    }

    /// Whether two published rectangles are the same rectangle.
    ///
    /// A tolerance rather than `==` because both sides arrive through two
    /// coordinate conversions. Half a point is far below what this is asked to
    /// tell apart — a card is 240 × 60 and the canvas it sits on is 800 × 600 —
    /// so it cannot call a correctly published card its own container.
    func isSameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// The whole observed tree, one element per line.
    ///
    /// Every failure below carries this, deliberately. These two tests passed on
    /// every developer machine and failed on CI for five days, and the report
    /// that came back — an origin and a width — could not distinguish a canvas
    /// that published no card elements at all from one that published them at the
    /// wrong place. A message nobody can reproduce has to carry its own evidence.
    func describe(_ tree: [AnyObject]) -> String {
        let rows = tree.map { element -> String in
            let frame = (axAttribute(element, "accessibilityFrame") as? NSValue)?.rectValue
            return "  \(Swift.type(of: element))"
                + " role=\(axString(element, "accessibilityRole") ?? "nil")"
                + " label=\(axString(element, "accessibilityLabel").map { "\"\($0)\"" } ?? "nil")"
                + " value=\(axString(element, "accessibilityValue").map { "\"\($0)\"" } ?? "nil")"
                + " valueDescription="
                + (axString(element, "accessibilityValueDescription").map { "\"\($0)\"" } ?? "nil")
                + " frame=\(frame.map { "\($0)" } ?? "nil")"
        }
        return "Observed tree, \(tree.count) element(s); \(Self.assistiveClient.description); "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString):\n"
            + rows.joined(separator: "\n")
    }

    /// Where an assistive client would actually point, in the space
    /// `CanvasAXElement.viewFrame(in:)` speaks.
    ///
    /// A published `accessibilityFrame` is in SCREEN coordinates with y UP; the
    /// element list is in the hosted root's SwiftUI space with y DOWN. Both
    /// conversions are here rather than in the assertions so that a test reading
    /// `(20, 20)` is reading the same numbers the fixture wrote.
    func viewFrame(ofPublished element: AnyObject, in window: NSWindow) throws -> CGRect {
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

    // MARK: - The dim is audible (§4, slice 3 task 7)

    /// A project holding a region bound to `ch1` with `s1` living in it, and `s2`
    /// loose on bare canvas outside every region. Under `.piece("ch1")` the first
    /// is lit and the second is dimmed.
    func boundRegionProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 60, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insert(CanvasNode(id: secondScrapID, kind: .scrap,
                                origin: CGPoint(x: 60, y: 420), width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "ch1", in: &scene)
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText,
                                                      secondScrapID: secondScrapText])
    }

    /// The label an assistive client would actually be handed for a card.
    func axLabel(ofCardValued value: String, in window: NSWindow) throws -> String {
        let element = try axCard(valued: value, in: try axTree(in: window))
        return try XCTUnwrap(axString(element, "accessibilityLabel"),
                             "the card publishes no label at all")
    }

    /// Swap the subject the way the window does — a new `let` on the same view,
    /// in the same place in the hierarchy, so the canvas's `@State` survives it
    /// exactly as it does when the writer clicks a row in the binder.
    @MainActor
    func retarget(_ window: NSWindow, at subject: CanvasSubject) throws {
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<CanvasView>,
                                    "the window is not hosting a CanvasView, so there "
                                    + "is no subject to change")
        hosting.rootView.subject = subject
        pump()
    }

    // MARK: - ⌘Z, on the real surface

    /// One character at a time, at the end of the text, so every keystroke fires
    /// its own `textDidChange` — which is where `syncActiveEdit` asks
    /// `ScrapUndoBeat` its two questions. A single `insertText` of the whole run
    /// would be ONE change and would test nothing about coalescing.
    func type(_ text: String, into editor: NSTextView) {
        for character in text {
            let end = (editor.string as NSString).length
            editor.insertText(String(character), replacementRange: NSRange(location: end, length: 0))
        }
    }

    /// Whatever the writer is looking at, after a rebind has replaced the text
    /// view underneath the container.
    func mountedText(in window: NSWindow) throws -> String {
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
    func sceneOnDisk(_ root: URL) -> CanvasScene {
        CanvasStore(projectRoot: root).load().scene
    }

    /// The other half of what a delete has to reach: `canvas.md` is the ONLY
    /// place a scrap's words live, so a card removed from the scene while its
    /// text stays behind leaves an orphan paragraph in the writer's file.
    func scrapsOnDisk(_ root: URL) -> [CanvasNodeID: String] {
        CanvasStore(projectRoot: root).load().scraps
    }

    /// A real Escape, built the way AppKit delivers one — 0x1B in
    /// `charactersIgnoringModifiers`, which is what `CanvasEventNSView.keyDown`
    /// switches on. Key code 53.
    func escapeKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)!
    }

    /// A real ⌫, built the way AppKit delivers one. `charactersIgnoringModifiers`
    /// is what `CanvasEventNSView.keyDown` switches on, so it is what this has to
    /// carry, and the window number is what lets `window.sendEvent(_:)` route it.
    func deleteKeyEvent(for window: NSWindow) -> NSEvent {
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
    func clickAndFocusTheCanvas(_ events: CanvasEventNSView,
                                        at point: CGPoint,
                                        in window: NSWindow) {
        events.applyMouseDown(at: point, clickCount: 1)
        events.applyMouseUp(at: point)
        XCTAssertTrue(window.makeFirstResponder(events),
                      "the canvas cannot hold first responder, so no key the "
                      + "writer presses can ever reach it")
        pump()
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
    func editMenuTarget(_ selector: Selector, in window: NSWindow) -> NSObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: selector) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    /// The Edit menu item for `selector`, resolved and validated the way AppKit
    /// does — including letting the validator rewrite the item's `title`, which
    /// is how "Undo" becomes "Undo Move Card".
    func editMenuItem(_ selector: Selector,
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

    // MARK: - Drawing a line, through real events

    /// Two measured cards, well apart: the fixture scrap at (20,20) and a second
    /// at (400,200), both 240 wide.
    ///
    /// The heights here are the measured ones, but the view re-derives them on
    /// load — so every test below reads the LIVE frame out of the scene rather
    /// than arithmetic of its own. The connect target in particular is clamped
    /// against the card's height, and a test that computed it from the fixture
    /// would be aiming at a card that is not there.
    func twoCardProjectRoot() throws -> URL {
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
    func mouseEvent(_ type: NSEvent.EventType,
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
    func sendRealDrag(in window: NSWindow,
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
    func sendRealClick(in window: NSWindow, at point: CGPoint) throws {
        try sendRealDrag(in: window, from: point, through: [], shift: false)
    }

    /// Where the connect mark is on a card, read off the live scene.
    func connectMarkCentre(of id: CanvasNodeID, in model: CanvasModel) throws -> CGPoint {
        let frame = try XCTUnwrap(model.scene.node(id)?.frame,
                                  "the card is unmeasured, so it has no mark and no "
                                  + "frame to put one on")
        let target = CanvasRenderer.connectHandleRect(inCard: frame)
        XCTAssertFalse(target.isNull,
                       "precondition: this card is tall enough to carry a connect "
                       + "mark above its resize corner")
        return CGPoint(x: target.midX, y: target.midY)
    }

    let insideTheFirstCard = CGPoint(x: 60, y: 30)
    let insideTheSecondCard = CGPoint(x: 440, y: 215)

    // MARK: - Selecting a line, and taking it back

    /// A canvas with the two fixture cards and one line between them, drawn the
    /// way the writer draws it — a ⇧-drag through the real event path, which is
    /// also what leaves the line SELECTED.
    ///
    /// Returns the line's id and the midpoint of its segment, both read off the
    /// live scene. The cards' heights are re-derived on load, so a hard-coded
    /// midpoint would be aiming at a line that is not there.
    func drawALine(in window: NSWindow,
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

    /// A region at (100,100)–(500,400) with one resident, and a line crossing
    /// its chrome bar (y 100–124) at x = 300.
    ///
    /// The line's two cards sit above and below the region, both 120 wide at
    /// x = 240, so **both centres are at x = 300 whatever height the view
    /// re-derives** — the segment is vertical at that x and meets the bar at one
    /// place only. That is what makes a second sample along the same bar a real
    /// control rather than a second point on the line.
    func lineCrossingARegionsBarRoot() throws -> URL {
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

    let crossingLineID = CanvasLineID("cross")
    let crossingRegionID = CanvasRegionID("r1")
}

/// A canvas with a rename field beside it — see `hostBesideARenameField`.
///
/// `HStack` and not `ZStack`: the field must be reachable and focusable, not
/// stacked under a canvas that fills the window.
private struct CanvasBesideARenameField: View {
    let canvas: CanvasView

    var body: some View {
        HStack(spacing: 0) {
            TextField("rename", text: .constant("Chapter One"))
                .frame(width: 160)
            canvas
        }
    }
}

/// The tree's subject, changeable from a test. `@Observable` rather than a
/// `@State` the test cannot reach: what has to be driven is a subject change
/// arriving from OUTSIDE the canvas, which is how the real one arrives.
@Observable
final class MutableSubject {
    var value: CanvasSubject = .piece("ch1")
}

private struct CanvasWithASwitchableSubject: View {
    let subject: MutableSubject
    let model: CanvasModel
    let root: URL
    let selectTheProjectRow: () -> Void

    var body: some View {
        CanvasView(model: model, projectRoot: root, paletteSwatchHexes: { [] },
                   subject: subject.value, selectTheProjectRow: selectTheProjectRow)
    }
}

/// **The instrument for "the Escape travelled on", and it is a WINDOW rather
/// than a second monitor for a measured reason.**
///
/// A key the canvas declined and a key it silently swallowed are identical from
/// every other vantage point in these tests: both leave the subject unchanged.
/// The first draft read the difference off a probe monitor installed before the
/// canvas, on the belief that local monitors run most-recently-installed first.
/// **They do not run in a stable order at all** — measured 2026-08-04 on macOS
/// 26.5, the same two monitors installed in the same order twice in one process
/// were invoked B,A and then A,B, and the suite failed intermittently in three
/// different tests before that was measured rather than assumed.
///
/// What IS deterministic: a monitor returning `nil` stops the event before ANY
/// window sees it. So the window's own `sendEvent` is the honest counter, and it
/// is also the truer question — `NSWindow` is precisely the responder that took
/// the writer's first Escape out of full screen.
final class CanvasHostWindow: SilentTestWindow {
    private(set) var escapesDelivered = 0

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.charactersIgnoringModifiers == CanvasEventNSView.escape {
            escapesDelivered += 1
        }
        super.sendEvent(event)
    }
}
