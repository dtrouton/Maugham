import Foundation
import MaughamCore

// MARK: - shared response encoding

enum CompileResponseEncoder {
    static func encodeCompleted(
        _ pub: Publication,
        warnings: [TectonicLogParser.Diagnostic]
    ) throws -> Data {
        var obj: [String: Any] = [
            "status": "completed",
            "version": pub.version,
            "format": pub.format.rawValue,
            "output_path": pub.outputPath,
            "checkpoint_id": pub.checkpointID,
            "log_path": "build/compile.log",
            "warnings": warnings.map { encode(diag: $0) },
            "errors": []
        ]
        if let label = pub.label { obj["label"] = label }
        if let language = pub.language { obj["language"] = language }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    static func encodeFailed(
        errors: [TectonicLogParser.Diagnostic], logExcerpt: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": "failed",
            "errors": errors.map { encode(diag: $0) },
            "log_excerpt": String(logExcerpt.prefix(4000)),
            "log_path": "build/compile.log"
        ], options: [.sortedKeys])
    }

    static func encodeOutcome(_ outcome: CompileOrchestrator.Outcome) throws -> Data {
        switch outcome {
        case .completed(let pub, let warnings):
            return try encodeCompleted(pub, warnings: warnings)
        case .failed(let errors, let log):
            return try encodeFailed(errors: errors, logExcerpt: log)
        case .dryRunPassed(let warnings):
            return try JSONSerialization.data(withJSONObject: [
                "status": "dry_run_passed",
                "warnings": warnings.map { encode(diag: $0) }
            ], options: [.sortedKeys])
        }
    }

    static func inProgress(
        jobID: String, phase: CompileJob.Phase, startedAt: Date
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": "in_progress",
            "job_id": jobID,
            "phase": phase.rawValue,
            "started_at": ISO8601DateFormatter().string(from: startedAt)
        ], options: [.sortedKeys])
    }

    static func encode(diag: TectonicLogParser.Diagnostic) -> [String: Any] {
        var obj: [String: Any] = [
            "level": diag.level.rawValue,
            "message": diag.message,
            "context_lines": diag.contextLines
        ]
        if let line = diag.line { obj["line"] = line }
        if let file = diag.file { obj["file"] = file }
        return obj
    }

    /// Read the current `inProgress` phase from a job status, defaulting
    /// to `.compiling` if the status isn't actually in-progress. (Defensive
    /// — callers should only invoke this with an inProgress job.)
    static func phase(of job: CompileJob) -> CompileJob.Phase {
        if case .inProgress(let p) = job.status { return p }
        return .compiling
    }
}

// MARK: - compile

public enum CompileTool: MCPTool {
    public static let method = "compile"
    public static let description =
    "Full PDF or EPUB compile. wait_seconds blocks up to that long for completion; if it elapses, returns {status: in_progress, job_id, phase}. On success creates a Publication record referencing the captured PublicationSnapshot (template + config + styles bytes, frozen at compile time). Note: the Publication.checkpoint_id field is reserved for a follow-up milestone — it's empty in v1, and reproducibility is via snapshot_id (which republish uses)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"},"format":{"type":"string","enum":["pdf","epub"]},"label":{"type":"string"},"language":{"type":"string","description":"BCP-47-ish language tag (e.g. 'es') to compile a translated edition: applies language_overrides, sets dc:language / \\\\MaughamLanguage, and language-suffixes the output filename. Omit for the source-language edition."},"allow_stale":{"type":"boolean","default":false,"description":"Compile a translated edition even if some paragraphs are stale or missing, falling back to source text for those paragraphs (default false blocks the compile and reports the gap instead)."},"dry_run":{"type":"boolean","default":false,"description":"Run the version-collision guard and translation-coverage gate for this edition and report the verdict WITHOUT compiling: no output file, no Publication record, no version bump. Returns {status: dry_run_passed, warnings} when it would compile, or the same failed/gate-blocked shape a real compile returns. Answers 'would this edition compile pass for the currently included sections' without minting a throwaway Publication."},"wait_seconds":{"type":"integer","default":60}},"required":["project_id","format"]}
    """

    struct Params: Codable {
        let projectID: String
        let format: PublishConfig.Format
        let label: String?
        let language: String?
        let allowStale: Bool?
        let dryRun: Bool?
        let waitSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case format, label, language
            case allowStale = "allow_stale"
            case dryRun = "dry_run"
            case waitSeconds = "wait_seconds"
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        if let language = params.language,
           !TranslationRecord.isValidLanguageTag(language) {
            throw MCPError.invalidArgument("invalid language tag: \(language)")
        }
        let entry = try resolveProject(params.projectID, in: registry)
        let store = entry.store
        let projectURL = entry.url
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: projectURL)
        let astSource = ProjectStoreASTSource(
            projectStore: store,
            language: params.language,
            allowStale: params.allowStale ?? false)
        let orch = CompileOrchestrator(
            projectURL: projectURL,
            astSource: astSource,
            configStore: stores.configStore,
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0")

        let wait = TimeInterval(params.waitSeconds ?? 60)
        let format = params.format
        let label = params.label
        let language = params.language
        let allowStale = params.allowStale ?? false
        let dryRun = params.dryRun ?? false
        let task = Task {
            try await orch.compile(
                format: format, label: label,
                language: language, allowStale: allowStale, dryRun: dryRun)
        }
        do {
            let outcome = try await withTimeout(seconds: wait) { try await task.value }
            return try CompileResponseEncoder.encodeOutcome(outcome)
        } catch is TimeoutError {
            // Defer to job_id polling. The compile keeps running.
            // Give the orchestrator's first await a chance to register
            // its job before we look for it — without this sleep, a
            // wait_seconds=0 call may race the orchestrator's `register`
            // and see an empty inProgress list.
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let jobs = await stores.jobManager.allInProgress()
            if let job = jobs.last {
                return try CompileResponseEncoder.inProgress(
                    jobID: job.jobID,
                    phase: CompileResponseEncoder.phase(of: job),
                    startedAt: job.startedAt)
            }
            // The compile may have already finished between timeout and
            // the inProgress lookup (fast compiles + small wait_seconds).
            // Await its outcome rather than fabricating an in_progress
            // for a job that no longer exists.
            let outcome = try await task.value
            return try CompileResponseEncoder.encodeOutcome(outcome)
        }
    }
}

// MARK: - preview_compile

public enum PreviewCompileTool: MCPTool {
    public static let method = "preview_compile"
    public static let description =
    "Fast subset compile. section_ids = list of piece IDs to include (omit for whole project). language/allow_stale mirror compile: preview a translated edition (applies language_overrides + language-suffixed templates) behind the SAME coverage gate — the gate scopes to exactly the pieces this preview renders, so an exploratory preview of one section isn't blocked by other untranslated pieces. Does NOT create a Publication or bump version."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"},"format":{"type":"string","enum":["pdf","epub"]},"section_ids":{"type":"array","items":{"type":"string"}},"language":{"type":"string","description":"BCP-47-ish language tag (e.g. 'es') to preview a translated edition, applying language_overrides + language-suffixed templates and running the same coverage gate as compile. Omit for the source-language preview."},"allow_stale":{"type":"boolean","default":false,"description":"Preview a translated edition even if some paragraphs are stale or missing, falling back to source text (default false blocks and reports the gap, exactly like compile)."},"max_pages":{"type":"integer"},"wait_seconds":{"type":"integer","default":30}},"required":["project_id","format"]}
    """

    struct Params: Codable {
        let projectID: String
        let format: PublishConfig.Format
        let sectionIDs: [String]?
        let language: String?
        let allowStale: Bool?
        let maxPages: Int?
        let waitSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case format
            case sectionIDs = "section_ids"
            case language
            case allowStale = "allow_stale"
            case maxPages = "max_pages"
            case waitSeconds = "wait_seconds"
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        if let language = params.language,
           !TranslationRecord.isValidLanguageTag(language) {
            throw MCPError.invalidArgument("invalid language tag: \(language)")
        }
        let entry = try resolveProject(params.projectID, in: registry)
        let store = entry.store
        let projectURL = entry.url
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: projectURL)
        let preview = PreviewCompiler(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: store,
                language: params.language,
                allowStale: params.allowStale ?? false),
            configStore: stores.configStore,
            jobManager: stores.jobManager,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0",
            language: params.language,
            allowStale: params.allowStale ?? false)
        let result = try await preview.preview(
            format: params.format,
            sectionIDs: params.sectionIDs,
            maxPages: params.maxPages)
        if !result.errors.isEmpty {
            // Gate-block / compile-error parity with compile's `.failed` shape.
            return try CompileResponseEncoder.encodeFailed(
                errors: result.errors, logExcerpt: result.logExcerpt)
        }
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "format": params.format.rawValue,
            "output_path": result.outputPath,
            "warnings": result.warnings.map { CompileResponseEncoder.encode(diag: $0) },
            "errors": []
        ], options: [.sortedKeys])
    }
}

// MARK: - compile_status

public enum CompileStatusTool: MCPTool {
    public static let method = "compile_status"
    public static let description =
    "Poll a compile job's status. Returns the same shape as compile()."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"},"job_id":{"type":"string"}},"required":["project_id","job_id"]}
    """

    struct Params: Codable {
        let projectID: String
        let jobID: String
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case jobID = "job_id"
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: entry.url)
        guard let job = await stores.jobManager.get(jobID: params.jobID) else {
            return try JSONSerialization.data(withJSONObject: [
                "status": "not_found"
            ], options: [.sortedKeys])
        }
        switch job.status {
        case .inProgress(let phase):
            return try CompileResponseEncoder.inProgress(
                jobID: job.jobID, phase: phase, startedAt: job.startedAt)
        case .completed(let path, let warnings, let errors):
            return try JSONSerialization.data(withJSONObject: [
                "status": "completed",
                "output_path": path,
                "log_path": "build/compile.log",
                "warnings": warnings.map { CompileResponseEncoder.encode(diag: $0) },
                "errors": errors.map { CompileResponseEncoder.encode(diag: $0) }
            ], options: [.sortedKeys])
        case .failed(let errors, let log):
            return try CompileResponseEncoder.encodeFailed(
                errors: errors, logExcerpt: log)
        case .cancelled:
            return try JSONSerialization.data(withJSONObject: [
                "status": "cancelled"
            ], options: [.sortedKeys])
        case .dryRunPassed(let warnings):
            // F2: a polled dry_run job reports its actual outcome — the same
            // shape the synchronous compile(dry_run:true) response carries.
            return try JSONSerialization.data(withJSONObject: [
                "status": "dry_run_passed",
                "warnings": warnings.map { CompileResponseEncoder.encode(diag: $0) }
            ], options: [.sortedKeys])
        }
    }
}

// MARK: - compile_cancel

public enum CompileCancelTool: MCPTool {
    public static let method = "compile_cancel"
    public static let description =
    "Cancel an in-flight compile."
    public static let inputSchemaJSON = CompileStatusTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(CompileStatusTool.Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: entry.url)
        let result = await stores.jobManager.cancel(jobID: params.jobID)
        let statusString: String
        switch result {
        case .cancelled:        statusString = "cancelled"
        case .alreadyCompleted: statusString = "already_completed"
        case .alreadyFailed:    statusString = "already_failed"
        case .notFound:         statusString = "not_found"
        }
        return try JSONSerialization.data(
            withJSONObject: ["status": statusString], options: [.sortedKeys])
    }
}

// MARK: - timeout helper

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        if seconds > 0 {
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
        } else {
            group.addTask {
                throw TimeoutError()
            }
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
