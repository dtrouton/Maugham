import AppKit

/// One home for the NSUndoManager registration dance every op-log undo uses.
///
/// The pattern is v0.17.0's accept-undo (`Document+Annotations.swift`,
/// `acceptAnnotation`), which is deliberately NOT refactored onto this helper —
/// accept carries extra manuscript-text-apply choreography (`removeAllActions`,
/// `_undoCoherentApplyPending`) and is regression-scarred. New registrations for
/// resolutions that DON'T touch manuscript text (reject / archive / withdraw /
/// edit) use this; accept keeps its own.
///
/// The trick this encodes: the nested redo registration runs SYNCHRONOUSLY
/// inside the undo closure, so NSUndoManager routes it onto the REDO stack. The
/// mutations themselves are op-log appends (async), so each hops to a task; the
/// `workTaskSink` hands that task back so tests can await it (mirror of
/// `Document._lastUndoWorkTask`).
@MainActor
enum OpUndoRegistrar {
    static func register<T: AnyObject>(
        _ um: UndoManager?, actionName: String, target: T,
        workTaskSink: ((Task<Void, Never>) -> Void)? = nil,
        undo: @escaping @MainActor (T) async -> Void,
        redo: @escaping @MainActor (T) async -> Void
    ) {
        // Never register while itself undoing/redoing: NSUndoManager routes a
        // registration made during undo onto the redo stack (that's how the
        // nested redo below works), so registering at the top level here during
        // an in-flight undo/redo would corrupt the stack.
        guard let um, !um.isUndoing, !um.isRedoing else { return }
        // `[weak um]`: NSUndoManager retains the registered handler, and the
        // handler re-registers onto `um` — a strong capture is a retain cycle
        // that strands the manager (and, transitively, the Document).
        um.registerUndo(withTarget: target) { [weak um] t in
            if let um {
                um.registerUndo(withTarget: t) { t2 in
                    let task = Task { @MainActor in await redo(t2) }
                    workTaskSink?(task)
                }
                um.setActionName(actionName)
            }
            let task = Task { @MainActor in await undo(t) }
            workTaskSink?(task)
        }
        um.setActionName(actionName)
    }
}
