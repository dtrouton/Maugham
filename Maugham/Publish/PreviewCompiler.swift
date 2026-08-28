import Foundation

@MainActor
public struct PreviewCompiler {

    /// The deterministic preview output directory where previews are rendered.
    /// Kept in sync with `ReadPreviewPageTool.previewSubpath` — the single
    /// source of truth for preview output paths.
    public static let previewSubpath = ".maugham/publish/build/preview"

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors:   [TectonicLogParser.Diagnostic]
        /// Set when a gate block (or config load) fails the preview, mirroring
        /// the `logExcerpt` a real compile carries into its `.failed` shape.
        public let logExcerpt: String

        public init(
            outputPath: String,
            warnings: [TectonicLogParser.Diagnostic],
            errors: [TectonicLogParser.Diagnostic],
            logExcerpt: String = ""
        ) {
            self.outputPath = outputPath
            self.warnings = warnings
            self.errors = errors
            self.logExcerpt = logExcerpt
        }
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let configStore: PublishConfigStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String
    /// F2: when non-nil, preview the translated edition — apply
    /// `effectiveMetadata` + language-suffixed style files and run the SAME
    /// coverage gate as `compile`. nil ⇒ the source-language preview, unchanged.
    ///
    /// P2: one half of the pair `LanguageSet` reconciles; see `languages`.
    public let language: String?
    /// P2: the languages this preview renders, one complete body each — the
    /// same argument `CompileOrchestrator.compile` takes, reconciled with
    /// `language` by the same `LanguageSet`. `nil` (or empty) leaves `language`
    /// to speak alone, which is every caller that predates this branch.
    public let languages: [String]?
    public let allowStale: Bool

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        language: String? = nil, languages: [String]? = nil,
        allowStale: Bool = false
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.language = language
        self.languages = languages
        self.allowStale = allowStale
    }

    /// Compile a preview, registering a job for it.
    ///
    /// **Every exit past the registration is terminal for that job.** The gate
    /// blocks below fail it and return; a THROW — from the EMISSION write, from
    /// the AST source, from `PDFCompiler`/`EPUBCompiler` (locating tectonic,
    /// building the AST, the cache, the spawn) — would otherwise leave the job
    /// `.inProgress` for the life of the process, and an in-progress job is not
    /// an inert record: `ProposalPromotion` reads `allInProgress()` and refuses
    /// approve/revert while one stands, so a preview that died on a missing
    /// binary would lock the writer out of promoting their templates, naming a
    /// compile that will never end. So the throw fails the job on its way out.
    public func preview(
        format: PublishConfig.Format,
        sectionIDs: [String]?,
        maxPages: Int?,
        imprint: String? = nil
    ) async throws -> Result {
        let jobID = await jobManager.register(phase: .renderingBody)
        do {
            return try await run(
                jobID: jobID, format: format, sectionIDs: sectionIDs,
                maxPages: maxPages, imprint: imprint)
        } catch {
            await jobManager.fail(
                jobID: jobID,
                errors: [TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "the preview could not be compiled: \(error)",
                    contextLines: [])],
                logExcerpt: String(describing: error))
            throw error
        }
    }

    private func run(
        jobID: String,
        format: PublishConfig.Format,
        sectionIDs: [String]?,
        maxPages: Int?,
        imprint: String?
    ) async throws -> Result {
        guard var config = try await configStore.load() else {
            // RULING-7 (M7-PB-010): the cause rides the Result, so the tool
            // renders the failed shape — an empty `errors` here was read by
            // `PreviewCompileTool` as success-with-an-empty-path, the failure
            // presented as a success with the reason dropped on the floor.
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: "no publish config — run initialize_publish_template first.",
                contextLines: [
                    "Previews read .maugham/publish/config.json, which this project does not have yet."
                ])
            await jobManager.fail(jobID: jobID, errors: [diag], logExcerpt: "no config")
            return Result(outputPath: "", warnings: [], errors: [diag])
        }

        // Imprint resolution, a two-line twin of `CompileOrchestrator.compile`'s
        // door (Task 6): the unknown-name check first, then `resolved`. It is a
        // twin rather than a shared helper because the two entry points differ
        // in what they do on failure — the orchestrator can refuse before it
        // registers a job, while a preview's job is already registered by
        // `preview(_:)` above, so this refusal must FAIL that job on its way
        // out. Everything below reads an ordinary `PublishConfig` and never
        // learns an imprint existed (spec §3).
        if let imprint, config.imprints[imprint] == nil {
            let error = PublishConfig.UnknownImprint(
                requested: imprint, known: Array(config.imprints.keys))
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.errorDescription ?? "unknown imprint '\(imprint)'",
                contextLines: ["Nothing was previewed — no output file."])
            await jobManager.fail(
                jobID: jobID, errors: [diag],
                logExcerpt: "unknown_imprint: \(imprint)")
            return Result(outputPath: "", warnings: [], errors: [diag],
                          logExcerpt: "unknown_imprint: \(imprint)")
        }
        // Read the piece ids only when they can change an answer, exactly as
        // the orchestrator does: with no imprints declared there is no
        // allowlist to materialize, and deriving every manuscript a second
        // time would be pure cost. A throw from here (an unreadable op log,
        // RULING-54; a merge-patch fragment that leaves a block undecodable)
        // escapes to `preview(_:)`'s catch, which fails the job and rethrows —
        // the same terminal exit every other throw past registration takes.
        config = try config.resolved(
            imprint: imprint,
            pieceIDs: config.imprints.isEmpty
                ? [] : try astSource.orderedPieces().map(\.pieceID))

        // P2 (Task 6): the languages this preview renders, one complete body
        // each — the SAME reconciliation the compile door performs, in the
        // same place and against the same `sourceTag` (the RESOLVED config's
        // `metadata.language`, because an imprint may spell the book's own
        // language differently from the book).
        //
        // Refused BEFORE the validate below and before a word of the
        // manuscript is emitted: a combination that cannot resolve is a
        // caller's typo, and nothing about deciding that needed the project.
        // The refusal FAILS the job on its way out — a preview's job is
        // already registered by `preview(_:)` — and wears the same
        // `.failed`-shaped Result the unknown-imprint refusal returns, with
        // the compile door's own `invalid_languages:` excerpt.
        let set: LanguageSet
        do {
            set = try LanguageSet(
                language: language, languages: languages,
                sourceTag: config.metadata.language)
        } catch {
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: error.localizedDescription,
                contextLines: ["Nothing was previewed — no output file."])
            let excerpt = "invalid_languages: \(error.localizedDescription)"
            await jobManager.fail(jobID: jobID, errors: [diag], logExcerpt: excerpt)
            return Result(outputPath: "", warnings: [], errors: [diag],
                          logExcerpt: excerpt)
        }

        // I1 (whole-branch review): the door VALIDATES what it resolved. A
        // preview runs with `replacesExistingOutput: true` and reaches
        // `PDFCompiler` with whatever `config.template` now says, so a
        // hand-edited (or synced) `imprints.x.template` of "../../secret.tex"
        // used to escape the publish tree on this path alone — the compile
        // door has validated since Task 6, and `set_publish_config`'s
        // write-time pass never sees a config that arrived another way.
        //
        // The PURE pass, deliberately, not the project-aware one: a preview
        // tolerates a missing default `template.tex` exactly as it always has
        // (the writer is iterating), and an imprint template that is simply
        // absent still surfaces from `PDFCompiler` as it does today. What this
        // refuses is a config that is malformed on its face. Same shape as the
        // unknown-name refusal above, and the same `invalid_config:` excerpt
        // `CompileOrchestrator.compile` fails with.
        let configErrors = PublishConfigValidator.validate(config)
        if !configErrors.isEmpty {
            let diags = configErrors.map {
                TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: "\($0.field): \($0.message)",
                    contextLines: ["Nothing was previewed — no output file."])
            }
            let excerpt = "invalid_config: "
                + configErrors.map(\.field).joined(separator: ", ")
            await jobManager.fail(jobID: jobID, errors: diags, logExcerpt: excerpt)
            return Result(outputPath: "", warnings: [], errors: diags,
                          logExcerpt: excerpt)
        }

        // F5: previews are where template iteration lives, so refresh the
        // project's app-owned EMISSION.md here too — same unconditional
        // overwrite of that ONE file as `CompileOrchestrator.compile`, never
        // touching template.tex/preamble/partials/config.json/style files.
        try EmissionContract.renderProjectCopy(appVersion: maughamVersion)
            .write(to: projectURL.appendingPathComponent(
                        ".maugham/publish/EMISSION.md"),
                   atomically: true, encoding: .utf8)

        // Preview output lands in build/preview/ — don't pollute Exports/.
        // This override deliberately outranks an imprint's own `outputs`
        // patch: previews have one naming rule, whoever asked for them. It
        // does NOT flatten the imprint away, because `OutputFilenameBuilder`
        // reads `config.imprint` (set by `resolved` just above) rather than
        // taking an argument — this template names no `{imprint}` token, so
        // the builder's collision guard inserts the name before the
        // extension and an imprint preview lands as
        // `preview-0.1-pdf-special.pdf`. That is what keeps it off the book's
        // preview: this directory is last-write-wins by design (a second
        // preview overwrites its own prior output), so two editions sharing
        // one filename would mean the writer's last look silently replaced
        // the other's.
        config.outputs = .init(
            directory: Self.previewSubpath,
            filenameTemplate: "preview-{version}-{ext}.{ext}",
            sanitizeSpaces: true,
            formatsEnabled: config.outputs.formatsEnabled)

        // F1: an omitted `section_ids` means "all *included* sections" — drop
        // any piece whose config section carries `include == false`. An explicit
        // `section_ids` is an exploratory override: honored verbatim, so it may
        // name an excluded section (preview is for looking, not shipping).
        //
        // P2: this is now a WRAP applied to every body rather than a source
        // built once, so a second body cannot slip past the subset the first
        // one was held to.
        let excludedSectionIDs = config.excludedSectionIDs
        let wrap: (ProjectASTBuilder.Source) -> ProjectASTBuilder.Source = { base in
            if let sectionIDs {
                return FilteredASTSource(base: base, sectionIDs: sectionIDs)
            }
            return IncludeFilteredASTSource(
                base: base, excludedSectionIDs: excludedSectionIDs)
        }

        // F2 + P2: one body per language, each bound to its own text and folded
        // to its own config. The two folds this method used to perform inline —
        // `effectiveMetadata`, then the existence-based language-suffixed style
        // files — happen once per body inside `BodyPlan`, so a second body
        // cannot inherit the first's metadata or its per-piece style files.
        // `[nil]` (no language asked for) folds nothing, exactly as before.
        //
        // A source that cannot bind to a language throws here; it escapes to
        // `preview(_:)`'s catch, which fails the job and rethrows — the same
        // terminal exit every other throw past registration takes.
        let plan = try BodyPlan.make(
            set: set, resolved: config, source: astSource,
            publishDir: projectURL.appendingPathComponent(
                ".maugham/publish", isDirectory: true),
            wrap: wrap)
        // The edition-effective config is the FIRST body's, as at the compile
        // door: it is what names the file and describes the document as a
        // whole, while each body retitles only inside its own half.
        let effective = plan.first.config

        // F2: run the SAME translation-coverage gate as `compile` — through the
        // same `gateEveryTongue` (P2 Task 6), which is where the per-tag prefix,
        // the "every blocked tongue, not just the first" rule and the joined
        // excerpt live — gating exactly the pieces that will actually render.
        // For a default
        // preview that is the included set (so the excluded set is the config's
        // `excludedSectionIDs`, matching compile); for an explicit `section_ids`
        // override it is precisely the named allowlist, so an exploratory preview
        // of one stub is never blocked by OTHER untranslated pieces. A block
        // returns the same `.failed`-shaped errors + logExcerpt compile emits;
        // any pass warnings ride out on the success path below.
        var gateWarnings: [TectonicLogParser.Diagnostic] = []
        if !set.translatedTags.isEmpty,
           let source = astSource as? ProjectStoreASTSource {
            // Which pieces this preview actually renders — read off the plan's
            // own first body, because every body is wrapped by the same filter
            // and the ids cannot differ between them. The emptiness check above
            // is not just a shortcut: a source-only preview must not pay for
            // deriving the project twice to answer a question nobody asked.
            let renderedIDs = Set(try plan.first.source.orderedPieces().map(\.pieceID))
            let allIDs = Set(try source.orderedPieces().map(\.pieceID))
            let excludedFromGate = allIDs.subtracting(renderedIDs)
            switch try TranslationCoverage.gateEveryTongue(
                projectStore: source.projectStore, tags: set.translatedTags,
                excludedSectionIDs: excludedFromGate, allowStale: allowStale
            ) {
            case .blocked(let errors, let logExcerpt):
                await jobManager.fail(jobID: jobID, errors: errors, logExcerpt: logExcerpt)
                return Result(outputPath: "", warnings: [], errors: errors,
                              logExcerpt: logExcerpt)
            case .passed(let warnings):
                gateWarnings += warnings
            }
        }

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, bodies: plan.bodies,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity,
                replacesExistingOutput: true)
            let r = try await pdf.compile(label: "preview")
            let warnings = gateWarnings + r.warnings
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: warnings, errors: r.errors)
        case .epub:
            let e = try EPUBCompiler(
                projectURL: projectURL, bodies: plan.bodies,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity,
                replacesExistingOutput: true)
            let r = try await e.compile(label: "preview")
            let warnings = gateWarnings + r.warnings
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: warnings, errors: r.errors)
        }
    }
}

/// Wraps another `ProjectASTBuilder.Source`, filtering to a subset of pieces
/// (an allowlist: keeps only pieces named in `sectionIDs`; nil/empty ⇒ all).
private struct FilteredASTSource: ProjectASTBuilder.Source {
    let base: ProjectASTBuilder.Source
    let sectionIDs: [String]?
    func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
        let all = try base.orderedPieces()
        guard let ids = sectionIDs, !ids.isEmpty else { return all }
        let set = Set(ids)
        return all.filter { set.contains($0.pieceID) }
    }
}

/// F1: wraps any `ProjectASTBuilder.Source`, dropping pieces whose id is in the
/// excluded set (a denylist — the complement of `FilteredASTSource`). This is
/// how a subset edition becomes first-class: `CompileOrchestrator`/`Republisher`
/// wrap their live source with the effective config's `excludedSectionIDs`, so
/// the emitters (both formats) and every downstream record see only the included
/// pieces. An empty excluded set is a pass-through.
struct IncludeFilteredASTSource: ProjectASTBuilder.Source {
    let base: ProjectASTBuilder.Source
    let excludedSectionIDs: Set<String>
    func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
        let all = try base.orderedPieces()
        guard !excludedSectionIDs.isEmpty else { return all }
        return all.filter { !excludedSectionIDs.contains($0.pieceID) }
    }
}
