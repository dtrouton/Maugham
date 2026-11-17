import Foundation
import MaughamCore

/// **One heading in To resolve and the items under it** (shell plan 2).
struct ResolveGroup: Identifiable, Equatable {
    enum Key: Hashable {
        /// The Book's own to-dos ("The book").
        case bookLevel
        /// Items on a piece as a whole ("Whole chapter"; "Whole script").
        case wholePiece(docId: String)
        /// Items on one paragraph, titled by its text.
        case paragraph(docId: String, paragraphId: String)
        /// A screenplay's scene, titled by its slugline, keyed by the id of the
        /// paragraph its slugline begins — so a scene inserted above leaves
        /// every other scene's key (and the list's state for it) where it was.
        case scene(docId: String, headingParagraphId: String)
        /// A screenplay's paragraphs before its first slugline.
        case beforeFirstScene(docId: String)
        /// A piece whose paragraph order did not read: its paragraph-anchored
        /// items, in one group ("Position unknown"), never placed by guess.
        case unplaced(docId: String)
        /// Items whose paragraph is no longer in the sequence ("No longer in
        /// the text") — always the piece's last, never dropped.
        case removed(docId: String)
        /// One piece of a Book or Part, titled by the piece.
        case piece(docId: String)
        /// One figure's notes, titled by the figure.
        case figure(id: String)
    }

    let key: Key
    let title: String
    let items: [ResolveItem]
    var id: Key { key }
}

/// **To resolve's grouping** (shell plan 2, Task 2): a snapshot's items under
/// headings — by paragraph in a piece, by scene in a screenplay, by piece in a
/// Book or Part. Pure; called once per refresh, never from a row (tripwire 4).
///
/// Order, outermost first:
/// - `.piece`: the Book's to-dos (a screenplay's Book only), Whole chapter,
///   one group per paragraph in `sequence` order — or, for a screenplay
///   (`sceneIndex != nil`), Before the first scene then one group per scene —
///   then No longer in the text, then one group per figure the piece owns.
///   A piece whose order did not read (`sequences[docId] == nil`) has no
///   paragraph, scene or removed groups: its anchored items go in one
///   Position unknown group after Whole chapter.
/// - `.pieces`: The book (when it holds anything), one group per piece in the
///   scope's (manuscript) order, then one group per figure with notes. Inside
///   a piece group: whole-piece items, then paragraph order, then removed.
/// - `.figure`: its one group. `.elsewhere` / `.outside`: none.
/// - Inside every group (and every section of a piece group): notes in
///   `AnnotationQueueOrder`, then findings, then to-dos by `priority`.
///
/// Empty groups are never emitted. An item is never dropped: a document the
/// scope does not name (none should reach here) gets a piece group of its own
/// after the scope's pieces.
enum ResolveGrouping {

    /// - Parameters:
    ///   - structure: the manifest's tree, for piece titles.
    ///   - sceneIndex: `ParagraphOffsets.sceneIndex` of the window's script
    ///     when the scope is a screenplay's `.piece`; nil otherwise.
    ///   - sceneTitles: the sluglines, indexed as `sceneIndex` is.
    ///   - figureNames: figure id → its name (`FigureRecord.name`), for
    ///     figure group titles. No default on purpose: an omitted map titles
    ///     every figure "Figure", invisible in a green suite.
    static func groups(_ snapshot: ResolveSnapshot, scope: ResolveScope, structure: [StructureItem],
                       sceneIndex: [String: Int]?, sceneTitles: [String],
                       figureNames: [String: String]) -> [ResolveGroup] {
        let isPiece: Bool
        switch scope {
        case .elsewhere, .outside: return []
        case .piece: isPiece = true
        case .pieces, .figure: isPiece = false
        }

        // One pass: the Book's to-dos, each figure's notes, each piece's items.
        var bookItems: [ResolveItem] = []
        var figureOrder: [String] = [], byFigure: [String: [ResolveItem]] = [:]
        var docOrder: [String] = [], byDoc: [String: [ResolveItem]] = [:]
        for item in snapshot.items {
            let docId = item.docId
            if docId == ProjectStore.projectTasksDocId {
                bookItems.append(item)
            } else if DocumentClass.isFigureDocId(docId) {
                if byFigure[docId] == nil { figureOrder.append(docId) }
                byFigure[docId, default: []].append(item)
            } else {
                if byDoc[docId] == nil { docOrder.append(docId) }
                byDoc[docId, default: []].append(item)
            }
        }

        var groups: [ResolveGroup] = []
        if !bookItems.isEmpty {
            groups.append(ResolveGroup(key: .bookLevel, title: "The book",
                                       items: ordered(bookItems, sequence: [])))
        }

        // The scope's pieces in its order, then any stray document.
        let scoped = scope.docIds.filter { !DocumentClass.isFigureDocId($0) }
        let pieces = scoped + docOrder.filter { !scoped.contains($0) }
        for (position, docId) in pieces.enumerated() {
            guard let items = byDoc[docId], !items.isEmpty else { continue }
            let sections = self.sections(
                docId: docId, items: items, sequence: snapshot.sequences[docId],
                paragraphText: snapshot.paragraphText,
                sceneIndex: isPiece ? sceneIndex : nil, sceneTitles: sceneTitles)
            if isPiece && position == 0 {
                groups += sections
            } else {
                groups.append(ResolveGroup(key: .piece(docId: docId),
                                           title: pieceTitle(docId, structure: structure),
                                           items: sections.flatMap(\.items)))
            }
        }

        for figureId in figureOrder {
            guard let items = byFigure[figureId] else { continue }
            groups.append(ResolveGroup(key: .figure(id: figureId),
                                       title: figureNames[figureId] ?? "Figure",
                                       items: ordered(items, sequence: [])))
        }
        return groups
    }

    // MARK: - One piece

    /// One piece's items as sections: whole piece, then paragraphs (or
    /// scenes), then removed. `sequence == nil` (a piece whose order did not
    /// read) judges nothing removed and places nothing: its anchored items go
    /// in one Position unknown group.
    private static func sections(docId: String, items: [ResolveItem], sequence: [String]?,
                                 paragraphText: [String: String],
                                 sceneIndex: [String: Int]?, sceneTitles: [String]) -> [ResolveGroup] {
        var position: [String: Int] = [:]
        for (index, pid) in (sequence ?? []).enumerated() where position[pid] == nil {
            position[pid] = index
        }
        let order = sequence ?? []

        var whole: [ResolveItem] = [], removed: [ResolveItem] = []
        var paragraphOrder: [String] = [], byParagraph: [String: [ResolveItem]] = [:]
        var unplaced: [ResolveItem] = []
        for item in items {
            guard let pid = item.paragraphId else { whole.append(item); continue }
            guard sequence != nil else { unplaced.append(item); continue }
            if position[pid] == nil { removed.append(item); continue }
            if byParagraph[pid] == nil { paragraphOrder.append(pid) }
            byParagraph[pid, default: []].append(item)
        }
        // Every paragraph here has a position (the unknown went to `unplaced`).
        let placed = paragraphOrder.sorted { (position[$0] ?? .max) < (position[$1] ?? .max) }

        var sections: [ResolveGroup] = []
        if !whole.isEmpty {
            sections.append(ResolveGroup(key: .wholePiece(docId: docId),
                                         title: sceneIndex == nil ? "Whole chapter" : "Whole script",
                                         items: ordered(whole, sequence: order)))
        }
        if !unplaced.isEmpty {
            sections.append(ResolveGroup(key: .unplaced(docId: docId), title: "Position unknown",
                                         items: ordered(unplaced, sequence: order)))
        }
        if let sceneIndex {
            var before: [ResolveItem] = []
            var byScene: [Int: [ResolveItem]] = [:]
            for pid in placed {
                let items = byParagraph[pid] ?? []
                if let scene = sceneIndex[pid] { byScene[scene, default: []] += items } else { before += items }
            }
            if !before.isEmpty {
                sections.append(ResolveGroup(key: .beforeFirstScene(docId: docId),
                                             title: "Before the first scene",
                                             items: ordered(before, sequence: order)))
            }
            // A scene's slugline begins its first paragraph (Fountain needs a
            // blank line before a heading), so that paragraph names the scene.
            var heading: [Int: String] = [:]
            for pid in order { if let scene = sceneIndex[pid], heading[scene] == nil { heading[scene] = pid } }
            for scene in byScene.keys.sorted() {
                // Always found: a placed item's paragraph is in `order`. The
                // fallback keeps the items listed rather than drop them.
                let headingId = heading[scene] ?? "#\(scene)"
                sections.append(ResolveGroup(
                    key: .scene(docId: docId, headingParagraphId: headingId),
                    title: sceneTitles.indices.contains(scene) ? sceneTitles[scene] : "Scene \(scene + 1)",
                    items: ordered(byScene[scene] ?? [], sequence: order)))
            }
        } else {
            for pid in placed {
                sections.append(ResolveGroup(
                    key: .paragraph(docId: docId, paragraphId: pid),
                    title: paragraphTitle(paragraphText[pid]),
                    items: ordered(byParagraph[pid] ?? [], sequence: order)))
            }
        }
        if !removed.isEmpty {
            sections.append(ResolveGroup(key: .removed(docId: docId), title: "No longer in the text",
                                         items: ordered(removed, sequence: order)))
        }
        return sections
    }

    // MARK: - Inside a group

    /// Notes in `AnnotationQueueOrder` (the queue's own rule, reused), then
    /// findings in the reader's order, then to-dos by `priority` (ascending,
    /// as the Tasks pane orders them; ties keep the reader's order).
    private static func ordered(_ items: [ResolveItem], sequence: [String]) -> [ResolveItem] {
        var notes: [ProjectAnnotation] = [], findings: [ResolveItem] = [], todos: [WriterTask] = []
        for item in items {
            switch item {
            case .note(let note): notes.append(note)
            case .finding: findings.append(item)
            case .todo(let task): todos.append(task)
            }
        }
        // Map the sorted annotations back to their ProjectAnnotations, by id
        // in arrival order, so each of two documents' equal ids is listed once.
        var pending: [String: [ProjectAnnotation]] = [:]
        for note in notes { pending[note.annotation.id, default: []].append(note) }
        let sortedNotes: [ResolveItem] = AnnotationQueueOrder
            .sorted(notes.map(\.annotation), sequence: sequence)
            .compactMap { annotation in
                guard var queue = pending[annotation.id], !queue.isEmpty else { return nil }
                let next = queue.removeFirst()
                pending[annotation.id] = queue
                return .note(next)
            }
        let sortedTodos = todos.enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map { ResolveItem.todo($0.element) }
        return sortedNotes + findings + sortedTodos
    }

    /// The paragraph's text as the editor shows it; a placeholder when there
    /// is none to show, never an empty heading.
    private static func paragraphTitle(_ text: String?) -> String {
        guard let text else { return "Text unavailable" }
        let shown = RenderFilter.stripTaskAnchorsInline(text)
        return shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty paragraph" : shown
    }

    private static func pieceTitle(_ docId: String, structure: [StructureItem]) -> String {
        TreeWalk.find(id: docId, in: structure)?.title ?? "Untitled"
    }
}
