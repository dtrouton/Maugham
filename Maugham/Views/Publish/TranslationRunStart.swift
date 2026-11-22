import Foundation
import MaughamCore

/// **What a translation Run does once its refusals have passed** — the cast
/// sheet a nameless edition stands behind, the notice for pieces this Mac's
/// translator may not write, or the pipeline started (moved off the
/// Department desk in shell p4 Task 7; windowless, tripwire 33).
///
/// Run Whole Book on an edition's To resolve head reaches `startBookRun`; a
/// one-chapter run in a language (plan 4 Task 9) reaches `startRun`.
struct TranslationRunStart: Equatable {
    var notice: String?
    var castPrompt: EditionCastPrompt?

    /// **One round on one chapter.** Asked of the translator's settled
    /// posture first; a language with no honest translator name stands
    /// behind the cast sheet rather than minting a byline nobody chose.
    @MainActor
    static func startRun(
        language: String, docId: String, pipeline: TranslationPipeline,
        documentStore: DocumentStore, store: ProjectStore
    ) async -> TranslationRunStart {
        var castPrompt: EditionCastPrompt?
        var busy: String?
        let notice = await startTranslating(
            [docId], in: documentStore, structure: store.manifest.structure
        ) { _ in
            if needsTranslatorName(language: language, in: store.manifest) {
                castPrompt = EditionCastPrompt(
                    ask: .nameForRun(language: language, docId: docId))
                return
            }
            busy = refusedIfBusy(pipeline.run(docId: docId, language: language), pipeline: pipeline)
        }
        return TranslationRunStart(notice: busy ?? notice, castPrompt: castPrompt)
    }

    /// **One round on every chapter of `documentIds`, in order** — the pieces
    /// this Mac's translator may write are run, the others named and left out.
    @MainActor
    static func startBookRun(
        language: String, documentIds: [String], pipeline: TranslationPipeline,
        documentStore: DocumentStore, store: ProjectStore
    ) async -> TranslationRunStart {
        var castPrompt: EditionCastPrompt?
        var busy: String?
        let notice = await startTranslating(
            documentIds, in: documentStore, structure: store.manifest.structure
        ) { documents in
            if needsTranslatorName(language: language, in: store.manifest) {
                castPrompt = EditionCastPrompt(
                    ask: bookAsk(language: language, documentIds: documents))
                return
            }
            busy = refusedIfBusy(pipeline.runBook(documentIds: documents, language: language),
                                 pipeline: pipeline)
        }
        return TranslationRunStart(notice: busy ?? notice, castPrompt: castPrompt)
    }

    /// **A second start is refused aloud** (shell p4 Task 8, review M12): the
    /// project's windows share one pipeline (`ProjectSession`'s roster), and a
    /// press in one window can land while another window's round — begun
    /// after this window last looked — is under way. The pipeline refuses;
    /// this says which round holds it, where the press used to do nothing.
    @MainActor
    static func refusedIfBusy(_ started: Bool, pipeline: TranslationPipeline) -> String? {
        started ? nil : TranslationRunState.busyReason(language: pipeline.status.language)
    }

    /// The sheet a whole-book run stands behind, with the queue it was
    /// pressed over.
    static func bookAsk(language: String,
                        documentIds: [String]) -> EditionCastPrompt.Ask {
        .nameForBookRun(language: language, documentIds: documentIds)
    }

    // MARK: - The translator's posture (P3c Task 8)

    /// **What this Mac's TRANSLATOR may write about a piece** — the drawing
    /// door, asked as the actor that signs a translation's lines, never as the
    /// writer's own hand.
    @MainActor
    static func postureOfTheTranslator(
        forPiece docId: String, in documentStore: DocumentStore
    ) -> Posture {
        documentStore.posture(forDocId: docId, as: .translator)
    }

    /// **The acting door** (ruling I): the pieces among `docIds` this Mac's
    /// translator may write, asked of the SETTLED posture before a round
    /// spends a session. `start` gets the allowed pieces, in order, when
    /// there is at least one; the refused ones are named in the returned
    /// notice (nil when none were).
    @MainActor
    static func startTranslating(
        _ docIds: [String], in documentStore: DocumentStore,
        structure: [StructureItem], start: ([String]) -> Void
    ) async -> String? {
        var allowed: [String] = []
        var refused: [String] = []
        for docId in docIds {
            let posture = await documentStore.settledPosture(forDocId: docId, as: .translator)
            if posture.allows(.translate) { allowed.append(docId) } else { refused.append(docId) }
        }
        if !allowed.isEmpty { start(allowed) }
        guard !refused.isEmpty else { return nil }
        return notTranslatable(titles: refused.map {
            TreeWalk.find(id: $0, in: structure)?.title ?? $0
        })
    }

    /// What a Run says about pieces its translator may not write, by title.
    static func notTranslatable(titles: [String]) -> String {
        let quoted = titles.map { "\u{201C}\($0)\u{201D}" }
        let named: String
        switch quoted.count {
        case 0: named = "that piece"
        case 1: named = quoted[0]
        case 2: named = quoted[0] + " and " + quoted[1]
        default: named = quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
        }
        return "Your part in this book doesn\u{2019}t reach \(named), so "
            + (quoted.count > 1 ? "they were" : "it was") + " not translated."
    }

    /// A window whose stores never finished loading, or a probe mount.
    static let noTranslatorWired =
        "This window isn\u{2019}t ready to run a translation yet. Try again in a "
        + "moment, or reopen the project."

    /// **Would this language's translator mint with no name?** `nil` from
    /// `EditionStatus.translatorName` — no stored role and no preset — is
    /// exactly the run that must not reach the orchestrator unannounced. A
    /// pure read: it never mints.
    static func needsTranslatorName(language: String, in manifest: ProjectManifest) -> Bool {
        EditionStatus.translatorName(for: language, in: manifest) == nil
    }
}

/// **Whether Run and Run Whole Book are drawn**, from the TRANSLATOR actor's
/// posture per piece — the key that signs a translation's lines, never the
/// writer's hand. A translation's permission is the piece's, not the
/// language's, so one answer holds for every language.
///
/// - **Run** (a chapter) is drawn where the chapter in view may be
///   translated; with none in view, where ANY piece may be.
/// - **Run Whole Book** is drawn where any piece may be; the run itself
///   leaves out, and names, the ones that may not. With no piece to judge,
///   the book's own stream answers.
struct TranslationRunOffers: Equatable {
    let run: Bool
    let runBook: Bool

    static let unrestricted = TranslationRunOffers(run: true, runBook: true)

    static func decide(
        target: String?, book: [String], mayTranslate: (String) -> Bool
    ) -> TranslationRunOffers {
        let any = book.isEmpty
            ? mayTranslate(DocumentClass.projectStreamDocId)
            : book.contains(where: mayTranslate)
        return TranslationRunOffers(
            run: target.map(mayTranslate) ?? any,
            runBook: any)
    }
}
