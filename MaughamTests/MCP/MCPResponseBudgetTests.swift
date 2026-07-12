import XCTest
import MaughamCore
@testable import Maugham

/// E4 (2026-07-11 maintainability review): the "1 MB MCP response cap"
/// (ADR 0004 / tripwire 10) was real code only for images. Text tools emitted
/// unbounded, so `read_document` on a novel silently overran the JSON-RPC
/// transport line. These tests pin the byte-budget guard: an oversized text
/// response fails loudly with a structured `payload_too_large` + a hint toward
/// a section-scoped alternative, and a normal response still passes untouched.
@MainActor
final class MCPResponseBudgetTests: XCTestCase {

    // MARK: - Helpers

    /// Write a manuscript `.md` whose materialized (anchored) body is safely
    /// over the 900 KB text budget, seed its op log via `Document.load` (so the
    /// closed-doc read path through `DerivedManuscript` sees it), and register
    /// the project. Returns the project id for the MCP request.
    private func makeOversizedManuscriptProject(bodyBytes: Int) async throws
        -> (url: URL, reg: ProjectRegistry, id: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MRB-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        // Builder loop: ~600-char paragraphs separated by blank lines until we
        // exceed the requested body size. Plain ASCII prose so the count is a
        // faithful lower bound on the emitted UTF-8 payload.
        let para = String(repeating: "The lighthouse keeper waited through the long grey dusk. ", count: 11)
        var body = "Chapter 1\n\n"
        while body.utf8.count < bodyBytes {
            body += para
            body += "\n\n"
        }
        try body.write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)

        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document, path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // Seed the op log so the ADR-0018 closed-doc branch has a source.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)

        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, reg, ProjectIdentifier.id(for: tmp))
    }

    /// Assert that `body` throwing produced a structured `payload_too_large`
    /// tool error with a non-empty hint. Returns the payload for extra checks.
    private func expectPayloadTooLarge(
        _ body: () async throws -> Data,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> MCPError.ToolErrorPayload? {
        do {
            _ = try await body()
            XCTFail("expected payload_too_large, got a full emit", file: file, line: line)
            return nil
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "payload_too_large", file: file, line: line)
            XCTAssertNotNil(payload.hint, "too-large error must carry a hint", file: file, line: line)
            XCTAssertFalse(payload.hint?.isEmpty ?? true, file: file, line: line)
            return payload
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - read_document (manuscript) — the E4 case

    func test_readDocument_oversizedManuscript_throwsPayloadTooLarge() async throws {
        let (_, reg, id) = try await makeOversizedManuscriptProject(bodyBytes: 1_100_000)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        _ = await expectPayloadTooLarge {
            try await ReadDocumentTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        }
    }

    func test_readDocument_normalManuscript_passesThrough() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MRB-ok-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter 1\n\nA short first paragraph.\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document, path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"document_id\":\"ch-1\"}"
        let json = try await ReadDocumentTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let doc = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: json)
        XCTAssertTrue(doc.text.contains("A short first paragraph"))
    }

    // MARK: - read_publish_file — the survey's next-most-at-risk text emitter

    func test_readPublishFile_oversized_throwsPayloadTooLarge() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MRB-pub-\(UUID())")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/publish/build"),
            withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // A compile.log is the realistic large file here.
        let big = String(repeating: "LaTeX warning: overfull hbox on page 42.\n", count: 30_000)
        try big.write(
            to: tmp.appendingPathComponent(".maugham/publish/build/compile.log"),
            atomically: true, encoding: .utf8)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"path\":\"build/compile.log\"}"
        _ = await expectPayloadTooLarge {
            try await ReadPublishFileTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        }
    }

    func test_readPublishFile_normal_passesThrough() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MRB-pub-ok-\(UUID())")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/publish"),
            withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        try "\\documentclass{book}\n".write(
            to: tmp.appendingPathComponent(".maugham/publish/template.tex"),
            atomically: true, encoding: .utf8)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"path\":\"template.tex\"}"
        let json = try await ReadPublishFileTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(obj["content"] as? String, "\\documentclass{book}\n")
    }
}
