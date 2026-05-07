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
}

/// Manages an open Maugham project: its manifest plus its manuscript text.
/// Phase 1a supports Short Story projects only (single manuscript file).
@MainActor
@Observable
public final class ProjectStore {
    public let url: URL
    public private(set) var manifest: ProjectManifest
    public var manuscriptText: String

    private static let manifestFilename = "project.maugham.json"

    private init(url: URL, manifest: ProjectManifest, manuscriptText: String) {
        self.url = url
        self.manifest = manifest
        self.manuscriptText = manuscriptText
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

        return ProjectStore(url: url, manifest: manifest,
                            manuscriptText: manuscriptText)
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

    private static func newId(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }

    /// Add a new document or group beneath a parent (or at root if `parentId` is nil).
    /// Creates the file/folder on disk and saves the manifest atomically.
    public func addStructureItem(
        parentId: String?,
        title: String,
        kind: StructureItemKind
    ) async throws -> StructureItem {
        // 1. Resolve parent path for the new item
        let parentPath: String
        if let parentId {
            guard let parent = findItem(id: parentId, in: manifest.structure),
                  parent.type == .group else {
                throw ProjectStoreError.parentNotFound(parentId)
            }
            parentPath = parent.path ?? ""
        } else {
            parentPath = "manuscript"
        }

        // 2. Make sure the parent folder exists on disk
        let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentURL.path) {
            try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        // 3. Compute filename based on existing siblings
        let siblingNames = (try? fm.contentsOfDirectory(atPath: parentURL.path)) ?? []
        let filename: String
        switch kind {
        case .document(let ext):
            filename = FileNaming.nextDocumentFilename(
                title: title, extension: ext, siblingFilenames: siblingNames)
        case .group:
            filename = FileNaming.nextGroupFolderName(
                title: title, siblingFilenames: siblingNames)
        }
        let newURL = parentURL.appendingPathComponent(filename)
        let relativePath = "\(parentPath)/\(filename)"

        // 4. Create file or folder on disk
        do {
            switch kind {
            case .document:
                try Data().write(to: newURL)
            case .group:
                try fm.createDirectory(at: newURL, withIntermediateDirectories: false)
            }
        } catch {
            throw ProjectStoreError.fileSystemError(error.localizedDescription)
        }

        // 5. Build the new StructureItem
        let item = StructureItem(
            id: Self.newId(prefix: kind.idPrefix),
            title: title,
            type: kind.itemType,
            path: relativePath,
            children: kind.itemType == .group ? [] : nil)

        // 6. Mutate manifest: append to parent's children or to root structure
        if let parentId {
            mutateItem(id: parentId) { parent in
                var children = parent.children ?? []
                children.append(item)
                parent.children = children
            }
        } else {
            manifest.structure.append(item)
        }
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    // MARK: - Tree helpers

    private func findItem(
        id: String, in items: [StructureItem]
    ) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    /// Mutate the item with the given id in place. The closure receives an
    /// inout reference and can change any field.
    private func mutateItem(
        id: String,
        transform: (inout StructureItem) -> Void
    ) {
        var newStructure = manifest.structure
        Self.applyMutation(id: id, in: &newStructure, transform: transform)
        manifest.structure = newStructure
    }

    private static func applyMutation(
        id: String,
        in items: inout [StructureItem],
        transform: (inout StructureItem) -> Void
    ) {
        for i in items.indices {
            if items[i].id == id {
                transform(&items[i])
                return
            }
            if items[i].children != nil {
                var children = items[i].children!
                applyMutation(id: id, in: &children, transform: transform)
                items[i].children = children
            }
        }
    }

    private func saveManifest() async throws {
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let tmpURL = manifestURL.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmpURL)
        } catch {
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }
    }

    /// Rename an item: updates manifest title and moves the file or folder
    /// to a new slug while preserving the NN prefix. For groups, recursively
    /// updates child paths.
    public func renameStructureItem(
        id: String, newTitle: String
    ) async throws {
        guard let item = findItem(id: id, in: manifest.structure),
              let oldPath = item.path else {
            throw ProjectStoreError.structureMissing
        }

        // Compute new slug. NN prefix is preserved by extracting it from the old path.
        let oldFilename = (oldPath as NSString).lastPathComponent
        let nn = String(oldFilename.prefix(2))

        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)

        let fm = FileManager.default
        let siblingNames = ((try? fm.contentsOfDirectory(atPath: parentURL.path)) ?? [])
            .filter { $0 != oldFilename }  // exclude self

        let newFilename: String
        switch item.type {
        case .document:
            let ext = (oldFilename as NSString).pathExtension
            let baseSlug = Slugifier.slug(from: newTitle)
            let dedupedSlug = Self.dedupeSlug(
                base: baseSlug, ext: ext, isFolder: false,
                siblings: siblingNames)
            newFilename = "\(nn)-\(dedupedSlug).\(ext)"
        case .group:
            let baseSlug = Slugifier.slug(from: newTitle)
            let dedupedSlug = Self.dedupeSlug(
                base: baseSlug, ext: nil, isFolder: true,
                siblings: siblingNames)
            newFilename = "\(nn)-\(dedupedSlug)"
        }

        let newPath = parentPath.isEmpty ? newFilename : "\(parentPath)/\(newFilename)"
        let newURL = url.appendingPathComponent(newPath)

        // Move on disk
        do {
            try fm.moveItem(at: url.appendingPathComponent(oldPath), to: newURL)
        } catch {
            throw ProjectStoreError.fileSystemError(error.localizedDescription)
        }

        // Update manifest: title and path on the item, plus recursive child
        // path updates for groups (their relative locations within the group
        // are unchanged, but the absolute prefix changes).
        mutateItem(id: id) { mutable in
            mutable.title = newTitle
            mutable.path = newPath
            if mutable.type == .group, var children = mutable.children {
                Self.rewriteChildPaths(
                    in: &children, oldPrefix: oldPath, newPrefix: newPath)
                mutable.children = children
            }
        }
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Static slug-deduper used by rename (since we already know NN).
    /// Mirrors FileNaming's collision logic but without computing a new NN.
    private static func dedupeSlug(
        base: String, ext: String?, isFolder: Bool, siblings: [String]
    ) -> String {
        let regex = try? NSRegularExpression(pattern: #"^\d{2}-(.+?)(\.[^.]+)?$"#)
        var existing = Set<String>()
        for name in siblings {
            let r = NSRange(name.startIndex..., in: name)
            guard let regex,
                  let m = regex.firstMatch(in: name, range: r),
                  let slugRange = Range(m.range(at: 1), in: name) else { continue }
            let extPart = m.range(at: 2).location != NSNotFound
                ? Range(m.range(at: 2), in: name).map { String(name[$0]) }
                : nil
            if isFolder {
                if extPart == nil { existing.insert(String(name[slugRange])) }
            } else if let ext, extPart == ".\(ext)" {
                existing.insert(String(name[slugRange]))
            }
        }
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Rewrites the path prefix of every child item recursively.
    private static func rewriteChildPaths(
        in children: inout [StructureItem],
        oldPrefix: String,
        newPrefix: String
    ) {
        for i in children.indices {
            if let p = children[i].path, p.hasPrefix(oldPrefix + "/") {
                children[i].path = newPrefix + p.dropFirst(oldPrefix.count)
            }
            if children[i].children != nil {
                var nested = children[i].children!
                rewriteChildPaths(in: &nested,
                                  oldPrefix: oldPrefix, newPrefix: newPrefix)
                children[i].children = nested
            }
        }
    }

    /// Move the item's file or folder to the system Trash and remove its
    /// manifest entry. For groups, the entire folder (including all children)
    /// is recycled in one atomic system call.
    public func deleteStructureItem(id: String) async throws {
        guard let item = findItem(id: id, in: manifest.structure),
              let path = item.path else {
            throw ProjectStoreError.structureMissing
        }

        let fullURL = url.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: fullURL.path) {
            do {
                try await recycleURLs([fullURL])
            } catch {
                throw ProjectStoreError.fileSystemError(error.localizedDescription)
            }
        }

        removeFromStructure(id: id)
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Wrap NSWorkspace.recycle's callback API in async/await.
    private func recycleURLs(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func removeFromStructure(id: String) {
        var newStructure = manifest.structure
        Self.applyRemoval(id: id, in: &newStructure)
        manifest.structure = newStructure
    }

    private static func applyRemoval(
        id: String, in items: inout [StructureItem]
    ) {
        items.removeAll(where: { $0.id == id })
        for i in items.indices where items[i].children != nil {
            var children = items[i].children!
            applyRemoval(id: id, in: &children)
            items[i].children = children
        }
    }

    /// Persist the current manuscript text and an updated `modified` timestamp.
    /// Manifest write is atomic via temp-file + rename. Manuscript write is
    /// non-atomic in 1a; NSFileCoordinator integration arrives in milestone 1e.
    public func save() async throws {
        // Write manuscript first; if it fails we don't bump the manifest.
        guard let docPath = manifest.structure.first(where: { $0.type == .document })?.path else {
            throw ProjectStoreError.structureMissing
        }
        let manuscriptURL = url.appendingPathComponent(docPath)
        do {
            try manuscriptText.write(to: manuscriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw ProjectStoreError.manuscriptUnwritable(error.localizedDescription)
        }

        // Bump modified and write manifest atomically.
        // Round to whole seconds so the in-memory value matches what ISO-8601
        // (second precision) will round-trip back from disk.
        manifest.modified = Date(timeIntervalSinceReferenceDate:
            (Date().timeIntervalSinceReferenceDate).rounded())
        let manifestURL = url.appendingPathComponent(Self.manifestFilename)
        let tmpURL = url.appendingPathComponent(Self.manifestFilename + ".tmp")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }
    }
}

private extension StructureItemKind {
    var itemType: StructureItem.ItemType {
        switch self {
        case .document: return .document
        case .group: return .group
        }
    }

    var idPrefix: String {
        switch self {
        case .document(let ext) where ext == "fountain": return "scene"
        case .document: return "doc"
        case .group: return "grp"
        }
    }
}
