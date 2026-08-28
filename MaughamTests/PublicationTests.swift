import XCTest
@testable import Maugham

final class PublicationTests: XCTestCase {

    func testRoundTrips_minimal() throws {
        let pub = Publication(
            publicationID: "pub_abc",
            version: "0.3",
            label: "galley",
            format: .pdf,
            outputPath: "Exports/Title-v0.3-galley.pdf",
            snapshotID: "snap-xyz",
            checkpointID: "chk-001",
            republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0")
        let encoded = try JSONEncoder().encode(pub)
        let decoded = try JSONDecoder().decode(Publication.self, from: encoded)
        XCTAssertEqual(decoded, pub)
    }

    func testUsesSnakeCaseOnDisk() throws {
        let pub = Publication(
            publicationID: "pub_x", version: "0.1", label: nil,
            format: .epub, outputPath: "p.epub", snapshotID: "snap-x",
            checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        let data = try JSONEncoder().encode(pub)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("publication_id"))
        XCTAssertTrue(s.contains("snapshot_id"))
        XCTAssertTrue(s.contains("checkpoint_id"))
        XCTAssertTrue(s.contains("compiled_at"))
        XCTAssertTrue(s.contains("maugham_version"))
        XCTAssertTrue(s.contains("tectonic_version"))
    }

    // MARK: - Task 4: imprint identity

    func testRoundTrips_withImprint() throws {
        let pub = Publication(
            publicationID: "pub_abc",
            version: "0.3",
            label: "galley",
            format: .pdf,
            outputPath: "Exports/Title-v0.3-galley.pdf",
            snapshotID: "snap-xyz",
            checkpointID: "chk-001",
            republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0",
            imprint: "special-edition")
        let encoded = try JSONEncoder().encode(pub)
        let decoded = try JSONDecoder().decode(Publication.self, from: encoded)
        XCTAssertEqual(decoded, pub)
        XCTAssertEqual(decoded.imprint, "special-edition")
    }

    func testImprint_defaultsToNil() throws {
        let pub = Publication(
            publicationID: "pub_abc",
            version: "0.3",
            label: nil,
            format: .pdf,
            outputPath: "Exports/Title-v0.3.pdf",
            snapshotID: "snap-xyz",
            checkpointID: "chk-001",
            republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0")
        XCTAssertNil(pub.imprint)
    }

    func testImprint_usesSnakeCaseKeyOnDisk() throws {
        let pub = Publication(
            publicationID: "pub_x", version: "0.1", label: nil,
            format: .epub, outputPath: "p.epub", snapshotID: "snap-x",
            checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0",
            imprint: "special-edition")
        let data = try JSONEncoder().encode(pub)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"imprint\":\"special-edition\""), "expected explicit imprint key: \(s)")
    }

    func testImprint_nilNotEncoded() throws {
        let pub = Publication(
            publicationID: "pub_x", version: "0.1", label: nil,
            format: .epub, outputPath: "p.epub", snapshotID: "snap-x",
            checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        let data = try JSONEncoder().encode(pub)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertFalse(s.contains("\"imprint\""), "nil imprint should not encode: \(s)")
    }

    func testOldRecord_withoutImprint_decodesToNil() throws {
        // A publications.jsonl line written before this milestone — no
        // "imprint" key at all. decodeIfPresent must tolerate its absence.
        let json = """
        {"publication_id":"pub1","version":"0.1","label":null,"format":"pdf",
         "output_path":"Exports/Book-v0.1.pdf","snapshot_id":"s1","checkpoint_id":"c1",
         "republished_from":null,"compiled_at":0,"maugham_version":"0.24.0","tectonic_version":"0.15"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let pub = try dec.decode(Publication.self, from: Data(json.utf8))
        XCTAssertNil(pub.imprint)
    }
}
