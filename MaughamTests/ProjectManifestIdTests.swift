import XCTest
import MaughamCore
@testable import Maugham

/// Covers the minted `ProjectManifest.id` added for the iPhone companion:
/// additive optional field (no schema bump), and `ProjectStore.load`'s
/// one-time backfill that mints + persists a stable id for pre-`id` manifests.
final class ProjectManifestIdTests: XCTestCase {

    func test_decode_legacyManifest_leavesIdNil() throws {
        let json = """
        {
          "schemaVersion": 1,
          "type": "novel",
          "title": "Test",
          "author": "",
          "created": "2026-05-29T12:00:00Z",
          "modified": "2026-05-29T12:00:00Z",
          "structure": [],
          "research": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self, from: json)
        XCTAssertNil(manifest.id)
    }

    func test_encode_roundTripsId() throws {
        let original = ProjectManifest(
            id: "01HQR8YN3T6JYWBQ5VWZG2H8J9",
            type: .novel, title: "T", author: "",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ProjectManifest.self, from: data)
        XCTAssertEqual(round.id, "01HQR8YN3T6JYWBQ5VWZG2H8J9")
    }

    @MainActor
    func test_load_backfillsAndPersistsStableId() async throws {
        let temp = TempDirectory()
        // ProjectFactory writes the manifest with id == nil.
        let url = try await ProjectFactory.createNovelProject(
            named: "IdBackfill", in: temp.url)

        // First load mints an id...
        let first = try await ProjectStore.load(from: url)
        let minted = first.manifest.id
        XCTAssertNotNil(minted, "load should backfill a minted id")
        XCTAssertEqual(minted?.count, 26, "ULID is 26 Crockford-base32 chars")

        // ...and it is persisted to disk and stable across reloads
        // (a second load must NOT mint a different id).
        let second = try await ProjectStore.load(from: url)
        XCTAssertEqual(second.manifest.id, minted,
                       "id must persist and be stable, not re-minted per load")

        // Confirm it actually reached disk, not just the in-memory store.
        let data = try Data(contentsOf: url.appendingPathComponent("project.maugham.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(ProjectManifest.self, from: data)
        XCTAssertEqual(onDisk.id, minted)
    }
}
