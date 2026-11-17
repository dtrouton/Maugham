import Foundation
import MaughamCore

/// The one rule that turns a tree click into a `WindowSubject`
/// (spec `2026-11-16-subject-resolve-brief-shell-design.md`, "The model").
public enum ClickRule {
    /// `openInCentre` is a double-click or the explicit control.
    public enum Gesture { case click, openInCentre }

    public static func resolve(_ clicked: BinderSubject, gesture: Gesture,
                               current: WindowSubject, structure: [StructureItem],
                               projectType: ProjectType) -> WindowSubject {
        var next = current
        if gesture == .openInCentre {
            next.open = clicked
            next.faces = clicked
            if next.beside == clicked { next.beside = nil }
            return next
        }
        // A click on the row already opened beside puts it away (shell p1
        // Task 3): the tree's own way to dismiss what it pulled up.
        if current.beside == clicked {
            next.beside = nil
            return next
        }
        switch clicked {
        case .research:
            next.beside = clicked
        case .item(let id) where isPiece(id, in: structure):
            switch current.open {
            case .canvas, .edition:
                next.faces = clicked
            default:
                next.open = clicked
                next.faces = clicked
            }
        case .item, .project, .figure, .inbox, .canvas, .palette, .edition:
            next.open = clicked
            next.faces = clicked
        }
        return next
    }

    /// **Going to a thing from outside the tree** — a wiki link, a find
    /// result, Claude's Show, a board chip, a creation selecting what it made.
    /// A click, except that a thing already beside or in the faces stays
    /// exactly where it is: such a caller says *show me this*, never *put it
    /// away*, so it must not reach the click's dismissal. `nil` is the Book.
    /// (Task 4 replaces this with going to a place.)
    public static func navigate(to target: BinderSubject?, current: WindowSubject,
                                structure: [StructureItem],
                                projectType: ProjectType) -> WindowSubject {
        let target = target ?? .project
        guard target != current.lastClicked else { return current }
        return resolve(target, gesture: .click, current: current,
                       structure: structure, projectType: projectType)
    }

    /// A piece is a document; a Part is a group. An id not in the structure is
    /// treated as a piece.
    private static func isPiece(_ id: String, in structure: [StructureItem]) -> Bool {
        TreeWalk.find(id: id, in: structure)?.type != .group
    }
}
