import Foundation
import MaughamCore

extension Document {

    /// Drop orphan paragraphs from the op-log-derived state: entries in
    /// `paragraphs` whose ids the current `sequence` no longer references.
    /// The deriver's `typing_burst` fold updates paragraph entries but never
    /// deletes them, so a paragraph the writer split / merged away in an
    /// earlier session lingers in the accumulator forever. Left in place these
    /// orphans poison the inline-task deriver (it walks every paragraph, not
    /// just `sequence`) — surfacing phantom checkbox rows in the Tasks pane
    /// with no matching paragraph in the `.md`. Pure and self-contained so it
    /// stays directly testable; operates on the post-crash-recovery derived
    /// state.
    ///
    /// Pre-ADR-0019 this carried three additional branches that rebuilt
    /// content / order from the parsed on-disk `.md`'s anchors (empty-derived
    /// seeding, empty-sequence rebuild, stale-sequence recovery). ADR 0019 made
    /// the op log authoritative — `Document.load` derives content + order from
    /// it alone via `deriveWithSequenceFallback`, never the `.md` — and F2's
    /// fix seeds the op log at Bootstrap for the one state (anchored file +
    /// empty log) branch 1 covered, so those branches were dead and removed.
    internal nonisolated static func reconcile(
        derived: Deriver.DerivedState
    ) -> Deriver.DerivedState {
        var initial = derived
        if !initial.sequence.isEmpty {
            let sequenceIdSet = Set(initial.sequence)
            let paragraphsHasOrphans = initial.paragraphs.keys.contains {
                !sequenceIdSet.contains($0)
            }
            if paragraphsHasOrphans {
                let trimmed = initial.paragraphs.filter {
                    sequenceIdSet.contains($0.key)
                }
                initial = Deriver.DerivedState(
                    paragraphs: trimmed, sequence: initial.sequence)
            }
        }
        return initial
    }

    public static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        try await load(
            url: url, device: device, session: session, presenter: presenter,
            burstIdle: .seconds(30), burstMax: .seconds(90))
    }

    /// Internal overload that accepts custom burst thresholds. Used by tests
    /// to avoid waiting 30 seconds for the default idle threshold.
    internal static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?,
        burstIdle: Duration,
        burstMax: Duration
    ) async throws -> Document {
        // Resolve doc-id by looking up the manifest. For tests + initial
        // setup, fall back to a deterministic id derived from the path.
        let docId = try resolveDocId(for: url)

        // projectURL is wherever `project.maugham.json` lives. Walk up
        // from the doc's URL until we find it. For Novel/Screenplay this
        // is 2 levels up (manuscript/<file>.md → project/); for Collection
        // it can be 3 (pieces/<piece-folder>/<file>.md → project/) or
        // deeper for research notes. Defaulting to a fixed 2-level
        // deletingLastPathComponent landed inside the piece folder for
        // Collections and made every .maugham/ops/<docId>.jsonl path
        // resolve to a non-existent location, silently dropping ops.
        let projectURL = resolveProjectURL(for: url)

        // Bootstrap detection. Per-device partitioning (ADR 0012) means a doc's
        // log may exist only as `<docId>.<slug>.jsonl` with no legacy
        // `<docId>.jsonl`; check the whole globbed set, or a doc whose only
        // writer was a non-current device reads as "no log" and re-bootstraps.
        let logExists = !OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).isEmpty
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: sanctioned manuscript site — stored bytes as bootstrap-import / divergence reference; op log is authoritative
        let parsed = ParagraphParser.parse(storedBytes)
        // ADR 0019: the .md is clean (no anchors), so "the .md has no anchors"
        // no longer signals "needs bootstrap" — that would re-bootstrap every
        // clean file now that clean-`.md` output has shipped. An existing op log
        // is authoritative;
        // only a doc with NO op log (a brand-new or imported plain file)
        // bootstraps from its .md. Reading the .md to MINT ids for that
        // new/imported doc is the sanctioned import read — not reading it as
        // truth for an existing doc. `!parsed.isEmpty` still filters out the
        // transient empty-.md case for a newly-created doc before first
        // autosave (there's nothing to bootstrap); Bootstrap.run also has its
        // own empty-parsed guard, so this is belt-and-braces.
        let needsBootstrap = !logExists && !parsed.isEmpty

        if needsBootstrap {
            _ = try await Bootstrap.run(
                projectURL: projectURL, docId: docId,
                mdURL: url, device: device, session: session)
        }

        let opStore = OpLogStore(projectURL: projectURL, presenter: presenter)
        let pending = PendingBuffer(projectURL: projectURL, docId: docId, device: device)
        try await pending.loadFromDisk()

        let loaded = try await opStore.loadDiagnosed(docId: docId)
        var ops = loaded.ops

        // Forensics (audit 0.6 / Sweep 6): any op-log line that failed to decode
        // — a crash/power-loss mid-`append` leaving a torn final line, or a line
        // written by a newer schema this build can't read — is dropped from the
        // op stream by `loadDiagnosed`. Before, that drop was silent on the
        // normal load path (`IntegrityQuarantine` only ran from the backup gate).
        // Persist a forensic record so nothing vanishes without a trace. This is
        // best-effort: a quarantine-write failure must NEVER abort the load —
        // the manuscript still opens; quarantining is forensics, not a gate.
        if !loaded.diagnostics.skipped.isEmpty {
            let stamp = ISO8601DateFormatter.quarantineStamp(from: Date())
            do {
                _ = try IntegrityQuarantine.record(
                    skipped: loaded.diagnostics.skipped,
                    forDocId: docId, in: projectURL, stamp: stamp)
            } catch {
                documentLog.error(
                    "quarantine-record write failed for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Crash recovery: fold the pending buffer into a real op. Two triggers:
        //
        //   1. pending has un-bursted CHANGES (the classic text-edit path).
        //   2. pending has NO changes but carries a durable `sequence` that
        //      DIFFERS from the op-log-derived sequence — an ordering-only edit
        //      (paragraph delete / pure reorder) that recorded nothing in the
        //      buffer but was stamped onto `pending.sequence` by autosave's
        //      `setSequence` before the crash (F1). Without this the ordering
        //      change was silently dropped and the deleted paragraph resurrected.
        //
        // The difference-check on trigger 2 is LOAD-BEARING: `performAutosave`
        // stamps `pending.setSequence` on every 750ms flush and `close()`
        // re-creates the pending file after the burst flush, so a
        // `{sequence, changes: []}` pending file is the NORMAL post-quit state.
        // Folding it unconditionally would append a junk op on every launch;
        // folding ONLY when the sequences diverge appends exactly one recovery
        // op for a genuinely-unbursted ordering change and nothing for a clean
        // quit. A legacy pending file (pre-ADR-0019) loads `sequence == []` → the
        // second trigger's non-empty guard never fires → behavior unchanged.
        //
        // Order comes from the pending buffer (durable, op-log-domain) — NOT the
        // .md (ADR 0019). A legacy pending file with un-bursted changes but no
        // sequence loads `sequence == []` → we fall back to `sequence: nil`,
        // which the deriver reads as "ordering unchanged", carrying the op log's
        // own last-explicit sequence forward.
        // NOTE (growth spec §4.2): this is a recovery op — correctness over
        // bytes. Keyframing applies only to flushBurstNow.
        let derivedSequenceBeforeRecovery =
            Deriver.deriveWithSequenceFallback(ops: ops).sequence
        let orderingOnlyDivergence = pending.isEmpty()
            && !pending.sequence.isEmpty
            && pending.sequence != derivedSequenceBeforeRecovery
        if !pending.isEmpty() || orderingOnlyDivergence {
            let recoveredSequence = pending.sequence
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: device, session: session, kind: .typingBurst,
                changes: pending.snapshot(),
                sequence: recoveredSequence.isEmpty ? nil : recoveredSequence)
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }

        // ADR 0019: content + order come ONLY from the op log, never from the
        // `.md`'s anchors. `deriveWithSequenceFallback` synthesises a sequence
        // from first-appearance order for legacy logs whose typing bursts
        // predate the always-capture-sequence fix. `reconcile` then drops orphan
        // paragraphs (ids in the accumulator but not in `sequence`) so the
        // inline-task deriver doesn't surface phantom rows. The `.md` on disk is
        // clean (ADR 0019) and plays no part in content or order.
        let initial = Document.reconcile(
            derived: Deriver.deriveWithSequenceFallback(ops: ops))

        // F4: a file edited while Maugham was CLOSED is otherwise silently
        // overwritten by the first autosave, with no `.maugham/conflicts/`
        // trace — the backup-on-discard net (`handleExternalDiskChange`) only
        // covers live presenter events. When a log already existed (so this is
        // NOT the fresh-bootstrap path, whose `.md` IS the seed) and the
        // on-disk display form diverges from the op-log-derived display form,
        // snapshot the on-disk bytes forensically BEFORE the `Document` — and
        // its autosave — exist to clobber them. Compare DISPLAY forms
        // (`stripAnchors` both) so an unmigrated still-anchored file whose
        // content equals op-log truth does not false-positive. Dedup against
        // the newest existing snapshot so repeated open/close of an unchanged
        // divergent file doesn't accumulate identical copies. A backup-write
        // failure must NEVER abort the load — the manuscript still opens; the
        // snapshot is forensics, not a gate (mirrors the quarantine-write above).
        if logExists {
            let derivedRender = MarkdownDisplayFilter.stripAnchors(
                Materializer.materialize(
                    paragraphs: initial.paragraphs, sequence: initial.sequence))
            if MarkdownDisplayFilter.stripAnchors(storedBytes) != derivedRender {
                do {
                    let newest = Document.newestConflictBackup(
                        forFileAt: url, docId: docId)
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }  // adr-0018-ok: conflict-backup snapshot read for dedup, not manuscript truth
                    if newest != storedBytes {
                        _ = try Document.writeConflictBackup(
                            forFileAt: url, docId: docId, text: storedBytes,
                            kind: "diverged")
                    }
                } catch {
                    documentLog.error(
                        "divergence snapshot write failed for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: sanctioned manuscript site — echo-guard baseline; op log is authoritative
        let initialEcho = EchoState.initialLoad(bytes: lastWritten)

        // BurstScheduler with caller-supplied thresholds (defaults: 30s/90s).
        let burstHolder = WeakBurstHolder()
        let burst = BurstScheduler(
            idle: burstIdle, max: burstMax
        ) {
            Task { @MainActor in
                try? await burstHolder.document?.flushBurstNow()
            }
        }

        let doc = Document(
            url: url, docId: docId, device: device, session: session,
            presenter: presenter, opStore: opStore, pending: pending,
            burstScheduler: burst,
            paragraphs: initial.paragraphs, sequence: initial.sequence,
            lastDiskEcho: initialEcho)
        burstHolder.document = doc

        // Initialize autosave + displayText.
        doc.autosaveScheduler = DebounceScheduler<Void>(
            delay: .milliseconds(750)
        ) { [weak doc] _ in
            try? await doc?.performAutosave()
        }
        doc.recomputeDisplayText()
        doc._opLogMirror = ops
        doc._annotationsCacheValid = false
        doc._hasAnyAnnotationOps = ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        return doc
    }
}

/// Looks up the doc-id for a manuscript path. Walks UP the directory tree
/// until it finds `project.maugham.json`, then resolves the doc against
/// that project's manifest. Falls back to a deterministic hash of the
/// path if no manifest is found (test fixtures, headless tooling).
///
/// The walk-up matters for nested doc layouts: Novel/Screenplay projects
/// keep manuscripts at `<project>/manuscript/<file>.md` (2 levels), but
/// Collection projects put pieces at `<project>/pieces/<piece-folder>/<file>`
/// (3 levels) and research notes can be deeper still. A fixed
/// `deletingLastPathComponent().deletingLastPathComponent()` lands inside
/// the piece folder for Collections and silently triggers the hash fallback,
/// producing a docId that doesn't match the manifest's StructureItem.id.
/// Op log files then go to the wrong file, MCP annotations stop resolving,
/// and the editor's live Document gets a fabricated id no other lookup
/// can find.
internal func resolveDocId(for url: URL) throws -> String {
    var probe = url.deletingLastPathComponent()
    let fm = FileManager.default
    // Cap the walk at 16 ancestors so a malformed URL can't infinite-loop.
    for _ in 0..<16 {
        let manifestURL = probe.appendingPathComponent(ProjectManifest.fileName)
        if fm.fileExists(atPath: manifestURL.path) {
            let relativePath = url.path
                .replacingOccurrences(of: probe.path + "/", with: "")
            if let data = try? Data(contentsOf: manifestURL) {  // adr-0018-ok: project manifest JSON read, not manuscript
                let dec = ProjectManifest.makeDecoder()
                if let manifest = try? dec.decode(
                    ProjectManifest.self, from: data),
                   let item = findItemByPath(
                    relativePath, in: manifest.structure) {
                    return item.id
                }
            }
            // Found the manifest but couldn't decode or match. Stop walking;
            // don't keep climbing into an unrelated parent project.
            let relativeFallback = url.path
                .replacingOccurrences(of: probe.path + "/", with: "")
            return "doc-\(StableHash.fnv1a64Hex(relativeFallback))"
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }   // hit root
        probe = parent
    }
    // No manifest found — hash-fallback against the basename so test fixtures
    // still get a stable id.
    let basename = url.lastPathComponent
    return "doc-\(StableHash.fnv1a64Hex(basename))"
}

/// Walks up the directory tree from a doc's URL until it finds the directory
/// that contains `project.maugham.json`. Used by Document.load to anchor
/// `.maugham/ops/<docId>.jsonl` and other project-relative paths. Falls
/// back to two-level deletion (the legacy behavior) if no manifest is found,
/// which keeps test fixtures that fake a project structure without writing
/// a manifest working.
internal func resolveProjectURL(for url: URL) -> URL {
    var probe = url.deletingLastPathComponent()
    let fm = FileManager.default
    for _ in 0..<16 {
        if fm.fileExists(atPath:
            probe.appendingPathComponent(ProjectManifest.fileName).path) {
            return probe
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }
        probe = parent
    }
    // Legacy fallback for tests that don't write a manifest: 2 levels up.
    return url.deletingLastPathComponent().deletingLastPathComponent()
}

private func findItemByPath(_ path: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.path == path { return item }
        if let kids = item.children,
           let found = findItemByPath(path, in: kids) { return found }
    }
    return nil
}

/// Indirection so BurstScheduler's fire closure can reference the
/// Document without a retain cycle.
@MainActor
private final class WeakBurstHolder {
    weak var document: Document?
}

extension ISO8601DateFormatter {
    /// A filesystem-safe timestamp for `.maugham/` sidecar filenames: ISO8601
    /// with fractional seconds, `:` replaced by `-` (colons are illegal in some
    /// filesystems / awkward in URLs). Mirrors the conflict-archive stamp in
    /// `DocumentStore.archiveManifestForConflict` so the two conventions match.
    /// Lives Mac-side because MaughamCore is wall-clock-free (the stamp is
    /// injected into `IntegrityQuarantine.record`).
    static func quarantineStamp(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
