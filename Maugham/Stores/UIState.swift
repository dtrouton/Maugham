import Foundation

/// Per-project UI state persisted to `.maugham/ui-state.json`.
/// Schema-versioned for forward compatibility.
public struct UIState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    /// What the window's tree names (`BinderSubject`).
    ///
    /// **Persisted under the keys it always used, and additively.** An item
    /// subject still writes `selectedItemId` as a bare string, so an older build
    /// restores it exactly as it did; the project subject writes a separate
    /// `selectedSubjectIsProject` flag and NO `selectedItemId`, so an older build
    /// sees no selection and falls to the first document — the same landing a
    /// deleted item already gets. Decode reads a bare string back as `.item`.
    /// Neither direction of the skew loses or invents a selection, which is why
    /// the new case cost no schema bump and no migration.
    public var selectedSubject: BinderSubject?
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

    /// The model the Diagnostics pane's gear menu spawns compiler runs
    /// against (M2 Task 8).
    ///
    /// **No schema bump**, for `selectedSubject`'s reason one field up: this is
    /// one additive key with a default, so a file written without it decodes to
    /// `.standard` — the spec's default (§3.5) and `defaultModel`'s own answer —
    /// and an older build ignores a key it has never heard of. Both directions
    /// of the version skew read cleanly, which is what the constant is for.
    public var compilerModel: CompilerModelChoice

    /// How wide the assistant column is when a reference is being studied
    /// (M2 §6.2, Plan 2 Task 5).
    ///
    /// **No schema bump**, for `compilerModel`'s reason: one additive key with
    /// a default, so a file written without it decodes to
    /// `defaultAssistantColumnWidth` and an older build ignores a key it has
    /// never heard of.
    ///
    /// **Every way in is clamped, including the decode.** The drag is one
    /// writer of this field and a hand-edited `ui-state.json` is the other, and
    /// only one of them has a gesture with a limit — so the clamp lives with the
    /// stored value rather than in the view, and a 4000 pt column cannot be
    /// restored into a window that has no room for it.
    public var assistantColumnWidth: Double

    /// The width a project that has never been dragged opens at. Wide enough to
    /// read a research note's paragraphs at the editor's own measure, narrow
    /// enough that the prose beside it is still a column rather than a margin.
    public static let defaultAssistantColumnWidth: Double = 340

    /// **The floor is a legibility floor, not a layout one.** Below ~260 pt a
    /// research note's paragraphs break every four or five words and the column
    /// stops being a thing you can study — which is the only reason it exists.
    /// The ceiling keeps the writing column the wider of the two at the window's
    /// own minimum (`ProjectWindow`'s `minWidth: 980`).
    public static let assistantColumnWidthRange: ClosedRange<Double> = 260...620

    public static func clampedAssistantColumnWidth(_ width: Double) -> Double {
        min(max(width, assistantColumnWidthRange.lowerBound),
            assistantColumnWidthRange.upperBound)
    }

    public init(
        schemaVersion: Int = UIState.currentSchemaVersion,
        selectedSubject: BinderSubject? = nil,
        isNoChromeOn: Bool = false,
        binderSegment: BinderSegment = .manuscript,
        researchPreviewVisible: Bool = false,
        detailSegment: DetailSegment = .inspector,
        outlineLayout: OutlineLayout = .table,
        isReviewModeOn: Bool = false,
        persona: Persona = .default,
        personaMemory: PersonaMemory = .empty,
        compilerModel: CompilerModelChoice = .standard,
        assistantColumnWidth: Double = UIState.defaultAssistantColumnWidth
    ) {
        self.schemaVersion = schemaVersion
        self.selectedSubject = selectedSubject
        self.isNoChromeOn = isNoChromeOn
        self.binderSegment = binderSegment
        self.researchPreviewVisible = researchPreviewVisible
        self.detailSegment = detailSegment
        self.outlineLayout = outlineLayout
        self.isReviewModeOn = isReviewModeOn
        self.persona = persona
        self.personaMemory = personaMemory
        self.compilerModel = compilerModel
        self.assistantColumnWidth =
            UIState.clampedAssistantColumnWidth(assistantColumnWidth)
    }

    public static let empty = UIState()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedItemId, selectedSubjectIsProject,
             isNoChromeOn, binderSegment,
             researchPreviewVisible, detailSegment, outlineLayout, isReviewModeOn,
             persona, personaMemory, compilerModel, assistantColumnWidth
    }

    /// Hand-written because `selectedSubject` is not stored the way it is
    /// spelled — see that property. Everything else is written exactly as the
    /// synthesized encoder wrote it, so no other field's on-disk shape moves.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        switch selectedSubject {
        case .item(let id):
            try c.encode(id, forKey: .selectedItemId)
        case .project:
            try c.encode(true, forKey: .selectedSubjectIsProject)
        case nil:
            break
        }
        try c.encode(isNoChromeOn, forKey: .isNoChromeOn)
        try c.encode(binderSegment, forKey: .binderSegment)
        try c.encode(researchPreviewVisible, forKey: .researchPreviewVisible)
        try c.encode(detailSegment, forKey: .detailSegment)
        try c.encode(outlineLayout, forKey: .outlineLayout)
        try c.encode(isReviewModeOn, forKey: .isReviewModeOn)
        try c.encode(persona, forKey: .persona)
        try c.encode(personaMemory, forKey: .personaMemory)
        try c.encode(compilerModel, forKey: .compilerModel)
        try c.encode(assistantColumnWidth, forKey: .assistantColumnWidth)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        // The flag is checked FIRST and wins: a file written by this build for
        // the project subject carries no `selectedItemId` at all, and one
        // carrying both could only come from a hand-edit — in which case the
        // explicit new key is the more specific statement of intent.
        if (try? c.decodeIfPresent(Bool.self, forKey: .selectedSubjectIsProject)) == true {
            self.selectedSubject = .project
        } else if let id = try c.decodeIfPresent(String.self, forKey: .selectedItemId) {
            self.selectedSubject = .item(id)
        } else {
            self.selectedSubject = nil
        }
        self.isNoChromeOn = (try? c.decode(Bool.self, forKey: .isNoChromeOn)) ?? false
        self.isReviewModeOn = (try? c.decode(Bool.self, forKey: .isReviewModeOn)) ?? false
        self.binderSegment = (try? c.decode(BinderSegment.self, forKey: .binderSegment)) ?? .manuscript
        self.researchPreviewVisible = (try? c.decode(Bool.self, forKey: .researchPreviewVisible)) ?? false
        self.detailSegment = (try? c.decode(DetailSegment.self, forKey: .detailSegment)) ?? .inspector
        self.outlineLayout = (try? c.decode(OutlineLayout.self, forKey: .outlineLayout)) ?? .table
        self.persona = (try? c.decode(Persona.self, forKey: .persona)) ?? .default
        self.personaMemory =
            (try? c.decode(PersonaMemory.self, forKey: .personaMemory)) ?? .empty
        self.compilerModel =
            (try? c.decode(CompilerModelChoice.self, forKey: .compilerModel)) ?? .standard
        // Clamped on the way IN as well as on the way out — see the property.
        self.assistantColumnWidth = UIState.clampedAssistantColumnWidth(
            (try? c.decode(Double.self, forKey: .assistantColumnWidth))
                ?? UIState.defaultAssistantColumnWidth)
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
