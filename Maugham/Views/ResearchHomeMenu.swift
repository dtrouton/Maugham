import Foundation
import MaughamCore

/// **A research row's words for where it belongs** (shell p5 Task 4a): the
/// drags' meaning, in a menu. A Research-section row offers **Move to
/// Chapter ▸** (it leaves the book for that chapter); a row a chapter links
/// offers **Move to Chapter ▸** (from this chapter to that one), **Make
/// Whole-Book** (back to the Research section) and, where another chapter links
/// it too, **Remove from “This”** and a line saying which others hold it.
///
/// Link edits, never file moves: a novel's research lives where it is and a
/// chapter links it, so nothing here goes through the typed mover (tripwire
/// 14). Each target is one the posture lets this Mac change (`mayLink`, the
/// structure door "Link Research…" asks); a verb the posture refuses is not
/// offered. A Collection's own research keeps its file moves (`Move to ▸`).
/// Which piece is whose is `ResearchHomes`' answer, asked. Pure.
struct ResearchHomeMenu: Equatable {
    enum Verb: Equatable {
        case link(researchId: String, to: String)
        case move(researchId: String, from: String, to: String)
        case unlink(researchId: String, from: [String])
    }

    struct Item: Equatable, Identifiable {
        let title: String
        let verb: Verb
        /// Keyed on what the item does — its target piece — never its title:
        /// two chapters may share one (fix round 2, OOS3).
        var id: String {
            switch verb {
            case .link(_, let to): return "link:" + to
            case .move(_, let from, let to): return "move:\(from)>\(to)"
            case .unlink(_, let from): return "unlink:" + from.joined(separator: ",")
            }
        }
    }

    /// **Move to Chapter ▸, in the tree's own shape** (fix round 1, M10): a
    /// submenu per Part, its chapters and its Parts inside, so a book of two
    /// hundred chapters is chosen from as it is read; a book without Parts is
    /// a flat list.
    indirect enum MoveNode: Equatable, Identifiable {
        case target(Item)
        case part(id: String, title: String, children: [MoveNode])
        var id: String {
            switch self {
            case .target(let item): return "target:" + item.id
            case .part(let id, _, _): return "part:" + id
            }
        }
    }

    /// The targets nested under their Parts, in tree order. Pure.
    static func tree(_ items: [Item], parts: (String) -> [StructureItem]) -> [MoveNode] {
        func insert(_ item: Item, along path: ArraySlice<StructureItem>, into nodes: inout [MoveNode]) {
            guard let part = path.first else { nodes.append(.target(item)); return }
            if case .part(let id, let title, var children)? = nodes.last, id == part.id {
                insert(item, along: path.dropFirst(), into: &children)
                nodes[nodes.count - 1] = .part(id: id, title: title, children: children)
            } else {
                var children: [MoveNode] = []
                insert(item, along: path.dropFirst(), into: &children)
                nodes.append(.part(id: part.id, title: part.title, children: children))
            }
        }
        var nodes: [MoveNode] = []
        for item in items {
            let piece: String
            switch item.verb {
            case .link(_, let to), .move(_, _, let to): piece = to
            case .unlink: continue
            }
            insert(item, along: parts(piece)[...], into: &nodes)
        }
        return nodes
    }


    /// "Move to Chapter" — the submenu's title, in the project's own noun.
    let moveTitle: String
    /// One item per chapter the note may move to, in tree order.
    let moveTargets: [Item]
    /// "Remove from “Three”", where another chapter keeps it.
    let removeFromThis: Item?
    /// "Make Whole-Book": every link the note has goes.
    let makeWholeBook: Item?
    /// "Also in “Five”" — the other chapters holding it, named.
    let alsoIn: String?
    /// `moveTargets`, nested by Part.
    let moveTree: [MoveNode]

    static let makeWholeBookTitle = "Make Whole-Book"

    static func moveTitle(noun: String) -> String { "Move to \(noun.capitalized)" }
    static func removeTitle(_ piece: String) -> String { "Remove from “\(piece)”" }
    static func alsoInLine(_ pieces: [String]) -> String {
        "Also in " + pieces.map { "“\($0)”" }.joined(separator: ", ")
    }

    /// The menu `itemId`'s row offers, drawn in `fold`'s fold (nil: the
    /// Research section), or nil where it offers none.
    static func of(itemId: String, inFold fold: String?, homes: ResearchHomes,
                   noun: String, mayLink: (String) -> Bool) -> ResearchHomeMenu? {
        func title(_ piece: String) -> String { homes.pieceTitles[piece] ?? piece }
        let homesOfItem = homes.homes(of: itemId)
        let movable = homes.pieceOrder.filter {
            homes.takesLinks($0) && !homesOfItem.contains($0) && mayLink($0)
        }
        guard let fold else {
            guard homes.isWholeBook(itemId) else { return nil }
            let targets = movable.map {
                Item(title: title($0), verb: .link(researchId: itemId, to: $0))
            }
            guard !targets.isEmpty else { return nil }
            return ResearchHomeMenu(moveTitle: moveTitle(noun: noun), moveTargets: targets,
                                    removeFromThis: nil, makeWholeBook: nil, alsoIn: nil,
                                    moveTree: tree(targets, parts: homes.parts(of:)))
        }
        // Only a row this fold LINKS: an item filed in a Collection piece's
        // folder, or inside a group the chapter links, moves with its file or
        // its group.
        let links = homes.links(of: itemId)
        guard links.contains(fold), mayLink(fold) else { return nil }
        let others = homesOfItem.filter { $0 != fold }
        let targets = homes.takesLinks(fold) ? movable.map {
            Item(title: title($0), verb: .move(researchId: itemId, from: fold, to: $0))
        } : []
        let whole: Item?
        if Set(links) == Set(homesOfItem), links.allSatisfy(mayLink) {
            whole = Item(title: makeWholeBookTitle, verb: .unlink(researchId: itemId, from: links))
        } else {
            whole = nil
        }
        return ResearchHomeMenu(
            moveTitle: moveTitle(noun: noun), moveTargets: targets,
            removeFromThis: others.isEmpty
                ? nil : Item(title: removeTitle(title(fold)), verb: .unlink(researchId: itemId, from: [fold])),
            makeWholeBook: whole,
            alsoIn: others.isEmpty ? nil : alsoInLine(others.map(title)),
            moveTree: tree(targets, parts: homes.parts(of:)))
    }
}

/// **A Research-section group's Delete or Move, when a piece holds something
/// beneath it** (fix round 1, the owner's ruling on I2): the verb acts only
/// on what the section draws under the row, and the question says plainly
/// what goes and what stays before anything does.
///
/// - **Delete** trashes the whole-book subtrees (`ResearchHomes.Take.taken`);
///   what a piece holds is not touched, and the group stays on as their
///   group — drawn nowhere once it holds only theirs (`isContainer`), its
///   name still in their place ("World / Maps"). No file of theirs moves.
/// - **Move** lifts what pieces hold out of the group first, to where the
///   group stands, then moves the group: it arrives with its whole-book
///   research, and they stay with their pieces.
///
/// Nil where nothing beneath the rows is a piece's: the verb is the plain
/// one. Pure.
struct HeldResearchAct: Equatable {
    enum Verb: Equatable {
        case delete
        case move(ResearchMoveTarget, landing: Landing)
    }

    /// **Where moved rows land among their new siblings** — named, not an
    /// index, so it is found again on the tree as it stands when the move is
    /// made, after any lift (fix round 3, c).
    enum Landing: Equatable {
        /// After the last sibling (the mover's `nil` index).
        case end
        /// Before the first (a drop into a group's middle).
        case head
        /// Above or below the row the drop was aimed beside.
        case beside(rowId: String, position: DropIntent.Position)

        /// The mover's index for `movingIds` landing in `target` in
        /// `research` now; nil appends — also where the row it was beside has
        /// gone, or now stands under another parent (closing round A): never
        /// an index read off one container and applied to another.
        func index(movingIds: [String], to target: ResearchMoveTarget,
                   in research: [ResearchItem]) -> Int? {
            switch self {
            case .end: return nil
            case .head: return 0
            case .beside(let rowId, let position):
                guard TreeWalk.contains(id: rowId, in: research) else { return nil }
                let parent = TreeWalk.first(in: research, where: {
                    ($0.children ?? []).contains { $0.id == rowId } })
                switch target {
                case .group(let group): guard parent?.id == group else { return nil }
                case .sharedRoot, .piece: guard parent == nil else { return nil }
                }
                return ResearchSelectionSync.postRemovalInsertionIndex(
                    targetId: rowId, position: position, movingIds: movingIds,
                    siblings: parent?.children ?? research)
            }
        }
    }

    /// The held items under one row, lifted to where that row stands.
    struct Lift: Equatable {
        let ids: [String]
        let to: ResearchMoveTarget
    }

    let verb: Verb
    /// The rows the writer acted on.
    let ids: [String]
    let take: ResearchHomes.Take
    let lifts: [Lift]
    let title: String
    let message: String
    let confirmTitle: String
    /// What a Move that lifted, then failed to move the rows, has done —
    /// the alert's first words (fix round 2, NB3).
    let afterLift: String

    /// `noun`: the project's word for a piece ("chapter").
    static func of(_ verb: Verb, ids: [String], homes: ResearchHomes,
                   research: [ResearchItem], structure: [StructureItem],
                   noun: String) -> HeldResearchAct? {
        func parent(of id: String) -> String? {
            TreeWalk.first(in: research, where: { ($0.children ?? []).contains { $0.id == id } })?.id
        }
        // **A move asks only for Research-section rows, and only when they
        // change parent** (fix round 3, a + e). A fold row's move is the
        // plain move: a link is held by id, so moving a chapter's group never
        // changes which chapters hold what is in it. A same-parent reorder of
        // a section group changes nothing about the chapters' notes either.
        // Delete keeps the "beyond the row's own pieces" rule for every row.
        let acted: [String]
        switch verb {
        case .delete:
            acted = ids
        case .move(let target, _):
            acted = ids.filter { homes.homes(of: $0).isEmpty }
            let stays = acted.allSatisfy { id in
                switch target {
                case .group(let group): return parent(of: id) == group
                case .sharedRoot: return parent(of: id) == nil
                case .piece: return false
                }
            }
            if stays { return nil }
        }
        let take = homes.take(acted, in: research)
        guard !take.held.isEmpty else { return nil }
        func title(_ id: String) -> String { TreeWalk.find(id: id, in: research)?.title ?? id }
        // Lifted to where the row stood — its group, a Collection piece's
        // own folder, or the Research root — for a Move and (no ghost group,
        // closing round A) a Delete alike.
        var lifts: [Lift] = []
        for id in acted where take.staying.contains(id) {
            guard let row = TreeWalk.find(id: id, in: research) else { continue }
            let under = take.held.filter { TreeWalk.contains(id: $0, in: row.children ?? []) }
            guard !under.isEmpty else { continue }
            let to: ResearchMoveTarget = parent(of: id).map { .group($0) }
                ?? homes.owner(of: id).map { .piece($0) } ?? .sharedRoot
            lifts.append(Lift(ids: under, to: to))
        }
        let named = ids.count == 1 ? "“\(title(ids[0]))”" : "\(ids.count) items"
        // The pieces the rows are drawn under (a fold's row) are not the ones
        // that keep what is held: name the others.
        let own = Set(ids.flatMap { homes.homes(of: $0) })
        func chapters(of id: String) -> String {
            let pieces = homes.homes(of: id).filter { !own.contains($0) }.map { homes.pieceTitles[$0] ?? $0 }
            return pieces.count < 2 ? pieces.joined()
                : pieces.dropLast().joined(separator: ", ") + " and " + pieces.last!
        }
        // **One plain sentence** (closing round A addendum): one note named
        // with its chapter; several, up to three named with theirs, then
        // "and N more".
        let stays: String
        if take.held.count == 1, let id = take.held.first {
            stays = "“\(title(id))” stays with \(chapters(of: id))"
        } else {
            let shown = take.held.prefix(3).map { "“\(title($0))” (\(chapters(of: $0)))" }
            let more = take.held.count - shown.count
            let list = more > 0
                ? shown.joined(separator: ", ") + " and \(more) more"
                : shown.dropLast().joined(separator: ", ") + " and " + shown.last!
            stays = "\(list) stay with their \(noun)s"
        }
        switch verb {
        case .delete:
            return HeldResearchAct(
                verb: verb, ids: ids, take: take, lifts: lifts,
                title: "Delete \(named)?",
                message: "\(stays); the rest of \(named) goes to the Trash.",
                confirmTitle: "Delete", afterLift: "")
        case .move(let target, _):
            let to: String
            switch target {
            case .sharedRoot: to = "Research"
            case .group(let id): to = "“\(title(id))”"
            case .piece(let id): to = "“\(TreeWalk.find(id: id, in: structure)?.title ?? id)”"
            }
            return HeldResearchAct(
                verb: verb, ids: ids, take: take, lifts: lifts,
                title: "Move \(named) to \(to)?",
                message: "\(stays); the rest of \(named) moves to \(to).",
                confirmTitle: "Move",
                afterLift: "The \(noun)s’ notes were lifted out of \(named), but \(named) couldn’t be moved: ")
        }
    }
}
