import Foundation
import MaughamCore

// MARK: - Figures and Research (report plan 6b, spec §4)
//
// The verbs that move a figure between Research and the book: *Use in
// document* (Task 6), *Send to Research* (Task 7) and the return, `bringBack`
// (Task 8). The figure's own creation and registry steps
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

    /// Test seam: runs in `sendToResearch` after the working copy is written
    /// and before the park — where an edit landing meanwhile is put. Nil in
    /// production.
    static var beforeSendParksForTesting: (@MainActor () async throws -> Void)?

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

    // MARK: - Send to Research (report plan 6b Task 7, spec §4.2, ruling P-5)

    /// **Park a figure in Research** and answer the Research item that holds
    /// its working copy. The figure stays in the registry; its stream stays,
    /// marked parked, and folds nothing until it is brought back (ruling P-5).
    ///
    /// 1. **Doors first**: the figure's `.editFigure` posture
    ///    (`requireFigurePermitted`), then the `.writeText` door of every
    ///    manuscript holding the figure's line, each held through the
    ///    door-checked route (`holdManuscriptsForFigureText(.removeLine)`).
    ///    Any refusal — or a figure already parked — changes nothing
    ///    (`FigureEditRefused`, `FigureSendRefused`).
    /// 2. **The working copy**, from the figure's host's state: a table as a
    ///    CSV with formulas as `=` cells (`TableCSV.renderResearch`, the book's
    ///    language and names), a picture as a copy of its file — added to
    ///    Research under `scope` through the typed creator route
    ///    (`createResearchAsset`, a coordinated copy that never overwrites).
    ///    A table's sidecar (`ResearchTableSidecar`: figure id, name, the
    ///    line's caption, formats, header and total rows, widths, and the
    ///    CSV's `ContentHash`) goes beside it.
    /// 3. **The park** (`FigureDocument.parkInResearch`): `figureParked` with
    ///    the copy's path, hash and item id — refused if the figure changed
    ///    since the copy was made — and, in the same synchronous step, the
    ///    figure's line removed from its manuscript (an ordinary op-logged
    ///    edit, undoable there). A failure here takes the copy back out.
    /// 4. A table's `figures/<name>.csv` is no longer rendered: the stale
    ///    render goes to the Trash through the typed mover. Figures reading it
    ///    keep its parked values (`FigureWorkbook.assemble`).
    ///
    /// Not undoable with ⌘Z (ruling P-8): it is undone by bringing the figure
    /// back. Needs the window's `DocumentStore`.
    @discardableResult
    public func sendToResearch(figureId: String, scope: ResearchScope) async throws -> ResearchItem {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let record = manifest.figures?.first(where: { $0.id == figureId }) else {
            throw FigureEditInvalid(reason: "this figure is not in the book's list of figures")
        }
        guard let labelKind = Self.labelKind(of: record.kind) else {
            throw FigureEditInvalid(reason: "this build cannot send a figure of this kind to Research")
        }
        let alreadyParked = try await documentStore.figureIsParked(figureId)
        guard !alreadyParked else { throw FigureSendRefused(reason: .alreadyInResearch) }
        try await requireFigurePermitted(figureId: figureId, site: "sendToResearch", documentStore: documentStore)
        // A name that cannot be a label has no line in the text to remove.
        let label = ManuscriptLabel(reference: "\(labelKind.rawValue):\(record.name)")
        var held: HeldFigureTextEdit?
        if let label { held = try await holdManuscriptsForFigureText(.removeLine(label)) }

        let wasOpen = documentStore.openFigure(forId: figureId) != nil
        let holding = held
        func letGo() async {
            await holding?.release()
            if !wasOpen { await documentStore.closeFigure(figureId: figureId) }
        }
        let host: FigureDocument
        do { host = try await documentStore.openFigure(figureId: figureId) } catch {
            await letGo()
            throw error
        }
        let snapshot = host.state
        guard snapshot.parked == nil else {
            await letGo()
            throw FigureSendRefused(reason: .alreadyInResearch)
        }
        var caption: String?
        if let label, let held {
            caption = held.manuscripts.lazy.compactMap {
                Self.figureCaption(in: $0.manuscript.doc.displayText, label)
            }.first
        }

        let copy: (item: ResearchItem, path: String, hash: String)
        do {
            copy = try await writeWorkingCopy(of: record, state: snapshot, caption: caption, scope: scope)
        } catch {
            await letGo()
            throw error
        }
        var written: HeldFigureTextEdit.Written = []
        do {
            try await Self.beforeSendParksForTesting?()
            try await host.parkInResearch(
                path: copy.path, hash: copy.hash, itemId: copy.item.id, expecting: snapshot
            ) {
                if let holding { written = try holding.write() }
            }
        } catch {
            // The park never landed: whatever text the step removed goes
            // back, and so does the copy.
            HeldFigureTextEdit.unwrite(written)
            await removeWorkingCopy(copy.item)
            await letGo()
            throw error
        }
        await letGo()
        // Its render is no longer written; the stale one goes to the Trash,
        // unless another record still names the file.
        let shared = (manifest.figures ?? []).contains {
            $0.id != figureId && $0.path.lowercased() == record.path.lowercased()
        }
        if record.kind == .table, !shared { await trashStrayFigureFile(at: record.path) }
        await documentStore.renderFigures(changed: [figureId])
        return copy.item
    }

    /// The working copy written into Research under `scope` — a table's CSV
    /// and sidecar, or a picture's file — with its path and content hash.
    /// Anything written is taken back out when a later step fails.
    private func writeWorkingCopy(
        of record: FigureRecord, state: FigureState, caption: String?, scope: ResearchScope
    ) async throws -> (item: ResearchItem, path: String, hash: String) {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        let item: ResearchItem
        switch record.kind {
        case .table:
            let names = try await documentStore.formulaNamesForUse()
            let locale = TableLocale(languageTag: await bookLanguageTag())
            let csv = TableCSV.renderResearch(state.table, locale: locale, names: names)
            let folder = try FigureIngest.makeTemporaryFolder()
            let file = folder.appendingPathComponent( // local-path: a temporary folder minted here; figurePath makes the name a plain file
                (Self.figurePath(name: record.name, kind: .table) as NSString).lastPathComponent)
            defer { FigureIngest.removeTemporary(file) }
            try Data(csv.utf8).write(to: file)
            item = try await createResearchAsset(scope: scope, fromURL: file)
        case .image:
            guard let image = state.image else {
                throw FigureEditInvalid(reason: "this picture has no file to send")
            }
            let file: URL
            do {
                file = try SafeRelativePath.resolveFile(
                    named: image.filename, in: Self.figuresFolder, under: url)
            } catch {
                throw FigureEditInvalid(reason: "this figure's file name is not a file in figures/")
            }
            item = try await createResearchAsset(scope: scope, fromURL: file)
        case .unknown:
            throw FigureEditInvalid(reason: "this build cannot send a figure of this kind to Research")
        }
        do {
            guard let path = item.path else {
                throw ProjectStoreError.fileSystemError("The working copy has no file in Research")
            }
            let written = try resolvedProjectPath(path)
            let hash = try await Task.detached { try ContentHash.ofFile(written) }.value
            if record.kind == .table {
                try ResearchTableSidecar.write(
                    ResearchTableSidecar(
                        figureId: record.id, contentHash: hash, name: record.name,
                        caption: caption, table: state.table),
                    forItem: item.id, in: url)
            }
            return (item, path, hash)
        } catch {
            await removeWorkingCopy(item)
            throw error
        }
    }

    /// A working copy a failed send leaves behind, taken back out: its file
    /// to the Trash through the typed mover (Maugham's own artifact), its
    /// sidecar removed, its item out of Research. Best-effort, logged.
    private func removeWorkingCopy(_ item: ResearchItem) async {
        beginStructuralVerb(); defer { endStructuralVerb() }
        if let path = item.path { await trashStrayFigureFile(at: path) }
        if let sidecar = try? ResearchTableSidecar.fileURL(forItem: item.id, in: url),
           FileManager.default.fileExists(atPath: sidecar.path) {
            do { try FileManager.default.removeItem(at: sidecar) } catch {
                projectStoreLog.error(
                    "sendToResearch: a failed send's sidecar was not removed: \(error.localizedDescription, privacy: .public)")
            }
        }
        removeResearchItem(id: item.id)
        manifest.modified = Date()
        do { try await saveManifest() } catch {
            projectStoreLog.error(
                "sendToResearch: a failed send's Research item was not taken out: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The caption of the figure line labelled `label` in `text`, or nil.
    nonisolated static func figureCaption(in text: String, _ label: ManuscriptLabel) -> String? {
        for (block, _) in ManuscriptBlocks.parse(text) {
            if case .figure(let caption, _, let l) = block, l == label {
                return caption.isEmpty ? nil : caption
            }
        }
        return nil
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

/// **A send to Research refused before anything changed** (report plan 6b
/// Task 7): the figure, its stream, the text and Research are as they were.
public struct FigureSendRefused: LocalizedError, Equatable {
    public enum Reason: Equatable {
        /// The figure is already parked in Research.
        case alreadyInResearch
        /// These pieces' text cannot be read, so whether they hold the
        /// figure's line cannot be checked.
        case unreadable([String])
        /// These pieces hold the figure's line, and this Mac may not change
        /// their text.
        case piecesNotWritable([String])
    }

    public let reason: Reason

    public var errorDescription: String? {
        switch reason {
        case .alreadyInResearch:
            return "This figure is already in Research."
        case .unreadable(let titles):
            return titles.joined(separator: ", ")
                + " can't be read, so whether it holds this figure can't be checked."
        case .piecesNotWritable(let titles):
            return "Not sent — this Mac may not change the text of "
                + titles.joined(separator: ", ") + ", which holds this figure."
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
