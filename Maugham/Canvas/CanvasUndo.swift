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
/// owner changes between plans: `CanvasView`'s `@State` in 1C-a, `CanvasModel`
/// in 1C-b Task 4. Only the closures get rebound; this class does not change.
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
/// `CanvasView.undoManager` for why, at length. Every gesture here is already
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
        guard before.scene != now.scene || before.scraps != now.scraps else { return }

        undoManager.beginUndoGrouping()
        register(before, name: name)
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
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
    /// `CanvasViewMountingTests.test_aPauseInsideAScrapEndsTheStepWhereTheWriterStopped`
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
        return before.scene != now.scene || before.scraps != now.scraps
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
    /// `UndoManager`, so ⇧⌘Z reads "Redo Move Scrap" and the step keeps its name
    /// however many times the writer cycles it.
    private func register(_ snapshot: Snapshot, name: String) {
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
    static func hasGoneIdle(since last: Date?, now: Date) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) >= idleSeconds
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
