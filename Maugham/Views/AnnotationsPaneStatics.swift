// Static-only by rule (#116): no instance members — instance state stays in the root.
import SwiftUI
import MaughamCore

// MARK: - The pane's pure statics — every one a test without a mount

extension AnnotationsPane {
    enum KindOption: String, CaseIterable, Identifiable, FilterRowItem {
        case all, comments, suggestions, queries, craft

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .comments: return "Comments"
            case .suggestions: return "Suggestions"
            case .queries: return "Queries"
            case .craft: return "Craft"
            }
        }

        var symbolName: String {
            switch self {
            case .all: return "circle"
            case .comments: return "bubble.left"
            case .suggestions: return "pencil.line"
            case .queries: return "questionmark.circle"
            case .craft: return "book"
            }
        }

        var kind: AnnotationKind? {
            switch self {
            case .all: return nil
            case .comments: return .comment
            case .suggestions: return .suggestedChange
            case .queries: return .query
            case .craft: return .craftNote
            }
        }
    }

    /// **Whether the document-scope empty state means "nothing here" or
    /// "narrowed to nothing"** (M4 P2 Task 8, T3 carry; widened in review,
    /// corrected in whole-branch review — see below).
    ///
    /// Pure so both readings are assertable without a mount — `pool` is every
    /// OPEN annotation on the document regardless of kind, author, triage or
    /// pass (`AnnotationFilter(statuses: [.open])`), `visibleRows` is fully
    /// filtered (`visibleAnnotations`), and the two can only disagree when
    /// one of those four — not the queue itself, and not resolved status —
    /// is what's showing nothing.
    ///
    /// **`pool` must stay pinned to `.open` and never widen to every status.**
    /// A writer who settles every note (the loop's own success state) has
    /// zero open notes and some number of resolved ones; if `pool` counted
    /// the resolved notes too, this predicate would read "narrowed to
    /// nothing" and the pane would claim Kind/Author/Triage/the pass filter
    /// was hiding notes that no such filter can reveal — only **Show
    /// Resolved** can, and that control isn't named in the copy this
    /// function's answer feeds. A cleared queue is the ordinary empty case,
    /// not a filtered one, and it's also the moment `emptyState`'s own
    /// `.settled` arm ("You've handled this check's notes.") is telling the
    /// SAME writer the SAME thing on the sibling pane — the two must not
    /// disagree about whether the queue is empty.
    static func documentQueueIsGenuinelyEmpty(
        pool: [Annotation], visibleRows: [Annotation]
    ) -> Bool {
        visibleRows.isEmpty && pool.isEmpty
    }

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
    static func letterVoice(run: CompilerRun?, passes: [ReviewPass]) -> String {
        guard let passId = run?.passId,
              let pass = ReviewPass.pass(id: passId, in: passes)
        else { return AuthorReader.nobody.editorName }
        return pass.effectiveEditorName
    }

    /// **A refused Reopen / Restore is SAID** (P3c plan 2 Task 8). The pane
    /// used to hand `reopenAnnotation` a bare `try?`, so a Restore the door
    /// refused — a Delete that is not hers to undo, drawn a frame before the
    /// refusal was knowable — did nothing at all (RULING-22's shape). The
    /// refusal's own sentence now goes to the window's notice channel
    /// (`MaughamEvent.postNotice`, the house path;
    /// `TranslationReviewPaneLogic.reply`'s shape) and comes back to the caller.
    @MainActor
    @discardableResult
    static func sayRefused(_ error: Error, in document: Document) -> String {
        let sentence = error.localizedDescription
        MaughamEvent.postNotice(sentence, projectURL: document.opStore.projectURL)
        return sentence
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

    /// Whether any bulk verb survives this document's posture (P3c Task 5).
    static func bulkOffersAVerb(posture: Posture) -> Bool {
        [AnnotationBulkActions.BulkVerb.accept, .stet, .triage(nil)]
            .contains { AnnotationBulkActions.offers($0, under: posture) }
    }
}
