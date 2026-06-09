import Foundation

// MARK: - Errors

public enum RepublishError: Error, LocalizedError {
    /// The snapshot's `PublishConfig` failed validation (e.g. traversal in
    /// `outputs.directory` or `filenameTemplate`). Fail loudly rather than
    /// writing output files outside the allowed roots (finding 1.5).
    case invalidSnapshotConfig(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotConfig(let msg): return msg
        }
    }
}

public struct Republisher {

    public typealias Outcome = CompileOrchestrator.Outcome

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        publicationStore: PublicationStore,
        snapshotStore: PublicationSnapshotStore,
        jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.publicationStore = publicationStore
        self.snapshotStore = snapshotStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func republish(
        snapshotID: String,
        format: PublishConfig.Format,
        label: String?
    ) async throws -> Outcome {
        let snap = try snapshotStore.load(id: snapshotID)

        // Traversal guard (finding 1.5): the snapshot's config is validated
        // here before it reaches PDFCompiler/EPUBCompiler, where
        // `outputs.directory` is appended to `projectURL` to form the output
        // path. A crafted `"../../outside"` would escape the project root.
        // `republish` trusts the snapshot, so we must re-check it rather than
        // relying only on `set_publish_config`'s write-time validation.
        let configErrors = PublishConfigValidator.validate(snap.config)
        if !configErrors.isEmpty {
            throw RepublishError.invalidSnapshotConfig(
                "Snapshot config failed validation: " +
                configErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; "))
        }

        // Stage the snapshot's publish files to a temp project-shaped tree.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("Republish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try PublicationSnapshotStore.extract(
            snap, into: stage.appendingPathComponent(".maugham/publish",
                                                     isDirectory: true))

        // Find the prior publication so we can fill `republishedFrom`.
        let pubs = try await publicationStore.load()
        let priorVersion = pubs.first(where: { $0.snapshotID == snapshotID })?.version

        let jobID = await jobManager.register(phase: .renderingBody)

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: stage, astSource: astSource,
                config: snap.config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID)
            let r = try await pdf.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = r.logExcerpt
        case .epub:
            let e = EPUBCompiler(
                projectURL: stage, astSource: astSource,
                config: snap.config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID)
            let r = try await e.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = ""
        }

        if !errors.isEmpty || outputPath.isEmpty {
            await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
            return .failed(errors: errors, logExcerpt: logExcerpt)
        }

        // Move output from stage to real project's Exports/.
        let stageOutputURL = URL(fileURLWithPath: outputPath)
        let exports = projectURL.appendingPathComponent(
            snap.config.outputs.directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(stageOutputURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: stageOutputURL, to: dest)

        // Re-persist snapshot (idempotent — the file already exists).
        try snapshotStore.save(snap)

        // Append a Publication referencing the source snapshot.
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let newVersion = priorVersion.map { "\($0)-r\(suffix)" }
            ?? "republish-\(suffix)"
        let pub = Publication(
            publicationID: "pub-" + String(UUID().uuidString.lowercased().prefix(12)),
            version: newVersion,
            label: label,
            format: format,
            outputPath: relativePath(dest.path, from: projectURL),
            snapshotID: snap.snapshotID,
            checkpointID: "",
            republishedFrom: priorVersion,
            compiledAt: Date(),
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)
        try await publicationStore.append(pub)

        await jobManager.complete(jobID: jobID, outputPath: dest.path,
                                  warnings: warnings, errors: errors)
        return .completed(pub, warnings: warnings)
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
