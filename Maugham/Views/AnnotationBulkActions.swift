import Foundation
import MaughamCore

/// **Bulk operations over the annotation queue** (M3 P2 Task 5, spec §5). A
/// writer who has just triaged forty notes should not have to click forty
/// times to act on them.
///
/// Two halves, deliberately separated:
///
/// - `plan` is PURE. It answers *which notes this verb honestly reaches*, so
///   the bar can say "Accept 4 of 6" **before** the click rather than reporting
///   the shortfall afterwards. Its whole truth table is testable without
///   mounting the pane (`AnnotationBulkActionsTests`).
/// - `perform` runs the verbs on a real `Document`, **sequentially, one note at
///   a time**, collecting per-item failures instead of halting on the first.
///
/// ### The rule `plan` encodes
///
/// **A bulk verb reaches exactly where the ROW's own verb reaches, and no
/// further.** The bar is a faster way to press the buttons already on screen —
/// not a second, more permissive policy. Each arm falls out of that one rule:
///
/// - **Accept** — the row offers Accept only on an unresolved note
///   (`AnnotationRow.showsReopen` swaps the dispositions for Reopen once it is
///   settled), and it gates a *stale* suggestion behind an "Apply anyway"
///   confirm, because applying it would overwrite text the writer has edited
///   since. A batch cannot ask forty times, and answering *for* the writer in
///   either direction is worse than declining: a skipped note is still open and
///   still one click from the confirm it deserves. So a stale suggestion is out
///   of plan — and a stale *comment* is not, because the row's gate is
///   `kind == .suggestedChange && isStale` and a comment has no replacement
///   text to misplace.
///
///   **A `.query` is out of plan for accept entirely**, and this is the arm the
///   rule was worth writing down for. A query row has no Accept affordance at
///   all — `AnnotationRow.dispositions`' `.query` case offers *Reply…*, which
///   opens a sheet and calls `acceptAnnotation(id:userResponse:)` with the
///   writer's own words. Bulk accept would call it with `userResponse: nil`:
///   the question leaves the open queue answered with **silence**, and it does
///   so quietly, because accept registers no undo for a non-suggestion kind and
///   `.accepted` has no Reopen arm. Reply is the verb, a reply is text, and text
///   is the one thing a batch cannot supply.
/// - **Stet** — a resolution like the others: open notes only. "Skips the
///   already-stetted" is that rule's special case, not a clause of its own.
///   Staleness gates nothing here; a stet moves no text.
/// - **Triage** — a mark is *not* a resolution (`Document.triageAnnotation`),
///   so a resolved note takes one too and the plan reaches every status. The
///   one exclusion is the one the row itself makes: its menu disables the mark
///   a note already holds, because re-applying it appends an op whose ⌘Z undoes
///   nothing the writer can see. Forty of those is that defect forty times.
///
/// ### Undo: one registration per note, and no group of our own
///
/// There is **no manual undo group** around a batch, by ruling. Grouping would
/// have to cover accept, and `Document.acceptAnnotation` calls
/// `removeAllActions` from *inside* itself (ADR 0023's D1 — an external buffer
/// replace makes every native typing-undo action unsound); a group wrapped
/// around that is the D1 violation the corollary exists to prevent.
///
/// Each note therefore registers its own undo action, and each one appends its
/// own compensating op (three stets undone append three `annotationReopen`
/// ops), which is what makes a triage undo give every note back the mark *it*
/// held rather than blanket-clearing the batch.
///
/// How many ⌘Z presses that costs the writer is `NSUndoManager`'s decision and
/// not ours: `groupsByEvent` coalesces registrations made within one event into
/// a single top-level group, and measurement says it does so here — **one ⌘Z
/// reverses the batch**. Nothing fights that; one deliberate click undone by
/// one keystroke is what a writer expects. (The plan called for ⌘Z peeling one
/// note at a time; the platform does not hold to that premise, and forcing it
/// would mean toggling `groupsByEvent` on the window's live manager mid-event —
/// documented as not allowed, and a far worse trade than the behaviour we get
/// for free. `AnnotationBulkActionsTests` pins the measurement.)
///
/// **Suggestion accepts are the exception, and it is not this file's doing**:
/// each accept's `removeAllActions` wipes the previous one's registration, so a
/// batch of three leaves exactly one undoable step — the last. The recourse for
/// the rest is the row's own **Revert**, which reaches any accepted suggestion
/// at any time, and the bar's Accept button says so in its tooltip.
enum AnnotationBulkActions {

    /// The verbs the bulk bar offers. `triage(nil)` is Clear.
    enum BulkVerb: Equatable, Hashable {
        case accept
        case stet
        case triage(TriageMark?)

        /// The one word the bar uses for this verb — the button, the menu item
        /// and the summary notice all read it here, so two surfaces cannot come
        /// to call the same verb different things (`TriageMark.queueLabel`'s
        /// precedent).
        var word: String {
            switch self {
            case .accept: return "Accept"
            case .stet: return "Stet"
            case .triage(let mark): return mark?.queueLabel ?? "Clear"
            }
        }

        /// What the summary notice says HAPPENED ("2 of 3 accepted").
        var pastTense: String {
            switch self {
            case .accept: return "accepted"
            case .stet: return "stetted"
            case .triage: return "marked"
            }
        }
    }

    // MARK: - The plan

    /// Which of these notes the verb honestly applies to, in the order given
    /// (which is the queue's own order — see `AnnotationQueueOrder`).
    static func plan(_ annotations: [Annotation], verb: BulkVerb) -> [String] {
        annotations.filter { applies(verb, to: $0) }.map(\.id)
    }

    /// The per-note arm of the rule in this file's doc comment. Separate from
    /// `plan` so a row-level caller could ask the same question of one note
    /// without building an array.
    static func applies(_ verb: BulkVerb, to annotation: Annotation) -> Bool {
        switch verb {
        case .accept:
            guard annotation.status == .open else { return false }
            // A query has no Accept on its row at all — only Reply…, and a
            // reply is text a batch cannot write. See above.
            guard annotation.kind != .query else { return false }
            // The row would have asked first; a batch cannot. See above.
            return !(annotation.kind == .suggestedChange && annotation.isStale)
        case .stet:
            return annotation.status == .open
        case .triage(let mark):
            return annotation.triage != mark
        }
    }

    /// What the bar's button says. Honest before the click: the shortfall is
    /// visible as "4 of 6" rather than discovered in the summary afterwards.
    static func buttonTitle(
        _ verb: BulkVerb, planned: Int, targetCount: Int, hasSelection: Bool
    ) -> String {
        if planned < targetCount {
            return "\(verb.word) \(planned) of \(targetCount)"
        }
        return hasSelection
            ? "\(verb.word) \(planned) selected"
            : "\(verb.word) all \(planned)"
    }

    // MARK: - The outcome

    /// What a run did, and what it could not do. Failures are collected, never
    /// thrown out of the loop and never surfaced one alert at a time.
    struct Outcome: Equatable {
        let verb: BulkVerb
        var succeeded: [String] = []
        /// Accepts REFUSED because the quoted passage is no longer in the
        /// paragraph (RULING-5). Not an error the writer caused and not one
        /// they can retry — the recourse is a fresh suggestion.
        var anchorLost: [String] = []
        /// Anything else that threw. Logged individually; counted here so the
        /// notice can say the run was incomplete rather than implying success.
        var failed: [String] = []

        var attempted: Int {
            succeeded.count + anchorLost.count + failed.count
        }

        /// ONE summary for the whole batch, or nil when everything landed. A
        /// notice on every run would make the one that matters invisible by
        /// making it ordinary; no notice at all would be the M5-AN-050 silence
        /// back again, forty notes at a time.
        var notice: String? {
            guard !anchorLost.isEmpty || !failed.isEmpty else { return nil }
            var parts = ["\(succeeded.count) of \(attempted) \(verb.pastTense)."]
            if anchorLost.count == 1 {
                parts.append(
                    "One suggestion could no longer be applied — the passage it "
                    + "would replace is no longer in its paragraph.")
            } else if anchorLost.count > 1 {
                parts.append(
                    "\(anchorLost.count) suggestions could no longer be applied "
                    + "— the passage each would replace is no longer in its "
                    + "paragraph.")
            }
            if !anchorLost.isEmpty {
                parts.append(
                    "Those notes stay open; ask Claude for fresh suggestions "
                    + "against the current text.")
            }
            if failed.count == 1 {
                parts.append("One more could not be completed.")
            } else if failed.count > 1 {
                parts.append("\(failed.count) more could not be completed.")
            }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - The executor

    /// Runs `verb` over `ids` one at a time against the live document.
    ///
    /// Sequential on purpose — these are op-log appends against one actor and
    /// each registers its own undo action; a concurrent fan-out would interleave
    /// the registrations into an order no ⌘Z could reverse sensibly. Accept is
    /// the one verb routed through a throwing catch rather than `try?`: a lost
    /// span anchor is a refusal the writer must hear about (RULING-5), and the
    /// batch carries on past it rather than halting on the first.
    @MainActor
    static func perform(
        _ verb: BulkVerb, on ids: [String], in document: Document,
        undoManager: UndoManager?
    ) async -> Outcome {
        var outcome = Outcome(verb: verb)
        for id in ids {
            do {
                switch verb {
                case .accept:
                    try await document.acceptAnnotation(
                        id: id, undoManager: undoManager)
                case .stet:
                    try await document.stetAnnotation(
                        id: id, undoManager: undoManager)
                case .triage(let mark):
                    try await document.triageAnnotation(
                        id: id, mark: mark, undoManager: undoManager)
                }
                outcome.succeeded.append(id)
            } catch let error as AnnotationAcceptError
                        where error == .suggestionAnchorLost {
                outcome.anchorLost.append(id)
            } catch {
                documentLog.error("bulk \(verb.pastTense, privacy: .public) failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                outcome.failed.append(id)
            }
        }
        return outcome
    }
}
