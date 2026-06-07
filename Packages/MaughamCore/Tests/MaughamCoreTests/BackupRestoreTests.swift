import XCTest
@testable import MaughamCore

final class BackupRestoreTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_700_000_000)

    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rsd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_listGenerations_mergesDestinationsNewestFirst() throws {
        let source = try makeTree(["a.md": "alpha"])
        let d1 = destDir(); let d2 = destDir()
        defer { [source, d1, d2].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: d1, generationId: "01A", at: when)
        _ = try BackupWriter.write(source: source, to: d2, generationId: "01C", at: when)
        _ = try BackupWriter.write(source: source, to: d1, generationId: "01B", at: when)

        let gens = BackupRestore.listGenerations(across: [d1, d2])

        // Newest-first by ULID id, across both destinations.
        XCTAssertEqual(gens.map(\.id), ["01C", "01B", "01A"])
        XCTAssertEqual(gens.first?.destination, d2)
        XCTAssertEqual(gens.first?.builtAt, when)
    }

    func test_listGenerations_emptyWhenNoDestinationsOrGenerations() {
        XCTAssertTrue(BackupRestore.listGenerations(across: []).isEmpty)
        XCTAssertTrue(BackupRestore.listGenerations(across: [destDir()]).isEmpty)
    }
}
