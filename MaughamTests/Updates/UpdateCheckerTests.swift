// MaughamTests/Updates/UpdateCheckerTests.swift
import XCTest
@testable import Maugham

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private func makeChecker(
        currentVersion: String = "0.1.0",
        fetch: @escaping () async throws -> GitHubRelease,
        download: @escaping (URL, String) async throws -> URL = { _, _ in
            URL(fileURLWithPath: "/tmp/fake.dmg")
        }
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersionString: currentVersion,
            fetchLatest: fetch,
            downloadDMG: download)
    }

    private func release(version: String, body: String = "notes") -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"\(body)","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).dmg",
                    "browser_download_url":"https://example/Maugham-\(version).dmg",
                    "size":100}]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }

    func test_idleToUpToDate_whenNoNewerVersion() async {
        let checker = makeChecker(currentVersion: "0.2.0", fetch: { self.release(version: "0.2.0") })
        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(checker.state, .upToDate(currentVersion: "0.2.0"))
    }

    func test_idleToReady_whenNewerVersionAvailable() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            download: { url, _ in URL(fileURLWithPath: "/tmp/Maugham-0.2.0.dmg") })
        await checker.performCheck(trigger: .manual)
        if case .ready(let v, _, _) = checker.state {
            XCTAssertEqual(v, "0.2.0")
        } else {
            XCTFail("Expected .ready, got \(checker.state)")
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
}
