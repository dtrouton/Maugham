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
}
