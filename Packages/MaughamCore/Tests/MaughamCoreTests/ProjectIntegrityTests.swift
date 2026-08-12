import XCTest
@testable import MaughamCore

final class ProjectIntegrityTests: XCTestCase {
    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        return url
    }
    private func writeOps(_ project: URL, file: String, lines: [String]) throws {
        let url = project.appendingPathComponent(".maugham/ops/\(file)")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    func test_check_healthyProjectReportsClean() async throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let op = Op(opId: "01ABC", docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
                    device: "macA", session: "s", kind: .checkpoint, changes: [],
                    sequence: nil, provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let line = String(data: try enc.encode(op), encoding: .utf8)!
        try writeOps(proj, file: "doc-0f677d7e.macA.jsonl", lines: [line])

        let report = try await ProjectIntegrity.check(projectURL: proj)
        XCTAssertTrue(report.isHealthy)
    }

    @MainActor
    func test_check_flagsCorruptLineAndConflictTwin() async throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try writeOps(proj, file: "doc-0f677d7e.macA.jsonl", lines: ["GARBAGE NOT JSON"])
        try writeOps(proj, file: "doc-0f677d7e.macA 2.jsonl", lines: ["{}"])

        let report = try await ProjectIntegrity.check(projectURL: proj)
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.docSkips.first?.docId, "doc-0f677d7e")
        // Both the normal file's garbage line and the conflict-twin's `{}` fail to
        // decode as Op; the order they're globbed in isn't guaranteed, so assert the
        // garbage line is present rather than that it's first (avoids a directory-order flake).
        XCTAssertEqual(
            report.docSkips.first?.skipped.contains(where: { $0.raw == "GARBAGE NOT JSON" }), true)
        XCTAssertEqual(report.conflictTwins, ["doc-0f677d7e.macA 2.jsonl"])
    }

    @MainActor
    func test_check_flagsSemanticCorruption_emptyParagraphId() async throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        // A valid-JSON op whose change carries an EMPTY paragraph id — parses fine,
        // but is semantically corrupt (the minor-corruption case the JSON check misses).
        let op = Op(opId: "01ABC", docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
                    device: "macA", session: "s", kind: .typingBurst,
                    changes: [Op.ParagraphChange(paragraphId: "", prior: nil, next: "orphaned")],
                    sequence: nil, provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let line = String(data: try enc.encode(op), encoding: .utf8)!
        try writeOps(proj, file: "doc-0f677d7e.macA.jsonl", lines: [line])

        let report = try await ProjectIntegrity.check(projectURL: proj)
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.docSkips.count, 0)  // it parsed fine — not a syntactic skip
        XCTAssertEqual(report.invalidParagraphIds.map(\.opId), ["01ABC"])
    }

    /// RULING-54: an UNREADABLE-yet-present checkpoint device file is a
    /// FINDING, not fewer findings. It used to read as empty through
    /// `try? … ?? []` — fewer checkpoints meant fewer dangling pointers to
    /// find, so the report got HEALTHIER exactly when the project got worse.
    @MainActor
    func test_check_unreadableCheckpointFile_isAFinding_notFewerFindings() async throws {
        let proj = makeProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        // A directory squatting on a checkpoint device file's path — the same
        // failure shape as a permissions break or an iCloud dataless stub.
        let badURL = CheckpointStore.fileURL(
            deviceSlug: DeviceSlug.unsafeForTesting("bad"), in: proj)
        try FileManager.default.createDirectory(
            at: badURL, withIntermediateDirectories: true)

        let report = try await ProjectIntegrity.check(projectURL: proj)
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.unreadableCheckpointFiles.map(\.name),
                       [badURL.lastPathComponent],
                       "the unreadable checkpoint file is named in the report")
    }
}
