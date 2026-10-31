import Foundation

/// **The ops a note on a figure is made of** (report plan 9c-1), built once for
/// the Mac, the phone and MCP (tripwire 19). A figure's notes live in the
/// figure's own stream (`docId` = the figure id), anchored by the four flat
/// provenance scalars, and `AnnotationDeriver` reads them like any other note.
///
/// - A suggested change carries its cell as `Op.figure` (`cell`, `next`,
///   `prior`) on the `claudeSuggestion` — never folded as a cell write by
///   `FigureDeriver`, so it stays a suggestion.
/// - **Accept is one op**: a `claudeAccept` carrying the same payload (the cell
///   it writes) and `sourceAnnotationId`. Its undo is a `claudeAcceptRevert`
///   carrying the inverse cell, minted by the host from `FigureInverse` with
///   `lifecycleProvenance`. `FigureDeriver` folds either as the cell set its
///   payload is (`FigureOpPayload.foldKind`).
///
/// A builder makes the op and decides nothing about who may append it, whether
/// the anchor is still live (RULING-5) or whether the note is withdrawn
/// (RULING-22): the caller asks those, as the manuscript's accept does.
public enum FigureAnnotationOps {

    /// Who is writing, when, and from where — the fields every op carries.
    public struct Stamp: Sendable {
        public var figureId: String
        public var device: String
        public var session: String
        public var at: Date
        public var appVersion: String?
        public var osVersion: String?
        public init(figureId: String, device: String, session: String = ULID.generate(),
                    at: Date = Date(), appVersion: String? = nil, osVersion: String? = nil) {
            self.figureId = figureId; self.device = device; self.session = session
            self.at = at; self.appVersion = appVersion; self.osVersion = osVersion
        }
    }

    public enum BuildError: Error, Equatable, Sendable {
        /// A suggested change names one cell: no anchor, or a range, is refused.
        case suggestionNeedsOneCell
        /// A craft note is about the whole figure; it takes no cell.
        case craftNoteTakesNoCell
    }

    // MARK: - Creation

    /// A note's creation op. `anchor` nil is a note on the whole figure.
    /// A `.suggestedChange` needs a single-cell anchor; `suggestedCell` is the
    /// cell it proposes (nil proposes clearing it) and `prior` the cell as it
    /// stood. `language` rides `toolArgs` exactly as `add_query`'s does.
    public static func creation(
        kind: AnnotationKind, anchor: FigureCellAnchor?, body: String,
        suggestedCell: Cell? = nil, prior: Cell? = nil,
        author: AnnotationAuthor?, language: String? = nil,
        reviewPassId: String? = nil, stamp: Stamp
    ) throws -> Op {
        let opKind: OpKind
        var payload: FigureOpPayload?
        switch kind {
        case .comment: opKind = .claudeComment
        case .query: opKind = .claudeQuery
        case .craftNote:
            guard anchor == nil else { throw BuildError.craftNoteTakesNoCell }
            opKind = .claudeCraftNote
        case .suggestedChange:
            guard let anchor, anchor.rowEnd == nil, anchor.columnEnd == nil else {
                throw BuildError.suggestionNeedsOneCell
            }
            opKind = .claudeSuggestion
            payload = FigureOpPayload(
                cell: CellKey(row: anchor.row, column: anchor.column), next: suggestedCell, prior: prior)
        }
        let toolArgs = language.flatMap { try? JSONEncoder().encode(["language": $0]) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return Op(
            opId: ULID.generate(), docId: stamp.figureId, at: stamp.at,
            device: stamp.device, session: stamp.session, kind: opKind, changes: [],
            provenance: Op.Provenance(
                sessionId: stamp.session, toolArgs: toolArgs, annotationBody: body,
                appVersion: stamp.appVersion, osVersion: stamp.osVersion,
                authorSourceKind: author?.sourceKind.rawValue,
                authorDisplayName: author?.displayName,
                reviewPassId: reviewPassId,
                figureRowId: anchor?.row.raw, figureRowEndId: anchor?.rowEnd?.raw,
                figureColId: anchor?.column.raw, figureColEndId: anchor?.columnEnd?.raw),
            figure: payload)
    }

    // MARK: - Accept and its undo

    /// Accept a figure suggestion: one `claudeAccept` that writes `cell` (`next`
    /// over `prior`) and resolves the note.
    public static func accept(annotationId: String, cell: CellKey, next: Cell?, prior: Cell?,
                              stamp: Stamp) -> Op {
        lifecycle(.claudeAccept, annotationId, stamp,
                  figure: FigureOpPayload(cell: cell, next: next, prior: prior))
    }

    /// **A status-only accept**: the note accepted with no cell written —
    /// a comment's *Got it*, a craft note's Accept, a query's Reply (its
    /// words as `userResponse`), and what a stet's or archive's ⌘Z puts back
    /// over a note that was accepted (its cell was never taken back). Folds
    /// as nothing.
    public static func statusOnlyAccept(annotationId: String, userResponse: String? = nil,
                                        stamp: Stamp) -> Op {
        lifecycle(.claudeAccept, annotationId, stamp, userResponse: userResponse)
    }

    /// **A status-only revert**: a status-only accept's ⌘Z — the note open
    /// again, no cell moved (the manuscript's textless revert). Folds as
    /// nothing. A cell-carrying accept's revert is `FigureInverse`'s.
    public static func statusOnlyRevert(annotationId: String, stamp: Stamp) -> Op {
        lifecycle(.claudeAcceptRevert, annotationId, stamp)
    }

    /// **Is this note accepted only in the table?** A suggested change on a
    /// figure's stream writes a cell when accepted, so it is accepted in the
    /// grid and nowhere else (plan 9c-1 ruling): the Mac's queue draws its
    /// Accept disabled with the reason, and the phone never offers it. Asked
    /// of the stream (`docId`) as well as the anchor, so a suggestion whose
    /// anchor will not decode is still never accepted as a paragraph's.
    public static func acceptsOnlyInTheTable(_ annotation: Annotation, docId: String) -> Bool {
        annotation.kind == .suggestedChange
            && (annotation.figureAnchor != nil || DocumentClass.isFigureDocId(docId))
    }

    // MARK: - Dispositions

    public static func reject(annotationId: String, reason: String?, stamp: Stamp) -> Op {
        lifecycle(.claudeReject, annotationId, stamp, userResponse: reason)
    }
    public static func stet(annotationId: String, stamp: Stamp) -> Op {
        lifecycle(.annotationStet, annotationId, stamp)
    }
    public static func archive(annotationId: String, stamp: Stamp) -> Op {
        lifecycle(.claudeArchive, annotationId, stamp)
    }
    /// Reopen a rejected, archived or stetted note. Whether the note is in a
    /// state with a reopen inverse is `AnnotationInverse.reopenOp`'s question.
    public static func reopen(annotationId: String, stamp: Stamp) -> Op {
        lifecycle(.annotationReopen, annotationId, stamp)
    }

    // MARK: - Which op reopens a note (Mac and phone, tripwire 19)

    /// Why `reopen(for:docId:stamp:)` builds nothing.
    public enum ReopenRefusal: Error, Equatable, Sendable {
        /// The note is open: there is nothing to reopen.
        case alreadyOpen
        /// An accepted figure suggestion: its accept wrote a cell, which only
        /// the grid puts back (the accept's ⌘Z, or changing the cell).
        case acceptedInTheTable
    }

    /// **Does an ACCEPTED note of this kind reopen by a status-only revert?**
    /// True for a note whose accept wrote no cell (a comment's *Got it*, a
    /// query's Reply, a craft note's Accept); false for a suggestion on a
    /// figure, whose accept wrote its cell. The one answer the Mac's queue
    /// row, the Mac's reopen, the phone's offer and the phone's writer share.
    public static func reopensAnAccept(_ annotation: Annotation, docId: String) -> Bool {
        annotation.kind != .suggestedChange && !acceptsOnlyInTheTable(annotation, docId: docId)
    }

    /// **The op that reopens a figure note**, by its status: a rejected,
    /// archived or stetted note by `reopen`; an accepted one that wrote no
    /// cell (`reopensAnAccept`) by a status-only revert. Throws a
    /// `ReopenRefusal` for an open note and for an accepted figure suggestion.
    public static func reopen(for annotation: Annotation, docId: String, stamp: Stamp) throws -> Op {
        switch annotation.status {
        case .rejected, .archived, .stetted:
            return reopen(annotationId: annotation.id, stamp: stamp)
        case .accepted:
            guard reopensAnAccept(annotation, docId: docId) else { throw ReopenRefusal.acceptedInTheTable }
            return statusOnlyRevert(annotationId: annotation.id, stamp: stamp)
        case .open:
            throw ReopenRefusal.alreadyOpen
        }
    }

    /// **What every lifecycle op on a figure note carries**: the note it
    /// answers (`sourceAnnotationId`), a rejection's reason, and the stamp's
    /// session and versions. Also what a host stamps on an accept or revert
    /// it re-mints as a compensation (a grid visit's undo and redo).
    /// `sourceCheckpoint` names the checkpoint a restore's revert came from.
    public static func lifecycleProvenance(
        annotationId: String, userResponse: String? = nil, sourceCheckpoint: String? = nil, stamp: Stamp
    ) -> Op.Provenance {
        Op.Provenance(
            sessionId: stamp.session, sourceCheckpoint: sourceCheckpoint, sourceAnnotationId: annotationId,
            userResponse: userResponse, appVersion: stamp.appVersion, osVersion: stamp.osVersion)
    }

    private static func lifecycle(
        _ kind: OpKind, _ annotationId: String, _ stamp: Stamp,
        userResponse: String? = nil, figure: FigureOpPayload? = nil
    ) -> Op {
        Op(opId: ULID.generate(), docId: stamp.figureId, at: stamp.at,
           device: stamp.device, session: stamp.session, kind: kind, changes: [],
           provenance: lifecycleProvenance(annotationId: annotationId, userResponse: userResponse, stamp: stamp),
           figure: figure)
    }

    // MARK: - A suggested value in machine form

    /// The numbers-and-dots form Claude writes: `.` decimal, no grouping, a
    /// formula starting `=` with A1 references by current positions.
    private static let machine = TableLocale(languageTag: "en-US", fallbackRegion: nil)

    /// The cell `text` proposes at `key`: a number, text or `=` formula, read as
    /// the grid reads typed input under a fixed POSIX-style locale (never the
    /// book's), with A1 references turned into ids. The cell's existing format
    /// and alignment are kept. Empty text proposes clearing it (`.success(nil)`).
    ///
    /// **A number never carries a comma** (controller ruling, final review):
    /// read under en-US, `1,500` would be fifteen hundred where a European
    /// writer meant one and a half, `1,234.5` would take a grouping format,
    /// and `1,5` would quietly become text. So a value that is not a formula
    /// and would read as a number with its commas taken out is refused,
    /// naming the form. Text with a comma (`Smith, J.`) and a formula's
    /// argument commas are untouched; `'1,5` proposes the text `1,5`.
    public static func suggestedCell(from text: String, at key: CellKey, table: FigureTable,
                                     names: FormulaNames) -> Result<Cell?, FormulaParseError> {
        if let comma = numberComma(in: text) {
            return .failure(FormulaParseError(message: commaRefusal, offset: comma))
        }
        return FigureCellEntry.cell(from: text, prior: table[key], table: table, names: names, locale: machine)
    }

    /// What a refused comma says: the machine form, with an example.
    public static let commaRefusal =
        "a number in machine form takes '.' for the decimal and no grouping (1500, 1234.5); a comma is not part of it"

    /// The offset of the first comma in `text` when it is not a formula and
    /// reads as a number once its commas are taken out; nil otherwise.
    private static func numberComma(in text: String) -> Int? {
        guard let index = text.firstIndex(of: ",") else { return nil }
        if case .formula = CellInput.parse(text, locale: machine) { return nil }
        guard case .value(.number, _) = CellInput.parse(text.replacingOccurrences(of: ",", with: ""), locale: machine)
        else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }
}
