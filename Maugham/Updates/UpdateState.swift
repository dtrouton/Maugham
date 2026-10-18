import Foundation

/// State of the auto-updater. See 2026-06-01-mac-auto-update-design.md §"Data flow".
public enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(version: String, progress: Double)
    /// A new version has been downloaded AND verified (signature + Team ID +
    /// notarization). `bundleURL` is the staged `Maugham.app`, ready to swap in.
    case readyToInstall(bundleURL: URL, version: String, releaseNotes: String)
    /// The swap helper is launching / the app is about to quit.
    case installing(version: String)
    case error(String)
    case upToDate(currentVersion: String)
    /// A newer Maugham exists, but its build needs a macOS this Mac does not
    /// run. **Not an update**: nothing is downloaded, nothing is offered, and
    /// the writer is told in one sentence why. Up-to-date-shaped everywhere
    /// that draws the updater — this Mac is on the newest Maugham it can run.
    /// See `MinimumSystemVersion` and the plan's D4.
    case newerBuildNeedsNewerSystem(currentVersion: String,
                                    newerVersion: String,
                                    requiredSystem: String)
}

extension UpdateState {
    /// The one sentence the sheet shows when a newer build needs a newer macOS.
    /// Nil in every other state.
    public var systemRequirementSentence: String? {
        guard case .newerBuildNeedsNewerSystem(_, let newer, let required) = self else {
            return nil
        }
        return "Maugham \(newer) needs macOS \(required) or later."
    }
}
