import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 open-doc rule (finding F6): `list_all_links` and `find_references`
/// must read an OPEN doc's live `Document` state. The op log lags an
/// actively-edited doc by the burst window (30s/90s) — the 750ms autosave
/// appends no ops — so wiki tokens typed but not yet flushed would be invisible
/// to a tool that always derives. Closed docs still derive from the op log
/// (see `ReferenceOpLogSourceTests`).
@MainActor
final class ReferenceFreshnessTests: XCTestCase {

    /// Build a one-doc project with the doc OPEN and registered, then apply an
    /// unflushed live edit. Returns the registry + project id for tool calls.
    private func makeOpenDocProject(
        initialMd: String, liveEdit: String
    ) async throws -> (registry: ProjectRegistry, projectId: String, ds: DocumentStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefFresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-reffresh"
        let docURL = tmp.appendingPathComponent(docPath)
        try initialMd.write(to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(id: docId, title: "Ch 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)
        doc.setFullText(liveEdit)   // unflushed — no ops on disk

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (reg, ProjectIdentifier.id(for: tmp), ds)
    }

    func test_listAllLinks_openDoc_seesUnflushedWikiToken() async throws {
        let ctx = try await makeOpenDocProject(
            initialMd: "She met [[OldTarget]] once.",
            liveEdit: "She met [[FreshTarget]] just now.")
        defer { Task { await ctx.ds.close() } }

        let paramsData = Data("{\"project_id\":\"\(ctx.projectId)\"}".utf8)
        let result = try await ListAllLinksTool.handle(
            paramsJSON: paramsData, registry: ctx.registry)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: result)

        XCTAssertTrue(edges.contains { $0.to_title == "FreshTarget" },
            "list_all_links must surface the unflushed live wiki token; edges: \(edges)")
        XCTAssertFalse(edges.contains { $0.to_title == "OldTarget" },
            "the replaced wiki token must not appear; edges: \(edges)")
    }

    func test_findReferences_openDoc_seesUnflushedWikiToken() async throws {
        let ctx = try await makeOpenDocProject(
            initialMd: "Points to [[OldTarget]] as the culprit.",
            liveEdit: "Points to [[FreshTarget]] as the culprit.")
        defer { Task { await ctx.ds.close() } }

        let freshParams = Data(
            "{\"project_id\":\"\(ctx.projectId)\",\"target\":\"FreshTarget\"}".utf8)
        let freshResult = try await FindReferencesTool.handle(
            paramsJSON: freshParams, registry: ctx.registry)
        let freshRefs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: freshResult)
        XCTAssertEqual(freshRefs.count, 1,
            "find_references must surface the unflushed live wiki ref; refs: \(freshRefs)")

        let oldParams = Data(
            "{\"project_id\":\"\(ctx.projectId)\",\"target\":\"OldTarget\"}".utf8)
        let oldResult = try await FindReferencesTool.handle(
            paramsJSON: oldParams, registry: ctx.registry)
        let oldRefs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: oldResult)
        XCTAssertTrue(oldRefs.isEmpty,
            "the replaced wiki token must not back-reference; refs: \(oldRefs)")
    }
}
