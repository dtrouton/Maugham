import Foundation

public struct EPUBCompiler {

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]   // EPUB pipeline has no LaTeX warnings
        public let errors:   [TectonicLogParser.Diagnostic]
    }

    /// A `bodies:` array that cannot make a book.
    public struct NoBodies: Error, LocalizedError, Equatable {
        public var errorDescription: String? {
            "an EPUB compile needs at least one body"
        }
    }

    public let projectURL: URL
    /// One complete body per rendered language, in order (P2). Each body owns
    /// its own sections — its own filenames, its own spine ids and its own
    /// `<html lang>` — so a bilingual EPUB is one publication whose halves a
    /// reading system can tell apart.
    ///
    /// Single-language compiles pass through the `astSource:` init below,
    /// which builds a one-body array; every caller that predates P2 ships a
    /// byte-identical `content.opf` and `nav.xhtml` and the same
    /// `section-%03d.xhtml` filenames.
    public let bodies: [BodyPlan.Body]
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String
    public let jobID: String?
    /// The tag the language-SUFFIXED files are resolved against —
    /// `styles.<tag>.css`. `nil` for a source compile, and `nil` for a
    /// multi-body one: a bilingual book belongs to no single tongue's
    /// stylesheet. dc:language comes from `config.metadata.language`, which the
    /// orchestrator has already folded to the edition.
    public let language: String?
    /// How this edition is NAMED — see `PDFCompiler.identity`. Defaults to
    /// `language`; the joined identity ("en+sr") only for a multi-body compile,
    /// so a bilingual book lands beside the source edition rather than on it.
    public let identity: String?
    /// See `PDFCompiler.replacesExistingOutput` — false by default (refuse),
    /// true only for previews.
    public let replacesExistingOutput: Bool

    /// The designated init: a compile is its ordered bodies.
    public init(
        projectURL: URL, bodies: [BodyPlan.Body],
        config: PublishConfig, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        jobID: String? = nil, language: String? = nil,
        identity: String? = nil,
        replacesExistingOutput: Bool = false
    ) throws {
        guard !bodies.isEmpty else { throw NoBodies() }
        self.projectURL = projectURL
        self.bodies = bodies
        self.config = config
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.jobID = jobID
        self.language = language
        self.identity = identity ?? language
        self.replacesExistingOutput = replacesExistingOutput
    }

    /// The single-body init every caller before P2 uses.
    ///
    /// It builds the one-body plan itself rather than calling `BodyPlan.make`
    /// — `make` is `@MainActor` and this init is not, and it has nothing to
    /// rebind: the caller has already bound `astSource` to the language it is
    /// compiling and already folded `config` to it. Its tag derivation is
    /// `PDFCompiler`'s, character for character.
    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        config: PublishConfig, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        jobID: String? = nil, language: String? = nil,
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
            tectonicVersion: tectonicVersion,
            jobID: jobID,
            language: language,
            replacesExistingOutput: replacesExistingOutput)
    }

    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .renderingBody)
        }

        // Persist build/body*.xhtml for open-loop EPUB inspection via
        // read_publish_file.
        let build = publish.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

        // One complete body per language, in order, each reading its OWN
        // source and emitting under its OWN config. A single body keeps the
        // filenames and spine ids it has always had — `section-%03d.xhtml`
        // and `s<i>` — because a book that has only ever had one language
        // must not have its archive rearranged underneath it.
        var sections: [EPUBPackage.Section] = []
        var languages: [String] = []
        for (index, body) in bodies.enumerated() {
            let tag = Self.fileTag(for: body, at: index)
            let ast = try ProjectASTBuilder.build(from: body.source)
            let ownSections = zip(ast.sections.indices, ast.sections).map { (i, s) in
                EPUBPackage.Section(
                    id: bodies.count == 1 ? "s\(i + 1)" : "s-\(tag)-\(i + 1)",
                    filename: bodies.count == 1
                        ? String(format: "section-%03d.xhtml", i + 1)
                        : "section-\(tag)-" + String(format: "%03d", i + 1) + ".xhtml",
                    title: s.title,
                    xhtmlBody: XHTMLBodyEmitter.emit(
                        ProjectAST(sections: [s]), config: body.config),
                    language: body.displayTag)
            }
            sections.append(contentsOf: ownSections)
            languages.append(body.displayTag)

            let assembled = ownSections.map { $0.xhtmlBody }.joined(separator: "\n")
            try? assembled.write(to: build.appendingPathComponent("body.\(tag).xhtml"),
                                 atomically: true, encoding: .utf8)
            // `build/body.xhtml` is the FIRST body's, exactly as
            // `PDFCompiler` keeps `build/metadata.tex` the first body's beside
            // the per-body `build/metadata.<tag>.tex`.
            if index == 0 {
                try? assembled.write(to: build.appendingPathComponent("body.xhtml"),
                                     atomically: true, encoding: .utf8)
            }
        }
        try? "EPUB compile: no LaTeX log (HTML/CSS pipeline).".write(
            to: build.appendingPathComponent("compile.log"),
            atomically: true, encoding: .utf8)

        // Pick the language-suffixed stylesheet (`styles.es.css`) when the
        // edition ships one; else the base `styles.css` (Task 10).
        let cssName = LanguageSuffixedFile.resolve(
            "styles.css", language: language, under: publish)
        let cssURL = publish.appendingPathComponent(cssName)
        let css = (try? String(contentsOf: cssURL)) ?? ""  // adr-0018-ok: bundled EPUB CSS asset read, not manuscript

        var cover: EPUBPackage.Cover? = nil
        if let coverPath = config.cover.path {
            let coverURL = publish.appendingPathComponent(coverPath)
            if FileManager.default.fileExists(atPath: coverURL.path),
               let data = try? Data(contentsOf: coverURL) {  // adr-0018-ok: cover-image bytes read, not manuscript
                let mediaType: String
                let ext = coverURL.pathExtension.lowercased()
                switch ext {
                case "jpg", "jpeg": mediaType = "image/jpeg"
                case "png":         mediaType = "image/png"
                case "webp":        mediaType = "image/webp"
                default:            mediaType = "application/octet-stream"
                }
                cover = .init(
                    filename: "cover." + ext, data: data,
                    mediaType: mediaType)
            }
        }

        // Document-level metadata is the FIRST body's — a bilingual EPUB is
        // one publication, titled in its source language, and `dc:language`'s
        // first entry is that body's. The same rule `PDFCompiler` applies to
        // `build/metadata.tex`.
        let m = bodies[0].config.metadata
        let pkg = EPUBPackage(
            metadata: .init(
                title: m.title, author: m.author,
                subject: m.subtitle, language: m.language,
                isbn: m.isbn, publisher: m.publisher,
                publishedYear: m.year, keywords: m.keywords,
                version: config.nextVersion, label: label,
                checkpointID: "",
                compiledAtISO8601: ISO8601DateFormatter().string(from: Date())),
            sections: sections, cover: cover, stylesheetCSS: css,
            languages: languages)

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .compiling)
        }

        let filename = makeOutputFilename(format: .epub, label: label)
        let exports = projectURL.appendingPathComponent(config.outputs.directory,
                                                       isDirectory: true)
        try FileManager.default.createDirectory(
            at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            guard replacesExistingOutput else {
                let diag = OutputFilenameBuilder.occupiedDestinationRefusal(
                    destination: dest, projectURL: projectURL)
                return Result(outputPath: "", warnings: [], errors: [diag])
            }
            try FileManager.default.removeItem(at: dest)
        }

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .writingOutput)
        }
        try await EPUBZipPackager.write(
            package: pkg, to: dest, workingDirectory: publish)

        return Result(outputPath: dest.path, warnings: [], errors: [])
    }

    /// How a body is spelled in `section-<tag>-NNN.xhtml`, in its spine id and
    /// in `build/body.<tag>.xhtml`.
    ///
    /// `PDFCompiler.fileTag(for:at:)`'s rule, over the same allowlist: the
    /// body's own `displayTag` when it can be a filename, else the body's
    /// ordinal. Every tag but one is validated by `LanguageSet`; the source
    /// body's is `config.metadata.language`, free-form config text, and a
    /// value like `"en US"` would put a space in an archive entry name and in
    /// an `href`. Only the FILENAME is sanitised — the section still declares
    /// the writer's own spelling in `xml:lang`, and `<dc:language>` still
    /// carries it.
    static func fileTag(for body: BodyPlan.Body, at index: Int) -> String {
        LaTeXSafeFilename(body.displayTag) != nil ? body.displayTag : "\(index + 1)"
    }

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        OutputFilenameBuilder.make(config: config, format: format, label: label,
                                  language: identity)
    }
}
