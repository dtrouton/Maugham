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
    ///     Annotations · Inbox · Intent ·
    ///     Visual Language · Tasks · Translation · History · Inspector
    ///
    /// Research and Palette left this order whole (stage 3a Task 6): every
    /// tree grew its own section for both (stage 2a), and ⌘⌥R/⌘⌥P now reveal
    /// those sections instead of opening a right-pane segment.
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
    /// you to*. Personas are lenses, not gates. (`.outline` was demoted to no
    /// registry at all in slice 1 — the tree shows structure and the pane was
    /// read-only, so it could not be the structure surface Plan needs — and
    /// stage 3a Task 6 finished the job: the case is deleted outright, its
    /// altitude view now built into the centre column instead.)
    ///
    /// Still owed to the design, and NOT this re-cut's: `.inspector` dissolves
    /// into per-persona sections (§5.1, slice 4). §5.0 keeps it in all four
    /// until then — it anchors the far end of the order — so it is listed in
    /// `PersonaPaneRegistryTests.notYetDelivered`, the ledger, rather than
    /// counted here. **Plan's `.tasks` came OFF that ledger**: §5 said Plan
    /// loses it, §5.0 is later and gives it back, so it is design now.
    ///
    /// Reserved for later milestones of this redesign: `.editions` → publish.
    /// (`.intent` and `.visualLanguage` were reserved here too and are consumed
    /// as of M1A; `.diagnostics` as of M2 Task 8; `.references` as of M2 Plan
    /// 2's Task 5 — their §6.3 cells are below.)
    var panes: [DetailSegment] {
        switch self {
        case .plan:
            // Inbox · Tasks · History · Inspector.
            //
            // **Plan lost Research, Palette, Intent and Visual Language in
            // §5.0's re-cut, because Plan AUTHORS all four.** Research and
            // Palette already have their homes in this persona's tree, so those
            // two are moves. Intent and Visual Language do NOT yet: §5.0 parks
            // their left-column home as a build (a section of the tree each, a
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
            // `ProjectWindow.inspectorRoute` tests `Persona.centresTheCanvas`
            // before anything else, and Plan is the persona that answers true,
            // so ⌘⌥I in Plan inspects the selected
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
            // `.outline` left in slice 1 (Plan is where structure gets built,
            // and a read-only outline was not that) and the case itself is
            // gone as of stage 3a Task 6. The altitude view built in Tasks 1-3
            // is NOT Plan's structure surface — `subjectShowsAltitude` refuses
            // Plan on the persona guard (`showsManuscriptDocuments`), so
            // Plan's project row keeps showing the undimmed board
            // (`test_planNeverShowsAltitudeWhateverTheSubject`). Plan's
            // structure surfaces are still the tree and the canvas.
            return [.inbox, .tasks, .history, .inspector]
        case .author:
            // Diagnostics · Intent · References · Tasks · History · Inspector.
            //
            // **Research and Palette left this list whole in stage 3a Task
            // 6.** Every tree grew its own section for both (stage 2a), and
            // ⌘⌥R/⌘⌥P now reveal those sections instead of opening a pane
            // here — building and browsing research/palette material is a
            // tree action in every persona, never Author-exclusive.
            // `LinkedResearchPane` and `PalettePane`, the two views that used
            // to mount here, are deleted outright.
            //
            // **This is still the persona the right column was designed
            // for**: it consults what Plan authors. Today that means
            // **References** (⌘⌥E) — the research the writer linked to the
            // open chapter, and the cards clustered for it on the canvas —
            // beside **Intent** (⌘⌥N), the chapter's aim. Before stage 3a,
            // Research and Palette did that consulting job directly: ⌘⌥R
            // showed what the chapter pointed at, ⌘⌥P kept a card open
            // beside the prose. References absorbed that job when the two
            // panes left. Visual Language is Publish's and stays absent
            // here.
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
            //
            // **`.diagnostics` joined in M2 Task 8 and leads, moving Author's
            // default off Research a second time.** It is the fast loop's own
            // pane — the compiler's notes on what the writer just wrote — and
            // Author is its one persona: the compiler answers ⌘R from
            // whichever document is open, which only happens while drafting.
            // Placed first in `canonicalPaneOrder` for the same reason
            // Annotations leads Review (`test_reviewPersona_leadsWithAnnotations`)
            // — the two loops the design separates (Diagnostics fast, serving
            // Author; Annotations durable, serving Review) each get the front
            // of their one persona's row.
            //
            // **`.references` joined in M2 Plan 2's Task 5, immediately after
            // `.intent`, and that position is an argument rather than the next
            // free slot.** §6.3 marks it ● for Author, and the pane holds the
            // union of the research the writer LINKED to this document and the
            // cards they clustered for it on the canvas
            // (`PinnedReferences.pinned`) — the same set the compiler is
            // briefed on. Beside Intent it puts what the piece is *going for*
            // next to what it is *made of*, which is the pair a writer consults
            // together, and keeps both on the working-with side of Tasks.
            return [.diagnostics, .intent, .references,
                    .tasks, .history, .inspector]
        case .review:
            // Annotations · Intent · References · Tasks · History · Inspector.
            //
            // **`.references` is ○ rather than ● here (§6.3), and it is in for
            // Intent's reason applied one step further.** Review compares a
            // draft against the intent it started from; the pinned set is what
            // that intent was to be built out of, so a reviewer asking whether
            // a chapter used what it was pointed at has the shelf without
            // leaving the persona. It does not lead — adjudicating does.
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
            // `.outline` left in slice 1 with every other persona's, and the
            // case itself is gone as of stage 3a Task 6.
            //
            // **`.inspector` is here for a reason of its own, and the shared
            // doc comment's — "it anchors the far end of the order" — is not
            // it.** That warrant is cosmetic, and a cosmetic warrant is what
            // this milestone has now twice come within one edit of acting on
            // (see `.publish` below, and §5.1 of the persona-shell spec, which
            // records the near-miss). Written down here so the next reader
            // cannot delete this entry on the weaker one.
            //
            // The real reason: **the Inspector is where a writer rules on a
            // review pass** — the record Review is *about*. In Review the left
            // column is the project's own tree (`TreePane`), and Review does
            // not `centresTheCanvas`, so `ProjectWindow.inspectorRoute`
            // returns `.collectionPiece` on a Collection and `.document`
            // otherwise, and both arms land on the pass LADDER
            // (`PassLadder`, hosted by `PieceInspector.statusSection` and
            // `InspectorView`'s Document section): one row per
            // `ProjectManifest.effectiveReviewPasses` entry, each saying where
            // this piece stands, with the derived `ReviewStatus` read-only
            // above it. Those two files are the only callers of
            // `ProjectStore.setPassState`, and no MCP tool writes the record.
            // Take `.inspector` off Review and the persona whose job is
            // adjudicating a draft cannot record a verdict at all; the writer
            // has to leave for another persona to mark a chapter's Copyedit
            // done.
            //
            // **This argument was re-made in M3 P1 Task 4, not merely
            // reworded.** It used to rest on `StructureItem.status`, the free
            // string the two inspector pickers wrote through
            // `updateInspector(… status:)`. That argument survived its own
            // control: the pickers are gone, the argument's field is
            // legacy-read-only (`ReviewStatus.derived` falls back to it and
            // nothing writes it), and the reasoning now names the thing that
            // actually stands here.
            //
            // Pinned by `PersonaPaneRegistryTests
            // .test_reviewKeepsTheInspectorBecauseItIsWhereAPassIsRuledOn`,
            // whose census goes red if a third pass-state writer appears — at
            // which point this argument needs re-making again, not patching.
            // (M3 P1 Task 8's Review board is expected to be that third writer,
            // and it does not weaken this: the board is Review's own centre
            // column, so it adds a Review surface rather than moving the ladder
            // out of the Inspector.)
            return [.annotations, .intent, .references, .tasks, .history, .inspector]
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
    /// not have — a named rule rather than an inline containment check at each
    /// site, for `TreePane`'s reason one column over: re-deriving that kind of
    /// check inline shipped a real bug (2026-07-02 smoke finding).
    func coerce(_ segment: DetailSegment) -> DetailSegment {
        panes.contains(segment) ? segment : defaultPane
    }
}

// MARK: - The centre column

public extension Persona {
    /// **Would this persona's centre column show a manuscript document?**
    ///
    /// The guard behind Denver's 2026-08-02 ruling — *"if I'm moving to the
    /// manuscript I'm moving to Author"* — and the one question
    /// `ManuscriptNavigation` asks before it moves anyone.
    ///
    /// **It was asked of the binder registry until stage 2b Task 6, and now it
    /// is asked of the centre column.** The old form was
    /// `binderSegments(for:).contains(documentHome(for:))` — a persona shows
    /// documents exactly when its own left column offers the segment whose
    /// centre is the document. Task 7 deleted that basis outright, enum and both
    /// registries together, and a rule resting on a list that no longer exists
    /// could not have been the one that survived.
    ///
    /// **What replaced it is still not a persona NAME.** A hardcoded
    /// `== .plan` reads identically today and ships the defect the moment
    /// another persona's centre changes, because clicking an annotation or a
    /// history row navigates to a paragraph and a reviewer ejected into Author
    /// cannot adjudicate — the one job Review exists for. So it is derived from
    /// `centresTheCanvas` through the falsifiable static below: the centre
    /// column holds one thing or the other, and a persona shows documents
    /// exactly when the board is not what it holds.
    ///
    /// **It is now openly the complement of `centresTheCanvas`, and the comment
    /// that said the two were "deliberately NOT a second spelling" is retired
    /// rather than dropped.** That was true while one was asked of segments and
    /// the other of registries — two different questions at two different
    /// levels. On one axis they are the same question, and leaving them as two
    /// independent switches over four cases would be two answers that can
    /// disagree about what Plan's centre column is.
    var showsManuscriptDocuments: Bool {
        Self.showsManuscriptDocuments(centresTheCanvas: centresTheCanvas)
    }

    /// The rule over ANY centre column, so it can be falsified.
    ///
    /// Split out for exactly the reason the segment-list version was: all four
    /// real personas agree with a `== .plan` shortcut, so no test over
    /// `Persona.allCases` can tell the correct implementation from the lazy
    /// one. The discriminator has to be an input this app does not ship — a
    /// centre column that draws the board without being Plan's, or Plan's
    /// without drawing it
    /// (`ManuscriptNavigationTests.test_theRuleIsAboutTheCentreColumn_notAboutAnyParticularPersona`).
    static func showsManuscriptDocuments(centresTheCanvas: Bool) -> Bool {
        !centresTheCanvas
    }

    /// **The one spelling of "the centre column is the planning canvas".**
    ///
    /// The successor to `BinderSegment.centresTheCanvas` (shell-finish stage 2b
    /// Task 6), and the reason the question moved: the board is Plan's centre
    /// column and always was. The segment was only ever a proxy for the persona
    /// — Plan offered the two segments that drew it and nobody else offered
    /// either — and that proxy cost three separate sites a `== .canvas`
    /// equality the compiler could not check, each with its own visible failure
    /// (the region inspector unreachable from Plan's tree, a Collection's
    /// reference placeholder taking the centre from the canvas, a `⌘\` collapse
    /// never handing the sidebar back). A fourth was found later by grepping
    /// for the comparison rather than reading the list.
    ///
    /// Exhaustive with no `default:`, so a fifth persona has to say whether its
    /// centre is the board rather than inheriting "no".
    var centresTheCanvas: Bool {
        switch self {
        case .plan: return true
        case .author, .review, .publish: return false
        }
    }

    /// **The one spelling of "the centre column is the compiled book"**
    /// (shell-finish stage 3b Task 5, spec §4's Publish column).
    ///
    /// `centresTheCanvas`'s sibling and written for its reason: the alternative
    /// is a `== .publish` at every gate that needs the question — the centre
    /// column's own layer, the status footer's refusal, and the refresh that
    /// re-asks on arrival — and the compiler cannot check that three equalities
    /// spread over two files still mean the same thing. The canvas's version of
    /// exactly this cost three sites a visible defect apiece before it was
    /// named.
    ///
    /// **It is deliberately NOT derived from `centresTheCanvas`'s complement or
    /// from `showsManuscriptDocuments`.** Publish's centre holds a manuscript
    /// document whenever nothing has been compiled — that is stage 3a's degrade
    /// and it still stands — so this is a third, independent fact about the
    /// centre column rather than a partition of the other two.
    ///
    /// **The Exports footer stays the sole place the persona is named** (`persona
    /// != .plan` in `ProjectWindow`): it is a control about exporting rather
    /// than a rule about what the centre column draws, and every tree looks the
    /// same, so what is left to gate on is what the writer is doing.
    ///
    /// Exhaustive with no `default:`, so a fifth persona has to say whether its
    /// centre is the book rather than inheriting "no".
    var previewsThePublishedBook: Bool {
        switch self {
        case .publish: return true
        case .plan, .author, .review: return false
        }
    }

    /// **The one spelling of "this persona's centre column edits research and
    /// palette cards."** False only for `.review` (shell-finish stage 3b Task
    /// 6, Denver's ruling): *Review adjudicates; it doesn't edit research or
    /// palette cards from its own columns.* Read by `ResearchSubjectCentre`'s
    /// mount (`ProjectWindow.editorPane`) and by `PaletteWallCentre`'s card arm
    /// — the same value at both sites, so a reviewer can't reach a mutable
    /// note through one door and a locked one through the other.
    ///
    /// The alternative is `== .review` at each of those two sites, which is
    /// exactly the shape `centresTheCanvas` and `previewsThePublishedBook` were
    /// each written to close off — a hardcoded equality ships the defect the
    /// moment a fifth persona needs an answer, silently, because the compiler
    /// has nothing to ask.
    ///
    /// **Publish answers `true` despite never being asked**: its centre is the
    /// compiled book (`previewsThePublishedBook`), so `researchSubjectPlacement`
    /// routes a Publish research subject to `.nothingMoves` before this
    /// predicate is ever read there — Task 5's rule, unchanged. `true` is the
    /// honest answer to the literal question ("if Publish's centre showed a
    /// note, would it be editable") rather than a value chosen to make an
    /// unreachable case look intentional.
    ///
    /// Exhaustive with no `default:`, so a fifth persona has to say whether its
    /// centre edits research rather than inheriting "yes".
    var editsResearchInTheCentre: Bool {
        switch self {
        case .review: return false
        case .plan, .author, .publish: return true
        }
    }
}
