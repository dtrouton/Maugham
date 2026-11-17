import SwiftUI
import MaughamCore

/// **Going to a place in the manuscript opens its piece in the centre** (shell
/// p1 Task 4).
///
/// A place is a paragraph or a document named from outside the tree: an
/// annotation row, a history row, a task row, a diagnostic's excerpt, a
/// figure's Used-in link, a find result, a `[[wiki-link]]`, the Inspector's
/// Links row, the Project Statistics window's jump, a slugline. Whatever the
/// centre was — the canvas, an edition, the Inbox, the Book — the writer asked
/// to READ that place, so `open` and `faces` both become its piece and `beside`
/// is left exactly as it was.
///
/// **This is not the click rule.** A click on a piece while the canvas or an
/// edition is the centre moves only the faces (`ClickRule`, clause 1). A place
/// is different: there is no surface but the editor on which a paragraph can
/// be shown, so leaving the canvas in the centre would put the writer's jump
/// nowhere.
///
/// **Which receivers route here is a census, not a number** —
/// `ManuscriptForceCensusTests` names the notifications
/// (`.maughamNavigateToDocument`, `.maughamNavigateToParagraph`,
/// `.maughamNavigateToScene`) and requires each receiver to call `go`.
///
/// It used to decide a PERSONA (Denver's 2026-08-02 ruling, *"if I'm moving to
/// the manuscript I'm moving to Author"*); the subject's `open` is that
/// decision now, and there is no persona to move or remember.
enum ManuscriptNavigation {

    /// The payload key a paragraph navigation names its document by
    /// (`TasksPane`, `HistoryPaneVerbs`, `TranslationReveal.navigatePayload`).
    static let docIdKey = "doc_id"

    /// **Going to a document**: its piece takes the centre and the faces;
    /// whatever is beside stays. `nil` (no document could be named) moves
    /// nothing.
    static func destination(toDocument docId: String?,
                            current: WindowSubject) -> WindowSubject {
        guard let docId else { return current }
        var next = current
        next.open = .item(docId)
        next.faces = .item(docId)
        return next
    }

    /// **Which document a paragraph navigation is in.** The payload's own
    /// `doc_id` when the poster named one; otherwise the piece the faces are
    /// on, because every poster that names none is a right-column pane about
    /// the faces' document (an annotation or diagnostic row of that document,
    /// the scene navigator after it put the script on the faces). A faces on a
    /// Part, the Book or anything else names no paragraph's document: `nil`.
    static func paragraphDocId(payload: [AnyHashable: Any]?,
                               current: WindowSubject,
                               structure: [StructureItem]) -> String? {
        if let named = payload?[docIdKey] as? String { return named }
        guard let id = current.faces.itemID,
              let item = TreeWalk.find(id: id, in: structure),
              item.type == .document else { return nil }
        return id
    }

    /// **A right-column pane travelling** — an annotation row about another
    /// piece, a figure's Used-in link. A document piece is a place and opens
    /// (`destination(toDocument:)`); anything else (a figure, a Part, the
    /// Book) is `ClickRule.navigate`.
    static func travel(to target: BinderSubject?, current: WindowSubject,
                       structure: [StructureItem],
                       projectType: ProjectType) -> WindowSubject {
        if case .item(let id)? = target,
           TreeWalk.find(id: id, in: structure)?.type == .document {
            return destination(toDocument: id, current: current)
        }
        return ClickRule.navigate(to: target, current: current,
                                  structure: structure, projectType: projectType)
    }

    /// The one place a navigation is applied to a window: the subject, written
    /// only when it changed.
    ///
    /// **Deliberately does NOT force the inspector column open**, unlike
    /// `CanvasClaudeArrivalModifier`'s Show: that takes the writer to something
    /// the RIGHT column names; this takes them to the centre, and reopening a
    /// column they closed with `⌘⌥I` would be a side effect nobody asked for.
    @MainActor
    static func go(to destination: WindowSubject, subject: Binding<WindowSubject>) {
        if destination != subject.wrappedValue { subject.wrappedValue = destination }
    }
}
