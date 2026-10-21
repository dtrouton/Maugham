import Foundation
import MaughamCore
import AppKit

// EditorCoordinator — the Insert menu (plan 3a Task 4), and Route A, the one
// way a command edits the text.
extension EditorCoordinator {
    /// Whether this surface draws resolved labels and problem marks (plan 3b
    /// Task 6, `ReferenceLabelOverlay`, `ManuscriptChecks`): a manuscript's
    /// prose editor with the window's index (only `EditorHost` builds one and
    /// sets `answersInsertCommands`). A research note, a statement and a
    /// screenplay get neither.
    var showsReferenceMarks: Bool {
        answersInsertCommands && referenceIndex != nil && mode is ProseMode && !isDetached
    }

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
    /// 6. **brackets the edit in an undo group of its own whenever none is
    ///    open** (Task 6 fix rounds 1–2, I2). `NSUndoManager` opens its
    ///    implicit event group LAZILY, at the first registration — so
    ///    `groupingLevel` is usually 0 inside a key or menu event as well as
    ///    in a Task continuation (a figure) or on the next runloop (a table
    ///    tidy), and the bracket runs, synchronously, in all of them. That is
    ///    safe because each caller makes ONE registration per event, so the
    ///    bracket is exactly the step the event would have been. Outside an
    ///    event it is what keeps the step closed: an implicit group opened
    ///    there stays open until the NEXT event ends, and the writer's next
    ///    typing would join it (`CanvasModel` records the same trap;
    ///    `FigureCommandTests.test_anAsyncFigureIsItsOwnUndoStepWithTheDefaultGrouping`).
    ///
    /// `range` and `selection` are UTF-16 ranges; `selection` is in the text
    /// AFTER the replace. Returns false — changing nothing — when the editor
    /// is detached, the range is out of bounds, or the membrane refuses.
    ///
    /// **`landing: .deferred`** is for an edit that lands after the event that
    /// asked for it (an async figure, whole-branch review I2). It never takes
    /// the focus, and when the writer has moved on — the text view is not the
    /// first responder, or `writerMoved` (the caller's reading of the
    /// selection or text since the request) — it keeps the writer's own
    /// selection, shifted through the edit, and does not scroll. Otherwise it
    /// selects `selection`, as the immediate landing does.
    @discardableResult
    func applyCommandEdit(replacing range: NSRange, with replacement: String,
                          selecting selection: NSRange, actionName: String,
                          landing: CommandLanding = .immediate) -> Bool {
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
        // A command's edit is never typing: the completion trigger reads this
        // (`noteEditForCompletion`) through `shouldChangeTextIn` and `textDidChange`.
        isApplyingCommandEdit = true
        defer { isApplyingCommandEdit = false }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        let writersSelection = textView.selectedRange()
        let keepsWritersSelection: Bool
        switch landing {
        case .immediate: keepsWritersSelection = false
        case .deferred(let writerMoved):
            keepsWritersSelection = writerMoved || textView.window?.firstResponder !== textView
        }
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        undo?.setActionName(actionName)
        if keepsWritersSelection {
            let kept = Self.selection(writersSelection, shiftedByReplacing: range,
                                      withLength: (replacement as NSString).length)
            let location = min(max(0, kept.location), storage.length)
            textView.setSelectedRange(NSRange(
                location: location, length: min(kept.length, storage.length - location)))
            return true
        }
        let location = min(max(0, selection.location), storage.length)
        let target = NSRange(location: location,
                             length: min(max(0, selection.length), storage.length - location))
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        if typewriterScroll { scrollSelectionToVerticalCenter(in: textView) }
        if case .immediate = landing { textView.window?.makeFirstResponder(textView) }
        return true
    }

    /// How a Route A edit lands (`applyCommandEdit`).
    enum CommandLanding: Equatable {
        /// In the event that asked for it: select, scroll, take the focus.
        case immediate
        /// After the event (an async figure): never take the focus; keep the
        /// writer's selection when they have moved on.
        case deferred(writerMoved: Bool)
    }

    /// `selection` (in the text before the edit) carried through replacing
    /// `range` with `length` characters: after the edit it shifts, before it
    /// stays, and a selection the edit overlapped collapses to the edit's end.
    nonisolated static func selection(_ selection: NSRange, shiftedByReplacing range: NSRange,
                                      withLength length: Int) -> NSRange {
        let delta = length - range.length
        if selection.location >= NSMaxRange(range) {
            return NSRange(location: selection.location + delta, length: selection.length)
        }
        if NSMaxRange(selection) <= range.location { return selection }
        return NSRange(location: range.location + length, length: 0)
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
    func applyCommandEdit(_ edit: ReportInsert.Edit, actionName: String,
                          landing: CommandLanding = .immediate) -> Bool {
        applyCommandEdit(replacing: edit.replacedRange, with: edit.replacement,
                         selecting: edit.selection, actionName: actionName, landing: landing)
    }

    // MARK: - The Insert menu

    /// The scope context the Insert observers filter against: the key-window
    /// context every window command uses, only on a manuscript surface, and
    /// only while no OTHER text input holds the window's focus (whole-branch
    /// review M1): with a statement, a research note or an inspector field
    /// focused, the command is not the manuscript's, and must neither write
    /// into it nor pull the focus over. The manuscript focused, or a non-text
    /// view (the binder), still answers.
    func insertCommandContext() -> EventReceiverContext? {
        guard answersInsertCommands, !anotherTextInputHasTheFocus else { return nil }
        return receiverContext(.keyWindow)
    }

    /// Whether the window's first responder is a text view other than this
    /// editor's: a sibling `EditorSurface`, or a field's field editor.
    var anotherTextInputHasTheFocus: Bool {
        guard let textView, let responder = textView.window?.firstResponder else { return false }
        return responder !== textView && responder is NSText
    }

    /// Whether this editor makes figures (plan 3a Task 6,
    /// `EditorCoordinator+Figure.swift`): a surface that answers the Insert
    /// menu — a Markdown manuscript, which only `EditorHost` says — whose host
    /// handed it an importer. A research note, a statement and a screenplay
    /// say no, so their drop and paste are what they always were.
    var answersFigures: Bool {
        answersInsertCommands && figureImporter != nil && !isDetached
    }

    /// Whether this editor opens the table grid (plan 3b Task 5,
    /// `EditorCoordinator+Tables.swift`): a manuscript surface whose host
    /// presents the sheet (`tableEditor`).
    var answersTableGrid: Bool {
        answersInsertCommands && tableEditor != nil && !isDetached
    }

    /// Insert ▸ Table (⌘⇧T, R-3a-5): a 3-column table on a block of its own
    /// at the caret (after the selection), its first header cell selected.
    func insertTable() {
        guard answersInsertCommands, let textView else { return }
        let at = NSMaxRange(textView.selectedRange())
        let blocks = tableBlockRange(containing: at)
            .map { [$0] } ?? []
        // Asked per command, never per keystroke: the labels the project's
        // OTHER manuscript documents define (a Report refuses a duplicate).
        let elsewhere = projectLabelsElsewhere?() ?? []
        applyCommandEdit(ReportInsert.tableEdit(in: textView.string, at: at, tableBlocks: blocks,
                                                labelsElsewhere: elsewhere),
                         actionName: "Insert Table")
    }

    /// Insert ▸ Citation… (⌘⇧C, plan 3b Task 3): `[@` at the caret (after
    /// the selection) as one Route A step, then the citation picker opened on
    /// it with every source listed. Refused, writing nothing, where Route A
    /// refuses; Esc leaves the `[@` as written.
    func insertCitation() {
        insertReferenceTrigger("[@", standsAfter: { unit in
            unit == PickerUnit.openParen
                || Unicode.Scalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) == true
        }) { $0 is CitationCompletion }
    }

    /// Insert ▸ Cross-Reference… (⌘⇧X, plan 3b Task 4): `@` at the caret as
    /// one Route A step, then the cross-reference picker opened on it with
    /// every target listed, in publishing order.
    func insertCrossReference() {
        insertReferenceTrigger("@", standsAfter: CrossReferenceCompletion.isWordStartBoundary) {
            $0 is CrossReferenceCompletion
        }
    }

    /// Writes `trigger` at the caret through Route A, then opens the first
    /// registered picker `isPicker` names on it (fix round 1, I6). After a
    /// character the trigger may not stand after (`standsAfter` false: a
    /// word, `!`, `[`, `\`) it is written after a space; and the trigger is
    /// checked against the text it WOULD make before anything is written, so
    /// where it still could not open (inside code) nothing is written.
    private func insertReferenceTrigger(_ trigger: String, standsAfter: (unichar) -> Bool,
                                        isPicker: (any CompletionSource) -> Bool) {
        guard answersInsertCommands, let textView,
              let source = completionSources.first(where: isPicker) else { return }
        let at = NSMaxRange(textView.selectedRange())
        let text = textView.string as NSString
        guard at <= text.length, !isInsideCode(at) else { return }
        let written = at == 0 || standsAfter(text.character(at: at - 1)) ? trigger : " " + trigger
        let caret = at + (written as NSString).length
        let wouldBe = text.replacingCharacters(in: NSRange(location: at, length: 0),
                                               with: written) as NSString
        guard source.trigger(in: wouldBe, caret: caret) != nil,
              applyCommandEdit(replacing: NSRange(location: at, length: 0), with: written,
                               selecting: NSRange(location: caret, length: 0),
                               actionName: source.actionName),
              let opened = source.trigger(in: textView.string as NSString, caret: caret)
        else { return }
        openCompletion(source: source, trigger: opened)
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
