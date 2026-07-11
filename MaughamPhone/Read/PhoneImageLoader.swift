import UIKit
import MaughamCore

/// The phone's one image-load path (the Read tab had zero image rendering before
/// Task 6). Faults an evicted iCloud-Drive image in, reads it coordinated, then
/// decodes a `UIImage`. Eviction-tolerant by contract: a caller that gets `nil`
/// (or a thrown error) shows a placeholder — never an error screen — because a
/// palette card's text must render even when its images can't.
///
/// The read routes through `CoordinatedFileIO.coordinatedRead` (NOT a raw
/// `Data(contentsOf:)`), so it needs no `adr-0018-ok` annotation — the ADR-0018
/// tripwire accepts the coordinated primitive, and these are card assets, not
/// manuscript bodies.
enum PhoneImageLoader {
    static func load(
        _ url: URL, downloads: DownloadCoordinator, io: CoordinatedFileIO
    ) async throws -> UIImage? {
        try await downloads.ensureDownloaded(url)
        let data = try io.coordinatedRead(at: url)
        return UIImage(data: data)
    }
}
