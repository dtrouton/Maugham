// MaughamTests/OpLog/BootstrapTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class BootstrapTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BST-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_bootstrap_writesIdsIntoMarkdownAndEmitsOp() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "First paragraph.\n\nSecond paragraph.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try await Bootstrap.run(
            projectURL: tmp,
            docId: "doc-1",
            mdURL: mdURL,
            device: "m",
            session: "s")

        // .md gained inline IDs
        let after = try String(contentsOf: mdURL, encoding: .utf8)
        let parsed = ParagraphParser.parse(after)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNotNil(parsed[0].id)
        XCTAssertNotNil(parsed[1].id)
        XCTAssertNotEqual(parsed[0].id, parsed[1].id)

        // Bootstrap op landed
        let store = OpLogStore(projectURL: tmp)
        let ops = try await store.load(docId: "doc-1")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .bootstrap)
        XCTAssertEqual(ops[0].changes.count, 2)
        XCTAssertEqual(ops[0].sequence?.count, 2)

        // Result reports the new IDs
        XCTAssertEqual(result.paragraphIds.count, 2)
    }

    /// New F2 contract for idempotency: an anchored `.md` is a no-op ONLY when
    /// the doc already has an op log. The existing log is authoritative — the
    /// anchors were minted long ago and the log carries every edit since — so
    /// Bootstrap must not append a duplicate.
    func test_bootstrap_isIdempotent_noOpWhenLogAlreadyExists() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "<!-- ¶a3f9 -->\n\nAlready tagged.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        // Seed an existing op log so the doc is NOT in the torn empty-log state.
        let store = OpLogStore(projectURL: tmp)
        try await store.append(Op(
            opId: ULID.generate(), docId: "doc-1", at: Date(),
            device: "m", session: "s", kind: .bootstrap,
            changes: [.init(paragraphId: "a3f9", prior: nil, next: "Already tagged.")],
            sequence: ["a3f9"]))

        let result = try await Bootstrap.run(
            projectURL: tmp, docId: "doc-1", mdURL: mdURL,
            device: "m", session: "s")

        XCTAssertFalse(result.bootstrapped,
            "an anchored file with an existing op log must be a no-op")
        let ops = try await store.load(docId: "doc-1")
        XCTAssertEqual(ops.count, 1,
            "Bootstrap must not append when an op log already exists")
    }

    /// F2: an anchored `.md` with an EMPTY op log is a torn state (crash between
    /// the anchor write and the op append, a deleted `.maugham/`, or a backup
    /// restore that missed the hidden dir). Bootstrap must SEED the op log from
    /// the file's EXISTING ids — minting nothing, not rewriting the `.md`.
    func test_bootstrap_anchoredFile_emptyLog_seedsFromExistingIds() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        let before = "<!-- ¶a3f9 -->\n\nAlpha.\n\n<!-- ¶b7k2 -->\n\nBravo.\n"
        try before.write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try await Bootstrap.run(
            projectURL: tmp, docId: "doc-1", mdURL: mdURL,
            device: "m", session: "s")

        XCTAssertTrue(result.bootstrapped,
            "anchored file + empty op log must seed the log")
        XCTAssertEqual(result.paragraphIds, ["a3f9", "b7k2"])

        // The `.md` was NOT rewritten (identity + bytes preserved).
        let after = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertEqual(after, before, "seed path must not rewrite the .md")

        // Exactly one bootstrap op carrying the file's EXISTING ids + text.
        let ops = try await OpLogStore(projectURL: tmp).load(docId: "doc-1")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .bootstrap)
        XCTAssertEqual(ops[0].sequence, ["a3f9", "b7k2"])
        XCTAssertEqual(ops[0].changes.map(\.paragraphId), ["a3f9", "b7k2"])
        XCTAssertEqual(ops[0].changes.map(\.next), ["Alpha.", "Bravo."])

        // Initial checkpoint emitted, same as the mint path.
        let cps = try await CheckpointStore(projectURL: tmp).load()
        XCTAssertEqual(cps.count, 1)
        XCTAssertEqual(cps[0].labelSource, .auto)
    }

    func test_bootstrap_emitsAutoLabeledCheckpoint() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "First.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        _ = try await Bootstrap.run(
            projectURL: tmp, docId: "doc-1", mdURL: mdURL,
            device: "m", session: "s")

        let cps = try await CheckpointStore(projectURL: tmp).load()
        XCTAssertEqual(cps.count, 1)
        XCTAssertEqual(cps[0].labelSource, .auto)
        XCTAssertTrue(cps[0].label.contains("Initial"))
    }
}
