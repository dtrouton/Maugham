import AppKit

/// **One ⌘Z for a figure line and the figure it made** (report plan 7b,
/// R7b-5; Denver 2026-10-25, spec §12 item 7). Insert ▸ Table and Convert to
/// Table Figure make a figure in the store, then write its line through Route A
/// (`applyCommandEdit`); the line's `alongside:` registration lands here,
/// inside the text's own undo group, so the text and the figure are ONE step:
///
/// - **undo** sends the figure to the project Trash (`ProjectStore.removeFigure`,
///   which answers its Trash entry);
/// - **redo** brings the same figure back from that entry, id kept
///   (`ProjectStore.restoreTrashEntry`).
///
/// It re-registers itself BOTH ways, unlike `OpUndoRegistrar` (whose redo
/// registers no undo, so ⌘Z ⇧⌘Z ⌘Z would bring the text back out without the
/// figure). Each re-registration runs synchronously inside the undo or redo
/// pass — which is what routes it onto the opposite stack, into the same
/// group as the text's — and the store verb hops to a task. The tasks chain: a
/// redo awaits a removal still in flight.
///
/// **A refusal still moves the text** (the text is the native step and has
/// already moved); the writer is told why through `report` — the editor's
/// `commandFailureReporter`. A refused removal leaves the figure in the book; a
/// refused restore (`FigureRestoreRefused`, its name taken meanwhile) leaves it
/// in the Trash — the redone line, whose path is the name's, now shows the
/// other figure that has that name (Denver's ruling, report plan 7b) — and the
/// next ⌘Z does not try to remove either of them. A Route B wipe or a document switch drops the
/// registration, leaving the figure where it is (accepted).
@MainActor
final class FigureBirthUndo {
    private let figureId: String
    private let actionName: String
    /// `[weak]`: the async hop must not keep a closed book alive (OpUndoRegistrar's
    /// note). Gone means nothing is left to change.
    private weak var store: ProjectStore?
    private let report: @MainActor (String) -> Void
    private let workTaskSink: ((Task<Void, Never>) -> Void)?
    /// The figure's Trash entry while it is in the Trash (after a removal, and
    /// after a refused restore); nil while it is in the book.
    private var trashEntryId: String?
    /// The last store verb, so the next awaits it.
    private var pending: Task<Void, Never>?

    /// Runs at the start of a removal (a test suspends it there, so a redo
    /// arrives while it is in flight: the store's removal otherwise runs to
    /// its end on the main actor before the redo's task starts).
    static var beforeRemovalForTesting: (@MainActor () async -> Void)?

    private init(figureId: String, actionName: String, store: ProjectStore,
                 report: @escaping @MainActor (String) -> Void,
                 workTaskSink: ((Task<Void, Never>) -> Void)?) {
        self.figureId = figureId
        self.actionName = actionName
        self.store = store
        self.report = report
        self.workTaskSink = workTaskSink
    }

    /// Registers the figure's birth on `um`. Call it inside the text edit's
    /// undo group (`applyCommandEdit(... alongside:)`). Registers nothing while
    /// `um` is itself undoing or redoing (OpUndoRegistrar's guard).
    static func register(on um: UndoManager, figureId: String, actionName: String,
                         store: ProjectStore,
                         report: @escaping @MainActor (String) -> Void,
                         workTaskSink: ((Task<Void, Never>) -> Void)? = nil) {
        guard !um.isUndoing, !um.isRedoing else { return }
        let birth = FigureBirthUndo(figureId: figureId, actionName: actionName, store: store,
                                    report: report, workTaskSink: workTaskSink)
        birth.registerUndo(on: um)
    }

    // The target is the manager itself: NSUndoManager does NOT retain a
    // target (a handler whose target has gone traps in the Swift overlay —
    // measured, with `self` as the target), and the manager is alive whenever
    // it invokes a handler. Each handler holds `self` strongly; `self` holds
    // neither the manager nor a handler, so there is no cycle.

    private func registerUndo(on um: UndoManager) {
        um.registerUndo(withTarget: um) { [self] um in
            registerRedo(on: um)
            remove()
        }
        um.setActionName(actionName)
    }

    private func registerRedo(on um: UndoManager) {
        um.registerUndo(withTarget: um) { [self] um in
            registerUndo(on: um)
            restore()
        }
        um.setActionName(actionName)
    }

    /// The figure to the Trash — unless it is already there (a refused restore
    /// left it).
    private func remove() {
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            guard self.trashEntryId == nil, let store = self.store else { return }
            await Self.beforeRemovalForTesting?()
            do {
                self.trashEntryId = try await store.removeFigure(id: self.figureId).id
            } catch {
                self.report(Self.removalRefusedMessage(error))
            }
        }
        pending = task
        workTaskSink?(task)
    }

    /// The same figure back from its Trash entry — unless it never left (a
    /// refused removal kept it in the book).
    private func restore() {
        // The line is already back (the text's redo ran first): its card
        // comes back with it, before the restore lands (whole-branch I2).
        store?.documentStore?.readoptFigureCard(figureId: figureId)
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            guard let entry = self.trashEntryId, let store = self.store else { return }
            do {
                try await store.restoreTrashEntry(id: entry)
                self.trashEntryId = nil
            } catch {
                // The registry did not change, so no manifest watch refills
                // the cards: refill them here, or the card readopted above
                // would stay (re-review N1).
                store.documentStore?.invalidateFigureCards()
                self.report(Self.restoreRefusedMessage(error))
            }
        }
        pending = task
        workTaskSink?(task)
    }

    /// What the writer is told when ⌘Z took the line back but not its figure.
    static func removalRefusedMessage(_ error: Error) -> String {
        if error is FigureEditRefused {
            return "The text was taken back, but this Mac may not change its figure, so the figure stays in the book."
        }
        return "The text was taken back, but its figure stays in the book: \(error.localizedDescription)"
    }

    /// What the writer is told when ⇧⌘Z put the line back but not its figure.
    /// A name taken meanwhile says what the line now shows: the other figure
    /// called that, since the line's path is the name's.
    static func restoreRefusedMessage(_ error: Error) -> String {
        if let taken = error as? FigureRestoreRefused {
            return "The figure line is back, but it now shows the other figure called \(taken.name); "
                + "the figure it made stays in the Trash."
        }
        return "The figure line is back, but its figure stays in the Trash: \(error.localizedDescription)"
    }
}
