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
    /// piece: bound to the piece itself, or one of a region's `cards`.
    case card(PinnedReference)
    /// **A canvas region bound to the piece** (owner, 2026-11-20): one row,
    /// its title and count, opening to its cards in the shelf's order
    /// (`PinnedReferences.readingOrder(ofRegion:in:)`). Its row pulls the
    /// region up; each card row pulls that card up. One entry in the count
    /// past which the fold groups, inside the Cards group.
    case region(id: String, title: String, cards: [PinnedReference])
    case palette(id: String, title: String)
    case figure(id: String, name: String)
    /// `incoming`: the other piece links HERE ("Linked from").
    case link(pieceId: String, title: String, incoming: Bool)

    /// Unique within one fold: the same id may honestly appear as an outgoing
    /// and an incoming link, so the kind is part of it.
    var id: String {
        switch self {
        case .research(let id, _, _): return "research:\(id)"
        case .card(let ref): return "card:\(ref.id)"
        case .region(let id, _, _): return "region:\(id)"
        case .palette(let id, _): return "palette:\(id)"
        case .figure(let id, _): return "figure:\(id)"
        case .link(let pieceId, _, let incoming):
            return incoming ? "linkedFrom:\(pieceId)" : "link:\(pieceId)"
        }
    }

    var group: PieceFoldGroup {
        switch self {
        case .research: return .research
        case .card, .region: return .cards
        case .palette: return .palette
        case .figure: return .figures
        case .link: return .links
        }
    }
}

extension PieceFoldEntry {
    /// **What pulling this row up puts beside** (shell p3): research and a
    /// palette card are research items; a card is what it holds — a research
    /// item, a scrap, a canvas-owned picture; a region is the region; a figure
    /// is the figure (appraisal 8: beside, like every other fold row). A link
    /// travels to its piece, so it is not pulled up.
    var pulledUp: PulledUp? {
        switch self {
        case .research(let id, _, _), .palette(let id, _):
            return .research(id)
        case .region(let id, _, _):
            return .canvasRegion(id: id)
        case .card(let ref):
            switch ref.kind {
            case .research(let itemId): return .research(itemId)
            case .palette(let cardId): return .research(cardId)
            case .scrap(let nodeId): return .canvasScrap(nodeId: nodeId)
            case .photo(let path): return .canvasPhoto(path: path)
            }
        case .figure(let id, _):
            return .figure(id)
        case .link:
            return nil
        }
    }
}

extension PieceFoldEntry {
    /// A region's cards as the rows its chevron opens to; empty for every
    /// other entry.
    var regionCards: [PieceFoldEntry] {
        guard case .region(_, _, let cards) = self else { return [] }
        return cards.map(PieceFoldEntry.card)
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

/// One region row's open/closed state in one piece's fold — the open-ids-only
/// spelling `PieceFoldGroupKey` uses (`BinderTreeSectionsState`).
struct PieceFoldRegionKey: Hashable {
    let docId: String
    let regionId: String
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
        /// The canvas's half: the signal the pulled-up views key on too.
        let canvas: CanvasCardsRevision
    }

    /// docId → that piece's entries, in `PieceFoldGroup` order. A piece absent
    /// here has an empty fold.
    let entries: [String: [PieceFoldEntry]]
    /// docId → how its fold is drawn, worked out once with the entries, so a
    /// row looks its layout up and computes nothing (tripwire 4).
    let layouts: [String: PieceFoldLayout]
    /// Entry id → the glyph its row draws, for a canvas card and a palette
    /// card: **`CanvasItemFacts`' table, the canvas's own**, resolved once with
    /// the entries (`glyph(for:in:)`) so a row looks it up (tripwire 4). The
    /// research glyph table is not spelled again here: a pinned PDF, recording
    /// or picture draws in the fold what it draws on the board.
    let glyphs: [String: String]
    /// Entry id → the project-relative picture its row draws as a thumbnail
    /// (`thumbnailPath(for:in:)`), resolved with the glyphs.
    let thumbnails: [String: String]

    /// - Parameter alwaysGrouped: the pieces whose fold groups at any size
    ///   (`PieceFoldLayout.of(_:alwaysGroups:)`).
    init(entries: [String: [PieceFoldEntry]], alwaysGrouped: Set<String> = [],
         items: CanvasItemIndex = .empty) {
        self.entries = entries
        var glyphs: [String: String] = [:]
        var thumbnails: [String: String] = [:]
        // A region's cards are rows too, under the region's own chevron.
        for row in entries.values.joined().flatMap({ [$0] + $0.regionCards }) {
            if let glyph = Self.glyph(for: row, in: items) { glyphs[row.id] = glyph }
            if let path = Self.thumbnailPath(for: row, in: items) { thumbnails[row.id] = path }
        }
        self.glyphs = glyphs
        self.thumbnails = thumbnails
        var layouts: [String: PieceFoldLayout] = [:]
        for (docId, rows) in entries where !rows.isEmpty {
            layouts[docId] = PieceFoldLayout.of(rows, alwaysGroups: alwaysGrouped.contains(docId))
        }
        self.layouts = layouts
    }

    /// **A scrap is not an item and has no `CanvasItemKind`** — it is words
    /// typed onto the board. Its one glyph of its own, never an item kind's.
    static let scrapGlyph = "note.text"
    /// A region's row: the glyph the region inspector draws for a region.
    static let regionGlyph = "square.dashed"

    /// The glyph of a card or palette row, through `CanvasItemFacts`; nil for
    /// the rows that are not canvas items (research rows are `ResearchRow`'s,
    /// figures and links draw their own).
    static func glyph(for entry: PieceFoldEntry, in items: CanvasItemIndex) -> String? {
        switch entry {
        case .region:
            return regionGlyph
        case .card(let ref):
            switch ref.kind {
            // One arm for both: a palette card IS a research item, told apart
            // by position, and `CanvasItemFacts` reads that off the entry.
            case .research(let id), .palette(let id):
                return CanvasItemFacts.resolve(.project(id: id), in: items).glyph
            case .photo(let path):
                return CanvasItemFacts.resolve(.owned(path: path), in: items).glyph
            case .scrap:
                return scrapGlyph
            }
        case .palette(let id, _):
            return CanvasItemFacts.resolve(.project(id: id), in: items).glyph
        case .research, .figure, .link:
            return nil
        }
    }

    /// **Which fold rows show a thumbnail**: a card that is a picture — a
    /// canvas-owned picture, or a research image the canvas holds — through
    /// `CanvasItemFacts`, which the canvas draws its own pictures from. A
    /// research row's is `ResearchRow`'s; a scrap, a region, a palette pin, a
    /// figure and a link have none.
    static func thumbnailPath(for entry: PieceFoldEntry, in items: CanvasItemIndex) -> String? {
        guard case .card(let ref) = entry else { return nil }
        switch ref.kind {
        case .research(let id):
            return CanvasItemFacts.resolve(.project(id: id), in: items).thumbnailPath
        case .photo(let path):
            return CanvasItemFacts.resolve(.owned(path: path), in: items).thumbnailPath
        case .palette, .scrap:
            return nil
        }
    }

    /// The picture `entry`'s row draws, if any, as resolved with the index.
    func thumbnail(of entry: PieceFoldEntry) -> String? { thumbnails[entry.id] }

    /// The glyph `entry`'s row draws, as resolved when the index was built.
    func glyph(of entry: PieceFoldEntry) -> String {
        glyphs[entry.id] ?? CanvasItemKind.missingGlyph
    }

    /// The layout of `docId`'s fold; nil for an empty fold (no chevron).
    func layout(of docId: String) -> PieceFoldLayout? { layouts[docId] }

    static let empty = PieceFoldIndex(entries: [:])

    @MainActor
    static func key(store: ProjectStore, canvasWrites: Int) -> Key {
        Key(modified: store.manifest.modified,
            canvas: CanvasCardsRevision(sceneRevision: store.liveCanvas?.sceneRevision,
                                        closedCanvasWrites: canvasWrites))
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
        // A promoted region's row holds what the region pulled up shows: the
        // note it became, then its cards (review M2).
        let shelves = PinnedReferenceResolver.shelves(
            forDocIds: documents.map(\.id), store: store, projectRoot: projectRoot,
            promotedRegionsListTheirCards: true)
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
        return PieceFoldIndex(entries: out, alwaysGrouped: grouped,
                              items: CanvasItemIndex.over(research: manifest.research))
    }

    /// One piece's fold, from values. Pure.
    ///
    /// - Research: the shelf's research in shelf order (linked, then derived —
    ///   manifest order), then the research fold's items it has not already
    ///   named. Research a `.contained` fold holds is listed by the fold, as the
    ///   tree draws it (a group root is one row, its contents inside it), and
    ///   is `owned`; everything else is linked.
    /// - Cards: one `.region` per bound region in the shelf's order, holding
    ///   its cards in the shelf's order, then the loose cards.
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

        // A section is a region by its id, never by its title: a region the
        // writer titled "Cards" is not the loose cards.
        for section in shelf.sections {
            var regionCards: [PinnedReference] = []
            for ref in section.references {
                switch ref.kind {
                case .palette(let cardId):
                    if claimed.insert(cardId).inserted {
                        palette.append(.palette(id: cardId, title: ref.title))
                    }
                case .research where section.title == nil:
                    shelfResearch.append(ref)
                case .research, .scrap, .photo:
                    guard claimed.insert(ref.id).inserted else { continue }
                    if section.regionId != nil {
                        regionCards.append(ref)
                    } else {
                        cards.append(.card(ref))
                    }
                }
            }
            if let region = section.regionId, !regionCards.isEmpty {
                cards.append(.region(id: region.raw, title: section.title ?? "",
                                     cards: regionCards))
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

/// **Whether a canvas's cards may have changed** — the one signal the fold
/// index (`PieceFoldIndex.Key`) and every pulled-up canvas read (a card, a
/// region, a region's title) key on, so a fold and what it pulled up refresh
/// together: the canvas's structural revision while it is live (never the
/// per-frame counter, tripwire 30), and the window's count of Claude's writes
/// into a closed canvas's sidecar (`.maughamCanvasNodesAdded`,
/// `BinderTreeSectionsState.closedCanvasWrites`), which moves neither the
/// revision nor the manifest.
struct CanvasCardsRevision: Hashable {
    let sceneRevision: Int?
    let closedCanvasWrites: Int
}
