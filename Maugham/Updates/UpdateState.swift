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
}
