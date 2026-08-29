import XCTest
@testable import Maugham

/// **The pipeline over fake orchestrators** (spec §12): leg order, every skip
/// rule with its reason, failure stopping the rest and keeping earlier
/// writes, minting by id. Cancel, generation and the book queue are
/// `TranslationPipelineCancelTests`' (Task 5).
@MainActor
final class TranslationPipelineTests: XCTestCase {

    // MARK: - A scripted world

    /// Every closure the pipeline calls, answered from a script and recorded.
    /// Translator legs "end" on the next main-actor hop through the same
    /// `translatorRunEnded` the window wires — the orchestrator's own timing.
    @MainActor
    final class FakeWorld {
        let pipeline = TranslationPipeline()
        var translateOutcome: TranslatorOrchestrator.RunSummary.Outcome =
            .ingested(.init(entriesWritten: 2, queriesMinted: 1))
        /// What a fix leg answers, given what it was briefed. Default: address
        /// every note with a rewrite.
        var fixAnswer: ([TranslatorBriefing.FixNote], Bool) -> TranslatorOrchestrator.RunSummary.Outcome = { notes, isFinal in
            .ingested(.init(
                entriesWritten: notes.count, addressed: notes.map(\.id),
                summary: isFinal ? "Done." : nil,
                glossaryProposals: isFinal ? [.init(term: "fog", rendering: "niebla", reason: "fixed")] : [],
                rewrites: notes.map { .init(paragraphId: $0.paragraphId, beforeRecordId: "b",
                                            before: "old", afterRecordId: "a", after: "new") }))
        }
        var readerInputs: ReaderBriefing.Inputs? = ReaderBriefing.Inputs(
            readerName: "Ocampo", language: "es", authorLanguage: "English",
            paragraphs: [.init(paragraphId: "a1b2", translation: "Llegó la niebla."),
                         .init(paragraphId: "c3d4", translation: "Cerró la puerta.")])
        var collatorInputs: CollatorBriefing.Inputs? = CollatorBriefing.Inputs(
            collatorName: "Borges", language: "es", authorLanguage: "English",
            pairs: [.init(paragraphId: "a1b2", sourceText: "The fog came in.", translation: "Llegó la niebla."),
                    .init(paragraphId: "c3d4", sourceText: "She closed the door.", translation: "Cerró la puerta.")])
        /// Consumed per cold leg, in order (read, re-read, collate). A nil
        /// entry = the default report for that leg.
        var coldEvents: [CompilerRunEvent?] = [nil, nil, nil]
        var readerIdentity: (name: String, roleId: String) = ("Ocampo", "role-reader-es")
        var collatorIdentity: (name: String, roleId: String) = ("Borges", "role-collator-es")
        var nextNumber = 7
        var mintAnswer: (TranslationPipeline.DeclinedMint) -> [String: String] = { mint in
            Dictionary(uniqueKeysWithValues: mint.items.map { ($0.note.id, "ann-\($0.note.id)") })
        }

        private(set) var calls: [String] = []
        /// A world that WRAPS these closures — the cancel suite's `HeldWorld`,
        /// which parks a leg instead of answering it — records the leg here
        /// rather than keeping a second log: a leg that was entered and held
        /// is a leg the pipeline started, and `calls` is the one call log.
        func record(_ call: String) { calls.append(call) }
        private(set) var briefedFixNotes: [[TranslatorBriefing.FixNote]] = []
        private(set) var coldMessages: [String] = []
        private(set) var mints: [TranslationPipeline.DeclinedMint] = []
        private(set) var saved: [TranslationRound] = []
        private(set) var ended: [TranslationRound] = []
        private var runs = 0
        private var coldIndex = 0

        static let readerReport = """
            {"overall":{"verdict":"mixed","text":"Reads well."},\
            "notes":[{"paragraph_id":"a1b2","kind":"rhythm","severity":"minor","text":"Limps."}]}
            """
        static let collatorReport = """
            {"overall":{"text":"Holds."},"departures":[\
            {"paragraph_id":"a1b2","verdict":"drifted","kind":"omission","note":"Lost a clause.","gloss":"The fog came."},\
            {"paragraph_id":"c3d4","verdict":"holds","kind":"rendering","note":"Split.","gloss":"She shut it."}]}
            """

        init() {
            pipeline.configure(environment: environment())
        }

        func environment() -> TranslationPipeline.Environment {
            TranslationPipeline.Environment(
                model: "test-model",
                runTranslation: { [unowned self] docId, language in
                    calls.append("translate")
                    return end(with: translateOutcome, docId: docId, language: language)
                },
                runFix: { [unowned self] docId, language, notes, isFinal in
                    calls.append("fix")
                    briefedFixNotes.append(notes)
                    return end(with: fixAnswer(notes, isFinal), docId: docId, language: language)
                },
                cancelTranslator: { [unowned self] in calls.append("cancelTranslator") },
                translatorName: { _ in "Cortázar" },
                readerIdentity: { [unowned self] _ in readerIdentity },
                collatorIdentity: { [unowned self] _ in collatorIdentity },
                briefReader: { [unowned self] _, _ in readerInputs },
                briefCollator: { [unowned self] _, _ in collatorInputs },
                coldCall: { [unowned self] message, _, _ in
                    calls.append("cold")
                    coldMessages.append(message)
                    let scripted = coldIndex < coldEvents.count ? coldEvents[coldIndex] : nil
                    coldIndex += 1
                    if let scripted { return scripted }
                    return .resultText(
                        message.contains("side by side") ? Self.collatorReport : Self.readerReport)
                },
                cancelColdCall: { [unowned self] in calls.append("cancelColdCall") },
                mintDeclinedQueries: { [unowned self] mint in
                    mints.append(mint)
                    return mintAnswer(mint)
                },
                nextRoundNumber: { [unowned self] _ in nextNumber },
                saveRound: { [unowned self] in saved.append($0) },
                onRoundEnded: { [unowned self] in ended.append($0) })
        }

        private func end(with outcome: TranslatorOrchestrator.RunSummary.Outcome,
                         docId: String, language: String) -> String {
            runs += 1
            let runId = "run-\(runs)"
            Task { [pipeline] in
                pipeline.translatorRunEnded(.init(
                    runId: runId, docId: docId, language: language, at: Date(), outcome: outcome))
            }
            return runId
        }
    }

    /// Spin the main actor until the round is saved (or fail after ~2s).
    /// Static so the cancel suite can share it without instantiating a case.
    static func settle(_ world: FakeWorld, rounds: Int = 1,
                       file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if world.saved.count >= rounds, world.pipeline.status == .idle { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the pipeline did not settle", file: file, line: line)
    }

    private func legs(_ round: TranslationRound) -> [(TranslationRound.Leg, TranslationRound.LegStatus)] {
        round.legs.map { ($0.leg, $0.status) }
    }

    // MARK: - Order and the record

    func test_theSevenLegsRunInOrderAndTheRoundRecordsEachOfThem() async throws {
        let world = FakeWorld()
        XCTAssertTrue(world.pipeline.run(docId: "doc-1", language: "es"))
        await Self.settle(world)

        XCTAssertEqual(world.calls, ["translate", "cold", "fix", "cold", "fix", "cold", "fix"])
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.number, 7)
        XCTAssertEqual(round.language, "es")
        XCTAssertEqual(round.docId, "doc-1")
        XCTAssertNotNil(round.endedAt)
        XCTAssertEqual(round.legs.map(\.leg), TranslationRound.Leg.allCases)
        XCTAssertTrue(round.legs.allSatisfy { $0.status == .ran })
        XCTAssertEqual(round.legs[0].counts, .init(entries: 2, queries: 1))
        XCTAssertEqual(round.leg2?.verdict, "mixed")
        XCTAssertEqual(round.leg4?.text, "Reads well.")
        XCTAssertEqual(round.collatorOverall, "Holds.")
        XCTAssertEqual(round.notes.map(\.leg), [.read, .reread])
        XCTAssertEqual(round.notes.map(\.author), ["Ocampo", "Ocampo"])
        XCTAssertEqual(round.departures.map(\.verdict), ["drifted", "holds"])
        XCTAssertEqual(round.summary, "Done.")
        XCTAssertEqual(round.glossaryProposals.map(\.term), ["fog"])
        XCTAssertEqual(round.glossaryProposals.first?.adopted, false)
        XCTAssertEqual(world.ended, [round])
        XCTAssertEqual(world.pipeline.status, .idle)
    }

    /// The ids the fix leg is briefed with are the record's own, minted
    /// before the leg — so `addressed` lands on the note it names, with the
    /// paragraph's before/after from the rewrite ingest reported.
    func test_noteIdsAreMintedBeforeTheFixLegAndAreWhatItsAnswersName() async throws {
        let world = FakeWorld()
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)

        XCTAssertEqual(world.briefedFixNotes.count, 3)
        XCTAssertEqual(world.briefedFixNotes[0].map(\.id), [round.notes[0].id])
        XCTAssertEqual(world.briefedFixNotes[0].first?.kind, "rhythm")
        XCTAssertEqual(world.briefedFixNotes[0].first?.severity, "minor")
        XCTAssertEqual(world.briefedFixNotes[1].map(\.id), [round.notes[1].id])
        XCTAssertEqual(world.briefedFixNotes[2].map(\.id), [round.departures[0].id],
                       "leg 7 is briefed with the DRIFTED departures only")
        XCTAssertNil(world.briefedFixNotes[2].first?.severity)
        XCTAssertTrue(world.briefedFixNotes[2].first?.text.contains("The fog came.") == true,
                      "a departure's fix note carries the gloss")
        XCTAssertEqual(round.notes[0].outcome,
                       .addressed(.init(beforeRecordId: "b", before: "old",
                                        afterRecordId: "a", after: "new")))
        XCTAssertEqual(round.departures[0].outcome,
                       .addressed(.init(beforeRecordId: "b", before: "old",
                                        afterRecordId: "a", after: "new")))
        XCTAssertNil(round.departures[1].outcome, "a holds departure is never fix work")
        XCTAssertEqual(round.legs[2].counts?.addressed, 1)
    }

    /// The reader is sent exactly the composed briefing, and its report is
    /// parsed against the ids it was briefed with.
    func test_theColdLegsSendTheComposedBriefings() async throws {
        let world = FakeWorld()
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        XCTAssertEqual(world.coldMessages[0],
                       ReaderBriefing.compose(inputs: try XCTUnwrap(world.readerInputs)))
        XCTAssertEqual(world.coldMessages[2],
                       CollatorBriefing.compose(inputs: try XCTUnwrap(world.collatorInputs)))
    }

    // MARK: - Skips, each with its reason

    func test_aReadWithNothingTranslatedSkipsAndSoDoesEverythingAfterIt() async throws {
        let world = FakeWorld()
        world.readerInputs = ReaderBriefing.Inputs(
            readerName: "Ocampo", language: "es", authorLanguage: "English",
            paragraphs: [.init(paragraphId: "a1b2", translation: nil)])
        world.translateOutcome = .nothingToTranslate
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)

        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate"])
        XCTAssertEqual(round.legs.map(\.status), Array(repeating: .skipped, count: 7))
        XCTAssertEqual(round.legs[0].reason, TranslationPipeline.nothingToTranslateReason)
        XCTAssertEqual(round.legs[1].reason, TranslationPipeline.nothingToReadReason)
        XCTAssertEqual(round.legs[2].reason, TranslationPipeline.readerFoundNothingReason)
        XCTAssertEqual(round.legs[3].reason, TranslationPipeline.nothingChangedReason)
        XCTAssertEqual(round.legs[5].reason, TranslationPipeline.nothingWrittenReason)
        XCTAssertEqual(round.legs[6].reason, TranslationPipeline.collatorFoundNoDriftReason)
        XCTAssertEqual(round.summary, TranslationPipeline.nothingToDoSummary)
    }

    func test_aFixWithNoNotesIsASkipAndTheRereadSkipsBecauseNothingChanged() async throws {
        let world = FakeWorld()
        world.coldEvents = [.resultText(#"{"overall":{"verdict":"reads_as_native","text":"Fine."},"notes":[]}"#), nil, nil]
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)

        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate", "cold", "cold", "fix"],
                       "leg 6 still collates because leg 1 wrote; leg 7 fixes its drift")
        XCTAssertEqual(legs(round).map(\.1),
                       [.ran, .ran, .skipped, .skipped, .skipped, .ran, .ran])
        XCTAssertEqual(round.legs[2].reason, TranslationPipeline.readerFoundNothingReason)
        XCTAssertEqual(round.legs[3].reason, TranslationPipeline.nothingChangedReason)
        XCTAssertEqual(round.legs[4].reason, TranslationPipeline.readerFoundNothingReason)
    }

    func test_aFixWhoseNotedParagraphsLostTheirTranslationIsRecordedAsASkip() async throws {
        let world = FakeWorld()
        world.fixAnswer = { _, _ in .nothingToTranslate }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.legs[2].status, .skipped)
        XCTAssertEqual(round.legs[2].reason, TranslationPipeline.noCurrentTranslationReason)
        XCTAssertNil(round.notes[0].outcome, "a note the leg never reached has no outcome")
    }

    func test_collateSkipsWhenNothingWasWrittenEvenThoughTheReaderSpoke() async throws {
        let world = FakeWorld()
        world.translateOutcome = .nothingToTranslate
        world.fixAnswer = { notes, _ in
            .ingested(.init(entriesWritten: 0, declined: notes.map { .init(noteId: $0.id, reason: "Deliberate.") }))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate", "cold", "fix"])
        XCTAssertEqual(round.legs[5].status, .skipped)
        XCTAssertEqual(round.legs[5].reason, TranslationPipeline.nothingWrittenReason)
        XCTAssertEqual(round.summary, TranslationPipeline.nothingToDoSummary)
    }

    // MARK: - Failure ends it there

    func test_aFailedLegEndsThePipelineThereAndKeepsEarlierLegs() async throws {
        let world = FakeWorld()
        world.coldEvents = [.failed(.sessionDied(detail: "boom")), nil, nil]
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)

        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(world.calls, ["translate", "cold"])
        XCTAssertEqual(legs(round).map(\.1), [.ran, .failed])
        XCTAssertEqual(round.legs[0].counts?.entries, 2, "leg 1's writes stay")
        XCTAssertEqual(round.legs[1].reason,
                       RoundNarrative.failureCopy(.sessionDied(detail: "boom"), session: .translation))
        XCTAssertEqual(round.stoppedAt, .read)
        XCTAssertNil(round.summary)
    }

    func test_anIngestRejectionIsAFailedLeg() async throws {
        let world = FakeWorld()
        world.translateOutcome = .ingested(.init(rejection: "paragraphs edited while this round was running: a1b2"))
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(legs(round).map(\.1), [.failed])
        XCTAssertEqual(round.legs[0].reason, "paragraphs edited while this round was running: a1b2")
    }

    func test_unusableReaderOutputFailsTheReadLeg() async throws {
        let world = FakeWorld()
        world.coldEvents = [.resultText("I would rather not."), nil, nil]
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(legs(round).map(\.1), [.ran, .failed])
        XCTAssertEqual(round.legs[1].reason,
                       RoundNarrative.failureCopy(.unusableOutput, session: .translation))
    }

    func test_aTranslatorThatRefusesToStartIsAFailedLeg() async throws {
        let world = FakeWorld()
        var environment = world.environment()
        environment.runTranslation = { _, _ in nil }
        world.pipeline.configure(environment: environment)
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(legs(round).map(\.1), [.failed])
        XCTAssertEqual(round.legs[0].reason, TranslationPipeline.translatorRefusedSentence)
    }

    func test_aReaderWhoCannotBeBriefedOrNamedIsAFailedLeg() async throws {
        let world = FakeWorld()
        world.readerInputs = nil
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        XCTAssertEqual(world.saved.first?.legs[1].reason,
                       TranslationPipeline.unbriefableSentence(role: "reader"))
    }

    // MARK: - Minting by id

    func test_declinedNotesAreMintedWithTheTranslatorsReasonAndRecorded() async throws {
        let world = FakeWorld()
        world.fixAnswer = { notes, isFinal in
            .ingested(.init(entriesWritten: 0,
                            declined: notes.map { .init(noteId: $0.id, reason: "Deliberate.") },
                            summary: isFinal ? "Nothing changed." : nil))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)

        // Leg 3 declined and wrote nothing, so leg 4 skips (nothing changed)
        // and leg 5 has no notes; leg 6 still collates because leg 1 wrote,
        // and leg 7 declines its one drifted departure: two mints.
        XCTAssertEqual(world.mints.count, 2)
        let first = world.mints[0]
        XCTAssertEqual(first.docId, "doc-1")
        XCTAssertEqual(first.language, "es")
        XCTAssertEqual(first.translatorName, "Cortázar")
        XCTAssertEqual(first.items.map(\.reason), ["Deliberate."])
        XCTAssertEqual(first.items.map(\.authorRoleId), ["role-reader-es"])
        XCTAssertEqual(world.mints[1].items.map(\.authorRoleId), ["role-collator-es"])
        XCTAssertEqual(round.notes[0].outcome,
                       .declined(reason: "Deliberate.", annotationId: "ann-\(round.notes[0].id)"))
        XCTAssertEqual(round.departures[0].outcome,
                       .declined(reason: "Deliberate.", annotationId: "ann-\(round.departures[0].id)"))
        XCTAssertEqual(round.legs[2].counts?.declined, 1)
    }

    func test_anAddressedNoteWithNoEntryIsRecordedWithTheTranslationUnchanged() async throws {
        let world = FakeWorld()
        world.fixAnswer = { notes, _ in
            .ingested(.init(entriesWritten: 0, addressed: notes.map(\.id)))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.notes[0].outcome,
                       .addressed(.init(beforeRecordId: nil, before: nil, afterRecordId: nil, after: nil)))
        XCTAssertTrue(world.mints.isEmpty)
    }

    /// **A leg records outcomes for its own work-list and nothing else.**
    /// Legs 3 and 5 are two turns of ONE warm translator session, so leg 2's
    /// note ids are still in the model's context when leg 5 answers. An id
    /// echoed out of the earlier turn must not reach into the row leg 3
    /// already ruled on — the author would read a verdict no leg reached.
    func test_aFixLegRecordsOutcomesOnlyForTheNotesItWasBriefedWith() async throws {
        let world = FakeWorld()
        var leg3NoteIds: [String] = []
        world.fixAnswer = { notes, isFinal in
            if isFinal {
                return .ingested(.init(entriesWritten: 1, addressed: notes.map(\.id)))
            }
            if leg3NoteIds.isEmpty {
                leg3NoteIds = notes.map(\.id)
                return .ingested(.init(
                    entriesWritten: 1, addressed: notes.map(\.id),
                    rewrites: notes.map { .init(paragraphId: $0.paragraphId, beforeRecordId: "b",
                                                before: "old", afterRecordId: "a", after: "new") }))
            }
            // Leg 5: its own note, plus leg 2's id echoed back out of the
            // warm session with a verdict that contradicts leg 3's.
            return .ingested(.init(
                entriesWritten: 1, addressed: notes.map(\.id),
                declined: leg3NoteIds.map { .init(noteId: $0, reason: "Echo.") }))
        }
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)

        XCTAssertEqual(round.notes.count, 2)
        XCTAssertEqual(round.notes[0].id, leg3NoteIds.first)
        XCTAssertEqual(round.notes[0].outcome,
                       .addressed(.init(beforeRecordId: "b", before: "old",
                                        afterRecordId: "a", after: "new")),
                       "leg 5 cannot overwrite leg 3's verdict on leg 2's note")
        XCTAssertEqual(round.notes[1].outcome,
                       .addressed(.init(beforeRecordId: nil, before: nil,
                                        afterRecordId: nil, after: nil)),
                       "leg 5 still records its own")
        XCTAssertFalse(world.mints.contains { mint in
            mint.items.contains { $0.note.id == leg3NoteIds.first }
        }, "and never mints a query against a note it was not briefed with")
    }

    /// A summary landing synchronously inside `start()` has already resumed
    /// the leg; a `nil` run id arriving afterwards must not resume it a
    /// second time. (`CheckedContinuation` traps on a double resume, so the
    /// unguarded shape fails this as a crash, not an assertion.)
    func test_aSummaryThatLandsInsideTheStartCallIsTheLegsAnswer() async throws {
        let world = FakeWorld()
        var environment = world.environment()
        environment.runTranslation = { [pipeline = world.pipeline] docId, language in
            pipeline.translatorRunEnded(.init(
                runId: "run-sync", docId: docId, language: language, at: Date(),
                outcome: .ingested(.init(entriesWritten: 3, queriesMinted: 0))))
            return nil
        }
        world.pipeline.configure(environment: environment)
        world.pipeline.run(docId: "doc-1", language: "es")
        await Self.settle(world)
        let round = try XCTUnwrap(world.saved.first)
        XCTAssertEqual(round.legs[0].status, .ran)
        XCTAssertEqual(round.legs[0].counts?.entries, 3)
        XCTAssertNotEqual(round.legs[0].reason, TranslationPipeline.translatorRefusedSentence)
    }

    func test_aSecondRunWhileOneIsRunningIsRefused() async throws {
        let world = FakeWorld()
        XCTAssertTrue(world.pipeline.run(docId: "doc-1", language: "es"))
        XCTAssertFalse(world.pipeline.run(docId: "doc-2", language: "es"))
        await Self.settle(world)
        XCTAssertEqual(world.saved.count, 1)
    }

    func test_anUnconfiguredPipelineRefuses() {
        XCTAssertFalse(TranslationPipeline().run(docId: "doc-1", language: "es"))
    }
}
