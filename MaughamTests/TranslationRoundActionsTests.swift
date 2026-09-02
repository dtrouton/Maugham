import XCTest
import MaughamCore
@testable import Maugham

/// **The round report's nine verbs, against a real project** (translation
/// pipeline P4 Task 4).
///
/// `QueryRulingTests`' discipline one surface over: every assertion is made at
/// the thing the verb was supposed to change — the edition brief's own
/// `## Rulings` stratum, the annotation projection, the round ledger on disk —
/// and never at the `Outcome` alone. An `Outcome.done` that wrote nothing is
/// exactly the failure these verbs exist to make impossible, and it agrees with
/// itself perfectly.
@MainActor
final class TranslationRoundActionsTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
    }

    /// `TranslationPipelineEnvironmentTests.makeHarness`'s project on disk (it
    /// is `private` there) — one three-paragraph novel chapter, open in a
    /// `DocumentStore`, because a real `Document.load` is what mints the `¶id`s
    /// every directive here is anchored to — plus the publish config the desk's
    /// derivations expect.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundActions-\(UUID().uuidString)")
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

        return Harness(projectURL: root, store: projectStore,
                       documentStore: documentStore, doc: doc)
    }

    private func roundFor(_ h: Harness, number: Int) -> TranslationRound {
        TranslationRound(number: number, language: "es",
                         docId: h.doc.docId, startedAt: Date())
    }

    private func actionsFor(_ h: Harness) -> TranslationRoundActions {
        TranslationRoundActions.production(
            store: h.store, documentStore: h.documentStore,
            projectURL: h.projectURL, world: nil)
    }

    /// The Spanish edition brief's rulings, read back through the store's own
    /// one spelling of "what a statement says".
    private func briefRulings(_ h: Harness) throws -> [Ruling] {
        guard let statement = h.store.statement(kind: .editionBrief("es"), scope: .project)
        else { return [] }
        return RulingsSection.parse(try h.store.statementText(of: statement)).rulings
    }

    private func storedRound(_ h: Harness) -> TranslationRound? {
        TranslationRoundStore(projectURL: h.projectURL).latest(language: "es", docId: nil)
    }

    /// A declined note's query, minted the way `mintDeclined` mints one.
    private func mintQuery(_ h: Harness, paragraph index: Int,
                           body: String) async throws -> Annotation {
        let id = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.doc.sequence[index], body: body,
            toolArgs: TranslatorOrchestrator.Environment.queryToolArgs(
                language: "es", roleId: "r"),
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Ocampo"),
            announcing: false)
        h.doc.announceAnnotationsChanged()
        return try XCTUnwrap(
            h.doc.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == id },
            "the query did not project")
    }

    private func annotation(_ h: Harness, _ id: String) -> Annotation? {
        h.doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    private func departure(id: String, paragraphId: String) -> TranslationRound.DepartureRecord {
        .init(id: id, paragraphId: paragraphId, verdict: "holds",
              kind: "rendering", note: "Split.", gloss: "g")
    }

    // MARK: - Fine

    /// **The author's disposition is recorded BESIDE the translator's fact,
    /// never over it.** Fine is offered on every row, an addressed departure
    /// included, so a dismissal written into `outcome` would erase that row's
    /// before/after — permanently, on one click, with nothing red. This is the
    /// test that would go red if it were.
    func test_fineOnAnAddressedDepartureKeepsItsRewrite() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 1)
        let rewrite = TranslationRound.Rewrite(
            beforeRecordId: "r1", before: "Lleg\u{00f3} la niebla.",
            afterRecordId: "r2", after: "La niebla lleg\u{00f3}.")
        var addressed = departure(id: "d1", paragraphId: h.doc.sequence[0])
        addressed.outcome = .addressed(rewrite)
        round.departures = [addressed]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)

        guard case .done(let updated?, _) = await actionsFor(h).dismiss(round, "d1") else {
            return XCTFail("Fine did not answer .done with the changed round")
        }
        XCTAssertEqual(updated.departures[0].dismissed, true)
        XCTAssertEqual(updated.departures[0].outcome, .addressed(rewrite),
                       "the translator's own fact was overwritten by the author's")
        let stored = try XCTUnwrap(storedRound(h), "the ledger on disk does not agree")
        XCTAssertEqual(stored.departures[0].dismissed, true)
        XCTAssertEqual(stored.departures[0].outcome, .addressed(rewrite))
        XCTAssertTrue(h.doc.annotations(filter: AnnotationFilter()).isEmpty,
                      "Fine wrote an annotation; it is a record change and nothing else")
        await h.documentStore.close()
    }

    /// The ordinary case — a `holds` departure with nothing the translator did
    /// — records the same disposition and still leaves `outcome` alone.
    func test_fineRecordsDismissedOnTheRoundAndTouchesNoAnnotation() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 1)
        round.departures = [departure(id: "d1", paragraphId: h.doc.sequence[0])]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)

        guard case .done(let updated?, _) = await actionsFor(h).dismiss(round, "d1") else {
            return XCTFail("Fine did not answer .done with the changed round")
        }
        XCTAssertEqual(updated.departures[0].dismissed, true)
        XCTAssertNil(updated.departures[0].outcome)
        XCTAssertEqual(storedRound(h)?.departures[0].dismissed, true,
                       "the ledger on disk does not agree")
        XCTAssertNil(storedRound(h)?.departures[0].outcome)
        XCTAssertTrue(h.doc.annotations(filter: AnnotationFilter()).isEmpty,
                      "Fine wrote an annotation; it is a record change and nothing else")
        await h.documentStore.close()
    }

    /// A departure id the round does not carry — the row is gone, and the verb
    /// says so rather than writing a record it invented.
    func test_fineOverAMissingRowIsRefusedInWords() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 1)
        round.departures = [departure(id: "d1", paragraphId: h.doc.sequence[0])]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)

        guard case .refused(let sentence) = await actionsFor(h).dismiss(round, "nope") else {
            return XCTFail("Fine acted on a departure that is not in the round")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.rowGone)
        await h.documentStore.close()
    }

    // MARK: - Keep mine

    func test_keepMineMintsADirectiveInTheChosenHomeWithTheRoundsProvenance() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 2)
        let pid = h.doc.sequence[1]
        let actions = actionsFor(h)

        guard case .done = await actions.keepMine(
            round, pid, "keep the repetition", .edition("es")) else {
            return XCTFail("Keep mine was refused over the edition brief")
        }
        let rulings = try briefRulings(h)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].directive?.paragraphId, pid)
        XCTAssertEqual(rulings[0].directive?.text, "keep the repetition")
        XCTAssertEqual(rulings[0].provenance,
                       TranslationRoundReport.provenance(round: round, verb: "keep mine"))

        guard case .done = await actions.keepMine(
            round, pid, "one sentence", .everyEdition) else {
            return XCTFail("Keep mine was refused over the piece's own intent")
        }
        let intent = try XCTUnwrap(
            h.store.statement(kind: .intent, scope: .document(h.doc.docId)),
            "every-edition did not reach the piece's craft intent")
        XCTAssertEqual(
            RulingsSection.parse(try h.store.statementText(of: intent))
                .rulings.first?.directive?.text,
            "one sentence")
        // …and the every-edition note went ONLY there: a directive about the
        // English filed in the Spanish brief as well would be one decision the
        // writer made once and would have to revoke twice.
        XCTAssertEqual(try briefRulings(h).count, 1,
                       "the every-edition note also landed in the edition brief")
        await h.documentStore.close()
    }

    /// The translator's-note voice, because it is the same act reached from a
    /// second surface: an instruction with no words says nothing to a
    /// translator, so nothing is written.
    func test_keepMineWithNoInstructionIsRefusedAndWritesNothing() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 2)

        guard case .refused(let sentence) = await actionsFor(h).keepMine(
            round, h.doc.sequence[0], "   ", .edition("es")) else {
            return XCTFail("an empty translator's note was written")
        }
        XCTAssertEqual(sentence, TranslatorsNoteCopy.emptyRefusal)
        XCTAssertNil(h.store.statement(kind: .editionBrief("es"), scope: .project),
                     "a refusal minted the brief")
        await h.documentStore.close()
    }

    // MARK: - Make it a rule

    func test_makeItARuleLandsAGeneralRulingInTheEditionBrief() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 3)

        guard case .done = await actionsFor(h).makeRule(
            round, "Never soften an oath.") else {
            return XCTFail("Make it a rule was refused")
        }
        let rulings = try briefRulings(h)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].text, "Never soften an oath.")
        XCTAssertNil(rulings[0].directive,
                     "a general rule is not anchored to a paragraph")
        XCTAssertEqual(rulings[0].provenance,
                       TranslationRoundReport.provenance(round: round, verb: "make it a rule"))
        XCTAssertNil(h.store.statement(kind: .intent, scope: .document(h.doc.docId)),
                     "an edition's rule reached the book's own intent")
        await h.documentStore.close()
    }

    func test_makeItARuleWithNoWordsIsRefused() async throws {
        let h = try await makeHarness()
        guard case .refused = await actionsFor(h).makeRule(roundFor(h, number: 3), "  ") else {
            return XCTFail("an empty rule was written")
        }
        XCTAssertNil(h.store.statement(kind: .editionBrief("es"), scope: .project))
        await h.documentStore.close()
    }

    // MARK: - Translator's right

    func test_translatorsRightRejectsTheDeclinedQuery() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 4)
        let query = try await mintQuery(h, paragraph: 0, body: "Split, for the rhythm.")

        guard case .done(let updated, _) = await actionsFor(h).translatorsRight(
            round, query.id) else {
            return XCTFail("Translator's right was refused")
        }
        XCTAssertNil(updated, "siding with the translator changes no record")
        XCTAssertEqual(annotation(h, query.id)?.status, .rejected)
        XCTAssertEqual(annotation(h, query.id)?.userResponse,
                       TranslationRoundReport.translatorsRightTitle)
        XCTAssertTrue(try briefRulings(h).isEmpty,
                      "siding with the translator wrote doctrine")
        await h.documentStore.close()
    }

    // MARK: - Reader's right

    func test_readersRightAcceptsTheQueryAndMintsADirectiveQuotingTheNote() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 5)
        let pid = h.doc.sequence[2]
        let query = try await mintQuery(h, paragraph: 2, body: "Too flat in Spanish.")

        guard case .done = await actionsFor(h).readersRight(
            round, query.id, pid, "Too flat in Spanish.",
            TranslationRoundReport.readersRightTitle) else {
            return XCTFail("Reader's right was refused")
        }
        XCTAssertEqual(annotation(h, query.id)?.status, .accepted)
        XCTAssertEqual(annotation(h, query.id)?.userResponse,
                       TranslationRoundReport.readersRightTitle)
        let rulings = try briefRulings(h)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].directive?.paragraphId, pid)
        XCTAssertEqual(rulings[0].directive?.text, "Too flat in Spanish.")
        XCTAssertEqual(
            rulings[0].provenance,
            TranslationRoundReport.provenance(
                round: round,
                verb: TranslationRoundReport.readersRightTitle.lowercased()))
        await h.documentStore.close()
    }

    /// A declined note that minted no query still becomes doctrine — the
    /// directive is the decision, and the reply is only where a thread exists
    /// to post it on.
    func test_readersRightWithNoQueryStillWritesTheDirective() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 5)
        let pid = h.doc.sequence[0]

        guard case .done = await actionsFor(h).readersRight(
            round, "", pid, "Keep the fog literal.",
            TranslationRoundReport.readersRightTitle) else {
            return XCTFail("Reader's right refused a note with no query")
        }
        XCTAssertEqual(try briefRulings(h).first?.directive?.text, "Keep the fog literal.")
        await h.documentStore.close()
    }

    /// **A declined DEPARTURE is the collator's disagreement, not the
    /// reader's** — the row draws "Collator's right", and both records this
    /// verb writes have to say the same thing. Before the verb carried its own
    /// title, a writer siding with the collator settled the thread with
    /// "Reader's right" and filed the doctrine under "reader's right", naming
    /// somebody who was not in the argument.
    func test_collatorsRightRecordsTheCollatorOnBothRecords() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 5)
        let pid = h.doc.sequence[1]
        let query = try await mintQuery(h, paragraph: 1, body: "Drifts from the original.")

        guard case .done = await actionsFor(h).readersRight(
            round, query.id, pid, "Drifts from the original.",
            TranslationRoundReport.collatorsRightTitle) else {
            return XCTFail("Collator's right was refused")
        }
        XCTAssertEqual(annotation(h, query.id)?.userResponse,
                       TranslationRoundReport.collatorsRightTitle)
        XCTAssertEqual(try briefRulings(h).first?.provenance,
                       TranslationRoundReport.provenance(round: round,
                                                         verb: "collator\u{2019}s right"))
        await h.documentStore.close()
    }

    // MARK: - Glossary

    func test_adoptMintsOneGlossaryRulingAndMarksTheProposalAdopted() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 6)
        round.glossaryProposals = [
            .init(term: "fog", rendering: "niebla", reason: "consistency", adopted: false)]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)

        guard case .done(let updated?, let sentence) = await actionsFor(h).adopt(round, 0) else {
            return XCTFail("Adopt did not answer .done with the changed round")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.adoptedLine)
        XCTAssertTrue(updated.glossaryProposals[0].adopted)
        XCTAssertEqual(storedRound(h)?.glossaryProposals[0].adopted, true,
                       "the ledger on disk does not agree")
        let rulings = try briefRulings(h)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].text,
                       Ruling.glossaryText(term: "fog", rendering: "niebla",
                                           note: "consistency"))
        XCTAssertEqual(rulings[0].glossary?.term, "fog")
        XCTAssertEqual(rulings[0].glossary?.rendering, "niebla")
        XCTAssertEqual(rulings[0].provenance, Ruling.Provenance.glossary)
        await h.documentStore.close()
    }

    /// P1's carry-forward: a proposal with an empty half is not a glossary
    /// entry, and adopting one would write `«» → «niebla»` into the doctrine
    /// every later round is checked against.
    func test_adoptRefusesAnEmptyTermAndMintsNothing() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 6)
        round.glossaryProposals = [
            .init(term: "  ", rendering: "niebla", reason: "consistency", adopted: false)]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)

        guard case .refused(let sentence) = await actionsFor(h).adopt(round, 0) else {
            return XCTFail("an empty glossary term was adopted")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.emptyGlossaryTerm)
        XCTAssertNil(h.store.statement(kind: .editionBrief("es"), scope: .project))
        XCTAssertEqual(storedRound(h)?.glossaryProposals[0].adopted, false)
        await h.documentStore.close()
    }

    func test_skipMarksTheProposalSkippedAndWritesNothingElse() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 7)
        round.glossaryProposals = [
            .init(term: "fog", rendering: "niebla", reason: "consistency", adopted: false)]
        try TranslationRoundStore(projectURL: h.projectURL).append(round)

        guard case .done(let updated?, let sentence) = await actionsFor(h).skip(round, 0) else {
            return XCTFail("Skip did not answer .done with the changed round")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.skippedLine)
        XCTAssertEqual(updated.glossaryProposals[0].skipped, true)
        XCTAssertFalse(updated.glossaryProposals[0].adopted)
        XCTAssertEqual(storedRound(h)?.glossaryProposals[0].skipped, true)
        XCTAssertNil(h.store.statement(kind: .editionBrief("es"), scope: .project),
                     "Skip wrote doctrine")
        await h.documentStore.close()
    }

    func test_skipOverAnIndexTheRoundDoesNotHaveIsRefused() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 7)
        guard case .refused(let sentence) = await actionsFor(h).skip(round, 3) else {
            return XCTFail("Skip acted on a proposal that is not in the round")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.rowGone)
        await h.documentStore.close()
    }

    // MARK: - Answering a question

    /// An empty reply would settle the translator's question with nothing in
    /// it, and `acceptAnnotation` would take it without complaint.
    func test_anEmptyReplyIsRefusedAndSettlesNothing() async throws {
        let h = try await makeHarness()
        let query = try await mintQuery(h, paragraph: 0, body: "t\u{fa} or usted?")

        guard case .refused(let sentence) = await actionsFor(h).answer(
            roundFor(h, number: 8), query, "   \n ") else {
            return XCTFail("an empty reply settled the question")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.emptyReply)
        XCTAssertEqual(annotation(h, query.id)?.status, .open)
        await h.documentStore.close()
    }

    func test_answerRepliesAndAnswerAsRulingFilesTheRulingFirst() async throws {
        let h = try await makeHarness()
        let round = roundFor(h, number: 8)
        let actions = actionsFor(h)

        // A plain reply settles the thread and writes no doctrine.
        let plain = try await mintQuery(h, paragraph: 0, body: "tú or usted?")
        guard case .done(let unchanged, _) = await actions.answer(
            round, plain, "Usted throughout.") else {
            return XCTFail("Answer was refused")
        }
        XCTAssertNil(unchanged, "a reply changes no record")
        XCTAssertEqual(annotation(h, plain.id)?.status, .accepted)
        XCTAssertEqual(annotation(h, plain.id)?.userResponse, "Usted throughout.")
        XCTAssertTrue(try briefRulings(h).isEmpty, "a plain reply wrote doctrine")

        // …and the same answer as a ruling is `QueryRuling`'s two records.
        let ruled = try await mintQuery(h, paragraph: 1, body: "Keep the door shut?")
        guard case .done(_, let sentence) = await actions.answerAsRuling(
            round, ruled, "Shut, and never latched.") else {
            return XCTFail("Answer as ruling was refused")
        }
        XCTAssertEqual(sentence, QueryRuling.confirmation(language: "es"))
        XCTAssertEqual(annotation(h, ruled.id)?.status, .accepted)
        XCTAssertEqual(annotation(h, ruled.id)?.userResponse, "Shut, and never latched.")
        let rulings = try briefRulings(h)
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].text, "Shut, and never latched.")
        XCTAssertEqual(rulings[0].provenance, QueryRuling.provenance(for: ruled))
        await h.documentStore.close()
    }

    // MARK: - A round the ring no longer holds

    func test_averbOnARoundThatAgedOutIsRefusedInWords() async throws {
        let h = try await makeHarness()
        var round = roundFor(h, number: 11)
        round.departures = [departure(id: "d1", paragraphId: h.doc.sequence[0])]
        // Never appended: the ring has no such round to rewrite.

        guard case .refused(let sentence) = await actionsFor(h).dismiss(round, "d1") else {
            return XCTFail("Fine rewrote a round the ledger does not hold")
        }
        XCTAssertTrue(sentence.contains("aged out"),
                      "the refusal does not say what happened: \(sentence)")
        await h.documentStore.close()
    }

}
