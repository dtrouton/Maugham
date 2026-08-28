import Foundation
import Observation

/// **The desk's own compile** (imprints P3 Task 4).
///
/// Until this file there was no way to make a book from inside Maugham. The
/// only production construction of `CompileOrchestrator` was `CompileTool`'s,
/// which means every book this app has ever produced was asked for by Claude
/// over the MCP socket. The Publish desk gets the verb here.
///
/// **It is the tool's construction, line for line**, and deliberately so: the
/// same `PublishingStores.sharedFor` (so a desk compile and an MCP compile
/// contend on ONE mint gate and one job manager, rather than both passing the
/// catalog guard and both minting), the same unbound `ProjectStoreASTSource`
/// (`language: nil` — `BodyPlan` rebinds the source per body, so a tag named
/// here would be discarded and rebuilt anyway), and the same two toolchain
/// versions, which this task folded into `PublishToolchain`.
///
/// **Model, not view.** Nothing here draws; `DepartmentCompileState` holds
/// every sentence and every decision, so the surface Task 5 builds takes values
/// and holds no orchestrator.
@Observable
@MainActor
final class DeskCompileRunner {

    /// **What a press asks for.** Deliberately narrower than
    /// `CompileOrchestrator.compile`: no `label`, no `version`, no `dryRun`, no
    /// legacy singular `language`. A desk that could pin a version or burn a
    /// dry run would be a second control surface for decisions the catalog and
    /// the config already own.
    struct Request: Equatable {
        var format: PublishConfig.Format
        /// The editions to render, in order. Empty is the plain source book.
        /// A source-only compile the desk wants NAMED passes the book's own
        /// tag — `LanguageSet` substitutes it back to the source body, and the
        /// status line then says which language that is.
        var languages: [String]
        var imprint: String?
        var allowStale: Bool

        init(format: PublishConfig.Format,
             languages: [String] = [],
             imprint: String? = nil,
             allowStale: Bool = false) {
            self.format = format
            self.languages = languages
            self.imprint = imprint
            self.allowStale = allowStale
        }
    }

    private(set) var state = DepartmentCompileState()

    /// The compile in flight. It is what `start` guards on rather than
    /// `state.phase`, because a refusal replaces the phase while the run it
    /// refused carries on — guarding on the phase would let the press after a
    /// refusal start a second orchestrator.
    private var task: Task<Void, Never>?

    /// The project the last press was for, so `cancel()` can find its job
    /// manager. `nil` until the first `start`, which is why a cancel before any
    /// compile does nothing rather than crashing.
    private var stores: PublishingStores?

    /// **The id of the job THIS desk's compile registered**, and the only job
    /// its Cancel will ever touch.
    ///
    /// Not `@MainActor` state, because the orchestrator hands the id over from
    /// its own executor the moment it registers — hopping to the main actor to
    /// store it would leave a window in which the writer's Cancel finds nothing
    /// to cancel and silently does nothing. A lock is the cheapest thing that
    /// closes it.
    private let ownJob = JobIDHolder()

    /// The job the desk's compile in flight registered, or `nil` when the desk
    /// has none. `nonisolated` so a test (and `cancel`'s own detached work) can
    /// read it without a hop; the holder is what makes that safe.
    nonisolated var currentJobID: String? { ownJob.get() }

    // MARK: - Verbs

    /// **Press Compile.** Returns immediately; the state carries the rest.
    func start(_ request: Request, projectStore: ProjectStore, projectURL: URL) {
        guard task == nil else {
            // The run in flight is untouched: only the phase changes, and
            // `isRunning` is stored precisely so this cannot read as idle.
            state.phase = .refused(DepartmentCompileState.alreadyRunning)
            return
        }

        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: projectURL), projectURL: projectURL)
        self.stores = stores
        let orchestrator = CompileOrchestrator(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: projectStore,
                language: nil),
            configStore: stores.configStore,
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            mintGate: stores.mintGate,
            maughamVersion: PublishToolchain.maughamVersion,
            tectonicVersion: PublishToolchain.tectonicVersion)

        ownJob.set(nil)
        state = DepartmentCompileState(
            phase: .running(format: request.format,
                            languages: request.languages,
                            imprint: request.imprint),
            isRunning: true)

        task = Task { [weak self] in
            let settled: DepartmentCompileState
            do {
                let outcome = try await orchestrator.compile(
                    format: request.format,
                    label: nil,
                    // The legacy singular tag is never used here; `languages`
                    // is the one list. Empty means the source book, which is
                    // what `LanguageSet` reads a nil list as.
                    language: nil,
                    languages: request.languages.isEmpty ? nil : request.languages,
                    allowStale: request.allowStale,
                    dryRun: false,
                    version: nil,
                    imprint: request.imprint,
                    // The desk learns which job is its own — see `ownJob`.
                    onJobRegistered: { [ownJob] in ownJob.set($0) })
                settled = DepartmentCompileState.settled(after: outcome)
            } catch {
                // `compile` throws for the things that are not outcomes at all
                // — an unreadable config directory, a snapshot that could not
                // be written. The desk says so rather than staying blank.
                settled = DepartmentCompileState(
                    phase: .failed(error.localizedDescription), isRunning: false)
            }
            self?.finish(with: settled)
        }
    }

    /// **Stop the compile — this one, and never anybody else's.**
    ///
    /// The same verb `CompileCancelTool` performs, with the id the orchestrator
    /// handed back at registration rather than one a caller supplied.
    ///
    /// **It used to take `allInProgress().last`, and that was a real bug.** One
    /// `CompileJobManager` serves the whole project: `PreviewCompiler` (every
    /// `preview_compile` Claude runs) and the designer's `SampleCompiler`
    /// register on it too, and neither passes through the mint gate that would
    /// otherwise make "the newest in-flight job" a synonym for "this press". A
    /// writer who pressed Compile…, watched Claude run a preview, and then
    /// pressed Cancel cancelled the PREVIEW — while the book they meant to stop
    /// went on and published itself under a button whose help says nothing is
    /// published.
    ///
    /// With no job of its own it does nothing, which is the honest answer both
    /// before the first press and after a compile has settled.
    ///
    /// Cancelling sets the token the orchestrator polls at its one checkpoint,
    /// after the render and before the snapshot: nothing durable is committed
    /// and the outcome comes back `.cancelled`, which `DepartmentCompileState
    /// .settled(after:)` draws as an idle desk with a sentence rather than as a
    /// failure.
    func cancel() {
        guard let stores, let jobID = ownJob.get() else { return }
        Task { _ = await stores.jobManager.cancel(jobID: jobID) }
    }

    // MARK: -

    private func finish(with settled: DepartmentCompileState) {
        task = nil
        // The desk has no compile of its own any more, so its Cancel has
        // nothing to aim at. Left set, a press after the compile had settled
        // would ask the manager to cancel a terminal job — harmless today
        // (`CompileJobManager.cancel` answers `.alreadyCompleted`) and exactly
        // the kind of aim a later id-reuse would turn into the bug this file
        // just fixed.
        ownJob.set(nil)
        state = settled
    }
}

/// **A job id that two executors can share.** The orchestrator writes it from
/// wherever it is running; the desk reads it on the main actor, and a test
/// reads it from a runloop pump. `NSLock` rather than an actor because both
/// sides need the answer synchronously — an `await` here is the window that
/// makes a Cancel pressed a millisecond after Compile do nothing.
private final class JobIDHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        value = id
    }

    func get() -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
