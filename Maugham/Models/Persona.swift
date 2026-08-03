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
    /// **ONE ORDER, FOUR SUBSETS.** §5.0 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// (2026-08-03) — an amendment that supersedes §5's per-persona lists for
    /// the right column. Every case below is the SAME sequence with non-members
    /// removed:
    ///
    ///     Annotations · Inbox · Research · Palette · Intent ·
    ///     Visual Language · Tasks · Translation · History · Inspector
    ///
    /// Denver: *"it'll be confusing if I am always hunting for the right option
    /// in different modes, so the order should be one set and things just
    /// disappear or appear in it, and we have some common anchors."* Tasks
    /// divides what you work *with* from what flows *through*; History and
    /// Inspector close the row, Inspector outermost.
    ///
    /// **So a case below chooses MEMBERSHIP and never position.** The order is
    /// transcribed once, in `PersonaPaneRegistryTests.canonicalPaneOrder`, and
    /// `test_everyPersonasPanesAreTheCanonicalOrderFilteredToItsMembers`
    /// compares all four against it — the first assertion of pane order the
    /// suite has ever carried. Until 2026-08-03 order was asserted NOWHERE: a
    /// reorder that kept every persona's first element passed the entire suite
    /// while changing the picker for every writer.
    ///
    /// **`.inspector` is last so `defaultPane = panes.first` survives.** Each
    /// persona's default falls out of membership plus that shared order and
    /// nothing selects it. Inspector first, which an earlier draft of §5.0 had,
    /// would land every persona on Inspector and force this property to become
    /// an order plus a separate default — two values that can disagree about
    /// where a persona opens.
    ///
    /// **The rule §5.0 sorts by is *what a persona authors*: the left column is
    /// where a thing is made, the right is what you glance at while making
    /// something else. Do NOT generalise that into a law about this registry.**
    /// The audit behind §5.0 falsified the general form outright — eight of the
    /// eleven right-hand panes write, and `LinkedResearchPane` creates notes,
    /// files and links. What holds across the column is subject-taking panes
    /// versus self-selecting browsers; make-left/consult-right is exactly right
    /// for Palette and is argued pane by pane at the cases below.
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
    /// that matrix now has three documents, each later than the last. §6.3 of
    /// `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md` is
    /// the base; §5 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// amends it; **§5.0 of that same document supersedes §5's per-persona
    /// lists for THIS registry**, and is what the four cases below transcribe.
    /// The left column is untouched by it.
    /// `PersonaPaneRegistryTests.test_everyPersona_matchesTheDesignMatrix`
    /// checks the whole table rather than a row at a time — the matrix was
    /// swept row-wise twice and lost a cell each time (Review's translation
    /// and palette, then Plan's tasks).
    ///
    /// **Leaving a registry is a demotion, not a removal**, and §5.0 leans on
    /// that harder than any slice before it: ⌘⌥-letters bind unconditionally in
    /// `MaughamApp`'s View menu, `DetailPaneToggle.visibleSegments(including:)`
    /// appends an unregistered selection, and `segmentContent` renders every
    /// case. So ⌘⌥N still writes intent in Plan and ⌘⌥L still opens the
    /// translation pane in Review; what changed is which panes a persona *leads
    /// you to*. Personas are lenses, not gates. (`.outline` is the one pane in
    /// no registry at all — the tree shows structure and `OutlinePane` is
    /// read-only, so it cannot be the structure surface Plan needs.)
    ///
    /// Still owed to the design, and NOT this re-cut's: `.inspector` dissolves
    /// into per-persona sections (§5.1, slice 4). §5.0 keeps it in all four
    /// until then — it anchors the far end of the order — so it is listed in
    /// `PersonaPaneRegistryTests.notYetDelivered`, the ledger, rather than
    /// counted here. **Plan's `.tasks` came OFF that ledger**: §5 said Plan
    /// loses it, §5.0 is later and gives it back, so it is design now.
    ///
    /// Reserved for later milestones of this redesign: `.diagnostics` →
    /// author; `.references` → author, review; `.editions` → publish.
    /// (`.intent` and `.visualLanguage` were reserved here too and are consumed
    /// as of M1A — their §6.3 cells are below.)
    var panes: [DetailSegment] {
        switch self {
        case .plan:
            // Inbox · Tasks · History · Inspector.
            //
            // **Plan lost Research, Palette, Intent and Visual Language in
            // §5.0's re-cut, because Plan AUTHORS all four.** Research and
            // Palette already have their left segments here, so those two are
            // moves. Intent and Visual Language do NOT yet: §5.0 parks their
            // left-column home as a build (a `BinderSegment` case each, a
            // centre route, and a decision about what the left pane shows while
            // you edit), and until it ships **they are reachable in Plan by
            // ⌘⌥N and ⌘⌥V only**. That is a real cost, stated in §5.0 and
            // accepted by Denver rather than overlooked.
            //
            // `.history` is NEW here and is Denver's call: *"which will make
            // more sense when a future milestone versions research notes, but
            // even now I think it's a useful reference of the evolution of the
            // manuscript."*
            //
            // `.tasks` STAYS. §5 had Plan losing it; §5.0 is later and gives it
            // back, so it is design rather than a departure owed — see
            // `PersonaPaneRegistryTests.designMatrix`.
            //
            // **`.inspector` here is the CANVAS's inspector and can never be
            // `InspectorView`, which is the reason it is worth keeping.**
            // `ProjectWindow.inspectorRoute` tests `centresTheCanvas` before
            // anything else, and both of Plan's canvas segments (`.canvas`,
            // `.tree`) answer true, so ⌘⌥I in Plan inspects the selected
            // region, line or card. A later reader who "fixes" this by
            // expecting document metadata would be undoing that routing on
            // purpose; a chapter's metadata is Author's (⌘2).
            //
            // **Defaulting to `.inbox` also closes a live defect** (the audit's
            // finding A, recorded rather than fixed separately). Plan's default
            // was `.research` → `LinkedResearchPane`, which needs a manuscript
            // document; Plan lands on `.canvas`, whose left pane is the
            // RESEARCH tree and never writes `selectedSubject`. So entering
            // Plan on a fresh window showed "No document selected" with no
            // control in either visible column able to change it.
            //
            // `.outline` left in slice 1: Plan is where structure gets built,
            // and a read-only outline is not that.
            return [.inbox, .tasks, .history, .inspector]
        case .author:
            // Research · Palette · Intent · Tasks · History · Inspector.
            //
            // **§5.0 changed Author's ORDER and not its membership.** This is
            // the persona the right column was designed for: it consults what
            // Plan authors — what the open chapter points at (⌘⌥R), a palette
            // card beside the prose (⌘⌥P), the chapter's aim (⌘⌥N). Visual
            // language is — for Author and stays absent.
            //
            // **Author's landing pane MOVES from Inspector to Research, and
            // the reason recorded here before is overruled by name.** It read:
            // *"`.inspector` stays first — Author is the default persona and
            // its landing pane must not move under an upgrading writer."* §5.0
            // answers it: one order shared by all four personas is worth more
            // to a writer than one persona's landing pane holding still, and
            // Inspector at the far end is the one position where every persona
            // can find it. The same sentence is why `.history` is no longer
            // pinned to the end.
            //
            // `.history` joined in slice 1 — it takes `activeDocId` like any
            // per-document pane, and before that ⌘⌥H in Author summoned a pane
            // `PersonaMemory` then refused to keep.
            return [.research, .palette, .intent, .tasks, .history, .inspector]
        case .review:
            // Annotations · Intent · Tasks · History · Inspector.
            //
            // Intent is ● here for the reason the milestone exists: review's
            // job is to compare a draft against the intent you started with.
            // `.annotations` leads, which is the suite's one long-standing
            // order constraint (`test_reviewPersona_leadsWithAnnotations`) and
            // now also falls out of the canonical order.
            //
            // **§5.0 took three: Palette (authoring, so Plan's), Visual
            // Language (Publish's), and Translation.** Translation is a
            // reversal §5.0 records as one — §5 had just moved it HERE, calling
            // it adjudication rather than edition-building, and Denver
            // overturned that: *"I'm more convinced translation should be
            // logically part of the publish flow. We are not changing the
            // source, it's effectively a transformation for publish."* A
            // translation never mutates the manuscript — it is a parallel,
            // paragraph-keyed layer with a coverage gate on the compile — so
            // what it belongs to is the edition. Review adjudicates what will
            // change the source; translation cannot.
            //
            // **`ProjectWindow` still force-sets `detailSegment = .translation`
            // on entering translation review, and that still works from any
            // persona**: `DetailPaneToggle.visibleSegments(including:)` appends
            // it and the picker renders it selected
            // (`DetailPaneTogglePersonaTests
            // .test_visibleSegments_includeTranslationWhenForcedOutsideItsPersonas`).
            // Demotion, not removal.
            //
            // `.outline` left in slice 1 with every other persona's.
            return [.annotations, .intent, .tasks, .history, .inspector]
        case .publish:
            // Visual Language · Tasks · Translation · History · Inspector.
            //
            // Visual language leads, and did before §5.0: §6.3 marks it ● for
            // Publish and it is Publish's built work today. `.intent` left in
            // slice 1 — Publish is not where a book's aim is read.
            //
            // **`.translation` ARRIVES here in §5.0, reversing the slice-1 move
            // that had just taken it to Review** — the argument is Denver's and
            // is spelled at `.review` above. Tasks and History come with it,
            // and Publish stops sitting exactly on the two-pane floor
            // `PersonaPaneRegistryTests.test_everyPersona_offersAtLeastTwoPanes`
            // asserts.
            //
            // **`.inspector` is no longer a DEVIATION** — §5.0's order gives it
            // to all four personas, so Publish's copy is on
            // `notYetDelivered` with everyone else's rather than in
            // `documentedDeviations`. What is still Publish's alone is why it
            // will be the LAST one §5.1 can dissolve:
            // `InspectorPublishSection` is the only UI in the app for per-piece
            // publish config (include in ToC, start-on, title override), so
            // removing it before slice 4 gives Publish its own pane deletes the
            // writer's table-of-contents control. The reason recorded here
            // before slice 1 — "without it the picker was a single button,
            // which reads as broken chrome" — is TOO WEAK, and it no longer
            // holds at all now that Publish carries five panes; a comment
            // stating a weaker reason than the real one is how a later reader
            // acts on the weaker one.
            return [.visualLanguage, .tasks, .translation, .history, .inspector]
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
    ///
    /// **THIS REGISTRY AND `panes` FAIL DIFFERENTLY, and §6.1 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md` is
    /// where that was finally written down.** Every right-hand pane has a
    /// `⌘⌥`-letter in `MaughamApp`'s View menu, so dropping a pane from `panes`
    /// is a DEMOTION — ⌘⌥O still opens Outline in every persona. **There is no
    /// keyboard route to a `BinderSegment` at all**, so dropping a segment from
    /// here is a REMOVAL: the only route back is switching persona. §8's
    /// "personas are lenses, never gates" is therefore true of one of the two
    /// registries, and every subtraction below is made knowing which.
    func binderSegments(for projectType: ProjectType) -> [BinderSegment] {
        let home = BinderSegment.documentHome(for: projectType)
        switch self {
        case .plan:
            // §6.3 gives Plan a canvas centre column, so the canvas leads and is
            // therefore `binderHome` — entering Plan lands on it. `.tree` is
            // slice 2's addition and sits second (see below). Research and
            // Palette follow: Research is §6.3's Left surface, and the binder is
            // where a palette card is picked.
            //
            // **`.tree` is Plan's manuscript tree with the CANVAS still in the
            // centre** (spec §3.1) — the structure segment. It closes §1's hole,
            // which Denver hit within minutes of opening Plan on 2026-08-02:
            // "the binder hasn't appeared in plan view."
            //
            // **The manuscript segment itself stays absent, and the reason
            // recorded here before is now false.** It read: "the coercion rule
            // keeps any segment the destination offers, so including it would
            // let a writer entering Plan from the manuscript simply stay on it."
            // **That rule no longer exists.** `PersonaMemory.restoredBinderSegment`
            // replaced it: a persona switch restores the DESTINATION's own
            // remembered position, so a writer arriving in Plan lands where they
            // last stood in Plan and never on the segment they came from. The
            // old argument could not survive that and does not need to.
            //
            // What is true now, and it is a different answer rather than a
            // reversal of that one: `.manuscript` means "the editor in the
            // centre", and §2 says Plan does not draft. `.tree` gives Plan the
            // same TREE without the same CENTRE — which is precisely why it is a
            // case of its own and not a reuse of the manuscript home (see
            // `BinderSegment.tree`). Adding `.manuscript` here would put a text
            // editor in Plan; adding `.tree` puts a structure surface there.
            //
            // Ordering is unchanged on purpose: `binderHome` is `.first`, so
            // Plan still lands on the canvas, which is what §6.3 gives it and
            // what every writer of it has opened into so far.
            return [.canvas, .tree, .research, .palette]
        case .author:
            // §6.3 Left = "Binder", and after slice 2 that is all it is: the
            // manuscript home, alone.
            //
            // `.research` LEFT in slice 2 task 6 of the persona shell (§6.1).
            // The argument is not convenience — it is that **the right-hand
            // registry already said research is not Review's or Publish's
            // business** (at the time `.research` was a pane in Plan and Author
            // and absent from both the others; §5.0's re-cut has since taken it
            // off Plan too, on the grounds that Plan AUTHORS research — the
            // same conclusion from the other side), so the left column was the
            // half that disagreed. Editing research is making planning
            // material, which is
            // Plan's output under §2's rule, and Author keeps
            // `LinkedResearchPane` on the right (⌘⌥R) for reading what the open
            // chapter points at.
            //
            // **`.palette` followed in task 6b, on a WEAKER warrant — and the
            // weaker one is what is written here.** Nothing disagreed: at the
            // time palette was a left segment in Plan and Author and a right
            // pane in Plan, Author and Review, so the left set was a strict
            // SUBSET of the right set. (§5.0's re-cut has since taken the
            // palette PANE off Plan and Review, so the two registries now read
            // as complements — made on Plan's left, consulted on Author's
            // right. That is the same conclusion arrived at from the other
            // side, and it does not disturb this case.) This is §6.1's
            // principle applied further, not a
            // contradiction corrected. The principle: the left segment is
            // `PaletteBinderList` and picking a card puts `PaletteCardEditor`
            // in the CENTRE, which is making palette material; the right pane
            // is `PalettePane`, "read-only images, swatches, and sensory notes
            // beside the editor" by its own doc comment, which is consulting it
            // while drafting. Making is Plan's, consulting is Author's, and
            // ⌘⌥P is the route Author keeps
            // (`PersonaBinderSegmentTests.test_theWallIsPlansAndTheCardIsStillAuthorsThroughTheRightColumn`).
            // Overstating this as a contradiction would put a stronger reason
            // in the code than the true one — §5.1's own lesson about a comment
            // recording a WEAKER reason than the real one, running the other
            // way.
            //
            // **THE ASYMMETRY THIS LEAVES, recorded because smoke meets it.**
            // Two event routes still force `.research` in Author —
            // `ProjectWindow.openResearchItem` (the **Open** button on a
            // promoted canvas card) and `handleShowLatestMCPNote` (the **Show**
            // button on the MCP note banner). And `loadProject` restores
            // `UIState.binderSegment` VERBATIM — it filters `.manuscript` on a
            // screenplay and nothing else — so a project last quit in Author on
            // the palette wall reopens there once, on the build that takes the
            // segment away. All three still render, highlighted, because
            // `BinderSegmentPicker.visibleSegments` appends the current
            // selection; that is the lens-not-gate half working. But Author now
            // has NO picker route in and ⌘1 as the only way back out. Pinned by
            // `test_aForcedResearchSegmentStillRendersInEveryPersona` and
            // `test_aRestoredPaletteSegmentStillRendersInEveryPersona`.
            return [home]
        case .review:
            // DELIBERATE DEVIATION: §6.3 Left = "Pieces by review state",
            // which is not built. The ordinary binder stands in. Palette
            // dropped out as a making surface rather than an adjudicating one,
            // and `.research` followed it in slice 2 (§6.1) for the reason
            // spelled at `.author` above — Review has no research pane on the
            // right either, so nothing here disagrees with anything there.
            //
            // ONE SEGMENT, on purpose. The "a single button reads as broken
            // chrome" worry recorded at `.publish` before is answered rather
            // than ignored: this column is ALREADY a deviation standing in for
            // an unbuilt surface, so a single entry makes the placeholder
            // visible instead of disguising it, and M3 supplies the real second
            // entry. Padding a picker with a segment that does not serve the
            // persona is exactly what slice 1 refused to do for `.outline`.
            return [home]
        case .publish:
            // DELIBERATE DEVIATION: §6.3 Left = "Editions", which M1D builds.
            // Until then the binder stands in, alone — `.research` left in
            // slice 2 (§6.1), and with it the reason recorded here before
            // ("plus Research so the picker is a choice rather than a single
            // button reading as broken chrome"), which §6.1 overrules by name.
            // See `.review` above for why one segment is the honest shape for a
            // column that is standing in for an unbuilt surface; M4 supplies
            // Publish's real second entry.
            return [home]
        }
    }

    /// Where this persona lands when entered. Always the head of its own
    /// segment list, so the offered set and the landing spot cannot disagree;
    /// `PersonaBinderSegmentTests.test_everyPersonaBinderHome_isAmongItsOwnSegments`
    /// pins that for every persona × project type.
    func binderHome(for projectType: ProjectType) -> BinderSegment {
        // `binderSegments` is never empty — every case above returns at least
        // its own `home`, and `home` is what this falls back to anyway, so the
        // two answers agree even if one day a case returns nothing.
        //
        // **There is no floor on THIS side and there deliberately is not one.**
        // `PersonaPaneRegistryTests.test_everyPersona_offersAtLeastTwoPanes` is
        // about the RIGHT-hand registry; slice 2 took Review, Publish AND
        // Author to a single binder segment each on purpose (§6.1), so a ≥2
        // assertion here would be asserting a coincidence that has already
        // stopped being true — three times over, leaving Plan the only persona
        // whose left column is a choice at all (§6.2, revisited after slice 7).
        binderSegments(for: projectType).first ?? BinderSegment.documentHome(for: projectType)
    }

    /// **Would this persona's centre column show a manuscript document?**
    ///
    /// The guard behind Denver's 2026-08-02 ruling — *"if I'm moving to the
    /// manuscript I'm moving to Author"* — and the one question
    /// `ManuscriptNavigation` asks before it moves anyone.
    ///
    /// **It is asked of the binder registry, never of a persona name.** The
    /// centre column routes off the SEGMENT (`ProjectWindow.editorRoute`), and
    /// `BinderSegment.documentHome(for:)` is the segment whose centre is the
    /// document — `.manuscript` for a novel, a short story and a Collection,
    /// `.scenes` for a screenplay. So a persona shows documents exactly when its
    /// own column offers that segment, and today Plan is the only one that does
    /// not. That fact FALLS OUT of the registry rather than being asserted: a
    /// hardcoded `== .plan` reads identically today and ships the defect the
    /// moment Review's left column changes, because clicking an annotation or a
    /// history row navigates to a paragraph and a reviewer ejected into Author
    /// cannot adjudicate — the one job Review exists for.
    ///
    /// This is the neighbour of `BinderSegment.centresTheCanvas` and is
    /// deliberately NOT a second spelling of it: that answers "which segments
    /// draw the canvas", this answers "which personas offer the document". Both
    /// are asked at the segment level and neither re-derives the other.
    func showsManuscriptDocuments(for projectType: ProjectType) -> Bool {
        Self.showsManuscriptDocuments(in: binderSegments(for: projectType),
                                      for: projectType)
    }

    /// The rule over ANY column, so it can be falsified.
    ///
    /// Split out because all four real registries agree with a `== .plan`
    /// shortcut, so no test over `Persona.allCases` can tell the correct
    /// implementation from the lazy one — the discriminator has to be a segment
    /// list this app does not ship
    /// (`ManuscriptNavigationTests.test_theRuleIsAboutTheDocumentHome_notAboutAnyParticularPersona`).
    static func showsManuscriptDocuments(in segments: [BinderSegment],
                                         for projectType: ProjectType) -> Bool {
        segments.contains(BinderSegment.documentHome(for: projectType))
    }
}
