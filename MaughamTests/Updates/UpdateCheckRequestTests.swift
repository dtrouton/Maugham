import XCTest
@testable import Maugham

/// A restored Check for Updates… window does not check on its own: only an
/// appearance the menu item asked for checks. Windowless (tripwire 33): the
/// decision is the pure `UpdateSheet.checksOnAppear` and the one-shot flag.
@MainActor
final class UpdateCheckRequestTests: XCTestCase {
    private let ready = UpdateState.readyToInstall(
        bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: "0.2.0", releaseNotes: "")

    func test_theRequestIsOneShot() {
        let request = UpdateCheckRequest()
        XCTAssertFalse(request.consume(), "nothing asked: a restored window")
        request.request()
        XCTAssertTrue(request.isPending)
        XCTAssertTrue(request.consume(), "the menu item asked")
        XCTAssertFalse(request.isPending)
        XCTAssertFalse(request.consume(), "a later appearance of the same window does not check again")
    }

    /// Unrequested (a window restored at launch), no state checks — idle included.
    func test_anUnrequestedAppearanceNeverChecks() {
        for state in [UpdateState.idle, .upToDate(currentVersion: "0.1.0"), .error("x"),
                      .newerBuildNeedsNewerSystem(currentVersion: "0.1.0", newerVersion: "0.2.0",
                                                  requiredSystem: "28"),
                      .checking, .downloading(version: "0.2.0", progress: 0.5), ready,
                      .installing(version: "0.2.0")] {
            XCTAssertFalse(UpdateSheet.checksOnAppear(requested: false, state: state), "\(state)")
        }
    }

    /// Requested: a fresh check from every resting state — not only idle,
    /// since after the first background poll the state is `.upToDate` and
    /// stays there — but never over a check, download or install in flight.
    func test_aRequestedAppearanceChecksFromEveryRestingState() {
        for state in [UpdateState.idle, .upToDate(currentVersion: "0.1.0"), .error("x"),
                      .newerBuildNeedsNewerSystem(currentVersion: "0.1.0", newerVersion: "0.2.0",
                                                  requiredSystem: "28")] {
            XCTAssertTrue(UpdateSheet.checksOnAppear(requested: true, state: state), "\(state)")
        }
        for state in [UpdateState.checking, .downloading(version: "0.2.0", progress: 0.5), ready,
                      .installing(version: "0.2.0")] {
            XCTAssertFalse(UpdateSheet.checksOnAppear(requested: true, state: state), "\(state)")
        }
    }
}
