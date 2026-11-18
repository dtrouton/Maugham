import Foundation
import MaughamCore

/// One decision under Brief's **Decided**: a ruling the writer stands by, and
/// the statement it was made in.
struct BriefDecision: Identifiable, Equatable {

    /// Where a decision was made — the Book Brief's filter.
    enum Origin: Hashable {
        case book
        case piece(docId: String)
        case lessons
        case firstReader
        case edition(language: String)

        /// A stable spelling for ids; never shown.
        var key: String {
            switch self {
            case .book: return "book"
            case .piece(let docId): return "piece:\(docId)"
            case .lessons: return "lessons"
            case .firstReader: return "first-reader"
            case .edition(let language): return "edition:\(language)"
            }
        }
    }

    let ruling: Ruling
    let origin: Origin

    /// Origin-qualified: a ruling id is derived from its text, so one sentence
    /// ruled in two statements is two decisions with one `ruling.id`.
    var id: String { "\(origin.key)/\(ruling.id)" }
}

/// Decided's order, its fold, what still stands, and the Book's filter. Pure.
enum BriefDecisions {

    /// How many decisions show before the rest fold.
    static let showing = 3

    /// Dated rulings by `ruledOn`, newest first (ties keep file order), then
    /// the undated (hand-typed) ones in file order.
    static func newestFirst(_ rulings: [Ruling]) -> [Ruling] {
        newestFirst(rulings, date: \.ruledOn)
    }

    /// The same order over decisions from several statements; undated ones
    /// keep the order they were gathered in.
    static func newestFirst(_ decisions: [BriefDecision]) -> [BriefDecision] {
        newestFirst(decisions, date: \.ruling.ruledOn)
    }

    /// The first `showing`, and the rest.
    static func split(_ rulings: [Ruling]) -> (showing: [Ruling], folded: [Ruling]) {
        (Array(rulings.prefix(showing)), Array(rulings.dropFirst(showing)))
    }

    /// The rulings that still stand. The lessons ledger's retired entries do
    /// not (`LessonsLedger.kind(of:)`, the ledger's own grammar); every other
    /// kind's rulings all stand.
    static func standing(_ rulings: [Ruling], kind: Statement.Kind) -> [Ruling] {
        guard kind == .lessons else { return rulings }
        return rulings.filter {
            if case .retired = LessonsLedger.kind(of: $0.text) { return false }
            return true
        }
    }

    /// The origins that have at least one decision, in the filter's order: the
    /// book, pieces in manuscript order (a piece the structure no longer holds
    /// after them, by id), the lessons ledger, the first reader, editions by
    /// language tag.
    static func origins(of decisions: [BriefDecision], structure: [StructureItem]) -> [BriefDecision.Origin] {
        let present = Set(decisions.map(\.origin))
        let order = Dictionary(
            TreeWalk.collect(in: structure, where: { $0.type == .document }).enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let pieces = present.compactMap { origin -> String? in
            if case .piece(let docId) = origin { return docId } else { return nil }
        }.sorted { lhs, rhs in
            switch (order[lhs], order[rhs]) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs < rhs
            }
        }
        let editions = present.compactMap { origin -> String? in
            if case .edition(let language) = origin { return language } else { return nil }
        }.sorted()

        var ordered: [BriefDecision.Origin] = []
        if present.contains(.book) { ordered.append(.book) }
        ordered += pieces.map { .piece(docId: $0) }
        if present.contains(.lessons) { ordered.append(.lessons) }
        if present.contains(.firstReader) { ordered.append(.firstReader) }
        ordered += editions.map { .edition(language: $0) }
        return ordered
    }

    /// The decisions made at `origin`; every decision when `origin` is nil.
    static func filtered(_ decisions: [BriefDecision], by origin: BriefDecision.Origin?) -> [BriefDecision] {
        guard let origin else { return decisions }
        return decisions.filter { $0.origin == origin }
    }

    // MARK: - Helper

    private static func newestFirst<T>(_ items: [T], date: (T) -> Date?) -> [T] {
        let dated = items.enumerated().compactMap { index, item in date(item).map { (index, $0, item) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
        return dated + items.filter { date($0) == nil }
    }
}
