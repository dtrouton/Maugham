import Foundation
import MaughamCore

/// **What a research move does, and what it takes from each chapter** (shell
/// p5a closing round A3: one oracle). Every move — the row menu's Move to ▸,
/// every drop arm (a reorder, a drop on a group, on the Research section, on
/// another chapter), one row or a batch, and the assistant's
/// `move_research_item` — is planned here, and the plan is simulated on the
/// manifest: `ResearchHomes` before and after, over the moved rows and
/// everything beneath them, gives the **losses** (a chapter that drew an item
/// before and does not after) and the **gains**. The question a move asks,
/// the refusals it meets (read-through, the posture) and the assistant's
/// `left` all read this one diff; nothing else works out who loses what.
///
/// The plan's steps, as the rules of the round before decided them:
/// - **Lifts**: a Research-section group moving to another parent leaves the
///   chapters' notes it hides where it stood (the owner's ruling on I2).
/// - **The move** itself, when there is one (`target`).
/// - **Unlinks**: to the book (the Research root or a whole-book group, no
///   chapter to link to) a row's own direct links go — a drop on Research
///   means whole-book (A2); or the links a drop out of a fold edits.
/// - **A link** to the chapter a row was dropped on (`linkTo`).
/// Pure.
struct ResearchMovePlan: Equatable {
    /// What chapters hold under one Research-section row, lifted to where
    /// that row stands before it moves.
    struct Lift: Equatable {
        let ids: [String]
        let to: ResearchMoveTarget
    }

    let ids: [String]
    let target: ResearchMoveTarget?
    /// The link edits the caller named (a drop between chapters), kept so
    /// the plan can be made again on a later manifest.
    let explicitUnlinks: [String: [String]]?
    let lifts: [Lift]
    /// What the lifts keep in place: the chapters' notes a section group hid.
    let held: [String]
    let unlinks: [String: [String]]
    let linkTo: String?
    /// Item id → the chapters (pieces) that draw it before and not after,
    /// in tree order.
    let losses: [String: [String]]
    /// Item id → the chapters that draw it after and not before.
    let gains: [String: [String]]
    /// Where the first row is drawn after: a chapter's fold, or nil for the
    /// Research section — where the landing is shown.
    let landingPiece: String?

    /// Every chapter that loses anything.
    var losingChapters: Set<String> { Set(losses.values.joined()) }

    /// The store's link edits for this plan's own save.
    var linkEdit: ResearchLinkEdit {
        ResearchLinkEdit(unlink: unlinks, linkTo: linkTo.map { (ids, $0) })
    }
    var gainingChapters: Set<String> { Set(gains.values.joined()) }

    /// `explicitUnlinks`: the link edits a drop out of a fold makes on its own
    /// (a move between chapters by their links), nil to let the destination
    /// decide (to the book, a row's own links go).
    static func make(ids: [String], target: ResearchMoveTarget?, linkTo: String?,
                     explicitUnlinks: [String: [String]]?, homes: ResearchHomes,
                     structure: [StructureItem], research: [ResearchItem],
                     projectType: ProjectType) -> ResearchMovePlan {
        func parent(of id: String) -> String? {
            TreeWalk.first(in: research, where: { ($0.children ?? []).contains { $0.id == id } })?.id
        }
        var lifts: [Lift] = []
        var held: [String] = []
        var unlinks = explicitUnlinks ?? [:]
        if let target {
            // A Research-section row (no piece of its own) changing parent
            // lifts what chapters hold beneath it (fix rounds 1–3).
            let section = ids.filter { homes.homes(of: $0).isEmpty }.filter { id in
                switch target {
                case .group(let group): return parent(of: id) != group
                case .sharedRoot: return parent(of: id) != nil
                case .piece: return true
                }
            }
            let take = homes.take(section, in: research)
            held = take.held
            for id in section where take.staying.contains(id) {
                guard let row = TreeWalk.find(id: id, in: research) else { continue }
                let under = take.held.filter { TreeWalk.contains(id: $0, in: row.children ?? []) }
                guard !under.isEmpty else { continue }
                let to: ResearchMoveTarget = parent(of: id).map { .group($0) }
                    ?? homes.owner(of: id).map { .piece($0) } ?? .sharedRoot
                lifts.append(Lift(ids: under, to: to))
            }
            // To the book, a row's own links go (A2).
            if explicitUnlinks == nil, linkTo == nil, homes.homes(at: target).isEmpty {
                for id in ids {
                    let links = homes.links(of: id)
                    if !links.isEmpty { unlinks[id] = links }
                }
            }
        }
        // **The diff**: the rows and everything beneath them, before and after.
        let (afterStructure, afterResearch) = simulate(
            ids: ids, target: target, lifts: lifts, unlinks: unlinks, linkTo: linkTo,
            structure: structure, research: research)
        let after = ResearchHomes.derive(structure: afterStructure, research: afterResearch,
                                         projectType: projectType)
        var watched: [String] = []
        for id in ids {
            guard let row = TreeWalk.find(id: id, in: research) else { continue }
            watched.append(id)
            watched += TreeWalk.collect(in: row.children ?? [], where: { _ in true }).map(\.id)
        }
        var losses: [String: [String]] = [:]
        var gains: [String: [String]] = [:]
        for id in watched {
            let was = homes.homes(of: id), now = after.homes(of: id)
            let lost = was.filter { !now.contains($0) }
            let won = now.filter { !was.contains($0) }
            if !lost.isEmpty { losses[id] = lost }
            if !won.isEmpty { gains[id] = won }
        }
        return ResearchMovePlan(ids: ids, target: target, explicitUnlinks: explicitUnlinks,
                                lifts: lifts, held: held, unlinks: unlinks, linkTo: linkTo,
                                losses: losses, gains: gains,
                                landingPiece: ids.first.flatMap { after.homes(of: $0).first })
    }

    /// The manifest as the plan leaves it: lifts, the move (appended; a
    /// Collection piece's folder by its path), the unlinks, the link.
    static func simulate(ids: [String], target: ResearchMoveTarget?, lifts: [Lift],
                         unlinks: [String: [String]], linkTo: String?,
                         structure: [StructureItem], research: [ResearchItem])
        -> (structure: [StructureItem], research: [ResearchItem]) {
        var tree = research
        let folders = ProjectStore.researchFolders(in: structure)
        func move(_ moving: [String], to destination: ResearchMoveTarget) {
            var taken: [ResearchItem] = []
            func strip(_ items: [ResearchItem]) -> [ResearchItem] {
                items.compactMap { item in
                    if moving.contains(item.id) { taken.append(item); return nil }
                    var item = item
                    item.children = item.children.map(strip)
                    return item
                }
            }
            tree = strip(tree)
            switch destination {
            case .group(let group):
                func put(_ items: [ResearchItem]) -> [ResearchItem] {
                    items.map { item in
                        var item = item
                        if item.id == group { item.children = (item.children ?? []) + taken }
                        else { item.children = item.children.map(put) }
                        return item
                    }
                }
                tree = put(tree)
            case .sharedRoot:
                tree += taken.map { item in
                    var item = item
                    item.path = item.path.map { "research/" + ($0 as NSString).lastPathComponent }
                    return item
                }
            case .piece(let piece):
                let prefix = folders.first { $0.pieceId == piece }?.prefix ?? "research"
                tree += taken.map { item in
                    var item = item
                    item.path = item.path.map { prefix + "/" + ($0 as NSString).lastPathComponent }
                    return item
                }
            }
        }
        for lift in lifts { move(lift.ids, to: lift.to) }
        if let target { move(ids, to: target) }
        let movedIds = ids
        func edit(_ items: [StructureItem]) -> [StructureItem] {
            items.map { item in
                var item = item
                var ids = item.linkedResearchIds ?? []
                ids.removeAll { unlinks[$0]?.contains(item.id) == true }
                if item.id == linkTo {
                    for id in movedIds where !ids.contains(id) { ids.append(id) }
                }
                item.linkedResearchIds = ids.isEmpty ? nil : ids
                item.children = item.children.map(edit)
                return item
            }
        }
        return (edit(structure), tree)
    }
}
