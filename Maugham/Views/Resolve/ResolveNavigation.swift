import Foundation
import MaughamCore

/// **A To resolve row's click goes to its place** — through the existing
/// going-to-a-place path, never a new one.
///
/// The paragraph event's payload always names the row's document and a
/// paragraph, so `ManuscriptNavigation` opens that piece in the centre on that
/// paragraph whatever the centre was (the canvas, the Book, another piece).
/// That is how a row on a piece that is not open becomes a row that acts
/// (`ResolveVerbGate`). A note also posts `.maughamNavigateToAnnotation`
/// first, as the queue always has, so the editor can select the note's span.
/// The receivers are unchanged; the editor receives a position, never a
/// payload of its own (ADR 0027 §1).
enum ResolveNavigation {

    /// The paragraph payload's key — the one spelling in To resolve.
    static let paragraphIdKey = "paragraph_id"

    /// The paragraph event's payload for a place: `doc_id`, and
    /// `paragraph_id` when there is one. With no paragraph it only opens the
    /// piece: `ManuscriptNavigation` holds no place, and the editor's own
    /// receiver ignores a payload without a paragraph.
    static func payload(docId: String, paragraphId: String?) -> [String: String] {
        var payload = [ManuscriptNavigation.docIdKey: docId]
        if let paragraphId { payload[paragraphIdKey] = paragraphId }
        return payload
    }

    /// The paragraph event's payload: `doc_id` and `paragraph_id`. An item
    /// that points at no paragraph lands on its piece's first
    /// (`firstParagraph`). `nil` where there is no place in the manuscript:
    /// a Book-level to-do, a figure's note (its row travels to the figure), or
    /// a whole-piece item on a piece with no paragraph.
    static func payload(for item: ResolveItem, firstParagraph: String?) -> [String: String]? {
        let docId = item.docId
        guard docId != ProjectStore.projectTasksDocId,
              !DocumentClass.isFigureDocId(docId),
              let paragraphId = item.paragraphId ?? firstParagraph
        else { return nil }
        return payload(docId: docId, paragraphId: paragraphId)
    }

    /// The payload key that makes a row's click open its piece inside the
    /// faces (`ClickRule.openInsideTheFaces`). Posted only by
    /// `goInsideTheFaces`; read only by `ManuscriptNavigation.destination`.
    static let insideTheFacesKey = "resolve_inside_the_faces"

    /// Go there. Posts through `MaughamEvent` only (tripwire 21), to the key
    /// window: a note's annotation event first, then the paragraph event.
    static func go(_ item: ResolveItem, firstParagraph: String?) {
        post(item, payload: payload(for: item, firstParagraph: firstParagraph).map { $0 as [String: Any] })
    }

    /// **A row's click in a Book or Part list** (owner's ruling, review I1):
    /// the same place, but the piece opens inside the faces — `open` moves,
    /// the faces and the list stay. The receiver falls back to `go`'s
    /// destination when the faces do not hold the piece.
    static func goInsideTheFaces(_ item: ResolveItem, firstParagraph: String?) {
        post(item, payload: insideTheFacesPayload(for: item, firstParagraph: firstParagraph))
    }

    /// What `goInsideTheFaces` posts: the row's place, marked.
    static func insideTheFacesPayload(for item: ResolveItem, firstParagraph: String?) -> [String: Any]? {
        payload(for: item, firstParagraph: firstParagraph).map(insideTheFaces)
    }

    private static func insideTheFaces(_ place: [String: String]) -> [String: Any] {
        var info: [String: Any] = place
        info[insideTheFacesKey] = true
        return info
    }

    /// Whether a row's click in `scope` opens its piece inside the faces: a
    /// Book or Part list that holds the row's piece. A piece's own list, a
    /// figure's, anything else: the ordinary place.
    static func opensInsideTheFaces(docId: String, scope: ResolveScope) -> Bool {
        guard case .pieces(let docIds, _) = scope else { return false }
        return docIds.contains(docId)
    }

    private static func post(_ item: ResolveItem, payload: [String: Any]?) {
        if case .note(let note) = item, !DocumentClass.isFigureDocId(note.docId) {
            var info: [String: Any] = ["annotation_id": note.annotation.id]
            if let pid = note.annotation.paragraphId { info[paragraphIdKey] = pid }
            MaughamEvent.post(.maughamNavigateToAnnotation, to: .keyWindow, payload: info)
        }
        guard let payload else { return }
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow, payload: payload)
    }

    /// The finding chip's twin of `goInsideTheFaces`.
    static func goInsideTheFaces(toDocId docId: String, paragraphId: String?) {
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow,
                          payload: insideTheFaces(payload(docId: docId, paragraphId: paragraphId)))
    }

    /// Open `docId` in the centre — with a paragraph, on it. The head's
    /// "Open the piece…" line and its letter's jumps.
    static func go(toDocId docId: String, paragraphId: String? = nil) {
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow,
                          payload: payload(docId: docId, paragraphId: paragraphId))
    }
}
