import Foundation

public struct CompileJob: Sendable {
    public let jobID: String
    public let startedAt: Date
    public var status: Status

    public enum Phase: String, Codable, Sendable {
        case fetchingPackages = "fetching_packages"
        case renderingBody    = "rendering_body"
        case compiling
        case writingOutput    = "writing_output"
    }

    public enum Status: Sendable, Equatable {
        case inProgress(phase: Phase)
        case completed(outputPath: String,
                       warnings: [TectonicLogParser.Diagnostic],
                       errors: [TectonicLogParser.Diagnostic])
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
        case cancelled
        /// F2 `dry_run`: gates passed, nothing compiled — a distinct terminal
        /// state so a polled `compile_status` reports `dry_run_passed` (with
        /// the gate warnings) instead of degrading to a completed-with-empty-
        /// output shape.
        case dryRunPassed(warnings: [TectonicLogParser.Diagnostic])

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .dryRunPassed: return true
            case .inProgress: return false
            }
        }
    }

    public init(jobID: String, startedAt: Date, status: Status) {
        self.jobID = jobID
        self.startedAt = startedAt
        self.status = status
    }
}
