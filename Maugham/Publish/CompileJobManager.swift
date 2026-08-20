import Foundation

public actor CompileJobManager {

    public enum CancelResult: Equatable, Sendable {
        case cancelled
        case alreadyCompleted
        case alreadyFailed
        case notFound
    }

    private var jobs: [String: CompileJob] = [:]
    private var cancellationTokens: [String: Bool] = [:]

    public init() {}

    @discardableResult
    public func register(
        phase: CompileJob.Phase,
        startedAt: Date = Date()
    ) -> String {
        let id = "job-" + String(UUID().uuidString.lowercased().prefix(12))
        jobs[id] = CompileJob(
            jobID: id, startedAt: startedAt,
            status: .inProgress(phase: phase))
        cancellationTokens[id] = false
        return id
    }

    public func get(jobID: String) -> CompileJob? {
        jobs[jobID]
    }

    /// All jobs currently in `.inProgress`, oldest first. Used by
    /// `CompileTool` to hand back a `job_id` when `wait_seconds` elapses
    /// before the orchestrator completes.
    public func allInProgress() -> [CompileJob] {
        jobs.values
            .filter { if case .inProgress = $0.status { return true }; return false }
            .sorted(by: { $0.startedAt < $1.startedAt })
    }

    /// Every job this manager holds, oldest first — `allInProgress()`'s
    /// unfiltered sibling. It exists because a caller that never learns a job's
    /// id can otherwise only ask whether the job is still running, and "not
    /// running" cannot tell a `.failed` job from one that was never registered:
    /// `PreviewCompilerTests` pins a thrown preview ending `.failed`, and
    /// `preview` hands its job id back to nobody.
    public func all() -> [CompileJob] {
        jobs.values.sorted(by: { $0.startedAt < $1.startedAt })
    }

    public func updatePhase(jobID: String, phase: CompileJob.Phase) {
        // A terminal job is never resurrected to `.inProgress` — without this
        // the compilers' phase updates overwrote `.cancelled` back to
        // in-progress the moment the writer's cancel landed between phases
        // (RULING-22, M7-PB-009's companion hole).
        guard var job = jobs[jobID], !job.status.isTerminal else { return }
        job.status = .inProgress(phase: phase)
        jobs[jobID] = job
    }

    /// RULING-22 (M7-PB-009): `.cancelled` is the writer's own instruction and
    /// it STANDS — a compile that finishes anyway must not overwrite it, or
    /// the record of what the writer asked for is erased by the thing they
    /// asked to stop. Every terminal writer below runs through this guard.
    private func isCancelledRecord(_ jobID: String) -> Bool {
        if case .cancelled = jobs[jobID]?.status { return true }
        return false
    }

    public func complete(
        jobID: String, outputPath: String,
        warnings: [TectonicLogParser.Diagnostic],
        errors: [TectonicLogParser.Diagnostic]
    ) {
        guard var job = jobs[jobID], !isCancelledRecord(jobID) else { return }
        job.status = .completed(
            outputPath: outputPath, warnings: warnings, errors: errors)
        jobs[jobID] = job
    }

    /// F2: terminal state for a `dry_run` compile — gates passed, nothing
    /// compiled. Kept distinct from `complete` so `compile_status` can report
    /// `dry_run_passed` rather than a completed job with an empty output path.
    public func completeDryRun(
        jobID: String, warnings: [TectonicLogParser.Diagnostic]
    ) {
        guard var job = jobs[jobID], !isCancelledRecord(jobID) else { return }
        job.status = .dryRunPassed(warnings: warnings)
        jobs[jobID] = job
    }

    public func fail(
        jobID: String,
        errors: [TectonicLogParser.Diagnostic],
        logExcerpt: String
    ) {
        guard var job = jobs[jobID], !isCancelledRecord(jobID) else { return }
        job.status = .failed(errors: errors, logExcerpt: logExcerpt)
        jobs[jobID] = job
    }

    @discardableResult
    public func cancel(jobID: String) -> CancelResult {
        guard var job = jobs[jobID] else { return .notFound }
        switch job.status {
        case .completed:     return .alreadyCompleted
        case .dryRunPassed:  return .alreadyCompleted
        case .failed:        return .alreadyFailed
        case .cancelled:     return .cancelled
        case .inProgress:
            job.status = .cancelled
            jobs[jobID] = job
            cancellationTokens[jobID] = true
            return .cancelled
        }
    }

    /// Compilers poll this between phases to honor cancellation.
    public func isCancelled(jobID: String) -> Bool {
        cancellationTokens[jobID] == true
    }

    public func gcOlderThan(seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        jobs = jobs.filter { _, job in
            if job.status.isTerminal && job.startedAt < cutoff {
                return false
            }
            return true
        }
    }
}
