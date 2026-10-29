import SwiftUI
import AppKit
import MaughamCore

// MARK: - Reads from Research

/// **One source a figure's pins read** (spec §4.3, §7): a Research table, or
/// a figure parked in Research — its title, the cells read ("B2:C9", the
/// rectangle every pin on it covers), the latest pin's date, and where it
/// stands (`PinStatus`). A value the inspector's model holds; never read in
/// a body.
struct FigurePinSourceRow: Equatable, Identifiable {
    let id: String
    let title: String
    /// The cells read, nil when no pin on it is recorded yet (`unpinned`).
    let range: String?
    /// The latest pin's date, nil with none.
    let pinnedAt: Date?
    let status: PinStatus

    /// The tag beside it; nil while every pin is current.
    var statusText: String? {
        switch status {
        case .current: nil
        case .sourceChanged: "changed"
        case .sourceMissing: "missing"
        case .unpinned: "not pinned"
        }
    }

    /// The figure's pins by source: every source `status` names (what the
    /// host's `pinStatus` answered), with the cells and dates its pins hold.
    /// Ordered by title, then id. Pure.
    static func build(status: [String: PinStatus], pins: [CellKey: [FigureResearchPin]],
                      title: (String) -> String) -> [FigurePinSourceRow] {
        var bySource: [String: [FigureResearchPin]] = [:]
        for pin in pins.values.joined() { bySource[pin.research, default: []].append(pin) }
        return status.map { source, status in
            let held = bySource[source] ?? []
            return FigurePinSourceRow(id: source, title: title(source), range: range(of: held),
                                      pinnedAt: held.map(\.at).max(), status: status)
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    /// The rectangle `pins` cover in their source, in A1 ("B2", "B2:C9").
    static func range(of pins: [FigureResearchPin]) -> String? {
        guard let first = pins.first else { return nil }
        var top = first.row, bottom = first.row, left = first.column, right = first.column
        for pin in pins {
            top = min(top, pin.row); bottom = max(bottom, pin.row)
            left = min(left, pin.column); right = max(right, pin.column)
        }
        let start = A1.columnLetters(left) + String(top + 1)
        guard top != bottom || left != right else { return start }
        return start + ":" + A1.columnLetters(right) + String(bottom + 1)
    }
}

// MARK: - Used in: travel to a line

/// **A "Used in" link, followed** (spec §7): the piece is selected and the
/// caret lands on the line — through the window's one path that selects a
/// piece, waits for its document and then scrolls (`TranslationReveal`'s
/// source reveal, as a publish problem's row uses it), at the line's offset
/// in the paragraph holding it (`TranslationReveal.offset`). A line the op
/// log cannot place selects the piece alone.
enum FigureUseTravel {

    enum Destination: Equatable {
        /// Select the piece, then land on the line in the paragraph holding it.
        case paragraph(TranslationReveal)
        /// The piece alone: no paragraph holds the line (the text moved on).
        case piece(BinderSubject)
    }

    /// A line's place in the op log's text: its paragraph, and where the line
    /// starts in it (UTF-16 units of the paragraph's display text).
    struct Place: Equatable {
        let paragraphId: String
        let offset: Int
    }

    /// Where `line` (from 0) sits in the display text `sequence` joins with a
    /// blank line between paragraphs (`Document.displayText`'s shape, task
    /// anchors stripped). A line in the blank between two paragraphs is the
    /// next one's start; past the end, nil. Pure.
    static func place(atLine line: Int, paragraphs: [String: String],
                      sequence: [String]) -> Place? {
        guard line >= 0 else { return nil }
        var start = 0
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            let lines = MarkdownDisplayFilter.stripTaskAnchorsInline(text)
                .split(separator: "\n", omittingEmptySubsequences: false)
            if line < start + lines.count {
                let within = max(0, line - start)
                let offset = lines.prefix(within).reduce(0) { $0 + $1.utf16.count + 1 }
                return Place(paragraphId: id, offset: offset)
            }
            start += lines.count + 1
        }
        return nil
    }

    /// Where `use` takes the window: the piece's open `Document` answers the
    /// place when one is open (its live text, the text the index read), else
    /// the op log's derived state (tripwire 20).
    @MainActor
    static func destination(for use: FigureListing.Use, store: ProjectStore,
                            documentStore: DocumentStore?) -> Destination {
        let place: Place?
        if let open = documentStore?.document(forDocId: use.docId) {
            place = Self.place(atLine: use.lineIndex, paragraphs: open.paragraphs, sequence: open.sequence)
        } else if let state = try? store.derivedCache.state(forDocId: use.docId, in: store.url) {
            place = Self.place(atLine: use.lineIndex, paragraphs: state.paragraphs, sequence: state.sequence)
        } else {
            place = nil
        }
        guard let place else { return .piece(.item(use.docId)) }
        return .paragraph(TranslationReveal(docId: use.docId, language: nil, paragraphId: place.paragraphId,
                                            offset: place.offset == 0 ? nil : place.offset))
    }

    /// **The travel, posted**: the reveal (the window selects the piece and,
    /// once its document is up, navigates to the paragraph at the line's
    /// offset — `TranslationReveal.perform`), then the same navigation at
    /// once — which, from a persona whose centre shows no manuscript (Plan),
    /// takes the window to Author first (`ManuscriptNavigation`), so the
    /// reveal has an editor to land in; with no editor on that piece yet it
    /// moves no caret. A piece alone is a subject write. `post` is
    /// production's `MaughamEvent.post(_:to: .keyWindow, payload:)`.
    @MainActor
    static func perform(_ destination: Destination, select: (BinderSubject) -> Void,
                        post: (Notification.Name, [String: Any]) -> Void) {
        switch destination {
        case .paragraph(let reveal):
            post(.maughamRevealTranslation, TranslationReveal.payload(reveal))
            post(.maughamNavigateToParagraph, TranslationReveal.navigatePayload(reveal))
        case .piece(let subject):
            select(subject)
        }
    }
}

// MARK: - The model

/// **What the figure inspector shows that costs a read** (report plan 8a
/// Task 7): the figure's pins by source (`FigureDocument.pinStatus` through
/// the window's host — never in a body, loaded on appear and again when the
/// window's figure revision moves), the Compare rows (`comparePins`, when the
/// sheet opens), and the notes and suggestions on the figure's stream — that
/// stream alone, read off the main actor (`ProjectStore.figureNotes`), on
/// appear and when an annotation change names the figure, never on a figure
/// write and never the project walk. Plus the line a refusal is said on.
@MainActor
@Observable
final class FigureInspectorModel {
    let figureId: String
    private(set) var sources: [FigurePinSourceRow] = []
    /// Compare's rows, nil until read.
    private(set) var comparisons: [FigurePinComparisonRow]?
    private(set) var notes: [Annotation] = []
    /// A refusal or failure, said under the actions.
    var message: String?

    init(figureId: String) { self.figureId = figureId }

    /// The pins (through the figure's host, opened for the read when no grid
    /// holds it). A figure that will not open shows none.
    func loadPins(store: ProjectStore, documentStore: DocumentStore) async {
        let read = try? await documentStore.withFigureHost(figureId) { host in
            (await host.pinStatus(), host.state.pins)
        }
        sources = FigurePinSourceRow.build(status: read?.0 ?? [:], pins: read?.1 ?? [:],
                                           title: { Self.sourceTitle($0, in: store) })
    }

    /// The notes on the figure's own stream, read off the main actor.
    func loadNotes(store: ProjectStore) async {
        notes = Self.ordered(await store.figureNotes(figureId))
    }

    /// Compare: each pinned cell a refresh would change, old beside new.
    func loadComparisons(store: ProjectStore, documentStore: DocumentStore) async {
        let read = try? await documentStore.withFigureHost(figureId) { host in
            (await host.comparePins(), host.state.table)
        }
        comparisons = FigurePinComparisonRow.build(
            read?.0 ?? [], table: read?.1 ?? FigureTable(rows: 0, columns: 0),
            sourceTitle: { Self.sourceTitle($0, in: store) })
    }

    /// Notes oldest first.
    static func ordered(_ notes: [Annotation]) -> [Annotation] {
        notes.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Does an annotations-changed post name this figure? (Its notes reload.)
    static func names(_ figureId: String, _ note: Notification) -> Bool {
        note.userInfo?[MaughamEvent.annotationDocIdKey] as? String == figureId
    }

    /// A source's name: the Research item's title, a parked figure's name,
    /// else its id.
    static func sourceTitle(_ id: String, in store: ProjectStore) -> String {
        TreeWalk.find(id: id, in: store.manifest.research)?.title
            ?? store.manifest.figures?.first { $0.id == id }?.name
            ?? id
    }
}

// MARK: - The view

/// **The figure inspector** (report plan 8a Task 7, spec §7): the right
/// column's inspector arm for a figure subject — name (renamed through
/// `FigureActions.rename`, a refusal said and the field put back), number and
/// section, Used in (each line and each cross-reference, a link that selects
/// the piece and lands on the line), Reads from Research (each source, its
/// cells and pin date, with Compare), the notes and suggestions on the
/// figure's stream, and the actions — Open in Window, Send to Research,
/// Import from CSV — through the helper the tree's row menu calls. The
/// actions that write are absent where the posture or the share forbids
/// them (Review Focus 5). Mount it with `.id(figureId)`.
struct FigureInspector: View {
    let figureId: String
    let store: ProjectStore
    let documentStore: DocumentStore
    let listing: FigureListingModel
    let figureWindows: FigureWindows?
    let control: EditorControl
    let persona: Persona
    /// The project window, whose annotation changes reload the notes.
    let window: NSWindow?
    /// The window's subject-picker, for a Used-in link that can only select its piece.
    let select: (BinderSubject) -> Void
    /// Notes' "Show in Notes": the queue, widened, at this figure.
    let showNotes: (String) -> Void

    @State private var model: FigureInspectorModel
    @State private var draftName = ""
    /// The name last sent to the store, so Return and the focus leaving do
    /// not send it twice.
    @State private var committedName: String?
    @FocusState private var nameFocused: Bool
    @State private var showsCompare = false

    init(figureId: String, store: ProjectStore, documentStore: DocumentStore, listing: FigureListingModel,
         figureWindows: FigureWindows?, control: EditorControl, persona: Persona, window: NSWindow?,
         select: @escaping (BinderSubject) -> Void, showNotes: @escaping (String) -> Void) {
        self.figureId = figureId
        self.store = store
        self.documentStore = documentStore
        self.listing = listing
        self.figureWindows = figureWindows
        self.control = control
        self.persona = persona
        self.window = window
        self.select = select
        self.showNotes = showNotes
        _model = State(initialValue: FigureInspectorModel(figureId: figureId))
    }

    /// The one helper (`FigureActions`), as the inspector hands it what it knows.
    static func actions(store: ProjectStore, figureWindows: FigureWindows?, control: EditorControl,
                        persona: Persona, model: FigureInspectorModel) -> FigureActions {
        FigureActions(store: store, figureWindows: figureWindows, typography: control.typography,
                      windowRefusesWrites: { FigureActions.windowRefusesWrites(control: control, persona: persona) },
                      report: { [weak model] in model?.message = $0 })
    }

    private var actions: FigureActions {
        Self.actions(store: store, figureWindows: figureWindows, control: control, persona: persona, model: model)
    }
    private var record: FigureRecord? { store.manifest.figures?.first { $0.id == figureId } }
    /// The listing's row, or the registry's figure as an unused one.
    private var row: FigureListing.Row? {
        if let row = listing.row(forFigureId: figureId) { return row }
        guard let record else { return nil }
        return FigureListing.Row(figureId: record.id, kind: record.kind, name: record.name, caption: "",
                                 number: FigureListing.unusedNumber, usedIn: [], referencedFrom: [],
                                 pieceOfLine: nil)
    }
    private struct LoadKey: Equatable {
        let figureId: String
        let revision: Int
    }

    var body: some View {
        ScrollView {
            if let row {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection(row)
                    LabeledContent("Number") {
                        Text(Self.numberAndSection(row, structure: store.manifest.structure))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    usedInSection(row)
                    Divider()
                    researchSection
                    Divider()
                    notesSection
                    Divider()
                    actionsSection(row)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("This figure is gone", systemImage: "tablecells")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The pins move with the figure (any write, a park, a trust change).
        .task(id: LoadKey(figureId: figureId, revision: documentStore.figureRevision)) {
            await model.loadPins(store: store, documentStore: documentStore)
        }
        // The notes: the figure's own stream, on appear and when an
        // annotation change names it — not on every figure write.
        .task(id: figureId) { await model.loadNotes(store: store) }
        .onProjectEvent(.maughamAnnotationsChanged, url: store.url, window: window) { note in
            guard FigureInspectorModel.names(figureId, note) else { return }
            Task { await model.loadNotes(store: store) }
        }
        .onChange(of: record?.name, initial: true) { _, name in draftName = name ?? "" }
        .sheet(isPresented: $showsCompare) {
            FigurePinsCompare(model: model, refusal: refreshRefusal,
                              load: { await model.loadComparisons(store: store, documentStore: documentStore) },
                              refresh: { actions.refreshPins(figureId) },
                              done: { showsCompare = false })
        }
    }

    /// Why Refresh is not offered, nil when it is (this Mac may edit the
    /// figure and a grid has it open, whose stack takes the step).
    private var refreshRefusal: String? {
        Self.refusal(mayEdit: actions.mayEdit(figureId), hasGrid: actions.hasGrid(figureId))
    }

    // MARK: Sections

    @ViewBuilder
    private func nameSection(_ row: FigureListing.Row) -> some View {
        LabeledContent("Name") {
            if actions.mayEdit(figureId) {
                TextField("", text: $draftName, onCommit: commitName)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    // Leaving the field commits it, as Return does.
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            } else {
                Text(row.name)
            }
        }
    }

    @ViewBuilder
    private func usedInSection(_ row: FigureListing.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Used in").font(.headline)
            if row.usedIn.isEmpty {
                Text("No line uses it").foregroundStyle(.secondary)
            }
            ForEach(Array(row.usedIn.enumerated()), id: \.offset) { _, use in
                useLink(use)
            }
            if !row.referencedFrom.isEmpty {
                Text("Referenced from").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(row.referencedFrom.enumerated()), id: \.offset) { _, use in
                    useLink(use)
                }
            }
        }
    }

    private func useLink(_ use: FigureListing.Use) -> some View {
        Button(Self.useTitle(use, structure: store.manifest.structure)) { travel(to: use) }
            .buttonStyle(.link)
    }

    @ViewBuilder
    private var researchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reads from Research").font(.headline)
            if model.sources.isEmpty {
                Text("Nothing").foregroundStyle(.secondary)
            }
            ForEach(model.sources) { source in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(source.range.map { "\(source.title) \($0)" } ?? source.title)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let pinned = source.pinnedAt {
                        Text(pinned, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    if let tag = source.statusText {
                        Text(tag).font(.caption2).padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            if !model.sources.isEmpty {
                Button("Compare\u{2026}") { showsCompare = true }
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes and suggestions").font(.headline)
            if model.notes.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(model.notes, id: \.id) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Self.kindTitle(note.kind)) \u{00B7} \(note.status.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(note.body).lineLimit(3)
                }
            }
            if !model.notes.isEmpty {
                Button("Show in Notes") { showNotes(figureId) }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ row: FigureListing.Row) -> some View {
        let mayEdit = actions.mayEdit(figureId)
        let offered = Self.offered(mayEdit: mayEdit, kind: row.kind)
        let importRefusal = Self.refusal(mayEdit: mayEdit, hasGrid: actions.hasGrid(figureId))
        VStack(alignment: .leading, spacing: 6) {
            if offered.contains(.openInWindow) {
                Button("Open in Window") { actions.openInWindow(row) }
            }
            if offered.contains(.sendToResearch) {
                SwiftUI.Menu(FigureTableMenu.sendToResearchTitle) {
                    ForEach(actions.sendDestinations(for: row), id: \.self) { destination in
                        Button(destination.title) { actions.sendToResearch(row, to: destination) }
                    }
                }
                .fixedSize()
            }
            if offered.contains(.importCSV) {
                // Shown while no grid can take it, disabled, with the reason.
                Button(FigureTableCommand.importCSV.title) { actions.importFromCSV(figureId) }
                    .disabled(importRefusal != nil)
                if let importRefusal {
                    Text(importRefusal).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Acts

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = record?.name, !trimmed.isEmpty, trimmed != current else {
            draftName = record?.name ?? ""
            return
        }
        guard trimmed != committedName else { return }   // Return, then the focus leaving
        committedName = trimmed
        Self.rename(to: trimmed, actions: actions, model: model, current: { record?.name },
                    revert: { draftName = $0 })
    }

    /// **Rename**: the store's verb; a refusal is said (`model.message`) and
    /// the field is put back to the name the registry holds. Answers the work.
    @discardableResult
    static func rename(to name: String, actions: FigureActions, model: FigureInspectorModel,
                       current: @escaping @MainActor () -> String?,
                       revert: @escaping @MainActor (String) -> Void) -> Task<Void, Never> {
        model.message = nil
        let work = actions.rename(model.figureId, to: name)
        return Task { @MainActor in
            await work.value
            revert(current() ?? name)
        }
    }

    private func travel(to use: FigureListing.Use) {
        FigureUseTravel.perform(
            FigureUseTravel.destination(for: use, store: store, documentStore: documentStore),
            select: select,
            post: { MaughamEvent.post($0, to: .keyWindow, payload: $1) })
    }

    // MARK: Pure

    enum Action: Equatable { case openInWindow, sendToResearch, importCSV }

    /// What the actions row offers: Open in Window always; Send to Research,
    /// and a table's Import, only where this Mac may edit the figure (the
    /// posture and the window's own refusal). Import is enabled only while a
    /// grid is open on it (`refusal`).
    static func offered(mayEdit: Bool, kind: FigureKind) -> [Action] {
        var out: [Action] = [.openInWindow]
        guard mayEdit else { return out }
        out.append(.sendToResearch)
        if kind == .table { out.append(.importCSV) }
        return out
    }

    /// Why Import and Refresh cannot act now, nil when they can: they write
    /// on the open grid's stack, as this Mac's edit.
    static func refusal(mayEdit: Bool, hasGrid: Bool) -> String? {
        guard mayEdit else { return "This figure is read-only here." }
        guard hasGrid else { return FigureActions.openTheTableFirst }
        return nil
    }

    /// "Table 2 · Chapter 3"; an unused figure "— · unused".
    static func numberAndSection(_ row: FigureListing.Row, structure: [StructureItem]) -> String {
        guard let piece = row.pieceOfLine else { return "\(row.number) \u{00B7} unused" }
        return "\(row.number) \u{00B7} \(FigureSectionVerbs.pieceTitle(piece, in: structure))"
    }

    /// "Chapter 3, line 12" — the line counted from 1, as the writer reads
    /// it; the link lands on that line (`FigureUseTravel.Place.offset`).
    static func useTitle(_ use: FigureListing.Use, structure: [StructureItem]) -> String {
        "\(FigureSectionVerbs.pieceTitle(use.docId, in: structure)), line \(use.lineIndex + 1)"
    }

    static func kindTitle(_ kind: AnnotationKind) -> String {
        switch kind {
        case .comment: "Comment"
        case .suggestedChange: "Suggestion"
        case .query: "Query"
        case .craftNote: "Craft note"
        }
    }
}
