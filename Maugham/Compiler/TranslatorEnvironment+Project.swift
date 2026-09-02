import Foundation
import MaughamCore
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit); mirrors `compilerLog`.
private let translatorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Translator")

/// **The translator loop's production wiring: one project window's stores, as
/// the closures the run executes on.**
///
/// `CompilerEnvironment+Project.swift`'s peer in every respect that matters —
/// separate from `TranslatorOrchestrator.swift` so that file names no store,
/// and **every capture weak**, because SwiftUI never dismantles a closed
/// window's view graph and an orchestrator that outlived one teardown path
/// while holding a `ProjectStore` strongly would keep the whole project in
/// memory with nothing on screen. `detach()` is still what stops the *session*,
/// which no capture policy can do.
///
/// What is different is what the closures DO. The compiler reads and reports;
/// this loop writes, and it writes through the writer's own doors:
///
/// - **the words** go through `TranslationWritePipeline`, the one place a batch
///   of translations is validated, built and appended — the same door
///   `write_translation` uses, so the two cannot drift about which batches are
///   legal or which source hash is trustworthy;
/// - **the questions** go through `Document.addAnnotation`, so a translator's
///   query is a note the writer disposes of in the queue exactly like any
///   other, signed with the translator's own name;
/// - **the translator** is `ProjectStore.translatorRole(for:)`, find-or-create.
///   This is that verb's first production caller, and a run is the write act
///   that makes the mint legitimate (`ProjectStore+ProductionRoles`'s rule).
extension TranslatorOrchestrator.Environment {

    /// Why a closure could not do its job at all. Distinct from a *refusal*
    /// (`briefRound` answering nil, an ingest rejection) — those are
    /// answers; this is the window having gone away underneath the run.
    enum WiringFailure: Error, LocalizedError {
        case windowClosed

        var errorDescription: String? {
            "the project window closed before this run could resolve its translator"
        }
    }

    /// - Parameters:
    ///   - bible: the per-device ledger of facts the manuscript has
    ///     established, sliced per round against this round's own prose. The
    ///     compiler's `bibleSlice` closure takes the same store for the same
    ///     reason; what a translator does with a fact is different (a gender
    ///     the source never had to state is a grammatical choice in most of
    ///     the languages this loop serves), which is the briefing's business,
    ///     not this parameter's.
    ///   - preferences: read at every spawn, never captured as a value, so a
    ///     session already warm when the writer turns Claude off does not
    ///     answer one more round. `nil` means refuse — the safe direction.
    ///   - onRunEnded: where a finished run is recorded. P4's desk is the
    ///     stated destination; until it exists `ProjectWindow` logs.
    ///   - onRunAbandoned: a click that turned out not to be a run — the
    ///     briefing answered nil — named by the run id the verb returned.
    ///     Defaulted, because most callers have nothing to do with it; a
    ///     caller SEQUENCING on the run (`TranslationPipeline`) supplies one,
    ///     or it waits forever on a run that never started.
    @MainActor
    static func production(
        store: ProjectStore,
        documentStore: DocumentStore,
        projectURL: URL,
        bible: BibleStore,
        preferences: UserPreferences,
        model: String = CompilerOrchestrator.defaultModel,
        onRunEnded: @escaping @MainActor (TranslatorOrchestrator.RunSummary) -> Void,
        onRunAbandoned: @escaping @MainActor (String) -> Void = { _ in }
    ) -> TranslatorOrchestrator.Environment {
        TranslatorOrchestrator.Environment(
            projectId: ProjectIdentifier.id(for: projectURL),
            // The compiler's setting, so a writer who chose a deeper model for
            // their checks gets it for their translations too. Kept current
            // afterwards by `TranslatorOrchestrator.updateModel(_:)`, which the
            // gear menu calls beside the compiler's rather than re-running this.
            model: model,
            briefRound: { [weak store, weak documentStore, weak bible] docId, language in
                guard let store else { return nil }
                return briefing(
                    docId: docId, language: language, store: store,
                    documentStore: documentStore, bible: bible,
                    projectURL: projectURL)
            },
            briefFix: { [weak store, weak documentStore, weak bible] docId, language, notes, isFinalLeg in
                guard let store else { return nil }
                return fixBriefing(
                    docId: docId, language: language, notes: notes, isFinalLeg: isFinalLeg,
                    store: store, documentStore: documentStore, bible: bible,
                    projectURL: projectURL)
            },
            translatorIdentity: { [weak store] language in
                guard let store else { throw WiringFailure.windowClosed }
                // **Find-or-create, and the run is what earns the mint.** The
                // briefing below reads the same stored row back rather than
                // resolving a name of its own — `TranslatorOrchestrator.begin`
                // asks for the identity first precisely so it can.
                let role = try await store.translatorRole(for: language)
                return (role.effectiveName, role.id)
            },
            writeMCPConfig: {
                try ClaudeCLISession.writeMCPConfig(
                    bridgeBinary: ClaudeCLISession.bridgeBinary,
                    socketPath: BuildVariant.current.mcpSocketPath,
                    to: ClaudeCLISession.sessionConfigDirectory)
            },
            makeRunner: { configURL, model in
                ClaudeCLISession(
                    model: model,
                    confinement: .bridged(mcpConfigPath: configURL),
                    cliOverride: nil,
                    isEnabled: { [weak preferences] in preferences?.mcpEnabled ?? false },
                    runTimeout: ClaudeCLISession.translationRunTimeout)
            },
            ingest: { [weak store, weak documentStore] report, context in
                guard let store else {
                    return .init(rejection: WiringFailure.windowClosed.localizedDescription)
                }
                return await ingest(
                    report, context: context, store: store,
                    documentStore: documentStore, projectURL: projectURL)
            },
            onRunEnded: onRunEnded,
            onRunAbandoned: onRunAbandoned)
    }

    // MARK: - The briefing

    /// What both gathers resolve before they differ: the current paragraphs,
    /// the translator's stored row, the two statements, the directives, and
    /// the merged records with their derivation. `nil` is "not a run" for
    /// `briefing`'s two reasons.
    ///
    /// **One resolution, two gathers.** A translate leg and a fix leg differ
    /// only in which paragraphs they ask for and what they say about them —
    /// everything above is the same round, and a second copy of it is a second
    /// answer to which document, which records and whose doctrine a leg is
    /// about, free to drift from the first by a whole typing burst.
    private struct RoundContext {
        let state: (sequence: [String], paragraphs: [String: String], projectURL: URL)
        let role: ProductionRole?
        let intentText: String?
        let briefText: String?
        let directives: [String: [Directive]]
        let latest: [String: TranslationRecord]
        let derived: TranslatedDocument
    }

    @MainActor
    private static func roundContext(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, projectURL: URL
    ) -> RoundContext? {
        // The pipeline's own gate, called here so a malformed tag costs a
        // refused click rather than a whole session — the ingest would catch it
        // at the end of the round otherwise.
        guard (try? TranslationWritePipeline.validate(language: language)) != nil else {
            translatorLog.error(
                "a translation run was asked for an unusable language tag: \(language, privacy: .public)")
            return nil
        }
        guard let state = try? currentParagraphState(
            documentId: docId, store: store,
            documentStore: documentStore, projectURL: projectURL)
        else {
            translatorLog.error(
                "a translation run found no current paragraphs for doc \(docId, privacy: .public)")
            return nil
        }
        let intentText = craftIntentText(docId: docId, store: store)
        let briefText = editionBriefText(language: language, store: store)
        let records = TranslationStore.loadMerged(
            forDocId: docId, language: language, in: projectURL)
        return RoundContext(
            state: state,
            // **The stored row, not a second resolution.** `translatorIdentity`
            // has already run by the time this is called
            // (`TranslatorOrchestrator.begin` pins the order), so the mint has
            // landed and a plain lookup agrees with the identity by
            // construction — where a second call to the find-or-create verb
            // would be a second chance to mint.
            role: store.manifest.storedTranslator(for: language),
            intentText: intentText, briefText: briefText,
            directives: Directives.byParagraph(
                Directives.gather(craftIntent: intentText, editionBrief: briefText)),
            latest: TranslationStore.latestByParagraph(records),
            derived: TranslationDeriver.derive(
                records: records, sequence: state.sequence,
                paragraphs: state.paragraphs, language: language))
    }

    /// Everything one round needs, gathered from the project.
    ///
    /// **`nil` is "not a run"** — the orchestrator's own escape hatch, used
    /// here for the two things that are not worth a session to discover: a
    /// language tag the readers could not parse (Task 4 left this validation to
    /// its one caller rather than take a dependency on the write pipeline), and
    /// a document whose current paragraphs cannot be resolved at all.
    ///
    /// An empty work-list is NOT nil: nothing stale and nothing missing is a
    /// real answer, and the orchestrator reports it as `nothingToTranslate`.
    @MainActor
    private static func briefing(
        docId: String, language: String, store: ProjectStore,
        documentStore: DocumentStore?, bible: BibleStore?, projectURL: URL
    ) -> TranslatorOrchestrator.BriefedRound? {
        guard let context = roundContext(
            docId: docId, language: language, store: store,
            documentStore: documentStore, projectURL: projectURL) else { return nil }
        let state = context.state
        let role = context.role
        let intentText = context.intentText
        let briefText = context.briefText
        let directives = context.directives
        let latest = context.latest
        let derived = context.derived

        // **The delta is `stale ∪ missing ∪ directed`** (spec §2). Stale and
        // missing are the deriver's; directed is a FRESH paragraph the writer
        // has ruled on since it was translated — two dates, nothing stored,
        // which is how "Keep mine" on a round report reaches the next Run.
        let work = derived.entries.filter { entry in
            entry.status != .fresh || Directives.isDirected(
                translatedAt: latest[entry.paragraphId]?.at,
                directives: directives[entry.paragraphId] ?? [])
        }
        let workList = work.map { entry in
            TranslatorBriefing.Inputs.WorkItem(
                paragraphId: entry.paragraphId,
                // `read_translation`'s own strip: an inline `<!--t-XXXX-->` task
                // marker must never reach the model, which would echo it back
                // inside a translated paragraph.
                sourceText: MarkdownDisplayFilter.stripTaskAnchorsInline(entry.sourceText),
                status: entry.status,
                // A stale item's last answer is worth reconsidering; a DIRECTED
                // item's current answer is what the directive is a standard
                // for. Missing has nothing to hand over.
                priorTranslation: entry.status == .missing ? nil : entry.translatedText,
                directives: (directives[entry.paragraphId] ?? []).map(\.text))
        }

        let (open, answered) = languageQueries(
            docId: docId, language: language, documentStore: documentStore)

        let inputs = TranslatorBriefing.Inputs(
            translatorName: role?.effectiveName
                ?? ProductionRole.defaultTranslatorName(language: language)
                ?? language,
            language: language,
            roleBrief: role?.effectiveBrief,
            craftIntentText: intentText,
            editionBriefText: briefText,
            workList: workList,
            contextParagraphs: neighbours(of: work.map(\.paragraphId), in: state),
            openQueries: open,
            answeredQueries: answered,
            // **The same ledger the compiler slices, sliced the same way** —
            // `BibleStore.slice(matching:)` owns the rule; what is decided
            // here is only which prose this run is about, which for a
            // translator is the work-list rather than a delta. An absent
            // store (a window torn down mid-gather) is an empty slice, not a
            // refused round: a briefing without facts is smaller, not wrong.
            bibleFacts: bible?.slice(matching: workList.map(\.sourceText)
                .joined(separator: "\n")) ?? [],
            glossary: GlossaryTable.gather(editionBrief: briefText))

        // **What each work paragraph looked like at send time**, hashed off
        // the RAW text rather than the stripped `sourceText` the model is
        // shown — the pipeline stamps a record's `sourceHash` from the raw
        // string, so a guard comparing anything else would compare two
        // normalizations and fire on nothing. Read here because this is the
        // one place the round is gathered; carried to ingest, which is the one
        // place it can be spent (`midRunEdits`).
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the deriver
        // walks the sequence and cannot repeat an id today, and a trap is the
        // wrong way to find out if that ever stops being true.
        let hashes = Dictionary(
            work.map { entry in
                (entry.paragraphId,
                 TranslationHash.hash(state.paragraphs[entry.paragraphId] ?? ""))
            },
            uniquingKeysWith: { first, _ in first })

        return TranslatorOrchestrator.BriefedRound(inputs: inputs, sourceHashes: hashes)
    }

    /// **The fix leg's briefing** (spec §2, `.fix`): the work-list is exactly
    /// the noted paragraphs — those that still carry a FRESH translation —
    /// each `.fresh` with its current translation as `priorTranslation`, in
    /// sequence order; the mode's notes are the ones whose paragraph made an
    /// item. A note on a paragraph that is missing, stale (the writer edited
    /// the English mid-pipeline) or gone is dropped here rather than briefed
    /// blind — the parser would otherwise fail the whole leg for an id the
    /// model was never shown a paragraph for, with no clue why.
    ///
    /// An EMPTY work-list is not nil, on `briefing`'s own rule: no noted
    /// paragraph having a translation any more is a real answer, which the
    /// orchestrator reports as `nothingToTranslate` and the pipeline records
    /// as a skip. `nil` stays reserved for the two things that are not a run
    /// at all.
    @MainActor
    static func fixBriefing(
        docId: String, language: String, notes: [TranslatorBriefing.FixNote],
        isFinalLeg: Bool, store: ProjectStore, documentStore: DocumentStore?,
        bible: BibleStore?, projectURL: URL
    ) -> TranslatorOrchestrator.BriefedRound? {
        guard let context = roundContext(
            docId: docId, language: language, store: store,
            documentStore: documentStore, projectURL: projectURL) else { return nil }

        // Walked in the deriver's order rather than the notes' — the notes
        // arrive from a reader's report in whatever order it wrote them, and a
        // work-list out of sequence reads as a jumble to the model being asked
        // to keep one voice across it. `translatedText != nil` as well as
        // `.fresh` because a BLANK source paragraph derives fresh with nothing
        // translated (`TranslationDeriver`'s own rule), and there is nothing to
        // repair there.
        let noted = Set(notes.map(\.paragraphId))
        let work = context.derived.entries.filter {
            noted.contains($0.paragraphId) && $0.status == .fresh && $0.translatedText != nil
        }
        let briefable = Set(work.map(\.paragraphId))
        let briefedNotes = notes.filter { briefable.contains($0.paragraphId) }

        let workList = work.map { entry in
            TranslatorBriefing.Inputs.WorkItem(
                paragraphId: entry.paragraphId,
                // `briefing`'s own strip, for its own reason: an inline
                // `<!--t-XXXX-->` task marker must never reach the model.
                sourceText: MarkdownDisplayFilter.stripTaskAnchorsInline(entry.sourceText),
                // Every fix item is fresh by construction — the filter above
                // admits nothing else — and its current translation is what the
                // note is a complaint about, so it is always handed over.
                status: .fresh,
                priorTranslation: entry.translatedText,
                directives: (context.directives[entry.paragraphId] ?? []).map(\.text))
        }
        let (open, answered) = languageQueries(
            docId: docId, language: language, documentStore: documentStore)

        let inputs = TranslatorBriefing.Inputs(
            translatorName: context.role?.effectiveName
                ?? ProductionRole.defaultTranslatorName(language: language)
                ?? language,
            language: language,
            roleBrief: context.role?.effectiveBrief,
            craftIntentText: context.intentText,
            editionBriefText: context.briefText,
            workList: workList,
            contextParagraphs: neighbours(of: work.map(\.paragraphId), in: context.state),
            openQueries: open,
            answeredQueries: answered,
            bibleFacts: bible?.slice(matching: workList.map(\.sourceText)
                .joined(separator: "\n")) ?? [],
            mode: .fix(notes: briefedNotes, isFinalLeg: isFinalLeg),
            glossary: GlossaryTable.gather(editionBrief: context.briefText))

        // `briefing`'s hashes, on `briefing`'s reasoning: read off the RAW
        // source, keyed on the work-list only, spent by `midRunEdits`.
        let hashes = Dictionary(
            work.map { entry in
                (entry.paragraphId,
                 TranslationHash.hash(context.state.paragraphs[entry.paragraphId] ?? ""))
            },
            uniquingKeysWith: { first, _ in first })
        return TranslatorOrchestrator.BriefedRound(inputs: inputs, sourceHashes: hashes)
    }

    /// The writer's declared intent for this piece, whole — the essay AND its
    /// rulings, on `CompilerEnvironment+Project`'s reasoning: the rulings are
    /// half of what the writer has decided, and a translator briefed on the
    /// essay alone is briefed on the smaller half.
    ///
    /// Absence is valid and mints nothing (M1A's rule). RULING-54: an
    /// unreadable statement reads as absent here, and the Intent pane's editor
    /// owns surfacing the refusal.
    @MainActor
    static func craftIntentText(docId: String, store: ProjectStore) -> String? {
        guard let resolved = store.effectiveIntent(forDocId: docId) else { return nil }
        return try? store.statementText(of: resolved)
    }

    /// This edition's doctrine, verbatim — register, idiom policy, and whatever
    /// rulings a translation session has already settled there.
    /// `read_edition_brief`'s own text, through the same `statementText`, so
    /// what the run is briefed on and what Claude can read on demand cannot
    /// disagree. Project scope only: an edition's register applies to the book.
    @MainActor
    static func editionBriefText(language: String, store: ProjectStore) -> String? {
        guard let statement = store.statement(
            kind: .editionBrief(language), scope: .project) else { return nil }
        return try? store.statementText(of: statement)
    }

    /// The paragraph immediately before and after each work item, for
    /// continuity — never the work itself, and deduped so a paragraph between
    /// two work items is listed once.
    static func neighbours(
        of workIds: [String],
        in state: (sequence: [String], paragraphs: [String: String], projectURL: URL)
    ) -> [TranslatorBriefing.Inputs.ContextParagraph] {
        let work = Set(workIds)
        var seen = work
        var result: [TranslatorBriefing.Inputs.ContextParagraph] = []
        for (index, id) in state.sequence.enumerated() where work.contains(id) {
            for neighbour in [index - 1, index + 1] {
                guard state.sequence.indices.contains(neighbour) else { continue }
                let neighbourId = state.sequence[neighbour]
                guard !seen.contains(neighbourId),
                      let text = state.paragraphs[neighbourId],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                seen.insert(neighbourId)
                result.append(.init(
                    paragraphId: neighbourId,
                    text: MarkdownDisplayFilter.stripTaskAnchorsInline(text)))
            }
        }
        return result
    }

    /// This language's queries, split into the ones still waiting on the writer
    /// and the ones they have answered.
    ///
    /// **Read off the OPEN document only** — deliberately still, now that
    /// `mint` reaches a closed one. The two are not the same trade: a mint
    /// that cannot land loses the writer a question outright, while a gather
    /// that skips a closed document's history costs a round some context it
    /// can be re-briefed with next time. A transient load here would be one
    /// per gather, on every leg of a book queue, for a briefing section the
    /// cap already trims — the cost is paid where something is lost, not
    /// everywhere symmetry would put it.
    ///
    /// **Craft notes as well as queries**, because a doc-scoped translation
    /// question mints as a `.craftNote` — `addAnnotation` refuses an
    /// anchorless `.query` — and "tú or usted throughout?" is the question a
    /// translator is most likely to ask and least able to guess at. Gathered
    /// only when the note carries THIS language's tag, which
    /// `AnnotationDeriver` now projects for both kinds off the same `toolArgs`
    /// the mint writes; an untagged craft note is somebody else's note and
    /// filters out on `language` alone. `translation_status`'s
    /// `open_queries` widened the same one way, so the count the writer reads
    /// and the history the round carries cannot disagree.
    @MainActor
    static func languageQueries(
        docId: String, language: String, documentStore: DocumentStore?
    ) -> ([TranslatorBriefing.Inputs.OpenQuery], [TranslatorBriefing.Inputs.AnsweredQuery]) {
        guard let document = documentStore?.document(forDocId: docId) else { return ([], []) }
        // Unfiltered by status, then split: half of what this is for is the
        // notes the writer has SETTLED, every one of which is invisible to
        // `AnnotationFilter`'s `[.open]` default (M5-AN-002's footgun).
        let queries = document
            .annotations(filter: AnnotationFilter(kinds: [.query, .craftNote],
                                                  statuses: nil))
            .filter { $0.language == language }
        let open = queries
            .filter { $0.status == .open }
            .map { TranslatorBriefing.Inputs.OpenQuery(
                paragraphId: $0.paragraphId, text: $0.body) }
        // Most recently settled first, so the briefing's own cap spends its
        // words on the answers the writer gave last (`CompilerAnnotation
        // Disposition.gather`'s rule). An answered query with no written
        // answer teaches the translator nothing and is left out.
        let answered = queries
            .filter { $0.status != .open }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
            .compactMap { annotation -> TranslatorBriefing.Inputs.AnsweredQuery? in
                guard let answer = annotation.userResponse,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return .init(paragraphId: annotation.paragraphId,
                             text: annotation.body, answer: answer)
            }
        return (open, answered)
    }

    // MARK: - Ingest

    /// **Where a round's words and questions actually land**, and the only
    /// writing this loop does.
    ///
    /// The order is deliberate: the freshness check and the words first, and a
    /// batch either of them refuses ends the ingest there — nothing written,
    /// and **nothing asked either**. Minting the questions of a round the
    /// writer will simply run again would double-ask every one of them, since
    /// a translator query has no fingerprint to dedupe on the way the
    /// compiler's notes do.
    @MainActor
    private static func ingest(
        _ report: TranslatorReport,
        context: TranslatorOrchestrator.IngestContext,
        store: ProjectStore, documentStore: DocumentStore?, projectURL: URL
    ) async -> TranslatorOrchestrator.IngestOutcome {
        let state: (sequence: [String], paragraphs: [String: String], projectURL: URL)
        do {
            state = try currentParagraphState(
                documentId: context.docId, store: store,
                documentStore: documentStore, projectURL: projectURL)
        } catch {
            return .init(rejection: sentence(for: error))
        }

        // **The mid-run edit, refused before anything is written.** The
        // pipeline's own re-validation catches a paragraph that VANISHED; a
        // paragraph the writer rewrote while the session was thinking passes
        // every one of its checks and is the more dangerous case, because the
        // record it would append carries the hash of the CURRENT source
        // against a translation of text the model was never shown — an entry
        // that reads fresh forever and is silently wrong. Compared before the
        // pipeline call, so a rejection also mints no queries: `mint` is
        // reached only by falling past this and the write.
        if let edited = midRunEdits(in: report, context: context, state: state) {
            return .init(rejection: edited)
        }

        var warnings: [String] = []
        var written = 0
        var rewrites: [TranslatorOrchestrator.ParagraphRewrite] = []
        if !report.entries.isEmpty {
            // **Read before the write, because after it the old record is no
            // longer the latest.** A fix leg's whole point is what it CHANGED,
            // and the pipeline appends rather than replaces, so the only moment
            // the standing record is visible as "the one that stood" is this
            // one. Read for a translate leg too: the shape is the same and a
            // paragraph translated for the first time simply has nil on the
            // before side, which is the honest answer rather than an omission.
            let before = TranslationStore.latestByParagraph(
                TranslationStore.loadMerged(
                    forDocId: context.docId, language: context.language, in: projectURL))
            do {
                // **The one shared write pipeline**, which re-validates every
                // `¶id` against the state resolved a line ago rather than
                // against the sequence the round was briefed on. A paragraph
                // the writer deleted mid-round therefore rejects the whole
                // batch, loudly, naming the ids — the honest all-or-nothing
                // answer, and the words are still there to be re-run.
                warnings = try TranslationWritePipeline.perform(
                    entries: report.entries.map {
                        TranslationWritePipeline.Entry(
                            paragraphId: $0.paragraphId, text: $0.text,
                            verbatim: $0.verbatim, delete: nil)
                    },
                    language: context.language,
                    documentId: context.docId,
                    state: state,
                    deviceSlug: DeviceSlug.make(from: MacDeviceID.current))
                written = report.entries.count
            } catch {
                return .init(rejection: sentence(for: error))
            }
            let after = TranslationStore.latestByParagraph(
                TranslationStore.loadMerged(
                    forDocId: context.docId, language: context.language, in: projectURL))
            rewrites = report.entries.map { entry in
                TranslatorOrchestrator.ParagraphRewrite(
                    paragraphId: entry.paragraphId,
                    beforeRecordId: before[entry.paragraphId]?.opId,
                    before: before[entry.paragraphId]?.text,
                    afterRecordId: after[entry.paragraphId]?.opId,
                    after: after[entry.paragraphId]?.text)
            }
            // `write_translation`'s step 7, verbatim: a live translation-review
            // posture must re-derive rather than stay frozen until the writer
            // leaves the pane and comes back.
            MaughamEvent.post(
                .maughamTranslationDidUpdate,
                to: .project(for: projectURL),
                payload: [
                    "document_id": context.docId,
                    "language": context.language
                ])
        }

        let minted = await mint(
            report.queries, context: context, store: store, projectURL: projectURL)
        // **The report's own answers travel whole**, unparsed and unedited: the
        // pipeline routes `addressed`/`declined` back to the notes they name and
        // files the summary and the glossary proposals, and a second reading of
        // the report here would be a second answer to what the translator said.
        return .init(
            entriesWritten: written, queriesMinted: minted, warnings: warnings,
            addressed: report.addressed, declined: report.declined,
            summary: report.summary, glossaryProposals: report.glossaryProposals,
            rewrites: rewrites)
    }

    /// The paragraphs whose source changed between the send and the answer,
    /// as the sentence the writer reads — or `nil` when the round's words are
    /// still about the text the model saw.
    ///
    /// **Compared against the hash the round was BRIEFED with**, which is the
    /// only thing that can tell an edit from a coincidence: the state resolved
    /// a line above is the current text, and hashing it twice would agree with
    /// itself no matter what the writer typed. An entry naming a paragraph the
    /// round never briefed as work is not this guard's business — it is either
    /// a context paragraph the contract told the model to leave out or an id
    /// the document does not have, and the pipeline's own rules answer both.
    ///
    /// The answer is a refusal rather than a repair: the honest thing to do
    /// with a translation of a sentence the writer has since rewritten is to
    /// throw it away and run the round again, which is the same answer the
    /// deleted-paragraph case gets.
    @MainActor
    private static func midRunEdits(
        in report: TranslatorReport,
        context: TranslatorOrchestrator.IngestContext,
        state: (sequence: [String], paragraphs: [String: String], projectURL: URL)
    ) -> String? {
        let edited = report.entries
            .compactMap { entry -> String? in
                guard let briefed = context.briefedSourceHashes[entry.paragraphId]
                else { return nil }
                let current = TranslationHash.hash(state.paragraphs[entry.paragraphId] ?? "")
                return current == briefed ? nil : entry.paragraphId
            }
            .sorted()
        guard !edited.isEmpty else { return nil }
        // The pipeline's own vocabulary for the same shape of refusal — a
        // list of ids and a sentence a person can act on.
        return "paragraphs edited while this round was running: "
            + edited.joined(separator: ", ")
            + " — nothing was written, because the translation would be of text "
            + "you have since changed. Run the translation again to pick up the "
            + "new wording."
    }

    /// The round's questions, as annotations the writer disposes of like any
    /// other note.
    ///
    /// **A query whose paragraph vanished mid-run mints DOC-SCOPED rather than
    /// dropping** — the writer must still see the question, and the paragraph
    /// it was about is gone whichever way this goes. Doc-scoped means a craft
    /// note: `Document.addAnnotation` refuses a `.query` with no anchor
    /// (`paragraphNotFound`), and `CompilerNote`'s anchorless arm made the same
    /// call for the same reason. A whole-document question — one the report
    /// may ask with no `paragraph_id` at all — takes the same route, and is
    /// the ordinary case rather than the sad one.
    ///
    /// **The language reaches the writer twice, on purpose.** It is stamped in
    /// `toolArgs`, where `AnnotationDeriver` projects it for a craft note as
    /// well as a query — that is what lets a later round be briefed on the
    /// question and `translation_status` count it — and it is also spelled in
    /// the body, because a craft note wears no language chip in the queue and
    /// the writer disposing of it has to know which edition asked.
    ///
    /// **The mint never fails the run.** A note that cannot be appended is
    /// logged and the rest are written; a check that finished is not made to
    /// look like one that died.
    ///
    /// **A CLOSED document is no longer a gap** (Plan 3). Resolved through
    /// `withAnnotationDocument` — the one spelling of "loaded → the live
    /// instance, otherwise transient-load, run, close" the annotation tools
    /// use — because the book queue runs a pipeline over every chapter of a
    /// book, and all but the open one are closed. While this read the registry
    /// alone, a question about chapter nine had nowhere to land and was logged
    /// away: acceptable for a single-chapter Run the writer was watching,
    /// wrong for a queue they are not. A load that throws keeps the old
    /// sentence and mints nothing — the words still landed, and re-running the
    /// round asks the questions again.
    @MainActor
    private static func mint(
        _ queries: [TranslatorReport.Query],
        context: TranslatorOrchestrator.IngestContext,
        store: ProjectStore, projectURL: URL
    ) async -> Int {
        guard !queries.isEmpty else { return 0 }
        let author = AnnotationAuthor(
            sourceKind: .claude, displayName: context.translatorName)
        let toolArgs = queryToolArgs(
            language: context.language, roleId: context.translatorRoleId)

        do {
            return try await withAnnotationDocument(
                store: store, projectURL: projectURL, documentId: context.docId
            ) { document in
                var minted = 0
                for query in queries {
                    // Anchored to the LIVE paragraph, never to an id the round
                    // was briefed with and the document has since lost.
                    let anchor = query.paragraphId.flatMap {
                        document.sequence.contains($0) ? $0 : nil
                    }
                    do {
                        _ = try await document.addAnnotation(
                            kind: anchor == nil ? .craftNote : .query,
                            paragraphId: anchor,
                            body: anchor == nil
                                ? "Translation query (\(context.language)) — \(query.text)"
                                : query.text,
                            // The language tag `translation_status` counts an
                            // open query by, plus the role that signs it —
                            // `add_query`'s own encoding, which the deriver
                            // reads `language` back out of and ignores the rest
                            // of.
                            toolArgs: toolArgs,
                            // **The exact label IS the filter bucket**
                            // (`AnnotationAuthorFilter.distinctLabels`), which
                            // is the feature: this edition's questions gather
                            // under its translator's name. `.claude` keeps
                            // `isClaude` true, so every existing Claude
                            // affordance still applies.
                            author: author,
                            // One round is ONE event to every surface counting
                            // this project's notes, and each walks the whole
                            // project to answer it. Paid back once below.
                            announcing: false)
                        minted += 1
                    } catch {
                        translatorLog.error(
                            "a translator query could not be minted on doc \(context.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                if minted > 0 { document.announceAnnotationsChanged() }
                return minted
            }
        } catch {
            translatorLog.error(
                "\(queries.count, privacy: .public) translator quer(ies) had nowhere to land: doc \(context.docId, privacy: .public) could not be resolved: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// `add_query`'s `toolArgs` shape, which is where a query's language tag
    /// lives on the wire (`AnnotationDeriver.languageFromToolArgs`). The role id
    /// rides along as provenance: the byline is a display name and two
    /// translators can be renamed into one, while the id is what the manifest
    /// row is keyed by.
    static func queryToolArgs(language: String, roleId: String) -> String? {
        struct Args: Encodable {
            let language: String
            let role_id: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(Args(language: language, role_id: roleId)))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The sentence the writer reads when a batch is refused. `MCPError.message`
    /// is the pipeline's own wording — the unknown-`¶id` listing among it — and
    /// is written to be read by a person, so it travels unchanged.
    private static func sentence(for error: Error) -> String {
        (error as? MCPError)?.message ?? error.localizedDescription
    }
}
