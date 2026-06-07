import Foundation
import MaughamCore

@MainActor
@Observable
public final class BackupCoordinator {
    public init() {}

    /// Resolve persisted configs into runnable destinations. Unresolvable/stale
    /// bookmarks are dropped (the Settings UI surfaces them separately). Starts
    /// security-scoped access for each resolved URL (held for the process; the
    /// folder is the user's chosen backup root).
    public static func resolveDestinations(_ configs: [BackupDestinationConfig]) -> [BackupDestination] {
        configs.compactMap { cfg in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: cfg.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale) else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            return BackupDestination(url: url, retention: cfg.retention)
        }
    }
}
