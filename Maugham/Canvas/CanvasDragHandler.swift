import SwiftUI

/// `CanvasView`'s drags: the press, move and release of every gesture the
/// surface runs — moving and resizing cards and regions, sweeping a region,
/// drawing a line, and the throw — with the undo bracket each one opens and
/// closes (tripwire 32), over bindings to the view's own `@State`.
///
/// A sweep that makes a region opens its title for typing once its "New
/// Region" step has closed, through the `regionTitleEditing` it holds.
///
/// Built fresh per call by `CanvasView.dragHandler` and never stored; built
/// nowhere else (tripwire 32's surface census).
@MainActor
struct CanvasDragHandler {
    let model: CanvasModel
    let subject: CanvasSubject
    let layoutPass: CanvasLayoutPass
    let regionTitleEditing: CanvasRegionTitleEditing
    @Binding var interaction: CanvasInteraction
    @Binding var momentum: CanvasMomentum
    @Binding var revision: Int
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var selectionWhenPressed: CanvasSelection?

    // MARK: - Drags

    /// What the Edit menu will call this gesture. The writer reads these — the
    /// item says "Undo Move Region", not "Undo" — so every mode `begin` can
    /// enter needs one, and the compiler is what says so.
    ///
    /// `nil` cannot arrive: the one caller asks only when `isActive`. It has a
    /// name anyway rather than a `!`, because the alternative to a harmless
    /// fallback here is a crash on a surface the writer is dragging.
    ///
    /// **The node arms say "Card" and not "Scrap", and the noun is UNIFORM
    /// rather than routed through the kind** *(1C-d, whole-branch review M2).*
    /// They said "Scrap" while a scrap was the only node a writer could move or
    /// resize; 1C-d made an item node a first-class card — it resizes, it has an
    /// inspector arm, it promotes, and three routes create one — so a writer who
    /// dragged a **photograph** read *Undo Move Scrap*. That is Task 6's own
    /// `minimumScrapWidth` → `minimumCardWidth` argument ("it clamps every kind
    /// now, so the old name is false") arriving on the strings the writer
    /// actually reads, which is where it matters more than in an identifier.
    ///
    /// **Routing the noun through `CanvasNodeKind` was the other option and it is
    /// the wrong one**: `PromotionSource.noun`'s recorded ruling is that **a card
    /// is the NODE** the writer clicked and **a picture is the FILE** it holds, so
    /// "Move Picture" would contradict a distinction this slice took a fix round
    /// to settle — and it is false anyway of a referenced item node standing for a
    /// note, a PDF or a recording. One noun that is true of every kind beats three
    /// that are each true of one.
    ///
    /// **`"New Scrap"` deliberately does NOT move** (`handleClick`'s
    /// `.emptyCanvas` arm): a double-click on bare canvas mints a scrap and can
    /// mint nothing else, so there the narrower noun is the accurate one.
    private static func gestureName(for kind: CanvasInteraction.Kind?) -> String {
        switch kind {
        case .movingNode: return "Move Card"
        case .resizingNode: return "Resize Card"
        case .movingRegion: return "Move Region"
        case .resizingRegion: return "Resize Region"
        case .drawingRegion: return "New Region"
        case .drawingLine: return "Draw Line"
        case nil: return "Canvas"
        }
    }

    /// Whether this press begins a LINE rather than a move, a resize or a sweep.
    ///
    /// **Two routes, resolved into one `Bool` before `CanvasInteraction` sees
    /// anything**: ⇧ held over any card, and a drag out of the connect mark on
    /// the *selected* card. One answer means one implementation of what a connect
    /// drag does, so the discoverable route and the fast one cannot drift into
    /// behaving differently. It is a `static func` over its inputs rather than a
    /// computed property on the handler so it is reachable from a test without
    /// hosting SwiftUI — a decision one level above a primitive is exactly where
    /// this area has shipped unreachable halves before.
    ///
    /// **⇧ owes nothing to the selection**, and the mark route owes nothing to ⇧.
    /// ⇧ on bare canvas still sweeps a region: `CanvasInteraction.begin` only
    /// consults this when the press lands on a node, and there is no marquee
    /// select here (§9) for ⇧ to collide with.
    ///
    /// Three things must all hold for the mark route, and each is a way for the
    /// writer to have aimed at something else:
    ///
    /// - **A NODE is selected.** The mark is selection chrome and is drawn
    ///   nowhere else, so on an unselected card — or with a region selected —
    ///   there is nothing there to press. This is what stops the press that
    ///   *selects* a card from also starting a line out of it: `applyMouseDown`
    ///   fires `onClick` strictly before `onDrag(.began)`, so the first press
    ///   would otherwise both reveal the mark and act on it, and the writer would
    ///   have drawn a line at a mark that was not on screen when they pressed.
    ///   Click, then press, is two gestures and is correct.
    /// - **The press is inside `connectHandleRect`**, which is `.null` on a card
    ///   too short to hold the mark above the resize corner. `CGRect.null`
    ///   contains no point, so such a card simply has no connect target and ⇧ is
    ///   the way in — pinned by test rather than assumed.
    /// - **The selected card is the one under the pointer.** Another card in
    ///   front hides the mark, and `begin` resolves the source with
    ///   `topmostNode(at:)` — so without this the writer would press a card they
    ///   can see and get a line out of one they cannot.
    ///
    /// **`nonisolated` because it is pure**, and that is worth saying now that the
    /// enclosing struct carries `@MainActor` (1C-d): this reads its three
    /// arguments and no view state, so isolating it would be a claim about where
    /// it may be *called* that nothing about it justifies — and it would put every
    /// caller, tests included, on the main actor for a rect test.
    nonisolated static func pressStartsALine(at contentPoint: CGPoint,
                                             selection: CanvasSelection?,
                                             in scene: CanvasScene,
                                             shiftHeld: Bool) -> Bool {
        if shiftHeld { return true }
        guard case .node(let id)? = selection,
              let frame = scene.node(id)?.frame,
              scene.topmostNode(at: contentPoint)?.id == id else { return false }
        return CanvasRenderer.connectHandleRect(inCard: frame).contains(contentPoint)
    }

    /// A left-drag that begins over empty canvas now DRAWS A REGION, and one
    /// that begins inside an existing region's interior is still a no-op:
    /// `CanvasInteraction.begin` leaves the mode idle there, so `.changed` and
    /// `.ended` below never register. Nested regions are out of scope (§9).
    /// Panning is `scrollWheel`/`magnify`, not click-and-drag, and there is no
    /// marquee-select — that is out of scope here, not merely unbuilt.
    ///
    /// **A drag that starts inside a FOCUSED scrap belongs to the editor**, which
    /// is in front and takes the mouse itself, so it is a text selection rather
    /// than a card move. Nothing currently lets a writer drag a focused card by
    /// its text; whether that is right is a product question nobody has answered,
    /// and it is flagged rather than decided here.
    ///
    /// **A ⇧-drag from a card, or a drag out of the selected card's connect mark,
    /// draws a LINE.** Both are resolved into one `Bool` here — see
    /// `pressStartsALine` — and after the focus guard rather than before it: a
    /// drag inside a focused scrap belongs to the editor, which is in front and
    /// takes the mouse itself, so asking about connect marks above that guard
    /// would compute an answer for a press this handler never sees.
    ///
    /// **`timestamp` is the EVENT's time, and it goes exactly two places** —
    /// `interaction.update(…, now:)` and `interaction.end(now:)`, the pair that
    /// decides whether a release was a throw (issue #34). Every other arm here
    /// ignores it, and deliberately: a region sweep or a resize has no velocity
    /// to age, so threading it further would be handing a clock to code with no
    /// use for one. Before it arrived, both calls defaulted to
    /// `CACurrentMediaTime()` at PROCESSING time, so a main-thread stall between
    /// the last `mouseDragged` and the `mouseUp` aged a real writer's flick past
    /// `CanvasInteraction.maximumFlickAge` and disarmed it — a card that stopped
    /// dead where the pointer let go, and the reason the mounted flick test
    /// flaked on a loaded CI machine.
    ///
    /// Undefaulted, for `shiftHeld`'s reason one level up: the default belongs
    /// at the SEAM and nowhere below it, so the one call site here has to say
    /// which clock it means.
    func handleDrag(at contentPoint: CGPoint, phase: CanvasDragPhase, shiftHeld: Bool,
                    timestamp: TimeInterval) {
        switch phase {
        case .began:
            // ANY press stops a coast — this one included, and one on bare
            // canvas nowhere near the moving card. Above the focus guard
            // deliberately: the press that ENTERS a scrap is the second of a
            // double-click, and if the first one jiggled far enough to launch a
            // flick (the floor is half a point per frame) the card would go on
            // coasting under the mounted editor, dragging the text box with it.
            // The resting place reaches disk without a save of its own here: the
            // `onClick` that preceded this call scheduled one — every branch of
            // `handleClick` does — and `scene` already held every frame the
            // coast had applied.
            //
            // A press TRUNCATES the coast, so the card comes to rest HERE and
            // never reaches the timeline's rest branch — the only other place
            // that bumps the structural counter for a coast. Leave this out and
            // the accessibility tree keeps the frame the card had when the writer
            // let go of it, for as long as it takes some other structural change
            // to come along. This is the one path `commitActiveEdit`'s formerly
            // unconditional bump covered by accident, which is why it arrived
            // with the guard that removed it.
            // `CanvasViewMountingSurfaceTests.test_aPressThatStopsACoastRefreshesTheAccessibilityFrame`
            // reads 40 against a card drawn at 64 without it — and its cheap
            // half, `…BumpsTheCounterTheTreeIsRebuiltOn`, catches the same
            // removal without needing an assistive client to be attached.
            let wasCoasting = !momentum.isAtRest
            momentum.stop()
            if wasCoasting { model.bumpSceneRevision() }
            // A focused scrap owns its own mouse, so a drag can only start on an
            // unfocused card. `onClick` has already run for this same mouse-down
            // (`CanvasEventNSView.applyMouseDown` pins that order), so this sees
            // the focus state the click just set.
            guard editingNodeID == nil else { return }
            // Nor under an open region title: the only press that reaches here
            // with one open is the double click's second press, which has just
            // opened it — the bar is the field's now, as a focused scrap's card
            // is its editor's.
            guard !regionTitleEditing.isOpen else { return }
            // A read-only canvas (issue #44) begins no interaction, so
            // `.changed`/`.ended` bail on `isActive` and no coast launches. Pan
            // and zoom are scroll and magnify, and never reach this.
            guard CanvasEditGate.dragBegins(isReadOnly: model.isReadOnly) else { return }
            // The two routes into a line, answered once, HERE — the gesture
            // layer deliberately has no opinion about what is selected.
            // `selectionWhenPressed` and NOT `model.selection`: `handleClick` has
            // already run for this same mouse-down and moved the selection onto
            // whatever is under the pointer. See that property.
            let connecting = Self.pressStartsALine(at: contentPoint,
                                                   selection: selectionWhenPressed,
                                                   in: model.scene,
                                                   shiftHeld: shiftHeld)
            interaction.begin(at: contentPoint, in: model.scene, connecting: connecting)
            // Only when `begin` found something. A press on bare canvas INSIDE a
            // region leaves the interaction idle, so `.ended` bails on its first
            // guard and would never close a gesture opened here — the next real
            // drag would then nest inside it and two gestures would collapse
            // into one ⌘Z.
            if interaction.isActive {
                model.beginGesture(Self.gestureName(for: interaction.kind))
            }
        case .changed:
            guard interaction.isActive else { return }
            // `persist: false`: a drag emits a position per frame and the save
            // it owns is the one at `.ended`.
            model.withScene(persist: false) {
                interaction.update(to: contentPoint, in: &$0, now: timestamp)
            }
            // A resize rewraps, and `CanvasScene.setWidth` clears the cached
            // height to say so. Re-derive it NOW, not at `.ended`: a node with
            // no `cachedHeight` has no `frame`, and a node with no frame is
            // invisible to `nodes(intersecting:)` — so without this the card
            // blinks out for the whole drag and reappears on release, which is
            // what the writer reported. Re-measuring live is also the point of
            // a resize handle: the text visibly rewraps under the pointer.
            //
            // ONE node, not `rebuildLayouts()`, which measures every scrap on
            // the canvas and runs at drag-frame rate here. And deliberately no
            // `sceneRevision` bump — that is the STRUCTURAL counter and the
            // accessibility tree is gated on it (tripwire 30); bumping it per
            // frame would sort the scene and copy every scrap's string at
            // 60–120 Hz. The end of the resize bumps it once, via
            // `rebuildLayouts()`.
            if interaction.isResizing, let id = interaction.activeNodeID {
                layoutPass.remeasure(id)
            }
            revision += 1
        case .ended:
            guard interaction.isActive else { return }
            let wasResizing = interaction.isResizing
            // Both read BEFORE `end()` clears the mode. The swept rect lives in
            // the interaction and nowhere else, so there is no second copy of it
            // to go stale.
            let drawnRegion = interaction.pendingRegionDraw
            let movedNode = interaction.kind == .movingNode ? interaction.activeNodeID : nil
            // A line is CLOSED up here rather than merely read, and it is the one
            // of these that is not symmetrical with the sweep. The swept rect is
            // a value and survives in a `let`; the SOURCE CARD of a line lives in
            // the mode and nowhere else, so `endLine` has to run while the mode
            // is still live. It leaves the interaction idle itself, so `end()`
            // below reports no flick — the second guarantee that a line drag
            // never sends the card it started from skating.
            let wasDrawingLine = interaction.kind == .drawingLine
            var mintedLine: CanvasLineID?
            if wasDrawingLine {
                model.withScene(persist: false) {
                    mintedLine = interaction.endLine(at: contentPoint, in: &$0)
                }
            }
            let flick = interaction.end(now: timestamp)

            // Whether the sweep actually changed the scene, read below. A sweep
            // that minted nothing and bound nothing changed no part of it, and it
            // must not be mistaken for one that did — see the bump in the `else`
            // branch, where BOTH shapes have to be counted or the area the writer
            // just claimed stays dim.
            var sweepChangedTheScene = false
            // The region a sweep MADE, whose title opens once its step closes.
            var mintedRegion: CanvasRegionID?

            if let drawnRegion {
                model.withScene(persist: false) { scene in
                    // *** §4.1's invariant, and it is the whole of slice 3's
                    // mode: while the board is dimmed a sweep binds to whatever
                    // the tree names. *** The routing — assign what it caught, or
                    // create — is `sweepOutcome`'s, decided over the swept rect,
                    // the subject and the scene together. It is not re-spelled
                    // here, and the group exception lives there rather than in
                    // this handler, where it would be one `if` away from being
                    // lost in a later edit.
                    //
                    // Both arms are INSIDE this one `withScene`, in the bracket
                    // `.began` opened, so one ⌘Z takes back the whole act — the
                    // region and its binding, or every binding the sweep made.
                    // The drop-join twenty lines down is the same shape for the
                    // same reason. Anywhere else (a `mutate` of its own, or the
                    // inspector's verb) is a SECOND step on the stack: the writer
                    // presses ⌘Z, watches the box go, presses it again expecting
                    // their last sentence back and re-runs a binding change
                    // nothing can show them.
                    //
                    // **Never `mutateFromInspector`** — this is inside
                    // `handleDrag`'s own open bracket, and close-run-reopen would
                    // end a gesture the writer is still holding (tripwire 32's
                    // converse, censused in `TripwireGrepTests`).
                    switch CanvasInteraction.sweepOutcome(for: drawnRegion,
                                                          subject: subject, in: scene) {
                    case .bind(let regions, let piece):
                        // **Nothing is created, nothing moves, nothing is
                        // stolen** — so there is no `join`, no absorb and no
                        // re-homing on this path, which is precisely where the
                        // stealing would have bitten hardest. Tripwire 31 is not
                        // even in play: no geometry is being turned into
                        // membership, only into a binding the writer aimed at.
                        //
                        // Every region here is UNBOUND — `sweepOutcome` filtered
                        // them, because a sweep never re-binds (Denver,
                        // 2026-08-03). Moving a binding from one document to
                        // another stays the inspector's Piece picker's job.
                        for region in regions {
                            RegionBinding.bind(region, toPiece: piece, in: &scene)
                        }
                        // The selection is deliberately NOT touched. Nothing was
                        // created, so there is nothing new to hand the writer,
                        // and several regions cannot be handed to a
                        // single-subject inspector anyway. §4.1 names the undim
                        // as *"the only confirmation the gesture gives"*.
                        //
                        // The bracket was named "New Region" at `.began`, before
                        // the answer existed. Nothing was made, so say what was
                        // done: the Edit menu reads *Undo Bind Region(s)*.
                        model.renameGesture(regions.count == 1 ? "Bind Region"
                                                              : "Bind Regions")
                        sweepChangedTheScene = true
                    case .create(let piece):
                        // A sweep under `minimumSide` mints nothing — which is
                        // what every single click on bare canvas is, since
                        // `applyMouseDown` opens a drag session on every
                        // mouse-down.
                        //
                        // **Tripwire 31 licenses the absorption inside
                        // `createRegion` because it is a CREATION**: there is no
                        // prior relationship to break. It is not a licence for a
                        // move or a resize to touch membership or a binding.
                        guard let id = CanvasInteraction.createRegion(drawnRegion,
                                                                      in: &scene) else { break }
                        model.selection = .region(id)
                        mintedRegion = id
                        if let piece { RegionBinding.bind(id, toPiece: piece, in: &scene) }
                        sweepChangedTheScene = true
                    case .doNothing:
                        // Everything the sweep caught was already bound, so
                        // there is nothing to bind and — the half that matters —
                        // nothing to create either. Falling through to `.create`
                        // here drops a fresh rectangle on top of a board that
                        // already had regions on it, which is the defect §4.1
                        // exists to remove, arriving through its own fix.
                        //
                        // `sweepChangedTheScene` stays false, so no
                        // `sceneRevision` bump; the scene is untouched, so
                        // `endGesture` registers no step. The gesture costs the
                        // writer nothing at all.
                        break
                    }
                }
            } else if wasDrawingLine {
                // The line itself was inserted above; what belongs here is what
                // the writer is left holding. Selecting it is the same courtesy a
                // swept region gets, and it is what puts the new line under ⌫ and
                // under the inspector. A drag that minted nothing — bare canvas,
                // or back onto the source card — leaves the selection exactly as
                // it was: the writer changed nothing, so nothing they had should
                // move.
                if let mintedLine { model.selection = .line(mintedLine) }
            } else if let movedNode, interaction.hasMoved {
                // The drop, INSIDE the move's own gesture — so one ⌘Z takes back
                // the move and the join together. Dropping outside every region
                // removes nothing: removal is always its own act (§4.2), and the
                // tether is what makes the resulting state legible.
                model.withScene(persist: false) {
                    if let target = CanvasInteraction.joinTarget(for: movedNode, in: $0) {
                        CanvasMembership.join(movedNode, home: target, in: &$0)
                    }
                }
            }

            if wasResizing {
                // The rewrap cleared the cached height; re-measure before the
                // card is hit-tested or culled again. `rebuildLayouts()` bumps
                // `sceneRevision` itself.
                //
                // *** UNCONDITIONAL, and NOT behind `hasMoved`. *** The two ask
                // different questions: `hasMoved` is "did the pointer leave the
                // press point", while `CanvasScene.setWidth` clears
                // `cachedHeight` on EVERY `.changed`, including one delivered at
                // exactly the press point with an identical width. Gate this on
                // `hasMoved` and that one sample leaves the card with no height,
                // therefore no `frame`, therefore invisible to `topmostNode(at:)`,
                // to `nodes(intersecting:)` and to the renderer — the card
                // vanishes, and only a reload brings it back.
                //
                // The cost is that a corner press that never moved re-measures
                // and re-queues a save for an unchanged scene, which is cheap
                // and idempotent. It is NOT a licence to push an undo step from
                // here: anything added to this branch that the writer could
                // notice still has to read `interaction.hasMoved`. The gesture
                // closed below is not that — `endGesture` registers nothing at
                // all when the scene did not move.
                layoutPass.rebuildLayouts()
                // AFTER the re-measure, and the ordering is the whole of it.
                // `setWidth` clears `cachedHeight` on EVERY `.changed`, and
                // `CanvasNode` is `Equatable` INCLUDING that field. Close the
                // gesture first and the diff is "card with a height" against
                // "card with none", which differ — so a corner press that never
                // moved registers a step, and the writer's next ⌘Z appears to do
                // nothing while the one after it takes back an edit they had
                // forgotten about. Worse, that step's REDO re-applies the
                // heightless card: no `frame`, so invisible to `topmostNode(at:)`,
                // to `nodes(intersecting:)` and to the renderer at once.
                // `test_aCornerPressThatNeverMovedLeavesNothingToUndo` is the one
                // that fails if these two lines are swapped.
                model.endGesture()
            } else {
                // A press that never moved is not a drag. AppKit opens a drag
                // session on EVERY mouse-down, including the first of a
                // double-click, so without this every click into a scrap would
                // write the sidecar and rebuild the accessibility tree for
                // nothing. Safe HERE and not above because a move mutates
                // nothing until the pointer actually moves.
                //
                // The gesture closes ABOVE this bail-out, not below it: the
                // press opened one at `.began` whether or not it turned into a
                // drag, and returning with it still open would leave the next
                // real drag nested inside it — two gestures, one ⌘Z, and the
                // card jumping back further than the writer asked. Nothing
                // moved, so `endGesture` registers no step.
                model.endGesture()
                // *** `|| mintedLine != nil` KEEPS THE WRITER'S LINE. *** This
                // bail-out returns above `model.scheduleSave()`, and `hasMoved`
                // is set by `update`, which runs only on `.changed` — so a press
                // on one card and a release over another with no drag sample
                // between them would insert a line under `persist: false` and
                // then leave without ever queuing a write. A line the writer drew
                // and watched appear, gone at quit, with nothing to say why.
                //
                // **The sweep does not need this and the line does**, which is
                // the part that is not obvious from the symmetry: a sweep's rect
                // comes from the mode's own `current`, so with no `.changed` it
                // is a zero rect and `createRegion` refuses it — there is nothing
                // to lose. `endLine` reads the RELEASE point directly and is the
                // first gesture here that can mint something without a single
                // drag sample.
                guard interaction.hasMoved || mintedLine != nil else { return }
                // *** KEEP THIS, AND KEEP ITS GUARD. *** A move is one structural
                // change, recorded at the END of the gesture rather than once per
                // drag frame, and both the accessibility tree and the region
                // inspector's member lists are rebuilt from this counter alone. If
                // the card is about to coast, the timeline bumps it again when the
                // coast comes to rest.
                //
                // The guard is the sweep that minted nothing. `hasMoved` asks
                // whether the pointer left the press point, and on a trackpad a
                // press that drifted one point takes it — so on bare canvas that
                // is MOST clicks, since `applyMouseDown` opens a drag session on
                // every mouse-down and `createRegion` refuses anything under
                // `CanvasRegionMetrics.minimumSide`. Bumping there sorts the whole
                // scene and copies every scrap's string to rebuild a tree for a
                // scene that did not change, and rebuilds the inspector's lists
                // beside it, once per click on nothing.
                //
                // `drawnRegion == nil` is the other half of the same question and
                // not a second rule: outside a sweep, `hasMoved` and a live
                // interaction together mean a card or a region really moved.
                //
                // **A line drag that minted nothing takes the same guard**, and
                // it GROWS this predicate rather than adding a second `if`
                // beside it, because it is the same question asked of a third
                // gesture. It is reachable the same way: every ⇧-press on a card
                // opens a drag session, a trackpad press routinely drifts a
                // point, and a release over bare canvas makes no line — without
                // this each one would sort the scene, copy every scrap's string
                // and rebuild two cached lists in the other column.
                //
                // **A sweep that BOUND without minting counts here too**, and
                // that is §4.1's acceptance criterion rather than a nicety: the
                // lit set is rebuilt from this counter, so a bind that skipped it
                // would leave the region the writer just claimed dim until
                // something unrelated moved. The whole confirmation the gesture
                // gives is the undim, and it has to arrive inside the gesture.
                // `sweepChangedTheScene` covers both shapes for exactly that
                // reason — a `mintedRegion` here would have been true of one.
                let changedSomething = sweepChangedTheScene || mintedLine != nil
                if (drawnRegion == nil && !wasDrawingLine) || changedSomething {
                    model.bumpSceneRevision()
                }
                if let flick { momentum.launch(flick.id, velocity: flick.velocity) }
            }
            model.scheduleSave()
            revision += 1
            // Spec §3: a swept region's title opens for typing, like a new
            // Finder folder — AFTER `endGesture` above, so "New Region" is its
            // own closed step and naming never nests inside it.
            if let mintedRegion { regionTitleEditing.begin(mintedRegion) }
        }
    }
}
