import XCTest
import MaughamCore
@testable import Maugham

/// **The left column is a different tree in each of three shells, and which one
/// is derived exactly once.**
///
/// "The tree" is `BinderView` for a novel or a short story, `SceneNavigatorPane`
/// for a screenplay (one `.fountain`, sluglines under a script row) and
/// `CollectionPiecesPane` for a Collection. Deriving that inline inside a binder
/// toggle is the re-derivation that shipped the 2026-07-02 bug — a writer forced
/// onto `.manuscript` in a screenplay landed in a one-row `BinderView` — and
/// slice 1's whole-branch review found the same three-shell mistake again in the
/// project row, which the spec's §3.3 amendment records. There are two toggles,
/// so a second spelling is a second answer waiting to differ.
///
/// **Asked over `ProjectType.allCases`, never a hand-written list.** Those loops
/// read `[.novel, .screenplay, .collection]` until 2026-07-28 and `.shortStory`
/// was never asked; a case added to `ProjectType` has to arrive here on its own.
///
/// This is `BinderSegmentTreePaneTests` minus everything that was about the
/// strip: the segment's transience, its picker symbol, its tooltip uniqueness,
/// its `UIState` round trip, its per-persona memory and its agreement with
/// `documentHome(for:)` all died with `BinderSegment` in shell-finish stage 2b
/// Task 7. What is left is the one question that outlived it.
final class TreePaneTests: XCTestCase {

    func test_everyProjectTypeGetsItsOwnTree() {
        XCTAssertEqual(TreePane(for: .novel), .binder)
        XCTAssertEqual(TreePane(for: .shortStory), .binder)
        XCTAssertEqual(TreePane(for: .screenplay), .sceneNavigator)
        XCTAssertEqual(TreePane(for: .collection), .collectionPieces)
    }

    /// `.unknown` is excluded from `allCases` and can still reach a window: a
    /// same-schema manifest carrying an unexpected `type` decodes to it (ADR
    /// 0015). It must get a tree rather than a blank column.
    func test_anUnknownProjectTypeStillGetsATree() {
        XCTAssertEqual(TreePane(for: .unknown), .binder)
    }

    func test_everyProjectTypeIsAnswered() {
        for type in ProjectType.allCases {
            XCTAssertTrue(TreePane.allCases.contains(TreePane(for: type)), "\(type)")
        }
    }

    /// **The screenplay row, positively, because it is the one the bug was
    /// about.** A project type that answers `.binder` where it should answer
    /// `.sceneNavigator` is a one-row novel binder over a script with ninety
    /// scenes — and the loop above would still pass, since `.binder` is a member
    /// of `allCases` like any other.
    func test_onlyAScreenplayGetsTheSluglineNavigator() {
        for type in ProjectType.allCases + [.unknown] {
            XCTAssertEqual(TreePane(for: type) == .sceneNavigator,
                           type == .screenplay,
                           "\(type): the slugline navigator is the tree exactly "
                           + "where the project is one `.fountain`")
        }
    }
}
