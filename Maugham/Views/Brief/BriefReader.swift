import Foundation
import MaughamCore

/// **What a Brief scope holds**, read once (shell plan 3). A value; the view
/// draws it.
struct BriefSnapshot: Equatable {
    let scope: BriefScope
    /// The stored synopsis — the line field's value — nil when it trims to
    /// empty. (The DISPLAYED line, with the intent's opening as fallback, is
    /// `BriefLine.display`.) Nil for the Book and an edition.
    let line: String?
    /// The whole statement — what `ClauseMarks.applies` compares. Nil when
    /// there is none yet, and when it would not read (then it is named in
    /// `unreadable`, never read as empty).
    let intentText: String?
    /// `StatementEssay.half(of: intentText)`: Going for's prose.
    let intentEssay: String?
    /// Decided: every standing decision in scope, newest first.
    let decisions: [BriefDecision]
    /// What applies from the Book: its intent's essay (a piece and a Part only).
    let bookIntentEssay: String?
    /// The Book's own decisions, newest first (a piece and a Part only).
    let bookDecisions: [Ruling]
    /// What Claude has read off the text and the writer has not confirmed.
    let unconfirmedReadings: Int
    /// Statement ids that would not read (RULING-54).
    let unreadable: [String]

    static func empty(_ scope: BriefScope) -> BriefSnapshot {
        BriefSnapshot(scope: scope, line: nil, intentText: nil, intentEssay: nil, decisions: [],
                      bookIntentEssay: nil, bookDecisions: [], unconfirmedReadings: 0, unreadable: [])
    }
}

/// Reads a `BriefSnapshot` from store-level values only: the manifest's
/// synopsis, statements through `ProjectStore.statementText(of:)` (the live
/// statement `Document` if one is open, else the derived cache) and the bible
/// store's facts. **It never loads a manuscript `Document`**
/// (`BriefReaderTests.test_noBriefSourceLoadsAManuscriptDocument`), so a
/// piece's Brief reads the same whether the piece is open or not.
@MainActor
enum BriefReader {

    static func read(scope: BriefScope, store: ProjectStore, bible: BibleStore?) -> BriefSnapshot {
        var reading = Reading(store: store)
        let facts = bible?.allFacts() ?? []
        let structure = store.manifest.structure

        switch scope {
        case .piece(let docId):
            let intent = reading.text(of: store.statement(kind: .intent, scope: .document(docId)))
            let decisions = reading.decisions(.intent, .document(docId), origin: .piece(docId: docId))
            let book = reading.book()
            return BriefSnapshot(
                scope: scope, line: BriefLine.stored(TreeWalk.find(id: docId, in: structure)?.synopsis),
                intentText: intent, intentEssay: intent.map(StatementEssay.half(of:)),
                decisions: BriefDecisions.newestFirst(decisions),
                bookIntentEssay: book.essay, bookDecisions: book.decisions,
                unconfirmedReadings: BibleStratum.facts(for: .document(docId), in: facts).count,
                unreadable: reading.unreadable)

        case .part(let groupId, let docIds):
            let decisions = docIds.flatMap {
                reading.decisions(.intent, .document($0), origin: .piece(docId: $0))
            }
            let book = reading.book()
            return BriefSnapshot(
                scope: scope, line: BriefLine.stored(TreeWalk.find(id: groupId, in: structure)?.synopsis),
                intentText: nil, intentEssay: nil,
                decisions: BriefDecisions.newestFirst(decisions),
                bookIntentEssay: book.essay, bookDecisions: book.decisions,
                unconfirmedReadings: docIds.reduce(0) {
                    $0 + BibleStratum.facts(for: .document($1), in: facts).count
                },
                unreadable: reading.unreadable)

        case .book:
            let intent = reading.text(of: store.statement(kind: .intent, scope: .project))
            var decisions = reading.decisions(.intent, .project, origin: .book)
            let pieces = TreeWalk.collect(in: structure) {
                $0.type == .document && $0.pieceKind != .reference
            }
            for piece in pieces {
                decisions += reading.decisions(.intent, .document(piece.id), origin: .piece(docId: piece.id))
            }
            decisions += reading.decisions(.lessons, .project, origin: .lessons)
            decisions += reading.decisions(.firstReader, .project, origin: .firstReader)
            for language in editionLanguages(in: store.manifest.statements) {
                decisions += reading.decisions(.editionBrief(language), .project,
                                               origin: .edition(language: language))
            }
            return BriefSnapshot(
                scope: scope, line: nil,
                intentText: intent, intentEssay: intent.map(StatementEssay.half(of:)),
                decisions: BriefDecisions.newestFirst(decisions),
                bookIntentEssay: nil, bookDecisions: [],
                unconfirmedReadings: BibleStratum.facts(for: .project, in: facts).count,
                unreadable: reading.unreadable)

        case .edition(let language):
            let brief = reading.text(of: store.statement(kind: .editionBrief(language), scope: .project))
            let decisions = reading.decisions(.editionBrief(language), .project,
                                              origin: .edition(language: language))
            return BriefSnapshot(
                scope: scope, line: nil,
                intentText: brief, intentEssay: brief.map(StatementEssay.half(of:)),
                decisions: BriefDecisions.newestFirst(decisions),
                bookIntentEssay: nil, bookDecisions: [], unconfirmedReadings: 0,
                unreadable: reading.unreadable)

        case .elsewhere, .outside:
            return .empty(scope)
        }
    }

    /// Every edition brief's language tag, sorted.
    private static func editionLanguages(in statements: [Statement]) -> [String] {
        Set(statements.compactMap { statement -> String? in
            if case .editionBrief(let language) = statement.kind { return language }
            return nil
        }).sorted()
    }

    /// One read's statement texts, each statement read once, and the ids that
    /// would not read.
    @MainActor
    private struct Reading {
        let store: ProjectStore
        var unreadable: [String] = []
        private var cache: [String: String?] = [:]

        init(store: ProjectStore) { self.store = store }

        /// The statement's whole text; nil for no statement, and nil (named in
        /// `unreadable`) for one that throws.
        mutating func text(of statement: Statement?) -> String? {
            guard let statement else { return nil }
            if let cached = cache[statement.id] { return cached }
            let text: String?
            do {
                text = try store.statementText(of: statement)
            } catch {
                text = nil
                unreadable.append(statement.id)
            }
            cache[statement.id] = text
            return text
        }

        /// The standing rulings of `(kind, scope)`'s statement, tagged.
        mutating func decisions(_ kind: Statement.Kind, _ scope: Statement.Scope,
                                origin: BriefDecision.Origin) -> [BriefDecision] {
            guard let text = text(of: store.statement(kind: kind, scope: scope)) else { return [] }
            return BriefDecisions.standing(RulingsStratum.rows(in: text), kind: kind)
                .map { BriefDecision(ruling: $0, origin: origin) }
        }

        /// The Book's intent essay and its decisions, newest first.
        mutating func book() -> (essay: String?, decisions: [Ruling]) {
            guard let text = text(of: store.statement(kind: .intent, scope: .project)) else { return (nil, []) }
            return (StatementEssay.half(of: text),
                    BriefDecisions.newestFirst(RulingsStratum.rows(in: text)))
        }
    }
}
