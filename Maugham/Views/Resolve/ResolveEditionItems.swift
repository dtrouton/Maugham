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
            for (index, proposal) in round.glossaryProposals.enumerated()
            where isOpen(proposal) {
                items.append(.glossaryProposal(docId: docId, language: language,
                                               round: round.number, index: index, proposal))
            }
        }
        return items
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
    static func clearLine(language: String, isSource: Bool, hasRounds: Bool) -> String {
        if isSource {
            return "Nothing about the book\u{2019}s design or its last compile waits on you. "
                + "Run design above to ask for a new design."
        }
        let edition = TranslationReviewIndicator.displayLabel(forLanguageTag: language)
        guard hasRounds else {
            return "No round has run in \(edition) yet. Run one above; what the translator "
                + "asks and changes will be listed here."
        }
        return "Nothing in the \(edition) edition waits on you: every question is answered "
            + "and every change from the latest rounds is settled."
    }

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
        for case .note(let note) in snapshot.items
        where note.annotation.status == .open && !DocumentClass.isFigureDocId(note.docId) {
            if let language = note.annotation.language { languages.insert(language.lowercased()) }
        }
        return languages
    }

    // MARK: - The reads (disk, off the body path)

    /// **The rounds, from disk** — off the main actor: one ledger decode for
    /// the language (none for the Source).
    nonisolated static func readRounds(projectURL: URL, language: String, isSource: Bool,
                                       docIds: [String]) -> [String: TranslationRound] {
        guard !isSource else { return [:] }
        let all = TranslationRoundStore(projectURL: projectURL).latestFinishedByPiece(language: language)
        return Self.rounds(all, docIds: docIds)
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
        let rounds = await Task.detached(priority: .userInitiated) {
            readRounds(projectURL: projectURL, language: language, isSource: isSource, docIds: docIds)
        }.value
        let proposals = (try? DesignProposalStore(projectURL: projectURL).list()) ?? []
        var read = Read(language: language, rounds: rounds, proposals: proposals,
                        problems: problems, hasRounds: !rounds.isEmpty)
        let translator = EditionStatus.translatorName(for: language, in: store.manifest)
            ?? TranslationRoundReport.anonymousTranslator
        for (docId, round) in rounds {
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

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - What the rows act through

/// **The verbs an edition's rows reach** — the round report's and the gate's,
/// handed in by the pane, never re-spelled (the plan's contract). Each that
/// files says where through `onFiled`, from the destination the write
/// returned.
struct ResolveEditionVerbs {
    /// The round report's nine, wired to the window
    /// (`TranslationRoundActions.production`).
    var round = TranslationRoundActions()
    /// `TranslationAuthorVerbs.decide` for a piece in a language — the
    /// round report host's two questions.
    var authorVerbs: (_ docId: String, _ language: String) -> TranslationAuthorVerbs = { _, _ in .none }
    var translatorName: (_ language: String) -> String = { $0.uppercased() }
    /// The gate's Approve, and the list's Discard (`DesignGatePromotion`).
    var approve: (DesignProposalStore.Proposal) async -> DesignGateOutcome = { _ in .refused(DesignGate.notWired) }
    var discard: (DesignProposalStore.Proposal) async -> DesignGateOutcome = { _ in .refused(DesignGate.notWired) }
    /// The centre's covers (`PublishCentreModel.show`).
    var showRound: (TranslationRound) -> Void = { _ in }
    var showProposal: (DesignProposalStore.Proposal) -> Void = { _ in }
    var showProblems: () -> Void = {}
    /// A record changed: read the edition again.
    var onChanged: () -> Void = {}
    /// A gate verb's answer, for the gate if it is showing that proposal.
    var onProposalChanged: (DesignProposalStore.Proposal) -> Void = { _ in }
    /// Where an answer was filed (`FiledUnder`).
    var onFiled: (FiledDestination) -> Void = { _ in }
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

    var body: some View {
        switch item {
        case .translationChange(let docId, let language, _, _):
            if let round = read.rounds[docId], let row = read.departureRows[item.id] {
                EditionChangeRow(round: round, row: row, verbs: verbs,
                                 authorVerbs: verbs.authorVerbs(docId, language))
            }
        case .glossaryProposal(let docId, let language, _, let index, let proposal):
            if let round = read.rounds[docId] {
                EditionGlossaryRow(round: round, index: index, proposal: proposal, verbs: verbs,
                                   authorVerbs: verbs.authorVerbs(docId, language))
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
/// over the change's own round. Its source line reveals the paragraph in
/// the language (`TranslationReveal`), which opens the piece.
@MainActor
struct EditionChangeRow: View {
    let round: TranslationRound
    let row: TranslationRoundReport.DepartureRow
    let verbs: ResolveEditionVerbs
    let authorVerbs: TranslationAuthorVerbs

    private enum Sheet: Identifiable {
        case keepMine, makeRule
        var id: Int { self == .keepMine ? 0 : 1 }
    }

    @State private var sheet: Sheet?
    @State private var expanded = false
    @State private var settled = false
    @State private var notice: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DepartureRowView(
                row: row, isExpanded: expanded, isSettled: settled, verbs: authorVerbs,
                onFine: { run(settles: false) { await verbs.round.dismiss(round, row.id) } },
                onKeepMine: { sheet = .keepMine },
                onMakeRule: { sheet = .makeRule },
                onReveal: {
                    TranslationReveal.post(TranslationReveal(
                        docId: round.docId, language: round.language, paragraphId: row.paragraphId))
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
                        docId: round.docId, paragraphId: row.paragraphId,
                        excerpt: row.source ?? row.gloss, editions: [round.language]),
                    onCommit: { instruction, home in
                        sheet = nil
                        run(settles: true) {
                            await verbs.round.keepMine(round, row.paragraphId, instruction, home)
                        }
                    },
                    onCancel: { sheet = nil },
                    seed: row.note,
                    defaultHome: authorVerbs.keepMineHome(language: round.language),
                    offering: authorVerbs.keepMineHomes(language: round.language))
            case .makeRule:
                RoundRuleSheet(seed: row.note, language: round.language,
                               onCommit: { text in
                                   sheet = nil
                                   run(settles: true) { await verbs.round.makeRule(round, text) }
                               },
                               onCancel: { sheet = nil })
            }
        }
    }

    private func run(settles: Bool, _ action: @escaping () async -> TranslationRoundActions.Outcome) {
        notice = nil
        working = true
        Task { @MainActor in
            let outcome = await action()
            working = false
            EditionVerbOutcome.apply(outcome, settles: settles, verbs: verbs,
                                     notice: &notice, settled: &settled)
        }
    }
}

/// **What a round verb's outcome does to a row** — the round report's rule
/// (`TranslationRoundReportView.run`), with the filing said by the list.
enum EditionVerbOutcome {
    @MainActor
    static func apply(_ outcome: TranslationRoundActions.Outcome, settles: Bool,
                      verbs: ResolveEditionVerbs, notice: inout String?, settled: inout Bool) {
        switch outcome {
        case .done(let updated, let sentence):
            notice = sentence
            if settles { settled = true }
            if updated != nil { verbs.onChanged() }
        case .filed(let updated, let destination, _):
            // Where it went is the list's one filed line (`FiledUnder`).
            verbs.onFiled(destination)
            if settles { settled = true }
            if updated != nil { verbs.onChanged() }
        case .refused(let sentence):
            notice = sentence
        }
    }
}

/// **A term the round proposes fixing**: Adopt (a ruling in the edition
/// brief — where it may be written) and Skip, the round report's own.
/// Its title opens the round's report.
@MainActor
struct EditionGlossaryRow: View {
    let round: TranslationRound
    let index: Int
    let proposal: TranslationRound.GlossaryProposalRecord
    let verbs: ResolveEditionVerbs
    let authorVerbs: TranslationAuthorVerbs

    @State private var notice: String?
    @State private var working = false

    var body: some View {
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
                if authorVerbs.rule {
                    Button(TranslationRoundReport.adoptTitle) { run { await verbs.round.adopt(round, index) } }
                        .controlSize(.small).fixedSize()
                        .accessibilityLabel(TranslationRoundReport.adoptLabel(index: index))
                }
                Button(TranslationRoundReport.skipTitle) { run { await verbs.round.skip(round, index) } }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel(TranslationRoundReport.skipLabel(index: index))
            }
            .disabled(working)
            EditionVerbNotice(notice: notice)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func run(_ action: @escaping () async -> TranslationRoundActions.Outcome) {
        notice = nil
        working = true
        Task { @MainActor in
            let outcome = await action()
            working = false
            var settled = false
            EditionVerbOutcome.apply(outcome, settles: false, verbs: verbs,
                                     notice: &notice, settled: &settled)
        }
    }
}

/// **A design proposal waiting on a decision**: its line, Show (the gate
/// covers the centre), the gate's Approve, and Discard.
@MainActor
struct EditionDesignRow: View {
    let proposal: DesignProposalStore.Proposal
    let verbs: ResolveEditionVerbs

    @State private var notice: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(proposal.designerName) proposes a design")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(DepartmentDesignRow.latestLine(proposal))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            FlowLayout(spacing: 6) {
                Button(DepartmentDesignRow.showTitle) { verbs.showProposal(proposal) }
                    .controlSize(.small).fixedSize()
                    .accessibilityLabel(DepartmentDesignRow.showAccessibilityLabel)
                    .help(DepartmentDesignRow.showHelp)
                ForEach(EditionDesignRow.verbs(status: proposal.status), id: \.self) { verb in
                    Button(verb.title) { run(verb) }
                        .controlSize(.small).fixedSize()
                        .accessibilityLabel(verb.accessibilityLabel)
                        .help(verb.help)
                }
            }
            .disabled(working)
            EditionVerbNotice(notice: notice)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// The list's verbs on a proposal: the gate's Approve, and Discard —
    /// only while it waits. Request Changes stays the head's and the gate's
    /// (it needs the writer's words).
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

    static func verbs(status: DesignProposalStore.Status) -> [Verb] {
        status == .pending ? [.approve, .discard] : []
    }

    private func run(_ verb: Verb) {
        notice = nil
        working = true
        Task { @MainActor in
            let outcome = switch verb {
            case .approve: await verbs.approve(proposal)
            case .discard: await verbs.discard(proposal)
            }
            working = false
            switch outcome {
            case .done(let updated, let sentence):
                notice = sentence
                verbs.onProposalChanged(updated)
                verbs.onChanged()
            case .refused(let sentence):
                notice = sentence
            }
        }
    }
}

/// **A problem the last compile reported**: the problems list's own row
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
                Button(DepartmentRunState.showRoundTitle) { verbs.showProblems() }
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

/// **An edition's head** (shell p4 Task 6): where the edition stands and
/// Run.
///
/// - A translated edition: the translator's newest letter among the
///   chapters' latest rounds, signed, with its chapter and day, and Open the
///   report (the round's cover); then Run Whole Book — a round of every piece
///   in the imprint's book, `DepartmentPaneHost.startBookRun` — and Cancel
///   while it runs. Run is hidden where the translator may translate nothing
///   (`DepartmentTranslationOffers`).
/// - The Source edition (Denver, 2026-11-21, answer 1): the designer's name
///   and latest line, a direction field, Run (a design round), Request
///   Changes while the proposal's session is open, Cancel while one runs,
///   and Show for the newest proposal.
///
/// Its services come from the environment the column injects (the window's
/// roster); a probe that injects none reads without acting.
@MainActor
struct EditionHeadView: View {
    let language: String
    let isSource: Bool
    let docIds: [String]
    let store: ProjectStore
    let documentStore: DocumentStore
    let editionRead: ResolveEditionItems.Read
    let onShowRound: (TranslationRound) -> Void
    let onShowProposal: (DesignProposalStore.Proposal) -> Void

    @Environment(AgentRoster.self) private var roster: AgentRoster?
    @State private var notice: String?
    @State private var castPrompt: DepartmentCastPrompt?
    @State private var direction = ""

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
        .sheet(item: $castPrompt) { prompt in
            DepartmentCastSheet(prompt: prompt,
                                onConfirm: { confirmCast($0, prompt: prompt) },
                                onCancel: {
                                    castPrompt = nil
                                    notice = DepartmentCastCopy.cancelledLine(language: language)
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
        if let round = ResolveEditionItems.newestLetter(editionRead.rounds),
           let letter = ResolveEditionItems.letter(of: round) {
            Text(letter)
                .font(.callout)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("resolve.edition.letter")
            Text(ResolveEditionItems.signature(
                translator: translatorName,
                chapter: TreeWalk.find(id: round.docId, in: store.manifest.structure)?.title,
                round: round))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ResolveEditionItems.openTheReportTitle) { onShowRound(round) }
                .buttonStyle(.link)
                .font(.caption)
                .help(DepartmentRunState.showRoundHelp)
        } else {
            Text(ResolveEditionItems.noLetterLine(translator: translatorName,
                                                  hasRounds: editionRead.hasRounds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        translationRun
    }

    /// Whether this Mac's translator may translate any piece of the book —
    /// the desk's rule (`DepartmentTranslationOffers.decide`), asked of the
    /// translator actor's posture.
    static func offersRun(docIds: [String], mayTranslate: (String) -> Bool) -> Bool {
        DepartmentTranslationOffers.decide(target: nil, book: docIds, mayTranslate: mayTranslate).runBook
    }

    @ViewBuilder
    private var translationRun: some View {
        let run = runState
        if Self.offersRun(docIds: docIds, mayTranslate: {
            DepartmentPaneHost.postureOfTheTranslator(forPiece: $0, in: documentStore).allows(.translate)
        }) {
            FlowLayout(spacing: 6) {
                Button(DepartmentRunState.runBookTitle) { runBook() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!run.canRunBook)
                    .accessibilityLabel(DepartmentRunState.runBookAccessibilityLabel(language: language))
                    .help(run.bookRefusal
                          ?? DepartmentRunState.runBookHelp(language: language, count: docIds.count,
                                                            preflight: nil))
                if run.isRunning {
                    Button(DepartmentRunState.cancelTitle) {
                        roster?.pipeline.cancel()
                        roster?.translator.cancel()
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help(DepartmentRunState.cancelHelp)
                }
            }
            if run.isRunning || run.isFailure, let status = run.statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(run.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The edition's run state, from the window's translator and pipeline —
    /// the desk's resolve, over the whole book (no chapter target).
    private var runState: DepartmentRunState {
        let runState = roster?.translator.runState ?? .idle
        let pipeline = roster?.pipeline.status ?? .idle
        let session = DepartmentRunSession.read(
            runState: runState, isRunning: roster?.translator.isRunning ?? false, pipeline: pipeline)
        return DepartmentRunState.resolve(
            language: language,
            target: DepartmentRunTarget.resolve(subject: nil, structure: [], isOpen: { _ in false }),
            session: session, runState: runState, lastRun: nil, pipeline: pipeline,
            bookDocumentCount: docIds.count)
    }

    /// Run Whole Book: the desk's refusals, then the desk's start over the
    /// imprint's own pieces, its cast sheet where the language has no
    /// translator yet.
    private func runBook() {
        notice = nil
        guard let roster else { notice = DepartmentPaneHost.noTranslatorWired; return }
        let session = DepartmentRunSession.read(
            runState: roster.translator.runState, isRunning: roster.translator.isRunning,
            pipeline: roster.pipeline.status)
        if case .busy(let busy) = session {
            notice = DepartmentRunState.busyReason(language: busy)
            return
        }
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            notice = DepartmentRunState.unusableTag(language: language)
            return
        }
        let config = (try? PublishConfigStore.read(in: store.url)) ?? nil
        let book = DepartmentPaneHost.scopedDocumentIds(
            docIds, imprint: documentStore.uiState.publishImprint, in: config)
        guard !book.isEmpty else { notice = DepartmentRunState.nothingInTheBook; return }
        let pipeline = roster.pipeline
        Task {
            let start = await DepartmentPaneHost.startBookRun(
                language: language, documentIds: book, pipeline: pipeline,
                documentStore: documentStore, store: store)
            if let prompt = start.castPrompt { castPrompt = prompt }
            notice = start.notice
        }
    }

    private func confirmCast(_ answer: DepartmentCastAnswer, prompt: DepartmentCastPrompt) {
        castPrompt = nil
        guard case .nameForBookRun(let language, let documentIds) = prompt.ask,
              let pipeline = roster?.pipeline else {
            notice = DepartmentPaneHost.noTranslatorWired
            return
        }
        Task {
            let named = await DepartmentPaneHost.nameCast(language: language, answer: answer, store: store)
            if let failure = named.failure { notice = failure }
            guard named.translatorNamed else { return }
            pipeline.runBook(documentIds: documentIds, language: language)
        }
    }

    // MARK: The Source edition

    private var design: DepartmentDesignRow {
        let designer = roster?.designer
        let runState = designer?.runState ?? .idle
        return DepartmentDesignRow.resolve(
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
                Button(DepartmentDesignRow.showTitle) { onShowProposal(newest) }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(DepartmentDesignRow.showAccessibilityLabel)
                    .help(DepartmentDesignRow.showHelp)
            }
        }
        Text(design.latestLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        TextField(DepartmentDesignRow.directionPrompt, text: $direction, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .font(.callout)
            .accessibilityIdentifier("resolve.edition.direction")
        FlowLayout(spacing: 6) {
            Button(DepartmentDesignRow.runTitle) {
                let words = direction.trimmingCharacters(in: .whitespacesAndNewlines)
                if runDesign(words.isEmpty ? nil : words) { direction = "" }
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(!design.canRun)
            .accessibilityLabel(DepartmentDesignRow.runAccessibilityLabel)
            .help(design.refusal ?? DepartmentDesignRow.runHelp(designerName: design.designerName))
            if design.offersRequestChanges {
                Button(DepartmentDesignRow.requestChangesTitle) {
                    notice = DepartmentDesignRow.sendChanges(direction, to: roster?.designer)
                    if notice == nil { direction = "" }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(!design.canRun)
                .help(design.refusal ?? DepartmentDesignRow.requestChangesHelp)
            }
            if design.isRunning {
                Button(DepartmentRunState.cancelTitle) { roster?.designer.cancel() }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(DepartmentDesignRow.cancelAccessibilityLabel)
                    .help(DepartmentDesignRow.cancelHelp)
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

    /// The desk's design click, moved: the pre-flight's sentence, or the
    /// round (`language: nil` — a design round is the book's).
    private func runDesign(_ direction: String?) -> Bool {
        notice = nil
        guard let designer = roster?.designer else {
            notice = DepartmentDesignRow.noDesignerWired
            return false
        }
        if let refusal = DepartmentDesignRow.preflight(
            session: DesignSession.read(runState: designer.runState, isRunning: designer.isRunning),
            briefability: DepartmentDesignRow.briefability(store: store, projectURL: store.url)) {
            notice = refusal
            return false
        }
        designer.runDesign(direction: direction, language: nil)
        return true
    }
}
