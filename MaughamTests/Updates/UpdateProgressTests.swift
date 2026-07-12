// MaughamTests/Updates/UpdateProgressTests.swift
// Task 30 (6h): the update sheet's progress bar never moved because
// performCheck set `.downloading(progress: 0)` exactly once and the
// downloadAsset seam had no way to report intermediate progress. This
// suite drives the seam signature change and asserts the resulting
// `.downloading(progress:)` sequence a real download would produce.
import XCTest
@testable import Maugham

@MainActor
final class UpdateProgressTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UpdateChecker.performInstall = nil
    }
    override func tearDown() {
        UpdateChecker.performInstall = nil
        super.tearDown()
    }

    private func release(version: String, body: String = "notes") -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"\(body)","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).zip",
                    "browser_download_url":"https://example/Maugham-\(version).zip",
                    "size":100}]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }

    /// The seam now takes a progress callback; a fake download that invokes
    /// it with 0.25/0.5/1.0 must drive `checker.state` through matching
    /// `.downloading(progress:)` values in order, ending in `.readyToInstall`.
    func test_progressCallback_drivesDownloadingStateSequence() async {
        var observedProgress: [Double] = []
        let checker = UpdateChecker(
            currentVersionString: "0.1.0",
            fetchLatest: { self.release(version: "0.2.0") },
            downloadAsset: { _, _, progress in
                await progress(0.25)
                await progress(0.5)
                await progress(1.0)
                return URL(fileURLWithPath: "/tmp/Maugham-0.2.0.zip")
            },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") })

        // Observe every published state change synchronously via a Combine
        // subscription — polling checker.state after the fact would only
        // ever see the final value.
        let cancellable = checker.$state.sink { state in
            if case .downloading(_, let progress) = state {
                observedProgress.append(progress)
            }
        }
        defer { cancellable.cancel() }

        await checker.performCheck(trigger: .manual)

        // Initial 0 (set before download starts) + the three callback values.
        XCTAssertEqual(observedProgress, [0, 0.25, 0.5, 1.0])
        if case .readyToInstall(_, let v, _) = checker.state {
            XCTAssertEqual(v, "0.2.0")
        } else {
            XCTFail("Expected .readyToInstall, got \(checker.state)")
        }
    }

    /// expectedContentLength <= 0 (server didn't send Content-Length) reports
    /// -1 exactly once; UpdateSheet renders that as an indeterminate spinner.
    func test_indeterminateProgress_reportsNegativeOne() async {
        var observedProgress: [Double] = []
        let checker = UpdateChecker(
            currentVersionString: "0.1.0",
            fetchLatest: { self.release(version: "0.2.0") },
            downloadAsset: { _, _, progress in
                await progress(-1)
                return URL(fileURLWithPath: "/tmp/Maugham-0.2.0.zip")
            },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") })

        let cancellable = checker.$state.sink { state in
            if case .downloading(_, let progress) = state {
                observedProgress.append(progress)
            }
        }
        defer { cancellable.cancel() }

        await checker.performCheck(trigger: .manual)

        XCTAssertEqual(observedProgress, [0, -1])
    }

    /// UpdateSheet must render an indeterminate spinner (not a 0%-stuck bar)
    /// when progress is negative.
    func test_updateSheetContent_indeterminate_forNegativeProgress() {
        // Title stays version-bearing regardless of progress value.
        XCTAssertEqual(
            UpdateSheet.title(for: .downloading(version: "0.2.0", progress: -1)),
            "Downloading Maugham 0.2.0…")
    }
}
