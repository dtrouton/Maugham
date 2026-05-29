import Foundation

/// A point-in-time read of an iCloud-Drive item's download state, gathered from
/// the `URLUbiquitousItem*` resource keys in a single `resourceValues(forKeys:)`
/// call so the poll loop sees a consistent snapshot.
struct UbiquitousDownloadSnapshot {
    /// `.current` (local copy matches cloud), `.downloaded` (local copy exists
    /// but is stale), or `.notDownloaded` (placeholder only). nil if the key is
    /// unavailable.
    var status: URLUbiquitousItemDownloadingStatus?
    /// Best-effort fractional progress in 0.0...1.0 (the resource key reports
    /// 0...100; the live impl divides). nil if unknown.
    var fractionDownloaded: Double?
    /// A download error reported via `ubiquitousItemDownloadingErrorKey`, if any.
    var error: Error?
}

/// The narrow slice of FileManager / URL-resource access the download poll loop
/// needs, factored out so the loop is testable without a real iCloud container.
/// The production impl wraps `FileManager.default` + `URL.resourceValues`.
protocol UbiquitousFileSystem: Sendable {
    /// Kicks off (or no-ops if already local) the download of an evicted
    /// ubiquitous placeholder. Throwing surfaces an immediate "can't even start"
    /// failure (e.g. not actually a ubiquitous item).
    func startDownloadingUbiquitousItem(at url: URL) throws

    /// Reads the current download status / progress / error for `url`. Must NOT
    /// itself trigger a download.
    func downloadSnapshot(at url: URL) -> UbiquitousDownloadSnapshot

    /// Best-effort byte size via `URLResourceKey.fileSizeKey`. nil if unknown.
    /// Must NOT trigger a download.
    func fileSize(at url: URL) -> Int64?
}

/// Production `UbiquitousFileSystem` over `FileManager.default` and
/// `URL.resourceValues`. Reading a placeholder's resource values is cheap and —
/// crucially — does NOT fault in the file, so the poll loop can observe progress
/// without forcing the download itself.
struct LiveUbiquitousFileSystem: UbiquitousFileSystem {
    func startDownloadingUbiquitousItem(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    func downloadSnapshot(at url: URL) -> UbiquitousDownloadSnapshot {
        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // No resource values at all (e.g. not a ubiquitous item / vanished).
            // Report an empty snapshot; the loop treats nil-status as "keep
            // polling," which is correct for a transient read miss.
            return UbiquitousDownloadSnapshot()
        }
        // `ubiquitousItemPercentDownloadedKey` is unavailable on iOS — fractional
        // progress is only exposed via NSMetadataQuery's
        // NSMetadataUbiquitousItemPercentDownloadedKey, which is far heavier than
        // a per-poll resourceValues read. We deliberately don't wire that here:
        // the poll loop falls back to status-driven 0→1 progress when fraction is
        // nil, which is the right tradeoff for op-log files (small, fast). The
        // `fractionDownloaded` field stays in the seam so a richer (metadata-
        // backed) filesystem could populate it without touching the loop.
        return UbiquitousDownloadSnapshot(
            status: values.ubiquitousItemDownloadingStatus,
            fractionDownloaded: nil,
            error: values.ubiquitousItemDownloadingError
        )
    }

    func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}
