import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A translator's question, answered once, recorded twice** (publish
/// department, Task 8).
///
/// The writer answers a language-tagged query in the queue or in the
/// translation pane, and the same sentence becomes two things: a dated ruling
/// under the edition brief's `## Rulings` — where the next round's briefing
/// reads it as doctrine — and the reply on the annotation's own thread, where
/// the translator's dispositions carry it. One act, two records.
///
/// Every assertion here goes through the real op log (the statement's, and the
/// document's annotation projection) rather than a returned preview, for
/// `RulingPerformerTests`' reason: a preview can agree with itself and be wrong.
@MainActor
final class QueryRulingTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let doc: Document
        let pid: String
    }

    private func makeHarness(prefix: String) async throws -> Harness {
        let (dir, docURL) = try makeTestProject(
            prefix: prefix, initialMd: "The doctor arrived late.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: dir)
        await store.wordCountPopulationTask?.value
        let pid = try XCTUnwrap(doc.sequence.first)
        return Harness(projectURL: dir, store: store, doc: doc, pid: pid)
    }

    /// A translator's anchored question, tagged with the edition it belongs to
    /// — the `toolArgs` shape `add_query` writes and `AnnotationDeriver`
    /// projects onto `Annotation.language`.
    private func addQuery(
        _ h: Harness, body: String, language: String?
    ) async throws -> Annotation {
        let args = language.map { #"{"language":"\#($0)"}"# }
        let id = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: body, toolArgs: args)
        return try XCTUnwrap(annotation(h, id), "the query did not project")
    }

    /// P2's whole-document translation question: `addAnnotation` refuses an
    /// anchorless `.query`, so it mints as a language-tagged craft note.
    private func addWholeDocumentQuestion(
        _ h: Harness, body: String, language: String
    ) async throws -> Annotation {
        let id = try await h.doc.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: body,
            toolArgs: #"{"language":"\#(language)"}"#)
        return try XCTUnwrap(annotation(h, id), "the craft note did not project")
    }

    /// Across ALL statuses — the default filter hides the very note an answer
    /// has just settled.
    private func annotation(_ h: Harness, _ id: String) -> Annotation? {
        h.doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// What a statement SAYS, derived from its op log alone — never read off
    /// the `.md` beside it as truth (tripwire 20).
    private func derivedText(
        of statement: Statement, in projectURL: URL
    ) async throws -> String {
        let ops = try await OpLogStore(projectURL: projectURL).load(docId: statement.id)
        let derived = Deriver.derive(ops: ops)
        return derived.sequence.compactMap { derived.paragraphs[$0] }.joined(separator: "\n\n")
    }

    private func briefText(_ h: Harness, language: String) async throws -> String {
        let statement = try XCTUnwrap(
            h.store.statement(kind: .editionBrief(language), scope: .project),
            "no \(language) edition brief exists")
        return try await derivedText(of: statement, in: h.projectURL)
    }

    // MARK: - The ruling half

    /// The headline: the answer lands under the brief for the language the
    /// query itself carries — the brief being minted by the act when the
    /// writer has never opened one.
    func test_theAnswerLandsAsARulingInThatLanguagesBrief() async throws {
        let h = try await makeHarness(prefix: "QR-Lands")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")

        let refusal = await QueryRuling.commit(
            "Usted throughout, except between the sisters.",
            answering: query, in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNil(refusal, "the answer was refused: \(refusal ?? "")")
        let brief = try await briefText(h, language: "es")
        XCTAssertTrue(brief.contains("## Rulings"),
                      "the answer did not open a rulings stratum:\n\(brief)")
        XCTAssertTrue(
            brief.contains("Usted throughout, except between the sisters."),
            "the writer's words are not in the brief:\n\(brief)")
    }

    /// The language is the QUERY's, not a picker's and not the book's own
    /// intent. A ruling about the Spanish edition filed under the craft intent
    /// would be checked against every language, silently.
    func test_theBooksOwnIntentIsNeverWhereThisLands() async throws {
        let h = try await makeHarness(prefix: "QR-NotIntent")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")

        _ = await QueryRuling.commit(
            "Usted throughout.", answering: query,
            in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNil(h.store.statement(kind: .intent, scope: .project),
                     "the answer minted the book's craft intent")
        XCTAssertNotNil(h.store.statement(kind: .editionBrief("es"), scope: .project),
                        "the es brief is not there")
    }

    /// The provenance is the strain-answer's shape: what it answered, quoted,
    /// so a later reader of the brief knows which question the line settles.
    func test_theRulingsProvenanceCarriesTheQuerysOwnWords() async throws {
        let h = try await makeHarness(prefix: "QR-Provenance")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")

        _ = await QueryRuling.commit(
            "Usted throughout.", answering: query,
            in: h.doc, store: h.store, undoManager: nil)

        let brief = try await briefText(h, language: "es")
        XCTAssertTrue(brief.contains("\u{00AB}tú or usted?\u{00BB}"),
                      "the query's own words are not quoted in the line:\n\(brief)")
    }

    /// An em-dash in the question cannot reach the line: `RulingsSection`
    /// splits an item on its RIGHT-MOST em-dash, so one inside the excerpt
    /// would move that split into the quote and cut the writer's own sentence
    /// off mid-word.
    func test_anEmDashInTheQuestionCannotBreakTheLinesSplit() async throws {
        let h = try await makeHarness(prefix: "QR-EmDash")
        let query = try await addQuery(
            h, body: "tú \u{2014} or usted?", language: "es")

        _ = await QueryRuling.commit(
            "Usted throughout.", answering: query,
            in: h.doc, store: h.store, undoManager: nil)

        let brief = try await briefText(h, language: "es")
        let ruling = try XCTUnwrap(RulingsSection.parse(brief).rulings.first)
        XCTAssertEqual(ruling.text, "Usted throughout.",
                       "the writer's sentence was cut by the excerpt's em-dash")
    }

    // MARK: - The reply half

    /// The same sentence is the reply on the thread — which is what puts it in
    /// the next briefing's dispositions.
    func test_theSameAnswerPostsAsTheReplyOnTheThread() async throws {
        let h = try await makeHarness(prefix: "QR-Reply")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")

        _ = await QueryRuling.commit(
            "Usted throughout.", answering: query,
            in: h.doc, store: h.store, undoManager: nil)

        let settled = try XCTUnwrap(annotation(h, query.id))
        XCTAssertEqual(settled.userResponse, "Usted throughout.",
                       "the answer is not the reply on the thread")
        XCTAssertEqual(settled.status, .accepted,
                       "the query is still open after being answered")
    }

    // MARK: - P2's whole-document questions

    /// A language-tagged craft note is the same question one anchor wider, and
    /// answers the same way.
    func test_aLanguageTaggedCraftNoteIsAnsweredTheSameWay() async throws {
        let h = try await makeHarness(prefix: "QR-CraftNote")
        let note = try await addWholeDocumentQuestion(
            h, body: "Register throughout?", language: "fr")

        let refusal = await QueryRuling.commit(
            "Vouvoiement throughout.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNil(refusal, "the answer was refused: \(refusal ?? "")")
        let brief = try await briefText(h, language: "fr")
        XCTAssertTrue(brief.contains("Vouvoiement throughout."),
                      "the craft note's answer is not in the fr brief:\n\(brief)")
        XCTAssertEqual(try XCTUnwrap(annotation(h, note.id)).userResponse,
                       "Vouvoiement throughout.")
    }

    // MARK: - Who is offered this at all

    /// An untagged note belongs to no edition, so there is no brief to rule
    /// into — the affordance is not drawn, rather than drawn and refusing.
    func test_anUntaggedQueryOffersNothing() async throws {
        let h = try await makeHarness(prefix: "QR-Untagged")
        let query = try await addQuery(h, body: "Is this ironic?", language: nil)

        XCTAssertNil(QueryRuling.language(of: query))
        XCTAssertFalse(QueryRuling.offersARuling(query))
    }

    /// A tagged query and a tagged craft note offer it; nothing else does,
    /// whatever it carries. The two other kinds are constructed directly
    /// WITH a language, which the deriver never projects onto them — the
    /// predicate has to be honest about kind rather than leaning on that.
    func test_onlyQueriesAndCraftNotesEverOfferIt() async throws {
        let h = try await makeHarness(prefix: "QR-Kinds")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")
        let note = try await addWholeDocumentQuestion(
            h, body: "Register?", language: "es")

        XCTAssertTrue(QueryRuling.offersARuling(query))
        XCTAssertTrue(QueryRuling.offersARuling(note))

        for kind in [AnnotationKind.comment, .suggestedChange] {
            let impostor = Annotation(
                id: "a-\(kind)", kind: kind, paragraphId: h.pid,
                body: "b", suggestedText: nil, priorText: nil,
                createdAt: Date(), createdBySession: nil,
                status: .open, userResponse: nil, resolvedAt: nil,
                isStale: false, language: "es")
            XCTAssertFalse(QueryRuling.offersARuling(impostor),
                           "\(kind) was offered a ruling")
        }
    }

    /// A settled note is not answered again — the affordance goes with the
    /// rest of the dispositions when the question is closed.
    func test_aSettledQuestionIsNotOfferedOneEither() async throws {
        let h = try await makeHarness(prefix: "QR-Settled")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")
        _ = await QueryRuling.commit(
            "Usted throughout.", answering: query,
            in: h.doc, store: h.store, undoManager: nil)

        let settled = try XCTUnwrap(annotation(h, query.id))
        XCTAssertFalse(QueryRuling.offersARuling(settled))
    }

    // MARK: - Refusal

    /// **Nothing is half-done.** The ruling is written first, so a refusal
    /// leaves the question open and answerable rather than settling a thread
    /// whose doctrine never landed.
    func test_anEmptyAnswerIsRefusedAndTheQuestionStaysOpen() async throws {
        let h = try await makeHarness(prefix: "QR-Empty")
        let query = try await addQuery(h, body: "tú or usted?", language: "es")

        let refusal = await QueryRuling.commit(
            "   \n ", answering: query, in: h.doc, store: h.store, undoManager: nil)

        XCTAssertEqual(refusal, RulingFailure.emptyRuling.errorDescription,
                       "the refusal did not speak in the performer's own words")
        XCTAssertNil(h.store.statement(kind: .editionBrief("es"), scope: .project),
                     "a refused answer left a brief behind")
        let untouched = try XCTUnwrap(annotation(h, query.id))
        XCTAssertEqual(untouched.status, .open)
        XCTAssertNil(untouched.userResponse)
    }

    /// A note with no edition cannot be committed even if a caller reaches
    /// past the affordance — and it says so rather than filing the answer
    /// somewhere it invented.
    func test_anUntaggedNoteIsRefusedRatherThanFiledSomewhereInvented() async throws {
        let h = try await makeHarness(prefix: "QR-UntaggedCommit")
        let query = try await addQuery(h, body: "Is this ironic?", language: nil)

        let refusal = await QueryRuling.commit(
            "Yes.", answering: query, in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNotNil(refusal, "an editionless answer was accepted")
        XCTAssertEqual(try XCTUnwrap(annotation(h, query.id)).status, .open)
    }

    // MARK: - What the writer is told before they commit

    /// The confirm affordance states BOTH destinations. A sentence naming only
    /// the brief would leave the writer expecting the translator's thread to
    /// still be open; one naming only the reply would hide the doctrine.
    func test_theConfirmSentenceNamesBothRecords() {
        let sentence = QueryRuling.confirmation(language: "es")
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("brief"),
                      "the brief is not named: \(sentence)")
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("repl"),
                      "the reply is not named: \(sentence)")
        XCTAssertTrue(
            sentence.contains(
                TranslationReviewIndicator.displayLabel(forLanguageTag: "es")),
            "the edition is not named: \(sentence)")
    }
}
