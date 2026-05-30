import XCTest
@testable import MaughamPhone

/// Unit tests for the §3.13 download-banner mapping (Task F.4, the §7.1
/// `AnnotationsListViewBannerTests`). Asserts both the `Banner` case and its
/// user-facing copy against the spec table.
final class AnnotationsBannerTests: XCTestCase {

    func test_empty_isNone() {
        XCTAssertEqual(AnnotationsBanner.banner(forRecentStates: []), .none)
    }

    func test_allDownloaded_isNone() {
        let states: [DownloadStateLite] = [.downloaded, .downloaded, .downloaded]
        XCTAssertEqual(AnnotationsBanner.banner(forRecentStates: states), .none)
    }

    func test_anyDownloading_isSyncing_withDoneAndTotalCounts() {
        // 1 of 3 downloaded, 1 in flight, 1 not started → done = 1 (downloaded), total = 3.
        let states: [DownloadStateLite] = [.downloaded, .downloading, .notDownloaded]
        let banner = AnnotationsBanner.banner(forRecentStates: states)
        XCTAssertEqual(banner, .syncing(done: 1, total: 3))
        XCTAssertEqual(banner.text, "Syncing 1 of 3 projects from iCloud…")
    }

    func test_allNotDownloaded_isNeedsDownload() {
        let states: [DownloadStateLite] = [.notDownloaded, .notDownloaded]
        let banner = AnnotationsBanner.banner(forRecentStates: states)
        XCTAssertEqual(banner, .needsDownload)
        XCTAssertEqual(banner.text, "Recent projects need to download from iCloud")
    }

    func test_allFailed_isFailed() {
        let states: [DownloadStateLite] = [.failed, .failed]
        let banner = AnnotationsBanner.banner(forRecentStates: states)
        XCTAssertEqual(banner, .failed)
        XCTAssertEqual(banner.text, "Couldn’t reach iCloud. Try again.")
    }

    func test_failedBeatsNotDownloaded_onlyWhenAllFailed() {
        // A mix of failed + notDownloaded (none in flight) is NOT "all failed",
        // so it falls through to needsDownload — there's still something to fetch.
        let states: [DownloadStateLite] = [.failed, .notDownloaded]
        XCTAssertEqual(AnnotationsBanner.banner(forRecentStates: states), .needsDownload)
    }

    func test_none_copyIsEmpty() {
        XCTAssertEqual(AnnotationsBanner.Banner.none.text, "")
    }
}
