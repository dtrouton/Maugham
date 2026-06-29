import Foundation
import MaughamCore

extension Document {

    /// Reconcile the op-log-derived state with the parsed on-disk `.md`,
    /// applying the four load-time recovery branches that decide what the
    /// writer sees on open. Pure and self-contained: inputs are the derived
    /// op-log state + parsed paragraphs, output is the final state fed into
    /// the `Document` init. Lifted verbatim out of `load` so it is directly
    /// testable; operates on the post-crash-recovery derived state.
    internal nonisolated static func reconcile(
        derived: Deriver.DerivedState,
        parsed: [ParsedParagraph]
    ) -> Deriver.DerivedState {
        var initial = derived
        // Two recovery paths from non-canonical op-log states:
        //
        // 1. Empty paragraphs + tagged on-disk file: `Bootstrap.run`
        //    short-circuited with `allHaveIds` so no bootstrap op was
        //    emitted. Seed paragraphs + sequence from the parsed file.
        //
        // 2. Non-empty paragraphs but empty sequence: an older typing_burst
        //    landed without populating its `sequence` field (predates the
        //    fix that always captures sequence on burst). The deriver
        //    leaves sequence=[] in that case, which collapses displayText
        //    to "" and stops the doc rendering. Recover the sequence from
        //    the parsed on-disk file's id order — that's the source of
        //    truth for paragraph ordering anyway.
        if initial.paragraphs.isEmpty && parsed.contains(where: { $0.id != nil }) {
            var paragraphs: [String: String] = [:]
            var sequence: [String] = []
            for p in parsed {
                guard let id = p.id else { continue }
                paragraphs[id] = p.text
                sequence.append(id)
            }
            initial = Deriver.DerivedState(paragraphs: paragraphs, sequence: sequence)
        } else if initial.sequence.isEmpty && !initial.paragraphs.isEmpty {
            // Legacy log: typing_burst captured changes but not the
            // `sequence` field. The on-disk .md is the more current source
            // for both paragraph text AND order — autosave runs faster
            // than the burst scheduler so the .md reflects edits the op
            // log hasn't seen yet (e.g., user split a paragraph by adding
            // blank lines; autosave wrote the new anchors but the typing
            // burst hasn't fired yet so the new paragraph_ids aren't in
            // initial.paragraphs).
            //
            // Trust parsed entirely when it has anchored paragraphs.
            // Without this, addAnnotation for a freshly-minted paragraph
            // id reads paragraphs[id]=nil and persists prior_text=nil,
            // which silently breaks the staleness check for every
            // markdown annotation on a legacy doc.
            var freshParagraphs: [String: String] = [:]
            var freshSequence: [String] = []
            for p in parsed {
                guard let id = p.id else { continue }
                freshParagraphs[id] = p.text
                freshSequence.append(id)
            }
            if !freshSequence.isEmpty {
                initial = Deriver.DerivedState(
                    paragraphs: freshParagraphs, sequence: freshSequence)
            } else {
                // .md has no anchored content — fall back to whatever
                // the op log gave us so the doc still renders.
                initial = Deriver.DerivedState(
                    paragraphs: initial.paragraphs,
                    sequence: Array(initial.paragraphs.keys))
            }
        }

        // 3. Stale-sequence recovery. The op log's last explicit sequence
        //    may predate paragraph splits / inserts that autosave wrote
        //    to .md but the typing burst never captured (e.g., crash
        //    before flush, or the legacy crash-recovery path above prior
        //    to its sequence fix). When the parsed .md contains anchored
        //    paragraph ids that are NOT in `initial.sequence`, the .md is
        //    the more current source — trust its ordering.
        //
        //    Also drop orphan entries from `paragraphs` whose ids the
        //    new (parsed) sequence doesn't reference. Leaving them in
        //    place pollutes `tasks(filter:)` (the deriver walks every
        //    paragraph in `paragraphs`, not just those in `sequence`)
        //    with stale inline-task derivations.
        let parsedIds = parsed.compactMap(\.id)
        if !parsedIds.isEmpty {
            let parsedIdSet = Set(parsedIds)
            let sequenceIdSet = Set(initial.sequence)
            let parsedHasIdsNotInSequence = !parsedIdSet.isSubset(of: sequenceIdSet)
            let sequenceHasIdsNotInParsed = !sequenceIdSet.isSubset(of: parsedIdSet)
            if parsedHasIdsNotInSequence || sequenceHasIdsNotInParsed {
                var freshParagraphs: [String: String] = [:]
                for p in parsed {
                    guard let id = p.id else { continue }
                    // Prefer the op log's text if the op log knows this id
                    // (it may carry edits autosave hasn't redrawn yet);
                    // fall back to the parsed text otherwise.
                    freshParagraphs[id] = initial.paragraphs[id] ?? p.text
                }
                initial = Deriver.DerivedState(
                    paragraphs: freshParagraphs, sequence: parsedIds)
            }
        }

        // 4. Orphan-paragraph drop. Even when sequence and parsed agree,
        //    `paragraphs` can still carry entries for ids the writer
        //    split / merged away in earlier sessions (typing_burst doesn't
        //    delete entries from the deriver's accumulator, only updates
        //    them; once a paragraph_id is dropped from `sequence` its
        //    last-known text lingers forever in the in-memory map).
        //    These orphans poison the inline-task deriver (it walks every
        //    paragraph, not just sequence) — surfacing phantom checkbox
        //    rows in the Tasks pane that have no matching paragraph in
        //    the .md. Restrict `paragraphs` to keys in `sequence`.
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
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(storedBytes)
        // `parsed.isEmpty` (empty .md) used to satisfy `allSatisfy { id == nil }`
        // vacuously, triggering bootstrap that emitted a junk op with empty
        // changes + empty sequence. Filter empty .md out explicitly. The
        // empty case happens transiently for newly-created docs before
        // first autosave; there's nothing to bootstrap. Bootstrap.run also
        // has its own empty-parsed guard, so this is belt-and-braces.
        let needsBootstrap = (!logExists || parsed.allSatisfy { $0.id == nil })
            && !parsed.isEmpty

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

        // Crash recovery: fold any pending changes into a real op.
        // Order comes from the pending buffer (durable, op-log-domain) — NOT the
        // .md (ADR 0019). Autosave stamps `pending.sequence` with the live order
        // before each flush, so the un-bursted changes recover their paragraph
        // ordering without consulting the .md's parsed anchors. A legacy pending
        // file (pre-ADR-0019, no sequence) loads `sequence == []` → we fall back
        // to `sequence: nil`, which the deriver reads as "ordering unchanged",
        // carrying the op log's own last-explicit sequence forward.
        // NOTE (growth spec §4.2): this is a recovery op — correctness over
        // bytes. Keyframing applies only to flushBurstNow.
        if !pending.isEmpty() {
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

        let initial = Document.reconcile(
            derived: Deriver.derive(ops: ops), parsed: parsed)
        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
            if let data = try? Data(contentsOf: manifestURL) {
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
