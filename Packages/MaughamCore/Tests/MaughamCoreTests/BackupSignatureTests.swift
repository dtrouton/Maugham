import XCTest
@testable import MaughamCore

final class BackupSignatureTests: XCTestCase {
    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bsig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        return url
    }
    private func encode(_ op: Op) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return String(data: try! enc.encode(op), encoding: .utf8)!
    }
    private func contentOp(_ id: String) -> Op {
        Op(opId: id, docId: "doc-0f0f0f0f", at: Date(timeIntervalSince1970: 0),
           device: "macA", session: "s", kind: .typingBurst, changes: [], sequence: nil, provenance: nil)
    }
    private func checkpointOp(_ id: String) -> Op {
        Op(opId: id, docId: "doc-0f0f0f0f", at: Date(timeIntervalSince1970: 0),
           device: "macA", session: "s", kind: .checkpoint, changes: [], sequence: nil, provenance: nil)
    }
    private func writeOps(_ proj: URL, _ ops: [Op]) throws {
        let body = ops.map(encode).joined(separator: "\n") + "\n"
        try body.write(to: proj.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl"),
                       atomically: true, encoding: .utf8)
    }

    @MainActor
    func test_signature_unchangedWhenOnlyACheckpointOpIsAppended() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        let before = BackupSignature.compute(projectURL: proj)

        // Simulate a ⌘S that only appended a checkpoint breadcrumb.
        try writeOps(proj, [contentOp("01A"), checkpointOp("01CP")])
        let after = BackupSignature.compute(projectURL: proj)

        XCTAssertEqual(before, after, "a checkpoint-only save must not change the signature")
    }

    @MainActor
    func test_signature_unchangedWhenOnlyCheckpointsJsonlChanges() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        let before = BackupSignature.compute(projectURL: proj)

        try "{\"checkpoint_id\":\"x\"}\n".write(
            to: proj.appendingPathComponent(".maugham/checkpoints.jsonl"), atomically: true, encoding: .utf8)
        let after = BackupSignature.compute(projectURL: proj)

        XCTAssertEqual(before, after, "checkpoints.jsonl is volatile bookkeeping, excluded from the signature")
    }

    @MainActor
    func test_signature_changesWhenManuscriptContentChanges() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        let before = BackupSignature.compute(projectURL: proj)

        // A real content op (not a checkpoint) must change the signature.
        try writeOps(proj, [contentOp("01A"), contentOp("01B")])
        XCTAssertNotEqual(before, BackupSignature.compute(projectURL: proj))
    }

    @MainActor
    func test_signature_changesWhenAResearchFileChanges() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        try FileManager.default.createDirectory(
            at: proj.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "v1".write(to: proj.appendingPathComponent("research/note.md"), atomically: true, encoding: .utf8)
        let before = BackupSignature.compute(projectURL: proj)

        try "v2".write(to: proj.appendingPathComponent("research/note.md"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, BackupSignature.compute(projectURL: proj),
                          "research is primary content; changing it must change the signature")
    }
}
