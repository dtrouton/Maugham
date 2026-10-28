import Foundation

/// Is this process running tests? The one answer, for the Mac host, the phone
/// host and MaughamCore's own `swift test` workers (tripwire 19).
///
/// Two signals, either one enough:
/// - **The environment Xcode injects into a test host** — the configuration
///   file path (every Xcode run), the session identifier (parallel workers),
///   the bundle path. A Mac or phone app hosting tests carries these.
/// - **XCTest itself, loaded into the process.** `swift test` injects none of
///   those variables (measured 2026-10-28: zero `XCTest*` keys in every worker,
///   3,850 of 3,850 logged), but its `xctest` workers have `XCTestCase`. Before
///   this check, MaughamCore's own tests took the LIVE dev app's paths: they
///   loaded its Enclave key and rewrote its device state.
///
/// **Why it never fires in a shipping app:** neither app links XCTest, and
/// nothing outside a test run sets these variables — so a Debug or Release
/// build a person launches by hand answers `false` and keeps the bare paths.
public enum TestProcess {
    public static var isActive: Bool {
        isActive(environment: ProcessInfo.processInfo.environment,
                 xctestLoaded: NSClassFromString("XCTestCase") != nil)
    }

    /// The rule, over its inputs, so a test can pin both arms.
    static func isActive(environment env: [String: String], xctestLoaded: Bool) -> Bool {
        env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
            || xctestLoaded
    }
}
