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

    /// nil when no document in the set could be read. Off the body path only
    /// (tripwire 4): it opens every document's derived state.
    @MainActor
    static func budget(documentIds: [String], language: String, store: ProjectStore,
                       documentStore: DocumentStore?, projectURL: URL) -> Int? {
        var total = 0
        var counted = false
        for docId in documentIds {
            guard let state = try? currentParagraphState(
                documentId: docId, store: store, documentStore: documentStore,
                projectURL: projectURL) else { continue }
            counted = true
            let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
            let derived = TranslationDeriver.derive(
                records: records, sequence: state.sequence, paragraphs: state.paragraphs, language: language)
            total += sum(source: derived.entries.map(\.sourceText),
                         translations: derived.entries.map(\.translatedText))
        }
        return counted ? total : nil
    }
}
