import Foundation
import Observation

/// **The window's `claude` services, owned in one place, torn down in one
/// order** (foundations plan 3, Task 1).
///
/// Each of the five services below either owns a warm `claude` session or
/// sequences one, and every one of them inherits `ClaudeCLISession`'s sharp
/// edge: its `deinit` is nonisolated and cannot reap its own child, so a
/// service merely released is a live, billing process outliving the window
/// that started it (`Maugham/Compiler/AREA.md`, the shutdown contract). Before
/// this type, every window-ending path spelled the five teardowns out by name
/// — three places, each a list a sixth service had to be remembered into.
/// Now there is one list, here, and `TranslatorEnvironmentTests`' census
/// checks that every production class holding a session runner is a member
/// of it.
///
/// **The pipeline goes FIRST, on both verbs.** `TranslationPipeline` owns no
/// session but owns the LEG that waits — a round parked on a continuation the
/// translator's own summary resumes. The orchestrators emit no summary for a
/// turn cut short, so the pipeline's `shutdown()` has to resume that leg as
/// abandoned (and bump the generation that makes it answer cancelled) before
/// the translator it is waiting on stops existing.
///
/// `translationRuns` holds no session — it is the record finished rounds
/// leave for the desk — and is here because it is wired with the services
/// (`onRunEnded`) and lives exactly as long as they do.
@MainActor @Observable
final class AgentRoster {
    let compiler: CompilerOrchestrator
    let translator: TranslatorOrchestrator
    let designer: DesignerOrchestrator
    let coldCall: ColdCall
    let pipeline: TranslationPipeline
    let translationRuns: TranslationRunLog

    /// Each argument is a seam for a test; production passes none. The
    /// defaults are `nil` rather than `.init()` because a default argument is
    /// evaluated outside the main actor, where these initialisers cannot run.
    init(compiler: CompilerOrchestrator? = nil,
         translator: TranslatorOrchestrator? = nil,
         designer: DesignerOrchestrator? = nil,
         coldCall: ColdCall? = nil,
         pipeline: TranslationPipeline? = nil,
         translationRuns: TranslationRunLog? = nil) {
        self.compiler = compiler ?? CompilerOrchestrator()
        self.translator = translator ?? TranslatorOrchestrator()
        self.designer = designer ?? DesignerOrchestrator()
        self.coldCall = coldCall ?? ColdCall()
        self.pipeline = pipeline ?? TranslationPipeline()
        self.translationRuns = translationRuns ?? TranslationRunLog()
    }

    /// Ends every warm session, pipeline first (a parked leg is resolved
    /// before its translator goes). App quit and the AI toggle going off —
    /// the paths after which a writer may turn Claude back on in the same
    /// window, so nothing is unwired.
    func shutdownAll() {
        pipeline.shutdown()
        compiler.shutdown()
        translator.shutdown()
        designer.shutdown()
        coldCall.shutdown()
    }

    /// Detaches every service from its project environment, pipeline first.
    /// The window closing: each `detach()` shuts down first and then drops
    /// the closures over the project's stores, so neither a subprocess nor
    /// the project graph outlives the window.
    func detachAll() {
        pipeline.detach()
        compiler.detach()
        translator.detach()
        designer.detach()
        coldCall.detach()
    }

    /// The depth-menu change: every service that spawns a session gets the
    /// new model. Lazily retired by each, so a change made mid-round never
    /// kills the round in flight. `ColdCall` is absent on purpose: it takes
    /// the model per call, from the pipeline's own environment.
    func updateModel(_ model: CompilerModelChoice) {
        let claudeModel = model.claudeModel
        compiler.updateModel(claudeModel)
        // The translator and the designer run on the compiler's model —
        // one setting, three spawners.
        translator.updateModel(claudeModel)
        designer.updateModel(claudeModel)
        // …and the pipeline, whose cold legs spawn their own readers on it
        // rather than through either orchestrator above.
        pipeline.updateModel(claudeModel)
    }
}
