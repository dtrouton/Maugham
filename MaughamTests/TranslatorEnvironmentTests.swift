import XCTest
import MaughamCore
@testable import Maugham

/// **The translator's production wiring**: the closures
/// `TranslatorOrchestrator.Environment.production` hands the run, driven
/// against a real project on disk.
///
/// `TranslatorOrchestratorTests` proves the run's control flow with every
/// closure a spy; this file proves the closures themselves — that a report's
/// entries reach the one shared write pipeline, that its questions reach the
/// writer as annotations signed by the translator, and that the identity the
/// briefing names is minted once and found thereafter.
@MainActor
final class TranslatorEnvironmentTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
        let bible: BibleStore
        let environment: TranslatorOrchestrator.Environment
        let summaries: () -> [TranslatorOrchestrator.RunSummary]
    }

    /// One three-paragraph novel chapter, open in a `DocumentStore` — the
    /// shape `TranslationStatusToolTests` uses, for its reason: a real
    /// `Document.load` is what mints the `¶id`s every id in this file names.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslatorEnv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path = "manuscript/c1.md"
        try "The fog came in.\n\nShe closed the door.\n\nNobody spoke."
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "Env", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-1", title: "Chapter 1",
                                      type: .document, path: path)],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        projectStore.documentStore = documentStore

        let doc = try await Document.load(
            url: root.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)

        let suite = "TranslatorEnvTests-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)

        let summaries = Box<[TranslatorOrchestrator.RunSummary]>([])
        let bible = BibleStore(
            projectRoot: root, device: DeviceSlug.make(from: MacDeviceID.current))
        let environment = TranslatorOrchestrator.Environment.production(
            store: projectStore,
            documentStore: documentStore,
            projectURL: root,
            bible: bible,
            preferences: preferences,
            onRunEnded: { summaries.value.append($0) })

        return Harness(
            projectURL: root,
            projectId: ProjectIdentifier.id(for: root),
            projectStore: projectStore,
            documentStore: documentStore,
            doc: doc,
            bible: bible,
            environment: environment,
            summaries: { summaries.value })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// The context the orchestrator hands ingest. `briefedSourceHashes`
    /// defaults to the document's paragraphs as they stand — a round briefed
    /// this instant — so a test that says nothing about mid-run editing gets
    /// the case where nothing was edited, and the test that IS about it
    /// supplies its own.
    private func context(
        _ harness: Harness, language: String = "es",
        name: String = "Elena Ruiz", roleId: String = "role-es",
        briefedSourceHashes: [String: String]? = nil
    ) -> TranslatorOrchestrator.IngestContext {
        TranslatorOrchestrator.IngestContext(
            docId: harness.doc.docId, language: language, runId: "run-1",
            translatorName: name, translatorRoleId: roleId,
            briefedSourceHashes: briefedSourceHashes
                ?? harness.doc.paragraphs.mapValues { TranslationHash.hash($0) })
    }

    private func records(
        _ harness: Harness, language: String = "es"
    ) -> [TranslationRecord] {
        TranslationStore.loadMerged(
            forDocId: harness.doc.docId, language: language, in: harness.projectURL)
    }

    private func queries(_ harness: Harness) -> [Annotation] {
        harness.doc.annotations(filter: AnnotationFilter(statuses: nil))
    }

    private func source(at relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Ingest: the words

    /// The whole write path: a translated paragraph and a verbatim one land as
    /// records through `TranslationWritePipeline`, which is the only thing that
    /// appends a batch (`TripwireGrepTests`' census guards that half).
    func test_ingestWritesEntriesThroughTheSharedPipeline() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        XCTAssertEqual(ids.count, 3)

        let report = TranslatorReport(
            entries: [
                .init(paragraphId: ids[0], text: "Llegó la niebla.", verbatim: nil),
                .init(paragraphId: ids[1], text: nil, verbatim: true),
            ],
            queries: [])

        let outcome = await harness.environment.ingest(report, context(harness))

        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.entriesWritten, 2)

        let latest = TranslationStore.latestByParagraph(records(harness))
        XCTAssertEqual(latest[ids[0]]?.text, "Llegó la niebla.")
        XCTAssertEqual(latest[ids[0]]?.verbatim, false)
        // Verbatim carries the CURRENT source across — the pipeline's rule, not
        // the caller's, which is exactly why the caller passes the flag rather
        // than the text.
        XCTAssertEqual(latest[ids[1]]?.text, harness.doc.paragraphs[ids[1]])
        XCTAssertEqual(latest[ids[1]]?.verbatim, true)

        await harness.documentStore.close()
    }

    /// The re-validation at ingest is the pipeline's, and it is all-or-nothing:
    /// a paragraph deleted between the send and the answer rejects the whole
    /// batch, loudly, naming the id — and the good entry beside it is not
    /// written either.
    func test_anEntryNamingAVanishedParagraphRejectsTheWholeBatch() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        let report = TranslatorReport(
            entries: [
                .init(paragraphId: ids[0], text: "Llegó la niebla.", verbatim: nil),
                .init(paragraphId: "zzzz", text: "Nada.", verbatim: nil),
            ],
            queries: [])

        let outcome = await harness.environment.ingest(report, context(harness))

        let rejection = try XCTUnwrap(outcome.rejection)
        XCTAssertTrue(rejection.contains("zzzz"),
                      "the sentence the writer reads must name the id: \(rejection)")
        XCTAssertEqual(outcome.entriesWritten, 0)
        XCTAssertTrue(records(harness).isEmpty,
                      "a rejected batch writes nothing at all, its good entries included")

        await harness.documentStore.close()
    }

    /// **A mid-run edit rejects loudly rather than minting a fresh
    /// translation of stale text.**
    ///
    /// The dangerous sibling of the vanished-paragraph case above, and the
    /// one every check upstream of this waves through: the id still resolves,
    /// the pipeline's all-or-nothing rule is satisfied, and the record it
    /// would append carries `TranslationHash.hash(CURRENT source)` — so a
    /// translation of the sentence the writer just replaced would be stamped
    /// as the fresh translation of the sentence they replaced it WITH, and no
    /// later coverage derivation would ever call it stale. The round is
    /// refused whole instead, naming the paragraph, and the words are still
    /// there to be re-run.
    func test_aMidRunEditRejectsRatherThanTranslateTextTheWriterHasReplaced() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        // The round is briefed here, against the fog.
        _ = try await harness.environment.translatorIdentity("es")
        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let round = try XCTUnwrap(gathered)
        XCTAssertEqual(round.sourceHashes[ids[0]], TranslationHash.hash("The fog came in."),
                       "the hash is of the RAW source, the string the pipeline stamps from")

        // …and the writer rewrites that paragraph while the session thinks.
        harness.doc.setParagraph(id: ids[0], text: "The rain came in.")

        let outcome = await harness.environment.ingest(
            TranslatorReport(
                entries: [
                    .init(paragraphId: ids[0], text: "Llegó la niebla.", verbatim: nil),
                    .init(paragraphId: ids[1], text: "Cerró la puerta.", verbatim: nil),
                ],
                queries: [.init(paragraphId: ids[1], text: "¿La doctora es mujer?")]),
            context(harness, briefedSourceHashes: round.sourceHashes))

        let rejection = try XCTUnwrap(
            outcome.rejection,
            "a translation of text the writer has since replaced must not be written")
        XCTAssertTrue(rejection.contains(ids[0]),
                      "the sentence names the paragraph that moved: \(rejection)")
        XCTAssertFalse(rejection.contains(ids[1]),
                       "…and only that one: \(rejection)")
        XCTAssertEqual(outcome.entriesWritten, 0)
        XCTAssertTrue(records(harness).isEmpty,
                      "all-or-nothing: the untouched paragraph's translation is not "
                      + "written either")
        XCTAssertEqual(outcome.queriesMinted, 0)
        XCTAssertTrue(queries(harness).isEmpty,
                      "a refused round asks nothing, or the re-run double-asks it")

        await harness.documentStore.close()
    }

    /// The guard is about the paragraphs an entry NAMES, not about the
    /// document as a whole: a writer typing in a paragraph this round never
    /// asked for does not cost them the round.
    func test_anEditElsewhereInTheDocumentDoesNotRefuseTheRound() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        _ = try await harness.environment.translatorIdentity("es")
        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let round = try XCTUnwrap(gathered)

        harness.doc.setParagraph(id: ids[2], text: "Nobody spoke at all.")

        let outcome = await harness.environment.ingest(
            TranslatorReport(
                entries: [.init(paragraphId: ids[0], text: "Llegó la niebla.", verbatim: nil)],
                queries: []),
            context(harness, briefedSourceHashes: round.sourceHashes))

        XCTAssertNil(outcome.rejection, "\(outcome.rejection ?? "")")
        XCTAssertEqual(outcome.entriesWritten, 1)

        await harness.documentStore.close()
    }

    /// Advisory warnings ride the outcome and never block the write — the
    /// pipeline's own equals-source nudge, reaching the desk through
    /// `IngestOutcome.warnings`.
    func test_advisoryWarningsRideTheOutcomeWithoutRefusingTheWords() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        let source = try XCTUnwrap(harness.doc.paragraphs[ids[0]])

        let outcome = await harness.environment.ingest(
            TranslatorReport(
                entries: [.init(paragraphId: ids[0], text: source, verbatim: nil)],
                queries: []),
            context(harness))

        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.entriesWritten, 1)
        XCTAssertTrue(outcome.warnings.contains { $0.contains("verbatim") },
                      "an identical translation earns the advisory: \(outcome.warnings)")
        XCTAssertFalse(records(harness).isEmpty, "…and is still written")

        await harness.documentStore.close()
    }

    /// The same project-scoped post `write_translation` makes, so a live
    /// translation-review posture re-derives rather than staying frozen.
    func test_ingestPostsTheSameEventTheWriteToolPosts() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        var receivedDoc: String?
        var receivedLanguage: String?
        let token = MaughamEvent.observe(
            .maughamTranslationDidUpdate,
            context: {
                EventReceiverContext(kind: .project(id: harness.projectId),
                                     isWindowLive: true, isWindowKey: false)
            },
            handler: {
                receivedDoc = $0.userInfo?["document_id"] as? String
                receivedLanguage = $0.userInfo?["language"] as? String
            })
        defer { NotificationCenter.default.removeObserver(token) }

        _ = await harness.environment.ingest(
            TranslatorReport(
                entries: [.init(paragraphId: ids[0], text: "Llegó la niebla.", verbatim: nil)],
                queries: []),
            context(harness))

        XCTAssertEqual(receivedDoc, harness.doc.docId)
        XCTAssertEqual(receivedLanguage, "es")

        await harness.documentStore.close()
    }

    // MARK: - Ingest: the questions

    /// A query becomes an annotation the writer disposes of like any other —
    /// kind `.query`, the language tag set, signed by the translator, anchored
    /// to the live paragraph.
    func test_aQueryMintsAnAnnotationSignedByTheTranslator() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        let outcome = await harness.environment.ingest(
            TranslatorReport(
                entries: [],
                queries: [.init(paragraphId: ids[1], text: "¿La doctora es mujer?")]),
            context(harness))

        XCTAssertEqual(outcome.queriesMinted, 1)
        let minted = try XCTUnwrap(queries(harness).first)
        XCTAssertEqual(minted.kind, .query)
        XCTAssertEqual(minted.paragraphId, ids[1])
        XCTAssertEqual(minted.body, "¿La doctora es mujer?")
        XCTAssertEqual(minted.language, "es",
                       "the tag is what translation_status counts an open query by")
        XCTAssertEqual(minted.author?.displayName, "Elena Ruiz",
                       "the byline is the translator's name, not \"Claude\"")
        XCTAssertEqual(minted.author?.sourceKind, .claude)

        await harness.documentStore.close()
    }

    /// **A question whose paragraph vanished mid-run is still asked.** It mints
    /// doc-scoped rather than dropping — the writer must see it — and doc-scoped
    /// means a craft note, the only kind `Document.addAnnotation` will anchor to
    /// nothing (`CompilerNote`'s own precedent). The language travels in the
    /// body there, since the projection carries it for `.query` alone.
    func test_aQueryWhoseParagraphVanishedMintsDocScoped() async throws {
        let harness = try await makeHarness()

        let outcome = await harness.environment.ingest(
            TranslatorReport(
                entries: [],
                queries: [.init(paragraphId: "zzzz", text: "¿La doctora es mujer?")]),
            context(harness))

        XCTAssertEqual(outcome.queriesMinted, 1, "the question is not dropped")
        let minted = try XCTUnwrap(queries(harness).first)
        XCTAssertEqual(minted.kind, .craftNote)
        XCTAssertNil(minted.paragraphId)
        XCTAssertTrue(minted.body.contains("¿La doctora es mujer?"))
        XCTAssertTrue(minted.body.contains("es"),
                      "the language has to reach the writer some other way: \(minted.body)")

        await harness.documentStore.close()
    }

    /// A whole-document question — one the report is allowed to ask with no
    /// `paragraph_id` at all — takes the same doc-scoped route.
    func test_aWholeDocumentQuestionMintsDocScoped() async throws {
        let harness = try await makeHarness()

        _ = await harness.environment.ingest(
            TranslatorReport(
                entries: [],
                queries: [.init(paragraphId: nil, text: "¿Tuteo o usted en todo el libro?")]),
            context(harness))

        let minted = try XCTUnwrap(queries(harness).first)
        XCTAssertEqual(minted.kind, .craftNote)
        XCTAssertNil(minted.paragraphId)

        await harness.documentStore.close()
    }

    /// A rejected batch mints no questions either. The round is refused whole
    /// and the writer runs it again; minting here would double-ask every
    /// question on the re-run, since nothing dedupes a translator query.
    func test_aRejectedBatchAsksNothingEither() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        let outcome = await harness.environment.ingest(
            TranslatorReport(
                entries: [.init(paragraphId: "zzzz", text: "Nada.", verbatim: nil)],
                queries: [.init(paragraphId: ids[0], text: "¿La doctora es mujer?")]),
            context(harness))

        XCTAssertNotNil(outcome.rejection)
        XCTAssertEqual(outcome.queriesMinted, 0)
        XCTAssertTrue(queries(harness).isEmpty)

        await harness.documentStore.close()
    }

    // MARK: - Identity

    /// `translatorRole(for:)` is find-or-create, and a run is the write act
    /// that legitimises the mint: the first run puts the row on the manifest,
    /// the second finds the same one.
    func test_theTranslatorIsMintedOnTheFirstRunAndFoundOnTheSecond() async throws {
        let harness = try await makeHarness()

        XCTAssertTrue(harness.projectStore.manifest.productionRoles.isEmpty)

        let first = try await harness.environment.translatorIdentity("es")
        XCTAssertEqual(harness.projectStore.manifest.productionRoles.count, 1)
        XCTAssertFalse(first.name.isEmpty)

        let second = try await harness.environment.translatorIdentity("es")
        XCTAssertEqual(second.roleId, first.roleId,
                       "a second mint would split one person's work in two")
        XCTAssertEqual(harness.projectStore.manifest.productionRoles.count, 1)

        await harness.documentStore.close()
    }

    // MARK: - The briefing

    /// The work-list is the coverage derivation's stale-and-missing set, and
    /// nothing else: a fresh paragraph is not this round's work.
    func test_theBriefingAsksForWhatIsStaleOrMissingOnly() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence

        // ids[0] fresh, ids[1] stale (hashed against text it no longer has).
        try await TranslationStore.append(
            TranslationRecord(
                paragraphId: ids[0], language: "es", text: "Llegó la niebla.",
                sourceHash: TranslationHash.hash(harness.doc.paragraphs[ids[0]] ?? ""),
                verbatim: false),
            forDocId: harness.doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: harness.projectURL)
        try await TranslationStore.append(
            TranslationRecord(
                paragraphId: ids[1], language: "es", text: "Cerró la puerta.",
                sourceHash: TranslationHash.hash("something else entirely"),
                verbatim: false),
            forDocId: harness.doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: harness.projectURL)

        _ = try await harness.environment.translatorIdentity("es")
        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.workList.map(\.paragraphId), [ids[1], ids[2]])
        XCTAssertEqual(inputs.workList.first?.status, .stale)
        XCTAssertEqual(inputs.workList.first?.priorTranslation, "Cerró la puerta.",
                       "a stale item hands over its own last answer to reconsider")
        XCTAssertEqual(inputs.workList.last?.status, .missing)
        XCTAssertNil(inputs.workList.last?.priorTranslation)
        // The fresh paragraph is not work, but it IS the neighbour of one.
        XCTAssertEqual(inputs.contextParagraphs.map(\.paragraphId), [ids[0]])
        XCTAssertEqual(inputs.language, "es")
        XCTAssertFalse(inputs.translatorName.isEmpty)

        await harness.documentStore.close()
    }

    /// **Spec §2's `directed`**: a fresh paragraph carrying a directive ruled
    /// after its record is this round's work; one whose directive is older
    /// than its record is not.
    func test_aDirectiveNewerThanTheRecordMakesAFreshParagraphWork() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        // Every paragraph fresh, translated "two days ago" so the ruling days
        // below fall clearly on either side.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        for id in ids {
            try await TranslationStore.append(
                TranslationRecord(
                    paragraphId: id, language: "es", text: "…",
                    sourceHash: TranslationHash.hash(harness.doc.paragraphs[id] ?? ""),
                    at: twoDaysAgo),
                forDocId: harness.doc.docId,
                deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
                in: harness.projectURL)
        }
        _ = try await harness.environment.translatorIdentity("es")

        // ids[0]: directive ruled TODAY (after the record) → directed.
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: ids[0], "keep it plain"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .intent, forScope: .document(harness.doc.docId),
            store: harness.projectStore, world: nil)
        // ids[1]: a directive dated a week BEFORE the record → not directed.
        let brief = try await harness.projectStore.createStatement(
            kind: .editionBrief("es"), scope: .project)
        try await harness.projectStore.mutateStatementText(
            of: brief, session: "test-\(UUID().uuidString)") { markdown in
            RulingsSection.appending(
                Ruling.directiveText(paragraphId: ids[1], "one sentence"),
                provenance: Ruling.Provenance.translatorsNote,
                on: twoDaysAgo.addingTimeInterval(-7 * 86_400), to: markdown)
        }

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.workList.map(\.paragraphId), [ids[0]])
        XCTAssertEqual(inputs.workList.first?.status, .fresh)
        XCTAssertEqual(inputs.workList.first?.priorTranslation, "…",
                       "a directed item hands over what it currently says")
        XCTAssertEqual(inputs.workList.first?.directives, ["keep it plain"])
        XCTAssertEqual(gathered?.sourceHashes.keys.sorted(), [ids[0]],
                       "the mid-run-edit guard covers the directed item too")

        await harness.documentStore.close()
    }

    /// Directives and the glossary reach the briefing off the writer's own
    /// statements — craft intent's for every edition, the brief's for this one.
    func test_theBriefingCarriesDirectivesFromBothStatementsAndTheGlossary() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        _ = try await harness.environment.translatorIdentity("es")
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: ids[2], "this fragment is deliberate"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .intent, forScope: .document(harness.doc.docId),
            store: harness.projectStore, world: nil)
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: ids[2], "do not elevate this"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .editionBrief("es"), forScope: .project,
            store: harness.projectStore, world: nil)
        try await RulingPerformer.rule(
            Ruling.glossaryText(term: "October", rendering: "Octubre", note: "the month"),
            provenance: Ruling.Provenance.glossary,
            kind: .editionBrief("es"), forScope: .project,
            store: harness.projectStore, world: nil)

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        let last = try XCTUnwrap(inputs.workList.first { $0.paragraphId == ids[2] })
        XCTAssertEqual(last.directives, ["this fragment is deliberate", "do not elevate this"],
                       "craft intent's first, then the brief's")
        XCTAssertEqual(inputs.glossary,
                       [GlossaryEntry(term: "October", rendering: "Octubre", note: "the month")])
        XCTAssertEqual(inputs.mode, .translate)

        await harness.documentStore.close()
    }

    /// The name in the briefing is the one the identity minted — Task 4's
    /// order made load-bearing here: production reads both off the same stored
    /// translator row.
    func test_theBriefingNamesTheTranslatorTheIdentityMinted() async throws {
        let harness = try await makeHarness()

        let identity = try await harness.environment.translatorIdentity("es")
        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.translatorName, identity.name)

        await harness.documentStore.close()
    }

    /// A malformed tag is refused HERE, before a session is spawned — the
    /// orchestrator's `nil briefing == not a run` escape hatch, used for what
    /// Task 4's report says it should be.
    func test_aMalformedLanguageTagIsNotARun() async throws {
        let harness = try await makeHarness()

        let round = await harness.environment.briefRound(harness.doc.docId, "Español!")

        XCTAssertNil(round, "an invalid tag must not cost a whole session to discover")

        await harness.documentStore.close()
    }

    /// The writer's standing doctrine reaches the round: the edition brief for
    /// this language, verbatim, rulings and all.
    func test_theBriefingCarriesTheEditionBrief() async throws {
        let harness = try await makeHarness()
        _ = try await harness.environment.translatorIdentity("es")

        let statement = try await harness.projectStore.createStatement(
            kind: .editionBrief("es"), scope: .project)
        try await harness.projectStore.appendToStatement(
            "Usted, nunca tuteo.", to: statement, session: "test-\(UUID().uuidString)")

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs
        let brief = try XCTUnwrap(inputs.editionBriefText)
        XCTAssertTrue(brief.contains("Usted, nunca tuteo."), brief)

        await harness.documentStore.close()
    }

    /// **The bible reaches the round**, sliced against this round's own work
    /// the way the compiler slices its delta — one rule, on the store, two
    /// callers. A fact about someone this round's paragraphs name travels; a
    /// fact about someone they do not name stays home, or every round would
    /// carry the whole ledger.
    func test_theBriefingCarriesTheFactsAboutThisRoundsPeople() async throws {
        let harness = try await makeHarness()
        _ = try await harness.environment.translatorIdentity("es")

        harness.bible.record([
            BibleFact(id: "f-1", subject: "the fog", fact: "arrives before every death",
                      establishedAt: nil, docId: harness.doc.docId, recordedAt: Date()),
            BibleFact(id: "f-2", subject: "Marta", fact: "is the elder sister",
                      establishedAt: nil, docId: harness.doc.docId, recordedAt: Date()),
        ])

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.bibleFacts.map(\.subject), ["the fog"],
                       "the slice is the work-list's own people: the first paragraph "
                       + "says \"The fog came in.\" and no paragraph says Marta")
        XCTAssertTrue(
            TranslatorBriefing.compose(inputs: inputs)
                .contains("arrives before every death"),
            "…and the fact's own text is what the model reads")

        await harness.documentStore.close()
    }

    /// A project whose compiler has never run has established nothing, and a
    /// round briefed against an empty ledger is smaller rather than refused.
    func test_anEmptyBibleBriefsHonestly() async throws {
        let harness = try await makeHarness()
        _ = try await harness.environment.translatorIdentity("es")

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertTrue(inputs.bibleFacts.isEmpty)
        XCTAssertFalse(
            TranslatorBriefing.compose(inputs: inputs).contains("Established so far"))

        await harness.documentStore.close()
    }

    /// Queries already asked come back to the round so the translator does not
    /// ask them twice — open ones as open, the writer's answers as answers.
    func test_theBriefingCarriesTheLanguagesOwnQueries() async throws {
        let harness = try await makeHarness()
        let ids = harness.doc.sequence
        _ = try await harness.environment.translatorIdentity("es")

        // One open (es), one answered (es), one for another language.
        _ = await harness.environment.ingest(
            TranslatorReport(entries: [], queries: [
                .init(paragraphId: ids[0], text: "¿La doctora es mujer?"),
                .init(paragraphId: ids[1], text: "¿Nombre propio o traducido?"),
            ]),
            context(harness))
        _ = await harness.environment.ingest(
            TranslatorReport(entries: [], queries: [
                .init(paragraphId: ids[0], text: "Frage auf Deutsch?"),
            ]),
            context(harness, language: "de", name: "Kurt Meyer", roleId: "role-de"))

        let answerable = try XCTUnwrap(
            queries(harness).first { $0.body == "¿Nombre propio o traducido?" })
        try await harness.doc.acceptAnnotation(
            id: answerable.id, userResponse: "Traducido.")

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.openQueries.map(\.text), ["¿La doctora es mujer?"],
                       "another language's question is not this round's business")
        XCTAssertEqual(inputs.answeredQueries.map(\.text), ["¿Nombre propio o traducido?"])
        XCTAssertEqual(inputs.answeredQueries.first?.answer, "Traducido.")

        await harness.documentStore.close()
    }

    /// **A whole-document question comes back to the next round.** It minted
    /// as a craft note, because `addAnnotation` refuses an anchorless
    /// `.query`, and while the gather looked at `.query` alone the question
    /// was invisible to every later briefing — so a fresh session asked "tú or
    /// usted?" again, and again, with the writer's answer sitting unread in
    /// the queue. Round-trip through this file's own mint rather than a
    /// hand-built note, so the tag the gather filters on is the tag the mint
    /// actually writes.
    func test_aWholeDocumentQuestionIsRebriefedToTheNextRound() async throws {
        let harness = try await makeHarness()
        _ = try await harness.environment.translatorIdentity("es")

        _ = await harness.environment.ingest(
            TranslatorReport(entries: [], queries: [
                .init(paragraphId: nil, text: "¿Tuteo o usted en todo el libro?"),
            ]),
            context(harness))
        // Another edition's whole-document question, which this round must not
        // be shown: the discriminator is the tag, not the kind.
        _ = await harness.environment.ingest(
            TranslatorReport(entries: [], queries: [
                .init(paragraphId: nil, text: "Duzen oder siezen?"),
            ]),
            context(harness, language: "de", name: "Kurt Meyer", roleId: "role-de"))

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.openQueries.count, 1,
                       "the German edition's question is not this round's business")
        let open = try XCTUnwrap(inputs.openQueries.first)
        XCTAssertNil(open.paragraphId, "it is about the piece, not a paragraph")
        XCTAssertTrue(open.text.contains("¿Tuteo o usted en todo el libro?"), open.text)
        XCTAssertTrue(
            TranslatorBriefing.compose(inputs: inputs).contains("Do not raise"),
            "…and it reaches the model under the instruction not to re-ask it")

        await harness.documentStore.close()
    }

    /// The writer's answer to a whole-document question travels too — the
    /// settled half of the same gather, which is what stops the next round
    /// re-opening a question that has been decided.
    func test_anAnsweredWholeDocumentQuestionTravelsAsAnAnswer() async throws {
        let harness = try await makeHarness()
        _ = try await harness.environment.translatorIdentity("es")

        _ = await harness.environment.ingest(
            TranslatorReport(entries: [], queries: [
                .init(paragraphId: nil, text: "¿Tuteo o usted en todo el libro?"),
            ]),
            context(harness))
        let minted = try XCTUnwrap(queries(harness).first)
        try await harness.doc.acceptAnnotation(id: minted.id, userResponse: "Usted.")

        let gathered = await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertTrue(inputs.openQueries.isEmpty)
        XCTAssertEqual(inputs.answeredQueries.first?.answer, "Usted.")

        await harness.documentStore.close()
    }

    // MARK: - The teardown census

    /// **The wiring census** — `CompilerRunCommandTests`' own, in this
    /// currency. An orchestrator merely released keeps a live, billing `claude`
    /// running (its `deinit` is nonisolated and cannot reap its own child), so
    /// every path that ends a window owes each of them a call. Delete any one
    /// of them and every other assertion in this file still passes.
    ///
    /// **Three counts, not two, since P3**: the designer's loop is the third
    /// session owner and is headless like the translator's, so nothing else in
    /// the app would notice a missing teardown. The shape is deliberately one
    /// test rather than one per orchestrator — what is being asserted is that
    /// the arms stay PAIRED, which is a claim about the set.
    func test_everyWindowEndingPathShutsEverySessionDown() throws {
        let modifier = try source(at: "Maugham/Views/CompilerRunModifier.swift")
        // The compiler's own two teardown arms, each with its siblings.
        XCTAssertTrue(modifier.contains(".onGlobalEvent(.maughamAppWillTerminate)"))
        XCTAssertTrue(modifier.contains(".onChange(of: mcpEnabled)"))
        let compilerShutdowns =
            modifier.components(separatedBy: "orchestrator.shutdown()").count - 1
        XCTAssertEqual(
            compilerShutdowns,
            modifier.components(separatedBy: "translator.shutdown()").count - 1,
            "every compiler shutdown in the modifier needs its translator sibling")
        XCTAssertEqual(
            compilerShutdowns,
            modifier.components(separatedBy: "designer.shutdown()").count - 1,
            "every compiler shutdown in the modifier needs its designer sibling")
        XCTAssertGreaterThanOrEqual(
            compilerShutdowns, 2,
            "app-quit and the AI toggle are both window-ending paths")
        XCTAssertEqual(
            compilerShutdowns,
            modifier.components(separatedBy: "coldCall.shutdown()").count - 1,
            "every compiler shutdown in the modifier needs its cold-call sibling — "
            + "a cold read in flight when the window closes is a billing process "
            + "otherwise (translation pipeline spec §5)")

        // The designer's own five tokens are `DesignerEnvironmentTests`' —
        // each file owns the wiring of the loop it is about; the paired counts
        // above are what has to be asserted together.
        let window = try source(at: "Maugham/Views/ProjectWindow.swift")
        for token in ["TranslatorOrchestrator()", "translator.detach()",
                      "translator.configure(", "translator: translator",
                      "translator.updateModel("] {
            XCTAssertTrue(window.contains(token),
                          "ProjectWindow is missing \(token) — without it the "
                          + "translator is unwired, unmounted, or outlives the "
                          + "window that started it")
        }
        XCTAssertFalse(window.contains("translator.notARealVerb("),
                       "the scan reads the file rather than always answering true")

        for token in ["ColdCall()", "coldCall.detach()", "coldCall.configure(",
                      "coldCall: coldCall"] {
            XCTAssertTrue(window.contains(token),
                          "ProjectWindow is missing \(token) — without it the cold-call "
                          + "runner is unwired, unmounted, or outlives the window")
        }
    }
}
