import SwiftUI
import MaughamCore

/// **One pinned cell a refresh would change** (spec §4.3 Compare): the
/// figure's cell ("A1"), the source cell it reads ("model B2"), the value it
/// shows now and the value the source holds — "missing" where the source is
/// gone. Each value is shown in the reading cell's own format.
struct FigurePinComparisonRow: Equatable, Identifiable {
    let id: String
    let cell: String
    let source: String
    let old: String
    let new: String

    static let missing = "missing"

    /// Compare's rows, in the order `FigureDocument.comparePins` gave them.
    /// Pure.
    static func build(_ comparisons: [PinComparison], table: FigureTable,
                      sourceTitle: (String) -> String,
                      locale: TableLocale = TableLocale(languageTag: nil)) -> [FigurePinComparisonRow] {
        comparisons.map { c in
            let format = table.cells[c.cell]?.format ?? CellFormat()
            let at = A1.columnLetters(c.read.column) + String(c.read.row + 1)
            return FigurePinComparisonRow(
                id: "\(c.cell.row.raw)/\(c.cell.column.raw)/\(c.read.source)/\(c.read.row)/\(c.read.column)",
                cell: FigureGridAddress.string(for: c.cell, in: table) ?? FigureListing.unusedNumber,
                source: "\(sourceTitle(c.read.source)) \(at)",
                old: CellDisplay.string(for: c.old, format: format, locale: locale),
                new: c.new.map { CellDisplay.string(for: $0, format: format, locale: locale) } ?? missing)
        }
    }
}

/// **Compare** (spec §4.3, report plan 8a Task 7): the figure's pinned cells
/// whose source moved on, old and new side by side, and **Refresh**, which
/// re-reads every pin in the figure as one step on the stack of the grid open
/// on it (`FigureActions.refreshPins` → `FigureGridController
/// .refreshPinsFromResearch` → `FigureDocument.refreshPins`). Refresh is
/// offered only where this Mac may edit the figure (the posture, and the
/// window's own refusal — Review, ⌘⌥⇧R, a view-only share) and a grid has it
/// open; otherwise the sheet says why. The rows are read when the sheet opens, and
/// again after a refresh.
struct FigurePinsCompare: View {
    let model: FigureInspectorModel
    /// Why Refresh cannot act (`FigureInspector.refusal`), nil when it can.
    let refusal: String?
    let load: () async -> Void
    let refresh: () -> Task<Void, Never>?
    let done: () -> Void

    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Research has changed").font(.headline)
            if let rows = model.comparisons {
                if rows.isEmpty {
                    Text("Every pinned value matches its source.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Cell"); Text("Reads"); Text("Now"); Text("In Research")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(rows) { row in
                            GridRow {
                                Text(row.cell).monospacedDigit()
                                Text(row.source).lineLimit(1).truncationMode(.middle)
                                Text(row.old).monospacedDigit()
                                Text(row.new).monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
                Button("Refresh") {
                    guard let work = refresh() else { return }
                    refreshing = true
                    Task { @MainActor in
                        await work.value
                        await load()
                        refreshing = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(refusal != nil || refreshing || (model.comparisons?.isEmpty ?? true))
            }
        }
        .padding()
        .frame(minWidth: 380)
        .task { await load() }
    }
}
