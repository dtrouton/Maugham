import XCTest
@testable import Maugham
import MaughamCore

final class DiagnosticIngestTests: XCTestCase {

    private let runId = ULID.generate()
    private let docId = "doc-under-test"

    // MARK: - The sectioned contract

    /// Three paragraphs: two short enough to excerpt whole, one long enough
    /// that the excerpt has to stop. `they` is deliberately a live id that is
    /// also an English word — the id-scrub's false-positive boundary.
    private func liveV2(
        _ paragraphs: [String: String] = [
            "a1b2": "The first paragraph, as it stands right now.",
            "c3d4": "The second paragraph, as it stands right now.",
            "e5f6": "A longer paragraph whose opening runs past the eight word excerpt boundary by some margin.",
            "they": "A paragraph whose id is also an ordinary English word.",
        ]
    ) -> (String) -> String? {
        { paragraphs[$0] }
    }

    private var conformanceLine: String {
        """
        {"section":"conformance","checks":[\
        {"clause_quote":"Nothing supernatural happens.","status":"strains",\
        "refs":["a1b2"],"what_pulls":"The mirror answers before she speaks."},\
        {"clause_quote":"Kelly never explains herself.","status":"holds",\
        "refs":[],"what_pulls":null},\
        {"clause_quote":"The town is never named.","status":"silent",\
        "refs":[],"what_pulls":null}]}
        """
    }

    private var continuityLine: String {
        """
        {"section":"continuity","questions":[\
        {"cites":"the dock burned in the spring","refs":["c3d4"],\
        "question":"Is the dock standing again by this scene?"}]}
        """
    }

    private var readerLine: String {
        """
        {"section":"reader","reports":[\
        {"kind":"dream_break","refs":["a1b2"],\
        "report":"The dream broke at the shift in tense."},\
        {"kind":"belief","refs":["e5f6"],\
        "report":"By here a reader believes she has already left."}]}
        """
    }

    private var factsLine: String {
        """
        {"section":"facts","candidates":[\
        {"subject":"Kelly","fact":"Kelly keeps her father's watch.","refs":["e5f6"]}]}
        """
    }

    /// The fifth section (M3-P3 Task 4): the round's verdict on whether the
    /// draft has drifted from the declared intent, with the one sentence the
    /// schema asks for when it has.
    private var intentDriftLine: String {
        """
        {"section":"intent_drift","verdict":"drifted",\
        "note":"The last two scenes reach for a warmth the intent rules out."}
        """
    }

    /// The sixth section (editorial letter P1 Task 2): one of every part, so
    /// a part-for-part parse can be asserted from one line. `c3d4` and `e5f6`
    /// are live; nothing here dangles, which is what the dangling tests below
    /// vary one field at a time from.
    private var letterLine: String {
        """
        {"section":"letter","about":"A woman waits out a fog that will not lift.",\
        "one_thing":"Let the fog do less of the work.",\
        "working":[{"refs":["a1b2"],"what":"The opening image",\
        "why":"It states the weather and the mood in one move."}],\
        "habits":[{"name":"Filter words","refs":["c3d4","e5f6"],\
        "cost":"The reader is held one step back from the scene.",\
        "lesson":"Cut the verb of perception and the perception stays.",\
        "exercise":"Read the second paragraph aloud with the names removed."}],\
        "questions":[{"refs":["c3d4"],\
        "question":"Whose fear is this, hers or the narrator's?"}],\
        "scenes":[{"refs":["e5f6"],"wants":"To be let in","changes":"Nothing",\
        "turn":"","charge":"-"}]}
        """
    }

    private func parseSection(
        _ line: String, live: ((String) -> String?)? = nil
    ) -> DiagnosticIngest.PartialSection? {
        DiagnosticIngest.parseSection(
            line: line, runId: runId, docId: docId, liveParagraphText: live ?? liveV2())
    }

    private func parseAll(
        _ text: String, live: ((String) -> String?)? = nil
    ) -> DiagnosticIngest.SectionedOutcome? {
        DiagnosticIngest.parseAll(
            resultText: text, runId: runId, docId: docId, liveParagraphText: live ?? liveV2())
    }

    // MARK: v2 — the schema constant is the single source of field names

    /// v1's anti-drift pin, re-aimed at the section contract: every wire name
    /// and every enumerated value the v2 parser reads is one the prompt
    /// actually asks for.
    func test_v2FieldNamesComeFromTheSectionSchema() {
        let schema = CompilerPrompt.sectionSchemaDescription
        let names = [
            DiagnosticIngest.SectionField.section,
            DiagnosticIngest.SectionField.conformance,
            DiagnosticIngest.SectionField.checks,
            DiagnosticIngest.SectionField.clauseQuote,
            DiagnosticIngest.SectionField.status,
            DiagnosticIngest.SectionField.refs,
            DiagnosticIngest.SectionField.whatPulls,
            DiagnosticIngest.SectionField.continuity,
            DiagnosticIngest.SectionField.questions,
            DiagnosticIngest.SectionField.cites,
            DiagnosticIngest.SectionField.question,
            DiagnosticIngest.SectionField.reader,
            DiagnosticIngest.SectionField.reports,
            DiagnosticIngest.SectionField.readerKind,
            DiagnosticIngest.SectionField.report,
            DiagnosticIngest.SectionField.facts,
            DiagnosticIngest.SectionField.candidates,
            DiagnosticIngest.SectionField.subject,
            DiagnosticIngest.SectionField.fact,
            DiagnosticIngest.SectionField.holds,
            DiagnosticIngest.SectionField.strains,
            DiagnosticIngest.SectionField.silent,
            DiagnosticIngest.SectionField.dreamBreak,
            DiagnosticIngest.SectionField.belief,
            DiagnosticIngest.SectionField.intentDrift,
            DiagnosticIngest.SectionField.verdict,
            DiagnosticIngest.SectionField.drifted,
            // Read and dropped, but still read — so the name the parser looks
            // for has to be the name the prompt asks for.
            DiagnosticIngest.SectionField.driftNote,
            // The sixth section (editorial letter P1 Task 2). Every key the
            // letter parser reads, including the two enumerated `charge`
            // values, on the same rule as the five sections above it: a name
            // the parser looks for that the prompt never asks for is a field
            // that will always be absent, and nothing would say so.
            DiagnosticIngest.SectionField.letter,
            DiagnosticIngest.SectionField.about,
            DiagnosticIngest.SectionField.oneThing,
            DiagnosticIngest.SectionField.working,
            DiagnosticIngest.SectionField.what,
            DiagnosticIngest.SectionField.why,
            DiagnosticIngest.SectionField.habits,
            DiagnosticIngest.SectionField.habitName,
            DiagnosticIngest.SectionField.cost,
            DiagnosticIngest.SectionField.lesson,
            DiagnosticIngest.SectionField.exercise,
            DiagnosticIngest.SectionField.scenes,
            DiagnosticIngest.SectionField.wants,
            DiagnosticIngest.SectionField.changes,
            DiagnosticIngest.SectionField.turn,
            DiagnosticIngest.SectionField.charge,
            DiagnosticIngest.SectionField.chargePositive,
            DiagnosticIngest.SectionField.chargeNegative,
        ]
        for name in names {
            XCTAssertTrue(
                schema.contains("\"\(name)\""),
                "the prompt's section schema never names \"\(name)\"")
        }
    }

    // MARK: v2 — conformance

    func test_aStrainYieldsBothAStatusAndANote() {
        guard let section = parseSection(conformanceLine) else {
            return XCTFail("expected a conformance section")
        }

        XCTAssertEqual(
            section.conformance.map { $0.status }, ["strains", "holds", "silent"],
            "every check becomes a status, whatever it says")
        XCTAssertEqual(section.accepted.count, 1, "only the strain becomes a note")

        let note = section.accepted[0]
        XCTAssertEqual(note.kind, .conformanceStrain)
        XCTAssertEqual(note.clauseQuote, "Nothing supernatural happens.")
        XCTAssertEqual(note.body, "The mirror answers before she speaks.")
        XCTAssertNil(note.category, "v2 mints no free-form category")
        XCTAssertEqual(note.refs?.map { $0.paragraphId }, ["a1b2"])
        XCTAssertEqual(
            note.anchor?.paragraphId, "a1b2",
            "the first ref is the anchor, so the store's one staleness rule still applies")
        XCTAssertEqual(
            note.anchor?.anchorText, "The first paragraph, as it stands right now.")
        XCTAssertEqual(section.droppedDangling, 0)
        XCTAssertEqual(section.truncatedReader, 0)
    }

    func test_holdsAndSilentAreStatusesOnly() {
        let line = """
            {"section":"conformance","checks":[\
            {"clause_quote":"A held clause.","status":"holds","refs":["a1b2"],"what_pulls":null},\
            {"clause_quote":"A silent clause.","status":"silent","refs":[],"what_pulls":null}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.conformance.count, 2)
        XCTAssertTrue(
            section.accepted.isEmpty,
            "a clause that holds or goes unmentioned is not a note the writer has to read")
        XCTAssertEqual(section.conformance[0].refs.map { $0.paragraphId }, ["a1b2"])
    }

    /// A strain with nothing to say about what pulls loses its note but keeps
    /// its status: "this clause strains" is still true, and the summary is
    /// where it belongs.
    func test_aStrainWithNothingToSayKeepsItsStatusAndCountsTheLostNote() {
        let line = """
            {"section":"conformance","checks":[\
            {"clause_quote":"A strained clause.","status":"strains","refs":["a1b2"],"what_pulls":"  "}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.conformance.map { $0.status }, ["strains"])
        XCTAssertTrue(section.accepted.isEmpty)
        XCTAssertEqual(section.droppedDangling, 1)
    }

    func test_anUnknownStatusIsDroppedAndCounted() {
        let line = """
            {"section":"conformance","checks":[\
            {"clause_quote":"A clause.","status":"critical","refs":[],"what_pulls":"Something."}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertTrue(section.conformance.isEmpty, "the schema's three statuses are the whole vocabulary")
        XCTAssertTrue(section.accepted.isEmpty)
        XCTAssertEqual(section.droppedDangling, 1)
    }

    // MARK: v2 — continuity

    func test_aContinuityEntryBecomesAQuestionNoteCitingTheWritersWords() {
        guard let section = parseSection(continuityLine) else {
            return XCTFail("expected a continuity section")
        }

        XCTAssertEqual(section.accepted.count, 1)
        let note = section.accepted[0]
        XCTAssertEqual(note.kind, .continuity)
        XCTAssertEqual(note.body, "Is the dock standing again by this scene?")
        XCTAssertEqual(
            note.clauseQuote, "the dock burned in the spring",
            "cites is the writer's own words, on the same field the strain's clause uses")
        XCTAssertEqual(note.refs?.map { $0.paragraphId }, ["c3d4"])
        XCTAssertNil(note.category)
        XCTAssertTrue(section.conformance.isEmpty)
        XCTAssertTrue(section.facts.isEmpty)
    }

    // MARK: v2 — the reader's report

    func test_readerReportsKeepTheirSchemaPinnedKind() {
        guard let section = parseSection(readerLine) else {
            return XCTFail("expected a reader section")
        }

        XCTAssertEqual(section.accepted.map { $0.kind }, [.readerReport, .readerReport])
        XCTAssertEqual(
            section.accepted.map { $0.category }, ["dream_break", "belief"],
            "the section's two-valued kind is content, and it is the only thing v2 puts on category")
        XCTAssertEqual(section.accepted[1].refs?.first?.paragraphId, "e5f6")
    }

    /// The cap the schema asks for, enforced. Over-reporting is the model
    /// being eager, not a failed run — so the extras are truncated and
    /// counted separately from what was dropped on its own demerits.
    func test_theReaderReportIsTruncatedToThree() {
        let reports = (1...5).map {
            "{\"kind\":\"belief\",\"refs\":[\"a1b2\"],\"report\":\"Report number \($0).\"}"
        }
        let line = "{\"section\":\"reader\",\"reports\":[\(reports.joined(separator: ","))]}"
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(
            section.accepted.map { $0.body },
            ["Report number 1.", "Report number 2.", "Report number 3."],
            "the first three survive, in the order the model ranked them")
        XCTAssertEqual(section.truncatedReader, 2)
        XCTAssertEqual(
            section.droppedDangling, 0,
            "an over-eager reader report is not a note Maugham could not place")
    }

    // MARK: v2 — facts

    func test_factsBecomeBibleFactsAnchoredToTheirFirstRef() {
        guard let section = parseSection(factsLine) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.facts.count, 1)
        let fact = section.facts[0]
        XCTAssertEqual(fact.subject, "Kelly")
        XCTAssertEqual(fact.fact, "Kelly keeps her father's watch.")
        XCTAssertEqual(fact.establishedAt, "e5f6")
        // **The words as well as the id** (requirement 3). The pane captions a
        // fact with the establishing paragraph's prose, and this resolution is
        // the only place that prose is in hand — a fact that carried the id
        // alone left the stratum with nothing to print but `¶e5f6`.
        XCTAssertEqual(fact.excerpt, "A longer paragraph whose opening runs past the\u{2026}")
        XCTAssertEqual(fact.docId, docId)
        XCTAssertFalse(fact.id.isEmpty)
        XCTAssertTrue(
            section.accepted.isEmpty,
            "fact candidates land in the bible; they are never rendered as notes")
    }

    func test_aFactWithNoUsableRefIsStillAFactWithNoAnchor() {
        let line = """
            {"section":"facts","candidates":[\
            {"subject":"Kelly","fact":"Kelly is left-handed.","refs":[]}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.facts.count, 1)
        XCTAssertNil(section.facts[0].establishedAt)
        XCTAssertNil(section.facts[0].excerpt,
                     "there is no paragraph to quote, so the pane captions it by subject "
                     + "alone rather than by half a claim")
        XCTAssertEqual(section.droppedDangling, 0)
    }

    /// **A model that names the same paragraph twice gets one ref.** The pane
    /// keys its chip `ForEach` on `paragraphId`, and SwiftUI's behaviour on
    /// duplicate ids is undefined — so the list is deduplicated where the
    /// model's words become ours, not at each surface that draws them. First
    /// spelling wins, so the order the run reported survives.
    func test_aRefNamedTwiceResolvesOnce() {
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["a1b2","\u{00b6}a1b2","c3d4","a1b2"],"question":"A question?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.accepted[0].refs?.map { $0.paragraphId }, ["a1b2", "c3d4"])
        XCTAssertEqual(section.accepted[0].anchor?.paragraphId, "a1b2",
                       "the anchor is still the first ref that resolved")
    }

    // MARK: v2 — refs carry excerpts, captured at ingest

    func test_refsCaptureAnExcerptOfLiveTextAtIngest() {
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"a citation","refs":["e5f6","a1b2"],"question":"A question?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(
            section.accepted[0].refs?.map { $0.excerpt },
            [
                "A longer paragraph whose opening runs past the\u{2026}",
                "The first paragraph, as it stands right now.",
            ],
            "an excerpt is the head of the LIVE paragraph, elided only when there is more")
    }

    func test_midRunEditsShowUpInTheExcerpt() {
        let live = liveV2(["c3d4": "Rewritten while the run was still in flight."])
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"a citation","refs":["c3d4"],"question":"A question?"}]}
            """
        guard let section = parseSection(line, live: live) else {
            return XCTFail("a mid-run edit must not fail the section")
        }

        XCTAssertEqual(
            section.accepted[0].refs?.first?.excerpt,
            "Rewritten while the run was still in flight.")
        XCTAssertEqual(
            section.accepted[0].anchor?.anchorText,
            "Rewritten while the run was still in flight.")
    }

    /// An entry that points only at prose the document no longer has is
    /// dropped and counted — v1's dangling-id rule, applied to the whole
    /// entry, because the entry is the unit the writer reads.
    func test_anEntryWhoseEveryRefDanglesIsDroppedAndCounted() {
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"gone","refs":["zzzz"],"question":"About a paragraph that left?"},\
            {"cites":"here","refs":["zzzz","a1b2"],"question":"About one that partly stayed?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.accepted.map { $0.body }, ["About one that partly stayed?"])
        XCTAssertEqual(
            section.accepted[0].refs?.map { $0.paragraphId }, ["a1b2"],
            "a partly-resolving entry survives with the refs that resolved")
        XCTAssertEqual(section.droppedDangling, 1)
    }

    func test_bracketedAndPilcrowedRefsStillResolve() {
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["[a1b2]","\u{00b6}c3d4"],"question":"A question?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(
            section.accepted[0].refs?.map { $0.paragraphId }, ["a1b2", "c3d4"],
            "the resolved id is stored, never the decorated spelling")
        XCTAssertEqual(section.droppedDangling, 0)
    }

    // MARK: v2 — the id-scrub with teeth

    /// The contract says references travel in `refs` and prose never carries
    /// an id. This is the half with teeth: an entry that leaks one is refused.
    func test_anIdInProseIsRefused() {
        let offenders = [
            """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["a1b2"],"question":"Does a1b2 contradict the dock burning?"}]}
            """,
            """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["a1b2"],"question":"Does [c3d4] contradict the dock burning?"}]}
            """,
            """
            {"section":"reader","reports":[\
            {"kind":"belief","refs":["a1b2"],"report":"The dream broke at \u{00b6}a1b2."}]}
            """,
            """
            {"section":"conformance","checks":[\
            {"clause_quote":"A clause.","status":"strains","refs":["a1b2"],\
            "what_pulls":"a1b2 answers before she speaks."}]}
            """,
            """
            {"section":"facts","candidates":[\
            {"subject":"Kelly","fact":"Kelly keeps a watch (see a1b2).","refs":["a1b2"]}]}
            """,
        ]

        for offender in offenders {
            guard let section = parseSection(offender) else {
                return XCTFail("a leaked id must not fail the section: \(offender)")
            }
            XCTAssertTrue(
                section.accepted.isEmpty && section.facts.isEmpty && section.conformance.isEmpty,
                "an id in prose must be refused: \(offender)")
            XCTAssertEqual(section.droppedDangling, 1, "and counted: \(offender)")
        }
    }

    /// **The planted-offender control.** The same entries with the id taken
    /// out are accepted — without this the refusal above could be firing on
    /// something else entirely and the test would still be green.
    func test_plantedOffender_theSameEntriesWithoutTheIdAreAccepted() {
        let clean = [
            """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["a1b2"],"question":"Does the mirror contradict the dock burning?"}]}
            """,
            """
            {"section":"reader","reports":[\
            {"kind":"belief","refs":["a1b2"],"report":"The dream broke at the shift in tense."}]}
            """,
            """
            {"section":"conformance","checks":[\
            {"clause_quote":"A clause.","status":"strains","refs":["a1b2"],\
            "what_pulls":"The mirror answers before she speaks."}]}
            """,
            """
            {"section":"facts","candidates":[\
            {"subject":"Kelly","fact":"Kelly keeps a watch.","refs":["a1b2"]}]}
            """,
        ]

        for line in clean {
            guard let section = parseSection(line) else {
                return XCTFail("expected a section for: \(line)")
            }
            XCTAssertEqual(
                section.droppedDangling, 0,
                "nothing here should be refused: \(line)")
            XCTAssertFalse(
                section.accepted.isEmpty && section.facts.isEmpty && section.conformance.isEmpty,
                "something should have survived: \(line)")
        }
    }

    /// The scrub's stated boundary: a four-character token that is an English
    /// word and happens to also be a live id is read as the word. Refusing it
    /// would silently delete good notes over a coincidence, and a leaked id is
    /// overwhelmingly either decorated or carrying a digit.
    func test_anEnglishWordThatHappensToBeALiveIdIsNotAnIdLeak() {
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["a1b2"],"question":"Do they know the dock burned?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.accepted.count, 1)
        XCTAssertEqual(section.droppedDangling, 0)
    }

    /// …and the other side of that boundary: the same word, decorated the way
    /// the prompt prints ids, IS a leak.
    func test_aDecoratedWordShapedIdIsStillAnIdLeak() {
        let line = """
            {"section":"continuity","questions":[\
            {"cites":"c","refs":["a1b2"],"question":"Does [they] contradict the dock burning?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertTrue(section.accepted.isEmpty)
        XCTAssertEqual(section.droppedDangling, 1)
    }

    // MARK: v2 — the register, enforced at ingest

    /// The schema has nowhere for "you should" to go; this is what happens
    /// when the model writes one anyway.
    func test_aFixShapedBodyIsRefused() {
        let offenders = [
            "You should cut the second sentence.",
            "I'd suggest moving this beat earlier.",
            "The tense slips — you might want to hold the past.",
            "My suggestion: let her answer first.",
        ]

        for body in offenders {
            let line = """
                {"section":"reader","reports":[\
                {"kind":"dream_break","refs":["a1b2"],"report":"\(body)"}]}
                """
            guard let section = parseSection(line) else {
                return XCTFail("a fix-shaped body must not fail the section: \(body)")
            }
            XCTAssertTrue(section.accepted.isEmpty, "expected a refusal for: \(body)")
            XCTAssertEqual(section.droppedDangling, 1, "and a count for: \(body)")
        }
    }

    /// **The planted-offender control** for the refusal above, in both
    /// directions: an observation that names the same problem without
    /// prescribing survives, and so does a question that merely contains the
    /// word "should".
    func test_plantedOffender_observationsAndShouldQuestionsSurvive() {
        let keepers = [
            "The tense slips between the second and third sentences.",
            "Should she already know the dock burned?",
            "A reader believes she has left, then finds her still on the pier.",
        ]

        for body in keepers {
            let line = """
                {"section":"reader","reports":[\
                {"kind":"dream_break","refs":["a1b2"],"report":"\(body)"}]}
                """
            guard let section = parseSection(line) else {
                return XCTFail("expected a section for: \(body)")
            }
            XCTAssertEqual(section.accepted.count, 1, "expected to keep: \(body)")
            XCTAssertEqual(section.droppedDangling, 0, "expected no refusal for: \(body)")
        }
    }

    /// The writer's own words are never scrubbed for register — a clause the
    /// writer wrote as "you should never explain" is theirs, and refusing it
    /// would delete their declared world from the report.
    func test_theWritersOwnQuotedWordsAreNotScrubbedForRegister() {
        let line = """
            {"section":"conformance","checks":[\
            {"clause_quote":"You should never explain a joke.","status":"strains",\
            "refs":["a1b2"],"what_pulls":"The narrator explains the joke."}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.conformance.count, 1)
        XCTAssertEqual(section.accepted.count, 1)
        XCTAssertEqual(section.droppedDangling, 0)
    }

    // MARK: v2 — one spelling of the fold

    /// `parseAll` is `parseSection` folded, and nothing else. Ids and
    /// timestamps are minted per call, so the comparison is over everything
    /// but them — and the redaction is proved non-vacuous in the same test.
    func test_parseAllIsTheFoldOfParseSection() {
        let lines = [conformanceLine, continuityLine, readerLine, factsLine]

        guard let whole = parseAll(lines.joined(separator: "\n")) else {
            return XCTFail("expected an outcome")
        }
        let parts = lines.compactMap { parseSection($0) }
        XCTAssertEqual(parts.count, 4, "every section line must parse on its own")

        XCTAssertEqual(
            whole.accepted.map(Self.redacted), parts.flatMap { $0.accepted }.map(Self.redacted))
        XCTAssertEqual(whole.conformance, parts.flatMap { $0.conformance })
        XCTAssertEqual(whole.facts.map(Self.redacted), parts.flatMap { $0.facts }.map(Self.redacted))
        XCTAssertEqual(whole.droppedDangling, parts.reduce(0) { $0 + $1.droppedDangling })
        XCTAssertEqual(whole.truncatedReader, parts.reduce(0) { $0 + $1.truncatedReader })

        // The redaction must not be what makes the comparison pass.
        let other = Diagnostic(
            id: whole.accepted[0].id, docId: docId, anchor: whole.accepted[0].anchor,
            body: "a different note", category: nil, runId: runId)
        XCTAssertNotEqual(Self.redacted(whole.accepted[0]), Self.redacted(other))
    }

    /// Zero out what is minted fresh on every parse, so two parses of the
    /// same bytes can be compared on their content.
    private static func redacted(_ diagnostic: Diagnostic) -> Diagnostic {
        Diagnostic(
            id: "", docId: diagnostic.docId, anchor: diagnostic.anchor, body: diagnostic.body,
            category: diagnostic.category, runId: diagnostic.runId, kind: diagnostic.kind,
            refs: diagnostic.refs, clauseQuote: diagnostic.clauseQuote)
    }

    private static func redacted(_ fact: BibleFact) -> BibleFact {
        BibleFact(
            id: "", subject: fact.subject, fact: fact.fact, establishedAt: fact.establishedAt,
            excerpt: fact.excerpt, docId: fact.docId,
            recordedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: v2 — tolerance

    func test_fencedAndPrettyPrintedSectionsStillParse() {
        let payload = [conformanceLine, continuityLine, readerLine, factsLine]
            .joined(separator: "\n")
        let forms = [
            payload,
            "```json\n\(payload)\n```",
            "```\n\(payload)\n```",
            "Here is what I found.\n\n```json\n\(payload)\n```\n\nThat's everything.",
            // A model that pretty-prints has abandoned line-delimitation but
            // not the contract; the objects are still there.
            payload.replacingOccurrences(of: "],\"", with: "],\n  \""),
        ]

        for form in forms {
            guard let outcome = parseAll(form) else { return XCTFail("failed to parse: \(form)") }
            XCTAssertEqual(outcome.conformance.count, 3, "wrong conformance count for: \(form)")
            XCTAssertEqual(outcome.accepted.count, 4, "wrong note count for: \(form)")
            XCTAssertEqual(outcome.facts.count, 1, "wrong fact count for: \(form)")
        }
    }

    /// Forward tolerance: a section this build has never heard of is skipped,
    /// and the sections around it still land.
    func test_unknownSectionsAreSkippedWithoutFailure() {
        XCTAssertNil(
            parseSection("{\"section\":\"prosody\",\"observations\":[{\"note\":\"x\"}]}"),
            "an unknown section yields nothing rather than a failure")

        let text = [
            conformanceLine,
            "{\"section\":\"prosody\",\"observations\":[{\"note\":\"x\"}]}",
            continuityLine,
        ].joined(separator: "\n")
        guard let outcome = parseAll(text) else { return XCTFail("expected an outcome") }

        XCTAssertEqual(outcome.conformance.count, 3)
        XCTAssertEqual(outcome.accepted.count, 2)
        XCTAssertEqual(outcome.droppedDangling, 0, "an unknown section is not a lost note")
    }

    func test_garbageEntriesInAKnownSectionAreDroppedNotFatal() {
        let line = """
            {"section":"continuity","questions":[\
            "not an object",\
            {"cites":"c","refs":["a1b2"],"question":"   "},\
            {"cites":"c","refs":["a1b2"],"question":"A real question?"}]}
            """
        guard let section = parseSection(line) else { return XCTFail("expected a section") }

        XCTAssertEqual(section.accepted.map { $0.body }, ["A real question?"])
        XCTAssertEqual(section.droppedDangling, 2)
    }

    func test_unusableSectionedOutputIsNilNotCrash() {
        let unusable = [
            "",
            "   \n  ",
            "The prose is going well; I have no notes.",
            "{\"section\":\"conformance\",\"checks\":[",
            "[\"conformance\"]",
            "{\"something_else\":true}",
            "null",
        ]

        for text in unusable {
            XCTAssertNil(parseAll(text), "expected nil for: \(text)")
            XCTAssertNil(parseSection(text), "expected nil for: \(text)")
        }
    }

    /// **Deliberately inverted, M3-P3 Task 4.** This was
    /// `test_v2MintsNoDriftNote`, and its second assertion pinned the ABSENCE
    /// of `intent_drift` from the schema: v2 dropped v1's drift field, and
    /// M2's replacement was `DriftDetector`'s clause-strain *pattern* across
    /// run records — nothing on the wire. P3 asks the question again, as a
    /// judged per-round verdict rather than v1's anchorless note, so the v2
    /// pin is retired and replaced by its opposite.
    ///
    /// What did NOT change is the half that was always the point: **no
    /// `Diagnostic` is minted from drift**. The verdict is a projection onto
    /// the run record, never a note with an id, an anchor and a reply field.
    func test_p3AsksForAnIntentDriftVerdict() {
        let text = [conformanceLine, continuityLine, readerLine, factsLine, intentDriftLine]
            .joined(separator: "\n")
        guard let outcome = parseAll(text) else { return XCTFail("expected an outcome") }

        XCTAssertTrue(
            outcome.accepted.allSatisfy { $0.kind != nil },
            "every v2 note carries a kind; kind == nil is the mark of a v1 record")
        XCTAssertTrue(
            CompilerPrompt.sectionSchemaDescription.contains(
                DiagnosticIngest.SectionField.intentDrift),
            "P3's contract asks the drift question as a fifth section")

        // The four note-bearing sections carry four notes and one fact
        // between them; the drift section adds neither.
        XCTAssertEqual(outcome.accepted.count, 4)
        XCTAssertEqual(outcome.facts.count, 1)
        XCTAssertEqual(outcome.intentDriftVerdict, DiagnosticIngest.SectionField.drifted)
    }

    // MARK: v2 — the intent-drift verdict (M3-P3 Task 4)

    func test_theDriftSectionYieldsItsVerdictAndNothingElse() {
        guard let section = parseSection(intentDriftLine) else {
            return XCTFail("expected an intent_drift section")
        }

        XCTAssertEqual(section.intentDriftVerdict, "drifted")
        XCTAssertEqual(section.accepted, [], "a verdict is not a note")
        XCTAssertEqual(section.facts, [])
        XCTAssertEqual(section.conformance, [])
        XCTAssertEqual(
            section.droppedDangling, 0,
            "the drift section can lose nothing the writer would have read")
    }

    func test_holdsIsTheOtherRecognisedVerdict() {
        let line = "{\"section\":\"intent_drift\",\"verdict\":\"holds\"}"
        XCTAssertEqual(parseSection(line)?.intentDriftVerdict, "holds")
    }

    /// The no-unknown-case discipline (tripwire 12's cousin, `TriageMark`'s
    /// rule): the verdict is a projection this build never re-encodes, so a
    /// word it does not recognise reads as no verdict at all rather than
    /// travelling into the sidecar to be drawn under a glyph nothing has.
    func test_anUnrecognisedVerdictReadsAsNoVerdict() {
        let unrecognised = [
            "{\"section\":\"intent_drift\",\"verdict\":\"maybe\"}",
            "{\"section\":\"intent_drift\",\"verdict\":\"\"}",
            "{\"section\":\"intent_drift\",\"verdict\":42}",
            "{\"section\":\"intent_drift\"}",
        ]
        for line in unrecognised {
            guard let section = parseSection(line) else {
                return XCTFail("the section still parses: \(line)")
            }
            XCTAssertNil(section.intentDriftVerdict, line)
        }

        // Control: the same line with a recognised verdict does yield one, so
        // the nils above are not an always-nil parser passing vacuously.
        XCTAssertEqual(
            parseSection("{\"section\":\"intent_drift\",\"verdict\":\"HOLDS\"}")?
                .intentDriftVerdict,
            "holds", "case is the model's business, not the contract's")
    }

    /// **A four-section v2 answer still ingests whole.** The fifth section is
    /// additive: an answer from a model that never saw it loses nothing, and
    /// the verdict is simply absent.
    func test_aFourSectionAnswerStillIngestsWholeWithNoVerdict() {
        let text = [conformanceLine, continuityLine, readerLine, factsLine]
            .joined(separator: "\n")
        guard let outcome = parseAll(text) else { return XCTFail("expected an outcome") }

        XCTAssertEqual(outcome.accepted.count, 4)
        XCTAssertEqual(outcome.conformance.count, 3)
        XCTAssertEqual(outcome.facts.count, 1)
        XCTAssertNil(outcome.intentDriftVerdict)
    }

    /// **The fold keeps the latest non-nil verdict**, which is what lets the
    /// verdict survive a stream: sections arrive one at a time and are folded
    /// through `combining`, so a drift section that arrives BEFORE the sections
    /// after it must not be erased by their nils.
    ///
    /// Falsification: delete `combining`'s `?? accumulated` and this goes red
    /// on the first assertion.
    func test_theFoldKeepsTheLatestNonNilVerdict() throws {
        let drift = try XCTUnwrap(parseSection(intentDriftLine))
        let facts = try XCTUnwrap(parseSection(factsLine))

        XCTAssertEqual(
            DiagnosticIngest.combining(drift, facts).intentDriftVerdict, "drifted",
            "a section with no verdict must not erase the one already folded in")
        XCTAssertEqual(
            DiagnosticIngest.combining(facts, drift).intentDriftVerdict, "drifted")

        // A model that restates the section: the later word wins, the same
        // way the final result replaces the stream.
        let holds = try XCTUnwrap(
            parseSection("{\"section\":\"intent_drift\",\"verdict\":\"holds\"}"))
        XCTAssertEqual(DiagnosticIngest.combining(drift, holds).intentDriftVerdict, "holds")
        XCTAssertNil(DiagnosticIngest.combining(.empty, facts).intentDriftVerdict)
    }

    /// **`letter` rides `combining` the same way `intentDriftVerdict` does:
    /// last non-nil wins.** Task 1 only — no section parses a letter yet, so
    /// this constructs `SectionedOutcome` directly rather than through
    /// `parseSection`.
    func test_theFoldCarriesTheLaterLetterOverTheEarlier() {
        let letter = Letter(
            about: "a letter", oneThing: nil, working: [], habits: [], questions: [],
            scenes: nil, scenePosition: nil)
        let withLetter = DiagnosticIngest.SectionedOutcome(
            accepted: [], facts: [], conformance: [], droppedDangling: 0, truncatedReader: 0,
            intentDriftVerdict: nil, letter: letter)
        let withoutLetter = DiagnosticIngest.SectionedOutcome.empty

        XCTAssertEqual(
            DiagnosticIngest.combining(withoutLetter, withLetter).letter, letter,
            "a later section's letter must be carried forward")
        XCTAssertEqual(
            DiagnosticIngest.combining(withLetter, withoutLetter).letter, letter,
            "an earlier letter must survive a later section with none")
    }

    /// **The model's sentence is read and dropped** (ADR 0027: nothing
    /// model-produced renders in the editor's chrome). The outcome has nowhere
    /// to put it, and the strip Task 5 draws is app-authored from the verdict
    /// alone.
    func test_theModelsDriftNoteNeverBecomesAnythingTheWriterReads() {
        let text = [conformanceLine, continuityLine, readerLine, factsLine, intentDriftLine]
            .joined(separator: "\n")
        guard let outcome = parseAll(text) else { return XCTFail("expected an outcome") }

        let prose = outcome.accepted.map(\.body)
            + outcome.accepted.compactMap(\.clauseQuote)
            + outcome.facts.map(\.fact)
            + outcome.conformance.map(\.clauseQuote)
        XCTAssertFalse(
            prose.contains { $0.contains("warmth the intent rules out") },
            "the drift note reached the writer through some other field")
    }

    func test_everyV2NoteAndFactGetsItsOwnId() {
        let text = [conformanceLine, continuityLine, readerLine, factsLine]
            .joined(separator: "\n")
        guard let outcome = parseAll(text) else { return XCTFail("expected an outcome") }

        let ids = outcome.accepted.map { $0.id } + outcome.facts.map { $0.id }
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(Set(ids).count, 5)
        XCTAssertFalse(ids.contains(""))
    }
    // MARK: v2 — the sixth section: the letter (editorial letter P1 Task 2)

    /// **Part for part.** Every part of the schema's letter object survives
    /// the parse with its prose intact, its refs resolved against live text
    /// and its excerpts filled — the excerpt is what a surface prints, and a
    /// letter whose refs carried ids and no words would put a four-character
    /// token in front of the writer (spec §5, requirement 3).
    func test_aFullLetterParsesPartForPart() throws {
        let section = try XCTUnwrap(parseSection(letterLine), "expected a letter section")
        let letter = try XCTUnwrap(section.letter, "the letter never reached the outcome")

        XCTAssertEqual(letter.about, "A woman waits out a fog that will not lift.")
        XCTAssertEqual(letter.oneThing, "Let the fog do less of the work.")

        XCTAssertEqual(letter.working.count, 1)
        XCTAssertEqual(letter.working.first?.what, "The opening image")
        XCTAssertEqual(letter.working.first?.why,
                       "It states the weather and the mood in one move.")
        XCTAssertEqual(letter.working.first?.refs.map(\.paragraphId), ["a1b2"])
        XCTAssertEqual(letter.working.first?.refs.first?.excerpt,
                       "The first paragraph, as it stands right now.",
                       "the ref carries the paragraph's words, not its id")

        XCTAssertEqual(letter.habits.count, 1)
        let habit = try XCTUnwrap(letter.habits.first)
        XCTAssertEqual(habit.name, "Filter words")
        XCTAssertEqual(habit.cost, "The reader is held one step back from the scene.")
        XCTAssertEqual(habit.lesson, "Cut the verb of perception and the perception stays.")
        XCTAssertEqual(habit.exercise,
                       "Read the second paragraph aloud with the names removed.")
        XCTAssertEqual(habit.refs.map(\.paragraphId), ["c3d4", "e5f6"])
        XCTAssertEqual(habit.refs.last?.excerpt,
                       "A longer paragraph whose opening runs past the\u{2026}",
                       "a long paragraph's ref is cut at the excerpt boundary")

        XCTAssertEqual(letter.questions.map(\.question),
                       ["Whose fear is this, hers or the narrator's?"])
        XCTAssertEqual(letter.questions.first?.refs.map(\.paragraphId), ["c3d4"])

        let scenes = try XCTUnwrap(letter.scenes, "the scenes rows were dropped")
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes.first?.wants, "To be let in")
        XCTAssertEqual(scenes.first?.changes, "Nothing")
        XCTAssertEqual(scenes.first?.turn, "",
                       "a blank cell is an observation, not a reason to drop the row")
        XCTAssertEqual(scenes.first?.charge, "-")
        XCTAssertNil(letter.scenePosition, "Task 3 stamps the position; the parse does not")
    }

    /// **The caps are enforced where the section arrives**, exactly as
    /// `readerReportCap` is, and the extras are dropped without being counted:
    /// a model writing four habits has not made the run lose anything the
    /// writer would have read, and `droppedDangling` must not say it did.
    func test_aHabitWithFiveRefsKeepsFour() throws {
        // Five DISTINCT live ids. `resolveRefs` dedupes, so a repeated id
        // would make this pass with no cap at all — which is exactly what the
        // disable experiment caught when the fifth ref was a repeat of the
        // first.
        let five = liveV2([
            "a1b2": "One.", "c3d4": "Two.", "e5f6": "Three.",
            "they": "Four.", "g7h8": "Five.",
        ])
        let line = """
            {"section":"letter","habits":[{"name":"Filter words",\
            "refs":["a1b2","c3d4","e5f6","they","g7h8"],"cost":"Distance."}]}
            """
        let section = try XCTUnwrap(parseSection(line, live: five))
        let habit = try XCTUnwrap(section.letter?.habits.first)
        XCTAssertEqual(habit.refs.map(\.paragraphId), ["a1b2", "c3d4", "e5f6", "they"],
                       "five claimed refs must be cut to the schema's four")
        XCTAssertEqual(section.droppedDangling, 0,
                       "a cap is not a loss the writer needs to be told about")
        XCTAssertNil(habit.lesson, "an absent lesson is nil, not empty")
        XCTAssertNil(habit.exercise)
    }

    func test_fourWorkingEntriesKeepThree() throws {
        let entries = (1...4).map {
            "{\"refs\":[],\"what\":\"Thing \($0)\",\"why\":\"Because \($0).\"}"
        }.joined(separator: ",")
        let section = try XCTUnwrap(
            parseSection("{\"section\":\"letter\",\"working\":[\(entries)]}"))
        XCTAssertEqual(section.letter?.working.map(\.what),
                       ["Thing 1", "Thing 2", "Thing 3"],
                       "the cap keeps the first three the model thought of")
        XCTAssertEqual(section.droppedDangling, 0)
    }

    func test_theLettersQuestionsAreCappedAtThree() throws {
        let entries = (1...4).map {
            "{\"refs\":[\"a1b2\"],\"question\":\"Question \($0)?\"}"
        }.joined(separator: ",")
        let section = try XCTUnwrap(
            parseSection("{\"section\":\"letter\",\"questions\":[\(entries)]}"))
        XCTAssertEqual(section.letter?.questions.map(\.question),
                       ["Question 1?", "Question 2?", "Question 3?"])
        XCTAssertEqual(section.accepted.count, 3,
                       "the fourth question must not mint a note the letter "
                       + "itself does not carry")
    }

    /// **The one place `resolveRefs`' dangling rule is NOT applied** (spec
    /// §3.1, global constraint 8). A note whose every claimed ref is dead is
    /// dropped, because a note is a pointer at a paragraph. A letter entry is
    /// not: a habit is still true when one of its instances was rewritten, so
    /// the entry keeps its prose and loses only its jump links — and
    /// `droppedDangling` does not move, because the letter is not a note and
    /// the pane's "lost some notes" seal must not appear over a whole report.
    func test_aDanglingRefLeavesTheWorkingEntryStandingAndCountsNothing() throws {
        let line = """
            {"section":"letter","working":[{"refs":["zzzz"],\
            "what":"The opening image","why":"It does two things at once."}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        let working = try XCTUnwrap(section.letter?.working.first,
                                    "the entry was dropped with its dead ref")
        XCTAssertEqual(working.what, "The opening image")
        XCTAssertEqual(working.refs, [], "the dead ref is gone from the entry")
        XCTAssertEqual(section.droppedDangling, 0,
                       "a letter's dangling ref is not a lost note")
    }

    /// The control for the rule above: the SAME dead id, in a continuity
    /// entry, still costs the entry and still increments the count. Without
    /// this the letter's exemption could be a parser that stopped counting.
    func test_control_aDanglingRefStillCostsAContinuityQuestion() throws {
        let line = """
            {"section":"continuity","questions":[{"cites":"the fog",\
            "refs":["zzzz"],"question":"Is the dock standing again?"}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.accepted, [], "a note with no live ref is dropped")
        XCTAssertEqual(section.droppedDangling, 1,
                       "…and the run says it lost one")
    }

    /// **A letter question with a live ref reaches the queue.** It is the one
    /// part of the letter that also becomes a `Diagnostic`, anchored on the
    /// first ref that resolved — the dead one before it in the list changes
    /// where it anchors and nothing else.
    func test_aQuestionMintsOneDiagnosticAnchoredOnItsFirstLiveRef() throws {
        let line = """
            {"section":"letter","questions":[{"refs":["zzzz","c3d4"],\
            "question":"Whose fear is this?"}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.accepted.count, 1)
        let note = try XCTUnwrap(section.accepted.first)
        XCTAssertEqual(note.kind, .letterQuestion,
                       "a coach's question and a continuity question are two "
                       + "kinds, so the fingerprint tells them apart")
        XCTAssertEqual(note.body, "Whose fear is this?")
        XCTAssertEqual(note.anchor?.paragraphId, "c3d4")
        XCTAssertEqual(note.anchor?.anchorText,
                       "The second paragraph, as it stands right now.",
                       "the anchor carries WHOLE live text — the staleness rule "
                       + "reads it and an excerpt would never match")
        XCTAssertNil(note.clauseQuote, "a letter question cites no clause")
        XCTAssertNil(note.category)
        XCTAssertEqual(note.refs?.map(\.paragraphId), ["c3d4"])
        XCTAssertEqual(section.letter?.questions.first?.question, "Whose fear is this?",
                       "the letter keeps its own copy for reading in place")

        // The split: it is a note the writer disposes of in the queue, and it
        // is not something the sidecar keeps a second copy of.
        XCTAssertEqual(section.mintable.count, 1)
        XCTAssertEqual(section.mintable.first?.kind, .query,
                       "a question asks the writer something — that is .query")
        XCTAssertEqual(section.mintable.first?.paragraphId, "c3d4")
        XCTAssertEqual(section.sidecarDiagnostics, [],
                       "one finding has one home, and a letter question's is the queue")
    }

    /// **A question with no surviving ref is letter-only** (constraint 8). It
    /// renders in place and never reaches the queue: a `.query` cannot be
    /// minted without an anchor, and a fingerprint needs an anchor or a
    /// clause, so a note here would be one the mint refuses and the dedupe
    /// cannot see.
    func test_aQuestionWithNoLiveRefIsLetterOnly() throws {
        let line = """
            {"section":"letter","questions":[{"refs":["zzzz"],\
            "question":"Is the fog doing the work?"}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.questions.map(\.question),
                       ["Is the fog doing the work?"],
                       "the letter still carries it")
        XCTAssertEqual(section.letter?.questions.first?.refs, [])
        XCTAssertEqual(section.accepted, [],
                       "…and nothing was minted for it")
        XCTAssertEqual(section.droppedDangling, 0)
    }

    /// A question that claims NO refs at all is the same case by a different
    /// road, and the schema's own escape hatch: an observation about the
    /// reading rather than about one paragraph.
    func test_aQuestionThatNamesNoParagraphMintsNothingEither() throws {
        let line = """
            {"section":"letter","questions":[{"refs":[],\
            "question":"Is this the book you meant to write?"}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.questions.count, 1)
        XCTAssertEqual(section.accepted, [])
    }

    /// **A letter is never refused for a missing say-back.** `about` is the
    /// one always-present part in the schema, and a model that skipped it has
    /// still written a letter the writer should read.
    func test_aMissingSayBackStillParsesTheLetter() throws {
        let line = """
            {"section":"letter","one_thing":"Let the fog do less of the work."}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.about, "")
        XCTAssertEqual(section.letter?.oneThing, "Let the fog do less of the work.")
    }

    /// The control for the sentence above: a section object with not one key
    /// this parser recognises yields no letter at all, rather than an empty
    /// one a surface would draw a heading over.
    func test_aSectionWithNoRecognisedKeyYieldsNoLetter() throws {
        for line in ["{\"section\":\"letter\"}",
                     "{\"section\":\"letter\",\"prose\":\"Dear writer,\"}"] {
            let section = try XCTUnwrap(parseSection(line), line)
            XCTAssertNil(section.letter, line)
            XCTAssertEqual(section.droppedDangling, 0, line)
        }
        // Control: one recognised key, even carrying an empty array, IS a letter.
        XCTAssertNotNil(
            parseSection("{\"section\":\"letter\",\"working\":[]}")?.letter,
            "an empty part is still an answer — the schema asks for the array")
    }

    /// `scenes` absent or null is `nil` and not `[]`: the position said there
    /// is nothing to say about scenes (a lyric piece), which is a different
    /// answer from a scene table with no rows in it.
    func test_scenesAbsentOrNullIsNil() throws {
        for line in ["{\"section\":\"letter\",\"about\":\"A fog.\"}",
                     "{\"section\":\"letter\",\"about\":\"A fog.\",\"scenes\":null}"] {
            let section = try XCTUnwrap(parseSection(line), line)
            XCTAssertNil(section.letter?.scenes, line)
        }
        XCTAssertEqual(
            parseSection("{\"section\":\"letter\",\"scenes\":[]}")?.letter?.scenes, [],
            "control: an empty table is an empty table")
    }

    /// An unrecognised charge is no charge, on `intentDriftVerdict`'s rule: a
    /// word this build cannot draw must not reach a surface with no glyph for
    /// it.
    func test_anUnrecognisedChargeReadsAsNoCharge() throws {
        let line = """
            {"section":"letter","scenes":[{"refs":[],"wants":"In",\
            "changes":"Nothing","turn":"","charge":"neutral"}]}
            """
        XCTAssertNil(try XCTUnwrap(parseSection(line)).letter?.scenes?.first?.charge)
        let plus = """
            {"section":"letter","scenes":[{"refs":[],"wants":"In",\
            "changes":"Nothing","turn":"","charge":"+"}]}
            """
        XCTAssertEqual(try XCTUnwrap(parseSection(plus)).letter?.scenes?.first?.charge, "+",
                       "control: the two the schema names do survive")
    }

    /// **The sixth section is additive in both directions.** A six-line answer
    /// yields a letter with every earlier section intact, and a five-line
    /// answer from before the letter existed still ingests whole.
    func test_aSixLineAnswerYieldsALetterAndEveryEarlierSectionIntact() throws {
        let text = [conformanceLine, continuityLine, readerLine, factsLine,
                    intentDriftLine, letterLine].joined(separator: "\n")
        let outcome = try XCTUnwrap(parseAll(text))

        XCTAssertEqual(outcome.conformance.count, 3)
        XCTAssertEqual(outcome.facts.count, 1)
        XCTAssertEqual(outcome.intentDriftVerdict, "drifted")
        XCTAssertNotNil(outcome.letter)
        XCTAssertEqual(outcome.accepted.count, 5,
                       "the four sections' four notes, plus the letter's one "
                       + "anchored question — got \(outcome.accepted.map(\.body))")
        XCTAssertEqual(outcome.accepted.filter { $0.kind == .letterQuestion }.count, 1)
        XCTAssertEqual(outcome.sidecarDiagnostics.map(\.kind), [.conformanceStrain],
                       "the letter's question left the sidecar with the others")
    }

    func test_anOldFiveLineAnswerStillParsesWithNoLetter() throws {
        let text = [conformanceLine, continuityLine, readerLine, factsLine,
                    intentDriftLine].joined(separator: "\n")
        let outcome = try XCTUnwrap(parseAll(text))
        XCTAssertNil(outcome.letter)
        XCTAssertEqual(outcome.accepted.count, 4)
        XCTAssertEqual(outcome.intentDriftVerdict, "drifted")
    }
    // MARK: v2 — the letter's two scrubs (controller ruling on Task 2's concern 1)

    /// **A letter entry whose prose names a paragraph id is dropped.** The
    /// schema's standing rule — refer to the prose by a short quotation, the
    /// way an editor would — is the letter's too, and the letter is the part
    /// the writer READS, so a four-character token in it is the most visible
    /// place the rule could break.
    ///
    /// Dropping is the only refusal this file has, and here it is the right
    /// one: unlike a dangling ref, which costs an entry a jump link it can
    /// live without, a leaked id is in the words themselves and there is no
    /// half of the entry worth showing.
    func test_aLeakedIdDropsTheWorkingEntryAndItsCleanTwinSurvives() throws {
        let line = """
            {"section":"letter","working":[\
            {"refs":["a1b2"],"what":"The opening image","why":"See [a1b2] for how it lands."},\
            {"refs":["c3d4"],"what":"The second turn","why":"It arrives without being announced."}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.working.map(\.what), ["The second turn"],
                       "the entry naming a live id must go, and its clean twin "
                       + "must not go with it")
        XCTAssertEqual(section.droppedDangling, 0,
                       "the letter is not a note \u{2014} neither scrub moves the "
                       + "count that says the register lost something")
    }

    /// The scrub reaches every prose field of every part, not just the one
    /// that was easy to reach. One test per field, each the same shape: the
    /// id in that field alone, the entry gone.
    func test_theScrubReachesEveryProsePartOfTheLetter() throws {
        let cases: [(String, String)] = [
            ("working what", """
                {"section":"letter","working":[{"refs":[],"what":"See [a1b2]","why":"It lands."}]}
                """),
            ("working why", """
                {"section":"letter","working":[{"refs":[],"what":"The image","why":"See [a1b2]."}]}
                """),
            ("habit name", """
                {"section":"letter","habits":[{"name":"The [a1b2] habit","cost":"Distance."}]}
                """),
            ("habit cost", """
                {"section":"letter","habits":[{"name":"Filter words","cost":"Worst at [a1b2]."}]}
                """),
            ("habit lesson", """
                {"section":"letter","habits":[{"name":"Filter words","cost":"Distance.",\
                "lesson":"Cut it, as at [a1b2]."}]}
                """),
            ("habit exercise", """
                {"section":"letter","habits":[{"name":"Filter words","cost":"Distance.",\
                "exercise":"Read [a1b2] aloud."}]}
                """),
            ("question", """
                {"section":"letter","questions":[{"refs":["c3d4"],\
                "question":"Whose fear is this in [a1b2]?"}]}
                """),
            ("scene wants", """
                {"section":"letter","scenes":[{"refs":[],"wants":"To reach [a1b2]",\
                "changes":"Nothing","turn":""}]}
                """),
            ("scene changes", """
                {"section":"letter","scenes":[{"refs":[],"wants":"In",\
                "changes":"Nothing, see [a1b2]","turn":""}]}
                """),
            ("scene turn", """
                {"section":"letter","scenes":[{"refs":[],"wants":"In",\
                "changes":"Nothing","turn":"At [a1b2]"}]}
                """),
        ]
        for (label, line) in cases {
            let section = try XCTUnwrap(parseSection(line), label)
            let letter = section.letter
            XCTAssertEqual(letter?.working ?? [], [], label)
            XCTAssertEqual(letter?.habits ?? [], [], label)
            XCTAssertEqual(letter?.questions ?? [], [], label)
            XCTAssertEqual(letter?.scenes ?? [], [], label)
            XCTAssertEqual(section.accepted, [], label)
            XCTAssertEqual(section.droppedDangling, 0, label)
        }
    }

    /// **`about` and `one_thing` are fields, not entries, so they are emptied
    /// rather than dropped.** There is no entry to lose, and losing the whole
    /// letter over one leaked token in the say-back would cost the writer
    /// everything the letter did get right — the opposite of the "a letter is
    /// never refused for a missing say-back" rule one field over.
    func test_aLeakedIdEmptiesTheSayBackAndTheOneThingRatherThanDroppingTheLetter() throws {
        let line = """
            {"section":"letter","about":"A woman waits, see [a1b2].",\
            "one_thing":"Cut [a1b2].",\
            "working":[{"refs":["c3d4"],"what":"The second turn","why":"It is unannounced."}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        let letter = try XCTUnwrap(section.letter, "the letter itself must survive")
        XCTAssertEqual(letter.about, "")
        XCTAssertNil(letter.oneThing)
        XCTAssertEqual(letter.working.map(\.what), ["The second turn"],
                       "control: the rest of the letter is untouched")
    }

    /// **A fix-shaped question is dropped, and it is dropped because it must
    /// never reach the QUEUE.** The letter's own doctrine is questions and
    /// nothing else; a `.letterQuestion` mints as a `.query` the writer is
    /// asked to answer, and "you should cut this" is not a question they can
    /// answer — it is the suggested change the register exists to refuse.
    func test_aFixShapedQuestionIsDroppedAndAPlainOneSurvives() throws {
        let line = """
            {"section":"letter","questions":[\
            {"refs":["a1b2"],"question":"You should cut the second paragraph."},\
            {"refs":["c3d4"],"question":"Whose fear is this?"}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.questions.map(\.question), ["Whose fear is this?"],
                       "the directive must go and the question must stay")
        XCTAssertEqual(section.accepted.map(\.body), ["Whose fear is this?"],
                       "\u{2026}and only the question reaches the queue")
        XCTAssertEqual(section.droppedDangling, 0)
    }

    /// **The exercise is exempt, on purpose, and this is the control that
    /// keeps the scrub from spreading.** Le Guin's feed-forward is a thing to
    /// go and DO — *rewrite the scene without a single "was"* — and it is
    /// phrased as a directive because that is what an exercise is. Scrubbing
    /// it would delete the one part of the letter that teaches (spec §3.1).
    func test_aFixShapedExerciseSurvivesBecauseAnExerciseIsADirective() throws {
        let line = """
            {"section":"letter","habits":[{"name":"Filter words","refs":["a1b2"],\
            "cost":"The reader is held one step back.",\
            "exercise":"Try rewriting the scene without a single verb of perception."}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.habits.first?.exercise,
                       "Try rewriting the scene without a single verb of perception.",
                       "an exercise is a thing to do, not a suggested change")

        // Control: the SAME words in a question are refused, so the exemption
        // is the exercise's and not a scrub that stopped working.
        let asQuestion = """
            {"section":"letter","questions":[{"refs":["a1b2"],\
            "question":"Try rewriting the scene without a single verb of perception."}]}
            """
        XCTAssertEqual(try XCTUnwrap(parseSection(asQuestion)).letter?.questions ?? [], [])
    }

    /// The scrub is not applied to the letter's other prose. A `what` reading
    /// like advice is an observation about the draft the writer reads in
    /// place and never answers, and the fix-shape list is a small hand-written
    /// one that would refuse real sentences if pointed at everything.
    func test_theFixShapeScrubIsAskedOfQuestionsOnly() throws {
        let line = """
            {"section":"letter","about":"You should read this as a ghost story.",\
            "working":[{"refs":[],"what":"The opening","why":"I recommend it as a model."}]}
            """
        let section = try XCTUnwrap(parseSection(line))
        XCTAssertEqual(section.letter?.about, "You should read this as a ghost story.")
        XCTAssertEqual(section.letter?.working.count, 1)
    }
}
