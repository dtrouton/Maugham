import Foundation
import MaughamCore

/// **The book's figure index** (report plan 8a Task 2): every registered
/// figure with the number the book gives it, the lines that use it and the
/// cross-references that point at it — what the tree's Figures section, the
/// centre grid's bottom bar and the figure inspector read.
///
/// Pure: `build` reads a `ReferenceIndex` (whose `numberedLines` number every
/// table and figure, labelled or not, as publishing does) and the registry.
/// A figure line names its figure by its path, resolved against the piece's
/// own path by `FigureLineResolution.Index`, the editor's card lookup; a line
/// whose path names no record, or two, is not listed. A figure with no line
/// is listed with the number "—".
///
/// **The numbers follow the text, not the registry**: a figure's number is its
/// first line's, so moving the text renumbers it and nothing in the list does.
enum FigureListing {

    /// A place in a piece: its id and the line, from 0.
    struct Use: Hashable, Sendable {
        let docId: String
        let lineIndex: Int
    }

    struct Row: Equatable, Sendable, Identifiable {
        let figureId: String
        let kind: FigureKind
        let name: String
        /// The first line's caption; empty for a figure with no line, or a
        /// line with none.
        let caption: String
        /// "Table 2" or "Figure 1" in the book's words (`ReferenceIndex.words`),
        /// or `unusedNumber` when no line uses the figure.
        let number: String
        /// Every line that uses the figure, in reading order.
        let usedIn: [Use]
        /// Every cross-reference to a label one of those lines registered, in
        /// reading order.
        let referencedFrom: [Use]
        /// The piece holding the first line, nil when unused.
        let pieceOfLine: String?

        var id: String { figureId }
        var isUnused: Bool { usedIn.isEmpty }
    }

    /// The number an unused figure shows.
    static let unusedNumber = "—"

    /// The registry's figures, numbered: those the book uses in reading order
    /// of their first line, then the unused ones by name. `documentPathOf`
    /// answers a piece's project-relative path, which a line's path is
    /// resolved against; a piece it cannot answer lists nothing.
    static func build(index: ReferenceIndex, records: [FigureRecord],
                      documentPathOf: (String) -> String?) -> [Row] {
        let lookup = FigureLineResolution.Index(records)
        var firstLine: [String: ReferenceIndex.NumberedLine] = [:]
        var uses: [String: [Use]] = [:]
        var labels: [ManuscriptLabel: String] = [:]
        var order: [String] = []
        var paths: [String: String?] = [:]
        for line in index.numberedLines {
            guard let linePath = line.path else { continue }
            let documentPath: String?
            if let held = paths[line.docId] {
                documentPath = held
            } else {
                documentPath = documentPathOf(line.docId)
                paths[line.docId] = documentPath
            }
            guard let documentPath,
                  case .figure(let record) = lookup.record(forLinePath: linePath,
                                                           documentPath: documentPath)
            else { continue }
            if firstLine[record.id] == nil {
                firstLine[record.id] = line
                order.append(record.id)
            }
            uses[record.id, default: []].append(Use(docId: line.docId, lineIndex: line.line))
            if let label = line.targetLabel { labels[label] = record.id }
        }
        var references: [String: [Use]] = [:]
        for reference in index.crossReferences {
            guard let figureId = labels[reference.label] else { continue }
            references[figureId, default: []].append(Use(docId: reference.docId,
                                                         lineIndex: reference.line))
        }

        var byId: [String: FigureRecord] = [:]
        for record in records where byId[record.id] == nil { byId[record.id] = record }
        var rows: [Row] = order.compactMap { id in
            guard let record = byId[id], let line = firstLine[id] else { return nil }
            let word = line.kind == .table ? index.words.table : index.words.figure
            return Row(figureId: id, kind: record.kind, name: record.name, caption: line.caption,
                       number: "\(word) \(line.ordinal)", usedIn: uses[id] ?? [],
                       referencedFrom: references[id] ?? [], pieceOfLine: line.docId)
        }
        let unused = byId.values.filter { firstLine[$0.id] == nil }.sorted { a, b in
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
        rows += unused.map { record in
            Row(figureId: record.id, kind: record.kind, name: record.name, caption: "",
                number: unusedNumber, usedIn: [], referencedFrom: [], pieceOfLine: nil)
        }
        return rows
    }
}
