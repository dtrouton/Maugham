import Foundation

/// Returned by `Document.restoreToOp(opId:)`. Carries the full effect of
/// the restore so the modal can both render a confirmation toast
/// (*"Restored. 3 annotations auto-archived."*) and assert the effect in
/// tests without rummaging through the op log post-hoc.
public struct RewindRestoreResult: Equatable, Sendable {
    /// The appended `.checkpointRestore` op recording the rewind.
    public let restoreOp: Op
    /// Op ids of the `.claudeArchive` ops emitted by the sweep for
    /// annotations whose paragraph_id no longer exists post-restore.
    public let archivedAnnotationOpIds: [String]
    /// Paragraph ids that existed in the pre-restore sequence but not
    /// the post-restore sequence. Drives the impact summary.
    public let removedParagraphIds: [String]
    /// Paragraph count before the restore. For the impact summary.
    public let priorSequenceCount: Int
    /// Paragraph count after the restore.
    public let newSequenceCount: Int

    public init(
        restoreOp: Op,
        archivedAnnotationOpIds: [String],
        removedParagraphIds: [String],
        priorSequenceCount: Int,
        newSequenceCount: Int
    ) {
        self.restoreOp = restoreOp
        self.archivedAnnotationOpIds = archivedAnnotationOpIds
        self.removedParagraphIds = removedParagraphIds
        self.priorSequenceCount = priorSequenceCount
        self.newSequenceCount = newSequenceCount
    }
}
