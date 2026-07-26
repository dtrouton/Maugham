import XCTest
import AppKit
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
