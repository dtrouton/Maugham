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

    // MARK: Run, on this piece

    /// **Whether Run is drawn**: on the open piece only (plan 2's rule — a
    /// round translates the document the window is on), where this Mac's
    /// TRANSLATOR may translate it (`TranslationRunOffers.decide`, the
    /// desk's rule). Elsewhere the head says how instead.
    static func offersRun(docId: String, isOpen: Bool, mayTranslate: (String) -> Bool) -> Bool {
        isOpen && TranslationRunOffers.decide(target: docId, book: [docId], mayTranslate: mayTranslate).run
    }

    /// In place of Run on a piece that is not open: its click opens it,
    /// read in the language.
    static func openToRunLine(noun: String) -> String {
        "Open this \(noun) to run a round on it"
    }

    static func runHelp(language: String, title: String) -> String {
        TranslationRunState.runHelp(language: language, target: .ready(docId: "", title: title))
    }

    static func runAccessibilityLabel(language: String) -> String {
        "Run a round on this chapter into " + LanguageName.labelled(language)
    }

    /// The line under Run: what it runs, and what it will cost before the
    /// press (the edition head's rule, `TranslationRunState.preflightLine`).
    static func runScopeLine(noun: String, language: String,
                             preflight: TranslationPreflight.Budgets.Answer?) -> String {
        let cost = TranslationRunState.preflightLine(preflight).map { " \u{00B7} \($0)" } ?? ""
        return "Runs this \(noun) into \(LanguageName.title(language))\(cost)."
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
                + "and every change from its latest round is settled."
            : "No round has run on this \(noun) in \(name) yet. What the translator asks and "
                + "changes will be listed here."
        if sourceHasSomething {
            line += " Its source has notes or to-dos open: read it in Source to see them."
        }
        return line
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

    @Environment(AgentRoster.self) private var roster: AgentRoster?
    @State private var notice: String?
    @State private var castPrompt: EditionCastPrompt?
    @State private var preflight: TranslationPreflight.Budgets.Answer?
    @State private var derived: ResolvePieceInLanguage.Translation?
    @State private var showsOutOfDate = false
    @State private var showsLeftOvers = false
    @State private var clearing = false

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

    private var noun: String {
        FiledUnder.pieceNoun(TreeWalk.find(id: docId, in: store.manifest.structure),
                             projectType: store.manifest.type)
    }

    /// The editor's badges, when the editor shows this piece in this
    /// language; nil otherwise (then `derived` answers).
    private var editorTranslation: ResolvePieceInLanguage.Translation? {
        guard isOpen, let control = editorControl,
              control.translationLanguage?.caseInsensitiveCompare(language) == .orderedSame
        else { return nil }
        let badges = control.translationBadges
        return ResolvePieceInLanguage.translation(
            docId: docId, language: language,
            statuses: badges.entries.map { ($0.paragraphId, $0.status) }, orphans: badges.orphans)
    }

    private var translation: ResolvePieceInLanguage.Translation? {
        editorTranslation ?? derived.flatMap { $0.docId == docId && $0.language == language ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ResolvePieceInLanguage.headerLine(language: language))
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
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
            let answer = await TranslationPreflight.editionBudget(
                documentIds: [docId], language: language, store: store, documentStore: documentStore)
            if !Task.isCancelled { preflight = answer }
        }
        .onChange(of: docId) { _, _ in
            notice = nil
            showsOutOfDate = false
            showsLeftOvers = false
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

    private var isRunning: Bool {
        let status = roster?.pipeline.status ?? .idle
        return status != .idle
    }

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
            pipeline: pipeline, trend: read.trend, chapterPreflight: preflight)
    }

    @ViewBuilder
    private var runSection: some View {
        let run = runState
        if ResolvePieceInLanguage.offersRun(docId: docId, isOpen: isOpen, mayTranslate: {
            TranslationRunStart.postureOfTheTranslator(forPiece: $0, in: documentStore).allows(.translate)
        }) {
            FlowLayout(spacing: 6) {
                Button(TranslationRunState.runTitle) { runThisPiece() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!run.canRun)
                    .accessibilityLabel(ResolvePieceInLanguage.runAccessibilityLabel(language: language))
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
        } else if !isOpen {
            ResolveOpenThePieceButton(line: ResolvePieceInLanguage.openToRunLine(noun: noun)) {
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                disclosureLine(ResolvePieceInLanguage.leftOverLine(count: translation.leftOvers.count),
                               isShown: $showsLeftOvers, identifier: "resolve.pieceInLanguage.leftOvers")
                if ResolvePieceInLanguage.offersClear(
                    isOpen: isOpen, authorPosture: documentStore.posture(forDocId: docId)) {
                    Button(ResolvePieceInLanguage.clearTitle) {
                        clear(translation.leftOvers.map(\.id))
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(clearing)
                    .help(ResolvePieceInLanguage.clearHelp)
                }
            }
            if showsLeftOvers {
                PieceInLanguageLeftOvers(leftOvers: translation.leftOvers)
            }
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

    private func clear(_ ids: [String]) {
        clearing = true
        Task { @MainActor in
            notice = await ResolvePieceInLanguage.clearAndAnnounce(ids, docId: docId, language: language,
                                                                   projectURL: store.url)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(translation.outOfDate + translation.untranslated, id: \.self) { paragraphId in
                paragraphLink(paragraphId, stale: translation.outOfDate.contains(paragraphId))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(leftOvers) { leftOver in
                Text(leftOver.staleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 14)
    }
}
