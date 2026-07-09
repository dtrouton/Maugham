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
        //
        // `[weak t]` / `[weak t2]` on the hop tasks (accept's precedent): the
        // async hop must not keep a closed document alive past its window for
        // a post-teardown append. Silent return when gone — nothing left to
        // mutate.
        um.registerUndo(withTarget: target) { [weak um] t in
            if let um {
                um.registerUndo(withTarget: t) { t2 in
                    let task = Task { @MainActor [weak t2] in
                        guard let t2 else { return }
                        await redo(t2)
                    }
                    workTaskSink?(task)
                }
                um.setActionName(actionName)
            }
            let task = Task { @MainActor [weak t] in
                guard let t else { return }
                await undo(t)
            }
            workTaskSink?(task)
        }
        um.setActionName(actionName)
    }
}

/// Undo for inline checkbox flips. Inline tasks are text-is-state — a toggle
/// is a plain `setParagraph` → `.typingBurst`, NO task op — so undo is a
/// guarded flip-back of the paragraph text, not an op inverse.
///
/// The undo-coherent flag keeps the editor's next external buffer apply from
/// wiping the just-registered action (v0.17.0 D2 rule), mirroring
/// `acceptAnnotation`'s use of `_undoCoherentApplyPending`. Unlike accept,
/// this path deliberately does NOT `removeAllActions`: a checkbox flip is
/// length-preserving (`[ ]`↔`[x]`, `[[todo:`↔`[[done:`), so the whole-buffer
/// replace `applyExternalText` performs keeps every native typing-undo range
/// in bounds — interleaved typing undo survives the toggle and pops without
/// the ⌘Z fault (`InlineTaskToggleUndoTests`).
@MainActor
enum InlineToggleUndo {
    static func perform(on doc: Document, paragraphId: String,
                        prior: String, flipped: String,
                        undoManager: UndoManager?) {
        // Set BEFORE the mutation: `setParagraph` writes `displayText`, which
        // drives the editor's next update pass — the pass that consumes this
        // flag and preserves the fresh registration below. (Same ordering
        // intent as accept: flag armed before the observable write.)
        doc._undoCoherentApplyPending = true
        doc.setParagraph(id: paragraphId, text: flipped)
        OpUndoRegistrar.register(
            undoManager, actionName: "Toggle Checkbox", target: doc,
            workTaskSink: { [weak doc] in doc?._lastUndoWorkTask = $0 },
            undo: { d in
                // Fire-time drift guard: only flip back if the paragraph still
                // holds the value THIS toggle wrote; else decline as a loud
                // no-op (an intervening edit would otherwise be clobbered).
                guard d.paragraph(id: paragraphId) == flipped else {
                    documentLog.error("InlineToggleUndo undo: \(paragraphId, privacy: .public) drifted since toggle — ignoring")
                    return
                }
                d._undoCoherentApplyPending = true
                d.setParagraph(id: paragraphId, text: prior)
            },
            redo: { [weak undoManager] d in
                // Re-arm through the forward path, forwarding the LIVE manager
                // so ⌘Z/⇧⌘Z cycles indefinitely (never nil — the T3 dead-cycle
                // regression). Guarded so a drifted redo declines.
                guard d.paragraph(id: paragraphId) == prior else {
                    documentLog.error("InlineToggleUndo redo: \(paragraphId, privacy: .public) drifted since undo — ignoring")
                    return
                }
                InlineToggleUndo.perform(on: d, paragraphId: paragraphId,
                                         prior: prior, flipped: flipped,
                                         undoManager: undoManager)
            })
    }
}
