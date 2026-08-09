import Foundation
import MaughamCore

/// **Which manuscript tree the window's left column mounts.**
///
/// "The tree" is three views, not one — the correction the persona shell's
/// slice-1 whole-branch review made about the project row, and the one thing
/// that survived `BinderSegment` when the strip died (shell-finish stage 2b
/// Task 7). `BinderView` is right for a novel or a short story; a screenplay's
/// tree is `SceneNavigatorPane` (one `.fountain`, sluglines beneath a script
/// row) and a Collection's is `CollectionPiecesPane`.
///
/// **It is a type of its own rather than an inline `type == .screenplay` in the
/// binder toggles**, because deriving it inside a toggle is the re-derivation
/// that shipped the 2026-07-02 navigate bug — and there are two toggles, so a
/// second spelling is a second answer waiting to differ. `ScreenplayScriptSource`
/// is the third reader.
///
/// It used to live on `BinderSegment` beside `documentHome(for:)`, which
/// answered the same question about the same three shells. `documentHome` died
/// with the strip: with one left column per persona there is no longer a segment
/// for a navigation to land on, so the only surviving half of that pair is which
/// tree to draw.
enum TreePane: String, Equatable, Sendable, CaseIterable {
    /// `BinderView` — novel, short story, and the fallback for `.unknown`.
    case binder
    /// `SceneNavigatorPane` — a screenplay's sluglines under its script row.
    case sceneNavigator
    /// `CollectionPiecesPane`.
    case collectionPieces

    /// Exhaustive with no `default:` on purpose — a new `ProjectType` must
    /// answer here rather than inheriting a tree that is wrong for it.
    init(for projectType: ProjectType) {
        switch projectType {
        case .screenplay: self = .sceneNavigator
        case .collection: self = .collectionPieces
        case .novel, .shortStory, .unknown: self = .binder
        }
    }
}
