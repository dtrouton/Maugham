import Foundation
import MaughamCore

/// **"7 legs · ~N words briefed"** (spec §5's pre-flight): what a Run will send,
/// as a number the writer can weigh before the click. N is the source words
/// plus the translated words of every document in the set — the two texts the
/// legs are briefed with. `Bootstrap`'s own whitespace split, so the figure
/// agrees with the checkpoint's word count.
enum TranslationPreflight {

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
    @MainActor
    static func budgets(documentIds: [String], languages: [String],
                        store: ProjectStore, documentStore: DocumentStore?,
                        projectURL: URL) -> [String: Int] {
        guard !languages.isEmpty else { return [:] }
        var totals: [String: Int] = [:]
        var counted = false
        for docId in documentIds {
            guard let state = try? currentParagraphState(
                documentId: docId, store: store, documentStore: documentStore,
                projectURL: projectURL) else { continue }
            counted = true
            for language in languages {
                let records = TranslationStore.loadMerged(
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
                       documentStore: DocumentStore?, projectURL: URL) -> Int? {
        budgets(documentIds: documentIds, languages: [language], store: store,
                documentStore: documentStore, projectURL: projectURL)[language]
    }
}
