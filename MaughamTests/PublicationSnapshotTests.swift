import XCTest
@testable import Maugham

final class PublicationSnapshotTests: XCTestCase {

    func testRoundTrips_withBinaryAssets() throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-abc",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            publishFiles: [
                .init(relativePath: "template.tex", textContent: "% template", base64Content: nil),
                .init(relativePath: "cover.jpg", textContent: nil, base64Content: Data([0xFF,0xD8]).base64EncodedString())
            ],
            config: PublishConfig(metadata: .init(title: "Snap", author: "A")),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0")

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PublicationSnapshot.self, from: data)
        XCTAssertEqual(decoded.snapshotID, "snap-abc")
        XCTAssertEqual(decoded.publishFiles.count, 2)
        XCTAssertEqual(decoded.publishFiles[0].relativePath, "template.tex")
        XCTAssertEqual(decoded.publishFiles[0].textContent, "% template")
        XCTAssertNotNil(decoded.publishFiles[1].base64Content)
    }

    func testFile_ensuresExactlyOneContentPresent() {
        let text = PublicationSnapshot.File(
            relativePath: "a.tex", textContent: "x", base64Content: nil)
        XCTAssertTrue(text.isText)
        XCTAssertFalse(text.isBinary)

        let bin = PublicationSnapshot.File(
            relativePath: "a.jpg", textContent: nil, base64Content: "AAAA")
        XCTAssertTrue(bin.isBinary)
        XCTAssertFalse(bin.isText)
    }

    // MARK: - P2: the bodies a snapshot was captured over

    func testLanguages_roundTripInOrder() throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-langs",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            publishFiles: [],
            config: PublishConfig(metadata: .init(title: "Snap", author: "A")),
            maughamVersion: "0.3.3",
            tectonicVersion: "0.15.0",
            languages: ["en", "sr"])
        let data = try JSONEncoder().encode(snap)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"languages\""),
                      "the coding key is `languages`")
        XCTAssertEqual(
            try JSONDecoder().decode(PublicationSnapshot.self, from: data).languages,
            ["en", "sr"])
    }

    /// Every snapshot minted before P2 has no `languages` key at all. It must
    /// decode as `nil` — "this snapshot does not say" — rather than throwing,
    /// because a republish reads snapshots the writer already has on disk.
    /// Built by encoding a real snapshot and deleting exactly that one key, so
    /// the absence is the only difference between it and a current one.
    func testLanguages_absentFromAnOlderSnapshot_decodesAsNil() throws {
        let current = PublicationSnapshot(
            snapshotID: "snap-old",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            publishFiles: [],
            config: PublishConfig(metadata: .init(title: "Old", author: "A")),
            maughamVersion: "0.29.0",
            tectonicVersion: "0.15.0",
            languages: ["en"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(current))
                as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "languages"),
                        "the key a pre-P2 snapshot does not have")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(
            PublicationSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(snap.languages)
        XCTAssertEqual(snap.snapshotID, "snap-old")
    }
}
