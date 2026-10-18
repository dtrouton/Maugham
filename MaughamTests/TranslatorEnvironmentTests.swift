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

    /// The fixture directories this suite made, removed when it ends
    /// (whole-branch review, I4).
    ///
    /// `$TMPDIR` is shared with the whole machine and the test host sweeps it
    /// at launch, before an XCTest worker connects. A suite that leaves its
    /// fixtures behind makes every later gate slower, and at 543,002 entries
    /// it stopped being slower and started killing workers with no assertion
    /// failure and nothing to read.
    private var temporaries: [URL] = []

    /// Remember a fixture root so it is removed whatever the test does next.
    @discardableResult
    private func track(_ url: URL) -> URL {
        temporaries.append(url)
        return url
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        for url in temporaries { try? fm.removeItem(at: url) }
        temporaries = []
    }

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
        let root = track(TestTemp.root
            .appendingPathComponent("TranslatorEnv-\(UUID().uuidString)"))
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
            projectRoot: root, device: DeviceIdentity.author.slug)
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
    ) throws -> [TranslationRecord] {
        try TranslationStore.loadMerged(
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

        let latest = TranslationStore.latestByParagraph(try records(harness))
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
        XCTAssertTrue(try records(harness).isEmpty,
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
        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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
        XCTAssertTrue(try records(harness).isEmpty,
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
        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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
        XCTAssertFalse(try records(harness).isEmpty, "…and is still written")

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
            identity: LocalIdentities.current.translator, identities: .current,
            in: harness.projectURL)
        try await TranslationStore.append(
            TranslationRecord(
                paragraphId: ids[1], language: "es", text: "Cerró la puerta.",
                sourceHash: TranslationHash.hash("something else entirely"),
                verbatim: false),
            forDocId: harness.doc.docId,
            identity: LocalIdentities.current.translator, identities: .current,
            in: harness.projectURL)

        _ = try await harness.environment.translatorIdentity("es")
        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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
                identity: LocalIdentities.current.translator, identities: .current,
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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
        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertEqual(inputs.translatorName, identity.name)

        await harness.documentStore.close()
    }

    /// A malformed tag is refused HERE, before a session is spawned — the
    /// orchestrator's `nil briefing == not a run` escape hatch, used for what
    /// Task 4's report says it should be.
    func test_aMalformedLanguageTagIsNotARun() async throws {
        let harness = try await makeHarness()

        let round = try await harness.environment.briefRound(harness.doc.docId, "Español!")

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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
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

        let gathered = try await harness.environment.briefRound(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered).inputs

        XCTAssertTrue(inputs.openQueries.isEmpty)
        XCTAssertEqual(inputs.answeredQueries.first?.answer, "Usted.")

        await harness.documentStore.close()
    }

    // MARK: - The teardown census

    /// **The teardown census — a POPULATION census** (foundations plan 3,
    /// Task 1). A service merely released keeps a live, billing `claude`
    /// running (`ClaudeCLISession`'s `deinit` is nonisolated and cannot reap
    /// its own child), so every path that ends a window owes each service a
    /// call. Those calls now live in ONE place, `AgentRoster`, and this test
    /// checks the two things that make that enough:
    ///
    /// - every window-ending arm hands the roster its teardown —
    ///   `CompilerRunModifier`'s two arms (app quit, the AI toggle) each call
    ///   `roster.shutdownAll()`, and the window's `.onDisappear` gives its
    ///   WINDOW borrow back to `ProjectSessionRegistry`, whose release of a
    ///   window borrow calls `ProjectSession.detachWindow` — which runs
    ///   `roster.detachAll()` for the attached window — and whose last
    ///   release of any kind runs `ProjectSession.close()`, which runs it
    ///   again before the DocumentStore closes (Task 3b: the services follow
    ///   the windows, so a reader holding the stores keeps nothing billing);
    /// - every production class that HOLDS a session runner is a roster
    ///   member — derived from the code, never a list of names, so a sixth
    ///   orchestrator that spawns its own `claude` and is not in the roster
    ///   is red here rather than leaking on every window close.
    ///
    /// What the roster DOES with its members — the order, the fan-out — is
    /// `AgentRosterTests`'.
    func test_everyWindowEndingPathShutsEverySessionDown() throws {
        // (a) Both of the modifier's window-ending arms hand the roster its teardown.
        let modifier = try SourceTree.sourceOfType("CompilerRunModifier", under: ["Maugham"])
        for arm in [".onGlobalEvent(.maughamAppWillTerminate)", ".onChange(of: mcpEnabled)"] {
            let body = try XCTUnwrap(Self.closureBody(after: arm, in: modifier),
                                     "CompilerRunModifier has no \(arm) arm")
            XCTAssertTrue(body.contains("roster.shutdownAll()"),
                          "\(arm) must end every session through the roster — a "
                          + "service it misses is a billing process outliving the window")
        }
        // …and app quit reaches EVERY open project's roster, not only those a
        // mounted window holds: `MaughamApp`'s willTerminate observer calls
        // `ProjectSessionRegistry.shutdownAll()`, which shuts every entry's
        // roster down (final review M2).
        let appQuit = try Self.appQuitReport(base: SourceTree.repoRoot)
        XCTAssertTrue(appQuit.isEmpty, appQuit.joined(separator: "\n"))

        // (b) The window closing gives its session back (foundations plan 3,
        // Task 2, borrowed since Task 3) — code, not a comment naming it…
        let onDisappears = try SourceTree.windowSources().flatMap { text in
            Self.closureBodies(after: ".onDisappear", in: text)
        }.map { String(decoding: SourceTree.mask($0), as: UTF8.self) }
        XCTAssertTrue(onDisappears.contains { $0.contains("sessions.release(") },
                      "ProjectWindow's .onDisappear must give its session back to the "
                      + "registry — otherwise a closed window keeps its sessions and its "
                      + "stores alive")
        // …and never closes it itself: the session is borrowed, and another
        // window on the same project may still be working in it.
        XCTAssertFalse(onDisappears.contains { $0.contains("session.close()") },
                       "ProjectWindow's .onDisappear closes a session it only borrowed — "
                       + "the registry's last release is what closes it")
        // …the registry's release detaches a window borrow and its LAST
        // release closes the session…
        let release = try Self.registryReleaseReport(base: SourceTree.repoRoot)
        XCTAssertTrue(release.isEmpty, release.joined(separator: "\n"))
        // …the session's detach of the attached window detaches every
        // service — the link that ends billing while a reader holds the
        // stores (Task 3b)…
        let detach = try Self.windowDetachReport(base: SourceTree.repoRoot)
        XCTAssertTrue(detach.isEmpty, detach.joined(separator: "\n"))
        // …and the session's close detaches every service BEFORE the
        // DocumentStore closes.
        let close = try Self.sessionCloseReport(base: SourceTree.repoRoot)
        XCTAssertTrue(close.isEmpty, close.joined(separator: "\n"))

        // (c) Every holder of a session runner is a roster member.
        let report = try Self.rosterMembershipReport(base: SourceTree.repoRoot)
        XCTAssertTrue(report.isEmpty, report.joined(separator: "\n"))

        // (d) …and the roster's own two verbs reach EVERY member. Calling
        // `roster.shutdownAll()` from every arm is worth nothing if
        // `shutdownAll` forgot the compiler: a released orchestrator is a live,
        // billing process. Member names are derived from the roster's stored
        // properties, never typed here.
        let teardown = try Self.rosterTeardownReport(base: SourceTree.repoRoot)
        XCTAssertTrue(teardown.isEmpty, teardown.joined(separator: "\n"))

        // And the members are WIRED by the session and MOUNTED by the window.
        // Both reach each member under its short name (`translator` is
        // `roster.translator` — a local in `ProjectSession.open`, an accessor
        // in `ProjectWindow`), so these are the spellings in their code. The
        // last two wiring tokens are spelled `pipeline?.` rather than
        // `pipeline.`: they live inside the translator environment's
        // `onRunEnded`/`onRunAbandoned` closures, which capture the pipeline
        // weakly — a strong capture there is a window's whole project graph
        // held alive by an orchestrator closure, which is the thing
        // `.onDisappear`'s scorch exists to prevent.
        //
        // Read from `attachWindow`'s body (Task 3b), where the configure
        // calls live: a window attaching is what wires the services, and
        // `open` — the stores, which a reader borrows — configures none.
        let sessionSource = try SourceTree.sourceOfType("ProjectSession", under: ["Maugham"])
        let session = try XCTUnwrap(Self.closureBody(after: "func attachWindow(", in: sessionSource),
                                    "ProjectSession declares no attachWindow(")
        let open = try XCTUnwrap(Self.closureBody(after: "static func open(", in: sessionSource),
                                 "ProjectSession declares no open(")
        for token in ["compiler.configure(", "translator.configure(", "designer.configure(",
                      "coldCall.configure(", "pipeline.configure(",
                      "translator: translator, coldCall: coldCall",
                      "pipeline?.translatorRunEnded(", "pipeline?.translatorRunAbandoned("] {
            XCTAssertTrue(session.contains(token),
                          "ProjectSession.attachWindow is missing \(token) — without it a "
                          + "roster member is unwired or deaf to the translator")
        }
        XCTAssertFalse(String(decoding: SourceTree.mask(open), as: UTF8.self).contains(".configure("),
                       "ProjectSession.open configures a service — a reader's borrow would "
                       + "then hold a billing session no window can end")
        // The compiler's flash goes through the session to whichever window
        // is attached NOW, never to a closure captured from the window that
        // configured it — the reopened-window half of Task 3b.
        XCTAssertTrue(session.contains("onRunAcknowledged: { [weak self] in self?.flash($0) }"),
                      "the compiler's flash must forward through the session's current sink")
        // Mounted through the environment since foundations plan 3 Task 5:
        // the window injects the roster into the right column, and the
        // toggle reads the roster and hands each member to its pane. Read
        // from masked code, so a comment naming a token does not count.
        let window = try SourceTree.windowSource()
        let windowCode = String(decoding: SourceTree.mask(window), as: UTF8.self)
        XCTAssertTrue(windowCode.contains(".environment(roster)"),
                      "ProjectWindow no longer injects the roster — without it every "
                      + "roster member is unmounted from the right column")
        let toggle = try SourceTree.sourceOfType("DetailPaneToggle", under: ["Maugham"])
        let toggleCode = String(decoding: SourceTree.mask(toggle), as: UTF8.self)
        for token in ["@Environment(AgentRoster.self)",
                      "{ roster?.translator }", "{ roster?.coldCall }", "{ roster?.pipeline }",
                      "translator: translator", "coldCall: coldCall", "pipeline: pipeline"] {
            XCTAssertTrue(toggleCode.contains(token),
                          "DetailPaneToggle is missing \(token) — without it a roster member "
                          + "is unmounted")
        }
        XCTAssertFalse(window.contains("translator.notARealVerb(")
                       || session.contains("translator.notARealVerb(")
                       || toggle.contains("translator.notARealVerb("),
                       "the scan reads the file rather than always answering true")
    }

    /// CONTROL for (b)'s second half: a session whose `close()` closes the
    /// DocumentStore before detaching is reported, and so is one that only
    /// names the detach in a comment.
    func test_theSessionCloseCensusFiresOnAPlantedMisorder() throws {
        let misordered = try SourceTree.plantedTree([
            "Maugham/Stores/ProjectSession.swift": """
                @MainActor @Observable
                final class ProjectSession {
                    func close() async {
                        await documentStore.close()
                        roster.detachAll()
                    }
                }
                """,
        ])
        let misorderedReport = try Self.sessionCloseReport(base: misordered)
        XCTAssertEqual(misorderedReport.count, 1, misorderedReport.joined(separator: "\n"))
        XCTAssertTrue(misorderedReport.contains { $0.contains("before") },
                      misorderedReport.joined(separator: "\n"))

        let commented = try SourceTree.plantedTree([
            "Maugham/Stores/ProjectSession.swift": """
                @MainActor @Observable
                final class ProjectSession {
                    func close() async {
                        // roster.detachAll()
                        await documentStore.close()
                    }
                }
                """,
        ])
        let commentedReport = try Self.sessionCloseReport(base: commented)
        XCTAssertEqual(commentedReport.count, 1, commentedReport.joined(separator: "\n"))
        XCTAssertTrue(commentedReport.contains { $0.contains("never calls roster.detachAll()") },
                      commentedReport.joined(separator: "\n"))
    }

    /// CONTROL for (b)'s registry half: a registry whose `release` only
    /// drops its entry — or names the close in a comment — is reported.
    func test_theRegistryReleaseCensusFiresOnAPlantedForgottenClose() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Stores/ProjectSessionRegistry.swift": """
                @MainActor @Observable
                final class ProjectSessionRegistry {
                    func release(_ lease: Lease) async {
                        session.detachWindow(leaving.attachment)
                        // await session.close()
                        entries[lease.key] = nil
                    }
                }
                """,
        ])
        let report = try Self.registryReleaseReport(base: base)
        XCTAssertEqual(report.count, 1, report.joined(separator: "\n"))
        XCTAssertTrue(report.contains { $0.contains("never closes") }, report.joined(separator: "\n"))
    }

    /// CONTROL for the registry's window half (Task 3b): a `release` that
    /// closes on the last borrow but never detaches a window — or names the
    /// detach only in a comment — is reported.
    func test_theRegistryReleaseCensusFiresOnAPlantedForgottenWindowDetach() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Stores/ProjectSessionRegistry.swift": """
                @MainActor @Observable
                final class ProjectSessionRegistry {
                    func release(_ lease: Lease) async {
                        // session.detachWindow(leaving.attachment)
                        entries[lease.key] = nil
                        await session.close()
                    }
                }
                """,
        ])
        let report = try Self.registryReleaseReport(base: base)
        XCTAssertEqual(report.count, 1, report.joined(separator: "\n"))
        XCTAssertTrue(report.contains { $0.contains("never detaches a window") },
                      report.joined(separator: "\n"))
    }

    /// Whether app quit ends every open project's warm sessions: the
    /// willTerminate observer in `MaughamApp` calls the registry's
    /// `shutdownAll()`, and that runs `roster.shutdownAll()` over every
    /// entry. One sentence per missing link; empty when both hold. Read
    /// from masked code, so a comment naming a call does not count.
    private static func appQuitReport(base: URL) throws -> [String] {
        var report: [String] = []
        let app = try SourceTree.sourceOfType("MaughamApp", under: ["Maugham"], base: base)
        let observer = closureBody(after: "NSApplication.willTerminateNotification", in: app)
            .map { String(decoding: SourceTree.mask($0), as: UTF8.self) } ?? ""
        if !observer.contains("sessions.shutdownAll()") {
            report.append("MaughamApp's willTerminate observer never calls the session "
                          + "registry's shutdownAll() — a project only a reader holds keeps "
                          + "its claude sessions billing past the app's quit")
        }
        let registry = try SourceTree.sourceOfType("ProjectSessionRegistry", under: ["Maugham"],
                                                   base: base)
        let body = closureBody(after: "func shutdownAll()", in: registry)
            .map { String(decoding: SourceTree.mask($0), as: UTF8.self) } ?? ""
        if !body.contains("roster.shutdownAll()") {
            report.append("ProjectSessionRegistry.shutdownAll() never shuts a session's roster "
                          + "down — app quit would leave every open project's claude billing")
        }
        return report
    }

    /// CONTROL for the app-quit link: an observer that only names the call
    /// in a comment, over a registry whose `shutdownAll()` forgets the
    /// roster, is reported twice.
    func test_theAppQuitCensusFiresOnAPlantedForgottenShutdown() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/MaughamApp.swift": """
                @main
                struct MaughamApp: App {
                    init() {
                        NotificationCenter.default.addObserver(
                            forName: NSApplication.willTerminateNotification,
                            object: nil, queue: nil
                        ) { _ in
                            // sessions.shutdownAll()
                            unlink(path)
                        }
                    }
                }
                """,
            "Maugham/Stores/ProjectSessionRegistry.swift": """
                @MainActor @Observable
                final class ProjectSessionRegistry {
                    func shutdownAll() {
                        for entry in entries.values {
                            // entry.session.roster.shutdownAll()
                            _ = entry
                        }
                    }
                }
                """,
        ])
        let report = try Self.appQuitReport(base: base)
        XCTAssertEqual(report.count, 2, report.joined(separator: "\n"))
    }

    /// Whether `ProjectSessionRegistry.release` closes the session it gives
    /// up — the one place a window-ending path reaches `ProjectSession`'s
    /// close since windows borrow (Task 3). Empty when it does.
    private static func registryReleaseReport(base: URL) throws -> [String] {
        let text = try SourceTree.sourceOfType("ProjectSessionRegistry", under: ["Maugham"],
                                               base: base)
        guard let body = closureBody(after: "func release(", in: text) else {
            return ["ProjectSessionRegistry declares no release(_:)"]
        }
        let code = String(decoding: SourceTree.mask(body), as: UTF8.self)
        var report: [String] = []
        if !code.contains("session.detachWindow(") {
            report.append("ProjectSessionRegistry.release never detaches a window — the last "
                          + "window on a project would leave its services billing while a "
                          + "reader holds the stores")
        }
        if !code.contains("session.close()") {
            report.append("ProjectSessionRegistry.release never closes the session — the last "
                          + "borrow on a project would leave its services and stores alive")
        }
        return report
    }

    /// Whether `ProjectSession.detachWindow` detaches every service — the
    /// link that ends billing when the last window goes while a reader holds
    /// the stores (Task 3b). Empty when it does.
    private static func windowDetachReport(base: URL) throws -> [String] {
        let text = try SourceTree.sourceOfType("ProjectSession", under: ["Maugham"], base: base)
        guard let body = closureBody(after: "func detachWindow(", in: text) else {
            return ["ProjectSession declares no detachWindow(_:)"]
        }
        let code = String(decoding: SourceTree.mask(body), as: UTF8.self)
        guard code.contains("roster.detachAll()") else {
            return ["ProjectSession.detachWindow never calls roster.detachAll() — the last "
                    + "window closing would leave every claude service warm and billing"]
        }
        return []
    }

    /// CONTROL for the window-detach link: a `detachWindow` that clears the
    /// canvas but only NAMES the detach in a comment is reported.
    func test_theWindowDetachCensusFiresOnAPlantedForgottenDetach() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Stores/ProjectSession.swift": """
                @MainActor @Observable
                final class ProjectSession {
                    func detachWindow(_ token: WindowAttachment) {
                        guard attachment == token else { return }
                        // roster.detachAll()
                        projectStore.liveCanvas = nil
                    }
                }
                """,
        ])
        let report = try Self.windowDetachReport(base: base)
        XCTAssertEqual(report.count, 1, report.joined(separator: "\n"))
    }

    /// Whether `ProjectSession.close()` detaches the roster and THEN closes
    /// the DocumentStore, one sentence per thing wrong; empty when it does.
    /// Throws when nothing under `Maugham/` declares `ProjectSession`.
    private static func sessionCloseReport(base: URL) throws -> [String] {
        let text = try SourceTree.sourceOfType("ProjectSession", under: ["Maugham"], base: base)
        guard let body = closureBody(after: "func close()", in: text) else {
            return ["ProjectSession declares no close()"]
        }
        let code = String(decoding: SourceTree.mask(body), as: UTF8.self)
        guard let detach = code.range(of: "roster.detachAll()") else {
            return ["ProjectSession.close() never calls roster.detachAll() — a closed "
                    + "window's services would keep their sessions and the stores alive"]
        }
        guard let closeStore = code.range(of: "documentStore.close()") else {
            return ["ProjectSession.close() never closes its DocumentStore"]
        }
        if closeStore.lowerBound < detach.lowerBound {
            return ["ProjectSession.close() closes the DocumentStore before it detaches "
                    + "the roster — a service mid-turn would still be writing through it"]
        }
        return []
    }

    /// CONTROL for (d): a roster whose `shutdownAll` forgets the designer and
    /// whose `detachAll` forgets the compiler is reported twice — and a
    /// comment naming the missing call does not count as making it.
    func test_theRosterTeardownCensusFiresOnAPlantedForgottenMember() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Compiler/AgentRoster.swift": """
                @MainActor @Observable
                final class AgentRoster {
                    let compiler: CompilerOrchestrator
                    let designer: DesignerOrchestrator
                    let translationRuns: TranslationRunLog
                    func shutdownAll() {
                        compiler.shutdown()
                        // designer.shutdown()
                    }
                    func detachAll() {
                        designer.detach()
                    }
                }
                """,
        ])
        let report = try Self.rosterTeardownReport(base: base)
        XCTAssertEqual(report.count, 2, "Self-check: exactly the two planted omissions. Got:\n"
                       + report.joined(separator: "\n"))
        XCTAssertTrue(report.contains { $0.contains("designer.shutdown()") },
                      report.joined(separator: "\n"))
        XCTAssertTrue(report.contains { $0.contains("compiler.detach()") },
                      report.joined(separator: "\n"))
    }

    /// Roster members with no session to end, by TYPE, each with why.
    private static let noTeardownMembers: [String: String] = [
        "TranslationRunLog": "holds finished rounds' summaries only — no session, no "
            + "leg, nothing that bills or waits",
    ]

    /// Every roster member `shutdownAll` does not shut down or `detachAll`
    /// does not detach, one sentence each; empty when both reach every member.
    /// Throws (through `filesDeclaring`) when nothing declares `AgentRoster`.
    private static func rosterTeardownReport(base: URL) throws -> [String] {
        var report: [String] = []
        for file in try SourceTree.filesDeclaring("AgentRoster", under: ["Maugham"], base: base) {
            let text = try SourceTree.read(file, base: base)
            let masked = String(decoding: try SourceTree.checkedMask(text, path: file),
                                as: UTF8.self)
            let members = storedProperties(in: masked).filter { $0.owner == "AgentRoster" }
            guard !members.isEmpty else { continue }
            for stale in Set(noTeardownMembers.keys).subtracting(members.map(\.type)).sorted() {
                report.append("noTeardownMembers names \(stale), which is not a roster member")
            }
            for (verb, call) in [("shutdownAll", "shutdown"), ("detachAll", "detach")] {
                guard let body = closureBody(after: "func \(verb)()", in: text) else {
                    report.append("AgentRoster declares no \(verb)()")
                    continue
                }
                let code = String(decoding: SourceTree.mask(body), as: UTF8.self)
                for member in members where noTeardownMembers[member.type] == nil
                    && !code.contains("\(member.name).\(call)()") {
                    report.append("AgentRoster.\(verb)() never calls \(member.name).\(call)() — "
                                  + "every arm that calls it would leave that member's "
                                  + "session running")
                }
            }
        }
        return report
    }

    /// CONTROL for (c): a planted sixth orchestrator holding a runner, and not
    /// in the roster, is reported — and a runner held as a LOCAL inside a
    /// function, a computed property returning one, a closure that makes one,
    /// or one named in a comment, is not a holder. A class declared with its
    /// property on ONE line (`CompilerOrchestrator` below) still counts.
    func test_theSessionHolderCensusFiresOnAPlantedSixthOrchestrator() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Compiler/AgentRoster.swift": """
                @MainActor @Observable
                final class AgentRoster {
                    let compiler: CompilerOrchestrator
                    let translator: TranslatorOrchestrator
                    let designer: DesignerOrchestrator
                    let coldCall: ColdCall
                    let pipeline: TranslationPipeline
                    let translationRuns: TranslationRunLog
                    func shutdownAll() {
                        let probe: CompilerRunner? = nil
                    }
                }
                """,
            "Maugham/Compiler/Holders.swift": """
                final class CompilerOrchestrator { private var runner: CompilerRunner? }
                final class TranslatorOrchestrator {
                    @ObservationIgnored private var runner: CompilerRunner?
                }
                final class DesignerOrchestrator {
                    private var runner: CompilerRunner?
                }
                struct ReadsARunner {
                    var current: CompilerRunner? { nil }
                }
                final class ColdCall {
                    // private var live: ClaudeCLISession? — a comment, not a holder
                    private var live: CompilerRunner?
                }
                """,
            "Maugham/Compiler/SixthOrchestrator.swift": """
                @MainActor
                final class SixthOrchestrator {
                    struct Environment {
                        var makeRunner: (URL, String) -> CompilerRunner
                    }
                    private var session: ClaudeCLISession?
                    func run() {
                        let local: CompilerRunner? = nil
                    }
                }
                """,
        ])
        let report = try Self.rosterMembershipReport(base: base)
        XCTAssertEqual(report.count, 1, "Self-check: exactly the planted holder. Got:\n"
                       + report.joined(separator: "\n"))
        XCTAssertTrue(report.first?.contains("SixthOrchestrator") == true,
                      report.joined(separator: "\n"))
    }

    /// The types a session runner is held as. `CompilerRunner` is the seam;
    /// `ClaudeCLISession` is its production implementation, and a class
    /// holding one directly is as much a holder as one holding the seam.
    private static let runnerTypes: Set<String> = ["CompilerRunner", "ClaudeCLISession"]

    /// Roster members that hold no runner, each with why it is a member.
    private static let nonHoldingMembers: [String: String] = [
        "TranslationPipeline": "owns no session but owns the LEG that waits on the "
            + "translator's summary; its shutdown must run first, so it is torn down "
            + "with the services rather than beside them",
        "TranslationRunLog": "holds summaries only; it is wired with the services "
            + "(`onRunEnded`) and lives exactly as long as they do",
    ]

    /// Holders of a runner that are NOT roster members, each with why. Empty:
    /// `ClaudeCLISession` is the runner itself rather than a holder of one —
    /// it declares no runner property, so the scan never names it.
    private static let exemptHolders: [String: String] = [:]

    /// Every way the roster and the population of session holders disagree,
    /// one sentence each; empty when they agree.
    private static func rosterMembershipReport(base: URL) throws -> [String] {
        // Only a file whose raw text names a runner type or the roster can
        // declare a holder or a member; the rest are skipped before the mask.
        let names = runnerTypes.union(["AgentRoster"])
        let properties = try SourceTree.swiftFiles(under: "Maugham", base: base)
            .flatMap { file -> [(owner: String, name: String, type: String)] in
                let text = try SourceTree.read(file, base: base)
                guard names.contains(where: text.contains) else { return [] }
                let masked = try SourceTree.checkedMask(text, path: file)
                return storedProperties(in: String(decoding: masked, as: UTF8.self))
            }
        let holders = Set(properties.filter { runnerTypes.contains($0.type) }.map(\.owner))
        let members = Set(properties.filter { $0.owner == "AgentRoster" }.map(\.type))
        guard !members.isEmpty else { return ["AgentRoster declares no stored member"] }

        var report: [String] = []
        for holder in holders.subtracting(members).subtracting(exemptHolders.keys).sorted() {
            report.append("\(holder) holds a session runner and is not an AgentRoster member "
                          + "— no window-ending path would ever shut it down")
        }
        for member in members.subtracting(holders).subtracting(nonHoldingMembers.keys).sorted() {
            report.append("AgentRoster member \(member) holds no runner and has no "
                          + "nonHoldingMembers entry saying why it is a member")
        }
        for stale in Set(nonHoldingMembers.keys).subtracting(members.subtracting(holders)).sorted() {
            report.append("nonHoldingMembers names \(stale), which is not a runner-less roster member")
        }
        for stale in Set(exemptHolders.keys).subtracting(holders).sorted() {
            report.append("exemptHolders names \(stale), which holds no runner")
        }
        return report
    }

    /// Every stored property declared DIRECTLY in a class, struct, actor or
    /// enum body of one masked file, with its owner and its bare type (`?`/`!`
    /// and `any` stripped). A local inside a function is at a deeper brace and
    /// is not one; a computed property (`{` after the type) is not one; a
    /// closure-typed property is not one (its type does not match). Known
    /// limit: a stored property with `didSet`/`willSet` observers reads as
    /// computed, and an annotation reflowed across lines is not read. The
    /// blind spot most likely to arrive is a COLLECTION of runners
    /// (`[CompilerRunner]`, a pool or a per-language map) — its type is not a
    /// runner type, so a holder of one is not counted.
    private static func storedProperties(in masked: String)
        -> [(owner: String, name: String, type: String)] {
        let typeHeader = try! NSRegularExpression(pattern:
            #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"#
            + #"(?:(?:public|private|fileprivate|internal|package|open|final|indirect|nonisolated)\s+)*"#
            + #"(?:class|struct|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let property = try! NSRegularExpression(pattern:
            #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"#
            + #"(?:(?:public|private|fileprivate|internal|package|open|final|static|weak|unowned|lazy|nonisolated|override)(?:\([^)]*\))?\s+)*"#
            + #"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:any\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*(=.*)?$"#)
        let notTypeNames: Set<String> = ["func", "var", "let", "subscript", "init", "protocol"]

        var found: [(owner: String, name: String, type: String)] = []
        // One entry per open brace: the type name it opened, or nil.
        var stack: [String?] = []
        var pendingType: String?
        // Read in SEGMENTS between braces, so `final class X { var r: CompilerRunner? }`
        // on one line is read as the header, then the property inside it.
        for line in masked.components(separatedBy: "\n") {
            var segment = ""
            func read(_ segment: String, opensABody: Bool) {
                let range = NSRange(segment.startIndex..., in: segment)
                if let owner = stack.last ?? nil,
                   let match = property.firstMatch(in: segment, range: range),
                   let name = Range(match.range(at: 1), in: segment),
                   let type = Range(match.range(at: 2), in: segment),
                   // `var r: CompilerRunner? {` is computed: it holds nothing.
                   !(opensABody && match.range(at: 3).location == NSNotFound) {
                    found.append((owner, String(segment[name]), String(segment[type])))
                }
                if let match = typeHeader.firstMatch(in: segment, range: range),
                   let name = Range(match.range(at: 1), in: segment),
                   !notTypeNames.contains(String(segment[name])) {
                    pendingType = String(segment[name])
                }
            }
            for character in line {
                guard character == "{" || character == "}" else {
                    segment.append(character)
                    continue
                }
                read(segment, opensABody: character == "{")
                segment = ""
                if character == "{" {
                    stack.append(pendingType)
                    pendingType = nil
                } else if !stack.isEmpty {
                    stack.removeLast()
                }
            }
            read(segment, opensABody: false)
        }
        return found
    }

    /// The text of the closure body opening after `token`, or nil when the
    /// token is absent. Read through `SourceTree.mask`, so a brace in a string
    /// or comment never closes the body early.
    private static func closureBody(after token: String, in text: String) -> String? {
        closureBodies(after: token, in: text).first
    }

    /// The closure body after every occurrence of `token` in `text`.
    private static func closureBodies(after token: String, in text: String) -> [String] {
        let masked = SourceTree.mask(text)
        let maskedText = String(decoding: masked, as: UTF8.self)
        let raw = Array(text.utf8)
        var bodies: [String] = []
        var searchFrom = maskedText.startIndex
        while let hit = maskedText.range(of: token, range: searchFrom..<maskedText.endIndex) {
            let start = maskedText.utf8.distance(from: maskedText.startIndex, to: hit.upperBound)
            if let end = SourceTree.bodyEnd(in: masked, from: start) {
                bodies.append(String(decoding: raw[start...end], as: UTF8.self))
            }
            searchFrom = hit.upperBound
        }
        return bodies
    }

    // MARK: - The fix gather (Plan 3)

    // MARK: - A present-but-unreadable translation file (P2a D0)

    /// **The gather THROWS rather than answering nil.**
    ///
    /// `nil` is this gather's "not a run" — a bad language tag, a document with
    /// no current paragraphs — and the orchestrator ends a nil in silence,
    /// which is right for a click with nothing to act on. A translation file
    /// that is present and unreadable is not that: the edition exists and
    /// cannot be read, and briefing the translator off whichever actor file
    /// happened to open would show them paragraphs as untranslated that are
    /// translated on disk, so the round would write second renderings of them.
    func test_anUnreadableTranslationFileRefusesTheBriefingByName() async throws {
        let harness = try await makeHarness()
        try await seedTranslation(harness, paragraph: 0, text: "Llegó la niebla.")
        _ = try await harness.environment.translatorIdentity("es")

        // A second ACTOR's file for the same (document, language) — the P1b
        // shape — squatted by a directory so it is present and unreadable.
        let squat = TranslationStore.fileURL(
            forDocId: harness.doc.docId, language: "es",
            deviceSlug: DeviceSlug.make(from: "bad"), in: harness.projectURL)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)

        do {
            _ = try await harness.environment.briefRound(harness.doc.docId, "es")
            XCTFail("a present-but-unreadable translation file must refuse the run")
        } catch {
            guard case OpLogStore.ReadError.unreadableFile(let name, _, _) = error else {
                return XCTFail("expected OpLogStore.ReadError.unreadableFile, got \(error)")
            }
            XCTAssertEqual(name, squat.lastPathComponent,
                           "the refusal the writer sees names the file")
        }
    }

    private func seedTranslation(_ harness: Harness, paragraph index: Int,
                                 text: String, language: String = "es") async throws {
        let id = harness.doc.sequence[index]
        _ = try await TranslationWritePipeline.perform(
            entries: [.init(paragraphId: id, text: text, verbatim: nil, delete: nil)],
            language: language, documentId: harness.doc.docId,
            state: (harness.doc.sequence, harness.doc.paragraphs, harness.projectURL),
            actor: .translator)
    }

    /// The `.fix` work-list is built FROM the notes: one `.fresh` item per
    /// noted paragraph carrying its current translation, in sequence order,
    /// and the mode's notes are exactly the ones whose paragraph made an item
    /// — a note whose paragraph has no current translation is dropped rather
    /// than briefed blind (a `FixNote` with no work item would make the
    /// report fail whole with no clue why).
    func test_theFixGatherBuildsTheWorkListFromTheNotesItBriefs() async throws {
        let harness = try await makeHarness()
        try await seedTranslation(harness, paragraph: 0, text: "Llegó la niebla.")
        try await seedTranslation(harness, paragraph: 2, text: "Nadie habló.")
        let ids = harness.doc.sequence
        let notes: [TranslatorBriefing.FixNote] = [
            .init(id: "n-last", paragraphId: ids[2], author: "Ocampo", kind: "rhythm",
                  severity: "minor", text: "Limps."),
            .init(id: "n-first", paragraphId: ids[0], author: "Ocampo", kind: "register",
                  severity: "major", text: "Wobbles."),
            .init(id: "n-untranslated", paragraphId: ids[1], author: "Ocampo",
                  kind: "grammar", severity: "minor", text: "No text here."),
        ]

        // Hoisted out of `XCTUnwrap`: an `await` cannot live inside an
        // autoclosure, so the gather runs first and the unwrap reads a value.
        let gathered = try await harness.environment.briefFix(
            harness.doc.docId, "es", notes, true)
        let round = try XCTUnwrap(gathered)
        let inputs = round.inputs
        XCTAssertEqual(inputs.workList.map(\.paragraphId), [ids[0], ids[2]], "sequence order")
        XCTAssertEqual(inputs.workList.map(\.status), [.fresh, .fresh])
        XCTAssertEqual(inputs.workList.map(\.priorTranslation),
                       ["Llegó la niebla.", "Nadie habló."])
        guard case .fix(let briefed, let isFinal) = inputs.mode else {
            return XCTFail("a fix gather briefs in fix mode")
        }
        XCTAssertTrue(isFinal)
        XCTAssertEqual(briefed.map(\.id), ["n-last", "n-first"],
                       "the untranslated paragraph's note is not briefed")
        XCTAssertEqual(inputs.reportMode, .fix(briefedNoteIds: ["n-last", "n-first"]))
        XCTAssertEqual(Set(round.sourceHashes.keys), Set([ids[0], ids[2]]))
        XCTAssertTrue(TranslatorBriefing.compose(inputs: inputs)
                          .contains(TranslatorBriefing.repairSentence))
        await harness.documentStore.close()
    }

    /// No noted paragraph has a translation → an EMPTY work-list, not nil:
    /// the orchestrator reports `nothingToTranslate` and the pipeline records
    /// a skip, where nil would be an abandon with no leg to show for it.
    func test_aFixGatherWithNoBriefableNoteAnswersAnEmptyWorkList() async throws {
        let harness = try await makeHarness()
        let notes = [TranslatorBriefing.FixNote(
            id: "n1", paragraphId: harness.doc.sequence[0], author: "Ocampo",
            kind: "rhythm", severity: nil, text: "Limps.")]
        let gathered = try await harness.environment.briefFix(
            harness.doc.docId, "es", notes, false)
        let round = try XCTUnwrap(gathered)
        XCTAssertTrue(round.inputs.workList.isEmpty)
        await harness.documentStore.close()
    }

    /// Ingest reports what a fix leg rewrote — the record that stood before
    /// and the one it appended — and carries the report's own answers whole.
    func test_ingestReportsRewritesAndTheFixReportsAnswers() async throws {
        let harness = try await makeHarness()
        try await seedTranslation(harness, paragraph: 0, text: "Llegó la niebla.")
        let id = harness.doc.sequence[0]
        let before = try XCTUnwrap(
            TranslationStore.latestByParagraph(try records(harness))[id])
        let report = TranslatorReport(
            entries: [.init(paragraphId: id, text: "Vino la niebla.", verbatim: nil)],
            queries: [], addressed: ["n1"],
            declined: [.init(noteId: "n2", reason: "Deliberate.")],
            summary: "Two fixes.",
            glossaryProposals: [.init(term: "fog", rendering: "niebla", reason: "fixed")])

        let outcome = await harness.environment.ingest(report, context(harness))

        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.addressed, ["n1"])
        XCTAssertEqual(outcome.declined.map(\.reason), ["Deliberate."])
        XCTAssertEqual(outcome.summary, "Two fixes.")
        XCTAssertEqual(outcome.glossaryProposals.map(\.rendering), ["niebla"])
        let rewrite = try XCTUnwrap(outcome.rewrites.first { $0.paragraphId == id })
        XCTAssertEqual(rewrite.beforeRecordId, before.opId)
        XCTAssertEqual(rewrite.before, "Llegó la niebla.")
        XCTAssertEqual(rewrite.after, "Vino la niebla.")
        XCTAssertNotEqual(rewrite.afterRecordId, before.opId)
        XCTAssertEqual(rewrite.afterRecordId,
                       TranslationStore.latestByParagraph(try records(harness))[id]?.opId)
        await harness.documentStore.close()
    }

    /// A query on a document the window does not have open still lands — the
    /// book queue runs over closed chapters, and a question with nowhere to go
    /// was the one gap the single-chapter Run could afford.
    func test_aQueryOnAClosedDocumentStillLands() async throws {
        let harness = try await makeHarness()
        let docId = harness.doc.docId
        let paragraphId = harness.doc.sequence[1]
        await harness.documentStore.close()   // the window no longer holds it

        let report = TranslatorReport(
            entries: [], queries: [.init(paragraphId: paragraphId, text: "¿Usted o tú?")])
        let outcome = await harness.environment.ingest(report, context(harness))
        XCTAssertEqual(outcome.queriesMinted, 1)

        let reopened = try await Document.load(
            url: harness.projectURL.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s2", presenter: nil)
        let landed = reopened.annotations(filter: AnnotationFilter(statuses: nil))
        XCTAssertEqual(landed.map(\.body), ["¿Usted o tú?"])
        XCTAssertEqual(landed.first?.language, "es")
        _ = docId
    }

    // MARK: - The one ceiling every session shares (2026-09-09)

    /// **The translation cast once carried a 900 s budget of its own; since
    /// the liveness milestone every session shares one ceiling, and this pins
    /// that the factory passes nothing special.** `runTimeout` is readable for
    /// exactly this assertion.
    func test_theProductionRunnerCarriesTheOneCeilingEverySessionShares() async throws {
        let harness = try await makeHarness()
        let configURL = harness.projectURL.appendingPathComponent("mcp-config.json")
        let made = harness.environment.makeRunner(configURL, "haiku")
        let session = try XCTUnwrap(made as? ClaudeCLISession,
                                    "production spawns the real CLI session")
        XCTAssertEqual(session.runTimeout, ClaudeCLISession.defaultRunTimeout)
        XCTAssertEqual(session.confinement, .bridged(mcpConfigPath: configURL),
                       "the budget went; the confinement did not")
        session.shutdown()
    }
}
