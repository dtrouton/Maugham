import Foundation

@MainActor
public struct PreviewCompiler {

    /// The deterministic preview output directory where previews are rendered.
    /// Kept in sync with `ReadPreviewPageTool.previewSubpath` — the single
    /// source of truth for preview output paths.
    public static let previewSubpath = ".maugham/publish/build/preview"

    /// The one sentence a Word preview is refused with (report plan 4,
    /// R-4-5): the preview shows the book as a PDF or EPUB, and a Word file is
    /// read in Word.
    nonisolated static let docxPreviewRefusalSentence =
        "Preview shows PDF and EPUB; Word files open in Word."

    /// The log excerpt prefix of a known format the preview does not render
    /// — distinct from `CompileOrchestrator.unproducibleFormatLogExcerpt`,
    /// which names a format this build cannot produce at all.
    nonisolated static let unpreviewableFormatLogExcerpt = "unpreviewable_format: "

    /// **Does the preview render `format`?** `nil` for PDF and EPUB; for a
    /// format this build produces but the preview does not show, the
    /// sentence. An unknown format is `PublishConfigValidator.formatError`'s
    /// question, asked first, so it answers `nil` here. `preview_compile`'s
    /// schema enum is `allCases` less every format this refuses.
    nonisolated static func previewRefusal(_ format: PublishConfig.Format) -> String? {
        switch format {
        case .pdf, .epub, .unknown: return nil
        case .docx:                 return docxPreviewRefusalSentence
        }
    }

    /// Thrown by the `run` switch's `.docx` arm — defence in depth behind
    /// `preview`'s door, which refuses first.
    struct UnpreviewableFormat: Error, LocalizedError {
        let format: PublishConfig.Format
        var errorDescription: String? { PreviewCompiler.previewRefusal(format) }
    }

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
        // Can this build produce the format at all
        // (`PublishConfigValidator.formatError`)? Asked before the job
        // registers — nothing has begun — and before the EMISSION.md refresh
        // and every format-dependent step in `run`.
        if let refusal = PublishConfigValidator.formatError(format) {
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: refusal.message,
                contextLines: ["No preview file was written."])
            return Result(outputPath: "", warnings: [], errors: [diag],
                          logExcerpt: CompileOrchestrator.unproducibleFormatLogExcerpt
                              + format.rawValue)
        }
        // A format this build produces but the preview does not render (Word)
        // is refused the same way, at the same point, in its own words.
        if let sentence = Self.previewRefusal(format) {
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: sentence,
                contextLines: ["No preview file was written."])
            return Result(outputPath: "", warnings: [], errors: [diag],
                          logExcerpt: Self.unpreviewableFormatLogExcerpt + format.rawValue)
        }
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
                return FilteredASTSource(base: base, sectionIDs: sectionIDs,
                                         editionExcludedSectionIDs: excludedSectionIDs)
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

        // Report foundations plan 2, Task 7: a preview never refuses on a
        // publish problem (R-P2-1), so there is no gate to pass before it —
        // but it resolves HERE, on the main actor, through the same door as
        // compile and republish (`PublishProblemGate.resolve`), and hands the
        // bodies down: the manuscript is read once (final review M4), and what
        // the warnings judge is what the preview emits. Its problems, staging
        // failures included, ride out as warnings.
        let problemContext = plan.first.source.resolutionScope.publishContext()
        func problemWarnings(_ problems: [PublishProblem]) -> [TectonicLogParser.Diagnostic] {
            PublishProblemGate.warnings(problems, context: problemContext)
        }

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, bodies: plan.bodies,
                config: effective, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID,
                language: set.singleTag,
                identity: set.identity,
                replacesExistingOutput: true,
                resolved: try PDFCompiler.resolve(bodies: plan.bodies))
            let r = try await pdf.compile(label: "preview")
            let warnings = gateWarnings + problemWarnings(r.problems) + r.warnings
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
                replacesExistingOutput: true,
                resolved: try EPUBCompiler.resolve(bodies: plan.bodies))
            let r = try await e.compile(label: "preview")
            let warnings = gateWarnings + problemWarnings(r.problems) + r.warnings
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: warnings, errors: r.errors)
        case .docx:
            // Defence in depth, unreachable from `preview`: its door refuses
            // Word (`previewRefusal`). A throw, never a precondition failure.
            throw UnpreviewableFormat(format: format)
        case .unknown(let raw):
            // Defence in depth, unreachable from `preview`: its first check
            // (`PublishConfigValidator.formatError`) refuses every unknown
            // format. Kept so the switch stays exhaustive with no `default:`;
            // a throw, never a precondition failure.
            throw PublishFormatRefusal(raw: raw)
        }
    }
}

/// **A preview's or a sample's narrowing** — the one wrapper that shows LESS
/// than the edition: keeps only the pieces named in `sectionIDs` (an allowlist;
/// nil/empty ⇒ all). An explicit `section_ids` may name a section the edition
/// excludes (a preview is for looking, not shipping), so this filters the
/// unfiltered base, never the edition.
///
/// Its `resolutionScope` is the EDITION's book (R-S15): the base less the
/// edition's own `excludedSectionIDs`, so a one-chapter preview numbers and
/// resolves exactly as the edition it previews, and a section the edition
/// leaves out is no more part of the preview's book than of the published one.
/// A section named here that the edition excludes is emitted unresolved: its
/// elements render as their literal source.
///
/// Reads its base ONCE (`ReadOnceSource`): the subset and the edition's book
/// are two views of one derivation, so a preview reads the manuscript once
/// and an edit landing mid-compile can't make the two disagree.
///
/// Forwards `publishContext()` (`PublishContextTests`). Internal, not private,
/// so that test can hold one.
struct FilteredASTSource: ProjectASTBuilder.Source {
    let base: ProjectASTBuilder.Source
    let sectionIDs: [String]?
    /// The edition this narrows: the same base, less what the edition excludes.
    let edition: IncludeFilteredASTSource

    /// - Parameter editionExcludedSectionIDs: the edition's own
    ///   `PublishConfig.excludedSectionIDs` — never optional, so no caller can
    ///   forget the edition and resolve over a book it doesn't publish.
    init(base: ProjectASTBuilder.Source, sectionIDs: [String]?,
         editionExcludedSectionIDs: Set<String>) {
        let once = ReadOnceSource(base: base)
        self.base = once
        self.sectionIDs = sectionIDs
        self.edition = IncludeFilteredASTSource(
            base: once, excludedSectionIDs: editionExcludedSectionIDs)
    }

    func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
        let all = try base.orderedPieces()
        guard let ids = sectionIDs, !ids.isEmpty else { return all }
        let set = Set(ids)
        return all.filter { set.contains($0.pieceID) }
    }
    func publishContext() -> PublishContext { base.publishContext() }
    var resolutionScope: ProjectASTBuilder.Source { edition.resolutionScope }
    /// True only when it narrows nothing AND the edition excludes nothing:
    /// otherwise what it emits is not the book it resolves.
    var isWholeBook: Bool {
        (sectionIDs?.isEmpty ?? true) && edition.excludedSectionIDs.isEmpty && base.isWholeBook
    }
}

/// **The edition's own book**: drops the pieces the EDITION excludes — the
/// writer's `include: false` and an imprint's dropped sections, together
/// `PublishConfig.excludedSectionIDs` (a denylist). Every door wraps its body
/// with one (`CompileOrchestrator`, `Republisher`, and a default preview), so
/// the emitters and every downstream record see only the included pieces.
///
/// It IS the book it publishes (R-S15): its `resolutionScope` is itself and it
/// is whole whenever its base is. An excluded draft chapter therefore neither
/// blocks a Report's compile, nor takes a figure number, nor puts a source in
/// References, and a reference from an included chapter into it is unresolved.
/// An empty excluded set is a pass-through.
struct IncludeFilteredASTSource: ProjectASTBuilder.Source {
    let base: ProjectASTBuilder.Source
    let excludedSectionIDs: Set<String>
    func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
        let all = try base.orderedPieces()
        guard !excludedSectionIDs.isEmpty else { return all }
        return all.filter { !excludedSectionIDs.contains($0.pieceID) }
    }
    func publishContext() -> PublishContext { base.publishContext() }
    /// Itself, over a whole base. Over a base that is itself a view (no door
    /// builds one), the edition of that base's book.
    var resolutionScope: ProjectASTBuilder.Source {
        base.isWholeBook
            ? self
            : IncludeFilteredASTSource(base: base.resolutionScope,
                                       excludedSectionIDs: excludedSectionIDs)
    }
    var isWholeBook: Bool { base.isWholeBook }
}

/// A source read at most once: its first `orderedPieces()` answer (or throw)
/// is the answer for its lifetime, which is one compile's. `FilteredASTSource`
/// builds one so its subset and its edition's book share one derivation.
/// Transparent otherwise: context, scope and wholeness are the base's.
final class ReadOnceSource: ProjectASTBuilder.Source {
    let base: ProjectASTBuilder.Source
    private var memo: Result<[ProjectASTBuilder.PieceRef], Error>?

    init(base: ProjectASTBuilder.Source) { self.base = base }

    func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
        if let memo { return try memo.get() }
        let read = Result { try base.orderedPieces() }
        memo = read
        return try read.get()
    }
    func publishContext() -> PublishContext { base.publishContext() }
    var resolutionScope: ProjectASTBuilder.Source { base.isWholeBook ? self : base.resolutionScope }
    var isWholeBook: Bool { base.isWholeBook }
}
