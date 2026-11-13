// MaughamTests/Updates/UpdateTestKit.swift
import Foundation
@testable import Maugham

/// The updater tests' shared fixtures: one checker builder and one release
/// builder, so `UpdateCheckerTests` and `UpdateScheduleTests` agree.
@MainActor
enum UpdateTestKit {
    static func makeChecker(
        defaults: UserDefaults,
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

    static func release(version: String, body: String = "notes") -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"\(body)","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).zip",
                    "browser_download_url":"https://github.com/dtrouton/Maugham/releases/download/v\(version)/Maugham-\(version).zip",
                    "size":100}]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }
}
