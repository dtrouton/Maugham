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
    /// Op-log files are named `d_<docId>.<deviceSlug>.jsonl` (per-device) or the
    /// legacy unsuffixed `d_<docId>.jsonl`. The returned ids are the FULL
    /// `d_<docId>` form (`d_` + the 26-char ULID), which is exactly what
    /// `OpLogStore.load(docId:)` consumes: `load` re-globs `d_<docId>.*` itself,
    /// and the `.` after the id is the unambiguous boundary (confirmed against
    /// `OpLogStore.opLogFileURLs`).
    ///
    /// Non-op-log files (inbox manifests, stray junk) are ignored: only names of
    /// the shape `d_<id>(.<slug>)?.jsonl` with a Crockford-base32 ULID body match.
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

    /// Parse one filename into its `d_<docId>` id, or nil if it isn't an op-log
    /// file. Shape: `d_` + 26-char Crockford-base32 ULID, optionally `.<slug>`,
    /// then `.jsonl`. We validate the ULID body so an inbox file like
    /// `inbox.<slug>.jsonl` or arbitrary junk can never be mistaken for a doc.
    private static func docId(fromOpLogFilename name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        // Strip the `.jsonl` suffix, then split off an optional `.<slug>` tail.
        let stem = String(name.dropLast(".jsonl".count))
        // The doc id is the first dot-separated component; anything after the
        // id's trailing `.` is the device slug (per-device file) or absent
        // (legacy file). `d_<ULID>` itself contains no dot.
        let head = stem.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let candidate = String(head)
        return isDocId(candidate) ? candidate : nil
    }

    /// A doc id is `d_` followed by a 26-char Crockford-base32 ULID. (The
    /// `__project__` synthetic doc has no annotations, so it's intentionally not
    /// matched here.)
    private static func isDocId(_ s: String) -> Bool {
        guard s.hasPrefix("d_") else { return false }
        let body = s.dropFirst(2)
        guard body.count == 26 else { return false }
        // Crockford base32 alphabet (ULID), case-insensitive — excludes I L O U.
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZabcdefghjkmnpqrstvwxyz")
        return body.allSatisfy { allowed.contains($0) }
    }
}
