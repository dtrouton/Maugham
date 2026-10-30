import SwiftUI
import AppKit
import MaughamCore

/// **Insert ▸ Existing Figure…** (report plan 8b Task 3, Denver's ruling
/// D8b-1): the one way a figure the book already has reaches the text at the
/// caret. A figure no line uses yet — one made from Research, or one left
/// unused — has its figure line placed (`EditorCoordinator.placeExistingFigure`).
/// **A figure already placed is never placed twice** (the controller's ruling
/// at the Task 3 review): choosing it writes a cross-reference to its line's
/// label instead (`@tbl:cash`, the cross-reference picker's own form), and a
/// placed figure whose line has no label cannot be referred to — its row is
/// shown disabled, saying so; no label is invented.
///
/// The picker lists every figure of the window's `FigureListing` but the
/// parked ones: those to place first, then those to refer to in reading
/// order. **"Used" is the listing's or this document's live text's**
/// (`liveUses`): the listing is current only after a settle, so a figure
/// placed a moment ago is already a reference.
///
/// Pure here (`entries`, `liveUses`, `filter` and the keyboard rules),
/// pinned without a window; the sheet is `ExistingFigurePickerSession`,
/// presented on the editor's window — never an `NSPopover` on the text
/// (tripwire 5's shape). Either write is one Route A step, one ⌘Z.
enum ExistingFigurePicker {

    /// What choosing an entry does.
    enum Action: Equatable {
        /// Place the figure's line (no line uses it yet).
        case place
        /// Write a cross-reference to the label its line defines.
        case refer(ManuscriptLabel)
        /// Nothing: the figure is placed but its line has no label. The
        /// sentence says what to do.
        case unavailable(String)
    }

    /// One figure the picker offers, and what choosing it writes.
    struct Entry: Equatable, Identifiable {
        let figureId: String
        /// What the row reads: "— cash (unused)", "Refer to Table 2 · Cash flows · Chapter 1".
        let title: String
        /// The record's name, matched by the filter too.
        let name: String
        /// The figure line's path, written from this document's folder
        /// (`FigureIngest.relativePath`).
        let linePath: String
        /// `tbl:` for a table, `fig:` for a picture.
        let labelKind: ManuscriptLabel.Kind
        /// The caption a placed line carries — the placeholder — selected
        /// once written.
        let caption: String
        let action: Action

        var id: String { figureId }
        /// No line uses it yet: choosing places its line.
        var isUnused: Bool { action == .place }
        /// Whether choosing it writes anything.
        var isEnabled: Bool {
            if case .unavailable = action { return false }
            return true
        }
        /// The disabled row's sentence.
        var note: String? {
            if case .unavailable(let why) = action { return why }
            return nil
        }

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

    /// A figure line in this document's live text: its label and caption.
    struct LiveUse: Equatable {
        let label: ManuscriptLabel?
        let caption: String
    }

    /// The figures `text` (this document's live text, at `documentPath`) has
    /// a line for, by figure id — each one's first line. A line resolves to
    /// its figure as the editor's cards resolve it (`FigureLineResolution`).
    static func liveUses(in text: String, records: [FigureRecord],
                         documentPath: String) -> [String: LiveUse] {
        let lookup = FigureLineResolution.Index(records)
        var uses: [String: LiveUse] = [:]
        for (block, _) in ManuscriptBlocks.parse(text) {
            guard case .figure(let caption, let path, let label) = block,
                  case .figure(let record) = lookup.record(forLinePath: path, documentPath: documentPath),
                  uses[record.id] == nil else { continue }
            uses[record.id] = LiveUse(label: label, caption: caption)
        }
        return uses
    }

    /// The window's listing as the picker offers it.
    ///
    /// - Parked figures are left out (`isParked`, the card's answer), and
    ///   figures of a kind this build cannot write a line for.
    /// - A figure the listing numbers, or one with a line in this document's
    ///   live text (`live`, from `liveUses`), is **used** — unless every use
    ///   the listing knows is in this document and the live text has none
    ///   (its line was cut since the settle): then it is to place: it is offered as a
    ///   reference to its line's label. That label is the live line's when
    ///   the first line is this document's (`docId`), else the index's
    ///   (`firstLineLabel`); none makes the row unavailable.
    /// - Order: those to place first (the listing's name order), then the
    ///   used ones in the listing's reading order, then any used only in the
    ///   live text (placed since the last settle).
    ///
    /// `pieceTitle` names a piece by document id.
    @MainActor static func entries(listing: [FigureListing.Row], records: [FigureRecord],
                                   isParked: (String) -> Bool, documentPath: String, docId: String,
                                   live: [String: LiveUse],
                                   firstLineLabel: (FigureListing.Row) -> ManuscriptLabel?,
                                   pieceTitle: (String) -> String) -> [Entry] {
        var byId: [String: FigureRecord] = [:]
        for record in records where byId[record.id] == nil { byId[record.id] = record }
        var toPlace: [Entry] = [], listed: [Entry] = [], liveOnly: [Entry] = []
        for row in listing where !isParked(row.figureId) {
            guard let record = byId[row.figureId],
                  let kind = ProjectStore.labelKind(of: record.kind) else { continue }
            func entry(_ title: String, _ action: Action) -> Entry {
                Entry(figureId: row.figureId, title: title, name: record.name,
                      linePath: FigureIngest.relativePath(fromDocument: documentPath, toResearch: record.path),
                      labelKind: kind, caption: FigureIngest.captionPlaceholder, action: action)
            }
            let liveUse = live[row.figureId]
            // Every use the (settle-lagged) listing knows is this document's,
            // and the live text holds none: its line was cut since — unused.
            let goneFromHere = liveUse == nil && row.usedIn.allSatisfy { $0.docId == docId }
            if !row.isUnused && !goneFromHere {
                let label = row.pieceOfLine == docId && liveUse != nil
                    ? liveUse?.label : firstLineLabel(row)
                let what = row.caption.isEmpty ? row.name : row.caption
                let place = [row.number, what, row.pieceOfLine.map(pieceTitle) ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
                listed.append(label.map { entry("Refer to " + place, .refer($0)) }
                    ?? entry(place, .unavailable("Give \(row.number) a label to refer to it")))
            } else if let liveUse {
                let what = liveUse.caption.isEmpty ? row.name : liveUse.caption
                let place = "\(what) \u{00B7} \(pieceTitle(docId))"
                liveOnly.append(liveUse.label.map { entry("Refer to " + place, .refer($0)) }
                    ?? entry(place, .unavailable("Give this figure a label to refer to it")))
            } else {
                toPlace.append(entry("\(FigureListing.unusedNumber) \(row.name) (unused)", .place))
            }
        }
        return toPlace + listed + liveOnly
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

    // MARK: - The keyboard

    /// The selection once the filter shows `shown`: kept while it is still
    /// shown and enabled, else the first enabled row, else none.
    static func selection(keeping current: String?, in shown: [Entry]) -> String? {
        if let current, shown.contains(where: { $0.id == current && $0.isEnabled }) { return current }
        return shown.first(where: \.isEnabled)?.id
    }

    /// ↑ (`step` -1) or ↓ (+1) from the filter field: the next enabled row,
    /// stopping at either end; from no selection, the first (↓) or last (↑).
    static func selection(moving current: String?, by step: Int, in shown: [Entry]) -> String? {
        let enabled = shown.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        guard let at = enabled.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? enabled.first?.id : enabled.last?.id
        }
        return enabled[max(0, min(enabled.count - 1, at + step))].id
    }

    /// The entry Return (or a double-click) chooses: the selected row, when
    /// it is shown and enabled.
    static func chosen(_ selection: String?, in shown: [Entry]) -> Entry? {
        shown.first { $0.id == selection && $0.isEnabled }
    }

    // MARK: - Words

    /// The undo step a placed line names.
    static let actionName = "Insert Existing Figure"
    /// The undo step a written reference names.
    static let referenceActionName = "Insert Cross-Reference"
    /// Told when the book has no figure to offer.
    static let noFiguresMessage = "This book has no figures to insert yet."
    /// Told when the chosen figure went to Research while the picker was open.
    static let parkedMessage = "That figure is in Research now, so it wasn’t inserted. Use it in the document first."
    /// Told when the editor would not take the write.
    static let refusedMessage = "The figure couldn’t be inserted: this document can’t be written to now."
    /// Told when the caret is inside code, where a reference never resolves.
    static let insideCodeMessage = "A cross-reference can’t go inside code. Move the cursor out of the code and try again."
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

    /// The writer chose `entry`: the sheet ends, then the coordinator acts.
    func choose(_ entry: ExistingFigurePicker.Entry) {
        guard isOpen else { return }
        close()
        onChoose(entry)
    }

    func cancel() {
        guard isOpen else { return }
        close()
    }

    /// Ends the sheet without writing anything (the editor going away).
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
/// ↑/↓ in the field move the selection over the enabled rows, Return
/// inserts the selected row, Esc cancels, a double-click inserts. A
/// disabled row shows why beneath its title.
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
                .onSubmit { choose(selection, in: shown) }
                .onKeyPress(.downArrow) {
                    selection = ExistingFigurePicker.selection(moving: selection, by: 1, in: shown)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = ExistingFigurePicker.selection(moving: selection, by: -1, in: shown)
                    return .handled
                }
            List(shown, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).lineLimit(1).truncationMode(.middle)
                    if let note = entry.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                .tag(entry.id)
            }
            .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() },
                         primaryAction: { ids in choose(ids.first, in: shown) })
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
                Button("Insert") { choose(selection, in: shown) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ExistingFigurePicker.chosen(selection, in: shown) == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            selection = ExistingFigurePicker.selection(keeping: nil, in: shown)
            filterFocused = true
        }
        .onChange(of: query) { _, _ in
            selection = ExistingFigurePicker.selection(keeping: selection, in: self.shown)
        }
    }

    private func choose(_ id: String?, in shown: [ExistingFigurePicker.Entry]) {
        if let entry = ExistingFigurePicker.chosen(id, in: shown) { onChoose(entry) }
    }
}
