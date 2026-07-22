import Foundation

public struct EPUBCompiler {

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]   // EPUB pipeline has no LaTeX warnings
        public let errors:   [TectonicLogParser.Diagnostic]
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String
    public let jobID: String?

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        config: PublishConfig, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        jobID: String? = nil
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.config = config
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.jobID = jobID
    }

    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .renderingBody)
        }

        let ast = ProjectASTBuilder.build(from: astSource)
        let sections = zip(ast.sections.indices, ast.sections).map { (i, s) in
            EPUBPackage.Section(
                id: "s\(i + 1)",
                filename: String(format: "section-%03d.xhtml", i + 1),
                title: s.title,
                xhtmlBody: XHTMLBodyEmitter.emit(ProjectAST(sections: [s]), config: config))
        }

        // Persist build/body.xhtml for open-loop EPUB inspection via read_publish_file.
        let build = publish.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let assembled = sections.map { $0.xhtmlBody }.joined(separator: "\n")
        try? assembled.write(to: build.appendingPathComponent("body.xhtml"),
                             atomically: true, encoding: .utf8)
        try? "EPUB compile: no LaTeX log (HTML/CSS pipeline).".write(
            to: build.appendingPathComponent("compile.log"),
            atomically: true, encoding: .utf8)

        let cssURL = publish.appendingPathComponent("styles.css")
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

        let m = config.metadata
        let pkg = EPUBPackage(
            metadata: .init(
                title: m.title, author: m.author,
                subject: m.subtitle, language: m.language,
                isbn: m.isbn, publisher: m.publisher,
                publishedYear: m.year, keywords: m.keywords,
                version: config.nextVersion, label: label,
                checkpointID: "",
                compiledAtISO8601: ISO8601DateFormatter().string(from: Date())),
            sections: sections, cover: cover, stylesheetCSS: css)

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
            try FileManager.default.removeItem(at: dest)
        }

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .writingOutput)
        }
        try await EPUBZipPackager.write(
            package: pkg, to: dest, workingDirectory: publish)

        return Result(outputPath: dest.path, warnings: [], errors: [])
    }

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        OutputFilenameBuilder.make(config: config, format: format, label: label, language: nil)
    }
}
