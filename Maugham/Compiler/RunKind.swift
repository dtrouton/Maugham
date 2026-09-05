import Foundation

/// **Which loop asked for this run** — Author's ⌘R or Review's Run round.
///
/// The two verbs have always been one act: `CompilerOrchestrator.runRequested`
/// serves the keystroke in Author and the button in the round cockpit
/// identically, and the persona the writer is standing in is not an input to
/// it. That is what this type ends. A run now says which loop it belongs to,
/// minted at the keystroke in exactly one place (`CompilerRunModifier`, the
/// only site with a persona to mint from) and carried on `StreamingRun` to the
/// record, so the preview and the answer that supersedes it cannot describe
/// two different verbs.
///
/// **A typed pair rather than a `Bool`.** `isRound` would read as a modifier
/// on one verb; these are two, and the difference between them is about to
/// become what the run is FOR rather than a flag it carries. Adding a third
/// loop is adding a case, and every site that decides on the kind is then the
/// compiler's problem rather than a reviewer's — `Acknowledgment`'s reasoning,
/// one file over.
///
/// `String`-raw and `Codable` because it is stamped on `CompilerRun` and so
/// reaches the per-document sidecar on disk: a rename is a wire change, and
/// `CompilerRun.kind` is optional precisely so a record written before this
/// type existed still decodes (`CompilerRun.effectiveKind` states the legacy
/// rule for those).
enum RunKind: String, Codable, Equatable, Sendable {
    /// Author's ⌘R: the delta since the marker, read by the reader, filed in
    /// no lane.
    case check
    /// Review's Run round: the piece whole, read by the pass's editor, filed
    /// as a numbered round in that pass's lane.
    case round

    /// **The mint, and the whole of it.** Review is the round loop; every
    /// other persona that can reach a run is checking.
    ///
    /// Exhaustive rather than `persona == .review ? .round : .check`, so a
    /// fifth persona is a compile error here — a new mode of the window
    /// deserves a decision about which loop its runs belong to, not the
    /// silence a defaulted ternary would give it.
    static func of(persona: Persona) -> RunKind {
        switch persona {
        case .review: return .round
        case .plan, .author, .publish: return .check
        }
    }
}
