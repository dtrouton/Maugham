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
        // Flush any un-bursted local work BEFORE the merge (E3a). This
        // re-derives purely from the on-disk ops, so anything that hasn't
        // reached a burst boundary would otherwise be silently discarded the
        // instant a peer op syncs in mid-draft (a second Mac, a phone Accept) —
        // losing up to a burst window of live edits and autosaving the wrong
        // text. Flushing turns them into real ops so they participate in the
        // opId-ordered merge like any peer's. Reuses the tested flush path (the
        // same one `close()` runs) rather than inventing a fold. The flushed op
        // lands in `_opLogMirror` here, BEFORE `opStore.load` below, so the
        // `newOps` echo-filter still sees only the foreign op — our own op is
        // never re-processed as foreign.
        //
        // The guard is the SAME disjunction `flushBurstNow` uses to decide
        // whether to emit (`hadPending || emitOrderingOnly`, Document.swift):
        // `!pending.isEmpty()` catches un-bursted TYPING, and
        // `_orderingChangedSinceLoad` catches a pure REORDER / DELETE, which
        // records nothing in the pending buffer (its sequence IS the payload) —
        // without the second arm that ordering change would be re-derived away.
        if !pending.isEmpty() || _orderingChangedSinceLoad {
            try await flushBurstNow()
        }
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

        // Re-derive from the merged log through the SAME path as
        // `Document.load` (E3c): `deriveWithSequenceFallback` + `reconcile`.
        // The durable guarantee is identity with load — whatever `Document.load`
        // would produce for these ops, the live merge produces. The old
        // hand-rolled empty-sequence-PRESERVE branch made the two diverge.
        // Two behaviors ride on that identity:
        //   1. `deriveWithSequenceFallback` synthesizes a sequence from
        //      first-appearance order for a legacy sequence-less log, where the
        //      bare `Deriver.derive` returns an empty sequence. This subsumes
        //      the old PRESERVE branch: it existed only to stop that empty derive
        //      from clobbering the sequence `Document.load` used to recover from
        //      the parsed `.md`, and ADR 0019 replaced that `.md`-recovery with
        //      this same fallback — so preserving is dead. (An explicit
        //      `sequence: []` op — writer deleted every paragraph — still derives
        //      to [] here exactly as in load; `reconcile` leaves paragraphs alone
        //      when the sequence is empty, matching load.)
        //   2. `reconcile` drops orphan paragraphs (ids the merged `sequence`
        //      no longer references but the deriver's accumulator still carries).
        //      Without it a live merge left orphans the load path trims, so the
        //      inline-task deriver surfaced phantom task rows until reopen.
        let state = Document.reconcile(
            derived: Deriver.deriveWithSequenceFallback(ops: ops))
        let priorSequence = self.sequence
        self.paragraphs = state.paragraphs
        self.sequence = state.sequence
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

        // RULING-33 — status and manuscript may not disagree. A merge is the
        // only thing that can produce a reject beating an already-spliced
        // accept, so this is where the repair belongs; it runs BEFORE the
        // display recompute below so its text change is published in the same
        // pass as the merge's, and before `oldDisplayText` is compared, so a
        // repair correctly disqualifies the pure-append undo-stack
        // preservation (it moves text mid-document, which is exactly the case
        // that preservation excludes).
        if _hasAnyAnnotationOps {
            await repairRejectedButSplicedAnnotations()
        }

        // No conflict UI for log merge. Just publish the new state.
        //
        // E3(b) — preserve the writer's ⌘Z stack across a PURE-APPEND merge.
        // Publishing flows through `applyExternalText`, which does a wholesale
        // `textView.string = …` and clears the native typing-undo stack on every
        // buffer replace (ADR 0023 D1, the v0.16.0 ⌘Z-crash class) unless the
        // apply is flagged undo-coherent. Without this, a remote peer's op — even
        // one only appending a new paragraph elsewhere in the doc — wipes the
        // entire stack.
        //
        // The safe-to-preserve condition is a range-safety invariant, not a
        // paragraph-set one: a preserved native typing-undo action holds absolute
        // character ranges, so it only stays valid if every character offset it
        // could reference is unmoved — i.e. the NEW display text has the OLD
        // display text as a literal prefix. That admits an end-of-document append
        // and nothing else: a reorder or a MID-SEQUENCE insert shifts offsets
        // after the change point and would let a preserved action pop against text
        // that moved (the exact stale-range crash). `hasPrefix` is
        // necessary-and-sufficient; `removedFromLog.isEmpty` is kept as cheap
        // defense-in-depth (a removal can't grow a prefix, but the guard documents
        // intent and short-circuits). Compare the pre-recompute displayText to the
        // freshly recomputed one, then arm — the flag is a one-shot consumed by
        // the bound editor's LATER `EditorSurface.updateNSView` pass; any
        // non-pure-append merge leaves it false → the D1-consistent clear. The
        // caret-aware variant was declined by design (re-opens the v0.16 class).
        let oldDisplayText = self.displayText
        recomputeDisplayText()
        let pureAppend = removedFromLog.isEmpty
            && self.displayText.hasPrefix(oldDisplayText)
        if pureAppend {
            _undoCoherentApplyPending = true
        }
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
