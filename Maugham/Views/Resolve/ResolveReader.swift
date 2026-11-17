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
    static func snapshot(scope: ResolveScope, annotations: ProjectAnnotationsSnapshot,
                         tasks: [WriterTask], findings: [String: [Diagnostic]],
                         paragraphText: [String: String],
                         figureOwners: [String: String?] = [:]) -> ResolveSnapshot {
        let docIds = scope.docIds
        guard !docIds.isEmpty || scope.includesBookLevel else { return .empty }
        let inScope = Set(docIds)
        let book = scope.includesBookLevel

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
        for docId in scope.docIds where !DocumentClass.isFigureDocId(docId) {
            diagnostics.load(docId: docId)
        }
    }

    /// One read of `scope`: the two project walks (each cached whole by the
    /// store), each document's paragraphs read once to judge the strains'
    /// anchors, then `snapshot`. A document whose paragraphs will not read is
    /// named unreadable, and its anchored strains — which cannot be judged —
    /// are dropped with it.
    @MainActor
    static func read(scope: ResolveScope, store: ProjectStore,
                     documentStore: DocumentStore, diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        let docIds = scope.docIds
        guard !docIds.isEmpty || scope.includesBookLevel else { return .empty }
        let annotations = store.listAnnotationsAcrossProject()
        let tasks = store.listTasksAcrossProject(filter: TaskFilter(scope: .project, statuses: [.open]))

        var texts: [String: [String: String]] = [:]
        var unreadable: [String] = []
        let needsText: Bool = {
            if case .piece = scope { return true }
            return diagnostics != nil
        }()
        if needsText {
            for docId in docIds where !DocumentClass.isFigureDocId(docId) {
                do {
                    texts[docId] = try currentParagraphState(
                        documentId: docId, store: store,
                        documentStore: documentStore, projectURL: store.url).paragraphs
                } catch {
                    unreadable.append(docId)
                }
            }
        }

        var findings: [String: [Diagnostic]] = [:]
        if let diagnostics {
            for docId in docIds where !DocumentClass.isFigureDocId(docId) {
                let paragraphs = texts[docId] ?? [:]
                findings[docId] = diagnostics.live(docId: docId) { paragraphs[$0] }
            }
        }

        var paragraphText: [String: String] = [:]
        if case .piece(let docId, _) = scope { paragraphText = texts[docId] ?? [:] }

        let read = snapshot(scope: scope, annotations: annotations, tasks: tasks,
                            findings: findings, paragraphText: paragraphText,
                            figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []))
        let named = read.unreadableDocIds + unreadable.filter { !read.unreadableDocIds.contains($0) }
        return ResolveSnapshot(items: read.items, sequences: read.sequences,
                               paragraphText: read.paragraphText, unreadableDocIds: named)
    }
}
