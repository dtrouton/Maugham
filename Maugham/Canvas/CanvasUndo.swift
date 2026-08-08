import AppKit

/// Undo for the canvas.
///
/// Spec §10 left this open. The answer is a canvas-scoped `UndoManager`, NOT the
/// op log, and the reasoning must survive:
///
/// ADR 0023's unified undo appends COMPENSATING OPS to the op log. Canvas
/// geometry is derived state that may be deleted without loss (spec §8).
/// Putting it in the op log would make the sidecar the only record of a move —
/// no longer derived — which contradicts §8 directly. ⌘Z already means "undo
/// what is in front of you"; in the editor it runs the editor's own undo
/// manager. This is the same rule, not a new one.
///
/// **Snapshots, not per-property inverses.** 1C-b's region drags mutate a
/// region's frame AND every resident's origin; recording per-property inverses
/// for that is how you get a half-undone drag. `CanvasScene` is a value type
/// holding hundreds of nodes, so a snapshot per gesture is cheap and exactly
/// correct.
///
/// **The state is reached through two closures rather than owned**, because the
/// owner changed between plans: `CanvasView`'s `@State` in 1C-a, `CanvasModel`
/// since 1C-b Task 3. Only the closures were rebound; this class did not change.
///
/// **Scrap TEXT and scrap GEOMETRY share ONE stack, and only this class writes
/// to it.** The mounted `NSTextView` has `allowsUndo == false` (see
/// `ScrapLayout.makeEditor`) and registers nothing; `CanvasView` hands the raw
/// manager to `CanvasEventView`, which vends it to the responder chain so ⌘Z
/// with nothing focused reaches it, and hands THIS OBJECT to `ScrapEditorHost`,
/// whose container implements `undo:`/`redo:` itself — because a text view with
/// `allowsUndo` false returns a nil `undoManager` and the chain never arrives
/// (measured; see `ScrapEditorContainer`). The two routes differ on purpose: with
/// a scrap focused there is an open gesture holding the run of typing in
/// progress, and only `undo()` below closes it first. With nothing focused there
/// is no open gesture to close — every click runs `commitActiveEdit` — so the
/// bare manager is the whole of it. If the text view registered too, one change
/// would land twice — and its copy would target an `NSTextStorage` that the snapshot's
/// `rebuildLayouts()` has replaced, so the second ⌘Z would appear to do nothing.
///
/// **Granularity inside a scrap is the SENTENCE, not the visit and not the
/// word.** The outer bracket is focus; `breakGesture()` supplies the inner ones,
/// driven by `ScrapUndoBeat` — a finished sentence, or a beat of stillness.
/// Per-word is only reachable by giving the text view `allowsUndo`, which is the
/// double-registration defect above, and a break per word would also mean a
/// whole-scene snapshot per word.
///
/// **`beginGesture` opens NO `UndoManager` group**, and that is deliberate twice
/// over:
///
/// - `UndoManager` pushes a closed group whether or not anything was registered
///   inside it. Opening one at `beginGesture` would leave a step behind after a
///   gesture that changed nothing, and ⌘Z after a stray click would undo the
///   writer's last REAL edit while appearing to do nothing.
/// - An "Edit Scrap" gesture spans as many events as the writer types
///   keystrokes, so a group opened at `beginGesture` is a bracket held open
///   across events — stranded half-open by anything that tears the surface down
///   mid-visit, a persona switch above all. (Under `groupsByEvent`, which the
///   canvas turns OFF, it could not span them at all.)
///
/// So `beginGesture` takes a snapshot, and `endGesture` opens/registers/names/
/// closes synchronously in one go.
///
/// **The manager this is given has `groupsByEvent == false`** — see
/// `CanvasModel.undoManager` for why, at length. Every gesture here is already
/// grouped explicitly, so one gesture is one ⌘Z with no implicit group involved,
/// and tests exercise the manager production ships rather than a second
/// configuration of it.
///
/// **Camera changes are NOT undoable** — panning and zooming are navigation, and
/// undoing a pan would be baffling.
///
/// **The two closures are a retain cycle and the owner must break it.** They
/// capture whoever owns the state, which owns this object — exactly the shape
/// `CanvasStore.beforeFlush` has, and `CanvasView.onDisappear` clears both for
/// the same reason it clears that one. `UndoManager.registerUndo(withTarget:)`
/// retains this object too, so the owner also clears the stack.
final class CanvasUndo {

    typealias Snapshot = (scene: CanvasScene, scraps: [CanvasNodeID: String])

    /// Read the current state. Set by the owner.
    var readSnapshot: (() -> Snapshot)?
    /// Put a snapshot back. Set by the owner.
    var applySnapshot: ((Snapshot) -> Void)?

    private let undoManager: UndoManager
    private var depth = 0
    private var snapshotAtGestureStart: Snapshot?
    private var gestureName = ""

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    var isInGesture: Bool { depth > 0 }

    /// Open a gesture: take a snapshot, remember the name. **No `UndoManager`
    /// call happens here** — see the class doc. Nested calls are absorbed, so a
    /// gesture arriving mid-gesture cannot leave the manager unbalanced.
    func beginGesture(_ name: String) {
        depth += 1
        guard depth == 1 else { return }
        snapshotAtGestureStart = readSnapshot?()
        gestureName = name
    }

    /// Close the gesture, registering an undo only if the state actually moved.
    /// The group is opened HERE and closed on the next line, so it never spans an
    /// event boundary and an unchanged gesture pushes nothing at all.
    func endGesture() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }

        let name = gestureName
        defer {
            snapshotAtGestureStart = nil
            gestureName = ""
        }
        guard let before = snapshotAtGestureStart, let now = readSnapshot?() else { return }
        guard Self.stateMoved(from: before, to: now) else { return }

        undoManager.beginUndoGrouping()
        register(before, name: name)
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    /// Rename the gesture already open, for the case where what the writer did
    /// is only knowable at the END of it.
    ///
    /// **One caller, and it is the sweep** (persona-shell §4.1). A press opens
    /// the bracket the moment `begin` picks a mode, and at that instant a sweep
    /// is a sweep; whether it will mint a region or bind the ones it passes over
    /// depends on where the pointer eventually goes and on what the tree names.
    /// So "New Region" is fixed before the answer exists, and a step called
    /// *Undo New Region* that took back a BINDING would describe an act the
    /// writer did not perform.
    ///
    /// **It renames, it does not open, close or register.** Nothing about the
    /// bracket moves, so this cannot be a route around `mutate` /
    /// `mutateFromOutsideTheCanvas` — a caller with no gesture of its own gets
    /// nothing at all, rather than a step of its own under a borrowed name.
    ///
    /// A NESTED gesture is left alone for the same reason `breakGesture`
    /// declines there: the name belongs to whoever opened the outer bracket, and
    /// renaming it from inside would relabel a step they are still building.
    func renameGesture(_ name: String) {
        guard depth == 1 else { return }
        gestureName = name
    }

    /// Close the open gesture and immediately open another under the same name.
    ///
    /// This is what gives a long visit to a scrap more than one ⌘Z. `endGesture`
    /// registers nothing when the snapshot is unchanged, so a break at a moment
    /// nothing was typed costs a snapshot read and leaves the stack alone.
    ///
    /// A no-op outside a gesture, and a no-op inside a NESTED one — splitting an
    /// outer gesture from within an inner one would close a bracket the caller
    /// still believes it holds.
    func breakGesture() {
        guard depth == 1 else { return }
        let name = gestureName
        endGesture()
        beginGesture(name)
    }

    /// `beginGesture` / body / `endGesture`, for the common one-shot case.
    func mutate(_ name: String, _ body: () -> Void) {
        beginGesture(name)
        body()
        endGesture()
    }

    /// A one-shot change made from OUTSIDE the canvas — the region inspector, in
    /// the window's other column — which must be its own step even though the
    /// canvas may be holding a gesture open.
    ///
    /// **Why `mutate` is wrong here, and silently.** A visit to a scrap holds
    /// "Edit Scrap" open for as long as focus is in it, and *nothing on the
    /// inspector's side of the window closes it*: `CanvasView.commitActiveEdit`
    /// runs from `handleClick`, which only fires for clicks on the canvas. And a
    /// double-click never reassigns `selection`, so a region selected a moment
    /// ago is still what the inspector is showing. Rename it there and through
    /// `mutate` the rename nests: depth 2 takes no snapshot, depth 1 registers
    /// nothing, and **the rename is not on the undo stack at all.** Worse than
    /// absent — the open gesture's baseline predates it, so the next thing the
    /// writer types carries the rename into a step called "Edit Scrap", and a ⌘Z
    /// aimed at a sentence takes the region's name with it. Quit without
    /// returning to the canvas and `release()` drops the lot.
    ///
    /// **The repro is a double-click on the region's own CHROME BAR**, and it has
    /// to be — a double-click on a CARD cannot reach this state. AppKit delivers
    /// `clickCount: 1` on the first mouse-down of a double-click
    /// (`CanvasEventNSView.applyMouseDown` says so outright), and that first
    /// click runs `selection = scene.selectionTarget(at:)`, which resolves the card —
    /// so the region is deselected before "Edit Scrap" ever opens and the
    /// inspector is showing its empty state. On the chrome bar: click 1 selects
    /// the region; click 2 finds no node under the point, takes the
    /// `.emptyCanvas` branch, mints a scrap and opens "Edit Scrap" — and the
    /// `guard clickCount >= 2` returns before the selection is ever reassigned.
    ///
    /// Second path to the same state: an uncommitted rename in the label field,
    /// committed on focus loss by the very click that opens the gesture.
    ///
    /// `CanvasViewMountingEditingTests` drives both the working repro and the
    /// one that does not work, because **a repro nobody can reproduce is worse than
    /// none** — the next author tries it, fails, and concludes the rule is
    /// stale.
    ///
    /// This is the same close-run-reopen `undo()` performs, for the same reason:
    /// the run of typing in progress becomes its own step first, under its own
    /// name, so what is registered here is only what the inspector did — and the
    /// visit resumes, so the rest of the sentence is still bracketed.
    ///
    /// A NESTED gesture (depth > 1) still falls through to plain nesting, which
    /// is right: `closeResumableGesture` declines there because closing one
    /// bracket would leave whoever opened it holding one that no longer exists.
    /// Depth only exceeds 1 inside synchronous canvas code, where no click on
    /// another column can arrive.
    func mutateFromOutsideTheCanvas(_ name: String, _ body: () -> Void) {
        let reopen = closeResumableGesture()
        mutate(name, body)
        if let reopen { beginGesture(reopen) }
    }

    // MARK: - ⌘Z and ⇧⌘Z

    /// **⌘Z goes through here, not through the manager**, and the difference is
    /// the run of typing the writer is in the middle of.
    ///
    /// A visit to a scrap holds an OPEN gesture for as long as focus is in it,
    /// and everything typed since the last sentence or pause lives in that
    /// gesture and NOWHERE ELSE — `endGesture` is what turns it into a step.
    /// Undoing the manager directly therefore steps straight over it to the one
    /// before: type a sentence, pause, type another, press ⌘Z, and both vanish.
    /// Measured that way in
    /// `CanvasViewMountingEditingTests.test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped`
    /// before this existed. So the open gesture is closed FIRST — which is what
    /// AppKit does with its own event group before servicing an undo.
    ///
    /// Closing it from `NSUndoManagerWillUndoChange` was the other candidate and
    /// is worse: by then the manager is already undoing, and a registration made
    /// mid-undo becomes a REDO. Here the close happens before `undo()` is called
    /// at all.
    ///
    /// The gesture reopens afterwards under its own name, because the writer is
    /// still in the scrap and still typing; left closed, nothing would bracket
    /// the rest of the visit and the words after the ⌘Z would be unundoable.
    func undo() {
        let reopen = closeResumableGesture()
        undoManager.undo()
        if let reopen { beginGesture(reopen) }
    }

    /// ⇧⌘Z, symmetrically. Closing the open gesture first is not just symmetry:
    /// if the writer typed after undoing, that typing is a new step and
    /// `UndoManager` is entitled to drop the redo stack when it is registered —
    /// which is correct, and only happens at all if the close comes first. Typed
    /// nothing, and `endGesture` registers nothing and the redo survives.
    func redo() {
        let reopen = closeResumableGesture()
        undoManager.redo()
        if let reopen { beginGesture(reopen) }
    }

    /// True when ⌘Z would do something — **including when the only thing to take
    /// back is the run still inside the open gesture**, which the manager knows
    /// nothing about until `undo()` closes it. Without that second term the Edit
    /// menu greys Undo out while the writer is halfway through the first sentence
    /// they have typed into a scrap, and ⌘Z does nothing at all.
    var canUndo: Bool { undoManager.canUndo || openGestureHasChanges }

    /// No pending term: a gesture that has not been closed cannot be redone, and
    /// closing it would DROP the redo stack rather than add to it.
    var canRedo: Bool { undoManager.canRedo }

    /// What the Edit menu should read. A pending gesture has no action name yet —
    /// it is not a step until it closes — so while one is the only thing to undo
    /// the item reads a bare "Undo". Enabled and honestly unnamed beats greyed
    /// out and wrong.
    var undoMenuItemTitle: String { undoManager.undoMenuItemTitle }
    var redoMenuItemTitle: String { undoManager.redoMenuItemTitle }

    /// Whether closing the open gesture right now would register a step.
    private var openGestureHasChanges: Bool {
        guard depth == 1, let before = snapshotAtGestureStart,
              let now = readSnapshot?() else { return false }
        return Self.stateMoved(from: before, to: now)
    }

    /// Did anything the writer could see actually change?
    ///
    /// **Extracted because it must be asked identically in two places** — here,
    /// through `canUndo`'s pending term, and in `endGesture`, which is what
    /// actually registers. Written out twice they could drift, and the drift has
    /// a direction: a `canUndo` that says yes where `endGesture` says no is an
    /// enabled Edit-menu item and a ⌘Z that does nothing, which is the exact
    /// trust loss this whole class exists to prevent.
    private static func stateMoved(from before: Snapshot, to now: Snapshot) -> Bool {
        before.scene != now.scene || before.scraps != now.scraps
    }

    /// Close one open gesture and hand back its name so the caller can reopen it.
    ///
    /// `nil` when nothing is open — and deliberately `nil` for a NESTED gesture
    /// too: closing one bracket there would leave whoever opened it holding a
    /// bracket that no longer exists. The re-baseline inside `register` is what
    /// covers an undo serviced while a gesture is still open, which is exactly
    /// the case this declines to handle.
    private func closeResumableGesture() -> String? {
        guard depth == 1 else { return nil }
        let name = gestureName
        endGesture()
        return name
    }

    /// Deliberately does nothing. Named rather than absent so the next author
    /// sees the decision instead of assuming an omission.
    func noteCameraChanged() { }

    /// Drop the closures and the stack. The owner calls this at teardown: the
    /// closures capture the owner, which owns this object, and the manager
    /// retains this object for every step on its stack — three edges of the same
    /// cycle. Without it a closed canvas keeps its `CanvasStore` alive, which is
    /// the leak `CanvasView.onDisappear` already clears `beforeFlush` for.
    func release() {
        readSnapshot = nil
        applySnapshot = nil
        // `removeAllActions` inside an open group corrupts grouping state
        // (ADR 0023's corollary), and mid-undo is exactly when one is open.
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return }
        undoManager.removeAllActions()
    }

    /// Register `snapshot` as the state to return to. On undo it re-registers
    /// the state it replaced, which is what gives redo for free — and every
    /// re-registration lands inside the group `UndoManager` opens around an
    /// undo, so the redo is one step too.
    ///
    /// `name` is carried through and re-applied rather than left to
    /// `UndoManager`, so ⇧⌘Z reads "Redo Move Card" and the step keeps its name
    /// however many times the writer cycles it.
    private func register(_ snapshot: Snapshot, name: String) {
        // The canvas's manager has `groupsByEvent` off (see `CanvasView`), and
        // that turns "registered outside a group" from something `UndoManager`
        // quietly absorbs into something it RAISES. Both routes here are inside
        // one: `endGesture` opens a group on the line above, and the re-entrant
        // call below runs inside the group `UndoManager` opens around an undo.
        // A third caller that is not would crash the app on the writer's next
        // edit, so it fails here, in Debug, at the moment it is written.
        // `CanvasCompositionTests.test_theCanvasRegistersUndoInExactlyOnePlace`
        // is the other half — this one guards HOW, that one guards WHO.
        assert(undoManager.groupingLevel > 0,
               "CanvasUndo.register ran outside an undo group — with "
               + "groupsByEvent off, UndoManager raises on that")
        undoManager.registerUndo(withTarget: self) { target in
            // `readSnapshot` is OPTIONAL — an unwired recorder must record
            // nothing rather than trap.
            guard let current = target.readSnapshot?() else { return }
            target.register(current, name: name)
            target.undoManager.setActionName(name)
            target.applySnapshot?(snapshot)

            // The writer pressed ⌘Z with a scrap still focused, so a gesture is
            // open and its baseline was captured BEFORE this undo ran. Left
            // alone, `endGesture` would diff against that stale baseline and
            // register a step whose UNDO re-applies exactly what the writer just
            // undid: type in A, click into B, ⌘Z (A reverts), type in B, click
            // out — and the next ⌘Z brings A's discarded text back. Re-baseline
            // on the state the undo produced.
            if target.depth > 0 {
                target.snapshotAtGestureStart = target.readSnapshot?()
            }
        }
    }
}

/// When a run of typing inside one scrap becomes its own undo step.
///
/// Pure, so the policy is testable without a run loop, a timer or a text view.
/// `CanvasView.syncActiveEdit` asks these two questions on every change and
/// calls `CanvasUndo.breakGesture()` when either says yes.
///
/// Neither rule needs a timer: an idle beat is noticed retroactively at the next
/// keystroke, which is the only moment it can matter.
enum ScrapUndoBeat {

    /// Stillness this long ends a step. Long enough that a pause for thought
    /// mid-sentence is not chopped up, short enough that coming back to a scrap
    /// after a break does not extend the previous ⌘Z.
    static let idleSeconds: TimeInterval = 1.5

    /// Characters that end a sentence for this purpose. Over-eager on "Mr." and
    /// "e.g.", and that is fine — an extra boundary gives the writer a finer
    /// ⌘Z, never a coarser one.
    private static let terminators: Set<Character> = [".", "!", "?"]

    /// True when the writer has been still long enough that the run of typing
    /// before the pause should stand as its own step. Asked BEFORE the new
    /// keystroke is folded in, so the step that closes ends at the pause.
    static func hasGoneIdle(since last: Date?, now: Date,
                            idleAfter: TimeInterval = ScrapUndoBeat.idleSeconds) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) >= idleAfter
    }

    /// True when this edit just finished a sentence — the text now ends in a
    /// terminator and did not before. Asked AFTER the keystroke is folded in, so
    /// the full stop belongs to the step it closes.
    ///
    /// Deliberately blind to edits made away from the end of the text: the idle
    /// beat covers those, and a rule that fired on any terminator anywhere would
    /// fire on a deletion too.
    static func completesASentence(before: String, after: String) -> Bool {
        guard let now = after.last, terminators.contains(now) else { return false }
        guard let previous = before.last else { return true }
        return !terminators.contains(previous)
    }
}
