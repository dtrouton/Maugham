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
/// (foundations plan 3, Tasks 2 and 3b).
///
/// Two halves with two lifetimes. `open` is the STORES: load the manifest,
/// open the `DocumentStore`, cross-link the two, build the bible and the
/// declared world, and make the (unconfigured) roster — everything a reader
/// such as the Statistics window needs, and nothing that bills. A WINDOW then
/// `attachWindow`s: its canvas model becomes the store's live canvas, its
/// flash the compiler's, and every roster service is configured.
/// `detachWindow` undoes exactly that, so the services follow the windows and
/// not whoever happens to hold the stores. `close()` is the stores' end, in
/// its one order — the roster detaches first (a no-op if no window is
/// attached; each service's environment holds closures over both stores),
/// THEN the `DocumentStore` flushes and drains.
///
/// The session builds its own `AgentRoster`, so the windows on one project
/// share its services (`ProjectSessionRegistry` decides which window is
/// attached: the newest).
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

    /// Opens the project's stores at `url` — no service is configured and no
    /// window's anything is installed; that is `attachWindow`'s. Throws what
    /// `ProjectStore.load` and `DocumentStore.open` throw; the window maps
    /// those to its load-error sentences.
    static func open(url: URL) async throws -> ProjectSession {
        let s = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        s.documentStore = ds
        // The other direction, and set here for the same reason: the
        // registry's narrowing verbs live on `DocumentStore` and the
        // manifest lives on `ProjectStore`, so the schema gate at the first
        // narrowing (P3b Task 3) has to be able to tell the live store what
        // it just wrote to disk. Weak on both sides; the session owns them.
        ds.projectStore = s

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
        return ProjectSession(url: url, projectStore: s, documentStore: ds,
                              bible: bibleStore, declaredWorld: worldStore,
                              roster: AgentRoster())
    }

    // MARK: - The window's attachment

    /// Which window the session is attached to. Opaque: a window holds the
    /// one `attachWindow` handed it and gives it back to `detachWindow`.
    struct WindowAttachment: Hashable {
        fileprivate let serial: Int
    }

    /// The window the services and the canvas seam currently answer to, or
    /// nil while no window is attached (a reader alone, or between windows).
    private(set) var attachment: WindowAttachment?
    @ObservationIgnored private var attachmentSerial = 0
    /// The attached window's flash. The compiler's `onRunAcknowledged`
    /// forwards through `flash(_:)` to whatever this is NOW, never to a
    /// closure captured from the window that happened to configure it.
    @ObservationIgnored private var flashSink: (@MainActor (CompilerOrchestrator.Acknowledgment) -> Void)?

    /// Attaches a window: its canvas model becomes the store's live canvas,
    /// its flash becomes the compiler's, and — when no window was attached —
    /// every roster service is configured with its production environment.
    /// A second window attaching over a first takes the canvas and the flash
    /// and leaves the services as they are: nothing in their environments is
    /// a window's (the flash goes through the session), so the warm sessions
    /// the first window started stay warm. The newest window wins.
    @discardableResult
    func attachWindow(
        canvas: CanvasModel,
        flash: @escaping @MainActor (CompilerOrchestrator.Acknowledgment) -> Void,
        preferences: UserPreferences
    ) -> WindowAttachment {
        attachmentSerial += 1
        let token = WindowAttachment(serial: attachmentSerial)
        let configures = attachment == nil
        attachment = token
        flashSink = flash
        // The canvas seam: the model is `@State` on the window, so nothing an
        // MCP tool is handed can reach it otherwise. Set here and never in a
        // view `body` — a store is not read from a view body or anything a
        // body calls. A window reopened on a project whose session a reader
        // kept alive is attached afresh, so ITS canvas is the live one and
        // Claude's cards never go to the sidecar behind its back.
        projectStore.liveCanvas = canvas
        guard configures else { return token }

        // Every roster service, wired to this session's stores — moved from
        // `open` (foundations plan 3, Task 3b) unchanged in order and in its
        // captures; the locals are the names it has always used.
        let url = self.url
        let s = projectStore
        let ds = documentStore
        let bibleStore = bible
        let worldStore = declaredWorld
        // The roster's members under the names the wiring below has always
        // used, so the configure calls read exactly as they did in the window.
        let compiler = roster.compiler
        let translator = roster.translator
        let translationRuns = roster.translationRuns
        let designer = roster.designer
        let coldCall = roster.coldCall
        let pipeline = roster.pipeline

        compiler.configure(
            environment: .production(
                store: s, documentStore: ds, projectURL: url,
                declaredWorld: worldStore, bible: bibleStore,
                preferences: preferences,
                model: ds.uiState.compilerModel.claudeModel,
                onRunAcknowledged: { [weak self] in self?.flash($0) }),
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
        return token
    }

    /// Detaches the window holding `token`: every roster service detaches
    /// (pipeline first — the roster's own order), and the canvas seam and the
    /// flash are cleared, so no `claude` session outlives the last window on
    /// the project even while a reader holds the stores. A stale token — a
    /// newer window attached since — does nothing.
    func detachWindow(_ token: WindowAttachment) {
        guard attachment == token else { return }
        roster.detachAll()
        projectStore.liveCanvas = nil
        flashSink = nil
        attachment = nil
    }

    /// The compiler's acknowledgment, delivered to the attached window's
    /// flash — or to nobody, while no window is attached.
    func flash(_ acknowledgment: CompilerOrchestrator.Acknowledgment) {
        flashSink?(acknowledgment)
    }

    /// What a window's `load()` does, given the session it already holds.
    enum LoadStep: Equatable {
        /// The live session is for this project: use it, open nothing.
        case reuseLive
        /// The live session is for another project: close it, THEN open.
        case closeLiveThenOpen
        /// No session yet: open.
        case open
    }

    /// The window's load decision, pure so it can be pinned without a window.
    /// Re-opening a project whose session is live would run a second
    /// `DocumentStore.open` — a second presenter, and the open-time
    /// seal/rotate sweep whose rotation deletes — under Documents the live
    /// store still has registered; and a previous session closed alongside a
    /// new open, rather than before it, races the two.
    ///
    /// Compared by `ProjectSessionRegistry.key(for:)`, never by `URL`
    /// equality: the live session's `url` is its FIRST opener's spelling, and
    /// a window that reached the same folder by another (a symlink, a
    /// trailing `/`) would otherwise read as a different project and give its
    /// borrow back only to take it again.
    static func loadStep(live: URL?, requested: URL) -> LoadStep {
        guard let live else { return .open }
        return ProjectSessionRegistry.key(for: live) == ProjectSessionRegistry.key(for: requested)
            ? .reuseLive : .closeLiveThenOpen
    }

    /// The stores' end — `ProjectSessionRegistry`'s last release of any kind
    /// — in order: every roster service detaches (pipeline first — the
    /// roster's own order; a no-op when no window is attached), THEN the
    /// `DocumentStore` flushes and drains its registry. Detaching first is
    /// the point: each service's environment holds closures over both
    /// stores, so a session left configured would keep the project graph —
    /// and its `claude` subprocess — alive past the close.
    func close() async {
        roster.detachAll()
        await documentStore.close()
    }
}
