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
    /// What the window is about (shell p1): centre, right column, beside.
    /// Stored under its own `windowSubject` key. A file without it — written
    /// before shell p1 — builds one from the legacy selection keys
    /// (`selectedItemId`, `selectedSubjectIsProject`, `selectedResearchItemId`,
    /// `selectedFigureId`), else the Book. Those keys are read, never written.
    public var windowSubject: WindowSubject

    /// How the Book is shown. Seeded once from the legacy `outlineLayout` key
    /// when absent (`table` is `.outline`, `cards` is `.cards`); that key is
    /// read, never written.
    public var bookView: BookView
    /// How an edition is shown: its book or its Status (shell p4). Absent
    /// or unknown decodes as `.book`.
    public var editionView: EditionView
    /// Whether a piece read in a language draws its source under each
    /// paragraph (shell p4 Task 8). Absent decodes as `true`, the default.
    public var showsSourceUnderTranslation: Bool
    /// View ▸ Margin (shell p5 Task 2): what the margin beside the text
    /// marks. Absent or unknown decodes as `.off`, the default.
    public var marginSetting: MarginSetting
    public var isNoChromeOn: Bool
    public var researchPreviewVisible: Bool
    /// The right column's remembered position (shell p3): To resolve, Brief
    /// or the pulled-up thing — one for the window, whatever the subject. A
    /// missing or unknown value opens on To resolve (the tolerant decode,
    /// tripwire 11). The pane picker's old `detailSegment` key is neither
    /// read nor written: a file carrying it, with any value, decodes and
    /// ignores it.
    public var rightColumnPosition: RightColumnPosition

    /// The model the Diagnostics pane's gear menu spawns compiler runs
    /// against (M2 Task 8).
    ///
    /// **No schema bump**: this is one additive key with a default, so a file written without it decodes to
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

    /// **Which set-aside records this device has already told the writer
    /// about** (signed op log P2a, D2) — archive filenames, the key
    /// `SetAsideAcknowledgement` resolves and the History pane's disclosure
    /// shows.
    ///
    /// **No schema bump**, for `authorReaderChoice`'s reason one field up: one
    /// additive key with a tolerated-missing default, so a file written without
    /// it decodes to nothing acknowledged — every record then still has its
    /// say, which is the correct first-run behaviour — and an older build
    /// ignores a key it has never heard of. Nothing acknowledged writes no key
    /// at all, so a project where this never happened has the file it always
    /// had.
    ///
    /// **Per device on purpose.** UI state is this machine's: acknowledging a
    /// foreign line here says nothing about the phone, and each device tells
    /// its own writer once.
    ///
    /// **Names, never records.** A name whose archive is gone stays in the set
    /// rather than being swept — forgetting it would resurrect a sentence the
    /// writer already put down, and the archives are not this file's to police.
    public var acknowledgedSetAsideRecords: Set<String>

    /// **Which recovered captures this device has already sent to the Inbox**
    /// (P3b Task 8, reshaped in fix round 2's C1) — door key → the capture ids
    /// (`SetAsideDoor.captureId`, `<opId>#<paragraphId>`) already made from it.
    ///
    /// The key is the door's own subject: an archive filename for a set-aside
    /// record, and `<docId>|held` for a held span, which has no archive
    /// because none was ever written for it — whose ids carry the document as
    /// well, `<docId>|<opId>#<paragraphId>` (`SetAsideDoor.heldLineId`). **A
    /// held span is remembered by its LINES, never by its holder** (P3c Task
    /// 7, M2): the holder is the walk's opinion of whose the lines are, and it
    /// changes the day a signing Mac's first seal syncs. Keys in the older
    /// `<docId>|<holder>` shape are left where they are and read by nothing
    /// (tripwire 11); a paragraph sent under one is offered once more.
    ///
    /// **Ids rather than a once-flag**, which is the whole of C1. A held span
    /// is LIVE — the stream it names goes on being written to — so a flag left
    /// every paragraph that arrived after the first press with no way in at
    /// all, which is the state this door exists to remove. It also lets a send
    /// that lands only partly be re-pressed for the rest.
    ///
    /// **Per device**, like the acknowledgement beside it: what this Mac has
    /// handed its writer is this Mac's business, and the archives are forensics
    /// no surface writes into. Additive, no schema bump, no key when empty, and
    /// never swept: an id whose record is gone stays, because forgetting it
    /// would file the same paragraph a second time.
    public var sentRecoveredOpIds: [String: Set<String>]

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
    /// fourth column, 2026-08-25: what is pulled up beside the prose takes the
    /// RIGHT column at `detailColumnWidth`, so there is no second width to hold. The
    /// key is deliberately NOT in `CodingKeys` any more — a keyed container
    /// never asks for a key it has no case for, so a `ui-state.json` written by
    /// any earlier build still decodes, carrying the dead number harmlessly
    /// (`UIStateTests.test_aFileStillCarryingTheDeadWidthKeyDecodes`).

    /// How wide the window's RIGHT column is — one width, held through every
    /// subject change and every pane switch (shell-finish stage 1, Task 1).
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
        windowSubject: WindowSubject = .book,
        bookView: BookView = .outline,
        editionView: EditionView = .book,
        showsSourceUnderTranslation: Bool = true,
        marginSetting: MarginSetting = .off,
        isNoChromeOn: Bool = false,
        researchPreviewVisible: Bool = false,
        rightColumnPosition: RightColumnPosition = .resolve,
        compilerModel: CompilerModelChoice = .standard,
        activePassMemory: ActivePassMemory = .empty,
        detailColumnWidth: Double = UIState.defaultDetailColumnWidth,
        publishImprint: String? = nil,
        authorReaderChoice: AuthorReaderChoice? = nil,
        acknowledgedSetAsideRecords: Set<String> = [],
        sentRecoveredOpIds: [String: Set<String>] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.windowSubject = windowSubject
        self.bookView = bookView
        self.editionView = editionView
        self.showsSourceUnderTranslation = showsSourceUnderTranslation
        self.marginSetting = marginSetting
        self.isNoChromeOn = isNoChromeOn
        self.researchPreviewVisible = researchPreviewVisible
        self.rightColumnPosition = rightColumnPosition
        self.compilerModel = compilerModel
        self.activePassMemory = activePassMemory
        self.detailColumnWidth =
            UIState.clampedDetailColumnWidth(detailColumnWidth)
        self.publishImprint = publishImprint
        self.authorReaderChoice = authorReaderChoice
        self.acknowledgedSetAsideRecords = acknowledgedSetAsideRecords
        self.sentRecoveredOpIds = sentRecoveredOpIds
    }

    public static let empty = UIState()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, windowSubject, bookView, editionView, showsSourceUnderTranslation, marginSetting,
             selectedItemId, selectedSubjectIsProject,
             selectedResearchItemId, selectedFigureId,
             isNoChromeOn,
             researchPreviewVisible, rightColumnPosition, outlineLayout,
             compilerModel, activePassMemory,
             detailColumnWidth, publishImprint, authorReaderChoice,
             acknowledgedSetAsideRecords, sentRecoveredOpIds
    }

    /// Hand-written so the legacy keys above are decode-only: the legacy
    /// selection keys and `outlineLayout` are read to seed `windowSubject` and
    /// `bookView` and never written back.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(windowSubject, forKey: .windowSubject)
        try c.encode(bookView, forKey: .bookView)
        try c.encode(editionView, forKey: .editionView)
        try c.encode(showsSourceUnderTranslation, forKey: .showsSourceUnderTranslation)
        try c.encode(marginSetting, forKey: .marginSetting)
        try c.encode(isNoChromeOn, forKey: .isNoChromeOn)
        try c.encode(researchPreviewVisible, forKey: .researchPreviewVisible)
        try c.encode(rightColumnPosition, forKey: .rightColumnPosition)
        try c.encode(compilerModel, forKey: .compilerModel)
        try c.encode(activePassMemory, forKey: .activePassMemory)
        try c.encode(detailColumnWidth, forKey: .detailColumnWidth)
        try c.encodeIfPresent(publishImprint, forKey: .publishImprint)
        try c.encodeIfPresent(authorReaderChoice, forKey: .authorReaderChoice)
        // Written only once there IS one, so a `ui-state.json` on a project
        // where nothing was ever set aside stays exactly the file it was.
        if !acknowledgedSetAsideRecords.isEmpty {
            try c.encode(acknowledgedSetAsideRecords,
                         forKey: .acknowledgedSetAsideRecords)
        }
        // The same rule for the same reason (P3b Task 8): a project where no
        // set-aside words were ever sent to the Inbox carries no key at all.
        if !sentRecoveredOpIds.isEmpty {
            try c.encode(sentRecoveredOpIds, forKey: .sentRecoveredOpIds)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        // The flag is checked FIRST and wins: a file written by this build for
        // the project subject carries no `selectedItemId` at all, and one
        // carrying both could only come from a hand-edit — in which case the
        // explicit new key is the more specific statement of intent.
        let legacySelection: BinderSubject?
        if (try? c.decodeIfPresent(Bool.self, forKey: .selectedSubjectIsProject)) == true {
            legacySelection = .project
        } else if let id = try c.decodeIfPresent(String.self, forKey: .selectedItemId) {
            legacySelection = .item(id)
        } else if let id = try c.decodeIfPresent(String.self, forKey: .selectedResearchItemId) {
            legacySelection = .research(id)
        } else if let id = try c.decodeIfPresent(String.self, forKey: .selectedFigureId) {
            legacySelection = .figure(id)
        } else {
            legacySelection = nil
        }
        if let w = try? c.decode(WindowSubject.self, forKey: .windowSubject) {
            self.windowSubject = w
        } else if let legacy = legacySelection {
            self.windowSubject = WindowSubject(open: legacy, faces: legacy, beside: nil)
        } else {
            self.windowSubject = .book
        }
        self.isNoChromeOn = (try? c.decode(Bool.self, forKey: .isNoChromeOn)) ?? false
        // The old review-mode key (Manual Review Mode, gone with read-through)
        // is not in `CodingKeys`: a file carrying it decodes and ignores it (tripwire 11).
        self.researchPreviewVisible = (try? c.decode(Bool.self, forKey: .researchPreviewVisible)) ?? false
        // A missing or unknown position opens on To resolve. The tolerant
        // decode IS the migration (tripwire 11): the pane picker's
        // `detailSegment` key is not in `CodingKeys`, so the container skips
        // it whatever it holds.
        self.rightColumnPosition =
            (try? c.decode(RightColumnPosition.self, forKey: .rightColumnPosition)) ?? .resolve
        if let b = try? c.decode(BookView.self, forKey: .bookView) {
            self.bookView = b
        } else {
            let legacyLayout = try? c.decode(OutlineLayout.self, forKey: .outlineLayout)
            self.bookView = legacyLayout == .cards ? .cards : .outline
        }
        self.editionView = (try? c.decodeIfPresent(EditionView.self, forKey: .editionView)) ?? .book
        self.showsSourceUnderTranslation =
            (try? c.decodeIfPresent(Bool.self, forKey: .showsSourceUnderTranslation)) ?? true
        self.marginSetting = (try? c.decodeIfPresent(MarginSetting.self, forKey: .marginSetting)) ?? .off
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
        // Absent is the state every project starts in and every file written
        // before P2a is in: nothing acknowledged, so every set-aside record
        // still has its say.
        self.acknowledgedSetAsideRecords =
            (try? c.decode(Set<String>.self,
                           forKey: .acknowledgedSetAsideRecords)) ?? []
        // Absent means nothing has been sent, which is where every project
        // starts and where every file written before P3b Task 8 is: the door
        // is offered, once.
        self.sentRecoveredOpIds =
            (try? c.decode([String: Set<String>].self,
                           forKey: .sentRecoveredOpIds)) ?? [:]
        // `scrollLine` and `hasShownOpLogBootstrapNotice` were removed in
        // v0.3.1 (dead-code sweep), and `binderSegment` in shell-finish stage
        // 2b Task 7, when the binder strip died with `BinderSegment`,
        // `assistantColumnWidth` on 2026-08-25, when the study column took the
        // right column and stopped having a width of its own, and the window's
        // old working-mode keys in shell p1 Task 6. A keyed
        // container never asks for a key it has no case for, so every one of
        // those old values decodes away and is dropped on the next write —
        // which is what "no migration" (tripwire 11) means here. There is
        // nothing to restore a left-column choice to: the left column is the
        // project's own tree. Cursor restore flows through
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
