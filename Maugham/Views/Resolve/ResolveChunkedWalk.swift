import Foundation
import MaughamCore

/// **The tree's presence walk, off the main actor and in chunks** (shell p4
/// Task 3, fix rounds 2 and 3). At 200 closed chapters the store's
/// synchronous walk (`ProjectStore.listAnnotationsAcrossProject` +
/// `listTasksAcrossProject`) held the main actor for about 680 ms every time
/// a window opened; the presence read runs in every window, so it may not.
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
/// **Progress is monotonic** (fix round 3): a piece the reader already holds
/// whose op-log fingerprint is still the one it was read at, under the same
/// trust and the same manifest facts, is not read again (`.unchanged`), so a walk restarted by a steady
/// cadence of events skips what earlier walks read and always reaches the
/// end of the book.
///
/// Stateless, reads only: safe off the main actor. It captures only
/// `Inputs` (values), never a store. Cancelling the consumer stops the
/// producer before the next piece or figure.
enum ResolveChunkedWalk {

    /// What one walk reads: the closed pieces whose held read is stale, in
    /// manuscript order, and whether the figures' streams are read again.
    struct Request: Equatable, Sendable {
        let generation: Int
        let docIds: [String]
        let readsFigures: Bool
        /// What the reader already holds: each piece's fingerprint at its
        /// read, and the trust those reads were judged under. A piece whose
        /// fingerprint and trust are unchanged is skipped.
        var known: [String: DerivedManuscriptCache.Token] = [:]
        var knownTrust: TrustTable?
        var knownFacts: DocumentClass.Facts?
    }

    /// One piece's read.
    enum PieceRead: Sendable {
        case read(docId: String, notes: [Annotation], tasks: [WriterTask], sequence: [String],
                  paragraphs: [String: String], token: DerivedManuscriptCache.Token)
        /// Its log would not read (RULING-54: named, never empty).
        case unreadable(docId: String)
        /// Held already, and nothing it was read from has moved.
        case unchanged(docId: String)

        var docId: String {
            switch self {
            case .read(let docId, _, _, _, _, _), .unreadable(let docId), .unchanged(let docId): return docId
            }
        }
    }

    struct FigureReads: Sendable {
        /// The figures this walk read — the list it started with, which the
        /// manifest may have moved past by the time the step lands.
        let figureIds: [String]
        let notes: [String: [Annotation]]
        let unreadable: [String]
        let cells: [String: SuggestionDisplay.FigureCells]
    }

    enum Step: Sendable {
        /// The trust the walk judges under; the registry's unreadable name
        /// when it would not resolve (the store's walk names it the same way).
        case trust(TrustTable, facts: DocumentClass.Facts, unreadableName: String?)
        case pieces([PieceRead])
        case figures(FigureReads)
    }

    /// Everything the walk reads with, captured on the main actor. Values
    /// only: the producer holds no store, document or window.
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

    /// The walk on a detached producer. `onExit` runs when the producer has
    /// stopped — finished, or cancelled with its consumer.
    static func steps(_ inputs: Inputs, onExit: (@Sendable () -> Void)? = nil) -> AsyncStream<Step> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .utility) {
                run(inputs) { continuation.yield($0) }
                continuation.finish()
                onExit?()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// The walk itself, synchronous; `emit` gets each step. Stops at the
    /// next piece or figure once its task is cancelled.
    static func run(_ inputs: Inputs, emit: (Step) -> Void) {
        var walker = Walker(inputs)
        while let step = walker.next() { emit(step) }
    }

    /// **The walk, one step per call** — what `run` loops, and what a test
    /// steps by hand to interleave real reads with writes.
    struct Walker {
        let inputs: Inputs
        private var trust: TrustTable?
        private var tokens: [String: DerivedManuscriptCache.Token] = [:]
        private var position = 0
        private var figuresDone = false

        init(_ inputs: Inputs) { self.inputs = inputs }

        mutating func next() -> Step? {
            if Task.isCancelled { return nil }
            let url = inputs.url
            guard let trust else {
                let identities = LocalIdentities.current
                let resolved: TrustTable
                var unreadableName: String?
                do {
                    resolved = try TrustResolution.resolve(projectURL: url, identities: identities)
                } catch {
                    // The store's walk's fallback, and its naming (whole-branch
                    // review I2 there): remembered, else keyless, and the
                    // registry named so a count never looks whole.
                    resolved = TrustResolution.rememberedOrKeyless(projectURL: url, identities: identities)
                    unreadableName = OpLogStore.unreadableName(error)
                }
                if Task.isCancelled { return nil }
                self.trust = resolved
                // Each piece's file-set fingerprint, taken BEFORE its read: a
                // write after it moves the file set, so the held text is never
                // trusted past it.
                tokens = DerivedManuscriptCache.tokens(forDocIds: inputs.request.docIds, in: url)
                return .trust(resolved, facts: inputs.facts, unreadableName: unreadableName)
            }

            let docIds = inputs.request.docIds
            if position < docIds.count {
                let end = min(position + max(inputs.chunkSize, 1), docIds.count)
                var reads: [PieceRead] = []
                let sameTrust = inputs.request.knownTrust == trust && inputs.request.knownFacts == inputs.facts
                for docId in docIds[position..<end] {
                    if Task.isCancelled { return nil }
                    let token = tokens[docId] ?? DerivedManuscriptCache.token(forDocId: docId, in: url)
                    if sameTrust, inputs.request.known[docId] == token {
                        reads.append(.unchanged(docId: docId))
                        continue
                    }
                    guard let read = ProjectStore.readClosedDocument(docId, in: url, trust: trust,
                                                                     facts: inputs.facts) else {
                        reads.append(.unreadable(docId: docId))
                        continue
                    }
                    reads.append(.read(
                        docId: docId, notes: read.notes,
                        tasks: ProjectStore.closedDocumentTasks(ops: read.ops, paragraphs: read.paragraphs,
                                                                docId: docId),
                        sequence: read.sequence, paragraphs: read.paragraphs, token: token))
                }
                position = end
                return .pieces(reads)
            }

            guard inputs.request.readsFigures, !figuresDone else { return nil }
            figuresDone = true
            var notes: [String: [Annotation]] = [:]
            var unreadable: [String] = []
            var tables: [String: FigureTable] = [:]
            var suggestions: [(figureId: String, note: Annotation)] = []
            for figure in inputs.figures {
                if Task.isCancelled { return nil }
                guard let read = ProjectStore.figureNotesAndTable(figure.id, in: url, trust: trust,
                                                                  facts: inputs.facts) else {
                    unreadable.append(figure.id)
                    continue
                }
                tables[figure.id] = read.table
                notes[figure.id] = read.notes
                suggestions += read.notes.filter { $0.kind == .suggestedChange }.map { (figure.id, $0) }
            }
            return .figures(FigureReads(
                figureIds: inputs.figures.map(\.id),
                notes: notes, unreadable: unreadable,
                cells: ProjectStore.figureCells(suggestions, tables: tables, figures: inputs.figures,
                                                research: inputs.research, url: url)))
        }
    }
}
