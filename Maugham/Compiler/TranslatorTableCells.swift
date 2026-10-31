import Foundation
import MaughamCore

/// **One table a translator round is asked to label** (report plan 9e-2
/// Task 1, R6): a table figure the round's piece uses, and each of its text
/// cells that needs work in the round's language — missing or stale, never
/// fresh, and only a stored literal text cell (`FigureTextCells`, 9e-1's R1):
/// a number, a date or a formula is shared across languages and never goes
/// to the translator.
///
/// The cell's `key` is what the report names it by (`"row:col"`,
/// `FigureCellTranslationKey`); `address` is its A1, for display only —
/// rows and columns move, ids do not. `sourceText` is the cell's literal as
/// briefed, the snapshot a cell written back is hashed against.
struct TableCellWork: Equatable, Sendable {

    struct Cell: Equatable, Sendable {
        let key: CellKey
        let address: String
        let sourceText: String
        /// `.missing` or `.stale`; a fresh cell is never work.
        let status: TranslationStatus
        /// A stale cell's last answer, to reconsider; nil for a missing cell
        /// (and for a stale verbatim one, which carried no text).
        let priorTranslation: String?
    }

    let figureId: String
    let name: String
    let cells: [Cell]

    /// The work one used table holds, from its derivation in the round's
    /// language — nil when every text cell is fresh (the table is done: a
    /// whole-book table already labelled on another piece's round finds
    /// nothing here, R6).
    static func work(for use: FigureUse.Table, derived: FigureTranslatedTable) -> TableCellWork? {
        let cells = derived.entries.compactMap { entry -> Cell? in
            switch entry.status {
            case .fresh: return nil
            case .missing, .stale: break
            }
            return Cell(
                key: entry.key,
                address: FigureGridAddress.string(for: entry.key, in: use.table)
                    ?? FigureCellTranslationKey.paragraphId(for: entry.key),
                sourceText: entry.sourceText,
                status: entry.status,
                priorTranslation: entry.status == .stale ? entry.translatedText : nil)
        }
        guard !cells.isEmpty else { return nil }
        return TableCellWork(figureId: use.record.id, name: use.record.name, cells: cells)
    }
}

extension TranslatorOrchestrator.Environment {

    /// **The tables a translator round on `docId` labels** (R6): the table
    /// figures the piece uses — `FigureUse.tables(in:figures:)`, the coverage
    /// gate's own reader, so a table is work here exactly when the gate would
    /// count it: unparked, readable, each once in first-use order — that the
    /// TRANSLATOR may write, each with its missing and stale text cells.
    ///
    /// **Filtered by the figure's translation posture, as the translator**
    /// (`DocumentStore.translationPosture(forDocId:as: .translator)`): a
    /// pieces-author's translator never sees a whole-book table's cells —
    /// they would be refused at the write door, so they are never briefed. A
    /// `settling` answer (the table still cold) offers nothing, so a cell is
    /// never briefed on a guess; the next round finds it.
    ///
    /// `state` is the paragraphs the round itself briefs, so the figure lines
    /// read are the round's. Throws for a used table's translation file that
    /// is present and will not read — the piece's own rule (P2a D0): a
    /// refusal is not an absence.
    @MainActor
    static func tableCellWork(
        docId: String, language: String, state: (sequence: [String], paragraphs: [String: String]),
        store: ProjectStore, documentStore: DocumentStore?, projectURL: URL
    ) async throws -> [TableCellWork] {
        guard let documentStore,
              (store.manifest.figures ?? []).contains(where: { $0.kind == .table }),
              let path = TreeWalk.find(id: docId, in: store.manifest.structure)?.path
        else { return [] }
        let piece = FigureUse.Piece(path: path, sequence: state.sequence, paragraphs: state.paragraphs)
        let figures = await documentStore.translationFigures()
        let used = FigureUse.tables(in: [piece], figures: figures).readable.filter {
            documentStore.translationPosture(forDocId: $0.record.id, as: .translator)
                .allows(.translate)
        }
        guard !used.isEmpty else { return [] }
        let trust = try await documentStore.figureTrust()
        return try await Task.detached(priority: .userInitiated) {
            try used.compactMap { use in
                let derived: FigureTranslatedTable
                do {
                    derived = try FigureUse.coverage(
                        of: use, language: language, projectURL: projectURL, trust: trust).derived
                } catch {
                    throw UnreadableTable(name: use.record.name, underlying: error)
                }
                return TableCellWork.work(for: use, derived: derived)
            }
        }.value
    }

    /// A used table whose translation file is present and will not read,
    /// named, so the round's refusal says which table.
    struct UnreadableTable: LocalizedError {
        let name: String
        let underlying: Error
        var errorDescription: String? {
            "Table \(name): its translation could not be read — "
                + ((underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription)
        }
    }
}
