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
}
