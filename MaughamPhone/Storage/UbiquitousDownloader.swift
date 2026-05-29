import Foundation

/// Abstracts the iCloud-Drive download primitive so `DownloadCoordinator`'s
/// dedup + budget logic is unit-testable without a real ubiquitous container.
/// The production conformer is `CoordinatedFileIO` (Task D0.2); tests inject a
/// mock.
protocol UbiquitousDownloader: Sendable {
    /// Best-effort byte size for cold-launch budget accounting
    /// (`URLResourceKey.fileSizeKey`). nil if unknown. Must NOT trigger a
    /// download.
    func fileSize(at url: URL) -> Int64?

    /// Downloads `url` from iCloud Drive, yielding fractional progress in
    /// 0.0...1.0 and finishing the stream when the file is locally `.current`.
    /// Throws into the stream on download error. Honors Task cancellation
    /// (stops polling and finishes by throwing `CancellationError`).
    func download(at url: URL) -> AsyncThrowingStream<Double, Error>
}
