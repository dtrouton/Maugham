import Foundation

public struct PDFCompiler {

    public struct Result {
        public let outputPath: String         // absolute path
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors:   [TectonicLogParser.Diagnostic]
        public let logExcerpt: String
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let jobID: String?
    /// The requested edition language, used only for the output filename's
    /// `{language}` token / collision suffix. dc-facing metadata (including
    /// `\MaughamLanguage`) comes from `config.metadata`, which the orchestrator
    /// has already folded to the edition.
    public let language: String?
    /// Whether an existing file at the destination is replaced. **False by
    /// default — the compile path REFUSES an occupied destination** (RULING-8,
    /// M7-PB-008), matching the republish path's rule; only previews pass
    /// true, because a preview's whole flow reuses its own filenames.
    public let replacesExistingOutput: Bool

    public init(
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        config: PublishConfig,
        jobManager: CompileJobManager,
        maughamVersion: String,
        jobID: String? = nil,
        language: String? = nil,
        replacesExistingOutput: Bool = false
    ) throws {
        self.projectURL = projectURL
        self.astSource = astSource
        self.config = config
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.jobID = jobID
        self.language = language
        self.replacesExistingOutput = replacesExistingOutput
    }

    /// Full PDF compile.
    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        let build = publish.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(
            at: build, withIntermediateDirectories: true)

        // Phase: rendering body.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .renderingBody)
        }
        let ast = ProjectASTBuilder.build(from: astSource)
        let body = LaTeXBodyEmitter.emit(ast, config: config)
        let bodyURL = build.appendingPathComponent("body.tex")
        try body.write(to: bodyURL, atomically: true, encoding: .utf8)

        // Inject metadata as \renewcommand overrides. template.tex
        // \InputIfFileExists{build/metadata}{}{} picks this up.
        let metaURL = build.appendingPathComponent("metadata.tex")
        let m = config.metadata
        let metaTex = """
        \\renewcommand{\\Title}{\(LaTeXEscape.escape(m.title))}
        \\renewcommand{\\Subtitle}{\(LaTeXEscape.escape(m.subtitle ?? ""))}
        \\renewcommand{\\Author}{\(LaTeXEscape.escape(m.author))}
        \\renewcommand{\\Copyright}{\(LaTeXEscape.escape(m.copyright ?? ""))}
        \\renewcommand{\\Keywords}{\(LaTeXEscape.escape(m.keywords.joined(separator: ", ")))}
        \\renewcommand{\\MaughamVersion}{\(LaTeXEscape.escape(config.nextVersion))}
        \\renewcommand{\\MaughamLabel}{\(LaTeXEscape.escape(label ?? ""))}
        \\providecommand{\\MaughamLanguage}{}
        \\renewcommand{\\MaughamLanguage}{\(LaTeXEscape.escape(m.language))}
        """
        try metaTex.write(to: metaURL, atomically: true, encoding: .utf8)

        // Phase: compiling.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .compiling)
        }

        let binary = try locateTectonic()
        let cache = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cache)

        // Pick the language-suffixed template (`template.es.tex`) when the
        // edition ships one; else the base `template.tex` (Task 10).
        let templateName = LanguageSuffixedFile.resolve(
            "template.tex", language: language, under: publish)
        let templateURL = publish.appendingPathComponent(templateName)
        let invocationResult = try await invoker.compile(
            texFile: templateURL,
            workingDirectory: publish,
            outputDirectory: build,
            outputFormat: .pdf
        )

        let diagnostics = TectonicLogParser.parse(log: invocationResult.combinedLog)
        let errors = diagnostics.filter { $0.level == .error }
        let warnings = diagnostics.filter { $0.level == .warning }

        // Persist the full tectonic log on every compile (success and failure)
        // so Claude Desktop can read it via read_publish_file build/compile.log.
        // try? — failing to write the log must never fail a compile.
        let logURL = build.appendingPathComponent("compile.log")
        try? invocationResult.combinedLog.write(to: logURL, atomically: true, encoding: .utf8)

        if invocationResult.exitCode != 0 {
            return Result(
                outputPath: "",
                warnings: warnings, errors: errors,
                logExcerpt: invocationResult.combinedLog)
        }

        // Phase: writing output.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .writingOutput)
        }

        // tectonic emits <templateBasename>.pdf into build/, not publish root —
        // a suffixed template (`template.es.tex`) yields `template.es.pdf`.
        let generatedName = (templateName as NSString).deletingPathExtension + ".pdf"
        let generated = build.appendingPathComponent(generatedName)
        let filename = makeOutputFilename(format: .pdf, label: label)
        let exports = projectURL.appendingPathComponent(config.outputs.directory,
                                                       isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            guard replacesExistingOutput else {
                let diag = OutputFilenameBuilder.occupiedDestinationRefusal(
                    destination: dest, projectURL: projectURL)
                return Result(outputPath: "",
                              warnings: warnings, errors: errors + [diag],
                              logExcerpt: "output_path_occupied: \(dest.lastPathComponent)")
            }
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: generated, to: dest)

        return Result(
            outputPath: dest.path,
            warnings: warnings, errors: errors,
            logExcerpt: invocationResult.combinedLog)
    }

    // MARK: - helpers

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        OutputFilenameBuilder.make(config: config, format: format, label: label, language: language)
    }

    /// Locates `tectonic` either from the running app bundle or, in XCTest,
    /// from the host app bundle (which sits at `.../Maugham.app` outside the
    /// test bundle's `Contents/PlugIns/MaughamTests.xctest`).
    private func locateTectonic() throws -> URL {
        if let url = try? TectonicLocator.locate() { return url }
        // XCTest fallback: walk up from the test bundle to find the host app.
        let testBundlePath = Bundle(for: TectonicLocatorHostBundleProbe.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return try TectonicLocator.locateInBundle(at: URL(fileURLWithPath: appPath))
    }
}

/// Marker class for `Bundle(for:)` to look up the test bundle from PDFCompiler.
/// `Bundle.main` in XCTest returns the runner, not the host app, so we use
/// a real class declared in this module to anchor the lookup.
final class TectonicLocatorHostBundleProbe {}
