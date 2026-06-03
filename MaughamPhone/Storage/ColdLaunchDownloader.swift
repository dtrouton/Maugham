import Foundation
import MaughamCore

/// Cold-launch op-log prefetch (spec §3.13 step 3, thin first cut).
///
/// After the app re-establishes the projects root and refreshes manifests (the
/// "always download" tier), it proactively pulls the op logs of *recent*
/// projects into local storage so the Annotations tab (Phase F) finds local
/// JSONL instead of an evicted-placeholder "no annotations." Eviction-faulting
/// is `DownloadCoordinator`'s job; this type just decides WHICH op logs to ask
/// for, sums their sizes, and lets the coordinator's 50 MB budget gate each one.
///
/// Best-effort by contract: it never throws. A failed or budget-rejected
/// prefetch just means the Annotations tab will fault that op log in lazily
/// later via `ensureDownloaded`.
///
/// # Testability seam
/// `enumerateOpLogs` is injectable so a test can supply fake project dirs with
/// scripted op-log URLs without touching the real filesystem. The production
/// default globs `<projectURL>/.maugham/ops/` for `d_*.jsonl` files.
struct ColdLaunchDownloader {
    let downloads: DownloadCoordinator
    let io: CoordinatedFileIO

    /// Lists the op-log JSONL files for a project folder. Default globs the real
    /// `.maugham/ops/` directory; tests inject a fake.
    var enumerateOpLogs: (URL) -> [URL] = ColdLaunchDownloader.liveEnumerateOpLogs

    init(
        downloads: DownloadCoordinator,
        io: CoordinatedFileIO,
        enumerateOpLogs: @escaping (URL) -> [URL] = ColdLaunchDownloader.liveEnumerateOpLogs
    ) {
        self.downloads = downloads
        self.io = io
        self.enumerateOpLogs = enumerateOpLogs
    }

    /// For each recent project, enumerate its op logs, size each one, and request
    /// a budgeted download. Best-effort: never throws; a per-file size of nil
    /// defaults to 0 (let the budget admit it rather than skip a tiny/unknown
    /// file). Returns every op-log URL it attempted (i.e. asked the coordinator
    /// about), regardless of whether the budget admitted it — useful for tests
    /// and diagnostics.
    @discardableResult
    func prefetch(recentProjects: [BrowsedProject]) async -> [URL] {
        var attempted: [URL] = []
        for project in recentProjects {
            // `.maugham/ops` is a filesystem PATH component, not an identity
            // string (the Mac writes the same literal) — Tripwire 13 N/A.
            let opLogs = enumerateOpLogs(project.url)
            for opLog in opLogs {
                let sizeHint = io.fileSize(at: opLog) ?? 0
                // Fire-and-forget against the budget. The coordinator dedups and
                // starts (without awaiting completion) when the budget allows.
                _ = await downloads.ensureDownloadedIfBudgetAllows(opLog, sizeHint: sizeHint)
                attempted.append(opLog)
            }
        }
        return attempted
    }

    // MARK: - Production glob

    /// Lists a project's manuscript op-log files under `.maugham/ops/`.
    /// Recognition delegates to `OpLogStore.docId(fromOpLogFilename:)` — the
    /// single source of truth (a local `d_`-prefix predicate prefetched nothing
    /// pre-phone-v0.1.1). Returns `[]` for a project with no ops dir yet
    /// (never throws).
    static func liveEnumerateOpLogs(_ projectURL: URL) -> [URL] {
        let opsDir = projectURL
            .appendingPathComponent(".maugham", isDirectory: true)
            .appendingPathComponent("ops", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: opsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }
        return entries.filter { url in
            OpLogStore.docId(fromOpLogFilename: url.lastPathComponent) != nil
        }
    }
}
