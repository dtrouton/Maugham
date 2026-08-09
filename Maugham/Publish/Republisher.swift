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

        // Find the prior publication so we can fill `republishedFrom` and
        // carry its edition `language` forward — the snapshot's config is
        // already language-effective (Task 7 Rule 1), but the compilers and
        // the new Publication record still need the tag explicitly to
        // language-suffix the filename and tag the catalog entry.
        let prior = try await publicationStore.publication(forSnapshotID: snapshotID)
        let priorVersion = prior?.version

        // P1 (issue #25): the republish version is minted BEFORE compile and
        // stamped through the config — filename, artifact-internal stamp and
        // catalog row all agree, which is CompileOrchestrator's own stamp=row
        // invariant (its `effective.nextVersion = effectiveVersion`) arriving on
        // this path. Minted here, once: the append below must reuse this value.
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let newVersion = priorVersion.map { "\($0)-r\(suffix)" } ?? "republish-\(suffix)"
        var effective = snap.config
        effective.nextVersion = newVersion

        let language = prior?.language
        // Round 3: `republish` has no `allow_stale` parameter of its own — it
        // replays whichever gate mode the ORIGINAL compile used. `false` for
        // a strictly-gated edition and for any publication compiled before
        // this field existed (ADR 0015 additive default).
        let allowStale = prior?.allowStale ?? false

        // F1: reproduce the historical subset. The snapshot's config is already
        // language-effective (Task 7 Rule 1), so its `include` flags are exactly
        // those the original compile used — wrap the live source with the same
        // excluded set. An empty set is a pass-through (pre-F1 snapshots).
        let excludedSectionIDs = snap.config.excludedSectionIDs
        let emitSource = IncludeFilteredASTSource(
            base: astSource, excludedSectionIDs: excludedSectionIDs)

        let jobID = await jobManager.register(phase: .renderingBody)

        // Task 9 F1: the snapshot freezes config/templates only — `astSource`
        // still reads the LIVE ProjectStore for manuscript/translation content
        // (see `pieceRef(for:)` in ProjectStoreASTSource), so a translated
        // edition (`prior.language != nil`) can drift stale between the
        // gated `compile` and a later `republish`. Re-run the same coverage
        // check here and hand the report to `TranslationCoverage.applyGate`
        // in whichever mode `prior.allowStale` pins (round 3) — the SAME
        // helper `CompileOrchestrator.compile` uses (round 5: this used to
        // be reimplemented inline here, and had silently dropped
        // `fountainDriftWarnings` as a result).
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

        let outputPath: String
        let warnings: [TectonicLogParser.Diagnostic]
        let errors: [TectonicLogParser.Diagnostic]
        let logExcerpt: String

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: stage, astSource: emitSource,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: language)
            let r = try await pdf.compile(label: label)
            outputPath = r.outputPath
            warnings = r.warnings
            errors = r.errors
            logExcerpt = r.logExcerpt
        case .epub:
            let e = EPUBCompiler(
                projectURL: stage, astSource: emitSource,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID,
                language: language)
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
            // Defensive only: with the republish version in the filename this can
            // no longer collide with a SIBLING edition's file — it fires only when
            // re-staging after a crashed prior move of this same republish.
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: stageOutputURL, to: dest)

        // Re-persist snapshot (idempotent — the file already exists).
        try snapshotStore.save(snap)

        // Append a Publication referencing the source snapshot.
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
            tectonicVersion: tectonicVersion,
            language: language,
            allowStale: allowStale)
        try await publicationStore.append(pub)

        // Gate warnings (allow-stale fallbacks) ride alongside the
        // compiler's own warnings on the success path, matching
        // `CompileOrchestrator.compile`.
        let allWarnings = gateWarnings + warnings
        await jobManager.complete(jobID: jobID, outputPath: dest.path,
                                  warnings: allWarnings, errors: errors)
        return .completed(pub, warnings: allWarnings)
    }

    private func relativePath(_ abs: String, from root: URL) -> String {
        let prefix = root.path + "/"
        if abs.hasPrefix(prefix) { return String(abs.dropFirst(prefix.count)) }
        return abs
    }
}
