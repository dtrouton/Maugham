import Foundation
import MaughamCore

extension Document {

    public func handleExternalDiskChange(diskMd: String) async throws {
        // Echo guard: this is the file change we ourselves just wrote.
        // `lastDiskEcho` is updated atomically inside the autosave's
        // coordinated-write block, so by the time the presenter callback
        // hops back to the main actor the snapshot is already in place.
        guard diskMd != lastDiskEcho.bytes else { return }

        let derivedMd = materialize()
        let classification = Reconciler.classify(
            diskMd: diskMd, derivedMd: derivedMd)

        switch classification {
        case .echo:
            return

        case .silentIngest(let changes):
            // Construct an external_edit op carrying the changes.
            let op = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .externalEdit,
                changes: changes,
                sequence: nil,
                provenance: .init(synthesisSource: .diskAtIngest))
            try await opStore.append(op)
            _opLogMirror.append(op)
            invalidateAnnotationsCache()
            invalidateTasksCache()   // silent ingest changed paragraph text → re-derive inline tasks
            // Update internal state.
            for change in changes {
                paragraphs[change.paragraphId] = change.next
            }
            lastDiskEcho = .afterIngest(bytes: diskMd)
            recomputeDisplayText()

        case .needsSheet(let orphanCount):
            // Surface a pending conflict. UI reads document.pendingConflict.
            pendingConflict = ConflictState(
                path: url.path,
                localText: derivedMd,
                externalText: diskMd,
                externalModifiedAt: Date())
            _ = orphanCount  // (currently unused; could feed into the UI sheet)
        }
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

    public func resolveConflictKeepMine() async throws {
        guard let conflict = pendingConflict else { return }

        // Preserve the external version as a conflict backup before
        // overwriting (matches DocumentStore's existing backup behaviour).
        try writeConflictBackup(text: conflict.externalText, kind: "cloud")

        // Schedule an autosave of our current derived state. The disk
        // re-write happens via the autosave path.
        autosaveScheduler.schedule(())
        await autosaveScheduler.flush()
        pendingConflict = nil
    }

    public func resolveConflictUseExternal() async throws {
        guard let conflict = pendingConflict else { return }

        // Preserve our local version as a backup before accepting external.
        try writeConflictBackup(text: conflict.localText, kind: "local")

        // Ingest the external bytes as a synthesized external_edit op,
        // same as the silent-ingest path would have done if IDs had been
        // intact.
        try await handleExternalDiskChangeForceIngest(diskMd: conflict.externalText)
        pendingConflict = nil
    }

    private func handleExternalDiskChangeForceIngest(diskMd: String) async throws {
        // For "Use cloud" resolution: ignore the Reconciler classification
        // and ingest the diskMd verbatim. The new paragraphs may get fresh
        // IDs minted by restoreComments since the user-typed IDs are gone.
        let priorStored = materialize()
        let nextStored = RenderFilter.restoreComments(
            stored: priorStored, displayEdited:
                RenderFilter.stripComments(diskMd))
        let parsed = ParagraphParser.parse(nextStored)

        var newParagraphs: [String: String] = [:]
        var newSequence: [String] = []
        var changes: [Op.ParagraphChange] = []
        for p in parsed {
            guard let id = p.id else { continue }
            let prior = paragraphs[id]
            newParagraphs[id] = p.text
            newSequence.append(id)
            if prior != p.text {
                changes.append(.init(paragraphId: id, prior: prior, next: p.text))
            }
        }

        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .externalEdit,
            changes: changes,
            sequence: newSequence,
            provenance: .init(synthesisSource: .useCloudResolution))
        try await opStore.append(op)
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
        invalidateTasksCache()   // use-cloud resolution rewrote paragraph text
        let priorSequence = self.sequence
        self.paragraphs = newParagraphs
        self.sequence = newSequence
        self.lastDiskEcho = .afterIngest(bytes: diskMd)
        // Use-cloud conflict resolution can shrink sequence — flag a sweep
        // for any annotations on paragraphs that disappeared. Run sweep
        // directly here (it's already at an async boundary).
        let removedInResolution = Set(priorSequence).subtracting(Set(newSequence))
        if let reason = SweepReason.useCloud(removed: removedInResolution) {
            await sweepOrphanedAnnotations(reason: reason)
        }
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
