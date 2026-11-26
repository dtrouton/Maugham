import SwiftUI
import MaughamCore
import os

private let leftOverLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham",
    category: "ResolvePieceInLanguage")

// MARK: - The decisions (pure)

/// **To resolve for one piece read in a language** (shell p4 Task 9; the
/// design's "the faces follow the piece"). The list is an edition's, narrowed
/// to the piece (`ResolveScope.pieceInLanguage`: its questions in the
/// language, and its latest round's changes and glossary proposals); this is
/// the head above it — the piece's own latest round, Run on this piece, what
/// the translation still lacks, what is left over from deleted paragraphs,
/// and the caret's paragraph (`PieceInLanguageCaretSection`).
///
/// It replaces the translation review pane (deleted in this task): every
/// capability that pane had is here, in the list, or named gone in
/// `ResolvePieceInLanguageTests.test_everyReviewPaneCapabilityHasAHome`.
enum ResolvePieceInLanguage {

    // MARK: What the translation holds

    /// One translation left over from a paragraph the piece no longer has:
    /// the paragraph id it was recorded against, and its text.
    struct LeftOver: Identifiable, Equatable {
        let id: String
        let staleText: String
    }

    /// **What the piece's translation holds now** — the head's lines about
    /// the translation itself, which no round's letter says: the paragraphs
    /// out of date and not yet translated (in the piece's order), and the
    /// translations left over from paragraphs since deleted. Not list items:
    /// a run, not the writer, settles the first two, and the third is
    /// housekeeping — so none of them marks a row (the list and the marks
    /// stay one predicate, `ResolveEditionItems.items`).
    struct Translation: Equatable {
        var docId: String
        var language: String
        var outOfDate: [String] = []
        var untranslated: [String] = []
        var paragraphCount = 0
        var leftOvers: [LeftOver] = []
        /// The translation would not read (RULING-54): said, never shown as
        /// a translation with nothing missing.
        var unreadable: String?
    }

    /// The translation, from each paragraph's status (in the piece's order)
    /// and the orphaned records — the editor's own badges, or a derive.
    static func translation(docId: String, language: String,
                            statuses: [(paragraphId: String, status: TranslationStatus)],
                            orphans: [TranslationRecord]) -> Translation {
        Translation(
            docId: docId, language: language,
            outOfDate: statuses.filter { $0.status == .stale }.map(\.paragraphId),
            untranslated: statuses.filter { $0.status == .missing }.map(\.paragraphId),
            paragraphCount: statuses.count,
            leftOvers: leftOvers(from: orphans))
    }

    /// The orphaned records as rows. `TranslationDeriver.derive` resolves an
    /// orphan through its latest record (a tombstone removes it), so every
    /// record here has text; the guard is a backstop, never a filter.
    static func leftOvers(from orphans: [TranslationRecord]) -> [LeftOver] {
        orphans.compactMap { record in
            guard let text = record.text else { return nil }
            return LeftOver(id: record.paragraphId, staleText: text)
        }
    }

    /// **The piece's translation, read without a load** — the open document
    /// or the derived state for the source (`currentParagraphState`, on the
    /// main actor), the translation files and the derive off it. For a piece
    /// the editor is not showing in this language (an edition open, a
    /// chapter faced); the editor's own badges answer for the one it is.
    @MainActor
    static func readTranslation(docId: String, language: String, store: ProjectStore,
                                documentStore: DocumentStore) async -> Translation {
        let state: (sequence: [String], paragraphs: [String: String], projectURL: URL)
        do {
            state = try currentParagraphState(documentId: docId, store: store,
                                              documentStore: documentStore, projectURL: store.url)
        } catch {
            return Translation(docId: docId, language: language, unreadable: error.localizedDescription)
        }
        let url = store.url
        return await Task.detached(priority: .userInitiated) {
            do {
                let records = try TranslationStore.loadMerged(forDocId: docId, language: language, in: url)
                let derived = TranslationDeriver.derive(records: records, sequence: state.sequence,
                                                        paragraphs: state.paragraphs, language: language)
                return translation(docId: docId, language: language,
                                   statuses: derived.entries.map { ($0.paragraphId, $0.status) },
                                   orphans: derived.orphans)
            } catch {
                return Translation(docId: docId, language: language,
                                   unreadable: (error as? LocalizedError)?.errorDescription
                                       ?? error.localizedDescription)
            }
        }.value
    }

    /// "3 paragraphs out of date · 2 not translated yet"; nil when the
    /// translation lacks nothing.
    static func freshnessLine(_ translation: Translation) -> String? {
        var parts: [String] = []
        let stale = translation.outOfDate.count, missing = translation.untranslated.count
        if stale > 0 { parts.append(stale == 1 ? "1 paragraph out of date" : "\(stale) paragraphs out of date") }
        if missing > 0 {
            parts.append(missing == translation.paragraphCount && missing > 1
                         ? "none of its \(missing) paragraphs translated yet"
                         : (missing == 1 ? "1 paragraph not translated yet" : "\(missing) paragraphs not translated yet"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func leftOverLine(count: Int) -> String {
        count == 1
            ? "1 translation left over from a deleted paragraph"
            : "\(count) translations left over from deleted paragraphs"
    }

    // MARK: Clear, asked and decided over the store (fix round 1, M2 + M3)

    /// Whether the left-over texts start shown: a few, always; many start as
    /// the count with their first lines.
    static func leftOversStartShown(count: Int) -> Bool { count <= 3 }

    static func clearConfirmTitle(count: Int) -> String {
        count == 1
            ? "Clear 1 left-over translation? Its paragraph no longer exists."
            : "Clear \(count) left-over translations? Their paragraphs no longer exist."
    }

    enum ClearDecision: Equatable {
        case clear([String])
        case refuse(String)
    }

    /// **Clear writes exactly what was shown, and only while the store still
    /// holds it so.** `now` is the store's left-overs at the press; a shown
    /// one that came back to a paragraph, or whose text changed, refuses the
    /// whole Clear — nothing is cleared that the writer did not see.
    static func clearDecision(shown: [LeftOver], now: [LeftOver]) -> ClearDecision {
        let current = Dictionary(now.map { ($0.id, $0.staleText) }, uniquingKeysWith: { a, _ in a })
        guard !shown.isEmpty, shown.allSatisfy({ current[$0.id] == $0.staleText }) else {
            return .refuse(changedSinceShownLine)
        }
        return .clear(shown.map(\.id))
    }

    static let changedSinceShownLine =
        "These translations changed since they were shown, so nothing was cleared. Look at them again."

    static let clearTitle = "Clear"
    static let clearHelp = "Remove these translations: the paragraphs they were made for are gone. "
        + "Nothing in the text changes."
    static let showTitle = "Show"
    static let hideTitle = "Hide"

    /// The line for a translation that would not read.
    static func unreadableLine(_ reason: String) -> String {
        "This translation could not be read, so what it lacks is not known: \(reason)"
    }

    // MARK: The head's round

    /// **This piece's round in the language, as the head says it**: why its
    /// newest round stopped, when it did, over its latest finished round's
    /// letter — `ResolveEditionItems.headRounds` over the piece's own rounds,
    /// never another chapter's (Review Focus 1: after a whole-book run and a
    /// second run on this chapter, the second's letter).
    static func headRounds(_ read: ResolveEditionItems.Read, docId: String,
                           running: Bool, now: Date) -> ResolveEditionItems.HeadRounds {
        ResolveEditionItems.headRounds(
            newest: read.newestRound.flatMap { $0.docId == docId ? $0 : nil },
            rounds: read.rounds.filter { $0.key == docId }, running: running, now: now)
    }

    /// The letter's byline: who wrote it, the round and the day — no
    /// chapter, which the subject line above already names.
    static func signature(translator: String, round: TranslationRound) -> String {
        ResolveEditionItems.signature(translator: translator, chapter: nil, round: round)
    }

    /// The head with no letter on this piece yet.
    static func noLetterLine(translator: String, language: String, noun: String,
                             hasRounds: Bool) -> String {
        hasRounds
            ? "\(translator) wrote no letter on this \(noun)\u{2019}s latest round."
            : "\(translator) has not run a round on this \(noun) in \(LanguageName.title(language)) yet."
    }

    /// The head's first line: what the list below is about.
    static func headerLine(language: String) -> String {
        "\(LanguageName.title(language)) translation"
    }

    // MARK: Whose run it is (fix round 1, I2)

    /// **What the project's one pipeline is doing, seen from this piece in
    /// this language.** The pipeline is project-wide and its status names a
    /// pair, so a head that matched by language alone drew another chapter's
    /// leg and a Cancel that killed it (review I2).
    enum PieceRun: Equatable {
        case none
        /// This piece's round in this language — or a book run in it that has
        /// this piece still to reach (`TranslationPipeline.queue`).
        case this
        /// Any other round: another chapter, or this one in another language.
        case elsewhere(docId: String, language: String, book: TranslationPipeline.BookProgress?)
    }

    static func pieceRun(status: TranslationPipeline.Status, queued: [String],
                         docId: String, language: String) -> PieceRun {
        guard case .running(let runDoc, let runLanguage, _, let book) = status else { return .none }
        if runLanguage.caseInsensitiveCompare(language) == .orderedSame,
           runDoc == docId || queued.contains(docId) {
            return .this
        }
        return .elsewhere(docId: runDoc, language: runLanguage, book: book)
    }

    /// The pipeline's status as this head may draw it: its own run's, else
    /// idle — so `TranslationRunState.resolve` draws no leg and no Cancel for
    /// another chapter's round.
    static func pipelineStatus(_ status: TranslationPipeline.Status,
                               relation: PieceRun) -> TranslationPipeline.Status {
        relation == .this ? status : .idle
    }

    /// The quiet line for a round running elsewhere — no Cancel here; the
    /// toolbar's indicator is where that run is reached.
    static func elsewhereLine(_ relation: PieceRun, noun: String, titleOf: (String) -> String?) -> String? {
        guard case .elsewhere(let docId, let language, let book) = relation else { return nil }
        let title = titleOf(docId).map { "\u{201C}\($0)\u{201D}" } ?? "another \(noun)"
        let progress = book.map { " (\($0.position) of \($0.count))" } ?? ""
        return "Translating \(title) into \(LanguageName.title(language))\(progress)\u{2026}"
    }

    // MARK: Run, on this piece

    /// **Whether Run is drawn**: on the open piece only (plan 2's rule — a
    /// round translates the document the window is on), where this Mac's
    /// TRANSLATOR may translate it (`TranslationRunOffers.decide`, the
    /// desk's rule), and not while the one pipeline runs another round
    /// (the head says which instead).
    static func offersRun(docId: String, isOpen: Bool, mayTranslate: (String) -> Bool,
                          relation: PieceRun = .none) -> Bool {
        if case .elsewhere = relation { return false }
        return isOpen && TranslationRunOffers.decide(target: docId, book: [docId], mayTranslate: mayTranslate).run
    }

    /// In place of Run on a piece that is not open: its click opens it,
    /// read in the language.
    /// **The way from a piece read in a language to its page in that
    /// edition's book** (closing round, writer's seat a).
    static func seeInBookTitle(noun: String, language: String) -> String {
        "See this \(noun) in the \(LanguageName.title(language)) book"
    }

    static let seeInBookHelp = "Open this edition\u{2019}s compiled book at this piece\u{2019}s first page"

    static func openToRunLine(noun: String) -> String {
        "Open this \(noun) to translate it"
    }

    /// **What the Run slot holds** (fix round 1, I1 + M12): Run on the open
    /// piece; "Opening…" while the open piece is still registering (never an
    /// offer to open what is already opening); otherwise the line that opens
    /// it — naming its questions when the list has some whose Reply needs it
    /// open (`ResolveHead.hasItemsToAnswer`), as the ordinary head does.
    enum OpenSlot: Equatable {
        case run
        case opening
        case open(String)
    }

    static func openSlot(isOpen: Bool, isOpening: Bool, hasItemsToAnswer: Bool, noun: String) -> OpenSlot {
        if isOpen { return .run }
        if isOpening { return .opening }
        return .open(hasItemsToAnswer ? "Open this \(noun) to answer its questions" : openToRunLine(noun: noun))
    }

    static let openingLine = "Opening\u{2026}"

    /// **What Run costs, for the piece and language it was taken for**
    /// (fix round 1, M1): another piece shows nothing, never a stale figure.
    struct Cost: Equatable {
        let docId: String
        let language: String
        let answer: TranslationPreflight.Budgets.Answer?

        func answer(docId: String, language: String) -> TranslationPreflight.Budgets.Answer? {
            docId == self.docId && language.caseInsensitiveCompare(self.language) == .orderedSame
                ? answer : nil
        }
    }

    static func runHelp(language: String, title: String) -> String {
        TranslationRunState.runHelp(language: language, target: .ready(docId: "", title: title))
    }

    static func runAccessibilityLabel(language: String, noun: String) -> String {
        "Translate this \(noun) into " + LanguageName.labelled(language)
    }

    /// The line under Run: what it runs, and what it will cost before the
    /// press (the edition head's rule, `TranslationRunState.preflightLine`).
    static func runScopeLine(noun: String, language: String,
                             preflight: TranslationPreflight.Budgets.Answer?) -> String {
        let cost = TranslationRunState.preflightLine(preflight).map { " \u{00B7} \($0)" } ?? ""
        return "Translates this \(noun) into \(LanguageName.title(language))\(cost)."
    }

    /// **Run, decided**: a round under way, an unusable tag, then the start —
    /// the cast sheet's ask, or the notice.
    @MainActor
    static func run(language: String, docId: String, session: TranslationRunSession,
                    verbs: PieceInLanguageHeadVerbs) async -> TranslationRunStart {
        if case .busy(let busy) = session {
            return .init(notice: TranslationRunState.busyReason(language: busy))
        }
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            return .init(notice: TranslationRunState.unusableTag(language: language))
        }
        return await verbs.startRun(language, docId)
    }

    /// The cast sheet's Confirm for this piece's run: name the cast, then run
    /// the piece the sheet was asked over. Returns the notice.
    @MainActor
    static func confirmCast(_ answer: EditionCastAnswer, prompt: EditionCastPrompt,
                            store: ProjectStore, verbs: PieceInLanguageHeadVerbs) async -> String? {
        guard case .nameForRun(let language, let docId) = prompt.ask else { return nil }
        let named = await EditionCastVerbs.nameCast(language: language, answer: answer, store: store)
        guard named.translatorNamed else { return named.failure }
        return verbs.runNamed(language, docId) ?? named.failure
    }

    // MARK: The empty list

    /// **What a piece read in a language with nothing listed says** — true,
    /// and the next step where there is one. Never "nothing waits" while the
    /// window's first walk has not reached the piece's questions
    /// (`BookReading.isComplete`); and where the piece's SOURCE has something
    /// open — the tree's dot on its row (`ResolvePresence.rowMark`) — it says
    /// so, so a dotted row never faces a list that claims the piece is quiet.
    static func clearLine(language: String, noun: String, hasRounds: Bool,
                          readingBook: Bool, sourceHasSomething: Bool) -> String {
        if readingBook {
            return "Still reading this \(noun)\u{2019}s questions\u{2026} What the translator asks "
                + "will be listed here."
        }
        let name = LanguageName.title(language)
        var line = hasRounds
            ? "Nothing in this \(noun)\u{2019}s \(name) waits on you: every question is answered "
                + "and nothing from its latest round is left to look at."
            : "No round has run on this \(noun) in \(name) yet. What the translator asks, and "
                + "what its rounds leave to look at, will be listed here."
        if sourceHasSomething {
            line += " " + sourceHasSomethingLine
        }
        return line
    }

    /// The source's own items, said under the language's empty list; the
    /// button under it reads the piece in Source (`readSource`).
    static let sourceHasSomethingLine = "Its source has notes or to-dos open."
    static let readSourceTitle = "Read in Source to See Them"

    // MARK: The source's items, from a piece read in a language

    /// **Which key asks for the SOURCE's items** (plan 4 closing review, I2):
    /// ⌘⌥A (the passes' notes), ⌘⌥D (checks) and ⌘⌥T (to-dos) over a piece
    /// read in a language ask for what that language's list never holds. They
    /// read the piece in Source first, visibly, then land their filter; the
    /// piece's id is returned. ⌘⌥L (Questions) is the language's own, and
    /// every other ground — a Source piece, an edition, a Part, the Book —
    /// lists what the key asks for already: nil. Pure.
    static func readsSourceFirst(_ key: ResolveKeyFilter, scope: ResolveScope) -> String? {
        guard case .pieceInLanguage(let docId, _) = scope else { return nil }
        switch key {
        case .rounds, .checks, .mine: return docId
        case .questions: return nil
        }
    }

    /// **How the piece comes to be read in Source**: the open piece is
    /// switched in place (the writer's own choice, the place kept); a piece
    /// only faced — an edition open, a chapter clicked — opens in the centre,
    /// which reads it in Source. Pure.
    enum SourceRead: Equatable {
        case switchHere
        case open(docId: String)
    }

    static func sourceRead(docId: String, openDocId: String?) -> SourceRead {
        docId == openDocId ? .switchHere : .open(docId: docId)
    }

    /// Read `docId` in Source — `sourceRead`'s answer, through the routes the
    /// writer's own choices take (`LanguageSwitch.choose`, the ordinary place).
    @MainActor
    static func readSource(docId: String, openDocId: String?) {
        switch sourceRead(docId: docId, openDocId: openDocId) {
        case .switchHere: LanguageSwitch.choose(nil)
        case .open(let docId): ResolveNavigation.go(toDocId: docId)
        }
    }

    // MARK: Left over from deleted paragraphs

    /// **Clear the left-over translations** — a tombstone per id, in one
    /// batch, through the one translation store. The writer's own act, so it
    /// signs as the `author` (P1b) and asks the author's translation door
    /// first (`refuseUnlessTranslatable`): a refusal writes nothing. The one
    /// sanctioned second `appendBatch` site beside the write pipeline, and
    /// tombstones only (`TripwireGrepTests`). `sourceHash` hashes the empty
    /// string: the paragraph is gone, so there is no source to hash.
    @MainActor
    static func clear(
        _ ids: [String], docId: String, language: String,
        identities: LocalIdentities = .current,
        deviceState: OpLogDeviceState = .shared,
        projectURL: URL
    ) async throws {
        guard !ids.isEmpty else { return }
        try TranslationWritePipeline.refuseUnlessTranslatable(
            documentId: docId, actor: .author, identities: identities,
            deviceState: deviceState, projectURL: projectURL)
        let records = ids.map {
            TranslationRecord(paragraphId: $0, language: language, text: nil,
                              sourceHash: TranslationHash.hash(""))
        }
        try await TranslationStore.appendBatch(
            records, forDocId: docId, language: language,
            identity: identities.author, identities: identities,
            state: deviceState, in: projectURL)
    }

    /// **Clear, as the row's button runs it**: the write, then the post that
    /// makes every surface on the project re-derive (`write_translation`'s
    /// own). A refusal is said — to the window's notice channel and back to
    /// the caller — never only logged; nil means the tombstones landed.
    @MainActor
    static func clearAndAnnounce(_ ids: [String], docId: String, language: String,
                                 projectURL: URL) async -> String? {
        do {
            try await clear(ids, docId: docId, language: language, projectURL: projectURL)
        } catch {
            let sentence = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            leftOverLog.warning(
                "left-over clear refused for \(ids.count, privacy: .public) id(s): \(sentence, privacy: .public)")
            MaughamEvent.postNotice(sentence, projectURL: projectURL)
            return sentence
        }
        MaughamEvent.post(.maughamTranslationDidUpdate, to: .project(for: projectURL),
                          payload: ["document_id": docId, "language": language])
        return nil
    }

    /// Clear is drawn on the open piece only, where the author may translate
    /// it — the question `clear` asks the door. Hidden, never disabled.
    static func offersClear(isOpen: Bool, authorPosture: Posture) -> Bool {
        isOpen && authorPosture.allows(.translate)
    }

    // MARK: Going to a paragraph

    /// A paragraph of the piece, revealed in the language.
    static func reveal(docId: String, language: String, paragraphId: String) -> TranslationReveal {
        TranslationReveal(docId: docId, language: language, paragraphId: paragraphId)
    }

    /// A paragraph's line in the head's lists: its first words, else its id.
    static func paragraphLabel(_ text: String?, paragraphId: String) -> String {
        let shown = text.map { RenderFilter.stripTaskAnchorsInline($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let shown, !shown.isEmpty else { return paragraphId }
        return shown
    }
}

// MARK: - What the head's buttons reach

/// **The head's run verbs, as closures** — built from the window's roster in
/// production, recorded by the tests, which call the head's decisions
/// directly (tripwire 33).
struct PieceInLanguageHeadVerbs {
    /// One round on one piece (`TranslationRunStart.startRun`): the cast
    /// sheet's ask, or nil and the notice.
    var startRun: (_ language: String, _ docId: String) async -> TranslationRunStart
        = { _, _ in .init(notice: TranslationRunStart.noTranslatorWired) }
    /// After the cast sheet named the translator: nil when it started.
    var runNamed: (_ language: String, _ docId: String) -> String? = { _, _ in nil }
    var cancel: () -> Void = {}

    @MainActor
    static func production(roster: AgentRoster?, store: ProjectStore,
                           documentStore: DocumentStore) -> PieceInLanguageHeadVerbs {
        guard let roster else { return PieceInLanguageHeadVerbs() }
        let pipeline = roster.pipeline
        return PieceInLanguageHeadVerbs(
            startRun: { language, docId in
                await TranslationRunStart.startRun(
                    language: language, docId: docId, pipeline: pipeline,
                    documentStore: documentStore, store: store)
            },
            runNamed: { language, docId in
                TranslationRunStart.refusedIfBusy(pipeline.run(docId: docId, language: language),
                                                  pipeline: pipeline)
            },
            cancel: {
                roster.pipeline.cancel()
                roster.translator.cancel()
            })
    }
}

// MARK: - The head

/// **A piece read in a language: To resolve's head** (shell p4 Task 9).
///
/// 1. The language, then why this piece's newest round stopped (failed or
///    cancelled), in its own words, with Open the report.
/// 2. This piece's latest finished round's letter in the language, signed,
///    with Open the report — or who has not written one.
/// 3. Run (this piece, this language) on the open piece where its
///    translator may, with the line saying what it runs and what it costs,
///    Cancel while it runs and the running leg; the last run's report and
///    the trend while idle. Off the open piece: "Open this chapter to run a
///    round on it", which opens it read in the language.
/// 4. What the translation lacks — paragraphs out of date, not translated
///    yet — each a link to its paragraph in the language.
/// 5. What is left over from deleted paragraphs, with Clear on the open
///    piece.
/// 6. The caret's paragraph (`PieceInLanguageCaretSection`): spot-checks and
///    a table's cells, on the open piece.
///
/// A run's reader is the language's translator, never another loop's
/// (tripwire 34).
@MainActor
struct PieceInLanguageHeadView: View {
    let docId: String
    let language: String
    let store: ProjectStore
    let documentStore: DocumentStore
    /// The piece's own read (`ResolveEditionItems.readPiece`).
    let read: ResolveEditionItems.Read
    /// Whether the piece is the one open in the centre — Run, Clear and the
    /// caret's paragraph act only there.
    let isOpen: Bool
    /// The window's editor control, where the editor shows this piece in
    /// this language: its badges are the translation the writer sees, read
    /// here rather than derived twice. Nil anywhere else.
    let editorControl: EditorControl?
    /// The piece's first paragraph — where "Open this chapter" lands.
    let firstParagraph: String?
    /// The source paragraph texts, for the lists' labels.
    let paragraphText: [String: String]
    let model: String
    let world: DeclaredWorldStore?
    let onShowRound: (TranslationRound) -> Void
    /// The read's own key: a new translation re-reads (`.maughamTranslationDidUpdate`).
    var translationHeard: Int = 0
    /// The piece is the one open in the centre but its `Document` is still
    /// registering (fix round 1, M12): the head says it is opening.
    var isOpening: Bool = false
    /// The list holds a question whose Reply needs the piece open
    /// (`ResolveHead.hasItemsToAnswer`, fix round 1, I1).
    var hasItemsToAnswer: Bool = false
    /// File ▸ Translate This Chapter into …'s ask (shell p5 Task 7, row 7):
    /// Run, pressed for the menu where Run is offered; spent either way.
    var translateAsk: Binding<Bool> = .constant(false)

    @Environment(AgentRoster.self) private var roster: AgentRoster?
    @State private var notice: String?
    @State private var castPrompt: EditionCastPrompt?
    @State private var cost: ResolvePieceInLanguage.Cost?
    @State private var derived: ResolvePieceInLanguage.Translation?
    @State private var showsOutOfDate = false
    /// nil: the default for the count (`leftOversStartShown`).
    @State private var showsLeftOvers: Bool?
    @State private var clearing = false
    @State private var confirmingClear: [ResolvePieceInLanguage.LeftOver]?

    /// What Run costs on THIS piece in this language; nil for any other.
    private var preflight: TranslationPreflight.Budgets.Answer? {
        cost?.answer(docId: docId, language: language)
    }

    /// The project's one pipeline, seen from this piece (fix round 1, I2).
    private var relation: ResolvePieceInLanguage.PieceRun {
        guard let pipeline = roster?.pipeline else { return .none }
        return ResolvePieceInLanguage.pieceRun(status: pipeline.status, queued: pipeline.queue,
                                               docId: docId, language: language)
    }

    private struct PreflightKey: Equatable {
        let docId: String
        let language: String
        let manifest: Date
        let idle: Bool
        let heard: Int
    }

    private struct DeriveKey: Equatable {
        let docId: String
        let language: String
        let fromTheEditor: Bool
        let heard: Int
    }

    private var verbs: PieceInLanguageHeadVerbs {
        PieceInLanguageHeadVerbs.production(roster: roster, store: store, documentStore: documentStore)
    }

    /// What the project calls this piece (`PieceNoun`).
    private var pieceWord: PieceNoun {
        PieceNoun.of(TreeWalk.find(id: docId, in: store.manifest.structure), in: store.manifest)
    }

    private var noun: String { pieceWord.singular }

    /// The editor's badges, when the editor shows this piece in this
    /// language; nil otherwise (then `derived` answers).
    private var editorTranslation: ResolvePieceInLanguage.Translation? {
        guard isOpen, let control = editorControl,
              control.translationLanguage?.caseInsensitiveCompare(language) == .orderedSame
        else { return nil }
        let badges = control.translationBadges
        // An empty surface is a refused read (the editor says why in the
        // centre) or one not derived yet: the head reads for itself and says
        // what is true (fix round 1, M4).
        guard !badges.entries.isEmpty else { return nil }
        return ResolvePieceInLanguage.translation(
            docId: docId, language: language,
            statuses: badges.entries.map { ($0.paragraphId, $0.status) }, orphans: badges.orphans)
    }

    private var translation: ResolvePieceInLanguage.Translation? {
        editorTranslation ?? derived.flatMap { $0.docId == docId && $0.language == language ? $0 : nil }
    }

    var body: some View {
        content.onChange(of: translateAsk.wrappedValue, initial: true) { _, asked in
            guard asked else { return }
            translateAsk.wrappedValue = false
            guard ResolvePieceInLanguage.offersRun(docId: docId, isOpen: isOpen, mayTranslate: {
                TranslationRunStart.postureOfTheTranslator(forPiece: $0, in: documentStore).allows(.translate)
            }, relation: relation) else { return }
            if runState.canRun { runThisPiece() } else { notice = runState.refusal }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ResolvePieceInLanguage.headerLine(language: language))
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            // Its page in this edition's book (closing round, writer's seat
            // a): the edition's book at the chapter, which says so itself when
            // there is no book yet or it cannot find the chapter.
            Button(ResolvePieceInLanguage.seeInBookTitle(noun: noun, language: language)) {
                CentreViewSwitch.go(to: .editionBook(language: language, docId: docId))
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(ResolvePieceInLanguage.seeInBookHelp)
            .accessibilityIdentifier("resolve.pieceInLanguage.seeInBook")
            letter
            runSection
            if let translation { translationSection(translation) }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("resolve.pieceInLanguage.notice")
            }
            if isOpen, let document = documentStore.document(forDocId: docId), let control = editorControl {
                PieceInLanguageCaretSection(
                    document: document, control: control, language: language, store: store,
                    documentStore: documentStore, model: model, world: world)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        // The piece's translation, off the main actor — only where the
        // editor is not already showing it in this language.
        .task(id: DeriveKey(docId: docId, language: language, fromTheEditor: editorTranslation != nil,
                            heard: translationHeard)) {
            guard editorTranslation == nil else { return }
            let read = await ResolvePieceInLanguage.readTranslation(
                docId: docId, language: language, store: store, documentStore: documentStore)
            if !Task.isCancelled { derived = read }
        }
        // What Run costs on this piece, while idle (the edition head's rule).
        .task(id: PreflightKey(docId: docId, language: language, manifest: store.manifest.modified,
                               idle: TranslationPreflight.refillsBudgets(
                                   pipeline: roster?.pipeline.status ?? .idle),
                               heard: translationHeard)) {
            guard isOpen, TranslationPreflight.refillsBudgets(pipeline: roster?.pipeline.status ?? .idle)
            else { return }
            let asked = (docId, language)
            let answer = await TranslationPreflight.editionBudget(
                documentIds: [docId], language: language, store: store, documentStore: documentStore)
            if !Task.isCancelled {
                cost = ResolvePieceInLanguage.Cost(docId: asked.0, language: asked.1, answer: answer)
            }
        }
        .onChange(of: docId) { _, _ in
            notice = nil
            showsOutOfDate = false
            showsLeftOvers = nil
            confirmingClear = nil
        }
        .confirmationDialog(
            ResolvePieceInLanguage.clearConfirmTitle(count: confirmingClear?.count ?? 0),
            isPresented: Binding(get: { confirmingClear != nil },
                                 set: { if !$0 { confirmingClear = nil } })
        ) {
            Button(ResolvePieceInLanguage.clearTitle, role: .destructive) {
                if let shown = confirmingClear { clear(shown) }
                confirmingClear = nil
            }
            Button(TranslationRunState.cancelTitle, role: .cancel) { confirmingClear = nil }
        } message: {
            Text(ResolvePieceInLanguage.clearHelp)
        }
        .sheet(item: $castPrompt) { prompt in
            EditionCastSheet(prompt: prompt,
                             onConfirm: { answer in
                                 castPrompt = nil
                                 Task {
                                     notice = await ResolvePieceInLanguage.confirmCast(
                                         answer, prompt: prompt, store: store, verbs: verbs)
                                 }
                             },
                             onCancel: {
                                 castPrompt = nil
                                 notice = EditionCastCopy.cancelledLine(language: language)
                             })
        }
        Divider()
    }

    // MARK: The letter

    private var translatorName: String {
        EditionStatus.translatorName(for: language, in: store.manifest) ?? language.uppercased()
    }

    /// Whether THIS piece's round runs — never another chapter's (M10).
    private var isRunning: Bool { relation == .this }

    @ViewBuilder
    private var letter: some View {
        let head = ResolvePieceInLanguage.headRounds(read, docId: docId, running: isRunning, now: Date())
        if let stopped = head.stopped, let line = head.stoppedLine {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(stopped.failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("resolve.pieceInLanguage.stopped")
                Button(ResolveEditionItems.openTheReportTitle) { onShowRound(stopped) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .fixedSize()
                    .help(TranslationRunState.showRoundHelp)
            }
        }
        if let round = head.letter, let words = ResolveEditionItems.letter(of: round) {
            if head.letterIsEarlier {
                Text(ResolveEditionItems.earlierLetterLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(words)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("resolve.pieceInLanguage.letter")
            Text(ResolvePieceInLanguage.signature(translator: round.signedBy(liveName: translatorName),
                                                  round: round))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ResolveEditionItems.openTheReportTitle) { onShowRound(round) }
                .buttonStyle(.link)
                .font(.caption)
                .help(TranslationRunState.showRoundHelp)
        } else if read.language != nil {
            Text(ResolvePieceInLanguage.noLetterLine(translator: translatorName, language: language,
                                                     noun: noun, hasRounds: read.hasRounds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Run

    /// The piece's run state: the window's translator and pipeline, this
    /// piece as the target (open, or the sentence that says how), and the
    /// last run this window saw end on it (`roster.translationRuns`).
    private var runState: TranslationRunState {
        let runState = roster?.translator.runState ?? .idle
        let pipeline = roster?.pipeline.status ?? .idle
        let title = TreeWalk.find(id: docId, in: store.manifest.structure)?.title ?? ""
        return TranslationRunState.resolve(
            language: language,
            target: isOpen ? .ready(docId: docId, title: title) : .unavailable(TranslationRunTarget.openAChapter),
            session: TranslationRunSession.read(
                runState: runState, isRunning: roster?.translator.isRunning ?? false, pipeline: pipeline),
            runState: runState,
            lastRun: roster?.translationRuns.run(docId: docId, language: language),
            pipeline: ResolvePieceInLanguage.pipelineStatus(pipeline, relation: relation),
            trend: read.trend, chapterPreflight: preflight)
    }

    @ViewBuilder
    private var runSection: some View {
        let run = runState
        let relation = relation
        let slot = ResolvePieceInLanguage.openSlot(isOpen: isOpen, isOpening: isOpening,
                                                   hasItemsToAnswer: hasItemsToAnswer, noun: noun)
        // Another chapter's round: said quietly, no Cancel and no Run here
        // (the toolbar's indicator reaches it) — fix round 1, I2.
        if let elsewhere = ResolvePieceInLanguage.elsewhereLine(relation, noun: noun, titleOf: {
            TreeWalk.find(id: $0, in: store.manifest.structure)?.title
        }) {
            Text(elsewhere)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("resolve.pieceInLanguage.elsewhere")
        }
        if ResolvePieceInLanguage.offersRun(docId: docId, isOpen: isOpen, mayTranslate: {
            TranslationRunStart.postureOfTheTranslator(forPiece: $0, in: documentStore).allows(.translate)
        }, relation: relation) {
            FlowLayout(spacing: 6) {
                Button(TranslationRunState.runTitle(pieceWord)) { runThisPiece() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!run.canRun)
                    .accessibilityLabel(ResolvePieceInLanguage.runAccessibilityLabel(language: language, noun: noun))
                    .help(run.refusal ?? ResolvePieceInLanguage.runHelp(
                        language: language,
                        title: TreeWalk.find(id: docId, in: store.manifest.structure)?.title ?? ""))
                if run.isRunning {
                    Button(TranslationRunState.cancelTitle) { verbs.cancel() }
                        .controlSize(.small)
                        .fixedSize()
                        .help(TranslationRunState.cancelHelp)
                }
            }
            Text(ResolvePieceInLanguage.runScopeLine(noun: noun, language: language, preflight: preflight))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if case .opening = slot {
            Text(ResolvePieceInLanguage.openingLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .open(let line) = slot {
            ResolveOpenThePieceButton(line: line) {
                if let firstParagraph {
                    TranslationReveal.post(ResolvePieceInLanguage.reveal(
                        docId: docId, language: language, paragraphId: firstParagraph))
                } else {
                    ResolveNavigation.go(toDocId: docId)
                }
            }
        }
        // While it runs, its leg; idle, the last run's report and the trend.
        if let status = run.statusLine, run.isRunning || run.isFailure || run.report != nil {
            Text(status)
                .font(.caption)
                .foregroundStyle(run.isFailure ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("resolve.pieceInLanguage.status")
        }
        if let trend = TranslationRunState.trendLine(read.trend), !run.isRunning {
            Text(trend)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runThisPiece() {
        notice = nil
        let session = TranslationRunSession.read(
            runState: roster?.translator.runState ?? .idle,
            isRunning: roster?.translator.isRunning ?? false,
            pipeline: roster?.pipeline.status ?? .idle)
        let verbs = verbs
        Task {
            let outcome = await ResolvePieceInLanguage.run(language: language, docId: docId,
                                                           session: session, verbs: verbs)
            if let prompt = outcome.castPrompt { castPrompt = prompt }
            notice = outcome.notice
        }
    }

    // MARK: The translation itself

    @ViewBuilder
    private func translationSection(_ translation: ResolvePieceInLanguage.Translation) -> some View {
        if let reason = translation.unreadable {
            Text(ResolvePieceInLanguage.unreadableLine(reason))
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let line = ResolvePieceInLanguage.freshnessLine(translation) {
            disclosureLine(line, isShown: $showsOutOfDate, identifier: "resolve.pieceInLanguage.freshness")
            if showsOutOfDate {
                PieceInLanguageParagraphLinks(translation: translation, paragraphText: paragraphText)
            }
        }
        if !translation.leftOvers.isEmpty {
            let count = translation.leftOvers.count
            let shown = Binding(
                get: { showsLeftOvers ?? ResolvePieceInLanguage.leftOversStartShown(count: count) },
                set: { showsLeftOvers = $0 })
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                disclosureLine(ResolvePieceInLanguage.leftOverLine(count: count),
                               isShown: shown, identifier: "resolve.pieceInLanguage.leftOvers")
                if ResolvePieceInLanguage.offersClear(
                    isOpen: isOpen, authorPosture: documentStore.posture(forDocId: docId)) {
                    // Asks first, naming the count (fix round 1, M3).
                    Button(ResolvePieceInLanguage.clearTitle) {
                        confirmingClear = translation.leftOvers
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(clearing)
                    .help(ResolvePieceInLanguage.clearHelp)
                }
            }
            // The texts are what Clear removes: shown, or — many — their
            // first lines under the count.
            PieceInLanguageLeftOvers(leftOvers: translation.leftOvers, preview: !shown.wrappedValue)
        }
    }

    private func disclosureLine(_ line: String, isShown: Binding<Bool>, identifier: String) -> some View {
        Button {
            isShown.wrappedValue.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: isShown.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(line)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(line)
        .accessibilityHint(isShown.wrappedValue ? ResolvePieceInLanguage.hideTitle : ResolvePieceInLanguage.showTitle)
        .accessibilityIdentifier(identifier)
    }

    /// **Clear what was shown, as the STORE holds it at the press** (fix
    /// round 1, M2): the left-overs are read again from the translation
    /// files, and a shown one that changed refuses the whole Clear.
    private func clear(_ shown: [ResolvePieceInLanguage.LeftOver]) {
        clearing = true
        Task { @MainActor in
            let now = await ResolvePieceInLanguage.readTranslation(
                docId: docId, language: language, store: store, documentStore: documentStore)
            switch ResolvePieceInLanguage.clearDecision(shown: shown, now: now.leftOvers) {
            case .clear(let ids):
                notice = await ResolvePieceInLanguage.clearAndAnnounce(ids, docId: docId, language: language,
                                                                       projectURL: store.url)
            case .refuse(let sentence):
                notice = now.unreadable.map(ResolvePieceInLanguage.unreadableLine) ?? sentence
            }
            clearing = false
        }
    }
}

/// **What the translation lacks, paragraph by paragraph** — the head's
/// disclosed list: each out-of-date paragraph (an amber dot) and each not yet
/// translated (a hollow one), by its first words, a link to it in the
/// language.
@MainActor
struct PieceInLanguageParagraphLinks: View {
    let translation: ResolvePieceInLanguage.Translation
    let paragraphText: [String: String]

    private struct Row: Identifiable {
        let id: String
        let stale: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Each row's kind travels with it — no per-row lookup (tripwire 4).
            ForEach(translation.outOfDate.map { Row(id: $0, stale: true) }
                    + translation.untranslated.map { Row(id: $0, stale: false) }) { row in
                paragraphLink(row.id, stale: row.stale)
            }
        }
        .padding(.leading, 14)
    }

    private func paragraphLink(_ paragraphId: String, stale: Bool) -> some View {
        Button {
            TranslationReveal.post(ResolvePieceInLanguage.reveal(
                docId: translation.docId, language: translation.language,
                paragraphId: paragraphId))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: stale ? "circle.fill" : "circle")
                    .font(.system(size: 6))
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
                Text(ResolvePieceInLanguage.paragraphLabel(paragraphText[paragraphId], paragraphId: paragraphId))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((stale ? "Out of date: " : "Not translated yet: ")
                            + ResolvePieceInLanguage.paragraphLabel(paragraphText[paragraphId],
                                                                    paragraphId: paragraphId))
    }

}

/// **The translations left over from deleted paragraphs**, as the head
/// discloses them: their text, selectable, quiet.
struct PieceInLanguageLeftOvers: View {
    let leftOvers: [ResolvePieceInLanguage.LeftOver]
    /// The count's preview: the first two, two lines each, and how many more.
    var preview: Bool = false

    static let previewCount = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(preview ? Array(leftOvers.prefix(Self.previewCount)) : leftOvers) { leftOver in
                Text(leftOver.staleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(preview ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if preview, leftOvers.count > Self.previewCount {
                Text("and \(leftOvers.count - Self.previewCount) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 14)
    }
}
