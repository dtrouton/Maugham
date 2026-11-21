import Foundation
import MaughamCore

/// **What one read of a scope found** (shell plan 2).
struct ResolveSnapshot: Equatable {
    let items: [ResolveItem]
    /// docId → paragraph order, for the scope's documents.
    let sequences: [String: [String]]
    /// The `.piece` scope's paragraphs only, for group titles and the letter.
    let paragraphText: [String: String]
    /// The scope's documents and the figures it holds that would not
    /// read — named, never presented as empty (RULING-54).
    let unreadableDocIds: [String]

    static let empty = ResolveSnapshot(items: [], sequences: [:], paragraphText: [:], unreadableDocIds: [])
}

/// **To resolve's reader: what a scope holds, without a load** (shell plan 2,
/// Task 1). Every source is store-level — the project's annotation walk, its
/// task walk, the diagnostics sidecar and `currentParagraphState` (the open
/// document, else `derivedCache`). It never loads, transiently or otherwise,
/// and registers no document (`ResolveReaderTests.test_noResolveSourceLoadsADocument`).
///
/// `read` is called once per refresh, never from a row (tripwire 4).
enum ResolveReader {

    /// The pure half: filter what the walks found down to `scope`. Only open
    /// notes, open to-dos and conformance strains are items. `findings` are
    /// already live (`DiagnosticsStore.live`).
    ///
    /// **A figure's notes go where the board counts them**: on the piece that
    /// owns it, by the board's own rule (`ProjectStore.countsOn` over
    /// `figureOwners`, which is `ProjectStore.figureNoteOwners(manifest.figures)`),
    /// after that scope's paragraph notes. A figure no piece owns (a
    /// whole-book or shared-Research figure, or one the registry no longer
    /// holds) shows at Book scope and its own scope only. The Book's own to-dos
    /// come only where `includesBookLevel`.
    ///
    /// A figure owned by a piece the scope does not hold is dropped, at Book
    /// scope too: a reference piece's figure, or one whose owner id is stale,
    /// shows only at its own figure scope (the board counts it on that row).
    ///
    /// `figureOwners` has no default on purpose: an omitted map would make
    /// every owned figure look whole-book, a wrong count and no error.
    static func snapshot(scope: ResolveScope, annotations: ProjectAnnotationsSnapshot,
                         tasks: [WriterTask], findings: [String: [Diagnostic]],
                         paragraphText: [String: String],
                         figureOwners: [String: String?]) -> ResolveSnapshot {
        let docIds = scope.docIds
        guard !docIds.isEmpty || scope.includesBookLevel else { return .empty }
        let inScope = Set(docIds)
        let book = scope.includesBookLevel

        // **An edition holds its language's questions and nothing else the
        // walks find** (shell p4 Task 6): the open notes on its pieces that
        // carry that language. Its changes, proposals and problems are not
        // the walks' (`ResolveEditionItems`). The Source edition has none.
        if case .edition(let language, let isSource, _) = scope {
            let questions = isSource ? [] : annotations.annotations.filter {
                inScope.contains($0.docId) && ResolveEditionItems.isQuestion($0.annotation, in: language)
            }
            return ResolveSnapshot(
                items: questions.map(ResolveItem.note),
                sequences: annotations.sequences.filter { inScope.contains($0.key) },
                paragraphText: [:],
                unreadableDocIds: isSource ? [] : annotations.unreadableDocIds.filter(inScope.contains))
        }

        func holds(_ docId: String) -> Bool {
            if inScope.contains(docId) { return true }
            guard DocumentClass.isFigureDocId(docId) else { return false }
            if let owner = ProjectStore.countsOn(docId, owners: figureOwners) {
                return inScope.contains(owner)
            }
            return book
        }

        let open = annotations.annotations
            .filter { $0.annotation.status == .open && holds($0.docId) }
        // Paragraph notes first, then the figures' (stable within each).
        let notes = (open.filter { !DocumentClass.isFigureDocId($0.docId) }
                     + open.filter { DocumentClass.isFigureDocId($0.docId) })
            .map(ResolveItem.note)
        let strains = docIds.flatMap { docId in
            (findings[docId] ?? [])
                .filter { $0.kind == .conformanceStrain }
                .map { ResolveItem.finding(docId: docId, $0) }
        }
        let todos = tasks
            .filter { $0.status == .open }
            .map(ResolveItem.todo)
            .filter { inScope.contains($0.docId) || (book && $0.docId == ProjectStore.projectTasksDocId) }

        var paragraphs: [String: String] = [:]
        if case .piece = scope { paragraphs = paragraphText }

        return ResolveSnapshot(
            items: notes + strains + todos,
            sequences: annotations.sequences.filter { inScope.contains($0.key) },
            paragraphText: paragraphs,
            unreadableDocIds: annotations.unreadableDocIds.filter(holds))
    }

    /// Read the scope's sidecars into `diagnostics`, so `live` has something
    /// to answer. A plain file read per document. Call it from `.task` or
    /// `.onChange`, never from a body.
    @MainActor
    static func loadFindings(scope: ResolveScope, diagnostics: DiagnosticsStore) {
        // An edition lists no strains.
        if case .edition = scope { return }
        for docId in scope.docIds where !DocumentClass.isFigureDocId(docId) {
            diagnostics.load(docId: docId)
        }
    }

    /// **A new screenplay parse, without the walks** (`ResolveRegroupKey`).
    /// Re-reads only a `.piece` scope's own paragraph state — its sequence and
    /// text, which the scene placement is computed against — and keeps every
    /// held item. Any other scope is returned unchanged. A piece whose state
    /// will not read is named unreadable (RULING-54) and keeps no text.
    @MainActor
    static func rereadText(_ held: ResolveSnapshot, scope: ResolveScope, store: ProjectStore,
                           documentStore: DocumentStore) -> ResolveSnapshot {
        guard case .piece(let docId, _) = scope else { return held }
        do {
            let state = try currentParagraphState(documentId: docId, store: store,
                                                  documentStore: documentStore, projectURL: store.url)
            return rereading(held, docId: docId, sequence: state.sequence, paragraphs: state.paragraphs)
        } catch {
            return rereading(held, docId: docId, sequence: nil, paragraphs: [:])
        }
    }

    /// `held` with one piece's sequence and text replaced; its items, the
    /// other pieces' sequences and the unreadable names are kept. `sequence:
    /// nil` means the state would not read: the piece's held sequence is
    /// kept, the text emptied, and the piece named.
    static func rereading(_ held: ResolveSnapshot, docId: String, sequence: [String]?,
                          paragraphs: [String: String]) -> ResolveSnapshot {
        var sequences = held.sequences
        var unreadable = held.unreadableDocIds
        if let sequence {
            sequences[docId] = sequence
        } else if !unreadable.contains(docId) {
            unreadable.append(docId)
        }
        return ResolveSnapshot(items: held.items, sequences: sequences,
                               paragraphText: paragraphs, unreadableDocIds: unreadable)
    }

    /// One read of `scope` straight from the stores: the two project walks,
    /// the open pieces off their `Document`s, the sidecar's live strains.
    /// The view reads through `read(scope:annotations:tasks:live:...)` over
    /// walks it holds (`ResolveWalkHold`); this is that, with fresh walks.
    @MainActor
    static func read(scope: ResolveScope, store: ProjectStore,
                     documentStore: DocumentStore, diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        guard !scope.docIds.isEmpty || scope.includesBookLevel else { return .empty }
        return read(scope: scope, annotations: store.listAnnotationsAcrossProject(),
                    tasks: store.listTasksAcrossProject(filter: TaskFilter(scope: .project, statuses: [.open])),
                    live: ResolvePane.livePieces(scope: scope, documentStore: documentStore),
                    store: store, documentStore: documentStore, diagnostics: diagnostics)
    }

    /// **One read of `scope` over walks already held** (review C1): each open
    /// piece in `live` answers for itself — its notes, to-dos and order off its
    /// `Document` — and the walks answer for every closed piece and figure.
    @MainActor
    static func read(scope: ResolveScope, annotations: ProjectAnnotationsSnapshot,
                     tasks: [WriterTask], live: [String: ResolveLivePiece], store: ProjectStore,
                     documentStore: DocumentStore, diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        guard !scope.docIds.isEmpty || scope.includesBookLevel else { return .empty }
        let liveFindings: ((String, (String) -> String?) -> [Diagnostic])? = diagnostics.map { diagnostics in
            { docId, currentText in diagnostics.live(docId: docId, currentText: currentText) }
        }
        return gather(
            scope: scope,
            annotations: overlaying(annotations, live: live),
            tasks: overlaying(tasks, live: live),
            figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []),
            liveFindings: liveFindings,
            paragraphs: { docId in
                if let piece = live[docId] { return piece.paragraphs }
                return try currentParagraphState(documentId: docId, store: store,
                                                 documentStore: documentStore, projectURL: store.url).paragraphs
            })
    }

    /// The walk with each open piece's notes (every status) and order
    /// replaced by its live `Document`'s. A live piece is never unreadable.
    static func overlaying(_ walk: ProjectAnnotationsSnapshot,
                           live: [String: ResolveLivePiece]) -> ProjectAnnotationsSnapshot {
        guard !live.isEmpty else { return walk }
        var sequences = walk.sequences
        var fresh: [ProjectAnnotation] = []
        for (docId, piece) in live.sorted(by: { $0.key < $1.key }) {
            sequences[docId] = piece.sequence
            fresh += piece.notes.map { ProjectAnnotation(docId: docId, annotation: $0) }
        }
        return ProjectAnnotationsSnapshot(
            annotations: walk.annotations.filter { live[$0.docId] == nil } + fresh,
            unreadableDocIds: walk.unreadableDocIds.filter { live[$0] == nil },
            sequences: sequences, figureCells: walk.figureCells)
    }

    /// The task walk with each open piece's to-dos replaced by its live ones.
    static func overlaying(_ tasks: [WriterTask], live: [String: ResolveLivePiece]) -> [WriterTask] {
        guard !live.isEmpty else { return tasks }
        return tasks.filter { live[ResolveItem.todo($0).docId] == nil }
            + live.sorted(by: { $0.key < $1.key }).flatMap(\.value.todos)
    }

    /// **The read's decisions, with its two sources injected** (the seam
    /// `ResolveReaderTests` counts reads through).
    ///
    /// Paragraph text is read — once per document — only where something
    /// needs it: the `.piece` scope's own document (group titles, the
    /// letter), and a document whose sidecar holds an ANCHORED strain, whose
    /// liveness is judged against its paragraph's text. A first `live` call
    /// with a text source that answers nothing finds out which: `live` asks
    /// for text only for an anchored strain. A Book of sixty pieces with no
    /// anchored strain reads no text at all.
    ///
    /// A document whose text will not read is named unreadable (RULING-54),
    /// and its anchored strains — which cannot be judged — are dropped; its
    /// unanchored strains, notes and to-dos still list.
    ///
    /// - Parameters:
    ///   - liveFindings: `DiagnosticsStore.live(docId:currentText:)`, or nil
    ///     when there is no diagnostics store (no strains at all).
    ///   - paragraphs: a document's `[paragraphId: text]`; throws when it
    ///     will not read.
    @MainActor
    static func gather(scope: ResolveScope, annotations: ProjectAnnotationsSnapshot,
                       tasks: [WriterTask], figureOwners: [String: String?],
                       liveFindings: ((String, (String) -> String?) -> [Diagnostic])?,
                       paragraphs: (String) throws -> [String: String]) -> ResolveSnapshot {
        var texts: [String: [String: String]] = [:]
        var unreadable: [String] = []
        func text(of docId: String) -> [String: String]? {
            if let read = texts[docId] { return read }
            guard !unreadable.contains(docId) else { return nil }
            do {
                let read = try paragraphs(docId)
                texts[docId] = read
                return read
            } catch {
                unreadable.append(docId)
                return nil
            }
        }

        var paragraphText: [String: String] = [:]
        if case .piece(let docId, _) = scope { paragraphText = text(of: docId) ?? [:] }

        var findings: [String: [Diagnostic]] = [:]
        // An edition lists no strains, so none is judged.
        let listsStrains: Bool = if case .edition = scope { false } else { true }
        if listsStrains, let liveFindings {
            for docId in scope.docIds where !DocumentClass.isFigureDocId(docId) {
                var anchored = false
                let unjudged = liveFindings(docId) { _ in anchored = true; return nil }
                guard anchored else { findings[docId] = unjudged; continue }
                let current = text(of: docId) ?? [:]
                findings[docId] = liveFindings(docId) { current[$0] }
            }
        }

        let read = snapshot(scope: scope, annotations: annotations, tasks: tasks,
                            findings: findings, paragraphText: paragraphText,
                            figureOwners: figureOwners)
        let named = read.unreadableDocIds + unreadable.filter { !read.unreadableDocIds.contains($0) }
        return ResolveSnapshot(items: read.items, sequences: read.sequences,
                               paragraphText: read.paragraphText, unreadableDocIds: named)
    }
}
