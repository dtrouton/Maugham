import XCTest
@testable import Maugham

@MainActor
final class UpdateBannerIntegrationTests: XCTestCase {
    func test_shouldShowReturnsFalseForIdle() {
        XCTAssertFalse(UpdateBannerView.shouldShow(state: .idle, dismissed: []))
    }

    func test_shouldShowReturnsFalseForDownloading() {
        XCTAssertFalse(UpdateBannerView.shouldShow(
            state: .downloading(version: "0.2.0", progress: 0.3), dismissed: []))
    }

    func test_shouldShowReturnsTrueForReadyNotDismissed() {
        XCTAssertTrue(UpdateBannerView.shouldShow(
            state: .readyToInstall(bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: "0.2.0", releaseNotes: ""),
            dismissed: []))
    }

    func test_shouldShowReturnsFalseForReadyDismissed() {
        XCTAssertFalse(UpdateBannerView.shouldShow(
            state: .readyToInstall(bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: "0.2.0", releaseNotes: ""),
            dismissed: ["0.2.0"]))
    }

    func test_shouldShowReturnsTrueForReadyNewerThanDismissed() {
        XCTAssertTrue(UpdateBannerView.shouldShow(
            state: .readyToInstall(bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: "0.2.1", releaseNotes: ""),
            dismissed: ["0.2.0"]))
    }
}
