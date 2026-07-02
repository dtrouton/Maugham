import Foundation
import MaughamCore

extension Document {

    public func handleExternalDiskChange(diskMd: String) async throws {
        // A closed doc is husked + abandoned; it shouldn't receive presenter
        // callbacks (the DocumentStore removed the presenter and drained the
        // registry on close), but belt-guard so a stray one can't write a
        // spurious conflict backup against the empty husked `materialize()`.
        guard !isClosed else { return }
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
        try Document.writeConflictBackup(
            forFileAt: url, docId: docId, text: diskMd, kind: "discarded")

        // F7 ping-pong damping. Count discards with DISTINCT bytes; a byte-
        // identical re-delivery of a snapshot we've already seen doesn't advance
        // the counter (`insert` reports it was already present). Once the count
        // reaches `discardDampThreshold`, stop auto-rewriting: the op log stays
        // authoritative in memory and we keep snapshotting, but we no longer
        // bounce the `.md` back at a peer that keeps re-writing it. Log once.
        // A local edit clears the counter (`noteLocalEdit`), re-arming rewriting.
        let isDistinct = noteDiscardDistinct(diskMd)
        if isDistinct { _distinctDiscardCount += 1 }
        if _distinctDiscardCount >= Document.discardDampThreshold {
            if !_discardDampLogged {
                _discardDampLogged = true
                documentLog.error(
                    "external-discard ping-pong damped for \(self.docId, privacy: .public) after \(self._distinctDiscardCount, privacy: .public) distinct discards — snapshotting only, no longer rewriting the .md until a local edit")
            }
            return
        }
        autosaveScheduler.schedule(())
        await autosaveScheduler.flush()
    }

    public func handleExternalLogChange() async throws {
        // A closed doc is husked + abandoned; belt-guard so a stray presenter
        // callback can't re-derive state from disk and RESURRECT the husk
        // (rebuilding paragraphs/sequence into a doc no reader observes).
        guard !isClosed else { return }
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

    // MARK: - Conflict backups (forensic snapshots of discarded / diverged bytes)

    /// The `.maugham/conflicts/` directory for the project that contains `url`.
    /// Resolves the project root via `resolveProjectURL` — which walks UP to the
    /// manifest — so a Collection piece at `pieces/<NN>-<slug>/<file>.md` files
    /// its backups under the PROJECT root, not the piece folder (F8). A fixed
    /// two-level `deletingLastPathComponent` landed Collection backups in
    /// `pieces/.maugham/conflicts/` where nothing ever looks.
    static func conflictsDir(for url: URL) -> URL {
        resolveProjectURL(for: url).appendingPathComponent(".maugham/conflicts")
    }

    /// The newest K conflict backups to retain per doc; older ones are pruned on
    /// every successful write (F7 — an uncapped `.maugham/conflicts/` grew a
    /// backup on every ping-pong rewrite bounce).
    static let conflictBackupRetention = 20

    /// Writes `text` as a forensic backup of the manuscript file `url` under
    /// `<project>/.maugham/conflicts/<stem>-<docId>-<kind>-<stamp>.<ext>`,
    /// returning the URL written. The op log is untouched — this only preserves
    /// bytes about to be discarded (a while-open external edit) or that diverged
    /// from op-log truth while the app was closed (F4). Static so `Document.load`
    /// can call it before a `Document` instance exists.
    ///
    /// The filename carries `docId` (F7/Phase-3 correction) because two Collection
    /// pieces can share a file stem (`pieces/01/scene.md`, `pieces/02/scene.md`)
    /// yet land in the SAME project-scope conflicts dir — grouping retention and
    /// dedup on stem alone would cross-prune them. `MaughamSidecarPath` classifies
    /// on the `.maugham/conflicts/` prefix, not the filename, so the naming change
    /// is transparent to path routing.
    @discardableResult
    static func writeConflictBackup(
        forFileAt url: URL, docId: String, text: String, kind: String,
        at date: Date = Date()
    ) throws -> URL {
        let conflictsDir = conflictsDir(for: url)
        try FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)
        let filename = url.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let stamp = ISO8601DateFormatter.quarantineStamp(from: date)
        let base = "\(stem)-\(docId)-\(kind)-\(stamp)"
        let backupName = ext.isEmpty ? base : "\(base).\(ext)"
        let backupURL = conflictsDir.appendingPathComponent(backupName)
        try text.data(using: .utf8)?.write(to: backupURL, options: [.atomic])
        // Stamp the backup's mtime with the logical snapshot time so retention
        // and dedup order by *when the divergence happened*, not by the atomic
        // rename's wall clock (which ties when several land in the same tick).
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: backupURL.path)
        pruneConflictBackups(
            in: conflictsDir, forDocFileStem: stem, docId: docId, ext: ext,
            keeping: conflictBackupRetention)
        return backupURL
    }

    /// All conflict backups for the manuscript file `url` + `docId`, newest
    /// first (by mtime). Matched by the `<stem>-<docId>-` prefix — the trailing
    /// `-` keeps `docId` `d1` from matching `d10-…`, and the stem+docId pairing
    /// keeps two same-stem Collection pieces from colliding.
    private static func conflictBackups(
        in dir: URL, forDocFileStem stem: String, docId: String, ext: String
    ) -> [URL] {
        let prefix = "\(stem)-\(docId)-"
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let matches = entries.filter { entry in
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix) else { return false }
            // An extensionless doc must not match a candidate that carries an
            // extension (e.g. `c1` should not dedup against `c1.md`).
            return suffix.isEmpty
                ? (name as NSString).pathExtension.isEmpty
                : name.hasSuffix(suffix)
        }
        return matches.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db
        }
    }

    /// The most-recently-written conflict backup for the manuscript file `url`
    /// + `docId` (any `kind`), or nil if none exists. Used to dedup repeated
    /// snapshots of an unchanged divergent file.
    static func newestConflictBackup(forFileAt url: URL, docId: String) -> URL? {
        let filename = url.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return conflictBackups(
            in: conflictsDir(for: url), forDocFileStem: stem, docId: docId,
            ext: ext).first
    }

    /// Prunes the doc's conflict backups to the newest `keeping`, deleting the
    /// rest. Called after every write so the dir can't grow unbounded (F7).
    private static func pruneConflictBackups(
        in dir: URL, forDocFileStem stem: String, docId: String, ext: String,
        keeping: Int
    ) {
        let ordered = conflictBackups(
            in: dir, forDocFileStem: stem, docId: docId, ext: ext)
        guard ordered.count > keeping else { return }
        for stale in ordered[keeping...] {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
