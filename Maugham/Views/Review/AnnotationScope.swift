import Foundation
import MaughamCore

/// **How wide the annotations queue is looking** (M3 P2 Task 7).
///
/// Window `@State` on `ProjectWindow`, threaded down — and deliberately NOT
/// persisted to `UIState`: a scope is a glance, not a home. A writer who
/// widened the queue once to find where the copyedit notes piled up should
/// reopen the project in the piece they were working on, not in a list of the
/// whole book.
///
/// `focusPiece` is the arriving half. It is set by Task 9's click-through from
/// the board's open-notes column — "these eleven notes, in this chapter" — and
/// scrolls that piece's section into view (the `TreeScrollTarget` shape). It is
/// not a filter: the queue still shows the whole project, because the writer
/// who clicked one chapter's count is one scroll from the next chapter's and
/// hiding it would make the widest scope the narrowest one.
enum AnnotationScope: Equatable {
    case document
    case project(focusPiece: String?)

    var isProject: Bool {
        if case .project = self { return true }
        return false
    }
}

/// The queue's cross-document rules, pure so RULING-35's no-dead-controls rule
/// and the ejection trap are both testable without mounting the pane
/// (`AnnotationScopeTests`).
enum AnnotationScopePolicy {

    /// **A row's verbs act only where a live `Document` exists.**
    ///
    /// The alternative — materialising a transient `Document` for a closed
    /// piece and mutating that — is worse than a disabled button in the one way
    /// that matters: the op would land, the writer's ⌘Z would not reach it, and
    /// no surface would be showing the piece it changed. So a closed piece's
    /// notes are READ here and acted on there, and clicking the row is what
    /// gets the writer there.
    static func verbsEnabled(documentIsOpen: Bool) -> Bool { documentIsOpen }

    /// Why they are off. RULING-35: a disabled control that cannot say why is
    /// the half that costs the writer the most — this one also says what to do
    /// about it, and the click that does it is the row itself.
    static let closedPieceReason = "Open this piece to act"

    /// What clicking a project-scope row means.
    enum Click: Equatable {
        /// The row belongs to the piece already centred: the existing
        /// paragraph/annotation navigation, exactly as document scope does it.
        case jump
        /// The row belongs to another piece: take the window there. A SUBJECT
        /// write and nothing else — Review's centre shows documents, so this
        /// navigation must never move the persona (`ManuscriptNavigation`, and
        /// the ejection trap the whole of M3 is written around).
        case travel(String)
    }

    static func click(rowDocId: String, activeDocId: String?) -> Click {
        rowDocId == activeDocId ? .jump : .travel(rowDocId)
    }

    /// **Multiselect and the bulk bar are document-scope only.**
    ///
    /// `AnnotationBulkActions.perform` runs against ONE `Document`, and every
    /// count the bar shows ("All 23 shown", "12 will accept") is a promise
    /// about what the click will do. Across pieces those numbers would have to
    /// silently exclude every closed document — the bar would be honest only in
    /// the projects where it was useless. The honest cross-document version is
    /// a batch per document with an undo story of its own; it is not this task,
    /// and a writer who wants it can widen, travel to the piece, and use the bar
    /// there.
    static func showsBulkAffordances(_ scope: AnnotationScope) -> Bool {
        !scope.isProject
    }
}

/// **The cross-document queue's sections** — the board's rows with the
/// un-annotated ones dropped, each annotated piece carrying its own notes in
/// its own queue order.
///
/// Pure by construction, in `ReviewBoardRows`' discipline: rows in, sections
/// out, no store and no disk, so the whole truth table is exercised with no
/// window and no project (`AnnotationScopeTests`).
///
/// **It CALLS `ReviewBoardRows.derive` rather than walking the manifest again**
/// (the caller does the derive and hands the rows in). Order and grouping are
/// one question and the board already answers it; a second walk here is how the
/// queue and the board come to disagree about where Part Two starts.
enum AnnotationScopeSections {

    /// One section. A `.piece` carries its notes; a `.group` is a header and
    /// carries none — a group is a place in the tree, never a thing notes are
    /// attached to.
    ///
    /// The notes are `[Annotation]` rather than `[ProjectAnnotation]`: a piece
    /// section IS one document, and `item.id` is that document's id, so
    /// re-carrying the doc id per row would be a second copy of a fact the
    /// section already states.
    struct Section: Equatable, Identifiable {
        enum Kind: Equatable {
            /// A group header. `depth` is `ReviewBoardRows`' own — 0 for a root
            /// group, incrementing per level of nesting.
            case group(depth: Int)
            case piece
        }

        let kind: Kind
        let item: StructureItem
        let annotations: [Annotation]

        var id: String { item.id }
    }

    /// Group `annotations` by piece and drop everything with nothing in it.
    ///
    /// - Parameters:
    ///   - rows: `ReviewBoardRows.derive(structure:)`'s output — the order.
    ///   - annotations: the project-wide notes, ALREADY filtered by the pane
    ///     (kind, status, author, triage). Filtering before grouping is what
    ///     makes "a header only where there is something to show" mean *after
    ///     the filters*, which is the only reading that leaves no empty
    ///     headings when a writer narrows to Suggestions.
    ///   - sequences: `ProjectAnnotationsSnapshot.sequences` — each document's
    ///     paragraph order, so a piece's notes are sorted against ITS OWN
    ///     document order (the snapshot carries them precisely so a
    ///     cross-document sort never degrades to derive order for the closed
    ///     documents). A piece with no entry sorts into the queue's unanchored
    ///     tail rather than being dropped.
    static func build(
        rows: [ReviewBoardRows.Row],
        annotations: [ProjectAnnotation],
        sequences: [String: [String]] = [:]
    ) -> [Section] {
        guard !annotations.isEmpty else { return [] }

        var byDoc: [String: [Annotation]] = [:]
        for entry in annotations {
            byDoc[entry.docId, default: []].append(entry.annotation)
        }

        var sections: [Section] = []
        for row in rows {
            switch row.kind {
            case .reference:
                // A Collection's reference piece points at another project;
                // its notes are adjudicated in ITS window, and a row here would
                // be a control over state this manifest does not own. P1's
                // board makes the same choice (`ReviewBoardRows.Row.reference`
                // carries no chips).
                continue
            case .piece:
                guard let notes = byDoc[row.item.id], !notes.isEmpty else { continue }
                sections.append(Section(
                    kind: .piece,
                    item: row.item,
                    annotations: AnnotationQueueOrder.sorted(
                        notes, sequence: sequences[row.item.id] ?? [])))
            case .group(let depth):
                guard hasAnnotatedDescendant(row.item, byDoc: byDoc) else { continue }
                sections.append(Section(
                    kind: .group(depth: depth), item: row.item, annotations: []))
            }
        }
        return sections
    }

    /// Does anything under this group have notes?
    ///
    /// **Asked of the group's own subtree, not of the flat row list**, because
    /// the flat list cannot answer it: `ReviewBoardRows` carries depth on
    /// GROUPS alone (deliberately — see its doc comment), so a root-level piece
    /// following a nested group is indistinguishable from one inside it. The
    /// subtree is the honest source, and it is a containment question rather
    /// than an ordering one, so this is not the second walk the type doc
    /// forbids.
    private static func hasAnnotatedDescendant(
        _ item: StructureItem, byDoc: [String: [Annotation]]
    ) -> Bool {
        for child in item.children ?? [] {
            if child.type == .group {
                if hasAnnotatedDescendant(child, byDoc: byDoc) { return true }
            } else if child.pieceKind != .reference,
                      !(byDoc[child.id] ?? []).isEmpty {
                return true
            }
        }
        return false
    }

    /// The footnote for pieces the project walk could not read.
    ///
    /// RULING-54's honesty half, at the queue's foot: the aggregation is
    /// lenient about an unreadable op log (it skips the document rather than
    /// throwing the whole read away) and NAMES what it skipped, so this surface
    /// can say "unknown" where a silent queue would be saying "none". Titles,
    /// in board order, because an id means nothing to the writer.
    static func unreadableNotice(
        unreadableDocIds: [String], rows: [ReviewBoardRows.Row]
    ) -> String? {
        guard !unreadableDocIds.isEmpty else { return nil }
        let ids = Set(unreadableDocIds)
        let titles = rows.filter { ids.contains($0.item.id) }.map(\.item.title)
        guard !titles.isEmpty else { return nil }
        let named = titles.joined(separator: ", ")
        return titles.count == 1
            ? "Couldn\u{2019}t read \(named) — its notes are unknown, not none."
            : "Couldn\u{2019}t read \(named) — their notes are unknown, not none."
    }
}
