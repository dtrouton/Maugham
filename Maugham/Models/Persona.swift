import Foundation
import MaughamCore

/// The window's current working mode. Four optional lenses over one project —
/// never gates. Every persona is reachable at any time regardless of project
/// state; nothing is disabled, and nothing is required before writing.
///
/// Decoding is forward-tolerant: an unrecognised raw value becomes `.author`
/// rather than throwing, so a project touched by a newer build still opens.
/// This is deliberately weaker than `ResearchRole`'s lossless `.unknown`
/// sentinel — persona is presentation state, not identity, so there is nothing
/// to preserve on behalf of the newer build.
public enum Persona: String, Codable, Equatable, Sendable, CaseIterable {
    case plan
    case author
    case review
    case publish

    /// The default a fresh project opens in. Authoring is the mode most of a
    /// writer's hours are spent in, and the one whose layout matches today's
    /// window exactly — so an upgrading writer sees no change until they ask.
    public static let `default`: Persona = .author

    public var displayName: String {
        switch self {
        case .plan: return "Plan"
        case .author: return "Author"
        case .review: return "Review"
        case .publish: return "Publish"
        }
    }

    public var systemImageName: String {
        switch self {
        case .plan: return "lightbulb"
        case .author: return "pencil.line"
        case .review: return "text.magnifyingglass"
        case .publish: return "book.closed"
        }
    }

    /// ⌘1–⌘4. Ordering is the stage arc, and `allCases` order must match.
    public var shortcutKey: Character {
        switch self {
        case .plan: return "1"
        case .author: return "2"
        case .review: return "3"
        case .publish: return "4"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Persona(rawValue: raw) ?? .default
    }
}

// MARK: - Pane registry

public extension Persona {
    /// The right-pane segments this persona offers, in picker order. The first
    /// is the persona's default.
    ///
    /// THIS IS THE EXTENSION POINT. A milestone adding a right-pane surface
    /// adds its `DetailSegment` case and one entry here, and does not touch
    /// `ProjectWindow` or the picker at all.
    ///
    /// Two files it DOES touch, corrected in M1A after this comment claimed
    /// otherwise and the compiler disagreed: `DetailPaneToggle.segmentContent`
    /// is exhaustive over `DetailSegment` with no `default`, so the new case
    /// needs its content arm there (which is the point — a `default` would let
    /// a segment ship reachable and rendering the wrong pane); and the pane's
    /// `⌘⌥` shortcut is one `Button` in `MaughamApp`'s View menu, which is the
    /// sole dispatch path for all of them (`DocSyncTests` guards it against
    /// `docs/guide/reference.md`).
    ///
    /// The registry is the design's pane × persona matrix made executable, and
    /// that matrix now has two documents. §6.3 of
    /// `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md` is
    /// the base; §5 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` is
    /// **an amendment in force to it**, and where they disagree the amendment
    /// wins. `PersonaPaneRegistryTests.test_everyPersona_matchesTheDesignMatrix`
    /// checks the whole table rather than a row at a time — the matrix was
    /// swept row-wise twice and lost a cell each time (Review's translation
    /// and palette, then Plan's tasks).
    ///
    /// The amendment's departures, delivered by the persona shell's slice 1:
    /// `.outline` leaves every persona, `.translation` and `.intent` leave
    /// Publish, and `.history` joins Author. `.outline` leaves because the tree
    /// shows structure and `OutlinePane` is read-only — it renders and sets the
    /// selection but has no create, move or delete, so it cannot be the
    /// structure surface Plan needs. **Leaving a registry is a demotion, not a
    /// removal**: ⌘⌥O still binds unconditionally in `MaughamApp`'s View menu,
    /// `DetailPaneToggle.visibleSegments(including:)` appends an unregistered
    /// selection, and `segmentContent` still renders `OutlinePane`. Personas
    /// are lenses, not gates.
    ///
    /// Still owed to the amendment, and NOT slice 1's: `.tasks` leaves Plan,
    /// and `.inspector` dissolves into per-persona sections (§5.1, slice 4).
    /// They are listed in `PersonaPaneRegistryTests.notYetDelivered`, which is
    /// the ledger — not this comment.
    ///
    /// One deliberate deviation, marked at its case below: Publish carries
    /// `.inspector`, which §6.3 gives it as `—`.
    ///
    /// Reserved for later milestones of this redesign: `.diagnostics` →
    /// author; `.references` → author, review; `.editions` → publish.
    /// (`.intent` and `.visualLanguage` were reserved here too and are consumed
    /// as of M1A — their §6.3 cells are below.)
    var panes: [DetailSegment] {
        switch self {
        case .plan:
            // Primaries first, then the ○ cells: Tasks is planning-adjacent
            // (what the writer intends to do next), Inspector is metadata.
            // Intent and Visual Language are both ● here — planning is where a
            // book's aim and its look are decided.
            //
            // `.outline` left in slice 1 of the persona shell: Plan is where
            // structure gets built, and a read-only outline is not that.
            return [.research, .palette, .inbox,
                    .intent, .visualLanguage, .tasks, .inspector]
        case .author:
            // Intent is ○: the chapter's aim is worth a glance while drafting,
            // but Author leads with the document itself. Visual language is —
            // for Author, and stays absent.
            //
            // `.history` joined in slice 1 of the persona shell. It takes
            // `activeDocId` like any per-document pane and works wherever a
            // document is selected; it was registered only in Review, so ⌘⌥H
            // in Author summoned a pane that `PersonaMemory` then refused to
            // keep. `.inspector` stays first — Author is the default persona
            // and its landing pane must not move under an upgrading writer.
            // `.history` goes last for the same reason: nothing above it moves.
            return [.inspector, .research, .tasks, .palette, .intent, .history]
        case .review:
            // Order follows the review workflow: adjudicate notes, see what
            // changed, check the translated edition, then the supporting
            // lenses. Translation and Palette are ○ in the design's pane ×
            // persona matrix (§6.3) — reviewing a translated edition IS a
            // review activity, and `ProjectWindow` force-sets
            // `detailSegment = .translation` on entering translation review.
            //
            // Intent is ● here for the reason the milestone exists: review's
            // job is to compare a draft against the intent you started with, so
            // it sits with the notes and the diff rather than among the lenses.
            // Visual language is ○. `.outline` left in slice 1 with every
            // other persona's.
            return [.annotations, .history, .intent, .translation,
                    .inspector, .tasks, .palette, .visualLanguage]
        case .publish:
            // Thin until M1D gives Publishing its own surfaces (editions,
            // config). Visual language arrives here in M1A — §6.3 marks it ●
            // for Publish, and Publish's column is where "how the book looks"
            // is read.
            //
            // `.translation` and `.intent` left in slice 1 of the persona
            // shell. `TranslationReviewPane` is source text plus translator
            // queries — adjudication, which is Review's job, not building an
            // edition; and Publish is not where a book's aim is read.
            //
            // TWO CONSEQUENCES, stated so a reviewer does not have to
            // rediscover them. **Publish's default pane moves from Translation
            // to Visual Language**, because `defaultPane` is `panes.first`;
            // that is the design — visual language IS Publish's built work
            // today. And Publish now sits exactly on the two-pane floor
            // `PersonaPaneRegistryTests.test_everyPersona_offersAtLeastTwoPanes`
            // asserts, so the `.inspector` deviation below stops being a
            // nicety and becomes the only thing holding that floor.
            //
            // DELIBERATE DEVIATION from §6.3, which marks Inspector `—` for
            // Publish, and from the 2026-08-01 amendment, which dissolves it
            // everywhere. It stays until the Publishing section becomes
            // Publish's own pane (slice 4). The reason recorded here before —
            // "without it the picker was a single button, which reads as
            // broken chrome" — is TOO WEAK and the amendment (§5.1) says so by
            // name: `InspectorPublishSection` is the only UI in the app for
            // per-piece publish config (include in ToC, start-on, title
            // override), so removing it now deletes the writer's
            // table-of-contents control. A comment stating a weaker reason
            // than the real one is how a later reader acts on the weaker one.
            return [.visualLanguage, .inspector]
        }
    }

    var defaultPane: DetailSegment {
        // `panes` is never empty — PersonaPaneRegistryTests enforces ≥2.
        panes.first ?? .inspector
    }

    /// Map a segment onto one this persona actually offers. Used when the
    /// writer switches persona while sitting on a pane the destination does
    /// not have — the same shape as `BinderSegment.documentHome(for:)`, which
    /// exists because re-deriving that check inline shipped a real bug
    /// (2026-07-02 smoke finding).
    func coerce(_ segment: DetailSegment) -> DetailSegment {
        panes.contains(segment) ? segment : defaultPane
    }
}

// MARK: - Left column

public extension Persona {
    /// Binder segments this persona offers, in picker order. The first is the
    /// persona's `binderHome` — where entering the persona lands. `.trash` and
    /// `.find` stay conditional on their existing runtime predicates and are
    /// appended by `BinderSegmentPicker`, not listed here: they are transient
    /// states, not persona surfaces.
    ///
    /// Manuscript-shaped entries go through `BinderSegment.documentHome(for:)`
    /// and NEVER name `.manuscript` directly — a screenplay binder has no
    /// Manuscript segment (the Scenes segment IS the slugline navigator inside
    /// the single `.fountain`), and forcing `.manuscript` on one drops the
    /// writer into a one-row `BinderView` (2026-07-02 smoke finding).
    /// `PersonaBinderSegmentTests.test_screenplayPersonasNeverOfferManuscript`
    /// pins that.
    ///
    /// Reconciled against the three-column table in §6.3 of
    /// `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`,
    /// which gives each persona a Left surface: Plan "Research tree", Author
    /// "Binder", Review "Pieces by review state", Publish "Editions". One of
    /// those four surfaces does not exist yet (M1D builds the editions list), so the deviations are recorded at their cases below.
    func binderSegments(for projectType: ProjectType) -> [BinderSegment] {
        let home = BinderSegment.documentHome(for: projectType)
        switch self {
        case .plan:
            // §6.3 gives Plan a canvas centre column, so the canvas leads and is
            // therefore `binderHome` — entering Plan lands on it. Research and
            // Palette follow: Research is §6.3's Left surface, and the binder is
            // where a palette card is picked.
            //
            // The manuscript segment stays deliberately ABSENT, for the reason
            // recorded before the canvas existed: the coercion rule keeps any
            // segment the destination offers, so including it would let a writer
            // entering Plan from the manuscript simply stay on it and never see
            // the planning surfaces at all. Not a gate — a forced navigation
            // still selects the manuscript segment and `visibleSegments`
            // renders it, and ⌘2 is one keystroke away.
            return [.canvas, .research, .palette]
        case .author:
            // §6.3 Left = "Binder". Exactly today's segment list, in today's
            // order — the default persona must look unchanged to an upgrading
            // writer.
            return [home, .research, .palette]
        case .review:
            // DELIBERATE DEVIATION: §6.3 Left = "Pieces by review state",
            // which is not built. The ordinary binder stands in, and Palette
            // drops out — it is a making surface, not an adjudicating one.
            return [home, .research]
        case .publish:
            // DELIBERATE DEVIATION: §6.3 Left = "Editions", which M1D builds.
            // Until then the binder stands in, plus Research so the picker is
            // a choice rather than a single button reading as broken chrome —
            // the same reasoning recorded at `.publish`'s `.inspector` pane.
            return [home, .research]
        }
    }

    /// Where this persona lands when entered. Always the head of its own
    /// segment list, so the offered set and the landing spot cannot disagree;
    /// `PersonaBinderSegmentTests.test_everyPersonaBinderHome_isAmongItsOwnSegments`
    /// pins that for every persona × project type.
    func binderHome(for projectType: ProjectType) -> BinderSegment {
        // `binderSegments` is never empty — every case above returns ≥2.
        binderSegments(for: projectType).first ?? BinderSegment.documentHome(for: projectType)
    }
}
