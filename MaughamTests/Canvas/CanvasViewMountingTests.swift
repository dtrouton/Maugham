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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)

        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap,
                                origin: CGPoint(x: 20, y: 20), width: 240,
                                cachedHeight: 60))
        CanvasStore(projectRoot: root).save(scene: scene, scraps: [scrapID: scrapText])
        return root
    }

    /// SwiftUI mounts representables and applies state changes on the main
    /// runloop, so nothing here is observable until the loop has turned.
    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
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
                       + "axis-aligned glyphs over a card still up to 0.6° off, so "
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

        XCTAssertTrue(all.contains { axString($0, "accessibilityLabel") == CanvasAccessibility.canvasLabel },
                      "the canvas itself is not in the accessibility tree, so there "
                      + "is nothing for a VoiceOver user to land on and walk")
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
        let focused = window.value(forKey: "accessibilityFocusedUIElement") as AnyObject?
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
}
