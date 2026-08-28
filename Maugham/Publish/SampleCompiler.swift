import Foundation

/// Compiles a design proposal's sample pages — the writer's look at what a
/// round actually proposes — against a SCRATCH copy of the publish tree with
/// the proposal's staged files laid on top.
///
/// **Nothing live moves.** The live `.maugham/publish/` tree is the book's
/// shipping design and stays untouched until the writer approves (Task 8's
/// promotion is the only thing that writes it). So a sample compile:
///
/// 1. copies the live publish tree into `.maugham/design/proposals/<id>/scratch/`,
/// 2. lays the proposal's `files/` on top — **real files, copied; never
///    symlinks**, because a symlinked overlay makes the compiler's every
///    intermediate write reach back through the link, and a symlinked *tree*
///    reaches the live templates,
/// 3. runs `PreviewCompiler` with `projectURL:` pointed at that scratch, so
///    every path the compiler derives — `build/`, the preview output
///    directory, even the EMISSION.md refresh — lands inside it,
/// 4. and records the outcome on the proposal.
///
/// `test_assemble_leavesTheLivePublishTreeUntouched` is the guard; it is a
/// pure file-system test on purpose, so the branch's load-bearing guarantee
/// is never skipped because a TeX bundle could not be fetched.
///
/// **There is no `configStore` parameter.** The only config a sample compile
/// may read is the scratch's own copy, so this type constructs one against the
/// scratch it just assembled; a caller-supplied store would necessarily read
/// the live directory, which is the one thing this type exists to avoid.
/// (Nothing is lost: `DesignerReport` refuses `config.json` at parse, so a
/// proposal can never change what that copy says.)
///
/// **A sample sets the EDITION's text.** A round briefed on a language is
/// handed a source already bound to it, and `language:` must be threaded
/// through to `PreviewCompiler` as well — since P2 the preview builds its
/// bodies through `BodyPlan`, which rebinds even a single body, so a preview
/// asked for no language rebinds a pre-bound source back to the source text
/// and the gate shows English under a caveat promising the edition
/// (`DesignGateView.caveat`). The two must agree, and the argument is what
/// makes them.
///
/// **A sample is always `allowStale`.** That is this type's own contract, not
/// the compile door's: a design round is about typesetting, and the writer is
/// looking at what the edition IS right now rather than being refused a look at
/// their templates because a paragraph went untranslated this morning. (The
/// gate's zero-layer guard still refuses unconditionally; an edition with no
/// translation records at all has no text to set.)
///
/// **So a sample has to SAY when the book's own text stood in.** `allowStale`
/// turns every gap into a warning instead of a refusal, and pages that look
/// clean while half their prose is the wrong language are worse than a refusal.
/// `Outcome.pages` therefore carries the preview's `warnings` whole, and
/// `sampleResult(_:)` counts the source-text fallbacks among them
/// (`TranslationCoverage.isSourceTextFallback`) onto the record the gate reads
/// — `DesignGate.fallbackNotice`, one sentence beside the edition caveat.
/// The count is what is persisted rather than the diagnostics: the gate needs
/// the fact and its size, and the writer's own `compile_status` is where a
/// warning's full text belongs.
///
/// **Failure is a value, not an error.** A tectonic failure, a project with no
/// publish tree, a staged path that escapes the scratch — each rides out on
/// `Outcome.failed` with its cause (RULING-7's shape), because a design round
/// whose sample would not compile is a round the writer still needs to see.
/// The one thing `compile` throws for is failing to RECORD the outcome: that
/// is a disk refusal about the proposal itself, and swallowing it would leave
/// the desk showing a proposal that was never sampled.
@MainActor
enum SampleCompiler {

    /// What a sample compile produced: the pages, or why there are none.
    enum Outcome: Equatable {
        /// An absolute path to the sample PDF, the selection's writer-facing
        /// "this piece is here because…" lines, and every warning the preview
        /// rode out on — a sample is `allowStale`, so its source-text
        /// fallbacks arrive here and nowhere else.
        case pages(path: String, demonstrates: [String],
                   warnings: [TectonicLogParser.Diagnostic])
        /// The compiler's own diagnostics, kept whole. `logExcerpt` matters
        /// independently of `errors`: an empty `errors` array with a failed
        /// compile is the tectonic bundle fetch, and the excerpt is the only
        /// place that says so.
        case failed(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
    }

    // MARK: - the compile

    static func compile(
        proposal: DesignProposalStore.Proposal,
        selection: SamplePageSelection.Selection,
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        language: String?,
        jobManager: CompileJobManager,
        maughamVersion: String,
        tectonicVersion: String
    ) async throws -> Outcome {
        let outcome = await run(
            proposal: proposal, selection: selection, projectURL: projectURL,
            astSource: astSource, language: language, jobManager: jobManager,
            maughamVersion: maughamVersion, tectonicVersion: tectonicVersion)
        try DesignProposalStore(projectURL: projectURL)
            .recordSampleResult(id: proposal.id, sampleResult(outcome))
        return outcome
    }

    private static func run(
        proposal: DesignProposalStore.Proposal,
        selection: SamplePageSelection.Selection,
        projectURL: URL,
        astSource: ProjectASTBuilder.Source,
        language: String?,
        jobManager: CompileJobManager,
        maughamVersion: String,
        tectonicVersion: String
    ) async -> Outcome {
        // An empty selection must never reach `PreviewCompiler`: an empty
        // `sectionIDs` allowlist means "every piece" there (see
        // `FilteredASTSource`), so falling through would silently compile the
        // whole book and call it a sample.
        guard !selection.pieceIds.isEmpty else {
            return .failed(errors: [diagnostic(
                "no sample pages to compile — the selection names no pieces.",
                context: ["A sample is chosen from the book's element census; "
                          + "an empty book has nothing to demonstrate."])],
                logExcerpt: "empty_sample_selection")
        }

        let scratch: URL
        do {
            scratch = try assembleScratch(proposal: proposal, projectURL: projectURL)
        } catch {
            return .failed(
                errors: [diagnostic("the sample could not be staged: \(error)")],
                logExcerpt: "scratch_assembly_failed")
        }

        do {
            let result = try await PreviewCompiler(
                projectURL: scratch,
                astSource: astSource,
                configStore: PublishConfigStore(projectURL: scratch),
                jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion,
                // The edition this round is for, and the sample's own
                // allow-stale contract — see the type's own note.
                language: language,
                allowStale: true
            ).preview(
                format: .pdf, sectionIDs: selection.pieceIds,
                maxPages: selection.maxPages)

            guard result.errors.isEmpty, !result.outputPath.isEmpty else {
                return .failed(errors: result.errors, logExcerpt: result.logExcerpt)
            }
            return .pages(path: result.outputPath,
                          demonstrates: selection.demonstrates,
                          warnings: result.warnings)
        } catch {
            return .failed(
                errors: [diagnostic("the sample compile could not run: \(error)")],
                logExcerpt: "sample_compile_threw")
        }
    }

    // MARK: - the scratch

    /// Where a proposal's sample is compiled. Under the proposal's own folder
    /// rather than a temp directory so the pages survive the session that made
    /// them — the desk shows this PDF beside the proposal it belongs to — and
    /// so deleting `.maugham/design/` still costs nothing but derived things.
    static func scratchURL(
        proposal: DesignProposalStore.Proposal, projectURL: URL
    ) -> URL {
        DesignProposalStore(projectURL: projectURL)
            .proposalDir(id: proposal.id)
            .appendingPathComponent("scratch", isDirectory: true)
    }

    /// The compile's first half, separately callable so the copy/overlay
    /// contract can be pinned without a real LaTeX run: builds the scratch
    /// project and returns its root (the directory to hand `PreviewCompiler`
    /// as `projectURL`).
    ///
    /// Rebuilt from the live tree every time — never accumulated — so a file
    /// the designer has since dropped cannot haunt a later round's sample.
    @discardableResult
    static func assembleScratch(
        proposal: DesignProposalStore.Proposal, projectURL: URL
    ) throws -> URL {
        let fm = FileManager.default
        let livePublish = projectURL.appendingPathComponent(
            ".maugham/publish", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: livePublish.path, isDirectory: &isDir), isDir.boolValue
        else { throw Error.noLivePublishTree(projectURL.path) }

        let scratch = scratchURL(proposal: proposal, projectURL: projectURL)
        if fm.fileExists(atPath: scratch.path) {
            try fm.removeItem(at: scratch)
        }
        let scratchPublish = scratch.appendingPathComponent(
            ".maugham/publish", isDirectory: true)
        try fm.createDirectory(at: scratchPublish, withIntermediateDirectories: true)

        // The copy, minus `build/`: everything under it is written by the
        // compile that is about to run (`body.tex`, `metadata.tex`, the log,
        // the output PDF), so copying it would duplicate every prior artifact
        // into every proposal and change nothing about what the compiler reads.
        for item in try fm.contentsOfDirectory(
            at: livePublish, includingPropertiesForKeys: nil, options: [])
        where item.lastPathComponent != Self.compilerOutputDirectoryName {
            try fm.copyItem(
                at: item, to: scratchPublish.appendingPathComponent(item.lastPathComponent))
        }

        // The overlay: staged files on top, each one a real copy.
        let filesDir = DesignProposalStore(projectURL: projectURL)
            .proposalDir(id: proposal.id)
            .appendingPathComponent("files", isDirectory: true)
        let root = scratchPublish.standardizedFileURL.path
        for relativePath in proposal.filePaths {
            let dest = scratchPublish.appendingPathComponent(relativePath).standardizedFileURL
            // Defence in depth behind `DesignerReport`'s parse-time guard:
            // `proposal.json` is a file on disk, and this is the one place a
            // path that escaped it would write into the live templates.
            guard dest.path.hasPrefix(root + "/") else {
                throw Error.stagedPathEscapesTheScratch(relativePath)
            }
            let source = filesDir.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: source.path) else {
                throw Error.stagedFileMissing(relativePath)
            }
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
        }

        return scratch
    }

    /// `PDFCompiler`/`EPUBCompiler` write everything they produce under this
    /// directory of the publish tree.
    private static let compilerOutputDirectoryName = "build"

    // MARK: - errors

    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case noLivePublishTree(String)
        case stagedPathEscapesTheScratch(String)
        case stagedFileMissing(String)

        var description: String {
            switch self {
            case .noLivePublishTree(let path):
                return "no .maugham/publish templates to sample in \(path) — "
                    + "run initialize_publish_template first."
            case .stagedPathEscapesTheScratch(let path):
                return "the staged path \(path) points outside the sample's "
                    + "own directory and was refused."
            case .stagedFileMissing(let path):
                return "the proposal lists \(path) but nothing was staged at "
                    + "that path."
            }
        }
    }

    // MARK: - recording

    /// The outcome as the proposal records it. A failure keeps its cause: the
    /// desk shows it beside the proposal, and a proposal with no sample and no
    /// reason is indistinguishable from one that was never compiled.
    ///
    /// **The pages keep their `demonstrates` lines too** (P4 Task 5). This
    /// function used to drop them, which meant the selection's account of
    /// *why these pages* existed only inside the call that computed it — and
    /// the gate cannot rebuild it, because the selection is a function of the
    /// AST at the round and the writer keeps writing.
    static func sampleResult(_ outcome: Outcome) -> DesignProposalStore.SampleResult {
        switch outcome {
        case .pages(let path, let demonstrates, let warnings):
            return .pages(
                path: path, demonstrates: demonstrates,
                fallbackPieces: warnings.filter(
                    TranslationCoverage.isSourceTextFallback).count)
        case .failed:
            return .failed(error: failureSentence(outcome))
        }
    }

    /// One writer-facing sentence for a failed outcome — never empty, even
    /// when tectonic reported nothing parseable (that IS the diagnosis: an
    /// empty `errors` array with a failed compile is the TeX bundle fetch, and
    /// only the log excerpt says so).
    static func failureSentence(_ outcome: Outcome) -> String {
        guard case .failed(let errors, let logExcerpt) = outcome else { return "" }
        if !errors.isEmpty {
            return errors.map(\.message).joined(separator: "; ")
        }
        let tail = logTail(logExcerpt)
        guard !tail.isEmpty else {
            return "the sample compile produced no pages and no diagnostics."
        }
        return "the sample compile produced no pages and no LaTeX error, which "
            + "usually means typesetting never began. Log tail: " + tail
    }

    /// The TAIL. The head of a cold tectonic log is thousands of characters of
    /// `note: downloading …`, which is what made run 31874029028 undiagnosable
    /// from its own artifact.
    private static func logTail(_ log: String, limit: Int = 1200) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    private static func diagnostic(
        _ message: String, context: [String] = []
    ) -> TectonicLogParser.Diagnostic {
        .init(level: .error, file: nil, line: nil,
              message: message, contextLines: context)
    }
}
