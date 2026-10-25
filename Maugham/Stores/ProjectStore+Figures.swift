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
    static var beforeFigureRelabelWriteForTesting: (@MainActor (HeldFigureRelabel) async -> Void)?

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
        // A structural verb: it awaits (the door, the appends) before it
        // writes the manifest, so a manifest arriving meanwhile is held and
        // settled after the write, never adopted over the copy it extends.
        beginStructuralVerb(); defer { endStructuralVerb() }
        let figureId = Self.newId(prefix: DocumentClass.figureDocIdPrefix)
        let opStore = Document.makeLoadOpStore(projectURL: url, presenter: documentStore?.presenter)
        try await requireNewFigurePermitted(
            figureId: figureId, piece: piece, opStore: opStore, site: "createFigure")
        let op = figureOpMinter(figureId: figureId)
        var ops = [op(.figureCreate, FigureOpPayload(kind: kind))]
        if kind == .table {
            var used = Set<String>()
            var lastRow: RowID?
            for _ in 0..<max(rows, 0) {
                let id = RowID(TableID.mint(excluding: used))
                used.insert(id.raw)
                ops.append(op(.figureStructure, FigureOpPayload(structure: .insertRow(id, after: lastRow))))
                lastRow = id
            }
            var lastColumn: ColumnID?
            for _ in 0..<max(columns, 0) {
                let id = ColumnID(TableID.mint(excluding: used))
                used.insert(id.raw)
                ops.append(op(.figureStructure, FigureOpPayload(structure: .insertColumn(id, after: lastColumn))))
                lastColumn = id
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
    ///
    /// Needs the window's `DocumentStore` (the coordinated copy), as research
    /// assets do.
    @discardableResult
    public func createImageFigure(
        fromURL source: URL, name: String? = nil, piece: String?,
        avoiding taken: Set<String> = []
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
            op(.figureCreate, FigureOpPayload(kind: .image)),
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
    ///    manuscript route (`holdManuscriptsForFigureRelabel`); one refusing
    ///    refuses the rename, naming each piece.
    /// 4. Then: an image's file is moved and a `figureImageSet` with the same
    ///    hash and the new file name appended (`FigureDocument.renameImageFile`);
    ///    the record's name and path through `saveManifest`; a table's render
    ///    moved to its new file and rendered there (with any figure that
    ///    shared its old file, so a rename that separates two renders both);
    ///    and the text relabelled. Formulas store the figure's id, so they
    ///    show the new name with nothing written (R-D1).
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
        let newPath = try renamedFigurePath(of: record, to: newName)
        try await requireFigurePermitted(figureId: id, site: "renameFigure", documentStore: documentStore)

        let label = Self.labelKind(of: record.kind).flatMap {
            ManuscriptLabel(reference: "\($0.rawValue):\(record.name)")
        }
        var relabel: HeldFigureRelabel?
        if let label {
            relabel = try await holdManuscriptsForFigureRelabel(FigureLabelChange(
                old: label, newName: newName,
                oldFile: (record.path as NSString).lastPathComponent,
                newFile: (newPath as NSString).lastPathComponent))
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
        // the documents: all of them or none (`HeldFigureRelabel.write`). A
        // document that stopped being writable since it was held refuses the
        // whole rename, and the record and the picture go back too.
        if let relabel {
            if let hook = Self.beforeFigureRelabelWriteForTesting { await hook(relabel) }
            do {
                _ = try relabel.write()
            } catch {
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
    /// Its record leaves the registry and its file (a table's render, an
    /// image's picture) goes to the project Trash through the typed mover,
    /// carrying the record, so restoring it brings the figure back
    /// (`restoreRemovedFigure`). Its stream stays (append-only). Its line and
    /// references in the text are left; they read as broken references. The
    /// tables reading it re-render.
    public func removeFigure(id: String) async throws {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        guard let record = manifest.figures?.first(where: { $0.id == id }) else {
            throw FigureEditInvalid(reason: "this figure is not in the book's list of figures")
        }
        try await requireFigurePermitted(figureId: id, site: "removeFigure", documentStore: documentStore)
        await documentStore.closeFigure(figureId: id)

        // Its file goes to the Trash unless another record names it too.
        let shared = (manifest.figures ?? []).contains {
            $0.id != id && $0.path.lowercased() == record.path.lowercased()
        }
        var trashed: TrashEntry?
        if !shared, let file = try? resolvedProjectPathToChange(record.path),
           FileManager.default.fileExists(atPath: file.path) {
            let metadata = try JSONEncoder().encode(record)
            trashed = try await documentStore.trash(
                relativePath: record.path, using: trashStore,
                itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0,
                displayTitle: record.listTitle, subject: .figure)
        }
        manifest.figures = (manifest.figures ?? []).filter { $0.id != id }
        manifest.modified = Date()
        do {
            try await saveManifest()
        } catch {
            manifest.figures = (manifest.figures ?? []) + [record]
            if let trashed { _ = try? await trashStore.restore(trashId: trashed.id) }
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
        let entry = try await trashStore.restore(trashId: entryId, to: restored.path)
        if let landed = entry.restoredRelativePath, landed != restored.path {
            projectStoreLog.error(
                "restoreRemovedFigure: \(removed.name, privacy: .public)'s file landed at \(landed, privacy: .public), not \(restored.path, privacy: .public)")
        }
        manifest.figures = (manifest.figures ?? []) + [restored]
        await documentStore?.renderFigures(changed: [restored.id])
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
    private func trashStrayFigureFile(at relativePath: String) async {
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
    private static func labelKind(of kind: FigureKind) -> ManuscriptLabel.Kind? {
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
        let wasOpen = documentStore.openFigure(forId: figureId) != nil
        let host = try await documentStore.openFigure(figureId: figureId)
        do { try await host.renameImageFile(to: filename) } catch {
            if !wasOpen { await documentStore.closeFigure(figureId: figureId) }
            throw error
        }
        if !wasOpen { await documentStore.closeFigure(figureId: figureId) }
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
    private func requireFigurePermitted(
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
    /// (RulingPerformer's precedent). A refusal, or a `.settling` answer,
    /// throws `FigureEditRefused`.
    func requireNewFigurePermitted(
        figureId: String, piece: String?, opStore: OpLogStore, site: StaticString
    ) async throws {
        let posture: Posture
        if let documentStore {
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
    /// project's op session, the figure's own stream. Asked only after
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
        /// These pieces hold the figure's line or a reference to it, and
        /// this Mac may not change their text.
        case piecesNotWritable([String])
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
        case .piecesNotWritable(let titles):
            return "Not renamed — this Mac may not change the text of "
                + titles.joined(separator: ", ") + ", which refers to this figure."
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
