import Foundation

/// Where one piece stands on one named review pass (M3 P1) — the cell the
/// Review board draws at the intersection of a piece row and a `ReviewPass`
/// column. Held on `StructureItem.passStates`, keyed by the pass's `id`.
///
/// There is no `notStarted` case: an absent key (or an absent dictionary) IS
/// untouched, so a piece the writer has never ruled on costs nothing on disk
/// and no reader needs a fourth state to mean "nothing yet".
///
/// ADR-0015 safe round-trip: like the identity-bearing `ResearchRole` — and
/// unlike the tolerant `ItemType`/`AssetKind` decoders that degrade to a benign
/// default — an unrecognised (future) value is preserved verbatim in
/// `.unknown(raw)` and re-encoded as that same raw string. This matters more
/// here than almost anywhere: **the whole manifest is rewritten on every
/// structural edit**, so an OLD build that opens a project carrying a NEWER
/// build's pass states and merely renames a chapter re-encodes every item. A
/// lossy sentinel would silently clobber the writer's recorded state down to
/// the literal `"unknown"` — work lost in a save nobody asked to touch it. No
/// board column matches `.unknown`, so to an old reader it reads as untouched.
///
/// Not a `String`-raw enum: the associated value can't ride on `rawValue`, so
/// the conformance is hand-written. `Equatable`/`Sendable`/`Hashable`
/// synthesise (the payload is `String`); no `CaseIterable` is declared (it
/// would not synthesise with an associated value, and a UI enumerating the
/// choosable states wants the three known ones, never a decoded `.unknown`).
public enum PassState: Codable, Equatable, Hashable, Sendable {
    case inProgress
    case done
    case skipped
    /// A state written by a newer build. Carries the original raw string so
    /// re-encode is lossless (see type doc).
    case unknown(String)

    private static let inProgressRaw = "in_progress"
    private static let doneRaw = "done"
    private static let skippedRaw = "skipped"

    /// The stable on-disk string. Known cases emit their canonical value; an
    /// `.unknown` emits the preserved original raw.
    public var rawValue: String {
        switch self {
        case .inProgress: return Self.inProgressRaw
        case .done: return Self.doneRaw
        case .skipped: return Self.skippedRaw
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.inProgressRaw: self = .inProgress
        case Self.doneRaw: self = .done
        case Self.skippedRaw: self = .skipped
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
