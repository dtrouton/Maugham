import Foundation
import MaughamCore
import AppKit

/// What the coordinator remembers about tables between selection changes
/// (plan 3a Task 5). Plain state on the coordinator, never observed (tripwire 6).
struct TableTidyState {
    /// The start of the table the selection last touched; nil when it touches
    /// none. Leaving that table schedules its tidy.
    var anchor: Int?
    /// The table a scheduled leave-tidy will look for, and the work item that
    /// will run it on the next runloop.
    var pendingAnchor: Int?
    var pending: DispatchWorkItem?
    /// True while a table command's own edit is landing, so the selection
    /// changes it causes are not read as the writer leaving.
    var isApplying = false

    mutating func cancelPending() {
        pending?.cancel()
        pending = nil
        pendingAnchor = nil
    }

    /// Carries both anchors through one character edit, as `NSTextStorage`
    /// reports it (`editedRange` in the text AFTER the edit), the way
    /// `FigureIngest.Anchor` carries a figure's point (whole-branch review
    /// I3): an edit wholly before a table's start shifts it, one at or after
    /// it leaves it, and one that replaced the start forgets it. A forgotten
    /// pending anchor cancels its tidy.
    mutating func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        anchor = Self.shifted(anchor, editedRange: editedRange, delta: delta)
        guard pendingAnchor != nil else { return }
        pendingAnchor = Self.shifted(pendingAnchor, editedRange: editedRange, delta: delta)
        if pendingAnchor == nil { cancelPending() }
    }

    static func shifted(_ anchor: Int?, editedRange: NSRange, delta: Int) -> Int? {
        guard let anchor else { return nil }
        let start = editedRange.location
        let replacedEnd = start + editedRange.length - delta      // in the text BEFORE
        if start >= anchor { return anchor }
        if replacedEnd <= anchor { return anchor + delta }
        return nil
    }
}

// EditorCoordinator — pipe tables: Tab and Shift-Tab move by cell, Return at a
// body row's end adds a row, and the table re-aligns its pipes on each of those
// and when the caret leaves it — never mid-keystroke (Denver's ruling, spec §4
// amended 2026-10-20). Every re-align is `TableText.formatted()`, written as one
// Route A edit (`applyCommandEdit`): one ⌘Z step, through the membrane.
extension EditorCoordinator {
    /// The table holding the selection, as `lastTokens` (refreshed on every
    /// edit) places it.
    struct CaretTable {
        let range: NSRange
        let block: String
        let table: TableText
    }

    func caretTable(in textView: NSTextView) -> CaretTable? {
        let selection = textView.selectedRange()
        let ns = textView.string as NSString
        guard !tokensDescribeAnEarlierText,
              let range = tableBlockRange(containing: selection.location),
              NSMaxRange(range) <= ns.length,
              NSMaxRange(selection) <= NSMaxRange(range) else { return nil }
        let block = ns.substring(with: range)
        guard let table = TableText(parsing: block) else { return nil }
        return CaretTable(range: range, block: block, table: table)
    }

    // MARK: - Tab, Shift-Tab, Return

    /// The prose arms of `textView(_:doCommandBy:)`. True when the command was
    /// a table's; false (AppKit's default) outside a table, on its delimiter
    /// or caption line, and always while an input method is composing.
    func handleTableCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            return moveTableCell(forward: true, in: textView)
        case #selector(NSResponder.insertBacktab(_:)):
            return moveTableCell(forward: false, in: textView)
        case #selector(NSResponder.insertNewline(_:)):
            return addTableRow(in: textView)
        default:
            return false
        }
    }

    /// Tab: the next cell's text, selected (the next row's first cell after a
    /// row's last); at the table's last cell the caret stays. Shift-Tab: the
    /// previous cell. The table re-aligns first.
    private func moveTableCell(forward: Bool, in textView: NSTextView) -> Bool {
        guard let at = caretTable(in: textView) else { return false }
        let selection = textView.selectedRange()
        guard let cell = TableText.cell(at: selection.location - at.range.location,
                                        in: at.block) else { return false }
        let counts = [at.table.header.count] + at.table.rows.map(\.count)
        var (row, column) = cell
        var stays = false
        if forward {
            if column + 1 < counts[row] { column += 1 }
            else if row + 1 < counts.count { row += 1; column = 0 }
            else { stays = true }
        } else {
            if column > 0 { column -= 1 }
            else if row > 0 { row -= 1; column = max(0, counts[row] - 1) }
            else { stays = true }
        }

        let formatted = at.table.formatted()
        if formatted == at.block {
            // Nothing to re-align: selection only, no undo step.
            guard !stays else { return true }
            select(TableText.textRange(ofCell: row, column, in: at.block), in: at, textView)
            return true
        }
        let target: NSRange
        if stays {
            // The same cell, the caret as far into its text as it was.
            let old = TableText.textRange(ofCell: row, column, in: at.block)
            let new = TableText.textRange(ofCell: row, column, in: formatted)
            let into = max(0, min(selection.location - at.range.location - old.location, new.length))
            target = NSRange(location: new.location + into, length: 0)
        } else {
            target = TableText.textRange(ofCell: row, column, in: formatted)
        }
        if !applyTableEdit(at, formatted, selecting: target, actionName: "Tidy Table") {
            // Refused (a read-only posture): still move, through the text as it is.
            if !stays { select(TableText.textRange(ofCell: row, column, in: at.block), in: at, textView) }
        }
        return true
    }

    /// Return at the end of a body row (only spaces after the caret on its
    /// line): a new empty row after it, the caret in its first cell, the table
    /// re-aligned — one edit. Return anywhere on an empty LAST body row leaves
    /// the table (`leaveTable`). Return anywhere on the header row goes to the
    /// first body row (`enterFirstBodyRow`). Anywhere else Return is AppKit's.
    private func addTableRow(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, let at = caretTable(in: textView),
              let cell = TableText.cell(at: selection.location - at.range.location, in: at.block)
        else { return false }
        guard cell.row >= 1 else {
            enterFirstBodyRow(at, in: textView)
            return true
        }
        if cell.row == at.table.rows.count,
           at.table.rows[cell.row - 1].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            leaveTable(at, in: textView)
            return true
        }
        let ns = textView.string as NSString
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        var end = NSMaxRange(line)
        while end > selection.location, Self.isLineEndSpace(ns.character(at: end - 1)) { end -= 1 }
        guard end == selection.location else { return false }

        var grown = at.table
        grown.rows.insert(Array(repeating: "", count: grown.header.count), at: cell.row)
        let formatted = grown.formatted()
        let caret = TableText.offset(ofCell: cell.row + 1, 0, in: formatted)
        applyTableEdit(at, formatted, selecting: NSRange(location: caret, length: 0),
                       actionName: "Add Table Row")
        return true
    }

    /// Return on the header row (Denver's ruling on the whole-branch review's
    /// M2): the caret goes to the first body row's first cell, a body row
    /// added first when there is none. It never splits the table — a newline
    /// between the header and the delimiter row would dissolve it into prose.
    /// The table re-aligns, as on Tab; nothing to re-align or add moves only.
    private func enterFirstBodyRow(_ at: CaretTable, in textView: NSTextView) {
        var table = at.table
        if table.rows.isEmpty { table.rows.append(Array(repeating: "", count: table.header.count)) }
        let formatted = table.formatted()
        if formatted == at.block {
            let caret = TableText.offset(ofCell: 1, 0, in: at.block)
            select(NSRange(location: caret, length: 0), in: at, textView)
            return
        }
        let adds = at.table.rows.isEmpty
        let applied = applyTableEdit(
            at, formatted,
            selecting: NSRange(location: TableText.offset(ofCell: 1, 0, in: formatted), length: 0),
            actionName: adds ? "Add Table Row" : "Tidy Table")
        // Refused (a read-only posture): still move, through the text as it
        // is — when there is a body row to move to.
        if !applied, !adds {
            select(NSRange(location: TableText.offset(ofCell: 1, 0, in: at.block), length: 0),
                   in: at, textView)
        }
    }

    /// Return on an empty last body row (R-S4): the row goes (unless it is the
    /// table's only body row — a fresh table keeps its one row), the table is
    /// re-aligned, and a new empty paragraph opens a blank line below it (below
    /// the caption, if any), the caret there. The newlines that followed the
    /// table are replaced, so text after it stays a blank line away. One edit.
    private func leaveTable(_ at: CaretTable, in textView: NSTextView) {
        var table = at.table
        if table.rows.count > 1 { table.rows.removeLast() }
        let formatted = table.formatted()
        let ns = textView.string as NSString
        var end = NSMaxRange(at.range)
        while end < ns.length, ns.character(at: end) == 0x0A { end += 1 }
        let followed = end < ns.length
        let replacement = formatted + "\n\n" + (followed ? "\n\n" : "")
        let caret = at.range.location + (formatted as NSString).length + 2
        tableTidy.isApplying = true
        defer { tableTidy.isApplying = false }
        applyCommandEdit(replacing: NSRange(location: at.range.location,
                                            length: end - at.range.location),
                         with: replacement, selecting: NSRange(location: caret, length: 0),
                         actionName: "Leave Table")
        tableTidy.cancelPending()
        tableTidy.anchor = nil
    }

    /// Replaces the table with `formatted` as one Route A edit; `selection` is
    /// relative to the table. False when the membrane refused it.
    @discardableResult
    private func applyTableEdit(_ at: CaretTable, _ formatted: String, selecting selection: NSRange,
                                actionName: String) -> Bool {
        tableTidy.isApplying = true
        defer { tableTidy.isApplying = false }
        let applied = applyCommandEdit(
            replacing: at.range, with: formatted,
            selecting: NSRange(location: at.range.location + selection.location,
                               length: selection.length),
            actionName: actionName)
        tableTidy.cancelPending()
        tableTidy.anchor = at.range.location
        return applied
    }

    private func select(_ cell: NSRange, in at: CaretTable, _ textView: NSTextView) {
        let range = NSRange(location: at.range.location + cell.location, length: cell.length)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private static func isLineEndSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    // MARK: - Leaving the table

    /// Called on every selection change. A selection that touches a table
    /// remembers it; one that has left the remembered table schedules its tidy
    /// for the next runloop, so the edit never runs inside the selection
    /// callback's stack. An undo or redo moving the selection schedules
    /// nothing (re-tidying what ⌘Z just untidied would eat the redo and every
    /// undo step behind it), and neither does a composing input method.
    ///
    /// A selection change posted while an edit is landing (AppKit posts one
    /// inside `replaceCharacters`, before the retokenize) is read against
    /// stale tokens, so it is ignored: `textDidChange` asks again once the
    /// tokens are fresh, and the anchors ride the edit on their own
    /// (`TableTidyState.noteEdit`) — whole-branch review I3.
    ///
    /// Moving straight from one table into another leaves the first: it is
    /// scheduled as any other leave would be (whole-branch review M3 — Insert
    /// Table from inside a table lands its new table after it).
    func noteSelectionForTableTidy(in textView: NSTextView) {
        guard !tableTidy.isApplying, !tokensDescribeAnEarlierText,
              !textView.hasMarkedText() else { return }
        if let undo = textView.undoManager, undo.isUndoing || undo.isRedoing {
            tableTidy.anchor = nil
            tableTidy.cancelPending()
            return
        }
        let selection = textView.selectedRange()
        let touched = tableBlockRange(containing: selection.location)
            ?? tableBlockRange(containing: NSMaxRange(selection))
        if let touched {
            if let left = tableTidy.anchor, left != touched.location {
                scheduleTableTidy(at: left)
            }
            tableTidy.anchor = touched.location
            if tableTidy.pendingAnchor == touched.location { tableTidy.cancelPending() }
        } else if let anchor = tableTidy.anchor {
            tableTidy.anchor = nil
            scheduleTableTidy(at: anchor)
        }
    }

    private func scheduleTableTidy(at anchor: Int) {
        tableTidy.cancelPending()
        let item = DispatchWorkItem { [weak self] in self?.performPendingTableTidy() }
        tableTidy.pending = item
        tableTidy.pendingAnchor = anchor
        DispatchQueue.main.async(execute: item)
    }

    /// True while a leave-the-table tidy waits for the next runloop.
    var hasPendingTableTidy: Bool { tableTidy.pendingAnchor != nil }

    /// Runs the scheduled leave-the-table tidy now (the runloop calls it; a
    /// test may, instead of waiting). It re-reads everything: the table must
    /// still be there and untidy, the selection must still be outside it, and
    /// no input method may be composing, and the text view must have the focus.
    /// The caret keeps its place in the text.
    func performPendingTableTidy() {
        guard let anchor = tableTidy.pendingAnchor else { return }
        tableTidy.cancelPending()
        guard !isDetached, let textView, !textView.hasMarkedText() else { return }
        // A caret moved out of the table by code while focus is elsewhere (a
        // find jump with the find field focused) must not have its focus taken
        // by the edit (`applyCommandEdit` makes the text view first responder):
        // keep the table remembered, so the next move once the writer is back
        // tidies it.
        guard textView.window?.firstResponder === textView else {
            tableTidy.anchor = anchor
            return
        }
        let ns = textView.string as NSString
        guard !tokensDescribeAnEarlierText,
              let range = tableBlockRange(containing: anchor),
              NSMaxRange(range) <= ns.length else { return }
        let selection = textView.selectedRange()
        guard selection.location > NSMaxRange(range) || NSMaxRange(selection) < range.location
        else {
            tableTidy.anchor = range.location        // the writer is back in it
            return
        }
        let block = ns.substring(with: range)
        guard let table = TableText(parsing: block) else { return }
        let formatted = table.formatted()
        guard formatted != block else { return }
        let delta = (formatted as NSString).length - range.length
        let kept = selection.location > NSMaxRange(range)
            ? NSRange(location: selection.location + delta, length: selection.length)
            : selection
        tableTidy.isApplying = true
        defer { tableTidy.isApplying = false }
        applyCommandEdit(replacing: range, with: formatted, selecting: kept, actionName: "Tidy Table")
        // The writer may be in ANOTHER table (they left this one for it, M3):
        // that one stays remembered.
        tableTidy.anchor = tableBlockRange(containing: textView.selectedRange().location)?.location
    }
}

// MARK: - The grid editor (plan 3b Task 5)

/// What the table grid editor opens on (`EditorCoordinator.tableEditor`).
struct TableGridRequest: Equatable {
    /// The table as it stands in the text.
    let table: TableText
    /// The labels already taken: the project's other manuscripts' and this
    /// document's own, except this table's — a new label must be none of them.
    let takenLabels: Set<ManuscriptLabel>
    /// Whether the editor may write now (`commandMayWrite`). Read-only, the
    /// grid opens to be read and Save is disabled; the save is refused anyway.
    let mayWrite: Bool
}

/// Carries the start of the table being edited through every edit to the
/// text storage while the grid sheet is open, the way `FigureAnchorTracker`
/// carries a figure's point (`TableTidyState.shifted`): an edit before the
/// table shifts it, one at or after its start leaves it, one that replaced the
/// start forgets it (nil).
@MainActor
final class TableAnchorTracker {
    private(set) var anchor: Int?
    private var token: NSObjectProtocol?

    init(anchor: Int, storage: NSTextStorage) {
        self.anchor = anchor
        token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            let range = storage.editedRange, delta = storage.changeInLength
            MainActor.assumeIsolated {
                guard let self else { return }
                self.anchor = TableTidyState.shifted(self.anchor, editedRange: range, delta: delta)
            }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

// EditorCoordinator — the table grid editor (plan 3b Task 5, R-3b-3): Edit
// Table… (⌘⌥⇧T) and a double-click on a table's delimiter row open a SwiftUI
// sheet the host presents (`tableEditor`); its Save lands as one Route A edit.
extension EditorCoordinator {
    /// What the writer is told when the table changed while the grid was open.
    static let tableChangedWhileEditingMessage = "The table changed while you were editing it"

    /// Edit Table…: the grid on the table holding `location` (the caret when
    /// nil). Outside a table, on a surface with no grid, or while an input
    /// method is composing, nothing happens (returns nil). Read-only, the grid
    /// opens with Save disabled.
    ///
    /// The table's start is carried through every edit while the sheet is up
    /// (`TableAnchorTracker`); the save re-reads the table there and writes
    /// only if it is exactly the text the sheet opened on
    /// (`saveEditedTable`). The returned task ends when the sheet has closed
    /// and the save, if any, has landed.
    @discardableResult
    func editTable(at location: Int? = nil) -> Task<Void, Never>? {
        guard answersTableGrid, let textView, let storage = textView.textStorage,
              let editor = tableEditor, !textView.hasMarkedText(), !tokensDescribeAnEarlierText
        else { return nil }
        let at = location ?? textView.selectedRange().location
        let ns = textView.string as NSString
        guard let range = tableBlockRange(containing: at), NSMaxRange(range) <= ns.length else {
            return nil
        }
        let block = ns.substring(with: range)
        guard let table = TableText(parsing: block) else { return nil }
        closeCompletion()
        let request = TableGridRequest(table: table,
                                       takenLabels: labelsTaken(besidesTableAt: range, in: ns),
                                       mayWrite: commandMayWrite)
        let tracker = TableAnchorTracker(anchor: range.location, storage: storage)
        let task = Task { @MainActor [weak self] in
            let edited = await editor(request)
            tracker.stop()
            guard let edited, let self else { return }
            self.saveEditedTable(edited, replacing: block, at: tracker.anchor)
        }
        tableGridTask = task
        return task
    }

    /// The double-click route (`MaughamTextView.mouseDown`, R-3b-3): a
    /// double-click on a table's delimiter row opens the grid and is handled
    /// (true); anywhere else — inside a cell, where a double-click selects a
    /// word — it is not (false), and AppKit's word selection runs.
    func editTableOnDelimiterRow(atCharacterIndex index: Int) -> Bool {
        guard answersTableGrid, let range = tableDelimiterRowHit(atCharacterIndex: index)
        else { return false }
        editTable(at: range.location)
        return true
    }

    /// The table whose delimiter row (`|---|`, the line under the header)
    /// holds `index`, or nil. Pure over the text and the tokens.
    func tableDelimiterRowHit(atCharacterIndex index: Int) -> NSRange? {
        guard let textView, !tokensDescribeAnEarlierText,
              let range = tableBlockRange(containing: index) else { return nil }
        let ns = textView.string as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        let header = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let delimiterStart = NSMaxRange(header)
        guard delimiterStart < NSMaxRange(range) else { return nil }
        var delimiterEnd = delimiterStart
        while delimiterEnd < NSMaxRange(range), ns.character(at: delimiterEnd) != 0x0A { delimiterEnd += 1 }
        return index >= delimiterStart && index <= delimiterEnd ? range : nil
    }

    /// The grid's Save. Refused, writing nothing, when the membrane refuses
    /// (a read-only posture) — and, telling the writer
    /// (`tableChangedWhileEditingMessage`), when the table is not exactly
    /// `original` at `anchor` any more: an edit inside it, a sync re-render
    /// or a tidy while the sheet was open, or its start replaced (`anchor`
    /// nil). Otherwise one Route A edit (one ⌘Z step) writes
    /// `edited.formatted()`, the caret at its first cell.
    @discardableResult
    func saveEditedTable(_ edited: TableText, replacing original: String, at anchor: Int?) -> Bool {
        guard !isDetached, let textView, commandMayWrite else { return false }
        let ns = textView.string as NSString
        guard let anchor, !tokensDescribeAnEarlierText,
              let range = tableBlockRange(containing: anchor), range.location == anchor,
              NSMaxRange(range) <= ns.length, ns.substring(with: range) == original
        else {
            commandFailureReporter?(Self.tableChangedWhileEditingMessage)
            return false
        }
        let formatted = edited.formatted()
        let caret = range.location + TableText.offset(ofCell: 0, 0, in: formatted)
        tableTidy.isApplying = true
        defer { tableTidy.isApplying = false }
        let applied = applyCommandEdit(replacing: range, with: formatted,
                                       selecting: NSRange(location: caret, length: 0),
                                       actionName: "Edit Table", landing: .immediate)
        tableTidy.cancelPending()
        if applied { tableTidy.anchor = range.location }
        return applied
    }

    /// The labels a label set in the grid must not repeat: the project's
    /// other manuscripts' (`projectLabelsElsewhere`) and this document's own,
    /// read from its live text with the edited table taken out — so the
    /// table's own label is free, and a second table already sharing it is
    /// not.
    private func labelsTaken(besidesTableAt range: NSRange, in text: NSString) -> Set<ManuscriptLabel> {
        let without = text.replacingCharacters(in: range, with: "")
        return (projectLabelsElsewhere?() ?? []).union(ReportInsert.definedLabels(in: without))
    }
}
