import Foundation
import MaughamCore
import AppKit

// EditorCoordinator — the Insert menu (plan 3a Task 4), and Route A, the one
// way a command edits the text.
extension EditorCoordinator {
    // MARK: - Route A

    /// **Route A: a command's edit, as one native undo step.** The one helper
    /// every editor command that writes text goes through — Insert Table and
    /// Insert Footnote here, plan 3a's table re-align (Task 5) and figure
    /// insert (Task 6) after them. It:
    ///
    /// 1. replaces `range` with `replacement` in ONE `replaceCharacters`,
    ///    behind `shouldChangeText` — so the membrane (`shouldChangeTextIn`,
    ///    `EditorEditPolicy.allowsTextMutation`) refuses it in a read-only
    ///    posture, translation review or review mode, and AppKit registers it
    ///    as one undo action;
    /// 2. keeps the writer's typing a step of its own on either side: AppKit
    ///    ends typing coalescing at a non-typing `shouldChangeText`, so no
    ///    `breakUndoCoalescing` is needed (measured with and without —
    ///    `InsertCommandTests.test_typingTheNoteAfterTheInsertIsItsOwnUndoStep`);
    /// 3. lets `didChangeText` run the ordinary typing path
    ///    (`textDidChange` → the binding → `Document.setFullText`), with no
    ///    `applyExternalText` (tripwire 7) and no Route B undo wipe (ADR 0023 D1);
    /// 4. places `selection` after `didChangeText` returns. `textDidChange`'s
    ///    cursor restore runs synchronously inside `didChangeText`, so a
    ///    selection set after it is final — no skip flag, and no next-runloop
    ///    re-assert (one would race fast typing, as `textDidChange` documents);
    ///    with typewriter scroll on, the caret is centred;
    /// 5. names the undo step `actionName` ("Undo Insert Table");
    /// 6. **closes its own undo group when it runs outside any event** (Task 6
    ///    fix round 1, I2): a figure lands in a Task continuation and a table
    ///    tidy on the next runloop, where no event's group is open. With
    ///    `groupsByEvent` the implicit group opened there stays open until the
    ///    NEXT event ends, so the writer's next typing would join this step
    ///    (`CanvasModel` records the same trap). At `groupingLevel == 0` the
    ///    edit is bracketed in a group of its own; inside an event (a menu
    ///    item, a key) the event's group is the step, as before
    ///    (`FigureCommandTests.test_anAsyncFigureIsItsOwnUndoStepWithTheDefaultGrouping`).
    ///
    /// `range` and `selection` are UTF-16 ranges; `selection` is in the text
    /// AFTER the replace. Returns false — changing nothing — when the editor
    /// is detached, the range is out of bounds, or the membrane refuses.
    @discardableResult
    func applyCommandEdit(replacing range: NSRange, with replacement: String,
                          selecting selection: NSRange, actionName: String) -> Bool {
        guard !isDetached, let textView, let storage = textView.textStorage,
              range.location >= 0, NSMaxRange(range) <= storage.length else { return false }
        // The membrane's predicate first: an ended EMPTY group is not dropped,
        // so a refusal must not open one (the refusal tests count no step).
        // `shouldChangeText` below still asks the delegate, as before.
        guard commandMayWrite else { return false }
        // Step 6, around `shouldChangeText` because that is where the text
        // view registers the step. With `groupsByEvent` off for the bracket:
        // left on, `beginUndoGrouping` at level 0 first opens the implicit
        // event group, which is still open after ours ends — measured, the trap
        // this step exists for.
        let undo = textView.undoManager
        let ownGroup = undo.map { $0.groupingLevel == 0 } ?? false
        let groupedByEvent = undo?.groupsByEvent ?? false
        if ownGroup {
            undo?.groupsByEvent = false
            undo?.beginUndoGrouping()
        }
        defer {
            if ownGroup {
                undo?.endUndoGrouping()
                undo?.groupsByEvent = groupedByEvent
            }
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        undo?.setActionName(actionName)
        let location = min(max(0, selection.location), storage.length)
        let target = NSRange(location: location,
                             length: min(max(0, selection.length), storage.length - location))
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        if typewriterScroll { scrollSelectionToVerticalCenter(in: textView) }
        textView.window?.makeFirstResponder(textView)
        return true
    }

    /// Whether a command may write text now: the question the membrane
    /// (`shouldChangeTextIn`) asks a keystroke, plus a read-only recovery
    /// view's `isEditable`. Asked before a command opens an undo group, and
    /// before a figure copies anything.
    var commandMayWrite: Bool {
        (textView?.isEditable ?? false)
            && EditorEditPolicy.allowsTextMutation(isReviewMode: isReviewMode,
                                                   lockEditing: lockEditing,
                                                   isTranslationReview: isTranslationReview)
    }

    /// `applyCommandEdit` for a `ReportInsert.Edit`.
    @discardableResult
    func applyCommandEdit(_ edit: ReportInsert.Edit, actionName: String) -> Bool {
        applyCommandEdit(replacing: edit.replacedRange, with: edit.replacement,
                         selecting: edit.selection, actionName: actionName)
    }

    // MARK: - The Insert menu

    /// The scope context the Insert observers filter against: the key-window
    /// context every window command uses, and only on a manuscript surface.
    func insertCommandContext() -> EventReceiverContext? {
        guard answersInsertCommands else { return nil }
        return receiverContext(.keyWindow)
    }

    /// Whether this editor makes figures (plan 3a Task 6,
    /// `EditorCoordinator+Figure.swift`): a surface that answers the Insert
    /// menu — a Markdown manuscript, which only `EditorHost` says — whose host
    /// handed it an importer. A research note, a statement and a screenplay
    /// say no, so their drop and paste are what they always were.
    var answersFigures: Bool {
        answersInsertCommands && figureImporter != nil && !isDetached
    }

    /// Insert ▸ Table (⌘⇧T, R-3a-5): a 3-column table on a block of its own
    /// at the caret (after the selection), its first header cell selected.
    func insertTable() {
        guard answersInsertCommands, let textView else { return }
        let at = NSMaxRange(textView.selectedRange())
        let blocks = MarkdownTokenizer.tableBlockRange(containing: at, in: lastTokens)
            .map { [$0] } ?? []
        // Asked per command, never per keystroke: the labels the project's
        // OTHER manuscript documents define (a Report refuses a duplicate).
        let elsewhere = projectLabelsElsewhere?() ?? []
        applyCommandEdit(ReportInsert.tableEdit(in: textView.string, at: at, tableBlocks: blocks,
                                                labelsElsewhere: elsewhere),
                         actionName: "Insert Table")
    }

    /// Insert ▸ Footnote (⌘⇧N, R-3a-6): `[^n]` at the caret (after the
    /// selection) and its `[^n]: ` definition after the paragraph, the caret
    /// waiting there.
    func insertFootnote() {
        guard answersInsertCommands, let textView else { return }
        let at = NSMaxRange(textView.selectedRange())
        applyCommandEdit(ReportInsert.footnoteEdit(in: textView.string, at: at),
                         actionName: "Insert Footnote")
    }
}
