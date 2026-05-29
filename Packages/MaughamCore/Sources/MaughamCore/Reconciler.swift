import Foundation

/// Classifies an observed change to a manuscript .md file. Cross-Mac merges
/// happen at the log layer (transparent to UI); only external-tool edits
/// produce visible reconciliation events here.
public enum Reconciler {
    public enum Classification: Equatable {
        case echo
        case silentIngest(changes: [Op.ParagraphChange])
        case needsSheet(orphanCount: Int)
    }

    public static func classify(diskMd: String, derivedMd: String) -> Classification {
        if diskMd == derivedMd { return .echo }

        let diskParsed = ParagraphParser.parse(diskMd)
        let derivedParsed = ParagraphParser.parse(derivedMd)

        // If any paragraph in disk lacks an id, fall to sheet path.
        if diskParsed.contains(where: { $0.id == nil }) {
            return .needsSheet(orphanCount: diskParsed.filter { $0.id == nil }.count)
        }

        // Both sides fully tagged. Compute per-paragraph changes.
        var derivedMap: [String: String] = [:]
        for p in derivedParsed {
            if let id = p.id { derivedMap[id] = p.text }
        }
        var changes: [Op.ParagraphChange] = []
        for p in diskParsed {
            guard let id = p.id else { continue }
            if derivedMap[id] != p.text {
                changes.append(.init(paragraphId: id, prior: derivedMap[id], next: p.text))
            }
        }
        if changes.isEmpty { return .echo }
        return .silentIngest(changes: changes)
    }
}
