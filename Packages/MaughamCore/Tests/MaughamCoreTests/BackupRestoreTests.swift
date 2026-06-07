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

    func test_newestIntact_skipsCorruptGenerationsToFindGoodOne() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)  // good
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01B", at: when)  // will corrupt
        // Corrupt the newest generation's content.
        try "ROT".write(to: dest.appendingPathComponent("01B/a.md"), atomically: true, encoding: .utf8)

        let intact = BackupRestore.newestIntact(across: [dest])
        XCTAssertEqual(intact?.id, "01A")  // bisected past the corrupt 01B
    }

    func test_newestIntact_nilWhenAllCorruptOrNone() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertNil(BackupRestore.newestIntact(across: [dest]))  // none
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(BackupRestore.newestIntact(across: [dest]))  // all corrupt
    }

    func test_verify_returnsMismatchedPaths() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        XCTAssertEqual(BackupRestore.verify(gen), [])
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BackupRestore.verify(gen), ["a.md"])
    }

    func test_restoreBeside_copiesProjectWithoutBackupSidecars() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        // Give it a signature sidecar too (as a real backup run would).
        try "sig".write(to: dest.appendingPathComponent("01A/\(BackupSignature.signatureName)"),
                        atomically: true, encoding: .utf8)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("restored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }

        let result = try BackupRestore.restoreBeside(gen, to: target)

        XCTAssertEqual(result, target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.md"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("sub/b.md"), encoding: .utf8), "beta")
        // Backup bookkeeping must NOT appear in a restored project.
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(BackupWriter.manifestName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(BackupSignature.signatureName).path))
    }

    func test_restoreBeside_refusesExistingTarget() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        let target = destDir()  // already exists
        defer { [source, dest, target].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        XCTAssertThrowsError(try BackupRestore.restoreBeside(gen, to: target)) {
            XCTAssertEqual($0 as? RestoreError, .targetAlreadyExists(target))
        }
    }

    func test_restoreBeside_refusesCorruptGeneration() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        let gen = BackupRestore.listGenerations(across: [dest])[0]
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString)")
        XCTAssertThrowsError(try BackupRestore.restoreBeside(gen, to: target)) {
            XCTAssertEqual($0 as? RestoreError, .generationCorrupt(mismatchedPaths: ["a.md"]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))  // nothing written
    }
}
