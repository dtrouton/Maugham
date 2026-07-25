import Foundation
import MaughamCore

/// Where each persona was last standing — one remembered binder segment and
/// one remembered right-pane segment per persona.
///
/// This is what makes a persona a WORKSPACE rather than a filter. The first
/// shape of the persona shell kept whatever segment the destination persona
/// also offered, which is defensible on paper and wrong in the hand: Author
/// offers Research, so ⌘1 (Plan, whose binder home is Research) followed by
/// ⌘2 left the writer's binder on Research and "lost the binder" (2026-07-25
/// smoke, defect B). Remembering per persona makes the round trip lossless.
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
    private var binder: [String: BinderSegment]
    private var detail: [String: DetailSegment]

    public static let empty = PersonaMemory()

    public init(binder: [String: BinderSegment] = [:],
                detail: [String: DetailSegment] = [:]) {
        self.binder = binder
        self.detail = detail
    }

    // MARK: - Reading

    /// The binder segment `persona` should be restored to, already filtered for
    /// validity: a remembered value the persona no longer offers (or never did
    /// — a stale `.trash` from an older build, a `.manuscript` remembered
    /// against a project since converted to a screenplay) falls back to the
    /// persona's own `binderHome`. Nothing here can resurrect a runtime-gated
    /// segment, because `binderSegments(for:)` never contains one.
    public func restoredBinderSegment(for persona: Persona,
                                      projectType: ProjectType) -> BinderSegment {
        let offered = persona.binderSegments(for: projectType)
        if let remembered = binder[persona.rawValue], offered.contains(remembered) {
            return remembered
        }
        return persona.binderHome(for: projectType)
    }

    /// The right-pane segment `persona` should be restored to. Same validity
    /// filtering against `Persona.panes`, falling back to `defaultPane`.
    /// `DetailPaneToggle`'s own coercion stays the safety net for the one fact
    /// this cannot see — `hideOutline` on a collection project.
    public func restoredDetailSegment(for persona: Persona) -> DetailSegment {
        if let remembered = detail[persona.rawValue], persona.panes.contains(remembered) {
            return remembered
        }
        return persona.defaultPane
    }

    // MARK: - Writing

    /// Snapshot where `persona` is standing.
    ///
    /// A transient binder segment (`.find` / `.trash` — see
    /// `BinderSegment.isTransient`) is deliberately NOT recorded: it is a
    /// state the writer is passing through, not the surface this persona
    /// works on, and recording it would drop them back into a search or an
    /// emptied trash days later. The previously remembered value stands.
    public mutating func record(persona: Persona,
                                binderSegment: BinderSegment,
                                detailSegment: DetailSegment) {
        if !binderSegment.isTransient {
            binder[persona.rawValue] = binderSegment
        }
        detail[persona.rawValue] = detailSegment
    }

    // MARK: - Codable

    /// Hand-rolled and tolerant on BOTH axes: an unreadable map decodes empty,
    /// and an unknown segment raw value inside a readable map drops just that
    /// entry (it falls back to the persona's home on restore). A newer build's
    /// segment name must not cost the writer the whole memory — and, unlike
    /// `ResearchRole`, there is nothing to preserve losslessly here: this is
    /// presentation state with a well-defined default.
    private enum CodingKeys: String, CodingKey { case binder, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawBinder = (try? c.decode([String: String].self, forKey: .binder)) ?? [:]
        let rawDetail = (try? c.decode([String: String].self, forKey: .detail)) ?? [:]
        self.binder = rawBinder.compactMapValues(BinderSegment.init(rawValue:))
        self.detail = rawDetail.compactMapValues(DetailSegment.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(binder.mapValues(\.rawValue), forKey: .binder)
        try c.encode(detail.mapValues(\.rawValue), forKey: .detail)
    }
}
