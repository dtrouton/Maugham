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

    /// CI run 31584930789: a concurrent compile's in-flight atomic write left
    /// its Foundation temp file (`EMISSION.md.sb-<hex>-<random>`) in the
    /// publish tree while the winner's capture enumerated it; the rename then
    /// completed and the capture's read of the temp threw NSFileReadNoSuchFile,
    /// aborting the winning compile. The temps are transient junk either way —
    /// a capture must neither embed one nor die on one.
    func testCapture_skipsAtomicWriteTempFiles() async throws {
        let pub = tmp.appendingPathComponent(".maugham/publish")
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        try "% tex".write(to: pub.appendingPathComponent("template.tex"),
                          atomically: true, encoding: .utf8)
        try "transient".write(
            to: pub.appendingPathComponent("EMISSION.md.sb-aef33a4a-NcjUMd"),
            atomically: true, encoding: .utf8)

        let cfg = PublishConfig(metadata: .init(title: "Cap", author: "A"))
        let store = PublicationSnapshotStore(projectURL: tmp)
        let snap = try await store.capture(
            config: cfg, maughamVersion: "0.3.3", tectonicVersion: "0.15.0")
        XCTAssertEqual(snap.publishFiles.map(\.relativePath), ["template.tex"],
                       "an atomic-write temp is not a publish file")
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

    func testExtract_rejects_parentEscape_relativePath() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-evil",
            createdAt: Date(),
            publishFiles: [
                .init(relativePath: "../outside.tex",
                      textContent: "should not land", base64Content: nil),
            ],
            config: PublishConfig(metadata: .init(title: "T", author: "A")),
            maughamVersion: "0", tectonicVersion: "0.15.0")

        let dest = tmp.appendingPathComponent("extract-escape-\(UUID().uuidString)")
        do {
            try PublicationSnapshotStore.extract(snap, into: dest)
            XCTFail("expected pathTraversal error")
        } catch PublicationSnapshotStore.Error.pathTraversal(let rel) {
            XCTAssertEqual(rel, "../outside.tex")
        }
        let outside = dest.deletingLastPathComponent()
            .appendingPathComponent("outside.tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                       "file escaped destination")
    }

    func testExtract_rejects_absolutePath() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "snap-abs",
            createdAt: Date(),
            publishFiles: [
                .init(relativePath: "/tmp/owned.tex",
                      textContent: "no", base64Content: nil)
            ],
            config: PublishConfig(metadata: .init(title: "T", author: "A")),
            maughamVersion: "0", tectonicVersion: "0.15.0")
        let dest = tmp.appendingPathComponent("extract-abs-\(UUID().uuidString)")
        XCTAssertThrowsError(try PublicationSnapshotStore.extract(snap, into: dest)) { err in
            guard case PublicationSnapshotStore.Error.pathTraversal = err else {
                XCTFail("unexpected error \(err)")
                return
            }
        }
    }

    func testLoad_rejects_traversalSnapshotID() async throws {
        let store = PublicationSnapshotStore(projectURL: tmp)
        do {
            _ = try await store.load(id: "../../etc/passwd")
            XCTFail("expected invalidSnapshotID")
        } catch PublicationSnapshotStore.Error.invalidSnapshotID(let id) {
            XCTAssertEqual(id, "../../etc/passwd")
        }
    }

    func testSave_rejects_traversalSnapshotID() async throws {
        let snap = PublicationSnapshot(
            snapshotID: "../escapes",
            createdAt: Date(),
            publishFiles: [],
            config: PublishConfig(metadata: .init(title: "X", author: "Y")),
            maughamVersion: "0", tectonicVersion: "0.15.0")
        let store = PublicationSnapshotStore(projectURL: tmp)
        do {
            try await store.save(snap)
            XCTFail("expected invalidSnapshotID")
        } catch PublicationSnapshotStore.Error.invalidSnapshotID(let id) {
            XCTAssertEqual(id, "../escapes")
        }
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
