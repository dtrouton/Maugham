// MaughamTests/Updates/UpdateCheckerTests.swift
import XCTest
@testable import Maugham

@MainActor
final class UpdateCheckerTests: XCTestCase {
    // The production app wires UpdateChecker.performInstall (a global) to a
    // closure that may call NSApp.terminate. Keep it nil in these unit tests so
    // installNow's `performInstall?` short-circuits and state assertions hold.
    /// A private preferences domain per test, so the refusal memory never
    /// reaches the test host's `.standard` (shared across parallel workers).
    private var defaultsSuite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UpdateChecker.performInstall = nil
        defaultsSuite = "UpdateCheckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }
    override func tearDown() {
        UpdateChecker.performInstall = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        super.tearDown()
    }

    private func makeChecker(
        currentVersion: String = "0.1.0",
        fetch: @escaping () async throws -> GitHubRelease,
        downloadAsset: @escaping (GitHubRelease.Asset, String, @escaping @MainActor (Double) -> Void) async throws -> URL = { _, _, _ in
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
            systemVersion: systemVersion,
            refusalDefaults: defaults)
    }

    private func release(version: String, body: String = "notes") -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"\(body)","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).zip",
                    "browser_download_url":"https://github.com/dtrouton/Maugham/releases/download/v\(version)/Maugham-\(version).zip",
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
            downloadAsset: { _, _, _ in URL(fileURLWithPath: "/tmp/Maugham-0.2.0.zip") },
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

    // MARK: - The download cap

    private func release(version: String, assetSize: Int64) -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"notes","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).zip",
                    "browser_download_url":"https://github.com/dtrouton/Maugham/releases/download/v\(version)/Maugham-\(version).zip",
                    "size":\(assetSize)}]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }

    /// A release declaring more than the cap is refused before the download
    /// closure is called at all — an error on a manual check...
    func test_anAssetOverTheCapIsNeverDownloaded_manual() async {
        var downloaded = false
        let checker = makeChecker(
            fetch: { self.release(version: "0.2.0",
                                  assetSize: UpdateLimits.standard.maxDownloadBytes + 1) },
            downloadAsset: { asset, _, _ in downloaded = true; return asset.browserDownloadURL })
        await checker.performCheck(trigger: .manual)
        XCTAssertFalse(downloaded, "nothing may be fetched for an asset over the cap")
        guard case .error = checker.state else {
            return XCTFail("Expected .error, got \(checker.state)")
        }
        XCTAssertNil(checker.pendingQuitInstall)
    }

    /// ...and quietly idle on a background poll, like a release with no asset.
    func test_anAssetOverTheCapIsNeverDownloaded_background() async {
        var downloaded = false
        let checker = makeChecker(
            fetch: { self.release(version: "0.2.0",
                                  assetSize: UpdateLimits.standard.maxDownloadBytes + 1) },
            downloadAsset: { asset, _, _ in downloaded = true; return asset.browserDownloadURL })
        await checker.performCheck(trigger: .background)
        XCTAssertFalse(downloaded)
        XCTAssertEqual(checker.state, .idle)
    }

    /// Exactly the cap is still an update.
    func test_anAssetAtTheCapIsDownloaded() async {
        var downloaded = false
        let checker = makeChecker(
            fetch: { self.release(version: "0.2.0",
                                  assetSize: UpdateLimits.standard.maxDownloadBytes) },
            downloadAsset: { asset, _, _ in downloaded = true; return asset.browserDownloadURL })
        await checker.performCheck(trigger: .manual)
        XCTAssertTrue(downloaded)
    }

    // MARK: - Only this repo's release URL (#67 F14)

    private func release(version: String, assetURL: String) -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"notes","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).zip",
                    "browser_download_url":"\(assetURL)",
                    "size":100}]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }

    func test_anUntrustedAssetURLIsNeverDownloaded_manual() async {
        var downloaded = false
        let checker = makeChecker(
            fetch: { self.release(version: "0.2.0", assetURL: "https://example/Maugham-0.2.0.zip") },
            downloadAsset: { asset, _, _ in downloaded = true; return asset.browserDownloadURL })
        await checker.performCheck(trigger: .manual)
        XCTAssertFalse(downloaded, "nothing may be fetched from a URL that isn't this repo's release")
        XCTAssertEqual(checker.state,
                       .error(GitHubReleasesAPI.Error.untrustedAssetURL.localizedDescription))
        XCTAssertNil(checker.pendingQuitInstall)
    }

    func test_anUntrustedAssetURLIsNeverDownloaded_background() async {
        var downloaded = false
        let checker = makeChecker(
            fetch: { self.release(
                version: "0.2.0",
                assetURL: "https://github.com/dtrouton/Maugham/releases/download/v0.1.9/Maugham-0.2.0.zip") },
            downloadAsset: { asset, _, _ in downloaded = true; return asset.browserDownloadURL })
        await checker.performCheck(trigger: .background)
        XCTAssertFalse(downloaded, "another release's tag is not this release's URL")
        XCTAssertEqual(checker.state, .idle)
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
            downloadAsset: { asset, _, _ in downloaded = true; return asset.browserDownloadURL },
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

    // MARK: - #67 final review: a pending version is not re-staged

    /// With 0.2.0 already staged and waiting for a quit, a later check for the
    /// same version fetches nothing and stages nothing — re-staging would
    /// delete `staged-<v>` from under `pendingQuitInstall` — and stays ready.
    func test_aCheckForTheVersionAlreadyPendingNeitherDownloadsNorStages() async throws {
        let bundle = TestTemp.root.appendingPathComponent("staged-0.2.0/Maugham.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var downloads = 0
        var stages = 0
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            downloadAsset: { _, _, _ in downloads += 1; return URL(fileURLWithPath: "/tmp/fake.zip") },
            stageAndVerify: { _, _ in stages += 1; return bundle })
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(stages, 1)
        XCTAssertEqual(checker.pendingQuitInstall?.version, "0.2.0")

        await checker.performCheck(trigger: .background)
        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(downloads, 1, "the pending version is never fetched again")
        XCTAssertEqual(stages, 1, "the pending version is never re-staged")
        XCTAssertEqual(checker.state, .readyToInstall(bundleURL: bundle, version: "0.2.0", releaseNotes: "notes"))
        XCTAssertEqual(checker.pendingQuitInstall?.bundleURL, bundle)
    }

    /// A pending bundle that has gone from disk is not trusted to still be
    /// there: the check stages again.
    func test_aPendingBundleThatIsGoneIsStagedAgain() async {
        var stages = 0
        let gone = TestTemp.root.appendingPathComponent("staged-0.2.0/Maugham.app", isDirectory: true)
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            stageAndVerify: { _, _ in stages += 1; return gone })
        await checker.performCheck(trigger: .background)
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(stages, 2)
    }

    // MARK: - #67 final review: a twice-refused version waits for a manual check

    private func recordRefusal(_ version: String, times: Int, on checker: UpdateChecker) throws {
        for _ in 0..<times {
            try "refused \(version)\n".write(
                to: TestTemp.root.appendingPathComponent("install-status"), atomically: true, encoding: .utf8)
            checker.reportInstallStatus(in: TestTemp.root)
        }
    }

    func test_oneRefusalStillAutoStages() async throws {
        var downloads = 0
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            downloadAsset: { _, _, _ in downloads += 1; return URL(fileURLWithPath: "/tmp/fake.zip") })
        try recordRefusal("0.2.0", times: 1, on: checker)
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(downloads, 1)
        if case .readyToInstall = checker.state {} else { XCTFail("expected ready, got \(checker.state)") }
    }

    func test_twoRefusalsKeepTheBackgroundPollQuietButAManualCheckProceeds() async throws {
        var downloads = 0
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            downloadAsset: { _, _, _ in downloads += 1; return URL(fileURLWithPath: "/tmp/fake.zip") })
        try recordRefusal("0.2.0", times: 2, on: checker)
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(downloads, 0, "the background poll does not stage a twice-refused version")
        XCTAssertEqual(checker.state, .idle)

        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(downloads, 1, "Check for Updates still tries")
        if case .readyToInstall = checker.state {} else { XCTFail("expected ready, got \(checker.state)") }
    }

    func test_aNewerVersionClearsTheRefusals() async throws {
        var offered = "0.2.0"
        var downloads = 0
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: offered) },
            downloadAsset: { _, _, _ in downloads += 1; return URL(fileURLWithPath: "/tmp/fake.zip") })
        try recordRefusal("0.2.0", times: 2, on: checker)
        offered = "0.3.0"
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(InstallRefusalMemory.refusals(for: "0.2.0", defaults: defaults), 0)
        XCTAssertNil(defaults.object(forKey: InstallRefusalMemory.defaultsKey))
    }

    func test_reachingTheRefusedVersionClearsTheRefusals() async throws {
        let checker = makeChecker(currentVersion: "0.2.0", fetch: { self.release(version: "0.2.0") })
        try recordRefusal("0.2.0", times: 2, on: checker)
        await checker.performCheck(trigger: .background)
        XCTAssertNil(defaults.object(forKey: InstallRefusalMemory.defaultsKey))
    }
}
