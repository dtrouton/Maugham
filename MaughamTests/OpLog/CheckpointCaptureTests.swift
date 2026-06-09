// MaughamTests/OpLog/CheckpointCaptureTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CheckpointCaptureTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_captureCheckpoint_autoLabel_emitsCheckpointAndOp() async throws {
        // Seed: one typing op so doc has a pointer.
        let opStore = OpLogStore(projectURL: tmp)
        let seedOp = Op(
            opId: ULID.generate(),
            docId: "doc-1", at: Date(),
            device: "m", session: "s",
            kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "Hello.")])
        try await opStore.append(seedOp)

        let cp = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "doc-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s",
            label: nil)        // auto

        XCTAssertEqual(cp.labelSource, .auto)
        XCTAssertEqual(cp.docPointers["doc-1"], seedOp.opId)

        // Persisted to checkpoints.jsonl.
        let cps = try await CheckpointStore(projectURL: tmp).load()
        XCTAssertEqual(cps.count, 1)
        XCTAssertEqual(cps[0], cp)

        // Breadcrumb checkpoint op landed on doc-1's log.
        let ops = try await opStore.load(docId: "doc-1")
        XCTAssertTrue(ops.contains(where: { $0.kind == .checkpoint }))
    }

    func test_captureCheckpoint_userLabel_isHonored() async throws {
        let opStore = OpLogStore(projectURL: tmp)
        try await opStore.append(Op(
            opId: ULID.generate(), docId: "doc-1", at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "Hello.")]))
        let cp = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "doc-1",
            allDocIds: ["doc-1"],
            device: "m", session: "s",
            label: "end of draft 2")
        XCTAssertEqual(cp.label, "end of draft 2")
        XCTAssertEqual(cp.labelSource, .user)
    }

    /// The cpOp appended by CheckpointCapture MUST land in the live
    /// Document's _opLogMirror so the existing opId-set echo guard in
    /// Document+ExternalChange filters it — otherwise every ⌘S triggers a
    /// wasted re-derive when the project-root NSFilePresenter fires on the
    /// op-log file write.
    func test_captureCheckpoint_cpOpLandsInLiveDocumentMirror() async throws {
        // Seed the op log so the doc has a prior content op.
        let opStore = OpLogStore(projectURL: tmp)
        let seedOp = Op(
            opId: ULID.generate(),
            docId: "doc-1", at: Date(),
            device: "m", session: "s",
            kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "Hello.")])
        try await opStore.append(seedOp)

        // Build a minimal Document whose _opLogMirror we can inspect.
        // Write a .md file so Document.load can bootstrap.
        let mdURL = tmp.appendingPathComponent("doc.md")
        try "Hello. <!-- ¶aaaa -->".write(to: mdURL, atomically: true, encoding: .utf8)

        // Manually seed the mirror with the seedOp (simulating a loaded doc
        // that already knows about its own content ops).
        let doc = try await Document.load(
            url: mdURL, device: "m", session: "s", presenter: nil,
            burstIdle: .seconds(1), burstMax: .seconds(2))

        // Before the fix: CheckpointCapture uses a fresh opStore and doesn't
        // inform the live Document — the cpOp won't be in the mirror yet.
        // After the fix: the mirror contains the cpOp.

        // RED baseline: no checkpoint op in the mirror yet.
        XCTAssertFalse(
            doc.opLogSnapshot.contains { $0.kind == .checkpoint },
            "Precondition: mirror must not contain a checkpoint op before run")

        _ = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: doc.docId,
            allDocIds: [doc.docId],
            device: "m", session: "s",
            label: nil,
            activeDocument: doc)

        // The cpOp must now be in the live mirror so the echo guard
        // (mirrorIds.contains) would filter it on the next presenter callback.
        XCTAssertTrue(
            doc.opLogSnapshot.contains { $0.kind == .checkpoint },
            "cpOp must be in the live Document's mirror after CheckpointCapture.run")
    }
}
