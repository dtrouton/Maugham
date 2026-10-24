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
        // The window's door where a window holds this book (ruling R-6a-8):
        // the piece's yields and Edit Anyway apply as they do to its text.
        // Windowless, Core's door directly (RulingPerformer's precedent).
        let posture: Posture
        if let documentStore {
            posture = await documentStore.settledPosture(forNewFigure: figureId, piece: piece)
        } else {
            posture = PostureDoor.posture(as: .author, using: opStore) {
                .figure(id: figureId, piece: piece)
            }
        }
        guard !posture.isSettling, posture.allows(.editFigure) else {
            projectStoreLog.error("createFigure refused: this device may not make a figure here")
            throw FigureEditRefused(site: "createFigure")
        }

        let device = Document.loadIdentities[.author].deviceId
        let session = projectOpSession
        func op(_ kind: OpKind, _ payload: FigureOpPayload) -> Op {
            Op(opId: ULID.generate(), docId: figureId, at: Date(), device: device,
               session: session, kind: kind, changes: [], figure: payload)
        }
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
        for each in ops {
            try Self.beforeFigureAppendForTesting?(each)
            try await opStore.append(each)
        }
        _ = try await opStore.sealChain(docId: figureId, actor: .author)

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
        return placed
    }

    /// `base`, trimmed, or `base_2`, `base_3`… — the first that neither a
    /// figure's name nor its render path already answers to, compared
    /// case-insensitively (the Mac's disk does).
    func vacantFigureName(basedOn base: String, kind: FigureKind) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? (kind == .image ? "figure" : "table") : trimmed
        let records = manifest.figures ?? []
        let names = Set(records.map { $0.name.lowercased() })
        let paths = Set(records.map { $0.path.lowercased() })
        func isTaken(_ candidate: String) -> Bool {
            names.contains(candidate.lowercased())
                || paths.contains(Self.figurePath(name: candidate, kind: kind).lowercased())
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
