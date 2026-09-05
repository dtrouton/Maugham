import SwiftUI
import MaughamCore

/// **The letter's *Hold every scene to a turn?* offer, decided once**
/// (editorial letter P1 Task 9, spec §3.4).
///
/// Two hosts draw the letter — Author's Diagnostics pane and Review's round
/// cockpit — and both must answer the same question about the same run. The
/// decision and the write lived in each of them, near-verbatim, until fix
/// round 1: two copies of a predicate about the writer's own declared world is
/// two answers waiting to disagree, and the disagreement would be silent (one
/// column offering a clause the other knows is already filed).
///
/// `LetterSection` never sees this type. It is handed a closure or `nil`, so
/// the view stays store-free and its own half of the condition — a scene row
/// that does not turn — stays where the table is.
///
/// ## The predicate reads two tenses, and they are different questions
///
/// - **What the RUN was told.** `Letter.scenePosition` is a stamp, derived
///   before the round began from the project's type, the writer's intent and
///   the pass brief. `strong_default` is the one value the offer is for: the
///   strong form reached without a clause of the writer's, which is the gap
///   §3.4 says must be offered rather than assumed.
/// - **What the STATEMENT says now.** `ScenePosition.live` re-derives from the
///   intent as it stands. Only this can know about a ruling filed since the
///   round — without it a reopened pane offers again over the same run and a
///   second click files a duplicate saying what the statement already says.
///
/// ## Which live answers withdraw the offer
///
/// **A declared clause and an opt-out, and those two alone** (Denver's fix
/// round 1 ruling, applied to its own stated rationale — see the deviation
/// note below). `.strongDeclared` means they have answered it in their own
/// words; `ScenePosition.none` means they have said in their own words that
/// this piece does not move by scenes, and the opt-out beats everything.
///
/// **`.weak` does NOT withdraw it, and that is a deliberate departure from
/// the ruling's literal spelling** ("drawn iff `live` is EXACTLY
/// `.strongDefault`"), taken because the literal reading drops a case the
/// ruling's own rationale keeps. `ScenePosition.live` derives with
/// `passBrief: nil` — it must, since a brief is not a sentence the writer
/// wrote about this book — so a PROSE piece pushed into the strong form by
/// its pass brief stamps `strong_default` on the run and derives `.weak`
/// live. Under the literal rule that piece could never be offered the clause,
/// which is exactly the writer §3.4 wrote the offer for. Measured, not
/// assumed: `DiagnosticsPaneTests` pins both the opt-out withdrawal and the
/// brief-opted prose case, and the latter goes red under `== .strongDefault`.
@MainActor
enum TurnClauseOffer {

    /// Whether the offer stands. `store` optional because a host with no
    /// project has nowhere to file a ruling, and a button pressing into
    /// nowhere is worse than none.
    static func isOffered(
        letter: Letter, run: CompilerRun?, docId: String,
        store: ProjectStore?, filedRunId: String?
    ) -> Bool {
        guard let run, let store,
              letter.scenePosition == ScenePosition.strongDefault.rawValue,
              filedRunId != run.id else { return false }
        switch ScenePosition.live(store: store, docId: docId) {
        case .strongDeclared, ScenePosition.none: return false
        case .weak, .strongDefault: return true
        }
    }

    /// **Where the clause is filed: the scope the piece's intent RESOLVED to**
    /// (final review, Critical).
    ///
    /// A piece with no intent of its own is briefed, checked and drifted
    /// against the book's — `ProjectStore.effectiveIntent(forDocId:)`, the one
    /// resolution every reader of "which intent applies here" shares. Filing
    /// at `.document(docId)` regardless would mint a document-scoped statement
    /// whose essay is empty, and document scope wins from that moment on for
    /// the briefing (`CompilerEnvironment+Project`), the intent strip,
    /// `IntentDrift.mayTrailDraft` and `ScenePosition.live`. One click on a
    /// button offering a clause would have detached the chapter from the
    /// book's intent, and nothing on screen would have said so.
    ///
    /// `.document(docId)` remains the answer when nothing is declared
    /// anywhere: there is no intent to detach the piece from, and the piece's
    /// own is where a first sentence about it belongs.
    static func scope(store: ProjectStore, docId: String) -> Statement.Scope {
        store.effectiveIntent(forDocId: docId)?.scope ?? .document(docId)
    }

    /// **What the button says, in the same breath as where it writes.** The
    /// destination is invisible otherwise — the two acts differ only in which
    /// file gains a ruling — so the tense is the one thing that can tell a
    /// writer their click is about the whole book. `LetterSection` draws this
    /// string and decides nothing.
    static func buttonTitle(store: ProjectStore?, docId: String) -> String {
        guard let store else { return LetterSection.addToIntentTitle }
        return buttonTitle(for: scope(store: store, docId: docId))
    }

    static func buttonTitle(for scope: Statement.Scope) -> String {
        if case .project = scope { return LetterSection.addToBookIntentTitle }
        return LetterSection.addToIntentTitle
    }

    /// What the ruling's line says about where it came from. The voice is the
    /// piece's reader (`AuthorReader.editorName`, or the round's own stage),
    /// so a writer reading their
    /// own intent months later can see which letter asked.
    static func provenance(voice: String) -> String { "from \(voice)'s letter" }

    /// The whole builder: `nil` when the offer does not stand, else the
    /// closure that files it.
    ///
    /// `onFailure(nil)` is sent first, so a second attempt does not read under
    /// the first one's refusal. The write itself is `RulingPerformer.rule` —
    /// the one door into the writer-owned layer (spec §3.4) — and its refusal
    /// travels back to the host's own channel rather than being swallowed: a
    /// ruling the op log turned away would otherwise leave a button that looks
    /// pressed and an intent that never moved.
    static func handler(
        letter: Letter, run: CompilerRun?, docId: String,
        store: ProjectStore?, world: DeclaredWorldStore?,
        voice: String, filedRunId: String?,
        onFiled: @escaping (String) -> Void,
        onFailure: @escaping (String?) -> Void
    ) -> (() -> Void)? {
        guard isOffered(letter: letter, run: run, docId: docId,
                        store: store, filedRunId: filedRunId),
              let run, let store else { return nil }
        // Resolved once, before the press, so the button's tense and the
        // ruling's destination are the same answer rather than two reads that
        // could straddle a statement minted in between.
        let destination = scope(store: store, docId: docId)
        let title = buttonTitle(for: destination)
        return {
            onFailure(nil)
            Task {
                do {
                    try await RulingPerformer.rule(
                        LetterSection.turnClauseRuling,
                        provenance: provenance(voice: voice),
                        kind: .intent, forScope: destination,
                        store: store, world: world)
                    onFiled(run.id)
                } catch {
                    documentLog.error("\u{201C}\(title, privacy: .public)\u{201D} refused for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    onFailure(error.localizedDescription)
                }
            }
        }
    }
}
