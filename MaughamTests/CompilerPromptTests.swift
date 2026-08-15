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

    // MARK: - The previous round (M3-P3 Task 3)
    //
    // Per-run state, and the reason it lives outside the hash-gated briefing
    // block: it changes every round, and folding it in would re-embed the
    // whole essay/world/bible block along with it every single time.

    private func makeRoundRecord(
        passId: String? = "line", round: Int? = 1
    ) -> RoundRecord {
        RoundRecord(runId: "run-1", at: Date(timeIntervalSince1970: 0), passId: passId,
                    round: round, freshEyes: nil, fingerprints: [])
    }

    private func makePriorRound(
        passId: String? = "line", round: Int? = 1,
        notes: [CompilerPrompt.PriorNote]
    ) -> CompilerPrompt.PriorRound {
        CompilerPrompt.PriorRound(
            record: makeRoundRecord(passId: passId, round: round), notes: notes)
    }

    private static let untouchedQuestion = CompilerPrompt.PriorNote(
        body: "Whose coat is on the chair?", kind: .continuity, sinceEdited: false)
    private static let editedStrain = CompilerPrompt.PriorNote(
        body: "The last line reaches for a sigh.", kind: .conformanceStrain,
        sinceEdited: true)

    func test_noPreviousRoundLeavesTheMessageAsItWas() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousRound: nil,
            previousBriefingHash: nil)
        XCTAssertFalse(message.lowercased().contains("raised these notes"))
        XCTAssertFalse(message.contains("Round 1"))
    }

    /// **Between the listings and the delta**, because it is context about the
    /// prose the delta is about to show — not part of the standing briefing
    /// above it, and not the thing being checked.
    func test_theRoundSectionSitsBetweenTheListingsAndTheDelta() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: ["Villain sketch (card-xyz)"],
            pinnedListing: ["Chapter One (doc-abc)"],
            previousRound: makePriorRound(notes: [Self.untouchedQuestion]),
            previousBriefingHash: nil)

        guard let listing = message.range(of: "Villain sketch (card-xyz)"),
              let round = message.range(of: "raised these notes"),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected listings, round section and delta; got \(message)") }
        XCTAssertLessThan(listing.lowerBound, round.lowerBound)
        XCTAssertLessThan(round.lowerBound, delta.lowerBound)
    }

    /// The register: it names the lane and the round, and it partitions the
    /// notes by whether the writer has since edited the prose behind them —
    /// which is the only thing the app knows that the model cannot work out
    /// for itself.
    func test_theRoundSectionNamesTheLaneAndPartitionsBySinceEdited() {
        guard let section = CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(passId: "line", round: 2),
            notes: [Self.untouchedQuestion, Self.editedStrain])
        else { return XCTFail("expected a section") }

        XCTAssertTrue(section.contains("Round 2 of the \u{201C}line\u{201D} pass"), section)
        XCTAssertTrue(section.contains("raised these notes"), section)
        XCTAssertTrue(section.contains("Whose coat is on the chair?"), section)
        XCTAssertTrue(section.contains("The last line reaches for a sigh."), section)

        guard let edited = section.range(of: "The last line reaches for a sigh."),
              let untouched = section.range(of: "Whose coat is on the chair?"),
              let editedHeading = section.range(of: CompilerPrompt.sinceEditedHeading),
              let untouchedHeading = section.range(of: CompilerPrompt.untouchedHeading)
        else { return XCTFail("expected both partitions; got \(section)") }
        XCTAssertLessThan(editedHeading.lowerBound, edited.lowerBound)
        XCTAssertLessThan(untouchedHeading.lowerBound, untouched.lowerBound)
        XCTAssertLessThan(edited.lowerBound, untouchedHeading.lowerBound,
                          "the edited-behind partition comes first — it is the half "
                          + "the model would otherwise re-raise against prose that "
                          + "has moved")
    }

    /// A partition with nothing in it says nothing at all — an empty heading
    /// is the model being told about a distinction it cannot use.
    func test_aPartitionWithNoNotesIsNotDrawn() {
        let section = CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(), notes: [Self.untouchedQuestion])
        XCTAssertNotNil(section)
        XCTAssertFalse(section?.contains(CompilerPrompt.sinceEditedHeading) ?? true,
                       "got: \(section ?? "nil")")
        XCTAssertTrue(section?.contains(CompilerPrompt.untouchedHeading) ?? false,
                      "control: the populated partition IS drawn")
    }

    /// **Confirm, not reconstruct.** The model's job this round is its own
    /// report; the previous round is context so it does not re-derive what it
    /// already said, and so it can let go of what the writer has answered.
    /// There is no fifth section for it to answer in — resolved / persisting /
    /// new is computed app-side from fingerprints, never parsed back.
    func test_theRoundSectionAsksForConfirmationNotReconstruction() {
        guard let section = CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(), notes: [Self.untouchedQuestion])
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.lowercased().contains("confirm"), section)
        // No new answer section is asked for anywhere in it.
        XCTAssertFalse(section.contains("\"section\""), section)
        XCTAssertFalse(section.lowercased().contains("resolved"), section)
    }

    /// Nothing to confirm is nothing to say. A round that raised no notes
    /// still counts (the pane's line reports it), but there is no briefing in
    /// it.
    func test_aPreviousRoundThatRaisedNothingIsNoSection() {
        XCTAssertNil(CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(), notes: []))
    }

    /// **The comparison lane is `(document, pass)`**, and this is the prompt's
    /// own half of that rule — a record with no lane, or with no round number,
    /// is not something the next round can be measured against. The
    /// orchestrator refuses first; this is the second door on the same room.
    func test_aRecordWithNoLaneOrNoRoundIsNoSection() {
        XCTAssertNil(CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(passId: nil, round: nil),
            notes: [Self.untouchedQuestion]))
        XCTAssertNil(CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(passId: "line", round: nil),
            notes: [Self.untouchedQuestion]))
        XCTAssertNotNil(CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(passId: "line", round: 1),
            notes: [Self.untouchedQuestion]),
            "control: a lane and a number is what makes it briefable")
    }

    /// **The round section must NEVER fold into the briefing hash.** It
    /// changes every round by construction, so a hash that covered it would
    /// never match — and every run would re-embed the whole essay, declared
    /// world and bible slice for nothing.
    ///
    /// Asserted from the returned hash AND from the elision it gates: the
    /// second message says "unchanged", carries no essay — and carries the
    /// round section all the same.
    func test_theRoundSectionNeverFoldsIntoTheBriefingHash() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], previousRound: nil,
            previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)

        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            previousRound: makePriorRound(notes: [Self.untouchedQuestion]),
            previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash,
                       "the intent did not move; a round section that folded into the "
                       + "hash would re-embed the whole briefing every round")
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertTrue(secondMessage.contains("Whose coat is on the chair?"),
                      "…and the round section still travels")
    }

    func test_theRoundSectionsNotesAreCleanedOfAnchors() {
        let note = CompilerPrompt.PriorNote(
            body: "<!-- \u{00b6}a1b2 -->\n\nWhose coat is it?", kind: .continuity,
            sinceEdited: false)
        guard let section = CompilerPrompt.roundSection(
            previousRound: makeRoundRecord(), notes: [note])
        else { return XCTFail("expected a section") }
        XCTAssertFalse(section.contains("<!--"))
        XCTAssertFalse(section.contains("-->"))
    }
}
