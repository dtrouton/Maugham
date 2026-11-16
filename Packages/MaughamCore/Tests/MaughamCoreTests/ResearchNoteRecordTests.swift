import XCTest
@testable import MaughamCore

/// Note versions plan 2 Task 1: the small per-note record of who wrote the
/// text now on disk.
final class ResearchNoteRecordTests: XCTestCase {

    private let item = "res-1a2b3c4d"

    func test_aRecordRoundTrips() throws {
        let root = TestTemp.root
        let record = ResearchNoteRecord(contentHash: ContentHash.of(Data("hi".utf8)), writtenBy: .assistant)
        try ResearchNoteRecord.write(record, forItem: item, in: root)
        XCTAssertEqual(try ResearchNoteRecord.read(forItem: item, in: root), record)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".maugham/research-notes/\(item).json").path))
    }

    func test_aMissingFileReadsNil() throws {
        XCTAssertNil(try ResearchNoteRecord.read(forItem: item, in: TestTemp.root))
    }

    func test_aTolerantReadKeepsWhatItCanAndNilsTheRest() throws {
        let root = TestTemp.root
        let dir = root.appendingPathComponent(ResearchNoteRecord.folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"content_hash":"abc","written_by":"somebody-new"}"#.utf8)
            .write(to: dir.appendingPathComponent("\(item).json"))
        let record = try ResearchNoteRecord.read(forItem: item, in: root)
        XCTAssertEqual(record?.contentHash, "abc")
        XCTAssertNil(record?.writtenBy)
    }

    func test_aHostileItemIdIsRefused_andNothingIsWritten() throws {
        let root = TestTemp.root
        for hostile in ["../escape", "a/b", ".hidden", "x.y", ""] {
            XCTAssertThrowsError(try ResearchNoteRecord.write(
                ResearchNoteRecord(contentHash: "h", writtenBy: .writer), forItem: hostile, in: root))
            XCTAssertThrowsError(try ResearchNoteRecord.read(forItem: hostile, in: root))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".maugham").path), "nothing was created")
    }

    // MARK: - Removal (hardening 11-16 task 1.6)

    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func test_removeTakesOnlyTheNamedItemsRecord_forNoteAndTable() throws {
        let root = TestTemp.root
        try ResearchNoteRecord.write(ResearchNoteRecord(contentHash: "h", writtenBy: .assistant), forItem: item, in: root)
        try ResearchNoteRecord.write(ResearchNoteRecord(contentHash: "h", writtenBy: .writer), forItem: "res-sibling", in: root)
        try ResearchTableSidecar.write(ResearchTableSidecar(), forItem: item, in: root)
        try ResearchTableSidecar.write(ResearchTableSidecar(), forItem: "res-sibling", in: root)

        ResearchNoteRecord.remove(forItems: [item, "../escape"], in: root)
        ResearchTableSidecar.remove(forItems: [item, "../escape"], in: root)

        XCTAssertNil(try ResearchNoteRecord.read(forItem: item, in: root))
        XCTAssertNotNil(try ResearchNoteRecord.read(forItem: "res-sibling", in: root))
        XCTAssertNil(try ResearchTableSidecar.read(forItem: item, in: root))
        XCTAssertNotNil(try ResearchTableSidecar.read(forItem: "res-sibling", in: root))
    }

    func test_sweepRemovesAnOldOrphan_keepsAYoungOne_andKeepsALiveOne() throws {
        let root = TestTemp.root
        let expiry: TimeInterval = 30 * 86_400
        for id in ["res-oldorph", "res-young", "res-oldlive"] {
            try ResearchNoteRecord.write(ResearchNoteRecord(contentHash: "h", writtenBy: .writer), forItem: id, in: root)
            try ResearchTableSidecar.write(ResearchTableSidecar(), forItem: id, in: root)
        }
        for id in ["res-oldorph", "res-oldlive"] {
            try age(ResearchNoteRecord.fileURL(forItem: id, in: root), by: expiry + 86_400)
            try age(ResearchTableSidecar.fileURL(forItem: id, in: root), by: expiry + 86_400)
        }
        ResearchNoteRecord.sweepOrphans(liveItemIds: ["res-oldlive"], in: root, minimumAge: expiry, now: Date())
        ResearchTableSidecar.sweepOrphans(liveItemIds: ["res-oldlive"], in: root, minimumAge: expiry, now: Date())

        XCTAssertNil(try ResearchNoteRecord.read(forItem: "res-oldorph", in: root))
        XCTAssertNotNil(try ResearchNoteRecord.read(forItem: "res-young", in: root))
        XCTAssertNotNil(try ResearchNoteRecord.read(forItem: "res-oldlive", in: root))
        XCTAssertNil(try ResearchTableSidecar.read(forItem: "res-oldorph", in: root))
        XCTAssertNotNil(try ResearchTableSidecar.read(forItem: "res-young", in: root))
        XCTAssertNotNil(try ResearchTableSidecar.read(forItem: "res-oldlive", in: root))
    }
}
