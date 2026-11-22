import AppKit

/// **One window step for a whole in-place grid visit** (report plan 7d
/// Task 6; ADR 0023's one exception, after ADR 0026's canvas). While a table
/// is expanded its writes register on the grid's own stack
/// (`FigureGridController.gridUndo`) and the host records them
/// (`FigureDocument.beginVisit`); when it folds, the coordinator registers
/// this ONE step on the window's stack — at the moment of folding, so a
/// sentence typed after the fold sits above it and the first ⌘Z takes the
/// sentence, the second the whole visit (Review Focus 2).
///
/// - **The visit is still landing when the step is registered**: the fold
///   may commit an open edit, and writes asked before it may still be in
///   flight. `visit` ends the recorder once they have all landed; the step's
///   undo and redo await it before anything else.
/// - **undo** takes the whole visit back (`FigureDocument.undoVisit`): cells,
///   rows, sorts and settings in one append run and one render, declined
///   whole — and said — once anything it touched changed elsewhere (R7d-10);
///   **redo** puts it back with the same ids (`redoVisit`). A declined undo
///   leaves the visit applied, so the redo after it does nothing and the
///   next ⌘Z tries again.
/// - **No step for nothing**: a visit that wrote nothing removes the step
///   once it is known; one holding an op with no inverse removes it and says
///   why (`FigureVisit.reason`).
///
/// **No circular await**: the visit's end awaits the grid's writes and the
/// host's undo work as they stood at the fold, and a hop becomes the host's
/// undo work only once the visit has ended (`FigureGridUndoTests`, a ⌘Z
/// pressed while the fold's write is still landing).
///
/// It re-registers itself both ways, as `FigureBirthUndo` does: each
/// re-registration runs synchronously inside the undo or redo pass, which
/// routes it onto the opposite stack; the host's append hops to a task, and
/// the tasks chain, so a redo awaits an undo still landing. The target is
/// this object, which each handler holds strongly (no cycle: it holds
/// neither the manager nor a handler), so the step can be removed by target.
@MainActor
final class FigureVisitUndo {
    /// The window step's name: Edit ▸ Undo reads "Undo Edit Table".
    static let actionName = "Edit Table"

    private weak var host: (any FigureGridHost)?
    private let projectURL: URL
    /// **The session's read-through gate, asked of this figure at each ⌘Z
    /// and ⇧⌘Z** (`FigureWindows.readThroughRefusal`): a step left on another
    /// window's stack cannot write the cells of a figure one of whose pieces
    /// is in read-through. The step stays, refused and said, for a ⌘Z after
    /// Resume.
    private let readThrough: @MainActor () -> ReadThroughRefusal?
    /// What a ⌘Z or ⇧⌘Z says when the figure is no longer open here.
    static let notOpenSentence = "Couldn't undo the table's changes — the table is no longer open."
    /// The visit, once every write the grid asked for has landed and the
    /// recorder has ended; nil when it recorded nothing.
    private let visit: Task<FigureVisit?, Never>
    /// The host's undo-work handle, so a test (and a later visit's batch)
    /// awaits the append (`FigureDocument.awaitPendingUndoWork`).
    private let workTaskSink: ((Task<Void, Never>) -> Void)?
    /// The visit is in the figure (true until an undo lands).
    private var applied = true
    /// The last hop, so the next awaits it.
    private var pending: Task<Void, Never>?
    /// The visit has ended. Until then no hop is the host's undo work: the
    /// visit's end, and a batch still landing, await that work, and a hop
    /// awaits the visit — publishing it sooner would be a circular await.
    private var visitEnded = false
    /// Settled once the step is known to stay or has been removed (a test's wait).
    private(set) var settled: Task<Void, Never>?

    private init(host: any FigureGridHost, visit: Task<FigureVisit?, Never>,
                 readThrough: @escaping @MainActor () -> ReadThroughRefusal?,
                 workTaskSink: ((Task<Void, Never>) -> Void)?) {
        self.host = host
        self.readThrough = readThrough
        projectURL = host.projectURL
        self.visit = visit
        self.workTaskSink = workTaskSink
    }

    /// **Register the visit's one step on `um`**, the window's — at the
    /// fold, outside any undo or redo pass (registers nothing inside one).
    @discardableResult
    static func register(on um: UndoManager, host: any FigureGridHost,
                         visit: Task<FigureVisit?, Never>,
                         readThrough: @escaping @MainActor () -> ReadThroughRefusal?) -> FigureVisitUndo? {
        guard !um.isUndoing, !um.isRedoing else { return nil }
        let step = FigureVisitUndo(host: host, visit: visit, readThrough: readThrough,
                                   workTaskSink: { [weak host] in host?._lastUndoWorkTask = $0 })
        step.registerUndo(on: um)
        step.settled = Task { @MainActor [weak um] in
            let recorded = await visit.value
            step.visitEnded = true
            // A ⌘Z pressed while the visit was still landing is the host's undo work now.
            if let pending = step.pending { step.workTaskSink?(pending) }
            guard recorded?.isUndoable != true else { return }
            // Nothing to take back, or nothing that can be: no step.
            if let um, !um.isUndoing, !um.isRedoing { um.removeAllActions(withTarget: step) }
            if let reason = recorded?.reason { MaughamEvent.postNotice(reason, projectURL: host.projectURL) }
        }
        return step
    }

    /// **Refused by read-through**: said, nothing written. A refused ⌘Z puts
    /// the step back on the undo stack once this pass has ended, so a ⌘Z
    /// after Resume takes it back; a refused ⇧⌘Z is said and the redo goes
    /// (a known limit, ADR 0039 §4: AppKit offers no way back onto the redo
    /// stack from outside a pass).
    private func refusedByReadThrough(on um: UndoManager?, undoing: Bool) -> Bool {
        guard let refusal = readThrough() else { return false }
        MaughamEvent.postNotice(refusal.because("this table"), projectURL: projectURL)
        if undoing {
            Task { @MainActor [self, weak um] in
                if let um { registerUndo(on: um) }
            }
        }
        return true
    }

    private func registerUndo(on um: UndoManager) {
        um.registerUndo(withTarget: self) { [self, weak um] _ in
            if refusedByReadThrough(on: um, undoing: true) { return }

            if let um { registerRedo(on: um) }
            hop { step, host, visit in
                guard step.applied else { return }
                if await host.undoVisit(visit) { step.applied = false }
            }
        }
        um.setActionName(Self.actionName)
    }

    private func registerRedo(on um: UndoManager) {
        um.registerUndo(withTarget: self) { [self, weak um] _ in
            if refusedByReadThrough(on: um, undoing: false) { return }
            if let um { registerUndo(on: um) }
            hop { step, host, visit in
                guard !step.applied else { return }
                if await host.redoVisit(visit) { step.applied = true }
            }
        }
        um.setActionName(Self.actionName)
    }

    /// The append, after the hop before it and after the visit has landed.
    /// A visit that cannot be taken back has already been said and its step
    /// removed; a figure no longer open (removed from the book) is said.
    private func hop(_ body: @escaping @MainActor (FigureVisitUndo, any FigureGridHost, FigureVisit) async -> Void) {
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            guard let recorded = await self.visit.value, recorded.isUndoable else { return }
            guard let host = self.host, !host.isClosed else {
                MaughamEvent.postNotice(Self.notOpenSentence, projectURL: self.projectURL)
                return
            }
            await body(self, host, recorded)
        }
        pending = task
        if visitEnded { workTaskSink?(task) }   // else `settled` publishes it
    }
}

/// A visit step held without keeping it: the window's undo stack owns a live
/// step (`EditorCoordinator.figureVisitStepRefs`).
struct WeakFigureVisitUndo {
    weak var step: FigureVisitUndo?
}
