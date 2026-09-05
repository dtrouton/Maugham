import Foundation
import MaughamCore

/// **Which review pass the queue is looking through** (M3 P2 Task 8) — the
/// pane's fourth filter, after kind/status, author and triage.
///
/// Two rules, both pure so the truth table is assertable without the pane
/// (`AnnotationPassStampTests`):
///
/// 1. **What a selected pass shows.** The notes stamped with it, AND every
///    unstamped note. A note carries a pass only if one was active when it was
///    written (`Annotation.reviewPassId`), so "unstamped" covers every note
///    written before passes existed, every note Claude wrote against a closed
///    piece, and every note made with no pass chosen. Those belong to each
///    pass's queue rather than to none: the alternative is that turning the
///    filter on the day it ships hides a writer's entire existing pile.
/// 2. **What the queue defaults to.** The piece's own remembered active pass —
///    so a click on a board chip, which records that pass and then opens the
///    piece (M3 P1), lands the writer in a queue already narrowed to it —
///    falling back to every pass when the piece has none.
///
/// The default is a *fallback*, not a write: `Selection.followActivePass` means
/// "whatever this piece's active pass is", so travelling to another piece
/// re-answers the question instead of carrying the last piece's answer over.
/// An explicit `.pass`/`.allPasses` is the writer overriding that, and it
/// holds across pieces and across scopes until they change it.
enum AnnotationPassFilter {

    /// What the pane's pass control is set to.
    enum Selection: Equatable {
        /// Nothing chosen — follow whichever pass the piece is being reviewed
        /// through. The state the pane starts in and returns to when the
        /// writer travels to another piece.
        case followActivePass
        /// Every pass, explicitly.
        case allPasses
        /// One pass, explicitly.
        case pass(String)
    }

    /// The pass id the queue is filtered to, or nil for every pass.
    ///
    /// `piece` is nil in project scope (there is no single piece to have an
    /// active pass) and when nothing is open — `.followActivePass` resolves to
    /// every pass there, while an explicit choice still applies across every
    /// piece, which is what makes "show me the whole project's copyedit notes"
    /// expressible.
    ///
    /// A selection naming a pass the project no longer has heals to every pass
    /// — `AnnotationsPane.effectiveAuthorFilter`'s shape, and for its reason: a
    /// stale selection would otherwise hide every stamped note with no control
    /// left on screen to say why.
    static func resolved(
        _ selection: Selection,
        piece: String?,
        memory: ActivePassMemory,
        passes: [ReviewPass]
    ) -> String? {
        switch selection {
        case .allPasses:
            return nil
        case .pass(let id):
            return passes.contains(where: { $0.id == id }) ? id : nil
        case .followActivePass:
            guard let piece else { return nil }
            // The one spelling of the read rule (tripwire: a second inline
            // validity check is the drift `validatedActivePass` exists for).
            return memory.validatedActivePass(forPiece: piece, in: passes)
        }
    }

    /// Whether `annotation` belongs in a queue filtered to `passId`
    /// (nil = every pass).
    ///
    /// **The coach's own lane is never filtered out — a LEGACY rule, and
    /// still load-bearing** (editorial letter P1, spec §4.1; two loops P1
    /// Task 8). Nothing stamps her lane any more: she reads CHECKS now
    /// (`AuthorReader`), and a check files in no lane at all. But real op
    /// logs carry the notes she filed under `workshop` while one resolution
    /// served both verbs, and she is deliberately absent from
    /// `effectiveReviewPasses`: the toolbar's menu cannot offer her and
    /// `resolved` above can never answer her id. So filtering her out under a
    /// stage leaves NO selection that brings her back — assign such a piece
    /// to Line and every letter she wrote about it vanishes from the queue
    /// with no control on screen to say why. Her stamp therefore behaves like
    /// an unstamped note: in every pass's queue.
    ///
    /// Keyed on the LANE id (`ReviewPass.coachPreset.id`) rather than on
    /// `ProjectManifest.effectiveCoach`, so vacating the seat does not
    /// retroactively hide the rounds she already filed — they stay in the
    /// sidecar as history, and the queue is where the writer disposes of them.
    static func matches(_ annotation: Annotation, passId: String?) -> Bool {
        guard let passId else { return true }
        guard let stamp = annotation.reviewPassId else { return true }
        if stamp == ReviewPass.coachPreset.id { return true }
        return stamp == passId
    }
}
