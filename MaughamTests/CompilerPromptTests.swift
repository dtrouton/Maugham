// MaughamTests/CompilerPromptTests.swift
import XCTest
@testable import Maugham

/// `CompilerPrompt` assembles what a compiler run sends to a spawned Claude:
/// the delta (new vs revised, differently labeled), the resolved intent
/// (diffed in by hash so a warm session isn't re-sent the world), the pinned/
/// palette listings (ids and titles only — full contents are a tool call
/// away), the standing drift question, and the output-shape instruction Task
/// 6's parser depends on verbatim.
final class CompilerPromptTests: XCTestCase {

    private func makeContext(
        intentText: String? = "Keep it wry, keep it short.",
        intentScopeLabel: String = "this chapter",
        pinnedListing: [String] = [],
        paletteListing: [String] = []
    ) -> CompilerContext {
        CompilerContext(
            projectId: "proj-1", intentText: intentText,
            intentScopeLabel: intentScopeLabel, pinnedListing: pinnedListing,
            paletteListing: paletteListing)
    }

    private func makeDelta(
        new: [CompilerDelta.NewParagraph] = [],
        revised: [CompilerDelta.RevisedParagraph] = []
    ) -> CompilerDelta {
        CompilerDelta(new: new, revised: revised, newestOpId: "op9")
    }

    // MARK: - New vs revised labeling

    func test_revisionsCarryPrior_newDoesNot() {
        let delta = makeDelta(
            new: [.init(paragraphId: "a1b2", text: "Brand new sentence.")],
            revised: [.init(paragraphId: "c3d4", prior: "Old text.", text: "New text.")])

        let (message, _) = CompilerPrompt.runMessage(
            delta: delta, context: makeContext(), previousIntentHash: nil)

        // The new paragraph's text appears, but not paired with any "prior"
        // framing — it answers only to intent, per spec §3.2.
        XCTAssertTrue(message.contains("Brand new sentence."))
        XCTAssertTrue(message.contains("a1b2"))

        // The revised paragraph carries both halves.
        XCTAssertTrue(message.contains("Old text."))
        XCTAssertTrue(message.contains("New text."))
        XCTAssertTrue(message.contains("c3d4"))

        // The new section's own text never contains the word "prior" applied
        // to it — check by locating the new paragraph's line and asserting
        // no prior/before language sits beside it, while the revised section
        // does use before/after framing.
        let lines = message.components(separatedBy: "\n")
        let newLine = lines.first { $0.contains("Brand new sentence.") }
        XCTAssertNotNil(newLine)
        XCTAssertFalse((newLine ?? "").lowercased().contains("prior"))

        let revisedBlockStart = message.range(of: "c3d4")
        XCTAssertNotNil(revisedBlockStart)
    }

    func test_emptyDelta_stillProducesAValidMessage() {
        let (message, _) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: makeContext(), previousIntentHash: nil)
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Intent hash-diffing

    func test_intentIsDiffedIn_notResent() {
        let context = makeContext(intentText: "Keep it wry, keep it short.")

        let (firstMessage, firstHash) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: context, previousIntentHash: nil)
        XCTAssertNotNil(firstHash)
        XCTAssertTrue(firstMessage.contains("Keep it wry, keep it short."))

        // Same hash in => the intent text is not resent verbatim, replaced by
        // a marker saying it's unchanged.
        let (secondMessage, secondHash) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: context, previousIntentHash: firstHash)
        XCTAssertEqual(secondHash, firstHash)
        XCTAssertFalse(secondMessage.contains("Keep it wry, keep it short."))
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))

        // A different previousIntentHash => the intent text is embedded again.
        let (thirdMessage, thirdHash) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: context, previousIntentHash: "not-the-real-hash")
        XCTAssertEqual(thirdHash, firstHash)
        XCTAssertTrue(thirdMessage.contains("Keep it wry, keep it short."))
    }

    func test_nilIntent_producesNoIntentSectionAndNilHash() {
        let context = makeContext(intentText: nil)
        let (message, hash) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: context, previousIntentHash: nil)
        XCTAssertNil(hash)
        XCTAssertFalse(message.lowercased().contains("intent:"))
    }

    // MARK: - Pinned / palette listings

    func test_listingsCarryIdsAndToolNames_notContents() {
        let context = makeContext(
            pinnedListing: ["Chapter One (doc-abc)"],
            paletteListing: ["Villain sketch (card-xyz)"])

        let (message, _) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: context, previousIntentHash: nil)

        XCTAssertTrue(message.contains("Chapter One (doc-abc)"))
        XCTAssertTrue(message.contains("Villain sketch (card-xyz)"))
        XCTAssertTrue(message.contains("read_document"))
        XCTAssertTrue(message.contains("read_palette_card"))
    }

    func test_emptyListings_omitTheirSections() {
        let context = makeContext(pinnedListing: [], paletteListing: [])
        let (message, _) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: context, previousIntentHash: nil)

        XCTAssertFalse(message.lowercased().contains("pinned"))
        XCTAssertFalse(message.lowercased().contains("palette"))
    }

    // MARK: - Drift question

    func test_driftQuestionIsAlwaysAsked() {
        let (withIntent, _) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: makeContext(intentText: "Something."),
            previousIntentHash: nil)
        XCTAssertTrue(withIntent.lowercased().contains("drift"))

        let (withoutIntent, _) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: makeContext(intentText: nil),
            previousIntentHash: nil)
        XCTAssertTrue(withoutIntent.lowercased().contains("drift"))
    }

    // MARK: - Output schema instruction

    func test_outputSchemaInstruction_matchesDiagnosticIngestExpectations() {
        let schema = CompilerPrompt.outputSchemaDescription
        XCTAssertTrue(schema.contains("diagnostics"))
        XCTAssertTrue(schema.contains("paragraph_id"))
        XCTAssertTrue(schema.contains("category"))
        XCTAssertTrue(schema.contains("body"))
        XCTAssertTrue(schema.contains("intent_drift"))
        XCTAssertTrue(schema.lowercased().contains("exactly"))

        let (message, _) = CompilerPrompt.runMessage(
            delta: makeDelta(), context: makeContext(), previousIntentHash: nil)
        XCTAssertTrue(message.contains(schema))
    }

    // MARK: - Clean prose, no anchors

    func test_embeddedProseIsClean() {
        // Anchor comments live on their own line, ahead of a blank line and
        // the paragraph's text — the shape `Materializer` emits. Defense in
        // depth: the delta is expected to already carry clean text, but
        // `CompilerPrompt` must not let one through if it ever did.
        let delta = makeDelta(
            new: [.init(paragraphId: "a1b2", text: "<!-- \u{00b6}a1b2 -->\n\nSome prose.")],
            revised: [.init(
                paragraphId: "c3d4",
                prior: "<!-- \u{00b6}c3d4 -->\n\nOld prose.",
                text: "<!-- \u{00b6}c3d4 -->\n\nNew prose.")])

        let (message, _) = CompilerPrompt.runMessage(
            delta: delta, context: makeContext(), previousIntentHash: nil)

        XCTAssertFalse(message.contains("<!--"))
        XCTAssertFalse(message.contains("-->"))
    }

    // MARK: - Session preamble

    func test_sessionSystemPreamble_mentionsTasteNotSeverity() {
        let preamble = CompilerPrompt.sessionSystemPreamble(projectId: "proj-1")
        XCTAssertFalse(preamble.isEmpty)
        XCTAssertTrue(preamble.lowercased().contains("taste"))
        // No severity-rating instruction ("high/medium/low", a numeric
        // scale) — a compiler with taste doesn't rank its opinions, it just
        // may say there are none to rank.
        XCTAssertFalse(preamble.lowercased().contains("rating"))
        XCTAssertFalse(preamble.lowercased().contains("scale"))
    }

    // MARK: - v2 section schema

    private func makeWorld(
        clauses: [DerivedClause] = [], rules: [DerivedRule] = []
    ) -> DerivedWorld {
        DerivedWorld(
            sourceHash: "hash", clauses: clauses, rules: rules,
            derivedAt: Date(timeIntervalSince1970: 0))
    }

    private func makeFact(
        subject: String, fact: String, establishedAt: String? = nil
    ) -> BibleFact {
        BibleFact(
            id: "id-\(subject)-\(fact.hashValue)", subject: subject, fact: fact,
            establishedAt: establishedAt, docId: "doc-1",
            recordedAt: Date(timeIntervalSince1970: 0))
    }

    func test_sectionOrderIsFixed() {
        let schema = CompilerPrompt.sectionSchemaDescription
        guard let conformance = schema.range(of: "\"section\":\"conformance\""),
              let continuity = schema.range(of: "\"section\":\"continuity\""),
              let reader = schema.range(of: "\"section\":\"reader\""),
              let facts = schema.range(of: "\"section\":\"facts\"")
        else {
            return XCTFail("all four sections must be present")
        }
        XCTAssertLessThan(conformance.lowerBound, continuity.lowerBound)
        XCTAssertLessThan(continuity.lowerBound, reader.lowerBound)
        XCTAssertLessThan(reader.lowerBound, facts.lowerBound)
    }

    func test_refsArraysPresentForEverySection() {
        let schema = CompilerPrompt.sectionSchemaDescription
        let templateLines = schema.components(separatedBy: "\n")
            .filter { $0.contains("\"section\":") }
        XCTAssertEqual(templateLines.count, 4)
        for line in templateLines {
            XCTAssertTrue(line.contains("\"refs\""), line)
        }
    }

    func test_theSchemaForbidsIdsInProse() {
        let schema = CompilerPrompt.sectionSchemaDescription
        XCTAssertTrue(schema.contains("never contains a paragraph id"))
        XCTAssertTrue(schema.contains("short quotation"))
    }

    func test_theSchemaHasNowhereForYouShould() {
        let schema = CompilerPrompt.sectionSchemaDescription
        XCTAssertFalse(schema.lowercased().contains("severity"))
        XCTAssertFalse(schema.lowercased().contains("suggestion"))
        // Control: proves the substring check above actually exercises the
        // schema string, rather than a typo'd assertion passing vacuously.
        XCTAssertTrue(schema.lowercased().contains("status"))
    }

    func test_readerReportCapIsThree() {
        XCTAssertTrue(CompilerPrompt.sectionSchemaDescription.contains("at most 3"))
    }

    // MARK: - v2 run message

    func test_briefingEmbedsEssayWorldAndFacts() {
        let world = makeWorld(
            clauses: [.init(quote: "Keep it wry.", check: "tone stays wry")],
            rules: [.init(
                subject: "Kelly", quote: "Kelly only acts on what she's heard.",
                constraint: "never acts on offscreen knowledge")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (message, hash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Keep it wry, keep it short.",
            bibleFacts: facts, paletteListing: [], pinnedListing: [],
            previousBriefingHash: nil)

        XCTAssertNotNil(hash)
        XCTAssertTrue(message.contains("Keep it wry, keep it short."))
        XCTAssertTrue(message.contains("Keep it wry."))
        XCTAssertTrue(message.contains("Kelly only acts on what she's heard."))
        XCTAssertTrue(message.contains("Kelly grew up on the coast."))
        // Bible slice renders subject+fact only, never a paragraph id.
        XCTAssertTrue(message.contains("Kelly: Kelly grew up on the coast."))
    }

    func test_bibleFactsNeverEmbedTheirParagraphId() {
        let facts = [makeFact(subject: "Kelly", fact: "Kelly moved inland.", establishedAt: "a1b2")]
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: facts,
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertFalse(message.contains("a1b2"))
    }

    func test_briefingHash_nilWhenNothingDeclared() {
        let (message, hash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertNil(hash)
        XCTAssertFalse(message.lowercased().contains("unchanged"))
    }

    func test_theBriefingDiffsInAsOneUnit() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (firstMessage, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)
        XCTAssertTrue(firstMessage.contains("Essay text."))

        // Same content, previous hash matches: nothing re-embeds — a single
        // marker line replaces essay, world AND facts together.
        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], previousBriefingHash: firstHash)
        XCTAssertEqual(secondHash, firstHash)
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertFalse(secondMessage.contains("Keep it wry."))
        XCTAssertFalse(secondMessage.contains("Kelly grew up on the coast."))
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))

        // Only the facts changed — the hash still moves, and the WHOLE
        // briefing re-embeds (essay and world too), because the diff-in is
        // one unit, not three independently diffed pieces.
        let changedFacts = [makeFact(subject: "Kelly", fact: "Kelly moved inland.")]
        let (thirdMessage, thirdHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: changedFacts,
            paletteListing: [], pinnedListing: [], previousBriefingHash: firstHash)
        XCTAssertNotEqual(thirdHash, firstHash)
        XCTAssertTrue(thirdMessage.contains("Essay text."))
        XCTAssertTrue(thirdMessage.contains("Keep it wry."))
        XCTAssertTrue(thirdMessage.contains("Kelly moved inland."))
    }

    func test_listingsRenderAsInV1() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: ["Villain sketch (card-xyz)"],
            pinnedListing: ["Chapter One (doc-abc)"], previousBriefingHash: nil)
        XCTAssertTrue(message.contains("Chapter One (doc-abc)"))
        XCTAssertTrue(message.contains("Villain sketch (card-xyz)"))
        XCTAssertTrue(message.contains("read_document"))
        XCTAssertTrue(message.contains("read_palette_card"))
    }

    func test_v2DeltaLabelingMatchesV1() {
        let delta = makeDelta(
            new: [.init(paragraphId: "a1b2", text: "Brand new sentence.")],
            revised: [.init(paragraphId: "c3d4", prior: "Old text.", text: "New text.")])
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: delta, world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertTrue(message.contains("Brand new sentence."))
        XCTAssertTrue(message.contains("Old text."))
        XCTAssertTrue(message.contains("New text."))
    }

    func test_schemaIsAppendedToRunMessageV2() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertTrue(message.contains(CompilerPrompt.sectionSchemaDescription))
    }

    func test_essayAndWorldTextIsCleanedOfAnchors() {
        let essay = "<!-- \u{00b6}a1b2 -->\n\nEssay prose."
        let world = makeWorld(clauses: [.init(quote: "<!-- \u{00b6}c3d4 -->\n\nA clause.", check: "check")])
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: essay, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertFalse(message.contains("<!--"))
        XCTAssertFalse(message.contains("-->"))
    }
}
