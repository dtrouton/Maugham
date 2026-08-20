import Foundation

/// Which pieces demonstrate a publish design, chosen from an `ElementCensus`
/// so the smallest possible sample proves every element kind the book
/// actually uses. Pure and deterministic over its inputs.
public enum SamplePageSelection {

    /// Enough pages to prove a design end-to-end without becoming a second
    /// compile: 1 for the chapter opener (the page a reader turns to first),
    /// 2 for a representative two-page spread (the shape most pages take),
    /// and 3 headroom for whatever specials the census turns up — a title
    /// page, dual dialogue, a verse/lyric interlude — so no one kind gets
    /// crowded out of the sample.
    public static let maxPages = 6

    public struct Selection: Equatable, Sendable {
        /// Ordered: the first chapter always first, then the minimal
        /// additional pieces needed to cover every kind in the census.
        public let pieceIds: [String]
        public let maxPages: Int
        /// Writer-facing lines, one per entry in `pieceIds`, explaining why
        /// that piece is in the sample.
        public let demonstrates: [String]

        public init(pieceIds: [String], maxPages: Int, demonstrates: [String]) {
            self.pieceIds = pieceIds
            self.maxPages = maxPages
            self.demonstrates = demonstrates
        }
    }

    public static func choose(census: ElementCensus, ast: ProjectAST) -> Selection {
        guard let opener = ast.sections.first else {
            return Selection(pieceIds: [], maxPages: maxPages, demonstrates: [])
        }

        var titles: [String: String] = [:]
        for section in ast.sections where titles[section.pieceID] == nil {
            titles[section.pieceID] = section.title
        }

        var pieceIds: [String] = [opener.pieceID]
        var selected: Set<String> = [opener.pieceID]
        var demonstrates: [String] = [
            "chapter opener — \u{2018}\(opener.title)\u{2019}",
        ]

        // Walk `Kind.allCases` (declared order) rather than `census.kinds`
        // (a Set) — determinism must never ride on hash-iteration order.
        for kind in ElementCensus.Kind.allCases where census.kinds.contains(kind) {
            guard let pieceID = census.firstPiece[kind] else { continue }
            guard !selected.contains(pieceID) else { continue }
            selected.insert(pieceID)
            pieceIds.append(pieceID)
            let title = titles[pieceID] ?? pieceID
            demonstrates.append("\(ElementCensus.label(for: kind)) — \u{2018}\(title)\u{2019}")
        }

        return Selection(pieceIds: pieceIds, maxPages: maxPages, demonstrates: demonstrates)
    }
}
