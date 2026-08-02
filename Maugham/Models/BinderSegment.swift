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
    /// canvas — see `centresTheCanvas`, which is the one place that is spelled.
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

    /// **The one spelling of "the centre column is the planning canvas".**
    ///
    /// Two segments draw it: `.canvas`, whose left pane is the research tree the
    /// drag-in route needs, and `.tree`, whose left pane is the manuscript. Three
    /// separate sites spelled this as `binderSegment == .canvas` and the compiler
    /// caught none of them, each with its own visible failure — the region
    /// inspector unreachable from Plan's tree (the exact 2026-07-28 smoke
    /// defect), a Collection's reference placeholder taking the centre column
    /// from the canvas, and a `⌘\` collapse never handing the sidebar back.
    ///
    /// Exhaustive with no `default:`, so a future segment has to say whether it
    /// centres the canvas rather than inheriting "no".
    var centresTheCanvas: Bool {
        switch self {
        case .canvas, .tree: return true
        case .manuscript, .research, .palette, .scenes, .trash, .find: return false
        }
    }

    /// **Does this segment's left pane list a screenplay's sluglines?**
    ///
    /// Two segments mount `SceneNavigatorPane`: `.scenes`, a screenplay's
    /// document home, and `.tree`, Plan's structure segment, whose tree for a
    /// screenplay is the same navigator (`treePane(for:)`). Both need a parsed
    /// `FountainScript` to draw anything at all, which is why the question is
    /// worth a name — `ScreenplayScriptSource` asks it to decide whether the
    /// window has to derive that parse itself.
    ///
    /// **`.tree`'s answer is delegated to `treePane(for:)` rather than spelled
    /// as `projectType == .screenplay`** — that inline re-derivation is the one
    /// `BinderPaneToggle`'s `.tree` arm names as the 2026-07-02 bug, and a
    /// second copy here would be a third place the same routing lives.
    /// Exhaustive with no `default:` for `centresTheCanvas`'s reason.
    func showsSceneNavigator(for projectType: ProjectType) -> Bool {
        switch self {
        case .scenes: return true
        case .tree: return Self.treePane(for: projectType) == .sceneNavigator
        case .manuscript, .research, .palette, .canvas, .trash, .find: return false
        }
    }

    /// **Does the manuscript status footer belong under this segment?**
    ///
    /// `EditorStatusFooter` reports the writer's goal capsule, their live
    /// session words, the paragraph id under the cursor and the current element
    /// — all facts about a manuscript document — so it is silent on the canvas,
    /// on Plan's tree, on research, on the palette and on the trash.
    ///
    /// **It is NOT `centresTheCanvas` inverted.** It is close to *"the centre
    /// column is a document"* — `existingEditorSwitch` and
    /// `existingInspectorSwitch` both name `.manuscript, .scenes, .find` in one
    /// arm — but it is not spelled as that, and the reason is `.trash`: the
    /// trash has no centre column of its own to disagree about, so a predicate
    /// shared with those switches would have to answer for a segment they never
    /// see.
    ///
    /// **`.find` says YES, and that is a fix rather than the inherited value.**
    /// It said no until 2026-08-02, when slice 2's task 9 surfaced the
    /// disagreement and Denver ruled it an oversight from before find had a
    /// centre column: running `⌘⌥F` put the writer's document in the editor and
    /// silently took away the goal capsule, the live session words and the
    /// `¶id`/element readout, none of which stop being true because a search
    /// panel is open on the left. The footer follows the DOCUMENT in the centre,
    /// not the shape of the left column.
    ///
    /// **Nor is it `BinderPaneToggle`'s Exports gate**, which reads the same set
    /// today and asks a different question — that one is about the LEFT column
    /// (is the pane below the picker the manuscript tree?) and is derived from
    /// `documentHome(for:)` rather than switched, because "not the Exports list"
    /// is the right default for a segment that has not been thought about and
    /// "not the status footer" is not.
    ///
    /// **Exhaustive with no `default:`** for `centresTheCanvas`'s reason: this
    /// answered "no" for `.canvas` and again for `.tree` by inheriting a
    /// hand-spelled `== .manuscript || == .scenes`, and both times it was right
    /// by luck. M3's *"Pieces by review state"* left-hand surface is the near
    /// case that would centre the editor and want the footer, and nothing but
    /// the compiler would ask.
    var showsManuscriptStatusFooter: Bool {
        switch self {
        case .manuscript, .scenes, .find: return true
        case .tree, .research, .palette, .canvas, .trash: return false
        }
    }

    /// Runtime-gated, persona-independent segments that survive a persona
    /// switch: a writer mid-search or looking at the trash must not be
    /// ejected by switching persona. This is the single source both
    /// `PersonaModifier.applyPersonaChange`'s `keepBinder` whitelist and
    /// `BinderSegmentPicker.visibleSegments`'s append draw from, so the two
    /// cannot disagree — a future runtime-gated segment added to one and not
    /// the other would silently eject a writer from it on persona switch.
    /// Today only `.trash` and `.find` qualify; nothing else does.
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
