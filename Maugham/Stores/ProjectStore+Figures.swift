import Foundation
import MaughamCore

// MARK: - Figures (report plan 6a)
//
// A figure — a table or an image — is its own op-logged document (ruling D-d).
// The manifest's `figures` registry is the truth for its name, kind, piece and
// path (ruling D-e); its stream under `.maugham/ops/` is the truth for its
// content. This seam creates one; `FigureDocument` hosts it once it exists.

extension ProjectStore {

    /// The folder every figure's render lives in, project-relative.
    static let figuresFolder = "figures"

    /// Test seam: thrown from before each of `createFigure`'s appends, to
    /// prove a failed append leaves no registry record. Nil in production.
    static var beforeFigureAppendForTesting: ((Op) throws -> Void)?

    /// Test seam: runs in `renameFigure` after the record is saved and before
    /// the held manuscripts are relabelled — where a door closing meanwhile
    /// is put. Nil in production.
    static var beforeFigureRelabelWriteForTesting: (@MainActor (HeldFigureTextEdit) async -> Void)?

    /// Test seam: runs in `restoreRemovedFigure` after its path was found
    /// free and before the Trash restores the file there — where a file
    /// arriving meanwhile is put. Nil in production.
    static var beforeFigureRestoreLandsForTesting: ((String) throws -> Void)?

    /// **Create a figure** and answer its registry record.
    ///
    /// 1. **The door first**: the figure's posture, asked of the class the new
    ///    figure WILL have (`.figure(id:, piece:)` — Denver's ruling: a figure
    ///    belongs to the piece it was created in), for `.editFigure` — the
    ///    window's door, yields and Edit Anyway included (R-6a-8), where a
    ///    window holds the book. A refusal (or a `.settling` answer) throws
    ///    `FigureEditRefused` and nothing is written.
    /// 2. Its id is `fig-<8 hex>` (`newId(prefix:)`), never the name.
    /// 3. The name is stored as given (trimmed), de-duplicated against the
    ///    registry with `_2`, `_3`… — an underscore keeps a bare formula name
    ///    bare (`FormulaParser.isBareFigureName`); any other name is quoted by
    ///    formulas. Names compare case-insensitively, as their render files do
    ///    on the Mac's disk.
    /// 4. The stream opens with `figureCreate` and, for a table, one insert per
    ///    row and column with its minted id, all as this device's author, then
    ///    sealed. A table starts with no header row.
    /// 5. Only then is the record written, through the manifest's one door
    ///    (`saveManifest` → `ProjectManifest.encodeForDisk`, which raises the
    ///    content floor to 10 for a manifest with figures).
    /// 6. A table's `figures/<name>.csv` is rendered where a window holds the
    ///    book (`DocumentStore.renderFigures`).
    @discardableResult
    public func createFigure(
        kind: FigureKind, name: String, piece: String?,
        rows: Int = 3, columns: Int = 3
    ) async throws -> FigureRecord {
        guard FigureKind.known.contains(kind) else {
            throw FigureEditInvalid(reason: "this build cannot make a figure of kind \(kind.rawValue)")
        }
        return try await createFigureStream(
            kind: kind, table: kind == .table ? FigureTable(rows: rows, columns: columns) : nil,
            name: name, piece: piece, source: nil, site: "createFigure")
    }

    /// **What `createFigure` and a Research table's *Use in document* share**:
    /// the door, the stream — `figureCreate` (with `source`, when made from
    /// Research), then for a table one insert per row and column in `table`'s
    /// order with its own ids, a cell set per cell, and its header and total
    /// rows and column widths — sealed, then the record, then the render.
    /// Internal for `ProjectStore+FigureResearch` (*Use in document*).
    func createFigureStream(
        kind: FigureKind, table: FigureTable?, name: String, piece: String?,
        source: FigureSource?, site: StaticString
    ) async throws -> FigureRecord {
        // A structural verb: it awaits (the door, the appends) before it
        // writes the manifest, so a manifest arriving meanwhile is held and
        // settled after the write, never adopted over the copy it extends.
        beginStructuralVerb(); defer { endStructuralVerb() }
        let figureId = Self.newId(prefix: DocumentClass.figureDocIdPrefix)
        let opStore = Document.makeLoadOpStore(projectURL: url, presenter: documentStore?.presenter)
        try await requireNewFigurePermitted(
            figureId: figureId, piece: piece, opStore: opStore, site: site)
        let op = figureOpMinter(figureId: figureId)
        var ops = [op(.figureCreate, FigureOpPayload(kind: kind, source: source))]
        if kind == .table, let table {
            ops += FigureCarry.openingPayloads(of: table).map { op($0.kind, $0.payload) }
            // A formula reading a Research table pins what it reads, as one
            // typed in would (final review I-1).
            ops += await openingPins(of: table).map {
                op(.figurePinSet, FigureOpPayload(cell: $0.cell, pin: $0.pin))
            }
        }
        // The stream first, the record second: a failure part-way leaves a
        // stream no registry names — invisible, resolving to a whole-book
        // figure nobody lists (ruling D-b) — never a record over an empty or
        // half-written stream that could not be edited or removed.
        try await appendNewFigureStream(ops, figureId: figureId, opStore: opStore)

        // Named against the registry as it stands NOW, after the appends'
        // awaits, so two creations racing cannot take one name.
        let vacant = vacantFigureName(basedOn: name, kind: kind)
        let placed = FigureRecord(
            id: figureId, name: vacant, kind: kind, piece: piece,
            path: Self.figurePath(name: vacant, kind: kind))
        var figures = manifest.figures ?? []
        figures.append(placed)
        manifest.figures = figures
        manifest.modified = Date()
        try await saveManifest()
        // Its render exists from the start: `figures/<name>.csv`, written
        // through the window's coordinated door (report plan 6a Task 7).
        await documentStore?.renderFigures(changed: [figureId])
        return placed
    }

    /// **The entry pins a new table's formulas take** (final review I-1):
    /// `DocumentStore.entryPins` over the table as it will stand. Sources that
    /// will not read take none (logged): those cells show `#REF!` and the
    /// figure's pin status says `unpinned` until a refresh.
    private func openingPins(of table: FigureTable) async -> [PinWrite] {
        guard let documentStore else { return [] }
        do {
            return try await documentStore.entryPins(for: FigureState(kind: .table, table: table))
        } catch {
            projectStoreLog.error(
                "a new table's Research sources did not read, so its formulas take no pins: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// **Create an image figure from a picture on disk** (report plan 6a
    /// Task 9) — what Insert ▸ Figure…, an image drop and an image paste make
    /// (`FigureIngest.importImage`) — and answer its record.
    ///
    /// 1. **The door first**, as `createFigure` asks it: nothing is copied
    ///    when this Mac may not make a figure in `piece`.
    /// 2. A format the outputs can't show (HEIC, TIFF…) is re-encoded as PNG
    ///    (`FigureIngest.copyableFile`), off the main thread.
    /// 3. **The file is claimed under `figures/`**: its name is
    ///    `FigureIngest.figureName` of `name` (or the file's stem) — always a
    ///    valid label name — made vacant against the registry, every file
    ///    already in `figures/` whatever its extension, and `avoiding` (the
    ///    `fig:` names the text already uses), with `_2`, `_3`… The copy is
    ///    `DocumentStore.executeCopy`, which never overwrites: a name another
    ///    creation took meanwhile is stepped over and the next one tried.
    /// 4. The stream — `figureCreate(.image)` then `figureImageSet` with the
    ///    file's name and `FigureImageResolver.contentHash` — appended and
    ///    sealed as the author; then the record, `figures/<name>.<ext>`, through
    ///    the manifest's one door. A failure after the copy leaves the picture
    ///    in `figures/` with no record (R-6a-9's order: never a record over a
    ///    stream that isn't there).
    /// 5. A picture made from a Research item (*Use in document*) carries
    ///    `research` on its `figureCreate`: where it came from (spec §4.1).
    ///
    /// Needs the window's `DocumentStore` (the coordinated copy), as research
    /// assets do.
    @discardableResult
    public func createImageFigure(
        fromURL source: URL, name: String? = nil, piece: String?,
        avoiding taken: Set<String> = [], from research: FigureSource? = nil
    ) async throws -> FigureRecord {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        let figureId = Self.newId(prefix: DocumentClass.figureDocIdPrefix)
        let opStore = Document.makeLoadOpStore(projectURL: url, presenter: documentStore.presenter)
        try await requireNewFigurePermitted(
            figureId: figureId, piece: piece, opStore: opStore, site: "createImageFigure")

        let copyable = try await Task.detached { try FigureIngest.copyableFile(for: source) }.value
        defer { if copyable.isTemporary { FigureIngest.removeTemporary(copyable.url) } }
        let ext = copyable.url.pathExtension.lowercased()
        let base = FigureIngest.figureName(
            stem: name ?? source.deletingPathExtension().lastPathComponent)
        let folder = url.appendingPathComponent(Self.figuresFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let takenLower = Set(taken.map { $0.lowercased() })

        var claimed: (name: String, filename: String)?
        for _ in 0..<Self.imageClaimAttempts {
            let stems = Self.fileStemsLowercased(in: folder)
            let candidate = vacantFigureName(basedOn: base, kind: .image) {
                takenLower.contains($0.lowercased()) || stems.contains($0.lowercased())
            }
            // The file takes the name's filesystem-safe form (`figurePath`).
            let filename = (Self.figurePath(name: candidate, kind: .image) as NSString)
                .lastPathComponent + ".\(ext)"
            let destination = folder.appendingPathComponent(filename) // local-path: figurePath mints it from the vacant name
            do {
                try await documentStore.executeCopy(from: copyable.url, to: destination)
                claimed = (candidate, filename)
                break
            } catch where FileManager.default.fileExists(atPath: destination.path) {
                continue   // another creation took this file meanwhile
            }
        }
        guard let claimed else {
            throw ProjectStoreError.fileSystemError("No free name for the picture in figures/")
        }
        let copied = folder.appendingPathComponent(claimed.filename) // local-path: the name this loop minted and claimed
        let hash = try await Task.detached { try FigureImageResolver.contentHash(of: copied) }.value

        let op = figureOpMinter(figureId: figureId)
        try await appendNewFigureStream([
            op(.figureCreate, FigureOpPayload(kind: .image, source: research)),
            op(.figureImageSet, FigureOpPayload(
                image: FigureImageRef(filename: claimed.filename, contentHash: hash))),
        ], figureId: figureId, opStore: opStore)

        // The file's stem is the name, unless the registry took it across the
        // awaits (a different extension raced): then the next vacant name, and
        // the file keeps its own.
        let vacant = vacantFigureName(basedOn: claimed.name, kind: .image) {
            takenLower.contains($0.lowercased())
        }
        let placed = FigureRecord(
            id: figureId, name: vacant, kind: .image, piece: piece,
            path: "\(Self.figuresFolder)/\(claimed.filename)")
        var figures = manifest.figures ?? []
        figures.append(placed)
        manifest.figures = figures
        manifest.modified = Date()
        try await saveManifest()
        return placed
    }

    /// How many names `createImageFigure` tries before it gives up.
    private static let imageClaimAttempts = 16

    /// The stems of every file in `folder`, lower-cased: `map.png` and
    /// `map.csv` both answer `map`.
    private static func fileStemsLowercased(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { ($0 as NSString).deletingPathExtension.lowercased() })
    }

    /// **An image figure's first picture arrived** (`FigureDocument.setImage`
    /// on a figure made without one): its record's path gains the file's
    /// extension, `figures/<name>` → `figures/<name>.<ext>`.
    func recordFigureImagePath(figureId: String, path: String) async throws {
        guard var figures = manifest.figures,
              let index = figures.firstIndex(where: { $0.id == figureId }),
              figures[index].path != path else { return }
        figures[index].path = path
        manifest.figures = figures
        manifest.modified = Date()
        try await saveManifest()
    }

    // MARK: - Rename and remove (report plan 6b Task 5, ruling P-3)

    /// **Rename a figure** and answer its new record. All or nothing (ruling
    /// P-3): every door is asked before anything changes, and any refusal
    /// changes nothing — registry, files, text and formulas all as before.
    ///
    /// 1. **Refused** (`FigureRenameRefused`): an empty name; a name another
    ///    figure has, in any case (the `lowercased()` fold `FormulaNames`
    ///    matches with); a render path another figure has, or an image file
    ///    already in `figures/`.
    /// 2. **The figure's own door**: its `.editFigure` posture — the window's
    ///    acting answer, yields and *Edit Anyway* included. A refusal throws
    ///    `FigureEditRefused`.
    /// 3. **Every manuscript that holds its line or a cross-reference to its
    ///    label** (`{#tbl:old}`, `@tbl:old`) is held through the door-checked
    ///    manuscript route (`holdManuscriptsForFigureText`); one refusing
    ///    refuses the rename, naming each piece. **So is every translation
    ///    record holding one** (`holdTranslationsForRelabel`, final review
    ///    I-2): one that will not read, or a translation door that refuses,
    ///    refuses the rename, naming the languages. A parked figure is
    ///    refused before any of this (`FigureRenameRefused.inResearch`).
    /// 4. Then: an image's file is moved and a `figureImageSet` with the same
    ///    hash and the new file name appended (`FigureDocument.renameImageFile`);
    ///    the record's name and path through `saveManifest`; a table's render
    ///    moved to its new file and rendered there (with any figure that
    ///    shared its old file, so a rename that separates two renders both);
    ///    the text relabelled, then its fresh translations (stamped against
    ///    the relabelled text, so they stay fresh). Formulas store the
    ///    figure's id, so they show the new name with nothing written (R-D1).
    ///
    /// Needs the window's `DocumentStore` (the typed mover, the renders).
    @discardableResult
    public func renameFigure(id: String, to name: String) async throws -> FigureRecord {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { throw FigureRenameRefused(reason: .emptyName) }
        guard let record = manifest.figures?.first(where: { $0.id == id }) else {
            throw FigureEditInvalid(reason: "this figure is not in the book's list of figures")
        }
        guard newName != record.name else { return record }
        // One rule for both kinds, up front (final review M-4, Denver's
        // ruling): a parked figure is renamed once it is brought back.
        if try await documentStore.figureIsParked(id) {
            throw FigureRenameRefused(reason: .inResearch(record.kind))
        }
        let newPath = try renamedFigurePath(of: record, to: newName)
        try await requireFigurePermitted(figureId: id, site: "renameFigure", documentStore: documentStore)

        let label = Self.labelKind(of: record.kind).flatMap {
            ManuscriptLabel(reference: "\($0.rawValue):\(record.name)")
        }
        var relabel: HeldFigureTextEdit?
        var translations: HeldTranslationRelabel?
        if let label {
            let change = FigureLabelChange(
                old: label, newName: newName,
                oldFile: (record.path as NSString).lastPathComponent,
                newFile: (newPath as NSString).lastPathComponent)
            relabel = try await holdManuscriptsForFigureText(.relabel(change))
            // Its translations too, all or nothing (final review I-2).
            do { translations = try holdTranslationsForRelabel(change) } catch {
                await relabel?.release()
                throw error
            }
        }
        // Every door has answered yes. Anything after this that fails puts
        // back what it did and releases the held manuscripts unwritten.
        do {
            // Asked again after the awaits: a record another verb wrote
            // meanwhile may have taken the name.
            _ = try renamedFigurePath(of: record, to: newName)
            if record.kind == .image {
                try await renameImageFileThroughHost(figureId: id, to: (newPath as NSString).lastPathComponent)
            }
        } catch {
            await relabel?.release()
            throw error
        }
        var renamed = record
        renamed.name = newName
        renamed.path = newPath
        do {
            try await replaceFigureRecord(renamed)
        } catch {
            await putBackImageFile(of: record, figureId: id)
            await relabel?.release()
            throw error
        }
        // The text straight after the record, with nothing awaited between
        // the documents: all of them or none (`HeldFigureTextEdit.write`). A
        // document that stopped being writable since it was held refuses the
        // whole rename, and the record and the picture go back too.
        // Then the translations of what was written, re-stamped against it;
        // a batch that fails puts the text back too.
        if let relabel {
            if let hook = Self.beforeFigureRelabelWriteForTesting { await hook(relabel) }
            var written: HeldFigureTextEdit.Written = []
            do {
                written = try relabel.write()
                if let translations {
                    try await writeTranslationRelabel(
                        translations, after: relabel.manuscripts.map(\.manuscript.doc))
                }
            } catch {
                HeldFigureTextEdit.unwrite(written)
                var error = error
                if let incomplete = error as? TranslationRelabelIncomplete, let translations {
                    // The source is back, so what landed is put back against
                    // it; what could not be is said, not only logged.
                    let unrestored = await putBackTranslationRelabel(
                        translations, landed: incomplete.landed,
                        after: relabel.manuscripts.map(\.manuscript.doc))
                    error = unrestored.isEmpty
                        ? incomplete.underlying : FigureRenameTranslationsNotRestored(languages: unrestored)
                }
                do { try await replaceFigureRecord(record) } catch {
                    projectStoreLog.error(
                        "renameFigure: the record could not be put back after a refused relabel: \(error.localizedDescription, privacy: .public)")
                }
                await putBackImageFile(of: record, figureId: id)
                await relabel.release()
                throw error
            }
            await relabel.release()
        }
        let sharers = (manifest.figures ?? []).filter {
            $0.id != id && $0.path.lowercased() == record.path.lowercased()
        }
        if record.kind == .table, sharers.isEmpty {
            await moveTableRender(from: record.path, to: newPath, documentStore: documentStore)
        }
        await documentStore.renderFigures(changed: Set([id] + sharers.map(\.id)))
        return renamed
    }

    /// **Remove a figure** — a structural verb behind the figure's own door
    /// (its `.editFigure` posture; a refusal throws `FigureEditRefused`).
    /// Its record leaves the registry and **always** goes to the project
    /// Trash (final review I-3, Denver's ruling), so restoring the entry
    /// brings the figure back (`restoreRemovedFigure`):
    /// - its file (a table's render, an image's picture), where it is on disk
    ///   and no other record names it, through the typed mover;
    /// - a table whose render is not there (parked in Research, never
    ///   written, evicted by iCloud): a CSV rendered fresh from its op state
    ///   (`DocumentStore.figureRenderText`);
    /// - otherwise — a picture whose file is missing, a file another record
    ///   shares, a table whose stream will not read — an entry holding the
    ///   record only; restored, the figure comes back and its picture shows
    ///   missing as before.
    ///
    /// Its stream stays (append-only). Its line and references in the text
    /// are left; they read as broken references. The tables reading it
    /// re-render.
    public func removeFigure(id: String) async throws {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let record = manifest.figures?.first(where: { $0.id == id }) else {
            throw FigureEditInvalid(reason: "this figure is not in the book's list of figures")
        }
        try await requireFigurePermitted(figureId: id, site: "removeFigure", documentStore: documentStore)

        // Its file goes to the Trash unless another record names it too.
        let shared = (manifest.figures ?? []).contains {
            $0.id != id && $0.path.lowercased() == record.path.lowercased()
        }
        let onDisk = (try? resolvedProjectPathToChange(record.path))
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // Rendered before its host closes, from the freshest state.
        let rendered = !shared && !onDisk ? await documentStore.figureRenderText(for: record) : nil
        await documentStore.closeFigure(figureId: id)
        let movedTheFile = !shared && onDisk
        let trashed: TrashEntry
        if movedTheFile {
            trashed = try await trashFigureFile(of: record, at: record.path, documentStore: documentStore)
        } else {
            trashed = try await trashFigureRecord(record, render: rendered)
        }
        manifest.figures = (manifest.figures ?? []).filter { $0.id != id }
        manifest.modified = Date()
        do {
            try await saveManifest()
        } catch {
            manifest.figures = (manifest.figures ?? []) + [record]
            if movedTheFile {
                _ = try? await trashStore.restore(trashId: trashed.id)
            } else {
                // Nothing of the book's was moved: the entry just goes.
                try? await trashStore.permanentlyDelete(trashId: trashed.id)
            }
            throw error
        }
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        await documentStore.renderFigures(changed: [id])
    }

    /// **A removed figure, back from the Trash** (`restoreTrashEntry`'s
    /// `.figure` route): its record returns under the name it had, behind the
    /// door a new figure asks of its piece — so the text's label for it reads
    /// again. **A name another figure now has refuses the restore**
    /// (`FigureRestoreRefused`): it is never brought back under another name,
    /// which would leave its label broken. Its file lands where the record and
    /// the op log say — an image keeps its stream's file name — and anything
    /// standing there since goes to the Trash first (`trashStrayFigureFile`),
    /// so the stream and the file agree. The caller saves the manifest.
    func restoreRemovedFigure(_ removed: FigureRecord, entryId: String) async throws {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard manifest.figures?.contains(where: { $0.id == removed.id }) != true else {
            throw ProjectStoreError.trashEntryNotRewirable(
                title: removed.listTitle, reason: "the figure is already in the book.")
        }
        if let clash = (manifest.figures ?? []).first(where: {
            $0.name.lowercased() == removed.name.lowercased()
                || $0.path.lowercased() == removed.path.lowercased()
        }) {
            throw FigureRestoreRefused(name: clash.name)
        }
        let opStore = Document.makeLoadOpStore(projectURL: url, presenter: documentStore?.presenter)
        try await requireNewFigurePermitted(
            figureId: removed.id, piece: removed.piece, opStore: opStore, site: "restoreRemovedFigure")
        var restored = removed
        if removed.kind == .image, let filename = await imageFilename(ofFigure: removed.id),
           SafeRelativePath.isPlainFileName(filename) {
            restored.path = "\(Self.figuresFolder)/\(filename)"
        }
        if let clash = (manifest.figures ?? []).first(where: {
            $0.path.lowercased() == restored.path.lowercased()
        }) {
            throw FigureRestoreRefused(name: clash.name)
        }
        await trashStrayFigureFile(at: restored.path)
        // The file lands at the record's path or the restore is refused: a
        // record never names a file that is not the restored one.
        let notLanded = ProjectStoreError.trashEntryNotRewirable(
            title: removed.listTitle,
            reason: "its file could not be put back at \(restored.path), so it was left in the Trash.")
        if let file = try? resolvedProjectPathToChange(restored.path),
           FileManager.default.fileExists(atPath: file.path) {
            throw notLanded
        }
        try Self.beforeFigureRestoreLandsForTesting?(restored.path)
        let entry = try await trashStore.restore(trashId: entryId, to: restored.path)
        if let landed = entry.restoredRelativePath, landed != restored.path {
            // Undone: the file goes back to the Trash with its record, so the
            // figure can still come back once its path is free.
            if let documentStore {
                do {
                    _ = try await trashFigureFile(of: removed, at: landed, documentStore: documentStore)
                } catch {
                    projectStoreLog.error(
                        "restoreRemovedFigure: \(removed.name, privacy: .public)'s file landed at \(landed, privacy: .public) and could not go back to the Trash: \(error.localizedDescription, privacy: .public)")
                }
            }
            throw notLanded
        }
        manifest.figures = (manifest.figures ?? []) + [restored]
        // A table removed while parked comes back parked: the CSV its entry
        // carried is not a render it has, so it goes to the Trash as send's
        // stale render does.
        if restored.kind == .table, entry.restoredRelativePath != nil,
           (try? await documentStore?.figureIsParked(restored.id)) == true {
            await trashStrayFigureFile(at: restored.path)
        }
        await documentStore?.renderFigures(changed: [restored.id])
    }

    /// A figure's file sent to the project Trash through the typed mover,
    /// carrying `record` so a restore brings the figure back.
    private func trashFigureFile(
        of record: FigureRecord, at relativePath: String, documentStore: DocumentStore
    ) async throws -> TrashEntry {
        let metadata = try JSONEncoder().encode(record)
        return try await documentStore.trash(
            relativePath: relativePath, using: trashStore,
            itemMetadata: metadata,
            originalParentId: nil, originalIndex: 0,
            displayTitle: record.listTitle, subject: .figure)
    }

    /// **A removed figure's Trash entry when its file is not moved there**
    /// (final review I-3): `render` — a table's CSV rendered fresh — as the
    /// entry's file, named as the render would be (`FigureRender.renderPath`,
    /// one plain file name), so a restore lands it at the record's path; else
    /// the record alone (`carriesFile: false`).
    private func trashFigureRecord(_ record: FigureRecord, render: String?) async throws -> TrashEntry {
        let metadata = try JSONEncoder().encode(record)
        if let render, let path = FigureRender.renderPath(of: record) {
            return try await trashStore.recordTextEntry(
                text: render, filename: (path as NSString).lastPathComponent,
                originalRelativePath: path, itemMetadata: metadata,
                displayTitle: record.listTitle, subject: .figure)
        }
        return try await trashStore.recordManifestOnlyTrash(
            originalRelativePath: record.path, itemMetadata: metadata,
            originalParentId: nil, originalIndex: 0,
            displayTitle: record.listTitle, subject: .figure)
    }

    /// The file name an image figure's stream says its picture has, read
    /// windowless (nothing renders); nil when it has none or will not read.
    private func imageFilename(ofFigure figureId: String) async -> String? {
        guard let doc = try? await FigureDocument.load(
            figureId: figureId, projectURL: url, actor: .author,
            session: "restore", presenter: nil, documentStore: nil) else { return nil }
        let name = doc.state.image?.filename
        await doc.close()
        return name
    }

    /// **A file standing where a figure's file is about to be written goes to
    /// the project Trash first**, through the typed mover — a hand-placed or
    /// stray file is never overwritten or set beside unlisted. It is
    /// Maugham's safety copy of a file it is about to write over
    /// (`.internalArtifact`). Best-effort: a failure is logged.
    func trashStrayFigureFile(at relativePath: String) async {
        guard let documentStore, let file = try? resolvedProjectPathToChange(relativePath),
              FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            _ = try await documentStore.trash(
                relativePath: relativePath, using: trashStore,
                itemMetadata: Data("{}".utf8), originalParentId: nil, originalIndex: 0,
                displayTitle: (relativePath as NSString).lastPathComponent, subject: .internalArtifact)
        } catch {
            projectStoreLog.error(
                "a stray file at \(relativePath, privacy: .public) could not go to the Trash: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A refused rename's picture, put back under the name the record keeps.
    private func putBackImageFile(of record: FigureRecord, figureId: String) async {
        guard record.kind == .image else { return }
        do {
            try await renameImageFileThroughHost(
                figureId: figureId, to: (record.path as NSString).lastPathComponent)
        } catch {
            projectStoreLog.error(
                "renameFigure: the picture could not be put back: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The path `record` takes under `name`, or a refusal: the name another
    /// figure answers to in any case, the path another figure's record has,
    /// or — an image — a file already in `figures/` under the new name.
    private func renamedFigurePath(of record: FigureRecord, to name: String) throws -> String {
        let others = (manifest.figures ?? []).filter { $0.id != record.id }
        if let clash = others.first(where: { $0.name.lowercased() == name.lowercased() }) {
            throw FigureRenameRefused(reason: .nameTaken(clash.name))
        }
        let path: String
        switch record.kind {
        case .table:
            path = Self.figurePath(name: name, kind: .table)
        case .image:
            let ext = (record.path as NSString).pathExtension
            path = Self.figurePath(name: name, kind: .image) + (ext.isEmpty ? "" : ".\(ext)")
        case .unknown:
            throw FigureEditInvalid(reason: "this build cannot rename a figure of this kind")
        }
        if others.contains(where: { $0.path.lowercased() == path.lowercased() }) {
            throw FigureRenameRefused(reason: .pathTaken(path))
        }
        if record.kind == .image, path.lowercased() != record.path.lowercased(),
           let file = try? resolvedProjectPathToChange(path),
           FileManager.default.fileExists(atPath: file.path) {
            throw FigureRenameRefused(reason: .pathTaken(path))
        }
        return path
    }

    /// The label kind a figure of `kind` takes in the text: `tbl:` for a
    /// table, `fig:` for an image; none for a kind this build does not know.
    static func labelKind(of kind: FigureKind) -> ManuscriptLabel.Kind? {
        switch kind {
        case .table: return .tbl
        case .image: return .fig
        case .unknown: return nil
        }
    }

    /// An image figure's picture renamed through its host: the open one, or
    /// one opened for this and closed after.
    private func renameImageFileThroughHost(figureId: String, to filename: String) async throws {
        guard let documentStore else { return }
        try await documentStore.withFigureHost(figureId) { host in
            try await host.renameImageFile(to: filename)
        }
    }

    /// `record` written over the registry's record with its id, through the
    /// manifest's one door; the registry as it was when the save fails.
    private func replaceFigureRecord(_ record: FigureRecord) async throws {
        guard var figures = manifest.figures,
              let index = figures.firstIndex(where: { $0.id == record.id }) else { return }
        let before = manifest.figures
        figures[index] = record
        manifest.figures = figures
        manifest.modified = Date()
        do { try await saveManifest() } catch {
            manifest.figures = before
            throw error
        }
    }

    /// A renamed table's render, moved to its new file through the typed
    /// mover; the render pass that follows writes it fresh. A file already
    /// standing at the new path goes to the Trash first
    /// (`trashStrayFigureFile`), never overwritten. Best-effort: the render is
    /// derived, so a failure is logged, never a refusal. An old file already
    /// gone is nothing to move.
    private func moveTableRender(from oldPath: String, to newPath: String, documentStore: DocumentStore) async {
        guard let from = try? resolvedProjectPathToChange(oldPath),
              let to = try? resolvedProjectPathToChange(newPath) else { return }
        if from.path.lowercased() != to.path.lowercased() {
            await trashStrayFigureFile(at: newPath)
        }
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        do {
            try await documentStore.moveFigureFile(from: from, to: to)
        } catch {
            projectStoreLog.error(
                "renameFigure: the old render \(oldPath, privacy: .public) was not moved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// **The door an existing figure's structural verb asks**: its
    /// `.editFigure` posture — the window's acting answer, yields and *Edit
    /// Anyway* included (R-6a-8). A refusal or a `.settling` answer throws
    /// `FigureEditRefused`.
    func requireFigurePermitted(
        figureId: String, site: StaticString, documentStore: DocumentStore
    ) async throws {
        let posture = await documentStore.settledPosture(forDocId: figureId, as: .author)
        guard !posture.isSettling, posture.allows(.editFigure) else {
            projectStoreLog.error("\(site, privacy: .public) refused: this device may not change this figure")
            throw FigureEditRefused(site: "\(site)")
        }
    }

    // MARK: - The steps every creation shares

    /// **The door a new figure asks**, before anything is written: the
    /// figure's posture, asked of the class the new figure WILL have
    /// (`.figure(id:, piece:)`), for `.editFigure`. The window's door where a
    /// window holds this book (ruling R-6a-8) — the piece's yields and *Edit
    /// Anyway* apply as they do to its text; windowless, Core's door directly
    /// (RulingPerformer's precedent), and always for a figure made in
    /// another book (`inThisBook: false` — a promotion's staged root, whose
    /// `opStore` is that book's). A refusal, or a `.settling` answer, throws
    /// `FigureEditRefused`.
    func requireNewFigurePermitted(
        figureId: String, piece: String?, opStore: OpLogStore, site: StaticString,
        inThisBook: Bool = true
    ) async throws {
        let posture: Posture
        if inThisBook, let documentStore {
            posture = await documentStore.settledPosture(forNewFigure: figureId, piece: piece)
        } else {
            posture = PostureDoor.posture(as: .author, using: opStore) {
                .figure(id: figureId, piece: piece)
            }
        }
        guard !posture.isSettling, posture.allows(.editFigure) else {
            projectStoreLog.error("\(site, privacy: .public) refused: this device may not make a figure here")
            throw FigureEditRefused(site: "\(site)")
        }
    }

    /// The one place a new figure's ops are minted: this device's author, the
    /// project's op session, the figure's own stream — a promotion's carried
    /// streams too (`writeCarriedFigureStreams`). Asked only after
    /// `requireNewFigurePermitted`.
    private func figureOpMinter(figureId: String) -> (OpKind, FigureOpPayload) -> Op {
        let device = Document.loadIdentities[.author].deviceId
        let session = projectOpSession
        return { kind, payload in
            Op(opId: ULID.generate(), docId: figureId, at: Date(), device: device,
               session: session, kind: kind, changes: [], figure: payload)
        }
    }

    /// Appends a new figure's opening ops in order, then seals them as the
    /// author — the stream, before any record names it.
    private func appendNewFigureStream(_ ops: [Op], figureId: String, opStore: OpLogStore) async throws {
        for each in ops {
            try Self.beforeFigureAppendForTesting?(each)
            try await opStore.append(each)
        }
        _ = try await opStore.sealChain(docId: figureId, actor: .author)
    }

    // MARK: - Carried into a promoted piece's project (report plan 6c Task 4)

    /// **What promoting piece `pieceId` carries of the book's figures**, read
    /// now (rulings Q-4, Q-5): `FigureCarry.figures` over the registry, the
    /// piece's text — its open `Document`, else derived from its op log, never
    /// its `.md` (tripwire 20) — and each figure's state (its open host's,
    /// else the cache's read); then `FigureCarry.leftBehindReads` against
    /// `carriedResearch`, the Research item ids the promotion carries. Read
    /// before the promotion closes the window.
    ///
    /// **What stays reads** (controller ruling, final review I1): the
    /// piece's own figure that another piece's text or a staying figure's
    /// formula or pin reads (`FigureCarry.readByWhatStays`) is copied, not
    /// moved, and listed (`.readInTheCollection`); a staying figure reading
    /// `carriedResearch` is listed (`.collectionFormula`, `.collectionPin`).
    ///
    /// Throws when a piece's text will not derive, when a carried figure will
    /// not read, when one of the piece's own figures is of a kind this build
    /// cannot create, when a figure that stays is parked on a working copy in
    /// `carriedResearch`, or when a moved one is parked on a copy outside it
    /// (final review I2: it would arrive parked for good). Another figure of
    /// an unknown kind is left out and listed (`.unknownKind`).
    func figureCarryPlan(forPiece pieceId: String, carriedResearch: Set<String>) async throws -> FigureCarryPlan {
        let records = manifest.figures ?? []
        guard !records.isEmpty else { return FigureCarryPlan() }
        guard let path = Self.collectDocuments(in: manifest.structure).first(where: { $0.id == pieceId })?.path else {
            throw ProjectStoreError.fileSystemError("Piece not found: \(pieceId)")
        }
        let refs = FigureCarry.references(inText: try figureReadingText(docId: pieceId, path: path))

        let trust = try TrustResolution.resolve(
            projectURL: url, identities: Document.loadIdentities, cache: Document.loadRegistryCache)
        let cache = documentStore?.figureCache ?? FigureCache()
        let facts = DocumentClass.Facts(manifest)
        var states: [String: FigureState] = [:]
        var unreadable: [String: String] = [:]
        for record in records {
            if let open = documentStore?.openFigure(forId: record.id) {
                states[record.id] = open.state
                continue
            }
            do {
                states[record.id] = try cache.state(forFigureId: record.id, in: url, trust: trust, facts: facts)
            } catch {
                unreadable[record.id] = error.localizedDescription
            }
        }

        let found = FigureCarry.figures(
            forPiece: pieceId, records: records,
            referencedLabels: refs.labels, referencedPaths: refs.paths, states: states)
        let parks = FigureCarry.parks(of: states)
        // What stays reads is copied, not moved (final review I1).
        var otherText: [(reader: String, references: FigureCarry.TextReferences)] = []
        for doc in Self.collectDocuments(in: manifest.structure)
        where doc.id != pieceId && doc.pieceKind != .reference {
            guard let docPath = doc.path else { continue }
            otherText.append((doc.title, FigureCarry.references(
                inText: try figureReadingText(docId: doc.id, path: docPath))))
        }
        let readers = FigureCarry.readByWhatStays(
            moved: found.moved, records: records, states: states, otherText: otherText, parks: parks)
        let carry = (
            moved: found.moved.filter { readers[$0.id] == nil },
            copied: records.filter { record in
                readers[record.id] != nil || found.copied.contains { $0.id == record.id }
            })
        let carried = carry.moved + carry.copied
        let unseen = carried.filter { unreadable[$0.id] != nil }
        guard unseen.isEmpty else {
            throw FigureEditInvalid(reason: "These figures could not be read, so the piece was not promoted: "
                + unseen.map { "\($0.name) (\(unreadable[$0.id] ?? ""))" }.joined(separator: ", "))
        }
        // A kind this build cannot create (ruling, plan 6c Task 4 review):
        // the piece's own refuses the promotion before anything is written —
        // moving it would trash it in the Collection with no copy here — and
        // another's is left out, listed, and stays in the Collection.
        let newer = found.moved.filter { !FigureCarry.canRecreate($0, state: states[$0.id]) }
        guard newer.isEmpty else {
            throw FigureEditInvalid(reason: "A newer Maugham made "
                + newer.map(\.name).joined(separator: ", ")
                + ", so this piece can't be promoted until this Mac is updated.")
        }
        // A figure that stays in the Collection — not carried, or carried as
        // a copy — parked on a working copy the promotion carries would be
        // left parked on an item that is gone (controller ruling, plan 6c
        // Task 5 review): refused before anything moves, naming it.
        let movedIds = Set(carry.moved.map(\.id))
        let strandable = records.filter { record in
            !movedIds.contains(record.id)
                && states[record.id]?.parked.map { carriedResearch.contains($0.itemId ?? "") } == true
        }
        if let first = strandable.first {
            throw FigureEditInvalid(
                reason: "\(first.name) is parked in this piece\u{2019}s Research; bring it back before promoting.")
        }
        // A moved figure parked on a working copy that does not go with the
        // piece would arrive parked on an item the new book lacks, for good
        // (controller ruling, final review I2).
        if let first = carry.moved.first(where: { record in
            states[record.id]?.parked.map { !carriedResearch.contains($0.itemId ?? "") } == true
        }) {
            throw FigureEditInvalid(
                reason: "\(first.name) is in Research outside this piece; bring it back before promoting.")
        }
        let skipped = carry.copied.filter { !FigureCarry.canRecreate($0, state: states[$0.id]) }
        let copied = carry.copied.filter { FigureCarry.canRecreate($0, state: states[$0.id]) }
        let kept = carry.moved + copied
        let keptIds = Set(kept.map(\.id))
        let carriedStates = states.filter { keptIds.contains($0.key) }
        let staying = records.filter { !movedIds.contains($0.id) }
        return FigureCarryPlan(
            moved: carry.moved, copied: copied, states: carriedStates, parks: parks,
            ownCopied: Set(readers.keys),
            problems: FigureCarry.leftBehindReads(
                carried: kept, states: carriedStates, carriedResearch: carriedResearch, parks: parks)
                + skipped.map {
                    FigureCarryProblem(figureId: $0.id, cell: nil, source: $0.kind.rawValue, read: .unknownKind)
                }
                + records.compactMap { record in
                    readers[record.id].map {
                        FigureCarryProblem(figureId: record.id, cell: nil, source: $0, read: .readInTheCollection)
                    }
                }
                + FigureCarry.stayingReadsOfCarriedResearch(
                    staying: staying, states: states, carriedResearch: carriedResearch, parks: parks))
    }

    /// A document's text for reading which figures it names: its open
    /// `Document`'s, else derived from its op log, never its `.md` (tripwire
    /// 20).
    private func figureReadingText(docId: String, path: String) throws -> String {
        try documentStore?.document(for: path)?.displayText
            ?? derivedCache.displayText(forDocId: docId, in: url)
    }

    /// **Write `records`' re-created streams into the staged project at
    /// `staging`** (Denver 2026-10-25: promotion re-creates; history stays in
    /// the Collection). Each record keeps its id (Q-5) and, as its `piece`
    /// says it will stand in the new book, asks that book's door for
    /// `.editFigure` (`requireNewFigurePermitted(inThisBook: false)`). Its
    /// stream is `FigureCarry.openingOps` over `states[id]` under `parks`,
    /// minted by `figureOpMinter` — this device's author — and appended and
    /// sealed through the staged root's own `OpLogStore`
    /// (`appendNewFigureStream`, so `beforeFigureAppendForTesting` reaches
    /// it). A parked figure ends parked again (Q-6), naming its working
    /// copy's path in the new book, `researchPaths[itemId]` (final review M1).
    ///
    /// A picture is copied from `figures/` into the staged `figures/` under
    /// its own file name, each side through `SafeRelativePath` (tripwire 58):
    /// the read form here, the change form there. Answers what did not carry
    /// whole: a picture not in `figures/` (`.pictureMissing` — its stream
    /// still names it, as the Collection's did), and one whose bytes are not
    /// the content hash its stream names (`.pictureChanged` — copied as it
    /// is, so nothing is lost). Nothing in the Collection changes.
    ///
    /// Throws for a record with no state, a kind this build cannot create (a
    /// backstop: `figureCarryPlan` decides those first), a refused door or a
    /// failed append; what it wrote before is in `staging`, which the
    /// promotion's rollback removes.
    @discardableResult
    func writeCarriedFigureStreams(
        _ records: [FigureRecord], states: [String: FigureState], parks: [String: String],
        researchPaths: [String: String], into staging: URL
    ) async throws -> [FigureCarryProblem] {
        var problems: [FigureCarryProblem] = []
        let opStore = Document.makeLoadOpStore(projectURL: staging, presenter: nil)
        for record in records {
            guard var state = states[record.id] else {
                throw FigureEditInvalid(reason: "\(record.name) could not be read, so it was not carried")
            }
            if let itemId = state.parked?.itemId, let path = researchPaths[itemId] {
                state.parked?.path = path
            }
            let opening = FigureCarry.openingOps(for: record, state: state, parks: parks)
            guard !opening.isEmpty else {
                throw FigureEditInvalid(
                    reason: "this build cannot re-create \(record.name), a figure of kind \(record.kind.rawValue)")
            }
            try await requireNewFigurePermitted(
                figureId: record.id, piece: record.piece, opStore: opStore,
                site: "writeCarriedFigureStreams", inThisBook: false)
            let ops = FigureCarry.minted(opening, by: figureOpMinter(figureId: record.id))
            try await appendNewFigureStream(ops, figureId: record.id, opStore: opStore)
            if let image = state.image {
                if let problem = try copyCarriedPicture(image, of: record.id, into: staging) {
                    problems.append(problem)
                }
            }
        }
        return problems
    }

    /// `figures/<image.filename>` copied into `staging`'s `figures/` (unless
    /// it is there already), answering `.pictureMissing` when it is not on
    /// disk here and `.pictureChanged` when its bytes are not `image`'s
    /// content hash (copied all the same).
    private func copyCarriedPicture(
        _ image: FigureImageRef, of figureId: String, into staging: URL
    ) throws -> FigureCarryProblem? {
        let relative = "\(Self.figuresFolder)/\(image.filename)"
        let source = try resolvedProjectPath(relative)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return FigureCarryProblem(figureId: figureId, cell: nil, source: image.filename, read: .pictureMissing)
        }
        let destination = try Self.resolvedProjectPathToChange(relative, under: staging)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        guard (try? ContentHash.ofFile(source)) == image.contentHash else {
            return FigureCarryProblem(figureId: figureId, cell: nil, source: image.filename, read: .pictureChanged)
        }
        return nil
    }

    /// `base`, trimmed, or `base_2`, `base_3`… — the first that neither a
    /// figure's name nor its render path already answers to, compared
    /// case-insensitively (the Mac's disk does), nor `alsoTaken` refuses.
    func vacantFigureName(
        basedOn base: String, kind: FigureKind, alsoTaken: (String) -> Bool = { _ in false }
    ) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? (kind == .image ? "figure" : "table") : trimmed
        let records = manifest.figures ?? []
        let names = Set(records.map { $0.name.lowercased() })
        let paths = Set(records.map { $0.path.lowercased() })
        func isTaken(_ candidate: String) -> Bool {
            names.contains(candidate.lowercased())
                || paths.contains(Self.figurePath(name: candidate, kind: kind).lowercased())
                || alsoTaken(candidate)
        }
        guard isTaken(start) else { return start }
        var n = 2
        while isTaken("\(start)_\(n)") { n += 1 }
        return "\(start)_\(n)"
    }

    /// Where a figure's render lives: `figures/<name>.csv` for a table,
    /// `figures/<name>` for an image until its picture arrives. A character a
    /// filename cannot carry becomes `_`; the name itself keeps it.
    static func figurePath(name: String, kind: FigureKind) -> String {
        let safe = String(name.map { "/:\\".contains($0) ? "_" : $0 })
        let file = safe.hasPrefix(".") ? "_" + safe.dropFirst() : safe
        return "\(figuresFolder)/\(file)" + (kind == .table ? ".csv" : "")
    }
}

/// **A figure rename refused before anything changed** (report plan 6b
/// Task 5, ruling P-3): the registry, the files, the text and the formulas
/// are all as they were.
public struct FigureRenameRefused: LocalizedError, Equatable {
    public enum Reason: Equatable {
        /// The new name is empty.
        case emptyName
        /// Another figure is called this, in some case.
        case nameTaken(String)
        /// Another figure's file is at this path, or a file already is.
        case pathTaken(String)
        /// The text holds the figure, and this name cannot be a label.
        case notALabelName(String)
        /// The text already defines this label for something else.
        case labelTaken(String)
        /// These pieces' text cannot be read, so whether they refer to the
        /// figure cannot be checked.
        case unreadable([String])
        /// These pieces hold the figure's line or a reference to it, and
        /// this Mac may not change their text.
        case piecesNotWritable([String])
        /// The figure is parked in Research (final review M-4).
        case inResearch(FigureKind)
        /// The text holds the figure, and these languages' translations of
        /// it can't be read or this Mac may not change them (final review
        /// I-2), so they would keep the old label.
        case translationsNotWritable([String])
        /// A translation in these languages changed between the check and
        /// the write (a translation landing meanwhile): never overwritten.
        case translationChangedMeanwhile([String])
    }

    public let reason: Reason

    public var errorDescription: String? {
        switch reason {
        case .emptyName:
            return "A figure needs a name."
        case .nameTaken(let name):
            return "Another figure is already called \(name)."
        case .pathTaken(let path):
            return "\(path) is already taken in the figures folder."
        case .notALabelName(let name):
            return "\(name) can't be a label in the text: use letters, digits, - and _."
        case .labelTaken(let label):
            return "The text already uses the label \(label)."
        case .unreadable(let titles):
            return titles.joined(separator: ", ")
                + " can't be read, so its references can't be checked."
        case .piecesNotWritable(let titles):
            return "Not renamed — this Mac may not change the text of "
                + titles.joined(separator: ", ") + ", which refers to this figure."
        case .inResearch(let kind):
            return kind == .image
                ? "This picture is in Research; bring it back to rename it."
                : "This table is in Research; bring it back to rename it."
        case .translationsNotWritable(let languages):
            return "Not renamed — the "
                + languages.joined(separator: ", ")
                + " translation can't be changed here, and it refers to this figure."
        case .translationChangedMeanwhile(let languages):
            return "Not renamed — the "
                + languages.joined(separator: ", ")
                + " translation changed while the figure was being renamed. Try again."
        }
    }
}

/// **A removed figure that cannot come back under its own name** (report plan
/// 6b Task 5 review, Denver's ruling): another figure took the name, or its
/// file, meanwhile. The restore is refused rather than given another name,
/// which would leave the text's label for it broken.
public struct FigureRestoreRefused: LocalizedError, Equatable {
    public let name: String
    public var errorDescription: String? {
        "A figure called \(name) already exists; rename it first."
    }
}

/// **What a promotion carries of the book's figures** (report plan 6c Task
/// 4): `ProjectStore.figureCarryPlan`'s answer. `moved` are the piece's own,
/// `copied` the others it names or reads (both in registry order); `states`
/// holds each carried figure's state by id; `parks` every parked figure's
/// cycle (`FigureCarry.parks`); `problems` what they read that stays behind,
/// what stays reads of them or of the piece's Research, and each copied
/// figure left out for its kind.
struct FigureCarryPlan: Sendable {
    var moved: [FigureRecord] = []
    var copied: [FigureRecord] = []
    var states: [String: FigureState] = [:]
    var parks: [String: String] = [:]
    /// The piece's own figures among `copied`: read by something that stays
    /// in the Collection, so copied rather than moved (final review I1).
    var ownCopied: Set<String> = []
    var problems: [FigureCarryProblem] = []

    /// Every carried figure: the moved, then the copied.
    var carried: [FigureRecord] { moved + copied }
}
