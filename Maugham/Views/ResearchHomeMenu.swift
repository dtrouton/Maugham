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
        case move(ResearchMoveTarget, atIndex: Int?)
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
        let take = homes.take(ids, in: research)
        guard !take.held.isEmpty else { return nil }
        func title(_ id: String) -> String { TreeWalk.find(id: id, in: research)?.title ?? id }
        func parent(of id: String) -> String? {
            TreeWalk.first(in: research, where: { ($0.children ?? []).contains { $0.id == id } })?.id
        }
        var lifts: [Lift] = []
        if case .move = verb {
            for id in ids where take.staying.contains(id) {
                guard let row = TreeWalk.find(id: id, in: research) else { continue }
                let under = take.held.filter { TreeWalk.contains(id: $0, in: row.children ?? []) }
                guard !under.isEmpty else { continue }
                lifts.append(Lift(ids: under, to: parent(of: id).map { .group($0) } ?? .sharedRoot))
            }
        }
        let named = ids.count == 1 ? "“\(title(ids[0]))”" : "\(ids.count) items"
        // The pieces the rows are drawn under (a fold's row) are not the ones
        // that keep what is held: name the others.
        let own = Set(ids.flatMap { homes.homes(of: $0) })
        let kept = take.held.map { id -> String in
            let pieces = homes.homes(of: id).filter { !own.contains($0) }
                .map { homes.pieceTitles[$0] ?? $0 }
            return "“\(title(id))” (\(pieces.joined(separator: ", ")))"
        }
        let keptLine = kept.count == 1
            ? "\(kept[0]) is a \(noun)’s and stays with it"
            : "\(kept.dropLast().joined(separator: ", ")) and \(kept.last!) are \(noun)s’ and stay with them"
        switch verb {
        case .delete:
            let goes = take.taken.isEmpty
                ? "Nothing else is under it to delete."
                : own.isEmpty ? "Its whole-book research goes to the Trash."
                : "The rest of it goes to the Trash."
            return HeldResearchAct(
                verb: verb, ids: ids, take: take, lifts: lifts,
                title: "Delete \(named)?",
                message: "\(goes) \(keptLine); \(named) stays as \(kept.count == 1 ? "its" : "their") group.",
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
                message: "It goes with its whole-book research. \(keptLine): lifted out first, \(kept.count == 1 ? "it stays" : "they stay") where \(named) was.",
                confirmTitle: "Move",
                afterLift: "The \(noun)s’ notes were lifted out of \(named), but \(named) couldn’t be moved: ")
        }
    }
}
