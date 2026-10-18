// MaughamTests/Updates/GitHubReleasesAPITests.swift
import XCTest
@testable import Maugham

final class GitHubReleasesAPITests: XCTestCase {
    private func fixtureData(name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url, "Fixture \(name).json not found"))
    }

    func test_parseValidResponse() throws {
        let data = try fixtureData(name: "github-releases-latest")
        let release = try GitHubRelease.decode(from: data)
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.semanticVersion, SemanticVersion("0.2.0"))
        XCTAssertEqual(release.dmgAsset?.name, "Maugham-0.2.0.dmg")
        XCTAssertEqual(release.dmgAsset?.size, 12345678)
        XCTAssertTrue(release.body.contains("What's new"))
    }

    func test_parseResponseWithNoDmgAsset() throws {
        let json = """
        {"tag_name":"v0.3.0","name":"x","body":"x","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-0.3.0-src.zip","browser_download_url":"https://example/x","size":1}]}
        """
        let release = try GitHubRelease.decode(from: Data(json.utf8))
        XCTAssertNil(release.dmgAsset, ".dmg asset must be filtered")
    }

    func test_parseRejectsMalformed() {
        let json = "{}"
        XCTAssertThrowsError(try GitHubRelease.decode(from: Data(json.utf8)))
    }

    func test_zipAsset_selectsZipWhenPresent() throws {
        let json = """
        {"tag_name":"v0.5.0","name":"x","body":"n","assets":[
          {"name":"Maugham-0.5.0.dmg","browser_download_url":"https://e/x.dmg","size":1},
          {"name":"Maugham-0.5.0.zip","browser_download_url":"https://e/x.zip","size":2}
        ]}
        """
        let r = try GitHubRelease.decode(from: Data(json.utf8))
        XCTAssertEqual(r.zipAsset?.name, "Maugham-0.5.0.zip")
        XCTAssertEqual(r.dmgAsset?.name, "Maugham-0.5.0.dmg")
    }

    func test_zipAsset_nilWhenAbsent() throws {
        let json = """
        {"tag_name":"v0.5.0","name":"x","body":"n","assets":[
          {"name":"Maugham-0.5.0.dmg","browser_download_url":"https://e/x.dmg","size":1}
        ]}
        """
        let r = try GitHubRelease.decode(from: Data(json.utf8))
        XCTAssertNil(r.zipAsset)
    }

    // MARK: - Mac-release selection (the phone-tag-is-newer bug)

    /// GitHub's `/releases/latest` returns the most-recently-*published* release
    /// across ALL tags, so a `phone-v*` tag cut minutes after the Mac release
    /// wins — and its tag can't be parsed as a Mac SemanticVersion. The Mac
    /// updater must select the highest STABLE Mac release from the full list,
    /// never the phone tag. (Regression: v0.21.0 shipped, phone-v0.7.0 was
    /// published 4 min later, Mac updater choked with "Couldn't parse version".)
    func test_selectMacRelease_ignoresNewerPhoneTag() throws {
        let json = """
        [
          {"tag_name":"phone-v0.7.0","name":"phone","body":"b","draft":false,"prerelease":false,"assets":[]},
          {"tag_name":"v0.21.0","name":"mac","body":"b","draft":false,"prerelease":false,
           "assets":[{"name":"Maugham-0.21.0.zip","browser_download_url":"https://e/x.zip","size":1}]},
          {"tag_name":"phone-v0.6.0","name":"phone","body":"b","draft":false,"prerelease":false,"assets":[]},
          {"tag_name":"v0.20.0","name":"mac","body":"b","draft":false,"prerelease":false,"assets":[]}
        ]
        """
        let releases = try GitHubRelease.decodeList(from: Data(json.utf8))
        let selected = GitHubReleasesAPI.latestMacRelease(from: releases)
        XCTAssertEqual(selected?.tagName, "v0.21.0")
        XCTAssertEqual(selected?.semanticVersion, SemanticVersion("0.21.0"))
    }

    /// Selection is by highest version, not list order or publish time.
    func test_selectMacRelease_picksHighestVersion() throws {
        let json = """
        [
          {"tag_name":"v0.9.0","name":"m","body":"b","draft":false,"prerelease":false,"assets":[]},
          {"tag_name":"v0.21.0","name":"m","body":"b","draft":false,"prerelease":false,"assets":[]},
          {"tag_name":"v0.10.0","name":"m","body":"b","draft":false,"prerelease":false,"assets":[]}
        ]
        """
        let releases = try GitHubRelease.decodeList(from: Data(json.utf8))
        XCTAssertEqual(GitHubReleasesAPI.latestMacRelease(from: releases)?.tagName, "v0.21.0")
    }

    /// Drafts and prereleases are never offered as an update.
    func test_selectMacRelease_skipsDraftAndPrerelease() throws {
        let json = """
        [
          {"tag_name":"v0.22.0","name":"m","body":"b","draft":true,"prerelease":false,"assets":[]},
          {"tag_name":"v0.23.0","name":"m","body":"b","draft":false,"prerelease":true,"assets":[]},
          {"tag_name":"v0.21.0","name":"m","body":"b","draft":false,"prerelease":false,"assets":[]}
        ]
        """
        let releases = try GitHubRelease.decodeList(from: Data(json.utf8))
        XCTAssertEqual(GitHubReleasesAPI.latestMacRelease(from: releases)?.tagName, "v0.21.0")
    }

    /// No Mac releases at all → nil (updater surfaces this, doesn't crash).
    func test_selectMacRelease_nilWhenOnlyPhoneReleases() throws {
        let json = """
        [
          {"tag_name":"phone-v0.7.0","name":"p","body":"b","draft":false,"prerelease":false,"assets":[]}
        ]
        """
        let releases = try GitHubRelease.decodeList(from: Data(json.utf8))
        XCTAssertNil(GitHubReleasesAPI.latestMacRelease(from: releases))
    }

    // MARK: - Only this repo's release URL (#67 F14)

    private func asset(_ name: String, _ url: String) -> GitHubRelease.Asset {
        let json = #"{"name":"\#(name)","browser_download_url":"\#(url)","size":1}"#
        return try! JSONDecoder().decode(GitHubRelease.Asset.self, from: Data(json.utf8))
    }

    func test_onlyThisReposReleaseURLForThisTagAndAssetIsTrusted() {
        let good = "https://github.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip"
        let cases: [(String, String, Bool)] = [
            (good, "the real shape", true),
            ("https://GitHub.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip",
             "host case is not significant", true),
            ("http://github.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip", "http", false),
            ("https://example.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip",
             "another host", false),
            ("https://github.com.evil.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip",
             "a lookalike host", false),
            ("https://github.com:8443/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip",
             "a port", false),
            ("https://someone@github.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip",
             "a user", false),
            ("https://github.com/evil/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip", "another owner", false),
            ("https://github.com/dtrouton/Other/releases/download/v0.43.0/Maugham-0.43.0.zip", "another repo", false),
            ("https://github.com/dtrouton/Maugham/releases/download/v0.42.0/Maugham-0.43.0.zip", "another tag", false),
            ("https://github.com/dtrouton/Maugham/releases/download/v0.43.0/Other.zip", "a name mismatch", false),
            (good + "?x=1", "a query", false),
            ("https://github.com/dtrouton/Maugham/releases/download/v0.43.0/../v0.43.0/Maugham-0.43.0.zip",
             "a dot-dot path", false),
        ]
        for (url, why, expected) in cases {
            let a = asset("Maugham-0.43.0.zip", url)
            XCTAssertEqual(GitHubReleasesAPI.isTrustedAssetURL(a.browserDownloadURL, for: a, tag: "v0.43.0"),
                           expected, why)
        }
    }

    /// The bundled fixture is a real GitHub response and must pass.
    func test_theRealFixturesAssetIsTrusted() throws {
        let release = try GitHubRelease.decode(from: fixtureData(name: "github-releases-latest"))
        let asset = try XCTUnwrap(release.dmgAsset ?? release.zipAsset)
        XCTAssertTrue(GitHubReleasesAPI.isTrustedAssetURL(asset.browserDownloadURL, for: asset, tag: release.tagName))
    }
}
