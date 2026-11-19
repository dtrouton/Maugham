import Foundation
import MaughamCore

/// **What a piece's fold in the tree holds, and how it groups** (shell plan 3,
/// Task 2). The fold is a piece's material: its research, its canvas cards,
/// its palette pins, its own figures and its links in both directions.
///
/// **Nothing here derives membership of its own.** The research and canvas
/// material is the References shelf's (`PinnedReferenceResolver` /
/// `PinnedReferences.pinned`, which already merges a piece's linked, derived
/// and canvas-bound material and drops what the manifest can no longer
/// resolve); which research the piece OWNS is the tree's own research fold
/// (`TreeSectionDerivation.pieceFold`); a figure's owner is
/// `ProjectStore.figureNoteOwners`; and a backlink is `PieceLinks.linkedFrom`,
/// which the old inspector's "Linked from" reads too. This file only merges
/// them, orders them and groups them.

/// One row of a piece's fold.
enum PieceFoldEntry: Identifiable, Equatable {
    /// `owned`: research a Collection piece holds in its own folder; otherwise
    /// shared research the piece links to. The two are drawn differently.
    case research(id: String, title: String, owned: Bool)
    /// A scrap, an owned picture, or a research card the canvas holds for the
    /// piece. `regionTitle` is the bound region's title; nil for a card bound
    /// to the piece itself.
    case card(PinnedReference, regionTitle: String?)
    case palette(id: String, title: String)
    case figure(id: String, name: String)
    /// `incoming`: the other piece links HERE ("Linked from").
    case link(pieceId: String, title: String, incoming: Bool)

    /// Unique within one fold: the same id may honestly appear as an outgoing
    /// and an incoming link, so the kind is part of it.
    var id: String {
        switch self {
        case .research(let id, _, _): return "research:\(id)"
        case .card(let ref, _): return "card:\(ref.id)"
        case .palette(let id, _): return "palette:\(id)"
        case .figure(let id, _): return "figure:\(id)"
        case .link(let pieceId, _, let incoming):
            return incoming ? "linkedFrom:\(pieceId)" : "link:\(pieceId)"
        }
    }

    var group: PieceFoldGroup {
        switch self {
        case .research: return .research
        case .card: return .cards
        case .palette: return .palette
        case .figure: return .figures
        case .link: return .links
        }
    }
}

extension PieceFoldEntry {
    /// **What pulling this row up puts beside** (shell p3): research and a
    /// palette card are research items; a card is what it holds — a research
    /// item, a scrap, a canvas-owned picture. A figure opens in the centre and
    /// a link travels to its piece, so neither is pulled up.
    var pulledUp: PulledUp? {
        switch self {
        case .research(let id, _, _), .palette(let id, _):
            return .research(id)
        case .card(let ref, _):
            switch ref.kind {
            case .research(let itemId): return .research(itemId)
            case .palette(let cardId): return .research(cardId)
            case .scrap(let nodeId): return .canvasScrap(nodeId: nodeId)
            case .photo(let path): return .canvasPhoto(path: path)
            }
        case .figure, .link:
            return nil
        }
    }
}

/// The fold's kinds, in the order the fold lists them.
enum PieceFoldGroup: String, CaseIterable {
    case research, cards, palette, figures, links
}

/// One collapsed group's identity in one piece's fold — what the writer's
/// expand/collapse of a group is keyed on (`BinderTreeSectionsState`).
struct PieceFoldGroupKey: Hashable {
    let docId: String
    let group: PieceFoldGroup
}

/// A non-empty group of a grouped fold; its count is `entries.count`.
struct PieceFoldGroupRun: Equatable {
    let group: PieceFoldGroup
    let entries: [PieceFoldEntry]
}

/// How a fold is drawn: its rows, or past `groupsAbove` entries, collapsed
/// groups with counts.
enum PieceFoldLayout: Equatable {
    case rows([PieceFoldEntry])
    case groups([PieceFoldGroupRun])

    /// The most entries a fold lists as rows.
    static let groupsAbove = 6

    /// `entries` must already be in `PieceFoldGroup` order (`PieceFoldIndex`
    /// produces them so); a group holding nothing is omitted.
    ///
    /// `alwaysGroups`: a single-document project's one piece, whose fold is
    /// every research asset in the project (the shelf's rule) — never a long
    /// flat list there, groups with counts at any size (shell p3 Task 7).
    static func of(_ entries: [PieceFoldEntry], alwaysGroups: Bool = false) -> PieceFoldLayout {
        guard alwaysGroups || entries.count > groupsAbove else { return .rows(entries) }
        return .groups(PieceFoldGroup.allCases.compactMap { group in
            let run = entries.filter { $0.group == group }
            return run.isEmpty ? nil : PieceFoldGroupRun(group: group, entries: run)
        })
    }
}

/// Document-to-document links (`StructureItem.links`), resolved.
enum PieceLinks {
    /// Every item whose `links` name `docId`, in tree order — the old
    /// inspector's "Linked from" and the fold's incoming links, one rule.
    static func linkedFrom(_ docId: String, in structure: [StructureItem]) -> [StructureItem] {
        TreeWalk.collect(in: structure, where: { ($0.links ?? []).contains(docId) })
    }
}

/// **Every piece's fold, computed once per change and looked up per row**
/// (tripwire 4). A tree host builds it in `.task(id: PieceFoldIndex.key(…))`
/// and stores it on `BinderTreeSectionsState.foldIndex`; a row reads
/// `entries[docId]` and computes nothing.
struct PieceFoldIndex: Equatable {

    /// **What invalidates the index, and nothing else.**
    /// - `modified`: the manifest's stamp, which every manifest mutator moves —
    ///   the research index (add, rename, trash, move), linked research and
    ///   palette pins (`linkedResearchIds`), document links (`links`, through
    ///   `updateInspector`), the figure registry, and the structure itself.
    /// - `sceneRevision`: the live canvas's STRUCTURAL revision (binding a card
    ///   or region to a piece, clustering), nil while no canvas is live. Never
    ///   the per-frame redraw counter (tripwire 30). nil → 0 is a change on
    ///   purpose: the live model is ahead of the sidecar.
    /// - `canvasWrites`: the host's count of `.maughamCanvasNodesAdded`, the
    ///   one write into the canvas sidecar while no canvas is live (Claude's
    ///   `add_canvas_scraps`), which moves neither of the above.
    struct Key: Hashable {
        let modified: Date
        let sceneRevision: Int?
        let canvasWrites: Int
    }

    /// docId → that piece's entries, in `PieceFoldGroup` order. A piece absent
    /// here has an empty fold.
    let entries: [String: [PieceFoldEntry]]
    /// docId → how its fold is drawn, worked out once with the entries, so a
    /// row looks its layout up and computes nothing (tripwire 4).
    let layouts: [String: PieceFoldLayout]

    /// - Parameter alwaysGrouped: the pieces whose fold groups at any size
    ///   (`PieceFoldLayout.of(_:alwaysGroups:)`).
    init(entries: [String: [PieceFoldEntry]], alwaysGrouped: Set<String> = []) {
        self.entries = entries
        var layouts: [String: PieceFoldLayout] = [:]
        for (docId, rows) in entries where !rows.isEmpty {
            layouts[docId] = PieceFoldLayout.of(rows, alwaysGroups: alwaysGrouped.contains(docId))
        }
        self.layouts = layouts
    }

    /// The layout of `docId`'s fold; nil for an empty fold (no chevron).
    func layout(of docId: String) -> PieceFoldLayout? { layouts[docId] }

    static let empty = PieceFoldIndex(entries: [:])

    @MainActor
    static func key(store: ProjectStore, canvasWrites: Int) -> Key {
        Key(modified: store.manifest.modified,
            sceneRevision: store.liveCanvas?.sceneRevision,
            canvasWrites: canvasWrites)
    }

    /// Every document's fold. Reads the canvas once (through the shelf's own
    /// resolver) and loads no manuscript. Call only from a tree host's `.task`
    /// (`PieceFoldContentsTests.test_theIndexIsBuiltOnlyInATask`).
    @MainActor
    static func build(store: ProjectStore, projectRoot: URL) -> PieceFoldIndex {
        let manifest = store.manifest
        let documents = TreeWalk.collect(in: manifest.structure, where: { item in
            switch item.type {
            case .document: return true
            case .group: return false
            }
        })
        let shelves = PinnedReferenceResolver.shelves(
            forDocIds: documents.map(\.id), store: store, projectRoot: projectRoot)
        let figures = manifest.figures ?? []
        var out: [String: [PieceFoldEntry]] = [:]
        var grouped = Set<String>()
        for item in documents {
            // A single-document project's piece holds every research asset:
            // its fold groups at any size.
            if case .sharedOnly? = try? ProjectStore.researchRouting(
                for: item, projectType: manifest.type) {
                grouped.insert(item.id)
            }
            let fold = TreeSectionDerivation.pieceFold(
                for: item, structure: manifest.structure,
                research: manifest.research, projectType: manifest.type)
            let rows = entries(docId: item.id,
                               shelf: shelves[item.id] ?? PinnedShelf(sections: []),
                               fold: fold, figures: figures, links: item.links ?? [],
                               structure: manifest.structure, research: manifest.research)
            if !rows.isEmpty { out[item.id] = rows }
        }
        return PieceFoldIndex(entries: out, alwaysGrouped: grouped)
    }

    /// One piece's fold, from values. Pure.
    ///
    /// - Research: the shelf's research in shelf order (linked, then derived —
    ///   manifest order), then the research fold's items it has not already
    ///   named. Research a `.contained` fold holds is listed by the fold, as the
    ///   tree draws it (a group root is one row, its contents inside it), and
    ///   is `owned`; everything else is linked.
    /// - Cards: the shelf's bound regions in its order, then loose cards.
    /// - Palette: palette cards wherever the shelf met them.
    /// - Figures: the piece's own (`ProjectStore.figureNoteOwners`), by name.
    /// - Links: `links` in order, then the pieces linking here; a link to a
    ///   piece no longer in `structure` is dropped, as the shelf drops a
    ///   reference it cannot resolve.
    ///
    /// One id appears once: a card's or palette pin's claim comes first (a
    /// region-promoted note belongs to its region, the shelf's own rule).
    static func entries(docId: String, shelf: PinnedShelf,
                        fold: TreeSectionDerivation.PieceFold,
                        figures: [FigureRecord], links: [String],
                        structure: [StructureItem],
                        research: [ResearchItem]) -> [PieceFoldEntry] {
        guard let item = TreeWalk.find(id: docId, in: structure),
              hasAFold(item) else { return [] }

        var claimed = Set<String>()
        var cards: [PieceFoldEntry] = []
        var palette: [PieceFoldEntry] = []
        var shelfResearch: [PinnedReference] = []

        // The shelf closes the loose cards' section last, under one fixed title.
        let looseIndex = shelf.sections.lastIndex {
            $0.title != nil && $0.title == PinnedShelf.looseCardsTitle
        }
        for (index, section) in shelf.sections.enumerated() {
            let regionTitle = index == looseIndex ? nil : section.title
            for ref in section.references {
                switch ref.kind {
                case .palette(let cardId):
                    if claimed.insert(cardId).inserted {
                        palette.append(.palette(id: cardId, title: ref.title))
                    }
                case .research where section.title == nil:
                    shelfResearch.append(ref)
                case .research, .scrap, .photo:
                    if claimed.insert(ref.id).inserted {
                        cards.append(.card(ref, regionTitle: regionTitle))
                    }
                }
            }
        }

        let owns = fold.semantic == .contained
        var researchRows: [PieceFoldEntry] = []
        for ref in shelfResearch {
            // What a contained fold holds is listed below, as its root.
            if owns && TreeWalk.contains(id: ref.id, in: fold.items) { continue }
            if claimed.insert(ref.id).inserted {
                researchRows.append(.research(id: ref.id, title: ref.title, owned: false))
            }
        }
        for root in fold.items where claimed.insert(root.id).inserted {
            researchRows.append(.research(id: root.id, title: root.title, owned: owns))
        }

        let owners = ProjectStore.figureNoteOwners(figures)
        let figureRows: [PieceFoldEntry] = figures
            .filter { owners[$0.id] == .some(docId) }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            .map { .figure(id: $0.id, name: $0.name) }

        var linkRows: [PieceFoldEntry] = []
        var seenOut = Set<String>()
        for target in links where target != docId && seenOut.insert(target).inserted {
            guard let piece = TreeWalk.find(id: target, in: structure) else { continue }
            linkRows.append(.link(pieceId: piece.id, title: piece.title, incoming: false))
        }
        for source in PieceLinks.linkedFrom(docId, in: structure) where source.id != docId {
            linkRows.append(.link(pieceId: source.id, title: source.title, incoming: true))
        }

        return researchRows + cards + palette + figureRows + linkRows
    }

    /// A Collection reference piece lives in another project and has no fold
    /// here; every other document does.
    private static func hasAFold(_ item: StructureItem) -> Bool {
        switch item.type {
        case .group: return false
        case .document:
            switch item.pieceKind {
            case .reference: return false
            case .loose, .none: return true
            }
        }
    }
}
