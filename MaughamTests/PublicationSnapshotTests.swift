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
}
