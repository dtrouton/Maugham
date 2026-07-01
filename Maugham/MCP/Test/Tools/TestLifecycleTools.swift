import Foundation
import MaughamCore

/// `test_flush_autosave` — dev-only lifecycle tool. Forces the live doc's
/// pending burst (`flushBurstNow`) and then its debounced autosave
/// (`performAutosave`, `internal` on `Document` and reachable directly from
/// this app-target tool) to write the clean, anchor-free `.md` to disk NOW,
/// without waiting on the 750ms autosave debounce.
public enum TestFlushAutosaveTool: MCPTool {
    public struct Params: Codable { let project_id: String; let doc_id: String }
    public struct Result: Codable { public let ok: Bool; public let clean_disk_bytes: Int }
    public static let method = "test_flush_autosave"
    public static let description = "Dev-only: force the doc's pending burst + autosave to write the clean .md now (no 750ms wait)."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        guard let doc = entry.store.documentStore?.document(forDocId: p.doc_id) else {
            throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
        }
        try await doc.flushBurstNow()
        try await doc.performAutosave()
        let bytes = MarkdownDisplayFilter.stripAnchors(doc.materialize())
        return try JSONEncoder().encode(Result(ok: true, clean_disk_bytes: bytes.utf8.count))
    }
}

/// `test_checkpoint` — dev-only lifecycle tool. Fires a project-scope ⌘S
/// checkpoint (flushing the live doc's pending burst first) via the same
/// `CheckpointCapture.run` entry point the real ⌘S handler uses.
public enum TestCheckpointTool: MCPTool {
    public struct Params: Codable { let project_id: String; let doc_id: String; let label: String? }
    public struct Result: Codable { public let label: String; public let checkpoint_count: Int }
    public static let method = "test_checkpoint"
    public static let description = "Dev-only: fire a project-scope \u{2318}S checkpoint (flushes the live doc first)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"doc_id":{"type":"string"},"label":{"type":"string"}},"required":["project_id","doc_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        guard let ds = entry.store.documentStore, let doc = ds.document(forDocId: p.doc_id) else {
            throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
        }
        try? await doc.flushBurstNow()
        let cp = try await CheckpointCapture.run(
            projectURL: entry.url,
            activeDocId: p.doc_id,
            allDocIds: ds.allOpenDocuments().map { $0.docId },
            device: doc.device,
            session: doc.session,
            label: p.label,
            activeDocument: doc)
        let all = try await CheckpointStore(projectURL: entry.url).load()
        return try JSONEncoder().encode(Result(label: cp.label, checkpoint_count: all.count))
    }
}
