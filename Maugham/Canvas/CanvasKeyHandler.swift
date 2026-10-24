import SwiftUI

/// `CanvasView`'s keys: ⌫ deletes the selection, refusing mid-gesture
/// (tripwire 32), Escape asks the window for the whole board, the keys inside
/// a scrap finish it or make the next one, and Return, Tab, ⌘Return and the
/// arrows on the canvas make, enter and select — over bindings to the view's
/// own `@State`. Each returns whether the canvas used the key;
/// `CanvasEventNSView.keyDown` sends an unused one to `super`.
///
/// Built fresh per call by `CanvasView.keyHandler` and never stored; built
/// nowhere else (tripwire 32's surface census). It holds `scrapFlow` and
/// `editFocus`, so it schedules nothing.
@MainActor
struct CanvasKeyHandler {
    let model: CanvasModel
    let subject: CanvasSubject
    let selectTheProjectRow: () -> Void
    /// ⇧Tab's one-way ask: the window focuses the binder (`CanvasView`'s
    /// input). Nil where no visible binder answers it.
    let returnKeyboardToTree: (() -> Void)?
    let editFocus: CanvasEditFocus
    let layoutPass: CanvasLayoutPass
    let scrapFlow: CanvasScrapFlow
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var revision: Int
    @Binding var camera: CanvasCamera
    /// Bumped to ask `CanvasEventNSView` to take the keyboard (its
    /// `serveKeyboardRequest`).
    @Binding var keyboardTicket: Int

    // MARK: - Keys inside a scrap

    /// Return, Escape (`.finish`), Tab (`.makeJoined`) and ⌘Return
    /// (`.makeBelow`) from the mounted editor; `viewSize` is the canvas's, for
    /// the reveal. Every command FINISHES first — fold, leave, select — so no
    /// typed word is ever lost, whatever follows.
    ///
    /// A make then asks, in the order `CanvasEditGateTests` pins: the gate
    /// (before the fold), the fold (which closes "Edit Scrap"), and whether a
    /// gesture is still open. A refused make has still finished, so it returns
    /// `true`: handing the key back would let the text view insert a tab or
    /// newline into the scrap just left, words the model never sees.
    ///
    /// The canvas is asked for the keyboard only when nothing new was entered;
    /// a new scrap's editor requests focus itself. Asking both wins for the
    /// editor today only because it mounts after the event view updates
    /// (measured by mutation, 2026-10-24), so the ask is withheld rather than
    /// left to that order.
    func handleEditorCommand(_ command: ScrapEditorCommand, viewSize: CGSize) -> Bool {
        guard let id = editingNodeID else { return false }
        let mayCreate = CanvasEditGate.keyCreates(isReadOnly: model.isReadOnly)
        editFocus.commitActiveEdit()
        editFocus.leaveTheOpenScrap()
        if model.scene.node(id) != nil { model.selection = .node(id) }
        revision += 1
        let start: CGPoint?
        switch command {
        case .finish:
            start = nil
        case .makeJoined, .makeBelow:
            start = model.scene.node(id)?.frame
                .map { Self.nextScrapStart(beside: $0, joined: command == .makeJoined) }
        }
        guard let start, mayCreate, !model.isInGesture else {
            keyboardTicket += 1
            return true
        }
        let origin = CanvasKeyboard.clearOrigin(startingAt: start, stepping: .down,
                                                size: CanvasKeyboard.newCardSize(), in: model.scene)
        let made = scrapFlow.makeScrapAndEnter(at: origin,
                                               joinedTo: command == .makeJoined ? id : nil)
        if let frame = model.scene.node(made)?.frame {
            camera.reveal(frame, viewSize: viewSize)
        }
        return true
    }

    /// Where Tab's joined scrap (to the right) or ⌘Return's (below) starts
    /// looking for room, beside a card at `frame`; `clearOrigin` steps it down.
    private static func nextScrapStart(beside frame: CGRect, joined: Bool) -> CGPoint {
        joined
            ? CGPoint(x: frame.maxX + CanvasKeyboard.placementGap, y: frame.minY)
            : CGPoint(x: frame.minX, y: frame.maxY + CanvasKeyboard.placementGap)
    }

    // MARK: - Keys on the canvas

    /// Return, Tab, ⌘Return and the arrows with the canvas holding the
    /// keyboard (`CanvasEventNSView.onKey`); spec §1's table. Returns whether
    /// the key was used, and an unused one travels on — Tab with nothing
    /// selected moves along the key-view loop.
    ///
    /// Nothing while a scrap is open (its keys are the editor's) or a gesture
    /// is (tripwire 32). The gesture is asked FIRST, before the gate and the
    /// fold: `commitActiveEdit` ends whatever gesture is open, so asked
    /// mid-drag it would close "Move Card" under the writer's hand. Then a
    /// creating or entering key asks the gate, folds (a no-op with no scrap
    /// open, kept so every make reads the same), and makes or enters — the
    /// order `CanvasEditGateTests` pins. The arrows ask no gate: selecting is
    /// not editing.
    func handleCanvasKey(_ key: CanvasKey, viewSize: CGSize) -> Bool {
        guard editingNodeID == nil, !model.isInGesture else { return false }
        let mayCreate = CanvasEditGate.keyCreates(isReadOnly: model.isReadOnly)
        // A selection that no longer resolves, or hides in a collapsed
        // region, is no selection: the writer sees nothing selected.
        var selection = model.selection
        if case .node(let id)? = selection, model.scene.node(id) == nil || model.scene.isHidden(id) {
            selection = nil
        }
        let start: CGPoint
        var joinedTo: CanvasNodeID?
        switch (key, selection) {
        case (.arrow(let arrow), _):
            return selectNearest(arrow, from: selection, viewSize: viewSize)
        case (.backtab, _):
            // Back to the binder; it creates nothing, so no gate. With no
            // binder to answer, the key is not used and travels on.
            guard let returnKeyboardToTree else { return false }
            returnKeyboardToTree()
            return true
        case (.returnKey, nil):
            let size = CanvasKeyboard.newCardSize()
            let centre = camera.contentPoint(fromView: CGPoint(x: viewSize.width / 2,
                                                               y: viewSize.height / 2))
            start = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        case (.returnKey, .node(let id)?):
            guard let node = model.scene.node(id), case .scrap = node.kind else {
                // An item card: nothing to enter, but the key is meant.
                return true
            }
            guard mayCreate, let frame = node.frame else { return false }
            editFocus.commitActiveEdit()
            scrapFlow.enter(id, caretIndex: (model.scraps[id] ?? "").utf16.count)
            camera.reveal(frame, viewSize: viewSize)
            return true
        case (.returnKey, .region?):
            // Task 8: rename the region in place.
            return false
        case (.returnKey, .line?):
            return true
        case (.tab, .node(let id)?), (.commandReturn, .node(let id)?):
            guard let frame = model.scene.node(id)?.frame else { return false }
            start = Self.nextScrapStart(beside: frame, joined: key == .tab)
            if key == .tab { joinedTo = id }
        case (.tab, _), (.commandReturn, _):
            return false
        }
        guard mayCreate else { return false }
        editFocus.commitActiveEdit()
        let origin = CanvasKeyboard.clearOrigin(startingAt: start, stepping: .down,
                                                size: CanvasKeyboard.newCardSize(), in: model.scene)
        let made = scrapFlow.makeScrapAndEnter(at: origin, joinedTo: joinedTo)
        if let frame = model.scene.node(made)?.frame {
            camera.reveal(frame, viewSize: viewSize)
        }
        return true
    }

    /// An arrow: the nearest card that way from the selection's centre. With
    /// nothing selected it travels on; with no card that way it is swallowed,
    /// because the writer pressed a key the canvas understood.
    private func selectNearest(_ arrow: CanvasArrow, from selection: CanvasSelection?,
                               viewSize: CGSize) -> Bool {
        guard let selection,
              let from = CanvasKeyboard.centre(of: selection, in: model.scene) else { return false }
        var excluding: CanvasNodeID?
        if case .node(let id) = selection { excluding = id }
        guard let target = CanvasKeyboard.nearest(from: from, toward: arrow, in: model.scene,
                                                  excluding: excluding),
              let frame = model.scene.node(target)?.frame else { return true }
        model.selection = .node(target)
        // `revision`, never `sceneRevision`: a selection is not structural.
        revision += 1
        camera.reveal(frame, viewSize: viewSize)
        model.scheduleSave()
        return true
    }

    // MARK: - Delete

    /// ⌫, from `CanvasEventNSView.keyDown`. The one thing the canvas has never
    /// had: 1C-a built `CanvasScene.remove`, its inverse and the "Delete Scrap"
    /// undo step and shipped no caller for any of them, so a stray double-click
    /// left an empty card that ⌘Z took back only until the writer clicked away.
    ///
    /// The region case is the one with a rule behind it: **deleting a region
    /// never deletes cards** — the canvas owns arrangement, not existence (spec
    /// §3.1, generalised). Its membership records die with it, which is all
    /// `CanvasScene.removeRegion` touches. **Deleting a line is the same rule in
    /// a second id space**: the relationship goes and both cards stay.
    ///
    /// Nothing selected is a no-op rather than a guess — and it says so, by
    /// returning **whether anything was actually deleted**. `CanvasEventNSView`
    /// sends the key on to `super` when this is `false`, so a ⌫ over an empty
    /// selection beeps rather than being silently swallowed; the reasoning is on
    /// `keyDown`. A selection that no longer resolves is the same answer for the
    /// same reason: nothing went, so nothing was used.
    ///
    /// **It refuses outright while any gesture is open, and that is a
    /// correctness guard rather than a nicety.** `CanvasUndo.beginGesture` takes
    /// no snapshot when it nests and `endGesture` registers nothing until depth
    /// reaches zero, so a delete opened inside somebody else's bracket cannot be
    /// taken back on its own — at best it collapses into that gesture under the
    /// wrong name, and if the bracket never closes it is not recoverable at all.
    /// Both states are reachable: press and hold on a card (which opens "Move
    /// Scrap") and press ⌫; or press ⌫ in the runloop turn after a double-click,
    /// before the editor has claimed first responder, while "Edit Scrap" is open
    /// — then quit, and `detach()` drops the stack with the card already written
    /// away. `test_backspaceBeforeTheEditorTakesFocusCannotLoseTheCardUnrecoverably`
    /// measured exactly that: the card and its words gone from disk with nothing
    /// that could have brought them back.
    ///
    /// Refusing rather than closing the bracket first is also the honest
    /// semantics: mid-gesture the writer is holding something, so what a delete
    /// means is genuinely ambiguous. Returning `false` sends the key to `super`,
    /// and the beep says so.
    func deleteSelection() -> Bool {
        guard !model.isInGesture else { return false }
        // Read-only (issue #44): the card arm's `withScene(persist: false)`
        // would remove the card from memory, unguarded by the model.
        guard CanvasEditGate.deletes(isReadOnly: model.isReadOnly) else { return false }
        switch model.selection {
        case .region(let id):
            guard model.scene.region(id) != nil else { return false }
            model.mutate("Delete Region") { $0.removeRegion(id) }
        case .node(let id):
            guard model.scene.node(id) != nil else { return false }
            // The writer cannot be standing in it — a single click both selected
            // it and left the open scrap — but an undo can have moved focus
            // since, and an editor bound to a node that no longer exists is the
            // state `.unenterableNode` already refuses to leave standing.
            if editingNodeID == id { editFocus.leaveTheOpenScrap() }
            // "Card" and not "Scrap": this arm deletes an item node too, and a
            // writer who removed a photograph read *Undo Delete Scrap*. The noun
            // is uniform across all three node steps for the reason recorded on
            // `gestureName`, which is where the argument lives.
            model.beginGesture("Delete Card")
            model.withScene(persist: false) { $0.remove(id) }
            model.removeScrapText(id)
            model.endGesture()
            // Another caller that does not bump the structural counter, for the
            // same reason as the rest of them: `model.bumpSceneRevision()` below
            // reaches the view through the mirror in `body`, so bumping here as
            // well rebuilds the whole accessibility tree twice for one ⌫. The
            // deleted card leaving that tree is what
            // `CanvasViewMountingEditingTests.test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain`
            // asserts, so the delivery of that single bump is pinned rather than
            // assumed.
            //
            // **No test can see this CALL today, and that is measured rather
            // than assumed** (mutation, 2026-07-28: removing it leaves the whole
            // mounting suite green). What it does that nothing observes is drop
            // the deleted node's `ScrapLayout` — the filter at the end of
            // `rebuildLayouts` — which otherwise keeps that scrap's whole
            // `NSTextStorage` alive until some later structural change happens
            // to run one.
            layoutPass.rebuildLayouts(bumpsStructuralCounter: false)
        case .line(let id):
            guard model.scene.line(id) != nil else { return false }
            // **A line delete never touches its cards.** The writer took back
            // the relationship, not the things related — the mirror of a card
            // delete, which DOES take its lines with it (`CanvasScene.remove`),
            // because a line to a card that is gone draws into nowhere. One
            // gesture either way, so one ⌘Z either way.
            model.mutate("Delete Line") { $0.removeLine(id) }
        case .none:
            return false
        }
        model.selection = nil
        // A delete IS a structural change. `CanvasView`'s own doc for
        // `sceneRevision` used to say deletion was absent from the list because
        // 1C-a had no delete path; this is the line that changes that.
        model.bumpSceneRevision()
        model.scheduleSave()
        return true
    }

    /// **Escape: the way out of the dim** (§4.1). Returns whether the canvas used
    /// the key — see `CanvasEventNSView.keyDown`.
    ///
    /// Two refusals, and neither is defensive:
    ///
    /// - **A mounted scrap keeps its Escape.** §4.1 rules that the canvas may
    ///   only see the key with no editor mounted, and the responder chain
    ///   delivers that on its own for as long as the editor holds first
    ///   responder. This guard covers the window it does not: a scrap can be open
    ///   while the event view still has the keyboard, which is the same window
    ///   `deleteSelection`'s `isInGesture` guard exists for.
    /// - **An undimmed board has nothing to leave**, so the key travels on.
    ///   Escape means something to a great many responders above this one and a
    ///   canvas that swallowed every one of them would look identical from here.
    ///
    /// It does not clear the canvas SELECTION, and that is what "the keyboard
    /// spelling of the project row" means taken literally: clicking that row
    /// leaves the selected card selected, so this must too. It asks the window to
    /// name the project and stops there — the dim, the standing text and the
    /// sweep's binding all follow from the subject, so there is exactly one
    /// thing to change.
    func escapeAsksForTheWholeBoard() -> Bool {
        guard editingNodeID == nil, subject.dimsTheBoard else { return false }
        selectTheProjectRow()
        return true
    }
}
