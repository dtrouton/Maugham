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
            let store = JSONLAppendStore<Op>(
                fileURL: url, presenter: presenter,
                dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
            let result = try await store.loadDiagnosed()
            merged.append(contentsOf: result.elements)
            skipped.append(contentsOf: result.diagnostics.skipped)
        }
        return (Self.mergeSortedDedup(merged), ParseDiagnostics(skipped: skipped))
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
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
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
        }
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
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let op = try? dec.decode(Op.self, from: lineData) else { continue }
                ops.append(op)
            }
        }
        return mergeSortedDedup(ops)
    }

    /// Collapse a union of op arrays: opId-sorted, first-wins dedupe. Each
    /// source file is already internally deduped+sorted; this collapses any
    /// cross-file opId overlap (e.g. an op in both legacy and a per-device file).
    nonisolated static func mergeSortedDedup(_ ops: [Op]) -> [Op] {
        var seen = Set<String>()
        return ops
            .sorted { $0.opId < $1.opId }
            .filter { seen.insert($0.opId).inserted }
    }
}
