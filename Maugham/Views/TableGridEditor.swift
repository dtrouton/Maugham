import SwiftUI
import AppKit
import MaughamCore

// The table grid editor (report foundations plan 3b Task 5, R-3b-3): Edit
// Table… (⌘⌥⇧T) or a double-click on a table's delimiter row opens it on the
// caret's table. Every operation is a pure mutation of `TableGridModel`, tested
// directly; the sheet is a thin view over it. `EditorHost` presents it through
// `TableGridPresenter` and hands the result back to the coordinator, which
// writes it as one Route A edit (`EditorCoordinator.saveEditedTable`).

// MARK: - The model

/// One table being edited in the grid: a rectangle of cells (row 0 is the
/// header), one alignment per column, the caption and the label's name, and
/// the cell last focused (`selection`), which the row, column and paste verbs
/// act on. Every verb keeps the rectangle rectangular.
struct TableGridModel: Equatable {
    /// A cell of the grid: row 0 is the header, row 1 the first body row.
    struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    private(set) var header: [String]
    private(set) var alignments: [TableAlignment]
    private(set) var rows: [[String]]
    var caption: String
    /// The label's name, after `tbl:` (a typed `tbl:` prefix is ignored).
    var labelName: String
    /// The cell the verbs act on; nil before any cell has been focused.
    var selection: Cell?
    /// The labels a label set here must not repeat (`TableGridRequest`).
    let takenLabels: Set<ManuscriptLabel>
    let mayWrite: Bool

    init(_ request: TableGridRequest) {
        let t = request.table
        let columns = max(1, t.header.count, t.rows.map(\.count).max() ?? 0)
        func padded(_ cells: [String]) -> [String] {
            cells + Array(repeating: "", count: max(0, columns - cells.count))
        }
        header = padded(t.header)
        alignments = t.alignments + Array(repeating: .none, count: max(0, columns - t.alignments.count))
        alignments = Array(alignments.prefix(columns))
        rows = t.rows.map(padded)
        caption = t.caption ?? ""
        labelName = t.label?.name ?? ""
        takenLabels = request.takenLabels
        mayWrite = request.mayWrite
    }

    var columnCount: Int { header.count }
    /// Body rows; the grid shows `bodyRowCount + 1` rows with the header.
    var bodyRowCount: Int { rows.count }

    /// A cell's text; empty for a cell that is not there (a stale binding
    /// read during a row or column removal).
    func cell(_ row: Int, _ column: Int) -> String {
        guard isCell(row, column) else { return "" }
        return row == 0 ? header[column] : rows[row - 1][column]
    }

    func alignment(ofColumn column: Int) -> TableAlignment {
        alignments.indices.contains(column) ? alignments[column] : .none
    }

    // MARK: Cells

    /// A cell's text, one line (`TableText.singleLine`).
    mutating func setCell(_ row: Int, _ column: Int, to text: String) {
        guard isCell(row, column) else { return }
        let line = TableText.singleLine(text)
        if row == 0 { header[column] = line } else { rows[row - 1][column] = line }
    }

    mutating func setAlignment(_ alignment: TableAlignment, ofColumn column: Int) {
        guard alignments.indices.contains(column) else { return }
        alignments[column] = alignment
    }

    // MARK: Rows

    /// A new empty body row after `row` (0, the header, puts it first); the
    /// selection moves into it.
    mutating func addRow(after row: Int) {
        let at = max(0, min(row, rows.count))
        rows.insert(Array(repeating: "", count: columnCount), at: at)
        selection = Cell(row: at + 1, column: selection?.column ?? 0)
    }

    /// Removes body row `row` (the header is never removed); the selection
    /// stays on the row that takes its place, or the one above.
    mutating func removeRow(_ row: Int) {
        guard row >= 1, row <= rows.count else { return }
        rows.remove(at: row - 1)
        if let s = selection, s.row >= row {
            selection = Cell(row: s.row == row ? min(row, rows.count) : s.row - 1, column: s.column)
        }
    }

    /// Moves body row `row` up (`by: -1`) or down (`by: 1`) among the body
    /// rows; the header stays the header. The selection follows the row.
    mutating func moveRow(_ row: Int, by offset: Int) {
        let to = row + offset
        guard row >= 1, row <= rows.count, to >= 1, to <= rows.count else { return }
        rows.swapAt(row - 1, to - 1)
        if selection?.row == row { selection?.row = to }
    }

    func canMoveRow(_ row: Int, by offset: Int) -> Bool {
        row >= 1 && row <= rows.count && row + offset >= 1 && row + offset <= rows.count
    }

    // MARK: Columns

    /// A new empty column after `column`, with no alignment; the selection
    /// moves into it.
    mutating func addColumn(after column: Int) {
        let at = max(0, min(column + 1, columnCount))
        header.insert("", at: at)
        alignments.insert(.none, at: at)
        for i in rows.indices { rows[i].insert("", at: at) }
        selection = Cell(row: selection?.row ?? 0, column: at)
    }

    /// Removes column `column`, never the last one (a table has a column).
    mutating func removeColumn(_ column: Int) {
        guard columnCount > 1, header.indices.contains(column) else { return }
        header.remove(at: column)
        alignments.remove(at: column)
        for i in rows.indices { rows[i].remove(at: column) }
        if let s = selection, s.column >= column {
            selection = Cell(row: s.row,
                             column: s.column == column ? min(column, columnCount - 1) : s.column - 1)
        }
    }

    /// Moves column `column` left (`by: -1`) or right (`by: 1`), its header,
    /// alignment and cells together. The selection follows the column.
    mutating func moveColumn(_ column: Int, by offset: Int) {
        let to = column + offset
        guard header.indices.contains(column), header.indices.contains(to) else { return }
        header.swapAt(column, to)
        alignments.swapAt(column, to)
        for i in rows.indices { rows[i].swapAt(column, to) }
        if selection?.column == column { selection?.column = to }
    }

    func canMoveColumn(_ column: Int, by offset: Int) -> Bool {
        header.indices.contains(column) && header.indices.contains(column + offset)
    }

    // MARK: Paste Cells

    /// Copied cells (`clipboardCells(from:)`), filled in from `origin` (the
    /// selection, else the header's first cell) rightward and down. The table
    /// grows by rows and columns as the paste needs; a line break inside a
    /// copied cell becomes a space.
    mutating func pasteCells(_ pasted: [[String]], at origin: Cell? = nil) {
        guard !pasted.isEmpty else { return }
        let start = origin ?? selection ?? Cell(row: 0, column: 0)
        let width = pasted.map(\.count).max() ?? 0
        while columnCount < start.column + width { addColumn(after: columnCount - 1) }
        while rows.count < start.row + pasted.count - 1 {
            rows.append(Array(repeating: "", count: columnCount))
        }
        for (r, cells) in pasted.enumerated() {
            for (c, text) in cells.enumerated() { setCell(start.row + r, start.column + c, to: text) }
        }
        selection = start
    }

    /// The cells Paste Cells reads (fix round 1, M3): the tab-separated
    /// flavour spreadsheets write, by Excel's quote rule; else plain text,
    /// split on tabs and line breaks with every `"` kept — a quote the writer
    /// typed is theirs, not quoting. Nil with no text at all.
    static func clipboardCells(from pasteboard: NSPasteboard) -> [[String]]? {
        if let tsv = pasteboard.string(forType: tabSeparatedType) {
            return TableClipboard.rows(fromTabSeparated: tsv)
        }
        return pasteboard.string(forType: .string)
            .map { TableClipboard.rows(fromTabSeparated: $0, quoting: false) }
    }

    static let tabSeparatedType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")

    // MARK: Return, and what VoiceOver reads

    /// Where Return in `cell` moves the focus (fix round 1, ruling R-S5):
    /// the cell below, header to first body row; nil on the last row, where
    /// Return does nothing. Return in a cell never saves.
    func cellBelow(_ cell: Cell) -> Cell? {
        guard cell.row < rows.count, cell.column >= 0, cell.column < columnCount else { return nil }
        return Cell(row: cell.row + 1, column: cell.column)
    }

    /// A cell's accessibility label: "Header, column 2", "Row 1, column 2".
    static func accessibilityLabel(forCell cell: Cell) -> String {
        cell.row == 0 ? "Header, column \(cell.column + 1)"
            : "Row \(cell.row), column \(cell.column + 1)"
    }

    static func accessibilityLabel(forAlignmentOfColumn column: Int) -> String {
        "Column \(column + 1) alignment"
    }

    /// The row verbs name their row ("Move up row 2", "Remove row 2"); the
    /// header is "the header row".
    static func accessibilityLabel(forRowVerb verb: String, row: Int) -> String {
        row == 0 ? "\(verb) the header row" : "\(verb) row \(row)"
    }

    /// The column verbs name their column ("Move left column 3").
    static func accessibilityLabel(forColumnVerb verb: String, column: Int) -> String {
        "\(verb) column \(column + 1)"
    }

    // MARK: Caption, label and the result

    /// The name as typed, without a typed `tbl:` and outer spaces.
    private var trimmedLabelName: String {
        var name = labelName.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("tbl:") { name.removeFirst(4) }
        return name
    }

    /// Why the label can't be saved, or nil: empty (no label) is fine; a name
    /// must be `ManuscriptLabel.isValidName`, and must not be one the project
    /// already uses (`takenLabels`, which excludes this table's own label).
    var labelProblem: String? {
        let name = trimmedLabelName
        guard !name.isEmpty else { return nil }
        guard ManuscriptLabel.isValidName(name), let label = ManuscriptLabel(reference: "tbl:" + name)
        else { return "A label is letters, digits, - and _, starting with a letter or a digit." }
        guard !takenLabels.contains(label) else {
            return "tbl:\(name) is already a label in this project."
        }
        return nil
    }

    /// Whether Save may be pressed: a writable editor and a label it can write.
    var canSave: Bool { mayWrite && labelProblem == nil }

    /// The table the grid now describes; what Save hands back.
    var table: TableText {
        let name = trimmedLabelName
        let text = TableText.singleLine(caption).trimmingCharacters(in: .whitespaces)
        return TableText(header: header, alignments: alignments, rows: rows,
                         caption: text.isEmpty ? nil : text,
                         label: name.isEmpty ? nil : ManuscriptLabel(reference: "tbl:" + name))
    }

    private func isCell(_ row: Int, _ column: Int) -> Bool {
        row >= 0 && row <= rows.count && column >= 0 && column < columnCount
    }
}

// MARK: - The presenter

/// How `EditorHost` presents the grid and hands its result back to the
/// coordinator that asked (`EditorCoordinator.tableEditor`): `present`
/// suspends until the sheet's Save or Cancel calls `finish`. A plain reference
/// on the host, never read by `EditorHost.body` (tripwire 6): only
/// `TableGridSheetModifier` observes `session`.
@MainActor
@Observable
final class TableGridPresenter {
    struct Session: Identifiable {
        let id = UUID()
        let request: TableGridRequest
    }

    private(set) var session: Session?
    @ObservationIgnored private var continuation: CheckedContinuation<TableText?, Never>?

    /// Shows the grid on `request` and returns the edited table, nil on
    /// Cancel. A session still open is cancelled first. **Cancelling the
    /// awaiting task closes the sheet as cancelled** (fix round 1, I1): the
    /// coordinator's `detach()` cancels its grid task on a document switch,
    /// and a sheet left up would take a Save that lands nowhere.
    func present(_ request: TableGridRequest) async -> TableText? {
        finish(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                session = Session(request: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    /// Closes the sheet with `result` (nil: cancelled). Idempotent.
    func finish(_ result: TableText?) {
        session = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: result)
    }
}

/// Presents `TableGridEditor` while `presenter` has a session. Its own view,
/// so the session's observation invalidates this modifier and never the
/// host's body.
struct TableGridSheetModifier: ViewModifier {
    let presenter: TableGridPresenter

    func body(content: Content) -> some View {
        let session = presenter.session
        return content.sheet(item: Binding(
            get: { session },
            set: { if $0 == nil { presenter.finish(nil) } }
        )) { session in
            TableGridEditor(request: session.request,
                            onCancel: { presenter.finish(nil) },
                            onSave: { presenter.finish($0) })
        }
    }
}

// MARK: - The sheet

/// The grid: alignment pickers over the columns, the header row, the body
/// rows, the row and column verbs on the focused cell, Paste Cells, the
/// caption and the label. Cancel is `.cancelAction`, Save `.defaultAction`.
struct TableGridEditor: View {
    let onCancel: () -> Void
    let onSave: (TableText) -> Void
    @State private var model: TableGridModel
    @FocusState private var focus: TableGridModel.Cell?

    init(request: TableGridRequest, onCancel: @escaping () -> Void,
         onSave: @escaping (TableText) -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        _model = State(initialValue: TableGridModel(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Table").font(.headline)
            if !model.mayWrite {
                Text("This document can’t be changed here, so the table is shown to read.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                grid.padding(4)
            }
            .frame(minHeight: 160, idealHeight: 280, maxHeight: 420)
            .border(Color(nsColor: .separatorColor))
            verbs.disabled(!model.mayWrite)
            Form {
                TextField("Caption", text: $model.caption)
                TextField("Label", text: $model.labelName, prompt: Text("tbl: name"))
                if let problem = model.labelProblem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
            .disabled(!model.mayWrite)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                // Ruling R-S5 (fix round 1, I2): Save is the default button
                // only while no cell has the focus. A default button's Return
                // is a key equivalent, taken before the field sees it, so with
                // it bound a Return typed in a cell would save the table; in a
                // cell Return moves down instead (`onSubmit`). From the
                // caption and label fields Return still saves.
                Button("Save") { onSave(model.table) }
                    .keyboardShortcut(focus == nil ? .defaultAction : nil)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680)
        .onChange(of: focus) { _, cell in
            if let cell { model.selection = cell }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                ForEach(0..<model.columnCount, id: \.self) { column in
                    Picker("Alignment", selection: alignmentBinding(column)) {
                        Text("Default").tag(TableAlignment.none)
                        Text("Left").tag(TableAlignment.leading)
                        Text("Centre").tag(TableAlignment.center)
                        Text("Right").tag(TableAlignment.trailing)
                    }
                    .labelsHidden()
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forAlignmentOfColumn: column))
                    .frame(width: 110)
                    .disabled(!model.mayWrite)
                }
            }
            ForEach(0...model.bodyRowCount, id: \.self) { row in
                GridRow {
                    ForEach(0..<model.columnCount, id: \.self) { column in
                        let cell = TableGridModel.Cell(row: row, column: column)
                        TextField("", text: cellBinding(row, column))
                            .textFieldStyle(.roundedBorder)
                            .fontWeight(row == 0 ? .semibold : .regular)
                            .frame(width: 110)
                            .focused($focus, equals: cell)
                            // R-S5: Return in a cell goes down a row (nothing
                            // on the last); it never saves.
                            .onSubmit { if let below = model.cellBelow(cell) { focus = below } }
                            .accessibilityLabel(TableGridModel.accessibilityLabel(forCell: cell))
                            .disabled(!model.mayWrite)
                    }
                }
            }
        }
    }

    /// The verbs, each acting on the focused cell's row or column.
    private var verbs: some View {
        let at = model.selection ?? TableGridModel.Cell(row: 0, column: 0)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Add Row") { model.addRow(after: at.row) }
                Button("Remove Row") { model.removeRow(at.row) }.disabled(at.row == 0)
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forRowVerb: "Remove", row: at.row))
                Button("Move Up") { model.moveRow(at.row, by: -1) }
                    .disabled(!model.canMoveRow(at.row, by: -1))
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forRowVerb: "Move up", row: at.row))
                Button("Move Down") { model.moveRow(at.row, by: 1) }
                    .disabled(!model.canMoveRow(at.row, by: 1))
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forRowVerb: "Move down", row: at.row))
            }
            HStack {
                Button("Add Column") { model.addColumn(after: at.column) }
                Button("Remove Column") { model.removeColumn(at.column) }
                    .disabled(model.columnCount <= 1)
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forColumnVerb: "Remove", column: at.column))
                Button("Move Left") { model.moveColumn(at.column, by: -1) }
                    .disabled(!model.canMoveColumn(at.column, by: -1))
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forColumnVerb: "Move left", column: at.column))
                Button("Move Right") { model.moveColumn(at.column, by: 1) }
                    .disabled(!model.canMoveColumn(at.column, by: 1))
                    .accessibilityLabel(TableGridModel.accessibilityLabel(forColumnVerb: "Move right", column: at.column))
                Spacer()
                Button("Paste Cells") {
                    if let cells = TableGridModel.clipboardCells(from: .general) {
                        model.pasteCells(cells)
                    }
                }
                .help("Fill cells from the focused one with cells copied from Excel, Numbers or Sheets")
            }
        }
        .controlSize(.small)
    }

    private func cellBinding(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: { model.cell(row, column) },
                set: { model.setCell(row, column, to: $0) })
    }

    private func alignmentBinding(_ column: Int) -> Binding<TableAlignment> {
        Binding(get: { model.alignment(ofColumn: column) },
                set: { model.setAlignment($0, ofColumn: column) })
    }
}
