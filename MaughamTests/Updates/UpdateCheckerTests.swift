// MaughamTests/Updates/UpdateCheckerTests.swift
import XCTest
@testable import Maugham

@MainActor
final class UpdateCheckerTests: XCTestCase {
    // The production app wires UpdateChecker.performInstall (a global) to a
    // closure that may call NSApp.terminate. Keep it nil in these unit tests so
    // installNow's `performInstall?` short-circuits and state assertions hold.
    override func setUp() {
        super.setUp()
        UpdateChecker.performInstall = nil
    }
    override func tearDown() {
        UpdateChecker.performInstall = nil
        super.tearDown()
    }

    private func makeChecker(
        currentVersion: String = "0.1.0",
        fetch: @escaping () async throws -> GitHubRelease,
        downloadAsset: @escaping (URL, String, @escaping @MainActor (Double) -> Void) async throws -> URL = { _, _, _ in
            URL(fileURLWithPath: "/tmp/fake.zip")
        },
        stageAndVerify: @escaping (URL, String) async throws -> URL = { u, _ in u },
        systemVersion: MinimumSystemVersion = MinimumSystemVersion(major: 27)
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersionString: currentVersion,
            fetchLatest: fetch,
            downloadAsset: downloadAsset,
            stageAndVerify: stageAndVerify,
            systemVersion: systemVersion)
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

    func test_idleToUpToDate_whenNoNewerVersion() async {
        let checker = makeChecker(currentVersion: "0.2.0", fetch: { self.release(version: "0.2.0") })
        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(checker.state, .upToDate(currentVersion: "0.2.0"))
    }

    func test_idleToReadyToInstall_whenNewerVersionAvailable() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            downloadAsset: { url, _, _ in URL(fileURLWithPath: "/tmp/Maugham-0.2.0.zip") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") })
        await checker.performCheck(trigger: .manual)
        if case .readyToInstall(_, let v, _) = checker.state {
            XCTAssertEqual(v, "0.2.0")
        } else {
            XCTFail("Expected .readyToInstall, got \(checker.state)")
        }
    }

    func test_backgroundFailureRevertsToIdle() async {
        struct E: Error {}
        let checker = makeChecker(fetch: { throw E() })
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(checker.state, .idle)
    }

    func test_manualFailureSurfacesError() async {
        struct E: Error, LocalizedError {
            var errorDescription: String? { "synthetic" }
        }
        let checker = makeChecker(fetch: { throw E() })
        await checker.performCheck(trigger: .manual)
        if case .error(let msg) = checker.state {
            XCTAssertEqual(msg, "synthetic")
        } else {
            XCTFail("Expected .error, got \(checker.state)")
        }
    }

    func test_skipsDownloadIfDevPlaceholderVersion() async {
        // 0.0.0-dev means we're running a local dev build; checker shouldn't
        // claim "you're up to date" with a fake version. Instead surface idle.
        let checker = makeChecker(
            currentVersion: "0.0.0-dev",
            fetch: { self.release(version: "0.2.0") })
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(checker.state, .idle)
    }

    func test_installNow_setsInstallingState() async {
        let checker = makeChecker(fetch: { self.release(version: "0.1.0") })
        await checker.installNow(bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: "0.3.0")
        XCTAssertEqual(checker.state, .installing(version: "0.3.0"))
    }

    func test_pendingQuitInstall_setAfterAppStaged() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") })
        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(checker.pendingQuitInstall?.version, "0.2.0")
        XCTAssertEqual(checker.pendingQuitInstall?.bundleURL, URL(fileURLWithPath: "/tmp/Maugham.app"))
    }

    func test_pendingQuitInstall_notSetForDmgFallback() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham-0.2.0.dmg") })
        await checker.performCheck(trigger: .manual)
        XCTAssertNil(checker.pendingQuitInstall)
    }

    func test_installNow_clearsPendingQuitInstall() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") })
        await checker.performCheck(trigger: .manual)
        XCTAssertNotNil(checker.pendingQuitInstall)
        await checker.installNow(bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: "0.2.0")
        XCTAssertNil(checker.pendingQuitInstall)
    }

    // MARK: - A build this Mac cannot run is not an update

    /// The release body carries the build's minimum macOS (see
    /// `MinimumSystemVersion`). Above this Mac's OS: no update, no download,
    /// and one sentence saying what the newer Maugham needs.
    func test_aBuildAboveThisMacsSystemIsNotOffered() async {
        var downloaded = false
        let checker = makeChecker(
            currentVersion: "0.39.0",
            fetch: { self.release(version: "0.40.0",
                                  body: "notes<!-- maugham-minimum-macos: 27.0 -->") },
            downloadAsset: { url, _, _ in downloaded = true; return url },
            systemVersion: MinimumSystemVersion(major: 26, minor: 5))
        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(checker.state, .newerBuildNeedsNewerSystem(
            currentVersion: "0.39.0", newerVersion: "0.40.0", requiredSystem: "27"))
        XCTAssertEqual(checker.state.systemRequirementSentence,
                       "Maugham 0.40.0 needs macOS 27 or later.")
        XCTAssertFalse(downloaded, "nothing may be fetched for a build that cannot launch")
        XCTAssertNil(checker.pendingQuitInstall)
    }

    /// A background poll is no different — it is a terminal, non-error state,
    /// and the banner (which draws `.readyToInstall` only) stays away.
    func test_theBlockIsTheSameOnABackgroundPoll() async {
        let checker = makeChecker(
            currentVersion: "0.39.0",
            fetch: { self.release(version: "0.40.0",
                                  body: "<!-- maugham-minimum-macos: 27.0 -->") },
            systemVersion: MinimumSystemVersion(major: 26, minor: 5))
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(checker.state, .newerBuildNeedsNewerSystem(
            currentVersion: "0.39.0", newerVersion: "0.40.0", requiredSystem: "27"))
        XCTAssertFalse(UpdateBannerView.shouldShow(state: checker.state, dismissed: []))
    }

    func test_aBuildAtThisMacsSystemIsOffered() async {
        let checker = makeChecker(
            currentVersion: "0.39.0",
            fetch: { self.release(version: "0.40.0",
                                  body: "<!-- maugham-minimum-macos: 27.0 -->") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") },
            systemVersion: MinimumSystemVersion(major: 27))
        await checker.performCheck(trigger: .manual)
        if case .readyToInstall(_, let v, _) = checker.state {
            XCTAssertEqual(v, "0.40.0")
        } else {
            XCTFail("Expected .readyToInstall, got \(checker.state)")
        }
    }

    /// Every release before 0.40.0 carries no marker. Those are offered exactly
    /// as they were — a missing fact is never a refusal.
    func test_aReleaseCarryingNoMinimumIsOfferedAsBefore() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0", body: "plain notes") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") },
            systemVersion: MinimumSystemVersion(major: 26))
        await checker.performCheck(trigger: .manual)
        if case .readyToInstall(_, let v, _) = checker.state {
            XCTAssertEqual(v, "0.2.0")
        } else {
            XCTFail("Expected .readyToInstall, got \(checker.state)")
        }
    }

    /// The sheet draws `releaseNotes` as plain `Text`; the machine line must
    /// not arrive as literal markup.
    func test_theMarkerNeverReachesTheNotesTheSheetShows() async {
        let checker = makeChecker(
            currentVersion: "0.39.0",
            fetch: { self.release(version: "0.40.0",
                                  body: "What's new.\\n\\n<!-- maugham-minimum-macos: 27.0 -->") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") },
            systemVersion: MinimumSystemVersion(major: 27))
        await checker.performCheck(trigger: .manual)
        if case .readyToInstall(_, _, let notes) = checker.state {
            XCTAssertEqual(notes, "What's new.")
        } else {
            XCTFail("Expected .readyToInstall, got \(checker.state)")
        }
    }

    func test_stageVerifyFailureSurfacesError() async {
        struct E: Error, LocalizedError { var errorDescription: String? { "verify-failed" } }
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            stageAndVerify: { _, _ in throw E() })
        await checker.performCheck(trigger: .manual)
        if case .error(let msg) = checker.state {
            XCTAssertEqual(msg, "verify-failed")
        } else {
            XCTFail("Expected .error, got \(checker.state)")
        }
    }
}
