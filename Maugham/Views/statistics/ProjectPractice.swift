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
/// **The walk is OFF the main actor, and the split is the point.** Measured on
/// a 30-chapter × 200-paragraph book: **1.3–1.9 s** depending on how much the
/// ops carry, 96% of it inside `OpLogStore.loadSyncMerged`. Run where the
/// window ran it until fix round 2, that is the whole app frozen on every
/// stats-window open and on every session end while the window is up. So the
/// derivation is two halves that can never be one:
///
/// - `Plan(store:)` is `@MainActor` and reads the manifest — the document ids,
///   their titles and paths, and whether the project is a screenplay. It
///   touches no file and measures in the tens of microseconds.
/// - `derive(plan:projectURL:now:)` is `nonisolated`, takes only that
///   `Sendable` value, and is where every byte is read. It belongs on a
///   detached task; `ProjectStatisticsWindow.rederivePractice` is the one
///   production caller and hands the result back on the main actor.
///
/// There is deliberately no `derive(store:…)` convenience any more. One would
/// compile at any call site and quietly put the second half back on the main
/// actor, which is exactly the defect this shape exists to prevent.
///
/// **No view, no store retained.** `derive` reads a plain value and hands back
/// a plain value, so the section can be rebuilt, diffed and tested without a
/// window.
struct ProjectPractice: Equatable, Sendable {

    /// One manuscript document's process, plus the strings its rows draw.
    struct DocumentRow: Equatable, Sendable, Identifiable {
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

    // MARK: - What the walk needs from the project

    /// The manifest, reduced to the four facts the walk actually reads — and
    /// `Sendable`, which is the whole reason it is a type.
    ///
    /// `ProjectStore` is main-actor state; the walk is a file read that must
    /// not run there. Rather than hop back into the store for each document,
    /// the plan is taken once, on the main actor, and the walk is handed a
    /// value it can carry across.
    struct Plan: Equatable, Sendable {

        /// One manifest item that might become a row.
        struct Document: Equatable, Sendable {
            let id: String
            let title: String
            /// `nil` for an item the manifest lists with no file. Carried
            /// rather than filtered out here so the plan stays a plain
            /// transcription of the manifest and the rule that drops it — no
            /// path, no op log — is stated once, in the walk.
            let path: String?
        }

        let documents: [Document]
        let isScreenplay: Bool
    }

    // MARK: - Derivation

    /// The walk: every document's op log, read and merged into the book's one
    /// answer. **`nonisolated` on purpose** — see the type's own doc. Every
    /// file read in this function happens on whatever executor the caller is
    /// on, and the one production caller runs it detached.
    nonisolated static func derive(
        plan: Plan, projectURL: URL, now: Date
    ) -> ProjectPractice {
        var rows: [DocumentRow] = []
        var unreadable: [String] = []

        for item in plan.documents {
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
                sceneCaptions: plan.isScreenplay
                    ? sceneCaptions(for: Set(drawn), in: derived)
                    : [:]))
        }

        return ProjectPractice(
            rows: rows, unreadableDocIds: unreadable,
            isScreenplay: plan.isScreenplay)
    }

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

    // MARK: - What a row says

    /// The head of a paragraph, as it reads right now: whitespace collapsed
    /// onto one line so a row is one line, then capped. Anchors go through the
    /// one shared transform (CLAUDE.md: never a target-local copy) — derived
    /// paragraph text carries none, since `Materializer` adds them on the way
    /// out, but a writer who typed one by hand should not see it here.
    private nonisolated static func excerpt(of text: String) -> String {
        let collapsed = MarkdownDisplayFilter.stripAnchors(text)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(excerptCharacterLimit))
    }

    /// Paragraph id → the slugline it lives under, for the drawn paragraphs
    /// only. **Found by walking BACK from each drawn paragraph**, so the scan
    /// is the length of a scene rather than the length of the book, and it
    /// stops at the first slugline above (or at) the paragraph itself.
    ///
    /// The predicate is still the tokenizer's own — the same `.sceneHeading`
    /// question `list_scenes` asks (`ReferenceTools.swift:52-56`), never a
    /// second regex — and a paragraph is still asked ALONE, which is the cheap
    /// way round for one paragraph: a context-sensitive scene heading needs a
    /// blank line above it (`FountainTokenizer.classifyContextual`'s
    /// `prevBlank` gate) and `parse` starts its state machine with
    /// `prevBlank = true`, so a paragraph handed over on its own is already in
    /// exactly the context a heading wants, with no separator to synthesise and
    /// no line-offset → paragraph-id mapping to keep honest.
    ///
    /// **What was wrong was the number of paragraphs asked, not the question.**
    /// The first form walked FORWARD from the top of the document carrying the
    /// last slugline seen, which parses every paragraph above the drawn ones —
    /// the frontier is near the end of a document by definition, so that was
    /// usually all of them. Measured over one 3,000-paragraph screenplay:
    ///
    /// - forward walk, a tokenizer per paragraph: **49.7 ms**
    /// - forward walk, one hoisted tokenizer: **50.8 ms** (the type has no
    ///   stored properties; constructing one costs nothing, and hoisting it
    ///   buys nothing — measured rather than assumed)
    /// - one parse of the whole joined document, headings mapped back by
    ///   UTF-16 offset: **41.1 ms** — still linear in the book
    /// - this, walking back from each drawn paragraph: **2.0 ms**
    ///
    /// All four answer identically on that fixture.
    private nonisolated static func sceneCaptions(
        for drawn: Set<String>, in derived: Deriver.DerivedState
    ) -> [String: String] {
        guard !drawn.isEmpty else { return [:] }
        let tokenizer = FountainTokenizer()
        var indexOf: [String: Int] = [:]
        for (index, paragraphId) in derived.sequence.enumerated()
        where indexOf[paragraphId] == nil {
            indexOf[paragraphId] = index
        }

        var captions: [String: String] = [:]
        for paragraphId in drawn {
            // A drawn paragraph the manuscript no longer orders has no place to
            // walk back from, and no caption.
            guard var index = indexOf[paragraphId] else { continue }
            while index >= 0 {
                let text = derived.paragraphs[derived.sequence[index]] ?? ""
                if tokenizer.parse(text).lines.first?.element == .sceneHeading {
                    captions[paragraphId] =
                        text.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                index -= 1
            }
            // No entry rather than an invented one: a paragraph above the first
            // slugline belongs to no scene, and the row draws its excerpt alone.
        }
        return captions
    }
}

extension ProjectPractice.Plan {

    /// The manifest read, and the ONLY main-actor step in the whole derivation.
    /// Everything after this is `ProjectPractice.derive(plan:projectURL:now:)`,
    /// which reads files and must not run here.
    @MainActor
    init(store: ProjectStore) {
        self.init(
            documents: TreeWalk.collect(
                in: store.manifest.structure, where: { $0.type == .document }
            ).map {
                Document(id: $0.id, title: $0.title, path: $0.path)
            },
            isScreenplay: store.manifest.type == .screenplay)
    }
}
