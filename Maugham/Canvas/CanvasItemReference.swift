import Foundation

/// What an item node points at.
///
/// **Two provenances, and they are different kinds of claim rather than two
/// spellings of one id** (spec §3.1's 2026-07-30 amendment). A *referenced*
/// item already exists somewhere in the project and the canvas holds only its
/// position; an *owned* one is a file the canvas itself ingested, which exists
/// nowhere else in the project and would dangle if it did — `.maugham/inbox/`
/// is a queue the writer clears, so a node pointing into one is a card that
/// disappears the day they tidy up.
///
/// **Nested inside `CanvasNodeKind.item` rather than added beside it as a third
/// top-level case**, deliberately. Roughly fifteen sites test `case .scrap` and
/// want both provenances to behave identically — the resize refusal, the
/// promoted-stripe refusal, the tint refusal, the placeholder heal — and a third
/// top-level case would leave every one of those guards *looking* right while
/// silently changing what `Promotion.blockedReason`'s `if case .item` refuses.
/// Nested, the sites that genuinely differ are the ones that destructure, and
/// the compiler names every one of them.
///
/// Neither case carries the *identity* of the node: an item node's id is
/// `CanvasNodeID.item(_:)` for a project reference (so two adds of one research
/// item resolve to one node) and a minted id for an owned one (there is nothing
/// to deduplicate, and a filesystem path does not belong in an identity).
public enum CanvasItemReference: Equatable, Hashable, Sendable {
    /// A research item / palette card id. **The canvas never writes to it.**
    case project(id: String)

    /// A file under `canvas_assets/` that the canvas ingested and owns.
    ///
    /// **PROJECT-RELATIVE**, e.g. `"canvas_assets/photo-20260730-121314.png"` —
    /// never absolute, never a `file://` URL and never a Markdown image ref. Any
    /// of the three renders nothing, keys the thumbnail cache on a string that
    /// differs between Macs, and breaks the moment the project is moved or
    /// synced.
    case owned(path: String)
}
