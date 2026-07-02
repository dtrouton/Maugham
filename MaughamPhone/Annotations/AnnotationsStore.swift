import Foundation
import MaughamCore

/// Owns the Annotations tab's load + the grouped project→chapter tree, so the
/// three drill-down levels (root/chapters/notes) share one source of truth and a
/// resolve deep in the stack recomputes every level's counts on reload. Mirrors
/// `ProjectsBrowser`'s shape: plain `@Observable`, injected deps, `@MainActor`
/// (the UI observes on main). Heavy work stays off the render path — `reload` is
/// invoked from `.task`, the unlock button, pull-to-refresh, and the resolve
/// tick only (tripwire 4).
@MainActor
@Observable
final class AnnotationsStore {
    private let projectsBrowser: ProjectsBrowser
    private let downloads: DownloadCoordinator
    private let recents: RecentsTracker

    /// Every project with ≥1 note (open or resolved), each broken down by
    /// chapter. The view filters to Open/All via `AnnotationLoading.visibleProjects`.
    private(set) var projects: [ProjectAnnotations] = []
    private(set) var banner: AnnotationsBanner.Banner = .none
    private(set) var isLoading = false
    private(set) var didLoad = false

    init(projectsBrowser: ProjectsBrowser, downloads: DownloadCoordinator, recents: RecentsTracker) {
        self.projectsBrowser = projectsBrowser
        self.downloads = downloads
        self.recents = recents
    }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    /// Walk every project, load its annotations (all statuses), group by chapter,
    /// then recompute the recents' download banner.
    func reload() async {
        isLoading = true
        defer { isLoading = false; didLoad = true }

        var results: [ProjectAnnotations] = []
        for project in projectsBrowser.projects {
            let anns = await loadedAnnotations(for: project)
            guard !anns.isEmpty else { continue }
            let chapters = AnnotationLoading.groupByChapter(
                anns, structure: project.manifest.structure, research: project.manifest.research)
            results.append(ProjectAnnotations(
                id: project.id,
                projectName: project.manifest.title,
                projectURL: project.url,
                chapters: chapters))
        }
        projects = results
        await refreshBanner()
    }

    /// All annotations (open + resolved) for one project: enumerate `.maugham/ops/`,
    /// resolve distinct doc ids, fault each doc's op-log files in (best-effort —
    /// an evicted iCloud file reads as empty with NO error), load + derive.
    private func loadedAnnotations(for project: BrowsedProject) async -> [LoadedAnnotation] {
        let opsDir = project.url.appendingPathComponent(".maugham/ops", isDirectory: true)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: opsDir.path)) ?? []
        let docIds = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)
        guard !docIds.isEmpty else { return [] }

        let store = OpLogStore(projectURL: project.url)
        var all: [LoadedAnnotation] = []
        for docId in docIds {
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: project.url) {
                try? await downloads.ensureDownloaded(url)
            }
            guard let ops = try? await store.load(docId: docId) else { continue }
            all.append(contentsOf: AnnotationLoading.allAnnotations(ops: ops)
                .map { LoadedAnnotation(annotation: $0, docId: docId) })
        }
        return all
    }

    // MARK: - Banner (moved verbatim from AnnotationsListView)

    private func refreshBanner() async {
        let recentIds = recents.recents
        let recentProjects = projectsBrowser.projects.filter { recentIds.contains($0.id) }
        var states: [DownloadStateLite] = []
        for project in recentProjects {
            states.append(await projectDownloadState(project))
        }
        banner = AnnotationsBanner.banner(forRecentStates: states)
    }

    private func projectDownloadState(_ project: BrowsedProject) async -> DownloadStateLite {
        let opsDir = project.url.appendingPathComponent(".maugham/ops", isDirectory: true)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: opsDir.path)) ?? []
        let docIds = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)

        var urls: [URL] = []
        for docId in docIds {
            urls.append(contentsOf: OpLogStore.opLogFileURLs(forDocId: docId, in: project.url))
        }
        guard !urls.isEmpty else { return .downloaded }

        var lites: [DownloadStateLite] = []
        for url in urls {
            for await state in await downloads.observe(url) {
                lites.append(Self.lite(state))
                break
            }
        }
        if lites.contains(.downloading) { return .downloading }
        if lites.allSatisfy({ $0 == .failed }) && !lites.isEmpty { return .failed }
        if lites.contains(.notDownloaded) { return .notDownloaded }
        return .downloaded
    }

    private static func lite(_ state: DownloadCoordinator.DownloadState) -> DownloadStateLite {
        switch state {
        case .notDownloaded: return .notDownloaded
        case .downloading: return .downloading
        case .downloaded: return .downloaded
        case .failed: return .failed
        }
    }
}
