import XCTest
@testable import Maugham

final class PublicationSnapshotStoreTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PubSnapStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCapture_capturesTemplateAndStyles() async throws {
        let maugham = tmp.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: maugham, withIntermediateDirectories: true)
        let pub = maugham.appendingPathComponent("publish")
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        try "% tex".write(to: pub.appendingPathComponent("template.tex"),
                          atomically: true, encoding: .utf8)

        let cfg = PublishConfig(metadata: .init(title: "Cap", author: "A"))
        let store = PublicationSnapshotStore(projectURL: tmp)
        let snap = try await store.capture(
            config: cfg, maughamVersion: "0.3.3", tectonicVersion: "0.15.0")
        XCTAssertGreaterThanOrEqual(snap.publishFiles.count, 1)
    }

    func testSave_thenLoad_roundTrips() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap_test",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            publishFiles: [
                .init(relativePath: "template.tex", textContent: "% x", base64Content: nil)
            ],
            config: PublishConfig(metadata: .init(title: "X", author: "Y")),
            maughamVersion: "0.0", tectonicVersion: "0.15.0")

        let store = PublicationSnapshotStore(projectURL: tmp)
        try await store.save(snap)
        let loaded = try await store.load(id: "snap_test")
        XCTAssertEqual(loaded.snapshotID, "snap_test")
        XCTAssertEqual(loaded.publishFiles.count, 1)
    }

    func testExtract_writesAllFiles_intoDestination() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-extract",
            createdAt: Date(),
            publishFiles: [
                .init(relativePath: "template.tex", textContent: "% restored", base64Content: nil),
                .init(relativePath: "cover.jpg",
                      textContent: nil,
                      base64Content: Data([1,2,3,4]).base64EncodedString()),
            ],
            config: PublishConfig(metadata: .init(title: "T", author: "A")),
            maughamVersion: "0", tectonicVersion: "0.15.0")

        let dest = tmp.appendingPathComponent("extracted-\(UUID().uuidString)")
        try PublicationSnapshotStore.extract(snap, into: dest)

        let tex = try String(contentsOf: dest.appendingPathComponent("template.tex"))
        XCTAssertEqual(tex, "% restored")
        let img = try Data(contentsOf: dest.appendingPathComponent("cover.jpg"))
        XCTAssertEqual(img, Data([1,2,3,4]))
    }
}
