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

    func test_bootstrap_isIdempotent_doesNotRunIfIdsAlreadyPresent() async throws {
        let mdURL = tmp.appendingPathComponent("manuscript.md")
        try "<!-- ¶a3f9 -->\n\nAlready tagged.\n".write(to: mdURL, atomically: true, encoding: .utf8)

        let result = try await Bootstrap.run(
            projectURL: tmp, docId: "doc-1", mdURL: mdURL,
            device: "m", session: "s")

        XCTAssertFalse(result.bootstrapped, "should detect existing IDs and skip")
        let store = OpLogStore(projectURL: tmp)
        let ops = try await store.load(docId: "doc-1")
        XCTAssertEqual(ops, [])
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
