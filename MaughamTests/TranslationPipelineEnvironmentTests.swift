import XCTest
import MaughamCore
@testable import Maugham

/// The pipeline's production closures against a real project: the reader is
/// briefed with fresh translations only and never with source, the collator
/// with pairs and directives, identities are minted once, declined notes
/// mint as queries carrying the translator's reason, rounds reach the store.
@MainActor
final class TranslationPipelineEnvironmentTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
        let environment: TranslationPipeline.Environment
        let rounds: () -> [TranslationRound]
    }

    /// `TranslatorEnvironmentTests.makeHarness`'s project on disk — one
    /// three-paragraph novel chapter, open in a `DocumentStore`, because a real
    /// `Document.load` is what mints the `¶id`s every id in this file names —
    /// plus the publish config whose `metadata.language` is the book's own, and
    /// so the author's language every briefing's role frame is written in.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineEnv-\(UUID().uuidString)")
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

        try await PublishConfigStore(projectURL: root).save(
            PublishConfig(metadata: .init(title: "Env", author: "A", language: "en")))

        let translator = TranslatorOrchestrator()
        let coldCall = ColdCall()
        let rounds = Box<[TranslationRound]>([])
        let environment = TranslationPipeline.Environment.production(
            store: projectStore, documentStore: documentStore, projectURL: root,
            translator: translator, coldCall: coldCall,
            onRoundEnded: { rounds.value.append($0) })

        return Harness(projectURL: root, store: projectStore, documentStore: documentStore,
                       doc: doc, environment: environment, rounds: { rounds.value })
    }

    private final class Box<T> {
        var value: T
        init(_ v: T) { value = v }
    }

    private func seed(_ harness: Harness, paragraph index: Int, text: String) throws {
        let id = harness.doc.sequence[index]
        _ = try TranslationWritePipeline.perform(
            entries: [.init(paragraphId: id, text: text, verbatim: nil, delete: nil)],
            language: "es", documentId: harness.doc.docId,
            state: (harness.doc.sequence, harness.doc.paragraphs, harness.projectURL),
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current))
    }

    // MARK: - The reader's gather

    func test_theReaderIsBriefedWithFreshTranslationsOnlyAndNeverTheSource() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la niebla.")
        let gathered = await harness.environment.briefReader(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered)
        XCTAssertEqual(inputs.readerName, "Ocampo", "the preset, read without minting")
        XCTAssertEqual(inputs.language, "es")
        XCTAssertEqual(inputs.authorLanguage, "English")
        XCTAssertEqual(inputs.paragraphs.map(\.paragraphId), harness.doc.sequence)
        XCTAssertEqual(inputs.paragraphs.map(\.translation), ["Llegó la niebla.", nil, nil])
        XCTAssertFalse(ReaderBriefing.compose(inputs: inputs).contains("The fog came in."))
        await harness.documentStore.close()
    }

    func test_aStaleTranslationIsAGapToTheReader() async throws {
        let harness = try await makeHarness()
        // A record whose source hash is not the paragraph's current hash IS a
        // stale translation, by `TranslationDeriver`'s own definition.
        try await TranslationStore.append(
            TranslationRecord(paragraphId: harness.doc.sequence[1], language: "es",
                              text: "Cerró la puerta.", sourceHash: "not-the-current-hash"),
            forDocId: harness.doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: harness.projectURL)
        let gathered = await harness.environment.briefReader(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered)
        XCTAssertNil(inputs.paragraphs[1].translation, "stale is not the edition either")
        await harness.documentStore.close()
    }

    /// Spec §2: stale and missing are gaps the reader is briefed with `nil`
    /// for. A **verbatim** record is neither — `TranslationWritePipeline.perform`
    /// (~line 130) writes the paragraph's own source text as the record's
    /// `text` when `verbatim: true`, so that text IS the edition, and the
    /// reader must see it as a real translation rather than a hole.
    func test_aVerbatimParagraphReachesTheReaderAsTheEditionsOwnText() async throws {
        let harness = try await makeHarness()
        let id = harness.doc.sequence[2]
        _ = try TranslationWritePipeline.perform(
            entries: [.init(paragraphId: id, text: nil, verbatim: true, delete: nil)],
            language: "es", documentId: harness.doc.docId,
            state: (harness.doc.sequence, harness.doc.paragraphs, harness.projectURL),
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current))
        let gathered = await harness.environment.briefReader(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered)
        XCTAssertEqual(inputs.paragraphs[2].translation, harness.doc.paragraphs[id],
                       "a verbatim record's text is the source paragraph itself, not a gap")
        await harness.documentStore.close()
    }

    // MARK: - The collator's gather

    func test_theCollatorIsBriefedWithPairsDirectivesAndTheGlossary() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la niebla.")
        let id = harness.doc.sequence[0]
        // The one door (`TranslatorEnvironmentTests` seeds a directive the
        // same way): a translator's note ruled into this edition's brief.
        try await RulingPerformer.rule(
            Ruling.directiveText(paragraphId: id, "keep the fog literal"),
            provenance: Ruling.Provenance.translatorsNote,
            kind: .editionBrief("es"), forScope: .project,
            store: harness.store, world: nil)
        let gathered = await harness.environment.briefCollator(harness.doc.docId, "es")
        let inputs = try XCTUnwrap(gathered)
        XCTAssertEqual(inputs.collatorName, "Borges")
        XCTAssertEqual(inputs.authorLanguage, "English")
        XCTAssertEqual(inputs.pairs.map(\.paragraphId), harness.doc.sequence)
        XCTAssertEqual(inputs.pairs[0].sourceText, "The fog came in.")
        XCTAssertEqual(inputs.pairs[0].translation, "Llegó la niebla.")
        XCTAssertEqual(inputs.pairs[0].directives, ["keep the fog literal"])
        XCTAssertNil(inputs.pairs[1].translation)
        XCTAssertNotNil(inputs.editionBriefText)
        await harness.documentStore.close()
    }

    // MARK: - Identities

    func test_identitiesAreMintedOnceAndFoundThereafter() async throws {
        let harness = try await makeHarness()
        let first = try await harness.environment.readerIdentity("es")
        let second = try await harness.environment.readerIdentity("es")
        XCTAssertEqual(first.name, "Ocampo")
        XCTAssertEqual(first.roleId, second.roleId)
        XCTAssertEqual(harness.store.manifest.productionRoles.filter {
            if case .reader = $0.role { return true } else { return false }
        }.count, 1)
        let collator = try await harness.environment.collatorIdentity("es")
        XCTAssertEqual(collator.name, "Borges")
        XCTAssertEqual(harness.environment.translatorName("es"), "Cortázar")
        await harness.documentStore.close()
    }

    // MARK: - The declined mint

    func test_aDeclinedNoteMintsAQueryCarryingTheTranslatorsReason() async throws {
        let harness = try await makeHarness()
        let id = harness.doc.sequence[0]
        let note = TranslatorBriefing.FixNote(
            id: "n1", paragraphId: id, author: "Ocampo", kind: "rhythm",
            severity: "minor", text: "Limps.")
        let ids = await harness.environment.mintDeclinedQueries(.init(
            docId: harness.doc.docId, language: "es", translatorName: "Cortázar",
            items: [.init(note: note, reason: "Deliberate.", authorRoleId: "role-reader-es")]))

        let annotation = try XCTUnwrap(
            harness.doc.annotations(filter: AnnotationFilter(statuses: nil)).first)
        XCTAssertEqual(ids, ["n1": annotation.id])
        XCTAssertEqual(annotation.kind, .query)
        XCTAssertEqual(annotation.paragraphId, id)
        XCTAssertEqual(annotation.language, "es")
        XCTAssertEqual(annotation.author?.displayName, "Ocampo")
        XCTAssertEqual(annotation.body,
                       TranslationPipeline.Environment.declinedBody(
                           note: note, reason: "Deliberate.", translatorName: "Cortázar"))
        XCTAssertTrue(annotation.body.hasPrefix("rhythm · minor\n"), "kind/severity first line")
        XCTAssertTrue(annotation.body.hasSuffix("Cortázar declined: Deliberate."))
        await harness.documentStore.close()
    }

    /// A note the author REJECTS is never briefed again: the next translate
    /// gather's open queries no longer carry it (spec §6).
    func test_aRejectedDeclinedNoteIsAbsentFromTheNextBriefing() async throws {
        let harness = try await makeHarness()
        let id = harness.doc.sequence[0]
        let note = TranslatorBriefing.FixNote(id: "n1", paragraphId: id, author: "Ocampo",
                                              kind: "rhythm", severity: nil, text: "Limps.")
        let ids = await harness.environment.mintDeclinedQueries(.init(
            docId: harness.doc.docId, language: "es", translatorName: "Cortázar",
            items: [.init(note: note, reason: "Deliberate.", authorRoleId: "r")]))
        let (openBefore, _) = TranslatorOrchestrator.Environment.languageQueries(
            docId: harness.doc.docId, language: "es", documentStore: harness.documentStore)
        XCTAssertEqual(openBefore.count, 1)
        let mintedId = try XCTUnwrap(ids["n1"])
        try await harness.doc.rejectAnnotation(id: mintedId,
                                               userResponse: "Translator's right.")
        let (openAfter, _) = TranslatorOrchestrator.Environment.languageQueries(
            docId: harness.doc.docId, language: "es", documentStore: harness.documentStore)
        XCTAssertTrue(openAfter.isEmpty)
        await harness.documentStore.close()
    }

    // MARK: - Rounds, the author's language, the cold runner

    func test_roundsReachTheStoreAndNumbersComeFromIt() async throws {
        let harness = try await makeHarness()
        XCTAssertEqual(harness.environment.nextRoundNumber("es"), 1)
        let round = TranslationRound(number: 1, language: "es", docId: harness.doc.docId,
                                     startedAt: Date())
        harness.environment.saveRound(round)
        XCTAssertEqual(TranslationRoundStore(projectURL: harness.projectURL)
                           .latest(language: "es", docId: harness.doc.docId)?.number, 1)
        XCTAssertEqual(harness.environment.nextRoundNumber("es"), 2)
        await harness.documentStore.close()
    }

    func test_theAuthorsLanguageIsTheBooksOwnResolvedThroughTheImprint() {
        XCTAssertEqual(TranslationPipeline.Environment.languageName(tag: "en"), "English")
        XCTAssertEqual(TranslationPipeline.Environment.languageName(tag: "es"), "Spanish")
    }

    func test_theColdCallAndCancelReachTheWindowsRunner() async throws {
        // A ColdCall with no factory refuses with its own detail — the closure
        // is a pass-through and this pins that it IS the window's runner.
        let harness = try await makeHarness()
        let event = await harness.environment.coldCall("hi", nil, "m")
        guard case .failed(let failure) = event else { return XCTFail("an unwired runner refuses") }
        XCTAssertEqual(failure, .sessionDied(detail: ColdCall.notWiredDetail))
        harness.environment.cancelColdCall()
        harness.environment.cancelTranslator()
        await harness.documentStore.close()
    }
}
