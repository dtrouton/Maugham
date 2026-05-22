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
}
