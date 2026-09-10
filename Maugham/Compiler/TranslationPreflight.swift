import Foundation
import MaughamCore

/// **"7 legs · ~N words briefed"** (spec §5's pre-flight): what a Run will send,
/// as a number the writer can weigh before the click. N is the source words
/// plus the translated words of every document in the set — the two texts the
/// legs are briefed with. `Bootstrap`'s own whitespace split, so the figure
/// agrees with the checkpoint's word count.
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
        ) -> Budgets {
            do {
                return .counted(try TranslationPreflight.budgets(
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
    @MainActor
    static func budgets(documentIds: [String], languages: [String],
                        store: ProjectStore, documentStore: DocumentStore?,
                        projectURL: URL) throws -> [String: Int] {
        guard !languages.isEmpty else { return [:] }
        var totals: [String: Int] = [:]
        var counted = false
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
                       documentStore: DocumentStore?, projectURL: URL) throws -> Int? {
        try budgets(documentIds: documentIds, languages: [language], store: store,
                    documentStore: documentStore, projectURL: projectURL)[language]
    }
}
