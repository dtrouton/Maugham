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
        downloadAsset: @escaping (URL, String) async throws -> URL = { _, _ in
            URL(fileURLWithPath: "/tmp/fake.zip")
        },
        stageAndVerify: @escaping (URL, String) async throws -> URL = { u, _ in u }
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersionString: currentVersion,
            fetchLatest: fetch,
            downloadAsset: downloadAsset,
            stageAndVerify: stageAndVerify)
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
            downloadAsset: { url, _ in URL(fileURLWithPath: "/tmp/Maugham-0.2.0.zip") },
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
