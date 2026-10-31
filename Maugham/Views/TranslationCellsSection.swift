import SwiftUI
import MaughamCore

/// **A table's cell translations, as rows** (report plan 9e-1 Task 8, spec
/// §8): the pure half behind the Translation pane's Cells list and the figure
/// inspector's Translations lines, so what each shows is assertable without
/// a window (`TranslationCellRowsTests`).
enum TranslationCellRows {

    /// One live text cell: its A1 address, the source label, its translation
    /// (nil when missing) and the status chip.
    struct Row: Identifiable, Equatable {
        let id: String
        let address: String
        let source: String
        let translation: String?
        let status: TranslationStatus
    }

    /// One orphaned cell translation (a deleted row or column, or a label
    /// turned into a number): where it stood — its A1 while the cell is
    /// still in the table, else "Deleted cell" — and its text. `key` is nil
    /// for a stored key that does not parse, which no purge can address.
    struct OrphanRow: Identifiable, Equatable {
        let id: String
        let address: String
        let text: String
        let key: CellKey?
    }

    /// The figure's live text cells in row-major order.
    static func rows(_ derived: FigureTranslatedTable, table: FigureTable) -> [Row] {
        derived.entries.map { entry in
            Row(id: FigureCellTranslationKey.paragraphId(for: entry.key),
                address: FigureGridAddress.string(for: entry.key, in: table)
                    ?? FigureCellTranslationKey.paragraphId(for: entry.key),
                source: entry.sourceText, translation: entry.translatedText, status: entry.status)
        }
    }

    static let deletedCell = "Deleted cell"

    static func orphanRows(_ derived: FigureTranslatedTable, table: FigureTable) -> [OrphanRow] {
        derived.orphans.compactMap { record in
            guard let text = record.text else { return nil }
            let key = FigureCellTranslationKey.cellKey(fromParagraphId: record.paragraphId)
            let address = key.flatMap { FigureGridAddress.string(for: $0, in: table) } ?? deletedCell
            return OrphanRow(id: record.paragraphId, address: address, text: text, key: key)
        }
    }

    /// **The table figure a paragraph's line names** — the first figure line
    /// in `text` that Publish lays out as a table (`ManuscriptLabel.Kind
    /// .ofFigureLine == .tbl`) and that resolves, against `records`
    /// (`FigureLineResolution`, Publish's rule), to a registered table. Nil
    /// for a paragraph with no such line, and for a line naming a figure the
    /// registry no longer lists (removed: its translations are inert, R4).
    static func tableFigure(inParagraph text: String, documentPath: String,
                            records: [FigureRecord]) -> FigureRecord? {
        guard text.contains("!["), !records.isEmpty else { return nil }
        let index = FigureLineResolution.Index(records)
        for (block, _) in ManuscriptBlocks.parse(MarkdownDisplayFilter.stripAnchors(text)) {
            guard case .figure(_, let path, let label) = block,
                  ManuscriptLabel.Kind.ofFigureLine(path: path, label: label) == .tbl,
                  case .figure(let record) = FigureLineResolution.status(
                    linePath: path, documentPath: documentPath, index: index) else { continue }
            switch record.kind {
            case .table: return record
            case .image, .unknown: continue
            }
        }
        return nil
    }

    /// **Remove orphaned cell translations** — the writer's own act, so it
    /// signs as the `author` (as a paragraph orphan's purge does), through
    /// the one write door's delete form (`TranslationWritePipeline
    /// .performCells`, which asks the permit and posts the update naming the
    /// figure). A refusal is SAID: its sentence goes to the window's notice
    /// channel and comes back; nil means the tombstones landed. A row with
    /// no parseable key is skipped.
    @MainActor
    @discardableResult
    static func purge(
        _ orphans: [OrphanRow], figureId: String, language: String, table: FigureTable,
        projectURL: URL, identities: LocalIdentities = .current,
        deviceState: OpLogDeviceState = .shared
    ) async -> String? {
        let entries = orphans.compactMap { row in
            row.key.map { TranslationWritePipeline.CellEntry(key: $0, delete: true) }
        }
        guard !entries.isEmpty else { return nil }
        do {
            try await TranslationWritePipeline.performCells(
                entries: entries, language: language, figureId: figureId, table: table,
                projectURL: projectURL, actor: .author, identities: identities,
                deviceState: deviceState)
            return nil
        } catch {
            let sentence = error.localizedDescription
            MaughamEvent.postNotice(sentence, projectURL: projectURL)
            return sentence
        }
    }

    // MARK: - The inspector's coverage lines

    /// One language's coverage of a table: "es · 12 of 14 cells", with the
    /// stale count said when there is one.
    struct CoverageLine: Identifiable, Equatable {
        var id: String { language }
        let language: String
        let fresh: Int
        let stale: Int
        let total: Int

        var text: String {
            var line = "\(fresh) of \(total) cell\(total == 1 ? "" : "s")"
            if stale > 0 { line += ", \(stale) stale" }
            return line
        }
    }

    /// The coverage line of each language, sorted by tag; a table with no
    /// text cell has nothing to translate and no lines.
    static func coverage(_ reads: [String: FigureTranslatedTable]) -> [CoverageLine] {
        reads.keys.sorted().compactMap { language in
            guard let derived = reads[language], !derived.entries.isEmpty else { return nil }
            return CoverageLine(language: language, fresh: derived.freshCount,
                                stale: derived.staleCount, total: derived.entries.count)
        }
    }
}

// MARK: - The pane's Cells list

/// **The Translation pane's Cells list** (report plan 9e-1 Task 8): when the
/// caret's paragraph is a table figure's line, that table's text cells in the
/// review language — address, source, translation, status chip — and its
/// orphaned translations with Remove (the author's tombstone through the one
/// write door; a refusal is said in the window's notice line). Read off the
/// typing path, again whenever a cell translation of this figure lands or the
/// window's cards move (a source edit can turn a translation stale).
struct TranslationCellsSection: View {
    let figure: FigureRecord
    let language: String
    let documentStore: DocumentStore
    let projectURL: URL
    /// The window's card version: moves on a figure write.
    let cardVersion: Int

    /// **Whether Remove is offered**: the author's `.translate` on THIS
    /// figure's translation (`DocumentStore.translationPosture(forDocId:)`,
    /// judged by the figure's piece — the class `performCells` refuses by),
    /// asked here rather than handed in, so no caller can pass the chapter's
    /// posture (report plan 9e-1 final fix wave, I1: a pieces-author's chapter
    /// that prints a whole-book table). Reading it in `body` observes the
    /// door's epoch, so a trust change redraws it.
    var mayPurge: Bool {
        documentStore.translationPosture(forDocId: figure.id).allows(.translate)
    }

    /// Resolved through `WindowAccessor`, for the update event's liveness
    /// guard (ADR 0021).
    @State private var window: NSWindow?
    @State private var read: FigureCellTranslationRead?
    @State private var failure: String?
    @State private var reloads = 0

    private struct LoadKey: Equatable {
        let figureId: String
        let language: String
        let cardVersion: Int
        let reloads: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cells (\(language)) — \(figure.name)")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            } else if let read {
                let rows = TranslationCellRows.rows(read.derived, table: read.table)
                if rows.isEmpty {
                    Text("No cell holds typed text to translate.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in cellRow(row) }
                let orphans = TranslationCellRows.orphanRows(read.derived, table: read.table)
                if !orphans.isEmpty {
                    HStack {
                        Text("Orphaned cells").font(.caption.smallCaps()).foregroundStyle(.secondary)
                        Spacer()
                        if mayPurge {
                            Button("Remove All") { purge(orphans, read) }.controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                    ForEach(orphans) { orphan in orphanRow(orphan, read) }
                }
            }
        }
        .task(id: LoadKey(figureId: figure.id, language: language, cardVersion: cardVersion, reloads: reloads)) {
            await load()
        }
        .background(WindowAccessor(window: $window))
        .onProjectEvent(.maughamTranslationDidUpdate, url: projectURL, window: window) { note in
            guard note.userInfo?["figure_id"] as? String == figure.id else { return }
            reloads += 1
        }
    }

    private func cellRow(_ row: TranslationCellRows.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.source).font(.callout)
                Text(row.translation ?? "—").font(.callout)
                    .foregroundStyle(row.translation == nil ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TranslationStatusChip(status: row.status)
        }
    }

    private func orphanRow(_ orphan: TranslationCellRows.OrphanRow,
                           _ read: FigureCellTranslationRead) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(orphan.address).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(orphan.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if mayPurge, orphan.key != nil {
                Button("Remove") { purge([orphan], read) }.controlSize(.small)
            }
        }
    }

    private func load() async {
        do {
            let reads = try await documentStore.figureCellTranslations(
                figureId: figure.id, languages: [language])
            read = reads?[language]
            failure = reads == nil ? "Nothing to translate: this table is in Research, or gone." : nil
        } catch {
            read = nil
            failure = error.localizedDescription
        }
    }

    private func purge(_ orphans: [TranslationCellRows.OrphanRow], _ read: FigureCellTranslationRead) {
        Task { @MainActor in
            await TranslationCellRows.purge(
                orphans, figureId: figure.id, language: language, table: read.table,
                projectURL: projectURL)
        }
    }
}
