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

    public func compile(
        format: PublishConfig.Format,
        label: String?,
        language: String? = nil,
        allowStale: Bool = false
    ) async throws -> Outcome {
        let jobID = await jobManager.register(phase: .renderingBody)

        guard let config = try await configStore.load() else {
            await jobManager.fail(jobID: jobID, errors: [], logExcerpt: "no config")
            return .failed(errors: [], logExcerpt: "no config")
        }

        // The edition-effective config: base config with its metadata folded
        // to the language edition (dc:language set + language_overrides applied).
        // `language == nil` leaves metadata untouched (single-language compile).
        // Everything downstream — snapshot, compilers, filename, Publication —
        // reads `effective`, so the snapshot freezes config/templates for
        // `Republisher` (which reads snap.config). It does NOT freeze
        // manuscript/translation content — `astSource` still reads the live
        // ProjectStore on republish, so a translated edition is re-gated
        // separately in `Republisher.republish` (Task 9 F1), not here.
        // The post-compile version bump below saves the ORIGINAL `config`, never
        // `effective`, so a translated compile can't overwrite the shared config.
        var effective = config
        effective.metadata = config.effectiveMetadata(language: language)

        // Task 10: resolve language-suffixed per-piece style files on the
        // EFFECTIVE config before snapshot + emit. The emitter has no
        // filesystem access, so existence-based resolution happens here. Only
        // `effective` is rewritten — snapshot/compilers read it — while the
        // shared config saved below stays on the base names. `language == nil`
        // is a no-op. Republish stays consistent: the snapshot captures the
        // whole publish tree (including any `.es.tex` piece files), and it
        // freezes `effective`, so the frozen config's suffixed names match the
        // frozen tree.
        let publishDir = projectURL.appendingPathComponent(
            ".maugham/publish", isDirectory: true)
        effective = LanguageSuffixedFile.resolvingStyleFiles(
            in: effective, language: language, publishDir: publishDir)

        // F1: compute the excluded set from the EFFECTIVE config (after the
        // language fold above, so a language edition can't diverge the subset),
        // then wrap the live source so the emitters — and every downstream
        // record derived from them — see only the included pieces. An empty
        // excluded set is a pass-through.
        let excludedSectionIDs = effective.excludedSectionIDs
        let emitSource = IncludeFilteredASTSource(
            base: astSource, excludedSectionIDs: excludedSectionIDs)

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

        // Task 9: translation coverage gate. A translated edition
        // (`language != nil`) must not ship a book whose translation lags the
        // source. Reuse the astSource's own `ProjectStore` (the same one the
        // substitution path reads) to walk pieces, derive each, and hand the
        // report to `TranslationCoverage.applyGate` — the ONE place either
        // `compile` or `republish` decides block-vs-warn (Task 9 F1 round 5;
        // this used to be reimplemented in `Republisher.republish`, which let
        // the two drift apart).
        var gateWarnings: [TectonicLogParser.Diagnostic] = []
        if let language, let source = astSource as? ProjectStoreASTSource {
            let report = await TranslationCoverage.check(
                projectStore: source.projectStore, language: language,
                excludedSectionIDs: excludedSectionIDs)
            switch TranslationCoverage.applyGate(
                report: report, language: language, allowStale: allowStale
            ) {
            case .blocked(let errors, let logExcerpt):
                await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
                return .failed(errors: errors, logExcerpt: logExcerpt)
            case .passed(let warnings):
                gateWarnings += warnings
            }
        }

        // Capture snapshot BEFORE compile so it reflects the source state used.
        // Freeze the edition-effective config (see `effective` above).
        let snap = try snapshotStore.capture(
            config: effective, maughamVersion: maughamVersion,
            tectonicVersion: tectonicVersion)

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, astSource: emitSource,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: language)
            let result = try await pdf.compile(label: label)
            outputPath = result.outputPath
            warnings = result.warnings
            errors = result.errors
            logExcerpt = result.logExcerpt

        case .epub:
            let epub = EPUBCompiler(
                projectURL: projectURL, astSource: emitSource,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID,
                language: language)
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
            tectonicVersion: tectonicVersion,
            language: language,
            allowStale: allowStale)
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

        // Gate warnings (allow_stale fallbacks + fountain drift) ride alongside
        // the compiler's own warnings on the success path.
        let allWarnings = gateWarnings + warnings
        await jobManager.complete(
            jobID: jobID, outputPath: outputPath,
            warnings: allWarnings, errors: errors)
        return .completed(pub, warnings: allWarnings)
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
