import Foundation
import MaughamCore

/// The rewind confirm sheet's and after-toast's single source of numbers.
///
/// RULING-28: the collateral report has two halves — the confirmation states
/// the FULL set of collateral changes before the writer commits, and the
/// post-restore report confirms what actually happened. Naming one class and
/// omitting another is worse than naming none, so `preview` mirrors every
/// class `Document.restoreToOp` acts on (the step-7 sweep, the step-8
/// stranded-accept resolution, the step-9 return journey) and `toast` renders
/// the result those steps produced. `changesAnything` is RULING-37's view
/// half: Restore is not offered when there is nothing to do. Pure — computed
/// from the modal's op snapshot, no I/O.
enum RewindImpact {

    struct Preview: Equatable {
        var wordsUndone: Int
        var paragraphsRemoved: Int
        /// Open annotations anchored to paragraphs the rewind removes — the
        /// step-7 sweep's mirror.
        var annotationsToArchive: Int
        /// Sweep-archived annotations whose paragraph exists at the cursor —
        /// the step-9 reopen arm's mirror (RULING-25).
        var annotationsToReopen: Int
        /// Accepted suggestions whose accept lies past the cursor on a
        /// surviving paragraph — the step-8 revert mirror.
        var acceptsToReopen: Int
        /// Archived-from-accepted suggestions whose paragraph and accept both
        /// sit at-or-before the cursor — the step-9 accepted arm's mirror
        /// (RULING-26).
        var acceptsToRestore: Int
        var changesAnything: Bool
    }

    private static let statusKinds: Set<OpKind> = [
        .claudeAccept, .claudeReject, .claudeArchive,
        .claudeAcceptRevert, .annotationReopen
    ]
    private static let taskKinds: Set<OpKind> = [
        .taskCreate, .taskStatusChange, .taskPriorityChange,
        .taskParentChange, .taskBodyEdit, .taskArchive
    ]

    static func preview(ops: [Op], cursorOpId: String?) -> Preview {
        var p = Preview(wordsUndone: 0, paragraphsRemoved: 0,
                        annotationsToArchive: 0, annotationsToReopen: 0,
                        acceptsToReopen: 0, acceptsToRestore: 0,
                        changesAnything: false)
        guard let cursorOpId else { return p }
        let now = Deriver.deriveWithSequenceFallback(ops: ops)
        let target = Deriver.derive(ops: ops, upTo: .atOp(opId: cursorOpId, at: Date()))
        let nowSet = Set(now.sequence)
        let targetSet = Set(target.sequence)
        let removed = nowSet.subtracting(targetSet)

        p.paragraphsRemoved = removed.count
        p.wordsUndone = removed.compactMap { now.paragraphs[$0] }
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)

        let annotations = AnnotationDeriver.derive(ops: ops, paragraphs: now.paragraphs)
        var lifecycleBySource: [String: [Op]] = [:]
        for op in ops where statusKinds.contains(op.kind) {
            if let src = op.provenance?.sourceAnnotationId {
                lifecycleBySource[src, default: []].append(op)
            }
        }

        for ann in annotations {
            guard let pid = ann.paragraphId else { continue }
            switch ann.status {
            case .open:
                if ann.kind != .craftNote, removed.contains(pid) {
                    p.annotationsToArchive += 1
                }
            case .archived:
                guard targetSet.contains(pid) else { break }
                let lifecycle = (lifecycleBySource[ann.id] ?? []).sorted { $0.opId < $1.opId }
                guard let last = lifecycle.last, last.kind == .claudeArchive,
                      last.provenance?.synthesisSource == .rewind else { break }
                let before = lifecycle.dropLast().last
                let wasOpen = before == nil
                    || before?.kind == .claudeAcceptRevert
                    || before?.kind == .annotationReopen
                if wasOpen {
                    p.annotationsToReopen += 1
                } else if before?.kind == .claudeAccept,
                          let textAccept = lifecycle.last(where: {
                              $0.kind == .claudeAccept && !$0.changes.isEmpty }) {
                    if cursorOpId >= textAccept.opId {
                        p.acceptsToRestore += 1
                    } else {
                        // Step 9's else-arm: a target before the accept
                        // reopens to .open — the class the branch review
                        // caught this preview omitting.
                        p.annotationsToReopen += 1
                    }
                }
            case .accepted:
                if let textAccept = (lifecycleBySource[ann.id] ?? []).filter({
                       $0.kind == .claudeAccept && !$0.changes.isEmpty })
                       .max(by: { $0.opId < $1.opId }),
                   textAccept.opId > cursorOpId,
                   targetSet.contains(pid) {
                    p.acceptsToReopen += 1
                }
            case .rejected:
                break
            case .stetted:
                // A stet moved no text, so rewinding past one restores no
                // text either. Task 2 decides whether the preview should
                // count a stet the way it counts an archive; until a verb
                // can write one, there is nothing here to preview.
                break
            }
        }

        let textChanges = now.paragraphs != target.paragraphs
            || now.sequence != target.sequence
        let cursorIdx = ops.firstIndex { $0.opId == cursorOpId }
        let taskOpsAfter = cursorIdx.map { idx in
            ops.dropFirst(idx + 1).contains { taskKinds.contains($0.kind) }
        } ?? false
        p.changesAnything = textChanges || taskOpsAfter
        return p
    }

    /// The confirm-sheet sentence: every non-zero class named, zero classes
    /// omitted entirely.
    static func confirmSummary(_ p: Preview) -> String {
        var parts: [String] = []
        parts.append("Restoring would undo \(p.wordsUndone) words / "
                     + "\(p.paragraphsRemoved) paragraph\(p.paragraphsRemoved == 1 ? "" : "s") "
                     + "written after this point.")
        if p.annotationsToArchive > 0 {
            parts.append("\(p.annotationsToArchive) note\(p.annotationsToArchive == 1 ? "" : "s") will be archived.")
        }
        if p.annotationsToReopen > 0 {
            parts.append("\(p.annotationsToReopen) note\(p.annotationsToReopen == 1 ? "" : "s") will be reopened.")
        }
        if p.acceptsToReopen > 0 {
            parts.append("\(p.acceptsToReopen) accepted suggestion\(p.acceptsToReopen == 1 ? "" : "s") reopened.")
        }
        if p.acceptsToRestore > 0 {
            parts.append("\(p.acceptsToRestore) suggestion\(p.acceptsToRestore == 1 ? "" : "s") restored to accepted.")
        }
        return parts.joined(separator: " ")
    }

    /// The after-toast: what the restore actually did, or nil when a genuine
    /// no-op left nothing worth saying. A `.nearest` resolution is ALWAYS
    /// worth saying (RULING-27: the substitution is named), even when the
    /// nearest moment turned out to be the present.
    static func toast(for r: RewindRestoreResult) -> String? {
        var parts: [String] = []
        if case .nearest = r.targetResolution {
            parts.append("That exact moment is gone — restored to the nearest surviving one.")
        }
        if r.restoreOp != nil || !parts.isEmpty {
            var body = "Restored."
            let archived = r.archivedAnnotationOpIds.count
            let reopened = r.travelReopenedAnnotationIds.count
            let reaccepted = r.travelReacceptedAnnotationIds.count
            let acceptsReopened = r.reopenedAnnotationOpIds.count
            if archived > 0 { body += " \(archived) note\(archived == 1 ? "" : "s") auto-archived." }
            if reopened > 0 { body += " \(reopened) note\(reopened == 1 ? "" : "s") reopened." }
            if acceptsReopened > 0 { body += " \(acceptsReopened) accepted suggestion\(acceptsReopened == 1 ? "" : "s") reopened." }
            if reaccepted > 0 { body += " \(reaccepted) suggestion\(reaccepted == 1 ? "" : "s") restored to accepted." }
            parts.append(body)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
