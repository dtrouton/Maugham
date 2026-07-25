import Foundation

/// Per-project UI state persisted to `.maugham/ui-state.json`.
/// Schema-versioned for forward compatibility.
public struct UIState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var selectedItemId: String?
    public var isNoChromeOn: Bool
    public var binderSegment: BinderSegment
    public var researchPreviewVisible: Bool
    public var detailSegment: DetailSegment
    public var outlineLayout: OutlineLayout
    /// Review posture (WF1): annotate-only manuscript with focus/typewriter off.
    /// Per-window, persisted so the posture survives reopen. Additive in
    /// schema v3; old files default to false.
    public var isReviewModeOn: Bool

    /// The window's working mode. Persisted per PROJECT, not per window —
    /// `UIState` lives at `.maugham/ui-state.json` and two windows on the same
    /// project share it, last-writer-wins. That is deliberate and matches
    /// `isNoChromeOn` / `isReviewModeOn`, which have the same shape. Runtime
    /// per-window independence comes from `ProjectWindow`'s `@State`; only the
    /// mode a *freshly opened* window starts in is shared.
    public var persona: Persona

    /// Where each persona was last standing (`PersonaMemory`). Additive in
    /// schema v5; older files decode it empty, and every persona then lands on
    /// its own home the first time it is entered — which is the correct
    /// first-run behaviour anyway, so there is nothing to migrate.
    public var personaMemory: PersonaMemory

    public init(
        schemaVersion: Int = UIState.currentSchemaVersion,
        selectedItemId: String? = nil,
        isNoChromeOn: Bool = false,
        binderSegment: BinderSegment = .manuscript,
        researchPreviewVisible: Bool = false,
        detailSegment: DetailSegment = .inspector,
        outlineLayout: OutlineLayout = .table,
        isReviewModeOn: Bool = false,
        persona: Persona = .default,
        personaMemory: PersonaMemory = .empty
    ) {
        self.schemaVersion = schemaVersion
        self.selectedItemId = selectedItemId
        self.isNoChromeOn = isNoChromeOn
        self.binderSegment = binderSegment
        self.researchPreviewVisible = researchPreviewVisible
        self.detailSegment = detailSegment
        self.outlineLayout = outlineLayout
        self.isReviewModeOn = isReviewModeOn
        self.persona = persona
        self.personaMemory = personaMemory
    }

    public static let empty = UIState()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedItemId, isNoChromeOn, binderSegment,
             researchPreviewVisible, detailSegment, outlineLayout, isReviewModeOn,
             persona, personaMemory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.selectedItemId = try c.decodeIfPresent(String.self, forKey: .selectedItemId)
        self.isNoChromeOn = (try? c.decode(Bool.self, forKey: .isNoChromeOn)) ?? false
        self.isReviewModeOn = (try? c.decode(Bool.self, forKey: .isReviewModeOn)) ?? false
        self.binderSegment = (try? c.decode(BinderSegment.self, forKey: .binderSegment)) ?? .manuscript
        self.researchPreviewVisible = (try? c.decode(Bool.self, forKey: .researchPreviewVisible)) ?? false
        self.detailSegment = (try? c.decode(DetailSegment.self, forKey: .detailSegment)) ?? .inspector
        self.outlineLayout = (try? c.decode(OutlineLayout.self, forKey: .outlineLayout)) ?? .table
        self.persona = (try? c.decode(Persona.self, forKey: .persona)) ?? .default
        self.personaMemory =
            (try? c.decode(PersonaMemory.self, forKey: .personaMemory)) ?? .empty
        // `scrollLine` and `hasShownOpLogBootstrapNotice` were removed in
        // v0.3.1 (dead-code sweep). JSONDecoder ignores unknown keys, so old
        // ui-state.json files load cleanly. Cursor restore actually flows
        // through `Document.cursorLocation` (per-doc) — UIState never owned
        // scroll position in any production code path.
    }

    /// Load from disk; return `.empty` if file is missing, malformed, or has
    /// a schemaVersion newer than this build understands. v1 JSONs upgrade
    /// to v2 transparently — missing fields default.
    public static func loadOrEmpty(from url: URL) -> UIState {
        guard let data = try? Data(contentsOf: url) else { return .empty }  // adr-0018-ok: UI-state read, not manuscript
        guard let decoded = try? JSONDecoder().decode(UIState.self, from: data) else {
            return .empty
        }
        guard decoded.schemaVersion <= currentSchemaVersion else { return .empty }
        // Stamp the loaded state with the current schema; on next save, the
        // file becomes a v2 file.
        var upgraded = decoded
        upgraded.schemaVersion = currentSchemaVersion
        return upgraded
    }
}
