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

    /// `about` is the only always-present part of a letter, so it is not what
    /// decides emptiness. A letter is empty when every other part is: no
    /// `oneThing`, no working/habit/question entries, and `scenes` either
    /// `nil` or itself empty.
    var isEmpty: Bool {
        oneThing == nil && working.isEmpty && habits.isEmpty && questions.isEmpty
            && (scenes?.isEmpty ?? true)
    }
}
