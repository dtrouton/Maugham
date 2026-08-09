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

    /// FM-1 gave the checkpoint log a device slug, so the exclusion had to stop
    /// being an exact path and start being the whole partitioned STREAM. This is
    /// the `sessions/`-vs-`sessions.json` failure above, one milestone later: an
    /// exclusion that no longer matches the file that is actually written reads
    /// exactly like no exclusion at all, and every ⌘S would mint a generation.
    @MainActor
    func test_signature_unchangedWhenAPerDeviceCheckpointFileChanges() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        let before = BackupSignature.compute(projectURL: proj)

        let slug = DeviceSlug.make(from: "Denvers-Mac.local")
        try "{\"checkpoint_id\":\"x\"}\n".write(
            to: CheckpointStore.fileURL(deviceSlug: slug, in: proj),
            atomically: true, encoding: .utf8)
        let after = BackupSignature.compute(projectURL: proj)

        XCTAssertEqual(before, after,
                       "checkpoints.<slug>.jsonl is the same volatile bookkeeping the "
                       + "unsuffixed file was, and must be excluded the same way")
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

    // MARK: - Volatile sidecars must not perturb the signature
    //
    // Regression: the exclusion list carried `sessions/` and `ui-state/` —
    // directories that never existed — while the real artifacts are
    // `sessions.json` and `ui-state.json`. Both therefore contributed their
    // content hash, so every UI-state change minted a whole backup generation.
    // Harmless-looking until the persona work put `persona`/`personaMemory` in
    // ui-state.json and every ⌘1–⌘4 press started writing one.

    @MainActor
    func test_signature_unchangedWhenUIStateChanges() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        let uiState = proj.appendingPathComponent(".maugham/ui-state.json")
        try #"{"schemaVersion":5,"persona":"author"}"#.write(to: uiState, atomically: true, encoding: .utf8)
        let before = BackupSignature.compute(projectURL: proj)

        // The writer presses ⌘1. Nothing worth backing up has changed.
        try #"{"schemaVersion":5,"persona":"plan"}"#.write(to: uiState, atomically: true, encoding: .utf8)

        XCTAssertEqual(BackupSignature.compute(projectURL: proj), before,
                       "a UI-state change must not mint a backup generation")
    }

    @MainActor
    func test_signature_unchangedWhenSessionLogChanges() throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        let sessions = proj.appendingPathComponent(".maugham/sessions.json")
        try #"{"schemaVersion":1,"entries":[]}"#.write(to: sessions, atomically: true, encoding: .utf8)
        let before = BackupSignature.compute(projectURL: proj)

        try #"{"schemaVersion":1,"entries":[{"words":120}]}"#.write(to: sessions, atomically: true, encoding: .utf8)

        XCTAssertEqual(BackupSignature.compute(projectURL: proj), before,
                       "session bookkeeping must not mint a backup generation")
    }

    @MainActor
    func test_signature_stillChangesWhenRealContentChanges() throws {
        // The guard above must not have been bought by excluding too much.
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, [contentOp("01A")])
        try FileManager.default.createDirectory(
            at: proj.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let chapter = proj.appendingPathComponent("manuscript/c1.md")
        try "First paragraph.".write(to: chapter, atomically: true, encoding: .utf8)
        let before = BackupSignature.compute(projectURL: proj)

        try "First paragraph. Second.".write(to: chapter, atomically: true, encoding: .utf8)

        XCTAssertNotEqual(BackupSignature.compute(projectURL: proj), before,
                          "a manuscript edit MUST mint a backup generation")
    }
}
