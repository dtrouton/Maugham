// Maugham/OpLog/OpLogStore.swift  (now in MaughamCore)
import Foundation

/// Per-document append-only JSONL op log, **partitioned per device** (ADR 0012,
/// spec §3.12). Each device writes only to its own file
/// `.maugham/ops/<docId>.<deviceSlug>.jsonl`; readers glob every sibling for the
/// doc (including the legacy unsuffixed `<docId>.jsonl`) and merge.
///
/// The logical op log is unchanged: the merged, opId-deduped, opId-sorted set of
/// all ops. ULID opIds give a deterministic total order regardless of which file
/// each op came from, so `Deriver`/`Materializer`/rewind see one `[Op]` and don't
/// care how it was assembled. Partitioning exists only so iCloud Drive never has
/// to reconcile two writers of the same path — it resolves divergence by
/// whole-file replace, silently dropping the loser as a conflict-twin the loader
/// would never open.
///
/// The write target is derived from `op.device` itself — an op self-describes the
/// device that created it, which is exactly the file it belongs in — so no caller
/// has to thread a device slug through.
@MainActor
public final class OpLogStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    /// Test-only failure-injection seam. When non-nil, `append` throws this
    /// error instead of writing — letting tests exercise the disk-error
    /// recovery paths (e.g. `Document.close()`'s durable pending-flush
    /// fallback) without an actual unwritable filesystem. Default nil, so
    /// production behaviour is unchanged. `internal` + `@testable import` is
    /// the access surface; not part of the public API.
    var appendFailureForTesting: Error?

    private var opsDir: URL { projectURL.appendingPathComponent(".maugham/ops") }

    /// Glob every file for `docId` (legacy `<docId>.jsonl` + per-device
    /// `<docId>.<slug>.jsonl`), load each (coordinated), and merge: dedupe by
    /// opId, sort by opId. docIds contain no dots (delimiter between id and device
    /// slug), so the `<docId>.` boundary is unambiguous and can't prefix-collide
    /// with another doc. Format is `doc-<hex>` / `scene-<hex>` (ADR 0008) or the
    /// synthetic `__project__`.
    public func load(docId: String) async throws -> [Op] {
        try await loadDiagnosed(docId: docId).ops
    }

    /// Like `load(docId:)` but also surfaces the lines that failed to decode in
    /// any of the globbed per-device files, merged into one `ParseDiagnostics`.
    /// A torn/corrupt line (e.g. a crash mid-`append` leaving a truncated final
    /// line) is excluded from `ops` and reported in `diagnostics.skipped` so the
    /// caller can write a forensic record (`IntegrityQuarantine`) instead of
    /// dropping it silently. `load(docId:)` delegates here and discards the
    /// diagnostics, so existing callers are unaffected.
    public func loadDiagnosed(docId: String)
        async throws -> (ops: [Op], diagnostics: ParseDiagnostics)
    {
        let urls = Self.opLogFileURLs(forDocId: docId, in: projectURL)
        guard !urls.isEmpty else { return ([], ParseDiagnostics()) }
        var merged: [Op] = []
        var skipped: [ParseDiagnostics.SkippedLine] = []
        for url in urls {
            let result = try await Self.loadFileDiagnosed(url: url, presenter: presenter)
            merged.append(contentsOf: result.ops)
            skipped.append(contentsOf: result.diagnostics.skipped)
        }
        return (Self.mergeSortedDedup(merged), ParseDiagnostics(skipped: skipped))
    }

    /// Load + parse ONE op-log file — plain `.jsonl` tail or sealed `.mzseg`
    /// segment — into ops + diagnostics. The single per-file read shared by
    /// `loadDiagnosed(docId:)` and `ProjectIntegrity.check`, so opIds inside
    /// segments stay visible to the dangling-pointer check exactly as tail
    /// opIds are (growth spec §5.4).
    ///
    /// Segment verification failure (bad magic / decompress / checksum) is a
    /// data condition, not an error: surfaced as a `ParseDiagnostics.skipped`
    /// entry (so `ProjectIntegrity.check` marks the doc unhealthy and the
    /// load path quarantines it) while any salvageable decompressed lines
    /// still parse — best-effort, never silent (spec §5.3).
    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics) {
        if url.pathExtension == OpLogSegment.fileExtension {
            let coord = NSFileCoordinator(filePresenter: presenter)
            var coordErr: NSError?
            var bytes: Data?
            coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
                bytes = try? Data(contentsOf: ru)
            }
            if let coordErr { throw coordErr }
            guard let container = bytes else { return ([], ParseDiagnostics()) }

            let decoded = OpLogSegment.decodeVerifying(container)
            var skipped: [ParseDiagnostics.SkippedLine] = []
            if let failure = decoded.failure {
                skipped.append(.init(
                    byteOffset: 0,
                    raw: "<segment \(url.lastPathComponent): \(failure)>"))
            }
            guard let jsonl = decoded.jsonl else {
                return ([], ParseDiagnostics(skipped: skipped))
            }
            let parsed = JSONLAppendStore<Op>.parse(
                bytes: jsonl,
                dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
            // Per-line skips inside a salvaged segment only matter when the
            // container itself verified (otherwise the container record covers it).
            if decoded.isVerified {
                skipped.append(contentsOf: parsed.diagnostics.skipped)
            }
            return (parsed.elements, ParseDiagnostics(skipped: skipped))
        }
        let store = JSONLAppendStore<Op>(
            fileURL: url, presenter: presenter,
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        let result = try await store.loadDiagnosed()
        return (result.elements, result.diagnostics)
    }

    /// Append to the writer's own per-device file, keyed by `op.device`.
    public func append(_ op: Op) async throws {
        if let injected = appendFailureForTesting { throw injected }
        try await store(forDocId: op.docId, deviceSlug: DeviceSlug.make(from: op.device))
            .append(op)
    }

    private func store(forDocId docId: String, deviceSlug: String) -> JSONLAppendStore<Op> {
        JSONLAppendStore<Op>(
            fileURL: Self.opLogFileURL(forDocId: docId, deviceSlug: deviceSlug, in: projectURL),
            presenter: presenter,
            dedupKey: { $0.opId },
            sortedBy: { $0.opId < $1.opId })
    }

    // MARK: - Glob helpers (shared with synchronous readers)

    /// The op-log file URL a writer for `docId` on device `deviceSlug` appends to:
    /// `<projectURL>/.maugham/ops/<docId>.<deviceSlug>.jsonl`. SINGLE SOURCE OF TRUTH
    /// for op-log filename CONSTRUCTION — the producer-side twin of
    /// `docId(fromOpLogFilename:)`. Surfaces (phone `AnnotationWriter`, Mac
    /// `OpLogStore.store`) MUST call this, never hand-roll the `"\(docId).\(slug).jsonl"`
    /// template. See docs/superpowers/notes/cross-surface-contracts.md.
    public nonisolated static func opLogFileURL(
        forDocId docId: String, deviceSlug: String, in projectURL: URL
    ) -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("\(docId).\(deviceSlug).jsonl")
    }

    /// The doc id encoded in an op-log filename, or nil if `name` is not a
    /// manuscript doc op-log file. Filenames are `<docId>(.<slug>)?.jsonl`; the
    /// doc id is the component before the first `.` (doc ids contain no dot) and is
    /// `doc-<hex>` / `scene-<hex>` (ADR 0008). Deliberately NOT format-validated —
    /// this store is id-agnostic by contract; the only excluded stream is the
    /// synthetic `__project__` (tasks/checkpoints — no manuscript content).
    ///
    /// SINGLE SOURCE OF TRUTH for filename→docId. Surfaces (phone + Mac) MUST call
    /// this, never hand-roll a predicate (a stricter local copy is what shipped the
    /// phone-v0.1.1 "No open annotations" bug). Enforced by the reach-around
    /// tripwires; see docs/superpowers/notes/cross-surface-contracts.md.
    public nonisolated static func docId(fromOpLogFilename name: String) -> String? {
        let stem: String
        if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else if name.hasSuffix(".\(OpLogSegment.fileExtension)") {
            // Sealed segment `<docId>.<slug>.seg<NNNN>.mzseg` (ADR 0016).
            stem = String(name.dropLast(".\(OpLogSegment.fileExtension)".count))
        } else {
            return nil
        }
        let head = String(stem.split(separator: ".", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0])
        guard !head.isEmpty, head != "__project__" else { return nil }
        return head
    }

    /// Distinct doc ids among a set of `.maugham/ops/` filenames (per-device +
    /// legacy files for one doc collapse to one id).
    public nonisolated static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
        Set(filenames.compactMap(docId(fromOpLogFilename:)))
    }

    /// Every op-log file URL for `docId` (legacy + per-device). Pure listing,
    /// no read coordination — for readers that need the file set without the
    /// async coordinated load (mtime-change heuristics; the synchronous
    /// local-log readers in ProjectStore+Tasks). Returns [] if the ops dir or
    /// matching files don't exist.
    public nonisolated static func opLogFileURLs(
        forDocId docId: String, in projectURL: URL
    ) -> [URL] {
        let dir = projectURL.appendingPathComponent(".maugham/ops")
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { url in
            let n = url.lastPathComponent
            return n == "\(docId).jsonl"
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".jsonl"))
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".\(OpLogSegment.fileExtension)"))
        }
    }

    /// Sealed-segment URL: `.maugham/ops/<docId>.<deviceSlug>.seg<NNNN>.mzseg`
    /// (ADR 0016 / growth spec §5.1). SINGLE SOURCE OF TRUTH for segment
    /// filename construction — never hand-roll the template (grep tripwires
    /// on both targets enforce; see cross-surface-contracts.md).
    public nonisolated static func segmentFileURL(
        forDocId docId: String, deviceSlug: String, index: Int, in projectURL: URL
    ) -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(
                "\(docId).\(deviceSlug).seg\(String(format: "%04d", index)).\(OpLogSegment.fileExtension)")
    }

    /// Parse `<docId>.<deviceSlug>.seg<NNNN>.mzseg` → NNNN, or nil if `name`
    /// is not a segment of this (docId, deviceSlug) pair.
    nonisolated static func segmentIndex(
        fromFilename name: String, docId: String, deviceSlug: String
    ) -> Int? {
        let prefix = "\(docId).\(deviceSlug).seg"
        let suffix = ".\(OpLogSegment.fileExtension)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Synchronous globbed read+merge, bypassing `NSFileCoordinator`. For the
    /// local-only / heuristic readers that deliberately avoid async
    /// coordination; the async `load(docId:)` is the coordinated path and is
    /// preferred where the call site can await. Same opId dedupe + sort.
    public nonisolated static func loadSyncMerged(
        forDocId docId: String, in projectURL: URL
    ) -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        var ops: [Op] = []
        for url in opLogFileURLs(forDocId: docId, in: projectURL) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if url.pathExtension == OpLogSegment.fileExtension {
                guard let jsonl = OpLogSegment.decodeVerifying(data).jsonl else { continue }
                ops.append(contentsOf: JSONLAppendStore<Op>.parse(bytes: jsonl).elements)
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let op = try? dec.decode(Op.self, from: lineData) else { continue }
                ops.append(op)
            }
        }
        return mergeSortedDedup(ops)
    }

    /// Collapse a union of op arrays into the canonical merged log: opId-sorted,
    /// **content-deterministic, load-order-independent** dedupe. Each source file
    /// is already internally deduped+sorted; this collapses any cross-file opId
    /// overlap (e.g. an op in both legacy and a per-device file).
    ///
    /// The survivor of a same-opId collision must be the SAME regardless of the
    /// order the inputs arrive in — production feeds this from
    /// `contentsOfDirectory` enumeration, whose order is NOT guaranteed, so two
    /// devices with identical logs must still derive identical text. A plain
    /// `.sorted { $0.opId < $1.opId }` is not a stable sort, so a same-opId pair
    /// with DIFFERENT content could survive non-deterministically (the loser
    /// depended on file-enumeration order). We fix that by sorting on a TOTAL
    /// order `(opId, canonicalEncoding)`: two ops with the same opId but different
    /// content always order the same way (by their canonical `.sortedKeys` JSON),
    /// so first-wins-by-opId after the sort yields a deterministic survivor.
    ///
    /// NOTE: a same-opId collision whose payloads DIVERGE is a corruption signal
    /// (ULIDs don't collide; a divergent collision means a replay / hand-recovery
    /// / duplicated op). Picking a deterministic survivor here keeps merge correct;
    /// SURFACING the collision (e.g. via `IntegrityQuarantine`) is worth doing
    /// later but needs the `projectURL`/stamp this pure fn deliberately lacks —
    /// don't entangle it here. See `OpLog/AREA.md` for the resolution contract.
    nonisolated static func mergeSortedDedup(_ ops: [Op]) -> [Op] {
        // Canonical, content-deterministic encoding of an op — the same
        // `.sortedKeys` + ISO8601-fractional date coding the store writes to
        // disk, so the tiebreaker is a stable function of content alone (no
        // ordering/clock/enumeration dependence).
        func canonical(_ op: Op) -> String {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(op)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        var seen = Set<String>()
        return ops
            .sorted { a, b in
                if a.opId != b.opId { return a.opId < b.opId }
                return canonical(a) < canonical(b)
            }
            .filter { seen.insert($0.opId).inserted }
    }
}
