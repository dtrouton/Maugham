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
        XCTAssertEqual(report.docSkips.first?.skipped.first?.raw, "GARBAGE NOT JSON")
        XCTAssertEqual(report.conflictTwins, ["doc-0f677d7e.macA 2.jsonl"])
    }
}
