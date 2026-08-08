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

    /// v2 drops `intent_drift` entirely (Stage 3 replaces it with a pattern
    /// computed from run records), and mints no drift note of its own.
    func test_v2MintsNoDriftNote() {
        let text = [conformanceLine, continuityLine, readerLine, factsLine]
            .joined(separator: "\n")
        guard let outcome = parseAll(text) else { return XCTFail("expected an outcome") }

        XCTAssertTrue(
            outcome.accepted.allSatisfy { $0.kind != nil },
            "every v2 note carries a kind; kind == nil is the mark of a v1 record")
        XCTAssertFalse(
            CompilerPrompt.sectionSchemaDescription.contains("intent_drift"),
            "the v2 contract has no drift field to parse")
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
}
