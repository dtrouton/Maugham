import Foundation
import MaughamCore

/// Shared resolution helpers for the annotation MCP tools (creation + read).
/// Lifted here so the four creation tools and two read tools agree on how
/// to find a Document by `(project_id, document_id)`.

/// Run `body` against a Document for the given `(project_id, document_id)`.
///
/// Resolution policy:
/// 1. If the document is already loaded in the editor's DocumentStore
///    registry, hand back the live instance so the @Observable cache + UI
///    pane stay consistent with any mutation `body` performs.
/// 2. Otherwise, transient-load the document from disk via the project
///    manifest's path lookup, run `body`, and close it.
///
/// This matches the existing `read_document` tool's "any doc in the
/// project, not just the open one" semantics. Annotations are persisted
/// to `.maugham/ops/{docId}.jsonl` regardless of whether the doc is open;
/// next time the editor opens that doc, the deriver picks the annotations
/// up automatically.
@MainActor
func withAnnotationDocument<T>(
    projectId: String,
    documentId: String,
    registry: ProjectRegistry,
    body: (Document) async throws -> T
) async throws -> T {
    guard let entry = registry.lookup(id: projectId) else {
        throw MCPError.projectNotOpen
    }
    // Case 1: doc is loaded in the editor — use the live instance.
    if let ds = entry.store.documentStore,
       let doc = ds.document(forDocId: documentId) {
        return try await body(doc)
    }
    // Case 2: doc not loaded — transient-load from disk.
    guard let item = findManifestItem(
            id: documentId, in: entry.store.manifest.structure),
          let path = item.path else {
        throw MCPError.invalidArgument(
            "document_id not found in project manifest: \(documentId)")
    }
    let docURL = entry.url.appendingPathComponent(path)
    let doc = try await Document.load(
        url: docURL,
        device: "mcp",
        session: "mcp-\(UUID().uuidString.prefix(8))",
        presenter: nil)
    let result = try await body(doc)
    // close() flushes the pending typing-burst + autosave (both no-ops here
    // since this Document never received user edits). Fire-and-forget after
    // `body` returns so the MCP handler doesn't block on scheduler teardown.
    // Annotation ops have already been persisted via opStore.append inside
    // `body`, so the caller observes a fully durable state on return.
    Task { await doc.close() }
    return result
}

private func findManifestItem(
    id: String, in items: [StructureItem]
) -> StructureItem? {
    for item in items {
        if item.id == id { return item }
        if let kids = item.children,
           let found = findManifestItem(id: id, in: kids) {
            return found
        }
    }
    return nil
}
