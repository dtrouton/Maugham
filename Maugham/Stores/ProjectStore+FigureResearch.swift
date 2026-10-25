import Foundation
import MaughamCore

// MARK: - Figures and Research (report plan 6b, spec §4)
//
// The verbs that move a figure between Research and the book: *Use in
// document* (Task 6) here; *Send to Research* (Task 7) and the return,
// `bringBack` (Task 8), join it. The figure's own creation and registry steps
// are `ProjectStore+Figures`'s (`createFigureStream`, `createImageFigure`).

/// **What *Use in document* made** (report plan 6b Task 6): the new figure's
/// record, and the cells of a Research table it could not read as the writer
/// meant — each a formula that would not parse, kept as text holding its
/// `=…` (spec §4.1). Empty for a picture or a clean table.
public struct UseInDocumentResult: Equatable {
    public let record: FigureRecord
    public let problems: [CSVReadProblem]
}

extension ProjectStore {

    /// **Make a figure from a Research item** and answer it with the cells
    /// that could not be read. No line is placed in the text: the surface that
    /// calls this asks where (plans 7–8).
    ///
    /// 1. **A working copy of a parked figure goes back to its own log**: an
    ///    item whose sidecar (`ResearchTableSidecar`) names a figure the
    ///    registry lists, parked in Research, is handed to `bringBack` (Task 8)
    ///    and nothing is made here. Only then is the registry resolved.
    /// 2. **A Research table** (`AssetKind.table`) is read through
    ///    `TableCSV.read` with the book's language (the publish config's
    ///    `metadata.language`) and name directory
    ///    (`DocumentStore.formulaNamesForUse`): a cell beginning `=` becomes a
    ///    formula — an unknown function stays a formula and shows `#NAME?` —
    ///    and one that cannot be parsed stays text holding its `=…` and is
    ///    answered as a problem. A file of more than `TableCSV.figureCellLimit`
    ///    non-empty cells is refused (`UseInDocumentRefused.tooLarge`). A
    ///    sidecar written for exactly these bytes (its `contentHash`) lays its
    ///    header and total rows, formats and widths on.
    /// 3. **A picture or PDF** takes `createImageFigure`'s path; no workbook is
    ///    built.
    /// 4. Either way the figure is named from the item's title, de-duplicated
    ///    (`vacantFigureName`), behind the door a new figure asks of `piece`,
    ///    and its `figureCreate` records the source: the item's id, path and
    ///    the content hash of the bytes copied (`FigureSource`).
    ///
    /// Throws `UseInDocumentRefused` for an item that is not a Research table,
    /// picture or PDF, has no file, or is too large. Needs the window's
    /// `DocumentStore`.
    @discardableResult
    public func useInDocument(researchItemId: String, piece: String?) async throws -> UseInDocumentResult {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let item = findResearchItem(id: researchItemId, in: manifest.research),
              item.type == .asset else {
            throw UseInDocumentRefused(reason: .notInResearch)
        }
        let sidecar = researchTableSidecar(of: item)
        if let figureId = sidecar?.figureId, try await documentStore.figureIsParked(figureId) {
            return UseInDocumentResult(
                record: try await bringBack(researchItemId: item.id, piece: piece), problems: [])
        }
        switch item.kind {
        case .table?:
            let (path, file) = try researchFile(of: item)
            let (text, hash) = try await Task.detached { try Self.readResearchTable(file) }.value
            let cells = TableCSV.nonEmptyCellCount(text)
            guard cells <= TableCSV.figureCellLimit else {
                throw UseInDocumentRefused(reason: .tooLarge(cells: cells))
            }
            let names = try await documentStore.formulaNamesForUse()
            let locale = TableLocale(languageTag: await bookLanguageTag())
            var read = TableCSV.read(text, locale: locale, names: names)
            if let sidecar, sidecar.contentHash == hash {
                read.table = sidecar.applied(to: read.table)
            }
            let record = try await createFigureStream(
                kind: .table, table: read.table, name: item.title, piece: piece,
                source: FigureSource(researchItemId: item.id, path: path, contentHash: hash),
                site: "useInDocument")
            for problem in read.problems {
                projectStoreLog.info(
                    "useInDocument: \(item.title, privacy: .public) row \(problem.row + 1, privacy: .public), column \(problem.column + 1, privacy: .public) kept as text: \(problem.message, privacy: .public)")
            }
            return UseInDocumentResult(record: record, problems: read.problems)
        case .image?, .pdf?:
            let (path, file) = try researchFile(of: item)
            let hash = try await Task.detached { try ContentHash.ofFile(file) }.value
            let record = try await createImageFigure(
                fromURL: file, name: item.title, piece: piece,
                from: FigureSource(researchItemId: item.id, path: path, contentHash: hash))
            return UseInDocumentResult(record: record, problems: [])
        case .document?, .audio?, .link?, nil:
            throw UseInDocumentRefused(reason: .notAFigure(item.title))
        }
    }

    /// **Report plan 6b Task 8's seam: bring a parked figure back** from its
    /// working copy in Research. `useInDocument` routes here when the item's
    /// sidecar names a parked figure. Until Task 8 replaces this body with
    /// the return (resume, or the diff, then `figureResumed`), it refuses
    /// with `FigureReturnPending` and changes nothing.
    @discardableResult
    public func bringBack(researchItemId: String, piece: String?) async throws -> FigureRecord {
        throw FigureReturnPending(researchItemId: researchItemId)
    }

    /// The book's language tag for reading a table's cells (spec §5.2: dates by
    /// the book's day/month order): the publish config's `metadata.language`,
    /// or nil — English and the Mac's region — when there is no config, it
    /// will not read, or the tag is empty.
    private func bookLanguageTag() async -> String? {
        guard let config = try? await PublishConfigStore(projectURL: url).load() else { return nil }
        let tag = config.metadata.language.trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? nil : tag
    }

    /// Item's sidecar, or nil when it has none, or one that will not read
    /// (logged): a copy whose sidecar can't be read never attaches to a parked
    /// log, so it is used as a fresh table.
    private func researchTableSidecar(of item: ResearchItem) -> ResearchTableSidecar? {
        do {
            return try ResearchTableSidecar.read(forItem: item.id, in: url)
        } catch {
            projectStoreLog.error(
                "useInDocument: \(item.title, privacy: .public)'s Research table sidecar did not read, so it is used as a fresh table: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A Research item's path and the file it names (the read form: a copy
    /// reads it, and a writer's own linked research folder still works).
    private func researchFile(of item: ResearchItem) throws -> (path: String, url: URL) {
        guard let path = item.path else { throw UseInDocumentRefused(reason: .noFile(item.title)) }
        return (path, try resolvedProjectPath(path))
    }

    /// A Research table's text and the content hash of exactly the bytes
    /// read. UTF-16 when it opens with a byte-order mark (Excel's "Unicode
    /// text"), else UTF-8, else Windows Latin-1 (an older Excel's CSV).
    nonisolated private static func readResearchTable(_ file: URL) throws -> (text: String, hash: String) {
        let data = try Data(contentsOf: file) // adr-0018-ok: a Research table's CSV, read once to make a figure; not manuscript
        let hash = ContentHash.of(data)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, hash)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, hash) }
        return (String(data: data, encoding: .windowsCP1252) ?? "", hash)
    }
}

/// **A Research item *Use in document* cannot make a figure from** (report
/// plan 6b Task 6): nothing was changed.
public struct UseInDocumentRefused: LocalizedError, Equatable {
    public enum Reason: Equatable {
        /// No Research item has this id, or it is a group.
        case notInResearch
        /// The item is a note, audio or a link: not a table, picture or PDF.
        case notAFigure(String)
        /// The item names no file.
        case noFile(String)
        /// The table holds more non-empty cells than `TableCSV.figureCellLimit`.
        case tooLarge(cells: Int)
    }

    public let reason: Reason

    public var errorDescription: String? {
        switch reason {
        case .notInResearch:
            return "That item is no longer in Research."
        case .notAFigure(let title):
            return "\(title) can't be a figure: only a table, a picture or a PDF can."
        case .noFile(let title):
            return "\(title) has no file to copy."
        case .tooLarge(let cells):
            return "This table is too large to use as a figure (\(cells) cells; the limit is \(TableCSV.figureCellLimit.formatted(.number.locale(Locale(identifier: "en_US")))))."
        }
    }
}

/// **Report plan 6b Task 8's seam**: `bringBack` until Task 8 builds it. The
/// item is the working copy of a parked figure, which comes back to its own
/// log rather than as a new figure. Task 8 deletes this type.
public struct FigureReturnPending: LocalizedError, Equatable {
    public let researchItemId: String
    public var errorDescription: String? {
        "This table is a parked figure's copy; bringing it back is not built yet."
    }
}
