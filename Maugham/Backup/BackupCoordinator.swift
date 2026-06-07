import Foundation
import MaughamCore

@MainActor
@Observable
public final class BackupCoordinator {
    public init() {}

    /// Resolved destinations to back up to. Set from UserPreferences at app launch
    /// and whenever the config changes.
    public var destinations: [BackupDestination] = []

    /// Outcome of the most recent backup attempt (drives status UI).
    public enum Result: Sendable, Equatable {
        case idle
        case ok(written: Int, skipped: Int, failed: Int, at: Date)
        case integrityFailed(summary: String)
        case noDestinations
    }
    public private(set) var lastResult: Result = .idle

    /// Run an integrity check, then (if clean) back up to all destinations. A
    /// corrupt source is surfaced and the backup is skipped — corruption must not
    /// propagate to destinations. Never throws.
    public func backupNow(projectURL: URL, generationId: String, at now: Date) async {
        guard !destinations.isEmpty else { lastResult = .noDestinations; return }

        // Integrity-before-backup (decision 2026-06-07).
        if let report = try? await ProjectIntegrity.check(projectURL: projectURL), !report.isHealthy {
            let summary = "skips:\(report.docSkips.count) twins:\(report.conflictTwins.count) dangling:\(report.danglingPointers.count) bad-ids:\(report.invalidParagraphIds.count)"
            lastResult = .integrityFailed(summary: summary)
            return
        }

        // BackupRunner.run is synchronous filesystem work; hop off the main actor.
        let dests = projectDestinations(for: projectURL)
        let outcomes = await Task.detached {
            BackupRunner.run(projectURL: projectURL, destinations: dests, generationId: generationId, at: now)
        }.value

        var written = 0, skipped = 0, failed = 0
        for o in outcomes {
            switch o {
            case .written: written += 1
            case .skippedUnchanged: skipped += 1
            case .failed: failed += 1
            }
        }
        lastResult = .ok(written: written, skipped: skipped, failed: failed, at: now)
    }

    /// The per-project subfolder name under a destination: the project's minted
    /// `ProjectManifest.id`, falling back to the folder name if the manifest has
    /// no id (older projects). Keeps each project's generations separate so several
    /// projects can share one backup destination.
    public static func projectKey(for projectURL: URL) -> String {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data),
           let id = manifest.id, !id.isEmpty {
            return id
        }
        return projectURL.lastPathComponent
    }

    /// Per-project destination URLs (`<destination>/<projectKey>`), preserving retention.
    private func projectDestinations(for projectURL: URL) -> [BackupDestination] {
        let key = Self.projectKey(for: projectURL)
        return destinations.map {
            BackupDestination(url: $0.url.appendingPathComponent(key), retention: $0.retention)
        }
    }

    /// Generations for one project across all destinations, newest-first.
    public func generations(forProject projectURL: URL) -> [RestoreGeneration] {
        BackupRestore.listGenerations(across: projectDestinations(for: projectURL).map(\.url))
    }

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
