import XCTest
@testable import MaughamPhone

/// Exercises the Phase D coordinated read/write surface on `CoordinatedFileIO`
/// against REAL temp files — `NSFileCoordinator` works fine on local files, no
/// iCloud needed. The eviction/download path is covered separately
/// (`CoordinatedFileIODownloadTests`); here we prove the coordination wrappers
/// round-trip, append correctly, and — the core value — serialize concurrent
/// appends to one file without tearing records.
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

    // MARK: - Append

    func test_appendLine_createsFileAndAccumulates() throws {
        // Target a not-yet-existing nested path to also prove intermediate-dir
        // creation (mirrors `.maugham/ops/d_x.jsonl` on a fresh project).
        let url = tempDir
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("d_test.jsonl")

        let records = [
            #"{"i":0}"#,
            #"{"i":1}"#,
            #"{"i":2}"#,
        ]
        for record in records {
            try io.coordinatedAppendLine(Data(record.utf8), to: url)
        }

        let contents = try io.coordinatedRead(at: url)
        let text = String(decoding: contents, as: UTF8.self)

        // Newline-terminated each line → trailing newline → drop the empty tail.
        XCTAssertTrue(text.hasSuffix("\n"), "every record should be newline-terminated")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines, records, "order preserved")

        // Each line is independently valid JSON.
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int]
            XCTAssertNotNil(obj)
        }
    }

    func test_appendLine_doesNotDoubleNewline() throws {
        let url = tempDir.appendingPathComponent("log.jsonl")
        // Caller pre-terminates the line — the helper must NOT add a second "\n".
        try io.coordinatedAppendLine(Data("{\"a\":1}\n".utf8), to: url)
        try io.coordinatedAppendLine(Data("{\"a\":2}\n".utf8), to: url)

        let text = String(decoding: try io.coordinatedRead(at: url), as: UTF8.self)
        XCTAssertFalse(text.contains("\n\n"), "no blank lines from double newline")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Two records + one empty trailing element after the final "\n".
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"a\":2}", ""])
    }

    // MARK: - Concurrency (the point of coordination)

    func test_concurrentAppends_noCorruption() async throws {
        let url = tempDir.appendingPathComponent("concurrent.jsonl")
        let count = 200

        // Fire all appends concurrently at the SAME file. Each carries its index
        // so we can prove the final file is exactly {0..<N} — no loss, no dup, no
        // torn/interleaved line. The coordinated write is what serializes them.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let io = io
                group.addTask {
                    // Index-tagged JSON; failure to append would drop an index.
                    try? io.coordinatedAppendLine(Data(#"{"i":\#(i)}"#.utf8), to: url)
                }
            }
        }

        let text = String(decoding: try io.coordinatedRead(at: url), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, count, "every append landed as one well-formed line")

        var indices = Set<Int>()
        for line in lines {
            // A torn/interleaved line would fail to decode here.
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int],
                  let i = obj["i"] else {
                XCTFail("malformed/torn line: \(line)")
                continue
            }
            indices.insert(i)
        }
        XCTAssertEqual(indices, Set(0..<count), "exact set of indices, no loss/dup")
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
