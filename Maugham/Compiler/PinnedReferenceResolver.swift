import Foundation
import MaughamCore

/// **The five inputs `PinnedReferences.pinned` takes, resolved against a live
/// project — in one place, because getting them right is the hard part.**
///
/// `PinnedReferences` itself reaches for nothing: the scene arrives as a value,
/// the manifest as a `CanvasItemIndex`, the scrap words as a dictionary. That is
/// what makes it testable with no project on disk, and it is not weakened here —
/// this type is the *caller-side* assembly, and the pure function is unchanged.
///
/// Four of the five are easy to get subtly wrong, and one of them already was:
///
/// - **`linkedResearchIds`, never `StructureItem.links`.** The plan for this
///   milestone named the wrong field, and the two share no reader or writer
///   despite the near-identical name — `.links` is `InspectorLinksSection`'s
///   document-to-document backlink feature. A second assembly is a second
///   chance to make that substitution, and it would render a plausible, wrong
///   shelf with nothing red.
/// - **`CanvasClaudeWrite.readScene`, never `CanvasStore.load` directly.** It is
///   the attached-or-sidecar discriminator `list_canvas` reads through: with the
///   canvas open, the live model is ahead of the sidecar by every keystroke the
///   mounted scrap editor has folded in.
/// - **`derivedResearchItems` beside `linkedResearchIds`, never instead of
///   it.** They answer for different project types and neither is a superset:
///   links are a Novel chapter's record, derivation is a Collection piece's and
///   a single-document project's, and `derivedResearchItems` answers `[]` for a
///   Novel. A shelf assembled from one of them is complete for some project
///   types and silently empty for the rest (the design's §2.1).
/// - **A `CanvasItemIndex` over the WHOLE research tree**, which is what tells a
///   palette card from a research note — by POSITION, since nothing on the item
///   says so.
///
/// Its three readers — the References pane, the assistant column, and the
/// compiler's context listing — must not disagree about what this piece is
/// pinned to, because the writer reads the first two and Claude is briefed on
/// the third. `ReferencesPaneTests.test_thePinnedProjectionIsAssembledInExactlyOneProductionFile`
/// is the census that keeps them one.
enum PinnedReferenceResolver {

    @MainActor
    static func pins(forDocId docId: String,
                     store: ProjectStore,
                     projectRoot: URL) -> PinnedShelf {
        let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectRoot)
        return PinnedReferences.pinned(
            forDocId: docId,
            links: store.linkedResearchIds(forDocumentId: docId),
            derived: store.derivedResearchItems(forDocumentId: docId).map(\.id),
            scene: read.scene,
            scraps: read.scraps,
            items: CanvasItemIndex.over(research: store.manifest.research))
    }
}
