import Foundation
import Observation
import MaughamCore
import os

/// Same subsystem and category as the window's own logger: these lines moved
/// here from `ProjectWindow.load()` and read exactly as they did, so a Console
/// filter on the window's category still finds them.
private let _projectSessionLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ProjectWindow")

/// **An open project's stores and `claude` services, owned outside the view**
/// (foundations plan 3, Task 2).
///
/// Everything `ProjectWindow.load()` used to do that is not UI seeding lives
/// in `open`: load the manifest, open the `DocumentStore`, cross-link the two,
/// build the bible and the declared world, and configure every roster service
/// with its production environment. `close()` is the window-ending teardown,
/// in its one order — the roster detaches first (each service's environment
/// holds closures over both stores, and a session left configured keeps its
/// `claude` subprocess and the whole project graph alive), THEN the
/// `DocumentStore` flushes and drains.
///
/// The session builds its own `AgentRoster`, so whoever shares a session
/// shares its services (Task 3 shares one session across the windows on one
/// project). The canvas model and the flash callback are the window's, and
/// are handed in.
@MainActor @Observable
final class ProjectSession {
    let url: URL
    let projectStore: ProjectStore
    let documentStore: DocumentStore
    let bible: BibleStore
    let declaredWorld: DeclaredWorldStore
    let roster: AgentRoster

    private init(url: URL, projectStore: ProjectStore, documentStore: DocumentStore,
                 bible: BibleStore, declaredWorld: DeclaredWorldStore, roster: AgentRoster) {
        self.url = url
        self.projectStore = projectStore
        self.documentStore = documentStore
        self.bible = bible
        self.declaredWorld = declaredWorld
        self.roster = roster
    }

    /// Opens the project at `url` and wires its services. Throws what
    /// `ProjectStore.load` and `DocumentStore.open` throw; the window maps
    /// those to its load-error sentences.
    static func open(
        url: URL,
        preferences: UserPreferences,
        liveCanvas: CanvasModel?,
        onCompilerFlash: @escaping @MainActor (CompilerOrchestrator.Acknowledgment) -> Void
    ) async throws -> ProjectSession {
        let roster = AgentRoster()
        // The roster's members under the names the wiring below has always
        // used, so the configure calls read exactly as they did in the window.
        let compiler = roster.compiler
        let translator = roster.translator
        let translationRuns = roster.translationRuns
        let designer = roster.designer
        let coldCall = roster.coldCall
        let pipeline = roster.pipeline

        let s = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        s.documentStore = ds
        // The other direction, and set here for the same reason: the
        // registry's narrowing verbs live on `DocumentStore` and the
        // manifest lives on `ProjectStore`, so the schema gate at the first
        // narrowing (P3b Task 3) has to be able to tell the live store what
        // it just wrote to disk. Weak on both sides; the session owns them.
        ds.projectStore = s
        // The canvas's equivalent, and set here for the same reason: the
        // model is `@State` on the window, so nothing an MCP tool is handed
        // can reach it otherwise. Set at open and never in a view `body` — a
        // store is not read from a view body or anything a body calls.
        s.liveCanvas = liveCanvas

        // The Intent pane's strata, on the same device slug and the same
        // rule as every other derived sidecar (tripwire 24 at the filename
        // point, which both stores take care of themselves).
        //
        // **Built BEFORE the compiler, because the run reads both.** The
        // declared world is what ⌘R briefs its clauses from and the bible
        // is the ledger a run slices and then feeds; a compiler configured
        // against stores that did not exist yet would be a run with no
        // clauses and facts that go nowhere, all of it silent.
        let device = DeviceIdentity.author.slug
        let bibleStore = BibleStore(projectRoot: url, device: device)
        let worldStore = DeclaredWorldStore(projectRoot: url, device: device)
        compiler.configure(
            environment: .production(
                store: s, documentStore: ds, projectURL: url,
                declaredWorld: worldStore, bible: bibleStore,
                preferences: preferences,
                model: ds.uiState.compilerModel.claudeModel,
                onRunAcknowledged: { onCompilerFlash($0) }),
            diagnostics: DiagnosticsStore(
                projectRoot: url,
                device: DeviceIdentity.author.slug))
        // The translator's loop, wired beside the compiler's and for its
        // reason. Its run verb is the department desk's Run button (P4 Task
        // 3), and what a finished round has to say goes to the window's own
        // record so that desk can report it — plus the log line, which is
        // what a session that ran while no pane was open leaves behind.
        translator.configure(
            environment: .production(
                store: s, documentStore: ds, projectURL: url,
                // The same ledger the compiler was handed a few lines up,
                // and for the run's own reason: a fact the manuscript has
                // established about a person is a grammatical choice in
                // most of the languages this loop translates into.
                bible: bibleStore,
                preferences: preferences,
                model: ds.uiState.compilerModel.claudeModel,
                // **Two listeners, and the second is load-bearing for
                // cancel** (translation pipeline P3): the pipeline's leg is
                // suspended on a continuation that ONLY this forwarding
                // resumes. `pipeline.cancel()` mid-translator-leg works by
                // calling `TranslatorOrchestrator.cancel()`, which emits a
                // `.cancelled` summary — which reaches the parked leg
                // through this line and nowhere else. Drop it and a
                // cancelled round hangs forever.
                onRunEnded: { [weak translationRuns, weak pipeline] summary in
                    translationRuns?.record(summary)
                    pipeline?.translatorRunEnded(summary)
                    _projectSessionLog.info(
                        "translation run \(summary.runId, privacy: .public) ended for \(summary.docId, privacy: .public)/\(summary.language, privacy: .public)")
                },
                // A click that turned out not to be a run — the briefing
                // answered nil — emits no summary at all, so the leg would
                // wait on a run that never started.
                onRunAbandoned: { [weak pipeline] runId in
                    pipeline?.translatorRunAbandoned(runId)
                }))
        // The designer's loop, wired beside the other two. Headless for the
        // translator's reason — a design round is started from the desk
        // (P4) — so what a finished round has to say goes to the log until
        // that desk exists to say it to. **The two things it says are the
        // round's whole product**: which proposal is now on the desk, and
        // whether its sample pages compiled. A record naming neither is one
        // nobody can follow up on.
        designer.configure(
            environment: .production(
                store: s, projectURL: url,
                preferences: preferences,
                model: ds.uiState.compilerModel.claudeModel,
                onRunEnded: { summary in
                    _projectSessionLog.info(
                        "design run \(summary.runId, privacy: .public) round \(summary.round, privacy: .public) ended: \(ProjectWindow.designRunRecord(summary), privacy: .public)")
                }))
        // The cold-call runner, wired beside the three orchestrators. It
        // holds no session between calls; what it needs is the factory
        // that builds a sealed one, and the same toggle every spawn reads.
        coldCall.configure(
            makeRunner: ColdCall.productionRunnerFactory(preferences: preferences))
        // The pipeline, sequencing the translator and the cold-call runner
        // wired just above. Owns no session; owns the leg that waits.
        pipeline.configure(environment: .production(
            store: s, documentStore: ds, projectURL: url,
            translator: translator, coldCall: coldCall,
            model: ds.uiState.compilerModel.claudeModel,
            onRoundEnded: { round in
                _projectSessionLog.info(
                    "translation round \(round.number, privacy: .public) for \(round.docId, privacy: .public)/\(round.language, privacy: .public) ended at leg \(round.legs.last?.leg.name ?? "-", privacy: .public)")
                // **How a finished round reaches the desk** (P4). The round
                // is filed to `TranslationRoundStore`, which touches
                // neither the manifest nor the annotations, and the desk's
                // `ReloadKey` carries the pipeline's LANGUAGE and not its
                // leg — so nothing else here would tell the row it has a
                // newer round to draw. `.project`-scoped, because another
                // window on another book has no stake in it.
                MaughamEvent.postTranslationRoundEnded(projectURL: url, round: round)
            }))
        return ProjectSession(url: url, projectStore: s, documentStore: ds,
                              bible: bibleStore, declaredWorld: worldStore,
                              roster: roster)
    }

    /// The window-ending teardown, in order: every roster service detaches
    /// (pipeline first — the roster's own order), THEN the `DocumentStore`
    /// flushes and drains its registry. Detaching first is the point: each
    /// service's environment holds closures over both stores, so a session
    /// left configured would keep the project graph — and its `claude`
    /// subprocess — alive past the close.
    func close() async {
        roster.detachAll()
        await documentStore.close()
    }
}
