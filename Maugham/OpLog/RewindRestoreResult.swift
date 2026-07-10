import Foundation
import MaughamCore

/// Returned by `Document.restoreToOp(opId:)`. Carries the full effect of
/// the restore so the modal can both render a confirmation toast
/// (*"Restored. 3 annotations auto-archived."*) and assert the effect in
/// tests without rummaging through the op log post-hoc.
public struct RewindRestoreResult: Equatable, Sendable {
    /// The appended `.checkpointRestore` op recording the rewind, or
    /// `nil` when the rewind was a no-op (target state equals current —
    /// e.g. rewinding to the latest op in the log). A nil here means
    /// nothing was appended to the op log; spec §7.5 specified
    /// non-optional but the no-op case made that unsound (a sentinel
    /// `Op(opId: "")` would silently propagate through any caller that
    /// inspected `restoreOp.opId`).
    public let restoreOp: Op?
    /// Op ids of the `.claudeArchive` ops — both emitted by the sweep for
    /// annotations whose paragraph_id no longer exists post-restore, and appended
    /// by the stranded-accept resolution pass for accepted suggestions whose change was reverted.
    public let archivedAnnotationOpIds: [String]
    /// Paragraph ids that existed in the pre-restore sequence but not
    /// the post-restore sequence. Drives the impact summary.
    public let removedParagraphIds: [String]
    /// Paragraph count before the restore. For the impact summary.
    public let priorSequenceCount: Int
    /// Paragraph count after the restore.
    public let newSequenceCount: Int
    /// Creation-op ids of accepted suggestions whose `claudeAccept` lay past
    /// the rewind target: the restore reverted their applied text, so the
    /// restore also appended a changes-free `claudeAcceptRevert` per id to
    /// return them to `.open` (a stranded "accepted" row whose change no
    /// longer exists would otherwise hide in the resolved filter).
    public let reopenedAnnotationOpIds: [String]
    /// True when the rewound range (target op → restore op) contained
    /// task-lifecycle ops, i.e. a `.rewind`-stamped restore opened a
    /// `TaskDeriver` rewind window that excludes them. The undo of such a
    /// restore must close that window again (append a `.rewind`-flavored task
    /// marker keyed on THIS restore's op id) or the pane's task state stays
    /// rewound after ⌘Z brings text + annotations back.
    public let rewoundTaskOps: Bool

    public init(
        restoreOp: Op?,
        archivedAnnotationOpIds: [String],
        removedParagraphIds: [String],
        priorSequenceCount: Int,
        newSequenceCount: Int,
        reopenedAnnotationOpIds: [String],
        rewoundTaskOps: Bool = false
    ) {
        self.restoreOp = restoreOp
        self.archivedAnnotationOpIds = archivedAnnotationOpIds
        self.removedParagraphIds = removedParagraphIds
        self.priorSequenceCount = priorSequenceCount
        self.newSequenceCount = newSequenceCount
        self.reopenedAnnotationOpIds = reopenedAnnotationOpIds
        self.rewoundTaskOps = rewoundTaskOps
    }
}
