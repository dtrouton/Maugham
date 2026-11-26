import Foundation
import MaughamCore

/// **Read anywhere, act only on the open piece** (Denver, 2026-11-18).
///
/// To resolve reads every piece the faces cover without loading one
/// (`ResolveReader`). Acting is narrower: a verb that is a `Document` method —
/// accept, reject, stet, triage, reopen, delete or restore on a note; toggle,
/// archive, delete or reorder on a to-do; a bulk action — is offered only
/// where the row's piece is the one open in this window's centre, because the
/// only `Document` To resolve may act through is the one the editor holds
/// (`DocumentStore.document(forDocId:)`). Nothing loads a second one to act:
/// its ops would sit where the writer's ⌘Z never reaches, and a second live
/// `Document` on a path is the paragraph-loss defect.
///
/// Every other piece's row is readable, offers none of those verbs (hidden,
/// never disabled) and opens its piece on a click (`ResolveNavigation`),
/// where the row then offers them. The two verbs that need no `Document` —
/// a finding's Answer and a note's Keep as lesson — stay offered everywhere,
/// subject to posture. A Book-level to-do lives on the project stream, which
/// needs no `Document`: it keeps exactly the verbs its posture gives it.
///
/// **The gate only removes.** Posture still decides what the open piece's
/// rows offer (`AnnotationRowVerbs.decide`, `TaskRowVerbs.decide`); this
/// takes that answer and never adds to it. A figure's notes are not gated
/// here: they act through the figure's own host (`FigureRowGate`).
enum ResolveVerbGate {

    /// **May this window act on `docId`'s rows?** True only when the piece is
    /// what the centre shows (`subject.open == .item(docId)`) and its
    /// document is registered — a piece whose editor has not loaded yet has
    /// no `Document` to act through. With the canvas or anything else in the
    /// centre, the faces' piece reads and does not act.
    static func mayAct(onDocId docId: String, subject: WindowSubject,
                       isRegistered: (String) -> Bool) -> Bool {
        mayAct(onDocId: docId, openDocId: subject.open.itemID, isRegistered: isRegistered)
    }

    /// The same question for a host that knows only the centre's piece — the
    /// old document panes, whose `document`/`activeDocId` is the open piece.
    /// `openDocId` is `subject.open.itemID`.
    static func mayAct(onDocId docId: String, openDocId: String?,
                       isRegistered: (String) -> Bool) -> Bool {
        openDocId == docId && isRegistered(docId)
    }

    /// **The one piece bulk may act over** (shell plan 3 Task 6, carried
    /// from plan 2): the piece open in the centre, wherever the faces' list
    /// holds it — its own list, or the Book or Part list it was opened
    /// inside — and only while its document is registered. Nil anywhere
    /// else: bulk never reaches a piece that is not open.
    static func bulkDocId(scope: ResolveScope, openDocId: String?,
                          isRegistered: (String) -> Bool) -> String? {
        guard let openDocId, scope.docIds.contains(openDocId),
              mayAct(onDocId: openDocId, openDocId: openDocId, isRegistered: isRegistered)
        else { return nil }
        return openDocId
    }

    /// A note's verbs: the posture's answer on the open piece; off it, only
    /// Keep as lesson, and only where the lessons ledger's posture offered it.
    static func noteVerbs(_ decided: AnnotationRowVerbs, mayAct: Bool) -> AnnotationRowVerbs {
        guard !mayAct else { return decided }
        return AnnotationRowVerbs(
            acceptOrReject: false, dispose: false, answerAsRuling: false,
            makeChoice: false, keepAsLesson: decided.keepAsLesson, ownNote: false)
    }

    /// A check finding's verbs: Answer files a ruling (no `Document`) and is
    /// offered wherever the posture offers it; Promote to Task writes a task
    /// on the piece's `Document`, so only on the open piece.
    static func findingVerbs(answer: Bool, promote: Bool,
                             mayAct: Bool) -> (answer: Bool, promote: Bool) {
        (answer: answer, promote: promote && mayAct)
    }

    /// A to-do's verbs: the posture's answer on the open piece or on the
    /// Book's own stream; nothing anywhere else.
    static func taskVerbs(_ decided: TaskRowVerbs, mayAct: Bool,
                          isBookLevel: Bool) -> TaskRowVerbs {
        mayAct || isBookLevel ? decided : .none
    }
}
