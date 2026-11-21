import Foundation
import MaughamCore

/// **The tree's presence walk, off the main actor and in chunks** (shell p4
/// Task 3, fix round 2). At 200 closed chapters the store's synchronous walk
/// (`ProjectStore.listAnnotationsAcrossProject` + `listTasksAcrossProject`)
/// held the main actor for about 830 ms every time a window opened; the
/// presence read runs in every window, so it may not.
///
/// Each closed piece is read exactly as the store's walk reads it —
/// `ProjectStore.readClosedDocument` (merged ops under one trust table, the
/// derive, the notes under the open document's rule) and
/// `ProjectStore.closedDocumentTasks` from the same ops — one load per piece
/// instead of the store's two. Pieces go out a chunk at a time as `Step`s;
/// the reader applies each on the main actor (`ResolvePresenceReader.apply`),
/// so a step there costs one chunk's bookkeeping and the marks fill in as
/// the pieces are read. A piece not yet read draws nothing (it is neither
/// marked nor named unreadable).
///
/// Stateless, reads only: safe off the main actor. Cancelling the consumer
/// stops the producer between pieces.
enum ResolveChunkedWalk {

    /// What one walk reads: the closed pieces whose held read is stale, in
    /// manuscript order, and whether the figures' streams are read again.
    struct Request: Equatable, Sendable {
        let generation: Int
        let docIds: [String]
        let readsFigures: Bool
    }

    /// One piece's read.
    enum PieceRead: Sendable {
        case read(docId: String, notes: [Annotation], tasks: [WriterTask], sequence: [String],
                  paragraphs: [String: String], token: DerivedManuscriptCache.Token)
        /// Its log would not read (RULING-54: named, never empty).
        case unreadable(docId: String)

        var docId: String {
            switch self {
            case .read(let docId, _, _, _, _, _), .unreadable(let docId): return docId
            }
        }
    }

    struct FigureReads: Sendable {
        let notes: [String: [Annotation]]
        let unreadable: [String]
        let cells: [String: SuggestionDisplay.FigureCells]
    }

    enum Step: Sendable {
        /// The trust the walk judges under; the registry's unreadable name
        /// when it would not resolve (the store's walk names it the same way).
        case trust(unreadableName: String?)
        case pieces([PieceRead])
        case figures(FigureReads)
    }

    /// Everything the walk reads with, captured on the main actor.
    struct Inputs: Sendable {
        let url: URL
        let facts: DocumentClass.Facts
        let figures: [FigureRecord]
        let research: [ResearchItem]
        let request: Request
        var chunkSize: Int = ResolveChunkedWalk.chunkSize
    }

    /// Pieces per step. A piece's read is a few milliseconds off the main
    /// actor; applying one on it is a dictionary write.
    static let chunkSize = 8

    @MainActor
    static func inputs(for request: Request, store: ProjectStore) -> Inputs {
        Inputs(url: store.url, facts: DocumentClass.Facts(store.manifest),
               figures: store.manifest.figures ?? [], research: store.manifest.research,
               request: request)
    }

    static func steps(_ inputs: Inputs) -> AsyncStream<Step> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .utility) {
                run(inputs) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// The walk itself, synchronous; `emit` gets each step.
    static func run(_ inputs: Inputs, emit: (Step) -> Void) {
        let url = inputs.url
        let identities = LocalIdentities.current
        let trust: TrustTable
        var unreadableName: String?
        do {
            trust = try TrustResolution.resolve(projectURL: url, identities: identities)
        } catch {
            // The store's walk's fallback, and its naming (whole-branch
            // review I2 there): remembered, else keyless, and the registry
            // named so a count never looks whole.
            trust = TrustResolution.rememberedOrKeyless(projectURL: url, identities: identities)
            unreadableName = OpLogStore.unreadableName(error)
        }
        emit(.trust(unreadableName: unreadableName))

        let docIds = inputs.request.docIds
        // Each piece's file-set fingerprint, taken BEFORE its read: a write
        // after the read moves it, so the held text is never trusted past it.
        let tokens = DerivedManuscriptCache.tokens(forDocIds: docIds, in: url)
        var start = 0
        while start < docIds.count {
            if Task.isCancelled { return }
            let chunk = docIds[start..<min(start + max(inputs.chunkSize, 1), docIds.count)]
            var reads: [PieceRead] = []
            for docId in chunk {
                guard let read = ProjectStore.readClosedDocument(docId, in: url, trust: trust,
                                                                 facts: inputs.facts) else {
                    reads.append(.unreadable(docId: docId))
                    continue
                }
                reads.append(.read(
                    docId: docId, notes: read.notes,
                    tasks: ProjectStore.closedDocumentTasks(ops: read.ops, paragraphs: read.paragraphs,
                                                            docId: docId),
                    sequence: read.sequence, paragraphs: read.paragraphs,
                    token: tokens[docId] ?? DerivedManuscriptCache.token(forDocId: docId, in: url)))
            }
            emit(.pieces(reads))
            start += chunk.count
        }

        guard inputs.request.readsFigures, !Task.isCancelled else { return }
        var notes: [String: [Annotation]] = [:]
        var unreadable: [String] = []
        var tables: [String: FigureTable] = [:]
        var suggestions: [(figureId: String, note: Annotation)] = []
        for figure in inputs.figures {
            guard let read = ProjectStore.figureNotesAndTable(figure.id, in: url, trust: trust,
                                                              facts: inputs.facts) else {
                unreadable.append(figure.id)
                continue
            }
            tables[figure.id] = read.table
            notes[figure.id] = read.notes
            suggestions += read.notes.filter { $0.kind == .suggestedChange }.map { (figure.id, $0) }
        }
        emit(.figures(FigureReads(
            notes: notes, unreadable: unreadable,
            cells: ProjectStore.figureCells(suggestions, tables: tables, figures: inputs.figures,
                                            research: inputs.research, url: url))))
    }
}
