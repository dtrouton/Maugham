import XCTest
import MaughamCore
@testable import Maugham

/// **The two spot-checks, and the line neither of them crosses** (translation
/// pipeline spec §9, §12 — P4 Task 6).
///
/// Gloss and Ask the collator are the writer's two questions about one
/// paragraph: *what does this now say?* and *does it still say what I wrote?*
/// Each is one keystroke, one cold call, one answer on screen — and **neither
/// mints anything**. What the author does with the answer is a separate act
/// they press: Keep mine writes a translator's note, Make it a rule writes a
/// ruling, and until one of those is pressed a spot-check has changed nothing
/// on disk. The last test in this file is that property, asserted over a real
/// project.
@MainActor
final class SpotCheckTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
    }

    /// `TranslationPipelineEnvironmentTests.makeHarness`'s project: one
    /// three-paragraph chapter open in a `DocumentStore` (a real `Document
    /// .load`, because that is what mints the `¶id`s), and the publish config
    /// whose `metadata.language` is the book's own — the author's language every
    /// briefing's role frame is written in.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path = "manuscript/c1.md"
        try "The fog came in.\n\nShe closed the door.\n\nNobody spoke."
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "Spot", author: "A",
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
            PublishConfig(metadata: .init(title: "Spot", author: "A", language: "en")))

        return Harness(projectURL: root, store: projectStore,
                       documentStore: documentStore, doc: doc)
    }

    private func seed(_ harness: Harness, paragraph index: Int, text: String) throws {
        let id = harness.doc.sequence[index]
        _ = try TranslationWritePipeline.perform(
            entries: [.init(paragraphId: id, text: text, verbatim: nil, delete: nil)],
            language: "es", documentId: harness.doc.docId,
            state: (harness.doc.sequence, harness.doc.paragraphs, harness.projectURL),
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current))
    }

    private func entries(_ texts: [(String, String)]) -> [TranslationBadgeLayout.Entry] {
        texts.map { .init(paragraphId: $0.0, text: $0.1, status: .fresh) }
    }

    // MARK: - Neighbours off the badge entries

    func test_aParagraphInTheMiddleHasBothNeighbours() {
        let context = SpotCheck.neighbours(
            of: "bbbb",
            in: entries([("aaaa", "Llegó la niebla."), ("bbbb", "Cerró la puerta."),
                         ("cccc", "Nadie habló.")]))

        XCTAssertEqual(context?.before, "Llegó la niebla.")
        XCTAssertEqual(context?.paragraph, "Cerró la puerta.")
        XCTAssertEqual(context?.after, "Nadie habló.")
    }

    func test_theFirstParagraphHasNothingBeforeIt() {
        let context = SpotCheck.neighbours(
            of: "aaaa",
            in: entries([("aaaa", "Llegó la niebla."), ("bbbb", "Cerró la puerta.")]))

        XCTAssertNil(context?.before)
        XCTAssertEqual(context?.paragraph, "Llegó la niebla.")
        XCTAssertEqual(context?.after, "Cerró la puerta.")
    }

    func test_theLastParagraphHasNothingAfterIt() {
        let context = SpotCheck.neighbours(
            of: "bbbb",
            in: entries([("aaaa", "Llegó la niebla."), ("bbbb", "Cerró la puerta.")]))

        XCTAssertEqual(context?.before, "Llegó la niebla.")
        XCTAssertNil(context?.after)
    }

    func test_anIdTheSurfaceDoesNotHoldHasNoNeighbours() {
        XCTAssertNil(SpotCheck.neighbours(of: "zzzz", in: entries([("aaaa", "Llegó la niebla.")])))
    }

    // MARK: - Narrowing the collator's briefing

    private func wholeBriefing() -> CollatorBriefing.Inputs {
        CollatorBriefing.Inputs(
            collatorName: "Ocampo", language: "es", authorLanguage: "English",
            roleBrief: "Hold the two texts side by side.",
            craftIntentText: "Plain sentences, no ornament.",
            editionBriefText: "**Texture** \u{2014} fluent Spanish.",
            glossary: [GlossaryEntry(term: "the fog", rendering: "la niebla", note: nil)],
            pairs: (0..<5).map { index in
                .init(paragraphId: "p\(index)", sourceText: "Source \(index).",
                      translation: "Traducción \(index).",
                      directives: ["Keep the repetition in \(index)."])
            })
    }

    func test_narrowingKeepsThePairAndOneNeighbourEachSideInOrder() throws {
        let narrowed = try XCTUnwrap(SpotCheck.narrow(wholeBriefing(), to: "p2"))

        XCTAssertEqual(narrowed.pairs.map(\.paragraphId), ["p1", "p2", "p3"])
    }

    func test_narrowingAtTheEdgesTakesWhatIsThere() throws {
        XCTAssertEqual(try XCTUnwrap(SpotCheck.narrow(wholeBriefing(), to: "p0")).pairs
                        .map(\.paragraphId), ["p0", "p1"])
        XCTAssertEqual(try XCTUnwrap(SpotCheck.narrow(wholeBriefing(), to: "p4")).pairs
                        .map(\.paragraphId), ["p3", "p4"])
    }

    /// The writer's own standards are not narrowed with the text: a directive
    /// or a glossary entry dropped here is a spot-check judging the paragraph
    /// against a doctrine the author never relaxed.
    func test_narrowingKeepsTheDoctrineWhole() throws {
        let whole = wholeBriefing()
        let narrowed = try XCTUnwrap(SpotCheck.narrow(whole, to: "p2"))

        XCTAssertEqual(narrowed.collatorName, whole.collatorName)
        XCTAssertEqual(narrowed.language, whole.language)
        XCTAssertEqual(narrowed.authorLanguage, whole.authorLanguage)
        XCTAssertEqual(narrowed.roleBrief, whole.roleBrief)
        XCTAssertEqual(narrowed.craftIntentText, whole.craftIntentText)
        XCTAssertEqual(narrowed.editionBriefText, whole.editionBriefText)
        XCTAssertEqual(narrowed.glossary, whole.glossary)
        XCTAssertEqual(narrowed.pairs.map(\.directives),
                       [["Keep the repetition in 1."], ["Keep the repetition in 2."],
                        ["Keep the repetition in 3."]])
    }

    /// The parse gate travels with the narrowing: a departure about a paragraph
    /// this call did not show is not a departure about anything.
    func test_theBriefedIdsAreTheNarrowedSet() throws {
        let narrowed = try XCTUnwrap(SpotCheck.narrow(wholeBriefing(), to: "p2"))

        XCTAssertEqual(narrowed.briefedParagraphIds, ["p1", "p2", "p3"])
    }

    func test_anIdTheBriefingDoesNotHoldNarrowsToNothing() {
        XCTAssertNil(SpotCheck.narrow(wholeBriefing(), to: "zzzz"))
    }

    // MARK: - Gloss

    func test_aGlossComesBackAnswered() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = { $0.nextEvent = .resultText("{\"gloss\":\"She closed the door.\"}") }

        let outcome = await SpotCheck.gloss(
            paragraphId: "bbbb", language: "es",
            entries: entries([("aaaa", "Llegó la niebla."), ("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .answered("She closed the door."))
        await harness.documentStore.close()
    }

    /// The cold preamble is the one governing every cold session, and the
    /// paragraph being glossed is what the message is about.
    func test_theCallCarriesTheColdPreambleAndTheParagraph() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()

        _ = await SpotCheck.gloss(
            paragraphId: "bbbb", language: "es",
            entries: entries([("aaaa", "Llegó la niebla."), ("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        let send = try XCTUnwrap(factory.made.first?.sends.first)
        XCTAssertEqual(send.preamble, TranslationPipeline.coldPreamble)
        XCTAssertTrue(send.message.contains("Cerró la puerta."))
        XCTAssertFalse(send.message.contains("She closed the door."),
                       "the source never reaches a gloss")
        await harness.documentStore.close()
    }

    func test_aDeadSessionIsRefusedInTheRoundsOwnWords() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = { $0.nextEvent = .failed(.timedOut) }

        let outcome = await SpotCheck.gloss(
            paragraphId: "bbbb", language: "es",
            entries: entries([("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .refused(
            RoundNarrative.failureCopy(.timedOut, session: .translation)))
        await harness.documentStore.close()
    }

    func test_anUnreadableAnswerIsRefused() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = { $0.nextEvent = .resultText("It says she closed the door.") }

        let outcome = await SpotCheck.gloss(
            paragraphId: "bbbb", language: "es",
            entries: entries([("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .refused(
            RoundNarrative.failureCopy(.unusableOutput, session: .translation)))
        await harness.documentStore.close()
    }

    /// **A turn that resolved on `started` produced no answer at all**, and the
    /// refusal must not tell the writer their answer was unreadable — there was
    /// nothing to read, and they would go looking for output that does not
    /// exist.
    func test_aTurnThatOnlyStartedIsRefusedAsASessionThatNeverAnswered() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = { $0.nextEvent = .started }

        let outcome = await SpotCheck.gloss(
            paragraphId: "bbbb", language: "es",
            entries: entries([("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .refused(RoundNarrative.failureCopy(
            .sessionDied(detail: SpotCheck.noAnswerDetail), session: .translation)))
        XCTAssertNotEqual(outcome, .refused(RoundNarrative.failureCopy(
            .unusableOutput, session: .translation)),
            "nothing came back \u{2014} that is not an unreadable answer")
        await harness.documentStore.close()
    }

    /// One cold call at a time is `ColdCall`'s own rule; the spot-check says so
    /// in words the writer can act on, and spawns nothing.
    func test_aCallWhileTheRoundsLegIsOutIsRefusedAndSpawnsNothing() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = { $0.nextEvent = nil }   // hold the turn open

        let held = Task { await coldCall.call(message: "a leg", preamble: nil, model: "sonnet") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        let outcome = await SpotCheck.gloss(
            paragraphId: "bbbb", language: "es",
            entries: entries([("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .refused(SpotCheck.busyRefusal))
        XCTAssertEqual(factory.made.count, 1, "the spot-check spawned nothing")

        factory.made[0].release(.resultText("{}"))
        _ = await held.value
        await harness.documentStore.close()
    }

    func test_aParagraphWithNoTranslationOnTheSurfaceIsRefused() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()

        let outcome = await SpotCheck.gloss(
            paragraphId: "zzzz", language: "es", entries: entries([("bbbb", "Cerró la puerta.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .refused(SpotCheck.noTranslationRefusal))
        XCTAssertTrue(factory.made.isEmpty)
        await harness.documentStore.close()
    }

    // MARK: - Ask the collator

    func test_theCollatorIsAskedAboutOneParagraphWithBothTextsAndItsNeighbour() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la niebla.")
        try seed(harness, paragraph: 1, text: "Cerró la puerta.")
        try seed(harness, paragraph: 2, text: "Nadie habló.")
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()

        _ = await SpotCheck.askTheCollator(
            paragraphId: harness.doc.sequence[0], docId: harness.doc.docId, language: "es",
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        let message = try XCTUnwrap(factory.made.first?.sends.first?.message)
        XCTAssertTrue(message.contains("The fog came in."), "the collator holds both texts")
        XCTAssertTrue(message.contains("Llegó la niebla."))
        XCTAssertTrue(message.contains("She closed the door."), "one neighbour")
        XCTAssertFalse(message.contains("Nobody spoke."), "and no further than one")
        XCTAssertFalse(message.contains("Nadie habló."))
        await harness.documentStore.close()
    }

    func test_aCollationComesBackParsed() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la bruma.")
        let id = harness.doc.sequence[0]
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = {
            $0.nextEvent = .resultText("""
                {"overall":{"text":"It holds, with one softening."},
                 "departures":[{"paragraph_id":"\(id)","verdict":"drifted","kind":"mistranslation",
                 "note":"\\"bruma\\" is haze, not fog.","gloss":"The haze came in."}]}
                """)
        }

        let outcome = await SpotCheck.askTheCollator(
            paragraphId: id, docId: harness.doc.docId, language: "es",
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        guard case .answered(let report) = outcome else {
            return XCTFail("expected a parsed collation, got \(outcome)")
        }
        XCTAssertEqual(report.overall, "It holds, with one softening.")
        XCTAssertEqual(report.departures.map(\.paragraphId), [id])
        XCTAssertEqual(report.departures.first?.gloss, "The haze came in.")
        await harness.documentStore.close()
    }

    func test_aParagraphWithNoCurrentTranslationCannotBeCollated() async throws {
        let harness = try await makeHarness()
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()

        let outcome = await SpotCheck.askTheCollator(
            paragraphId: harness.doc.sequence[0], docId: harness.doc.docId, language: "es",
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(outcome, .refused(SpotCheck.noTranslationRefusal))
        XCTAssertTrue(factory.made.isEmpty)
        await harness.documentStore.close()
    }

    // MARK: - Neither verb mints

    /// **Spec §12's line, over a real project.** A gloss and a collation both
    /// come back; nothing is on disk that was not there before — no ruling in
    /// any statement, no annotation on the document, no round in the ledger.
    /// The author's Keep mine / Make it a rule are what write, and neither was
    /// pressed.
    func test_neitherSpotCheckWritesAnything() async throws {
        let harness = try await makeHarness()
        try seed(harness, paragraph: 0, text: "Llegó la niebla.")
        let id = harness.doc.sequence[0]
        let statementsBefore = harness.store.manifest.statements.count
        let roundsBefore = TranslationRoundStore(projectURL: harness.projectURL)
            .rounds(language: "es").count
        let (coldCall, factory) = ColdCallSpyFactory.makeColdCall()
        factory.configure = {
            $0.nextEvent = .resultText("""
                {"gloss":"The fog came in.","overall":{"text":"It holds."},
                 "departures":[{"paragraph_id":"\(id)","verdict":"drifted","kind":"omission",
                 "note":"the clause is gone","gloss":"The fog came."}]}
                """)
        }

        _ = await SpotCheck.gloss(
            paragraphId: id, language: "es", entries: entries([(id, "Llegó la niebla.")]),
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")
        _ = await SpotCheck.askTheCollator(
            paragraphId: id, docId: harness.doc.docId, language: "es",
            store: harness.store, documentStore: harness.documentStore,
            projectURL: harness.projectURL, coldCall: coldCall, model: "sonnet")

        XCTAssertEqual(harness.store.manifest.statements.count, statementsBefore,
                       "a spot-check files no ruling")
        XCTAssertTrue(harness.doc.annotations(filter: AnnotationFilter(statuses: nil)).isEmpty,
                      "a spot-check mints no note")
        XCTAssertEqual(TranslationRoundStore(projectURL: harness.projectURL)
                        .rounds(language: "es").count, roundsBefore,
                       "a spot-check is not a round")
        await harness.documentStore.close()
    }
}
