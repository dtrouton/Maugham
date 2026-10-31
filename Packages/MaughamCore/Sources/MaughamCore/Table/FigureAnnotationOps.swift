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
    public static func suggestedCell(from text: String, at key: CellKey, table: FigureTable,
                                     names: FormulaNames) -> Result<Cell?, FormulaParseError> {
        FigureCellEntry.cell(from: text, prior: table[key], table: table, names: names, locale: machine)
    }
}
