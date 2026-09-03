import Foundation
import MaughamCore

/// The Practice section's whole input — the writer's process across the BOOK,
/// spec `2026-08-29-the-editorial-letter-design.md` §5 surface 1.
///
/// `ProcessSignals` answers one document. This asks it of every manuscript
/// document and merges the answers: the project has one frontier (the most
/// recent of the per-document frontiers) and three hotspots (the churniest
/// paragraphs anywhere in the book), and each drawn paragraph carries the two
/// strings a row needs — its own words, and in a screenplay the slugline it
/// sits under.
///
/// **Closed documents only** (P3 constraint 30). The Statistics window is its
/// own scene running its own `ProjectStore`/`DocumentStore`
/// (`ProjectStatisticsWindow.load`), so nothing here consults a live
/// `Document`: every row derives through `OpLogStore.loadSyncMerged` +
/// `Deriver.deriveWithSequenceFallback`, the walk
/// `ProjectStore.projectAnnotations` already uses. A document whose log cannot
/// be read is skipped and NAMED (RULING-54 lenient — a section that refused the
/// whole book over one file would tell the writer nothing at all).
///
/// **No view, no store retained.** `derive` reads the store once and hands back
/// a value, so the section can be rebuilt, diffed and tested without a window.
struct ProjectPractice: Equatable {

    /// One manuscript document's process, plus the strings its rows draw.
    struct DocumentRow: Equatable, Identifiable {
        /// The docId, which IS `StructureItem.id` — the same key the op log,
        /// the annotation walk and `.maughamNavigateToDocument` all speak.
        let id: String
        let title: String
        let signals: ProcessSignals
        /// Paragraph id → the head of that paragraph as it reads right now.
        ///
        /// Keyed on exactly the paragraphs a row DRAWS — this document's
        /// frontier and its hotspots — because constraint 31 is why the excerpt
        /// exists at all: the jump opens the chapter and cannot scroll to the
        /// paragraph, so the excerpt is what tells the writer which one is
        /// meant. A paragraph nobody draws needs no excerpt, and a map over
        /// every paragraph in the book would be a copy of the manuscript held
        /// in a statistics value.
        let excerpts: [String: String]
        /// Screenplay only: paragraph id → the nearest PRECEDING slugline's
        /// text (or its own, when the paragraph is the slugline). Keyed on the
        /// same drawn set as `excerpts`, for the same reason; empty in a prose
        /// project, and empty for a paragraph that lives above the first
        /// slugline and so belongs to no scene.
        let sceneCaptions: [String: String]
    }

    /// Manuscript documents in structure order. Documents only — a group is not
    /// a row — and only those the manifest gives a `path`, since a pathless
    /// item has no op log to read.
    let rows: [DocumentRow]
    /// Documents skipped because their op log could not be read. Named rather
    /// than swallowed, so the section can say the book's numbers are short.
    let unreadableDocIds: [String]
    /// `manifest.type == .screenplay` — the one question that makes the section
    /// screenplay-shaped (spec §5: the existing stats render novel-shaped and
    /// the Practice section does not repeat that).
    let isScreenplay: Bool

    /// How many characters of a paragraph stand in for it in a row. Characters
    /// rather than `DiagnosticIngest.excerptWordLimit`'s words because this is a
    /// fixed-width row in a table, not a sentence in a pane — and that one is
    /// private to ingest besides.
    static let excerptCharacterLimit = 80

    // MARK: - The project's own answers

    /// The book's frontier: the row whose frontier is the most recent. `nil`
    /// when nothing has been typed anywhere — a value with nothing in it, not a
    /// zero. Ties (two chapters minted in the same instant) go to structure
    /// order, the same rule `hotspots` breaks its ties on.
    var frontier: (row: DocumentRow, frontier: ProcessSignals.Frontier)? {
        var best: (row: DocumentRow, frontier: ProcessSignals.Frontier)?
        for row in rows {
            guard let candidate = row.signals.frontier else { continue }
            guard let current = best else {
                best = (row, candidate)
                continue
            }
            if candidate.at > current.frontier.at { best = (row, candidate) }
        }
        return best
    }

    /// The book's churn: the top `ProcessSignals.hotspotCount` paragraphs by
    /// rewrites across every row. Ties break by row order and then by position,
    /// so the list reads DOWN the manuscript rather than in whatever order the
    /// per-document dictionaries happened to rank equal counts.
    var hotspots: [(row: DocumentRow, hotspot: ProcessSignals.Hotspot)] {
        var all: [(rowIndex: Int, row: DocumentRow, hotspot: ProcessSignals.Hotspot)] = []
        for (rowIndex, row) in rows.enumerated() {
            for hotspot in row.signals.hotspots {
                all.append((rowIndex, row, hotspot))
            }
        }
        return all
            .sorted { a, b in
                if a.hotspot.rewrites != b.hotspot.rewrites {
                    return a.hotspot.rewrites > b.hotspot.rewrites
                }
                if a.rowIndex != b.rowIndex { return a.rowIndex < b.rowIndex }
                return a.hotspot.position < b.hotspot.position
            }
            .prefix(ProcessSignals.hotspotCount)
            .map { (row: $0.row, hotspot: $0.hotspot) }
    }

    // MARK: - Derivation

    @MainActor
    static func derive(store: ProjectStore, projectURL: URL, now: Date) -> ProjectPractice {
        let isScreenplay = store.manifest.type == .screenplay
        var rows: [DocumentRow] = []
        var unreadable: [String] = []

        for item in TreeWalk.collect(
            in: store.manifest.structure, where: { $0.type == .document }
        ) {
            guard item.path != nil else { continue }
            // RULING-54 lenient, reason recorded: a window-wide READ skips a
            // document whose log cannot be read rather than refusing the whole
            // section — opening that document still refuses loudly. It is not
            // silent: the id goes into `unreadableDocIds`.
            guard let ops = try? OpLogStore.loadSyncMerged(
                forDocId: item.id, in: projectURL)
            else {
                unreadable.append(item.id)
                continue
            }
            // One derive per document: the sequence is both the paragraph order
            // the captions walk and the liveness oracle `ProcessSignals` reads.
            let derived = Deriver.deriveWithSequenceFallback(ops: ops)
            let signals = ProcessSignals(ops: ops, sequence: derived.sequence, now: now)

            var drawn: [String] = []
            if let frontier = signals.frontier { drawn.append(frontier.paragraphId) }
            drawn.append(contentsOf: signals.hotspots.map(\.paragraphId))

            var excerpts: [String: String] = [:]
            for paragraphId in drawn {
                guard let text = derived.paragraphs[paragraphId] else { continue }
                excerpts[paragraphId] = excerpt(of: text)
            }

            rows.append(DocumentRow(
                id: item.id,
                title: item.title,
                signals: signals,
                excerpts: excerpts,
                sceneCaptions: isScreenplay
                    ? sceneCaptions(for: Set(drawn), in: derived)
                    : [:]))
        }

        return ProjectPractice(
            rows: rows, unreadableDocIds: unreadable, isScreenplay: isScreenplay)
    }

    // MARK: - What a row says

    /// The head of a paragraph, as it reads right now: whitespace collapsed
    /// onto one line so a row is one line, then capped. Anchors go through the
    /// one shared transform (CLAUDE.md: never a target-local copy) — derived
    /// paragraph text carries none, since `Materializer` adds them on the way
    /// out, but a writer who typed one by hand should not see it here.
    private static func excerpt(of text: String) -> String {
        let collapsed = MarkdownDisplayFilter.stripAnchors(text)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(excerptCharacterLimit))
    }

    /// Paragraph id → the slugline it lives under, for the drawn paragraphs
    /// only. One pass down `sequence` carrying the last slugline seen, stopping
    /// as soon as every drawn paragraph has been passed.
    private static func sceneCaptions(
        for drawn: Set<String>, in derived: Deriver.DerivedState
    ) -> [String: String] {
        guard !drawn.isEmpty else { return [:] }
        var captions: [String: String] = [:]
        var remaining = drawn
        var currentScene: String?

        for paragraphId in derived.sequence {
            let text = derived.paragraphs[paragraphId] ?? ""
            if isSlugline(text) {
                currentScene = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard remaining.remove(paragraphId) != nil else { continue }
            // No entry rather than an invented one: a paragraph above the first
            // slugline belongs to no scene, and the row draws its excerpt alone.
            if let currentScene { captions[paragraphId] = currentScene }
            if remaining.isEmpty { break }
        }
        return captions
    }

    /// The slugline predicate is the tokenizer's own — the same
    /// `FountainTokenizer().parse(...)` → `.sceneHeading` question the Scenes
    /// navigator's `list_scenes` asks (`ReferenceTools.swift:52-56`). Never a
    /// second regex.
    ///
    /// **Asked per paragraph, and that is the cheap way round.** A
    /// context-sensitive scene heading needs a blank line above it
    /// (`FountainTokenizer.classifyContextual`'s `prevBlank` gate), and
    /// `parse` starts its state machine with `prevBlank = true` — so a
    /// paragraph handed over ALONE is already in exactly the context a heading
    /// wants, with no separator to synthesise. The alternative, tokenizing the
    /// whole materialized document once, would then need a line-offset →
    /// paragraph-id mapping to be kept honest against the anchors, which is
    /// more code and more to get wrong for a scan that stops at the last drawn
    /// paragraph anyway.
    private static func isSlugline(_ text: String) -> Bool {
        FountainTokenizer().parse(text).lines.first?.element == .sceneHeading
    }
}
