import SwiftUI
import AppKit
import MaughamCore

/// **Insert ▸ Existing Figure…** (report plan 8b Task 3, Denver's ruling
/// D8b-1): the one way a line for a figure the book already has is placed —
/// a figure made from Research, one left unused, or one used elsewhere (a
/// second line: one figure, two uses). The picker lists every figure of the
/// window's `FigureListing` but the parked ones, unused first and then in
/// reading order, and the chosen one's line is written at the caret through
/// Route A (`EditorCoordinator.placeExistingFigure`), one ⌘Z.
///
/// Pure here (`entries`, `filter`), pinned without a window; the sheet is
/// `ExistingFigurePickerSession`, which the coordinator presents on the
/// editor's window — never an `NSPopover` on the text (tripwire 5's shape).
enum ExistingFigurePicker {

    /// One figure the picker offers, and the line it writes.
    struct Entry: Equatable, Identifiable {
        let figureId: String
        /// What the row reads: "— cash (unused)", "Table 2 · Cash flows · Chapter 1".
        let title: String
        /// The record's name, matched by the filter too.
        let name: String
        /// The figure line's path, written from this document's folder
        /// (`FigureIngest.relativePath`).
        let linePath: String
        /// `tbl:` for a table, `fig:` for a picture.
        let labelKind: ManuscriptLabel.Kind
        /// The caption the line carries: the figure's first line's, or the
        /// placeholder for an unused one. Selected once written.
        let caption: String
        let isUnused: Bool

        var id: String { figureId }

        /// `![caption](path){#tbl:name}` — the label the record's name, so
        /// send, rename and relabel find it; a legacy name that cannot be a
        /// label writes the line without one.
        var line: String {
            guard ManuscriptLabel.isValidName(name) else {
                return "![\(FigureIngest.keptCaption(caption))](\(linePath))"
            }
            return FigureIngest.figureLine(path: linePath, kind: labelKind, name: name, caption: caption)
        }

        /// Where the caption sits in `line`, after its `![`.
        var captionRange: NSRange {
            NSRange(location: 2, length: (FigureIngest.keptCaption(caption) as NSString).length)
        }
    }

    /// The window's listing as the picker offers it: parked figures left out
    /// (`isParked`, the card's answer), unused first in the listing's order
    /// (by name), then the used ones in reading order. A figure of a kind
    /// this build cannot write a line for is left out. `pieceTitle` names the
    /// piece holding a used figure's first line.
    @MainActor static func entries(listing: [FigureListing.Row], records: [FigureRecord],
                        isParked: (String) -> Bool, documentPath: String,
                        pieceTitle: (String) -> String) -> [Entry] {
        var byId: [String: FigureRecord] = [:]
        for record in records where byId[record.id] == nil { byId[record.id] = record }
        let shown = listing.filter { !isParked($0.figureId) }
        let ordered = shown.filter(\.isUnused) + shown.filter { !$0.isUnused }
        return ordered.compactMap { row in
            guard let record = byId[row.figureId],
                  let kind = ProjectStore.labelKind(of: record.kind) else { return nil }
            let title: String
            if row.isUnused {
                title = "\(FigureListing.unusedNumber) \(row.name) (unused)"
            } else {
                let what = row.caption.isEmpty ? row.name : row.caption
                let piece = row.pieceOfLine.map(pieceTitle) ?? ""
                title = [row.number, what, piece].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            }
            return Entry(figureId: row.figureId, title: title, name: record.name,
                         linePath: FigureIngest.relativePath(fromDocument: documentPath,
                                                             toResearch: record.path),
                         labelKind: kind,
                         caption: row.caption.isEmpty ? FigureIngest.captionPlaceholder : row.caption,
                         isUnused: row.isUnused)
        }
    }

    /// Type-to-filter: the entries whose row or name holds every word of
    /// `query`, ignoring case and diacritics; an empty query keeps them all.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            words.allSatisfy { word in
                entry.title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || entry.name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// What the menu item and the undo step say.
    static let actionName = "Insert Existing Figure"
    /// Told when the book has no figure to place.
    static let noFiguresMessage = "This book has no figures to insert yet."
}

/// **One visit to the picker**: a sheet on the editor's window holding
/// `ExistingFigurePickerView`. `choose` ends the sheet, then hands the
/// coordinator the entry; `cancel` only ends it. Held by the coordinator
/// (`existingFigurePicker`) while open.
@MainActor
final class ExistingFigurePickerSession {
    let entries: [ExistingFigurePicker.Entry]
    private(set) var isOpen = false
    private(set) var sheet: NSWindow?
    private weak var parent: NSWindow?
    private let onChoose: (ExistingFigurePicker.Entry) -> Void
    private let onClose: () -> Void

    init(entries: [ExistingFigurePicker.Entry],
         onChoose: @escaping (ExistingFigurePicker.Entry) -> Void,
         onClose: @escaping () -> Void) {
        self.entries = entries
        self.onChoose = onChoose
        self.onClose = onClose
    }

    /// The sheet, on `window`.
    func present(on window: NSWindow) {
        let view = ExistingFigurePickerView(
            entries: entries,
            onChoose: { [weak self] in self?.choose($0) },
            onCancel: { [weak self] in self?.cancel() })
        let controller = NSHostingController(rootView: view)
        let sheet = NSWindow(contentViewController: controller)
        sheet.setContentSize(NSSize(width: 460, height: 360))
        self.sheet = sheet
        parent = window
        isOpen = true
        window.beginSheet(sheet)
    }

    /// The writer chose `entry`: the sheet ends, then the line is placed.
    func choose(_ entry: ExistingFigurePicker.Entry) {
        guard isOpen else { return }
        close()
        onChoose(entry)
    }

    func cancel() {
        guard isOpen else { return }
        close()
    }

    /// Ends the sheet without placing anything (the editor going away).
    func close() {
        guard isOpen else { return }
        isOpen = false
        if let sheet {
            if let parent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        }
        sheet = nil
        onClose()
    }
}

/// The picker's face: a filter field, the figures, Cancel and Insert.
/// Return inserts the selected row, Esc cancels, a double-click inserts.
struct ExistingFigurePickerView: View {
    let entries: [ExistingFigurePicker.Entry]
    let onChoose: (ExistingFigurePicker.Entry) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var filterFocused: Bool

    private var shown: [ExistingFigurePicker.Entry] {
        ExistingFigurePicker.filter(entries, query: query)
    }

    var body: some View {
        let shown = shown
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Existing Figure").font(.headline)
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit { insertSelection(in: shown) }
            List(shown, selection: $selection) { entry in
                Text(entry.title).lineLimit(1).truncationMode(.middle).tag(entry.id)
            }
            .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() },
                         primaryAction: { ids in
                             if let id = ids.first, let entry = shown.first(where: { $0.id == id }) {
                                 onChoose(entry)
                             }
                         })
            .overlay {
                if shown.isEmpty {
                    Text(entries.isEmpty ? "No figures." : "No figure matches.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { insertSelection(in: shown) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected(in: shown) == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            selection = shown.first?.id
            filterFocused = true
        }
        .onChange(of: query) { _, _ in
            let now = self.shown
            if !now.contains(where: { $0.id == selection }) { selection = now.first?.id }
        }
    }

    private func selected(in shown: [ExistingFigurePicker.Entry]) -> ExistingFigurePicker.Entry? {
        shown.first { $0.id == selection }
    }

    private func insertSelection(in shown: [ExistingFigurePicker.Entry]) {
        if let entry = selected(in: shown) { onChoose(entry) }
    }
}
