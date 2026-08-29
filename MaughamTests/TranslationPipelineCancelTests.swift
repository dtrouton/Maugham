import XCTest
@testable import Maugham

/// Cancel mid-leg and in the gap, shutdown, generation discipline, and the
/// book queue (spec §5, §12). Uses `TranslationPipelineTests.FakeWorld` with
/// its legs held open.
@MainActor
final class TranslationPipelineCancelTests: XCTestCase {

    typealias FakeWorld = TranslationPipelineTests.FakeWorld

    /// A world whose translator legs and cold legs can be HELD until the test
    /// releases them — so a cancel has something in flight to reach.
    ///
    /// A held leg still records itself in `world.calls` (through
    /// `FakeWorld.record`): a leg that was entered and parked is a leg the
    /// pipeline started, and the call log is what the tests read to say so.
    @MainActor
    private final class HeldWorld {
        let world = FakeWorld()
        var holdTranslator = false
        /// A predicate rather than a flag, so a test can hold the cold call
        /// of the SECOND chapter of a book queue without racing the first.
        var holdCold: () -> Bool = { false }
        var holdReaderBriefing = false
        private(set) var heldRunId: String?
        private var heldCold: CheckedContinuation<CompilerRunEvent, Never>?
        private var heldBriefing: CheckedContinuation<Void, Never>?
        private(set) var cancels: [String] = []
        private var runs = 0

        /// Whether a leg is parked right now — the exact condition a test
        /// waits on before cancelling, so no `Task.sleep` has to stand in for
        /// it.
        var isHoldingCold: Bool { heldCold != nil }
        var isHoldingBriefing: Bool { heldBriefing != nil }

        init() {
            var environment = world.environment()
            let base = environment
            environment.runTranslation = { [unowned self] docId, language in
                if holdTranslator {
                    world.record("translate")
                    runs += 1
                    heldRunId = "held-\(runs)"
                    return heldRunId
                }
                return base.runTranslation(docId, language)
            }
            environment.cancelTranslator = { [unowned self] in
                cancels.append("translator")
                if let runId = heldRunId {
                    heldRunId = nil
                    world.pipeline.translatorRunEnded(.init(
                        runId: runId, docId: "doc-1", language: "es", at: Date(), outcome: .cancelled))
                }
            }
            environment.coldCall = { [unowned self] message, preamble, model in
                if holdCold() {
                    world.record("cold")
                    return await withCheckedContinuation { heldCold = $0 }
                }
                return await base.coldCall(message, preamble, model)
            }
            environment.cancelColdCall = { [unowned self] in
                cancels.append("cold")
                let held = heldCold
                heldCold = nil
                held?.resume(returning: .failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
            }
            environment.briefReader = { [unowned self] docId, language in
                if holdReaderBriefing {
                    await withCheckedContinuation { heldBriefing = $0 }
                }
                return await base.briefReader(docId, language)
            }
            world.pipeline.configure(environment: environment)
        }

        /// Let a held cold call resolve on its own — what a shut-down
        /// `ColdCall` session does to a call already in flight, as opposed to
        /// `cancelColdCall` above, which the pipeline reaches deliberately.
        func releaseCold() {
            let held = heldCold
            heldCold = nil
            held?.resume(returning: .failed(
                .sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }

        func releaseBriefing() {
            let held = heldBriefing
            heldBriefing = nil
            held?.resume()
        }

        func waitFor(_ predicate: @escaping () -> Bool,
                     file: StaticString = #filePath, line: UInt = #line) async {
            for _ in 0..<200 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("condition never held", file: file, line: line)
        }
    }

    func test_cancelDuringATranslatorLegReachesTheTranslatorAndEndsTheRound() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }
        XCTAssertEqual(held.world.pipeline.status,
                       .running(docId: "doc-1", language: "es", leg: .translate, book: nil))

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world)

        XCTAssertEqual(held.cancels, ["translator"])
        let round = try XCTUnwrap(held.world.saved.first)
        XCTAssertEqual(round.legs.map(\.status), [.cancelled])
        XCTAssertNil(round.summary)
        XCTAssertEqual(held.world.calls, ["translate"], "nothing later starts")
    }

    func test_cancelDuringAColdLegReachesTheColdCall() async throws {
        let held = HeldWorld()
        held.holdCold = { true }
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.world.calls == ["translate", "cold"] }
        await held.waitFor { held.world.pipeline.status.leg == .read }

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world)

        XCTAssertEqual(held.cancels, ["cold"])
        let round = try XCTUnwrap(held.world.saved.first)
        XCTAssertEqual(round.legs.map(\.status), [.ran, .cancelled])
        XCTAssertEqual(round.legs[0].counts?.entries, 2, "leg 1's writes stay")
        XCTAssertEqual(round.stoppedAt, .read)
    }

    /// A cancel in the GAP — nothing in flight, the next leg's briefing being
    /// gathered — stops the pipeline by generation rather than a leg that
    /// never started: no cold call is made after it.
    func test_cancelInTheGapStopsThePipelineWithoutStartingTheNextLeg() async throws {
        let held = HeldWorld()
        held.holdReaderBriefing = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.world.calls == ["translate"] && held.world.pipeline.status.leg == .read }
        await held.waitFor { held.isHoldingBriefing }   // the gather started and parked

        held.world.pipeline.cancel()
        held.releaseBriefing()
        await TranslationPipelineTests.settle(held.world)

        XCTAssertTrue(held.cancels.isEmpty, "nothing was in flight to cancel")
        XCTAssertEqual(held.world.calls, ["translate"], "the read leg never sent")
        let round = try XCTUnwrap(held.world.saved.first)
        XCTAssertEqual(round.legs.map(\.status), [.ran, .cancelled])
    }

    func test_shutdownMidTranslatorLegSavesACancelledRoundAndGoesIdle() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }

        held.world.pipeline.shutdown()   // the orchestrator's own shutdown emits no summary
        await TranslationPipelineTests.settle(held.world)

        XCTAssertEqual(held.world.pipeline.status, .idle)
        XCTAssertEqual(held.world.saved.first?.legs.map(\.status), [.cancelled])
        held.holdTranslator = false
        XCTAssertTrue(held.world.pipeline.run(docId: "doc-1", language: "es"),
                      "shutdown keeps the environment; the next click works")
        await TranslationPipelineTests.settle(held.world, rounds: 2)
    }

    /// The owner may shut the pipeline down and start another run in the SAME
    /// turn — the AI toggle going off and straight back on. The shut-down run
    /// is still unwinding (its leg was resumed, not run), and when it finishes
    /// it must touch neither the status nor the queue of the run that replaced
    /// it: with a book on the queue, clearing it strands every chapter after
    /// the first.
    ///
    /// This is what `runToken` is for, and it is the case neither obvious
    /// spelling survives: an unconditional reset at the end of `execute`
    /// empties this queue, while `generation == gen` leaves a cancelled round
    /// showing `.running` forever (the cancel tests above).
    func test_aBookStartedTheInstantAfterShutdownIsNotEmptiedByTheOldRun() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }

        held.world.pipeline.shutdown()
        held.holdTranslator = false
        XCTAssertTrue(held.world.pipeline.runBook(documentIds: ["doc-2", "doc-3"], language: "es"))
        XCTAssertEqual(held.world.pipeline.status,
                       .running(docId: "doc-2", language: "es", leg: .translate,
                                book: .init(position: 1, count: 2)))

        await TranslationPipelineTests.settle(held.world, rounds: 3)
        XCTAssertEqual(held.world.saved.map(\.docId), ["doc-1", "doc-2", "doc-3"])
        XCTAssertEqual(held.world.saved[0].legs.map(\.status), [.cancelled],
                       "the shut-down round is still the one that was cut short")
    }

    /// The COLD twin of the test above, and the case `live` has to be scoped
    /// for. `shutdown()` resumes the translator's continuation and nothing
    /// else, so a cold call in flight stays in flight; the owner starts
    /// another run, which parks on its own translator leg; and only then does
    /// the stale call resolve. Its `live = .gap` must not land under the new
    /// run — Cancel would take the `.gap` arm and call nothing at all: the
    /// translator never cancelled, its continuation never resumed, its round
    /// never saved, and a desk stuck on `.running` that only another
    /// `shutdown()` recovers.
    func test_aStaleColdLegDoesNotBlindCancelForTheRunThatReplacedIt() async throws {
        let held = HeldWorld()
        held.holdCold = { true }
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.isHoldingCold }

        held.world.pipeline.shutdown()
        held.holdTranslator = true
        XCTAssertTrue(held.world.pipeline.run(docId: "doc-2", language: "es"))
        await held.waitFor { held.heldRunId != nil }

        held.releaseCold()   // the abandoned leg resolves under the new run
        await held.waitFor { held.world.saved.contains { $0.docId == "doc-1" } }

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world, rounds: 2)

        XCTAssertEqual(held.cancels, ["translator"],
                       "Cancel still reaches the leg the LIVE run is on")
        XCTAssertEqual(held.world.pipeline.status, .idle)
        // The stale round unwinds whenever its call resolves, so the order in
        // `saved` is not the order the rounds started in — read them by docId.
        let abandoned = try XCTUnwrap(held.world.saved.first { $0.docId == "doc-1" })
        XCTAssertEqual(abandoned.legs.map(\.status), [.ran, .cancelled])
        let live = try XCTUnwrap(held.world.saved.first { $0.docId == "doc-2" })
        XCTAssertEqual(live.legs.map(\.status), [.cancelled])
    }

    func test_detachDropsTheEnvironmentAndRefusesTheNextRun() {
        let world = FakeWorld()
        world.pipeline.detach()
        XCTAssertFalse(world.pipeline.run(docId: "doc-1", language: "es"))
    }

    func test_aSummaryForAnotherRunIsIgnored() async throws {
        let held = HeldWorld()
        held.holdTranslator = true
        held.world.pipeline.run(docId: "doc-1", language: "es")
        await held.waitFor { held.heldRunId != nil }
        held.world.pipeline.translatorRunEnded(.init(
            runId: "somebody-elses", docId: "doc-1", language: "es", at: Date(),
            outcome: .ingested(.init(entriesWritten: 9))))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(held.world.pipeline.status.leg, .translate, "still waiting on its own run")
        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world)
    }

    // MARK: - The book queue

    func test_theBookQueueRunsEveryChapterInOrderWithConsecutiveNumbers() async throws {
        let world = FakeWorld()
        var number = 3
        var environment = world.environment()
        environment.nextRoundNumber = { _ in defer { number += 1 }; return number }
        world.pipeline.configure(environment: environment)

        XCTAssertTrue(world.pipeline.runBook(documentIds: ["doc-1", "doc-2", "doc-3"], language: "es"))
        XCTAssertEqual(world.pipeline.status,
                       .running(docId: "doc-1", language: "es", leg: .translate,
                                book: .init(position: 1, count: 3)))
        await TranslationPipelineTests.settle(world, rounds: 3)

        XCTAssertEqual(world.saved.map(\.docId), ["doc-1", "doc-2", "doc-3"])
        XCTAssertEqual(world.saved.map(\.number), [3, 4, 5])
        XCTAssertEqual(world.ended.count, 3)
        XCTAssertEqual(world.pipeline.status, .idle)
    }

    func test_cancelStopsTheBookQueueAfterTheLiveLeg() async throws {
        let held = HeldWorld()
        // Hold chapter 2's first cold call — decided at the call, so chapter
        // 1's three cold legs run free and there is no race to set a flag in.
        held.holdCold = { held.world.saved.count == 1 }
        held.world.pipeline.runBook(documentIds: ["doc-1", "doc-2", "doc-3"], language: "es")
        await held.waitFor { held.world.pipeline.status == .running(docId: "doc-2", language: "es", leg: .read, book: .init(position: 2, count: 3)) }
        await held.waitFor { held.isHoldingCold }
        XCTAssertEqual(held.world.calls.count, 9,
                       "chapter 1's seven legs, then chapter 2's translate and its held cold")

        held.world.pipeline.cancel()
        await TranslationPipelineTests.settle(held.world, rounds: 2)

        XCTAssertEqual(held.world.saved.map(\.docId), ["doc-1", "doc-2"])
        XCTAssertTrue(held.world.saved[1].wasCancelled)
        XCTAssertEqual(held.world.pipeline.status, .idle)
    }

    func test_aFailedRoundStopsTheBookQueue() async throws {
        let world = FakeWorld()
        world.coldEvents = [nil, nil, nil, .failed(.sessionDied(detail: "boom"))]   // chapter 2's read
        world.pipeline.runBook(documentIds: ["doc-1", "doc-2", "doc-3"], language: "es")
        await TranslationPipelineTests.settle(world, rounds: 2)
        XCTAssertEqual(world.saved.map(\.docId), ["doc-1", "doc-2"])
        XCTAssertEqual(world.saved[1].stoppedAt, .read)
    }

    func test_anEmptyBookIsRefused() {
        XCTAssertFalse(FakeWorld().pipeline.runBook(documentIds: [], language: "es"))
    }
}

private extension TranslationPipeline.Status {
    var leg: TranslationRound.Leg? {
        if case .running(_, _, let leg, _) = self { return leg }
        return nil
    }
}
