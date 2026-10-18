// Maugham/Updates/UpdateLimits.swift
import Foundation

/// The updater's size ceilings, in one place. A release is ~30 MB today, so
/// every limit here is generous by an order of magnitude: they exist to bound
/// a broken or hostile release (a disk-filling download), never to refuse an
/// honest one.
public struct UpdateLimits: Sendable, Equatable {
    /// The most bytes one update download may be. Checked twice: against the
    /// release's declared `asset.size` before a byte is fetched, and against
    /// the bytes actually received while the download runs (the declaration
    /// is the server's claim, the count is ours).
    public var maxDownloadBytes: Int64

    public init(maxDownloadBytes: Int64) {
        self.maxDownloadBytes = maxDownloadBytes
    }

    public static let standard = UpdateLimits(maxDownloadBytes: 512 * 1024 * 1024)
}
