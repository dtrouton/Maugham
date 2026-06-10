import Foundation
import MaughamCore

@MainActor
@Observable
public final class BackupCoordinator {
    /// The integrity gate, injectable so the throws-blocks-backup path is testable
    /// (production is `ProjectIntegrity.check`). A throw here is treated as a
    /// corruption signal and blocks the backup — see `backupNow`.
    private let integrityCheck: (URL) async throws -> IntegrityReport

    public init() {
        self.integrityCheck = { try await ProjectIntegrity.check(projectURL: $0) }
    }

    /// Test seam: inject a custom integrity gate (e.g. one that throws).
    init(integrityCheck: @escaping (URL) async throws -> IntegrityReport) {
        self.integrityCheck = integrityCheck
    }

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
    /// Backup outcome **per project** (keyed by a normalized URL). Per-project so a
    /// failure on one project doesn't light the "backups paused" banner on every
    /// open window — the coordinator is a single app-wide object shared by all
    /// project windows.
    public private(set) var resultsByProject: [URL: Result] = [:]

    /// The most recent backup outcome for `projectURL` (`.idle` if none yet).
    public func lastResult(for projectURL: URL) -> Result {
        resultsByProject[Self.resultKey(projectURL)] ?? .idle
    }

    /// Normalize so the banner's `url` and `backupNow`'s `store.url` (which may
    /// differ by `/var`↔`/private/var` or trailing slash) key the same slot.
    private static func resultKey(_ url: URL) -> URL { url.standardizedFileURL }

    /// Run an integrity check, then (if clean) back up to all destinations. A
    /// corrupt source is surfaced and the backup is skipped — corruption must not
    /// propagate to destinations. Never throws.
    public func backupNow(projectURL: URL, generationId: String, at now: Date) async {
        let key = Self.resultKey(projectURL)
        guard !destinations.isEmpty else { resultsByProject[key] = .noDestinations; return }

        // Integrity-before-backup (decision 2026-06-07). A *throwing* check is the
        // strongest corruption signal there is — the check itself couldn't complete
        // — so it must BLOCK the backup, not be swallowed. The prior `try?` collapsed
        // a throw to nil, the `if let` fell through, and the backup proceeded over
        // an unverifiable source (audit N1 / item 1b). Treat throw and "unhealthy"
        // identically: surface and skip.
        do {
            let report = try await integrityCheck(projectURL)
            if !report.isHealthy {
                let summary = "skips:\(report.docSkips.count) twins:\(report.conflictTwins.count) dangling:\(report.danglingPointers.count) bad-ids:\(report.invalidParagraphIds.count)"
                resultsByProject[key] = .integrityFailed(summary: summary)
                return
            }
        } catch {
            resultsByProject[key] = .integrityFailed(summary: "integrity check failed: \(error.localizedDescription)")
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
        resultsByProject[key] = .ok(written: written, skipped: skipped, failed: failed, at: now)
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
