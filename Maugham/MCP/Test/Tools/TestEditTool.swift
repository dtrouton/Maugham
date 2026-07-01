import Foundation
import MaughamCore

#if MAUGHAM_DEV_BUILD

/// `test_apply_edit` — the "typing" surrogate. Sets the FULL display text via
/// the exact path the editor binding uses (`Document.setFullText` then
/// `DocumentStore.recordEditorTextWrite`), mirroring `EditorHost.swift`'s
/// `text` binding setter exactly. Not a parallel write path — this drives
/// the same op-log/autosave/word-count machinery a real keystroke would.
public enum TestApplyEditTool: MCPTool {
    public struct Params: Codable {
        let project_id: String
        let doc_id: String
        let new_text: String
        let cursor: Int?
    }
    public struct Result: Codable {
        public let ok: Bool
        public let display_text: String
    }
    public static let method = "test_apply_edit"
    public static let description = "Dev-only: set a doc's full display text as if the user typed it (Document.setFullText + recordEditorTextWrite). Compute new_text from test_dump_document."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"doc_id":{"type":"string"},"new_text":{"type":"string"},"cursor":{"type":"integer"}},"required":["project_id","doc_id","new_text"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        // Safety fence: this tool MUTATES the manuscript (setFullText +
        // recordEditorTextWrite). The dev-build ProjectRegistry also holds the
        // writer's REAL open projects, so require the target live under
        // TestWorkspace.root before any write can happen. Throws
        // TestWorkspaceError.outsideWorkspace otherwise.
        try TestWorkspace.require(entry.url)
        guard let ds = entry.store.documentStore, let doc = ds.document(forDocId: p.doc_id) else {
            throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
        }
        // WritingMode is derived from the doc's manuscript-relative path, the
        // same way EditorHost.swift derives it (`currentItem.path` off the
        // manifest structure item, see EditorHost.swift:63,77).
        guard let item = TreeWalk.find(id: p.doc_id, in: entry.store.manifest.structure),
              let path = item.path else {
            throw MCPError.invalidArgument("no manifest structure item with path for doc: \(p.doc_id)")
        }
        doc.setFullText(p.new_text, postEditCursor: p.cursor)
        // Second half of the editor binding: word-count/session bookkeeping.
        ds.recordEditorTextWrite(
            documentId: p.doc_id,
            newText: p.new_text,
            mode: WritingModeFactory.mode(for: path),
            store: entry.store)
        return try JSONEncoder().encode(Result(ok: true, display_text: doc.displayText))
    }
}
#endif
