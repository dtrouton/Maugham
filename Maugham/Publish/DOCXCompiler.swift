import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MaughamCore

/// **The Word (`.docx`) compile** — the third publish format beside
/// `PDFCompiler` and `EPUBCompiler` (report plan 4, R-4-5), through the same
/// gate: the door resolves each body for Word's images (`resolve(bodies:)`),
/// `PublishProblemGate` judges them, and the compiler emits what was judged.
///
/// Per body: `prepare(resolution:publishDir:)` stages its figures (R-S3: a
/// PDF or SVG becomes a PNG before emission; one that can't is a problem and
/// prints its literal). Then `DOCXBodyEmitter.emit(bodies:config:page:)`
/// writes one document from every body in order, and `DOCXPackage` zips it
/// with the styles (built-in, or a `reference.docx` merged over them) to
/// `Exports/`. The page is A4 unless the book's region is the US or Canada
/// (R-S4) — the tag's region, or this Mac's when the tag names none (R-S5).
public struct DOCXCompiler {

    /// The same shape as `EPUBCompiler.Result`: Word has no log, so a door's
    /// `logExcerpt` for a DOCX compile is `""`.
    public struct Result {
        public let outputPath: String
        /// A `reference.docx` that couldn't be used, for one.
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors: [TectonicLogParser.Diagnostic]
        /// Every body's publish problems as the compile ended — see
        /// `PDFCompiler.Result.problems`.
        public var problems: [PublishProblem] = []
    }

    /// A `bodies:` array that cannot make a document.
    public struct NoBodies: Error, LocalizedError, Equatable {
        public var errorDescription: String? { "a Word compile needs at least one body" }
    }

    public let projectURL: URL
    /// One body per rendered language, in order: one document, a page break
    /// between two.
    public let bodies: [BodyPlan.Body]
    public let config: PublishConfig
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String
    public let jobID: String?
    /// See `EPUBCompiler.language`.
    public let language: String?
    /// How this edition is NAMED — see `PDFCompiler.identity`.
    public let identity: String?
    /// See `PDFCompiler.replacesExistingOutput`.
    public let replacesExistingOutput: Bool
    /// The bodies the door's gate already resolved over `imageAllowed` — see
    /// `PDFCompiler.resolved`. Nil resolves here.
    public let resolved: [PublishProblemGate.Body]?

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
        precondition(resolved == nil || resolved?.count == bodies.count,
                     "resolved bodies must match bodies one for one")
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
        self.resolved = resolved
    }

    /// The single-body init, `EPUBCompiler`'s, for a source already bound to
    /// its language and a config already folded to it.
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
            bodies: [BodyPlan.Body(tag: tag, displayTag: tag ?? config.metadata.language,
                                   source: astSource, config: config)],
            config: config, jobManager: jobManager,
            maughamVersion: maughamVersion, tectonicVersion: tectonicVersion,
            jobID: jobID, language: language,
            replacesExistingOutput: replacesExistingOutput)
    }

    public func compile(label: String?) async throws -> Result {
        let publish = projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
        let build = publish.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        if let id = jobID { await jobManager.updatePhase(jobID: id, phase: .renderingBody) }

        // Each body's AST and its resolution over its whole book — the
        // door's gate usually made both already, so the document is emitted
        // with exactly what the gate judged.
        let bodiesResolved = try resolved ?? Self.resolve(bodies: bodies)
        var problems: [PublishProblem] = []
        var emitted: [DOCXBodyEmitter.Body] = []
        for (index, body) in bodies.enumerated() {
            let prepared = Self.prepare(resolution: bodiesResolved[index].resolution, publishDir: publish)
            problems += prepared.resolution.problems
            emitted.append(DOCXBodyEmitter.Body(
                ast: bodiesResolved[index].ast, resolution: prepared.resolution,
                bodyTag: index == 0 ? nil : body.displayTag,
                figureFiles: prepared.figureFiles))
        }
        // Document-level choices are the FIRST body's, as `EPUBCompiler`'s
        // metadata and `PDFCompiler`'s `metadata.tex` are.
        let first = bodies[0].config.metadata
        let document = DOCXBodyEmitter.emit(bodies: emitted, config: config,
                                            page: Self.page(forLanguage: first.language))
        try? document.documentXML.write(to: build.appendingPathComponent("document.xml"),
                                        atomically: true, encoding: .utf8)
        let (styles, styleWarning) = DOCXPackage.Styles.forCompile(publishDir: publish,
                                                                   language: first.language)
        if let id = jobID { await jobManager.updatePhase(jobID: id, phase: .compiling) }

        let filename = OutputFilenameBuilder.make(config: config, format: .docx, label: label,
                                                  language: identity)
        let exports = projectURL.appendingPathComponent(config.outputs.directory, isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let dest = exports.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            guard replacesExistingOutput else {
                let diag = OutputFilenameBuilder.occupiedDestinationRefusal(destination: dest,
                                                                            projectURL: projectURL)
                return Result(outputPath: "", warnings: [], errors: [diag], problems: problems)
            }
            try FileManager.default.removeItem(at: dest)
        }
        if let id = jobID { await jobManager.updatePhase(jobID: id, phase: .writingOutput) }
        try DOCXPackage.write(
            body: document, styles: styles,
            metadata: .init(title: first.title, author: first.author, created: Date()),
            customProperties: [], to: dest)
        return Result(outputPath: dest.path, warnings: styleWarning.map { [$0] } ?? [], errors: [],
                      problems: problems)
    }

    // MARK: - the page (R-S4)

    /// Letter when the region is the US or Canada, A4 otherwise (R-S4). The
    /// region is the book's language tag's (`en-US`, `fr-CA`, `en_us`); a tag
    /// that names none, or no tag, falls back to this Mac's region (R-S5), so
    /// an `en` book exported in Chicago is Letter and in London A4.
    /// `fallbackRegion` is injectable for tests.
    static func page(forLanguage tag: String,
                     fallbackRegion: String? = Locale.current.region?.identifier) -> DOCXPage {
        let subtags = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).dropFirst()
        let tagged = subtags.first { $0.count == 2 && $0.allSatisfy(\.isLetter) }.map(String.init)
        let region = (tagged ?? fallbackRegion)?.uppercased()
        return region == "US" || region == "CA" ? .letter : .a4
    }

    // MARK: - images

    /// The image formats a Word body may carry. Word embeds png, jpeg and gif
    /// natively; pdf and svg are rasterised to PNG when the DOCX is prepared
    /// (R-4-2), so a Report with PDF charts exports to Word.
    static let imageAllowed: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "svg"]

    /// Every body resolved for Word's images: the door's gate calls this and
    /// hands the answer to the compiler.
    static func resolve(bodies: [BodyPlan.Body]) throws -> [PublishProblemGate.Body] {
        try PublishProblemGate.resolve(bodies: bodies, imageAllowed: imageAllowed)
    }

    /// One body's resolution and the files its figures embed.
    struct PreparedBody {
        var resolution: PublishResolution
        /// pieceID → node index → a PNG, JPEG or GIF file:
        /// `DOCXBodyEmitter.Body.figureFiles`.
        var figureFiles: [String: [Int: URL]]
    }

    /// The resolution of what this compile rasterises at: 200 dpi, unless
    /// that would make the longer side more than `rasterMaxPixels`.
    static let rasterDPI = 200.0
    static let rasterMaxPixels = 6_000.0

    /// Stages the figures of a resolution already made — the gate's (R-S3).
    /// Each image is sniffed first (`FigureImageResolver.openingProblem`). A
    /// PNG, JPEG or GIF is handed on as it is. A PDF's first page and an SVG
    /// are drawn to a PNG in `build/docx-media/<hash>.png` — `build/` is
    /// never snapshotted — carrying their DPI, so the emitter sizes the
    /// drawing at the figure's natural size. A figure that can't be read or
    /// drawn is an `imageUnreadable` problem (`stagingFailed`) and prints its
    /// literal, so no relationship ever points at a file that isn't there.
    static func prepare(resolution: PublishResolution, publishDir: URL) -> PreparedBody {
        var resolution = resolution
        var figureFiles: [String: [Int: URL]] = [:]
        let media = publishDir.appendingPathComponent("build/docx-media", isDirectory: true)
        for (piece, files) in resolution.figureFiles.sorted(by: { $0.key < $1.key }) {
            for (index, source) in files.sorted(by: { $0.key < $1.key }) {
                let ext = source.pathExtension.lowercased()
                if let problem = FigureImageResolver.openingProblem(of: source) {
                    resolution.stagingFailed(pieceID: piece, nodeIndex: index, because: problem)
                    continue
                }
                guard DOCXImageGeometry.rasterised.contains(ext) else {
                    guard DOCXPackage.imageType(ext) != nil else {
                        resolution.stagingFailed(pieceID: piece, nodeIndex: index,
                                                 because: "is a .\(ext) file, which Word can't show")
                        continue
                    }
                    figureFiles[piece, default: [:]][index] = source
                    continue
                }
                do {
                    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
                    let png = media.appendingPathComponent(
                        try FigureImageResolver.contentHash(of: source) + ".png")
                    if !FileManager.default.fileExists(atPath: png.path) {
                        // Drawn beside it and moved in whole, so a concurrent
                        // compile never reads half a PNG.
                        let partial = media.appendingPathComponent(UUID().uuidString + ".partial.png")
                        defer { try? FileManager.default.removeItem(at: partial) }
                        try rasterise(source, to: partial)
                        if !FileManager.default.fileExists(atPath: png.path) {
                            try? FileManager.default.moveItem(at: partial, to: png)
                        }
                    }
                    // The move can lose a race or fail outright: never hand the
                    // emitter a file that isn't there.
                    guard FileManager.default.fileExists(atPath: png.path) else {
                        resolution.stagingFailed(pieceID: piece, nodeIndex: index,
                                                 because: "couldn't be prepared for Word (its PNG wasn't written)")
                        continue
                    }
                    figureFiles[piece, default: [:]][index] = png
                } catch let failure as RasterFailure {
                    resolution.stagingFailed(pieceID: piece, nodeIndex: index, because: failure.reason)
                } catch {
                    resolution.stagingFailed(
                        pieceID: piece, nodeIndex: index,
                        because: "couldn't be prepared for Word ("
                            + PublishProblem.withoutClosingStop(error.localizedDescription) + ")")
                }
            }
        }
        return PreparedBody(resolution: resolution, figureFiles: figureFiles)
    }

    /// Why a figure couldn't be drawn, as a fragment after its path.
    struct RasterFailure: Error, Equatable {
        let reason: String
    }

    /// Draws `source` (a PDF's first page, or an SVG) into a PNG at
    /// `destination`, on white. A PDF is drawn by `DOCXImageGeometry.pdfBox`,
    /// the box the emitter measures, its rotation applied. An SVG is drawn by
    /// AppKit (`NSImage`), which ImageIO can't; one AppKit can't draw is a
    /// `RasterFailure`.
    static func rasterise(_ source: URL, to destination: URL) throws {
        let image: CGImage
        let dpi: Double
        switch source.pathExtension.lowercased() {
        case "pdf":
            guard let document = CGPDFDocument(source as CFURL), // adr-0018-ok: research PDF drawn to a PNG for Word
                  let page = document.page(at: 1) else {
                throw RasterFailure(reason: "won't open as a PDF")
            }
            let box = page.getBoxRect(DOCXImageGeometry.pdfBox)
            let turned = abs(page.rotationAngle) % 180 == 90
            let size = turned ? CGSize(width: box.height, height: box.width) : box.size
            (image, dpi) = try draw(points: size) { context in
                context.concatenate(page.getDrawingTransform(
                    DOCXImageGeometry.pdfBox, rect: CGRect(origin: .zero, size: size),
                    rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(page)
            }
        case "svg":
            guard let svg = NSImage(contentsOf: source), // adr-0018-ok: research SVG drawn to a PNG for Word
                  !svg.representations.isEmpty, svg.size.width > 0, svg.size.height > 0 else {
                throw RasterFailure(reason: "is an SVG this Mac can't draw, so it can't go into a Word file")
            }
            (image, dpi) = try draw(points: svg.size) { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                svg.draw(in: CGRect(origin: .zero, size: svg.size))
                NSGraphicsContext.restoreGraphicsState()
            }
        default:
            throw RasterFailure(reason: "isn't a PDF or an SVG")
        }
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString,
                                                         1, nil) else {
            throw RasterFailure(reason: "couldn't be written as a PNG")
        }
        CGImageDestinationAddImage(sink, image, [kCGImagePropertyDPIWidth: dpi,
                                                 kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { throw RasterFailure(reason: "couldn't be written as a PNG") }
    }

    /// A white bitmap `points` large at `rasterDPI` (less for a huge page),
    /// scaled so `body` draws in points.
    private static func draw(points: CGSize, _ body: (CGContext) -> Void) throws -> (CGImage, Double) {
        guard points.width > 0, points.height > 0 else { throw RasterFailure(reason: "has no size to draw") }
        let dpi = min(rasterDPI, rasterMaxPixels * 72 / max(points.width, points.height))
        let pixels = (width: max(1, Int((points.width * dpi / 72).rounded())),
                      height: max(1, Int((points.height * dpi / 72).rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RasterFailure(reason: "couldn't be drawn (no bitmap)")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        context.scaleBy(x: CGFloat(pixels.width) / points.width, y: CGFloat(pixels.height) / points.height)
        body(context)
        guard let image = context.makeImage() else { throw RasterFailure(reason: "couldn't be drawn") }
        return (image, Double(pixels.width) * 72 / points.width)
    }

    // MARK: - TEMPORARY STUB (report plan 4 Task 2; Task 5 deletes it)

    /// The sentence the stub fails with. TEMPORARY — see `notYetBuiltStub`.
    static let notYetBuiltSentence = "Word export isn't built yet"

    /// **TEMPORARY, the one stub compile arm.** `Republisher` calls this in
    /// its `.docx` arm until Task 5 builds the republish; the whole-branch
    /// review checks that no caller and no definition remain. It writes
    /// nothing and returns a failed `Result` — no output path, the one error
    /// — carrying the gate's problems so they ride along as for any failed
    /// compile. Nothing is minted on the failure path.
    static func notYetBuiltStub(problems: [PublishProblem]) -> Result {
        Result(
            outputPath: "", warnings: [],
            errors: [TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: notYetBuiltSentence,
                contextLines: ["Nothing was compiled."])],
            problems: problems)
    }
}
