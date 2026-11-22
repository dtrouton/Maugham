import Foundation
import MaughamCore

/// **An edition's Status, as values** (shell p4 Task 5): one row per piece of
/// the book — its translation (fresh / stale / missing), its own latest
/// finished round, how many of that round's changes still want a look, its
/// trend, and what every cell says. Pure: `EditionStatusView`'s host reads
/// the sources once per key and hands them here; nothing on a row's body
/// path reaches the disk (tripwire 4).
enum EditionStatusRows {

    /// **What a chapter the read could not open is called** (issue #43,
    /// F-D): the writer's own title, the failure's sentence beneath.
    static func couldNotRead(_ title: String) -> String {
        "Couldn\u{2019}t read \(title)"
    }

    struct Row: Equatable, Identifiable {
        let piece: StructureItem
        /// This edition's figures for the piece, or nil where the walk has
        /// none (nothing translated and nobody asked, or an unreadable piece).
        let translation: EditionStatus.DocumentRow?
        /// The piece's own newest finished round in this language.
        let latestRound: TranslationRound?
        /// That round's departures nobody has settled.
        let changesToLookAt: Int
        /// Notes per round for this piece, oldest first.
        let trend: [Int]
        var id: String { piece.id }
    }

    /// **The rows, in the book's order**: every document that is not a
    /// Collection's reference, joined by id to `report` (this edition's rows,
    /// one per document), `rounds` and `trends`. A round or trend for a piece
    /// the manifest no longer holds is dropped by construction.
    static func rows(structure: [StructureItem], report: [EditionStatus.DocumentRow],
                     rounds: [String: TranslationRound], trends: [String: [Int]]) -> [Row] {
        let byDoc = Dictionary(report.map { ($0.documentId, $0) }, uniquingKeysWith: { first, _ in first })
        return ReviewBoardRows.derive(structure: structure).compactMap { row in
            guard row.kind == .piece, row.item.type == .document else { return nil }
            let round = rounds[row.id]
            return Row(piece: row.item, translation: byDoc[row.id], latestRound: round,
                       changesToLookAt: round.map(changesToLookAt) ?? 0,
                       trend: trends[row.id] ?? [])
        }
    }

    /// **A departure still to look at**: the translator did nothing with it
    /// (`outcome == nil`) and the writer has not said Fine (`dismissed`, or
    /// the legacy `.dismissed` outcome).
    static func changesToLookAt(_ round: TranslationRound) -> Int {
        round.departures.filter(isToLookAt).count
    }

    /// **The one predicate** (shell p4 Task 6): Status counts what it
    /// holds, and an edition's To resolve lists exactly those departures.
    static func isToLookAt(_ departure: TranslationRound.DepartureRecord) -> Bool {
        departure.outcome == nil && departure.dismissed != true
    }

    // MARK: - What each cell says

    /// One cell: its terse text (the column's floor), its long wording (any
    /// wider), and the sentence its help and VoiceOver read.
    struct Cell: Equatable {
        let text: String
        let long: String
        let help: String
        init(text: String, long: String? = nil, help: String) {
            self.text = text
            self.long = long ?? text
            self.help = help
        }
        static let empty = Cell(text: "", help: "")

        /// The wording for the width the grid has.
        func wording(wide: Bool) -> String { wide ? long : text }
    }

    /// The translation cell. Unreadable says so (RULING-54) rather than a
    /// number that would be short; no figures at all is nothing.
    static func translation(_ row: Row, unreadable: Bool) -> Cell {
        if unreadable { return Cell(text: "\u{2014}", help: "\(row.piece.title) could not be read") }
        guard let t = row.translation else { return .empty }
        let total = t.fresh + t.stale + t.missing
        let help = "\(t.fresh) fresh \u{00B7} \(t.stale) stale \u{00B7} \(t.missing) missing"
        if total == 0 { return Cell(text: "Not started", help: "Nothing translated yet") }
        // Long: every number that wants work, worst first.
        let wants = [t.missing > 0 ? "\(t.missing) missing" : nil,
                     t.stale > 0 ? "\(t.stale) stale" : nil].compactMap { $0 }
        if t.missing > 0 { return Cell(text: "\(t.missing) missing", long: wants.joined(separator: " \u{00B7} "), help: help) }
        if t.stale > 0 { return Cell(text: "\(t.stale) stale", long: wants.joined(separator: " \u{00B7} "), help: help) }
        return Cell(text: "Fresh", long: "All \(t.fresh) fresh", help: help)
    }

    /// The round cell: its number and day, and how it ended in the help.
    static func round(_ row: Row) -> Cell {
        guard let round = row.latestRound else { return .empty }
        let day = round.startedAt.formatted(.dateTime.day().month(.abbreviated))
        let ended: String
        if round.failed, let leg = round.stoppedAt {
            ended = "failed while \(leg.verb)"
        } else {
            ended = "finished"
        }
        return Cell(text: "#\(round.number) \u{00B7} \(day)\(round.failed ? " !" : "")",
                    long: "Round \(round.number) \u{00B7} \(day) \u{00B7} \(ended)",
                    help: "Round \(round.number), \(round.startedAt.formatted(date: .abbreviated, time: .omitted)), \(ended)")
    }

    static func questions(_ row: Row) -> Cell {
        let count = row.translation?.openQueries ?? 0
        guard count > 0 else { return .empty }
        let words = "\(count) open \(count == 1 ? "question" : "questions")"
        return Cell(text: "\(count)", long: "\(count) \(count == 1 ? "question" : "questions")", help: words)
    }

    static func changes(_ row: Row) -> Cell {
        let count = row.changesToLookAt
        guard count > 0 else { return .empty }
        return Cell(text: "\(count)", long: "\(count) \(TranslationVocabulary.toLookAt.lowercased())",
                    help: "\(count) from the last round \(TranslationVocabulary.toLookAt.lowercased())")
    }

    /// The last three rounds' note counts, oldest first.
    static func trend(_ row: Row) -> Cell {
        guard !row.trend.isEmpty else { return .empty }
        return Cell(text: row.trend.suffix(3).map(String.init).joined(separator: "\u{2192}"),
                    long: row.trend.suffix(5).map(String.init).joined(separator: " \u{2192} "),
                    help: "Notes per round: " + row.trend.map(String.init).joined(separator: ", "))
    }

    /// The publishing cell: the contents and where the piece starts.
    static func publishing(_ section: PublishConfig.Section?) -> Cell {
        let section = section ?? PublishConfig.Section()
        let start: String?
        switch section.startOn {
        case .recto: start = "right"
        case .verso: start = "left"
        case .any: start = nil
        }
        let toc = section.includeInToc ? "In contents" : "Not in contents"
        let text = section.includeInToc ? "TOC" : "No TOC"
        return Cell(text: text + (start.map { " \u{00B7} \($0.prefix(1).uppercased())" } ?? ""),
                    long: toc + (start.map { " \u{00B7} \($0) page" } ?? ""),
                    help: toc + (start.map { ", starts on a \($0) page" } ?? ""))
    }

    // MARK: - The click

    /// **What a row's click opens** (Denver, 2026-11-21, answer 3): the
    /// chapter, read in this edition's language — through `TranslationReveal`
    /// at its first paragraph, the route that lands a piece in a language. The
    /// Source edition, or a piece with no paragraph, opens the piece.
    enum Opening: Equatable {
        case reveal(TranslationReveal)
        case piece(String)
    }

    /// A chapter with nothing translated yet opens in the source: there is
    /// no text in the language to read.
    static func opening(pieceId: String, language: String, isSource: Bool,
                        hasTranslation: Bool = true, firstParagraph: String?) -> Opening {
        guard !isSource, hasTranslation, let firstParagraph else { return .piece(pieceId) }
        return .reveal(TranslationReveal(docId: pieceId, language: language,
                                         paragraphId: firstParagraph))
    }

    /// **Whether a row has anything to read in the language**: fresh or
    /// stale paragraphs.
    static func hasTranslation(_ row: Row?) -> Bool {
        guard let t = row?.translation else { return false }
        return t.fresh + t.stale > 0
    }

    /// **What VoiceOver hears on a row**: the title, then every cell that
    /// says something, in its whole sentence — the cells sit inside the
    /// row's one button, so the label is all of them. (The publishing cell is
    /// its own element, with its own label.)
    static func accessibilityLabel(_ row: Row, unreadable: Bool, isSource: Bool) -> String {
        var parts = [row.piece.title]
        if !isSource {
            parts += [translation(row, unreadable: unreadable), round(row), questions(row),
                      changes(row), trend(row)].map(\.help)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// **Unreadable chapters, named above the rows** (the desk's standing
    /// line, RULING-54): an edition whose walk could not open a chapter does
    /// not show it as empty.
    static func notices(_ unreadable: [EditionStatus.UnreadableDocument]) -> [(headline: String, detail: String)] {
        unreadable.map { (EditionStatusRows.couldNotRead($0.title), $0.reason) }
    }
}

/// **The one word for what a translation round leaves the writer to settle**
/// (owner's answer 7, 2026-11-22): the translator's changes AND the
/// paragraphs that departed from the source untouched — so not "Changes".
/// To resolve's chip, the edition Status column, its cells, their help and
/// VoiceOver say this, and only this
/// (`EditionStatusRowsTests.test_whatARoundLeavesIsToLookAtEverywhereTheWriterSeesIt`).
enum TranslationVocabulary {
    static let toLookAt = "To look at"
    /// The Status column's name in its help and VoiceOver.
    static let toLookAtColumnName = "To look at from the last round"
}
