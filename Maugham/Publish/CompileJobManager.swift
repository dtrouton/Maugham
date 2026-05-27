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

    public func updatePhase(jobID: String, phase: CompileJob.Phase) {
        guard var job = jobs[jobID] else { return }
        job.status = .inProgress(phase: phase)
        jobs[jobID] = job
    }

    public func complete(
        jobID: String, outputPath: String,
        warnings: [TectonicLogParser.Diagnostic],
        errors: [TectonicLogParser.Diagnostic]
    ) {
        guard var job = jobs[jobID] else { return }
        job.status = .completed(
            outputPath: outputPath, warnings: warnings, errors: errors)
        jobs[jobID] = job
    }

    public func fail(
        jobID: String,
        errors: [TectonicLogParser.Diagnostic],
        logExcerpt: String
    ) {
        guard var job = jobs[jobID] else { return }
        job.status = .failed(errors: errors, logExcerpt: logExcerpt)
        jobs[jobID] = job
    }

    @discardableResult
    public func cancel(jobID: String) -> CancelResult {
        guard var job = jobs[jobID] else { return .notFound }
        switch job.status {
        case .completed:    return .alreadyCompleted
        case .failed:       return .alreadyFailed
        case .cancelled:    return .cancelled
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
