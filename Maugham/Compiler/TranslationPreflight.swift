import Foundation
import MaughamCore

/// **"7 legs · ~N words briefed"** (spec §5's pre-flight): what a Run will send,
/// as a number the writer can weigh before the click. N is the source words
/// plus the translated words of every document in the set — the two texts the
/// legs are briefed with — plus the table cells the translator leg is briefed
/// (report plan 9e-2): each missing or stale label's source text and a stale
/// one's prior translation, every table once however many pieces use it.
/// `Bootstrap`'s own whitespace split, so the figure agrees with the
/// checkpoint's word count.
enum TranslationPreflight {

    /// **What a pre-flight pass answered** (P2a D0, fix round 1).
    ///
    /// Three states rather than a dictionary, because a dictionary has only
    /// two: figures, and an empty one standing in for everything else. Before
    /// this, a refusal was caught at the desk and turned into `[:]` — the
    /// writer watched the "~N words briefed" clause simply vanish, and the only
    /// thing naming the file was `EditionStatus`' Couldn't-read line happening
    /// to be derived on the same pass. That coupling was a habit and nothing
    /// pinned it; this makes the pre-flight say it itself.
    enum Budgets: Equatable {
        /// Nothing was asked, or the scope has nothing in it. Draws no clause.
        case none
        /// Words to brief, per language tag.
        case counted([String: Int])
        /// A translation file is present and unreadable. Carries the refusal's
        /// own sentence, which names the file.
        case unreadable(String)

        /// What this scope has to say about one language — words, or a
        /// refusal, or nothing at all.
        ///
        /// `nil` is what lets the chapter's answer fall through to the book's
        /// WHOLE: a chapter that refused is never papered over with the book's
        /// figure, and a chapter that counted is never reported through the
        /// book's refusal.
        func answer(for language: String) -> Answer? {
            switch self {
            case .none: return nil
            case .unreadable(let sentence): return .unreadable(sentence)
            case .counted(let byLanguage): return byLanguage[language].map(Answer.words)
            }
        }

        enum Answer: Equatable {
            case words(Int)
            case unreadable(String)
        }

        /// One pre-flight pass, folded into this answer: `budgets`' figures, or
        /// the refusal's own sentence. The door the desk uses; the throwing
        /// `budgets` stays for callers that genuinely propagate.
        @MainActor
        static func over(
            documentIds: [String], languages: [String],
            store: ProjectStore, documentStore: DocumentStore?, projectURL: URL
        ) async -> Budgets {
            do {
                return .counted(try await TranslationPreflight.budgets(
                    documentIds: documentIds, languages: languages, store: store,
                    documentStore: documentStore, projectURL: projectURL))
            } catch {
                return .unreadable(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func sum(source: [String], translations: [String?]) -> Int {
        source.map(wordCount).reduce(0, +)
            + translations.compactMap { $0 }.map(wordCount).reduce(0, +)
    }

    /// The words one table's briefed cells carry: each cell's source text and
    /// a stale cell's prior translation — what the translator leg is shown.
    static func cellWords(_ work: TableCellWork) -> Int {
        sum(source: work.cells.map(\.sourceText), translations: work.cells.map(\.priorTranslation))
    }

    /// **Every edition's budget over one set of documents, opening each
    /// document once.**
    ///
    /// The desk draws a row per language and wants the same figure for each of
    /// them, and `currentParagraphState` is the expensive half — for a closed
    /// document it derives the whole manuscript off the op log. Asked once per
    /// pair, a four-edition book derives every chapter four times per pass; the
    /// per-language work that is left (`loadMerged` + `derive` + `sum`) reads
    /// one edition's own translation file and is cheap beside it.
    ///
    /// Empty when no document in the set could be read — the same "nothing to
    /// say" `budget` answers with `nil`, and distinct from a language whose
    /// figure is genuinely zero, which is present and 0. Off the body path only
    /// (tripwire 4).
    ///
    /// **Throws when a translation file is present and unreadable** (P2a D0).
    /// A skipped actor file makes the figure too LARGE — every paragraph it
    /// holds reads as untranslated and so as words still to brief — and "~N
    /// words" is exactly the number the writer weighs a click against. The
    /// desk draws no figure at all over the refusal, beside the Couldn't-read
    /// line `EditionStatus` puts up in the same pass for the same file.
    /// Distinct from the unreadable STATE above, which stays a per-document
    /// skip: that one is the document, and it is already reported.
    ///
    /// **The table cells are the translator round's own gather**
    /// (`TableCellPass`, posture-filtered on the acting answer, missing and
    /// stale only), so the figure counts exactly the labels a Run would
    /// brief — one pass for the whole call. A
    /// table used by two pieces of the set is counted once per language: the
    /// first piece's round labels it, the second finds it fresh (R6). A used
    /// table whose translation file will not read throws, the paragraphs' rule.
    @MainActor
    static func budgets(documentIds: [String], languages: [String],
                        store: ProjectStore, documentStore: DocumentStore?,
                        projectURL: URL) async throws -> [String: Int] {
        guard !languages.isEmpty else { return [:] }
        var totals: [String: Int] = [:]
        var counted = false
        var tablesCounted: [String: Set<String>] = [:]
        // One pass for the whole call: figures, trust and posture resolved
        // once, a shared table's coverage derived once (M4).
        let tables = TableCellPass(store: store, documentStore: documentStore, projectURL: projectURL)
        for docId in documentIds {
            guard let state = try? currentParagraphState(
                documentId: docId, store: store, documentStore: documentStore,
                projectURL: projectURL) else { continue }
            counted = true
            for language in languages {
                let records = try TranslationStore.loadMerged(
                    forDocId: docId, language: language, in: projectURL)
                let derived = TranslationDeriver.derive(
                    records: records, sequence: state.sequence,
                    paragraphs: state.paragraphs, language: language)
                totals[language, default: 0] += sum(
                    source: derived.entries.map(\.sourceText),
                    translations: derived.entries.map(\.translatedText))
            }
            let cells = try await tables?.work(
                docId: docId, languages: languages, state: (state.sequence, state.paragraphs)) ?? [:]
            for language in languages {
                for work in cells[language] ?? []
                where tablesCounted[language, default: []].insert(work.figureId).inserted {
                    totals[language, default: 0] += cellWords(work)
                }
            }
        }
        guard counted else { return [:] }
        // A language that summed to nothing still has an answer — the set was
        // readable, so "0 words" is a fact rather than an absence. This is
        // already true of every language by construction: the inner loop
        // above runs `totals[language, default: 0] +=` for every language on
        // every successfully-read docId, so once `counted` is true every
        // language already has an entry.
        return totals
    }

    /// One edition's budget. nil when no document in the set could be read.
    /// Off the body path only (tripwire 4): it opens every document's derived
    /// state.
    @MainActor
    static func budget(documentIds: [String], language: String, store: ProjectStore,
                       documentStore: DocumentStore?, projectURL: URL) async throws -> Int? {
        try await budgets(documentIds: documentIds, languages: [language], store: store,
                          documentStore: documentStore, projectURL: projectURL)[language]
    }

    // MARK: - One edition's figure, off the main actor (shell p4 Task 7 fix round, I2)

    /// **Whether a pre-flight is worth taking now** (the desk's rule,
    /// restored with the figure): only while no round runs. Mid-round the
    /// round's own leg line is what the head says, the figure would describe
    /// a click nobody can make, and every ingest would re-read the book; the
    /// last idle figure stands and the round's end takes a fresh one.
    nonisolated static func refillsBudgets(pipeline: TranslationPipeline.Status) -> Bool {
        pipeline == .idle
    }

    /// **What Run Whole Book will cost, before the press**: `budget`'s figure
    /// for one edition over the run's pieces, with the book's text read OFF
    /// the main actor — a closed piece's op log through `ProjectStore
    /// .readClosedDocument`, its translation through `TranslationStore
    /// .loadMerged` — so nothing book-sized holds the main actor when an
    /// edition is selected. The main actor snapshots the open pieces and, only
    /// where the book has tables, counts the briefed cells one piece per step.
    ///
    /// **Cached per (project, edition, pieces, manifest)** and checked against
    /// a fingerprint taken off the main actor (each closed piece's op-log
    /// file set, the translations folder, the open pieces' text): a second
    /// selection of the same edition over an unchanged book reads no
    /// document. Cancellable: a superseded read stops between pieces.
    @MainActor
    static func editionBudget(documentIds: [String], language: String, store: ProjectStore,
                              documentStore: DocumentStore?) async -> Budgets.Answer? {
        guard !documentIds.isEmpty else { return nil }
        let url = store.url
        let facts = DocumentClass.Facts(store.manifest)
        var open: [String: OpenText] = [:]
        for docId in documentIds {
            if let doc = documentStore?.document(forDocId: docId) {
                open[docId] = OpenText(sequence: doc.sequence, paragraphs: doc.paragraphs)
            }
        }
        let hasTables = (store.manifest.figures ?? []).contains { $0.kind == .table }
        let key = EditionBudgetCache.Key(project: url.path, language: language.lowercased(),
                                         docIds: documentIds, manifest: store.manifest.modified)
        let cached = EditionBudgetCache.entries[key]
        let openFingerprint = open.mapValues(\.fingerprint)
        let work = Task.detached(priority: .utility) { () -> OffMain? in
            let fingerprint = EditionBudgetCache.Fingerprint(
                ops: DerivedManuscriptCache.tokens(forDocIds: documentIds, in: url),
                translations: translationsStamp(in: url), open: openFingerprint)
            if let cached, cached.fingerprint == fingerprint {
                return OffMain(fingerprint: fingerprint, words: nil, cachedAnswer: cached.answer, states: [:])
            }
            return paragraphWords(documentIds: documentIds, language: language, url: url,
                                  facts: facts, open: open, keepStates: hasTables,
                                  fingerprint: fingerprint)
        }
        let offMain = await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
        guard let offMain, !Task.isCancelled else { return nil }
        if let answer = offMain.cachedAnswer { return answer }
        var answer: Budgets.Answer
        switch offMain.words {
        case .none: return nil
        case .failure(let sentence): answer = .unreadable(sentence)
        case .success(var words):
            if hasTables, let tables = TableCellPass(store: store, documentStore: documentStore,
                                                     projectURL: url) {
                var counted: Set<String> = []
                for docId in documentIds {
                    guard let state = offMain.states[docId] else { continue }
                    do {
                        let cells = try await tables.work(docId: docId, languages: [language],
                                                          state: (state.sequence, state.paragraphs))
                        for work in cells[language] ?? [] where counted.insert(work.figureId).inserted {
                            words += cellWords(work)
                        }
                    } catch {
                        answer = .unreadable((error as? LocalizedError)?.errorDescription
                                             ?? error.localizedDescription)
                        EditionBudgetCache.store(key, fingerprint: offMain.fingerprint, answer: answer)
                        return answer
                    }
                    // One piece's cells per main-actor step.
                    await Task.yield()
                    if Task.isCancelled { return nil }
                }
            }
            answer = .words(words)
        }
        EditionBudgetCache.store(key, fingerprint: offMain.fingerprint, answer: answer)
        return answer
    }

    /// An open piece's text, snapshotted on the main actor.
    struct OpenText: Sendable {
        let sequence: [String]
        let paragraphs: [String: String]
        var fingerprint: Int {
            var hasher = Hasher()
            hasher.combine(sequence)
            for id in sequence { hasher.combine(paragraphs[id]) }
            return hasher.finalize()
        }
    }

    struct OffMain: Sendable {
        enum Words: Sendable { case success(Int), failure(String) }
        let fingerprint: EditionBudgetCache.Fingerprint
        let words: Words?
        var cachedAnswer: Budgets.Answer? = nil
        let states: [String: OpenText]
    }

    /// The paragraphs' half, off the main actor: each piece's text (the open
    /// snapshot, else its op log read under the project's trust), its
    /// translation merged and derived, the words summed. A translation file
    /// present and unreadable is the figure's refusal (`budgets`' rule).
    nonisolated static func paragraphWords(
        documentIds: [String], language: String, url: URL, facts: DocumentClass.Facts,
        open: [String: OpenText], keepStates: Bool, fingerprint: EditionBudgetCache.Fingerprint
    ) -> OffMain? {
        let identities = LocalIdentities.current
        let trust = (try? TrustResolution.resolve(projectURL: url, identities: identities))
            ?? TrustResolution.rememberedOrKeyless(projectURL: url, identities: identities)
        var words = 0
        var counted = false
        var states: [String: OpenText] = [:]
        for docId in documentIds {
            if Task.isCancelled { return nil }
            let state: OpenText
            if let snapshot = open[docId] {
                state = snapshot
            } else if let read = ProjectStore.readClosedDocument(docId, in: url, trust: trust, facts: facts) {
                state = OpenText(sequence: read.sequence, paragraphs: read.paragraphs)
            } else { continue }
            counted = true
            do {
                let records = try TranslationStore.loadMerged(forDocId: docId, language: language, in: url)
                let derived = TranslationDeriver.derive(records: records, sequence: state.sequence,
                                                        paragraphs: state.paragraphs, language: language)
                words += sum(source: derived.entries.map(\.sourceText),
                             translations: derived.entries.map(\.translatedText))
            } catch {
                return OffMain(fingerprint: fingerprint,
                               words: .failure((error as? LocalizedError)?.errorDescription
                                               ?? error.localizedDescription),
                               states: [:])
            }
            if keepStates { states[docId] = state }
        }
        return OffMain(fingerprint: fingerprint, words: counted ? .success(words) : nil, states: states)
    }

    /// The translations folder's files — name, size and date — one listing:
    /// any translation written moves it.
    nonisolated static func translationsStamp(in url: URL) -> [String] {
        let dir = TranslationStore.directoryURL(in: url)
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return names.map { name in
            let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            return "\(name)|\(size)|\(date)"
        }
    }
}

/// **The edition figures already counted** (I2's cache): one per (project,
/// edition, pieces, manifest), trusted while its fingerprint holds.
@MainActor
enum EditionBudgetCache {
    struct Key: Hashable {
        let project: String
        let language: String
        let docIds: [String]
        let manifest: Date
    }

    struct Fingerprint: Equatable, Sendable {
        let ops: [String: DerivedManuscriptCache.Token]
        let translations: [String]
        let open: [String: Int]
    }

    struct Entry: Sendable {
        let fingerprint: Fingerprint
        let answer: TranslationPreflight.Budgets.Answer
    }

    static var entries: [Key: Entry] = [:]
    /// Reads that found nothing cached — a test's handle on "read no document".
    static var computed = 0

    static func store(_ key: Key, fingerprint: Fingerprint, answer: TranslationPreflight.Budgets.Answer) {
        computed += 1
        // Small: a window shows one edition at a time.
        if entries.count > 32 { entries.removeAll() }
        entries[key] = Entry(fingerprint: fingerprint, answer: answer)
    }
}
