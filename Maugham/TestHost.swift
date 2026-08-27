import AppKit
import Foundation

/// Whether this process is hosting an XCTest bundle rather than serving a
/// writer — and, if so, the two process-level facts a headless gate rests on.
///
/// The Mac scheme runs its test classes across several worker processes, each
/// a full copy of the app. Left as a `.regular` app, every one of them bounces
/// a Dock icon, takes a ⌘-tab slot and — through the windows the mounted-view
/// suites open — paints over whatever the developer is doing. A test host has
/// no writer, so at launch it is switched to `.accessory` (no Dock tile, no
/// ⌘-tab entry; windows still real, SwiftUI still lays out, key status still
/// grantable, a suite that must activate still can) and **every window it
/// ever shows is concealed** — drawn at alpha 0, deaf to the real mouse, out
/// of Mission Control and the Window menu.
///
/// The test bundle's own fixture (`TestWindow`) conceals the windows it
/// builds the moment it builds them; the sweep here is for the windows it
/// never sees. Measured 2026-08-27, the first evening the gate ran hidden:
/// a `.confirmationDialog` raised by `DesignGateTests` ("Finalize this
/// design") appeared as an orphan popup over the developer's desktop — a
/// sheet is its own child window at full alpha, whatever its parent's — and
/// an alert panel, a popover or the app's own Welcome scene would do the same.
/// The sweep catches each on its first update; a sheet is caught as it begins.
///
/// Detection reads the environment XCTest injects into its host — the
/// configuration-file path (every Xcode) and the session identifier (parallel
/// workers) — never a build flag, so the same Debug binary a developer runs by
/// hand keeps its Dock icon and its windows.
enum TestHost {
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
    }

    /// Apply the test-host policy: `.accessory`, and the window sweep.
    /// Idempotent; a no-op outside a test host.
    @MainActor
    static func applyActivationPolicyIfHosting() {
        guard isActive else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        installWindowSweep()
    }

    /// The hidden-window configuration every test-host window ends up with.
    /// Idempotent. Nonisolated because the test fixture calls it from suites
    /// that are not main-actor-isolated (they construct `NSWindow`s the same
    /// way); notifications deliver it on the main thread regardless.
    static func conceal(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
    }

    @MainActor private static var sweepInstalled = false

    @MainActor
    private static func installWindowSweep() {
        guard !sweepInstalled else { return }
        sweepInstalled = true
        let center = NotificationCenter.default
        // Any window's first update — a sheet, an alert panel, a popover, a
        // scene the app opened itself. The alpha check keeps it to one write
        // per window; a concealed window's later updates cost a comparison.
        center.addObserver(forName: NSWindow.didUpdateNotification, object: nil,
                           queue: nil) { note in
            guard let window = note.object as? NSWindow, window.alphaValue != 0 else { return }
            conceal(window)
        }
        // A sheet, as it begins: `attachedSheet` is set once the begin has
        // run, so the conceal is queued behind it rather than racing it.
        center.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil,
                           queue: nil) { note in
            guard let parent = note.object as? NSWindow else { return }
            DispatchQueue.main.async {
                if let sheet = parent.attachedSheet { conceal(sheet) }
            }
        }
    }
}
