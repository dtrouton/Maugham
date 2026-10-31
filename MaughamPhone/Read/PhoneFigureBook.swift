import Foundation
import MaughamCore

/// **A book's figure cards on the phone** (report plan 9b Task 4, spec §10.2):
/// read-only, computed through the same Core engine the Mac's card uses — the
/// op logs folded by `FigureCache`, the values by `FigureWorkbook`, the cards by
/// `FigureCardBook` (tripwire 19). Nothing here edits, and nothing reads
/// `figures/<name>.csv` (tripwire 20): values come from the op logs.
///
/// **Every file `FigureCache` will read is downloaded first.** The cache reads
/// uncoordinated, and an evicted iCloud file reads as empty bytes with no error,
/// which would draw an empty table as though it were real (tripwire 18). A
/// figure whose files will not download, or whose stream will not read, is left
/// out — no card, and a formula reading it is `#REF!` — never shown empty.
///
/// **Trust is resolved once per load** and that one table is handed to every
/// read; resolving it is Core's `TrustResolution`, not a decision made here.
///
/// The phone shows no "Research has changed" banner (plan 9b ruling): that
/// needs the Research files, which only the Mac reads, so every card is built
/// with `pinChanged: [], sourceChanged: []`.
@MainActor
final class PhoneFigureBook {
    typealias ResolveTrust = @Sendable (URL) async throws -> TrustTable

    private let downloads: DownloadCoordinator
    private let io: CoordinatedFileIO
    private let region: String?
    private let resolveTrust: ResolveTrust
    private let cache = FigureCache()

    /// How many times a load resolved trust; a test counts it.
    private(set) var trustResolutions = 0
    /// The last load's cards, or nil before a load or for a book with no figures.
    private(set) var book: FigureCardBook?
    private var index = FigureLineResolution.Index([])
    private var projectURL: URL?

    /// - Parameters:
    ///   - region: the region a language tag without one borrows — the
    ///     device's, as the Mac card borrows the Mac's; a test fixes it.
    ///   - resolveTrust: the trust table for a project; a test counts calls.
    init(
        downloads: DownloadCoordinator, io: CoordinatedFileIO = .live,
        region: String? = Locale.current.region?.identifier,
        resolveTrust: @escaping ResolveTrust = PhoneFigureBook.liveTrust
    ) {
        self.downloads = downloads
        self.io = io
        self.region = region
        self.resolveTrust = resolveTrust
    }

    /// Core's resolver, off the main actor (a directory walk plus a signature
    /// check per record), as the phone's Settings standing does it.
    nonisolated static let liveTrust: ResolveTrust = { projectURL in
        try await Task.detached(priority: .userInitiated) {
            try TrustResolution.resolve(
                projectURL: projectURL, identities: .current, cache: .shared)
        }.value
    }

    /// Load the book's cards. Nil when the manifest registers no figures, or
    /// when the registry will not read (RULING-54: no figure could be judged).
    @discardableResult
    func load(manifest: ProjectManifest, projectURL: URL) async -> FigureCardBook? {
        let records = manifest.figures ?? []
        self.projectURL = projectURL
        index = FigureLineResolution.Index(records)
        book = nil
        guard !records.isEmpty else { return nil }

        let language = await bookLanguageTag(in: projectURL)

        // Fault in every figure's stream before anything reads it; a figure
        // with no file yet, or one that will not download, is left out.
        var arrived: Set<String> = []
        for record in records where !arrived.contains(record.id) {
            let files = OpLogStore.opLogFileURLs(forDocId: record.id, in: projectURL)
            guard !files.isEmpty else { continue }
            var downloaded = true
            for file in files {
                do { try await downloads.ensureDownloaded(file) } catch { downloaded = false }
            }
            if downloaded { arrived.insert(record.id) }
        }

        trustResolutions += 1
        guard let trust = try? await resolveTrust(projectURL) else { return nil }

        let facts = DocumentClass.Facts(manifest)
        var states: [String: FigureState] = [:]
        for record in records where arrived.contains(record.id) && states[record.id] == nil {
            guard let state = try? cache.state(
                forFigureId: record.id, in: projectURL, trust: trust, facts: facts) else { continue }
            states[record.id] = state
        }

        // The workbook over the figures that read; each read above is cached,
        // so assembling reads nothing again.
        var readable = manifest
        readable.figures = records.filter { states[$0.id] != nil }
        let assembled = FigureWorkbook.assemble(
            for: readable, cache: cache, projectURL: projectURL, trust: trust)

        let built = FigureCardBook.build(
            records: records, states: states, workbook: assembled.workbook,
            locale: TableLocale(languageTag: language, fallbackRegion: region),
            pinChanged: [], sourceChanged: [])
        book = built
        return built
    }

    /// The card under a figure line, by Core's line rule; nil before a load or
    /// for a figure that was left out.
    func card(forLinePath linePath: String, documentPath: String) -> FigureCardModel? {
        book?.model(forLinePath: linePath, documentPath: documentPath, index: index)
    }

    /// The picture a figure line shows: a registered image figure's file, or a
    /// picture in Research the line names directly. Nil for a table, an
    /// ambiguous or removed figure, a path that is not local, or one that
    /// leaves the project (tripwire 58).
    func imageURL(forLinePath linePath: String, documentPath: String) -> URL? {
        guard let projectURL else { return nil }
        let path: String
        switch index.record(forLinePath: linePath, documentPath: documentPath) {
        case .figure(let record):
            guard record.kind == .image else { return nil }
            path = record.path
        case .ambiguous:
            return nil
        case .none:
            guard case .inside(let target, let root) = FigurePathRule.lexical(
                linePath, piecePath: documentPath),
                  root != [FigurePathRule.figuresFolder] else { return nil }
            path = target.joined(separator: "/")
        }
        return try? SafeRelativePath.resolve(path, under: projectURL)
    }

    /// The book's language from its publish config, downloaded and read
    /// coordinated; nil (English and the region) when there is none.
    private func bookLanguageTag(in projectURL: URL) async -> String? {
        let url = BookLanguage.configURL(in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try await downloads.ensureDownloaded(url)
            return BookLanguage.tag(fromConfigData: try io.coordinatedRead(at: url))
        } catch {
            return nil
        }
    }
}
