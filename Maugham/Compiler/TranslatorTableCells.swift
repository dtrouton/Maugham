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
    /// `TableCellPass.work` does the gathering; this is a pass of one.
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
        guard let pass = TableCellPass(store: store, documentStore: documentStore, projectURL: projectURL)
        else { return [] }
        return try await pass.work(docId: docId, languages: [language], state: state)[language] ?? []
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

/// **One pass over the table cells of several pieces** (report plan 9e-2
/// final fix wave, M4): the book's figures, the trust table and each table's
/// translation posture are resolved ONCE per pass, and each table's coverage
/// in each language is derived once — a table shared by several pieces is not
/// re-derived for every piece that uses it. A round is a pass of one piece;
/// the desk's pre-flight is a pass over every piece it counts.
///
/// **Filtered by the figure's translation posture, as the translator, on the
/// ACTING answer** (`DocumentStore.settledTranslationPosture(forDocId:as:
/// .translator)`, 9e-2 final fix wave I1): a pieces-author's translator never
/// sees a whole-book table's cells — they would be refused at the write door,
/// so they are never briefed — and a table that is merely cold is waited
/// out, never read as "not offered" (controller ruling I: a verb acts on a
/// settled answer). A drawing accessor's `settling` here turned a round that
/// owed only cells into "nothing to translate".
@MainActor
final class TableCellPass {

    private let store: ProjectStore
    private let documentStore: DocumentStore
    private let projectURL: URL
    private var figures: PublishFigures?
    private var trust: TrustTable?
    private var reaches: [String: Bool] = [:]
    /// language → figure id → its work (nil: every text cell fresh).
    private var derived: [String: [String: TableCellWork?]] = [:]

    /// nil — nothing to gather — without a document store or a table figure.
    init?(store: ProjectStore, documentStore: DocumentStore?, projectURL: URL) {
        guard let documentStore,
              (store.manifest.figures ?? []).contains(where: { $0.kind == .table }) else { return nil }
        self.store = store
        self.documentStore = documentStore
        self.projectURL = projectURL
    }

    /// The work each language owes on `docId`'s tables. Every language asked
    /// is a key, `[]` when its tables are done.
    func work(
        docId: String, languages: [String], state: (sequence: [String], paragraphs: [String: String])
    ) async throws -> [String: [TableCellWork]] {
        var out = Dictionary(languages.map { ($0, [TableCellWork]()) }, uniquingKeysWith: { a, _ in a })
        guard !languages.isEmpty,
              let path = TreeWalk.find(id: docId, in: store.manifest.structure)?.path
        else { return out }
        let piece = FigureUse.Piece(path: path, sequence: state.sequence, paragraphs: state.paragraphs)
        let figures: PublishFigures
        if let cached = self.figures {
            figures = cached
        } else {
            figures = await documentStore.translationFigures()
            self.figures = figures
        }
        var used: [FigureUse.Table] = []
        for use in FigureUse.tables(in: [piece], figures: figures).readable {
            let id = use.record.id
            let reaches: Bool
            if let cached = self.reaches[id] {
                reaches = cached
            } else {
                reaches = await documentStore.settledTranslationPosture(forDocId: id, as: .translator)
                    .allows(.translate)
                self.reaches[id] = reaches
            }
            if reaches { used.append(use) }
        }
        guard !used.isEmpty else { return out }

        let owed = languages.flatMap { language in
            used.filter { derived[language]?[$0.record.id] == nil }.map { (language, $0) }
        }
        if !owed.isEmpty {
            let trust: TrustTable
            if let cached = self.trust {
                trust = cached
            } else {
                trust = try await documentStore.figureTrust()
                self.trust = trust
            }
            let projectURL = self.projectURL
            let fresh = try await Task.detached(priority: .userInitiated) {
                try owed.map { language, use -> (String, String, TableCellWork?) in
                    let table: FigureTranslatedTable
                    do {
                        table = try FigureUse.coverage(
                            of: use, language: language, projectURL: projectURL, trust: trust).derived
                    } catch {
                        throw TranslatorOrchestrator.Environment.UnreadableTable(
                            name: use.record.name, underlying: error)
                    }
                    return (language, use.record.id, TableCellWork.work(for: use, derived: table))
                }
            }.value
            for (language, id, work) in fresh {
                derived[language, default: [:]][id] = .some(work)
            }
        }
        for language in languages {
            out[language] = used.compactMap { derived[language]?[$0.record.id] ?? nil }
        }
        return out
    }
}
