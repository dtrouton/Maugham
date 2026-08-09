import XCTest
import MaughamCore
@testable import Maugham

/// **`.tree` shows a different pane in each of three shells, and which one is
/// derived exactly once.**
///
/// "The tree" is `BinderView` for a novel or a short story, `SceneNavigatorPane`
/// for a screenplay (one `.fountain`, sluglines under a script row) and
/// `CollectionPiecesPane` for a Collection. Deriving that inline inside a binder
/// toggle is the re-derivation that shipped the 2026-07-02 bug — a writer forced
/// onto `.manuscript` in a screenplay landed in a one-row `BinderView` — and
/// slice 1's whole-branch review found the same three-shell mistake again in the
/// project row, which the spec's §3.3 amendment records.
///
/// **Asked over `ProjectType.allCases`, never a hand-written list.**
/// `CanvasPersonaTests`' header says why: those loops read
/// `[.novel, .screenplay, .collection]` until 2026-07-28 and `.shortStory` was
/// never asked.
final class BinderSegmentTreePaneTests: XCTestCase {

    func test_everyProjectTypeGetsItsOwnTree() {
        XCTAssertEqual(BinderSegment.treePane(for: .novel), .binder)
        XCTAssertEqual(BinderSegment.treePane(for: .shortStory), .binder)
        XCTAssertEqual(BinderSegment.treePane(for: .screenplay), .sceneNavigator)
        XCTAssertEqual(BinderSegment.treePane(for: .collection), .collectionPieces)
    }

    /// `.unknown` is excluded from `allCases` and can still reach a window: a
    /// same-schema manifest carrying an unexpected `type` decodes to it (ADR
    /// 0015). It must get a tree rather than a blank column.
    func test_anUnknownProjectTypeStillGetsATree() {
        XCTAssertEqual(BinderSegment.treePane(for: .unknown), .binder)
    }

    func test_everyProjectTypeIsAnswered() {
        for type in ProjectType.allCases {
            XCTAssertTrue(BinderSegment.TreePane.allCases
                .contains(BinderSegment.treePane(for: type)), "\(type)")
        }
    }

    /// **The contract that keeps the two derivations from drifting.**
    ///
    /// `treePane(for:)` and `documentHome(for:)` answer the same question about
    /// the same three shells, and neither can be written in terms of the other
    /// without a `default:` (the home's return type is the whole segment enum,
    /// the tree's is not). So they are held together here instead: a project
    /// type whose document home is `.scenes` shows the scene navigator, and one
    /// whose home is `.manuscript` shows a document tree of some kind.
    ///
    /// A new `ProjectType` that answers one of the two and forgets the other
    /// fails here rather than in the hand.
    func test_theTreePaneAndTheDocumentHomeAgreeOnEveryProjectType() {
        for type in ProjectType.allCases + [.unknown] {
            let home = BinderSegment.documentHome(for: type)
            XCTAssertEqual(BinderSegment.treePane(for: type) == .sceneNavigator,
                           home == .scenes,
                           "\(type): the scene navigator is the tree exactly "
                           + "where `.scenes` is the document home")
        }
    }

    // MARK: - The segment itself

    func test_theTreeIsNotTransient() {
        XCTAssertFalse(BinderSegment.tree.isTransient,
                       "`.trash` and `.find` are the transient pair — a persona "
                       + "surface carried across a persona switch by "
                       + "`applyPersonaChange`'s whitelist would strand a writer "
                       + "on Plan's tree in Author, where the canvas would then "
                       + "take the editor's column")
    }

    /// **The picker is icon-only** (`BinderSegment.pickerSymbolName` records why
    /// text was measured and rejected), so a duplicate symbol is two segments
    /// the writer cannot tell apart — the 2026-07-25 palette-unreachable shape.
    func test_theTreeHasItsOwnSymbolAndItsOwnName() {
        XCTAssertFalse(BinderSegment.tree.pickerSymbolName.isEmpty)
        let symbols = BinderSegment.allCases.map(\.pickerSymbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        for type in ProjectType.allCases {
            XCTAssertEqual(BinderSegment.tree.displayName(for: type), "Structure",
                           "\(type)")
        }
    }

    /// **The tooltip is the only text the picker carries, so no two segments the
    /// picker can render together may share one.**
    ///
    /// This is why `.tree` is not named after the segment whose pane it borrows.
    /// `visibleSegments` APPENDS the current selection, so a screenplay reopened
    /// in Plan on a restored `.scenes` renders Plan's four plus `.scenes` — and
    /// a `.tree` labelled "Scenes" would be a second segment with the same word
    /// under a different glyph.
    func test_noTwoSegmentsThePickerCanShowTogetherShareAName() {
        for type in ProjectType.allCases {
            for selected in BinderSegment.allCases {
                let rendered = BinderSegmentPicker.visibleSegments(
                    persona: .plan, projectType: type,
                    hasTrash: true, including: selected)
                let names = rendered.map { $0.displayName(for: type) }
                XCTAssertEqual(Set(names).count, names.count,
                               "\(type) with \(selected) selected renders "
                               + "\(names) — two segments cannot share the only "
                               + "text this picker has")
            }
        }
    }

    /// A restored `"tree"` survives the round trip, and an older build drops it
    /// and falls back rather than losing the whole memory (no migration —
    /// tripwire 11).
    func test_theTreeSurvivesAUIStateRoundTrip() throws {
        var state = UIState.empty
        state.binderSegment = .tree
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(UIState.self, from: data).binderSegment,
                       .tree)
    }

    func test_theTreeIsRememberedPerPersona() {
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, binderSegment: .tree, detailSegment: .intent)
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel), .tree,
                       "⌘2 then ⌘1 must put the writer back on the tree they left")
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .novel),
                       .manuscript,
                       "and Author, which does not offer it, falls back to its "
                       + "own home rather than inheriting Plan's")
    }
}
