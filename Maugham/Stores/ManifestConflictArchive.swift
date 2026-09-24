import Foundation

/// **The name of an archived manifest** — `.maugham/conflicts/manifest-<ts>.json`
/// — spelled once for the writer (`DocumentStore.archiveManifestForConflict`)
/// and the reader (`RemovedElsewhere.scan`), so the date a reader shows is the
/// date the writer stamped and the two cannot drift.
///
/// The stamp is ISO 8601 in UTC with fractional seconds and every `:` turned to
/// `-` (a colon is not a portable filename character). Only the TIME half can
/// have held a colon, so the reader restores them there alone.
enum ManifestConflictArchive {
    static let prefix = "manifest-"
    static let suffix = ".json"

    static func fileName(for date: Date) -> String {
        let stamp = formatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return "\(prefix)\(stamp)\(suffix)"
    }

    /// The moment an archive was written, or nil when `name` is not an archived
    /// manifest — a document's own conflict backup shares the directory, and a
    /// chapter called `manifest.md` backs up as `manifest-<docId>-…md`.
    static func date(fromFileName name: String) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        let halves = stamp.split(separator: "T", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let time = halves[1].replacingOccurrences(of: "-", with: ":")
        return formatter().date(from: "\(halves[0])T\(time)")
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
