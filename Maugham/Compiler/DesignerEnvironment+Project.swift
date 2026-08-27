import Foundation
import MaughamCore
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit); mirrors `compilerLog` and
// `translatorLog`.
private let designerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Designer")

/// **The designer loop's production wiring: one project window's stores, as
/// the closures the round executes on.**
///
/// `TranslatorEnvironment+Project.swift`'s peer, and the same two disciplines
/// apply whole: **every capture weak**, because SwiftUI never dismantles a
/// closed window's view graph and an orchestrator that outlived one teardown
/// path while holding a `ProjectStore` strongly would keep the whole project in
/// memory with nothing on screen; and `detach()` is still what stops the
/// *session*, which no capture policy can do.
///
/// What is different is what a round PRODUCES. The translator writes words the
/// writer will publish; the designer writes nothing the writer has not first
/// stood at a gate and approved:
///
/// - **the proposal** goes to `DesignProposalStore`, under `.maugham/design/` —
///   derived, superseding whatever was pending, and never the live
///   `.maugham/publish/` tree, which Task 8's promotion is the only thing that
///   writes;
/// - **the sample** goes through `SampleCompiler`, which assembles a scratch
///   copy of the publish tree with the proposal laid on top and previews it. A
///   compile that fails is recorded ON the proposal and ends the round *clean*
///   (spec §6): the gate shows the spec beside the tectonic error, because a
///   design round whose sample would not compile is exactly the round the
///   writer needs to see;
/// - **the designer** is `ProjectStore.designerRole()`, which is a READ by
///   construction. There is no identity closure on `Environment` and nothing
///   here mints one: the preset lives in the merge
///   (`ProjectManifest.effectiveProductionRoles`), not on disk, and a gather
///   that stamped a row into the manifest would shift `modified` and reshuffle
///   the project wall because somebody asked who the designer was.
///   `DesignerEnvironmentTests.test_gatheringTheBriefingMintsNoDesigner` pins
///   it bytes-unchanged.
extension DesignerOrchestrator.Environment {

    /// Why a closure could not do its job at all. Distinct from a *refusal*
    /// (`briefRound` answering nil) — that is an answer; this is the window
    /// having gone away underneath the round.
    enum WiringFailure: Error, LocalizedError {
        case windowClosed

        var errorDescription: String? {
            "the project window closed before this design round could be staged"
        }
    }

    /// - Parameters:
    ///   - preferences: read at every spawn, never captured as a value, so a
    ///     session already warm when the writer turns Claude off does not
    ///     answer one more round. `nil` means refuse — the safe direction.
    ///   - onRunEnded: where a finished round is recorded. P4's desk is the
    ///     stated destination; until it exists `ProjectWindow` logs.
    ///
    /// **No `documentStore` parameter, unlike the translator's.** Nothing here
    /// resolves a document: what the round is about is the whole book, and the
    /// one path that needs the live text of an open doc —
    /// `ProjectStoreASTSource` — reaches it through `ProjectStore.documentStore`
    /// itself. A second capture of the same object would be one more strong
    /// reference to get wrong.
    @MainActor
    static func production(
        store: ProjectStore,
        projectURL: URL,
        preferences: UserPreferences,
        model: String = CompilerOrchestrator.defaultModel,
        onRunEnded: @escaping @MainActor (DesignerOrchestrator.RunSummary) -> Void
    ) -> DesignerOrchestrator.Environment {
        DesignerOrchestrator.Environment(
            projectId: ProjectIdentifier.id(for: projectURL),
            // The compiler's setting, so a writer who chose a deeper model for
            // their checks gets it for their design too. Kept current
            // afterwards by `DesignerOrchestrator.updateModel(_:)`, which the
            // gear menu calls beside the compiler's rather than re-running this.
            model: model,
            briefRound: { [weak store] direction, language in
                guard let store else { return nil }
                return await briefing(
                    direction: direction, language: language,
                    store: store, projectURL: projectURL)
            },
            writeMCPConfig: {
                try ClaudeCLISession.writeMCPConfig(
                    bridgeBinary: ClaudeCLISession.bridgeBinary,
                    socketPath: BuildVariant.current.mcpSocketPath,
                    to: ClaudeCLISession.sessionConfigDirectory)
            },
            makeRunner: { configURL, model in
                ClaudeCLISession(
                    model: model,
                    mcpConfigPath: configURL,
                    cliOverride: nil,
                    isEnabled: { [weak preferences] in preferences?.mcpEnabled ?? false })
            },
            stage: { [weak store] report, context in
                guard let store else {
                    return .init(rejection: WiringFailure.windowClosed.localizedDescription)
                }
                return await stage(
                    report, context: context, store: store, projectURL: projectURL)
            },
            onRunEnded: onRunEnded)
    }

    // MARK: - The briefing

    /// Everything one round needs, gathered from the project.
    ///
    /// **`nil` is "not a run"** — the orchestrator's own escape hatch, used
    /// here for the two things that make a design round meaningless rather than
    /// merely thin:
    ///
    /// - **no live publish tree.** The designer's job is to revise a template
    ///   set; a project that has never run `initialize_publish_template` has
    ///   none to revise, and the sample compile would fail at the copy
    ///   (`SampleCompiler.Error.noLivePublishTree`) for the same reason. A whole
    ///   session to discover that is worse than a refused click.
    /// - **no book.** An AST that will not build, or one with no pieces in it,
    ///   leaves nothing for the census to find and nothing for the sample to
    ///   show — `SamplePageSelection` would return an empty selection and
    ///   `SampleCompiler` refuses one outright, so the round could only ever
    ///   end pageless.
    ///
    /// Everything else that is absent is briefed as absent rather than refused:
    /// no visual language declared, no edition brief, no direction from the
    /// writer, no config on disk. `DesignerBriefing` says so in words — the
    /// designer working from nothing is told that outright.
    ///
    /// **One AST, one edition.** The census, the selection and (later) the
    /// sample are all taken from `ProjectStoreASTSource` at the round's own
    /// `language`, so what the designer is told the book contains is what the
    /// sample pages will actually render. For a language round that means the
    /// translated text where it exists and the source text where it does not —
    /// `ProjectStoreASTSource`'s own per-paragraph fallback, which is the
    /// `allow_stale` posture and the right one for a preview that mutates
    /// nothing (spec §6: sample compiles fail like previews, not publishes).
    @MainActor
    private static func briefing(
        direction: String?, language: String?, store: ProjectStore, projectURL: URL
    ) async -> DesignerBriefing.Inputs? {
        guard PublishStarter.isInitialized(in: projectURL) else {
            designerLog.error(
                "a design round was asked for a project with no publish templates to revise")
            return nil
        }
        guard let ast = try? ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: store, language: language)),
              !ast.sections.isEmpty
        else {
            designerLog.error("a design round found no book to design for")
            return nil
        }

        let census = ElementCensus.take(from: ast)
        // A read: `designerRole()` answers with the preset and never writes it
        // back. Its `effectiveName` is the ONE spelling of who signs this
        // round — `DesignerOrchestrator.StageContext` carries it from here to
        // the staging rather than resolving it a second time.
        let designer = store.designerRole()
        let loaded = try? await PublishConfigStore(projectURL: projectURL).load()

        return DesignerBriefing.Inputs(
            designerName: designer.effectiveName,
            roleBrief: designer.effectiveBrief,
            visualLanguageText: visualLanguageText(store: store),
            census: census,
            selection: SamplePageSelection.choose(census: census, ast: ast),
            templateFiles: liveTemplateFiles(in: projectURL),
            // A project whose `config.json` is missing or unreadable is briefed
            // on the defaults rather than refused: the summary is three lines
            // about formats and covers, and none of them is worth losing a
            // round over.
            config: loaded.flatMap { $0 } ?? PublishConfig(),
            language: language,
            editionBriefText: language.flatMap { editionBriefText(language: $0, store: store) },
            direction: direction)
    }

    /// The writer's declared look for the book, whole — `read_visual_language`'s
    /// own text, through the same `statementText(of:)`, so what the round is
    /// briefed on and what Claude can read on demand cannot disagree. Project
    /// scope only: the book has one look (spec §3.2).
    ///
    /// Absence is valid and mints nothing (M1A's rule) — `DesignerBriefing`
    /// says "no visual language declared; ask before assuming" rather than
    /// inventing one. RULING-54: an unreadable statement reads as absent here,
    /// and the Visual Language pane's editor owns surfacing the refusal.
    @MainActor
    private static func visualLanguageText(store: ProjectStore) -> String? {
        guard let statement = store.statement(kind: .visualLanguage, scope: .project)
        else { return nil }
        return try? store.statementText(of: statement)
    }

    /// This edition's doctrine, verbatim — the same statement the translator's
    /// loop is briefed on and `read_edition_brief` returns. Project scope: an
    /// edition's register applies to the book.
    @MainActor
    private static func editionBriefText(language: String, store: ProjectStore) -> String? {
        guard let statement = store.statement(
            kind: .editionBrief(language), scope: .project) else { return nil }
        return try? store.statementText(of: statement)
    }

    // MARK: - The live templates

    /// Everything currently under `.maugham/publish/` that a proposal could
    /// legitimately revise, as `(relative path, contents)`.
    ///
    /// **Two exclusions, and each is a rule rather than a taste.** `build/` is
    /// written by the compile that is about to run — `body.tex`, the log, the
    /// output PDF — so it is output, not design. `config.json` is compile
    /// configuration: `DesignerReport` refuses it at parse, so embedding it
    /// would show the designer the one file it is structurally forbidden to
    /// propose, and `DesignerBriefing.configSummarySection` already states the
    /// design-relevant slice of it in three lines.
    ///
    /// A file that will not decode as UTF-8 is skipped rather than mangled —
    /// that is how a bundled font or a cover image stays out — and so is one
    /// past `maximumTemplateFileBytes`, which is a read ceiling rather than a
    /// briefing one: `DesignerBriefing.templateFileCharacterCap` does the
    /// eliding, with an elision note naming what was cut, and there is no
    /// reason to pull a megabyte off disk to throw away all but 4,000
    /// characters of it.
    private static func liveTemplateFiles(
        in projectURL: URL
    ) -> [DesignerBriefing.Inputs.TemplateFile] {
        let root = projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [])
        else { return [] }

        let rootPath = root.standardizedFileURL.path + "/"
        var files: [DesignerBriefing.Inputs.TemplateFile] = []
        while let item = walker.nextObject() as? URL {
            // Dotfiles by name, never by the `hidden` flag (`DotfileScan`).
            if DotfileScan.isDotfile(item) {
                walker.skipDescendants()
                continue
            }
            let absolute = item.standardizedFileURL.path
            guard absolute.hasPrefix(rootPath) else { continue }
            let relative = String(absolute.dropFirst(rootPath.count))
            if relative == Self.compilerOutputDirectoryName {
                walker.skipDescendants()
                continue
            }
            guard item.lastPathComponent != DesignerReport.reservedConfigFilename else { continue }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? 0) <= maximumTemplateFileBytes,
                  let content = try? String(contentsOf: item, encoding: .utf8)  // adr-0018-ok: a publish template, not manuscript content
            else { continue }
            files.append(.init(path: relative, content: content))
        }
        // Deterministic, so two rounds over an unchanged tree brief identically
        // — directory enumeration order is not.
        return files.sorted { $0.path < $1.path }
    }

    /// `PDFCompiler`/`EPUBCompiler` write everything they produce under this
    /// directory of the publish tree. `SampleCompiler` spells it too, and for
    /// the same reason — a shared constant would have to live on one of them
    /// and be reached for by the other across an area boundary.
    private static let compilerOutputDirectoryName = "build"

    /// The ceiling on one template file's read. Generous next to the starter's
    /// largest file (EMISSION.md, ~16 KB) and small enough that a font or a
    /// stray PDF never reaches the decoder.
    private static let maximumTemplateFileBytes = 512 * 1024

    // MARK: - Staging

    /// **Where a round's proposal actually lands**, and the only writing this
    /// loop does.
    ///
    /// The order is the writer's: the proposal is staged FIRST and the sample
    /// compiled second, because a proposal exists and is reviewable — spec in
    /// words, files on disk — before its pages have been typeset. That is also
    /// why a sample failure is not a rejection: `rejection` means *nothing was
    /// staged*, and the orchestrator turns it into a failed round that closes
    /// the writer's ability to ask for changes. A proposal whose pages would
    /// not compile is one the writer must still be able to read, reject, or
    /// send back (spec §6).
    @MainActor
    private static func stage(
        _ report: DesignerReport,
        context: DesignerOrchestrator.StageContext,
        store: ProjectStore,
        projectURL: URL
    ) async -> DesignerOrchestrator.StageOutcome {
        let proposal: DesignProposalStore.Proposal
        do {
            proposal = try DesignProposalStore(projectURL: projectURL).stage(
                report: report, round: context.round,
                designerName: context.designerName,
                // The round's own edition, written down beside its round number
                // (P4 Task 5). It rode this context in from the first round and
                // was dropped here; the gate needs it for Constraint 3's
                // base-templates caveat, and nothing downstream can infer it —
                // an edition round proposes the book's own template set.
                language: context.language)
        } catch {
            // The one thing the writer must act on: the design is still there
            // to be re-run, and the sentence says what refused it.
            return .init(
                rejection: "the design proposal could not be staged: "
                    + error.localizedDescription)
        }

        // **The project is told, at the moment something on disk moved.**
        // A fresh stage SUPERSEDES whatever pending proposal preceded it
        // (`DesignProposalStore.stage`'s one-slot rule), so a writer sitting at
        // the gate on round 2 while round 3 stages is looking at a record that
        // is no longer what the store holds — the verbs it offers would act on
        // a superseded proposal. Nothing else here would tell them: staging
        // touches neither the manifest nor a run's own state, which is exactly
        // why the desk grew this receiver for the gate's verbs (Task 6). The
        // failure path above deliberately posts nothing — a refused stage moved
        // no byte, and news of nothing is a re-read every window pays for.
        MaughamEvent.postDesignProposalsChanged(projectURL: projectURL)

        return .init(
            proposalId: proposal.id,
            filesStaged: proposal.filePaths.count,
            sample: await sample(for: proposal, context: context,
                                 store: store, projectURL: projectURL))
    }

    /// The sample compile, and what it left on the proposal.
    ///
    /// **The selection is recomputed here rather than carried from the
    /// briefing**, and the gap is the reason: a whole model turn separates the
    /// two, and the writer has been writing through it. `SampleCompiler` renders
    /// the book as it stands *now*, so a piece list derived from the AST as it
    /// stood *then* would choose pages against text that has moved. Both
    /// derivations are pure over the same source, so an unchanged book gives the
    /// same answer.
    ///
    /// **An AST that will not build hands `SampleCompiler` an empty selection
    /// on purpose.** That type already refuses one with its own sentence — an
    /// empty allowlist means "every piece" to `PreviewCompiler`, which would
    /// silently compile the whole book and call it a sample — so routing the
    /// case through it keeps one spelling of the refusal instead of two.
    @MainActor
    private static func sample(
        for proposal: DesignProposalStore.Proposal,
        context: DesignerOrchestrator.StageContext,
        store: ProjectStore,
        projectURL: URL
    ) async -> DesignProposalStore.SampleResult? {
        let astSource = ProjectStoreASTSource(projectStore: store, language: context.language)
        let ast = try? ProjectASTBuilder.build(from: astSource)
        let selection = ast.map {
            SamplePageSelection.choose(census: ElementCensus.take(from: $0), ast: $0)
        } ?? SamplePageSelection.Selection(
            pieceIds: [], maxPages: SamplePageSelection.maxPages, demonstrates: [])

        do {
            return SampleCompiler.sampleResult(
                try await SampleCompiler.compile(
                    proposal: proposal,
                    selection: selection,
                    projectURL: projectURL,
                    astSource: astSource,
                    // The project's ONE job manager — the same one a real
                    // compile and a preview contend on, so a sample in flight
                    // is visible to `compile_status` rather than running in a
                    // manager nothing can see.
                    jobManager: PublishingStores.sharedFor(
                        projectID: ProjectIdentifier.id(for: projectURL),
                        projectURL: projectURL).jobManager,
                    maughamVersion: maughamVersion,
                    tectonicVersion: bundledTectonicVersion))
        } catch {
            // `SampleCompiler.compile` throws for one thing only: it could not
            // RECORD the outcome on the proposal. The proposal itself is staged
            // and reviewable, so this is a missing sample rather than a failed
            // round — `nil` says "not sampled", which is what happened.
            designerLog.error(
                "a design proposal's sample result could not be recorded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The running build's version, as every other compile site reads it.
    private static var maughamVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The bundled tectonic's version, spelled as `CompileTools` and
    /// `PublicationTools` spell it. A literal in four places rather than three
    /// is not an improvement, but promoting it to a constant is a publish-area
    /// change with publish-area tests behind it, and this task is the wiring.
    private static let bundledTectonicVersion = "0.15.0"
}
