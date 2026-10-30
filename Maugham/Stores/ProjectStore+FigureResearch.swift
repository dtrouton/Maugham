import Foundation
import MaughamCore

// MARK: - Figures and Research (report plan 6b, spec §4)
//
// The verbs that move a figure between Research and the book: *Use in
// document* (Task 6), *Send to Research* (Task 7) and the return, `bringBack`
// (Task 8). The figure's own creation and registry steps
// are `ProjectStore+Figures`'s (`createFigureStream`, `createImageFigure`).

/// **What *Use in document* made** (report plan 6b Task 6): the new figure's
/// record — or the parked figure brought back (Task 8) — and the cells of a
/// Research table it could not read as the writer meant — each a formula that
/// would not parse, kept as text holding its `=…` (spec §4.1). Empty for a
/// picture or a clean table.
public struct UseInDocumentResult: Equatable {
    public let record: FigureRecord
    public let problems: [CSVReadProblem]
    /// **Cells the copy's change replaced a late edit in** (a return only):
    /// edited after the working copy was written, by a device the parker had
    /// not read, and changed in the copy too — the copy won (Task 8).
    public let overwritten: [CellKey]

    public init(record: FigureRecord, problems: [CSVReadProblem], overwritten: [CellKey] = []) {
        self.record = record
        self.problems = problems
        self.overwritten = overwritten
    }
}

extension ProjectStore {

    /// Test seam: runs in `sendToResearch` after the working copy is written
    /// and before the park, handed the held manuscripts — where an edit
    /// landing meanwhile, or a door closing, is put. Nil in production.
    static var beforeSendParksForTesting: (@MainActor (HeldFigureTextEdit?) async throws -> Void)?

    /// **Make a figure from a Research item** and answer it with the cells
    /// that could not be read. No line is placed in the text: the surface that
    /// calls this asks where (plans 7–8).
    ///
    /// 1. **A working copy of a parked figure goes back to its own log**: an
    ///    item whose sidecar (`ResearchTableSidecar`) names a figure the
    ///    registry lists, parked in Research, is handed to `bringBack` (Task 8)
    ///    and nothing is made here — when this Mac may edit that figure. One
    ///    that may not makes a new figure from the copy, as from any Research
    ///    table (final review M-5). Only then is the registry resolved.
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
    /// 4. Either way the figure is named `name` when that is a label name
    ///    (`ManuscriptLabel.isValidName` — *Move into Figures* keeps its
    ///    line's), else `FigureIngest.figureName` of `name` or the item's
    ///    title (`Q3 revenue (draft)` → `q3-revenue-draft`), so its line's
    ///    `{#tbl:…}`/`{#fig:…}` label is the record's name; de-duplicated
    ///    (`vacantFigureName`: `_2`, `_3`…), behind the door a new figure asks
    ///    of `piece`, and its `figureCreate` records the source: the item's
    ///    id, path and the content hash of the bytes copied (`FigureSource`).
    ///
    /// Throws `UseInDocumentRefused` for an item that is not a Research table,
    /// picture or PDF, has no file, or is too large. Needs the window's
    /// `DocumentStore`.
    @discardableResult
    public func useInDocument(
        researchItemId: String, piece: String?, name: String? = nil
    ) async throws -> UseInDocumentResult {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let item = findResearchItem(id: researchItemId, in: manifest.research),
              item.type == .asset else {
            throw UseInDocumentRefused(reason: .notInResearch)
        }
        let sidecar = researchTableSidecar(of: item)
        if try await figureToBringBack(namedBy: sidecar, documentStore: documentStore) != nil {
            return try await bringBack(researchItemId: item.id, piece: piece, name: name)
        }
        let figureName = Self.labelSafeFigureName(name, title: item.title)
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
                kind: .table, table: read.table, name: figureName, piece: piece,
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
                fromURL: file, name: figureName, piece: piece,
                from: FigureSource(researchItemId: item.id, path: path, contentHash: hash))
            return UseInDocumentResult(record: record, problems: [])
        case .document?, .audio?, .link?, nil:
            throw UseInDocumentRefused(reason: .notAFigure(item.title))
        }
    }

    /// **The parked figure a Research item brings back**, by id, or nil when
    /// *Use in document* on it makes a new figure: the item's sidecar names a
    /// figure the registry lists, parked, which this Mac may edit (final
    /// review M-5, Denver's ruling — anyone else makes a new, independent
    /// figure from the copy's data; the sidecar's figure id is not followed,
    /// and its formats apply only to the bytes they were written for). The
    /// one answer `useInDocument` routes by and a Research row's menu and
    /// inspector read to say *Bring Back to Figures* (report plan 8b Task 4).
    /// Throws when the figure's stream or the registry will not read.
    func figureToBringBack(fromResearchItemId researchItemId: String) async throws -> String? {
        guard let documentStore,
              let item = findResearchItem(id: researchItemId, in: manifest.research),
              item.type == .asset else { return nil }
        return try await figureToBringBack(namedBy: researchTableSidecar(of: item), documentStore: documentStore)
    }

    /// `figureToBringBack(fromResearchItemId:)` for every Research picture,
    /// table and PDF, by item id — what the window's tree
    /// caches for its menus (`BinderTreeSectionsState.figureReturns`). An
    /// item whose figure will not read is left out (it says *Use in
    /// Document*; the verb itself asks again and says why).
    func figuresToBringBack() async -> [String: String] {
        guard let documentStore else { return [:] }
        let ids = TreeWalk.collect(in: manifest.research) {
            $0.type == .asset && [.table, .image, .pdf].contains($0.kind)
        }.map(\.id)
        // The sidecars are read off the main actor, once each; one that will
        // not read is passed over quietly (the verb itself logs and says).
        let projectURL = url
        let named = await Task.detached {
            ids.reduce(into: [String: ResearchTableSidecar]()) { out, id in
                if let sidecar = try? ResearchTableSidecar.read(forItem: id, in: projectURL) { out[id] = sidecar }
            }
        }.value
        var out: [String: String] = [:]
        for (id, sidecar) in named {
            guard let figureId = try? await figureToBringBack(namedBy: sidecar, documentStore: documentStore)
            else { continue }
            out[id] = figureId
        }
        return out
    }

    private func figureToBringBack(
        namedBy sidecar: ResearchTableSidecar?, documentStore: DocumentStore
    ) async throws -> String? {
        guard let figureId = sidecar?.figureId, try await documentStore.figureIsParked(figureId) else { return nil }
        let posture = await documentStore.settledPosture(forDocId: figureId, as: .author)
        return !posture.isSettling && posture.allows(.editFigure) ? figureId : nil
    }

    /// **The piece whose Research holds an item** — a Collection piece's own
    /// research folder (`researchScopePieceId` of the item's root path) —
    /// else nil, shared Research. A figure made from the item belongs to it
    /// (report plan 8b Task 4). With nil the figure is the whole book's
    /// (`FigureRecord.piece`): placing its line does not change that, and its
    /// door is the whole-book authors'.
    func researchHomePiece(ofItemId id: String) -> String? {
        researchScopePieceId(ofPath: Self.researchRootPath(ofItemId: id, in: manifest.research))
    }

    // MARK: - Coming back (report plan 6b Task 8, spec §4.2, ruling P-7)

    /// **Bring a parked figure back from its working copy in Research** and
    /// answer it, with what the copy's read could not parse and the late edits
    /// the copy's changes replaced. `useInDocument` routes here when the
    /// item's sidecar names a parked figure. The figure keeps its record —
    /// name, piece, path — so every reference to it reconnects with no op;
    /// neither `piece` nor `name` is asked (a name the caller would give a
    /// new figure is not this one's). The working copy stays in Research.
    ///
    /// 1. **Only the parked copy**: the item's sidecar names the figure, the
    ///    registry lists it, it is parked, and its park names THIS item
    ///    (`FigureParking.itemId`) — a copy whose park was dropped (a second
    ///    park while parked) is an orphan. Else `FigureReturnRefused`.
    /// 2. **The figure's door** (`.editFigure`), then its host.
    /// 3. **Unchanged** (the copy's content hash is the park's): `figureResumed`
    ///    alone — history, ids, formats and anchors return as they were.
    /// 4. **A changed table** is read as *Use in document* reads one (the
    ///    book's language and names, the cell ceiling), and
    ///    `FigureReturnDiff` brings back its differences, three-way: from the
    ///    state the copy was written from — the parked state when it still
    ///    renders to the park's hash, else the stream as far as the parker had
    ///    read (`FigureReturnDiff.base(of:streams:frontier:)`) — onto the parked
    ///    state. The sidecar's formats apply when it was written for the
    ///    parked bytes.
    /// 5. **A changed picture** replaces the figure's file, one `figureImageSet`.
    /// 6. `FigureDocument.resumeFromResearch` appends it all, the resume first,
    ///    signed by this Mac's author key with `broughtBackFromResearch`.
    ///
    /// Needs the window's `DocumentStore`.
    @discardableResult
    public func bringBack(
        researchItemId: String, piece: String?, name: String? = nil
    ) async throws -> UseInDocumentResult {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let item = findResearchItem(id: researchItemId, in: manifest.research),
              item.type == .asset else {
            throw UseInDocumentRefused(reason: .notInResearch)
        }
        guard let figureId = researchTableSidecar(of: item)?.figureId,
              let record = manifest.figures?.first(where: { $0.id == figureId }) else {
            throw FigureReturnRefused(reason: .notAParkedCopy)
        }
        try await requireFigurePermitted(figureId: figureId, site: "bringBack", documentStore: documentStore)
        // The return renders once, as it ends (`resumeFromResearch`).
        let result = try await documentStore.withFigureHost(figureId) { host in
            let plan = try await returnPlan(for: item, record: record, host: host)
            try await host.resumeFromResearch(
                changes: plan.changes.ops, picture: plan.picture, expecting: plan.expecting)
            for problem in plan.changes.problems {
                projectStoreLog.info(
                    "bringBack: \(item.title, privacy: .public) row \(problem.row + 1, privacy: .public), column \(problem.column + 1, privacy: .public) kept as text: \(problem.message, privacy: .public)")
            }
            return UseInDocumentResult(
                record: record, problems: plan.changes.problems, overwritten: plan.changes.overwritten)
        }
        return result
    }

    /// What a return appends, made against `host`'s state (`expecting`): a
    /// changed table's differences, or a changed picture's file and hash —
    /// neither for a copy whose content hash is still the park's.
    private func returnPlan(
        for item: ResearchItem, record: FigureRecord, host: FigureDocument
    ) async throws -> (changes: FigureReturnDiff.Changes, picture: (url: URL, hash: String)?, expecting: FigureState) {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let parked = host.state.parked else { throw FigureReturnRefused(reason: .notParked) }
        guard parked.itemId == item.id else {
            throw FigureReturnRefused(reason: Self.wasParkedBefore(item.id, current: parked, in: host._ops)
                ? .sentAgainSince(record.kind) : .notThisCopy)
        }
        let (_, file) = try researchFile(of: item)
        let none = FigureReturnDiff.Changes.none

        switch record.kind {
        case .table:
            let (text, hash) = try await Task.detached { try Self.readResearchTable(file) }.value
            guard hash != parked.hash else { return (none, nil, host.state) }
            let cells = TableCSV.nonEmptyCellCount(text)
            guard cells <= TableCSV.figureCellLimit else {
                throw UseInDocumentRefused(reason: .tooLarge(cells: cells))
            }
            let names = try await documentStore.formulaNamesForUse()
            let locale = TableLocale(languageTag: await bookLanguageTag())
            let read = TableCSV.read(text, locale: locale, names: names)
            let current = host.state
            // The state the copy was written from: the parked state while it
            // still renders to the park's bytes (two-way is exact), else the
            // stream as far as the parker had read.
            let sidecar = researchTableSidecar(of: item)
            let namesAtPark = sidecar.map { names.renaming($0.formulaNames) }
            let base: FigureState
            let rendered = Self.researchHash(of: current.table, locale: locale, names: namesAtPark ?? names)
            if rendered != parked.hash, let frontier = parked.frontier {
                base = FigureReturnDiff.base(of: host._ops, streams: host.streams, frontier: frontier)
            } else {
                base = current
            }
            var used = Set(current.table.rowSlots.map(\.id.raw)).union(current.table.columnSlots.map(\.id.raw))
            let changes = FigureReturnDiff.changes(
                from: base, onto: current, to: read.table,
                sidecar: sidecar?.contentHash == parked.hash ? sidecar : nil,
                names: names, namesAtPark: sidecar?.contentHash == parked.hash ? namesAtPark : nil,
                problems: read.problems,
                mintRow: { let id = TableID.mint(excluding: used); used.insert(id); return RowID(id) },
                mintColumn: { let id = TableID.mint(excluding: used); used.insert(id); return ColumnID(id) })
            var withPins = changes
            withPins.ops += await returnPins(for: changes.ops, onto: current).map {
                FigureReturnDiff.Change(kind: .figurePinSet, payload: FigureOpPayload(cell: $0.cell, pin: $0.pin))
            }
            return (withPins, nil, current)
        case .image:
            let hash = try await Task.detached { try ContentHash.ofFile(file) }.value
            return (none, hash == parked.hash ? nil : (url: file, hash: hash), host.state)
        case .unknown:
            throw FigureEditInvalid(reason: "this build cannot bring back a figure of this kind")
        }
    }

    /// **The name a figure made from Research takes, before de-duplication**:
    /// `name` as given when it is a label name (`ManuscriptLabel.isValidName`),
    /// else `FigureIngest.figureName` of `name` or `title` — always a label
    /// name, so the line's label can be the record's name.
    nonisolated static func labelSafeFigureName(_ name: String?, title: String) -> String {
        if let name, ManuscriptLabel.isValidName(name) { return name }
        return FigureIngest.figureName(stem: name ?? title)
    }

    /// **Is `itemId` the copy of an EARLIER park than the current one?** — a
    /// park that named it sorts before the park that names the current copy:
    /// the figure came back and was sent again since. (A copy whose park
    /// never took — a second send while parked — sorts after.)
    nonisolated static func wasParkedBefore(_ itemId: String, current: FigureParking, in ops: [Op]) -> Bool {
        let parks = ops.filter { $0.kind == .figureParked }
        guard let mine = parks.filter({ $0.figure?.parkedItemId == itemId }).map(\.opId).min(),
              let now = parks.filter({ $0.figure?.parkedItemId == current.itemId }).map(\.opId).max()
        else { return false }
        return mine < now
    }

    /// **The entry pins the cells a return sets take** (final review I-1):
    /// `DocumentStore.entryPins` over the figure as the return leaves it,
    /// limited to the cells its cell sets write — a formula brought back from
    /// the copy that reads a Research table pins it, as one typed in would.
    /// Sources that will not read take none (logged; the status says
    /// `unpinned`).
    private func returnPins(
        for changes: [FigureReturnDiff.Change], onto current: FigureState
    ) async -> [PinWrite] {
        guard let documentStore else { return [] }
        var resulting = current
        resulting.parked = nil
        var cells = Set<CellKey>()
        for change in changes {
            FigureDeriver.fold(Op(
                opId: ULID.generate(), docId: "return", at: Date(), device: "return", session: "return",
                kind: change.kind, changes: [], figure: change.payload), into: &resulting)
            if change.kind == .figureCellSet, let cell = change.payload.cell { cells.insert(cell) }
        }
        guard !cells.isEmpty else { return [] }
        do {
            return try await documentStore.entryPins(for: resulting, cells: cells)
        } catch {
            projectStoreLog.error(
                "bringBack: the copy's Research sources did not read, so its formulas take no pins: \(error.localizedDescription, privacy: .public)")
            return []
        }
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

        let holding = held
        let copy: (item: ResearchItem, path: String, hash: String)
        do {
            copy = try await documentStore.withFigureHost(figureId) { host in
                let snapshot = host.state
                guard snapshot.parked == nil else { throw FigureSendRefused(reason: .alreadyInResearch) }
                var caption: String?
                if let label, let held {
                    caption = held.manuscripts.lazy.compactMap {
                        Self.figureCaption(in: $0.manuscript.doc.displayText, label)
                    }.first
                }
                let copy = try await writeWorkingCopy(
                    of: record, state: snapshot, caption: caption, scope: scope)
                var written: HeldFigureTextEdit.Written = []
                do {
                    try await Self.beforeSendParksForTesting?(holding)
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
                    throw error
                }
                return copy
            }
        } catch {
            await holding?.release()
            throw error
        }
        await holding?.release()
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
        var cited: [String: String] = [:]
        switch record.kind {
        case .table:
            let names = try await documentStore.formulaNamesForUse()
            cited = names.cited(by: state.table)
            let locale = TableLocale(languageTag: await bookLanguageTag())
            let csv = TableCSV.renderResearch(state.table, locale: locale, names: names)
            let folder = try FigureIngest.makeTemporaryFolder()
            // The file's stem is the copy's Research title: a vacant one, so a
            // second send never makes `research:<title>` name two tables
            // (final review M-3).
            let stem = vacantResearchTableTitle(
                basedOn: ((Self.figurePath(name: record.name, kind: .table) as NSString)
                    .lastPathComponent as NSString).deletingPathExtension)
            let file = folder.appendingPathComponent("\(stem).csv") // local-path: a temporary folder minted here; figurePath makes the stem a plain file name
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
            // A picture's sidecar holds only who it is: the return recognises
            // a working copy by its sidecar's figure id, whatever its kind.
            let sidecar = record.kind == .table
                ? ResearchTableSidecar(
                    figureId: record.id, contentHash: hash, name: record.name,
                    caption: caption, table: state.table, formulaNames: cited)
                : ResearchTableSidecar(figureId: record.id, contentHash: hash, name: record.name, caption: caption)
            try ResearchTableSidecar.write(sidecar, forItem: item.id, in: url)
            return (item, path, hash)
        } catch {
            await removeWorkingCopy(item)
            throw error
        }
    }

    /// `base`, or `base_2`, `base_3`… — the first title no Research table
    /// answers to, folded as `FormulaNames` folds a `research:` name
    /// (`lowercased()`), so a formula naming it is never ambiguous.
    private func vacantResearchTableTitle(basedOn base: String) -> String {
        let taken = Set(TreeWalk.collect(in: manifest.research, where: {
            $0.type == .asset && $0.kind == .table
        }).map { $0.title.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base)_\(n)".lowercased()) { n += 1 }
        return "\(base)_\(n)"
    }

    /// A working copy a failed send leaves behind, taken back out: its file
    /// to the Trash (`trashUnsentWorkingCopy`), its sidecar removed, its item
    /// out of Research. Best-effort, logged.
    private func removeWorkingCopy(_ item: ResearchItem) async {
        beginStructuralVerb(); defer { endStructuralVerb() }
        if let path = item.path { await trashUnsentWorkingCopy(item, at: path) }
        if let sidecar = try? ResearchTableSidecar.fileURL(forItem: item.id, in: url),
           FileManager.default.fileExists(atPath: sidecar.path) {
            do { try FileManager.default.removeItem(at: sidecar) } catch { // raw-delete: derived sidecar under .maugham/research-tables/
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

    /// **A failed send's working copy, to the project Trash** through the
    /// typed mover — a file Maugham wrote into Research moments ago and the
    /// writer never saw, so it is Maugham's own artifact (`.internalArtifact`),
    /// labelled as the unsent copy it is. Best-effort: a failure is logged.
    private func trashUnsentWorkingCopy(_ item: ResearchItem, at relativePath: String) async {
        guard let documentStore, let file = try? resolvedProjectPathToChange(relativePath),
              FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            _ = try await documentStore.trash(
                relativePath: relativePath, using: trashStore,
                itemMetadata: Data("{}".utf8), originalParentId: nil, originalIndex: 0,
                displayTitle: "Unsent Research copy: \(item.title)", subject: .internalArtifact)
        } catch {
            projectStoreLog.error(
                "sendToResearch: a failed send's working copy at \(relativePath, privacy: .public) could not go to the Trash: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Research pins (report plan 6b Task 9, spec §4.3)

    /// **A Research table as a pin reads it now** — its file's content hash
    /// and its values, its formulas computed against `book` (read as *Use in
    /// document* reads one: the book's language, `names`). Nil when the item
    /// is gone, is not a Research table, or its file will not read: the pins
    /// on it keep their values (`PinStatus.sourceMissing`).
    func pinSourceRead(researchItemId: String, book: Workbook, names: FormulaNames) async -> PinSourceRead? {
        guard let item = findResearchItem(id: researchItemId, in: manifest.research),
              item.type == .asset, item.kind == .table,
              let path = item.path, let file = try? resolvedProjectPath(path) else { return nil }
        guard let (text, hash) = try? await Task.detached(operation: { try Self.readResearchTable(file) }).value
        else { return nil }
        let locale = TableLocale(languageTag: await bookLanguageTag())
        let table = TableCSV.read(text, locale: locale, names: names).table
        return PinSourceRead(hash: hash, table: table, book: book, as: "research:\(item.id)")
    }

    /// **A parked figure's working copy as a pin reads it now**: the Research
    /// item its park names (`FigureParking.itemId`, which follows the typed
    /// mover; else the item at its park's path). Nil when the copy is gone.
    func pinSourceRead(workingCopyOf parking: FigureParking, book: Workbook, names: FormulaNames) async -> PinSourceRead? {
        let itemId = parking.itemId ?? TreeWalk.collect(in: manifest.research, where: { $0.path == parking.path }).first?.id
        guard let itemId else { return nil }
        return await pinSourceRead(researchItemId: itemId, book: book, names: names)
    }

    /// **The content hash a park's working copy of `table` has** — the bytes
    /// `writeWorkingCopy` writes (`TableCSV.renderResearch`). A parked state
    /// that still hashes to its `parkedHash` is what the copy was written
    /// from, so a return needs no frontier (its fast path).
    nonisolated static func researchHash(of table: FigureTable, locale: TableLocale, names: FormulaNames) -> String {
        ContentHash.of(Data(TableCSV.renderResearch(table, locale: locale, names: names).utf8))
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
    func bookLanguageTag() async -> String? {
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

/// **A Research item that cannot bring a parked figure back** (report plan
/// 6b Task 8): nothing was changed.
public struct FigureReturnRefused: LocalizedError, Equatable {
    public enum Reason: Equatable {
        /// The item's sidecar names no figure the book lists.
        case notAParkedCopy
        /// The figure it names is not in Research.
        case notParked
        /// The figure is in Research, but its park names another item: this
        /// one is a copy whose park never took (a second send while parked).
        case notThisCopy
        /// This copy is from an earlier park: the figure came back and was
        /// sent to Research again since (final re-review).
        case sentAgainSince(FigureKind)
    }

    public let reason: Reason

    public var errorDescription: String? {
        switch reason {
        case .notAParkedCopy:
            return "This item is not a figure's copy in Research."
        case .notParked:
            return "That figure is not in Research."
        case .notThisCopy:
            return "This is not the copy that figure was sent to Research as, so it can't bring it back."
        case .sentAgainSince(let kind):
            return (kind == .image ? "This picture" : "This table")
                + " was sent to Research again since this copy was made; bring it back from its newer copy."
        }
    }
}

/// **A figure line that could not be pointed at its figure** (report plan 8b
/// Task 1, *Move into Figures*): the text is as it was.
public struct FigureLineRetargetRefused: LocalizedError, Equatable {
    public enum Reason: Equatable {
        /// The piece's text no longer holds that line as it was found.
        case lineNotFound
        /// The piece's text cannot be read.
        case unreadable(String)
        /// This Mac may not change the piece's text.
        case pieceNotWritable(String)
    }

    public let reason: Reason

    public var errorDescription: String? {
        switch reason {
        case .lineNotFound:
            return "That figure line has changed since it was found, so it was left as it is."
        case .unreadable(let title):
            return "\(title) can't be read, so its figure line was left as it is."
        case .pieceNotWritable(let title):
            return "This Mac may not change the text of \(title), so its figure line was left as it is."
        }
    }
}
