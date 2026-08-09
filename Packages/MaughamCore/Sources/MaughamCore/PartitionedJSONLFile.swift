import Foundation

/// Filename construction and matching for a **project-scope** append-only JSONL
/// stream that is partitioned per device: `<stem>.<deviceSlug>.jsonl`, with the
/// pre-partition `<stem>.jsonl` still readable as a merge source.
///
/// This is ADR 0012's pattern applied to the sidecars it did not name. ADR 0012
/// restructured the op log (`.maugham/ops/<docId>.<slug>.jsonl`) and the inbox
/// manifest (`.maugham/inbox/inbox.<slug>.jsonl`) because iCloud Drive resolves
/// two writers of one path by whole-file replace, silently dropping the loser as
/// a conflict twin the loader never opens. `.maugham/checkpoints.jsonl` and
/// `.maugham/publications.jsonl` had the identical shape and were simply out of
/// that ADR's scope — CLAUDE.md tripwire 17's own defect, left in place. Two Macs
/// saving inside one sync window lost the loser's rows, and losing a checkpoint
/// destroys the very dangling pointer whose presence would have signalled the
/// loss. Model-checked: `OpLogSync_cpshared` (violates `CheckpointNoLoss`)
/// against `OpLogSync_cppartitioned` (green) — same spec, one constant. See
/// `formal/OpLogSync.tla`.
///
/// **Writers only ever get a per-device URL.** `url(stem:deviceSlug:in:)` cannot
/// return the legacy unsuffixed name, so the OpLogStore legacy rule — read it,
/// never write it, never seal it — falls out of the type rather than out of
/// vigilance. `urls(stem:in:)` is the reader's glob and includes it.
///
/// The stem carries no dot, so the `<stem>.` boundary is unambiguous; the slug is
/// a `DeviceSlug` (tripwire 24) and `.raw` is interpolated only here, at the
/// filename point.
public enum PartitionedJSONLFile {

    /// The file a writer on `deviceSlug` appends to. SINGLE SOURCE OF TRUTH for
    /// the `<stem>.<slug>.jsonl` template — never hand-roll it at a call site.
    public static func url(stem: String, deviceSlug: DeviceSlug, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).\(deviceSlug.raw).jsonl")
    }

    /// Every file a reader must merge for `stem`: the legacy `<stem>.jsonl` plus
    /// one `<stem>.<slug>.jsonl` per device that has ever written here. Sorted by
    /// filename so the merge sees the same order on every device (directory
    /// enumeration order is not guaranteed). Empty when the directory or the
    /// files do not exist.
    public static func urls(stem: String, in directory: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { matches(filename: $0.lastPathComponent, stem: stem) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether `filename` belongs to `stem`'s stream — legacy or per-device. The
    /// predicate half of the template, for classifiers that hold a name rather
    /// than a URL (`MaughamSidecarPath`).
    public static func matches(filename: String, stem: String) -> Bool {
        filename == "\(stem).jsonl"
            || (filename.hasPrefix("\(stem).") && filename.hasSuffix(".jsonl"))
    }

    /// Whether a project-relative path names a file in `stem`'s stream, where
    /// `stem` is itself given relative to the project (`.maugham/checkpoints`).
    /// The relative-path form the backup signature and the sidecar classifier
    /// both work in.
    public static func matches(relativePath: String, stemPath: String) -> Bool {
        let dir = (stemPath as NSString).deletingLastPathComponent
        guard (relativePath as NSString).deletingLastPathComponent == dir else { return false }
        return matches(filename: (relativePath as NSString).lastPathComponent,
                       stem: (stemPath as NSString).lastPathComponent)
    }
}
