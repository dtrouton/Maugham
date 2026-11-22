import SwiftUI
import MaughamCore

// MARK: - The decisions (pure)

/// **What an edition's To resolve holds beyond its questions** (shell p4
/// Task 6; the design's "To resolve" for an edition). The questions are the
/// walks' (`ResolveReader.snapshot`'s `.edition` arm); these four kinds are
/// read here, once per key, without loading a document:
///
/// - **changes**: each piece's latest finished round in the language
///   (`TranslationRoundStore.latestFinishedByPiece`, intersected with the
///   book), its departures nobody has settled (`EditionStatusRows.isToLookAt`,
///   the Status column's own predicate);
/// - **glossary proposals** of those rounds, neither adopted nor skipped;
/// - **a design proposal** still pending — in every edition's list, the
///   Source's included (the plan's call 1: its gate covers any edition's
///   centre, and every edition's pages use the design);
/// - **the last compile's problems** (`PublishCentreModel.compileRunner`'s
///   own state — the facts the centre's problems cover draws, never
///   re-derived).
///
/// The Source edition has no changes or glossary proposals.
enum ResolveEditionItems {

    /// One read of an edition's own sources.
    struct Read: Equatable {
        /// The edition this read is of — a list moving between editions never
        /// draws one edition's rounds under another's head.
        var language: String?
        /// Each piece's latest finished round in the language, for the
        /// pieces the book holds.
        var rounds: [String: TranslationRound] = [:]
        /// The rows the round report draws, for the changes listed — keyed by
        /// the item's id, built once per read (tripwire 4).
        var departureRows: [String: TranslationRoundReport.DepartureRow] = [:]
        /// Every design proposal, newest first (`DesignProposalStore.list`).
        var proposals: [DesignProposalStore.Proposal] = []
        /// The last compile's problems, as the window's runner holds them.
        var problems: [TectonicLogParser.Diagnostic] = []
        /// Every document's title, for a problem's row.
        var problemRows: [String: PublishProblems.Row] = [:]
        /// Whether any round has ever finished in this language — what the
        /// empty list says.
        var hasRounds = false
        /// The language's newest round of ANY outcome, when it is one of the
        /// book's pieces' (fix round I3) — what the head says stopped.
        var newestRound: TranslationRound?
        /// **The pieces Run Whole Book runs** — the imprint the window stands
        /// on (`UIState.publishImprint`, the one choice the edition's compile
        /// bar shows and changes), folded over the book (review I5). Its
        /// count, its help, its offer and the run itself are all asked over
        /// this one set.
        var runBook: [String] = []
        /// That imprint's name; nil for the whole book.
        var imprint: String?

        static let empty = Read()

        /// The proposal still waiting on a decision — at most one
        /// (`DesignProposalStore.stage` supersedes the rest).
        var pendingProposal: DesignProposalStore.Proposal? {
            proposals.first { $0.status == .pending }
        }
    }

    /// **The four kinds, for one edition**, in the reader's order: the
    /// pending design proposal, the problems (exact repeats once), then per
    /// piece in `docIds` order its changes and its glossary proposals.
    static func items(language: String, isSource: Bool, docIds: [String],
                      read: Read) -> [ResolveItem] {
        var items: [ResolveItem] = []
        if let pending = read.pendingProposal { items.append(.designProposal(pending)) }
        var seen = Set<String>()
        for problem in read.problems {
            // `read.problems` is already `stoppingProblems` — the one
            // predicate the tree's mark asks too.
            let item = ResolveItem.compileProblem(problem)
            if seen.insert(item.id).inserted { items.append(item) }
        }
        guard !isSource else { return items }
        for docId in docIds {
            guard let round = read.rounds[docId] else { continue }
            for departure in round.departures where EditionStatusRows.isToLookAt(departure) {
                items.append(.translationChange(docId: docId, language: language,
                                                round: round.number, departure))
            }
            // One row per identity — an older ledger may hold the same pair
            // twice (N2); answering the row answers every copy.
            var listed = Set<String>()
            for proposal in round.glossaryProposals
            where isOpen(proposal) && listed.insert(proposal.identity).inserted {
                items.append(.glossaryProposal(docId: docId, language: language,
                                               round: round.number, proposal))
            }
        }
        return items
    }

    /// **The compile problems To resolve lists and the tree marks** — the
    /// one predicate (controller's ruling, shell p4 Task 6 fix round): only
    /// what stopped a book. A refused or failed compile's errors; a compile
    /// that landed, warnings and all, lists nothing (its warnings stay behind
    /// Show Problems in the centre).
    @MainActor
    static func stoppingProblems(_ state: CompileRunState) -> [TectonicLogParser.Diagnostic] {
        guard PublishCentreModel.coversWithProblems(state) else { return [] }
        return state.problems.filter { $0.level == .error }
    }

    // MARK: An edition's question — the one spelling

    /// **The language an open note is a question in**, lowercased; nil for a
    /// settled note or one with no language. The one spelling of "an
    /// edition's question" (review M13): the reader's `.edition` arm, the
    /// live splice and the tree's mark all ask it.
    static func questionLanguage(of annotation: Annotation) -> String? {
        guard annotation.status == .open, let language = annotation.language else { return nil }
        return language.lowercased()
    }

    /// Whether `annotation` is one of `language`'s questions.
    static func isQuestion(_ annotation: Annotation, in language: String) -> Bool {
        questionLanguage(of: annotation) == language.lowercased()
    }

    /// A glossary proposal nobody has answered.
    static func isOpen(_ proposal: TranslationRound.GlossaryProposalRecord) -> Bool {
        !proposal.adopted && proposal.skipped != true
    }

    /// `latestFinishedByPiece` holds every piece a round ever finished on —
    /// unpruned (Task 2's review): only the book's pieces count.
    static func rounds(_ byPiece: [String: TranslationRound],
                       docIds: [String]) -> [String: TranslationRound] {
        let held = Set(docIds)
        return byPiece.filter { held.contains($0.key) }
    }

    /// **Whether a round leaves anything for the writer** — a change to look
    /// at or a glossary proposal to answer. The tree's mark asks it.
    static func leavesSomething(_ round: TranslationRound) -> Bool {
        round.departures.contains(where: EditionStatusRows.isToLookAt)
            || round.glossaryProposals.contains(where: isOpen)
    }

    // MARK: The head's letter

    /// **The translator's newest letter** among the pieces' latest rounds:
    /// the highest-numbered round (numbers rise per language) that says
    /// something — its `summary`, else the collator's overall verdict.
    static func newestLetter(_ rounds: [String: TranslationRound]) -> TranslationRound? {
        rounds.values.filter { letter(of: $0) != nil }.max { $0.number < $1.number }
    }

    /// What a round says, in its own words; nil when it says nothing.
    static func letter(of round: TranslationRound) -> String? {
        for text in [round.summary, round.collatorOverall] {
            if let words = text?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                return words
            }
        }
        return nil
    }

    /// The letter's byline: who wrote it, about which chapter, and when.
    static func signature(translator: String, chapter: String?, round: TranslationRound) -> String {
        let day = round.startedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\u{2014} \(translator)"
            + (chapter.map { " \u{00B7} \($0)" } ?? "")
            + " \u{00B7} round \(round.number) \u{00B7} \(day)"
    }

    static let openTheReportTitle = "Open the report"

    /// The head with no letter yet: who would write one.
    static func noLetterLine(translator: String, hasRounds: Bool) -> String {
        hasRounds
            ? "\(translator) has not written a letter on the latest rounds."
            : "\(translator) has not run a round in this edition yet."
    }

    // MARK: The empty list

    /// **What an edition with nothing in its list says** — true, and the next
    /// step where there is one.
    static func clearLine(language: String, isSource: Bool, hasRounds: Bool,
                          readingBook: Bool = false) -> String {
        if isSource {
            return "Nothing about the book\u{2019}s design or its last compile waits on you. "
                + "Run design above to ask for a new design."
        }
        let edition = LanguageName.labelled(language)
        // **Never "nothing waits" over a book not yet read** (fix round 2,
        // N4): until the window's first walk has reached every chapter, a
        // question not yet reached is simply absent.
        if readingBook { return readingBookLine }
        guard hasRounds else {
            return "No round has run in \(edition) yet. Run one above; what the translator "
                + "asks and changes will be listed here."
        }
        return "Nothing in the \(edition) edition waits on you: every question is answered "
            + "and every change from the latest rounds is settled."
    }

    static let readingBookLine =
        "Still reading the book\u{2019}s questions\u{2026} What the translator asks will be listed here."

    // MARK: The tree's mark

    /// **Which edition rows carry the mark** (Task 3's dot, through
    /// `ResolvePresence.rowMark`): every edition while a design proposal
    /// waits or the last compile left problems (the book level is in every
    /// edition's list); a translated edition while one of the book's pieces
    /// holds an open question in its language, or a latest round leaves it
    /// something. Pure; the watch reads the rounds off the main actor.
    ///
    /// - Parameters:
    ///   - editions: the tree's rows — (language, isSource).
    ///   - questionLanguages: lowercased languages with an open question on
    ///     one of the book's pieces (from the presence read's snapshot).
    ///   - roundsLeaveSomething: lowercased languages whose latest rounds
    ///     leave a change or a glossary proposal.
    static func markedEditions(editions: [(language: String, isSource: Bool)],
                               questionLanguages: Set<String>,
                               roundsLeaveSomething: Set<String>,
                               bookLevel: Bool) -> Set<String> {
        var marked: Set<String> = []
        for edition in editions {
            let key = edition.language.lowercased()
            if bookLevel
                || (!edition.isSource
                    && (questionLanguages.contains(key) || roundsLeaveSomething.contains(key))) {
                marked.insert(edition.language)
            }
        }
        return marked
    }

    /// The languages an open question on the book's pieces is in — from the
    /// Book-scope snapshot the presence read already holds (no walk of its
    /// own; a figure's note is no piece's question).
    static func questionLanguages(_ snapshot: ResolveSnapshot) -> Set<String> {
        var languages: Set<String> = []
        for case .note(let note) in snapshot.items where !DocumentClass.isFigureDocId(note.docId) {
            if let language = questionLanguage(of: note.annotation) { languages.insert(language) }
        }
        return languages
    }

    // MARK: - The reads (disk, off the body path)

    /// **The rounds, from disk** — off the main actor: one ledger decode for
    /// the language (none for the Source).
    nonisolated static func readRounds(projectURL: URL, language: String, isSource: Bool,
                                       docIds: [String])
    -> (rounds: [String: TranslationRound], newest: TranslationRound?) {
        guard !isSource else { return ([:], nil) }
        let read = TranslationRoundStore(projectURL: projectURL)
            .latestFinishedByPieceAndNewest(language: language)
        let newest = read.newest.flatMap { docIds.contains($0.docId) ? $0 : nil }
        return (Self.rounds(read.byPiece, docIds: docIds), newest)
    }

    /// **The languages whose latest rounds leave something** — the mark's
    /// disk half, off the main actor: one ledger decode per language.
    nonisolated static func languagesLeavingSomething(projectURL: URL, languages: [String],
                                                     docIds: [String]) -> Set<String> {
        let store = TranslationRoundStore(projectURL: projectURL)
        var out: Set<String> = []
        for language in languages {
            let rounds = Self.rounds(store.latestFinishedByPiece(language: language), docIds: docIds)
            if rounds.values.contains(where: leavesSomething) { out.insert(language.lowercased()) }
        }
        return out
    }

    /// Whether a design proposal waits — the mark's other disk half (the
    /// store is the main actor's; a listing of a few small files).
    @MainActor
    static func hasPendingProposal(projectURL: URL) -> Bool {
        ((try? DesignProposalStore(projectURL: projectURL).list()) ?? [])
            .contains { $0.status == .pending }
    }

    /// **The whole read, for To resolve's `.task`**: the ledger off the main
    /// actor, the proposals' listing, then — only for the pieces whose
    /// changes are listed, a yield between pieces — the source paragraphs the
    /// rows quote (`currentParagraphState`: the open document, else the
    /// derived state; never a load), and the problems' rows.
    @MainActor
    static func read(language: String, isSource: Bool, docIds: [String],
                     problems: [TectonicLogParser.Diagnostic],
                     store: ProjectStore, documentStore: DocumentStore) async -> Read {
        let projectURL = store.url
        let scope = runScope(docIds: docIds, persisted: documentStore.uiState.publishImprint,
                             config: (try? PublishConfigStore.read(in: projectURL)) ?? nil)
        let ledger = await Task.detached(priority: .userInitiated) {
            readRounds(projectURL: projectURL, language: language, isSource: isSource, docIds: docIds)
        }.value
        let rounds = ledger.rounds
        let proposals = (try? DesignProposalStore(projectURL: projectURL).list()) ?? []
        var read = Read(language: language, rounds: rounds, proposals: proposals,
                        problems: problems, hasRounds: !rounds.isEmpty,
                        newestRound: ledger.newest,
                        runBook: scope.docIds, imprint: scope.imprint)
        let liveTranslator = EditionStatus.translatorName(for: language, in: store.manifest)
            ?? TranslationRoundReport.anonymousTranslator
        for (docId, round) in rounds {
            // The name the round was signed with (review M3).
            let translator = round.signedBy(liveName: liveTranslator)
            let wanted = Set(round.departures.filter(EditionStatusRows.isToLookAt).map(\.paragraphId))
            guard !wanted.isEmpty else { continue }
            var sources: [String: String] = [:]
            if let state = try? currentParagraphState(documentId: docId, store: store,
                                                      documentStore: documentStore,
                                                      projectURL: projectURL) {
                for id in wanted {
                    guard let raw = state.paragraphs[id] else { continue }
                    let text = MarkdownDisplayFilter.stripAnchors(raw)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { sources[id] = text }
                }
            }
            for row in TranslationRoundReport.departureRows(round, sources: sources,
                                                            translatorName: translator) {
                guard let departure = round.departures.first(where: { $0.id == row.id }),
                      EditionStatusRows.isToLookAt(departure) else { continue }
                let item = ResolveItem.translationChange(docId: docId, language: language,
                                                         round: round.number, departure)
                read.departureRows[item.id] = row
            }
            // One chapter's derived state per main-actor step: a whole-book
            // round leaves every chapter's changes, and nothing that scales
            // with the book holds the main actor (`EditionStatusCostTests`).
            await Task.yield()
            if Task.isCancelled { break }
        }
        let titles = PublishProblems.titles(in: store.manifest.structure)
        for row in PublishProblems.rows(problems, titles: titles) {
            read.problemRows[ResolveItem.compileProblem(problems[row.id]).id] = row
        }
        return read
    }

    /// **A round as a verb wrote it, in a read** (review C1): the piece's
    /// round replaced when it is the same round; anything else unchanged.
    static func patching(_ read: Read, with updated: TranslationRound) -> Read {
        guard read.language?.caseInsensitiveCompare(updated.language) == .orderedSame,
              read.rounds[updated.docId]?.number == updated.number else { return read }
        var next = read
        next.rounds[updated.docId] = updated
        return next
    }

    /// The key an edition row's author verbs are cached under: its piece;
    /// empty for a book-level item (no piece's posture is asked).
    static func authorKey(_ item: ResolveItem) -> String {
        switch item {
        case .translationChange, .glossaryProposal: return item.docId
        case .note, .finding, .todo, .designProposal, .compileProblem: return ""
        }
    }

    /// **What Run Whole Book runs**: the imprint the window stands on — the
    /// persisted choice the edition's compile bar shows, read through the
    /// desk's own normalisation (a name the config no longer declares is the
    /// whole book) — folded over the book's pieces. Pure.
    static func runScope(docIds: [String], persisted: String?,
                         config: PublishConfig?) -> (docIds: [String], imprint: String?) {
        let imprint = PublishImprint.selection(
            persisted: persisted, among: PublishImprint.imprintNames(in: config))
        return (PublishImprint.scopedDocumentIds(docIds, imprint: imprint, in: config), imprint)
    }

    /// The line under Run Whole Book: how many chapters it runs, and of
    /// which imprint when one is chosen.
    static func runScopeLine(count: Int, imprint: String?,
                             preflight: TranslationPreflight.Budgets.Answer? = nil) -> String {
        let chapters = count == 1 ? "1 chapter" : "\(count) chapters"
        // What it will cost, before the press (fix round I2): the figure, or
        // the refusal that stands in its place.
        let cost = TranslationRunState.preflightLine(preflight).map { " \u{00b7} \($0)" } ?? ""
        guard let imprint else { return "Runs every chapter of the book: \(chapters)\(cost)." }
        return "Runs the \(chapters) of \u{201C}\(imprint)\u{201D}, the imprint chosen above the book\(cost)."
    }

    /// **What the head says about the edition's newest round** (fix round
    /// I3): a round that stopped — failed or cancelled — newer than the
    /// letter on show is said in its own words above it, and the letter is
    /// then the earlier one. While a round runs, its own line speaks instead.
    struct HeadRounds: Equatable {
        var stopped: TranslationRound?
        var stoppedLine: String?
        var letter: TranslationRound?
        var letterIsEarlier = false
    }

    static func headRounds(newest: TranslationRound?, rounds: [String: TranslationRound],
                           running: Bool, now: Date) -> HeadRounds {
        let letter = newestLetter(rounds)
        guard !running, let newest, newest.failed || newest.wasCancelled else {
            return HeadRounds(letter: letter)
        }
        return HeadRounds(stopped: newest,
                          stoppedLine: TranslationRunState.roundLine(newest, now: now),
                          letter: letter,
                          letterIsEarlier: letter.map { $0.number < newest.number } ?? false)
    }

    static let earlierLetterLabel = "The last finished round\u{2019}s letter"

    /// `held` with its edition kinds replaced by `items`: the walks' questions
    /// stay, and every change, proposal and problem is this read's.
    static func replacing(_ held: ResolveSnapshot, with items: [ResolveItem]) -> ResolveSnapshot {
        let kept = held.items.filter { item in
            switch item {
            case .translationChange, .glossaryProposal, .designProposal, .compileProblem: return false
            case .note, .finding, .todo: return true
            }
        }
        return ResolveSnapshot(items: kept + items, sequences: held.sequences,
                               paragraphText: held.paragraphText,
                               unreadableDocIds: held.unreadableDocIds)
    }
}

/// **What an edition's list is re-read on** (`ResolvePane`'s edition task):
/// the edition, its pieces, the ledger's date, the proposals heard, the
/// compile's problems and the verbs that changed a record.
struct ResolveEditionKey: Equatable {
    let scope: ResolveScope
    let roundsModified: Date?
    let heard: Int
    let problems: [TectonicLogParser.Diagnostic]
    /// The imprint the window stands on — what Run Whole Book runs.
    var imprint: String? = nil

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - What the rows act through

/// **The verbs an edition's rows reach** — the round report's and the gate's,
/// handed in by the pane, never re-spelled (the plan's contract). Each that
/// files says where through `onFiled`, from the destination the write
/// returned; each that rewrote a round hands the round as written to
/// `onRoundChanged`, which patches the list and the centre's report at once.
struct ResolveEditionVerbs {
    /// The round report's verbs, wired to the window
    /// (`TranslationRoundActions.production`).
    var round = TranslationRoundActions()
    /// `TranslationAuthorVerbs.decide` for a piece in a language — the round
    /// report host's questions, asked once per render for the pieces listed.
    var authorVerbs: (_ docId: String, _ language: String) -> TranslationAuthorVerbs = { _, _ in .none }
    /// **Whether this Mac may decide the book's design** — Approve, Discard,
    /// Run and Request Changes (shell p4 Task 6 fix round): the posture of
    /// the Visual Language statement, the design's own home. Hidden, never
    /// disabled.
    var mayDecideDesign = false
    /// The gate's Approve, and the list's Discard (`DesignGatePromotion`).
    var approve: (DesignProposalStore.Proposal) async -> DesignGateOutcome = { _ in .refused(DesignGate.notWired) }
    var discard: (DesignProposalStore.Proposal) async -> DesignGateOutcome = { _ in .refused(DesignGate.notWired) }
    /// The centre's covers (`PublishCentreModel.show`).
    var showRound: (TranslationRound) -> Void = { _ in }
    var showProposal: (DesignProposalStore.Proposal) -> Void = { _ in }
    var showProblems: () -> Void = {}
    /// A round as written by a verb: patch the list and the report now.
    var onRoundChanged: (TranslationRound) -> Void = { _ in }
    /// A proposal as a gate verb left it: read the list again; the gate
    /// adopts it if it is showing that proposal.
    var onProposalChanged: (DesignProposalStore.Proposal) -> Void = { _ in }
    /// Where an answer was filed (`FiledUnder`).
    var onFiled: (FiledDestination) -> Void = { _ in }
}

/// **What each row's button does, as functions the tests call directly**
/// (tripwire 33: no press-then-wait). Each resolves the round the row is
/// about from the CURRENT read — never a copy the row was drawn with — and
/// calls the one verb, with the departure or proposal named by identity.
@MainActor
enum ResolveEditionActs {

    /// Fine on a change.
    static func fine(_ item: ResolveItem, read: ResolveEditionItems.Read,
                     verbs: ResolveEditionVerbs) async -> TranslationRoundActions.Outcome? {
        guard case .translationChange(let docId, _, _, let departure) = item,
              let round = read.rounds[docId] else { return nil }
        return await verbs.round.dismiss(round, departure.id)
    }

    /// Keep mine on a change: the directive on its paragraph, settling it.
    static func keepMine(_ item: ResolveItem, instruction: String, home: TranslatorsNote.Home,
                         read: ResolveEditionItems.Read,
                         verbs: ResolveEditionVerbs) async -> TranslationRoundActions.Outcome? {
        guard case .translationChange(let docId, _, _, let departure) = item,
              let round = read.rounds[docId] else { return nil }
        return await verbs.round.keepMine(round, departure.paragraphId, instruction, home, departure.id)
    }

    /// Make it a rule on a change: doctrine for the edition, settling it.
    static func makeRule(_ item: ResolveItem, text: String, read: ResolveEditionItems.Read,
                         verbs: ResolveEditionVerbs) async -> TranslationRoundActions.Outcome? {
        guard case .translationChange(let docId, _, _, let departure) = item,
              let round = read.rounds[docId] else { return nil }
        return await verbs.round.makeRule(round, text, departure.id)
    }

    /// Adopt a glossary proposal, by its identity.
    static func adopt(_ item: ResolveItem, read: ResolveEditionItems.Read,
                      verbs: ResolveEditionVerbs) async -> TranslationRoundActions.Outcome? {
        guard case .glossaryProposal(let docId, _, _, let proposal) = item,
              let round = read.rounds[docId] else { return nil }
        return await verbs.round.adopt(round, proposal.identity)
    }

    /// Skip a glossary proposal, by its identity.
    static func skip(_ item: ResolveItem, read: ResolveEditionItems.Read,
                     verbs: ResolveEditionVerbs) async -> TranslationRoundActions.Outcome? {
        guard case .glossaryProposal(let docId, _, _, let proposal) = item,
              let round = read.rounds[docId] else { return nil }
        return await verbs.round.skip(round, proposal.identity)
    }

    /// Approve or Discard a design proposal.
    static func decide(_ verb: EditionDesignRow.Verb, _ proposal: DesignProposalStore.Proposal,
                       verbs: ResolveEditionVerbs) async -> DesignGateOutcome {
        switch verb {
        case .approve: return await verbs.approve(proposal)
        case .discard: return await verbs.discard(proposal)
        }
    }

    /// **What a round verb's outcome does** — the round report's rule
    /// (`TranslationRoundReportView.run`): the round as written goes to the
    /// list and the centre now; a filing is said by the list's one filed
    /// line; a refusal is the row's own sentence. Returns the row's notice.
    static func apply(_ outcome: TranslationRoundActions.Outcome?, verbs: ResolveEditionVerbs) -> String? {
        switch outcome {
        case .done(let updated, let sentence)?:
            if let updated { verbs.onRoundChanged(updated) }
            return sentence
        case .filed(let updated, let destination, _)?:
            if let updated { verbs.onRoundChanged(updated) }
            verbs.onFiled(destination)
            return nil
        case .refused(let sentence)?:
            return sentence
        case nil:
            return TranslationRoundReport.rowGone
        }
    }
}

// MARK: - The rows

/// **One edition item's row** in To resolve, by kind. Values in, closures
/// out; each kind holds only its own transient state (a sheet, the line its
/// last verb said).
@MainActor
struct ResolveEditionRow: View {
    let item: ResolveItem
    let read: ResolveEditionItems.Read
    let verbs: ResolveEditionVerbs
    /// The pieces' author verbs, asked once per render (`ResolvePane`).
    let authorVerbs: TranslationAuthorVerbs

    var body: some View {
        switch item {
        case .translationChange:
            if let row = read.departureRows[item.id] {
                EditionChangeRow(item: item, row: row, read: read, verbs: verbs, authorVerbs: authorVerbs)
            }
        case .glossaryProposal(let docId, _, _, let proposal):
            if let round = read.rounds[docId] {
                EditionGlossaryRow(item: item, round: round, proposal: proposal, read: read,
                                   verbs: verbs, authorVerbs: authorVerbs)
            }
        case .designProposal(let proposal):
            EditionDesignRow(proposal: proposal, verbs: verbs)
        case .compileProblem:
            if let row = read.problemRows[item.id] {
                EditionProblemRow(row: row, verbs: verbs)
            }
        case .note, .finding, .todo:
            EmptyView()
        }
    }
}

/// The line a verb said, under its row.
private struct EditionVerbNotice: View {
    let notice: String?
    var body: some View {
        if let notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// **A change the translator made**: the round report's own row
/// (`DepartureRowView`) and its verbs — Fine, Keep mine, Make it a rule —
/// each settling the change (controller's ruling: filing settles). Its
/// source line reveals the paragraph in the language (`TranslationReveal`),
/// which opens the piece.
@MainActor
struct EditionChangeRow: View {
    let item: ResolveItem
    let row: TranslationRoundReport.DepartureRow
    let read: ResolveEditionItems.Read
    let verbs: ResolveEditionVerbs
    let authorVerbs: TranslationAuthorVerbs

    private enum Sheet: Identifiable {
        case keepMine, makeRule
        var id: Int { self == .keepMine ? 0 : 1 }
    }

    @State private var sheet: Sheet?
    @State private var expanded = false
    @State private var notice: String?
    @State private var working = false

    private var language: String {
        if case .translationChange(_, let language, _, _) = item { return language }
        return ""
    }

    private var docId: String { item.docId }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DepartureRowView(
                row: row, isExpanded: expanded, verbs: authorVerbs,
                onFine: { run { await ResolveEditionActs.fine(item, read: read, verbs: verbs) } },
                onKeepMine: { sheet = .keepMine },
                onMakeRule: { sheet = .makeRule },
                onReveal: {
                    TranslationReveal.post(TranslationReveal(
                        docId: docId, language: language, paragraphId: row.paragraphId))
                },
                onToggleExpanded: { expanded.toggle() })
            .disabled(working)
            EditionVerbNotice(notice: notice)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .sheet(item: $sheet) { which in
            switch which {
            case .keepMine:
                TranslatorsNoteSheet(
                    target: TranslatorsNote.Target(
                        docId: docId, paragraphId: row.paragraphId,
                        excerpt: row.source ?? row.gloss, editions: [language]),
                    onCommit: { instruction, home in
                        sheet = nil
                        run {
                            await ResolveEditionActs.keepMine(item, instruction: instruction, home: home,
                                                              read: read, verbs: verbs)
                        }
                    },
                    onCancel: { sheet = nil },
                    seed: row.note,
                    defaultHome: authorVerbs.keepMineHome(language: language),
                    offering: authorVerbs.keepMineHomes(language: language))
            case .makeRule:
                RoundRuleSheet(seed: row.note, language: language,
                               onCommit: { text in
                                   sheet = nil
                                   run { await ResolveEditionActs.makeRule(item, text: text, read: read, verbs: verbs) }
                               },
                               onCancel: { sheet = nil })
            }
        }
    }

    private func run(_ action: @escaping () async -> TranslationRoundActions.Outcome?) {
        notice = nil
        working = true
        Task { @MainActor in
            let outcome = await action()
            working = false
            notice = ResolveEditionActs.apply(outcome, verbs: verbs)
        }
    }
}

/// **A term the round proposes fixing**: Adopt and Skip, the round report's
/// own, where this Mac may decide the glossary
/// (`TranslationRoundReport.glossaryOffers`). Its title opens the round's
/// report.
@MainActor
struct EditionGlossaryRow: View {
    let item: ResolveItem
    let round: TranslationRound
    let proposal: TranslationRound.GlossaryProposalRecord
    let read: ResolveEditionItems.Read
    let verbs: ResolveEditionVerbs
    let authorVerbs: TranslationAuthorVerbs

    @State private var notice: String?
    @State private var working = false

    var body: some View {
        let offers = TranslationRoundReport.glossaryOffers(authorVerbs)
        VStack(alignment: .leading, spacing: 4) {
            Button { verbs.showRound(round) } label: {
                Text("\u{00AB}\(proposal.term)\u{00BB} \u{2192} \u{00AB}\(proposal.rendering)\u{00BB}")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(TranslationRoundReport.proposalsHeading + ": " + ResolveEditionItems.openTheReportTitle)
            if !proposal.reason.isEmpty {
                Text(proposal.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FlowLayout(spacing: 6) {
                if offers.adopt {
                    Button(TranslationRoundReport.adoptTitle) {
                        run { await ResolveEditionActs.adopt(item, read: read, verbs: verbs) }
                    }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel(TranslationRoundReport.adoptTitle + " \u{00AB}\(proposal.term)\u{00BB}")
                }
                if offers.skip {
                    Button(TranslationRoundReport.skipTitle) {
                        run { await ResolveEditionActs.skip(item, read: read, verbs: verbs) }
                    }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel(TranslationRoundReport.skipTitle + " \u{00AB}\(proposal.term)\u{00BB}")
                }
            }
            .disabled(working)
            EditionVerbNotice(notice: notice)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func run(_ action: @escaping () async -> TranslationRoundActions.Outcome?) {
        notice = nil
        working = true
        Task { @MainActor in
            let outcome = await action()
            working = false
            notice = ResolveEditionActs.apply(outcome, verbs: verbs)
        }
    }
}

/// **A design proposal waiting on a decision**: its line, Show (the gate
/// covers the centre), and — where this Mac may decide the design — the
/// gate's Approve and Discard, which asks first: it cannot be taken back.
@MainActor
struct EditionDesignRow: View {
    let proposal: DesignProposalStore.Proposal
    let verbs: ResolveEditionVerbs

    @State private var notice: String?
    @State private var working = false
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(proposal.designerName) proposes a design")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(DesignRoundState.latestLine(proposal))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            FlowLayout(spacing: 6) {
                Button(DesignRoundState.showTitle) { verbs.showProposal(proposal) }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel(DesignRoundState.showAccessibilityLabel)
                    .help(DesignRoundState.showHelp)
                ForEach(EditionDesignRow.verbs(status: proposal.status, mayDecide: verbs.mayDecideDesign),
                        id: \.self) { verb in
                    Button(verb.title) {
                        if verb == .discard { confirmingDiscard = true } else { run(verb) }
                    }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel(verb.accessibilityLabel)
                    .help(verb.help)
                }
            }
            .disabled(working)
            EditionVerbNotice(notice: notice)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .confirmationDialog(DesignGate.discardConfirmTitle, isPresented: $confirmingDiscard) {
            Button(DesignGate.discardTitle, role: .destructive) { run(.discard) }
            Button(DesignGate.cancelTitle, role: .cancel) {}
        } message: {
            Text(DesignGate.discardCost)
        }
    }

    /// The list's verbs on a proposal: the gate's Approve, and Discard —
    /// only while it waits, and only where this Mac may decide the design.
    /// Request Changes stays the head's and the gate's (it needs words).
    enum Verb: Hashable {
        case approve, discard
        var title: String {
            switch self {
            case .approve: return DesignGate.Verb.approve.title
            case .discard: return DesignGate.discardTitle
            }
        }
        var accessibilityLabel: String {
            switch self {
            case .approve: return DesignGate.Verb.approve.accessibilityLabel
            case .discard: return "Discard this design"
            }
        }
        var help: String {
            switch self {
            case .approve: return DesignGate.Verb.approve.help
            case .discard: return DesignGate.discardHelp
            }
        }
    }

    static func verbs(status: DesignProposalStore.Status, mayDecide: Bool) -> [Verb] {
        mayDecide && status == .pending ? [.approve, .discard] : []
    }

    private func run(_ verb: Verb) {
        notice = nil
        working = true
        Task { @MainActor in
            let outcome = await ResolveEditionActs.decide(verb, proposal, verbs: verbs)
            working = false
            switch outcome {
            case .done(let updated, let sentence):
                notice = sentence
                verbs.onProposalChanged(updated)
            case .refused(let sentence):
                notice = sentence
            }
        }
    }
}

/// **A problem that stopped the last compile**: the problems list's own row
/// words, Show (the problems cover the centre) and Show in Manuscript.
@MainActor
struct EditionProblemRow: View {
    let row: PublishProblems.Row
    let verbs: ResolveEditionVerbs

    var body: some View {
        let glyph = PublishProblems.glyph(row.level)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label {
                    Text(glyph.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: glyph.systemImage)
                        .foregroundStyle(row.level == .error ? Color.red : Color.orange)
                }
                .labelStyle(.titleAndIcon)
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(row.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            FlowLayout(spacing: 6) {
                Button(TranslationRunState.showRoundTitle) { verbs.showProblems() }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel("Show the last compile\u{2019}s problems")
                if row.isInBook {
                    Button(PublishProblems.showInManuscriptTitle) { reveal() }
                        .controlSize(.small).fixedSize()
                        .accessibilityLabel(
                            PublishProblems.showInManuscriptAccessibilityLabel(title: row.title))
                        .help(row.paragraphID == nil
                              ? PublishProblems.openPieceHelp : PublishProblems.showParagraphHelp)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func reveal() {
        switch PublishProblems.reveal(row) {
        case .paragraph(let reveal): TranslationReveal.post(reveal)
        case .piece(let piece):
            if let id = piece.itemID { ResolveNavigation.go(toDocId: id) }
        }
    }
}

// MARK: - The head

/// **What the head's buttons reach**, as closures (shell p4 Task 6 fix
/// round): built from the window's roster in production
/// (`EditionHeadVerbs.production`), recorded in the tests, which call the
/// head's verb functions directly (tripwire 33).
struct EditionHeadVerbs {
    /// Start a whole-book round over `documentIds` (`TranslationRunStart.startBookRun`):
    /// the cast sheet's ask, or nil and the notice.
    var startBookRun: (_ language: String, _ documentIds: [String]) async -> TranslationRunStart
        = { _, _ in .init(notice: TranslationRunStart.noTranslatorWired) }
    /// After the cast sheet named the translator: nil when it started, else
    /// why not (a round already holds the project's one pipeline).
    var runBookNamed: (_ language: String, _ documentIds: [String]) -> String? = { _, _ in nil }
    var cancelRound: () -> Void = {}
    /// A design round; nil when it went, else the refusal's sentence.
    var runDesign: (_ direction: String?) -> String? = { _ in DesignRoundState.noDesignerWired }
    /// The gate's iterate arm (`DesignRoundState.sendChanges`).
    var requestChanges: (_ words: String) -> String? = { _ in DesignRoundState.noDesignerWired }
    var cancelDesign: () -> Void = {}

    /// The window's roster, wired. A nil roster is a probe: every verb says
    /// it is not wired.
    @MainActor
    static func production(roster: AgentRoster?, store: ProjectStore,
                           documentStore: DocumentStore) -> EditionHeadVerbs {
        guard let roster else { return EditionHeadVerbs() }
        let pipeline = roster.pipeline
        let designer = roster.designer
        return EditionHeadVerbs(
            startBookRun: { language, documentIds in
                await TranslationRunStart.startBookRun(
                    language: language, documentIds: documentIds, pipeline: pipeline,
                    documentStore: documentStore, store: store)
            },
            runBookNamed: { language, documentIds in
                TranslationRunStart.refusedIfBusy(
                    pipeline.runBook(documentIds: documentIds, language: language), pipeline: pipeline)
            },
            cancelRound: {
                roster.pipeline.cancel()
                roster.translator.cancel()
            },
            runDesign: { direction in
                if let refusal = DesignRoundState.preflight(
                    session: DesignSession.read(runState: designer.runState, isRunning: designer.isRunning),
                    briefability: DesignRoundState.briefability(store: store, projectURL: store.url)) {
                    return refusal
                }
                designer.runDesign(direction: direction, language: nil)
                return nil
            },
            requestChanges: { words in DesignRoundState.sendChanges(words, to: designer) },
            cancelDesign: { designer.cancel() })
    }
}

/// **An edition's head** (shell p4 Task 6): where the edition stands and
/// Run.
///
/// - A translated edition: the translator's newest letter among the
///   chapters' latest rounds, signed, with its chapter and day, and Open the
///   report (the round's cover); then Run Whole Book over the pieces of the
///   imprint the window stands on (`Read.runBook`, the compile bar's one
///   choice), the line that says how many and of which imprint, and Cancel
///   while it runs. Run is hidden where the translator may translate none of
///   those pieces.
/// - The Source edition (Denver, 2026-11-21, answer 1): the designer's name
///   and latest line, a direction field, Run (a design round), Request
///   Changes while the proposal's session is open, Cancel while one runs,
///   and Show for the newest proposal — the deciding verbs only where this
///   Mac may decide the design.
///
/// Neither run resolves a reader from another loop's memory (tripwire 34):
/// a round's cast is the language's roles, a design round's the designer.
@MainActor
struct EditionHeadView: View {
    let language: String
    let isSource: Bool
    let store: ProjectStore
    let documentStore: DocumentStore
    let editionRead: ResolveEditionItems.Read
    /// `ResolveEditionVerbs.mayDecideDesign` — the design verbs' posture.
    let mayDecideDesign: Bool
    let onShowRound: (TranslationRound) -> Void
    let onShowProposal: (DesignProposalStore.Proposal) -> Void

    @Environment(AgentRoster.self) private var roster: AgentRoster?
    @State private var notice: String?
    @State private var castPrompt: EditionCastPrompt?
    /// What Run Whole Book will cost (fix round I2), taken while idle.
    @State private var preflight: TranslationPreflight.Budgets.Answer?
    @State private var direction = ""

    private struct PreflightKey: Equatable {
        let language: String
        let isSource: Bool
        let docIds: [String]
        let manifest: Date
        let idle: Bool
    }

    private var verbs: EditionHeadVerbs {
        EditionHeadVerbs.production(roster: roster, store: store, documentStore: documentStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isSource { designHead } else { translatorHead }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("resolve.edition.notice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        // Run Whole Book's cost (fix round I2): one edition's figure over the
        // run's pieces, read off the main actor and cached per book; taken
        // only while no round runs — the last idle figure stands mid-round.
        .task(id: PreflightKey(language: language, isSource: isSource, docIds: editionRead.runBook,
                               manifest: store.manifest.modified,
                               idle: TranslationPreflight.refillsBudgets(
                                   pipeline: roster?.pipeline.status ?? .idle))) {
            guard !isSource, editionRead.language != nil,
                  TranslationPreflight.refillsBudgets(pipeline: roster?.pipeline.status ?? .idle)
            else { return }
            let answer = await TranslationPreflight.editionBudget(
                documentIds: editionRead.runBook, language: language,
                store: store, documentStore: documentStore)
            if !Task.isCancelled { preflight = answer }
        }
        .sheet(item: $castPrompt) { prompt in
            EditionCastSheet(prompt: prompt,
                                onConfirm: { answer in
                                    castPrompt = nil
                                    Task { notice = await Self.confirmCast(answer, prompt: prompt, store: store,
                                                                           verbs: verbs) }
                                },
                                onCancel: {
                                    castPrompt = nil
                                    notice = EditionCastCopy.cancelledLine(language: language)
                                })
        }
        Divider()
    }

    // MARK: A translated edition

    private var translatorName: String {
        EditionStatus.translatorName(for: language, in: store.manifest) ?? language.uppercased()
    }

    @ViewBuilder
    private var translatorHead: some View {
        let head = ResolveEditionItems.headRounds(
            newest: editionRead.newestRound, rounds: editionRead.rounds,
            running: roster?.pipeline.status != .idle && roster?.pipeline.status != nil, now: Date())
        if let stopped = head.stopped, let line = head.stoppedLine {
            // Why the newest round stopped, in its own words, with its door.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(stopped.failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("resolve.edition.stopped")
                Button(ResolveEditionItems.openTheReportTitle) { onShowRound(stopped) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .fixedSize()
                    .help(TranslationRunState.showRoundHelp)
            }
        }
        if let round = head.letter, let letter = ResolveEditionItems.letter(of: round) {
            if head.letterIsEarlier {
                Text(ResolveEditionItems.earlierLetterLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(letter)
                .font(.callout)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("resolve.edition.letter")
            Text(ResolveEditionItems.signature(
                translator: round.signedBy(liveName: translatorName),
                chapter: TreeWalk.find(id: round.docId, in: store.manifest.structure)?.title,
                round: round))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ResolveEditionItems.openTheReportTitle) { onShowRound(round) }
                .buttonStyle(.link)
                .font(.caption)
                .help(TranslationRunState.showRoundHelp)
        } else if editionRead.language != nil {
            Text(ResolveEditionItems.noLetterLine(translator: translatorName,
                                                  hasRounds: editionRead.hasRounds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        translationRun
    }

    /// Whether this Mac's translator may translate any of the pieces Run
    /// would run — the desk's rule (`TranslationRunOffers.decide`),
    /// asked of the translator actor's posture, over `Read.runBook`.
    static func offersRun(docIds: [String], mayTranslate: (String) -> Bool) -> Bool {
        TranslationRunOffers.decide(target: nil, book: docIds, mayTranslate: mayTranslate).runBook
    }

    @ViewBuilder
    private var translationRun: some View {
        let run = runState
        let book = editionRead.runBook
        if editionRead.language != nil, Self.offersRun(docIds: book, mayTranslate: {
            TranslationRunStart.postureOfTheTranslator(forPiece: $0, in: documentStore).allows(.translate)
        }) {
            FlowLayout(spacing: 6) {
                Button(TranslationRunState.runBookTitle) { runBook() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!run.canRunBook)
                    .accessibilityLabel(TranslationRunState.runBookAccessibilityLabel(language: language))
                    .help(run.bookRefusal
                          ?? TranslationRunState.runBookHelp(language: language, count: book.count,
                                                            preflight: preflight))
                if run.isRunning {
                    Button(TranslationRunState.cancelTitle) { verbs.cancelRound() }
                        .controlSize(.small)
                        .fixedSize()
                        .help(TranslationRunState.cancelHelp)
                }
            }
            Text(ResolveEditionItems.runScopeLine(count: book.count, imprint: editionRead.imprint,
                                                  preflight: preflight))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // While a round runs, its leg. (A stopped round is said above,
            // from the ledger: this head's run has no chapter, so the
            // translator's own failure phase never reaches it — fix round I3.)
            if run.isRunning, let status = run.statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The edition's run state, from the window's translator and pipeline —
    /// the desk's resolve, over the run's own pieces (no chapter target).
    private var runState: TranslationRunState {
        let runState = roster?.translator.runState ?? .idle
        let pipeline = roster?.pipeline.status ?? .idle
        let session = TranslationRunSession.read(
            runState: runState, isRunning: roster?.translator.isRunning ?? false, pipeline: pipeline)
        return TranslationRunState.resolve(
            language: language,
            target: TranslationRunTarget.resolve(subject: nil, structure: [], isOpen: { _ in false }),
            session: session, runState: runState, lastRun: nil, pipeline: pipeline,
            bookDocumentCount: editionRead.runBook.count)
    }

    private func runBook() {
        notice = nil
        let session = TranslationRunSession.read(
            runState: roster?.translator.runState ?? .idle,
            isRunning: roster?.translator.isRunning ?? false,
            pipeline: roster?.pipeline.status ?? .idle)
        let book = editionRead.runBook
        let verbs = verbs
        Task {
            let outcome = await Self.runBook(language: language, book: book, session: session, verbs: verbs)
            if let prompt = outcome.castPrompt { castPrompt = prompt }
            notice = outcome.notice
        }
    }

    /// **Run Whole Book, decided**: the desk's refusals in order (a round
    /// under way, an unusable tag, nothing to run), then the start over
    /// exactly `book` — the set the button's count and offer were asked over.
    static func runBook(language: String, book: [String], session: TranslationRunSession,
                        verbs: EditionHeadVerbs) async -> TranslationRunStart {
        if case .busy(let busy) = session {
            return .init(notice: TranslationRunState.busyReason(language: busy))
        }
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            return .init(notice: TranslationRunState.unusableTag(language: language))
        }
        guard !book.isEmpty else { return .init(notice: TranslationRunState.nothingInTheBook) }
        return await verbs.startBookRun(language, book)
    }

    /// The cast sheet's Confirm for a book run: name the cast, then run the
    /// queue it was asked over. Returns the notice.
    static func confirmCast(_ answer: EditionCastAnswer, prompt: EditionCastPrompt,
                            store: ProjectStore, verbs: EditionHeadVerbs) async -> String? {
        guard case .nameForBookRun(let language, let documentIds) = prompt.ask else { return nil }
        let named = await EditionCastVerbs.nameCast(language: language, answer: answer, store: store)
        guard named.translatorNamed else { return named.failure }
        return verbs.runBookNamed(language, documentIds) ?? named.failure
    }

    // MARK: The Source edition

    private var design: DesignRoundState {
        let designer = roster?.designer
        let runState = designer?.runState ?? .idle
        return DesignRoundState.resolve(
            designerName: store.designerRole().effectiveName,
            proposals: editionRead.proposals,
            runState: runState,
            session: DesignSession.read(runState: runState, isRunning: designer?.isRunning ?? false),
            hasOpenProposalRound: designer?.hasOpenProposalRound ?? false)
    }

    @ViewBuilder
    private var designHead: some View {
        let design = design
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(design.designerName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if design.offersShow, let newest = editionRead.proposals.first {
                Button(DesignRoundState.showTitle) { onShowProposal(newest) }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(DesignRoundState.showAccessibilityLabel)
                    .help(DesignRoundState.showHelp)
            }
        }
        Text(design.latestLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if mayDecideDesign {
            TextField(DesignRoundState.directionPrompt, text: $direction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .font(.callout)
                .accessibilityIdentifier("resolve.edition.direction")
            FlowLayout(spacing: 6) {
                Button(DesignRoundState.runTitle) {
                    let outcome = Self.runDesign(direction, verbs: verbs)
                    notice = outcome.notice
                    if outcome.spent { direction = "" }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(!design.canRun)
                .accessibilityLabel(DesignRoundState.runAccessibilityLabel)
                .help(design.refusal ?? DesignRoundState.runHelp(designerName: design.designerName))
                if design.offersRequestChanges {
                    Button(DesignRoundState.requestChangesTitle) {
                        let outcome = Self.requestChanges(direction, verbs: verbs)
                        notice = outcome.notice
                        if outcome.spent { direction = "" }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!design.canRun)
                    .help(design.refusal ?? DesignRoundState.requestChangesHelp)
                }
                if design.isRunning {
                    Button(TranslationRunState.cancelTitle) { verbs.cancelDesign() }
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(DesignRoundState.cancelAccessibilityLabel)
                        .help(DesignRoundState.cancelHelp)
                }
            }
        }
        if let status = design.statusLine {
            Text(status)
                .font(.caption)
                .foregroundStyle(design.isFailure ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Run design: the direction trimmed, empty is none; the words are spent
    /// only on a round that went.
    static func runDesign(_ direction: String, verbs: EditionHeadVerbs) -> (notice: String?, spent: Bool) {
        let words = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        let refusal = verbs.runDesign(words.isEmpty ? nil : words)
        return (refusal, refusal == nil)
    }

    /// Request Changes: the writer's words, untrimmed, to the gate's one
    /// spelling; spent only when they went.
    static func requestChanges(_ words: String, verbs: EditionHeadVerbs) -> (notice: String?, spent: Bool) {
        let refusal = verbs.requestChanges(words)
        return (refusal, refusal == nil)
    }
}
