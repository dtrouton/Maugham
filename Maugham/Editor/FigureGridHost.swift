import AppKit
import MaughamCore

/// **What the table grid writes through** (report plan 8b Task 6): what
/// is asked of a grid's host through `FigureGridController.host` — by the
/// controller, the coordinator's in-place visit and its `FigureVisitUndo` —
/// so the same grid can edit a table figure (`FigureDocument`) or — next — a
/// table kept in Research. Nothing reached through a grid needs to know which.
///
/// - **The state is observable**: the controller reads `state` inside
///   `withObservationTracking`, so a conformer is `@Observable` and announces
///   a change of `state` on the main actor.
/// - **Every mutator asks its own door** and throws its refusal; the grid
///   says it. Each takes the grid's `undoManager` and registers its step
///   there (one ⌘Z per call).
/// - **The in-place visit** (`beginVisit`…) is the coordinator's, reached
///   through the controller, and its one window step (`FigureVisitUndo`)
///   undoes through the same host: a host never expanded in place begins no
///   visit (`beginVisit` answers false), so it records none and is never
///   asked to undo one.
/// - **`offers`** says which of the figure's own commands the grid shows and
///   performs; the controller asks it before offering one.
@MainActor
protocol FigureGridHost: AnyObject {
    /// The id the grid is keyed by (one grid per host, `FigureWindows`).
    var figureId: String { get }
    var projectURL: URL { get }
    /// The table, its pins and park, as the host holds it now (observed).
    var state: FigureState { get }
    /// Closed: every mutator refuses.
    var isClosed: Bool { get }
    /// The figure-only commands this host's grid offers.
    var offers: FigureGridOffers { get }

    /// Every undo or redo hop already asked has landed.
    func awaitPendingUndoWork() async
    /// The host's last undo or redo hop: the fold awaits it, and a visit's
    /// window step publishes its own hop here (`FigureVisitUndo`).
    var _lastUndoWorkTask: Task<Void, Never>? { get set }
    /// The table read again from where it is kept (another writer's change).
    func reload() async throws

    // MARK: Cells and structure

    func setCell(_ cell: Cell?, at key: CellKey, undoManager: UndoManager?) async throws
    func setCells(_ edits: [CellKey: Cell?], actionName: String, undoManager: UndoManager?) async throws
    func insertRow(after: RowID?, undoManager: UndoManager?) async throws -> RowID
    func insertColumn(after: ColumnID?, undoManager: UndoManager?) async throws -> ColumnID
    func deleteRow(_ id: RowID, undoManager: UndoManager?) async throws
    func deleteColumn(_ id: ColumnID, undoManager: UndoManager?) async throws
    func moveRow(_ id: RowID, after: RowID?, undoManager: UndoManager?) async throws
    func moveColumn(_ id: ColumnID, after: ColumnID?, undoManager: UndoManager?) async throws
    func sortRows(by column: ColumnID, ascending: Bool, values: (CellKey) -> CellValue,
                  actionName: String, undoManager: UndoManager?) async throws
    func setHeaderRows(_ rows: Int, undoManager: UndoManager?) async throws
    func setTotalRow(_ total: Bool, undoManager: UndoManager?) async throws
    func setColumnWidth(_ column: ColumnID, _ width: Double?, undoManager: UndoManager?) async throws
    /// A batch planned against `expecting`, refused when the state moved.
    func applyChanges(_ changes: [FigureReturnDiff.Change], expecting: FigureState,
                      actionName: String, undoManager: UndoManager?) async throws
    /// The research pins re-read (offered only where `offers.refreshPins`).
    func refreshPins(undoManager: UndoManager?) async throws

    // MARK: The in-place visit (the coordinator's)

    /// Begins recording the grid's writes for one fold step; false when this
    /// host records no visit (or one is already open).
    @discardableResult
    func beginVisit(undoManager: UndoManager) -> Bool
    /// The open visit, ended: nil when it recorded nothing.
    func endVisit() -> FigureVisit?
    /// The visit `manager` began, ended; nil when it owns none.
    func endVisit(ownedBy manager: UndoManager) -> FigureVisit?
    /// The open visit has recorded a write.
    var visitHasRecorded: Bool { get }
    /// A folded visit taken back, or put back, as one step; false when declined.
    @discardableResult
    func undoVisit(_ visit: FigureVisit) async -> Bool
    @discardableResult
    func redoVisit(_ visit: FigureVisit) async -> Bool
}

/// **The figure's own commands a grid offers** — a figure offers them all;
/// a host that is not a figure says which it has.
struct FigureGridOffers: Equatable {
    /// The bottom bar's name field.
    var nameField: Bool
    /// A typed name is written (`ProjectStore.renameFigure`).
    var rename: Bool
    /// The bottom bar's caption field (the figure line's text).
    var caption: Bool
    /// Send to Research.
    var sendToResearch: Bool
    /// Refresh from Research (the pins).
    var refreshPins: Bool
    /// ⤢, the figure's own window.
    var openInWindow: Bool

    static let figure = FigureGridOffers(nameField: true, rename: true, caption: true,
                                         sendToResearch: true, refreshPins: true, openInWindow: true)
}

/// A figure is the grid's first host: no behaviour changes, and every
/// figure command is offered.
extension FigureDocument: FigureGridHost {
    var offers: FigureGridOffers { .figure }
}
