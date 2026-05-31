import Foundation
import MaughamCore

/// Pure, testable core of the Annotations tab's per-project load (Task F.4).
///
/// The view drives the I/O (enumerate filenames, `ensureDownloaded`, `OpLogStore.load`);
/// these two functions hold the only non-trivial logic — which doc ids a project
/// has, and which annotations from a doc's op stream are still open — so they can
/// be unit-tested without touching the filesystem or the actor-backed downloader.
enum AnnotationLoading {

    /// Distinct doc ids present in a project's `.maugham/ops/` directory, given
    /// the bare filenames in that directory.
    ///
    /// Op-log files are named `<docId>.<deviceSlug>.jsonl` (per-device) or the
    /// legacy unsuffixed `<docId>.jsonl`. A doc id is minted as `doc-<hex>` (or
    /// `scene-<hex>` for screenplay scenes) — ADR 0008 — and never contains a
    /// dot, so the id is exactly the filename component before the first `.`.
    /// The returned ids are that full form, which is what `OpLogStore.load(docId:)`
    /// consumes: `load` re-globs `<docId>.*` itself.
    ///
    /// We deliberately do NOT validate the id's *format* (the Mac's `OpLogStore`
    /// doesn't either — it trusts the structure to supply real ids). Only the
    /// synthetic `__project__` stream (tasks/checkpoints — no annotations) and
    /// non-`.jsonl` files are excluded.
    static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
        var ids = Set<String>()
        for name in filenames {
            guard let id = docId(fromOpLogFilename: name) else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Open annotations from one document's merged op stream: replay to the
    /// current paragraph map (`Deriver`), derive the annotation projection
    /// (`AnnotationDeriver`), and keep only those still `.open` (accepted /
    /// rejected / archived are resolved and don't belong on the triage list).
    static func openAnnotations(ops: [Op]) -> [Annotation] {
        let paragraphs = Deriver.derive(ops: ops).paragraphs
        return AnnotationDeriver.derive(ops: ops, paragraphs: paragraphs)
            .filter { $0.status == .open }
    }

    // MARK: - Private

    /// Parse one filename into its doc id, or nil if it isn't a doc op-log file.
    /// Shape: `<docId>(.<slug>)?.jsonl`. The doc id is the first dot-separated
    /// component (doc ids contain no dot); the synthetic `__project__` stream is
    /// rejected here since it carries no annotations.
    private static func docId(fromOpLogFilename name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        // Strip the `.jsonl` suffix, then split off an optional `.<slug>` tail.
        let stem = String(name.dropLast(".jsonl".count))
        // The doc id is the first dot-separated component; anything after the
        // id's trailing `.` is the device slug (per-device file) or absent
        // (legacy file). A doc id (`doc-<hex>` / `scene-<hex>`) contains no dot.
        let head = stem.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let candidate = String(head)
        return isDocId(candidate) ? candidate : nil
    }

    /// Any op-log stream id is a doc id EXCEPT the synthetic `__project__`
    /// (project-scope tasks/checkpoints — it carries no annotations). We don't
    /// validate the id's *format*: doc ids are `doc-<hex>` / `scene-<hex>`
    /// (ADR 0008), not a fixed `d_<ULID>` shape, and the Mac's `OpLogStore`
    /// itself never format-checks the id — it's just the filename component
    /// before the first `.`. An earlier `d_`+26-char-ULID check matched ZERO
    /// real files and silently rendered every project as "No open annotations".
    private static func isDocId(_ s: String) -> Bool {
        !s.isEmpty && s != "__project__"
    }
}
