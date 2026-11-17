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

    /// A piece is a document; a Part is a group. An id not in the structure is
    /// treated as a piece.
    private static func isPiece(_ id: String, in structure: [StructureItem]) -> Bool {
        TreeWalk.find(id: id, in: structure)?.type != .group
    }
}
