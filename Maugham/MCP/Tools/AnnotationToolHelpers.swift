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
    let docURL = try ProjectStore.resolvedProjectPath(path, under: projectURL)
    // Anything arriving through MCP is the assistant's (constraint 6): the
    // annotation ops `body` appends land in the assistant's own file, chained
    // and sealed under the assistant's key rather than unsigned under a
    // sentinel no key answers to.
    let doc = try await Document.load(
        url: docURL,
        actor: .assistant,
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

// MARK: - A note on a figure (report plan 9c-1 Task 4)

/// What a creation tool was asked to anchor: a paragraph (`document_id` +
/// `paragraph_id`, the original forms) or a figure (`figure`, with the other
/// two absent). One spelling of the either/or, so the four tools agree.
enum AnnotationTarget {
    case paragraph(documentId: String, paragraphId: String)
    case figure(String)

    /// Throws `invalidArgument` unless exactly one anchor form is given.
    /// `needsParagraph` is false for `add_craft_note`, which is document-scoped.
    static func resolve(
        figure: String?, documentId: String?, paragraphId: String?, needsParagraph: Bool = true
    ) throws -> AnnotationTarget {
        if let figure {
            guard documentId == nil, paragraphId == nil else {
                throw MCPError.invalidArgument(
                    "Pass `figure` (a figure note) or `document_id`"
                    + (needsParagraph ? " with `paragraph_id`" : "") + " (a manuscript note), not both.")
            }
            return .figure(figure)
        }
        guard let documentId else {
            throw MCPError.invalidArgument(
                "Pass `document_id`" + (needsParagraph ? " and `paragraph_id`" : "")
                + " for a manuscript note, or `figure` (e.g. tbl:cashflow!C3) for a figure note.")
        }
        guard let paragraphId else {
            if needsParagraph {
                throw MCPError.invalidArgument("`paragraph_id` is required with `document_id`.")
            }
            return .paragraph(documentId: documentId, paragraphId: "")
        }
        return .paragraph(documentId: documentId, paragraphId: paragraphId)
    }
}

/// Create a note on a figure as the assistant and return its annotation id.
///
/// The figure is found as `read_figure` finds it (`ReadFigureTool.find`: a
/// name or a `tbl:`/`fig:` label, kind-checked) over the windowless
/// `publishFigures()` snapshot; the cells, if any, become row and column ids
/// once, here (`FigureAnchorAddress.anchor`). A suggested change takes one
/// cell and `suggestedValue` in machine form (`FigureAnnotationOps.suggestedCell`);
/// nothing here writes a cell or a figure CSV. No review-pass stamp: a
/// figure has no open `Document` to ask (plan 9c-1 ruling).
@MainActor
func addFigureNote(
    kind: AnnotationKind, projectId: String, figure: String, body: String,
    suggestedValue: String? = nil, language: String? = nil, registry: ProjectRegistry
) async throws -> String {
    guard let entry = registry.lookup(id: projectId) else {
        throw MCPError.unknownProjectID(projectId)
    }
    guard let ds = entry.store.documentStore else {
        throw MCPError.invalidArgument("The project's window is not ready for a figure note.")
    }
    guard let parsed = FigureAnchorAddress.parse(figure) else {
        throw MCPError.invalidArgument(
            "`figure` '\(figure)' is not a figure address: use tbl:name, tbl:name!C3 or tbl:name!C3:E3.")
    }
    let snapshot = await entry.store.publishFigures()
    let record = try ReadFigureTool.find(parsed.label, in: snapshot.records)
    guard record.kind == .table else {
        throw MCPError.invalidArgument(
            "Figure '\(record.name)' is an image: notes anchor to a table's cells; "
            + "this build cannot anchor a note to an image.")
    }
    guard !snapshot.parked.contains(record.id) else {
        throw MCPError.invalidArgument(
            "Figure '\(record.name)' is parked in Research; bring it back into the book before annotating it.")
    }
    guard let state = snapshot.states[record.id], state.kind == .table else {
        throw MCPError.invalidArgument("Figure '\(record.name)' could not be read (its op log would not fold).")
    }
    let table = state.table

    var anchor: FigureCellAnchor?
    if let cells = parsed.cells {
        switch FigureAnchorAddress.anchor(cells, in: table) {
        case .success(let a): anchor = a
        case .failure:
            throw MCPError.invalidArgument(
                "'\(cells)' is not a live cell or range in '\(record.name)' "
                + "(\(table.rows.count) rows, \(table.columns.count) columns); "
                + "use a form like \"C3\" or \"C3:E3\". A cell whose row or column was deleted has no address.")
        }
    }

    var suggestedCell: Cell?
    var prior: Cell?
    if kind == .suggestedChange {
        guard let anchor, anchor.rowEnd == nil, anchor.columnEnd == nil else {
            throw MCPError.invalidArgument(
                "A suggested change names one cell (e.g. \(parsed.label)!C3), not a range or the whole figure.")
        }
        guard let value = suggestedValue else {
            throw MCPError.invalidArgument("`suggested_value` is required with `figure`.")
        }
        let key = CellKey(row: anchor.row, column: anchor.column)
        let names = FormulaNames(
            records: snapshot.records, tables: snapshot.states.mapValues(\.table),
            research: entry.store.manifest.research)
        switch FigureAnnotationOps.suggestedCell(from: value, at: key, table: table, names: names) {
        case .success(let cell): suggestedCell = cell
        case .failure(let error):
            throw MCPError.invalidArgument("`suggested_value` '\(value)' does not parse: \(error.message)")
        }
        prior = table[key]
    }

    let op: Op
    do {
        op = try FigureAnnotationOps.creation(
            kind: kind, anchor: anchor, body: body, suggestedCell: suggestedCell, prior: prior,
            author: claudeAnnotationAuthor, language: language,
            stamp: .init(figureId: record.id, device: Document.loadIdentities[.assistant].deviceId,
                         session: "mcp-\(UUID().uuidString.prefix(8))"))
    } catch FigureAnnotationOps.BuildError.craftNoteTakesNoCell {
        throw MCPError.invalidArgument("A craft note is about the whole figure: pass `figure` without a cell.")
    }
    do {
        try await ds.addFigureAnnotation(op)
    } catch let error as FigureParkedRefused {
        throw MCPError.invalidArgument(
            "Figure '\(record.name)' is parked in Research (\(error.localizedDescription)).")
    }
    return op.opId
}
