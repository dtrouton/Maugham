// MaughamTests/CompilerPromptTests.swift
import MaughamCore
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

    /// Five since M3-P3 Task 4: `intent_drift` is asked last, after the four
    /// note sections, because it is a verdict on the whole reading rather than
    /// one more thing found in it.
    ///
    /// **Six since the editorial letter (P1 Task 2), and the letter is now
    /// what comes last.** The order is a streaming decision, not a taxonomy:
    /// the writer reads line-level results while the letter is still being
    /// written, which is the tempo the guide already promises (spec §3.1).
    func test_sectionOrderIsFixed() {
        let schema = CompilerPrompt.sectionSchemaDescription
        guard let conformance = schema.range(of: "\"section\":\"conformance\""),
              let continuity = schema.range(of: "\"section\":\"continuity\""),
              let reader = schema.range(of: "\"section\":\"reader\""),
              let facts = schema.range(of: "\"section\":\"facts\""),
              let drift = schema.range(of: "\"section\":\"intent_drift\""),
              let letter = schema.range(of: "\"section\":\"letter\"")
        else {
            return XCTFail("all six sections must be present")
        }
        XCTAssertLessThan(conformance.lowerBound, continuity.lowerBound)
        XCTAssertLessThan(continuity.lowerBound, reader.lowerBound)
        XCTAssertLessThan(reader.lowerBound, facts.lowerBound)
        XCTAssertLessThan(facts.lowerBound, drift.lowerBound)
        XCTAssertLessThan(drift.lowerBound, letter.lowerBound,
                          "the letter is asked last, so the four note sections "
                          + "and the verdict have all streamed before it begins")
    }

    /// **`intent_drift` alone has no `refs` slot, and that is asserted rather
    /// than merely tolerated.** Of the two ways Task 4 could have kept this
    /// test true, the other — giving the drift section a `refs` array — would
    /// invite the model to anchor a judgement about the whole draft to one
    /// paragraph, and nothing downstream could read it: the verdict lands as a
    /// `String?` on the run record, never as a `Diagnostic` with an anchor. A
    /// field with no reader is a field that drifts.
    ///
    /// **The letter (P1 Task 2) joins the refs-carrying group**, and it is the
    /// verdict that stays alone. Every part of a letter that says something
    /// about the prose names the paragraphs it says it about, and one of them
    /// — a question — anchors a real note on its first resolving ref. The
    /// verdict is the one answer in the whole contract that is about the
    /// reading rather than about any of the words in it.
    func test_refsArraysPresentForEveryNoteSection() {
        let schema = CompilerPrompt.sectionSchemaDescription
        let templateLines = schema.components(separatedBy: "\n")
            .filter { $0.contains("\"section\":") }
        XCTAssertEqual(templateLines.count, 6)

        let driftName = "\"\(DiagnosticIngest.SectionField.intentDrift)\""
        let noteLines = templateLines.filter { !$0.contains(driftName) }
        XCTAssertEqual(noteLines.count, 5,
                       "five sections point at paragraphs; only the verdict does not")
        for line in noteLines {
            XCTAssertTrue(line.contains("\"refs\""), line)
        }

        let driftLine = templateLines.filter { $0.contains(driftName) }
        XCTAssertEqual(driftLine.count, 1)
        XCTAssertFalse(
            driftLine[0].contains("\"refs\""),
            "the drift verdict is about the reading, not about a paragraph")
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

    /// **The whole sentence, not the number.** This used to match the bare
    /// substring "at most 3", which was enough while the schema said it once.
    /// The letter's general instruction (P1 Task 2) says "at most 3 questions"
    /// in the same string, so the loose match would now survive the reader's
    /// own cap being deleted — a guard weakened by an unrelated addition is
    /// the exact shape of a test that stops guarding without going red.
    func test_readerReportCapIsThree() {
        XCTAssertTrue(
            CompilerPrompt.sectionSchemaDescription
                .contains("reader section holds at most 3 entries"),
            "the reader's own cap must be asked for in its own words")
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

    // MARK: - The pass's editor and brief (M4 P1 Task 4)

    /// A lane as the run resolves it — through `ReviewPass`'s own
    /// `effectiveEditorName`/`effectiveBrief`, which is what production does.
    /// Spelled once here so a test naming "copyedit" gets Gould without
    /// restating the resolution.
    private func lane(_ passId: String) -> CompilerOrchestrator.ActivePass {
        let pass = ReviewPass.presets.first { $0.id == passId }
            ?? ReviewPass(id: passId, name: passId)
        return CompilerOrchestrator.ActivePass(
            id: pass.id, name: pass.name, editorName: pass.effectiveEditorName,
            brief: pass.effectiveBrief)
    }

    /// **The role frame and the doctrine, in the model's own second person.**
    /// A named editor is not paint: the round carries that editor's register,
    /// and the brief is what says what the register attends to.
    func test_thePassSectionCarriesTheEditorAndTheBrief() {
        guard let section = CompilerPrompt.passSection(lane("copyedit"))
        else { return XCTFail("a briefed lane must produce a section") }
        XCTAssertTrue(section.contains("You are Gould"), section)
        XCTAssertTrue(section.contains("Copyedit"), section)
        let brief = try? XCTUnwrap(ReviewPass.presets.first { $0.id == "copyedit" }?.brief)
        XCTAssertTrue(section.contains(brief ?? "\u{0}"),
                      "the pass's own brief must travel verbatim; got \(section)")
    }

    /// A custom pass nobody has written a brief for gets the honest fallback
    /// rather than silence: the name is the only doctrine there is, so the
    /// altitude it suggests is what the round is told to read at.
    func test_aPassWithNoBriefGetsTheAltitudeFallback() {
        let custom = CompilerOrchestrator.ActivePass(
            id: "vibes", name: "Vibes", editorName: "Marta", brief: nil)
        guard let section = CompilerPrompt.passSection(custom)
        else { return XCTFail("a briefless lane still frames its editor") }
        XCTAssertTrue(section.contains("You are Marta"), section)
        XCTAssertTrue(section.contains(CompilerPrompt.brieflessPassFallback), section)
        XCTAssertTrue(section.contains("Vibes"),
                      "the fallback's whole content is the pass's name; got \(section)")
    }

    /// A brief the writer emptied is a brief they do not have.
    /// `ReviewPass.effectiveBrief` lets a stored empty string win over the
    /// preset's doctrine — correct for resolution, and a blank line under the
    /// role frame here.
    func test_aBriefTheWriterEmptiedReadsAsNoBriefAtAll() {
        let emptied = CompilerOrchestrator.ActivePass(
            id: "copyedit", name: "Copyedit", editorName: "Gould", brief: "   ")
        guard let section = CompilerPrompt.passSection(emptied)
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.contains(CompilerPrompt.brieflessPassFallback), section)
        XCTAssertFalse(section.hasSuffix("\n"), section)
    }

    /// A passless \u{2318}R is an ordinary M2 run: no editor, no register, no
    /// section. The message must read exactly as it did before passes existed.
    func test_aPasslessRunHasNoPassSection() {
        XCTAssertNil(CompilerPrompt.passSection(nil))
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], pass: nil,
            previousBriefingHash: nil)
        XCTAssertFalse(message.contains("You are "), message)
    }

    /// With the round section, between the listings and the delta — context
    /// about the reading rather than part of the standing briefing above it.
    func test_thePassSectionSitsBetweenTheListingsAndTheDelta() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: ["Villain sketch (card-xyz)"], pinnedListing: [],
            pass: lane("copyedit"), previousBriefingHash: nil)
        guard let listing = message.range(of: "Villain sketch (card-xyz)"),
              let frame = message.range(of: "You are Gould"),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected listings, pass frame and delta; got \(message)") }
        XCTAssertLessThan(listing.lowerBound, frame.lowerBound)
        XCTAssertLessThan(frame.lowerBound, delta.lowerBound)
    }

    // MARK: - The writer's dispositions (M4 P1 Task 4)

    private static let standingQuestion = CompilerAnnotationDisposition(
        fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
        excerpt: "Has anyone said how long yet?", state: .standing, reason: nil)
    private static let declinedReport = CompilerAnnotationDisposition(
        fingerprint: "reader\u{1f}\u{1f}p2\u{1f}belief",
        excerpt: "The reader stopped believing the fog.", state: .declined,
        reason: "The fog is deliberately unmeasured.")

    /// **The two halves say opposite things and must not be confused.** A
    /// standing note is live — confirm it or let it resolve, but never raise
    /// it again as news. A settled one is the writer's answer, and raising it
    /// in any section is asking them to answer it twice.
    func test_theDispositionsSectionPartitionsStandingFromSettled() {
        guard let section = CompilerPrompt.dispositionsSection(
            [Self.standingQuestion, Self.declinedReport])
        else { return XCTFail("expected a section") }

        XCTAssertTrue(section.contains(CompilerPrompt.standingNotesHeading), section)
        XCTAssertTrue(section.contains(CompilerPrompt.settledNotesHeading), section)
        XCTAssertTrue(section.contains("Has anyone said how long yet?"), section)
        XCTAssertTrue(section.contains("DECLINED"), section)
        XCTAssertTrue(section.contains("The fog is deliberately unmeasured."),
                      "the writer's own reason is the whole point of briefing "
                      + "the verdict; got \(section)")

        guard let standing = section.range(of: "Has anyone said how long yet?"),
              let standingHeading = section.range(of: CompilerPrompt.standingNotesHeading),
              let settledHeading = section.range(of: CompilerPrompt.settledNotesHeading),
              let settled = section.range(of: "The reader stopped believing the fog.")
        else { return XCTFail("expected both partitions; got \(section)") }
        XCTAssertLessThan(standingHeading.lowerBound, standing.lowerBound)
        XCTAssertLessThan(standing.lowerBound, settledHeading.lowerBound)
        XCTAssertLessThan(settledHeading.lowerBound, settled.lowerBound)
    }

    /// Every settled verdict is named, and each carries the writer's words
    /// when they wrote any.
    func test_everySettledVerdictHasItsOwnWord() {
        let settled = [
            CompilerAnnotationDisposition(
                fingerprint: nil, excerpt: "A", state: .declined, reason: "no time"),
            CompilerAnnotationDisposition(
                fingerprint: nil, excerpt: "B", state: .stetted, reason: nil),
            CompilerAnnotationDisposition(
                fingerprint: nil, excerpt: "C", state: .rejected, reason: "wrong reading"),
        ]
        guard let section = CompilerPrompt.dispositionsSection(settled)
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.contains("DECLINED: no time"), section)
        XCTAssertTrue(section.contains("STETTED"), section)
        XCTAssertTrue(section.contains("REJECTED: wrong reading"), section)
        XCTAssertFalse(section.contains(CompilerPrompt.standingNotesHeading),
                       "a partition with nothing in it is a distinction the "
                       + "model cannot use; got \(section)")
    }

    /// **A finding cannot be both live and answered.** The mint's dedupe stops
    /// two OPEN notes sharing a fingerprint, but nothing stops an open note
    /// sharing one with a settled twin — and briefing both would tell the
    /// model to confirm and to forget the same thing. The live note wins:
    /// it is the one in the writer's queue right now.
    func test_aStandingFingerprintSilencesItsSettledTwin() {
        let twin = CompilerAnnotationDisposition(
            fingerprint: Self.standingQuestion.fingerprint,
            excerpt: "An older wording of the same question.", state: .rejected,
            reason: "answered in the draft")
        guard let section = CompilerPrompt.dispositionsSection(
            [Self.standingQuestion, twin])
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.contains("Has anyone said how long yet?"), section)
        XCTAssertFalse(section.contains("An older wording of the same question."),
                       "the settled twin of a standing finding must not be "
                       + "briefed; got \(section)")
        XCTAssertFalse(section.contains(CompilerPrompt.settledNotesHeading), section)
    }

    /// A note with no fingerprint is the anchorless kind — a doc-scoped craft
    /// note — and this section is its ONLY duplicate guard on a warm round.
    /// Two of them must both be briefed rather than collapsing into one
    /// "nil" bucket.
    func test_fingerprintlessNotesAreBriefedIndividually() {
        let notes = [
            CompilerAnnotationDisposition(
                fingerprint: nil, excerpt: "The outline promised a scene.",
                state: .standing, reason: nil),
            CompilerAnnotationDisposition(
                fingerprint: nil, excerpt: "The ending arrives twice.",
                state: .standing, reason: nil),
        ]
        guard let section = CompilerPrompt.dispositionsSection(notes)
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.contains("The outline promised a scene."), section)
        XCTAssertTrue(section.contains("The ending arrives twice."), section)
    }

    func test_aPieceWithNoCompilerNotesGetsNoDispositionsSection() {
        XCTAssertNil(CompilerPrompt.dispositionsSection([]))
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], dispositions: [],
            previousBriefingHash: nil)
        XCTAssertFalse(message.contains(CompilerPrompt.standingNotesHeading), message)
        XCTAssertFalse(message.contains(CompilerPrompt.settledNotesHeading), message)
    }

    /// **The settled list is capped and the standing list is not**, and the
    /// asymmetry is deliberate: settled notes accumulate for the life of the
    /// piece, while the standing ones are what the writer is holding right now
    /// and are the duplicate guard the fresh path leans on. A truncated
    /// standing list mints duplicates.
    func test_theSettledListIsCappedAndSaysSo() {
        let many = (0..<(CompilerPrompt.settledDispositionLimit + 3)).map { index in
            CompilerAnnotationDisposition(
                fingerprint: "fp-\(index)", excerpt: "Settled note \(index)",
                state: .stetted, reason: nil)
        }
        guard let section = CompilerPrompt.dispositionsSection(many)
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.contains("Settled note 0"),
                      "the newest settled notes are the ones briefed")
        XCTAssertFalse(
            section.contains("Settled note \(CompilerPrompt.settledDispositionLimit + 2)"),
            "the cap did nothing; got \(section)")
        XCTAssertTrue(section.contains("3 more"),
                      "a silent truncation reads as a shorter history than the "
                      + "writer has; got \(section)")
    }

    func test_manyStandingNotesAreAllBriefed() {
        let many = (0..<(CompilerPrompt.settledDispositionLimit + 3)).map { index in
            CompilerAnnotationDisposition(
                fingerprint: "fp-\(index)", excerpt: "Standing note \(index)",
                state: .standing, reason: nil)
        }
        guard let section = CompilerPrompt.dispositionsSection(many)
        else { return XCTFail("expected a section") }
        for index in 0..<(CompilerPrompt.settledDispositionLimit + 3) {
            XCTAssertTrue(section.contains("Standing note \(index)"),
                          "standing note \(index) was dropped; got \(section)")
        }
    }

    /// A note's body is the model's own prose from an earlier round, so it can
    /// be a paragraph long and it can carry an anchor comment if anything ever
    /// let one through. Neither belongs in a briefing line.
    func test_dispositionExcerptsAreCleanedAndShortened() {
        let long = String(repeating: "word ", count: 200)
        let note = CompilerAnnotationDisposition(
            fingerprint: nil, excerpt: "<!-- \u{00b6}a1b2 -->\n\n" + long,
            state: .standing, reason: nil)
        guard let section = CompilerPrompt.dispositionsSection([note])
        else { return XCTFail("expected a section") }
        XCTAssertFalse(section.contains("<!--"), section)
        XCTAssertFalse(section.contains("-->"), section)
        XCTAssertLessThan(section.count, long.count,
                          "the excerpt was embedded whole; got \(section.count) chars")
        XCTAssertTrue(section.contains("\u{2026}"),
                      "a shortened excerpt says it was shortened")
    }

    func test_theDispositionsSectionSitsBetweenTheListingsAndTheDelta() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: ["Villain sketch (card-xyz)"], pinnedListing: [],
            dispositions: [Self.standingQuestion], previousBriefingHash: nil)
        guard let listing = message.range(of: "Villain sketch (card-xyz)"),
              let standing = message.range(of: CompilerPrompt.standingNotesHeading),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected listings, dispositions and delta; got \(message)") }
        XCTAssertLessThan(listing.lowerBound, standing.lowerBound)
        XCTAssertLessThan(standing.lowerBound, delta.lowerBound)
    }

    /// **Neither new section may fold into the briefing hash**, for the round
    /// section's own reason: both change with the writer rather than with the
    /// declared world, so a hash covering either would never match its
    /// predecessor and the essay, the declared world and the bible slice would
    /// re-embed in full on every \u{2318}R.
    func test_neitherThePassNorTheDispositionsFoldIntoTheBriefingHash() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], pass: nil, dispositions: [],
            previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)

        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], pass: lane("copyedit"),
            dispositions: [Self.standingQuestion, Self.declinedReport],
            previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash,
                       "the intent did not move; a pass or a disposition that "
                       + "folded into the hash would re-embed the whole briefing "
                       + "every round")
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertTrue(secondMessage.contains("You are Gould"),
                      "\u{2026}and both new sections still travel")
        XCTAssertTrue(secondMessage.contains("Has anyone said how long yet?"))
    }

    // MARK: - The emitter: an Annotation becomes a disposition (M4 P1 Task 4)
    //
    // **The 1C-b lesson, one milestone on.** That slice shipped a rule whose
    // renderer was tested from hand-built values while the EMITTER that made
    // them had no test at all, so a half of the rule was unreachable and
    // nothing was red. Every test above this line builds its own
    // `CompilerAnnotationDisposition`; without the ones below, deleting
    // `init?(annotation:)`'s authorship guard leaves the whole gate green
    // while the writer's own notes — and Claude Desktop's — are briefed as
    // "settled, do not raise again", instructing the model to suppress
    // findings it never raised.

    private func annotation(
        id: String = "a-1",
        body: String = "Has anyone said how long yet?",
        status: AnnotationStatus,
        userResponse: String? = nil,
        resolvedAt: Date? = nil,
        previousRejectionReason: String? = nil,
        triage: TriageMark? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        compilerRunId: String? = "run-1",
        compilerFingerprint: String? = "continuity\u{1f}the fog\u{1f}p1\u{1f}"
    ) -> Annotation {
        Annotation(
            id: id, kind: .query, paragraphId: "p1", body: body,
            suggestedText: nil, priorText: nil, createdAt: createdAt,
            createdBySession: nil, status: status, userResponse: userResponse,
            resolvedAt: resolvedAt, isStale: false,
            previousRejectionReason: previousRejectionReason, triage: triage,
            compilerRunId: compilerRunId, compilerFingerprint: compilerFingerprint)
    }

    /// **Only what the compiler wrote.** The writer's own notes and Claude
    /// Desktop's are theirs; briefing the model on what it must not re-raise
    /// makes sense only for findings it raised, and telling it to suppress a
    /// note it never wrote is telling it to ignore the piece.
    func test_aNoteTheCompilerDidNotWriteIsNoDisposition() {
        XCTAssertNil(CompilerAnnotationDisposition(
            annotation: annotation(status: .open, compilerRunId: nil,
                                   compilerFingerprint: nil)),
            "a hand-written note reached the dispositions briefing")
        XCTAssertNotNil(CompilerAnnotationDisposition(
            annotation: annotation(status: .open)),
            "control: the same note with a run id on it IS the compiler's")
    }

    /// The whole mapping, in one table — every status the projection has an
    /// opinion about, and both branches of the reason chain.
    func test_everyAnnotationStateMapsToItsDisposition() {
        let settled = Date(timeIntervalSince1970: 100)
        let cases: [(name: String, input: Annotation,
                     expected: CompilerAnnotationDisposition?)] = [
            ("open, untriaged",
             annotation(status: .open),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .standing,
                   reason: nil)),
            ("open, marked do \u{2014} still standing",
             annotation(status: .open, triage: .do),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .standing,
                   reason: nil)),
            ("open, marked decline \u{2014} no words anywhere",
             annotation(status: .open, triage: .decline),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .declined,
                   reason: nil)),
            // The second branch of `userResponse ?? previousRejectionReason`:
            // a note the writer rejected with a reason, reopened, and has now
            // marked decline. The reason is still part of this note's record
            // (RULING-31) and is the only prose the decline has.
            ("open, marked decline, carrying a prior rejection's reason",
             annotation(status: .open, previousRejectionReason: "The fog is on purpose.",
                        triage: .decline),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .declined,
                   reason: "The fog is on purpose.")),
            ("stetted \u{2014} the words stand",
             annotation(status: .stetted, userResponse: "It reads right to me.",
                        resolvedAt: settled),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .stetted,
                   reason: "It reads right to me.")),
            ("rejected \u{2014} settled no",
             annotation(status: .rejected, userResponse: "Wrong reading.",
                        resolvedAt: settled),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .rejected,
                   reason: "Wrong reading.")),
            // A live resolution's own words win over the history.
            ("rejected with both \u{2014} the live response wins",
             annotation(status: .rejected, userResponse: "Wrong reading.",
                        resolvedAt: settled,
                        previousRejectionReason: "An older no."),
             .init(fingerprint: "continuity\u{1f}the fog\u{1f}p1\u{1f}",
                   excerpt: "Has anyone said how long yet?", state: .rejected,
                   reason: "Wrong reading.")),
            // The writer ACTED on it: the prose it named has moved, so the
            // finding is either gone or honestly news again.
            ("accepted \u{2014} nothing to brief",
             annotation(status: .accepted, resolvedAt: settled), nil),
            // Set aside unread, so there is no verdict to state on the
            // writer's behalf.
            ("archived \u{2014} nothing to brief",
             annotation(status: .archived, resolvedAt: settled), nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                CompilerAnnotationDisposition(annotation: testCase.input),
                testCase.expected, testCase.name)
        }
    }

    /// **The cap must spend its words on what the writer settled most
    /// recently, not on what the model raised most recently.** The two orders
    /// come apart the moment a writer works through a backlog:
    /// `Document.annotations` is `createdAt`-descending, and a question raised
    /// in round 1 and answered this morning is the one whose prose they are
    /// still near.
    func test_settledDispositionsAreOrderedByWhenTheyWereSettled() {
        let raisedLate = annotation(
            id: "late-raise", body: "Raised yesterday, settled last week.",
            status: .rejected, userResponse: "no",
            resolvedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 90),
            compilerFingerprint: "fp-late-raise")
        let settledLate = annotation(
            id: "late-settle", body: "Raised long ago, settled this morning.",
            status: .rejected, userResponse: "no",
            resolvedAt: Date(timeIntervalSince1970: 900),
            createdAt: Date(timeIntervalSince1970: 10),
            compilerFingerprint: "fp-late-settle")

        // Arrival order is `Document.annotations`' own: newest CREATED first.
        let gathered = CompilerAnnotationDisposition.gather(
            from: [raisedLate, settledLate])
        XCTAssertEqual(gathered.map(\.excerpt),
                       ["Raised long ago, settled this morning.",
                        "Raised yesterday, settled last week."],
                       "the settled half must be ordered by resolution, not by "
                       + "the order it arrived in")

        guard let section = CompilerPrompt.dispositionsSection(gathered),
              let first = section.range(of: "Raised long ago"),
              let second = section.range(of: "Raised yesterday")
        else { return XCTFail("expected both settled notes in the section") }
        XCTAssertLessThan(first.lowerBound, second.lowerBound,
                          "…and the section renders what it is handed")
    }

    /// A triage decline is a mark, not a resolution, so it has no date to sort
    /// on: it follows every dated verdict, and ties fall back on arrival order
    /// rather than on nothing — `sorted(by:)` is not stable, and an unstable
    /// order would reshuffle the briefing between two runs with nothing
    /// changed.
    func test_undatedDeclinesSortAfterDatedVerdictsAndKeepArrivalOrder() {
        let declineA = annotation(
            id: "d-a", body: "Decline A", status: .open, triage: .decline,
            compilerFingerprint: "fp-a")
        let declineB = annotation(
            id: "d-b", body: "Decline B", status: .open, triage: .decline,
            compilerFingerprint: "fp-b")
        let rejected = annotation(
            id: "r", body: "Rejected", status: .rejected, userResponse: "no",
            resolvedAt: Date(timeIntervalSince1970: 5),
            compilerFingerprint: "fp-r")

        XCTAssertEqual(
            CompilerAnnotationDisposition
                .gather(from: [declineA, declineB, rejected]).map(\.excerpt),
            ["Rejected", "Decline A", "Decline B"])
        XCTAssertEqual(
            CompilerAnnotationDisposition
                .gather(from: [declineB, declineA, rejected]).map(\.excerpt),
            ["Rejected", "Decline B", "Decline A"],
            "arrival order is the tie-break, and it must be honoured rather "
            + "than reshuffled")
    }

    /// The standing half is neither sorted nor capped: it is what the writer
    /// is holding, its order is the deriver's, and truncating it mints
    /// duplicates.
    func test_gatherPutsStandingFirstAndLeavesItsOrderAlone() {
        let standingA = annotation(id: "s-a", body: "Standing A", status: .open,
                                   compilerFingerprint: "fp-sa")
        let standingB = annotation(id: "s-b", body: "Standing B", status: .open,
                                   compilerFingerprint: "fp-sb")
        let settled = annotation(id: "x", body: "Settled", status: .stetted,
                                 resolvedAt: Date(timeIntervalSince1970: 5),
                                 compilerFingerprint: "fp-x")
        XCTAssertEqual(
            CompilerAnnotationDisposition
                .gather(from: [settled, standingA, standingB]).map(\.excerpt),
            ["Standing A", "Standing B", "Settled"])
    }

    /// A long free-text rejection reason is the writer's own prose in a field
    /// with no length rule, and a newline in it breaks one bullet into what
    /// reads as several notes.
    func test_aReasonIsShortenedAndCollapsedLikeAnExcerpt() {
        let note = CompilerAnnotationDisposition(
            fingerprint: nil, excerpt: "Short enough.", state: .rejected,
            reason: "Because\nof\nreasons. " + String(repeating: "word ", count: 200))
        guard let section = CompilerPrompt.dispositionsSection([note])
        else { return XCTFail("expected a section") }
        XCTAssertEqual(section.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }.count, 1,
            "the reason's newlines split one note into several; got \(section)")
        XCTAssertTrue(section.contains("\u{2026}]"),
                      "a shortened reason says it was shortened; got \(section)")
    }

    // MARK: - The spike's three disciplines (M4 P1 Task 4)

    /// The three instruction-side additions ride the schema's own surrounding
    /// prose, so they reach every run — warm, cold, passless alike. Pinned by
    /// distinctive phrase rather than whole text: the wording is the author's
    /// to improve, the discipline is not.
    func test_theSchemaCarriesTheReaderBarTheDedupAndTheDriftStabilizer() {
        let schema = CompilerPrompt.sectionSchemaDescription
        for instruction in [CompilerPrompt.formOnItsOwnTermsInstruction,
                            CompilerPrompt.readerBarInstruction,
                            CompilerPrompt.crossSectionDedupInstruction,
                            CompilerPrompt.driftStabilizerInstruction] {
            XCTAssertTrue(schema.contains(instruction),
                          "the schema stopped carrying: \(instruction)")
        }
        // The disciplines themselves, by the phrase each turns on.
        XCTAssertTrue(CompilerPrompt.readerBarInstruction.contains("empty"),
                      "the reader bar's whole job is to make an empty array the "
                      + "expected answer")
        // **Not scoped to the reader section** (M4 P1 review, minor 6): an
        // unconventional form is mistaken for a mistake in all four, and the
        // copyedit register is where it bites hardest.
        XCTAssertTrue(CompilerPrompt.formOnItsOwnTermsInstruction
            .contains("every section"))
        XCTAssertFalse(CompilerPrompt.readerBarInstruction
            .contains("unconventional"),
            "the form rule must not be scoped to the reader section")
        XCTAssertTrue(CompilerPrompt.crossSectionDedupInstruction
            .contains("One issue gets one entry"))
        XCTAssertTrue(CompilerPrompt.driftStabilizerInstruction
            .lowercased().contains("direction"))
    }

    /// **Exactly six section lines, and the sixth is the letter.**
    ///
    /// This began life as `test_theDisciplinesAddedNoSixthSection`: the
    /// disciplines are instruction text around the schema, and the point was
    /// that instruction prose must never smuggle a section in with it. That
    /// point is unchanged — a seventh line still fails here — but the number
    /// moved once, consciously, when the editorial letter (P1 Task 2) became
    /// the sixth section. It is LAST because it is written about the reading
    /// as a whole rather than found in it, so the writer is reading the four
    /// note sections and the drift verdict while the letter is still being
    /// composed (spec §3.1). The count is asserted here and the ORDER in
    /// `test_sectionOrderIsFixed`; between them a section cannot be added,
    /// removed or moved without an editor looking at it.
    func test_theSchemaAsksForExactlySixSections() {
        let templateLines = CompilerPrompt.sectionSchemaDescription
            .components(separatedBy: "\n")
            .filter { $0.contains("\"section\":") }
        XCTAssertEqual(templateLines.count, 6,
                       "got \(templateLines.count) section lines: "
                       + "\(templateLines.map { $0.prefix(40) })")
    }

    // MARK: - What the disciplines cost (M4 P2 Task 7)

    /// **The standing per-run instruction text has a word budget, so its
    /// cost is a conscious edit rather than folklore.** Every one of these
    /// additions rides `sectionSchemaDescription` (or, for the pass brief,
    /// the run message alongside it) and reaches every run — warm, cold,
    /// passless alike (see the disciplines tests above) — so their combined
    /// length is standing overhead on every single Claude call this feature
    /// makes, not a one-time cost.
    ///
    /// Measured at write time: the three disciplines
    /// (`readerBarInstruction`/`crossSectionDedupInstruction`/
    /// `driftStabilizerInstruction`) plus `formOnItsOwnTermsInstruction` plus
    /// one representative preset pass brief (`ReviewPass.presets`' own
    /// "structural") totalled 301 words, under a 450-word ceiling.
    ///
    /// **Re-measured at 564 words when the editorial letter's general
    /// instruction (P1 Task 2) joined the list**, and the ceiling moved once,
    /// consciously, to 715. `letterInstruction` is the largest single addition
    /// this feature has made to standing per-run text, and it earns its size:
    /// it is what a letter MEANS, stated once for every voice, so a custom
    /// pass with no brief does not get a letter the model invented the rules
    /// for. The ceiling keeps the same ~150 words of headroom the 450 did — a
    /// wording pass may grow a sentence or two without becoming a silent
    /// regression, and a failure here means the budget was actually spent and
    /// asks the editor to look, not to raise the number by reflex.
    func test_theStandingPerRunInstructionAdditionsStayUnderAWordBudget() {
        let disciplines = [
            CompilerPrompt.readerBarInstruction,
            CompilerPrompt.crossSectionDedupInstruction,
            CompilerPrompt.driftStabilizerInstruction,
        ]
        guard let structuralBrief = ReviewPass.presets
            .first(where: { $0.id == "structural" })?.brief else {
            return XCTFail("the structural preset lost its brief")
        }
        let additions = disciplines
            + [CompilerPrompt.formOnItsOwnTermsInstruction,
               CompilerPrompt.letterInstruction, structuralBrief]
        let wordCount = additions.reduce(0) {
            $0 + $1.split(whereSeparator: { $0.isWhitespace }).count
        }
        let budget = 715
        XCTAssertLessThan(wordCount, budget,
            "The three disciplines (reader bar, cross-section dedup, drift "
            + "stabilizer) plus the form-on-its-own-terms instruction plus the "
            + "general letter instruction plus one representative preset pass "
            + "brief (Structural) now measure "
            + "\(wordCount) words of standing per-run instruction text — over "
            + "the \(budget)-word budget. This total rides every single "
            + "compiler run, warm or cold; if it grew here, that is a "
            + "conscious cost, so look at what grew before raising the ceiling.")
    }

    // MARK: - The briefing carries the shelf's grouping (references-shelf, Task 3)

    /// One line per pin, exactly as `pinnedListingLine` writes today, with a
    /// `## <title>` line ahead of each TITLED section — an untitled section
    /// (the research run at the top of the shelf) gets no header at all, so a
    /// run reads the same grouping the writer sees in the References pane.
    func test_pinnedListingLinesPrecedesEachTitledSectionWithAHeader() {
        let untitled = PinnedSection(
            title: nil,
            references: [PinnedReference(id: "res-sarah", kind: .research(itemId: "res-sarah"),
                                         title: "Sarah")])
        let titled = PinnedSection(
            title: "Act II fog",
            references: [PinnedReference(id: "res-fog", kind: .research(itemId: "res-fog"),
                                         title: "The falls at night")])
        let shelf = PinnedShelf(sections: [untitled, titled])

        let lines = CompilerOrchestrator.Environment.pinnedListingLines(shelf)

        XCTAssertEqual(lines, [
            "Sarah (res-sarah) — read_document",
            "## Act II fog",
            "The falls at night (res-fog) — read_document",
        ])
    }

    /// A shelf with no titled sections at all — every reference under one
    /// untitled run — emits no header anywhere.
    func test_pinnedListingLinesEmitsNoHeaderForAnUntitledShelf() {
        let shelf = PinnedShelf(sections: [
            PinnedSection(title: nil, references: [
                PinnedReference(id: "res-sarah", kind: .research(itemId: "res-sarah"),
                                title: "Sarah"),
            ]),
        ])

        let lines = CompilerOrchestrator.Environment.pinnedListingLines(shelf)

        XCTAssertEqual(lines, ["Sarah (res-sarah) — read_document"])
    }

    /// **The listing is capped, and it says what it left out** (whole-branch
    /// review I3, 2026-08-26).
    ///
    /// §2.1 routes `derivedResearchItems` into the shelf, and for a short story
    /// or a screenplay that is *every research asset in the project*, on every
    /// piece — so the briefing's length became a property of how much research
    /// the writer holds rather than of what they chose, on a listing that ships
    /// with every ⌘R. The prompt-ceiling test above guards a fixture; this
    /// guards the real bound.
    ///
    /// The trailer matters as much as the cap: a silently short list reads to
    /// the model as "this is all of it".
    func test_pinnedListingLinesCapsThePinsAndSaysHowManyItLeftOut() {
        let cap = CompilerOrchestrator.Environment.pinnedListingCap
        let many = (0..<(cap + 7)).map { i in
            PinnedReference(id: "res-\(i)", kind: .research(itemId: "res-\(i)"),
                            title: "Note \(i)")
        }
        let lines = CompilerOrchestrator.Environment.pinnedListingLines(
            PinnedShelf(sections: [PinnedSection(title: nil, references: many)]))

        XCTAssertEqual(lines.count, cap + 1,
                       "\(cap) pins and the trailer, or the ceiling is not a "
                       + "ceiling")
        XCTAssertEqual(lines.first, "Note 0 (res-0) — read_document",
                       "the writer's own order survives the cap — it truncates "
                       + "the tail, it does not sample")
        XCTAssertEqual(lines.last, "…and 7 more pinned — see References",
                       "a short list with nothing saying so reads as the whole "
                       + "of it, and a run can conclude a fact is unsupported "
                       + "because its source was truncated away")
    }

    /// **Headers do not count against the cap, and none is emitted over
    /// nothing.** The `## <region>` line is what says where the pins under it
    /// came from — dropping headers to make room would save four tokens and cost
    /// the grouping this listing exists to carry — and a section the cap leaves
    /// no room for is omitted whole rather than drawn as a bare heading.
    func test_theCapCountsPinsAndNeverLeavesAHeadingOverNothing() {
        let cap = CompilerOrchestrator.Environment.pinnedListingCap
        let full = (0..<cap).map { i in
            PinnedReference(id: "res-\(i)", kind: .research(itemId: "res-\(i)"),
                            title: "Note \(i)")
        }
        let lines = CompilerOrchestrator.Environment.pinnedListingLines(
            PinnedShelf(sections: [
                PinnedSection(title: "Act I", references: Array(full.prefix(2))),
                PinnedSection(title: "Act II fog", references: Array(full.dropFirst(2))),
                PinnedSection(title: "Act III", references: [
                    PinnedReference(id: "res-late", kind: .research(itemId: "res-late"),
                                    title: "Too late"),
                ]),
            ]))

        XCTAssertEqual(lines.first, "## Act I",
                       "the two headers that DO have room are emitted, and they "
                       + "are not what the cap counts")
        XCTAssertEqual(lines.filter { $0.hasPrefix("## ") }.count, 2,
                       "the third section had no room for a pin, so it is "
                       + "omitted whole rather than drawn as a bare heading")
        XCTAssertEqual(lines.last, "…and 1 more pinned — see References")
    }
}
