import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentOpLogAccessorTests: XCTestCase {

    private func makeProject(initialMd: String) throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OPLOG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    func test_opLog_returnsLogIncludingBootstrap() async throws {
        let (project, path) = try makeProject(
            initialMd: "First paragraph.\n\nSecond paragraph.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let ops = try await doc.opLog()
        XCTAssertFalse(ops.isEmpty)
        XCTAssertTrue(ops.contains(where: { $0.kind == .bootstrap }))
    }

    func test_opLog_reflectsAppendedBurst() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let countBefore = (try await doc.opLog()).count
        doc.setFullText("Hello world.")
        try await doc.flushBurstNow()
        let countAfter = (try await doc.opLog()).count
        XCTAssertEqual(countAfter, countBefore + 1)
        let opsAfter = try await doc.opLog()
        XCTAssertEqual(opsAfter.last?.kind, .typingBurst)
    }
}
