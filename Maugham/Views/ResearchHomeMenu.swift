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
        /// Every link the note has goes, chosen in `fold`'s fold — a move
        /// to the book through the one oracle (closing round A4).
        case makeWholeBook(researchId: String, from: [String], fold: String)
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
            case .makeWholeBook(_, let from, _): return "whole:" + from.joined(separator: ",")
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
            case .unlink, .makeWholeBook: continue
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

    static func moveTitle(noun: PieceNoun) -> String { "Move to \(noun.capitalised)" }
    static func removeTitle(_ piece: String) -> String { "Remove from “\(piece)”" }
    static func alsoInLine(_ pieces: [String]) -> String {
        "Also in " + pieces.map { "“\($0)”" }.joined(separator: ", ")
    }

    /// The menu `itemId`'s row offers, drawn in `fold`'s fold (nil: the
    /// Research section), or nil where it offers none.
    static func of(itemId: String, inFold fold: String?, homes: ResearchHomes,
                   noun: PieceNoun, mayLink: (String) -> Bool) -> ResearchHomeMenu? {
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
            whole = Item(title: makeWholeBookTitle,
                         verb: .makeWholeBook(researchId: itemId, from: links, fold: fold))
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
    typealias Lift = ResearchMovePlan.Lift

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
    /// A move's plan (`ResearchMovePlan`): what it does and what it takes.
    var plan: ResearchMovePlan?
    /// The losses the question names: the plan's, less the one pair the
    /// writer asked for (`asked(of:sources:research:)`).
    var asked: [String: [String]] = [:]
    /// The fold each row was taken from, as asked (asked again with them).
    var sources: [String: String] = [:]

    /// **The losses a move asks about** (closing round A3): every one the
    /// plan finds, save the one the writer asked for — a single NOTE taken out
    /// of the fold it was taken from. A group, several rows, an unknown
    /// source, or any other chapter losing anything is asked.
    static func asked(of plan: ResearchMovePlan, sources: [String: String],
                      research: [ResearchItem]) -> [String: [String]] {
        var asked = plan.losses
        if plan.ids.count == 1, let id = plan.ids.first, let source = sources[id],
           TreeWalk.find(id: id, in: research)?.type != .group {
            asked[id]?.removeAll { $0 == source }
            if asked[id]?.isEmpty == true { asked[id] = nil }
        }
        return asked
    }

    /// **A move's question, or nil where it asks nothing** (closing round
    /// A3): one sentence over what the plan keeps (a section group's hidden
    /// chapter notes) and what it takes (`asked`).
    static func ofMove(_ plan: ResearchMovePlan, landing: Landing, sources: [String: String],
                       homes: ResearchHomes, research: [ResearchItem],
                       structure: [StructureItem], noun: PieceNoun) -> HeldResearchAct? {
        let asked = Self.asked(of: plan, sources: sources, research: research)
        guard !plan.held.isEmpty || !asked.isEmpty else { return nil }
        let ids = plan.ids
        func title(_ id: String) -> String { TreeWalk.find(id: id, in: research)?.title ?? id }
        func chapter(_ piece: String) -> String { homes.pieceTitles[piece] ?? piece }
        func and(_ names: [String]) -> String {
            names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        func ranked(_ pieces: Set<String>) -> [String] {
            homes.pieceOrder.filter(pieces.contains) + pieces.filter { !homes.pieceOrder.contains($0) }.sorted()
        }
        let named = ids.count == 1 ? "“\(title(ids[0]))”" : "\(ids.count) items"
        let to: String
        if let linkTo = plan.linkTo {
            to = "“\(chapter(linkTo))”"
        } else {
            switch plan.target {
            case .group(let id)?: to = "“\(title(id))”"
            case .piece(let id)?: to = "“\(TreeWalk.find(id: id, in: structure)?.title ?? id)”"
            case .sharedRoot?, nil: to = "Research"
            }
        }
        // **The words** (closing round A4, the reviewer's strings): chapters
        // named up to three, then "and N more".
        func listed(_ names: [String]) -> String {
            guard names.count > 3 else { return and(names) }
            let more = names.count - 3
            return names.prefix(3).joined(separator: ", ") + " and \(more) more"
        }
        // "it", "both", "all three" — what "takes it from …" ends on.
        func from(_ names: [String]) -> String {
            let words = ["three", "four", "five", "six", "seven", "eight", "nine", "ten"]
            switch names.count {
            case 1: return names[0]
            case 2: return "both"
            case 3...10: return "all \(words[names.count - 3])"
            default: return "all \(names.count)"
            }
        }
        func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        // Each losing chapter with how many of what goes leave it.
        let perChapter: [String: Int] = asked.values.reduce(into: [:]) { counts, pieces in
            for piece in pieces { counts[piece, default: 0] += 1 }
        }
        let losingOrder = ranked(Set(perChapter.keys))
        let losingNames = losingOrder.map(chapter)
        // "2 out of Chapter 1 and 1 out of Two" / "a note each from …".
        func counted(_ joiner: String) -> String {
            listed(losingOrder.map { "\(perChapter[$0] ?? 0) \(joiner) \(chapter($0))" })
        }
        let rowsAreNotes = ids.allSatisfy { TreeWalk.find(id: $0, in: research)?.type != .group }
        var sentence: String
        if !plan.held.isEmpty {
            let own = Set(ids.flatMap { homes.homes(of: $0) })
            func chapters(of id: String) -> String {
                and(homes.homes(of: id).filter { !own.contains($0) }.map(chapter))
            }
            if asked.isEmpty {
                let stays: String
                if plan.held.count == 1, let id = plan.held.first {
                    stays = "“\(title(id))” stays with \(chapters(of: id))"
                } else {
                    let shown = plan.held.prefix(3).map { "“\(title($0))” (\(chapters(of: $0)))" }
                    let more = plan.held.count - shown.count
                    let list = more > 0
                        ? shown.joined(separator: ", ") + " and \(more) more"
                        : shown.dropLast().joined(separator: ", ") + " and " + shown.last!
                    stays = "\(list) stay with their \(noun.plural)"
                }
                sentence = "\(stays); the rest of \(named) moves to \(to)."
            } else {
                // A lift and a loss: "Moving these 2 items to “Places” leaves
                // “Maps” with Three and takes a note each from One and Two."
                let leaves = plan.held.count == 1
                    ? "“\(title(plan.held[0]))” with \(chapters(of: plan.held[0]))"
                    : listed(plan.held.map { "“\(title($0))”" }) + " with their \(noun.plural)"
                let each = losingOrder.allSatisfy { perChapter[$0] == 1 }
                let takes = each && losingOrder.count > 1
                    ? "a note each from \(listed(losingNames))"
                    : counted("from")
                let what = ids.count == 1 ? named : "these \(ids.count) items"
                sentence = "Moving \(what) to \(to) leaves \(leaves) and takes \(takes)."
            }
        } else if ids.count == 1, let id = ids.first, TreeWalk.find(id: id, in: research)?.type != .group,
                  let losing = asked[id], asked.count == 1 {
            // One note: "“Hull” also belongs to Two; moving it to “Places”
            // takes it from Two." / "… belongs to One and Two; … from both."
            let names = ranked(Set(losing)).map(chapter)
            let also = (plan.losses[id] ?? []).count > losing.count
            sentence = "“\(title(id))” \(also ? "also " : "")belongs to \(listed(names)); "
                + "moving it to \(to) takes it from \(from(names))."
        } else if ids.count == 1, let id = ids.first {
            // A group: "Moving “Ships” to “Places” takes it and its 2 notes
            // out of Chapter 1."
            let notes = asked.keys.filter { $0 != id }.count
            let it = notes == 0 ? "it" : "it and its \(plural(notes, "note"))"
            sentence = "Moving \(named) to \(to) takes \(it) out of \(listed(losingNames))."
        } else {
            // Several rows: "Moving 3 notes to “Two” takes them out of
            // Chapter 1." / "… takes 2 out of Chapter 1 and 1 out of Two."
            let what = plural(ids.count, rowsAreNotes ? "note" : "item")
            let takes = losingOrder.count == 1 && perChapter[losingOrder[0]] == asked.count
                ? "them out of \(losingNames[0])" : counted("out of")
            sentence = "Moving \(what) to \(to) takes \(takes)."
        }
        var act = HeldResearchAct(
            verb: .move(plan.target ?? .sharedRoot, landing: landing), ids: ids,
            take: ResearchHomes.Take(taken: [], held: plan.held, staying: []), lifts: plan.lifts,
            title: "Move \(named) to \(to)?", message: sentence, confirmTitle: "Move",
            afterLift: "The \(noun.plural)’ notes were lifted out of \(named), but \(named) couldn’t be moved: ")
        act.plan = plan
        act.asked = asked
        act.sources = sources
        return act
    }

    /// **A Delete's question** over what chapters hold beneath the rows
    /// (fix rounds 1–3, closing round A): lifted out first, then the rows go.
    /// `noun`: the project's word for a piece (`PieceNoun`).
    static func ofDelete(ids: [String], homes: ResearchHomes, research: [ResearchItem],
                         noun: PieceNoun) -> HeldResearchAct? {
        func parent(of id: String) -> String? {
            TreeWalk.first(in: research, where: { ($0.children ?? []).contains { $0.id == id } })?.id
        }
        let acted = ids
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
            stays = "\(list) stay with their \(noun.plural)"
        }
        return HeldResearchAct(
            verb: .delete, ids: ids, take: take, lifts: lifts,
            title: "Delete \(named)?",
            message: "\(stays); the rest of \(named) goes to the Trash.",
            confirmTitle: "Delete", afterLift: "")
    }
}
