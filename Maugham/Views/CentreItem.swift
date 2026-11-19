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

    /// **Whether what covers the editor hides it**: the Book's view, or any
    /// cover but the no-book notice (which stands over the Book's view and
    /// takes no clicks). While it does, the manuscript's text view never
    /// holds the keys (`CentreKeys`). Pure.
    static func coverHidesTheEditor(cover: CentreCover?, altitude: BookView?) -> Bool {
        if altitude != nil { return true }
        switch cover {
        case .none, .notice: return false
        case .books, .designGate, .translationRound, .publishProblems, .centreItem: return true
        }
    }

    /// Whether this statement is the centre's cover — Brief and the pulled-up
    /// view then draw a placeholder, so two `StatementEditorHost`s never bind
    /// one statement.
    static func statementIsInTheCentre(kind: Statement.Kind, scope: Statement.Scope,
                                       centreItem: CentreItem?) -> Bool {
        centreItem == .statement(kind: kind, scope: scope)
    }
}
