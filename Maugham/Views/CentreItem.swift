import Foundation
import MaughamCore

/// **A statement or a piece's History opened in the centre** (shell plan 3):
/// drawn as a cover over the editor route (`CentreCover.centreItem`), where a
/// publish cover wins while it stands. Not a subject: the subject opens the
/// piece (or the Book) the item belongs to (`ProjectWindow.openingInCentre`),
/// and the item clears on any later change of what is open
/// (`centreItemAfterOpenChange`).
enum CentreItem: Equatable {
    case statement(kind: Statement.Kind, scope: Statement.Scope)
    case history(docId: String)
}

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
    /// `open` holds, cleared by any change of it.
    static func centreItemAfterOpenChange(_ item: CentreItem?, from old: BinderSubject,
                                          to new: BinderSubject) -> CentreItem? {
        old == new ? item : nil
    }

    /// Whether this statement is the centre's cover — Brief and the pulled-up
    /// view then draw a placeholder, so two `StatementEditorHost`s never bind
    /// one statement.
    static func statementIsInTheCentre(kind: Statement.Kind, scope: Statement.Scope,
                                       centreItem: CentreItem?) -> Bool {
        centreItem == .statement(kind: kind, scope: scope)
    }
}
