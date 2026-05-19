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
