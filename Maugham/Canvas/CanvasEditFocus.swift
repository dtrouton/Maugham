import SwiftUI

/// `CanvasView`'s open scrap: folding the writer's words into the model, the
/// outer undo boundary when focus leaves, and leaving the scrap — over bindings
/// to the view's own `@State`.
///
/// Built fresh per call by `CanvasView.editFocus` and never stored; built
/// nowhere else (tripwire 32's surface census).
@MainActor
struct CanvasEditFocus {
    let model: CanvasModel
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var caretIndex: Int?
    @Binding var straighten: CanvasFocusStraighten
    @Binding var lastKeystrokeAt: Date?
    @Binding var layouts: [CanvasNodeID: ScrapLayout]
    @Binding var revision: Int

    // MARK: - The writer's words

    /// Fold the live editor's text back into the model and re-measure the card.
    ///
    /// **Called on EVERY keystroke** (`ScrapEditorHost.onTextChanged`), from
    /// `.onDisappear`, and from `CanvasStore.beforeFlush`. Typing mutates the
    /// `NSTextStorage` inside `ScrapLayout` in place; until this runs, `scraps`
    /// still holds the text as it was before the writer typed, the queued save
    /// payload is stale, and the drawn card never grows past the height it had
    /// when it was last measured. Quit at that moment and the scrap comes back
    /// empty — the words are safe is the one promise this surface cannot break.
    ///
    /// It folds the string and nothing else. `onTextChanged` fires synchronously
    /// inside `textDidChange`, so rebuilding layouts from here would replace an
    /// `NSTextStorage` from inside its own text view's change notification.
    ///
    /// Pushes no undo step of its OWN, deliberately — one per keystroke is the
    /// other failure. What it does instead is move the INNER undo boundaries
    /// inside the open "Edit Scrap" gesture, and **only when the change came from
    /// a real keystroke**:
    ///
    /// - **The idle beat is asked BEFORE the fold**, so the step that closes ends
    ///   where the writer actually stopped rather than one character into what
    ///   they typed next.
    /// - **The sentence rule is asked AFTER the fold**, so the full stop belongs
    ///   to the step it closes rather than opening the following one.
    ///
    /// Swapping either would be invisible in the code and obvious to a writer:
    /// ⌘Z after a pause would take back one extra character, and ⌘Z after a
    /// sentence would leave the full stop stranded at the head of the next step.
    ///
    /// `fromKeystroke` is `false` by default because the other two callers —
    /// `.onDisappear` and `CanvasStore.beforeFlush` — run at teardown and at app
    /// quit. A writer who paused for two seconds and then quit would otherwise
    /// trip the idle break at `beforeFlush`, closing a step and REOPENING a
    /// gesture on a view that is going away: a half-open bracket, arriving from
    /// the save path instead of the focus path. Neither of them may move a
    /// boundary, and neither has to say so.
    func syncActiveEdit(fromKeystroke: Bool = false) {
        guard let id = editingNodeID, let layout = layouts[id] else { return }
        // Read once: `ScrapLayout.text` bridges out of an `NSTextStorage` on
        // every access, and this runs on every keystroke.
        let updated = layout.text
        guard model.scraps[id] != updated else { return }
        let previous = model.scraps[id] ?? ""
        let now = Date()

        // BEFORE the fold — see the doc above.
        if fromKeystroke, ScrapUndoBeat.hasGoneIdle(since: lastKeystrokeAt, now: now,
                                                    idleAfter: model.undoIdleInterval) {
            model.breakGesture()
        }

        model.withScene(persist: false) {
            $0.setCachedHeight(CanvasScrapMeasure.height(of: layout), for: id)
        }
        // The fold, and the save that carries both it and the height above.
        model.setScrapText(updated, for: id)
        revision += 1

        // AFTER the fold — see the doc above.
        if fromKeystroke,
           ScrapUndoBeat.completesASentence(before: previous, after: updated) {
            model.breakGesture()
        }
        if fromKeystroke { lastKeystrokeAt = now }
    }

    /// The outer undo boundary: focus is leaving the scrap.
    ///
    /// `syncActiveEdit` has folded the text in on every keystroke and broken the
    /// gesture at each sentence and each pause; this closes whatever is still
    /// open. `endGesture` registers nothing when the state has not moved, so
    /// clicking in and straight back out leaves no step behind — and it is a
    /// no-op outside a gesture, which is what makes it safe at the head of
    /// `handleClick`, where most clicks have nothing focused at all.
    ///
    /// Plus the accessibility tree, whose synthetic element for this scrap has
    /// been stale for the whole visit — deliberately, because the real
    /// `NSTextView` was the accessible thing while the writer was in it.
    ///
    /// **That bump is guarded on there having BEEN a visit, and the guard is the
    /// point of it.** This runs at the head of `handleClick`, and
    /// `CanvasEventNSView.applyMouseDown` emits `onClick` before `onDrag(.began)`
    /// — so bumping unconditionally rebuilds the whole tree on every mouse-down
    /// the canvas ever sees, including the press that begins a drag, which is the
    /// moment the surface most needs to feel instant. With nothing focused there
    /// is nothing to fold in either: `syncActiveEdit` returns on its first guard
    /// and `endGesture` registers nothing. Every path that changes the scene with
    /// no scrap focused bumps the counter where the change happens — `load` and
    /// the create branch through `rebuildLayouts()`, the two `.ended` branches of
    /// `handleDrag`, and a coast at `.began` or at rest — so nothing depends on
    /// this one to notice a change it did not make.
    func commitActiveEdit() {
        syncActiveEdit()
        model.endGesture()
        lastKeystrokeAt = nil
        if editingNodeID != nil { model.bumpSceneRevision() }
    }

    /// Focus leaves the canvas's open scrap: unmount the editor and let the card
    /// settle back over ~120 ms. `isSettled` is false the moment focus leaves —
    /// it means "every card is at ITS target", not "every progress value is 1" —
    /// so the clock keeps running until it lands.
    func leaveTheOpenScrap() {
        editingNodeID = nil
        caretIndex = nil
        straighten.focus(nil)
    }
}
