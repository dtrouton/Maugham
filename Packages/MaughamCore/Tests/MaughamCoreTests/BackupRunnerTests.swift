import XCTest
@testable import MaughamCore

final class BackupRunnerTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_700_000_000)

    func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("br-\(UUID().uuidString)")
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("brd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_latestRootHash_nilWhenNoGenerations() throws {
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertNil(try BackupRunner.latestRootHash(at: dest))
    }

    func test_latestRootHash_matchesNewestGenerationManifest() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        let gen = try BackupWriter.write(source: source, to: dest, generationId: "01A", at: when)
        XCTAssertEqual(try BackupRunner.latestRootHash(at: dest), gen.manifest.rootHash)
    }

    // Regression: an idle ⌘S only appends a `.checkpoint` breadcrumb op to the op
    // log; that must NOT spawn a new generation (was the "saves every time" bug).
    func test_run_skipsWhenOnlyACheckpointOpWasAppended() throws {
        let proj = FileManager.default.temporaryDirectory.appendingPathComponent("brp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: proj.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        let dest = destDir()
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        func line(_ id: String, _ kind: OpKind) -> String {
            let op = Op(opId: id, docId: "doc-0f0f0f0f", at: Date(timeIntervalSince1970: 0),
                        device: "macA", session: "s", kind: kind, changes: [], sequence: nil, provenance: nil)
            return String(data: try! enc.encode(op), encoding: .utf8)!
        }
        let opsFile = proj.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl")
        try (line("01A", .typingBurst) + "\n").write(to: opsFile, atomically: true, encoding: .utf8)

        _ = BackupRunner.run(projectURL: proj, destinations: [BackupDestination(url: dest, retention: 5)],
                             generationId: "01GEN1", at: when)
        // Simulate a checkpoint-only save: append a `.checkpoint` op.
        try (line("01A", .typingBurst) + "\n" + line("01CP", .checkpoint) + "\n")
            .write(to: opsFile, atomically: true, encoding: .utf8)
        let second = BackupRunner.run(projectURL: proj, destinations: [BackupDestination(url: dest, retention: 5)],
                                      generationId: "01GEN2", at: when)

        guard case .skippedUnchanged = second[0] else { return XCTFail("expected skip, got \(second[0])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01GEN1"])  // no churn
    }

    func test_run_writesToAllDestinationsFirstTime() throws {
        let source = try makeTree(["a.md": "alpha", "sub/b.md": "beta"])
        let d1 = destDir(); let d2 = destDir()
        defer { [source, d1, d2].forEach { try? FileManager.default.removeItem(at: $0) } }

        let outcomes = BackupRunner.run(
            projectURL: source,
            destinations: [BackupDestination(url: d1, retention: 3),
                           BackupDestination(url: d2, retention: 3)],
            generationId: "01A", at: when)

        XCTAssertEqual(outcomes.count, 2)
        for o in outcomes {
            guard case .written = o else { return XCTFail("expected written, got \(o)") }
        }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01A"])
        XCTAssertEqual(try BackupWriter.generationIds(at: d2), ["01A"])
    }

    func test_run_skipsUnchangedSourceSecondTime() throws {
        let source = try makeTree(["a.md": "alpha"])
        let d1 = destDir()
        defer { [source, d1].forEach { try? FileManager.default.removeItem(at: $0) } }

        _ = BackupRunner.run(projectURL: source,
                             destinations: [BackupDestination(url: d1, retention: 3)],
                             generationId: "01A", at: when)
        // Nothing changed → second run with a NEW id must skip, not write a twin.
        let second = BackupRunner.run(projectURL: source,
                                      destinations: [BackupDestination(url: d1, retention: 3)],
                                      generationId: "01B", at: when)
        guard case .skippedUnchanged = second[0] else { return XCTFail("expected skip, got \(second[0])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01A"])  // still just the first
    }

    func test_run_writesNewGenerationWhenSourceChanges() throws {
        let source = try makeTree(["a.md": "alpha"])
        let d1 = destDir()
        defer { [source, d1].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = BackupRunner.run(projectURL: source,
                             destinations: [BackupDestination(url: d1, retention: 3)],
                             generationId: "01A", at: when)
        // Change the source, then a second run must write a new generation.
        try "CHANGED".write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let second = BackupRunner.run(projectURL: source,
                                      destinations: [BackupDestination(url: d1, retention: 3)],
                                      generationId: "01B", at: when)
        guard case .written = second[0] else { return XCTFail("expected written, got \(second[0])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01A", "01B"])
    }

    func test_run_appliesRetentionPerDestination() throws {
        let source = try makeTree(["a.md": "v0"])
        let d1 = destDir()
        defer { [source, d1].forEach { try? FileManager.default.removeItem(at: $0) } }
        // Three changing runs, retention 2 → oldest pruned.
        for (i, id) in ["01A", "01B", "01C"].enumerated() {
            try "v\(i)".write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            _ = BackupRunner.run(projectURL: source,
                                 destinations: [BackupDestination(url: d1, retention: 2)],
                                 generationId: id, at: when)
        }
        XCTAssertEqual(try BackupWriter.generationIds(at: d1), ["01B", "01C"])
    }

    // MARK: - FM-2: a corrupt newest generation must not suppress backups

    /// `BackupRetention_NoWedgedOnCorruptNewest`. The signature marker lives
    /// INSIDE the generation directory it describes, so partial corruption — the
    /// common kind — rots the content and leaves the marker readable. Answering
    /// with that marker made every later run report `.skippedUnchanged`: the
    /// system said "backed up", wrote nothing, and never replaced the corrupt
    /// newest generation for as long as the writer did not edit.
    func test_latestSignature_nilWhenTheNewestGenerationDoesNotVerify() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = BackupRunner.run(projectURL: source,
                             destinations: [BackupDestination(url: dest, retention: 5)],
                             generationId: "01A", at: when)
        XCTAssertNotNil(try BackupRunner.latestSignature(at: dest))

        // Content only — the `.maugham-backup-signature` marker survives.
        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("01A")
                .appendingPathComponent(BackupSignature.signatureName).path))

        XCTAssertNil(try BackupRunner.latestSignature(at: dest))
    }

    /// The wedge itself, through `run`: with the source unchanged, the run that
    /// follows the corruption must still WRITE, and exactly one such run is
    /// needed before skip-detection resumes.
    func test_run_doesNotSkipWhileTheNewestGenerationIsCorrupt() throws {
        let source = try makeTree(["a.md": "alpha"])
        let dest = destDir()
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        func run(_ id: String) -> BackupOutcome {
            BackupRunner.run(projectURL: source,
                             destinations: [BackupDestination(url: dest, retention: 5)],
                             generationId: id, at: when)[0]
        }
        guard case .written = run("01A") else { return XCTFail("first run must write") }
        guard case .skippedUnchanged = run("01B") else {
            return XCTFail("an unchanged source over an intact newest must still skip")
        }

        try "ROT".write(to: dest.appendingPathComponent("01A/a.md"), atomically: true, encoding: .utf8)

        guard case .written = run("01C") else {
            return XCTFail("a corrupt newest generation must not suppress the backup")
        }
        // ...and the replacement is intact, so the next run goes back to skipping.
        guard case .skippedUnchanged = run("01D") else {
            return XCTFail("skip-detection must resume once the newest verifies again")
        }
    }

    func test_run_oneFailingDestinationDoesNotAbortOthers() throws {
        let source = try makeTree(["a.md": "alpha"])
        let good = destDir()
        // A destination URL where a FILE sits where the dir must be → createDirectory fails.
        let badParent = destDir()
        let bad = badParent.appendingPathComponent("blocker")
        try "x".write(to: bad, atomically: true, encoding: .utf8)  // `bad` is a file, not a dir
        defer { [source, good, badParent].forEach { try? FileManager.default.removeItem(at: $0) } }

        let outcomes = BackupRunner.run(
            projectURL: source,
            destinations: [BackupDestination(url: bad, retention: 3),
                           BackupDestination(url: good, retention: 3)],
            generationId: "01A", at: when)

        guard case .failed = outcomes[0] else { return XCTFail("expected failed for bad dest, got \(outcomes[0])") }
        guard case .written = outcomes[1] else { return XCTFail("expected written for good dest, got \(outcomes[1])") }
        XCTAssertEqual(try BackupWriter.generationIds(at: good), ["01A"])  // good one still succeeded
    }
}
