import Foundation
import MaughamCore
import os

private let pipelineEnvLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "TranslationPipeline")

/// **The pipeline's production wiring** — `TranslatorEnvironment+Project
/// .swift`'s peer: one window's stores and the two session owners it
/// sequences, as closures, every capture weak. The translator legs go to the
/// window's `TranslatorOrchestrator`; the cold legs to its `ColdCall`; the
/// reader and collator are `ProjectStore.readerRole/collatorRole(for:)`,
/// find-or-create, which a run is the write act that earns; declined notes
/// mint through `withAnnotationDocument` so a closed chapter in a book queue
/// still gets its queries; rounds go to `TranslationRoundStore`.
extension TranslationPipeline.Environment {

    @MainActor
    static func production(
        store: ProjectStore, documentStore: DocumentStore, projectURL: URL,
        translator: TranslatorOrchestrator, coldCall: ColdCall,
        model: String = CompilerOrchestrator.defaultModel,
        onRoundEnded: @escaping @MainActor (TranslationRound) -> Void
    ) -> TranslationPipeline.Environment {
        TranslationPipeline.Environment(
            model: model,
            runTranslation: { [weak translator] docId, language in
                translator?.runTranslation(docId: docId, language: language)
            },
            runFix: { [weak translator] docId, language, notes, isFinalLeg in
                translator?.runFix(docId: docId, language: language, notes: notes,
                                   isFinalLeg: isFinalLeg)
            },
            cancelTranslator: { [weak translator] in translator?.cancel() },
            translatorName: { [weak store] language in
                guard let store else { return language }
                return EditionStatus.translatorName(for: language, in: store.manifest) ?? language
            },
            readerIdentity: { [weak store] language in
                guard let store else { throw TranslatorOrchestrator.Environment.WiringFailure.windowClosed }
                let role = try await store.readerRole(for: language)
                return (role.effectiveName, role.id)
            },
            collatorIdentity: { [weak store] language in
                guard let store else { throw TranslatorOrchestrator.Environment.WiringFailure.windowClosed }
                let role = try await store.collatorRole(for: language)
                return (role.effectiveName, role.id)
            },
            briefReader: { [weak store, weak documentStore] docId, language in
                guard let store else { return nil }
                return readerBriefing(docId: docId, language: language, store: store,
                                      documentStore: documentStore, projectURL: projectURL)
            },
            briefCollator: { [weak store, weak documentStore] docId, language in
                guard let store else { return nil }
                return collatorBriefing(docId: docId, language: language, store: store,
                                        documentStore: documentStore, projectURL: projectURL)
            },
            coldCall: { [weak coldCall] message, preamble, model in
                guard let coldCall else {
                    return .failed(.sessionDied(detail: ColdCall.notWiredDetail))
                }
                return await coldCall.call(message: message, preamble: preamble, model: model)
            },
            cancelColdCall: { [weak coldCall] in coldCall?.cancel() },
            mintDeclinedQueries: { [weak store] mint in
                guard let store else { return [:] }
                return await mintDeclined(mint, store: store, projectURL: projectURL)
            },
            nextRoundNumber: { TranslationRoundStore(projectURL: projectURL).nextNumber(language: $0) },
            saveRound: { round in
                do { try TranslationRoundStore(projectURL: projectURL).append(round) } catch {
                    pipelineEnvLog.error("round \(round.number, privacy: .public) for \(round.language, privacy: .public) could not be saved: \(error, privacy: .public)")
                }
            },
            onRoundEnded: onRoundEnded)
    }

    // MARK: - Gathers

    /// The reader's inputs: every paragraph in sequence order, a translation
    /// only where the derivation says FRESH — stale and missing are gaps, and
    /// a stale translation is not the edition either (spec §2). Text is
    /// passed through `stripTaskAnchorsInline`, the translator gather's own
    /// rule. The name is read without minting (`EditionStatus.readerName`,
    /// the one spelling of stored-then-preset); the identity closure has
    /// already stored the row by the time this runs.
    @MainActor
    static func readerBriefing(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, projectURL: URL
    ) -> ReaderBriefing.Inputs? {
        guard let state = try? currentParagraphState(
            documentId: docId, store: store, documentStore: documentStore, projectURL: projectURL)
        else { return nil }
        let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
        let derived = TranslationDeriver.derive(
            records: records, sequence: state.sequence, paragraphs: state.paragraphs, language: language)
        let role = store.manifest.storedReader(for: language)
        return ReaderBriefing.Inputs(
            readerName: EditionStatus.readerName(for: language, in: store.manifest) ?? language,
            language: language,
            authorLanguage: authorLanguage(store: store, documentStore: documentStore,
                                           projectURL: projectURL),
            roleBrief: role?.effectiveBrief,
            editionBriefText: TranslatorOrchestrator.Environment.editionBriefText(
                language: language, store: store),
            paragraphs: derived.entries.map { entry in
                .init(paragraphId: entry.paragraphId,
                      translation: entry.status == .fresh
                          ? entry.translatedText.map(MarkdownDisplayFilter.stripTaskAnchorsInline)
                          : nil)
            })
    }

    /// The collator's inputs: the same derivation read as PAIRS — the source
    /// beside what the edition says there — plus the writer's own standards
    /// (craft intent, the edition brief, that paragraph's directives, the
    /// glossary). Freshness governs the translation half exactly as it does
    /// the reader's: a stale rendering is not what this edition says.
    @MainActor
    static func collatorBriefing(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, projectURL: URL
    ) -> CollatorBriefing.Inputs? {
        guard let state = try? currentParagraphState(
            documentId: docId, store: store, documentStore: documentStore, projectURL: projectURL)
        else { return nil }
        let records = TranslationStore.loadMerged(forDocId: docId, language: language, in: projectURL)
        let derived = TranslationDeriver.derive(
            records: records, sequence: state.sequence, paragraphs: state.paragraphs, language: language)
        let role = store.manifest.storedCollator(for: language)
        let intentText = TranslatorOrchestrator.Environment.craftIntentText(docId: docId, store: store)
        let briefText = TranslatorOrchestrator.Environment.editionBriefText(
            language: language, store: store)
        let directives = Directives.byParagraph(
            Directives.gather(craftIntent: intentText, editionBrief: briefText))
        return CollatorBriefing.Inputs(
            collatorName: EditionStatus.collatorName(for: language, in: store.manifest) ?? language,
            language: language,
            authorLanguage: authorLanguage(store: store, documentStore: documentStore,
                                           projectURL: projectURL),
            roleBrief: role?.effectiveBrief,
            craftIntentText: intentText,
            editionBriefText: briefText,
            glossary: GlossaryTable.gather(editionBrief: briefText),
            pairs: derived.entries.map { entry in
                .init(paragraphId: entry.paragraphId,
                      sourceText: MarkdownDisplayFilter.stripTaskAnchorsInline(entry.sourceText),
                      translation: entry.status == .fresh
                          ? entry.translatedText.map(MarkdownDisplayFilter.stripTaskAnchorsInline)
                          : nil,
                      directives: (directives[entry.paragraphId] ?? []).map(\.text))
            })
    }

    /// **The author's language is the book's own** — nothing else in the
    /// project names it — resolved through the imprint the desk is standing
    /// on exactly as the compile sheet resolves it
    /// (`DepartmentPaneHost.sourceLanguage`, the one spelling), then named in
    /// English for the briefing's role frame.
    @MainActor
    static func authorLanguage(store: ProjectStore, documentStore: DocumentStore?,
                               projectURL: URL) -> String {
        let config = (try? PublishConfigStore.read(in: projectURL)) ?? nil
        let tag = DepartmentPaneHost.sourceLanguage(
            imprint: documentStore?.uiState.publishImprint, in: config,
            pieceIDs: EditionStatus.manuscriptDocumentIds(in: store.manifest))
        return languageName(tag: tag)
    }

    /// The language's name **in English**, because the role frame it lands in
    /// is written for a reader of the author's own language and a tag is not a
    /// language to a model. An unrecognised tag is its own name.
    static func languageName(tag: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: tag) ?? tag
    }

    // MARK: - The declined mint

    /// The query's body (spec §6): kind and severity on the first line, the
    /// note, then the translator's reason under the translator's name — the
    /// "reply" the annotation layer has no primitive for, carried where the
    /// queue already draws prose. The structured form is the round record's.
    static func declinedBody(note: TranslatorBriefing.FixNote, reason: String,
                             translatorName: String) -> String {
        let head = note.severity.map { "\(note.kind) \u{00b7} \($0)" } ?? note.kind
        return "\(head)\n\(note.text)\n\n\(translatorName) declined: \(reason)"
    }

    /// `TranslatorEnvironment+Project.mint`'s idiom over the note's own
    /// author: anchored to the live paragraph (doc-scoped craft note if it is
    /// gone), `add_query`'s `toolArgs` with the language and the reader's or
    /// collator's role id, announced once. Never fails the round.
    @MainActor
    static func mintDeclined(
        _ mint: TranslationPipeline.DeclinedMint, store: ProjectStore, projectURL: URL
    ) async -> [String: String] {
        guard !mint.items.isEmpty else { return [:] }
        do {
            return try await withAnnotationDocument(
                store: store, projectURL: projectURL, documentId: mint.docId
            ) { document in
                var ids: [String: String] = [:]
                for item in mint.items {
                    let anchor = document.sequence.contains(item.note.paragraphId)
                        ? item.note.paragraphId : nil
                    let body = declinedBody(note: item.note, reason: item.reason,
                                            translatorName: mint.translatorName)
                    do {
                        let id = try await document.addAnnotation(
                            kind: anchor == nil ? .craftNote : .query,
                            paragraphId: anchor,
                            body: anchor == nil
                                ? "Translation query (\(mint.language)) \u{2014} \(body)"
                                : body,
                            toolArgs: TranslatorOrchestrator.Environment.queryToolArgs(
                                language: mint.language, roleId: item.authorRoleId),
                            author: AnnotationAuthor(sourceKind: .claude,
                                                     displayName: item.note.author),
                            announcing: false)
                        ids[item.note.id] = id
                    } catch {
                        pipelineEnvLog.error("a declined note could not be minted on doc \(mint.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if !ids.isEmpty { document.announceAnnotationsChanged() }
                return ids
            }
        } catch {
            pipelineEnvLog.error("\(mint.items.count, privacy: .public) declined note(s) had nowhere to land: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
