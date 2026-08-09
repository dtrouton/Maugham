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
    public let language: String?
    public let allowStale: Bool

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        language: String? = nil, allowStale: Bool = false
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.language = language
        self.allowStale = allowStale
    }

    public func preview(
        format: PublishConfig.Format,
        sectionIDs: [String]?,
        maxPages: Int?
    ) async throws -> Result {
        let jobID = await jobManager.register(phase: .renderingBody)
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
        // F5: previews are where template iteration lives, so refresh the
        // project's app-owned EMISSION.md here too — same unconditional
        // overwrite of that ONE file as `CompileOrchestrator.compile`, never
        // touching template.tex/preamble/partials/config.json/style files.
        try EmissionContract.renderProjectCopy(appVersion: maughamVersion)
            .write(to: projectURL.appendingPathComponent(
                        ".maugham/publish/EMISSION.md"),
                   atomically: true, encoding: .utf8)

        // Preview output lands in build/preview/ — don't pollute Exports/.
        config.outputs = .init(
            directory: Self.previewSubpath,
            filenameTemplate: "preview-{version}-{ext}.{ext}",
            sanitizeSpaces: true,
            formatsEnabled: config.outputs.formatsEnabled)

        // F2: fold the config to the language edition exactly as
        // `CompileOrchestrator.compile` does — metadata (dc:language +
        // language_overrides) then existence-based language-suffixed style
        // files. `language == nil` leaves both untouched.
        config.metadata = config.effectiveMetadata(language: language)
        config = LanguageSuffixedFile.resolvingStyleFiles(
            in: config, language: language,
            publishDir: projectURL.appendingPathComponent(
                ".maugham/publish", isDirectory: true))

        // F1: an omitted `section_ids` means "all *included* sections" — drop
        // any piece whose config section carries `include == false`. An explicit
        // `section_ids` is an exploratory override: honored verbatim, so it may
        // name an excluded section (preview is for looking, not shipping).
        let filteredSrc: ProjectASTBuilder.Source
        if let sectionIDs {
            filteredSrc = FilteredASTSource(base: astSource, sectionIDs: sectionIDs)
        } else {
            filteredSrc = IncludeFilteredASTSource(
                base: astSource, excludedSectionIDs: config.excludedSectionIDs)
        }

        // F2: run the SAME translation-coverage gate as `compile`, gating exactly
        // the pieces that will actually render (`filteredSrc`). For a default
        // preview that is the included set (so the excluded set is the config's
        // `excludedSectionIDs`, matching compile); for an explicit `section_ids`
        // override it is precisely the named allowlist, so an exploratory preview
        // of one stub is never blocked by OTHER untranslated pieces. A block
        // returns the same `.failed`-shaped errors + logExcerpt compile emits;
        // any pass warnings ride out on the success path below.
        var gateWarnings: [TectonicLogParser.Diagnostic] = []
        if let language, let source = astSource as? ProjectStoreASTSource {
            let renderedIDs = Set(filteredSrc.orderedPieces().map(\.pieceID))
            let allIDs = Set(source.orderedPieces().map(\.pieceID))
            let excludedFromGate = allIDs.subtracting(renderedIDs)
            let report = TranslationCoverage.check(
                projectStore: source.projectStore, language: language,
                excludedSectionIDs: excludedFromGate)
            switch TranslationCoverage.applyGate(
                report: report, language: language, allowStale: allowStale
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
                projectURL: projectURL, astSource: filteredSrc,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: language,
                replacesExistingOutput: true)
            let r = try await pdf.compile(label: "preview")
            let warnings = gateWarnings + r.warnings
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: warnings, errors: r.errors)
        case .epub:
            let e = EPUBCompiler(
                projectURL: projectURL, astSource: filteredSrc,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID,
                language: language,
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
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        let all = base.orderedPieces()
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
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        let all = base.orderedPieces()
        guard !excludedSectionIDs.isEmpty else { return all }
        return all.filter { !excludedSectionIDs.contains($0.pieceID) }
    }
}
