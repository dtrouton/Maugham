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

// MARK: - The table's anchor

/// Carries the start of the table being converted through every edit to the
/// text storage while its figure is made, the way `FigureAnchorTracker`
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

// EditorCoordinator — Convert to Table Figure (report plan 7b Task 5): a pipe
// table becomes a table figure, its cells read as a CSV import reads them
// (R7b-10), and the table's block — rows and `Table:` line — becomes one
// figure line keeping its caption and label (R7b-9). ⌘⌥⇧T, Insert ▸ Convert to
// Table Figure, and the editor's right-click menu inside a pipe table.
extension EditorCoordinator {
    /// The undo step Convert names ("Undo Convert to Table Figure"), and the
    /// menu items' title.
    static let convertTableActionName = "Convert to Table Figure"

    /// Whether a right-click at `index` offers Convert to Table Figure: a
    /// surface that makes table figures and may write now, with `index` in a
    /// pipe table (its ends included) as the fresh tokens place it. Pure over
    /// the text, the tokens and the posture.
    func convertOffer(atCharacterIndex index: Int) -> Bool {
        convertibleTable(at: index) != nil && commandMayWrite
    }

    /// The right-click menu's item (`MaughamTextView.menu(for:)`): nil unless
    /// `convertOffer(atCharacterIndex:)` says yes; otherwise an item that
    /// converts the table at `index` (`convertTableFromMenu(_:)`).
    func convertTableMenuItem(atCharacterIndex index: Int) -> NSMenuItem? {
        guard convertOffer(atCharacterIndex: index) else { return nil }
        let item = NSMenuItem(title: Self.convertTableActionName,
                              action: #selector(convertTableFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = index
        return item
    }

    @objc func convertTableFromMenu(_ sender: NSMenuItem) {
        convertTableToFigure(at: sender.representedObject as? Int)
    }

    /// The pipe table holding `index`: its block (header row through
    /// `Table:` line) and parse. Nil outside a table, on a surface that makes
    /// no table figures, or while the tokens describe an earlier text.
    private func convertibleTable(at index: Int) -> CaretTable? {
        guard answersTableFigures, let textView, !tokensDescribeAnEarlierText,
              let range = tableBlockRange(containing: index) else { return nil }
        let ns = textView.string as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        let block = ns.substring(with: range)
        guard let table = TableText(parsing: block) else { return nil }
        return CaretTable(range: range, block: block, table: table)
    }

    /// **Convert to Table Figure** on the table holding `location` (the caret
    /// when nil). Outside a pipe table, where the membrane refuses, or while
    /// an input method is composing, nothing happens (nil, R7b-8).
    ///
    /// The table's text and start are recorded (`TableAnchorTracker` carries
    /// the start through every edit), then the figure is made through
    /// `tableFigureMaker` with the pipe table's cells. Its name (R7b-9): a
    /// `tbl:` label's name, the label itself kept on the line exactly, so
    /// every `@tbl:` reference resolves to the same number; with none, a name
    /// from `FigureIngest.convertedTableName`, stepped clear of the `tbl:`
    /// names in use, and the label minted from it. Once the figure exists the
    /// table is re-read at its start: if it is not exactly the recorded text —
    /// an edit, another device's change, a tidy — nothing is written and the
    /// figure goes to the Trash with a notice (Review Focus 2); a refused
    /// write or a lost document does the same (R7b-6). Otherwise the block is
    /// replaced by the figure line as one Route A edit, landing `.deferred`,
    /// the figure's birth registered alongside so one ⌘Z takes back both.
    /// Cells kept as text because their formula would not read are named in a
    /// notice. The task is `tableFigureTask`.
    @discardableResult
    func convertTableToFigure(at location: Int? = nil) -> Task<Void, Never>? {
        guard let textView, let storage = textView.textStorage, let maker = tableFigureMaker,
              !textView.hasMarkedText(), commandMayWrite,
              let at = convertibleTable(at: location ?? textView.selectedRange().location)
        else { return nil }
        closeCompletion()
        let keptLabel = at.table.label?.kind == .tbl ? at.table.label : nil
        let request: FigureIngest.TableFigureRequest
        if let keptLabel {
            request = .init(name: keptLabel.name, taken: [], pipe: at.table)
        } else {
            let others = (textView.string as NSString).replacingCharacters(in: at.range, with: "")
            request = .init(
                name: FigureIngest.convertedTableName(caption: at.table.caption, label: at.table.label),
                taken: FigureIngest.existingFigureNames(
                    in: others, elsewhere: projectLabelsElsewhere?() ?? [], kind: .tbl),
                pipe: at.table)
        }
        let tracker = TableAnchorTracker(anchor: at.range.location, storage: storage)
        let writersSelection = textView.selectedRange()
        let report = commandFailureReporter
        let task = Task { @MainActor [weak self] in
            defer { tracker.stop() }
            let birth: FigureIngest.TableFigureBirth
            do {
                birth = try await maker(request)
            } catch {
                report?(FigureIngest.tableConvertFailureMessage(for: error))
                return
            }
            guard let self else {
                await Self.discard(birth, because: .documentLeft, report: report)
                return
            }
            guard await self.tableFigureMayLand(birth, in: textView, report: report) else { return }
            guard let range = self.unchangedTable(at.block, at: tracker.anchor) else {
                await Self.discard(birth, because: .tableChanged, report: report)
                return
            }
            let line = FigureIngest.figureLine(
                path: birth.linePath, kind: .tbl, name: keptLabel?.name ?? birth.name,
                caption: at.table.caption ?? "")
            let caret = NSRange(location: range.location + (line as NSString).length, length: 0)
            let writerMoved = textView.selectedRange() != writersSelection
            self.tableTidy.isApplying = true
            let applied = self.applyCommandEdit(
                replacing: range, with: line, selecting: caret,
                actionName: Self.convertTableActionName,
                landing: .deferred(writerMoved: writerMoved),
                alongside: self.figureBirthUndo(figureId: birth.figureId,
                                                actionName: Self.convertTableActionName,
                                                store: birth.store))
            self.tableTidy.isApplying = false
            self.tableTidy.cancelPending()
            guard applied else {
                await Self.discard(birth, because: .refused, report: report)
                return
            }
            // The writer may be in ANOTHER table: that one stays remembered.
            self.tableTidy.anchor = self.tableBlockRange(
                containing: textView.selectedRange().location)?.location
            if let notice = FigureIngest.convertedTableProblemsMessage(birth.problems) {
                report?(notice)
            }
        }
        tableFigureTask = task
        return task
    }

    /// The table block at `anchor` when it is still exactly `original`; nil
    /// when its start was replaced, it moved, or its text changed.
    private func unchangedTable(_ original: String, at anchor: Int?) -> NSRange? {
        guard let anchor, let textView, !tokensDescribeAnEarlierText,
              let range = tableBlockRange(containing: anchor), range.location == anchor
        else { return nil }
        let ns = textView.string as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == original else { return nil }
        return range
    }
}
