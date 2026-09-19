import SwiftUI
import MaughamCore

/// The Inspector's review section (M3 P1 Task 4): the projected
/// ``ReviewStatus`` read-only at the top, then one row per
/// `ProjectManifest.effectiveReviewPasses` entry with a menu naming where this
/// piece stands on that pass.
///
/// **This replaces the free-string status picker in both inspector arms.** The
/// writer used to declare "revising" directly, which meant the app's one
/// adjudication field said nothing about *what* had been revised; now the
/// verdict is derived from the passes the writer actually ruled on, and the
/// place they rule is here.
///
/// **One view, two hosts, and the WRITE stays at the host.** `PieceInspector`
/// and `InspectorView` render the identical ladder — two hand-kept copies is
/// the drift `StatusSwatch` and `IntentAffordanceRow` were each extracted to
/// end — but neither the rendering nor a shared closure decides how the write
/// happens, because the two hosts genuinely differ there: `InspectorView`
/// keeps a 500 ms debounced draft for its text fields, and the ladder must NOT
/// ride it (see that file's `onSet`). Keeping `onSet` at the host is also what
/// keeps `PersonaPaneRegistryTests`' census meaningful — it names the SURFACES
/// that can write a pass state, and a shared leaf writer would collapse the
/// census to this one file and hide them.
struct PassLadder: View {
    let item: StructureItem
    let passes: [ReviewPass]
    /// `(passId, state)` — `nil` means untouched, and the store verb removes
    /// the key rather than storing a fourth state.
    let onSet: (String, PassState?) -> Void

    /// The row titles. `.skipped` reads as "Skip" because the writer is making
    /// a decision, not describing a past one — it is an adjudication ("this
    /// pass does not apply to this piece"), which is why `ReviewStatus` counts
    /// an all-skipped piece as final.
    static let untouchedTitle = "Untouched"
    static let inProgressTitle = "In Progress"
    static let doneTitle = "Done"
    static let skipTitle = "Skip"

    /// **How a row is named to the accessibility tree** (macOS 27 shell slice,
    /// Task 4).
    ///
    /// A `Picker(.menu)` mounts no AppKit control on macOS 27, so a test can
    /// only reach this row through the tree — and there the row's own label
    /// ("Structural") is a SEPARATE sibling node, while the inspector publishes
    /// a fifth `AXPopUpButton` that is not a ladder row at all (Publishing's
    /// *Start on*). Without a name of its own the only way to say *which pass
    /// this is* would be "the static text immediately before it", and this
    /// suite has already been bitten once by a positional read — the
    /// publishing section's page-range menu was measured arriving
    /// asynchronously at index 0 mid-test.
    ///
    /// Additive and invisible: VoiceOver still reads the row's own label, which
    /// is where the writer's words are.
    static func identifier(forPass passId: String) -> String {
        "passLadder.\(passId)"
    }

    var derivedStatus: ReviewStatus {
        ReviewStatus.derived(
            passStates: item.passStates,
            passes: passes,
            legacyStatus: item.status)
    }

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 5) {
                Circle()
                    .fill(StatusSwatch.color(for: derivedStatus))
                    .frame(width: 6, height: 6)
                Text(StatusSwatch.label(for: derivedStatus))
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(passes) { pass in
            Picker(pass.name, selection: binding(for: pass)) {
                Text(Self.untouchedTitle).tag(PassState?.none)
                Text(Self.inProgressTitle).tag(PassState?.some(.inProgress))
                Text(Self.doneTitle).tag(PassState?.some(.done))
                Text(Self.skipTitle).tag(PassState?.some(.skipped))
                // A state written by a NEWER build gets a row of its own,
                // showing its raw value, so the menu can render the selection
                // it actually holds. Without it no tag matches, the popup
                // shows blank, and the writer's next choice looks like a
                // correction of nothing — the lossless round-trip `PassState`
                // guarantees on disk would be honest and invisible.
                if case .unknown(let raw) = item.passStates?[pass.id] {
                    Text(raw).tag(PassState?.some(.unknown(raw)))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(Self.identifier(forPass: pass.id))
        }
    }

    /// A setter that only ever forwards — no store call, no derivation, nothing
    /// that can suspend (tripwire 3). The host decides what a write means.
    private func binding(for pass: ReviewPass) -> Binding<PassState?> {
        Binding(
            get: { item.passStates?[pass.id] },
            set: { onSet(pass.id, $0) })
    }
}
