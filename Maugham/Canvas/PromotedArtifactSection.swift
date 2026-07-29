import SwiftUI

/// What a promoted thing became, and the way to open it — **the one section,
/// used by both inspector arms.**
///
/// **It lived in `ScrapInspector` for one slice and only cards had it.** A card
/// and a region gained the same field in 1C-c2, drew the same stripe, and were
/// announced with the same VoiceOver term; the card arm said what it produced,
/// offered **Open**, and rendered the dangling case, and the region arm said
/// nothing at all. A writer saw a permanent stripe on a region's chrome bar with
/// no way to learn what it produced, no way to open it, and no way to discover
/// that the palette card had been deleted. `ScrapInspector`'s own doc comment
/// states the rule that indicted the omission — CLAUDE.md rule 8 asks every new
/// data type for a surface that can inspect and act on it — and this is the
/// previous slice's Delete-button asymmetry recurring, so the fix is one
/// implementation both arms are handed rather than a second copy.
struct PromotedArtifactSection: View {

    /// What the thing has produced, if anything. Lifted out of the view so the
    /// three-way decision is reachable from a test that hosts no SwiftUI.
    enum ArtifactState: Equatable {
        case notPromoted
        case promoted(itemID: String, title: String)
        /// A mark whose artifact is no longer in the project.
        case artifactMissing(itemID: String)
    }

    /// What is being described — and **it changes the noun and nothing else.**
    ///
    /// **The region arm named a kind, and 1C-c2a made that a lie.** Its sentence
    /// read *Became the palette card “…”* on the stated grounds that a region's
    /// mark could only ever name a palette card, the other half of its row being
    /// a piece binding that produced no artifact. Task 2 put `.researchNote` on
    /// that row; this file was in no task's diff, so nothing recompiled and
    /// nothing failed, and a region promoted to a research note said *Became the
    /// palette card “Act II fog”* over an **Open** button that opened a note.
    ///
    /// So `became` names no kind for either subject: both arms can now produce
    /// more than one, and neither is told which. It is deliberately not a
    /// `switch` with two identical arms — that shape invites a later edit to
    /// re-divide them, which is exactly how this broke.
    ///
    /// `noun` still differs, and that is still correct: the dangling sentence
    /// says which *thing* on the canvas was promoted, which no promotion can
    /// change. (`PromotionSource.noun` is the other spelling of that word, one
    /// layer down, where a refusal needs it for a line as well.)
    enum Subject {
        case card
        case region

        var noun: String {
            switch self {
            case .card: return "card"
            case .region: return "region"
            }
        }

        func became(_ title: String) -> String { "Became “\(title)”" }
    }

    let state: ArtifactState
    let subject: Subject
    let onOpen: (String) -> Void

    static func artifactState(promotedItemID: String?, title: String?) -> ArtifactState {
        guard let itemID = promotedItemID else { return .notPromoted }
        guard let title else { return .artifactMissing(itemID: itemID) }
        return .promoted(itemID: itemID, title: title)
    }

    var body: some View {
        Section("Promoted") {
            switch state {
            case .notPromoted:
                Text("Not promoted yet.").font(.caption).foregroundStyle(.secondary)
            case .promoted(let itemID, let title):
                HStack(spacing: 6) {
                    Text(subject.became(title)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button("Open") { onOpen(itemID) }
                        .buttonStyle(.borderless)
                }
            case .artifactMissing:
                Text("This \(subject.noun) was promoted, and what it produced is no "
                     + "longer in the project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
