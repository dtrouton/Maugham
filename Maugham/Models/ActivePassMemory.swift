import Foundation
import MaughamCore

/// Which review pass each piece was last looked at through — one remembered
/// `ReviewPass.id` per piece, restored the next time that piece's board
/// opens.
///
/// **Copies `PersonaMemory`'s tolerant keyed-map shape exactly**
/// (`PersonaMemory.swift:33-97`): `[String: String]` on the wire (a
/// human-readable `ui-state.json`, not enum-keyed), an unreadable map decodes
/// to empty, and nothing here throws. Unlike `PersonaMemory`'s value type
/// (`DetailSegment`, a closed enum whose unknown raw values drop per-entry at
/// decode), a pass id is a bare `String` — the same representation
/// `ReviewPass.id`, `ProjectStore.setPassState(id:passId:_:)` and
/// `PassState`'s dictionary keys already use — so nothing can fail to decode
/// per-entry; the whole map either reads or, tolerantly, reads as empty.
///
/// **Stale ids sit harmlessly and are never swept.** A pass renamed out of
/// `ProjectManifest.effectiveReviewPasses` (or a customized list that used to
/// include a preset and no longer does) leaves this memory's raw entry
/// exactly where it was — `record(piece:passId:)` never validates against the
/// live pass list, and `activePass(forPiece:)` returns whatever string is
/// stored, full stop. Validity is a READ-TIME question for whoever consults
/// `effectiveReviewPasses` when deciding what to show — **in P1 that reader
/// does not exist yet**: the board's chip click writes the record
/// (`ProjectWindow.recordActivePass`) and M3 P2's queue pane is the consumer:
/// a stored id absent from the effective list is treated as "no active pass" there,
/// not swept from this memory, so the piece's real chosen pass is exactly
/// where it was if the pass list is ever restored. This mirrors
/// `PersonaMemory.restoredDetailSegment`'s own validity check
/// (`persona.panes.contains(remembered)`) — the filtering happens at the
/// reader, not inside the stored map.
///
/// Persisted in `UIState`, so it is per PROJECT and shared last-writer-wins by
/// two windows on the same project — the same shape as `personaMemory` and
/// `compilerModel`, which sit beside it.
public struct ActivePassMemory: Codable, Equatable, Sendable {
    /// Piece id → last-viewed `ReviewPass.id`.
    private var active: [String: String]

    public static let empty = ActivePassMemory()

    public init(active: [String: String] = [:]) {
        self.active = active
    }

    // MARK: - Reading

    /// The pass id `piece` was last looked at through, or `nil` if none was
    /// ever recorded. Returns the raw stored value regardless of whether it
    /// still names a pass in the project's current `effectiveReviewPasses` —
    /// see the type doc comment for why that check belongs to the caller.
    public func activePass(forPiece piece: String) -> String? {
        active[piece]
    }

    // MARK: - Writing

    /// Remember that `piece` was last looked at through `passId`.
    public mutating func record(piece: String, passId: String) {
        active[piece] = passId
    }

    // MARK: - Codable

    /// Hand-rolled and tolerant, for `PersonaMemory`'s reason: an unreadable
    /// map decodes empty rather than failing the whole `UIState` load.
    private enum CodingKeys: String, CodingKey { case active }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.active = (try? c.decode([String: String].self, forKey: .active)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(active, forKey: .active)
    }
}
