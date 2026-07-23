import Foundation
import MaughamCore

public struct CompileOrchestrator {

    public enum Outcome: Sendable {
        case completed(Publication, warnings: [TectonicLogParser.Diagnostic])
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
        /// F2 `dry_run`: the coverage gate (and the version-collision guard)
        /// passed, but nothing was compiled, snapshotted, minted, or version-
        /// bumped. Carries the same gate warnings a real compile would ride out
        /// on its success path.
        case dryRunPassed(warnings: [TectonicLogParser.Diagnostic])
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
        allowStale: Bool = false,
        dryRun: Bool = false,
        version: String? = nil
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

        // F5: EMISSION.md is app-owned and generated — refresh the project's
        // copy on every compile (dry_run included: it still runs the
        // pipeline's front half, and there's no reason to let the doc drift
        // just because nothing got emitted) so it never misinforms an agent
        // reading it as instructed. Unconditional overwrite of that ONE file;
        // every other starter file (template.tex, preamble/partials,
        // config.json, style files) is untouched. Runs after config load and
        // BEFORE snapshot capture below, so a real compile's snapshot embeds
        // the freshly-stamped copy.
        try EmissionContract.renderProjectCopy(appVersion: maughamVersion)
            .write(to: publishDir.appendingPathComponent("EMISSION.md"),
                   atomically: true, encoding: .utf8)

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

        // Edition identity (spec 2026-07-23): a Publication is keyed on the
        // triple (version, language, format). Resolve the version THIS compile
        // mints at BEFORE the collision guard runs.
        //   • source (language == nil): version comes from next_version; a
        //     caller-supplied `version` is meaningless here and refused loudly.
        //   • edition (language != nil): an edition is a rendering OF a source
        //     version — it never mints its own. With `version` it pins that
        //     exact source version, which must already have a source-language
        //     publication. Without `version` it targets the latest source
        //     publication's version (most recent `compiledAt`, `language == nil`);
        //     when no source publication exists at all it refuses loudly
        //     ("compile the source edition first").
        let existingPublications = try await publicationStore.load()

        let effectiveVersion: String
        if language == nil {
            if let version {
                let diag = TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "version '\(version)' requires a language — source versions come from next_version, not a pinned version.",
                    contextLines: [
                        "Omit `version` to compile the source edition at next_version ('\(config.nextVersion)').",
                        "Or pass `language` to render an edition of an existing source version."
                    ])
                await jobManager.fail(
                    jobID: jobID, errors: [diag],
                    logExcerpt: "version_without_language: \(version)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "version_without_language: \(version)")
            }
            effectiveVersion = config.nextVersion
        } else if let version {
            // Original source records only (`republishedFrom == nil`): a
            // republished source record carries a mangled `-r…` version, and
            // letting a pin validate against one would mint the edition at
            // that mangled version — the same family fragmentation the
            // latest-source branch below guards against (T1 review). Pin the
            // ORIGINAL version; the edition compiles the CURRENT manuscript
            // either way (republish is the snapshot-reproduction path).
            guard existingPublications.contains(where: {
                $0.language == nil && $0.republishedFrom == nil
                    && $0.version == version
            }) else {
                let diag = TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "no source v\(version) to render in \(language!) — compile the source edition first, then render its edition.",
                    contextLines: [
                        "A language edition pins an EXISTING source publication's version.",
                        "No source-language publication (language == nil) exists at v\(version)."
                    ])
                await jobManager.fail(
                    jobID: jobID, errors: [diag],
                    logExcerpt: "no_source_version: \(version)/\(language!)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "no_source_version: \(version)/\(language!)")
            }
            effectiveVersion = version
        } else {
            // Latest ORIGINAL source publication by compiledAt. Republished
            // source records (`republishedFrom != nil`, language == nil) are
            // excluded: they carry a mangled `-r…` version, and if one were
            // the most recent, resolving to it would mint the edition at that
            // mangled version, fragmenting the (version, language, format)
            // family (T1 review).
            let sources = existingPublications.filter {
                $0.language == nil && $0.republishedFrom == nil
            }
            guard let latest = sources.max(by: { $0.compiledAt < $1.compiledAt }) else {
                let diag = TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "no source publication exists — compile the source edition first (or pass version to pin one) before rendering the \(language!) edition.",
                    contextLines: [
                        "An edition is a rendering of a source version; it no longer mints its own.",
                        "Compile without a language to create the source edition, then retry."
                    ])
                await jobManager.fail(
                    jobID: jobID, errors: [diag],
                    logExcerpt: "no_source_publication: \(language!)")
                return .failed(
                    errors: [diag],
                    logExcerpt: "no_source_publication: \(language!)")
            }
            effectiveVersion = latest.version
        }

        // Pre-compile collision guard: refuse only an exact (version, language,
        // format) match. For source compiles this is strictly weaker than the
        // old version-only guard (format joins the key), permitting a
        // deliberately completed edition family at a manually-set version.
        // Republished records share a version deliberately but always carry a
        // distinct `-r…` version string, so they never match this triple
        // (republish path untouched).
        if existingPublications.contains(where: {
            $0.version == effectiveVersion
                && $0.language == language
                && $0.format == format
        }) {
            let langLabel = language ?? "source"
            let diag = TectonicLogParser.Diagnostic(
                level: .error,
                file: nil, line: nil,
                message: "Publication v\(effectiveVersion) (\(langLabel), \(format.rawValue)) already exists; refusing to compile a colliding edition.",
                contextLines: [
                    "The (version, language, format) triple '\(effectiveVersion)/\(langLabel)/\(format.rawValue)' matches an existing Publication.",
                    language == nil
                        ? "Bump next_version via set_publish_config, or compile a different format/language to complete the family."
                        : "This edition already exists; compile a different format, or a new source version.",
                    "Or use republish if you want a new compile from a prior snapshot."
                ])
            await jobManager.fail(
                jobID: jobID,
                errors: [diag],
                logExcerpt: "version_collision: \(effectiveVersion)/\(langLabel)/\(format.rawValue)")
            return .failed(
                errors: [diag],
                logExcerpt: "version_collision: \(effectiveVersion)/\(langLabel)/\(format.rawValue)")
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

        // F2 dry_run: short-circuit AFTER the version-collision guard and the
        // coverage gate (both of which report a would-be failure with the
        // standard `.failed` shape above) but BEFORE any mutation — no snapshot,
        // no compile, no Publication, no event, no version bump, no output file.
        // Returns the gate verdict (any allow_stale/fountain-drift warnings) so
        // the caller can see exactly what a real compile would emit. The job
        // terminates in the distinct `.dryRunPassed` state so a polled
        // `compile_status` (wait_seconds:0 race) reports the dry-run outcome,
        // not a completed job with an empty output path.
        if dryRun {
            await jobManager.completeDryRun(jobID: jobID, warnings: gateWarnings)
            return .dryRunPassed(warnings: gateWarnings)
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
            version: effectiveVersion,
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

        // Bump version in config — source compiles only. A language edition is
        // a rendering of an existing source version and must never advance the
        // source version counter (spec 2026-07-23). Saving the ORIGINAL
        // `config` (never `effective`) keeps a translated compile from
        // overwriting the shared config.
        if language == nil {
            var nextConfig = config
            nextConfig.nextVersion = PublishConfigValidator.bumpedNextVersion(
                from: config.nextVersion)
            try await configStore.save(nextConfig)
        }

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
