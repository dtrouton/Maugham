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

    /// **The instruction half of the id-scrub, and it must name every field
    /// the scrub is asked of.** Task 2's fix round gave `parseLetter` an
    /// id-scrub over all twelve of the letter's prose fields; until this
    /// sentence covered them, ingest was dropping letter entries for a rule
    /// the model had never been given — a refusal it could not have complied
    /// with and would never learn from.
    func test_theSchemaForbidsIdsInProse() {
        let schema = CompilerPrompt.sectionSchemaDescription
        XCTAssertTrue(schema.contains("never contains a paragraph id"))
        XCTAssertTrue(schema.contains("short quotation"))
        XCTAssertTrue(
            schema.contains("every prose field of the letter"),
            "the letter's prose is scrubbed for leaked ids at ingest, so the "
            + "instruction must ask for what the parser enforces")
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

    /// **The coach is a teacher, not an editor** (spec §4.1, §4.4). She is a
    /// pass in every respect the run cares about — a lane, a round, a byline —
    /// and the ONE thing that is not a stage's is the register she reads in.
    /// `isCoach` is the only thing the section branches on, and this line is
    /// the only place in the app that branch is visible.
    func test_theCoachIsFramedAsATeacherRatherThanAnEditor() {
        let coach = ReviewPass.coachPreset
        guard let section = CompilerPrompt.passSection(
            CompilerOrchestrator.ActivePass(
                id: coach.id, name: coach.name,
                editorName: coach.effectiveEditorName,
                brief: coach.effectiveBrief, isCoach: true))
        else { return XCTFail("the coach must produce a section") }
        XCTAssertEqual(
            section.split(separator: "\n").first.map(String.init),
            "You are Le Guin, this writer's workshop teacher.",
            "the coach's role frame is the whole of what isCoach buys; got \(section)")
        XCTAssertFalse(section.contains("this manuscript's"),
                       "a stage's frame reached the coach; got \(section)")
        let brief = try? XCTUnwrap(coach.brief)
        XCTAssertTrue(section.contains(brief ?? "\u{0}"),
                      "her doctrine must travel verbatim under the frame")
    }

    /// The control for the branch above: a stage keeps the editor framing it
    /// has had since M4 P1, and never becomes anybody's teacher.
    func test_aStageIsStillFramedAsThisManuscriptsEditor() {
        guard let section = CompilerPrompt.passSection(lane("copyedit"))
        else { return XCTFail("expected a section") }
        XCTAssertEqual(
            section.split(separator: "\n").first.map(String.init),
            "You are Gould, this manuscript's Copyedit editor.",
            "got \(section)")
        XCTAssertFalse(section.contains("teacher"),
                       "a stage was framed as a teacher; got \(section)")
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

    // MARK: - The scene position, told to the model (editorial letter P1 Task 3)

    /// **Every position gets its sentence, `.none` included.** The whole
    /// point of deriving the position app-side is that the model is never
    /// asked to infer one (spec §3.4) — and silence is exactly an invitation
    /// to infer. A run that said nothing about scenes would leave the model to
    /// decide from the prose whether this book turns, which is the judgement
    /// the derivation exists to take off it.
    func test_everyScenePositionGetsItsOwnSentence() {
        var seen: Set<String> = []
        for position in [ScenePosition.none, .weak, .strongDeclared, .strongDefault] {
            guard let section = CompilerPrompt.scenePositionSection(position) else {
                return XCTFail("\(position) was told nothing about scenes")
            }
            XCTAssertFalse(section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(seen.insert(section).inserted,
                          "\(position) repeated another position's sentence")
        }
    }

    /// `.none` asks for `null` — not an empty array, which is a scene table
    /// with no rows in it (`Letter.scenes`' own doc, and the pair
    /// `DiagnosticIngestTests.test_scenesAbsentOrNullIsNil` pins).
    func test_theNonePositionAsksForNullRatherThanAnEmptyTable() {
        guard let section = CompilerPrompt.scenePositionSection(.none)
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.lowercased().contains("null"), section)
    }

    /// The weak form's two rules, both from spec §3.4: no charge, and a blank
    /// `changes` is an observation rather than a fault. The doctrine it
    /// encodes is the near-consensus one — something should change — so the
    /// word "conflict" must not appear in it at all.
    func test_theWeakPositionCarriesNoChargeAndNoConflict() {
        guard let section = CompilerPrompt.scenePositionSection(.weak)
        else { return XCTFail("expected a section") }
        XCTAssertTrue(section.lowercased().contains("null"),
                      "the weak form's charge is always null; got \(section)")
        XCTAssertFalse(section.lowercased().contains("conflict"),
                       "the weak form carries no conflict field, on purpose; got \(section)")
    }

    /// **Only the declared strong form asks for a strain**, and the default
    /// one says so in as many words. This is spec §3.4's "a strain needs a
    /// clause the writer wrote": under `.strongDefault` there is no clause of
    /// the writer's to quote, and a strain raised without one is the app
    /// having synthesized the standard it then judges them by.
    func test_onlyTheDeclaredStrongPositionAsksForAConformanceStrain() {
        guard let declared = CompilerPrompt.scenePositionSection(.strongDeclared),
              let byDefault = CompilerPrompt.scenePositionSection(.strongDefault)
        else { return XCTFail("expected both sections") }

        XCTAssertTrue(declared.lowercased().contains("strain"), declared)
        XCTAssertTrue(declared.lowercased().contains("conformance"), declared)
        XCTAssertTrue(declared.lowercased().contains("quote"), declared)

        XCTAssertTrue(byDefault.lowercased().contains("not"), byDefault)
        XCTAssertTrue(byDefault.lowercased().contains("observation"),
                      "a turn-less scene stays an observation; got \(byDefault)")
        XCTAssertTrue(byDefault.lowercased().contains("has not declared")
                        || byDefault.lowercased().contains("no clause"),
                      "…and it says WHY, so the model does not read the refusal as "
                      + "an oversight; got \(byDefault)")

        // Both strong forms still ask for the charge the weak one refuses.
        for section in [declared, byDefault] {
            XCTAssertTrue(section.contains("+") && section.contains("-"), section)
        }
    }

    /// **Nothing per-run folds into the briefing hash** (global constraint 5,
    /// and `test_theRoundSectionNeverFoldsIntoTheBriefingHash`'s own shape).
    /// The scene position moves with the project's type, the writer's intent
    /// and the lane they put the piece in — a hash covering it would never
    /// match its predecessor after a pass switch, and the essay, the declared
    /// world and the bible slice would re-embed in full on every ⌘R.
    func test_theScenePositionNeverFoldsIntoTheBriefingHash() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], scenePosition: .weak,
            previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)

        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [], scenePosition: .strongDeclared,
            previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash,
                       "the intent did not move; a scene position that folded into "
                       + "the hash would re-embed the whole briefing every time the "
                       + "writer switched lanes")
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertTrue(
            secondMessage.contains(CompilerPrompt.scenePositionSection(.strongDeclared) ?? "!"),
            "…and the position still travels")
    }

    /// Its place in the message: after the role frame, before the delta
    /// (global constraint 5, and the ordering comment in `runMessageV2`). What
    /// form this piece takes is part of the frame the delta is read through,
    /// not part of the thing being checked.
    func test_theScenePositionSitsBetweenTheRoleFrameAndTheDelta() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(new: [.init(paragraphId: "p1", text: "The fog came.")]),
            world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            pass: lane("copyedit"), scenePosition: .weak, previousBriefingHash: nil)
        guard let frame = message.range(of: "You are Gould"),
              let scenes = message.range(
                of: CompilerPrompt.scenePositionSection(.weak) ?? "!"),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected the frame, the position and the delta; got \(message)") }
        XCTAssertLessThan(frame.lowerBound, scenes.lowerBound)
        XCTAssertLessThan(scenes.lowerBound, delta.lowerBound)
    }

    // MARK: - The draft stage and the process numbers (P3 Task 4)

    /// The fixture for a run whose signals are worth a section: four sittings,
    /// the frontier laid down in the first and nothing new past it since, so
    /// `sessionsSinceFrontierMoved` is 3 — `ProcessSignals.frontierStallSessions`
    /// exactly.
    private func stalledSignals() -> ProcessSignals {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func op(_ id: String, session: String, minutes: Double,
                _ changes: [Op.ParagraphChange]) -> Op {
            Op(opId: id, docId: "doc-1", at: base.addingTimeInterval(minutes * 60),
               device: "macA", session: session, kind: .typingBurst,
               changes: changes, sequence: nil)
        }
        let ops = [
            op("op01", session: "s1", minutes: 0,
               [.init(paragraphId: "a1b2", prior: nil, next: "The fog came.")]),
            op("op02", session: "s2", minutes: 1,
               [.init(paragraphId: "a1b2", prior: "The fog came.", next: "Fog.")]),
            op("op03", session: "s3", minutes: 2,
               [.init(paragraphId: "a1b2", prior: "Fog.", next: "The fog.")]),
            op("op04", session: "s4", minutes: 3,
               [.init(paragraphId: "a1b2", prior: "The fog.", next: "Fog again.")]),
        ]
        return ProcessSignals(
            ops: ops, sequence: ["a1b2"],
            now: base.addingTimeInterval(4 * 60))
    }

    /// A reading with nothing worth saying: one sitting, the frontier moved in
    /// it, nothing rewritten five times, nobody away.
    private func quietSignals() -> ProcessSignals {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let op = Op(opId: "op01", docId: "doc-1", at: base, device: "macA",
                    session: "s1", kind: .typingBurst,
                    changes: [.init(paragraphId: "a1b2", prior: nil, next: "The fog came.")],
                    sequence: nil)
        return ProcessSignals(ops: [op], sequence: ["a1b2"], now: base)
    }

    /// **The drafting arm names the stage, says WHY, and doses the letter**
    /// (spec §3.8). A first draft in motion should not be line-edited, and the
    /// model is told that in the same breath as what it is allowed to write.
    func test_theDraftingStageNamesItselfAndDosesTheLetter() {
        guard let section = CompilerPrompt.stageSection(.drafting)
        else { return XCTFail("a stage the run derived must reach the model") }

        XCTAssertTrue(section.lowercased().contains("drafting"),
                      "the stage names itself; got \(section)")
        XCTAssertTrue(section.lowercased().contains("frontier"),
                      "…and says why it read as drafting; got \(section)")
        XCTAssertTrue(section.lowercased().contains("one question"),
                      "…at most one question; got \(section)")
        XCTAssertTrue(section.lowercased().contains("no exercise"),
                      "…no exercise; got \(section)")
        XCTAssertTrue(section.lowercased().contains("null"),
                      "…and scenes answered null; got \(section)")
        XCTAssertTrue(section.lowercased().contains("fresh eyes"),
                      "…and the full letter waits for a cold read; got \(section)")
    }

    /// **The ask overrides the dosage, and the drafting arm is where that is
    /// said** (global constraint 24). `parseLetter` never touches `answer`, so
    /// the only thing that can shorten an answer is the model deciding to —
    /// which is exactly what this sentence forbids.
    func test_theDraftingStageStillAnswersTheWritersAskInFull() {
        guard let section = CompilerPrompt.stageSection(.drafting)
        else { return XCTFail("a stage the run derived must reach the model") }
        XCTAssertTrue(section.lowercased().contains("in full"),
                      "an ask is answered in full whatever the stage; got \(section)")
        XCTAssertTrue(section.lowercased().contains("ask"),
                      "…and it names what it is about; got \(section)")
    }

    /// The other arm: revising is the letter as it has always been, and the
    /// section says so rather than staying silent — a run that named no stage
    /// and a run that named revising would otherwise read identically to the
    /// model, and the stage is a fact it is entitled to.
    func test_theRevisingStageAsksForTheWholeLetter() {
        guard let section = CompilerPrompt.stageSection(.revising)
        else { return XCTFail("a stage the run derived must reach the model") }
        XCTAssertTrue(section.lowercased().contains("revising"))
        XCTAssertTrue(section.lowercased().contains("full letter"),
                      "got \(section)")
    }

    /// No stage is no section at all, on `passSection`/`roundSection`/
    /// `scenePositionSection`'s rule: the call site composes optional sections
    /// in one spelling, and every production run has a stage — the parameter is
    /// optional for the tests and the other callers of this public function.
    ///
    /// Disable experiment: replaced the `guard let stage else { return nil }`
    /// with `switch stage ?? .revising`, so an absent stage wrote the revising
    /// arm. This test failed at its one `XCTAssertNil` line.
    func test_noStageIsNoSectionAtAll() {
        XCTAssertNil(CompilerPrompt.stageSection(nil))
    }

    /// **The dosage doctrine is measured, and deliberately NOT inside
    /// `test_theStandingPerRunInstructionAdditionsStayUnderAWordBudget`**
    /// (global constraint 26). That test measures what rides EVERY run; this
    /// is per-run frame, written only when there is a stage to name — folding
    /// it in would charge every run for words half of them never carry. So it
    /// gets a ceiling of its own, and 120 words is room for the stage, the
    /// reason, the five-part dose and the two overrides.
    ///
    /// **Measured at 94 words** when it landed (the revising arm, which no
    /// ceiling needs, is 25). The 26 words of headroom are for a clause, not
    /// for a paragraph: this text rides every drafting round, which on a
    /// writer mid-draft is most of them.
    func test_theDraftingDosageStaysUnderItsOwnWordCeiling() {
        guard let section = CompilerPrompt.stageSection(.drafting)
        else { return XCTFail("a stage the run derived must reach the model") }
        let words = section.split(whereSeparator: { $0.isWhitespace }).count
        XCTAssertLessThan(words, 120,
            "the drafting arm measures \(words) words; it rides every drafting "
            + "run, so growth here is a conscious cost")
    }

    /// **A quiet session produces no line at all** (spec §5). The whole point
    /// of the threshold is that Maugham says nothing about the writer's
    /// process most of the time — a `Process` heading over "the frontier moved
    /// this session" would be the app narrating an ordinary day back at them.
    ///
    /// Disable experiment: moved `processSection`'s `return` above the
    /// `noteworthy.isEmpty` guard, so a quiet reading wrote a bare heading.
    /// This test failed at the `XCTAssertNil(CompilerPrompt.processSection(
    /// quietSignals()))` line and again at the `XCTAssertFalse(message
    /// .contains(CompilerPrompt.processSectionOpening))` line.
    ///
    /// The assertions look for `processSectionOpening` rather than for
    /// `processHeading`: `letterInstruction` names `Process` in its own prose
    /// ("the numbers under Process"), so the word alone is in every message
    /// ever sent and an assertion on it would pass vacuously — measured, on
    /// the first red run of this test.
    func test_aQuietSessionWritesNoProcessSectionAnywhere() {
        XCTAssertNil(CompilerPrompt.processSection(quietSignals()),
                     "nothing crossed a threshold, so there is nothing to say")
        XCTAssertNil(CompilerPrompt.processSection(nil),
                     "…and no reading at all is the same silence")

        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(new: [.init(paragraphId: "p1", text: "The fog came.")]),
            world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            stage: .drafting, signals: quietSignals(),
            previousBriefingHash: nil)
        XCTAssertFalse(message.contains(CompilerPrompt.processSectionOpening),
                       "no section, not an empty one; got \(message)")
    }

    /// Each of the three signals says its own number, because a sentence
    /// without one is an opinion and the whole of `ProcessSignals` is the
    /// refusal to have one.
    func test_eachNoteworthySignalGetsASentenceCarryingItsNumber() {
        guard let stalled = CompilerPrompt.processSection(stalledSignals())
        else { return XCTFail("three stalled sessions is over the threshold") }
        XCTAssertTrue(stalled.hasPrefix(CompilerPrompt.processHeading),
                      "the section opens with its heading; got \(stalled)")
        XCTAssertTrue(stalled.contains("3"),
                      "sessions since the frontier moved; got \(stalled)")
        XCTAssertTrue(stalled.lowercased().contains("frontier"), "got \(stalled)")

        let hotspot = ProcessSignals.Hotspot(paragraphId: "a1b2", position: 3, rewrites: 7)
        let sentence = CompilerPrompt.processSentence(.hotspot(hotspot))
        XCTAssertTrue(sentence.contains("4th"),
                      "the paragraph is named by its position — no excerpt is "
                      + "available here; got \(sentence)")
        XCTAssertTrue(sentence.contains("7"), "…and its rewrite count; got \(sentence)")
        XCTAssertTrue(sentence.contains("\(ProcessSignals.churnWindowSessions)"),
                      "…over the window it was counted in; got \(sentence)")

        let cold = CompilerPrompt.processSentence(.coldRead(days: 21))
        XCTAssertTrue(cold.contains("21"), "days away; got \(cold)")
    }

    /// Their place in the message: after the scene position, before the round
    /// section — the stage first, then the numbers behind it. Both are frame
    /// for the delta rather than part of it, exactly as their neighbours are.
    func test_theStageAndTheProcessSitBetweenTheScenePositionAndTheDelta() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(new: [.init(paragraphId: "p1", text: "The fog came.")]),
            world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            pass: lane("copyedit"), scenePosition: .weak,
            stage: .drafting, signals: stalledSignals(),
            previousBriefingHash: nil)
        guard let scenes = message.range(
                of: CompilerPrompt.scenePositionSection(.weak) ?? "!"),
              let stage = message.range(of: CompilerPrompt.stageSection(.drafting) ?? "!"),
              let process = message.range(of: CompilerPrompt.processSectionOpening),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected all four; got \(message)") }
        XCTAssertLessThan(scenes.lowerBound, stage.lowerBound)
        XCTAssertLessThan(stage.lowerBound, process.lowerBound)
        XCTAssertLessThan(process.lowerBound, delta.lowerBound)
    }

    /// **The stage never folds into the briefing hash** (global constraint 25,
    /// and `test_theAskNeverFoldsIntoTheBriefingHash`'s shape). It is derived
    /// from this run's own delta, so it can differ between two consecutive ⌘Rs
    /// over an unchanged intent — and a hash covering it would re-embed the
    /// essay, the declared world and the bible slice the round the writer
    /// stopped adding and started rewriting.
    ///
    /// Disable experiment: folded both new sections into the hash input
    /// (`sha256Hex($0 + "stage:…" + "process:…")`). This test failed at its
    /// `XCTAssertEqual(secondHash, firstHash)` line, and so did
    /// `test_theProcessNumbersNeverFoldIntoTheBriefingHash`.
    func test_theDraftStageNeverFoldsIntoTheBriefingHash() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            stage: .drafting, previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)

        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            stage: .revising, previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash,
                       "the intent did not move; a stage that folded into the hash "
                       + "would re-embed the whole briefing the round the writer "
                       + "started rewriting")
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertTrue(
            secondMessage.contains(CompilerPrompt.stageSection(.revising) ?? "!"),
            "…and the stage still travels")
    }

    /// Its neighbour, for the numbers: a round with process signals and a round
    /// without hash identically. The signals move with the writer's own
    /// working day, so a hash covering them would never match its predecessor.
    ///
    /// Disable experiment: the same fold as its neighbour above. This test
    /// failed at its `XCTAssertEqual(secondHash, firstHash)` line.
    func test_theProcessNumbersNeverFoldIntoTheBriefingHash() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])

        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            signals: quietSignals(), previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)

        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            signals: stalledSignals(), previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash,
                       "the intent did not move; process numbers that folded into "
                       + "the hash would re-embed the whole briefing every time the "
                       + "writer's own week changed shape")
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertTrue(secondMessage.contains(CompilerPrompt.processSectionOpening),
                      "…and the numbers still travel")
    }

    // MARK: - The writer's ask (editorial letter P2 Task 3)

    /// The writer's own words, quoted, plus the instruction to answer them
    /// first. Their sentence is marked off by guillemets so a two-sentence
    /// ask cannot read as one sentence of theirs and one of ours.
    func test_theAskCarriesTheWritersWordsAndSaysToAnswerThemFirst() {
        guard let section = CompilerPrompt.askSection("I'm worried the middle sags.")
        else { return XCTFail("an ask the writer typed must reach the run") }

        XCTAssertTrue(section.contains("\u{00ab}I'm worried the middle sags.\u{00bb}"),
                      "their words, quoted rather than paraphrased into an "
                      + "instruction; got \(section)")
        XCTAssertTrue(section.lowercased().contains("before anything else"),
                      "…and the letter answers it first; got \(section)")
        XCTAssertTrue(section.contains("answer"),
                      "…in the field the schema asks for; got \(section)")
    }

    /// Nothing asked is no section at all, on `passSection`/`roundSection`/
    /// `scenePositionSection`'s rule — a section saying the writer asked
    /// nothing would spend standing words telling the model to do nothing.
    /// Blank is guarded here as well as in `DiagnosticsStore.setAsk`, because
    /// this function is reachable by any caller.
    func test_anAbsentOrBlankAskIsNoSectionAtAll() {
        XCTAssertNil(CompilerPrompt.askSection(nil))
        XCTAssertNil(CompilerPrompt.askSection(""))
        XCTAssertNil(CompilerPrompt.askSection("   \n  "))
    }

    /// Its place in the message: after the writer's dispositions, before the
    /// delta. The ask is the last of the per-run frame and the closest thing
    /// to the prose, because it is the writer's own words about the prose
    /// immediately below it.
    func test_theAskSitsBetweenTheDispositionsAndTheDelta() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(new: [.init(paragraphId: "p1", text: "The fog came.")]),
            world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            dispositions: [Self.standingQuestion],
            ask: "Does the middle sag?",
            previousBriefingHash: nil)
        guard let dispositions = message.range(of: CompilerPrompt.standingNotesHeading),
              let ask = message.range(
                of: CompilerPrompt.askSection("Does the middle sag?") ?? "!"),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected the dispositions, the ask and the delta; got \(message)") }
        XCTAssertLessThan(dispositions.lowerBound, ask.lowerBound)
        XCTAssertLessThan(ask.lowerBound, delta.lowerBound)
    }

    /// **The ask never folds into the briefing hash** (global constraint 5,
    /// and `test_theScenePositionNeverFoldsIntoTheBriefingHash`'s own shape),
    /// with one reason sharper than its neighbours': an ask is EXPECTED to
    /// change every round — that is what it is for — so a hash covering it
    /// would never match its predecessor, and the essay, the declared world
    /// and the bible slice would re-embed in full on every ⌘R the writer
    /// asked anything on.
    func test_theAskNeverFoldsIntoTheBriefingHash() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]

        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            ask: "Does the middle sag?", previousBriefingHash: nil)
        XCTAssertNotNil(firstHash)

        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            ask: "Is Kelly legible?", previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash,
                       "the intent did not move; an ask that folded into the hash "
                       + "would re-embed the whole briefing every round the writer "
                       + "asked something new")
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged"))
        XCTAssertFalse(secondMessage.contains("Essay text."))
        XCTAssertTrue(secondMessage.contains("Is Kelly legible?"),
                      "…and the ask still travels")
    }

    /// The control for the pin above: the hash DOES move when the thing it is
    /// about moves. Without this, a `briefingHashInput` that had quietly
    /// stopped hashing anything at all would pass the pin.
    func test_theBriefingHashStillMovesWhenTheEssayDoes() {
        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            ask: "Does the middle sag?", previousBriefingHash: nil)
        let (_, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "A different essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            ask: "Does the middle sag?", previousBriefingHash: firstHash)

        XCTAssertNotNil(firstHash)
        XCTAssertNotEqual(secondHash, firstHash)
    }

    /// The letter's schema asks for `answer` FIRST, because it is the first
    /// thing the model is told to write: a question the writer typed is
    /// answered before the reading it prompted.
    func test_theLetterSchemaAsksForTheAnswerFirst() {
        guard let letterLine = CompilerPrompt.sectionSchemaDescription
            .components(separatedBy: "\n")
            .first(where: { $0.contains("\"section\":\"letter\"") })
        else { return XCTFail("the letter's schema line went missing") }
        guard let answer = letterLine.range(of: "\"answer\""),
              let about = letterLine.range(of: "\"about\"")
        else { return XCTFail("expected both keys on the letter line; got \(letterLine)") }
        XCTAssertLessThan(answer.lowerBound, about.lowerBound)
    }

    /// The standing instruction says what an answer IS, for every voice —
    /// the same reason the rest of `letterInstruction` is general.
    func test_theLetterInstructionSaysHowAnAskIsAnswered() {
        let letter = CompilerPrompt.letterInstruction.lowercased()
        for (phrase, why) in [
            // Tightened at P3 Task 3 from "answer it in answer before
            // anything else" — the same clause in three fewer words, and the
            // pin moved with the wording rather than the clause being cut.
            ("answer it in answer first", "the ask is answered first"),
            ("your own register", "…in the letter's own voice, not a form reply"),
            ("an opinion where they asked for one", "…and an opinion when one is asked for"),
            ("answer is null when they asked nothing", "…and null when nothing was asked"),
        ] {
            XCTAssertTrue(letter.contains(phrase),
                          "the letter instruction stopped saying \"\(phrase)\" — \(why)")
        }
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

    /// The instruction-side additions ride the schema's own surrounding
    /// prose, so they reach every run — warm, cold, passless alike. Pinned by
    /// distinctive phrase rather than whole text: the wording is the author's
    /// to improve, the discipline is not.
    ///
    /// **`letterInstruction` joined the loop in Task 2's fix round**, and it
    /// had to: until it did, the only test naming it was an
    /// `XCTAssertLessThan` on a word budget, so deleting the interpolation —
    /// or gutting the static — made the suite MORE green. An instruction whose
    /// only guard is a cost ceiling is guarded in exactly the wrong direction.
    func test_theSchemaCarriesTheReaderBarTheDedupAndTheDriftStabilizer() {
        let schema = CompilerPrompt.sectionSchemaDescription
        for instruction in [CompilerPrompt.formOnItsOwnTermsInstruction,
                            CompilerPrompt.readerBarInstruction,
                            CompilerPrompt.crossSectionDedupInstruction,
                            CompilerPrompt.driftStabilizerInstruction,
                            CompilerPrompt.letterInstruction] {
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

    /// **The letter's doctrine, clause by clause** (editorial letter P1
    /// Task 2, spec §3.1/§3.3/§4.4). Each of these is a decision the brief
    /// made, not a wording choice, and each is one a rewording could quietly
    /// drop while the instruction stayed long enough to look intact.
    ///
    /// The two that carry the most weight and would be least visible in
    /// their absence: **voice distinctness** is the one habit test the brief
    /// names by name, and the **writer's own bar** is what makes "what's
    /// working" a comparison to their own best work rather than to a rule.
    /// The other two are the register itself — questions never carry a
    /// suggested change, and an exercise is a thing to do rather than a
    /// rewrite, which is also the doctrine `parseLetter`'s scrub exemption
    /// rests on.
    func test_theLetterInstructionCarriesItsDoctrineClauseByClause() {
        let letter = CompilerPrompt.letterInstruction.lowercased()
        let clauses = [
            ("voice distinctness", "the one habit test the brief names by name"),
            ("their lines alone", "…and the test it actually is"),
            ("the writer's own pieces", "the writer's own bar (spec §4.4)"),
            ("never a suggested change", "questions only, and never a fix"),
            ("never a rewrite", "an exercise is a thing to DO"),
            ("your pass brief allows", "each pass writes only the parts its brief allows"),
            ("with no brief", "…and a pass with no brief writes all of them"),
            ("at most 2", "the habits cap the ingest also enforces"),
            ("at most 3 questions", "the questions cap the ingest also enforces"),
            ("one_thing", "the single thing to fix if only one"),
            // The ledger's three clauses (P2 Task 4).
            ("verbatim", "a known habit is reported under its own heading"),
            ("lesson null", "…and the writer already has the lesson for it"),
            ("retired", "what the reading looked for and did not find"),
            // The process line (P3 Task 3).
            ("numbers under process",
             "the process line is the app's own numbers said in the reader's words"),
            ("null when none were given",
             "…and there is no line at all when no numbers were briefed"),
        ]
        for (phrase, why) in clauses {
            XCTAssertTrue(letter.contains(phrase),
                          "the letter instruction stopped saying \"\(phrase)\" — \(why)")
        }
    }

    // MARK: - The lessons ledger (editorial letter P2 Task 4)

    /// A hand-typed ledger of the shape `LessonsLedger` reads: one open
    /// lesson, one settled choice, one retired entry, under a preamble.
    private static let ledger = """
        I keep learning the same two things.

        ## Rulings

        - Filter words — ruled 1 Sep 2026, Denver
        - Choice: Present tense throughout — ruled 1 Sep 2026, Denver
        - Throat-clearing (retired 2 Sep 2026) — ruled 1 Sep 2026, Denver
        """

    /// **What the ledger is briefed as**: the writer's own preamble, the open
    /// lessons under the heading that tells the model how to cite one, and the
    /// settled choices under the heading that tells it not to raise them.
    func test_theLedgerIsBriefedAsItsEssayItsLessonsAndItsChoices() throws {
        let section = try XCTUnwrap(CompilerPrompt.lessonsSection(Self.ledger))
        XCTAssertTrue(section.contains("I keep learning the same two things."))
        XCTAssertTrue(section.contains("Lessons the writer is working on"))
        XCTAssertTrue(section.contains("Filter words"))
        XCTAssertTrue(section.contains("Choices the writer has made"))
        XCTAssertTrue(section.contains("Present tense throughout"))
        XCTAssertFalse(section.contains("Choice: Present tense"),
                       "the marker is the app's grammar, not something to brief")
    }

    /// **A retired lesson is briefed to nobody.** It is the one entry kind the
    /// writer is done with, and re-raising it is exactly what retiring it was
    /// for.
    func test_aRetiredLessonIsBriefedToNobody() throws {
        let section = try XCTUnwrap(CompilerPrompt.lessonsSection(Self.ledger))
        XCTAssertFalse(section.contains("Throat-clearing"))
    }

    /// Nothing to say is no section at all, on `askSection`/`passSection`'s
    /// rule — and a ledger of nothing but retired entries has nothing to say,
    /// which is the case that matters for the hash below.
    func test_aLedgerWithNothingLiveInItIsNoSectionAtAll() {
        XCTAssertNil(CompilerPrompt.lessonsSection(nil))
        XCTAssertNil(CompilerPrompt.lessonsSection(""))
        XCTAssertNil(CompilerPrompt.lessonsSection("""
            ## Rulings

            - Throat-clearing (retired 2 Sep 2026) — ruled 1 Sep 2026, Denver
            """))
        // Control: one open lesson and there is a section.
        XCTAssertNotNil(CompilerPrompt.lessonsSection("""
            ## Rulings

            - Filter words — ruled 1 Sep 2026, Denver
            """))
    }

    /// **Each arm of the guard on its own.** The section is nil only when all
    /// three are empty, so a ledger that is nothing but a preamble and one
    /// that is nothing but choices each brief — and each, being a section,
    /// contributes to the hash. Without these two the guard could have been
    /// written as "no open lesson" and every test above would still pass.
    func test_aPreambleAloneAndChoicesAloneEachBriefAndHash() {
        let preambleOnly = "I keep learning the same two things."
        let choicesOnly = """
            ## Rulings

            - Choice: Present tense throughout — ruled 1 Sep 2026, Denver
            """

        let preamble = CompilerPrompt.lessonsSection(preambleOnly)
        XCTAssertNotNil(preamble)
        XCTAssertEqual(preamble?.contains("I keep learning the same two things."), true)

        let choices = CompilerPrompt.lessonsSection(choicesOnly)
        XCTAssertNotNil(choices)
        XCTAssertEqual(choices?.contains("Present tense throughout"), true)

        // …and each is enough to have a hash with nothing else declared.
        for ledger in [preambleOnly, choicesOnly] {
            let (_, hash) = CompilerPrompt.runMessageV2(
                delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
                paletteListing: [], pinnedListing: [],
                lessons: ledger, previousBriefingHash: nil)
            XCTAssertNotNil(hash, ledger)
        }
    }

    /// The ledger's preamble is labelled like every sibling section, so a
    /// preamble-only ledger does not arrive as an unattributed paragraph under
    /// the bible's list.
    func test_theLedgersPreambleIsLabelled() throws {
        let section = try XCTUnwrap(
            CompilerPrompt.lessonsSection("I keep learning the same two things."))
        guard let label = section.range(of: "What the writer has learned"),
              let essay = section.range(of: "I keep learning the same two things.")
        else { return XCTFail("expected the label above the preamble; got \(section)") }
        XCTAssertLessThan(label.lowerBound, essay.lowerBound)
    }

    /// The ledger rides the message, after the bible and inside the hash-gated
    /// briefing — it is a thing the writer has DECLARED, like the essay and the
    /// world above it, rather than per-run context like the ask.
    func test_theLedgerRidesTheBriefingAfterTheBible() throws {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.",
            bibleFacts: [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")],
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger, previousBriefingHash: nil)
        guard let bible = message.range(of: "Established so far:"),
              let lessons = message.range(of: "Lessons the writer is working on"),
              let delta = message.range(of: "This run's delta:")
        else { return XCTFail("expected the bible, the ledger and the delta; got \(message)") }
        XCTAssertLessThan(bible.lowerBound, lessons.lowerBound)
        XCTAssertLessThan(lessons.lowerBound, delta.lowerBound)
    }

    /// **The ledger folds INTO the briefing hash** (global constraint 13), and
    /// this is the direction that matters: a lesson the writer kept between two
    /// runs must reach the second one, and a hash blind to it would answer
    /// "unchanged since last run" over a briefing that had changed.
    func test_aChangedLedgerChangesTheBriefingHash() {
        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger, previousBriefingHash: nil)
        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger + "\n- Over-explaining — ruled 2 Sep 2026, Denver",
            previousBriefingHash: firstHash)

        XCTAssertNotNil(firstHash)
        XCTAssertNotEqual(secondHash, firstHash,
                          "a lesson the writer kept between two runs never "
                          + "reached the second one")
        XCTAssertFalse(secondMessage.lowercased().contains("unchanged since last run"))
        XCTAssertTrue(secondMessage.contains("Over-explaining"))
        XCTAssertTrue(secondMessage.contains("Essay text."),
                      "the briefing diffs in as ONE unit — the essay re-embeds too")
    }

    /// The control for the pin above: the same ledger twice does not move the
    /// hash, so "unchanged since last run" still fires for a writer who kept
    /// no new lesson. Without this, a `briefingHashInput` that hashed the
    /// ledger by identity would pass the pin and re-embed everything forever.
    func test_theSameLedgerTwiceLeavesTheHashWhereItWas() {
        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger, previousBriefingHash: nil)
        let (secondMessage, secondHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger, previousBriefingHash: firstHash)

        XCTAssertEqual(secondHash, firstHash)
        XCTAssertTrue(secondMessage.lowercased().contains("unchanged since last run"))
        XCTAssertFalse(secondMessage.contains("Filter words"),
                       "the ledger re-embedded over a marker line that said it had not")
    }

    /// **"Unchanged since last run" fires only when the ledger is also
    /// unchanged.** The marker line covers the essay, the world, the bible AND
    /// the ledger as one unit, so a run whose ledger moved gets all four back
    /// in full rather than a marker that lies about one of them.
    func test_theMarkerLineCoversTheLedgerToo() {
        let world = makeWorld(clauses: [.init(quote: "Keep it wry.", check: "tone check")])
        let facts = [makeFact(subject: "Kelly", fact: "Kelly grew up on the coast.")]
        let (_, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger, previousBriefingHash: nil)
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: world, essay: "Essay text.", bibleFacts: facts,
            paletteListing: [], pinnedListing: [],
            lessons: "## Rulings\n\n- Over-explaining — ruled 2 Sep 2026, Denver",
            previousBriefingHash: firstHash)

        XCTAssertFalse(message.lowercased().contains("unchanged since last run"))
        XCTAssertTrue(message.contains("Essay text."))
        XCTAssertTrue(message.contains("Keep it wry."))
        XCTAssertTrue(message.contains("Kelly grew up on the coast."))
        XCTAssertTrue(message.contains("Over-explaining"))
    }

    /// **A ledger with nothing live in it contributes nothing to the hash.**
    /// The hash is over what is BRIEFED, not over the writer's file: a run
    /// where the only change was retiring a lesson has nothing new to say to
    /// the model, and re-embedding the whole declared world to say it would be
    /// the diff-in rule paying for a section that is not there.
    func test_aLedgerOfOnlyRetiredEntriesLeavesTheHashWhereItWas() {
        let retiredOnly = """
            ## Rulings

            - Throat-clearing (retired 2 Sep 2026) — ruled 1 Sep 2026, Denver
            """
        let (_, without) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        let (message, with) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: retiredOnly, previousBriefingHash: nil)

        XCTAssertEqual(with, without)
        XCTAssertFalse(message.contains("Throat-clearing"))

        // Control: one OPEN lesson is briefed, and the hash moves with it.
        let (openMessage, open) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay text.", bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: retiredOnly + "\n- Filter words — ruled 1 Sep 2026, Denver",
            previousBriefingHash: nil)
        XCTAssertNotEqual(open, without)
        XCTAssertTrue(openMessage.contains("Filter words"))
    }

    /// **A ledger alone is enough to have a hash at all.** The all-absent
    /// guard answers `nil` when there is nothing declared to diff in; a writer
    /// with no intent statement and a ledger has declared something, and a
    /// `nil` hash there would re-embed the ledger every single run.
    func test_aLedgerAloneIsSomethingDeclared() {
        let (message, hash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [],
            lessons: Self.ledger, previousBriefingHash: nil)
        XCTAssertNotNil(hash)
        XCTAssertTrue(message.contains("Filter words"))

        // Control: nothing declared anywhere is still no hash.
        let (_, none) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertNil(none)
    }

    /// The letter's schema asks for the two keys the ledger adds: a habit
    /// citation on each question, and the letter-wide list of what the reading
    /// looked for and did not find.
    func test_theLetterSchemaAsksForTheHabitCitationAndRetired() throws {
        let letterLine = try XCTUnwrap(
            CompilerPrompt.sectionSchemaDescription
                .components(separatedBy: "\n")
                .first(where: { $0.contains("\"section\":\"letter\"") }),
            "the letter's schema line went missing")
        guard let questions = letterLine.range(of: "\"questions\""),
              let habit = letterLine.range(of: "\"habit\""),
              let scenes = letterLine.range(of: "\"scenes\""),
              let retired = letterLine.range(of: "\"retired\"")
        else { return XCTFail("expected all four keys; got \(letterLine)") }
        XCTAssertLessThan(questions.lowerBound, habit.lowerBound,
                          "habit is a key of the question entry, not of the letter")
        XCTAssertLessThan(habit.lowerBound, scenes.lowerBound)
        XCTAssertLessThan(scenes.lowerBound, retired.lowerBound,
                          "retired comes last, after the scene table")
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
    ///
    /// **Measured again at the ask (P2 Task 3), and the 564 above was already
    /// stale: the true total at that point was 593**, `letterInstruction`
    /// having grown by a census fix (`c9639832`) after P1 Task 2 recorded its
    /// number. That is the hazard a measured budget exists to catch, and it
    /// only catches it when somebody re-measures, so both of this task's
    /// numbers are recorded here rather than one:
    ///
    /// - **556 words** once `letterInstruction` was rewritten tighter — the
    ///   same clauses in fewer words, every one of them still pinned by
    ///   `test_theLetterInstructionCarriesItsDoctrineClauseByClause`.
    /// - **593 words** with the ask's own sentence added back on top.
    ///
    /// So the room for the ask was BOUGHT rather than borrowed from the
    /// ceiling: the standing cost of every run is exactly what it was before
    /// this task, with one more thing said in it. The ceiling stays 715.
    ///
    /// **Re-measured at 651 words when the ledger's three sentences joined
    /// `letterInstruction` (P2 Task 4)** — how a known habit is reported, how
    /// a question names the habit it was raised under, and what `retired`
    /// lists. That is 58 words for the whole ledger half of this feature, paid
    /// out of the headroom Task 3's tightening left rather than out of the
    /// ceiling, which stays 715 with 64 words of room still in it.
    ///
    /// **Re-measured three times at the process line (P3 Task 3)**, because a
    /// budget only catches what somebody actually counts and this task both
    /// spent and bought:
    ///
    /// - **651 words** before anything moved — the P2 number above, still
    ///   true, so nothing had grown unnoticed since.
    /// - **635 words** once `letterInstruction` was rewritten tighter again:
    ///   the same clauses in 16 fewer words, every one of them still pinned by
    ///   `test_theLetterInstructionCarriesItsDoctrineClauseByClause`.
    /// - **654 words** with the process sentence added back on top — 19 words
    ///   saying where the letter's one line about the writer's own practice
    ///   comes from and when there is none.
    ///
    /// So the process line cost the standing per-run text 3 words net, not 19,
    /// and the ceiling stays 715 with 61 words of room still in it. The
    /// dosage doctrine is NOT counted here on purpose (global constraint 26):
    /// `stageSection` is per-run frame, written only when there is a stage to
    /// name, and folding it into a standing-overhead budget would measure it
    /// against every run including the ones that never carry it.
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

    /// **The coach's brief is measured against a stage's, not left to grow.**
    ///
    /// `workshopBrief` is deliberately NOT in the standing-overhead list
    /// above: it is a pass brief, and that test already measures one
    /// representative (Structural) because exactly one pass brief rides any
    /// given run. But Le Guin has more to say than a stage does — the letter
    /// is her main event, where for the four stages it is a closing clause —
    /// and a brief that grew without anyone looking would make the coach's
    /// runs quietly the most expensive in the app.
    ///
    /// So the ratio is pinned rather than an absolute: half again the
    /// structural brief is room for a voice with a doctrine, and no more. If
    /// this fails, either her brief grew or a stage's shrank, and both are
    /// worth an editor's eye before the multiplier moves.
    func test_theCoachsBriefStaysWithinHalfAgainOfAStagesBrief() {
        func words(_ text: String) -> Int {
            text.split(whereSeparator: { $0.isWhitespace }).count
        }
        guard let structural = ReviewPass.presets
            .first(where: { $0.id == "structural" })?.brief,
              let workshop = ReviewPass.coachPreset.brief else {
            return XCTFail("a brief went missing")
        }
        let ceiling = words(structural) * 3 / 2
        XCTAssertLessThanOrEqual(words(workshop), ceiling,
            "the coach's brief is \(words(workshop)) words against the "
            + "structural brief's \(words(structural)) — over the "
            + "half-again ceiling of \(ceiling). One of the two moved; look "
            + "at which before raising the multiplier.")
    }

    /// **The coach's process clause is declarative, not conditional** (spec
    /// §4.4, P3 Task 4). The old spelling — "Shown that the frontier has not
    /// moved, she may say so once" — was written before the numbers existed
    /// and reads as a permission granted for a hypothetical. Now the section
    /// is real, has a name (`CompilerPrompt.processHeading`) and arrives only
    /// when a threshold was crossed, so the brief names it and says what she
    /// does with it.
    ///
    /// The three constraints on the saying survive the rewrite verbatim: once,
    /// in her own words, with the numbers behind her, and without scolding.
    ///
    /// Disable experiment: put the old conditional sentence back AHEAD of the
    /// new one, so the brief carried both. This test failed at its
    /// `XCTAssertFalse(workshop.contains("Shown that the frontier"))` line —
    /// the negative is what makes the rewrite a replacement rather than an
    /// addition, and the positive assertion alone would have passed.
    func test_theCoachsBriefNamesTheProcessNumbersDeclaratively() {
        guard let workshop = ReviewPass.coachPreset.brief
        else { return XCTFail("the coach lost her brief") }

        XCTAssertTrue(
            workshop.contains(
                "When the Process numbers say the frontier has not moved, she "
                + "says so once, in her own words, with the numbers behind her "
                + "and without scolding."),
            "got \(workshop)")
        XCTAssertFalse(workshop.contains("Shown that the frontier"),
                       "the conditional spelling is gone, not shadowed by a "
                       + "second sentence; got \(workshop)")
        XCTAssertTrue(workshop.contains(CompilerPrompt.processHeading),
                      "she is told what the section is called, because that is "
                      + "how she finds the numbers; got \(workshop)")
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
