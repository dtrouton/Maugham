import Foundation

/// **Which reader the writer picked for Author's checks** (two loops P2).
///
/// A pick from a menu, not a person: `.firstReader` names nobody, because who
/// she IS is manifest identity (`ProjectManifest.firstReaderName`) and travels
/// with the book, while a pick is a preference this machine holds. Storing the
/// name here instead would give a project two answers to who its first reader
/// is, one of which never leaves this Mac.
///
/// Optional wherever it is held: `nil` is "not chosen", which is a different
/// state from `.nobody` — the first falls to the default rule (the coach while
/// her seat is held, else a named first reader, else nobody) and the second is
/// the writer saying they want no reader at all.
public enum AuthorReaderChoice: String, Codable, Equatable, Sendable {
    case coach
    case firstReader
    case nobody
}

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
    ///
    /// **A research subject writes a THIRD key, `selectedResearchItemId`, on the
    /// same principle** (stage-2a Task 1): a build that has never heard of it
    /// writes and reads neither of the other two, so it sees no selection at
    /// all rather than misreading a research id as a structure item id.
    public var selectedSubject: BinderSubject?
    public var isNoChromeOn: Bool
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

    /// **Which imprint the Publish desk is standing on** (imprints P3 Task 5) —
    /// `nil` for the book itself, which is what every project compiled as
    /// before an imprint could be picked at all.
    ///
    /// **No schema bump**, for `compilerModel`'s reason one field up: one
    /// additive key with a tolerated-missing default, so a file written without
    /// it decodes to the book and an older build ignores a key it has never
    /// heard of. Both directions of the version skew read cleanly.
    ///
    /// **A name rather than a resolved imprint.** What the writer picked is a
    /// string the project's `config.json` defines, and a name whose imprint has
    /// since been deleted must survive the round trip rather than being swept
    /// here — the desk's picker is where a stale name falls back to the book,
    /// because that is where the config is actually read.
    public var publishImprint: String?

    /// **Who the writer picked to read this project's checks**
    /// (`AuthorReaderChoice`, two loops P2) — `nil` while they have not picked,
    /// which is not the same as picking nobody.
    ///
    /// **No schema bump**, for `publishImprint`'s reason one field up: one
    /// additive optional key, so a file written without it decodes to
    /// "unchosen" — the state every project starts in — and an older build
    /// ignores a key it has never heard of. The decode is tolerant in the
    /// other direction too: a raw value written by a NEWER build reads as
    /// unchosen rather than throwing away the whole of the window's state.
    ///
    /// **A pick, never a name.** A stale pick is resolved against the project's
    /// own facts every time it is read (`ProjectManifest.authorReader(choice:
    /// statementText:)`), so a coach whose seat has since been vacated, or a
    /// first reader whose name has since been cleared, falls back to the
    /// default rule instead of being swept here.
    public var authorReaderChoice: AuthorReaderChoice?

    /// Which review pass each piece was last looked at through
    /// (`ActivePassMemory`, M3-P1 Task 5).
    ///
    /// **No schema bump**, for `compilerModel`'s reason one field up: this is
    /// one additive key with a default, so a file written without it decodes
    /// to `.empty` — every piece then opens on the board's own default pass
    /// the first time it is looked at, which is the correct first-run
    /// behaviour anyway — and an older build ignores a key it has never heard
    /// of.
    public var activePassMemory: ActivePassMemory

    /// **`assistantColumnWidth` used to live here** (M2 §6.2) and died with the
    /// fourth column, 2026-08-25: a studied reference now takes the RIGHT
    /// column at `detailColumnWidth`, so there is no second width to hold. The
    /// key is deliberately NOT in `CodingKeys` any more — a keyed container
    /// never asks for a key it has no case for, so a `ui-state.json` written by
    /// any earlier build still decodes, carrying the dead number harmlessly
    /// (`AssistantColumnTests.test_aFileStillCarryingTheDeadWidthKeyDecodes`).

    /// How wide the window's RIGHT column is — one width, held through every
    /// persona and every pane switch (shell-finish stage 1, Task 1).
    ///
    /// **A non-optional `Double` with a default and a clamp on every way in**
    /// — rather than a
    /// `Double?` whose `nil` would mean "never dragged". Nothing distinguishes
    /// a never-dragged column from one dragged back to 280, and two spellings
    /// of one rule is how the second comes to differ. No schema bump: one
    /// additive key with a default reads cleanly in both directions of the
    /// version skew.
    ///
    /// **The reason it has to be persisted at all is a measured one.** The
    /// column used to declare a RANGE (`min: 240, ideal: 280, max: 360`), and a
    /// range is not a width — AppKit re-resolves a position inside it whenever
    /// the pane's content wants a different one, and a `columnVisibility`
    /// transition drops it on the range's floor. See `DetailColumnWidthTests`,
    /// which measures both.
    public var detailColumnWidth: Double

    /// The width a project that has never been dragged opens at — the `ideal`
    /// the range used to carry, so nothing moves for a writer who never touches
    /// the divider.
    public static let defaultDetailColumnWidth: Double = 280

    /// **The floor is the old `min`**; below it the inspector's labelled rows
    /// wrap into unreadability. The ceiling is deliberately wider than the old
    /// `max: 360` — a writer-owned width may be wider than a designer's cap,
    /// and the clamp is the safety rather than the opinion.
    ///
    /// **What protects the prose is the clamp, not this range.** A window that
    /// cannot afford the ceiling never shows it:
    /// `ProjectWindow.effectiveDetailColumnWidth` reduces what is displayed to
    /// what the window has left after the binder and the writing column take
    /// their floors, and `test_theWidestWishDoesNotGrowTheNarrowestWindow` holds
    /// that measurement. No worked example here on purpose — this comment
    /// carried one ("at 480 the writing column still lays out at 499pt") that
    /// was taken on a silently-GROWN window, describing a layout the clamp has
    /// since made impossible. A number in prose about arithmetic the code does
    /// is the unmaintainable-count defect wearing math.
    public static let detailColumnWidthRange: ClosedRange<Double> = 240...480

    public static func clampedDetailColumnWidth(_ width: Double) -> Double {
        min(max(width, detailColumnWidthRange.lowerBound),
            detailColumnWidthRange.upperBound)
    }

    public init(
        schemaVersion: Int = UIState.currentSchemaVersion,
        selectedSubject: BinderSubject? = nil,
        isNoChromeOn: Bool = false,
        researchPreviewVisible: Bool = false,
        detailSegment: DetailSegment = .inspector,
        outlineLayout: OutlineLayout = .table,
        isReviewModeOn: Bool = false,
        persona: Persona = .default,
        personaMemory: PersonaMemory = .empty,
        compilerModel: CompilerModelChoice = .standard,
        activePassMemory: ActivePassMemory = .empty,
        detailColumnWidth: Double = UIState.defaultDetailColumnWidth,
        publishImprint: String? = nil,
        authorReaderChoice: AuthorReaderChoice? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.selectedSubject = selectedSubject
        self.isNoChromeOn = isNoChromeOn
        self.researchPreviewVisible = researchPreviewVisible
        self.detailSegment = detailSegment
        self.outlineLayout = outlineLayout
        self.isReviewModeOn = isReviewModeOn
        self.persona = persona
        self.personaMemory = personaMemory
        self.compilerModel = compilerModel
        self.activePassMemory = activePassMemory
        self.detailColumnWidth =
            UIState.clampedDetailColumnWidth(detailColumnWidth)
        self.publishImprint = publishImprint
        self.authorReaderChoice = authorReaderChoice
    }

    public static let empty = UIState()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedItemId, selectedSubjectIsProject,
             selectedResearchItemId,
             isNoChromeOn,
             researchPreviewVisible, detailSegment, outlineLayout, isReviewModeOn,
             persona, personaMemory, compilerModel, activePassMemory,
             detailColumnWidth, publishImprint, authorReaderChoice
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
        case .research(let id):
            try c.encode(id, forKey: .selectedResearchItemId)
        case nil:
            break
        }
        try c.encode(isNoChromeOn, forKey: .isNoChromeOn)
        try c.encode(researchPreviewVisible, forKey: .researchPreviewVisible)
        try c.encode(detailSegment, forKey: .detailSegment)
        try c.encode(outlineLayout, forKey: .outlineLayout)
        try c.encode(isReviewModeOn, forKey: .isReviewModeOn)
        try c.encode(persona, forKey: .persona)
        try c.encode(personaMemory, forKey: .personaMemory)
        try c.encode(compilerModel, forKey: .compilerModel)
        try c.encode(activePassMemory, forKey: .activePassMemory)
        try c.encode(detailColumnWidth, forKey: .detailColumnWidth)
        try c.encodeIfPresent(publishImprint, forKey: .publishImprint)
        try c.encodeIfPresent(authorReaderChoice, forKey: .authorReaderChoice)
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
        } else if let id = try c.decodeIfPresent(String.self, forKey: .selectedResearchItemId) {
            self.selectedSubject = .research(id)
        } else {
            self.selectedSubject = nil
        }
        self.isNoChromeOn = (try? c.decode(Bool.self, forKey: .isNoChromeOn)) ?? false
        self.isReviewModeOn = (try? c.decode(Bool.self, forKey: .isReviewModeOn)) ?? false
        self.researchPreviewVisible = (try? c.decode(Bool.self, forKey: .researchPreviewVisible)) ?? false
        self.detailSegment = (try? c.decode(DetailSegment.self, forKey: .detailSegment)) ?? .inspector
        self.outlineLayout = (try? c.decode(OutlineLayout.self, forKey: .outlineLayout)) ?? .table
        self.persona = (try? c.decode(Persona.self, forKey: .persona)) ?? .default
        self.personaMemory =
            (try? c.decode(PersonaMemory.self, forKey: .personaMemory)) ?? .empty
        self.compilerModel =
            (try? c.decode(CompilerModelChoice.self, forKey: .compilerModel)) ?? .standard
        self.activePassMemory =
            (try? c.decode(ActivePassMemory.self, forKey: .activePassMemory)) ?? .empty
        // Clamped on the way IN as well as on the way out: a hand-edited
        // `ui-state.json` is a writer of this field too, and it has no gesture
        // with a limit.
        self.detailColumnWidth = UIState.clampedDetailColumnWidth(
            (try? c.decode(Double.self, forKey: .detailColumnWidth))
                ?? UIState.defaultDetailColumnWidth)
        self.publishImprint =
            (try? c.decodeIfPresent(String.self, forKey: .publishImprint)) ?? nil
        // Tolerated in BOTH directions: an absent key is the writer's
        // unchosen state, and a raw value this build has never heard of (a
        // choice a newer build offers) reads as unchosen too rather than
        // throwing the rest of the file away with it.
        self.authorReaderChoice =
            (try? c.decodeIfPresent(AuthorReaderChoice.self, forKey: .authorReaderChoice)) ?? nil
        // `scrollLine` and `hasShownOpLogBootstrapNotice` were removed in
        // v0.3.1 (dead-code sweep), and `binderSegment` in shell-finish stage
        // 2b Task 7, when the binder strip died with `BinderSegment`, and
        // `assistantColumnWidth` on 2026-08-25, when the study column took the
        // right column and stopped having a width of its own. A keyed
        // container never asks for a key it has no case for, so every one of
        // those old values decodes away and is dropped on the next write —
        // which is what "no migration" (tripwire 11) means here. There is
        // nothing to restore a left-column choice to: every persona's left
        // column is the project's own tree. Cursor restore flows through
        // `Document.cursorLocation` (per-doc); UIState never owned scroll
        // position in any production code path.
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
