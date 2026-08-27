import AppKit
import Foundation

/// Whether this process is hosting an XCTest bundle rather than serving a
/// writer.
///
/// The Mac scheme runs its test classes across several worker processes, each
/// a full copy of the app. Left as a `.regular` app, every one of them bounces
/// a Dock icon, takes a ⌘-tab slot and — through the windows the mounted-view
/// suites open — paints over whatever the developer is doing. A test host has
/// no writer, so it is switched to `.accessory` at launch: no Dock tile, no
/// ⌘-tab entry, windows still real (SwiftUI lays out, key status still
/// grantable, a suite that must activate still can). The windows themselves
/// are hidden by the test bundle's own fixture (`TestWindow`); this is only the
/// process-level half.
///
/// Detection reads the environment XCTest injects into its host — the
/// configuration-file path (every Xcode) and the session identifier (parallel
/// workers) — never a build flag, so the same Debug binary a developer runs by
/// hand keeps its Dock icon.
enum TestHost {
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
    }

    /// Apply the test-host activation policy. Idempotent; a no-op outside a
    /// test host.
    @MainActor
    static func applyActivationPolicyIfHosting() {
        guard isActive else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
