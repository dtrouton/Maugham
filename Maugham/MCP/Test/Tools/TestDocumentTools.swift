import AppKit
import Foundation
import MaughamCore

#if MAUGHAM_DEV_BUILD

/// `test_add_document` — dev-only. Adds a manuscript document at the root of
/// the structure through the binder's own verb (`ProjectStore.addStructureItem`),
/// so a scripted smoke can build a multi-chapter book without a click.
public enum TestAddDocumentTool: MCPTool {
    public struct Params: Codable { let project_id: String; let title: String }
    public struct Result: Codable { public let doc_id: String; public let path: String }
    public static let method = "test_add_document"
    public static let description = "Dev-only: add a manuscript document at the structure root (the binder's own verb)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"title":{"type":"string"}},"required":["project_id","title"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        try TestWorkspace.require(entry.url)
        let item = try await entry.store.addStructureItem(
            parentId: nil, title: p.title, kind: .document(extension: "md"))
        return try JSONEncoder().encode(Result(doc_id: item.id, path: item.path ?? ""))
    }
}

/// `test_open_document` — dev-only. Loads a document through the one door
/// (`Document.load`, as the author actor — exactly what `EditorHost` does) and
/// registers it, so the other `test_` tools can type into it. Refuses a doc
/// already open (a second live `Document` for one path is two writers). A load
/// refusal — e.g. `waitingForPiece` — comes back as the error, verbatim.
public enum TestOpenDocumentTool: MCPTool {
    public struct Params: Codable { let project_id: String; let doc_id: String }
    public struct Result: Codable { public let ok: Bool; public let display_text: String }
    public static let method = "test_open_document"
    public static let description = "Dev-only: load + register a document as the author actor (EditorHost's load), so test_apply_edit can reach it."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    private static let sessionId = UUID().uuidString

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        try TestWorkspace.require(entry.url)
        guard let ds = entry.store.documentStore else {
            throw MCPError.invalidArgument("project has no document store")
        }
        if let open = ds.document(forDocId: p.doc_id) {
            return try JSONEncoder().encode(Result(ok: true, display_text: open.displayText))
        }
        guard let item = TreeWalk.find(id: p.doc_id, in: entry.store.manifest.structure),
              let path = item.path else {
            throw MCPError.invalidArgument("no manifest structure item with path for doc: \(p.doc_id)")
        }
        let doc: Document
        do {
            doc = try await Document.load(
                url: entry.url.appendingPathComponent(path),
                actor: .author,
                session: sessionId,
                presenter: ds.presenter)
        } catch {
            throw MCPError.invalidArgument("load refused: \(error)")
        }
        ds.register(document: doc, for: path)
        return try JSONEncoder().encode(Result(ok: true, display_text: doc.displayText))
    }
}

/// `test_close_document` — dev-only. The inverse: flush, close and unregister,
/// so a later `test_open_document` re-runs the load against what is on disk now.
public enum TestCloseDocumentTool: MCPTool {
    public struct Params: Codable { let project_id: String; let doc_id: String }
    public struct Result: Codable { public let ok: Bool }
    public static let method = "test_close_document"
    public static let description = "Dev-only: close + unregister a document opened with test_open_document."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        try TestWorkspace.require(entry.url)
        guard let ds = entry.store.documentStore, let doc = ds.document(forDocId: p.doc_id),
              let item = TreeWalk.find(id: p.doc_id, in: entry.store.manifest.structure),
              let path = item.path else {
            throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
        }
        await doc.close()
        ds.unregister(path: path)
        return try JSONEncoder().encode(Result(ok: true))
    }
}
#endif
