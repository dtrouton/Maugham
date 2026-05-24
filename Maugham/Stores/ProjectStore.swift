import AppKit
import Foundation
import SwiftUI

public enum StructureItemKind: Equatable, Sendable {
    case document(extension: String)  // "md" or "fountain"
    case group
}

public enum ProjectStoreError: Error, Equatable {
    case manifestNotFound
    case manifestUnreadable(String)
    case manuscriptUnreadable(String)
    case manuscriptUnwritable(String)
    case manifestUnwritable(String)
    case structureMissing
    case parentNotFound(String)
    case fileSystemError(String)
    case cycle
}

/// Manages an open Maugham project: its manifest plus its manuscript text.
/// Phase 1a supports Short Story projects only (single manuscript file).
@MainActor
@Observable
public final class ProjectStore {
    public let url: URL
    public internal(set) var manifest: ProjectManifest
    public var manuscriptText: String

    /// Optional reference to the DocumentStore that owns this project's
    /// coordinated I/O. Set by ProjectWindow at open time. When non-nil,
    /// manifest saves route through DocumentStore.writeManifest. When nil
    /// (e.g., during initial load before DocumentStore exists), saves use
    /// the legacy direct atomic-write path.
    public weak var documentStore: DocumentStore?

    /// Per-document cached word counts. Refreshed by EditorHost on text
    /// change. Aggregate sum is used by SessionTracker for project-wide
    /// net delta calculation.
    private var wordCountCache: [String: Int] = [:]

    public var projectWordCount: Int {
        wordCountCache.values.reduce(0, +)
    }

    public func recordWordCount(forDocumentId id: String, wordCount: Int) {
        wordCountCache[id] = wordCount
    }

    public func cachedWordCount(for id: String) -> Int? {
        wordCountCache[id]
    }

    static let manifestFilename = "project.maugham.json"

    public let trashStore: TrashStore
    public internal(set) var trashEntries: [TrashEntry] = []
    var lastDeletedTrashId: String?

    // MARK: - Search state

    public internal(set) var currentSearch: SearchResults?
    public internal(set) var searchInProgress: Bool = false
    var searchTask: Task<Void, Never>?

    // MARK: - Project-scope task state (milestone-tasks)
    //
    // Cross-project task aggregation cache + the sync mirror of
    // `.maugham/ops/__project__.jsonl`. Implementation lives in
    // `ProjectStore+Tasks.swift`; stored properties must live on the class
    // body because `@Observable` extensions can't synthesize storage.
    // See `docs/superpowers/specs/2026-05-23-tasks-design.md` §9.

    /// Sync mirror of the project-scope op log. Read-after-write within the
    /// same actor sees the latest state; the disk append is fire-and-forget
    /// (mirrors the per-doc task append pattern from Task 3).
    internal var _projectOpLogMirror: [Op] = []

    /// Set to true once the project op log has been loaded from disk (or
    /// the first append fires, whichever comes first). Lazy load on first
    /// `listTasksAcrossProject` / `projectTasksOpLog` call.
    internal var _projectOpLogLoaded: Bool = false

    /// Version counter for the project op log. Bumped on every append.
    /// Part of the cross-project cache key per spec §9.5.
    internal var _projectLogVersion: Int = 0

    /// Cross-project task derivation cache. Invalidated when the cache key
    /// changes (per-doc tasksVersion sum + closed-doc op-log mtime hash sum
    /// + project log version).
    internal var _projectTasksCache: [WriterTask] = []
    internal var _projectTasksCacheKey: ProjectTasksCacheKey? = nil

    /// SwiftUI-observable version token. Bumped on every append and on every
    /// rebuild. The pane in Task 8 binds to this. Mutation is only via
    /// `bumpProjectTasksVersion()` so the set surface is auditable.
    public internal(set) var projectTasksVersion: Int = 0

    internal func bumpProjectTasksVersion() {
        projectTasksVersion &+= 1
    }

    /// Stable device + session identifiers for project-scope ops. The
    /// per-Document `device` / `session` are not visible here, and project
    /// ops live in a separate log anyway, so we mint our own per-instance.
    /// `@ObservationIgnored` because these are computed-once internal
    /// identifiers, never observed by SwiftUI.
    @ObservationIgnored internal var projectOpDevice: String = {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "unknown-host" : name
    }()
    @ObservationIgnored internal var projectOpSession: String = UUID().uuidString

    #if DEBUG
    /// Debug counter for cache-rebuild tests. Increments every time the
    /// cross-project derivation actually runs. A hit on the cache key leaves
    /// this unchanged.
    internal var _debugTasksRebuildCount: Int = 0
    #endif

    /// Cache-key struct kept on the class so the extension can read/write it.
    /// Two keys with identical fields compare equal; that's how the cache
    /// short-circuits.
    public struct ProjectTasksCacheKey: Equatable {
        let perDocVersionSum: Int
        let projectLogVersion: Int
    }

    private init(
        url: URL,
        manifest: ProjectManifest,
        manuscriptText: String,
        trashStore: TrashStore,
        trashEntries: [TrashEntry]
    ) {
        self.url = url
        self.manifest = manifest
        self.manuscriptText = manuscriptText
        self.trashStore = trashStore
        self.trashEntries = trashEntries
    }

    /// Load a project from disk by URL.
    public static func load(from url: URL) async throws -> ProjectStore {
        let manifestURL = url.appendingPathComponent(manifestFilename)
        let fm = FileManager.default

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ProjectStoreError.manifestNotFound
        }

        let manifest: ProjectManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(ProjectManifest.self, from: data)
        } catch {
            throw ProjectStoreError.manifestUnreadable(error.localizedDescription)
        }

        let manuscriptText = try Self.readManuscript(for: manifest, at: url)

        let trashStore = TrashStore(projectURL: url)
        try? await trashStore.sweep()
        let trashEntries = (try? await trashStore.list()) ?? []

        let store = ProjectStore(
            url: url,
            manifest: manifest,
            manuscriptText: manuscriptText,
            trashStore: trashStore,
            trashEntries: trashEntries)
        Self.populateWordCountCache(in: store, from: manifest, at: url)
        return store
    }

    /// Walk every document in `manifest.structure`, read its file, and
    /// record the word count via the WritingMode for that file's extension.
    /// Called during `load(from:)` so consumers (goal indicator, Statistics
    /// window, etc.) see correct totals from the start instead of zeros
    /// until the user types into each document.
    private static func populateWordCountCache(
        in store: ProjectStore,
        from manifest: ProjectManifest,
        at projectURL: URL
    ) {
        for item in collectDocuments(in: manifest.structure) {
            guard let path = item.path else { continue }
            let fileURL = projectURL.appendingPathComponent(path)
            guard let text = try? String(contentsOf: fileURL,
                                         encoding: .utf8) else { continue }
            let count = WritingModeFactory.mode(for: path)
                .metrics(text).wordCount
            store.recordWordCount(forDocumentId: item.id, wordCount: count)
        }
    }

    static func collectDocuments(
        in items: [StructureItem]
    ) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let children = item.children {
                out.append(contentsOf: collectDocuments(in: children))
            }
        }
        return out
    }

    private static func readManuscript(
        for manifest: ProjectManifest, at projectURL: URL
    ) throws -> String {
        guard let docPath = manifest.structure.first(where: { $0.type == .document })?.path else {
            return ""
        }
        let manuscriptURL = projectURL.appendingPathComponent(docPath)
        guard FileManager.default.fileExists(atPath: manuscriptURL.path) else {
            return ""
        }
        do {
            return try String(contentsOf: manuscriptURL, encoding: .utf8)
        } catch {
            throw ProjectStoreError.manuscriptUnreadable(error.localizedDescription)
        }
    }

    static func newId(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }

}
