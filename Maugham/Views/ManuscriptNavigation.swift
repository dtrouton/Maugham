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
/// `ManuscriptForceCensusTests.test_everyNavigationReceiverStillRoutesThroughTheNavigation`
/// names the notifications and requires each receiver to call `go`; read the
/// list there rather than a copy here.
///
/// It used to decide a window MODE (Denver's 2026-08-02 ruling, *"if I'm moving
/// to the manuscript I'm moving to Author"*); the subject's `open` is that
/// decision now, and there is no mode to move or remember.
enum ManuscriptNavigation {

    /// The payload key a paragraph navigation names its document by
    /// (the Tasks pane, `HistoryPaneVerbs`, `TranslationReveal.navigatePayload`).
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

    /// **Where a paragraph navigation takes the subject**: To resolve's row
    /// click over the Book or a Part that holds the piece opens it inside the
    /// faces (`ClickRule.openInsideTheFaces`, review I1); every other place —
    /// find, a wiki link, history, Claude's Show, a slugline, a report row —
    /// is `destination(toDocument:)`, the faces moving with it.
    static func destination(toDocument docId: String?, payload: [AnyHashable: Any]?,
                            current: WindowSubject, structure: [StructureItem]) -> WindowSubject {
        if let docId, payload?[ResolveNavigation.insideTheFacesKey] as? Bool == true,
           let inside = ClickRule.openInsideTheFaces(docId, current: current, structure: structure) {
            return inside
        }
        return destination(toDocument: docId, current: current)
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

    /// **A go-to-paragraph or slugline, applied to the window**: where it
    /// takes the subject (the place's piece open), having held the place on
    /// `control` when the window's manuscript editor does not have that piece
    /// loaded (`EditorControl.pendingPlace`, shell p1 Task 4b). The window's
    /// receivers (`ParagraphNavModifier`) call this and then `go`.
    ///
    /// Asked of the editor, not of the subject: a poster may already have
    /// written `open` itself before posting (the scene navigator over the
    /// Book, a research item, a figure, the Inbox or the palette; a figure's
    /// Used-in reveal), so "open did not change" does not mean "the editor
    /// has it". The place is written before the subject so it is there
    /// whenever the load lands.
    @MainActor
    static func holdingThePlace(payload: [AnyHashable: Any]?, current: WindowSubject,
                                structure: [StructureItem],
                                control: EditorControl) -> WindowSubject {
        let docId = paragraphDocId(payload: payload, current: current, structure: structure)
        let next = destination(toDocument: docId, payload: payload, current: current, structure: structure)
        if holdsThePlace(docId: docId, structure: structure,
                         mounted: control.mountedDocumentId),
           let place = place(docId: docId, payload: payload) {
            control.pendingPlace = place
        }
        return next
    }

    /// **Whether the window holds a place for the editor to land on once its
    /// document has loaded**: when it names a document piece the window's
    /// manuscript editor does not have. When the editor has it, its own
    /// receiver lands the place at once and nothing is held — a held place
    /// would land again on the next reload. A non-document id (a Part, a
    /// stale id) loads no editor, so nothing is held for it.
    static func holdsThePlace(docId: String?, structure: [StructureItem], mounted: String?) -> Bool {
        guard let docId, TreeWalk.find(id: docId, in: structure)?.type == .document else { return false }
        return mounted != docId
    }

    /// **The window's `open` changed** (`ParagraphNavModifier`'s
    /// `.onChange(of: subject.open)`): a waiting place whose document is no
    /// longer open is dropped — its load was abandoned, and it must not land
    /// on a later, ordinary open of that piece.
    @MainActor
    static func openChanged(to open: BinderSubject, control: EditorControl) {
        guard let pending = control.pendingPlace, open != .item(pending.docId) else { return }
        control.pendingPlace = nil
    }

    /// **The place a navigation names**: a paragraph (with its offset) or a
    /// slugline's line, from the payload; nil when it names neither.
    static func place(docId: String?, payload: [AnyHashable: Any]?) -> EditorControl.PendingPlace? {
        guard let docId else { return nil }
        if let pid = payload?["paragraph_id"] as? String {
            return .init(docId: docId, target: .paragraph(
                id: pid, offset: payload?[MaughamEvent.paragraphOffsetKey] as? Int))
        }
        if let location = payload?["lineLocation"] as? Int {
            return .init(docId: docId, target: .line(location: location))
        }
        return nil
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
