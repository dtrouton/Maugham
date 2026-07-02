import Foundation
import MaughamCore

public struct CompileOrchestrator {

    public enum Outcome: Sendable {
        case completed(Publication, warnings: [TectonicLogParser.Diagnostic])
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

        // D3c: pre-compile collision guard. `PublishStarter.install` (D3a)
        // reconciles `next_version` past existing publications, but a writer
        // can still manually set it backward via set_publish_config. Refuse
        // to compile into an already-used version so we don't mint two
        // publications at the same version string — they'd be unaddressable
        // apart via the `version` query (publication_id query works, but the
        // collision is still a bug we should surface explicitly).
        let existingPublications = try await publicationStore.load()
        if existingPublications.contains(where: { $0.version == config.nextVersion }) {
            let next = PublishConfigValidator.bumpedNextVersion(
                from: config.nextVersion)
            let diag = TectonicLogParser.Diagnostic(
                level: .error,
                file: nil, line: nil,
                message: "Publication v\(config.nextVersion) already exists; refusing to compile a colliding version.",
                contextLines: [
                    "config.next_version is '\(config.nextVersion)', which matches an existing Publication.",
                    "Bump next_version to '\(next)' (or higher) via set_publish_config, then retry.",
                    "Or use republish if you want a new compile from a prior snapshot."
                ])
            await jobManager.fail(
                jobID: jobID,
                errors: [diag],
                logExcerpt: "version_collision: \(config.nextVersion)")
            return .failed(
                errors: [diag],
                logExcerpt: "version_collision: \(config.nextVersion)")
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
        // TODO: transactional commit. If `configStore.save` throws after
        // `publicationStore.append` succeeds, the next compile reuses the same
        // version → two Publications at the same version. Swapping order moves
        // the failure mode to "version burned, no Publication" (visible gap).
        // Both shapes are non-corrupting but confusing; a real fix needs a
        // two-phase commit or a "pending publication" record promoted on
        // success of both writes.
        try await publicationStore.append(pub)

        // Notify in-app surfaces (e.g. ExportsListView) that a new publication
        // landed so they can refresh. Project-scoped at the post (ADR 0021):
        // the helper filters to windows on this project (and drops closed
        // ones); receivers no longer hand-filter.
        MaughamEvent.post(
            .maughamPublicationCompleted,
            to: .project(for: projectURL),
            object: pub.publicationID)

        // Bump version in config.
        var nextConfig = config
        nextConfig.nextVersion = PublishConfigValidator.bumpedNextVersion(
            from: config.nextVersion)
        try await configStore.save(nextConfig)

        await jobManager.complete(
            jobID: jobID, outputPath: outputPath,
            warnings: warnings, errors: errors)
        return .completed(pub, warnings: warnings)
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
