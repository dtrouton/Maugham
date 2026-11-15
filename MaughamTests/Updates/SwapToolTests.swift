import XCTest
@testable import Maugham

/// The compiled swap tool (`maugham-swap/main.swift`), driven as the BUILT
/// product the test host's own bundle embeds at
/// `UpdateInstaller.swapToolRelativePath` — the same binary, at the same
/// place, the helper runs in production. A missing tool fails, never skips:
/// every configuration embeds it.
final class SwapToolTests: XCTestCase {
    private struct Result {
        let status: Int32
        let stderr: String
    }

    private func runTool(_ arguments: [String]) throws -> Result {
        let p = Process()
        p.executableURL = try XCTUnwrap(UpdateInstaller.swapToolURL(),
            "the test host must embed \(UpdateInstaller.swapToolRelativePath)")
        p.arguments = arguments
        // To a file, not a pipe, and the wait is bounded: a stuck tool fails
        // the test instead of hanging the gate.
        let errFile = TestTemp.root.appendingPathComponent("swap-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: errFile)
        defer { try? handle.close() }
        p.standardError = handle
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            XCTFail("the swap tool did not exit within 10 s")
            return Result(status: -1, stderr: "")
        }
        return Result(status: p.terminationStatus,
                      stderr: (try? String(contentsOf: errFile, encoding: .utf8)) ?? "")
    }

    /// `name/marker` holding `content`, under the test root.
    private func makeDirectory(_ name: String, content: String) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        return dir
    }

    private func marker(in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("marker"), encoding: .utf8)
    }

    func test_swapsTwoDirectories_andBothExistAfterwards() throws {
        let a = try makeDirectory("a", content: "A")
        let b = try makeDirectory("b", content: "B")
        let result = try runTool([a.path, b.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(try marker(in: a), "B")
        XCTAssertEqual(try marker(in: b), "A")
    }

    func test_pathsWithSpacesAndQuotes_areSwapped() throws {
        let a = try makeDirectory("My App's \"old\" $(copy).app", content: "A")
        let b = try makeDirectory("new 'staged' `Maugham`.app", content: "B")
        let result = try runTool([a.path, b.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try marker(in: a), "B")
        XCTAssertEqual(try marker(in: b), "A")
    }

    func test_badUsage_exits64_andTouchesNothing() throws {
        let a = try makeDirectory("a", content: "A")
        let b = try makeDirectory("b", content: "B")
        let c = try makeDirectory("c", content: "C")
        for arguments in [[], [a.path], [a.path, b.path, c.path], ["a", b.path], [a.path, "b"], ["", b.path]] {
            let result = try runTool(arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.hasPrefix("usage: maugham-swap"), result.stderr)
        }
        XCTAssertEqual(try marker(in: a), "A")
        XCTAssertEqual(try marker(in: b), "B")
    }

    func test_aMissingPath_exits1_namesTheError_andTouchesNothing() throws {
        let a = try makeDirectory("a", content: "A")
        let missing = TestTemp.root.appendingPathComponent("missing")
        let result = try runTool([a.path, missing.path])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stderr, "maugham-swap: \(String(cString: strerror(ENOENT)))\n")
        XCTAssertEqual(try marker(in: a), "A")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
