import XCTest
@testable import Maugham

final class PublicationStoreTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicationStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoad_emptyReturnsEmpty() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pubs = try await store.load()
        XCTAssertTrue(pubs.isEmpty)
    }

    func testAppend_thenLoad_roundTrips() async throws {
        let store = await PublicationStore(projectURL: tmp)
        let pub = Publication(
            publicationID: "pub_a", version: "0.1", label: nil,
            format: .pdf, outputPath: "Exports/x-v0.1.pdf",
            snapshotID: "snap_a", checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000), maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        try await store.append(pub)
        let pubs = try await store.load()
        XCTAssertEqual(pubs, [pub])
    }

    func testAppend_preservesOrder() async throws {
        let store = await PublicationStore(projectURL: tmp)
        for (idx, v) in ["0.1", "0.2", "0.3"].enumerated() {
            try await store.append(Publication(
                publicationID: "pub_\(v)", version: v, label: nil,
                format: .pdf, outputPath: "x.pdf", snapshotID: "s",
                checkpointID: "c", republishedFrom: nil,
                compiledAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(idx)), maughamVersion: "0",
                tectonicVersion: "0.15.0"))
        }
        let pubs = try await store.load()
        XCTAssertEqual(pubs.map(\.version), ["0.1", "0.2", "0.3"])
    }
}
