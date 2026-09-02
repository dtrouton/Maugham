import Foundation

/// The compiler's sixth section (P1): one editorial letter per run, read as
/// prose rather than a list of findings. Task 2 parses it off the wire; this
/// type only carries what a parse (or a decoded sidecar) hands it.
///
/// Codable is synthesized — every part but `about` is optional, so a future
/// P2/P3 addition falls out through `decodeIfPresent` with no hand-written
/// decoder, the same discipline `CompilerRun` and `DiagnosticIngest.SectionedOutcome`
/// already keep for their own optional fields.
struct Letter: Codable, Equatable, Sendable {
    /// One thing the letter's "what's working" section names: what it is,
    /// and where.
    struct Working: Codable, Equatable, Sendable {
        let refs: [Diagnostic.Ref]
        let what: String
        let why: String
    }

    /// One named habit the letter raises, with the paragraphs it recurs in
    /// and, optionally, what it costs the reader and an exercise for it.
    struct Habit: Codable, Equatable, Sendable {
        let name: String
        let refs: [Diagnostic.Ref]
        let cost: String
        let lesson: String?
        let exercise: String?
    }

    /// One open question the letter poses about the draft.
    struct Question: Codable, Equatable, Sendable {
        let refs: [Diagnostic.Ref]
        let question: String
    }

    /// One scene-level note — what the scene wants, what changes in it, its
    /// turn, and optionally its charge.
    struct Scene: Codable, Equatable, Sendable {
        let refs: [Diagnostic.Ref]
        let wants: String
        let changes: String
        let turn: String
        let charge: String?
    }

    let about: String
    let oneThing: String?
    let working: [Working]
    let habits: [Habit]
    let questions: [Question]
    /// `nil` means the letter's scene position said there is nothing to say
    /// about scenes — a lyric or essayistic piece — and it is distinct from
    /// `[]`, which is a scene table with no rows in it. Both are reachable
    /// from the wire: `scenes` absent or `null` parses as `nil`, and
    /// `"scenes":[]` parses as `[]` (`DiagnosticIngest.parseLetter`, Task 2).
    /// The pair is pinned by `DiagnosticIngestTests.test_scenesAbsentOrNullIsNil`.
    let scenes: [Scene]?
    /// `ScenePosition.rawValue` (Task 3). `var` because Task 3 stamps it onto
    /// an already-parsed letter; every other stored property here is `let`.
    /// `nil` on a letter parsed before Task 3 exists, or on a section that
    /// said nothing about position.
    var scenePosition: String?

    /// The model's answer to what the writer asked this round (P2 Task 3),
    /// scrubbed for a leaked paragraph id like `about` and `one_thing` — a
    /// FIELD rather than an entry, so a leak empties it instead of costing
    /// the letter everything else it got right.
    ///
    /// `nil` when nothing was asked, and also when something was asked and
    /// the model answered nothing: the letter is never refused over a missing
    /// answer, exactly as it is never refused over a missing say-back.
    ///
    /// **`= nil` is load-bearing, not tidiness.** These two are `var`s with
    /// default values, so Swift synthesizes memberwise-initializer defaults
    /// for them (SE-0242) and every `Letter(...)` written before P2 still
    /// compiles unchanged. Adding them without the default would put two new
    /// labels on ~20 call sites for no behavioural reason.
    var answer: String? = nil

    /// The ask exactly as it was briefed, stamped at `record` from the run
    /// rather than read off the answer (P2 Task 3) — the same discipline as
    /// `scenePosition`, and for a second reason of its own: the writer can
    /// clear or rewrite their ask the moment the check ends, and a section
    /// that said what was answered without saying what was asked would be
    /// half a conversation.
    var asked: String? = nil

    /// `about` is the only always-present part of a letter, so it is not what
    /// decides emptiness. A letter is empty when every other part is: no
    /// `oneThing`, no working/habit/question entries, no `answer`, and
    /// `scenes` either `nil` or itself empty.
    ///
    /// **`answer` counts and `asked` does not** (P2 Task 3). An answer is a
    /// part of the letter the writer reads; the ask is a stamp saying what
    /// the run was briefed on, the way `scenePosition` is a stamp saying what
    /// form it was told this piece takes. A letter carrying only the stamp
    /// answered nothing and has nothing to show.
    var isEmpty: Bool {
        oneThing == nil && working.isEmpty && habits.isEmpty && questions.isEmpty
            && answer == nil && (scenes?.isEmpty ?? true)
    }
}
