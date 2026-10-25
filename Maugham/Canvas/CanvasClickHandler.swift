import SwiftUI

/// `CanvasView`'s clicks: a single click leaves whatever was open and selects;
/// a double click enters the scrap under the pointer or makes one on bare
/// canvas — over bindings to the view's own `@State`. It writes
/// `selectionWhenPressed` first, which the drag handler reads at `.began`.
/// Making and entering a scrap is `CanvasScrapFlow`'s; this handler resolves
/// what was clicked and the caret, and hands over.
///
/// Built fresh per call by `CanvasView.clickHandler` and never stored; built
/// nowhere else (tripwire 32's surface census). It holds the `scrapFlow` and
/// `regionTitleEditing` it was handed, so this file schedules no work. A
/// double click on a region's title opens it for naming, and every click
/// first commits an open title.
@MainActor
struct CanvasClickHandler {
    let model: CanvasModel
    let editFocus: CanvasEditFocus
    let scrapFlow: CanvasScrapFlow
    let regionTitleEditing: CanvasRegionTitleEditing
    @Binding var selectionWhenPressed: CanvasSelection?
    @Binding var straighten: CanvasFocusStraighten
    @Binding var layouts: [CanvasNodeID: ScrapLayout]
    @Binding var revision: Int

    // MARK: - Clicks

    /// What a double click landed on. Three cases, resolved from ONE hit test.
    ///
    /// `CanvasScene.topmostNode(at:)` filters the whole scene, so asking twice in
    /// one click is an avoidable `O(scene)` pass; and asking it in a `guard` with
    /// the other conditions is how the fall-through below went missing in the
    /// first draft. Making the third case a NAMED case is what stops it being
    /// forgotten again.
    private enum ClickTarget {
        /// Bare canvas — make a scrap here.
        case emptyCanvas
        /// A scrap the view has measured and laid out — enter it.
        case scrap(node: CanvasNode, layout: ScrapLayout, frame: CGRect)
        /// A node that cannot be entered: an item node (1C-d gives those their
        /// own behaviour), or a scrap with no layout or no `cachedHeight` yet.
        /// Reachable TODAY — Task 5's codec round-trips item nodes deliberately,
        /// so a sidecar written by a later build opens with them present.
        case unenterableNode
        /// A line. Nothing to enter and nothing to make — see the switch below.
        case line
        /// A region's title (`CanvasRegionMetrics.titleHitRect`) — name it in
        /// place. The rest of its chrome bar is `.emptyCanvas`, and mints.
        case regionTitle(CanvasRegionID)
    }

    private func clickTarget(at contentPoint: CGPoint) -> ClickTarget {
        guard let node = model.scene.topmostNode(at: contentPoint) else {
            // The SAME precedence as `CanvasScene.selectionTarget`, and it has
            // to be:
            // the `clickCount: 1` AppKit sends first has already selected
            // whatever this resolves to, so a double click that answered a
            // different question would act on something the writer is not
            // looking at.
            if CanvasLineHit.line(at: contentPoint, in: model.scene) != nil { return .line }
            if let region = regionTitle(at: contentPoint) { return .regionTitle(region) }
            return .emptyCanvas
        }
        guard case .scrap = node.kind,
              let layout = layouts[node.id],
              let frame = node.frame else { return .unenterableNode }
        return .scrap(node: node, layout: layout, frame: frame)
    }

    /// The region whose title is under `contentPoint`: on its chrome bar (the
    /// same `regionHit` the selection asks, so click 1 has selected it) and
    /// inside the title's target, sized by the label as drawn.
    private func regionTitle(at contentPoint: CGPoint) -> CanvasRegionID? {
        guard case .chrome(let id)? = CanvasInteraction.regionHit(at: contentPoint, in: model.scene),
              let region = model.scene.region(id) else { return nil }
        let title = CanvasRegionMetrics.titleHitRect(
            in: region.frame, labelWidth: CanvasRenderer.drawnLabelWidth(of: region))
        return title.contains(contentPoint) ? id : nil
    }

    /// Single click: leave whatever was being edited. Double click: enter the
    /// scrap under the pointer, or make one on bare canvas.
    ///
    /// The single/double split is the standard canvas idiom, and it is what lets
    /// a single click start a DRAG while the editor is unmounted — with the
    /// editor frontmost, a focused scrap owns its own mouse.
    ///
    /// One accepted gap, from the same fact: a click that lands here while an
    /// editor is already mounted on the SAME scrap updates `caretIndex` but does
    /// not move the caret, because `ScrapEditorHost` re-claims focus only on a
    /// rebind — by design, or every camera nudge would slam the caret back. It
    /// can only happen inside the ~120 ms window where the editor is mounted but
    /// still invisible and therefore not taking its own clicks; once the card is
    /// level AppKit places the caret itself, which is the whole point of putting
    /// the editor in front. A second double-click inside a tenth of a second
    /// keeps the first one's caret.
    func handleClick(at contentPoint: CGPoint, clickCount: Int) {
        // FIRST, above everything else in this method: the selection as the
        // writer saw it when they pressed. The connect-mark drag reads it at
        // `.began`, which runs after this whole method — see
        // `selectionWhenPressed`.
        selectionWhenPressed = model.selection
        editFocus.commitActiveEdit()
        // An open region title keeps what was typed: a click anywhere on the
        // canvas commits it (spec §3), before the click does anything else.
        regionTitleEditing.commitIfOpen()

        // A read-only canvas (issue #44) takes a double click as a single one:
        // it selects, and makes, enters and mounts nothing.
        guard CanvasEditGate.clickCount(clickCount, isReadOnly: model.isReadOnly) >= 2 else {
            model.selection = model.scene.selectionTarget(at: contentPoint)
            // The selection is read INSIDE the draw closure, where a model value
            // is not in SwiftUI's dependency graph — that is what this counter
            // is for. `revision` and never `sceneRevision`: a selection change
            // is not a structural one.
            //
            // **No test can see this line today, and that is measured rather
            // than assumed** (mutation, 2026-07-27: removing it leaves the
            // mounting and composition suites entirely green). `leaveTheOpenScrap()`
            // on the next line writes three pieces of `@State`, which invalidates
            // `body` and gets the redraw for free — so the bump is currently
            // belt and braces. It stays because that cover is incidental: a
            // selection set from anywhere that does NOT also move focus — the
            // inspector in the other column, a keyboard selection — has nothing
            // else to invalidate on, and the symptom is an accent that appears
            // whenever something unrelated next redraws.
            revision += 1
            editFocus.leaveTheOpenScrap()
            model.scheduleSave()
            return
        }

        switch clickTarget(at: contentPoint) {
        case .scrap(let node, let layout, let frame):
            // §7A.5 requirement 1: resolve the caret in the card's LOCAL,
            // UNROTATED space at CLICK TIME — before the card straightens.
            // Straightening first moves the click point out from under the
            // cursor, and the caret lands somewhere the writer did not aim.
            let angle = CanvasRenderer.drawnAngle(for: node, straighten: straighten)
            let local = CanvasRenderer.localPoint(contentPoint, inCard: frame, angle: angle)
            let textOrigin = CanvasCardMetrics.textOrigin(inCard: frame)
            let caret = layout.characterIndex(
                at: CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y))
            // `commitActiveEdit` at the head of this method has already closed
            // the previous visit, so a click straight from one scrap into
            // another never nests.
            scrapFlow.enter(node.id, caretIndex: caret)

        case .emptyCanvas:
            // One "New Scrap" step, then "Edit Scrap" — `CanvasScrapFlow` is the
            // one way to make a scrap, chapter-aware.
            scrapFlow.makeScrapAndEnter(at: contentPoint)

        case .regionTitle(let id):
            // Click 1 selected the region; click 2 names it where it is. The
            // rest of the bar falls to `.emptyCanvas`, tripwire 32's repro.
            regionTitleEditing.begin(id)

        case .unenterableNode, .line:
            // Nothing to enter, so this behaves like a single click. Falling
            // through instead would leave `editingNodeID` and `straighten`
            // pointing at whatever was open before: the invisible editor stays
            // mounted on the card the writer just clicked AWAY from, and
            // `visibleEditorNodeID` re-reveals it the moment `isLevel` fires.
            //
            // **A line shares this arm rather than falling to `.emptyCanvas`,
            // and that is a real bug rather than a tidiness.** There it would
            // mint a scrap UNDER the writer's own line — and AppKit sends
            // `clickCount: 1` first, so that click has already selected the line
            // and the other column is showing it. "Edit Scrap" open over a line
            // selection is tripwire 32's own repro arriving through a new door.
            // A double click on a line therefore opens no editor of any kind;
            // its label is edited in the other column, which is where a region's
            // label already is.
            editFocus.leaveTheOpenScrap()
        }
        model.scheduleSave()
    }
}
