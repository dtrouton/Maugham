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
    ///
    /// **`alongside`** is handed the undo manager inside the edit's own undo
    /// group, after the replace and before the step is named, so whatever it
    /// registers is part of the same ⌘Z — a figure line's `FigureBirthUndo`
    /// (report plan 7b, R7b-5). Not called when the edit is refused.
    @discardableResult
    func applyCommandEdit(replacing range: NSRange, with replacement: String,
                          selecting selection: NSRange, actionName: String,
                          landing: CommandLanding = .immediate,
                          separatingFigureLines: Bool = false,
                          alongside: ((UndoManager) -> Void)? = nil) -> Bool {
        guard !isDetached, let textView, let storage = textView.textStorage,
              range.location >= 0, NSMaxRange(range) <= storage.length else { return false }
        // The membrane's predicate first: an ended EMPTY group is not dropped,
        // so a refusal must not open one (the refusal tests count no step).
        // `shouldChangeText` below still asks the delegate, as before.
        guard commandMayWrite else { return false }
        var replacement = replacement, selection = selection
        if separatingFigureLines {
            (replacement, selection) = separatedInline(replacing: range, with: replacement,
                                                       selecting: selection, in: storage.string as NSString)
        }
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
        if let undo { alongside?(undo) }
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

    /// An inline command insert (`separatingFigureLines`: a citation, a
    /// cross-reference, a picked completion — text with no line break) with
    /// a figure line kept its own paragraph, as typing is
    /// (`FigureLineSeparation`, whole-branch review M4); its selection moved
    /// with it. A block-level insert places its own lines and is never asked.
    private func separatedInline(replacing range: NSRange, with replacement: String,
                                 selecting selection: NSRange, in text: NSString) -> (String, NSRange) {
        guard !(mode is ScreenplayMode), replacement.rangeOfCharacter(from: .newlines) == nil,
              case .replace(_, let separated, let caret)? = FigureLineSeparation.decide(
                text: text, range: range, replacement: replacement)
        else { return (replacement, selection) }
        let end = range.location + (replacement as NSString).length
        let delta = (separated as NSString).length - (replacement as NSString).length
        var moved = selection
        if selection.length == 0, selection.location == end {
            moved.location = caret
        } else if selection.location >= end {
            moved.location += delta
        }
        return (separated, moved)
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
                          landing: CommandLanding = .immediate,
                          alongside: ((UndoManager) -> Void)? = nil) -> Bool {
        applyCommandEdit(replacing: edit.replacedRange, with: edit.replacement,
                         selecting: edit.selection, actionName: actionName, landing: landing,
                         alongside: alongside)
    }

    /// The `alongside:` registration for a figure line whose figure the
    /// command just made: one ⌘Z takes back the line and sends the figure to
    /// the Trash, ⇧⌘Z brings the same figure back (`FigureBirthUndo`). A
    /// refusal either way is told through `commandFailureReporter`; each store
    /// verb's task is left in `figureBirthUndoTask` for a test to await.
    func figureBirthUndo(figureId: String, actionName: String,
                         store: ProjectStore) -> (UndoManager) -> Void {
        { [weak self] um in
            guard let self else { return }
            FigureBirthUndo.register(
                on: um, figureId: figureId, actionName: actionName, store: store,
                report: { [weak self] in self?.commandFailureReporter?($0) },
                workTaskSink: { [weak self] in self?.figureBirthUndoTask = $0 })
        }
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

    /// Whether this editor makes table figures (report plan 7b Task 4): a
    /// manuscript surface whose host handed it a maker (`tableFigureMaker`).
    var answersTableFigures: Bool {
        answersInsertCommands && tableFigureMaker != nil && !isDetached
    }

    /// The undo step Insert ▸ Table names ("Undo Insert Table").
    static let insertTableActionName = "Insert Table"

    /// **Insert ▸ Table (⌘⇧T)** (report plan 7b Task 4, R7b-7): makes a 3×3
    /// table figure with a header row in the document's piece
    /// (`tableFigureMaker`), then writes `![Caption](figures/table.csv){#tbl:table}`
    /// as a paragraph of its own at the caret (after the selection), `Caption`
    /// selected. The line always carries a `tbl:` label, its name the
    /// figure's (R7b-9): the maker is handed the `tbl:` names the text and the
    /// project already use, so the store steps the name clear of them.
    ///
    /// It lands as image ingest's line does (`beginFigureIngest`): the point
    /// is carried through typing while the figure is made
    /// (`FigureAnchorTracker`), a composition is waited out, and the line
    /// lands `.deferred`. One ⌘Z takes back the line and sends the figure to
    /// the Trash (`figureBirthUndo`, R7b-5). The membrane is asked before
    /// anything is made; a figure that exists but whose line cannot be
    /// written — the membrane refused meanwhile, the editor left the
    /// document, a composition outlasted the waits — goes to the Trash, and
    /// the writer is told (R7b-6).
    @discardableResult
    func insertTableFigure() -> Task<Void, Never>? {
        guard answersTableFigures, commandMayWrite, let textView,
              let storage = textView.textStorage, let maker = tableFigureMaker else { return nil }
        let at = NSMaxRange(textView.selectedRange())
        let tracker = FigureAnchorTracker(
            anchor: FigureIngest.Anchor(point: at, in: textView.string), storage: storage)
        let writersSelection = textView.selectedRange()
        // Asked per command, never per keystroke.
        let taken = FigureIngest.existingFigureNames(
            in: textView.string, elsewhere: projectLabelsElsewhere?() ?? [], kind: .tbl)
        // Held now, so a figure whose editor went away is still told about.
        let report = commandFailureReporter
        let task = Task { @MainActor [weak self] in
            defer { tracker.stop() }
            let birth: FigureIngest.TableFigureBirth
            do {
                birth = try await maker(FigureIngest.TableFigureRequest(
                    name: FigureIngest.tableFigureName, taken: taken, pipe: nil))
            } catch {
                report?(FigureIngest.tableFigureFailureMessage(for: error))
                return
            }
            guard let self else {
                await Self.discard(birth, because: .documentLeft, report: report)
                return
            }
            guard await self.tableFigureMayLand(birth, in: textView, report: report) else { return }
            let writerMoved = tracker.anchor.edited || textView.selectedRange() != writersSelection
            let location = tracker.anchor.location(
                in: textView.string, caret: NSMaxRange(textView.selectedRange()))
            guard let landed = self.writeTableFigureLine(birth, at: location, writerMoved: writerMoved) else {
                await Self.discard(birth, because: .refused, report: report)
                return
            }
            // Spec §6.4: the new table expands in place (report plan 7c Task 6)
            // — for a writer still where they asked. A writer who moved on
            // keeps the focus: the line lands as a card (review I2 ruling).
            if !writerMoved { self.expandFigureGrid(lineAt: landed) }
        }
        tableFigureTask = task
        return task
    }

    /// Waits out a composition before a made table figure's line is
    /// written (`waitOutComposition`); false — the figure sent to the Trash,
    /// the writer told — when the editor left the document or the
    /// composition outlasted every wait. Insert ▸ Table and Convert share it.
    func tableFigureMayLand(_ birth: FigureIngest.TableFigureBirth, in textView: NSTextView,
                            report: (@MainActor (String) -> Void)?) async -> Bool {
        switch await waitOutComposition(in: textView) {
        case .ready:
            return true
        case .gone:
            await Self.discard(birth, because: .documentLeft, report: report)
            return false
        case .gaveUp:
            await Self.discard(birth, because: .composing, report: report)
            return false
        }
    }

    /// The table figure's line at `location` through Route A, its birth
    /// registered alongside: where its caption landed in the text, or nil
    /// when the membrane refused.
    private func writeTableFigureLine(_ birth: FigureIngest.TableFigureBirth, at location: Int,
                                      writerMoved: Bool) -> Int? {
        guard let textView else { return nil }
        let line = FigureIngest.figureLine(path: birth.linePath, kind: .tbl, name: birth.name)
        let blocks = tableBlockRange(containing: location)
            .map { [$0] } ?? []
        let edit = FigureIngest.figureEdit(in: textView.string, at: location,
                                           tableBlocks: blocks, line: line)
        let written = applyCommandEdit(
            edit, actionName: Self.insertTableActionName,
            landing: .deferred(writerMoved: writerMoved),
            alongside: figureBirthUndo(figureId: birth.figureId,
                                       actionName: Self.insertTableActionName,
                                       store: birth.store))
        return written ? edit.selection.location : nil
    }

    /// Why a made table figure's line was not written (R7b-6).
    enum TableFigureDiscard: Equatable {
        /// The membrane refused the line.
        case refused
        /// The editor left the document while the figure was made.
        case documentLeft
        /// An input method composed through every wait.
        case composing
        /// Convert to Table Figure: the pipe table's text changed while its
        /// figure was made (Review Focus 2).
        case tableChanged
    }

    /// Sends a table figure whose line was not written to the Trash, and says
    /// so (R7b-6). A removal the store refuses leaves the figure where it is,
    /// and the sentence says that instead.
    static func discard(_ birth: FigureIngest.TableFigureBirth,
                                because reason: TableFigureDiscard,
                                report: (@MainActor (String) -> Void)?) async {
        let trashed: Bool
        do {
            try await birth.store.removeFigure(id: birth.figureId)
            trashed = true
        } catch {
            trashed = false
        }
        report?(tableFigureDiscardMessage(reason, trashed: trashed, name: birth.name))
    }

    /// The sentence a discarded table figure is told with.
    static func tableFigureDiscardMessage(_ reason: TableFigureDiscard, trashed: Bool,
                                          name: String) -> String {
        let why: String
        switch reason {
        case .refused: why = "The table figure was made, but this document can’t be written to now"
        case .documentLeft: why = "The table figure was made, but its document was no longer open"
        case .composing: why = "The table figure was made, but it wasn’t placed while you were composing text"
        case .tableChanged: why = "The table changed while its figure was being made and was left as it is"
        }
        return trashed
            ? why + ", so the figure went to the Trash."
            : why + ", and it couldn’t be moved to the Trash: it stays in the book as “\(name)”."
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
                               actionName: source.actionName, separatingFigureLines: true),
              let opened = source.trigger(in: textView.string as NSString,
                                          caret: textView.selectedRange().location)
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
