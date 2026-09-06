import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The first reader's note, answered once, recorded twice** (two loops P2
/// Task 5).
///
/// The writer answers her note in the queue, and the same sentence becomes two
/// things: a dated instruction under her statement's `## Rulings` — where her
/// next reading is briefed on it as a standing instruction from the writer —
/// and the reply on the note's own thread, where the dispositions carry it.
///
/// Every assertion goes through the real op log (her statement's, and the
/// document's annotation projection) rather than a returned preview, for
/// `QueryRulingTests`' reason: a preview can agree with itself and be wrong.
///
/// Nothing here presses a mounted control (tripwire 33): the predicate, the
/// destination and the commit are all values, and the queue's wiring is pinned
/// by a source census.
@MainActor
final class FirstReaderRulingTests: XCTestCase {

    // MARK: - Harness

    private static let readerName = "Marguerite"

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let doc: Document
        let pid: String
    }

    /// A real project on disk, with a first reader named unless `reader` is
    /// nil. `QueryRulingTests`' fixture, one field wider.
    private func makeHarness(
        prefix: String, reader: String? = FirstReaderRulingTests.readerName
    ) async throws -> Harness {
        let (dir, docURL) = try makeTestProject(
            prefix: prefix, initialMd: "The doctor arrived late.\n")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: dir)
        await store.wordCountPopulationTask?.value
        if let reader { try await store.setFirstReaderName(reader) }
        let pid = try XCTUnwrap(doc.sequence.first)
        return Harness(projectURL: dir, store: store, doc: doc, pid: pid)
    }

    /// A note in her name — the shape `CompilerEnvironment+Project` mints for a
    /// check she read: signed with her display name, and stamped with no pass,
    /// because she reads checks and never rounds.
    private func addHerNote(
        _ h: Harness, kind: AnnotationKind = .comment,
        body: String = "The doctor's entrance lands flat.",
        author: String? = FirstReaderRulingTests.readerName,
        passId: String? = nil
    ) async throws -> Annotation {
        let id = try await h.doc.addAnnotation(
            kind: kind, paragraphId: h.pid, body: body,
            author: author.map {
                AnnotationAuthor(sourceKind: .claude, displayName: $0)
            },
            reviewPassId: passId)
        return try XCTUnwrap(annotation(h, id), "the note did not project")
    }

    /// Across ALL statuses — the default filter hides the very note an answer
    /// has just settled.
    private func annotation(_ h: Harness, _ id: String) -> Annotation? {
        h.doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// What her statement SAYS, derived from its op log alone — never read off
    /// the `.md` beside it as truth (tripwire 20).
    private func statementText(_ h: Harness) async throws -> String {
        let statement = try XCTUnwrap(
            h.store.statement(kind: .firstReader, scope: .project),
            "her statement does not exist")
        let ops = try await OpLogStore(projectURL: h.projectURL).load(docId: statement.id)
        let derived = Deriver.derive(ops: ops)
        return derived.sequence.compactMap { derived.paragraphs[$0] }
            .joined(separator: "\n\n")
    }

    // MARK: - The predicate

    /// The headline case: her open, unstamped, untagged note is offered a
    /// ruling.
    func test_herOwnOpenNoteIsOfferedARuling() async throws {
        let h = try await makeHarness(prefix: "FRR-Offered")
        let note = try await addHerNote(h)

        XCTAssertTrue(
            FirstReaderRuling.offersARuling(note, manifest: h.store.manifest))
    }

    /// A SETTLED note is not answered again — the affordance goes with the rest
    /// of the dispositions when the note is closed. Offering it would file a
    /// second instruction for one decision, dated a week apart.
    func test_aSettledNoteIsOfferedNothing() async throws {
        let h = try await makeHarness(prefix: "FRR-Settled")
        let note = try await addHerNote(h)

        _ = await FirstReaderRuling.commit(
            "Let it land flat \u{2014} that is the joke.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        let settled = try XCTUnwrap(annotation(h, note.id))
        XCTAssertEqual(settled.status, .accepted, "the note was not settled")
        XCTAssertFalse(
            FirstReaderRuling.offersARuling(settled, manifest: h.store.manifest))
    }

    /// A STAMPED note is some editor's, filed in a lane. She reads checks and
    /// never rounds, so a stamped note answered into her statement would brief
    /// her with doctrine the writer aimed at a pass — even when the byline
    /// happens to match.
    func test_aStampedNoteIsOfferedNothingEvenInHerName() async throws {
        let h = try await makeHarness(prefix: "FRR-Stamped")
        let stamped = try await addHerNote(h, passId: "structural")

        XCTAssertFalse(
            FirstReaderRuling.offersARuling(stamped, manifest: h.store.manifest))
    }

    /// Another byline is another reader. The coach's notes, a human
    /// collaborator's, an unsigned one: none of them is an instruction to her.
    func test_someoneElsesNoteIsOfferedNothing() async throws {
        let h = try await makeHarness(prefix: "FRR-OtherAuthor")
        let coach = try await addHerNote(h, author: "Le Guin")
        let unsigned = try await addHerNote(h, author: nil)

        XCTAssertFalse(
            FirstReaderRuling.offersARuling(coach, manifest: h.store.manifest))
        XCTAssertFalse(
            FirstReaderRuling.offersARuling(unsigned, manifest: h.store.manifest))
    }

    /// A LANGUAGE-TAGGED note is an edition query, whatever else it carries —
    /// `QueryRuling` owns those, and this is the fact that makes the two offers
    /// mutually exclusive.
    func test_aLanguageTaggedNoteIsNeverHers() async throws {
        let h = try await makeHarness(prefix: "FRR-Tagged")
        let id = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "t\u{00FA} or usted?",
            toolArgs: #"{"language":"es"}"#,
            author: AnnotationAuthor(
                sourceKind: .claude, displayName: Self.readerName))
        let tagged = try XCTUnwrap(annotation(h, id))

        XCTAssertEqual(tagged.language, "es", "the tag did not project")
        XCTAssertFalse(
            FirstReaderRuling.offersARuling(tagged, manifest: h.store.manifest))
    }

    /// The three kinds her findings reach the queue as: a reader's report
    /// mints as `.comment`, her letter's one question as `.query`, and an
    /// anchorless finding as `.craftNote`. A suggested change is the one kind
    /// that is not — it is a rewrite nobody asked her for, and answering it as
    /// a standing instruction would file doctrine about it.
    func test_onlyHerThreeFindingKindsEverOfferIt() async throws {
        let h = try await makeHarness(prefix: "FRR-Kinds")

        for kind in [AnnotationKind.comment, .query, .craftNote] {
            let note = Annotation(
                id: "a-\(kind)", kind: kind, paragraphId: h.pid,
                body: "b", suggestedText: nil, priorText: nil,
                createdAt: Date(), createdBySession: nil,
                status: .open, userResponse: nil, resolvedAt: nil,
                isStale: false,
                author: AnnotationAuthor(
                    sourceKind: .claude, displayName: Self.readerName))
            XCTAssertTrue(
                FirstReaderRuling.offersARuling(note, manifest: h.store.manifest),
                "\(kind) in her name was not offered a ruling")
        }
        let impostor = Annotation(
            id: "a-suggestion", kind: .suggestedChange, paragraphId: h.pid,
            body: "b", suggestedText: "c", priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil,
            isStale: false,
            author: AnnotationAuthor(
                sourceKind: .claude, displayName: Self.readerName))
        XCTAssertFalse(
            FirstReaderRuling.offersARuling(impostor, manifest: h.store.manifest),
            "a suggested change was offered a ruling")
    }

    /// **Her ANCHORLESS note is offered one too, and it may be the sharpest of
    /// the three** (Controller Ruling, two loops P2 Task 5). An anchorless
    /// finding falls back to `.craftNote` whatever section raised it
    /// (`CompilerNote.init(diagnostic:)`), and an observation about the piece
    /// as a whole — "I kept waiting for the sister to come back" — is exactly
    /// what a standing instruction answers. Left out, her most rulable remark
    /// would have had no door but Reply.
    func test_herAnchorlessNoteIsOfferedARulingToo() async throws {
        let h = try await makeHarness(prefix: "FRR-Anchorless")
        let id = try await h.doc.addAnnotation(
            kind: .craftNote, paragraphId: nil,
            body: "I kept waiting for the sister to come back.",
            author: AnnotationAuthor(
                sourceKind: .claude, displayName: Self.readerName))
        let note = try XCTUnwrap(annotation(h, id), "the craft note did not project")

        XCTAssertNil(note.paragraphId, "the note is not anchorless")
        XCTAssertTrue(
            FirstReaderRuling.offersARuling(note, manifest: h.store.manifest))
        XCTAssertEqual(
            RulingDestination.offered(for: note, manifest: h.store.manifest),
            .firstReader(name: Self.readerName))
    }

    /// **The widening costs the exclusivity nothing**, which is what makes it
    /// safe: `QueryRuling` offers over `.craftNote` as well, but only a
    /// LANGUAGE-TAGGED one. The same kind, tagged, is an edition question and
    /// never hers — even in her name.
    func test_aTaggedCraftNoteIsStillTheEditionsAndNeverHers() async throws {
        let h = try await makeHarness(prefix: "FRR-TaggedCraftNote")
        let id = try await h.doc.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: "Register throughout?",
            toolArgs: #"{"language":"fr"}"#,
            author: AnnotationAuthor(
                sourceKind: .claude, displayName: Self.readerName))
        let tagged = try XCTUnwrap(annotation(h, id))

        XCTAssertEqual(tagged.language, "fr", "the tag did not project")
        XCTAssertFalse(
            FirstReaderRuling.offersARuling(tagged, manifest: h.store.manifest))
        XCTAssertEqual(
            RulingDestination.offered(for: tagged, manifest: h.store.manifest),
            .editionBrief(language: "fr"))
    }

    /// The whole act over an anchorless note of hers, end to end: the
    /// instruction in her statement, the reply on the thread. An offer that
    /// drew a control the commit could not honour would be worse than no offer.
    func test_anAnchorlessNoteOfHersCommitsLikeAnyOther() async throws {
        let h = try await makeHarness(prefix: "FRR-AnchorlessCommit")
        let id = try await h.doc.addAnnotation(
            kind: .craftNote, paragraphId: nil,
            body: "I kept waiting for the sister to come back.",
            author: AnnotationAuthor(
                sourceKind: .claude, displayName: Self.readerName))
        let note = try XCTUnwrap(annotation(h, id))

        let refusal = await FirstReaderRuling.commit(
            "She has read the first two books \u{2014} nothing about Marnie is "
            + "new to her.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNil(refusal, "the answer was refused: \(refusal ?? "")")
        let text = try await statementText(h)
        XCTAssertTrue(text.contains("nothing about Marnie is new to her."),
                      "the writer's words are not in her statement:\n\(text)")
        let settled = try XCTUnwrap(annotation(h, note.id))
        XCTAssertEqual(settled.status, .accepted,
                       "the note is still open after being answered")
    }

    /// A project that has named nobody offers nothing — there is no statement
    /// to rule into, and no byline any note could match.
    func test_anUnnamedReaderOffersNothing() async throws {
        let h = try await makeHarness(prefix: "FRR-Unnamed", reader: nil)
        let note = try await addHerNote(h)

        XCTAssertNil(FirstReaderRuling.readerName(in: h.store.manifest))
        XCTAssertFalse(
            FirstReaderRuling.offersARuling(note, manifest: h.store.manifest))
    }

    /// A name that is only whitespace is no name. The manifest trims on the way
    /// in, so this is the hand-edited `project.json` arriving through the door
    /// `ProjectManifest.authorReader` guards for the same reason.
    func test_aBlankNameIsNoName() async throws {
        let h = try await makeHarness(prefix: "FRR-Blank", reader: nil)
        var manifest = h.store.manifest
        manifest.firstReaderName = "   "
        let note = try await addHerNote(h, author: "   ")

        XCTAssertNil(FirstReaderRuling.readerName(in: manifest))
        XCTAssertFalse(FirstReaderRuling.offersARuling(note, manifest: manifest))
    }

    // MARK: - The ruling half

    /// The headline: the answer lands under her statement's `## Rulings`, the
    /// statement being minted by the act when the writer has never opened one.
    func test_theFirstAnswerMintsHerStatement() async throws {
        let h = try await makeHarness(prefix: "FRR-Mints")
        let note = try await addHerNote(h)

        XCTAssertNil(h.store.statement(kind: .firstReader, scope: .project),
                     "her statement existed before the first answer")

        let refusal = await FirstReaderRuling.commit(
            "Keep the entrance flat.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNil(refusal, "the answer was refused: \(refusal ?? "")")
        let text = try await statementText(h)
        XCTAssertTrue(text.contains("## Rulings"),
                      "the answer did not open a rulings stratum:\n\(text)")
        XCTAssertTrue(text.contains("Keep the entrance flat."),
                      "the writer's words are not in her statement:\n\(text)")
    }

    /// The destination is HERS, not the book's own intent. An instruction to
    /// one reader filed as craft intent would be checked against every run of
    /// every piece, silently.
    func test_theBooksOwnIntentIsNeverWhereThisLands() async throws {
        let h = try await makeHarness(prefix: "FRR-NotIntent")
        let note = try await addHerNote(h)

        _ = await FirstReaderRuling.commit(
            "Keep the entrance flat.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        XCTAssertNil(h.store.statement(kind: .intent, scope: .project),
                     "the answer minted the book's craft intent")
        XCTAssertNotNil(h.store.statement(kind: .firstReader, scope: .project),
                        "her statement is not there")
    }

    /// The provenance quotes the note it settles, so a later reader of her
    /// statement knows which observation the line answers.
    func test_theProvenanceCarriesHerNotesOwnWords() async throws {
        let h = try await makeHarness(prefix: "FRR-Provenance")
        let note = try await addHerNote(h, body: "The doctor's entrance lands flat.")

        _ = await FirstReaderRuling.commit(
            "That is deliberate.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        let text = try await statementText(h)
        XCTAssertTrue(
            text.contains("\u{00AB}The doctor\u{2019}s entrance lands flat.\u{00BB}")
                || text.contains("\u{00AB}The doctor's entrance lands flat.\u{00BB}"),
            "her own words are not quoted in the line:\n\(text)")
        XCTAssertTrue(text.contains(Self.readerName),
                      "the line does not say whose note it answers:\n\(text)")
    }

    /// An em-dash in her note cannot reach the line: `RulingsSection.parseItem`
    /// splits an item on its RIGHT-MOST em-dash, so one surviving inside the
    /// excerpt would cut the writer's own sentence off mid-word.
    func test_anEmDashInHerNoteCannotBreakTheLinesSplit() async throws {
        let h = try await makeHarness(prefix: "FRR-EmDash")
        let note = try await addHerNote(h, body: "Flat \u{2014} deliberately?")

        _ = await FirstReaderRuling.commit(
            "Deliberately.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        let text = try await statementText(h)
        let ruling = try XCTUnwrap(RulingsSection.parse(text).rulings.first)
        XCTAssertEqual(ruling.text, "Deliberately.",
                       "the writer's sentence was cut by the excerpt's em-dash")
    }

    /// A second answer APPENDS. Her statement is a growing list of standing
    /// instructions, and one overwriting another would take a decision away
    /// with nothing red.
    func test_aSecondAnswerAppendsRatherThanOverwriting() async throws {
        let h = try await makeHarness(prefix: "FRR-Appends")
        let first = try await addHerNote(h, body: "The entrance lands flat.")
        let second = try await addHerNote(h, body: "The sisters sound alike.")

        _ = await FirstReaderRuling.commit(
            "Keep the entrance flat.", answering: first,
            in: h.doc, store: h.store, undoManager: nil)
        _ = await FirstReaderRuling.commit(
            "They are meant to.", answering: second,
            in: h.doc, store: h.store, undoManager: nil)

        let text = try await statementText(h)
        XCTAssertEqual(RulingsSection.parse(text).rulings.count, 2,
                       "the second answer did not append:\n\(text)")
        XCTAssertTrue(text.contains("Keep the entrance flat."))
        XCTAssertTrue(text.contains("They are meant to."))
    }

    // MARK: - The reply half

    /// The same sentence is the reply on the thread — which is what puts it in
    /// the next briefing's dispositions instead of leaving the note to be
    /// raised again. `QueryRuling.commit`'s disposition, mirrored.
    func test_theSameAnswerPostsAsTheReplyOnTheThread() async throws {
        let h = try await makeHarness(prefix: "FRR-Reply")
        let note = try await addHerNote(h)

        _ = await FirstReaderRuling.commit(
            "Keep the entrance flat.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        let settled = try XCTUnwrap(annotation(h, note.id))
        XCTAssertEqual(settled.userResponse, "Keep the entrance flat.",
                       "the answer is not the reply on the thread")
        XCTAssertEqual(settled.status, .accepted,
                       "the note is still open after being answered")
    }

    // MARK: - Refusal

    /// **Nothing is half-done.** The instruction is written first, so a refusal
    /// leaves the note open and answerable rather than settling a thread whose
    /// doctrine never landed.
    func test_anEmptyAnswerIsRefusedAndTheNoteStaysOpen() async throws {
        let h = try await makeHarness(prefix: "FRR-Empty")
        let note = try await addHerNote(h)

        let refusal = await FirstReaderRuling.commit(
            "   \n ", answering: note, in: h.doc, store: h.store, undoManager: nil)

        XCTAssertEqual(refusal, RulingFailure.emptyRuling.errorDescription,
                       "the refusal did not speak in the performer's own words")
        XCTAssertNil(h.store.statement(kind: .firstReader, scope: .project),
                     "a refused answer left a statement behind")
        let untouched = try XCTUnwrap(annotation(h, note.id))
        XCTAssertEqual(untouched.status, .open)
        XCTAssertNil(untouched.userResponse)
    }

    /// A project with no reader named cannot be committed against even if a
    /// caller reaches past the affordance — and it says what is missing rather
    /// than filing the answer somewhere it invented.
    func test_anUnnamedProjectIsRefusedRatherThanFiledSomewhereInvented() async throws {
        let h = try await makeHarness(prefix: "FRR-UnnamedCommit", reader: nil)
        let note = try await addHerNote(h)

        let refusal = await FirstReaderRuling.commit(
            "Keep it flat.", answering: note,
            in: h.doc, store: h.store, undoManager: nil)

        XCTAssertEqual(refusal, FirstReaderRuling.unnamedRefusal)
        XCTAssertNil(h.store.statement(kind: .firstReader, scope: .project),
                     "a refused answer left a statement behind")
        XCTAssertEqual(try XCTUnwrap(annotation(h, note.id)).status, .open)
    }

    // MARK: - What the writer is told before they commit

    /// The confirm sentence states BOTH destinations, and names her. One naming
    /// only the statement would leave the writer expecting the note still open;
    /// one naming only the reply would hide the instruction.
    func test_theConfirmSentenceNamesBothRecordsAndHer() {
        let sentence = FirstReaderRuling.confirmation(name: Self.readerName)
        XCTAssertTrue(sentence.contains(Self.readerName),
                      "she is not named: \(sentence)")
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("statement"),
                      "her statement is not named: \(sentence)")
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("repl"),
                      "the reply is not named: \(sentence)")
    }

    // MARK: - One control, one destination

    /// **The two offers cannot both answer for one note.** An edition query
    /// carries a `language` and hers never does — the fact the shared
    /// destination turns on, pinned here because it is what makes one control
    /// safe rather than merely tidy.
    func test_noNoteIsEverOfferedBothDestinations() async throws {
        let h = try await makeHarness(prefix: "FRR-Exclusive")
        let hers = try await addHerNote(h)
        let taggedId = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "t\u{00FA} or usted?",
            toolArgs: #"{"language":"es"}"#,
            author: AnnotationAuthor(
                sourceKind: .claude, displayName: Self.readerName))
        let tagged = try XCTUnwrap(annotation(h, taggedId))

        for note in [hers, tagged] {
            let both = QueryRuling.offersARuling(note)
                && FirstReaderRuling.offersARuling(note, manifest: h.store.manifest)
            XCTAssertFalse(both, "one note was offered both destinations")
        }
        XCTAssertEqual(
            RulingDestination.offered(for: hers, manifest: h.store.manifest),
            .firstReader(name: Self.readerName))
        XCTAssertEqual(
            RulingDestination.offered(for: tagged, manifest: h.store.manifest),
            .editionBrief(language: "es"))
    }

    /// A note offered neither destination resolves to nil, which is what makes
    /// the queue draw no control at all.
    func test_anOrdinaryNoteIsOfferedNoDestination() async throws {
        let h = try await makeHarness(prefix: "FRR-Neither")
        let ordinary = try await addHerNote(h, author: "Le Guin")

        XCTAssertNil(
            RulingDestination.offered(for: ordinary, manifest: h.store.manifest))
    }

    /// **A nil manifest still draws the translator's affordance and never
    /// hers.** Hosts holding no project identity render rows too, and the
    /// edition arm turns on the note alone.
    func test_aHostWithNoProjectIdentityStillOffersTheEditionArm() async throws {
        let h = try await makeHarness(prefix: "FRR-NoManifest")
        let hers = try await addHerNote(h)
        let taggedId = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "t\u{00FA} or usted?",
            toolArgs: #"{"language":"es"}"#)
        let tagged = try XCTUnwrap(annotation(h, taggedId))

        XCTAssertNil(RulingDestination.offered(for: hers, manifest: nil))
        XCTAssertEqual(RulingDestination.offered(for: tagged, manifest: nil),
                       .editionBrief(language: "es"))
    }

    /// The help names the destination, and the two are different sentences —
    /// a writer hovering over the button on her note must not be told about an
    /// edition brief.
    func test_theHelpNamesWhereTheSentenceLands() {
        let hers = RulingDestination.firstReader(name: Self.readerName).help
        let edition = RulingDestination.editionBrief(language: "es").help

        XCTAssertTrue(hers.contains(Self.readerName), hers)
        XCTAssertFalse(hers.localizedCaseInsensitiveContains("edition"), hers)
        XCTAssertTrue(edition.localizedCaseInsensitiveContains("edition brief"), edition)
        XCTAssertNotEqual(hers, edition)
    }

    // MARK: - The queue's wiring

    /// **Source census: the queue routes both destinations, and the row is
    /// given the identity it needs to choose.**
    ///
    /// Windowless on purpose (tripwire 33). What could silently break is not
    /// the predicate — every case above pins that — but the WIRING: a row built
    /// without a manifest draws her control never, and a commit that reached
    /// only `QueryRuling` would file her answer under an edition brief or
    /// refuse. Both are invisible to a test that asserts on values alone.
    func test_theQueueRoutesBothRulingDestinations() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let pane = repoRoot
            .appendingPathComponent("Maugham/Views/AnnotationsPane.swift")
        let text = try String(contentsOf: pane, encoding: .utf8)

        XCTAssertTrue(text.contains("FirstReaderRuling.commit("),
                      "the queue never files an answer into her statement")
        XCTAssertTrue(text.contains("QueryRuling.commit("),
                      "the queue stopped filing an answer into an edition brief")
        XCTAssertTrue(text.contains("manifest: store.manifest"),
                      "the row is not given the project identity its offer needs")
        XCTAssertTrue(text.contains("RulingDestination.offered("),
                      "the queue no longer asks the one destination decision")
    }
}
