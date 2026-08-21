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
        throw MCPError.unknownProjectID(projectId)
    }
    return try await withAnnotationDocument(
        store: entry.store, projectURL: entry.url, documentId: documentId, body: body)
}

/// The same resolution with the project already in hand — what a SURFACE calls
/// (`EditionStatus`, the department desk's derivation), which holds its
/// window's stores directly and has no registry to look anything up in.
///
/// **One spelling of the open-doc-else-transient-load rule**, which is why the
/// registry version above is a three-line wrapper around this one —
/// `currentParagraphState`'s pair, for `currentParagraphState`'s reason: a
/// second copy of "loaded → live instance, otherwise load and close" is a
/// second answer to which `Document` an annotation read is about, and the two
/// answers can differ by a whole typing burst.
@MainActor
func withAnnotationDocument<T>(
    store: ProjectStore,
    projectURL: URL,
    documentId: String,
    body: (Document) async throws -> T
) async throws -> T {
    // Case 1: doc is loaded in the editor — use the live instance.
    if let doc = openAnnotationDocument(documentId, in: store) {
        return try await body(doc)
    }
    // Case 2: doc not loaded — transient-load from disk.
    guard let item = TreeWalk.find(id: documentId, in: store.manifest.structure),
          let path = item.path else {
        throw MCPError.invalidArgument(
            "document_id not found in project manifest: \(documentId)")
    }
    let docURL = projectURL.appendingPathComponent(path)
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

/// `withAnnotationDocument`'s CASE 1, extracted: the live instance when the
/// editor has this document open, nil when it does not. One spelling, because
/// the pass-stamp resolution below is *about* which arm a call takes and a
/// second copy of the condition could drift from the arm it describes.
@MainActor
func openAnnotationDocument(
    _ documentId: String, in entry: ProjectRegistry.Entry
) -> Document? {
    openAnnotationDocument(documentId, in: entry.store)
}

@MainActor
func openAnnotationDocument(
    _ documentId: String, in store: ProjectStore
) -> Document? {
    store.documentStore?.document(forDocId: documentId)
}

/// The review pass an MCP-created note is stamped with (M3 P2 Task 8), or nil.
///
/// **Nil for a closed document, by design.** The active pass is a WINDOW's
/// state — `UIState.activePassMemory`, written when the writer clicks a pass
/// chip on the board — so it exists only where a window has one. Case 1 (the
/// document is open) can read it; case 2 transient-loads a document nobody is
/// looking at, and there is no pass to attribute the note to. That nil is an
/// answer rather than a gap: an unstamped note appears in EVERY pass's queue,
/// so nothing is hidden, and M5-AN-048's pinned behaviour — a craft note
/// appended to a CLOSED document — keeps working exactly as it did, its note
/// simply belonging to no pass. The alternative (stamping whatever pass the
/// piece was last opened under, weeks ago) would be the memory inventing a
/// context the writer is not in.
///
/// Validated through `ActivePassMemory.validatedActivePass`, so a pass the
/// project has since retired stamps nothing: a note carrying an id no column
/// can show is a note in a queue nobody can reach.
@MainActor
func activeReviewPassId(
    projectId: String, documentId: String, registry: ProjectRegistry
) -> String? {
    guard let entry = registry.lookup(id: projectId),
          openAnnotationDocument(documentId, in: entry) != nil,
          let ds = entry.store.documentStore else { return nil }
    return ds.uiState.activePassMemory.validatedActivePass(
        forPiece: documentId, in: entry.store.manifest.effectiveReviewPasses)
}

/// The author stamp for every annotation emitted through the MCP bridge.
/// All MCP annotations originate from Claude, so they carry `.claude`
/// provenance regardless of whether a sub-paragraph `quote` was supplied.
let claudeAnnotationAuthor = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")

/// Resolve an optional `quote` into a `SpanAnchor` captured against the
/// paragraph's *display* text — the same text Claude sees via `read_document`.
///
/// The paragraph's stored text may contain inline task anchors (HTML
/// comments); those are stripped first so the quote Claude copied from the
/// rendered manuscript matches. Returns nil when `quote` is nil/empty (the
/// annotation anchors the whole paragraph). Throws `MCPError.spanNotFound`
/// when a non-empty quote isn't present in the paragraph.
///
/// `doc` is the live (or transient) Document. When the paragraph isn't present
/// at all this returns nil rather than throwing, so the downstream
/// `addAnnotation` validation surfaces the more specific
/// `paragraph_not_found` error (and an empty quote always anchors the whole
/// paragraph). A non-empty quote that the paragraph *does* hold but doesn't
/// match throws `MCPError.spanNotFound`.
@MainActor
func resolveSpanAnchor(
    quote: String?, paragraphId: String, in doc: Document
) throws -> SpanAnchor? {
    guard let q = quote, !q.isEmpty else { return nil }
    guard let raw = doc.paragraphs[paragraphId] else { return nil }
    let paraText = MarkdownDisplayFilter.stripTaskAnchorsInline(raw)
    guard let r = SpanAnchorResolver.resolve(
        anchor: SpanAnchor(quote: q, prefix: "", suffix: "", posHint: 0),
        in: paraText)
    else {
        throw MCPError.spanNotFound(paragraphId: paragraphId, quote: q)
    }
    return SpanAnchorResolver.capture(in: paraText, range: r)
}
