import Foundation
import MaughamCore

/// What the window's tree names, resolved against the manifest into the
/// **pieces** the canvas can answer with (spec §4 and its §4.1 amendment).
///
/// **Why this is not `BinderSubject` handed down raw.** §4's table has three
/// rows — the project, a document with bindings, a document with nothing bound —
/// and §4.1 adds a fourth subject the tree can name: a **group**, which lights
/// the union of its children's bindings. Telling those apart needs
/// `manifest.structure`, because `BinderSubject.item(id)` deliberately does not
/// encode document-vs-group (see that type: *"the load-bearing test is
/// `TreeWalk.find(id:in:)` plus `item.type == .document` against a manifest this
/// type cannot see, and a second answer baked into the case would be free to
/// disagree with it"*). The canvas holds no manifest and should not start: the
/// nearest precedent is `CanvasView.itemIndex`, which is built in
/// `ProjectWindow` beside `pieceChoices` and handed down precisely so the walk
/// lands on the window's body path rather than on the canvas's, which
/// re-evaluates on every drag, coast and straighten frame (tripwire 4).
///
/// So the resolution happens once, where the manifest already is, and what
/// reaches the canvas is the answer rather than the question.
///
/// **`.group` is what a subject that is not a manuscript document resolves to**,
/// including an id the tree cannot find at all — which resolves to a group of no
/// pieces. That is the honest reading rather than a defensive one: a subject
/// naming nothing bindable lights nothing and can bind nothing, which is exactly
/// what §4.1 says a group does.
enum CanvasSubject: Hashable {

    /// §4 row one: the whole board, undimmed. Also what *no* selection resolves
    /// to — the dim is a state the writer deliberately enters, and a window that
    /// has not been clicked in yet has not entered it.
    case wholeProject

    /// A manuscript document, by `StructureItem.id`. The only thing a region's
    /// `boundPieceID` can ever hold — `RegionInspector`'s Picker is offered
    /// `ProjectStore.researchScopeTargets()`, which is documents only.
    case piece(String)

    /// A group, carrying **every manuscript document beneath it** — nested ones
    /// included, which is `TreeWalk.collect`'s recursion rather than a rule of
    /// this file's. §4.1: *"Select Part One and everything bound to any chapter
    /// beneath it lights together."*
    ///
    /// The pieces are carried rather than the group's own id because a group id
    /// can never match a `boundPieceID`, so an unresolved group would light
    /// nothing and read on screen exactly like a chapter with nothing bound.
    case group([String])

    /// The documents this subject names: one for a piece, every descendant
    /// document for a group, none for the project.
    var pieces: [String] {
        switch self {
        case .wholeProject: return []
        case .piece(let id): return [id]
        case .group(let ids): return ids
        }
    }

    /// Whether this subject filters the board at all. **Not `pieces.isEmpty`** —
    /// a group with no documents under it dims everything and lights nothing,
    /// which is a different state from the project row.
    var dimsTheBoard: Bool {
        if case .wholeProject = self { return false }
        return true
    }

    /// The one conversion, and it happens where the manifest is.
    ///
    /// A `switch` rather than `subject?.itemID`: `BinderSubject` asks a caller to
    /// say, where it asks, what the project means to it, and to the canvas the
    /// project and no-selection mean the same thing — the whole board.
    static func resolve(_ subject: BinderSubject?,
                        in structure: [StructureItem]) -> CanvasSubject {
        switch subject {
        case nil, .project:
            return .wholeProject
        case .item(let id):
            guard let item = TreeWalk.find(id: id, in: structure) else { return .group([]) }
            switch item.type {
            case .document:
                return .piece(id)
            case .group:
                return .group(TreeWalk.collect(in: item.children ?? [],
                                               where: { $0.type == .document }).map(\.id))
            }
        }
    }
}
