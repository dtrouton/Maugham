import Foundation
import MaughamCore

extension Document {

    public func handleExternalDiskChange(diskMd: String) async throws {
        // Echo guard: the change we ourselves just wrote.
        guard diskMd != lastDiskEcho.bytes else { return }
        // The on-disk file is the clean render (ADR 0019). If it already matches
        // what we would write, there is nothing to discard.
        let ourClean = MarkdownDisplayFilter.stripAnchors(materialize())
        guard diskMd != ourClean else { return }
        // External .md edits are never honored (hard invariant). Snapshot the
        // external bytes forensically under .maugham/conflicts/, then re-materialize
        // the op-log truth over them — the edit is discarded; the op log is
        // untouched. Cross-device sync is unaffected (it flows through the op-log
        // merge in handleExternalLogChange, not the .md).
        try writeConflictBackup(text: diskMd, kind: "discarded")
        autosaveScheduler.schedule(())
        await autosaveScheduler.flush()
    }

    public func handleExternalLogChange() async throws {
        // Reload the log file (OpLogStore.load dedupes by op_id and sorts).
        let ops = try await opStore.load(docId: docId)

        // Echo guard: every op we ourselves appended is already in
        // _opLogMirror. If the disk log has no ops we haven't seen, this
        // is NSFilePresenter firing on our own write — bail out before
        // doing the destructive re-derivation that re-deriving sequence
        // from the log would entail. Without this, every addAnnotation /
        // typingBurst flush would trigger a presenter callback that
        // re-derived state from disk, clobbered sequence (when the legacy
        // op log doesn't capture sequence per burst), and triggered the
        // orphan sweep to mass-archive paragraph-anchored annotations.
        let mirrorIds = Set(_opLogMirror.map(\.opId))
        let newOps = ops.filter { !mirrorIds.contains($0.opId) }
        if newOps.isEmpty {
            return
        }

        // Re-derive from the merged log, but PRESERVE the recovered sequence
        // when the new derivation produces an empty one. The recovery code
        // in Document.load seeded sequence from the parsed .md file for the
        // legacy case where typing_burst ops didn't capture sequence; that
        // recovery happens once at load and would be lost on every external
        // change otherwise.
        let state = Deriver.derive(ops: ops)
        let priorSequence = self.sequence
        self.paragraphs = state.paragraphs
        if state.sequence.isEmpty && !state.paragraphs.isEmpty
           && !self.sequence.isEmpty {
            // Keep the previously-recovered sequence. The new ops added
            // paragraphs that aren't in `self.sequence` will appear at the
            // tail (handled by mutation paths going forward).
        } else {
            self.sequence = state.sequence
        }
        // External op-log changes (cross-Mac sync) can shrink sequence —
        // flag a sweep so any annotations on now-removed paragraphs get
        // auto-archived on the next burst.
        let removedFromLog = Set(priorSequence).subtracting(Set(self.sequence))
        if let reason = SweepReason.externalLog(removed: removedFromLog) {
            flagSweep(reason)
        }
        self._opLogMirror = ops
        // Re-derive the sticky flag from the merged log: cross-Mac sync
        // could deliver annotation ops on a doc that previously had none.
        self._hasAnyAnnotationOps = ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        invalidateAnnotationsCache()
        invalidateTasksCache()   // log merge may have added task ops

        // Sweep only when a paragraph genuinely disappeared (flagged above
        // by comparing priorSequence to the merged-state sequence). For
        // cross-Mac sync that only adds new ops without dropping paragraphs,
        // no sweep is needed — and avoiding it prevents the false-archive
        // cascade when sequence reconstruction differs from the live view.
        if let reason = _pendingSweep {
            await sweepOrphanedAnnotations(reason: reason)
            _pendingSweep = nil
        }

        // No conflict UI for log merge. Just publish the new state.
        recomputeDisplayText()
    }

    private func writeConflictBackup(text: String, kind: String) throws {
        let projectURL = url.deletingLastPathComponent()
            .deletingLastPathComponent()
        let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
        try FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)
        let filename = url.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = ext.isEmpty
            ? "\(stem)-\(kind)-\(stamp)"
            : "\(stem)-\(kind)-\(stamp).\(ext)"
        let backupURL = conflictsDir.appendingPathComponent(backupName)
        try text.data(using: .utf8)?.write(to: backupURL, options: [.atomic])
    }
}
