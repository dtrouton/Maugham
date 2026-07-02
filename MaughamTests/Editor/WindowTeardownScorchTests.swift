import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// Regression net for the zombie-window teardown mitigation (workaround 1,
/// `docs/superpowers/notes/2026-07-02-scene-storage-spike.md`).
///
/// SwiftUI's `static GraphHost.sharedGraph` retains a closed `WindowGroup`
/// scene's view graph indefinitely, and `EditorSurface.dismantleNSView` never
/// runs on ⌘W. The mitigation empties the zombie ourselves: the coordinator
/// detaches via `MaughamTextView.viewWillMove(toWindow: nil)` (the path
/// `dismantleNSView` misses on close), and the heavy `@State` is scorched in
/// `.onDisappear`. The `@State` scorch needs a real window close and is verified
/// manually (heap/footprint A/B); the pieces pinned here are the two that ARE
/// headlessly drivable: `detach()` idempotency and the `viewWillMove` hook.
@MainActor
final class WindowTeardownScorchTests: XCTestCase {

    private func makeMaughamTextView(_ text: String = "Hello world") -> MaughamTextView {
        let tv = MaughamTextView()
        _ = tv.layoutManager  // pin TextKit 1, mirrors EditorSurface.makeNSView
        tv.string = text
        return tv
    }

    private func makeCoordinator(for tv: MaughamTextView) -> EditorCoordinator {
        let coord = EditorCoordinator(
            text: Binding(get: { tv.string }, set: { tv.string = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        tv.delegate = coord
        tv.coordinator = coord
        coord.attach(to: tv)
        return coord
    }

    /// (a) `detach()` is idempotent: calling it twice does not crash and leaves
    /// consistent state (detached, no text-view handle). On a piece flip BOTH
    /// `dismantleNSView` AND `viewWillMove(toWindow: nil)` fire, so a
    /// double-detach on one coordinator is a real production path.
    func test_detach_isIdempotent() {
        let tv = makeMaughamTextView()
        let coord = makeCoordinator(for: tv)

        coord.detach()
        XCTAssertTrue(coord.isDetached)
        XCTAssertNil(coord.textView)

        // Second call must be a clean no-op — no crash, state unchanged.
        coord.detach()
        XCTAssertTrue(coord.isDetached)
        XCTAssertNil(coord.textView)
    }

    /// (b) `MaughamTextView.viewWillMove(toWindow: nil)` detaches the coordinator.
    /// This is the window-close path `dismantleNSView` never takes (SwiftUI keeps
    /// the closed scene's graph), so the view-level hook is what breaks the
    /// coordinator↔text-view graph on ⌘W.
    func test_viewWillMoveToNilWindow_detachesCoordinator() {
        let tv = makeMaughamTextView()
        let coord = makeCoordinator(for: tv)
        XCTAssertFalse(coord.isDetached)
        XCTAssertTrue(coord.textView === tv)

        // Moving to a nil window == leaving the window (close/teardown).
        tv.viewWillMove(toWindow: nil)

        XCTAssertTrue(coord.isDetached, "leaving the window must detach the coordinator")
        XCTAssertNil(coord.textView, "detach drops the text-view handle")
    }

    /// (b′) Moving to a NON-nil window must NOT detach — only close/teardown
    /// (nil window) triggers the scorch; a normal mount is left alone.
    func test_viewWillMoveToRealWindow_doesNotDetach() {
        let tv = makeMaughamTextView()
        let coord = makeCoordinator(for: tv)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false  // test-owned window (see cycle tests)

        tv.viewWillMove(toWindow: window)

        XCTAssertFalse(coord.isDetached, "mounting into a real window must not detach")
        XCTAssertTrue(coord.textView === tv, "the coordinator keeps its text-view handle on mount")
    }
}
