import Foundation

/// A named editing pass on the manifest's `reviewPasses` list — the Review
/// persona's column headers on the board (M3 P1).
///
/// Position is array order; there is no separate order field, so reordering
/// is rewriting the array (Task 9's editor). `id` is stable identity: piece
/// `passStates` (Task 2) keys on it, and a rename must not disturb a single
/// piece's recorded state.
///
/// **Preset ids are a STABLE CONTRACT.** `"structural"`, `"line"`,
/// `"copyedit"`, `"proof"` are cited by P3's round records and must never
/// change once a project has states keyed on them — treat a rename of a
/// preset id as a breaking change to every project that has never customized
/// its pass list.
public struct ReviewPass: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The four presets a project starts with before any customization.
    /// `ProjectManifest.effectiveReviewPasses` returns these whenever the
    /// stored `reviewPasses` array is absent or empty — they are never
    /// written back to disk on their own (tripwire 11: no migrations).
    public static let presets: [ReviewPass] = [
        ReviewPass(id: "structural", name: "Structural"),
        ReviewPass(id: "line", name: "Line"),
        ReviewPass(id: "copyedit", name: "Copyedit"),
        ReviewPass(id: "proof", name: "Proof"),
    ]
}
