import XCTest
@testable import MaughamCore
@testable import Maugham

/// **`AgentRoster`: one owner, one teardown order, one model fan-out.**
///
/// The order is the load-bearing claim, and it is asserted through what the
/// services DO rather than through the roster's source: a translator leg is
/// parked in a real `TranslationPipeline` on a real `TranslatorOrchestrator`
/// whose session is a spy holding its turn open, and the spy records, at the
/// instant its session is ended, whether the pipeline was still running. The
/// pipeline must already be idle by then — a parked leg is resolved before
/// the translator it waits on stops existing.
///
/// Which services are members at all is `TranslatorEnvironmentTests`' census
/// (`test_everyWindowEndingPathShutsEverySessionDown`); this file is about
/// what membership does.
@MainActor
final class AgentRosterTests: XCTestCase {

    typealias FakeWorld = TranslationPipelineTests.FakeWorld

    /// A session that holds every turn open and remembers whether the
    /// pipeline was still running when it was ended.
    @MainActor
    private final class OrderSpy: CompilerRunner {
        let pipeline: TranslationPipeline
        private(set) var sends = 0
        private(set) var pipelineRunningAtShutdown: [Bool] = []
        var isRunning = false
        var sessionEpoch = 1
        private var held: CheckedContinuation<CompilerRunEvent, Never>?

        init(pipeline: TranslationPipeline) { self.pipeline = pipeline }

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sends += 1
            isRunning = true
            return await withCheckedContinuation { held = $0 }
        }

        private func release(_ event: CompilerRunEvent) {
            isRunning = false
            let continuation = held
            held = nil
            continuation?.resume(returning: event)
        }

        func cancelCurrentRun() {
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        }

        func shutdown() {
            pipelineRunningAtShutdown.append(pipeline.isRunning)
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }
    }

    /// A window's worth of services with a translator leg parked in the
    /// pipeline, a cold call out, a compiler check and a design round in
    /// flight — every one on an `OrderSpy` session, so a teardown that misses
    /// ANY service leaves that spy's record empty.
    private struct Parked {
        let world: FakeWorld
        let roster: AgentRoster
        let translatorSession: OrderSpy
        let coldSession: OrderSpy
        let compilerSession: OrderSpy
        let designerSession: OrderSpy
        let coldCallResult: Task<CompilerRunEvent, Never>

        var sessions: [(name: String, spy: OrderSpy)] {
            [("translator", translatorSession), ("coldCall", coldSession),
             ("compiler", compilerSession), ("designer", designerSession)]
        }
    }

    private func parkedRoster() async throws -> Parked {
        let world = FakeWorld()
        let translator = TranslatorOrchestrator()
        let coldCall = ColdCall()
        let translatorSession = OrderSpy(pipeline: world.pipeline)
        let coldSession = OrderSpy(pipeline: world.pipeline)
        let configURL = TestTemp.root.appendingPathComponent("translator-mcp.json")

        let item = TranslatorBriefing.Inputs.WorkItem(
            paragraphId: "a1b2", sourceText: "The fog came.", status: .missing)
        let round = TranslatorOrchestrator.BriefedRound(
            inputs: TranslatorBriefing.Inputs(
                translatorName: "Elena Ruiz", language: "es", workList: [item], mode: .translate),
            sourceHashes: ["a1b2": TranslationHash.hash(item.sourceText)])
        let pipeline = world.pipeline
        translator.configure(environment: TranslatorOrchestrator.Environment(
            projectId: "p-1",
            model: "test-model",
            briefRound: { _, _ in round },
            briefFix: { _, _, _, _ in round },
            translatorIdentity: { _ in ("Elena Ruiz", "role-es") },
            writeMCPConfig: {
                try Data("{}".utf8).write(to: configURL, options: .atomic)
                return configURL
            },
            makeRunner: { _, _ in translatorSession },
            ingest: { _, _ in .init(entriesWritten: 0, queriesMinted: 0) },
            onRunEnded: { [weak pipeline] in pipeline?.translatorRunEnded($0) },
            onRunAbandoned: { [weak pipeline] in pipeline?.translatorRunAbandoned($0) }))

        var environment = world.environment()
        environment.runTranslation = { [weak translator] docId, language in
            translator?.runTranslation(docId: docId, language: language)
        }
        environment.cancelTranslator = { [weak translator] in translator?.cancel() }
        pipeline.configure(environment: environment)
        coldCall.configure(makeRunner: { _ in coldSession })

        let compiler = CompilerOrchestrator()
        let compilerSession = OrderSpy(pipeline: pipeline)
        compiler.configure(
            environment: CompilerOrchestrator.Environment(
                projectId: "p-1",
                model: "test-model",
                prepareForRun: { _ in },
                reading: { id in
                    id == "doc-1"
                        ? CompilerOrchestrator.DocumentReading(
                            ops: [Op(opId: "op1", docId: id, at: Date(), device: "macA",
                                     session: "s", kind: .bootstrap,
                                     changes: [.init(paragraphId: "a1b2", prior: nil,
                                                     next: "The fog came.")],
                                     sequence: nil)],
                            paragraphs: ["a1b2": "The fog came."], sequence: ["a1b2"])
                        : nil
                },
                liveParagraphText: { _, _ in "The fog came." },
                intent: { _ in nil },
                cachedWorld: { _ in nil },
                deriveWorld: { _, _ in nil },
                bibleSlice: { _ in [] },
                recordFacts: { _ in },
                pinnedListing: { _ in [] },
                paletteListing: { [] },
                writeMCPConfig: { TestTemp.root.appendingPathComponent("compiler-mcp.json") },
                makeRunner: { _, _ in compilerSession },
                onRunAcknowledged: { _ in }),
            diagnostics: DiagnosticsStore(
                projectRoot: TestTemp.root, device: DeviceSlug.make(from: "test-mac")))

        let designer = DesignerOrchestrator()
        let designerSession = OrderSpy(pipeline: pipeline)
        let designerConfigURL = TestTemp.root.appendingPathComponent("designer-mcp.json")
        designer.configure(environment: DesignerOrchestrator.Environment(
            projectId: "p-1",
            model: "test-model",
            briefRound: { _, language in
                DesignerBriefing.Inputs(
                    designerName: "Tschichold", roleBrief: "Design the page.",
                    visualLanguageText: "Warm paper.", language: language, direction: nil)
            },
            writeMCPConfig: {
                try Data("{}".utf8).write(to: designerConfigURL, options: .atomic)
                return designerConfigURL
            },
            makeRunner: { _, _ in designerSession },
            stage: { _, _ in .init() },
            onRunEnded: { _ in }))

        let roster = AgentRoster(compiler: compiler, translator: translator, designer: designer,
                                 coldCall: coldCall, pipeline: pipeline)

        XCTAssertTrue(pipeline.run(docId: "doc-1", language: "es"))
        try await waitUntil { translatorSession.sends == 1 }
        XCTAssertTrue(pipeline.isRunning, "the premise: a translator leg is parked")

        let cold = Task { await coldCall.call(message: "read", preamble: nil, model: "m") }
        try await waitUntil { coldSession.sends == 1 }

        compiler.runRequested(docId: "doc-1", kind: .check)
        try await waitUntil { compilerSession.sends == 1 }
        designer.runDesign()
        try await waitUntil { designerSession.sends == 1 }

        return Parked(world: world, roster: roster, translatorSession: translatorSession,
                      coldSession: coldSession, compilerSession: compilerSession,
                      designerSession: designerSession, coldCallResult: cold)
    }

    private func waitUntil(_ predicate: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
        throw CancellationError()
    }

    /// Let the parked work end. A session the roster failed to end is ended
    /// here, so a missing teardown fails on its assertion rather than hanging
    /// the test on a turn nobody will ever release.
    private func finish(_ parked: Parked) async {
        if parked.coldSession.pipelineRunningAtShutdown.isEmpty { parked.roster.coldCall.shutdown() }
        if parked.translatorSession.pipelineRunningAtShutdown.isEmpty {
            parked.roster.translator.shutdown()
        }
        if parked.compilerSession.pipelineRunningAtShutdown.isEmpty {
            parked.roster.compiler.shutdown()
        }
        if parked.designerSession.pipelineRunningAtShutdown.isEmpty {
            parked.roster.designer.shutdown()
        }
        _ = await parked.coldCallResult.value
        await TranslationPipelineTests.settle(parked.world)
    }

    // MARK: - The order

    func test_shutdownAllEndsThePipelineBeforeTheTranslator() async throws {
        let parked = try await parkedRoster()

        parked.roster.shutdownAll()

        XCTAssertEqual(parked.translatorSession.pipelineRunningAtShutdown, [false],
                       "the translator's session was ended while the pipeline still had a "
                       + "leg parked on it — the pipeline must go first")
        for (name, spy) in parked.sessions {
            XCTAssertEqual(spy.pipelineRunningAtShutdown, [false],
                           "\(name)'s session must be ended exactly once, after the pipeline — "
                           + "a session shutdownAll misses is a live, billing process")
        }
        await finish(parked)
    }

    func test_detachAllFollowsTheSameOrderAndUnwiresEveryService() async throws {
        let parked = try await parkedRoster()

        parked.roster.detachAll()

        XCTAssertEqual(parked.translatorSession.pipelineRunningAtShutdown, [false],
                       "detach shuts down first, and the pipeline still goes first")
        for (name, spy) in parked.sessions {
            XCTAssertEqual(spy.pipelineRunningAtShutdown, [false],
                           "\(name)'s session must be ended by detachAll, after the pipeline")
        }
        await finish(parked)

        XCTAssertNil(parked.roster.translator.configuredModel, "the translator is unwired")
        XCTAssertNil(parked.roster.pipeline.configuredModel, "the pipeline is unwired")
        XCTAssertNil(parked.roster.compiler.configuredModel, "the compiler is unwired")
        XCTAssertNil(parked.roster.designer.configuredModel, "the designer is unwired")
        let refused = await parked.roster.coldCall.call(message: "x", preamble: nil, model: "m")
        XCTAssertEqual(refused, .failed(.sessionDied(detail: ColdCall.notWiredDetail)),
                       "the cold-call runner forgot the window's factory")
    }

    // MARK: - The model fan-out

    func test_updateModelReachesEveryServiceThatSpawnsASession() throws {
        let roster = AgentRoster()
        let configURL = TestTemp.root.appendingPathComponent("mcp.json")
        let noRunner: @MainActor (URL, String) -> CompilerRunner = { _, _ in
            fatalError("this test spawns nothing")
        }

        roster.compiler.configure(
            environment: CompilerOrchestrator.Environment(
                projectId: "p-1",
                model: "before",
                prepareForRun: { _ in },
                reading: { _ in nil },
                liveParagraphText: { _, _ in nil },
                intent: { _ in nil },
                cachedWorld: { _ in nil },
                deriveWorld: { _, _ in nil },
                bibleSlice: { _ in [] },
                annotationContext: { _ in [] },
                mintAnnotations: { _, _ in .nothing },
                recordFacts: { _ in },
                pinnedListing: { _ in [] },
                paletteListing: { [] },
                writeMCPConfig: { configURL },
                makeRunner: noRunner,
                onRunAcknowledged: { _ in }),
            diagnostics: DiagnosticsStore(
                projectRoot: TestTemp.root, device: DeviceSlug.make(from: "test-mac")))
        roster.translator.configure(environment: TranslatorOrchestrator.Environment(
            projectId: "p-1",
            model: "before",
            briefRound: { _, _ in nil },
            briefFix: { _, _, _, _ in nil },
            translatorIdentity: { _ in ("Elena Ruiz", "role-es") },
            writeMCPConfig: { configURL },
            makeRunner: noRunner,
            ingest: { _, _ in .init(entriesWritten: 0, queriesMinted: 0) },
            onRunEnded: { _ in }))
        roster.designer.configure(environment: DesignerOrchestrator.Environment(
            projectId: "p-1",
            model: "before",
            briefRound: { _, _ in nil },
            writeMCPConfig: { configURL },
            makeRunner: noRunner,
            stage: { _, _ in .init() },
            onRunEnded: { _ in }))
        var pipelineEnvironment = FakeWorld().environment()
        pipelineEnvironment.model = "before"
        roster.pipeline.configure(environment: pipelineEnvironment)

        roster.updateModel(.deep)

        let deep = CompilerModelChoice.deep.claudeModel
        XCTAssertEqual(roster.compiler.configuredModel, deep)
        XCTAssertEqual(roster.translator.configuredModel, deep)
        XCTAssertEqual(roster.designer.configuredModel, deep)
        XCTAssertEqual(roster.pipeline.configuredModel, deep,
                       "the pipeline's cold legs spawn their own readers on this model")
    }
}
