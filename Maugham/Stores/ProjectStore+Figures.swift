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
            let filename = "\(candidate).\(ext)"
            let destination = folder.appendingPathComponent(filename)
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
        let copied = folder.appendingPathComponent(claimed.filename)
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

    // MARK: - The steps every creation shares

    /// **The door a new figure asks**, before anything is written: the
    /// figure's posture, asked of the class the new figure WILL have
    /// (`.figure(id:, piece:)`), for `.editFigure`. The window's door where a
    /// window holds this book (ruling R-6a-8) — the piece's yields and *Edit
    /// Anyway* apply as they do to its text; windowless, Core's door directly
    /// (RulingPerformer's precedent). A refusal, or a `.settling` answer,
    /// throws `FigureEditRefused`.
    private func requireNewFigurePermitted(
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
