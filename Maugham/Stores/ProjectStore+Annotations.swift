import Foundation
import MaughamCore

// MARK: - Project-wide annotation aggregation (M3 P2)
//
// The queue's Project scope and the review board's open-notes column both ask
// one question — "what notes does this project have, and where?" — of every
// piece at once, open or closed. This file answers it.
//
// Shape is `ProjectStore+Tasks.swift`'s aggregation verbatim (its header
// comment says the cache key was shaped for exactly this extension): a key
// over open documents' version counters plus closed documents' op-log file
// mtimes, a cache held WHOLE and unfiltered, and callers filtering on read.
// Stored properties live on the `ProjectStore` class body — `@Observable`
// can't synthesize storage in an extension — so this file holds only
// behaviour.

/// One annotation plus the document it belongs to. The project-wide walk
/// flattens every piece's notes into a single list, so each one has to carry
/// its own provenance; `Annotation` itself has no doc id.
public struct ProjectAnnotation: Equatable {
    public let docId: String
    public let annotation: Annotation

    public init(docId: String, annotation: Annotation) {
        self.docId = docId
        self.annotation = annotation
    }
}

/// One piece's open-note count, split by the review pass each note was
/// written under. `total` counts every open note; `byPass` counts only those
/// carrying a `reviewPassId`, so an unstamped note (every note written before
/// passes existed, and any written with no pass active) is in `total` alone
/// and the two deliberately do not have to agree.
public struct OpenNotesSummary: Equatable {
    public let total: Int
    public let byPass: [String: Int]

    public init(total: Int, byPass: [String: Int]) {
        self.total = total
        self.byPass = byPass
    }
}

/// What one walk of the project found.
///
/// `unreadableDocIds` is the honesty half of the RULING-54 decision below: the
/// walk is lenient, so a document whose op log cannot be read is skipped
/// rather than throwing the whole read away — but it is NAMED, so a count
/// surface can say "unknown" instead of quietly saying a low number.
///
/// `sequences` is the paragraph order of each document the walk visited, which
/// the walk already had to derive to read the notes at all. A cross-document
/// sort needs document order for CLOSED documents too, and re-deriving it at
/// the sort site would walk every op log a second time.
public struct ProjectAnnotationsSnapshot: Equatable {
    public let annotations: [ProjectAnnotation]
    public let unreadableDocIds: [String]
    /// docId → paragraph-id order.
    public let sequences: [String: [String]]
    /// **A figure suggestion's before and after, as cell text** (report plan
    /// 9c-1 Task 7), keyed by note id — read off each figure's table in the
    /// walk that already derived it, in the book's language, so a queue row
    /// looks it up and computes nothing (tripwire 4).
    public let figureCells: [String: SuggestionDisplay.FigureCells]

    public init(
        annotations: [ProjectAnnotation],
        unreadableDocIds: [String],
        sequences: [String: [String]],
        figureCells: [String: SuggestionDisplay.FigureCells] = [:]
    ) {
        self.annotations = annotations
        self.unreadableDocIds = unreadableDocIds
        self.sequences = sequences
        self.figureCells = figureCells
    }
}

extension ProjectStore {

    // MARK: - Read API

    /// Every annotation in the project, in manifest order, with each document's
    /// paragraph order alongside.
    ///
    /// The universe is the MANIFEST's documents (`collectDocuments`), not the
    /// filenames in `.maugham/ops/` — the manifest is what says which pieces
    /// the project has, and an ops file can outlive the piece it belonged to.
    /// (The phone enumerates by filename, and buckets what it can't map under
    /// "Other"; that is its own choice for its own tab, not a contract.)
    ///
    /// An OPEN document contributes its live projection — the notes the writer
    /// is looking at right now, including ones whose disk append is still in
    /// flight. A CLOSED one is derived from its op log (ADR 0018: the `.md` is
    /// derived and is never read as truth here).
    ///
    /// Cached whole and unfiltered behind the same key shape as
    /// `listTasksAcrossProject`; repeated calls with nothing changed reuse the
    /// derivation.
    public func listAnnotationsAcrossProject() -> ProjectAnnotationsSnapshot {
        let key = currentAnnotationsKey()
        if let cached = _projectAnnotationsCache, _projectAnnotationsCacheKey == key {
            return cached
        }
        return rebuildAnnotationsCache(key: key)
    }

    /// Open-note counts per piece, for the board's column. Keyed by piece id
    /// (`StructureItem.id == docId`), with an entry only where at least one
    /// note is OPEN — `.stetted`, accepted, rejected and archived notes are all
    /// resolved, and a withdrawn note is absent from the projection entirely.
    ///
    /// Derived from the same cached snapshot, so asking for both costs one walk.
    /// A piece in `unreadableDocIds` gets no entry here: a zero would be a lie
    /// and this map has nowhere to say "unknown" — the caller that needs to
    /// distinguish the two reads the snapshot.
    ///
    /// **Pass the snapshot when you have already read one** (the board's count
    /// recompute wants both halves at once, M3 P2 Task 9). The cache makes a
    /// second call cheap but not free: the KEY check stats every closed
    /// document's op-log files, and doing that twice for one refresh is the
    /// aggregation's own cost paid for nothing.
    ///
    /// **A figure's notes count on the piece that owns it** (report plan 9c-1
    /// ruling: `FigureRecord.piece`), so the board's count for a chapter
    /// includes the notes on its tables. A whole-book figure's notes (no
    /// piece) count on no piece — they stay in the project queue — and no
    /// entry is keyed by a figure's id, which no board row shows.
    public func openNotesSummaries(
        in snapshot: ProjectAnnotationsSnapshot? = nil
    ) -> [String: OpenNotesSummary] {
        var totals: [String: Int] = [:]
        var passes: [String: [String: Int]] = [:]
        let owner = Self.figureNoteOwners(manifest.figures ?? [])
        let read = snapshot ?? listAnnotationsAcrossProject()
        // A piece owning a figure that would not read has a count nobody
        // knows (RULING-54): no entry, never a short number.
        let unknown = Self.unknownCounts(unreadableDocIds: read.unreadableDocIds, owners: owner)
        for entry in read.annotations
        where entry.annotation.status == .open {
            guard let docId = Self.countsOn(entry.docId, owners: owner),
                  !unknown.contains(docId) else { continue }
            totals[docId, default: 0] += 1
            if let pass = entry.annotation.reviewPassId {
                passes[docId, default: [:]][pass, default: 0] += 1
            }
        }
        return totals.reduce(into: [:]) { out, pair in
            out[pair.key] = OpenNotesSummary(
                total: pair.value, byPass: passes[pair.key] ?? [:])
        }
    }

    /// **The board rows whose open-notes count is unknown** (RULING-54): every
    /// document the walk could not read, and every piece owning a figure it
    /// could not read (report plan 9c-1 Task 7) — its notes count on that
    /// piece, so the piece's count is not known either. The board draws these
    /// as unknown, never as a number.
    public func openNotesUnreadable(in snapshot: ProjectAnnotationsSnapshot) -> Set<String> {
        Self.unknownCounts(unreadableDocIds: snapshot.unreadableDocIds,
                           owners: Self.figureNoteOwners(manifest.figures ?? []))
    }

    nonisolated static func unknownCounts(
        unreadableDocIds: [String], owners: [String: String?]
    ) -> Set<String> {
        Set(unreadableDocIds).union(unreadableDocIds.compactMap { owners[$0] ?? nil })
    }

    // MARK: - Helpers

    /// Each registered figure's owning piece, nil for a whole-book figure.
    nonisolated static func figureNoteOwners(_ figures: [FigureRecord]) -> [String: String?] {
        Dictionary(figures.map { ($0.id, $0.piece) }, uniquingKeysWith: { a, _ in a })
    }

    /// The board row a note on stream `docId` counts on: the document itself,
    /// or for a figure's stream the piece that owns it — nil for a whole-book
    /// figure, and for a figure the registry no longer holds.
    nonisolated static func countsOn(_ docId: String, owners: [String: String?]) -> String? {
        guard DocumentClass.isFigureDocId(docId) else { return docId }
        return owners[docId] ?? nil
    }

    private func currentAnnotationsKey() -> ProjectAnnotationsCacheKey {
        let openDocs = openDocumentsByID()
        var sum = 0
        var count = 0
        for item in Self.collectDocuments(in: manifest.structure) {
            count += 1
            if let doc = openDocs[item.id] {
                sum &+= doc.annotationsVersion
                continue
            }
            // Per-device partitioning (ADR 0012): fold every op-log file's
            // mtime (legacy + per-device + sealed segments), not just
            // `<docId>.jsonl`, so a peer device's file arriving via sync
            // re-derives the walk.
            for opLogURL in OpLogStore.opLogFileURLs(forDocId: item.id, in: url) {
                if let attrs = try? FileManager.default.attributesOfItem(
                    atPath: opLogURL.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    sum &+= Int(mtime.timeIntervalSince1970 * 1000)
                }
            }
        }
        // The figures' own streams (report plan 6a), always from disk: a note
        // on a figure is read off its stream whether or not a window holds it.
        for figure in manifest.figures ?? [] {
            count += 1
            for opLogURL in OpLogStore.opLogFileURLs(forDocId: figure.id, in: url) {
                if let attrs = try? FileManager.default.attributesOfItem(
                    atPath: opLogURL.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    sum &+= Int(mtime.timeIntervalSince1970 * 1000)
                }
            }
        }
        // The book's language (report plan 9c-1 Task 7): a figure
        // suggestion's cells are read as text in it, so a language change
        // re-reads the walk.
        if let attrs = try? FileManager.default.attributesOfItem(
            atPath: BookLanguage.configURL(in: url).path),
           let mtime = attrs[.modificationDate] as? Date {
            sum &+= Int(mtime.timeIntervalSince1970 * 1000)
        }
        // The document count is in the key because adding or removing a piece
        // changes what the walk covers without necessarily moving the sum (a
        // new piece has no op log yet, and so contributes nothing to it).
        return .init(perDocVersionSum: sum, documentCount: count)
    }

    @discardableResult
    private func rebuildAnnotationsCache(
        key: ProjectAnnotationsCacheKey
    ) -> ProjectAnnotationsSnapshot {
        #if DEBUG
        _debugAnnotationsRebuildCount &+= 1
        #endif

        let openDocs = openDocumentsByID()
        // Every status: the cache serves any follow-up filter without a
        // re-derive, exactly as the task cache does.
        let allStatuses = AnnotationFilter(kinds: nil, statuses: nil)

        var annotations: [ProjectAnnotation] = []
        var unreadable: [String] = []
        var sequences: [String: [String]] = [:]

        // ONE trust resolution for the whole walk. `loadSyncMerged` resolves
        // its own when given none, and that is a verified read of the registry
        // folder — thirty chapters would be thirty of them.
        //
        // **A resolution that throws leaves this walk KEYLESS, and the fallback
        // has to be spelled** (whole-branch review, I2): a bare `try?` yields
        // nil, `loadSyncMerged` then resolves its own table per document, that
        // throws the same error again, and the `try?` below records every
        // closed chapter as unreadable — a project-wide count emptied by one
        // registry record, and blamed on the chapters. Keyless is P1's
        // behaviour exactly. The registry's OWN name goes into the same list,
        // so the count surface still says it is not the whole story and says
        // it about the registry.
        //
        // **It stays on the main actor, and that is a decision** (P2b Task 10).
        // A resolve is a directory read plus a P256 verify per registry record,
        // and `TrustResolution`'s own note asks callers to run it off-main.
        // This one cannot be: the method is a synchronous `@MainActor`
        // accessor that every pane calls for a value, so moving the resolve
        // off-main means making the method `async`, and an `async` accessor
        // here is a redraw that arrives after the pane has already drawn —
        // the very shape tripwire 3 is about. The walk it heads is already a
        // main-actor synchronous disk read per closed document (see the note
        // above), so the resolve is a small fraction of a cost that is
        // deliberate and cached: the aggregation key folds every closed doc's
        // op-log mtime, so nothing here runs again until something moved.
        let trust: TrustTable
        do {
            trust = try TrustResolution.resolve(projectURL: url, identities: .current)
        } catch {
            // One fallback for every reader (fix round 2, minor 2): this
            // device's own memory of the register first, and `keyless` only
            // where there is none — `keyless` says *author of the whole book*
            // about everybody, so reaching for it over one unreadable record
            // would un-narrow every reviewer in the book.
            trust = TrustResolution.rememberedOrKeyless(
                projectURL: url, identities: .current)
            unreadable.append(OpLogStore.unreadableName(error))
        }

        // Bound out of the manifest once, for the amendment rule's class
        // closure: it is `@Sendable`, so it may not reach back through `self`.
        let facts = DocumentClass.Facts(manifest)
        for item in Self.collectDocuments(in: manifest.structure) {
            if let doc = openDocs[item.id] {
                sequences[item.id] = doc.sequence
                annotations.append(contentsOf: doc.annotations(filter: allStatuses)
                    .map { ProjectAnnotation(docId: item.id, annotation: $0) })
                continue
            }
            guard item.path != nil else { continue }
            // Sync disk reads are deliberate here for the reason the task walk
            // gives: a pane refresh must not block on async actor init per
            // document, and per-doc op logs are small. The cache key folds each
            // closed doc's op-log mtimes, so this runs only when something moved.
            //
            // RULING-54 lenient, reason recorded: a project-wide COUNT skips a
            // document whose log cannot be read rather than refusing the whole
            // read — opening that document still refuses loudly. It is not
            // silent, though: the id goes into `unreadableDocIds` so a count
            // surface can render "unknown" rather than a number that is short.
            // P3a Task 6 fix round 1: the queue judges an amendment as of its
            // own line too, off the permits this walk's own classification
            // recorded — one collector per document, because the map is keyed
            // by op id and two chapters must not share one.
            let amendmentPermits = AmendmentPermits()
            guard let ops = try? OpLogStore.loadSyncMerged(
                forDocId: item.id, in: url, trust: trust,
                facts: facts,
                amendmentPermits: amendmentPermits)
            else {
                unreadable.append(item.id)
                continue
            }
            // One derive per document: `deriveWithSequenceFallback` gives both
            // the paragraphs the notes anchor against and the order Task 7's
            // cross-document sort needs (the fallback arm recovers an order for
            // legacy sequence-less logs).
            let derived = Deriver.deriveWithSequenceFallback(ops: ops)
            sequences[item.id] = derived.sequence
            // P3a Task 6: the same *whose annotation is it* rule the open
            // document applies, off the table this walk already resolved and
            // the manifest it already holds. The queue counts notes in pieces
            // nobody has opened, so a rule only the editor applied would have
            // two surfaces disagreeing about whether a note is still there.
            annotations.append(contentsOf: AnnotationAggregation.allAnnotations(
                ops: ops, paragraphs: derived.paragraphs,
                amendments: .judged(
                    by: trust, permits: amendmentPermits.resolved,
                    insideTheUnsignedSnapshot:
                        amendmentPermits.resolvedInsideTheUnsignedSnapshot,
                    class: {
                        DocumentClass.resolve(docId: item.id, facts: facts)
                    }))
                .map { ProjectAnnotation(docId: item.id, annotation: $0) })
        }

        // **The figures' notes** (report plan 6a): a figure is its own
        // op-logged stream, judged like any other, so the notes on it are the
        // project's too — the phone's Annotations tab lists them, and the
        // queue files them under the registry's names
        // (`AnnotationScopeSections.build`'s `figures`). Read from disk even
        // when a window holds the figure, so every figure is read one way.
        // A figure has no paragraphs, so no sequence is recorded.
        var figureTables: [String: FigureTable] = [:]
        var figureSuggestions: [(figureId: String, note: Annotation)] = []
        for figure in manifest.figures ?? [] {
            guard let read = Self.figureNotesAndTable(figure.id, in: url, trust: trust, facts: facts) else {
                unreadable.append(figure.id)
                continue
            }
            figureTables[figure.id] = read.table
            annotations.append(contentsOf: read.notes.map { ProjectAnnotation(docId: figure.id, annotation: $0) })
            figureSuggestions += read.notes.filter { $0.kind == .suggestedChange }.map { (figure.id, $0) }
        }

        let snapshot = ProjectAnnotationsSnapshot(
            annotations: annotations,
            unreadableDocIds: unreadable,
            sequences: sequences,
            figureCells: figureCells(figureSuggestions, tables: figureTables))
        _projectAnnotationsCache = snapshot
        _projectAnnotationsCacheKey = key
        return snapshot
    }

    /// **One figure's notes** — its stream judged as the walk judges it,
    /// nil when the stream will not read. Nonisolated: the figure inspector
    /// reads it off the main actor (`figureNotes`), the walk inline.
    nonisolated static func figureAnnotations(
        _ figureId: String, in url: URL, trust: TrustTable, facts: DocumentClass.Facts
    ) -> [Annotation]? {
        figureNotesAndTable(figureId, in: url, trust: trust, facts: facts)?.notes
    }

    /// One figure's notes and the table they resolve against, from one read
    /// of its stream — nil when the stream will not read. Core's judged read
    /// (`FigureNotesRead`, report plan 9c-2), the one `FigureCache` and the
    /// phone read through too (tripwire 19).
    nonisolated static func figureNotesAndTable(
        _ figureId: String, in url: URL, trust: TrustTable, facts: DocumentClass.Facts
    ) -> (notes: [Annotation], table: FigureTable?)? {
        guard let read = try? FigureNotesRead.read(figureId: figureId, in: url, trust: trust, facts: facts)
        else { return nil }
        return (read.notes, read.table)
    }

    /// **Each figure suggestion's cells as text** (report plan 9c-1 Task 7),
    /// keyed by note id: `SuggestionDisplay.figureCells` against its figure's
    /// table, with every figure's table as the formula names and the book's
    /// language. The language is read only when there is a suggestion to
    /// show (a small file, read synchronously as this walk reads op logs).
    private func figureCells(
        _ suggestions: [(figureId: String, note: Annotation)], tables: [String: FigureTable]
    ) -> [String: SuggestionDisplay.FigureCells] {
        guard !suggestions.isEmpty else { return [:] }
        let names = FormulaNames(records: manifest.figures ?? [], tables: tables, research: manifest.research)
        let tag = (try? Data(contentsOf: BookLanguage.configURL(in: url))) // adr-0018-ok: publish config JSON read, not manuscript
            .flatMap(BookLanguage.tag(fromConfigData:))
        let locale = TableLocale(languageTag: tag)
        var cells: [String: SuggestionDisplay.FigureCells] = [:]
        for (figureId, note) in suggestions {
            guard let table = tables[figureId],
                  let shown = SuggestionDisplay.figureCells(for: note, table: table, names: names, locale: locale)
            else { continue }
            cells[note.id] = shown
        }
        return cells
    }

    /// **The notes on ONE figure's stream** (report plan 8a Task 7, the
    /// figure inspector): the trust resolve and the stream's read off the
    /// main actor, never the project walk — a figure's own writes move that
    /// walk's key, so asking it per write would re-derive every closed piece.
    /// Empty when the stream will not read.
    func figureNotes(_ figureId: String) async -> [Annotation] {
        let url = url, facts = DocumentClass.Facts(manifest)
        let trust = await figureReadTrust()
        return await Task.detached(priority: .userInitiated) {
            Self.figureAnnotations(figureId, in: url, trust: trust, facts: facts) ?? []
        }.value
    }

    /// **One figure's raw ops** (report plan 9c-1 Task 6, `get_annotation`'s
    /// history): the stream `figureNotes` derives from, read the same way
    /// (same trust, merged across devices), for a reader that wants the ops
    /// themselves. Raw like the manuscript's `Document.opLog()` — history is
    /// not amendment-judged on either side. Empty when the stream will not read.
    func figureOps(_ figureId: String) async -> [Op] {
        let url = url, facts = DocumentClass.Facts(manifest)
        let trust = await figureReadTrust()
        return await Task.detached(priority: .userInitiated) {
            (try? OpLogStore.loadSyncMerged(
                forDocId: figureId, in: url, trust: trust, facts: facts,
                amendmentPermits: AmendmentPermits())) ?? []
        }.value
    }

    /// The trust a single-figure read judges under — resolved off the main
    /// actor; the remembered (or keyless) table when it will not resolve.
    private func figureReadTrust() async -> TrustTable {
        let url = url, identities = LocalIdentities.current
        return await Task.detached(priority: .userInitiated) {
            (try? TrustResolution.resolve(projectURL: url, identities: identities))
                ?? TrustResolution.rememberedOrKeyless(projectURL: url, identities: identities)
        }.value
    }

    /// Open documents by doc id. `Document.docId` IS the manifest item's id
    /// (`resolveDocId` reads it out of the manifest), which is what lets the
    /// walk decide open-vs-closed per piece.
    private func openDocumentsByID() -> [String: Document] {
        (documentStore?.allOpenDocuments() ?? [])
            .reduce(into: [:]) { out, doc in out[doc.docId] = doc }
    }
}
