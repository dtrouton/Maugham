import AppKit
import SwiftUI
import XCTest
@testable import Maugham

/// The one way a test builds a window.
///
/// **Every window in this bundle is constructed here, and a tripwire enforces
/// it** (`TripwireGrepTests.test_noWindowIsPresentedOutsideTheTestWindowFixture`).
/// Sixty files once built their own titled window at the screen's origin and
/// ordered it front; across seven parallel worker processes that was hundreds
/// of windows flashing in the corner of the developer's display for the length
/// of every gate, and nothing stopped the sixty-first file from doing the same.
///
/// A window made here is **real and hidden**: it is on screen — `isVisible`
/// true, `occlusionState` `.visible`, `screen` non-nil — so SwiftUI lays out,
/// `onAppear` fires, `TimelineView` ticks and key status is grantable exactly
/// as before; but it is drawn at `alphaValue` 0, ignores the real mouse (a
/// synthetic click posted through `NSApp` or sent to the window is unaffected
/// — `ignoresMouseEvents` is a window-server hit-testing flag), stays out of
/// Mission Control, ⌘\` and the Window menu, and animates nothing. Measured
/// 2026-08-27: the full Mac gate is green under this configuration with a skip
/// list identical to the visible one. Moving windows OFF screen was tried and
/// rejected in the same session — AppKit clamps a titled window's origin back
/// onto the screen, so "off-screen" silently meant "visible".
///
/// The process-level half is `TestHost` in the app, not here: no Dock tile,
/// no ⌘-tab entry, and a sweep that conceals every window the host shows
/// that this fixture never built — a sheet (its own child window at full
/// alpha, whatever its parent's; `DesignGateTests`' "Finalize this design"
/// dialog floated over the developer's desktop the first evening the gate
/// ran hidden), an alert panel, a popover, the app's own Welcome scene.
///
/// ## Silent by default
///
/// The default window class is `SilentTestWindow`, not `NSWindow`: AppKit
/// beeps once for every keystroke no responder claims, and the suites send
/// plenty of those on purpose (Escape at nothing, ⌫ with no selection). The
/// first hidden gate turned that from noise under the window-flashing into
/// the only thing the developer could hear. A suite has no reason to ask for
/// a plain `NSWindow`, and none does.
///
/// ## Activation is opt-in
///
/// Activating the host takes the developer's keyboard. So
/// ``activate(_:deadline:)`` — the only sanctioned way to ask — does nothing
/// unless `MAUGHAM_ALLOW_ACTIVATION=1` is in the environment (CI sets
/// `TEST_RUNNER_MAUGHAM_ALLOW_ACTIVATION=1`; the runner has nobody to
/// interrupt). Measured 2026-08-27: on an `.accessory` host a synthetic click
/// lands WITHOUT activation (`NSApp.isActive` false, another app frontmost,
/// `NSApp.keyWindow` nil, every `TreeTravelRowMountingTests` click green), so
/// a plain local gate runs the click-driving suites too; they skip BY NAME,
/// on a measurement, only where the click demonstrably fails — a locked
/// screen — the way `TreeTravelTests.click(at:)` always has.
enum TestWindow {
    /// How a made window is put on screen.
    enum Presentation {
        /// `orderFront` — the common case.
        case front
        /// `makeKeyAndOrderFront` — for a suite routing events through
        /// `NSApp.sendEvent`, which goes to the key window or nowhere.
        case key
        /// Built but never ordered in — for a suite that only needs a view to
        /// HAVE a window (an `NSTextView` before `insertText`, a
        /// `viewWillMove(toWindow:)` argument).
        case unshown
    }

    /// Make a window of `type`, hidden, and present it as asked.
    ///
    /// `type` is the window class a suite needs — `SilentTestWindow` (the
    /// default) for anything, `KeyTestWindow` when it must read as key without
    /// the app being active, `CanvasHostWindow`, a suite's own subclass — so
    /// each suite keeps its override while the presentation is the fixture's.
    /// `isReleasedWhenClosed` is always `false`: every window here is owned by
    /// Swift, and a `close()` under ARC otherwise over-releases.
    @discardableResult
    static func make<W: NSWindow>(
        _ type: W.Type = SilentTestWindow.self,
        contentRect: CGRect,
        styleMask: NSWindow.StyleMask = [.titled],
        deferred: Bool = false,
        contentView: NSView? = nil,
        present presentation: Presentation = .front
    ) -> W {
        let window = type.init(contentRect: contentRect, styleMask: styleMask,
                               backing: .buffered, defer: deferred)
        window.isReleasedWhenClosed = false
        if let contentView { window.contentView = contentView }
        conceal(window)
        present(window, as: presentation)
        return window
    }

    /// Mount a SwiftUI view in a hidden window whose content is `size`, laid
    /// out once. Callers pump the run loop themselves — how long, and until
    /// what, is the test's own premise.
    @discardableResult
    static func mount<W: NSWindow>(
        _ view: some View,
        size: CGSize,
        as type: W.Type = SilentTestWindow.self,
        styleMask: NSWindow.StyleMask = [.titled],
        present presentation: Presentation = .front
    ) -> W {
        let frame = CGRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window: W = make(type, contentRect: frame, styleMask: styleMask,
                             contentView: hosting, present: presentation)
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    /// Present (or re-present) a window the fixture built. The conceal is
    /// re-applied because AppKit resets nothing here but a suite that resized
    /// or re-styled the window may want the guarantee restated.
    static func present(_ window: NSWindow, as presentation: Presentation = .front) {
        conceal(window)
        switch presentation {
        case .front: window.orderFront(nil)
        case .key: window.makeKeyAndOrderFront(nil)
        case .unshown: break
        }
    }

    /// Whether this run may take the keyboard. Read from the environment, never
    /// from `NSApp.isActive` — a developer's front app yielding is not consent.
    static var activationAllowed: Bool {
        ProcessInfo.processInfo.environment["MAUGHAM_ALLOW_ACTIVATION"] == "1"
    }

    /// Ask for the click premise — the host as the active app — where the run
    /// permits it. Returns whether the app is active afterwards; a caller that
    /// then measures its click as undelivered should skip by name and say
    /// `MAUGHAM_ALLOW_ACTIVATION=1` in the skip.
    @MainActor
    @discardableResult
    static func activate(_ window: NSWindow, deadline: TimeInterval = 1) async -> Bool {
        let app = NSApplication.shared
        if app.isActive { return true }
        guard activationAllowed else { return false }
        app.activate()
        window.makeKeyAndOrderFront(nil)
        _ = await RunLoopPump.until(deadline: deadline) { app.isActive }
        return app.isActive
    }

    /// The hidden-window configuration — `TestHost`'s, applied here at
    /// construction rather than on the window's first update, so a fixture
    /// window is never drawn even for a frame. Idempotent.
    static func conceal(_ window: NSWindow) {
        TestHost.conceal(window)
    }
}

/// A silent window that reports itself key.
///
/// The OS does not grant key status to an inactive app, and the host is never
/// activated by a local run (see `TestWindow.activate`). A suite whose subject
/// READS `isKeyWindow` — a `.keyWindow`-scoped `MaughamEvent`, a focus claim —
/// substitutes that one fact and nothing else: the window is real, and every
/// other property is AppKit's own. Six files carried a private copy of this
/// class before 2026-08-27; `reportsKey` is the one variant's (TreeTravel's)
/// need to flip it mid-test.
final class KeyTestWindow: SilentTestWindow {
    var reportsKey = true
    override var isKeyWindow: Bool { reportsKey }
}
