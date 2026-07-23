import Foundation

public struct PreviewCompiler {

    public struct Result {
        public let outputPath: String
        public let warnings: [TectonicLogParser.Diagnostic]
        public let errors:   [TectonicLogParser.Diagnostic]
    }

    public let projectURL: URL
    public let astSource: ProjectASTBuilder.Source
    public let configStore: PublishConfigStore
    public let jobManager: CompileJobManager
    public let maughamVersion: String
    public let tectonicVersion: String

    public init(
        projectURL: URL, astSource: ProjectASTBuilder.Source,
        configStore: PublishConfigStore, jobManager: CompileJobManager,
        maughamVersion: String, tectonicVersion: String
    ) {
        self.projectURL = projectURL
        self.astSource = astSource
        self.configStore = configStore
        self.jobManager = jobManager
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
    }

    public func preview(
        format: PublishConfig.Format,
        sectionIDs: [String]?,
        maxPages: Int?
    ) async throws -> Result {
        let jobID = await jobManager.register(phase: .renderingBody)
        guard var config = try await configStore.load() else {
            await jobManager.fail(jobID: jobID, errors: [], logExcerpt: "no config")
            return Result(outputPath: "", warnings: [], errors: [])
        }
        // Preview output lands in build/preview/ — don't pollute Exports/.
        config.outputs = .init(
            directory: ".maugham/publish/build/preview",
            filenameTemplate: "preview-{version}-{ext}.{ext}",
            sanitizeSpaces: true,
            formatsEnabled: config.outputs.formatsEnabled)

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

        switch format {
        case .pdf:
            let pdf = try PDFCompiler(
                projectURL: projectURL, astSource: filteredSrc,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion, jobID: jobID)
            let r = try await pdf.compile(label: "preview")
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: r.warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: r.warnings, errors: r.errors)
        case .epub:
            let e = EPUBCompiler(
                projectURL: projectURL, astSource: filteredSrc,
                config: config, jobManager: jobManager,
                maughamVersion: maughamVersion,
                tectonicVersion: tectonicVersion, jobID: jobID)
            let r = try await e.compile(label: "preview")
            await jobManager.complete(jobID: jobID, outputPath: r.outputPath,
                                      warnings: r.warnings, errors: r.errors)
            return Result(outputPath: r.outputPath, warnings: r.warnings, errors: r.errors)
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
