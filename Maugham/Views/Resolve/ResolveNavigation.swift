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
        return [ManuscriptNavigation.docIdKey: docId, "paragraph_id": paragraphId]
    }

    /// Go there. Posts through `MaughamEvent` only (tripwire 21), to the key
    /// window: a note's annotation event first, then the paragraph event.
    static func go(_ item: ResolveItem, firstParagraph: String?) {
        let payload = payload(for: item, firstParagraph: firstParagraph)
        if case .note(let note) = item, !DocumentClass.isFigureDocId(note.docId) {
            var info: [String: Any] = ["annotation_id": note.annotation.id]
            if let pid = note.annotation.paragraphId { info["paragraph_id"] = pid }
            MaughamEvent.post(.maughamNavigateToAnnotation, to: .keyWindow, payload: info)
        }
        guard let payload else { return }
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow, payload: payload)
    }
}
