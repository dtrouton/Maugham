// MaughamTests/CompilerPromptTests.swift
import XCTest
@testable import Maugham

/// `CompilerPrompt` assembles what a compiler run sends to a spawned Claude:
/// the delta (new vs revised, differently labeled), the declared world (essay
/// + derived clauses/rules) and bible slice diffed in as one unit so a warm
/// session isn't re-sent what it already read, the pinned/palette listings
/// (ids and titles only — full contents are a tool call away), and the
/// section schema `DiagnosticIngest` depends on verbatim.
final class CompilerPromptTests: XCTestCase {

    private func makeDelta(
        new: [CompilerDelta.NewParagraph] = [],
        revised: [CompilerDelta.RevisedParagraph] = []
    ) -> CompilerDelta {
        CompilerDelta(new: new, revised: revised, newestOpId: "op9")
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
