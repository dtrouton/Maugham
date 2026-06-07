import XCTest
@testable import MaughamCore

final class BackupWriterTests: XCTestCase {
    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func test_relativeFilePaths_listsAllFilesRecursivelySorted() throws {
        let root = try makeTree(["a.md": "a", "sub/b.md": "b", "sub/deep/c.md": "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            try BackupWriter.relativeFilePaths(under: root),
            ["a.md", "sub/b.md", "sub/deep/c.md"])
    }

    func test_relativeFilePaths_emptyDirIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try BackupWriter.relativeFilePaths(under: root), [])
    }
}
