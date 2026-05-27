import Foundation

public struct CompileOrchestrator {

    public enum Outcome: Sendable {
        case completed(Publication)
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let configStore: PublishConfigStore
    public let publicationStore: PublicationStore
    public let snapshotStore: PublicationSnapshotStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore,
        publicationStore: PublicationStore,
        snapshotStore: PublicationSnapshotStore,
        jobManager: CompileJobManager,
        maughamVersion: String,
        tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.publicationStore = publicationStore
        self.snapshotStore = snapshotStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func compile(format: PublishConfig.Format, label: String?) async throws -> Outcome {
        let jobID = await jobManager.register(phase: .renderingBody)

        guard let config = try await configStore.load() else {
            await jobManager.fail(jobID: jobID, errors: [], logExcerpt: "no config")
            return .failed(errors: [], logExcerpt: "no config")
        }

        // Capture snapshot BEFORE compile so it reflects the source state used.
        let snap = try snapshotStore.capture(
            config: config, maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, astSource: astSource,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID)
            let result = try await pdf.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = result.logExcerpt

        case .epub:
            let epub = EPUBCompiler(
                projectURL: projectURL, astSource: astSource,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID)
            let result = try await epub.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = ""
        }

        if !errors.isEmpty || outputPath.isEmpty {
            await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
            return .failed(errors: errors, logExcerpt: logExcerpt)
        }

        // Persist snapshot.
        try snapshotStore.save(snap)

        // Build Publication record.
        let pubIDSuffix = String(UUID().uuidString.lowercased().prefix(12))
        let pub = Publication(
            publicationID: "pub-\(pubIDSuffix)",
            version: config.nextVersion,
            label: label,
            format: format,
            outputPath: relativePath(outputPath, from: projectURL),
            snapshotID: snap.snapshotID,
            checkpointID: "",      // CheckpointStore integration is a follow-up
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)
        try await publicationStore.append(pub)

        // Bump version in config.
        var nextConfig = config
        nextConfig.nextVersion = PublishConfigValidator.bumpedNextVersion(
            from: config.nextVersion)
        try await configStore.save(nextConfig)

        await jobManager.complete(
            jobID: jobID, outputPath: outputPath,
            warnings: warnings, errors: errors)
        return .completed(pub)
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
