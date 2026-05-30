import Foundation

/// Pure mapping from the recents' op-log download states to the §3.13 header
/// banner the Annotations tab shows (Task F.4). Kept out of the view so the
/// state→copy table is unit-testable without constructing the download actor's
/// enum.
enum AnnotationsBanner {

    /// The banner to render above the annotation list, with the user-facing copy
    /// inline so the §3.13 table is the single source of truth.
    enum Banner: Equatable {
        /// Everything the recents need is downloaded — no banner.
        case none
        /// At least one recent's op log is still faulting in from iCloud.
        case syncing(done: Int, total: Int)
        /// Recents are evicted and nothing is in flight — offer a manual "Sync now".
        case needsDownload
        /// Every recent's download failed — offer a retry.
        case failed

        /// The headline copy for the banner (empty for `.none`). Drives the
        /// §3.13 strings; tests assert these verbatim.
        var text: String {
            switch self {
            case .none:
                return ""
            case let .syncing(done, total):
                return "Syncing \(done) of \(total) projects from iCloud…"
            case .needsDownload:
                return "Recent projects need to download from iCloud"
            case .failed:
                return "Couldn’t reach iCloud. Try again."
            }
        }
    }

    /// Map the set of recents' op-log download states to a banner (§3.13 table).
    ///
    /// Precedence, evaluated against the recents' states:
    ///   - empty input → `.none` (nothing to sync).
    ///   - any `.downloading` → `.syncing(done, total)`, where `total` is the
    ///     number of recents and `done` is those already `.downloaded` (the
    ///     in-flight ones are what's left).
    ///   - all `.failed` → `.failed`.
    ///   - any `.notDownloaded` (none in flight) → `.needsDownload`.
    ///   - otherwise (all `.downloaded`) → `.none`.
    static func banner(forRecentStates states: [DownloadStateLite]) -> Banner {
        guard !states.isEmpty else { return .none }

        let total = states.count
        let downloading = states.contains { $0 == .downloading }
        if downloading {
            let done = states.filter { $0 == .downloaded }.count
            return .syncing(done: done, total: total)
        }

        // No downloads in flight from here on.
        if states.allSatisfy({ $0 == .failed }) {
            return .failed
        }
        if states.contains(where: { $0 == .notDownloaded }) {
            return .needsDownload
        }
        return .none
    }
}

/// A tiny `Equatable` mirror of `DownloadCoordinator.DownloadState`, dropping the
/// `.downloading` progress payload so the banner mapping is value-comparable and
/// unit-testable without spinning up the actor. The view collapses each observed
/// `DownloadState` into one of these before calling `banner(forRecentStates:)`.
enum DownloadStateLite: Equatable {
    case notDownloaded
    case downloading
    case downloaded
    case failed
}
