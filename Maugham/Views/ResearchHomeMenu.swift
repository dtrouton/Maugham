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
        var id: String { title }
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
                                    removeFromThis: nil, makeWholeBook: nil, alsoIn: nil)
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
            alsoIn: others.isEmpty ? nil : alsoInLine(others.map(title)))
    }
}
