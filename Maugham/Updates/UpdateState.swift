import Foundation

/// State of the auto-updater. See production-release spec §3.2.
public enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(version: String, progress: Double)
    case ready(version: String, dmgURL: URL, releaseNotes: String)
    case error(String)
    case upToDate(currentVersion: String)
}
