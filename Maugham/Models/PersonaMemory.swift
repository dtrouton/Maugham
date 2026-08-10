import Foundation
import MaughamCore

/// Where each persona was last standing — one remembered right-pane segment
/// per persona.
///
/// This is what makes a persona a WORKSPACE rather than a filter. The first
/// shape of the persona shell kept whatever segment the destination persona
/// also offered, which is defensible on paper and wrong in the hand: Author
/// offers Research, so ⌘1 (Plan, whose binder home was Research) followed by
/// ⌘2 left the writer's binder on Research and "lost the binder" (2026-07-25
/// smoke, defect B). Remembering per persona makes the round trip lossless.
///
/// **It remembered a binder segment too, until shell-finish stage 2b Task 7.**
/// The strip died with `BinderSegment`: every persona's left column is now the
/// project's own tree, so there is no left-hand position to remember and no
/// round trip for one to be lossy across. The right column keeps both — its
/// panes are still a choice — and the on-disk `binder` map goes inert rather
/// than migrated (tripwire 11), which the tolerant decoder below already
/// handles for free.
///
/// Recorded on DEPARTURE only — `PersonaModifier.applyPersonaChange` snapshots
/// the persona being left on every switch. That is sufficient without also
/// tracking every segment click: a remembered value can only be *read* by
/// switching INTO a persona, which can only happen after switching OUT of it,
/// which is exactly when the snapshot is taken. It also means a reopened
/// project (whose columns are restored verbatim from `UIState`) records its
/// real, restored position the first time the writer leaves.
///
/// Persisted in `UIState`, so it is per PROJECT and shared last-writer-wins by
/// two windows on the same project — deliberately the same shape as `persona`
/// itself, which sits beside it.
public struct PersonaMemory: Codable, Equatable, Sendable {
    /// Keyed by `Persona.rawValue` rather than by `Persona`: a dictionary with
    /// an enum key does not round-trip through `JSONEncoder` as an object, and
    /// `ui-state.json` is a file a human reads.
    private var detail: [String: DetailSegment]

    public static let empty = PersonaMemory()

    public init(detail: [String: DetailSegment] = [:]) {
        self.detail = detail
    }

    // MARK: - Reading

    /// The right-pane segment `persona` should be restored to. Same validity
    /// filtering against `Persona.panes`, falling back to `defaultPane`.
    public func restoredDetailSegment(for persona: Persona) -> DetailSegment {
        if let remembered = detail[persona.rawValue], persona.panes.contains(remembered) {
            return remembered
        }
        return persona.defaultPane
    }

    // MARK: - Writing

    /// Snapshot where `persona` is standing.
    ///
    /// One column, since stage 2b Task 7. The binder half carried a
    /// transient-segment exception — `.find` and `.trash` were states the
    /// writer was passing through rather than the surface a persona works on,
    /// so recording one would have dropped them back into a search or an
    /// emptied trash days later. Both are window state now (the find overlay,
    /// the trash foot disclosure) and neither is anywhere a persona can be
    /// remembered standing.
    public mutating func record(persona: Persona,
                                detailSegment: DetailSegment) {
        detail[persona.rawValue] = detailSegment
    }

    // MARK: - Codable

    /// Hand-rolled and tolerant: an unreadable map decodes empty, and an
    /// unknown segment raw value inside a readable map drops just that entry
    /// (it falls back to the persona's default pane on restore). A newer
    /// build's pane name must not cost the writer the whole memory — and,
    /// unlike `ResearchRole`, there is nothing to preserve losslessly here:
    /// this is presentation state with a well-defined default.
    ///
    /// **The `binder` key is gone and is NOT read, written or migrated**
    /// (tripwire 11). A `ui-state.json` written before stage 2b Task 7 still
    /// carries one; a keyed container simply never asks for it, so it decodes
    /// away and is dropped on the next write. There is nothing to restore it
    /// to — every persona's left column is the project's tree.
    private enum CodingKeys: String, CodingKey { case detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDetail = (try? c.decode([String: String].self, forKey: .detail)) ?? [:]
        self.detail = rawDetail.compactMapValues(DetailSegment.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(detail.mapValues(\.rawValue), forKey: .detail)
    }
}
