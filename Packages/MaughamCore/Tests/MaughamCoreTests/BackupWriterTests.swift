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

    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_write_copiesAllFilesAndEmbedsVerifiableManifest() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }

        let gen = try BackupWriter.write(source: source, to: dest, generationId: "01GEN", at: when)

        let genDir = dest.appendingPathComponent("01GEN")
        XCTAssertEqual(gen.id, "01GEN")
        XCTAssertEqual(try String(contentsOf: genDir.appendingPathComponent("a.md"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: genDir.appendingPathComponent("sub/b.md"), encoding: .utf8), "beta")
        // Manifest exists and verifies against the copied tree.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: genDir.appendingPathComponent(BackupWriter.manifestName).path))
        XCTAssertEqual(MerkleBuilder.verify(manifest: gen.manifest, root: genDir), [])
        // Manifest does not list itself.
        XCTAssertFalse(gen.manifest.entries.contains { $0.relativePath == BackupWriter.manifestName })
    }

    func test_write_leavesNoPartialDirOnSuccess() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01GEN", at: when)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertEqual(entries, ["01GEN"])  // no .partial-* left behind
    }

    func test_write_cleansLeftoverPartialFromPriorFailure() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        // Simulate a leftover partial from a crashed prior run.
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent(".partial-01GEN"), withIntermediateDirectories: true)
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01GEN", at: when)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["01GEN"])
    }

    func test_generationIds_listsCommittedGenerationsSortedIgnoringPartials() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01B", at: when)
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01C", at: when)
        // A stray partial + a stray dotfile must be ignored.
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent(".partial-XX"), withIntermediateDirectories: true)

        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A", "01B", "01C"])
    }

    func test_generationIds_missingDestinationIsEmpty() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])
    }

    func test_prune_keepsNewestNAndRemovesOlder() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        for id in ["01A", "01B", "01C", "01D"] {
            _ = try BackupWriter.write(source: source, to: dest, generationId: id, at: when)
        }
        let removed = try BackupWriter.prune(destination: dest, keeping: 2)
        XCTAssertEqual(removed, ["01A", "01B"])               // oldest removed
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01C", "01D"])  // newest kept
    }

    func test_prune_noOpWhenWithinLimit() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 5), [])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A"])
    }

    func test_prune_keepingZeroRemovesAll() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 0), ["01A"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])
    }

    // MARK: - FM-2: retention orders by recency, recovery orders by intactness

    /// The defect `BackupRetention_NoCorruptRetainedOverIntact` describes: three
    /// generations, the middle one rotted, retention 2. Ordering by recency alone
    /// keeps `{01B corrupt, 01C intact}` and deletes `01A` — an intact generation
    /// destroyed to make room for one nothing can be recovered from, so the
    /// writer's effective protection is quietly 1 rather than the 2 they set.
    /// Falsified against the model: green under
    /// `BackupRetention_Fixed_NoCorruptRetainedOverIntact`, violated under its
    /// partner `BackupRetention_NoCorruptRetainedOverIntact`.
    func test_prune_neverDeletesAnIntactGenerationToKeepACorruptOne() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        for id in ["01A", "01B", "01C"] {
            _ = try BackupWriter.write(source: source, to: dest, generationId: id, at: when)
        }
        try "ROT".write(to: dest.appendingPathComponent("01B/a.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 2), ["01B"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A", "01C"])
        XCTAssertEqual(BackupRestore.newestIntact(across: [dest])?.id, "01C")
    }

    /// Intactness only ever *rescues*. With everything verifying, the answer is
    /// the recency answer — the retained set must not start reordering itself
    /// around a check that has nothing to say.
    func test_prune_isStillRecencyOrderedWhenEveryGenerationVerifies() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        for id in ["01A", "01B", "01C", "01D"] {
            _ = try BackupWriter.write(source: source, to: dest, generationId: id, at: when)
        }
        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 2), ["01A", "01B"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01C", "01D"])
    }

    /// When there are fewer intact generations than slots, the corrupt ones top
    /// the retained set up newest-first rather than being deleted — a corrupt
    /// generation is still forensic evidence, and nothing intact is displaced by
    /// keeping it.
    func test_prune_fillsRemainingSlotsWithTheNewestCorruptGenerations() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        for id in ["01A", "01B", "01C", "01D"] {
            _ = try BackupWriter.write(source: source, to: dest, generationId: id, at: when)
        }
        for id in ["01B", "01C", "01D"] {
            try "ROT".write(to: dest.appendingPathComponent("\(id)/a.md"), atomically: true, encoding: .utf8)
        }
        // Only 01A verifies; the second slot goes to the newest corrupt one.
        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 2), ["01B", "01C"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A", "01D"])
    }

    /// A generation whose manifest cannot be read is not "unknown" — it is
    /// not-intact, because the only property retention cares about is whether it
    /// can be recovered from.
    func test_prune_treatsAnUnreadableManifestAsNotIntact() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        for id in ["01A", "01B", "01C"] {
            _ = try BackupWriter.write(source: source, to: dest, generationId: id, at: when)
        }
        try FileManager.default.removeItem(
            at: dest.appendingPathComponent("01B").appendingPathComponent(BackupWriter.manifestName))

        XCTAssertEqual(try BackupWriter.prune(destination: dest, keeping: 2), ["01B"])
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A", "01C"])
    }

    func test_verifyGeneration_cleanWhenUntouched() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupWriter.verifyGeneration(id: "01A", at: dest), [])
    }

    func test_verifyGeneration_detectsTamper() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        // Corrupt a file inside the committed generation.
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try BackupWriter.verifyGeneration(id: "01A", at: dest), ["a.md"])
    }

    func test_verifyGeneration_throwsWhenManifestMissing() throws {
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        // A directory with no manifest (e.g. not a real generation).
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent("GHOST"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupWriter.verifyGeneration(id: "GHOST", at: dest))
    }

    func test_write_refusesToOverwriteExistingGeneration() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        _ = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        // Second write with the same id must throw and leave the original intact.
        XCTAssertThrowsError(
            try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        ) { error in
            XCTAssertEqual(error as? BackupError, .generationAlreadyExists(id: "01A"))
        }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("01A/a.md"), encoding: .utf8), "alpha")
        // No partial left behind by the refused write.
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01A"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".partial-01A").path))
    }
}
