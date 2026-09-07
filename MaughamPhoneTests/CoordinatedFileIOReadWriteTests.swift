import XCTest
@testable import MaughamPhone

/// Exercises the Phase D coordinated read/write surface on `CoordinatedFileIO`
/// against REAL temp files — `NSFileCoordinator` works fine on local files, no
/// iCloud needed. The eviction/download path is covered separately
/// (`CoordinatedFileIODownloadTests`); here we prove the coordination wrappers
/// round-trip, create directories idempotently, and report a missing file
/// rather than reading it as empty.
///
/// The append cases that used to live here went with `coordinatedAppendLine`
/// (signed op log P1, task 8): the phone's two JSONL writers both append
/// through `JSONLAppendStore`'s CHAINED path now, so an unchained append
/// primitive had no production caller left and its tests were exercising a
/// seam nothing used.
final class CoordinatedFileIOReadWriteTests: XCTestCase {
    private var tempDir: URL!
    private let io = CoordinatedFileIO()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatedFileIORWTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - Round-trip

    func test_writeThenRead_roundTrips() throws {
        let url = tempDir.appendingPathComponent("doc.txt")
        let payload = Data("hello coordinated world".utf8)

        try io.coordinatedWrite(at: url) { coordinatedURL in
            try payload.write(to: coordinatedURL)
        }
        let read = try io.coordinatedRead(at: url)

        XCTAssertEqual(read, payload)
    }

    // MARK: - ensureDirectory

    func test_ensureDirectory_isIdempotent() throws {
        let dir = tempDir.appendingPathComponent(".maugham/inbox", isDirectory: true)
        try io.ensureDirectory(at: dir)
        // Second call on an existing dir must not throw.
        try io.ensureDirectory(at: dir)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Missing file

    func test_coordinatedRead_throwsOnMissingFile() {
        let url = tempDir.appendingPathComponent("does-not-exist.txt")
        // Must surface a real error, not silently return empty Data.
        XCTAssertThrowsError(try io.coordinatedRead(at: url))
    }
}
