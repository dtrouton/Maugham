import Foundation

public struct PDFCompiler {

    public struct Result {
        public let outputPath: String         // absolute path
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors:   [TectonicLogParser.Diagnostic]
        public let logExcerpt: String
    }

    /// A `bodies:` array that cannot make a document.
    public struct NoBodies: Error, LocalizedError, Equatable {
        public var errorDescription: String? {
            "a PDF compile needs at least one body"
        }
    }

    public let projectURL: URL
    /// One complete body per rendered language, in order (P2). `build/body.tex`
    /// is a WRAPPER over them rather than the book itself, so a template can
    /// give each half its own title page by redefining `MaughamBody`.
    ///
    /// Single-language compiles pass through the `astSource:` init below, which
    /// builds a one-body array — so every caller that predates P2 compiles
    /// unchanged, and `build/metadata.tex` keeps its bytes.
    public let bodies: [BodyPlan.Body]
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let jobID: String?
    /// The tag the language-SUFFIXED files are resolved against —
    /// `template.<tag>.tex`, and the per-piece style files the config already
    /// carries. `nil` for a source compile, and `nil` for a multi-body one: a
    /// bilingual document belongs to no single tongue's template. dc-facing
    /// metadata (including `\MaughamLanguage`) comes from `config.metadata`,
    /// which the orchestrator has already folded to the edition.
    public let language: String?
    /// How this edition is NAMED — the output filename's `{language}` token and
    /// its collision suffix. Defaults to `language` and is the same string for
    /// every compile that has ever existed; a multi-body compile is the one
    /// case where the two part company, passing the joined identity ("en+sr")
    /// so a bilingual book lands BESIDE the source edition at its version
    /// rather than on top of it.
    public let identity: String?
    /// Whether an existing file at the destination is replaced. **False by
    /// default — the compile path REFUSES an occupied destination** (RULING-8,
    /// M7-PB-008), matching the republish path's rule; only previews pass
    /// true, because a preview's whole flow reuses its own filenames.
    public let replacesExistingOutput: Bool

    /// The designated init: a compile is its ordered bodies.
    public init(
        projectURL: URL,
        bodies: [BodyPlan.Body],
        config: PublishConfig,
        jobManager: CompileJobManager,
        maughamVersion: String,
        jobID: String? = nil,
        language: String? = nil,
        identity: String? = nil,
        replacesExistingOutput: Bool = false
    ) throws {
        guard !bodies.isEmpty else { throw NoBodies() }
        self.projectURL = projectURL
        self.bodies = bodies
        self.config = config
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.jobID = jobID
        self.language = language
        self.identity = identity ?? language
        self.replacesExistingOutput = replacesExistingOutput
    }

    /// The single-body init every caller before P2 uses.
    ///
    /// It builds the one-body plan itself rather than calling `BodyPlan.make`:
    /// `make` is `@MainActor` (it may rebind a main-actor-isolated source) and
    /// this init is not, and it has nothing to rebind — the caller has already
    /// bound `astSource` to the language it is compiling and already folded
    /// `config` to it. Its tag is `language ?? config.metadata.language`, which
    /// is exactly what `BodyPlan.make` would derive for a one-body
    /// `LanguageSet` over the same inputs.
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
        let tag = (language ?? "").isEmpty ? nil : language
        try self.init(
            projectURL: projectURL,
            bodies: [BodyPlan.Body(
                tag: tag,
                displayTag: tag ?? config.metadata.language,
                source: astSource,
                config: config)],
            config: config,
            jobManager: jobManager,
            maughamVersion: maughamVersion,
            jobID: jobID,
            language: language,
            replacesExistingOutput: replacesExistingOutput)
    }

    /// Full PDF compile.
    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        let build = publish.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(
            at: build, withIntermediateDirectories: true)

        // The template is the CONFIG's (Task 5) — `"template.tex"` is only its
        // default, and an imprint replaces it through
        // `PublishConfig.resolved(imprint:pieceIDs:)`. Nothing here takes an
        // `imprint` parameter: resolution happened at the door, and this
        // compiler reads the one field it left behind. Then the
        // language-suffixed variant (`special.es.tex`) when the edition ships
        // one; else the config's own name (Task 10).
        //
        // Resolved BEFORE the bodies are written, not just before the
        // invocation: the wrapper's `\input` arguments are relative to the
        // TEMPLATE's own directory (see `wrapperInputPrefix`), so the wrapper
        // cannot be written without knowing which template will read it.
        let templateName = LanguageSuffixedFile.resolve(
            config.template, language: language, under: publish)
        let templateURL = publish.appendingPathComponent(templateName)
        let prefix = Self.wrapperInputPrefix(forTemplate: templateName)

        // Phase: rendering body.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .renderingBody)
        }

        // One complete body per language, in order, each under its own tag.
        // `build/body.tex` is the WRAPPER over them (P2) — for a single body it
        // is the guard line plus one `MaughamBody` line, and the book itself
        // moves to `build/body.<tag>.tex`.
        var wrapperLines = [Self.maughamBodyGuard]
        for (index, body) in bodies.enumerated() {
            let tag = Self.fileTag(for: body, at: index)
            let ast = try ProjectASTBuilder.build(from: body.source)
            try LaTeXBodyEmitter.emit(ast, config: body.config).write(
                to: build.appendingPathComponent("body.\(tag).tex"),
                atomically: true, encoding: .utf8)
            try Self.metadataBlock(config: body.config, label: label).write(
                to: build.appendingPathComponent("metadata.\(tag).tex"),
                atomically: true, encoding: .utf8)
            wrapperLines.append(
                "\\begin{MaughamBody}{\(tag)}"
                + "\\input{\(prefix)build/metadata.\(tag)}"
                + "\\input{\(prefix)build/body.\(tag)}"
                + "\\end{MaughamBody}")
        }
        try wrapperLines.joined(separator: "\n").write(
            to: build.appendingPathComponent("body.tex"),
            atomically: true, encoding: .utf8)

        // Document-level metadata is the FIRST body's, byte-for-byte what a
        // single-body compile has always written here. template.tex
        // `\InputIfFileExists{build/metadata}{}{}` picks this up BEFORE
        // `\begin{document}`, so it is what the title page, the running heads
        // and hyperref's document properties read — a bilingual PDF is one
        // book, titled in its source language, and the translated half retitles
        // only inside its own `MaughamBody` group.
        try Self.metadataBlock(config: bodies[0].config, label: label).write(
            to: build.appendingPathComponent("metadata.tex"),
            atomically: true, encoding: .utf8)

        // Phase: compiling.
        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .compiling)
        }

        let binary = try locateTectonic()
        let cache = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cache)

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
        //
        // BASENAME, deliberately (measured against the bundled tectonic,
        // 2026-08-27): `--outdir` is FLAT. A template in a subdirectory,
        // `templates/special.tex`, lands its PDF at `build/special.pdf` — never
        // at `build/templates/special.pdf`. Taking the whole path and swapping
        // the extension looks right and names a file tectonic never writes, so
        // the move below throws a file-not-found on the one config an imprint
        // is most likely to use.
        let generatedName =
            ((templateName as NSString).lastPathComponent as NSString)
                .deletingPathExtension + ".pdf"
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

    // MARK: - the wrapper

    /// The first line of every `build/body.tex`.
    ///
    /// It is emitted rather than left to the template because **an existing
    /// project never receives starter updates** (`PublishStarter.installIfMissing`):
    /// a book whose `preamble.tex` predates P2 has never heard of `MaughamBody`,
    /// and without this line its next compile would fail on an undefined
    /// environment. `\ifdefined` means a template that DOES define it — the
    /// starter's own preamble, or an imprint giving each half a title page —
    /// wins, because the template's definition is read before the body.
    ///
    /// `\clearpage` is the whole default behaviour: the halves of a bilingual
    /// book start on fresh pages and nothing else changes. It opens no page of
    /// its own when the page is already fresh, which is why a single-body
    /// compile paginates exactly as it did before the wrapper existed.
    static let maughamBodyGuard =
        "\\ifdefined\\MaughamBody\\else\\newenvironment{MaughamBody}[1]{\\clearpage}{}\\fi"

    /// What every `\input` in the wrapper is prefixed with.
    ///
    /// **Measured 2026-08-28 against the bundled tectonic:** an `\input` inside
    /// `build/body.tex` resolves relative to the **primary template's own
    /// directory** — not relative to `body.tex`, and not relative to the
    /// process working directory (which is the publish dir, where the files
    /// plainly are). A template at `templates/special.tex` reading a wrapper
    /// that says `\input{build/metadata.en}` fails with
    /// `! LaTeX Error: File 'build/metadata.en' not found.`
    ///
    /// This is the same rule an imprint template already lives under for its
    /// own partials (`\input{../preamble}`, `ImprintTemplateCompileTests`) —
    /// but the wrapper is Maugham's file, not the template author's, so
    /// Maugham owns the prefix: one `../` per directory the template sits
    /// below the publish dir, and the empty string for a template at the root.
    static func wrapperInputPrefix(forTemplate name: String) -> String {
        let depth = name.split(separator: "/").count - 1
        return String(repeating: "../", count: max(0, depth))
    }

    /// How a body is spelled in `build/body.<tag>.tex` and in the wrapper's
    /// `\input` arguments.
    ///
    /// Normally the body's own `displayTag`. But that tag is a validated
    /// language tag in every path but one — the source body's is
    /// `config.metadata.language`, free-form config text — and a value like
    /// `"en US"` would emit an `\input` argument that cannot resolve and a
    /// filename that cannot be named in TeX. Rather than fail a compile that
    /// works today, an unusable tag falls back to the body's ordinal: always a
    /// safe filename, always unique within the document, and still visible to a
    /// template through `MaughamBody`'s argument.
    static func fileTag(for body: BodyPlan.Body, at index: Int) -> String {
        LaTeXSafeFilename(body.displayTag) != nil ? body.displayTag : "\(index + 1)"
    }

    /// The `\renewcommand` block a body's metadata becomes — the same text
    /// `PDFCompiler` has written to `build/metadata.tex` since publishing
    /// shipped, now rendered once per body as well as once for the document.
    static func metadataBlock(config: PublishConfig, label: String?) -> String {
        let m = config.metadata
        return """
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
    }

    // MARK: - helpers

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        OutputFilenameBuilder.make(config: config, format: format, label: label,
                                  language: identity)
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
