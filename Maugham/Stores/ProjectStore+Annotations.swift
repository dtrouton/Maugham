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

    public init(
        annotations: [ProjectAnnotation],
        unreadableDocIds: [String],
        sequences: [String: [String]]
    ) {
        self.annotations = annotations
        self.unreadableDocIds = unreadableDocIds
        self.sequences = sequences
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
    public func openNotesSummaries() -> [String: OpenNotesSummary] {
        var totals: [String: Int] = [:]
        var passes: [String: [String: Int]] = [:]
        for entry in listAnnotationsAcrossProject().annotations
        where entry.annotation.status == .open {
            totals[entry.docId, default: 0] += 1
            if let pass = entry.annotation.reviewPassId {
                passes[entry.docId, default: [:]][pass, default: 0] += 1
            }
        }
        return totals.reduce(into: [:]) { out, pair in
            out[pair.key] = OpenNotesSummary(
                total: pair.value, byPass: passes[pair.key] ?? [:])
        }
    }

    // MARK: - Helpers

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
            guard let ops = try? OpLogStore.loadSyncMerged(forDocId: item.id, in: url)
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
            annotations.append(contentsOf: AnnotationAggregation.allAnnotations(
                ops: ops, paragraphs: derived.paragraphs)
                .map { ProjectAnnotation(docId: item.id, annotation: $0) })
        }

        let snapshot = ProjectAnnotationsSnapshot(
            annotations: annotations,
            unreadableDocIds: unreadable,
            sequences: sequences)
        _projectAnnotationsCache = snapshot
        _projectAnnotationsCacheKey = key
        return snapshot
    }

    /// Open documents by doc id. `Document.docId` IS the manifest item's id
    /// (`resolveDocId` reads it out of the manifest), which is what lets the
    /// walk decide open-vs-closed per piece.
    private func openDocumentsByID() -> [String: Document] {
        (documentStore?.allOpenDocuments() ?? [])
            .reduce(into: [:]) { out, doc in out[doc.docId] = doc }
    }
}
