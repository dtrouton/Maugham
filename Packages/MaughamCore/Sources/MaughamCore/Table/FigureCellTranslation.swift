import Foundation

/// The wire spelling of a figure cell's translation key: `"<row id>:<column id>"` in
/// `TranslationRecord.paragraphId`. The colon is outside the id alphabet, so it parses back
/// unambiguously. Nothing else spells this format.
public enum FigureCellTranslationKey {
    public static func paragraphId(for key: CellKey) -> String { "\(key.row.raw):\(key.column.raw)" }

    /// Nil for anything that is not exactly two non-empty halves around one colon.
    public static func cellKey(fromParagraphId s: String) -> CellKey? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return CellKey(row: RowID(String(parts[0])), column: ColumnID(String(parts[1])))
    }
}

public enum FigureTextCells {
    /// A text cell is a stored literal, non-blank text value. A formula whose result is text,
    /// a bool, an error, a number, a date or an empty cell is not: formulas are shared across
    /// languages and print as computed from the source.
    public static func isTextCell(_ cell: Cell?) -> Bool {
        guard let cell, case .value(.text(let s)) = cell.content else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The literal of a text cell, else nil.
    public static func sourceText(_ cell: Cell?) -> String? {
        guard isTextCell(cell), let cell, case .value(.text(let s)) = cell.content else { return nil }
        return s
    }
}

public struct FigureTranslatedTable: Sendable {
    public struct Entry: Sendable {
        public let key: CellKey
        public let sourceText: String
        public let translatedText: String?
        public let status: TranslationStatus
        public let verbatim: Bool
    }
    public let language: String
    /// Live text cells in row-major order.
    public let entries: [Entry]
    /// Latest records that no live text cell answers to (deleted row or column, text turned
    /// into something else, or a key that does not parse). A revive re-attaches them.
    public let orphans: [TranslationRecord]

    public var freshCount: Int { entries.lazy.filter { $0.status == .fresh }.count }
    public var staleCount: Int { entries.lazy.filter { $0.status == .stale }.count }
    public var missingCount: Int { entries.lazy.filter { $0.status == .missing }.count }

    /// What a body prints: the translation of each fresh cell that has one. A stale or missing
    /// cell is absent, so the body falls back to the source text.
    public var freshLabels: [CellKey: String] {
        var out: [CellKey: String] = [:]
        for e in entries where e.status == .fresh {
            if let t = e.translatedText { out[e.key] = t }
        }
        return out
    }
}

public enum FigureTranslationDeriver {
    /// Mirrors `TranslationDeriver`: freshness is `sourceHash == hash(source)`, derived, never
    /// stored; orphans come from the same latest-wins/tombstone-removes view.
    public static func derive(records: [TranslationRecord], table: FigureTable,
                              language: String) -> FigureTranslatedTable {
        let latest = TranslationStore.latestByParagraph(records)
        var entries: [FigureTranslatedTable.Entry] = []
        var claimed = Set<String>()
        for row in table.rows {
            for column in table.columns {
                let key = CellKey(row: row, column: column)
                guard let source = FigureTextCells.sourceText(table[key]) else { continue }
                let id = FigureCellTranslationKey.paragraphId(for: key)
                if let rec = latest[id] {
                    claimed.insert(id)
                    entries.append(.init(key: key, sourceText: source, translatedText: rec.text,
                                         status: rec.sourceHash == TranslationHash.hash(source) ? .fresh : .stale,
                                         verbatim: rec.verbatim))
                } else {
                    entries.append(.init(key: key, sourceText: source, translatedText: nil,
                                         status: .missing, verbatim: false))
                }
            }
        }
        let orphans = latest.values
            .filter { !claimed.contains($0.paragraphId) }
            .sorted { $0.paragraphId < $1.paragraphId }
        return FigureTranslatedTable(language: language, entries: entries, orphans: orphans)
    }
}
