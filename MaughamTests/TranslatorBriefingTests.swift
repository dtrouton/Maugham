// MaughamTests/TranslatorBriefingTests.swift
import MaughamCore
import XCTest
@testable import Maugham

/// `TranslatorBriefing.compose` assembles what one translator run sends to
/// the spawned Claude — `CompilerPrompt`'s sibling, same purity discipline: a
/// plain `Inputs` value in, one message out, no store, no clock, no I/O.
final class TranslatorBriefingTests: XCTestCase {

    // MARK: - Role frame

    func test_roleFrame_namesTheTranslatorAndTheLanguageAndTheIngestRule() {
        let inputs = makeInputs(translatorName: "Cortázar", language: "es")
        let briefing = TranslatorBriefing.compose(inputs: inputs)

        XCTAssertTrue(briefing.contains("Cortázar"))
        XCTAssertTrue(briefing.contains("es"))
        XCTAssertTrue(briefing.contains("you never see your words written back"))
        XCTAssertTrue(briefing.contains("Maugham ingests"))
    }

    func test_roleFrame_includesTheRolesEffectiveBriefWhenPresent() {
        let inputs = makeInputs(roleBrief: "Keep the register formal throughout.")
        let briefing = TranslatorBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("Keep the register formal throughout."))
    }

    func test_roleFrame_noBriefSentenceWhenRoleBriefIsNil() {
        let inputs = makeInputs(roleBrief: nil)
        let briefing = TranslatorBriefing.compose(inputs: inputs)
        // Nothing to assert positively about absence of a whole sentence
        // beyond: composing with a nil brief does not crash and produces no
        // stray blank section (two consecutive blank lines beyond the normal
        // "\n\n" section separator would signal an empty line was appended).
        XCTAssertFalse(briefing.contains("\n\n\n"))
    }

    func test_roleFrame_isTheFirstSection() {
        let inputs = makeInputs(translatorName: "Cortázar")
        let briefing = TranslatorBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.hasPrefix("You are Cortázar"))
    }

    // MARK: - Declared intent / edition brief

    func test_declaredIntent_appearsVerbatimWhenPresent() {
        let inputs = makeInputs(craftIntentText: "This is a quiet, domestic story.")
        let briefing = TranslatorBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("This is a quiet, domestic story."))
    }

    func test_declaredIntent_omittedSectionWhenNilOrEmpty() {
        let nilBriefing = TranslatorBriefing.compose(inputs: makeInputs(craftIntentText: nil))
        XCTAssertFalse(nilBriefing.contains("Declared intent"))

        let emptyBriefing = TranslatorBriefing.compose(inputs: makeInputs(craftIntentText: ""))
        XCTAssertFalse(emptyBriefing.contains("Declared intent"))
    }

    /// The contract's own sentence: "a briefing with a ruling in it contains
    /// the ruling's text" — the `## Rulings` heading and its content both
    /// survive whole into the assembled message.
    func test_editionBrief_carriesItsRulingsIntact() {
        let brief = """
            Register: formal throughout; no contractions.

            ## Rulings

            2026-08-15 — "abuela" stays untranslated; it is a proper form of \
            address in this family, not a generic noun.
            """
        let inputs = makeInputs(editionBriefText: brief)
        let briefing = TranslatorBriefing.compose(inputs: inputs)

        XCTAssertTrue(briefing.contains("## Rulings"))
        XCTAssertTrue(briefing.contains(
            "\"abuela\" stays untranslated; it is a proper form of address"))
        XCTAssertTrue(briefing.contains("Register: formal throughout; no contractions."))
    }

    func test_editionBrief_omittedSectionWhenNilOrEmpty() {
        let nilBriefing = TranslatorBriefing.compose(inputs: makeInputs(editionBriefText: nil))
        XCTAssertFalse(nilBriefing.contains("Edition brief"))

        let emptyBriefing = TranslatorBriefing.compose(inputs: makeInputs(editionBriefText: ""))
        XCTAssertFalse(emptyBriefing.contains("Edition brief"))
    }

    // MARK: - Work list

    func test_workList_missingEntry_carriesItsSourceText() {
        let item = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "a1b2", sourceText: "The house stood empty.",
            status: .missing)
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(workList: [item]))

        XCTAssertTrue(briefing.contains("a1b2"))
        XCTAssertTrue(briefing.contains("The house stood empty."))
        XCTAssertTrue(briefing.contains("missing"))
    }

    func test_workList_staleEntry_carriesSourceAndPriorTranslation() {
        let item = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "c3d4", sourceText: "The house stood empty, waiting.",
            status: .stale, priorTranslation: "La casa estaba vacía.")
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(workList: [item]))

        XCTAssertTrue(briefing.contains("c3d4"))
        XCTAssertTrue(briefing.contains("The house stood empty, waiting."))
        XCTAssertTrue(briefing.contains("La casa estaba vacía."))
        XCTAssertTrue(briefing.contains("stale"))
    }

    func test_workList_staleEntry_withNoPriorTranslation_doesNotClaimOne() {
        let item = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "e5f6", sourceText: "New text.", status: .stale, priorTranslation: nil)
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(workList: [item]))
        XCTAssertFalse(briefing.contains("Prior translation"))
    }

    func test_workList_empty_saysNothingNeedsTranslation() {
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(workList: []))
        XCTAssertTrue(briefing.contains("nothing needs translation"))
    }

    // MARK: - Neighbor context

    func test_context_isMarkedAsContextNotWork() {
        let context = TranslatorBriefing.Inputs.ContextParagraph(
            paragraphId: "g7h8", text: "The garden had gone to seed.")
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(contextParagraphs: [context]))

        XCTAssertTrue(briefing.contains("g7h8"))
        XCTAssertTrue(briefing.contains("The garden had gone to seed."))
        XCTAssertTrue(briefing.contains("(context)"))
        XCTAssertTrue(briefing.contains("not this round's work"))
    }

    func test_context_dedupesAgainstTheWorkListByParagraphId() {
        let work = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "j9k1", sourceText: "Work paragraph.", status: .missing)
        // Same id as the work item, but claiming to be its own neighbor —
        // must not appear a second time, and must not appear at all in the
        // context section since it is already work.
        let context = TranslatorBriefing.Inputs.ContextParagraph(
            paragraphId: "j9k1", text: "Work paragraph.")
        let briefing = TranslatorBriefing.compose(
            inputs: makeInputs(workList: [work], contextParagraphs: [context]))

        // No context section at all, since its only entry was excluded.
        XCTAssertFalse(briefing.contains("(context)"))
    }

    func test_context_dedupesRepeatsAmongItself() {
        // Two work items sharing one neighbor: the neighbor is supplied
        // twice (once per work item), and must render once.
        let workA = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "m2n3", sourceText: "First.", status: .missing)
        let workB = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "p4q5", sourceText: "Third.", status: .missing)
        let sharedNeighbor = TranslatorBriefing.Inputs.ContextParagraph(
            paragraphId: "r6s7", text: "Second, between them.")
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(
            workList: [workA, workB], contextParagraphs: [sharedNeighbor, sharedNeighbor]))

        let occurrences = briefing.components(separatedBy: "Second, between them.").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func test_context_noSectionWhenEmpty() {
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(contextParagraphs: []))
        XCTAssertFalse(briefing.contains("(context)"))
    }

    // MARK: - Queries

    func test_openQuery_documentLevel_andParagraphScoped_bothRender() {
        let docLevel = TranslatorBriefing.Inputs.OpenQuery(text: "Should the title stay in Spanish?")
        let scoped = TranslatorBriefing.Inputs.OpenQuery(
            paragraphId: "t8v9", text: "Is this a proper name?")
        let briefing = TranslatorBriefing.compose(
            inputs: makeInputs(openQueries: [docLevel, scoped]))

        XCTAssertTrue(briefing.contains("Should the title stay in Spanish?"))
        XCTAssertTrue(briefing.contains("whole document"))
        XCTAssertTrue(briefing.contains("t8v9"))
        XCTAssertTrue(briefing.contains("Is this a proper name?"))
    }

    func test_answeredQuery_carriesTheWritersAnswer() {
        let answered = TranslatorBriefing.Inputs.AnsweredQuery(
            paragraphId: "w1x2", text: "Is this a proper name?", answer: "Yes, keep it as-is.")
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(answeredQueries: [answered]))

        XCTAssertTrue(briefing.contains("Is this a proper name?"))
        XCTAssertTrue(briefing.contains("Yes, keep it as-is."))
    }

    func test_queries_noSectionWhenBothEmpty() {
        let briefing = TranslatorBriefing.compose(
            inputs: makeInputs(openQueries: [], answeredQueries: []))
        XCTAssertFalse(briefing.contains("Queries from earlier rounds"))
    }

    /// The cap discipline `CompilerPrompt.settledDispositionLimit` uses for
    /// dispositions, mirrored: the answered half is capped and says how many
    /// were left out; the open half is not touched by the cap at all.
    func test_answeredQueries_capHolds() {
        let answered = (0..<(TranslatorBriefing.answeredQueryLimit + 5)).map { i in
            TranslatorBriefing.Inputs.AnsweredQuery(
                paragraphId: nil, text: "Question \(i)?", answer: "Answer \(i).")
        }
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(answeredQueries: answered))

        // Only the first `answeredQueryLimit` answers are rendered by text.
        for i in 0..<TranslatorBriefing.answeredQueryLimit {
            XCTAssertTrue(briefing.contains("Answer \(i)."), "expected Answer \(i). to appear")
        }
        for i in TranslatorBriefing.answeredQueryLimit..<(TranslatorBriefing.answeredQueryLimit + 5) {
            XCTAssertFalse(briefing.contains("Answer \(i)."), "did not expect Answer \(i). to appear")
        }
        XCTAssertTrue(briefing.contains("and 5 more"))
    }

    func test_openQueries_areNotCapped() {
        let open = (0..<(TranslatorBriefing.answeredQueryLimit + 5)).map { i in
            TranslatorBriefing.Inputs.OpenQuery(text: "Open question \(i)?")
        }
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(openQueries: open))
        for i in 0..<open.count {
            XCTAssertTrue(briefing.contains("Open question \(i)?"))
        }
    }

    // MARK: - Report contract

    func test_reportContract_appearsVerbatimAsTheLastSection() {
        let briefing = TranslatorBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.contains(TranslatorReport.schemaDescription))
        XCTAssertTrue(briefing.hasSuffix(TranslatorReport.schemaDescription))
    }

    // MARK: - Anchor hygiene

    func test_anchorsAreStrippedFromEmbeddedText() {
        let item = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "y3z4",
            sourceText: "<!-- ¶y3z4 -->\n\nThe house stood empty.",
            status: .missing)
        let briefing = TranslatorBriefing.compose(inputs: makeInputs(workList: [item]))
        XCTAssertFalse(briefing.contains("<!--"))
        XCTAssertTrue(briefing.contains("The house stood empty."))
    }

    // MARK: - Fixture

    private func makeInputs(
        translatorName: String = "Cortázar", language: String = "es",
        roleBrief: String? = nil, craftIntentText: String? = nil,
        editionBriefText: String? = nil,
        workList: [TranslatorBriefing.Inputs.WorkItem] = [],
        contextParagraphs: [TranslatorBriefing.Inputs.ContextParagraph] = [],
        openQueries: [TranslatorBriefing.Inputs.OpenQuery] = [],
        answeredQueries: [TranslatorBriefing.Inputs.AnsweredQuery] = []
    ) -> TranslatorBriefing.Inputs {
        TranslatorBriefing.Inputs(
            translatorName: translatorName, language: language, roleBrief: roleBrief,
            craftIntentText: craftIntentText, editionBriefText: editionBriefText,
            workList: workList, contextParagraphs: contextParagraphs,
            openQueries: openQueries, answeredQueries: answeredQueries)
    }
}
