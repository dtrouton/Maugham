import Foundation

/// **A figure line's registered figure** (report plan 7a Task 2): the
/// `(document path, path as written on the line)` to `FigureRecord` lookup the
/// card needs. Pure and string-only, no disk (tripwire 58: the record paths
/// are synced data and are only ever compared, never opened).
///
/// The line's path is standardised against the document's folder by
/// `FigurePathRule` — the rule Publish uses — so a line written
/// `../../figures/x.csv` from `pieces/<id>/x.md` finds `figures/x.csv`; the
/// comparison with `FigureRecord.path` is case-insensitive.
public enum FigureLineResolution {

    public enum Resolution: Equatable, Sendable {
        case figure(FigureRecord)
        /// No path-rule-clean line, or no record on that path.
        case none
        /// Two or more records share the path (the store refuses to render
        /// these).
        case ambiguous([FigureRecord])
    }

    public static func record(
        forLinePath linePath: String, documentPath: String, records: [FigureRecord]
    ) -> Resolution {
        guard case .inside(let target, _) = FigurePathRule.lexical(linePath, piecePath: documentPath)
        else { return .none }
        let wanted = target.joined(separator: "/").lowercased()
        let hits = records.filter { key(of: $0.path) == wanted }
        switch hits.count {
        case 0: return .none
        case 1: return .figure(hits[0])
        default: return .ambiguous(hits)
        }
    }

    /// A record's path standardised the same way (`.`/`..` folded, empty
    /// segments dropped), lowercased; a path that climbs out keys to itself
    /// so it can never match a clean target.
    private static func key(of path: String) -> String {
        let parts = FigurePathRule.standardised(FigurePathRule.components(path))
            ?? ["\u{0}" + path]
        return parts.joined(separator: "/").lowercased()
    }
}
