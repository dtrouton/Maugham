import Foundation
import MaughamCore

/// One project the phone discovered inside the bookmarked iCloud-Drive root.
///
/// `id` is the manifest's minted ULID when present, or a deterministic
/// `"path:"`-namespaced fallback derived from the folder name when the Mac
/// hasn't re-opened the project since the `id` field shipped (spec §3.7).
struct BrowsedProject: Identifiable, Equatable, Sendable {
    let id: ProjectId       // ProjectManifest.id, or a "path:"-prefixed fallback
    let url: URL            // the project folder URL (the dir, not the manifest)
    let manifest: ProjectManifest
}

/// Enumerates the bookmarked iCloud-Drive projects root and builds a stable
/// id → project map for the Read/Capture UI to observe.
///
/// For each immediate child directory containing a `project.maugham.json`, it
/// faults the manifest in (`DownloadCoordinator.ensureDownloaded`), reads it
/// coordinated, and decodes a `ProjectManifest`. A project that fails to
/// download or decode is SKIPPED into `failures` rather than aborting the whole
/// listing — one corrupt manifest must not hide every other project.
///
/// `@Observable` so the capture pill / project picker re-renders when a refresh
/// completes; `@MainActor` because that UI observation must happen on main.
@MainActor
@Observable
final class ProjectsBrowser {

    /// The discovered projects, sorted by `manifest.title` case-insensitively.
    /// Indexed for lookup via `project(id:)`.
    private(set) var projects: [BrowsedProject] = []

    /// Set when the root itself could not be enumerated (vs. a single project
    /// failing, which goes to `failures`). nil on success.
    private(set) var loadError: String?

    /// Per-project-folder decode/download failures from the LAST refresh. Keyed
    /// by the project FOLDER url. Cleared at the start of each `refresh`.
    private(set) var failures: [URL: String] = [:]

    // MARK: - Dependencies

    private let downloads: DownloadCoordinator
    private let io: CoordinatedFileIO

    /// Manifest filename at each project folder root. Sourced from
    /// `ProjectManifest.fileName` in MaughamCore so Mac and phone always
    /// agree on the name without a second literal.
    private static let manifestFileName = ProjectManifest.fileName

    init(downloads: DownloadCoordinator, io: CoordinatedFileIO = .live) {
        self.downloads = downloads
        self.io = io
    }

    // MARK: - Refresh

    /// Enumerate `root`'s immediate child directories that contain a
    /// `project.maugham.json`; for each, ensureDownloaded + coordinatedRead +
    /// decode, then publish a title-sorted `projects` list. Idempotent: a fresh
    /// refresh fully replaces the prior state (no duplicate accumulation).
    func refresh(root: URL) async {
        loadError = nil
        failures = [:]

        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            // The root itself is unreadable (bad bookmark, evicted root, perms).
            // Surface it, clear projects, and bail — nothing to list.
            loadError = describe(error)
            projects = []
            return
        }

        var found: [BrowsedProject] = []

        for child in children {
            // Only immediate directories that hold a manifest are projects.
            // Loose files and dirs without a manifest are naturally ignored.
            guard isDirectory(child, fm: fm) else { continue }
            let manifestURL = child.appendingPathComponent(Self.manifestFileName)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            do {
                // Fault the manifest in before reading: an evicted iCloud file
                // reads as empty bytes with NO error, so we must download first.
                try await downloads.ensureDownloaded(manifestURL)
                let data = try io.coordinatedRead(at: manifestURL)
                // Use the shared manifest decoder from MaughamCore so date
                // strategy stays in sync with the Mac writer automatically, and
                // honour the schemaVersion gate (ADR 0015): a project written by
                // a newer Maugham surfaces as a per-project failure rather than a
                // silent misparse.
                let manifest = try ProjectManifest.decodeGuardingSchema(data)
                found.append(BrowsedProject(
                    id: Self.resolveId(manifest: manifest, folder: child),
                    url: child,
                    manifest: manifest))
            } catch {
                // One bad/evicted manifest must not sink the whole listing.
                failures[child] = describe(error)
                continue
            }
        }

        // Stable, human-meaningful order for the picker.
        projects = found.sorted {
            $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending
        }
    }

    // MARK: - Lookup

    /// id → BrowsedProject lookup, for resolving a persisted `currentProjectId`
    /// (capture pill) and recents entries against the current listing.
    func project(id: ProjectId) -> BrowsedProject? {
        projects.first { $0.id == id }
    }

    // MARK: - Private

    /// Real minted id when present, else a deterministic path-derived fallback.
    ///
    /// A project the Mac hasn't re-opened since the `id` field shipped has
    /// `manifest.id == nil` (the Mac backfills on next open — spec §3.7). We
    /// must still surface it, so we synthesize an id from the folder name,
    /// namespaced with a `"path:"` prefix that can never collide with a real
    /// ULID (ULIDs are 26 uppercase Crockford-base32 chars, no colon). Prefer
    /// real ids; this is the defensive fallback only.
    private static func resolveId(manifest: ProjectManifest, folder: URL) -> ProjectId {
        if let id = manifest.id, !id.isEmpty { return id }
        return "path:" + folder.lastPathComponent
    }

    private func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        // Prefer the resource value (handles symlinks/packages correctly); fall
        // back to a path stat if the key is unavailable.
        if let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return isDir
        }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
