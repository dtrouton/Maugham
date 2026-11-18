import SwiftUI
import MaughamCore

// Moved from the Annotations pane's statics when that pane was deleted
// (shell plan 2 Task 7): the round's letter's signature and the pass-order
// nudge's decision, both drawn by To resolve's head.
extension ResolveHead {
    /// **Who signs what the cockpit is drawing — the standing ROUND's own
    /// editor, never the pass the writer has selected now** (two loops P1
    /// Task 5, Controller Ruling 5).
    ///
    /// The letter, the lesson and the turn clause on screen were written by
    /// the editor whose round produced them, and a chip click that moves the
    /// piece into another lane does not rewrite what a note in the queue was
    /// signed. Reading `cockpitActivePass` here re-signed a standing letter
    /// with whichever lane the writer had just selected — Gould's words filed
    /// under Perkins — and, with the seat vacated or the piece parked in no
    /// lane, signed a real round "Claude".
    ///
    /// `ReviewPass.pass(id:in:)` rather than the ladder alone, so a round the
    /// coach ran is signed with her name and not her schema id. A record
    /// naming no pass, or one naming a pass this project has since retired,
    /// falls back to the passless byline — the same one Author's own unread
    /// piece gets, which is where that constant's single production use lives.
    ///
    /// Static and pure so the rule can be asked over its inputs rather than
    /// only down the path a mounted disclosure takes — the selection is not a
    /// parameter, which is how it cannot creep back in.
    static func roundLetterVoice(run: CompilerRun?, passes: [ReviewPass]) -> String {
        guard let passId = run?.passId,
              let pass = ReviewPass.pass(id: passId, in: passes)
        else { return AuthorReader.nobody.editorName }
        return pass.effectiveEditorName
    }

    /// What the pass-order nudge draws: the earlier open pass, and the two
    /// verbs that close it.
    struct PassOrderNudgeDecision {
        let pass: ReviewPass
        let onMarkDone: (() -> Void)?
        let onSkip: (() -> Void)?
    }

    /// **The nudge, decided without a window** (P3c plan 2 Task 9) — the whole
    /// of `passOrderNudge`'s wiring, so a test can drive it from the window's
    /// posture door to the host's pass-state write.
    ///
    /// Document scope only, and only where `PassOrderAdvice` names an earlier
    /// open pass. **The verbs follow the piece's posture; the advice does not**
    /// (P3c Task 6, plan ruling R3): a reviewer working a lane is still told
    /// the earlier pass is open — she simply is not offered the ruling that
    /// closes it. Each verb writes the NAMED earlier pass through the host's
    /// `onSetPassState`, never the store directly.
    static func passOrderNudgeDecision(
        isProjectScope: Bool, docId: String?,
        memory: ActivePassMemory, passes: [ReviewPass],
        passStates: [String: PassState]?,
        posture: (String) -> Posture,
        onSetPassState: @escaping (String, String, PassState?) -> Void
    ) -> PassOrderNudgeDecision? {
        guard !isProjectScope, let docId,
              let earlier = PassOrderAdvice.advice(
                forPiece: docId, memory: memory,
                passes: passes, passStates: passStates)
        else { return nil }
        let offersVerbs = PassLadder.offersRulings(under: posture(docId))
        return PassOrderNudgeDecision(
            pass: earlier,
            onMarkDone: offersVerbs ? { onSetPassState(docId, earlier.id, .done) } : nil,
            onSkip: offersVerbs ? { onSetPassState(docId, earlier.id, .skipped) } : nil)
    }
}
