import Foundation

/// What a canvas whose layout file this build refused still offers (issue #44).
///
/// **Read-only, not frozen.** The model holds the refusal (`CanvasModel.isReadOnly`)
/// and its own verbs already change nothing; this is the SURFACE half — every
/// gesture, key, drop and inspector control that would start an edit asks here
/// first, so the writer is not offered an edit that would silently come to
/// nothing. Pan, zoom, single-click selection and every displayed value keep
/// working: a writer looking at a refused canvas can still find their words and
/// read what the inspector says about them.
///
/// **Pure and static on purpose**, so each decision is pinned by a test that
/// hosts no window (tripwire 33) and the view calls the very same function —
/// `CanvasEditGateTests` censuses that the calls are there.
///
/// **Not `Posture`** (tripwire 51). The permit decides what a person may write;
/// this is a file this build cannot read, the same kind of fact as
/// `ProjectWindow.shareIsReadOnly` — a lock beside the posture, never a role.
enum CanvasEditGate {

    /// The click count `CanvasClickHandler.handleClick` acts on. On a read-only canvas a
    /// double click is a single click: it selects, and it makes no scrap, enters
    /// none and mounts no editor (tripwire 27's editor never mounts for editing).
    static func clickCount(_ clickCount: Int, isReadOnly: Bool) -> Int {
        isReadOnly ? min(clickCount, 1) : clickCount
    }

    /// Whether a press may begin a drag interaction — a card or region move or
    /// resize, a sweep, a line. Every `CanvasInteraction.Kind` mutates the scene
    /// frame by frame through `withScene(persist: false)`, which the model does
    /// not guard (it carries the re-measures), so the refusal has to happen here
    /// or a card visibly moves and reverts on the next open. With no interaction
    /// begun, `.changed`/`.ended` bail and no coast is ever launched.
    static func dragBegins(isReadOnly: Bool) -> Bool { !isReadOnly }

    /// Whether ⌫/⌦ may delete the selection. `false` sends the key on to `super`,
    /// so it beeps — "that key means nothing here".
    static func deletes(isReadOnly: Bool) -> Bool { !isReadOnly }

    /// The three drops onto the canvas that ADD something. (The fourth, a
    /// research row already on the canvas, only selects its card and brings it
    /// into view — it changes nothing, so it is not asked here at all.)
    enum Drop: CaseIterable {
        /// A research row not on the canvas yet: a new card.
        case place
        /// An Inbox capture.
        case capture
        /// A Finder file or a browser bitmap. Refused BEFORE ingestion, or a
        /// refused drop strands a copy in `canvas_assets/`.
        case external
    }

    /// Whether the canvas accepts `drop`. `false` springs the drag back; the
    /// canvas's notice says why.
    static func accepts(_ drop: Drop, isReadOnly: Bool) -> Bool {
        switch drop {
        case .place, .capture, .external: return !isReadOnly
        }
    }

    /// Whether an inspector shows its VERBS — Delete, Cite a Card, Remove from
    /// this region, Promote…. Hidden rather than disabled: there is nothing the
    /// writer can do to make them work from here.
    static func offersVerbs(isReadOnly: Bool) -> Bool { !isReadOnly }

    /// Whether an inspector's VALUE fields — a name, Collapsed, a Piece picker —
    /// take input. Shown disabled rather than hidden, because what they say is
    /// still true and still worth reading.
    static func editsValues(isReadOnly: Bool) -> Bool { !isReadOnly }
}
