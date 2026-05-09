import XCTest
@testable import Maugham

final class ProjectManifestGutterMigrationTests: XCTestCase {

    func test_decode_legacyManifest_leavesShowElementGutterNil() throws {
        let json = """
        {
          "schemaVersion": 1,
          "type": "screenplay",
          "title": "Test",
          "author": "",
          "created": "2026-05-09T12:00:00Z",
          "modified": "2026-05-09T12:00:00Z",
          "structure": [],
          "research": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self, from: json)
        XCTAssertNil(manifest.showElementGutter)
    }

    func test_decode_manifestWithGutterFalse_decodesFalse() throws {
        let json = """
        {
          "schemaVersion": 1,
          "type": "screenplay",
          "title": "Test",
          "author": "",
          "created": "2026-05-09T12:00:00Z",
          "modified": "2026-05-09T12:00:00Z",
          "structure": [],
          "research": [],
          "showElementGutter": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self, from: json)
        XCTAssertEqual(manifest.showElementGutter, false)
    }

    @MainActor
    func test_setShowElementGutter_persists() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "GutterToggle", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.setShowElementGutter(false)
        XCTAssertEqual(store.manifest.showElementGutter, false)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.showElementGutter, false)
    }
}
