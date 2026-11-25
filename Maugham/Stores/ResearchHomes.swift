import Foundation
import MaughamCore

/// **Whose a research item is: the book's, or a piece's** (shell p5 Task 4a,
/// the owner's ruling of 2026-11-22: "In the old layout research was either
/// top level or under a chapter/piece"). Either/or, and this is the one answer:
/// the tree's Research section, every piece's fold, the reveal routes, the
/// drops, the row menus and the read-through gate all ask it, and none restates
/// it (`ResearchHomesTests.test_noTreeSurfaceRestatesWhereResearchLives`).
///
/// **An item's homes are the pieces whose fold draws a row for it**: a piece
/// whose folder holds it (a Collection's own research, through its top-level
/// item's path — `ProjectStore.researchScopePieceId`), a piece that links it
/// (`linkedResearchIds`), and every home of the group it sits in (a fold draws
/// a group whole, so a linked group's items are that piece's too). A home is a
/// LIVE piece: a document in the structure whose research routing keeps a fold
/// of its own (`ProjectStore.researchRouting` — `.pieceFolder` or
/// `.sharedPlusLink`). A link held by a piece the structure no longer has (it
/// went to the Trash, and its links with it) is no home, so the item falls back
/// to the book; restoring the piece restores its `linkedResearchIds`, and the
/// item goes back under it — a manual link never dies of its piece's absence
/// (the dormant-link semantics, `ProjectStore+ResearchMove`).
///
/// **Whole-book** is an item with no home that is not the palette's (the
/// Palette section draws those). The Research section draws exactly the
/// whole-book items, in place (`wholeBook`: the research tree with every
/// homed item filtered out of its group, never moved); a piece's fold draws its
/// `foldRoots` — each item homed there whose group is not — and their groups
/// whole beneath them. So every item has a row: a whole-book item in the
/// section (its groups are whole-book too, since a group's homes are its
/// items'), a homed one under each home (`ResearchHomesTests`' property test)
/// — save a whole-book group holding only pieces' items, which is their
/// group on disk and drawn nowhere (`isContainer`).
///
/// Pure, over manifest values: one walk of the structure and one of the
/// research tree (`visited`), cached by the window per manifest
/// (`ResearchHomesCache`) and never computed per row (tripwire 4).
struct ResearchHomes {
    /// The Research section's rows: the research tree, palette group out, each
    /// group's homed items filtered out of it.
    let wholeBook: [ResearchItem]
    /// The pieces that keep a fold of their own, in tree order.
    let pieceOrder: [String]
    /// Each of those pieces' titles.
    let pieceTitles: [String: String]
    /// How many structure and research nodes the derivation visited — one each.
    let visited: Int

    private let homesById: [String: [String]]
    private let linksById: [String: [String]]
    private let ownerById: [String: String]
    private let rootsByPiece: [String: [ResearchItem]]
    private let rootIdsByPiece: [String: Set<String>]
    private let placeById: [String: String]
    private let wholeBookIds: Set<String>
    private let pieceRank: [String: Int]
    private let linkingPieces: Set<String>
    /// Whole-book groups drawn nowhere: each holds only what pieces hold.
    private let containerIds: Set<String>
    /// Each piece's Parts, outermost first (`parts(of:)`).
    private let partsByPiece: [String: [StructureItem]]

    static let empty = ResearchHomes(
        wholeBook: [], pieceOrder: [], pieceTitles: [:], visited: 0, homesById: [:],
        linksById: [:], ownerById: [:], rootsByPiece: [:], placeById: [:],
        wholeBookIds: [], pieceRank: [:], linkingPieces: [], containerIds: [],
        partsByPiece: [:])

    private init(wholeBook: [ResearchItem], pieceOrder: [String], pieceTitles: [String: String],
                 visited: Int, homesById: [String: [String]], linksById: [String: [String]],
                 ownerById: [String: String], rootsByPiece: [String: [ResearchItem]],
                 placeById: [String: String], wholeBookIds: Set<String>, pieceRank: [String: Int],
                 linkingPieces: Set<String>, containerIds: Set<String>,
                 partsByPiece: [String: [StructureItem]]) {
        self.containerIds = containerIds
        self.rootIdsByPiece = rootsByPiece.mapValues { Set($0.map(\.id)) }
        self.partsByPiece = partsByPiece
        self.wholeBook = wholeBook
        self.pieceOrder = pieceOrder
        self.pieceTitles = pieceTitles
        self.visited = visited
        self.homesById = homesById
        self.linksById = linksById
        self.ownerById = ownerById
        self.rootsByPiece = rootsByPiece
        self.placeById = placeById
        self.wholeBookIds = wholeBookIds
        self.pieceRank = pieceRank
        self.linkingPieces = linkingPieces
    }

    // MARK: - The questions

    /// **The predicate**: the book's — in the Research section, under no piece.
    func isWholeBook(_ id: String) -> Bool { wholeBookIds.contains(id) }

    /// The pieces whose fold draws `id`, in tree order; empty for a whole-book
    /// item, a palette card and an id the research tree does not hold.
    func homes(of id: String) -> [String] { homesById[id] ?? [] }

    /// The live pieces that link `id` itself, in tree order (not through its group).
    func links(of id: String) -> [String] { linksById[id] ?? [] }

    /// The piece whose own folder holds `id` (a Collection's), or nil.
    func owner(of id: String) -> String? { ownerById[id] }

    /// The rows at the top of `piece`'s research: each item homed there whose
    /// group is not, in research-tree order.
    func foldRoots(of piece: String) -> [ResearchItem] { rootsByPiece[piece] ?? [] }

    /// **The chapters a move of `id` to `target` would take it away from**
    /// (fix round 3): a chapter that holds it through a group above it, which
    /// the destination is not inside. A link is held by id, so a note's own
    /// links never go; only what it inherits from where it stands can. A
    /// Collection piece's own folder is its file's place, moved on purpose
    /// (a rescope), so only linking pieces count. Empty: the move changes no
    /// chapter's hold. Pure.
    func chaptersLost(moving id: String, to target: ResearchMoveTarget,
                      in research: [ResearchItem]) -> [String] {
        guard let parent = TreeWalk.first(in: research, where: {
            ($0.children ?? []).contains { $0.id == id } }) else { return [] }
        let keeps: Set<String>
        switch target {
        case .group(let group): keeps = Set(homes(of: group))
        case .sharedRoot, .piece: keeps = []
        }
        return homes(of: parent.id).filter { takesLinks($0) && !keeps.contains($0) }
    }

    /// Whether `id` is a root row of `piece`'s fold — a lookup, for a row.
    func isFoldRoot(_ id: String, of piece: String) -> Bool {
        rootIdsByPiece[piece]?.contains(id) ?? false
    }

    /// Where a fold's root row sits in the research tree — its groups, outer
    /// first ("World / Maps") — or nil at the top. A linked note inside a
    /// whole-book group is drawn flat under the chapter, and this names the
    /// group it lives in, so the writer knows where it is when it goes back.
    func place(of id: String) -> String? { placeById[id] }

    /// **The one fold a reveal opens, and the row a selection draws there**:
    /// the open piece's when it is a home, else the first home in tree order.
    func preferredFold(of id: String, openPiece: String?) -> String? {
        let homes = homes(of: id)
        if let openPiece, homes.contains(openPiece) { return openPiece }
        return homes.first
    }

    /// Whether `piece` keeps a fold of its own (a research home can be one).
    func isAHome(_ piece: String) -> Bool { pieceRank[piece] != nil }

    /// Whether `piece`'s research is LINKED, not filed in a folder of its own
    /// (a novel's chapter, `.sharedPlusLink`): what a link verb may target.
    func takesLinks(_ piece: String) -> Bool { linkingPieces.contains(piece) }

    /// **A whole-book group that holds only what pieces hold** (fix round 1,
    /// the owner's ruling on I2): it stays on disk as their group — their
    /// place reads "World / Maps" — and is drawn nowhere, so no group in the
    /// Research section looks empty while carrying notes. A genuinely empty
    /// group is not one: it holds nothing at all, and is drawn.
    func isContainer(_ id: String) -> Bool { containerIds.contains(id) }

    /// The Parts above `piece`, outermost first (`ResearchHomeMenu`'s nesting).
    func parts(of piece: String) -> [StructureItem] { partsByPiece[piece] ?? [] }

    /// **What a verb on rows aimed at `ids` acts on** (fix round 1, I2; round
    /// 2): a row acts only on what is drawn under it. An item beneath it that
    /// a piece holds beyond the row's own pieces is `held` — it stays, whole,
    /// with that piece — and every group with such an item anywhere beneath
    /// it, however deep, `stays` as their group; every other subtree is
    /// `taken` whole. A Research-section row has no pieces of its own, so
    /// any piece's item beneath it is held; a fold row's linked group holds
    /// a note another chapter links directly. Pure; ids in visit order, each
    /// once.
    struct Take: Equatable {
        var taken: [String] = []
        var held: [String] = []
        var staying: [String] = []
    }

    func take(_ ids: [String], in research: [ResearchItem]) -> Take {
        var out = Take()
        var seen = Set<String>()
        func isHeld(_ item: ResearchItem, beyond own: Set<String>) -> Bool {
            !Set(homes(of: item.id)).isSubset(of: own)
        }
        func holds(_ item: ResearchItem, beyond own: Set<String>) -> Bool {
            (item.children ?? []).contains { isHeld($0, beyond: own) || holds($0, beyond: own) }
        }
        func visit(_ item: ResearchItem, own: Set<String>) {
            guard seen.insert(item.id).inserted else { return }
            if isHeld(item, beyond: own) { out.held.append(item.id); return }
            guard holds(item, beyond: own) else { out.taken.append(item.id); return }
            out.staying.append(item.id)
            for child in item.children ?? [] { visit(child, own: own) }
        }
        // A fold's row first: chosen there, it is acted on as its fold's.
        let found = ids.compactMap { TreeWalk.find(id: $0, in: research) }
        let ordered = found.filter { !homes(of: $0.id).isEmpty } + found.filter { homes(of: $0.id).isEmpty }
        for item in ordered { visit(item, own: Set(homes(of: item.id))) }
        // A row inside a subtree already taken goes with it.
        var under = Set<String>()
        for item in out.taken.compactMap({ TreeWalk.find(id: $0, in: research) }) {
            for inner in TreeWalk.collect(in: item.children ?? [], where: { _ in true }) {
                under.insert(inner.id)
            }
        }
        out.taken = out.taken.filter { !under.contains($0) }
        return out
    }

    // MARK: - The derivation

    /// One walk of each tree. `projectType` decides which documents keep a fold
    /// (`ProjectStore.researchRouting`, asked and never restated).
    static func derive(structure: [StructureItem], research: [ResearchItem],
                       projectType: ProjectType) -> ResearchHomes {
        var visited = 0
        var pieceOrder: [String] = []
        var pieceTitles: [String: String] = [:]
        var pieceRank: [String: Int] = [:]
        var linkers: [String: [String]] = [:]
        /// Each piece's links, by the order it made them.
        var linkOrder: [String: [String: Int]] = [:]
        var linkingPieces = Set<String>()
        var partsByPiece: [String: [StructureItem]] = [:]
        func walkStructure(_ items: [StructureItem], parts: [StructureItem] = []) {
            for item in items {
                visited += 1
                if item.type == .document, let routing = try? ProjectStore.researchRouting(
                    for: item, projectType: projectType) {
                    switch routing {
                    case .pieceFolder, .sharedPlusLink:
                        if case .sharedPlusLink = routing { linkingPieces.insert(item.id) }
                        pieceRank[item.id] = pieceOrder.count
                        pieceOrder.append(item.id)
                        pieceTitles[item.id] = item.title
                        if !parts.isEmpty { partsByPiece[item.id] = parts }
                        for (index, rid) in (item.linkedResearchIds ?? []).enumerated()
                        where linkers[rid]?.contains(item.id) != true {
                            linkers[rid, default: []].append(item.id)
                            linkOrder[item.id, default: [:]][rid] = index
                        }
                    case .sharedOnly:
                        break
                    }
                }
                walkStructure(item.children ?? [],
                              parts: item.type == .group ? parts + [item] : parts)
            }
        }
        walkStructure(structure)

        // A piece's own folder is a Collection's alone (`holdsPieces`).
        let folders = projectType.holdsPieces ? ProjectStore.researchFolders(in: structure) : []
        let paletteId = PaletteLookup.paletteGroup(in: research)?.id
        var homesById: [String: [String]] = [:]
        var linksById: [String: [String]] = [:]
        var ownerById: [String: String] = [:]
        var rootsByPiece: [String: [ResearchItem]] = [:]
        var placeById: [String: String] = [:]
        var wholeBookIds = Set<String>()
        var containerIds = Set<String>()

        func ranked(_ pieces: Set<String>) -> [String] {
            pieces.sorted { (pieceRank[$0] ?? .max) < (pieceRank[$1] ?? .max) }
        }

        /// The item's whole-book copy (its homed children filtered out), or nil
        /// where it is homed.
        func visit(_ item: ResearchItem, inherited: Set<String>, owner: String?,
                   groups: [String]) -> ResearchItem? {
            visited += 1
            let links = (linkers[item.id] ?? []).filter { pieceRank[$0] != nil }
            var homes = inherited.union(links)
            if let owner { homes.insert(owner); ownerById[item.id] = owner }
            if !links.isEmpty { linksById[item.id] = links }
            let kept = (item.children ?? []).compactMap {
                visit($0, inherited: homes, owner: owner, groups: groups + [item.title])
            }
            guard homes.isEmpty else {
                let ordered = ranked(homes)
                homesById[item.id] = ordered
                for piece in ordered where !inherited.contains(piece) {
                    rootsByPiece[piece, default: []].append(item)
                }
                if !groups.isEmpty, ordered.contains(where: { !inherited.contains($0) }) {
                    placeById[item.id] = groups.joined(separator: " / ")
                }
                return nil
            }
            let children = item.children ?? []
            // Every child is a piece's (or such a group): a container, drawn
            // nowhere (`isContainer`).
            if !children.isEmpty, kept.isEmpty {
                containerIds.insert(item.id)
                return nil
            }
            wholeBookIds.insert(item.id)
            var copy = item
            if item.children != nil { copy.children = kept }
            return copy
        }

        var wholeBook: [ResearchItem] = []
        for root in research where root.id != paletteId {
            let owner = ProjectStore.researchScopePieceId(ofPath: root.path, in: folders)
                .flatMap { pieceRank[$0] != nil ? $0 : nil }
            if let copy = visit(root, inherited: [], owner: owner, groups: []) {
                wholeBook.append(copy)
            }
        }
        // A fold lists what the piece links in the order it linked them, then
        // the rest in the research tree's order.
        for (piece, roots) in rootsByPiece {
            guard let order = linkOrder[piece] else { continue }
            rootsByPiece[piece] = roots.enumerated().sorted { a, b in
                let ra = order[a.element.id] ?? .max, rb = order[b.element.id] ?? .max
                return ra == rb ? a.offset < b.offset : ra < rb
            }.map(\.element)
        }
        return ResearchHomes(
            wholeBook: wholeBook, pieceOrder: pieceOrder, pieceTitles: pieceTitles,
            visited: visited, homesById: homesById, linksById: linksById,
            ownerById: ownerById, rootsByPiece: rootsByPiece, placeById: placeById,
            wholeBookIds: wholeBookIds, pieceRank: pieceRank, linkingPieces: linkingPieces,
            containerIds: containerIds, partsByPiece: partsByPiece)
    }
}

/// **The window's `ResearchHomes`, derived once per manifest** (tripwire 4):
/// a body or a getter asks it as often as it likes, and the derivation runs
/// only when the structure, the research or the kind changed. The key is the
/// manifest's own values — an unchanged array compares by its storage, so the
/// common case costs no walk at all.
@MainActor
final class ResearchHomesCache {
    private var key: (structure: [StructureItem], research: [ResearchItem], type: ProjectType)?
    private var value = ResearchHomes.empty
    /// How many times this cache derived — the cost pin's count.
    private(set) var derivations = 0
    /// How many times a lookup had to compare contents, its arrays not the
    /// ones the key holds — an equal manifest in new buffers (an adopted
    /// one). The key then takes the new buffers, so it happens once (M3).
    private(set) var contentCompares = 0

    func homes(structure: [StructureItem], research: [ResearchItem],
               projectType: ProjectType) -> ResearchHomes {
        if let key, key.type == projectType {
            if Self.sameBuffer(key.structure, structure), Self.sameBuffer(key.research, research) {
                return value
            }
            contentCompares += 1
            if key.structure == structure, key.research == research {
                self.key = (structure, research, projectType)
                return value
            }
        }
        value = ResearchHomes.derive(structure: structure, research: research,
                                     projectType: projectType)
        key = (structure, research, projectType)
        derivations += 1
        return value
    }

    /// Whether two arrays share one buffer — the comparison that costs nothing.
    private static func sameBuffer<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress }
        }
    }
}
