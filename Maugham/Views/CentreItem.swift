import Foundation
import MaughamCore

// `CentreItem` itself is a model type, beside `PulledUp` (Models/PulledUp.swift).

extension ProjectWindow {

    /// The subject an item opens in the centre over: a piece's intent and a
    /// piece's History open that piece; every other statement opens the Book.
    /// What is pulled up stays (it persists until closed); where the same
    /// statement is both, the pulled-up view draws a placeholder
    /// (`statementIsInTheCentre`).
    static func openingInCentre(_ item: CentreItem, subject: WindowSubject) -> WindowSubject {
        let target: BinderSubject
        switch item {
        case .statement(.intent, .document(let id)), .history(let id):
            target = .item(id)
        case .statement:
            target = .project
        }
        var next = subject
        next.open = target
        next.faces = target
        return next
    }

    /// The centre item after `open` moves from `old` to `new`: kept while
    /// `open` holds, cleared by any change of it — except the move that
    /// opened it. `openInCentre` writes the subject and the item in one
    /// update, so the window's `.onChange(of: open)` sees that move with the
    /// item already set; a move that lands on the item's own place
    /// (`openingInCentre`) is that opening. While an item stands `open` IS
    /// its place, so no later move can land there without leaving first.
    static func centreItemAfterOpenChange(_ item: CentreItem?, from old: BinderSubject,
                                          to new: BinderSubject) -> CentreItem? {
        guard let item else { return nil }
        if old == new { return item }
        let place = openingInCentre(item, subject: WindowSubject(open: old, faces: old)).open
        return place == new ? item : nil
    }

    /// **Whether the manuscript is the editor the writer can see** — THE
    /// question every manuscript-writing entry point that does not come
    /// through the text view's own keys asks before it acts (shell plan 3
    /// Task 5 fix 2): true only for the bare editor, `.editor(altitude: nil,
    /// cover: nil)`. False under the centre item's cover, under any other
    /// cover, under the Book's view, and for every centre that is not the
    /// editor (the canvas, research, a figure, the wall, the Inbox, a
    /// reference piece). Asked by the Insert menu's gate, the Format ▸ Table
    /// publication, `CentreKeys` (and through it the editor's own commands,
    /// `EditorCoordinator.manuscriptCommandContext`). Pure.
    static func manuscriptIsVisible(route: CentreRoute?) -> Bool {
        if case .editor(altitude: nil, cover: nil)? = route { return true }
        return false
    }

    /// Whether this statement is the centre's cover — Brief and the pulled-up
    /// view then draw a placeholder, so two `StatementEditorHost`s never bind
    /// one statement.
    static func statementIsInTheCentre(kind: Statement.Kind, scope: Statement.Scope,
                                       centreItem: CentreItem?) -> Bool {
        centreItem == .statement(kind: kind, scope: scope)
    }
}
