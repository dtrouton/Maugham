import AppKit

/// **Escape's delivery path on a dimmed board** (§4.1, *"Escape is the keyboard
/// spelling of the project row"*).
///
/// ### Why a monitor and not the responder chain
///
/// `CanvasEventNSView` can only be handed a key it holds first responder for, and
/// the ordinary way INTO the dim is clicking a chapter in Plan's tree — which
/// leaves the keyboard in the sidebar. So the writer's Escape never reached the
/// canvas at all: it travelled up the responder chain unhandled until something
/// above wanted it. In full screen that something is `NSWindow`, so the first
/// Escape left full screen and only the second lifted the dim (smoke, 2026-08-04).
/// **Full screen was never the culprit** — it was merely the first responder up
/// the chain with an opinion; outside it the same press was equally lost and only
/// looked like nothing happening. A fix aimed at full screen would have fixed the
/// symptom of one window state.
///
/// A **local `NSEvent` monitor** does not care who holds the keyboard, which is
/// the whole of the defect. Measured on macOS 26.5, 2026-08-04, and every one of
/// these is load-bearing:
///
/// - the monitor block runs from **`NSApplication.sendEvent(_:)`**, *before* the
///   event is handed to any window, so returning `nil` consumes it and full
///   screen never hears about it;
/// - **`NSWindow.sendEvent(_:)` bypasses monitors entirely**, which is why the
///   tests for this file go through `NSApp.sendEvent(_:)` — the window-level
///   spelling used by the rest of the canvas key tests cannot see this mechanism
///   at all and would pass against a monitor that was never installed;
/// - monitors run **most-recently-installed first**, and a `nil` from one
///   **short-circuits the rest**. That is what lets a test install a probe
///   monitor *before* the canvas mounts and read, off the probe, whether this one
///   let the key travel on — the only honest instrument for "declined", since a
///   decline and a silent swallow look identical from outside.
///
/// The rejected alternative was making Escape a menu-item key equivalent. The
/// discoverability was real, but a key equivalent is **app-wide**: it would take
/// Escape away from every sheet, field editor and completion list in the app, in
/// every window, forever.
///
/// ### What it refuses
///
/// A local monitor is app-global and is the widest-reaching thing on this
/// surface, so `disposition(of:ourWindow:canvasUsesIt:)` — the whole decision,
/// pure and testable — declines four ways before it consumes anything. See it.
@MainActor
final class CanvasEscapeMonitor {

    /// **The whole decision, as a pure function.** Returns the event to let it
    /// travel on, `nil` to consume it.
    ///
    /// Four refusals, in this order, and none of them is defensive tidiness:
    ///
    /// 1. **It is not Escape.** The monitor matches `.keyDown`, so every keystroke
    ///    the writer types anywhere in the app runs this block; it must be a
    ///    character comparison and a return.
    /// 2. **It is not OUR window.** A local monitor sees the whole application.
    ///    With two projects open, the dimmed board in one window must not eat
    ///    Escape in the other, and it must not eat the Escape that dismisses a
    ///    SHEET over its own canvas — a sheet is its own `NSWindow`, so the same
    ///    comparison covers both. Scoped on `event.window`, which is the window
    ///    the event was addressed to, rather than on `isKeyWindow`: tripwire 21's
    ///    rule for this codebase is that a delivery declares its scope, and the
    ///    event carries the answer.
    /// 3. **A text responder is editing.** This is the sharpest hazard the
    ///    mechanism creates. The binder's inline rename (tripwire 16) uses Escape
    ///    to CANCEL the rename, and a writer can be renaming a chapter while the
    ///    board is dimmed — indeed that is the ordinary state, since clicking the
    ///    chapter is what dimmed it. Eat that key and renaming loses its cancel.
    ///    The same holds for the find bar and for the canvas's own mounted scrap
    ///    editor, which §4.1 rules must keep its Escape. `NSText` is the one type
    ///    that covers all of them: an `NSTextField` hands first responder to the
    ///    window's **field editor**, which is an `NSTextView`, which is an
    ///    `NSText` — measured against a real SwiftUI `TextField` in
    ///    `CanvasViewMountingTests`, not read off the hierarchy.
    /// 4. **The canvas did not use it.** `CanvasView.escapeAsksForTheWholeBoard()`
    ///    is the one answer to "what does Escape do here" and it refuses an
    ///    undimmed board and an open scrap itself. A monitor that swallowed a key
    ///    the canvas did nothing with would be invisible on screen and would take
    ///    Escape from everything above.
    static func disposition(of event: NSEvent,
                            ourWindow: NSWindow?,
                            canvasUsesIt: () -> Bool) -> NSEvent? {
        guard event.charactersIgnoringModifiers == CanvasEventNSView.escape else { return event }
        guard let ourWindow, event.window === ourWindow else { return event }
        guard !isEditingText(ourWindow.firstResponder) else { return event }
        return canvasUsesIt() ? nil : event
    }

    /// Whether the thing holding the keyboard is somewhere the writer is typing.
    ///
    /// `NSText` and not `NSTextView`: `NSText` is the superclass both `NSTextView`
    /// and the window's field editor are, so one test covers the mounted scrap
    /// editor, the binder's inline rename `TextField`, the find bar and anything
    /// else with a caret in it. `NSTextField` is named beside it for the window
    /// between a field taking first responder and the field editor being
    /// installed — narrow, but the cost of being wrong is a rename that cannot be
    /// cancelled.
    /// `nonisolated` because it is a type test and nothing else — it reads no
    /// AppKit state, and the tests that drive it against a real field editor call
    /// it from XCTest's nonisolated context.
    nonisolated static func isEditingText(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }

    /// The installed monitor's token, and the only state this object has.
    /// `NSEvent.removeMonitor` is the sole way out, so a leaked token is a block
    /// that goes on eating keys in a window that no longer has a canvas — hence
    /// `deinit` as well as the two explicit removals.
    private var token: Any?

    /// Whether a monitor is currently installed. Not a debugging affordance: the
    /// install/remove pairing is invisible from outside and this is what pins it.
    var isInstalled: Bool { token != nil }

    /// Install, idempotently. `window` and `canvasUsesIt` are read at EVENT time
    /// rather than captured by value, so a view that moves to another window, and
    /// a subject that changes under the canvas, need no reinstall.
    ///
    /// **`assumeIsolated` returns a `Bool` and not the event, and that is a Swift
    /// 6 requirement rather than a style.** AppKit imports the handler as a plain
    /// escaping closure with no isolation (`NSEvent.h`: `NSEvent* _Nullable
    /// (^)(NSEvent *)`), so reaching main-actor state from it needs
    /// `assumeIsolated` — which is honest, since AppKit delivers these on the main
    /// thread. But `assumeIsolated`'s result is constrained to `Sendable`, and
    /// **`NSEvent`'s `Sendable` conformance is explicitly unavailable**: returning
    /// `NSEvent?` through it compiled with *"conformance of 'NSEvent' to
    /// 'Sendable' is unavailable; this is an error in the Swift 6 language mode"*.
    /// Carrying the decision out as a `Bool` and choosing the return value OUTSIDE
    /// the isolated region means the event never crosses the boundary at all —
    /// there is nothing to make `Sendable` and nothing to suppress. Inlining this
    /// back to `assumeIsolated { disposition(…) }` reads tidier and re-plants the
    /// warning.
    func install(window: @escaping () -> NSWindow?,
                 canvasUsesIt: @escaping () -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated {
                Self.disposition(of: event, ourWindow: window(),
                                 canvasUsesIt: canvasUsesIt) == nil
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }

    deinit {
        // Not `remove()`: `deinit` is nonisolated and this is the one path that
        // cannot be reached from the main actor on demand. `removeMonitor` is
        // safe to call here — it is the same object graph teardown AppKit does
        // for any monitor whose owner is going away.
        if let token { NSEvent.removeMonitor(token) }
    }
}
