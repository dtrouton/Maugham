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
                    imprint: request.imprint)
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

    /// **Stop the compile.**
    ///
    /// The same verb `CompileCancelTool` performs, minus the id: an MCP caller
    /// is handed a `job_id` and gives it back, and the desk has no id to give,
    /// so it asks the job manager which job is in flight. The NEWEST one, as
    /// `CompileTool` reads the same list when its wait elapses — a desk compile
    /// and an MCP compile of the same project cannot both be minting anyway
    /// (`PublishMintGate` refuses the second), so the in-flight list is
    /// effectively this one press.
    ///
    /// Cancelling sets the token the orchestrator polls at its one checkpoint,
    /// after the render and before the snapshot: nothing durable is committed
    /// and the outcome comes back `.cancelled`, which `DepartmentCompileState
    /// .settled(after:)` draws as an idle desk with a sentence rather than as a
    /// failure.
    func cancel() {
        guard let stores else { return }
        Task {
            guard let job = await stores.jobManager.allInProgress().last else { return }
            _ = await stores.jobManager.cancel(jobID: job.jobID)
        }
    }

    // MARK: -

    private func finish(with settled: DepartmentCompileState) {
        task = nil
        state = settled
    }
}
