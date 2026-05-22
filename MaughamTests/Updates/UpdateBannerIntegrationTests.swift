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
            state: .ready(version: "0.2.0", dmgURL: URL(fileURLWithPath: "/x"), releaseNotes: ""),
            dismissed: []))
    }

    func test_shouldShowReturnsFalseForReadyDismissed() {
        XCTAssertFalse(UpdateBannerView.shouldShow(
            state: .ready(version: "0.2.0", dmgURL: URL(fileURLWithPath: "/x"), releaseNotes: ""),
            dismissed: ["0.2.0"]))
    }

    func test_shouldShowReturnsTrueForReadyNewerThanDismissed() {
        XCTAssertTrue(UpdateBannerView.shouldShow(
            state: .ready(version: "0.2.1", dmgURL: URL(fileURLWithPath: "/x"), releaseNotes: ""),
            dismissed: ["0.2.0"]))
    }
}
