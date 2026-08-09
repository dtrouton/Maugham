import Foundation
import MaughamCore

/// Which top-level segment is active in the binder pane.
public enum BinderSegment: String, Codable, Equatable, Sendable, CaseIterable {
    case manuscript
    /// The manuscript tree with the planning canvas still in the centre — Plan's
    /// structure segment (persona shell spec §3.1).
    ///
    /// **A case of its own rather than a reuse of the manuscript home**, because
    /// the reuse would make one enum case mean "the editor" in Author and "the
    /// canvas" in Plan. That is the context-dependent meaning `SynthesisSource`
    /// (tripwire 12), `MaughamSidecarPath` and `DeviceSlug` (tripwire 24) were
    /// each introduced to remove — and it would leave five routing sites needing
    /// persona-awareness with no compiler help, where a new case is FORCED into
    /// every exhaustive switch below.
    ///
    /// `.tree` and `.canvas` differ only in the LEFT pane: the tree shows the
    /// project's manuscript (`treePane(for:)`), the canvas segment shows the
    /// research tree that §8A.1's drag-in route needs beside it. Both centre the
    /// canvas, which since stage 2b Task 6 is a fact about the PERSONA rather
    /// than about either of them — see `Persona.centresTheCanvas`.
    case tree
    case research
    case palette
    case scenes
    /// The Plan persona's centre column — the freeform planning canvas (M1C).
    /// One canvas per project (spec §2); regions do all the dividing.
    case canvas
    case trash
    case find

    /// The segment where a project's manuscript content lives — where
    /// "navigate to this document" should land. Screenplay binders have NO
    /// Manuscript segment (the picker offers Scenes/Research only; the Scenes
    /// segment IS the slugline navigator within the single `.fountain`), so
    /// forcing `.manuscript` on a screenplay drops it into the one-row novel
    /// BinderView (2026-07-02 smoke finding via the stats-window navigate
    /// path). Every receiver that resets or targets the content segment must
    /// route through here rather than re-deriving the type check.
    public static func documentHome(for projectType: ProjectType) -> BinderSegment {
        projectType == .screenplay ? .scenes : .manuscript
    }

    /// Which manuscript tree the `.tree` segment shows.
    ///
    /// **"The tree" is three views, not one** — the same correction the slice-1
    /// whole-branch review made about the project row, one segment over.
    /// `BinderView` is right for a novel or a short story; a screenplay's tree is
    /// `SceneNavigatorPane` (one `.fountain`, sluglines beneath a script row) and
    /// a Collection's is `CollectionPiecesPane`. Deriving that inline inside a
    /// binder toggle is the re-derivation that shipped the 2026-07-02 bug, so it
    /// lives here beside `documentHome(for:)`, which answers the same question
    /// about the same three shells.
    ///
    /// **It is NOT expressed in terms of `documentHome(for:)`**, because doing so
    /// needs a `default:` (that function's return type is the whole segment enum)
    /// and a `default:` is what lets a new project type ship silently wrong. The
    /// two are held together by a contract test instead —
    /// `BinderSegmentTreePaneTests.test_theTreePaneAndTheDocumentHomeAgreeOnEveryProjectType`
    /// — which is the shape this codebase uses when one derivation must track
    /// another without either being able to see the other's exhaustiveness.
    public enum TreePane: String, Equatable, Sendable, CaseIterable {
        /// `BinderView` — novel, short story, and the fallback for `.unknown`.
        case binder
        /// `SceneNavigatorPane` — a screenplay's sluglines under its script row.
        case sceneNavigator
        /// `CollectionPiecesPane`.
        case collectionPieces
    }

    public static func treePane(for projectType: ProjectType) -> TreePane {
        // Exhaustive with no `default:` on purpose — a new `ProjectType` must
        // answer here rather than inheriting a tree that is wrong for it.
        switch projectType {
        case .screenplay: return .sceneNavigator
        case .collection: return .collectionPieces
        case .novel, .shortStory, .unknown: return .binder
        }
    }

    /// **INTERIM — this predicate and every caller of it die in Task 7.**
    ///
    /// **Which segments Plan still offers whose centre column is something
    /// OTHER than the board.** It is the subtraction in
    /// `Persona.centresTheCanvas(interimSegment:)`, and it exists because the
    /// persona is nearly, but not yet, the whole answer to *"is the centre the
    /// canvas"*: Plan's picker still carries Research and Palette, and both put
    /// an old pane in the middle of the window
    /// (`ProjectWindow.existingEditorSwitch`). `.trash` is on the list for the
    /// same reason — its centre is a `ContentUnavailableView` — even though
    /// nothing has selected it since Task 2 made the trash a foot disclosure.
    ///
    /// **`.find` is deliberately absent and it is the interesting row.** Find is
    /// an overlay of the LEFT column since Task 1; it leaves the centre alone,
    /// so whatever was in the middle is still there. Adding it here would make
    /// the composite say the writer stopped looking at their document because a
    /// search panel opened beside it — Denver's 2026-08-02 footer ruling, in the
    /// one predicate that would quietly undo it.
    ///
    /// Exhaustive with no `default:`: while the enum stands, a new segment must
    /// say what its centre column is rather than inheriting "the board".
    var interimTakesTheCentreFromTheCanvas: Bool {
        switch self {
        case .research, .palette, .trash: return true
        case .manuscript, .tree, .scenes, .canvas, .find: return false
        }
    }

    /// **INTERIM — this predicate and every caller of it die in Task 7.**
    ///
    /// **Is this segment's left pane the project's tree?** Three views are the
    /// tree — `BinderView`, `SceneNavigatorPane` and `CollectionPiecesPane`
    /// (`treePane(for:)`) — and `.manuscript`, `.tree` and `.scenes` are what
    /// mount them. Everything else in the left column is an old pane or no pane:
    /// `ResearchView`, `PaletteBinderList`, `TrashView`, `ProjectSearchView`.
    ///
    /// **The question it answers is "can the writer point the window somewhere
    /// else again", and it stops being a question in Task 7**, when the tree
    /// becomes the whole left column in every persona. It was
    /// `leftPaneWritesTheSubject`, and the defect it exists to stop is a TRAP
    /// rather than a mis-route: a research subject took `.canvas`'s right column
    /// and `.trash`'s centre while their left panes offered nothing that could
    /// write the subject back, the subject persists through `UIState`, and
    /// Plan's `binderHome` IS `.canvas` — so relaunching reopened into the same
    /// trap. The three tree views are exactly the three that write
    /// `selectedSubject`, which is why one predicate answers both halves.
    ///
    /// **After Task 7 the answer is unconditionally yes, and the surviving form
    /// of the question is about the find OVERLAY** — with the panel over the
    /// column there is no row to click. That is not a trap: Escape puts the tree
    /// back and `treeFindActive` is `@State` that no relaunch restores.
    /// `ProjectSubjectReachabilityTests` asserts the way out rather than
    /// assuming it.
    ///
    /// **It is NOT the question `ScreenplayScriptSource` asks**, though the two
    /// are neighbours and an earlier draft of Task 6 conflated them. That one
    /// needs *"is the left pane the slugline navigator"*, and `.manuscript`
    /// mounts `BinderView` unconditionally — a one-row novel binder on a
    /// screenplay, never sluglines. See `needsDerivation`, which spells its own
    /// interim term and says why.
    ///
    /// Exhaustive with no `default:` while the enum stands.
    var interimLeftPaneIsTheTree: Bool {
        switch self {
        case .manuscript, .tree, .scenes: return true
        case .research, .palette, .canvas, .trash, .find: return false
        }
    }

    /// Runtime-gated, persona-independent segments that survive a persona
    /// switch: a writer mid-search or looking at the trash must not be
    /// ejected by switching persona. This is the single source both
    /// `PersonaModifier.applyPersonaChange`'s `keepBinder` whitelist and
    /// `BinderSegmentPicker.visibleSegments`'s append draw from, so the two
    /// cannot disagree — a future runtime-gated segment added to one and not
    /// the other would silently eject a writer from it on persona switch.
    ///
    /// **`.find` is a dead member since stage 2b Task 1** and goes with the case
    /// in the kill task: find is an overlay of the whole left column now, not a
    /// segment, so no picker offers it and no persona switch can reach it. Its
    /// survive-a-persona-switch property survived the move —
    /// `TreeFindOverlayTests.test_theOverlaySurvivesAPersonaSwitch` — but it is
    /// window state that carries it, not this predicate. `.trash` is the live
    /// member.
    public var isTransient: Bool {
        switch self {
        case .trash, .find: return true
        case .manuscript, .tree, .research, .palette, .scenes, .canvas: return false
        }
    }
}

// MARK: - Picker labelling

public extension BinderSegment {
    /// A collection's manuscript segment is labelled "Pieces"; every other
    /// project type calls it "Manuscript". Lives beside the case so the two
    /// binder toggles cannot label the same segment differently.
    func displayName(for projectType: ProjectType) -> String {
        switch self {
        case .manuscript: return projectType == .collection ? "Pieces" : "Manuscript"
        // **"Structure", not the document home's own name.** The obvious
        // alternative — borrowing `documentHome(for:).displayName(for:)`, so the
        // tree reads "Manuscript"/"Pieces"/"Scenes" like the segment it shows —
        // collides in the one case that matters: `visibleSegments` APPENDS the
        // current selection, so a screenplay reopened in Plan on a restored
        // `.scenes` renders two segments both tooltipped "Scenes" in a picker
        // that has no other text (`pickerSymbolName` explains why). §3.1.1 asks
        // the labels to carry the distinction between segments whose left panes
        // look alike; a name that can duplicate another's is the opposite of
        // that. "Structure" is also what the segment is FOR (§3.1.1: "shaping
        // the structure") and what the app already calls the manuscript tree —
        // `manifest.structure`, `addStructureItem`, `structure-and-binder.md`.
        case .tree: return "Structure"
        case .research: return "Research"
        case .palette: return "Palette"
        case .scenes: return "Scenes"
        case .canvas: return "Canvas"
        case .trash: return "Trash"
        case .find: return "Find"
        }
    }

    /// SF Symbol the binder picker renders for this segment. EVERY segment has
    /// one, and the picker renders nothing else — `displayName(for:)` survives
    /// as the tooltip and the accessibility label.
    ///
    /// It used to be `String?`, icon for Palette and text for the rest, which
    /// made the picker's `ForEach` emit two different child types behind an
    /// `if let`. That is a `_ConditionalContent` whose branch is cached per
    /// POSITION, and a segmented `Picker` updates its `NSSegmentedControl` in
    /// place: as soon as a persona change reshaped the list, the stale branch
    /// stayed on the old index and the picker rendered `Pieces | 🎨Research |
    /// 🎨` — a palette icon glued to Research, and, in a persona with no
    /// Palette segment at all, a palette icon on a segment that selects
    /// Research. That is 2026-07-25 smoke defect C, and why the writer could
    /// not reach the palette wall. Reproduced by driving the list through a
    /// persona switch offscreen; the uniform-`Image` picker is stable through
    /// the same sequence.
    ///
    /// Text for every segment was measured and rejected: the segmented control
    /// will not compress below its ideal width, and `Manuscript | Research |
    /// Palette` alone measures 264pt against a 240pt ideal column (352pt with
    /// Trash, 440pt with Find), so it truncates from the leading edge. The
    /// icon set measures 87–145pt and always fits — and it matches the right
    /// pane's picker, which has been icon-only since ADR 0005.
    var pickerSymbolName: String {
        switch self {
        case .manuscript: return "doc.text"
        // An indented list — the tree's own shape, and legible next to
        // `.canvas`'s `square.on.circle` and `.manuscript`'s single sheet, which
        // is the distinction §3.1.1 asks the picker to carry.
        case .tree: return "list.bullet.indent"
        case .research: return "books.vertical"
        case .palette: return "paintpalette"
        case .scenes: return "film"
        case .canvas: return "square.on.circle"
        case .trash: return "trash"
        case .find: return "magnifyingglass"
        }
    }
}
