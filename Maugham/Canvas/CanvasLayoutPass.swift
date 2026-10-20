import SwiftUI

/// `CanvasView`'s layout pass: the `ScrapLayout` cache and every card's derived
/// height, over bindings to the view's own `@State`.
///
/// Built fresh per call by `CanvasView.layoutPass` and never stored, so no
/// `@State` is ever read through a stale copy; built nowhere else (tripwire 32's
/// surface census). `itemIndex` is the MODEL's copy, handed in by that property
/// (issue #57, tripwire 57).
@MainActor
struct CanvasLayoutPass {
    let model: CanvasModel
    let itemIndex: CanvasItemIndex
    let projectRoot: URL
    @Binding var thumbnails: CanvasThumbnails
    @Binding var layouts: [CanvasNodeID: ScrapLayout]
    @Binding var itemPresentation: CanvasItemPresentation
    @Binding var thumbnailServiceTicket: Int
    @Binding var revision: Int

    /// Build a layout per scrap and fill in the derived heights the model needs
    /// for hit testing and culling.
    ///
    /// Called from `load`, and again from every path that can leave a node
    /// unmeasured: creating a scrap, finishing a resize, committing an edit. A
    /// node with no `cachedHeight` has no `frame`, so it is invisible to both
    /// hit testing and culling — it is on the canvas and cannot be clicked.
    ///
    /// **Replacing a layout whose editor is MOUNTED is safe**, and this says so
    /// with a measurement because it used to say the opposite with a warning.
    ///
    /// Task 15's undo is the caller that does it: `applySnapshot` restores an
    /// older string into `scraps` while the writer is still in the scrap, so the
    /// reuse branch below (keyed on `existing.text == text`) misses, `layouts[id]`
    /// is overwritten, and the `ScrapLayout` the mounted `NSTextView` was built
    /// from is released **synchronously** — a whole SwiftUI update pass before
    /// `ScrapEditorHost.updateNSView` rebinds. The old warning called that window
    /// a dangling stack, on the theory that the view retains only its
    /// `NSTextContainer`, whose `textLayoutManager` back-link is weak.
    ///
    /// That theory is wrong. Measured 2026-07-26 on macOS 26.5: with the
    /// `ScrapLayout` released and nothing but the text view left alive, the
    /// `NSTextLayoutManager`, the `NSTextContentStorage` and the `NSTextStorage`
    /// are all still alive, `textContainer.textLayoutManager` is non-nil,
    /// `string` reads, and the view lays out and draws. An `NSTextView` built
    /// through `NSTextView(frame:textContainer:)` owns its TextKit 2 stack
    /// itself. `ScrapLayoutTests.test_theMountedEditorOutlivesTheScrapLayoutThatBuiltIt`
    /// is that measurement in isolation, and
    /// `CanvasViewMountingEditingTests.test_anUndoInsideAScrapLeavesItsLiveEditorUsableBeforeTheRebind`
    /// is the same window reached through a real ⌘Z on the real surface.
    ///
    /// What that buys is a window that is safe, not one that is correct: through
    /// it the mounted view still shows the text the undo discarded. Showing the
    /// restored words is the REBIND's job — `updateNSView` sees a new layout
    /// identity and remounts — which is why the replacement has to be a new
    /// `ScrapLayout` rather than the old one mutated in place.
    ///
    /// `unorderedNodes`, not `nodes`: this measures every scrap and does not
    /// care which is in front, and `CanvasScene.nodes` sorts the whole scene on
    /// every access.
    ///
    /// **The layout CACHE lives here; the HEIGHT arithmetic does not.** The
    /// `ScrapLayout` objects are built and kept in this view because the mounted
    /// `NSTextView` and the draw pass share one TextKit stack per scrap (tripwire
    /// 26) — that sharing is §7A.2's structural mitigation and this loop is what
    /// maintains it. The number that goes into the scene comes from
    /// `CanvasScrapMeasure`, so a caller with no view on screen measures a card
    /// exactly as this does.
    ///
    /// **It measures BOTH kinds as of 1C-d, and they are two arithmetics.** A
    /// scrap's height comes from its text through the shared `ScrapLayout`; an
    /// item node's comes from its picture's aspect ratio plus one line of label
    /// (`CanvasCardMetrics.itemCardHeight(forCardWidth:pictureAspect:)`). Both are
    /// functions of the card's WIDTH, which is the rule §7A.3 already had and is
    /// what makes resizing an item node safe: `CanvasScene.setWidth`
    /// clears the cached height by design, and this pass puts back one that
    /// follows the new width.
    ///
    /// **`CanvasCardMetrics.itemLabelOnlyHeight` stays as the FLOOR**, which is
    /// what a card with no picture measures to and what a card whose picture has
    /// not decoded yet measures to as well. It is not bookkeeping: a node with no
    /// `cachedHeight` has no `frame`, and a node with no frame is dropped by
    /// `CanvasScene.topmostNode(at:)` and `nodes(intersecting:)` alike — neither
    /// drawn nor clickable, and persisted that way, which is the 1C-c3
    /// whole-branch Critical. Everything that can leave a node unmeasured now
    /// lands on the floor instead of on nil: a hand-edited sidecar, a photograph
    /// still decoding, a research item the writer deleted, and any future path
    /// that clears a height the way `setWidth` does.
    ///
    /// **The item facts are re-resolved at the head of this function**, so the
    /// measurement and the draw pass read the same value by construction. That is
    /// also why a thumbnail landing calls this rather than only bumping the
    /// redraw counter: the picture changes the card's *height*, not just its
    /// pixels.
    ///
    /// **`bumpsThumbnailTicket` is `false` for exactly one caller — the `.task`
    /// this function's own ticket schedules — and that is the whole of N1's
    /// structural fix.**
    ///
    /// `CanvasItemPresentation.resolve` asks the cache for every item node in the
    /// scene, and `CanvasThumbnails` evicts LRU over a byte budget: an evicted
    /// path is a miss, and a miss is re-queued. So a rebuild run straight after a
    /// service misses on whatever that service's own decodes evicted. Bump the
    /// ticket there and the surface asks for exactly the work it has just undone,
    /// for ever: resolve → miss → ticket → service → evict → resolve. Each turn
    /// also bumps the structural counter, so the accessibility tree sorts the
    /// scene and copies every scrap's string on a loop — tripwire 30's cost,
    /// permanently, on a canvas holding more photographs than the budget can keep
    /// (roughly 85 at the size an item card asks for).
    ///
    /// **The count-based schedule hid this by stalling** (the defect fixed one
    /// commit earlier), which is why it appeared with the ticket and not before.
    /// Going back to the count is not the answer: it trades an unbounded loop for
    /// a silent stall on the far more reachable one-bad-file path.
    ///
    /// **A signature over the pending SET does not close it either**, and this is
    /// worth writing down because it is the obvious next idea. Above the budget
    /// the evicted tail ROTATES: `resolved` refreshes each hit's `lastUsed` in
    /// iteration order, so servicing one pending set evicts a *different* set, and
    /// the next pending set differs from the last. A signature bumps on every one
    /// of them and the thrash runs at full speed; it only ever settles by
    /// eventually repeating a set, i.e. by stalling — the defect it was meant to
    /// avoid, arriving a lap later.
    ///
    /// What is left behind instead is bounded and honest: a canvas over the budget
    /// keeps the shapes of all its photographs (`CanvasThumbnails.aspect`), so no
    /// height moves, and the pixels the budget could not keep come back on the
    /// next structural change rather than on a loop.
    ///
    /// `bumpsStructuralCounter` is `false` for a caller whose bump is already
    /// arriving by another route — one that calls `model.bumpSceneRevision()` on
    /// its own line, which the mirror in `body` turns into the view's bump. Every
    /// other caller has changed the shape of the scene with nothing else about to
    /// say so. **`grep "bumpsStructuralCounter: false"` for the current set**
    /// rather than trusting a number here: this file has carried a stale count of
    /// them before, and the rule is what a new caller needs to decide by.
    /// **Keeping the suppression is what makes one ⌫ or one ⌘Z rebuild the
    /// accessibility tree once rather than twice**, and a writer holding ⌘Z pays
    /// a scene sort and a copy of every scrap's string per step.
    /// The test that catches a mirror which stops delivering is
    /// `CanvasViewMountingEditingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`,
    /// which asks the published accessibility tree whether the deleted card has
    /// left it.
    func rebuildLayouts(bumpsStructuralCounter: Bool = true,
                                bumpsThumbnailTicket: Bool = true) {
        // FIRST, and inside this function rather than beside its callers: every
        // path that changes the scene has to re-ask what its item nodes are, and
        // the measurement below reads the answer. `resolve` decodes nothing — a
        // miss is recorded and serviced by the `.task` in `body`.
        //
        // **`model.itemIndex` and not this view's own** (issue #57). Two of this
        // function's callers are closures the model holds — `onSceneChangedExternally`
        // and `onSceneReplacedByUndo` — and a struct's closure captures the view
        // VALUE it was made from, so through them `itemIndex` is the index of the
        // canvas that first appeared. The model's copy is a reference they still
        // reach, and `load()` plus the fingerprint `.onChange` keep it equal to the
        // one the window last handed down.
        // Here `itemIndex` is this pass's own field, and `CanvasView.layoutPass`
        // fills it from `model.itemIndex` on the line tripwire 57's walk reads.
        itemPresentation = CanvasItemPresentation.resolve(scene: model.scene,
                                                          index: itemIndex,
                                                          thumbnails: thumbnails,
                                                          projectRoot: projectRoot)
        // ONE `withScene` around the whole loop rather than one per node, and
        // `persist: false` because the caller owns the save.
        let scraps = model.scraps
        let items = itemPresentation
        model.withScene(persist: false) { scene in
            for node in scene.unorderedNodes {
                // A `switch` rather than a `guard … else { continue }`, so a
                // third kind is a compiler error here rather than a card that
                // silently never gets a height.
                switch node.kind {
                case .item:
                    // Measured from the picture when there is one, floored to a
                    // line of label when there is not — see the doc above. The
                    // height is DERIVED, so it is written unconditionally: an
                    // older sidecar's number, or one left by a producer that
                    // planned a card before its picture existed, is not evidence
                    // about the card being drawn now.
                    scene.setCachedHeight(
                        CanvasCardMetrics.itemCardHeight(
                            forCardWidth: node.width,
                            pictureAspect: items.item(for: node.id)?.pictureAspect),
                        for: node.id)
                case .scrap:
                    measureScrap(node, in: &scene, scraps: scraps)
                }
            }
        }
        // A resolve that missed something is work for the `.task` in `body`.
        // Written after the measure, and bumped rather than assigned — see
        // `thumbnailServiceTicket` for the stall that a count produced.
        //
        // **The caller that must NOT bump is the one this task feeds**: a resolve
        // run right after a service misses on whatever that service's decodes
        // evicted, so bumping here would ask for exactly the work that was just
        // undone, for ever. See `bumpsThumbnailTicket`.
        if bumpsThumbnailTicket, thumbnails.pendingCount > 0 { thumbnailServiceTicket += 1 }
        // Layouts for nodes that no longer exist would keep their text alive.
        layouts = layouts.filter { model.scene.node($0.key) != nil }
        revision += 1
        // Every caller of this — load, create, resize-end, undo — has changed the
        // shape of the scene, so the accessibility tree is stale. Undo and delete
        // are the two that bump the model's counter themselves; see the
        // parameter's doc above.
        if bumpsStructuralCounter { model.bumpSceneRevision() }
    }

    /// One scrap's layout and the height that follows from it — `rebuildLayouts`'s
    /// `.scrap` arm, lifted out so that loop reads as the two-kind routing it is.
    ///
    /// It reuses the cached `ScrapLayout` when the text is unchanged, because that
    /// object is the SAME TextKit stack the mounted editor types into (tripwire
    /// 26); replacing it on a pass that only changed a width would hand the editor
    /// a stack nothing is drawing.
    private func measureScrap(_ node: CanvasNode,
                              in scene: inout CanvasScene,
                              scraps: [CanvasNodeID: String]) {
        let existing = layouts[node.id]
        let text = scraps[node.id] ?? ""
        let layout: ScrapLayout
        if let existing, existing.text == text {
            existing.setWidth(CanvasCardMetrics.textWidth(forCardWidth: node.width))
            layout = existing
        } else {
            layout = ScrapLayout(
                text: text,
                width: CanvasCardMetrics.textWidth(forCardWidth: node.width),
                font: CanvasScrapMeasure.scrapFont,
                textColor: CanvasRenderer.cardInk)
            layouts[node.id] = layout
        }
        scene.setCachedHeight(CanvasScrapMeasure.height(of: layout), for: node.id)
    }

    /// Re-derive ONE card's height from its current width, for the resize path.
    ///
    /// This is `rebuildLayouts()`'s per-node body for a single node, and it is
    /// deliberately the same calls in the same order — so there is one spelling
    /// of card geometry per kind. A second measurement path is precisely how
    /// drawn and edited text end up on different rects (spec §7A.2).
    ///
    /// **It measures BOTH kinds as of 1C-d Task 6, and that is the half of the
    /// resize that is not the gesture.** The corner used to be a `.scrap`'s
    /// alone, and this function used to say so with a `case .scrap` in its guard;
    /// the sentence that stood there — "neither of which can be resized" — was
    /// true for the whole life of the guard and then quietly was not, because
    /// 1C-c3's `CanvasClaudePlacement` began creating item nodes while the corner
    /// test had no kind test on it. `setWidth` cleared the height, this guard
    /// declined to refill it, and the card left the surface for good.
    ///
    /// So handing the corner back needs this arm and not only the pass in
    /// `rebuildLayouts`: the rebuild runs at `.ended`, and a card healed only
    /// there is off the surface for the whole length of the drag — invisible to
    /// `topmostNode(at:)`, to `nodes(intersecting:)` and to the renderer while
    /// the writer holds the mouse down, which is exactly how they meet it.
    /// `CanvasViewMountingSurfaceTests.test_aCornerDragOnClaudesSourcePageResizesItAndStaysOnTheCanvas`
    /// reads the scene BETWEEN the samples for that reason.
    ///
    /// **The aspect is read off the presentation resolved by the last rebuild,
    /// not re-resolved here.** `CanvasItemPresentation.resolve` asks the
    /// thumbnail cache, and asking RECORDS A MISS — per drag frame that is the
    /// pending queue growing at 60–120 Hz for a picture whose shape has not
    /// changed and cannot. What a wider card wants is more PIXELS, and that
    /// request is the rebuild's at `.ended`. A card whose photograph has not
    /// decoded yet lands on `itemLabelOnlyHeight`, which is the floor and never
    /// nil.
    ///
    /// A resize never changes a scrap's text, so its layout is always the reused
    /// one; that guard is for a scrap whose layout has not been built.
    ///
    /// Does NOT touch `revision` or `sceneRevision` — the caller owns both, and
    /// the structural counter must not move per frame.
    func remeasure(_ id: CanvasNodeID) {
        guard let node = model.scene.node(id) else { return }
        // A `switch` rather than a `guard … else { return }`, for
        // `rebuildLayouts`' reason: a third kind is a compiler error here rather
        // than a card that silently loses its height on the resize path.
        switch node.kind {
        case .item:
            let height = CanvasCardMetrics.itemCardHeight(
                forCardWidth: node.width,
                pictureAspect: itemPresentation.item(for: id)?.pictureAspect)
            model.withScene(persist: false) { $0.setCachedHeight(height, for: id) }
        case .scrap:
            guard let layout = layouts[id] else { return }
            layout.setWidth(CanvasCardMetrics.textWidth(forCardWidth: node.width))
            model.withScene(persist: false) {
                $0.setCachedHeight(CanvasScrapMeasure.height(of: layout), for: id)
            }
        }
    }
}
