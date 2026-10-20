import Foundation
import MaughamCore

public struct EPUBCompiler {

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]   // EPUB pipeline has no LaTeX warnings
        public let errors:   [TectonicLogParser.Diagnostic]
        /// Every body's publish problems as the compile ended — see
        /// `PDFCompiler.Result.problems`.
        public var problems: [PublishProblem] = []
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
    /// The bodies the door's gate already resolved over `imageAllowed` — see
    /// `PDFCompiler.resolved`. Nil resolves here.
    public let resolved: [PublishProblemGate.Body]?

    /// The designated init: a compile is its ordered bodies.
    public init(
        projectURL: URL, bodies: [BodyPlan.Body],
        config: PublishConfig, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String,
        jobID: String? = nil, language: String? = nil,
        identity: String? = nil,
        replacesExistingOutput: Bool = false,
        resolved: [PublishProblemGate.Body]? = nil
    ) throws {
        guard !bodies.isEmpty else { throw NoBodies() }
        // One resolved body per body, or none: a mismatch is a programming
        // error — falling back would re-read the manuscript and let the gate
        // and the emission diverge.
        precondition(resolved == nil || resolved?.count == bodies.count,
                     "resolved bodies must match bodies one for one")
        self.resolved = resolved
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
        var images: [EPUBPackage.Image] = []
        var listOfFigures: [EPUBPackage.ListEntry] = []
        var listOfTables: [EPUBPackage.ListEntry] = []
        // Resolved for ALL bodies before any of them is emitted: a slugline
        // links to the SAME piece in every OTHER body, so a body cannot be
        // emitted knowing only its own tag.
        let tags = bodies.enumerated().map { Self.fileTag(for: $1, at: $0) }
        // R-S3: each body's AST and its resolution over its WHOLE book — the
        // door's gate usually made both already (`resolved`), so the book is
        // emitted with exactly what the gate judged.
        let bodiesResolved = try resolved ?? Self.resolve(bodies: bodies)
        var problems: [PublishProblem] = []
        for (index, body) in bodies.enumerated() {
            let tag = tags[index]
            let others = tags.enumerated().filter { $0.offset != index }.map(\.element)
            let ast = bodiesResolved[index].ast
            let prepared = Self.prepare(resolution: bodiesResolved[index].resolution)
            let resolution = prepared.resolution
            problems += resolution.problems
            let pieces = ast.sections.map(\.pieceID)
            let labelHrefs = Self.labelHrefs(resolution, emittedPieces: pieces, tag: tag,
                                             bodyCount: bodies.count)
            var ownSections = zip(ast.sections.indices, ast.sections).map { (i, s) in
                EPUBPackage.Section(
                    id: bodies.count == 1 ? "s\(i + 1)" : "s-\(tag)-\(i + 1)",
                    filename: Self.sectionFilename(tag: tag, index: i,
                                                   bodyCount: bodies.count),
                    title: s.title,
                    xhtmlBody: XHTMLBodyEmitter.emit(
                        ProjectAST(sections: [s]), config: body.config,
                        anchorTag: tag,
                        // The same piece index is the same piece in every body,
                        // so section `i` of body `other` is where this section's
                        // paragraphs live over there.
                        crossLinks: others.map {
                            (tag: $0,
                             href: Self.sectionFilename(tag: $0, index: i,
                                                        bodyCount: bodies.count))
                        },
                        resolution: resolution,
                        figureFiles: prepared.figureFiles,
                        labelHrefs: labelHrefs),
                    language: body.displayTag)
            }
            // R-P2-5: the body's References, its own file at the end of the
            // body, in the spine and the contents; only when it cites.
            if !resolution.references.isEmpty {
                ownSections.append(EPUBPackage.Section(
                    id: bodies.count == 1 ? "refs" : "refs-\(tag)",
                    filename: Self.referencesFilename(tag: tag, bodyCount: bodies.count),
                    title: "References",
                    xhtmlBody: XHTMLBodyEmitter.references(resolution.references),
                    language: body.displayTag))
            }
            sections.append(contentsOf: ownSections)
            languages.append(body.displayTag)
            images += prepared.images
            // R-P2-6: the lists are the FIRST body's — a later body captions
            // the same numbers, and would list every element twice.
            if index == 0 {
                let idTag = bodies.count > 1 ? tag : nil
                listOfFigures = Self.listEntries(.fig, resolution.listOfFigures, resolution: resolution,
                                                 emittedPieces: pieces, tag: tag, idTag: idTag,
                                                 bodyCount: bodies.count)
                listOfTables = Self.listEntries(.tbl, resolution.listOfTables, resolution: resolution,
                                                emittedPieces: pieces, tag: tag, idTag: idTag,
                                                bodyCount: bodies.count)
            }

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
            languages: languages, images: images,
            listOfFigures: listOfFigures, listOfTables: listOfTables)

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
                return Result(outputPath: "", warnings: [], errors: [diag], problems: problems)
            }
            try FileManager.default.removeItem(at: dest)
        }

        if let id = jobID {
            await jobManager.updatePhase(jobID: id, phase: .writingOutput)
        }
        try await EPUBZipPackager.write(
            package: pkg, to: dest, workingDirectory: publish)

        return Result(outputPath: dest.path, warnings: [], errors: [], problems: problems)
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

    /// Where a body's section for piece `index` lives in the archive — the one
    /// spelling of the rule. A single body keeps the filenames it has always
    /// had (`section-%03d.xhtml`); more than one carries the body's tag.
    ///
    /// It is a function rather than two literals because a cross-link's `href`
    /// must name the file the OTHER body actually shipped: written twice, the
    /// two spellings can drift and every link in the book breaks silently.
    static func sectionFilename(tag: String, index: Int, bodyCount: Int) -> String {
        bodyCount == 1
            ? String(format: "section-%03d.xhtml", index + 1)
            : "section-\(tag)-" + String(format: "%03d", index + 1) + ".xhtml"
    }

    /// Where a body's References live: `references.xhtml`, or
    /// `references-<tag>.xhtml` beside the other bodies' when there are several.
    static func referencesFilename(tag: String, bodyCount: Int) -> String {
        bodyCount == 1 ? "references.xhtml" : "references-\(tag).xhtml"
    }

    // MARK: - report elements (report foundations plan 2)

    /// One body's resolution and the images its figures show.
    struct PreparedBody {
        var resolution: PublishResolution
        /// pieceID → node index → the image's path inside `OEBPS/`
        /// (`images/<hash>.<ext>`): `XHTMLBodyEmitter.emit`'s `figureFiles`.
        var figureFiles: [String: [Int: String]]
        /// What the package copies into `OEBPS/images/`, one per figure (the
        /// package keeps each filename once).
        var images: [EPUBPackage.Image]
    }

    /// The image formats an EPUB reading system must show (R-P2-7).
    static let imageAllowed: Set<String> = ["png", "jpg", "jpeg", "gif", "svg"]

    /// The OPF media type of each format in `imageAllowed`; nil for any other.
    static func mediaType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "svg":         return "image/svg+xml"
        default:            return nil
        }
    }

    /// Every body resolved for an EPUB's images: the door's gate calls this
    /// and hands the answer to `init(…resolved:)`.
    static func resolve(bodies: [BodyPlan.Body]) throws -> [PublishProblemGate.Body] {
        try PublishProblemGate.resolve(bodies: bodies, imageAllowed: imageAllowed)
    }

    /// Names the images of a resolution already made — the gate's: a body is
    /// resolved in ONE place, `PublishProblemGate.resolve` (through
    /// `resolve(bodies:)`), and this only stages what it resolved.
    ///
    /// Naming an image reads it through (streamed, `FigureImageResolver
    /// .contentHash`), after a header sniff (`FigureImageResolver.opens`), so
    /// an image that can't be read or won't open is found HERE, before a word
    /// is emitted: `stagingFailed` makes it an `imageUnreadable` problem and
    /// its figure renders as its literal source. The bytes themselves are
    /// copied only at packaging time (`EPUBZipPackager`).
    static func prepare(resolution: PublishResolution) -> PreparedBody {
        var resolution = resolution
        var figureFiles: [String: [Int: String]] = [:]
        var images: [EPUBPackage.Image] = []
        for (piece, files) in resolution.figureFiles.sorted(by: { $0.key < $1.key }) {
            for (index, source) in files.sorted(by: { $0.key < $1.key }) {
                let ext = source.pathExtension.lowercased()
                // `imageAllowed` already refused any other format; this is the
                // second line of defence, never a manifest item without a type.
                guard let type = mediaType(forExtension: ext) else {
                    resolution.stagingFailed(pieceID: piece, nodeIndex: index,
                                             because: "is a .\(ext) file, which an EPUB can't show")
                    continue
                }
                if let problem = FigureImageResolver.openingProblem(of: source) {
                    resolution.stagingFailed(pieceID: piece, nodeIndex: index, because: problem)
                    continue
                }
                do {
                    let image = EPUBPackage.Image(
                        filename: try FigureImageResolver.contentHash(of: source) + "." + ext,
                        source: source, mediaType: type)
                    images.append(image)
                    figureFiles[piece, default: [:]][index] = image.href
                } catch {
                    resolution.stagingFailed(
                        pieceID: piece, nodeIndex: index,
                        because: "couldn't be read for the compile ("
                            + PublishProblem.withoutClosingStop(error.localizedDescription) + ")")
                }
            }
        }
        return PreparedBody(resolution: resolution, figureFiles: figureFiles, images: images)
    }

    /// Each label's href in this body: the section file its target's piece is
    /// emitted in, plus the label's id. A target in a piece this compile does
    /// not emit (a preview or an excluding imprint) gets none: its
    /// cross-reference reads as its resolved text, unlinked.
    static func labelHrefs(_ resolution: PublishResolution, emittedPieces: [String],
                           tag: String, bodyCount: Int) -> [ManuscriptLabel: String] {
        let files = fileIndex(emittedPieces)
        var hrefs: [ManuscriptLabel: String] = [:]
        for (label, target) in resolution.targets {
            guard let i = files[target.pieceID] else { continue }
            hrefs[label] = sectionFilename(tag: tag, index: i, bodyCount: bodyCount) + "#"
                + XHTMLBodyEmitter.labelID(label, tag: bodyCount > 1 ? tag : nil)
        }
        return hrefs
    }

    /// The nav's list of figures or tables (R-P2-6): every listed element this
    /// compile emits, linked to its id in its section file.
    private static func listEntries(_ kind: ManuscriptLabel.Kind,
                                    _ list: [PublishResolution.ListEntry],
                                    resolution: PublishResolution, emittedPieces: [String],
                                    tag: String, idTag: String?, bodyCount: Int) -> [EPUBPackage.ListEntry] {
        let files = fileIndex(emittedPieces)
        return list.compactMap { entry in
            guard let i = files[entry.target.pieceID] else { return nil }
            let id = XHTMLBodyEmitter.elementAddress(kind, number: entry.number, target: entry.target,
                                                     resolution: resolution, tag: idTag)
            return .init(title: XHTMLBodyEmitter.listTitle(kind, number: entry.number, caption: entry.caption,
                                                           resolution: resolution,
                                                           pieceID: entry.target.pieceID),
                         href: sectionFilename(tag: tag, index: i, bodyCount: bodyCount) + "#" + id)
        }
    }

    /// pieceID → its section's index in this body.
    private static func fileIndex(_ pieces: [String]) -> [String: Int] {
        Dictionary(pieces.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func makeOutputFilename(
        format: PublishConfig.Format, label: String?
    ) -> String {
        OutputFilenameBuilder.make(config: config, format: format, label: label,
                                  language: identity)
    }
}
