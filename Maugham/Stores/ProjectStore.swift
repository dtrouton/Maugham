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
    public private(set) var manifest: ProjectManifest
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

    private static let manifestFilename = "project.maugham.json"

    public let trashStore: TrashStore
    public private(set) var trashEntries: [TrashEntry] = []
    private var lastDeletedTrashId: String?

    // MARK: - Search state

    public private(set) var currentSearch: SearchResults?
    public private(set) var searchInProgress: Bool = false
    private var searchTask: Task<Void, Never>?

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

    private static func collectDocuments(
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

    /// Move an item to a new position. `toParentId` of nil means root. The
    /// destination index is into the children array of the new parent (or
    /// root structure if nil). Filename NN values renumber to keep contiguous
    /// 01, 02, 03 ordering within the destination parent.
    public func moveStructureItem(
        id: String, toParentId: String?, atIndex destIndex: Int
    ) async throws {
        guard let item = findItem(id: id, in: manifest.structure),
              let oldPath = item.path else {
            throw ProjectStoreError.structureMissing
        }
        let oldParentId = findParentId(of: id, in: manifest.structure, parent: nil)
        let oldIndex = currentIndex(of: id, parentId: oldParentId)

        if let toParentId, item.type == .group {
            if Self.isDescendant(
                ancestorId: id,
                candidateId: toParentId,
                in: manifest.structure)
            {
                throw ProjectStoreError.cycle
            }
            if toParentId == id {
                throw ProjectStoreError.cycle
            }
        }

        if let toParentId {
            guard let parent = findItem(id: toParentId, in: manifest.structure),
                  parent.type == .group else {
                throw ProjectStoreError.parentNotFound(toParentId)
            }
            _ = parent
        }

        if oldParentId == toParentId, oldIndex == destIndex {
            return
        }

        var destSiblings = childrenOf(parentId: toParentId)
        destSiblings.removeAll(where: { $0.id == id })
        let clampedIndex = max(0, min(destIndex, destSiblings.count))
        destSiblings.insert(item, at: clampedIndex)

        let destParentPath: String
        if let toParentId {
            destParentPath = findItem(id: toParentId, in: manifest.structure)?.path ?? "manuscript"
        } else {
            destParentPath = "manuscript"
        }

        var renameSteps: [RenamePlan.Step] = []
        var newDestSiblings: [StructureItem] = []
        for (i, sibling) in destSiblings.enumerated() {
            let newNN = String(format: "%02d", i + 1)
            let originalFilename = (sibling.path as NSString?)?.lastPathComponent ?? ""
            let slug: String
            let ext: String
            switch sibling.type {
            case .document:
                let stem = (originalFilename as NSString).deletingPathExtension
                slug = String(stem.dropFirst(3))  // drop "NN-"
                ext = (originalFilename as NSString).pathExtension
            case .group:
                slug = String(originalFilename.dropFirst(3))  // drop "NN-"
                ext = ""
            }
            let newFilename: String
            if sibling.type == .document {
                newFilename = "\(newNN)-\(slug).\(ext)"
            } else {
                newFilename = "\(newNN)-\(slug)"
            }
            let newPath = "\(destParentPath)/\(newFilename)"
            if sibling.path != newPath, let oldP = sibling.path {
                renameSteps.append(.init(
                    oldRelativePath: oldP,
                    newRelativePath: newPath))
            }
            var updated = sibling
            updated.path = newPath
            if updated.type == .group, var children = updated.children {
                Self.rewriteChildPaths(
                    in: &children,
                    oldPrefix: sibling.path ?? "",
                    newPrefix: newPath)
                updated.children = children
            }
            newDestSiblings.append(updated)
        }

        let plan = try RenamePlan(steps: renameSteps)
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        try await documentStore.executeRenamePlan(plan)

        removeFromStructure(id: id)
        replaceChildren(parentId: toParentId, with: newDestSiblings)
        manifest.modified = Date()
        try await saveManifest()
        _ = oldPath
    }

    // MARK: - Reorder helpers

    private func findParentId(
        of childId: String,
        in items: [StructureItem],
        parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children,
               let nested = findParentId(of: childId, in: children, parent: item.id) {
                return nested
            }
        }
        return nil
    }

    private func currentIndex(of id: String, parentId: String?) -> Int {
        let siblings = childrenOf(parentId: parentId)
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func childrenOf(parentId: String?) -> [StructureItem] {
        if let parentId {
            return findItem(id: parentId, in: manifest.structure)?.children ?? []
        }
        return manifest.structure
    }

    private static func isDescendant(
        ancestorId: String,
        candidateId: String,
        in items: [StructureItem]
    ) -> Bool {
        guard let ancestor = findItemStatic(id: ancestorId, in: items) else { return false }
        return Self.containsId(candidateId, in: ancestor.children ?? [])
    }

    private static func findItemStatic(
        id: String, in items: [StructureItem]
    ) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItemStatic(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    private static func containsId(
        _ id: String, in items: [StructureItem]
    ) -> Bool {
        for item in items {
            if item.id == id { return true }
            if let children = item.children, containsId(id, in: children) {
                return true
            }
        }
        return false
    }

    private func replaceChildren(
        parentId: String?,
        with newChildren: [StructureItem]
    ) {
        if let parentId {
            mutateItem(id: parentId) { parent in
                parent.children = newChildren
            }
        } else {
            manifest.structure = newChildren
        }
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }

        if let documentStore {
            // Route through DocumentStore for coordinated write.
            do {
                try await documentStore.writeManifest(data)
            } catch {
                throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
            }
            return
        }

        // Legacy direct path used during initial load before DocumentStore exists.
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let tmpURL = manifestURL.appendingPathExtension("tmp")
        do {
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
        let oldTitle = item.title

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

        // Wiki-link propagation: rewrite [[oldTitle]] occurrences in every
        // OTHER manuscript document body. The renamed doc is excluded from
        // the scan since its body could contain self-references in either
        // form, and the resolver's case-insensitive title match handles
        // those naturally on the next render.
        if oldTitle != newTitle, item.type == .document {
            await propagateWikiLinkRename(
                excludeId: id, oldTitle: oldTitle, newTitle: newTitle)
        }
    }

    /// Walk every other manuscript document; if its body references
    /// `[[oldTitle]]`, rewrite to `[[newTitle]]` and persist via direct
    /// disk write (these documents aren't necessarily the currently-open
    /// one in DocumentStore, so we go straight to file).
    private func propagateWikiLinkRename(
        excludeId: String, oldTitle: String, newTitle: String
    ) async {
        for doc in Self.collectDocuments(in: manifest.structure)
        where doc.id != excludeId {
            guard let path = doc.path else { continue }
            let fileURL = url.appendingPathComponent(path)
            guard let body = try? String(contentsOf: fileURL,
                                         encoding: .utf8) else { continue }
            guard let rewritten = WikiLinkRewriter.rewrite(
                body: body, oldTitle: oldTitle, newTitle: newTitle) else {
                continue
            }
            try? rewritten.write(
                to: fileURL, atomically: true, encoding: .utf8)
            // Refresh per-doc word-count cache since the body changed.
            let count = WritingModeFactory.mode(for: path)
                .metrics(rewritten).wordCount
            recordWordCount(forDocumentId: doc.id, wordCount: count)
        }
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

    /// Duplicate a structure item. For a document, copies the file and
    /// produces a sibling with title "Copy of <original>". For a group,
    /// recursively copies the folder and all descendants with fresh ids.
    public func duplicateStructureItem(
        id: String
    ) async throws -> StructureItem {
        guard let source = findItem(id: id, in: manifest.structure),
              let sourcePath = source.path else {
            throw ProjectStoreError.structureMissing
        }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }

        let parentId = findParentId(of: id, in: manifest.structure, parent: nil)
        let parentPath: String
        if let parentId {
            parentPath = findItem(id: parentId, in: manifest.structure)?.path
                ?? "manuscript"
        } else {
            parentPath = "manuscript"
        }
        let newTitle = "Copy of " + source.title

        let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)
        let siblingNames = (try? FileManager.default
            .contentsOfDirectory(atPath: parentURL.path)) ?? []
        let newFilename: String
        switch source.type {
        case .document:
            let ext = (sourcePath as NSString).pathExtension
            newFilename = FileNaming.nextDocumentFilename(
                title: newTitle, extension: ext, siblingFilenames: siblingNames)
        case .group:
            newFilename = FileNaming.nextGroupFolderName(
                title: newTitle, siblingFilenames: siblingNames)
        }
        let newPath = "\(parentPath)/\(newFilename)"
        let sourceFullURL = url.appendingPathComponent(sourcePath)
        let newFullURL = url.appendingPathComponent(newPath)

        try await documentStore.executeCopy(from: sourceFullURL, to: newFullURL)

        let copy = duplicatedItemTree(
            from: source,
            newTitle: newTitle,
            newPath: newPath,
            newPrefixForChildren: newPath)

        let sourceIndex = currentIndex(of: id, parentId: parentId)
        var siblings = childrenOf(parentId: parentId)
        siblings.insert(copy, at: sourceIndex + 1)
        replaceChildren(parentId: parentId, with: siblings)

        manifest.modified = Date()
        try await saveManifest()
        return copy
    }

    /// Recursively rebuild a StructureItem tree with fresh ids and rewritten
    /// paths. The top-level copy gets `newTitle` and `newPath`; descendants
    /// keep their titles and have their paths rewritten via `newPrefixForChildren`.
    private func duplicatedItemTree(
        from source: StructureItem,
        newTitle: String,
        newPath: String,
        newPrefixForChildren: String
    ) -> StructureItem {
        var copy = source
        copy.id = Self.newDuplicateId(prefix: source.type == .group ? "grp" : "doc")
        copy.title = newTitle
        copy.path = newPath
        if let children = source.children {
            var copiedChildren: [StructureItem] = []
            for child in children {
                guard let childPath = child.path else { continue }
                let childRelativeFromOldParent = childPath.dropFirst(
                    (source.path?.count ?? 0) + 1)
                let childNewPath = "\(newPrefixForChildren)/\(childRelativeFromOldParent)"
                copiedChildren.append(duplicatedItemTree(
                    from: child,
                    newTitle: child.title,
                    newPath: childNewPath,
                    newPrefixForChildren: childNewPath))
            }
            copy.children = copiedChildren
        }
        return copy
    }

    private static func newDuplicateId(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }

    /// Compact NN sequence gaps within a parent's children (or root if nil).
    /// Idempotent: running on an already-contiguous group is a no-op.
    public func tidyFilenames(parentId: String?) async throws {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }

        let siblings = childrenOf(parentId: parentId)
        let parentPath: String
        if let parentId {
            parentPath = findItem(id: parentId, in: manifest.structure)?.path
                ?? "manuscript"
        } else {
            parentPath = "manuscript"
        }

        var renameSteps: [RenamePlan.Step] = []
        var newSiblings: [StructureItem] = []
        for (i, sibling) in siblings.enumerated() {
            let newNN = String(format: "%02d", i + 1)
            guard let oldP = sibling.path else {
                newSiblings.append(sibling)
                continue
            }
            let oldFilename = (oldP as NSString).lastPathComponent
            let stem = String(oldFilename.dropFirst(3))
            let newFilename: String
            switch sibling.type {
            case .document:
                newFilename = "\(newNN)-\(stem)"
            case .group:
                newFilename = "\(newNN)-\(stem)"
            }
            let newPath = "\(parentPath)/\(newFilename)"
            if oldP != newPath {
                renameSteps.append(.init(
                    oldRelativePath: oldP, newRelativePath: newPath))
            }
            var updated = sibling
            updated.path = newPath
            if updated.type == .group, var children = updated.children {
                Self.rewriteChildPaths(
                    in: &children,
                    oldPrefix: oldP,
                    newPrefix: newPath)
                updated.children = children
            }
            newSiblings.append(updated)
        }

        let plan = try RenamePlan(steps: renameSteps)
        try await documentStore.executeRenamePlan(plan)
        replaceChildren(parentId: parentId, with: newSiblings)
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Walk the structure tree post-order, calling tidyFilenames at every
    /// group level. Single batched manifest save at the end.
    public func tidyAllFilenames() async throws {
        var groupIds: [String?] = []
        Self.collectGroupIds(in: manifest.structure, into: &groupIds)
        groupIds.append(nil)  // root last

        for parentId in groupIds {
            try await tidyFilenames(parentId: parentId)
        }
    }

    /// Link a research item to a manuscript document. Idempotent.
    public func linkResearch(
        researchId: String, toDocumentId documentId: String
    ) async throws {
        var changed = false
        Self.applyLinkMutation(
            documentId: documentId,
            in: &manifest.structure
        ) { item in
            var ids = item.linkedResearchIds ?? []
            if !ids.contains(researchId) {
                ids.append(researchId)
                item.linkedResearchIds = ids
                changed = true
            }
        }
        if changed {
            manifest.modified = Date()
            try await saveManifest()
        }
    }

    /// Remove a research link. Idempotent.
    public func unlinkResearch(
        researchId: String, fromDocumentId documentId: String
    ) async throws {
        var changed = false
        Self.applyLinkMutation(
            documentId: documentId,
            in: &manifest.structure
        ) { item in
            if var ids = item.linkedResearchIds, let idx = ids.firstIndex(of: researchId) {
                ids.remove(at: idx)
                item.linkedResearchIds = ids.isEmpty ? nil : ids
                changed = true
            }
        }
        if changed {
            manifest.modified = Date()
            try await saveManifest()
        }
    }

    /// IDs of research items linked to the given document.
    public func linkedResearchIds(forDocumentId documentId: String) -> [String] {
        Self.findItemLinks(documentId: documentId, in: manifest.structure) ?? []
    }

    /// Resolve a research-id list to actual ResearchItems, skipping orphans.
    public func resolveResearchLinks(_ ids: [String]) -> [ResearchItem] {
        ids.compactMap { id in findResearchItem(id: id, in: manifest.research) }
    }

    private static func applyLinkMutation(
        documentId: String,
        in items: inout [StructureItem],
        transform: (inout StructureItem) -> Void
    ) {
        for i in 0..<items.count {
            if items[i].id == documentId {
                transform(&items[i])
                return
            }
            if var children = items[i].children {
                applyLinkMutation(documentId: documentId, in: &children, transform: transform)
                items[i].children = children
            }
        }
    }

    private static func findItemLinks(
        documentId: String, in items: [StructureItem]
    ) -> [String]? {
        for item in items {
            if item.id == documentId { return item.linkedResearchIds ?? [] }
            if let children = item.children,
               let nested = findItemLinks(documentId: documentId, in: children) {
                return nested
            }
        }
        return nil
    }

    private static func collectGroupIds(
        in items: [StructureItem],
        into result: inout [String?]
    ) {
        for item in items where item.type == .group {
            if let children = item.children {
                collectGroupIds(in: children, into: &result)
            }
            result.append(item.id)
        }
    }

    /// Move the item's file or folder into the project's .trash/ folder and
    /// remove its manifest entry. The original file is recoverable via
    /// restoreLastDeleted() or restoreTrashEntry(id:) within 30 days.
    public func deleteStructureItem(id: String) async throws {
        guard let item = findItem(id: id, in: manifest.structure) else {
            throw ProjectStoreError.structureMissing
        }
        let path = item.path ?? ""
        let parentId = findParentId(of: id, in: manifest.structure, parent: nil)
        let index = currentIndex(of: id, parentId: parentId)
        let metadata = try JSONEncoder().encode(item)

        let entry = try await trashStore.moveToTrash(
            fileRelativePath: path,
            itemMetadata: metadata,
            originalParentId: parentId,
            originalIndex: index,
            displayTitle: item.title)

        removeFromStructure(id: id)
        manifest.modified = Date()
        try await saveManifest()

        trashEntries = (try? await trashStore.list()) ?? trashEntries
        lastDeletedTrashId = entry.id
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

    // MARK: - Trash restore / permanent delete

    /// Restore the most-recently-deleted item from the trash.
    /// No-op if nothing was deleted in this session.
    public func restoreLastDeleted() async throws {
        guard let id = lastDeletedTrashId else { return }
        try await restoreTrashEntry(id: id)
        lastDeletedTrashId = nil
    }

    /// Restore a specific trash entry by id, appending it back into
    /// the structure or research tree. Precise parent/index restoration
    /// is a follow-up; this implementation appends to the root list.
    public func restoreTrashEntry(id: String) async throws {
        let entry = try await trashStore.restore(trashId: id)

        if let item = try? JSONDecoder().decode(StructureItem.self, from: entry.itemMetadata) {
            manifest.structure.append(item)
        } else if let item = try? JSONDecoder().decode(ResearchItem.self, from: entry.itemMetadata) {
            manifest.research.append(item)
        }
        manifest.modified = Date()
        try await saveManifest()
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        if lastDeletedTrashId == id { lastDeletedTrashId = nil }
    }

    /// Permanently delete a specific trash entry (no recovery after this).
    public func permanentlyDeleteTrashEntry(id: String) async throws {
        try await trashStore.permanentlyDelete(trashId: id)
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        if lastDeletedTrashId == id { lastDeletedTrashId = nil }
    }

    /// Permanently delete all trash entries for this project.
    public func emptyTrash() async throws {
        for entry in trashEntries {
            try? await trashStore.permanentlyDelete(trashId: entry.id)
        }
        trashEntries = []
        lastDeletedTrashId = nil
    }

    /// Update an item's inspector fields. `nil` arguments mean "leave unchanged";
    /// to explicitly clear a field, pass an empty string for synopsis/status,
    /// an empty array for tags/links, or `0` for wordTarget.
    public func updateInspector(
        id: String,
        synopsis: String? = nil,
        status: String? = nil,
        tags: [String]? = nil,
        wordTarget: Int? = nil,
        pageTarget: Int? = nil,
        links: [String]? = nil
    ) async throws {
        guard findItem(id: id, in: manifest.structure) != nil else {
            throw ProjectStoreError.structureMissing
        }
        mutateItem(id: id) { item in
            if let synopsis { item.synopsis = synopsis }
            if let status { item.status = status }
            if let tags { item.tags = tags.isEmpty ? nil : tags }
            if let wordTarget {
                // Treat 0 as "clear the target."
                item.wordTarget = wordTarget == 0 ? nil : wordTarget
            }
            if let pageTarget {
                item.pageTarget = pageTarget == 0 ? nil : pageTarget
            }
            if let links { item.links = links.isEmpty ? nil : links }
        }
        manifest.modified = Date()
        try await saveManifest()
    }

    // MARK: - Cross-document search

    /// Run a cross-document search. Cancels any in-flight search; debounces 300ms.
    /// Flushes pending writes for the active document first so the search reads
    /// the freshest content from disk. Results land on currentSearch (Observable).
    public func performSearch(
        query: String, options: SearchOptions
    ) async {
        searchTask?.cancel()

        let task = Task { [weak self] in
            // Debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let self else { return }

            // Pre-search flush so disk reflects active-doc edits
            try? await self.documentStore?.flushPendingSave()
            if Task.isCancelled { return }

            self.searchInProgress = true

            let engine = ProjectSearchEngine()
            let results = await engine.search(query: query, options: options, in: self)

            if Task.isCancelled { return }

            self.currentSearch = results
            self.searchInProgress = false
        }
        searchTask = task
    }

    public func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        currentSearch = nil
        searchInProgress = false
    }

    /// Replace a single search match with the given replacement text.
    /// Loads the file, splices the replacement into the match's char range,
    /// saves via atomic write.
    public func replaceMatch(
        _ match: SearchMatch, with replacement: String
    ) async throws {
        let url = self.url.appendingPathComponent(match.documentPath)
        let original = try String(contentsOf: url, encoding: .utf8)
        let ns = original as NSString
        guard match.charRangeInDocument.location + match.charRangeInDocument.length
                <= ns.length else {
            // Stale match (file changed since search). Caller should re-run search.
            throw ProjectStoreError.fileSystemError("Match range out of bounds")
        }
        let updated = ns.replacingCharacters(
            in: match.charRangeInDocument, with: replacement) as String
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replace all matches in the given results with `replacement`.
    /// Groups by document; applies replacements right-to-left within each
    /// document so earlier offsets aren't shifted by later edits.
    public func replaceAll(
        in results: SearchResults, with replacement: String
    ) async throws {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        for (path, matches) in grouped {
            let url = self.url.appendingPathComponent(path)
            let original = try String(contentsOf: url, encoding: .utf8)
            var ns = original as NSString
            // Right-to-left order
            let ordered = matches.sorted {
                $0.charRangeInDocument.location > $1.charRangeInDocument.location
            }
            for match in ordered {
                // Guard against out-of-bounds in case content changed
                guard match.charRangeInDocument.location + match.charRangeInDocument.length
                        <= ns.length else { continue }
                ns = ns.replacingCharacters(
                    in: match.charRangeInDocument, with: replacement) as NSString
            }
            try (ns as String).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Update project-level targets. Currently surfaces 3a's page target;
    /// future expansion can add total-words / deadline editing through the
    /// same path. Treat 0 as "clear the target" — mirrors per-document word
    /// target convention.
    public func updateProjectTargets(pageTarget: Int) async throws {
        var targets = manifest.targets ?? ProjectTargets()
        targets.pageTarget = pageTarget == 0 ? nil : pageTarget
        manifest.targets = targets
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Toggle the per-project element gutter. nil = default (show); false =
    /// hide. The screenplay editor reads this on each layout pass.
    public func setShowElementGutter(_ value: Bool?) async throws {
        manifest.showElementGutter = value
        manifest.modified = Date()
        try await saveManifest()
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

    // MARK: - Research mutators

    public func addResearchItem(
        parentId: String?,
        title: String,
        kind: ResearchItem.AssetKind?
    ) async throws -> ResearchItem {
        let now = Date()
        let item: ResearchItem
        if kind == nil {
            guard let documentStore else {
                throw ProjectStoreError.fileSystemError("DocumentStore not available")
            }
            let parentPath = researchParentPath(parentId: parentId)
            let slug = Self.researchSlugify(title)
            let folderPath = "\(parentPath)/\(slug)"
            let folderURL = url.appendingPathComponent(folderPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true)
            _ = documentStore
            item = ResearchItem(
                id: Self.newId(prefix: "res-grp"),
                title: title,
                type: .group,
                kind: nil,
                path: folderPath,
                url: nil,
                caption: nil,
                tags: nil,
                links: nil,
                addedAt: now,
                children: [])
        } else {
            throw ProjectStoreError.fileSystemError(
                "Use addResearchAsset or addResearchLink for non-group items")
        }
        appendResearchItem(item, to: parentId)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    public func addResearchAsset(
        parentId: String?,
        fromURL externalURL: URL
    ) async throws -> ResearchItem {
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        let filename = externalURL.lastPathComponent
        guard let kind = ResearchKindInference.kind(forFilename: filename) else {
            throw ProjectStoreError.fileSystemError(
                "Unsupported research file type: \(filename)")
        }

        let parentPath = researchParentPath(parentId: parentId)
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let slug = Self.researchSlugify(stem)
        var targetFilename = "\(slug).\(ext)"
        let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: parentURL, withIntermediateDirectories: true)
        let existing = (try? FileManager.default
            .contentsOfDirectory(atPath: parentURL.path)) ?? []
        targetFilename = Self.researchDedupedFilename(targetFilename, existing: existing)
        let relativePath = "\(parentPath)/\(targetFilename)"
        let targetURL = url.appendingPathComponent(relativePath)

        try await documentStore.executeCopy(from: externalURL, to: targetURL)

        let item = ResearchItem(
            id: Self.newId(prefix: "res"),
            title: stem,
            type: .asset,
            kind: kind,
            path: relativePath,
            url: nil,
            caption: nil,
            tags: nil,
            links: nil,
            addedAt: Date(),
            children: nil)
        appendResearchItem(item, to: parentId)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    public func addResearchLink(
        parentId: String?,
        title: String,
        url linkURL: String
    ) async throws -> ResearchItem {
        let item = ResearchItem(
            id: Self.newId(prefix: "res"),
            title: title,
            type: .asset,
            kind: .link,
            path: nil,
            url: linkURL,
            caption: nil,
            tags: nil,
            links: nil,
            addedAt: Date(),
            children: nil)
        appendResearchItem(item, to: parentId)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    @discardableResult
    public func addResearchTextNote(
        parentId: String?,
        title: String = "Untitled Note"
    ) async throws -> ResearchItem {
        // Determine target folder: research/, or research/<group-slug>/
        let researchRoot = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(
            at: researchRoot, withIntermediateDirectories: true)

        let parentFolder: URL
        if let parentId,
           let parent = findResearchItem(id: parentId, in: manifest.research),
           parent.type == .group {
            let groupSlug = Self.researchSlugify(parent.title)
            parentFolder = researchRoot.appendingPathComponent(groupSlug)
            try FileManager.default.createDirectory(
                at: parentFolder, withIntermediateDirectories: true)
        } else {
            parentFolder = researchRoot
        }

        // Dedup title against existing siblings (numeric suffix)
        let siblings: [ResearchItem]
        if let parentId,
           let parent = findResearchItem(id: parentId, in: manifest.research) {
            siblings = parent.children ?? []
        } else {
            siblings = manifest.research
        }
        let existingTitles = Set(siblings.map { $0.title })
        var resolvedTitle = title
        var counter = 2
        while existingTitles.contains(resolvedTitle) {
            resolvedTitle = "\(title) \(counter)"
            counter += 1
        }

        // Write the empty .md file
        let slug = Self.researchSlugify(resolvedTitle)
        // Dedup against existing files on disk (title-dedup may not match if a
        // prior rename left a stale file at the same slug path).
        var finalFilename = "\(slug).md"
        var diskCounter = 2
        while FileManager.default.fileExists(
            atPath: parentFolder.appendingPathComponent(finalFilename).path) {
            finalFilename = "\(slug)-\(diskCounter).md"
            diskCounter += 1
        }
        let fileURL = parentFolder.appendingPathComponent(finalFilename)
        try Data().write(to: fileURL)

        // Compute relative path from project root
        let relativePath: String = {
            if parentFolder.path == researchRoot.path {
                return "research/\(finalFilename)"
            }
            return "research/\(parentFolder.lastPathComponent)/\(finalFilename)"
        }()

        let item = ResearchItem(
            id: Self.newId(prefix: "res"),
            title: resolvedTitle,
            type: .asset,
            kind: .document,
            path: relativePath,
            url: nil,
            caption: nil,
            tags: nil,
            links: nil,
            addedAt: Date(),
            children: nil)

        appendResearchItem(item, to: parentId)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    // MARK: - Research helpers

    private func researchParentPath(parentId: String?) -> String {
        if let parentId,
           let parent = findResearchItem(id: parentId, in: manifest.research),
           let parentPath = parent.path {
            return parentPath
        }
        return "research"
    }

    private func appendResearchItem(_ item: ResearchItem, to parentId: String?) {
        if let parentId {
            mutateResearchItem(id: parentId) { parent in
                var children = parent.children ?? []
                children.append(item)
                parent.children = children
            }
        } else {
            manifest.research.append(item)
        }
    }

    private func findResearchItem(
        id: String, in items: [ResearchItem]
    ) -> ResearchItem? {
        for it in items {
            if it.id == id { return it }
            if let children = it.children,
               let found = findResearchItem(id: id, in: children) {
                return found
            }
        }
        return nil
    }

    private func mutateResearchItem(
        id: String,
        _ transform: (inout ResearchItem) -> Void
    ) {
        manifest.research = Self.applyResearchMutation(
            id: id, in: manifest.research, transform: transform)
    }

    private static func applyResearchMutation(
        id: String,
        in items: [ResearchItem],
        transform: (inout ResearchItem) -> Void
    ) -> [ResearchItem] {
        items.map { item in
            var copy = item
            if copy.id == id {
                transform(&copy)
            } else if let children = copy.children {
                copy.children = applyResearchMutation(
                    id: id, in: children, transform: transform)
            }
            return copy
        }
    }

    private static func researchSlugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if ch == "-" || ch == "_" || ch.isWhitespace {
                if !lastDash && !out.isEmpty {
                    out.append("-")
                    lastDash = true
                }
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : out
    }

    private static func researchDedupedFilename(
        _ name: String, existing: [String]
    ) -> String {
        let existingSet = Set(existing)
        if !existingSet.contains(name) { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2...999 {
            let candidate = ext.isEmpty
                ? "\(stem)-\(n)"
                : "\(stem)-\(n).\(ext)"
            if !existingSet.contains(candidate) { return candidate }
        }
        return UUID().uuidString
    }

    /// Set or clear the per-project typography override.
    /// Pass `nil` to clear (fall back to user-level defaults).
    public func setProjectTypography(_ override: TypographySettings?) async throws {
        manifest.typography = override
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Resolve the effective typography for an editor: prefer the
    /// project-level override, otherwise fall back to the user default.
    public static func effectiveTypography(
        override: TypographySettings?,
        userDefault: TypographySettings
    ) -> TypographySettings {
        override ?? userDefault
    }

    /// Move a research item. Sibling reorder is manifest-only; cross-group
    /// drag physically moves the file (asset) or folder (group) on disk and
    /// rewrites descendant paths.
    public func moveResearchItem(
        id: String, toParentId: String?, atIndex destIndex: Int
    ) async throws {
        guard let item = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let oldParentId = findResearchParentId(of: id, in: manifest.research, parent: nil)

        // Cycle check for groups.
        if item.type == .group, let toParentId, toParentId == id {
            throw ProjectStoreError.cycle
        }
        if item.type == .group, let toParentId,
           Self.researchContains(id: toParentId, in: item.children ?? []) {
            throw ProjectStoreError.cycle
        }
        // Validate destination parent if non-nil.
        if let toParentId,
           let parent = findResearchItem(id: toParentId, in: manifest.research),
           parent.type != .group {
            throw ProjectStoreError.parentNotFound(toParentId)
        }

        // No-op detection.
        let oldIndex = currentResearchIndex(of: id, parentId: oldParentId)
        if oldParentId == toParentId, oldIndex == destIndex { return }

        // Same-parent reorder → manifest-only.
        if oldParentId == toParentId {
            var siblings = childrenOfResearch(parentId: toParentId)
            guard let from = siblings.firstIndex(where: { $0.id == id }) else {
                throw ProjectStoreError.structureMissing
            }
            let moved = siblings.remove(at: from)
            let clamped = max(0, min(destIndex, siblings.count))
            siblings.insert(moved, at: clamped)
            replaceResearchChildren(parentId: toParentId, with: siblings)
            manifest.modified = Date()
            try await saveManifest()
            return
        }

        // Cross-group: physical move required.
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        let updatedItem: ResearchItem
        if let oldPath = item.path {
            let leaf = (oldPath as NSString).lastPathComponent
            let newParentPath = researchParentPath(parentId: toParentId)
            let parentURL = url.appendingPathComponent(newParentPath, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: parentURL, withIntermediateDirectories: true)
            let existing = (try? FileManager.default
                .contentsOfDirectory(atPath: parentURL.path)) ?? []
            let dedupedLeaf = Self.researchDedupedFilename(leaf, existing: existing)
            let newPath = "\(newParentPath)/\(dedupedLeaf)"
            let plan = try RenamePlan(steps: [
                .init(oldRelativePath: oldPath, newRelativePath: newPath)
            ])
            try await documentStore.executeRenamePlan(plan)

            var copy = item
            copy.path = newPath
            if let children = copy.children {
                copy.children = Self.researchRewriteChildPaths(
                    children, oldPrefix: oldPath, newPrefix: newPath)
            }
            updatedItem = copy
        } else {
            // Link asset — no path. Just relocate in the manifest.
            updatedItem = item
        }

        // Remove from old parent, insert into new parent at clamped index.
        removeResearchItem(id: id)
        var destSiblings = childrenOfResearch(parentId: toParentId)
        let clamped = max(0, min(destIndex, destSiblings.count))
        destSiblings.insert(updatedItem, at: clamped)
        replaceResearchChildren(parentId: toParentId, with: destSiblings)

        manifest.modified = Date()
        try await saveManifest()
    }

    private func findResearchParentId(
        of childId: String, in items: [ResearchItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children,
               let nested = findResearchParentId(
                    of: childId, in: children, parent: item.id) {
                return nested
            }
        }
        return nil
    }

    private func currentResearchIndex(of id: String, parentId: String?) -> Int {
        let siblings = childrenOfResearch(parentId: parentId)
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func childrenOfResearch(parentId: String?) -> [ResearchItem] {
        if let parentId {
            return findResearchItem(id: parentId, in: manifest.research)?.children ?? []
        }
        return manifest.research
    }

    private func replaceResearchChildren(
        parentId: String?, with newChildren: [ResearchItem]
    ) {
        if let parentId {
            mutateResearchItem(id: parentId) { parent in
                parent.children = newChildren
            }
        } else {
            manifest.research = newChildren
        }
    }

    private func removeResearchItem(id: String) {
        manifest.research = Self.applyResearchRemoval(
            id: id, in: manifest.research)
    }

    private static func applyResearchRemoval(
        id: String, in items: [ResearchItem]
    ) -> [ResearchItem] {
        items.compactMap { item in
            if item.id == id { return nil }
            var copy = item
            if let children = copy.children {
                copy.children = applyResearchRemoval(id: id, in: children)
            }
            return copy
        }
    }

    private static func researchContains(id: String, in items: [ResearchItem]) -> Bool {
        for it in items {
            if it.id == id { return true }
            if let children = it.children, researchContains(id: id, in: children) {
                return true
            }
        }
        return false
    }

    private static func researchRewriteChildPaths(
        _ items: [ResearchItem], oldPrefix: String, newPrefix: String
    ) -> [ResearchItem] {
        items.map { item in
            var copy = item
            if let p = copy.path, p.hasPrefix(oldPrefix + "/") {
                copy.path = newPrefix + "/" + p.dropFirst(oldPrefix.count + 1)
            }
            if let children = copy.children {
                copy.children = researchRewriteChildPaths(
                    children, oldPrefix: oldPrefix, newPrefix: newPrefix)
            }
            return copy
        }
    }

    /// Duplicate a research item. Asset → copy file with "Copy of <title>".
    /// Link → new entry with same URL. Group → recursive copy with fresh ids.
    public func duplicateResearchItem(id: String) async throws -> ResearchItem {
        guard let source = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let parentId = findResearchParentId(of: id, in: manifest.research, parent: nil)
        let newTitle = "Copy of " + source.title

        var copy = source
        copy.id = Self.newId(prefix: source.type == .group ? "res-grp" : "res")
        copy.title = newTitle
        copy.addedAt = Date()
        copy.children = source.children?.map { Self.researchFreshIds($0) }

        if let sourcePath = source.path {
            // File or folder — copy on disk.
            guard let documentStore else {
                throw ProjectStoreError.fileSystemError("DocumentStore not available")
            }
            let parentPath = researchParentPath(parentId: parentId)
            let leaf = (sourcePath as NSString).lastPathComponent
            let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)
            let existing = (try? FileManager.default
                .contentsOfDirectory(atPath: parentURL.path)) ?? []
            let newLeaf = Self.researchDedupedFilename(leaf, existing: existing)
            let newPath = "\(parentPath)/\(newLeaf)"
            try await documentStore.executeCopy(
                from: url.appendingPathComponent(sourcePath),
                to: url.appendingPathComponent(newPath))
            copy.path = newPath
            // Rewrite descendant paths if group.
            if let children = copy.children {
                copy.children = Self.researchRewriteChildPaths(
                    children, oldPrefix: sourcePath, newPrefix: newPath)
            }
        }

        // Insert as next sibling of source.
        var siblings = childrenOfResearch(parentId: parentId)
        let sourceIndex = siblings.firstIndex(where: { $0.id == id }) ?? siblings.count - 1
        siblings.insert(copy, at: sourceIndex + 1)
        replaceResearchChildren(parentId: parentId, with: siblings)

        manifest.modified = Date()
        try await saveManifest()
        return copy
    }

    private static func researchFreshIds(_ item: ResearchItem) -> ResearchItem {
        var copy = item
        copy.id = Self.newId(prefix: item.type == .group ? "res-grp" : "res")
        if let children = copy.children {
            copy.children = children.map { researchFreshIds($0) }
        }
        return copy
    }

    /// Delete a research item. File-backed items (assets, groups with folders)
    /// are moved into the project's .trash/ folder (recoverable). Link-type
    /// or path-less items are removed from the manifest directly.
    public func deleteResearchItem(id: String) async throws {
        guard let item = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let parentId = findResearchParentId(
            of: id, in: manifest.research, parent: nil)
        let index = currentResearchIndex(of: id, parentId: parentId)

        if let path = item.path, !path.isEmpty {
            let metadata = try JSONEncoder().encode(item)
            let entry = try await trashStore.moveToTrash(
                fileRelativePath: path,
                itemMetadata: metadata,
                originalParentId: parentId,
                originalIndex: index,
                displayTitle: item.title)
            removeResearchItem(id: id)
            manifest.modified = Date()
            try await saveManifest()
            trashEntries = (try? await trashStore.list()) ?? trashEntries
            lastDeletedTrashId = entry.id
        } else {
            // Path-less items (links, etc.) — just remove from manifest.
            removeResearchItem(id: id)
            manifest.modified = Date()
            try await saveManifest()
        }
    }

    /// Import a list of file URLs (and/or folders) into the research tree
    /// under `toParentId` (nil = root). Folders import as groups containing
    /// recursively-imported children. Files with unknown extensions are
    /// skipped. Caps total imports at 1000 items per call.
    public func importResearchFiles(
        _ urls: [URL], toParentId: String?
    ) async throws -> [ResearchItem] {
        var imported: [ResearchItem] = []
        var counter = 0
        let cap = 1000
        for fileURL in urls {
            if counter >= cap { break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: fileURL.path, isDirectory: &isDir) else {
                continue
            }
            if isDir.boolValue {
                if let group = try await importResearchFolder(
                    fileURL, intoParentId: toParentId, counter: &counter, cap: cap) {
                    imported.append(group)
                }
            } else {
                guard ResearchKindInference.kind(forFilename: fileURL.lastPathComponent) != nil else {
                    continue
                }
                let asset = try await addResearchAsset(
                    parentId: toParentId, fromURL: fileURL)
                imported.append(asset)
                counter += 1
            }
        }
        return imported
    }

    private func importResearchFolder(
        _ folderURL: URL,
        intoParentId: String?,
        counter: inout Int,
        cap: Int
    ) async throws -> ResearchItem? {
        let folderName = folderURL.lastPathComponent
        let group = try await addResearchItem(
            parentId: intoParentId, title: folderName, kind: nil)
        let entries = (try? FileManager.default
            .contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil))
            ?? []
        for entry in entries {
            if counter >= cap { break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                _ = try await importResearchFolder(
                    entry, intoParentId: group.id, counter: &counter, cap: cap)
            } else {
                guard ResearchKindInference.kind(forFilename: entry.lastPathComponent) != nil
                else { continue }
                _ = try await addResearchAsset(parentId: group.id, fromURL: entry)
                counter += 1
            }
        }
        // Re-read the group from manifest to capture inserted children.
        return findResearchItem(id: group.id, in: manifest.research)
    }

    /// Update inline fields on a research item (title, caption, tags, url).
    /// nil arguments leave the corresponding field unchanged. Pass an
    /// explicit empty string / empty array to clear a field.
    /// When `title` changes AND the item has a path whose slug matches the old
    /// title slug, the underlying file (for assets) or folder (for groups) is
    /// renamed on disk to match the new slug before the manifest is updated.
    public func updateResearchItem(
        id: String,
        title: String? = nil,
        caption: String? = nil,
        tags: [String]? = nil,
        url linkURL: String? = nil
    ) async throws {
        guard let oldItem = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }

        // Attempt to rename file/folder on disk when title changes.
        var newPathForRenamed: String?
        var childPathRewrites: [(String, String)] = []
        if let newTitle = title, newTitle != oldItem.title {
            if let result = try renameResearchPath(
                item: oldItem, oldTitle: oldItem.title, newTitle: newTitle) {
                newPathForRenamed = result.newPath
                childPathRewrites = result.childPathRewrites
            }
        }

        mutateResearchItem(id: id) { item in
            if let title { item.title = title }
            if let caption { item.caption = caption }
            if let tags { item.tags = tags }
            if let linkURL { item.url = linkURL }
            if let newPath = newPathForRenamed { item.path = newPath }
        }

        // Apply child path rewrites when a group folder was renamed.
        for (oldPath, newPath) in childPathRewrites {
            rewriteResearchItemPath(from: oldPath, to: newPath, in: &manifest.research)
        }

        manifest.modified = Date()
        try await saveManifest()
    }

    /// Rename the backing file or folder when a research item's title changes.
    /// Returns (newRelativePath, childPathRewrites) or nil if no rename is needed.
    private func renameResearchPath(
        item: ResearchItem,
        oldTitle: String,
        newTitle: String
    ) throws -> (newPath: String, childPathRewrites: [(String, String)])? {
        guard let oldRelPath = item.path else { return nil }
        let oldURL = url.appendingPathComponent(oldRelPath)
        let oldSlug = Self.researchSlugify(oldTitle)
        let newSlug = Self.researchSlugify(newTitle)
        guard oldSlug != newSlug else { return nil }

        let parentDir = oldURL.deletingLastPathComponent()

        if item.type == .group {
            // Rename folder; collect child path rewrites.
            var dedupedSlug = newSlug
            var counter = 2
            while FileManager.default.fileExists(
                atPath: parentDir.appendingPathComponent(dedupedSlug).path) {
                dedupedSlug = "\(newSlug)-\(counter)"
                counter += 1
            }
            let newURL = parentDir.appendingPathComponent(dedupedSlug)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            let newRelative = relativeResearchPath(newURL)
            // Compute child rewrites.
            let oldPrefix = oldRelPath + "/"
            let newPrefix = newRelative + "/"
            var rewrites: [(String, String)] = []
            func walk(_ items: [ResearchItem]) {
                for child in items {
                    if let p = child.path, p.hasPrefix(oldPrefix) {
                        rewrites.append((p, newPrefix + String(p.dropFirst(oldPrefix.count))))
                    }
                    if let cc = child.children { walk(cc) }
                }
            }
            walk(item.children ?? [])
            return (newRelative, rewrites)
        } else {
            // Asset: rename file, preserve extension.
            let ext = oldURL.pathExtension
            var dedupedSlug = newSlug
            var counter = 2
            var newURL = ext.isEmpty
                ? parentDir.appendingPathComponent(dedupedSlug)
                : parentDir.appendingPathComponent("\(dedupedSlug).\(ext)")
            while FileManager.default.fileExists(atPath: newURL.path) {
                dedupedSlug = "\(newSlug)-\(counter)"
                counter += 1
                newURL = ext.isEmpty
                    ? parentDir.appendingPathComponent(dedupedSlug)
                    : parentDir.appendingPathComponent("\(dedupedSlug).\(ext)")
            }
            try FileManager.default.moveItem(at: oldURL, to: newURL)

            // Propagate to sibling <slug>_assets/ folder if it exists.
            let oldAssetsURL = parentDir.appendingPathComponent("\(oldSlug)_assets")
            let newAssetsURL = parentDir.appendingPathComponent("\(dedupedSlug)_assets")
            if FileManager.default.fileExists(atPath: oldAssetsURL.path) {
                try FileManager.default.moveItem(at: oldAssetsURL, to: newAssetsURL)

                // Update internal refs in the renamed note
                if let content = try? String(contentsOf: newURL, encoding: .utf8) {
                    let oldRef = "./\(oldSlug)_assets/"
                    let newRef = "./\(dedupedSlug)_assets/"
                    let rewritten = content.replacingOccurrences(of: oldRef, with: newRef)
                    if rewritten != content {
                        try rewritten.write(to: newURL, atomically: true, encoding: .utf8)
                    }
                }
            }

            return (relativeResearchPath(newURL), [])
        }
    }

    /// Convert an absolute file URL to a path relative to the project root.
    private func relativeResearchPath(_ fileURL: URL) -> String {
        let fullPath = fileURL.path
        let prefix = url.path
        guard fullPath.hasPrefix(prefix) else { return fullPath }
        let relative = String(fullPath.dropFirst(prefix.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    /// Walk `items` recursively and update the first matching `path` in-place.
    private func rewriteResearchItemPath(
        from oldPath: String,
        to newPath: String,
        in items: inout [ResearchItem]
    ) {
        for i in 0..<items.count {
            if items[i].path == oldPath {
                items[i].path = newPath
                return
            }
            if items[i].children != nil {
                rewriteResearchItemPath(from: oldPath, to: newPath, in: &items[i].children!)
            }
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
        case .document: return "doc"   // file extension is orthogonal to ID prefix
        case .group: return "grp"
        }
    }
}

// MARK: - Collection Pieces

/// Mode for a loose Collection piece: prose (.md) or screenplay (.fountain).
public enum PieceMode {
    case prose
    case screenplay

    var fileExtension: String {
        switch self {
        case .prose: return "md"
        case .screenplay: return "fountain"
        }
    }
}

extension ProjectStore {

    /// Add a loose piece to a Collection. Creates `pieces/<NN>-<slug>/`
    /// containing `<slug>.<ext>` (the main doc) plus an empty `research/`
    /// subfolder. Returns the manifest StructureItem for the new piece.
    public func addLoosePiece(
        title: String, mode: PieceMode
    ) async throws -> StructureItem {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "addLoosePiece only valid for Collection projects")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = trimmed.isEmpty ? "Untitled Piece" : trimmed
        let baseSlug = Slugifier.slug(from: baseTitle)

        // Slug dedup against existing piece doc basenames
        let existingSlugs: Set<String> = Set(manifest.structure.compactMap { piece -> String? in
            guard let path = piece.path else { return nil }
            // path for a loose piece is "pieces/<NN>-<slug>/<docSlug>.<ext>";
            // pull the doc slug from the basename without extension.
            let basename = (path as NSString).lastPathComponent
            return basename
                .replacingOccurrences(of: ".md", with: "")
                .replacingOccurrences(of: ".fountain", with: "")
        })
        var slug = baseSlug
        var resolvedTitle = baseTitle
        var counter = 2
        while existingSlugs.contains(slug) {
            slug = "\(baseSlug)-\(counter)"
            resolvedTitle = "\(baseTitle) \(counter)"
            counter += 1
        }

        // Folder NN prefix — next-available among existing piece folder names.
        let nn = String(format: "%02d", nextPieceNumber())
        let folderName = "\(nn)-\(slug)"
        let docName = "\(slug).\(mode.fileExtension)"

        let piecesURL = url.appendingPathComponent("pieces")
        let folderURL = piecesURL.appendingPathComponent(folderName)
        let researchURL = folderURL.appendingPathComponent("research")
        let docURL = folderURL.appendingPathComponent(docName)

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: researchURL, withIntermediateDirectories: true)
        try Data().write(to: docURL)  // empty file

        let relativePath = "pieces/\(folderName)/\(docName)"
        let id = Self.newId(prefix: "doc")
        let item = StructureItem(
            id: id,
            title: resolvedTitle,
            type: .document,
            path: relativePath,
            pieceKind: .loose)

        manifest.structure.append(item)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    private func nextPieceNumber() -> Int {
        let prefixes: [Int] = manifest.structure.compactMap { piece -> Int? in
            guard let path = piece.path else { return nil }
            // Path for a piece: "pieces/<NN>-<slug>/<file>"; folder is the parent
            // dir of the doc. Pull "<NN>" off the folder name.
            let folderName = ((path as NSString).deletingLastPathComponent
                as NSString).lastPathComponent
            let parts = folderName.components(separatedBy: "-")
            guard let first = parts.first, let n = Int(first) else { return nil }
            return n
        }
        return (prefixes.max() ?? 0) + 1
    }

    /// Link an existing standalone Maugham project as a reference piece in
    /// this Collection. Reads target's project.maugham.json for the title
    /// seed, generates a security-scoped bookmark, writes .maugham-link.json
    /// inside pieces/<NN>-<slug>/.
    public func addProjectReference(targetURL: URL) async throws -> StructureItem {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "addProjectReference only valid for Collection projects")
        }
        // Validate target is a Maugham project (has project.maugham.json)
        let targetManifestURL = targetURL.appendingPathComponent("project.maugham.json")
        guard FileManager.default.fileExists(atPath: targetManifestURL.path) else {
            throw ProjectStoreError.fileSystemError(
                "Selected folder is not a Maugham project: \(targetURL.path)")
        }
        let data = try Data(contentsOf: targetManifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let targetManifest = try decoder.decode(ProjectManifest.self, from: data)
        let title = targetManifest.title

        // Slug from title; dedup against existing pieces by folder slug.
        let baseSlug = Slugifier.slug(from: title)
        let existingSlugs: Set<String> = Set(manifest.structure.compactMap { piece -> String? in
            guard let path = piece.path else { return nil }
            let folderName = ((path as NSString).deletingLastPathComponent
                as NSString).lastPathComponent
            // Folder name shape: "<NN>-<slug>". Pull off the leading "<NN>-".
            let parts = folderName.components(separatedBy: "-")
            guard parts.count >= 2 else { return folderName }
            return parts.dropFirst().joined(separator: "-")
        })
        var slug = baseSlug
        var counter = 2
        while existingSlugs.contains(slug) {
            slug = "\(baseSlug)-\(counter)"
            counter += 1
        }

        let nn = String(format: "%02d", nextPieceNumber())
        let folderName = "\(nn)-\(slug)"
        let folderURL = url.appendingPathComponent("pieces/\(folderName)")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // Create security-scoped bookmark
        let bookmarkData = try targetURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        let bookmarkBase64 = bookmarkData.base64EncodedString()

        let linkFile = CollectionLinkFile(
            version: 1,
            title: title,
            path: targetURL.path,
            bookmark: bookmarkBase64,
            linkedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let linkData = try encoder.encode(linkFile)
        let linkURL = folderURL.appendingPathComponent(".maugham-link.json")
        try linkData.write(to: linkURL, options: .atomic)

        let relativePath = "pieces/\(folderName)/.maugham-link.json"
        let item = StructureItem(
            id: Self.newId(prefix: "doc"),
            title: title,
            type: .document,
            path: relativePath,
            pieceKind: .reference,
            linkedProjectPath: targetURL.path,
            linkedProjectBookmark: bookmarkData)

        manifest.structure.append(item)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    /// Promote a loose Collection piece into a standalone Maugham project.
    /// Moves the piece's main doc + research/ subfolder to a fresh project
    /// at `destination`. Converts the Collection's manifest entry into a
    /// reference. Returns the new project's URL.
    public func promotePieceToProject(
        pieceId: String, destination: URL
    ) async throws -> URL {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "promotePieceToProject only valid for Collection projects")
        }
        guard let pieceIdx = manifest.structure.firstIndex(where: { $0.id == pieceId }),
              manifest.structure[pieceIdx].pieceKind == .loose,
              let piecePath = manifest.structure[pieceIdx].path else {
            throw ProjectStoreError.fileSystemError(
                "Piece not found or not a loose piece: \(pieceId)")
        }
        let piece = manifest.structure[pieceIdx]
        let pieceFolderRel = (piecePath as NSString).deletingLastPathComponent
        let pieceFolderURL = url.appendingPathComponent(pieceFolderRel)
        let mainDocName = (piecePath as NSString).lastPathComponent
        let mainDocExt = (mainDocName as NSString).pathExtension
        let newType: ProjectType = mainDocExt == "fountain" ? .screenplay : .shortStory

        // 1. Flush + close any open document for this piece.
        if let docStore = documentStore,
           docStore.openDocumentPath == piecePath {
            try? await docStore.flushPendingSave()
            await docStore.close()
        }

        // 2. Stage the new project under a sibling .maugham-staging-* folder.
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        let stagingURL = parent.appendingPathComponent(
            ".maugham-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            try FileManager.default.createDirectory(
                at: stagingURL.appendingPathComponent("manuscript"),
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: stagingURL.appendingPathComponent("notes"),
                withIntermediateDirectories: true)

            // 3. Move main doc into staging/manuscript/
            let newDocURL = stagingURL.appendingPathComponent("manuscript/\(mainDocName)")
            try FileManager.default.moveItem(
                at: pieceFolderURL.appendingPathComponent(mainDocName),
                to: newDocURL)

            // 4. Move piece's research/ subfolder into staging/research/ (if non-empty)
            let pieceResearchURL = pieceFolderURL.appendingPathComponent("research")
            let newResearchURL = stagingURL.appendingPathComponent("research")
            if FileManager.default.fileExists(atPath: pieceResearchURL.path) {
                try FileManager.default.moveItem(at: pieceResearchURL, to: newResearchURL)
            } else {
                try FileManager.default.createDirectory(
                    at: newResearchURL, withIntermediateDirectories: true)
            }

            // 5. Build + write new project manifest
            let now = Date()
            let docStructItem = StructureItem(
                id: Self.newId(prefix: "doc"),
                title: piece.title,
                type: .document,
                path: "manuscript/\(mainDocName)",
                synopsis: piece.synopsis,
                status: piece.status,
                wordTarget: piece.wordTarget,
                pageTarget: piece.pageTarget,
                tags: piece.tags,
                links: piece.links)
            // Carry over per-piece research as the new project's research items;
            // rewrite their paths from pieces/<NN>-<slug>/research/X to research/X.
            let researchPrefix = "\(pieceFolderRel)/research/"
            let carriedResearch: [ResearchItem] = manifest.research.compactMap { item in
                guard let p = item.path, p.hasPrefix(researchPrefix) else { return nil }
                var copy = item
                copy.path = "research/" + String(p.dropFirst(researchPrefix.count))
                return copy
            }
            let newTargets: ProjectTargets? = {
                if let pt = piece.pageTarget { return ProjectTargets(pageTarget: pt) }
                if let wt = piece.wordTarget { return ProjectTargets(totalWords: wt) }
                return nil
            }()
            let newManifest = ProjectManifest(
                type: newType,
                title: piece.title,
                author: manifest.author,
                created: now,
                modified: now,
                structure: [docStructItem],
                research: carriedResearch,
                targets: newTargets)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(newManifest).write(
                to: stagingURL.appendingPathComponent("project.maugham.json"),
                options: .atomic)

            // 6. Validate by loading
            _ = try await ProjectStore.load(from: stagingURL)

            // 7. Atomic replace to final destination
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination, withItemAt: stagingURL)
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: destination)
            }

            // 8. Convert Collection piece to a reference:
            //    a. Write .maugham-link.json
            //    b. Update manifest entry
            //    c. Remove per-piece research items from manifest.research
            let bookmarkData = try destination.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            let linkFile = CollectionLinkFile(
                version: 1,
                title: piece.title,
                path: destination.path,
                bookmark: bookmarkData.base64EncodedString(),
                linkedAt: now)
            let linkURL = pieceFolderURL.appendingPathComponent(".maugham-link.json")
            try encoder.encode(linkFile).write(to: linkURL, options: .atomic)

            manifest.structure[pieceIdx].pieceKind = .reference
            manifest.structure[pieceIdx].path = "\(pieceFolderRel)/.maugham-link.json"
            manifest.structure[pieceIdx].linkedProjectPath = destination.path
            manifest.structure[pieceIdx].linkedProjectBookmark = bookmarkData
            manifest.structure[pieceIdx].synopsis = nil
            manifest.structure[pieceIdx].status = nil
            manifest.structure[pieceIdx].wordTarget = nil
            manifest.structure[pieceIdx].pageTarget = nil
            // Remove per-piece research entries from Collection's manifest
            manifest.research.removeAll { item in
                item.path?.hasPrefix(researchPrefix) == true
            }
            manifest.modified = now
            try await saveManifest()

            return destination
        } catch {
            // Rollback: delete staging if present
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Add a research note inside a piece's research/ subfolder. Adds a
    /// ResearchItem to manifest.research with a piece-scoped path. The note
    /// is project-local research from the manifest's POV — discoverability
    /// in the binder is done by path-prefix matching (UI layer).
    public func addPieceResearchNote(
        pieceId: String, title: String
    ) async throws -> ResearchItem {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "addPieceResearchNote only valid for Collection projects")
        }
        guard let piece = manifest.structure.first(where: { $0.id == pieceId }),
              piece.pieceKind == .loose,
              let piecePath = piece.path else {
            throw ProjectStoreError.fileSystemError(
                "Unknown loose piece: \(pieceId)")
        }
        // piecePath is "pieces/<NN>-<slug>/<slug>.<ext>"; the piece folder is
        // its parent.
        let pieceFolder = (piecePath as NSString).deletingLastPathComponent
        let researchFolder = "\(pieceFolder)/research"
        let researchFolderURL = url.appendingPathComponent(researchFolder)
        try FileManager.default.createDirectory(
            at: researchFolderURL, withIntermediateDirectories: true)

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = baseTitle.isEmpty ? "Untitled Note" : baseTitle
        let slug = Self.researchSlugify(resolvedTitle)
        var filename = "\(slug).md"
        var counter = 2
        while FileManager.default.fileExists(
            atPath: researchFolderURL.appendingPathComponent(filename).path) {
            filename = "\(slug)-\(counter).md"
            counter += 1
        }
        try Data().write(to: researchFolderURL.appendingPathComponent(filename))

        let relativePath = "\(researchFolder)/\(filename)"
        let item = ResearchItem(
            id: Self.newId(prefix: "res"),
            title: resolvedTitle,
            type: .asset,
            kind: .document,
            path: relativePath,
            addedAt: Date())
        manifest.research.append(item)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    /// Import an asset file into a piece's research/ subfolder. Mirrors
    /// addResearchAsset(parentId:fromURL:) but lands at pieces/<piece>/research/.
    /// Auto-detects kind (image/pdf/audio/document) via ResearchKindInference;
    /// unknown extensions fall back to .document.
    public func addPieceResearchAsset(
        pieceId: String, fromURL sourceURL: URL
    ) async throws -> ResearchItem {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "addPieceResearchAsset only valid for Collection projects")
        }
        guard let piece = manifest.structure.first(where: { $0.id == pieceId }),
              piece.pieceKind == .loose,
              let piecePath = piece.path else {
            throw ProjectStoreError.fileSystemError(
                "Unknown loose piece: \(pieceId)")
        }
        let pieceFolder = (piecePath as NSString).deletingLastPathComponent
        let researchFolder = "\(pieceFolder)/research"
        let researchFolderURL = url.appendingPathComponent(researchFolder)
        try FileManager.default.createDirectory(
            at: researchFolderURL, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent
        let kind = ResearchKindInference.kind(forFilename: filename) ?? .document
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let slug = Self.researchSlugify(stem)
        let existing = (try? FileManager.default
            .contentsOfDirectory(atPath: researchFolderURL.path)) ?? []
        let baseFilename = ext.isEmpty ? slug : "\(slug).\(ext)"
        let targetFilename = Self.researchDedupedFilename(baseFilename, existing: existing)
        let destURL = researchFolderURL.appendingPathComponent(targetFilename)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let relativePath = "\(researchFolder)/\(targetFilename)"
        let item = ResearchItem(
            id: Self.newId(prefix: "res"),
            title: stem,
            type: .asset,
            kind: kind,
            path: relativePath,
            addedAt: Date())
        manifest.research.append(item)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    /// Add a web-link research item scoped to a piece. The manifest entry's
    /// path lives under pieces/<piece>/research/ (as a synthetic .link filename)
    /// so the pane's path-prefix filter includes it in the right section.
    public func addPieceResearchLink(
        pieceId: String, title: String, url linkURL: String
    ) async throws -> ResearchItem {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "addPieceResearchLink only valid for Collection projects")
        }
        guard let piece = manifest.structure.first(where: { $0.id == pieceId }),
              piece.pieceKind == .loose,
              let piecePath = piece.path else {
            throw ProjectStoreError.fileSystemError(
                "Unknown loose piece: \(pieceId)")
        }
        let pieceFolder = (piecePath as NSString).deletingLastPathComponent
        let researchFolder = "\(pieceFolder)/research"
        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = baseTitle.isEmpty ? "Untitled Link" : baseTitle
        let slug = Self.researchSlugify(resolvedTitle)
        // Build a synthetic path for filtering — no file is actually written.
        let existingPaths = Set(manifest.research.compactMap { $0.path })
        var pathName = "\(slug).link"
        var counter = 2
        while existingPaths.contains("\(researchFolder)/\(pathName)") {
            pathName = "\(slug)-\(counter).link"
            counter += 1
        }
        let item = ResearchItem(
            id: Self.newId(prefix: "res"),
            title: resolvedTitle,
            type: .asset,
            kind: .link,
            path: "\(researchFolder)/\(pathName)",
            url: linkURL,
            addedAt: Date())
        manifest.research.append(item)
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    /// Bulk-import files into a piece's research/ folder. Returns all created
    /// items; individual file failures are skipped silently (caller can inspect
    /// the returned count to detect partial failures).
    @discardableResult
    public func importPieceResearchFiles(
        pieceId: String, urls: [URL]
    ) async throws -> [ResearchItem] {
        var imported: [ResearchItem] = []
        for fileURL in urls {
            if let item = try? await addPieceResearchAsset(
                pieceId: pieceId, fromURL: fileURL) {
                imported.append(item)
            }
        }
        return imported
    }

    /// Reorder a Collection piece within manifest.structure. Renumbers all
    /// piece folder NN- prefixes contiguously (01, 02, 03, …), moves folders
    /// on disk to match, updates manifest entry paths, and rewrites per-piece
    /// research item paths whose prefix changed.
    public func movePiece(pieceId: String, toIndex destIndex: Int) async throws {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "movePiece only valid for Collection projects")
        }
        guard let sourceIdx = manifest.structure.firstIndex(where: { $0.id == pieceId }) else {
            throw ProjectStoreError.structureMissing
        }
        if sourceIdx == destIndex { return }

        // 1. Reorder in memory (logical order)
        var reordered = manifest.structure
        let piece = reordered.remove(at: sourceIdx)
        let clamped = max(0, min(destIndex, reordered.count))
        reordered.insert(piece, at: clamped)

        // 2. Compute new NN- prefix for each piece in its new position.
        // Build a path rewrite map: oldFolderRel -> newFolderRel.
        var folderRewrites: [(oldRel: String, newRel: String)] = []
        var updatedPieces: [StructureItem] = []
        for (i, p) in reordered.enumerated() {
            guard let oldPath = p.path else {
                updatedPieces.append(p)
                continue
            }
            let oldFolderRel = (oldPath as NSString).deletingLastPathComponent
            let oldFolderName = (oldFolderRel as NSString).lastPathComponent
            // Strip old NN- prefix (first 3 chars, e.g. "01-"), append new
            let slug = String(oldFolderName.dropFirst(3))
            let newNN = String(format: "%02d", i + 1)
            let newFolderName = "\(newNN)-\(slug)"
            let piecesDirRel = (oldFolderRel as NSString).deletingLastPathComponent
            let newFolderRel = piecesDirRel.isEmpty
                ? newFolderName
                : "\(piecesDirRel)/\(newFolderName)"
            let docName = (oldPath as NSString).lastPathComponent
            let newPath = "\(newFolderRel)/\(docName)"

            if oldFolderRel != newFolderRel {
                folderRewrites.append((oldRel: oldFolderRel, newRel: newFolderRel))
            }

            var copy = p
            copy.path = newPath
            updatedPieces.append(copy)
        }

        // 3. Move folders on disk. Use a two-phase rename via temp names to
        //    avoid collisions when pieces swap positions (e.g. swap 01 and 02
        //    would have moveItem fail because the destination exists).
        let fm = FileManager.default
        let tmpSuffix = "-mv-\(UUID().uuidString.prefix(8))"
        // Phase A: oldRel -> oldRel + tmpSuffix
        for rewrite in folderRewrites {
            let oldURL = url.appendingPathComponent(rewrite.oldRel)
            let tmpURL = url.appendingPathComponent("\(rewrite.oldRel)\(tmpSuffix)")
            try fm.moveItem(at: oldURL, to: tmpURL)
        }
        // Phase B: oldRel + tmpSuffix -> newRel
        for rewrite in folderRewrites {
            let tmpURL = url.appendingPathComponent("\(rewrite.oldRel)\(tmpSuffix)")
            let newURL = url.appendingPathComponent(rewrite.newRel)
            try fm.moveItem(at: tmpURL, to: newURL)
        }

        // 4. Rewrite per-piece research item paths.
        for (i, item) in manifest.research.enumerated() {
            guard let p = item.path else { continue }
            for rewrite in folderRewrites {
                let oldPrefix = "\(rewrite.oldRel)/research/"
                let newPrefix = "\(rewrite.newRel)/research/"
                if p.hasPrefix(oldPrefix) {
                    var copy = item
                    copy.path = newPrefix + String(p.dropFirst(oldPrefix.count))
                    manifest.research[i] = copy
                    break
                }
            }
        }

        // 5. Commit
        manifest.structure = updatedPieces
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Rename a Collection piece. For loose pieces: renames the parent folder
    /// AND the main doc inside it, and rewrites per-piece research item paths
    /// in manifest.research. For reference pieces: renames the parent folder
    /// only (the .maugham-link.json filename stays). Slug dedup against
    /// existing sibling piece folders.
    public func renamePiece(pieceId: String, newTitle: String) async throws {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "renamePiece only valid for Collection projects")
        }
        guard let pieceIdx = manifest.structure.firstIndex(where: { $0.id == pieceId }),
              let oldPath = manifest.structure[pieceIdx].path else {
            throw ProjectStoreError.structureMissing
        }
        let piece = manifest.structure[pieceIdx]
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? "Untitled Piece" : trimmed

        // Old folder = parent of oldPath. Folder name = "<NN>-<oldSlug>".
        let oldFolderRel = (oldPath as NSString).deletingLastPathComponent
        let oldFolderName = (oldFolderRel as NSString).lastPathComponent
        let nnPrefix = String(oldFolderName.prefix(3))  // e.g., "01-"

        let baseSlug = Slugifier.slug(from: resolvedTitle)
        let piecesDirRel = (oldFolderRel as NSString).deletingLastPathComponent  // "pieces"
        let piecesDirURL = url.appendingPathComponent(piecesDirRel)
        let fm = FileManager.default
        let siblingFolders = ((try? fm.contentsOfDirectory(atPath: piecesDirURL.path)) ?? [])
            .filter { $0 != oldFolderName }

        // Slug dedup against sibling folder slugs (strip NN- prefix from each)
        let siblingSlugs: Set<String> = Set(siblingFolders.compactMap { name -> String? in
            let parts = name.components(separatedBy: "-").dropFirst()
            let s = parts.joined(separator: "-")
            return s.isEmpty ? nil : s
        })
        var slug = baseSlug
        var counter = 2
        while siblingSlugs.contains(slug) {
            slug = "\(baseSlug)-\(counter)"
            counter += 1
        }

        let newFolderName = "\(nnPrefix)\(slug)"
        let newFolderRel = piecesDirRel.isEmpty ? newFolderName : "\(piecesDirRel)/\(newFolderName)"
        let oldFolderURL = url.appendingPathComponent(oldFolderRel)
        let newFolderURL = url.appendingPathComponent(newFolderRel)

        // 1. Move the parent folder.
        if oldFolderURL.path != newFolderURL.path {
            try fm.moveItem(at: oldFolderURL, to: newFolderURL)
        }

        // 2. For loose pieces, rename the main doc inside the new folder.
        let newDocBaseName: String
        if piece.pieceKind == .loose {
            let oldDocName = (oldPath as NSString).lastPathComponent
            let oldExt = (oldDocName as NSString).pathExtension
            let newDocName = "\(slug).\(oldExt)"
            if oldDocName != newDocName {
                try fm.moveItem(
                    at: newFolderURL.appendingPathComponent(oldDocName),
                    to: newFolderURL.appendingPathComponent(newDocName))
            }
            newDocBaseName = newDocName
        } else {
            // References keep .maugham-link.json
            newDocBaseName = (oldPath as NSString).lastPathComponent
        }

        let newPiecePath = "\(newFolderRel)/\(newDocBaseName)"

        // 3. Rewrite per-piece research item paths in manifest.research.
        let oldResearchPrefix = "\(oldFolderRel)/research/"
        let newResearchPrefix = "\(newFolderRel)/research/"
        for (i, item) in manifest.research.enumerated() {
            if let p = item.path, p.hasPrefix(oldResearchPrefix) {
                var copy = item
                copy.path = newResearchPrefix + String(p.dropFirst(oldResearchPrefix.count))
                manifest.research[i] = copy
            }
        }

        // 4. Update manifest entry: title + path.
        manifest.structure[pieceIdx].title = resolvedTitle
        manifest.structure[pieceIdx].path = newPiecePath

        manifest.modified = Date()
        try await saveManifest()
    }
}

// MARK: - WikiLinkProject

extension ProjectStore: WikiLinkProject {
    /// Resolve a [[wiki-link]] title to the id of the first manuscript document
    /// whose title matches case-insensitively (after trimming). Used by the
    /// editor's wiki-link click handler to navigate.
    public func resolveDocumentId(forTitle title: String) -> String? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return Self.findFirstByTitle(normalized, in: manifest.structure)
    }

    private static func findFirstByTitle(
        _ normalized: String, in items: [StructureItem]
    ) -> String? {
        for item in items {
            if item.type == .document,
               item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased() == normalized {
                return item.id
            }
            if let children = item.children,
               let nested = findFirstByTitle(normalized, in: children) {
                return nested
            }
        }
        return nil
    }
}

// MARK: - Collection-Pieces: Reference Resolution

public enum ReferenceResolution: Equatable {
    case resolved(URL)
    case resolvedViaPathFallback(URL)
    case unresolved
}

extension ProjectStore {
    public func resolveReference(_ piece: StructureItem) -> ReferenceResolution {
        guard piece.pieceKind == .reference else { return .unresolved }
        // Bookmark path
        if let bookmark = piece.linkedProjectBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale) {
                // Validate it still points at a project
                let manifestURL = resolved.appendingPathComponent("project.maugham.json")
                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    return .resolved(resolved.resolvingSymlinksInPath())
                }
            }
        }
        // Path fallback
        if let pathStr = piece.linkedProjectPath {
            let candidate = URL(fileURLWithPath: pathStr)
            let manifestURL = candidate.appendingPathComponent("project.maugham.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return .resolvedViaPathFallback(candidate)
            }
        }
        return .unresolved
    }

    /// Update an existing reference piece's link target. Rewrites the
    /// .maugham-link.json on disk and refreshes the manifest entry's
    /// path + bookmark. Used by Inspector's Re-link button when the
    /// original reference is unresolved.
    public func relinkReference(pieceId: String, newURL: URL) async throws {
        guard let idx = manifest.structure.firstIndex(where: { $0.id == pieceId }) else {
            throw ProjectStoreError.fileSystemError("Unknown piece: \(pieceId)")
        }
        guard manifest.structure[idx].pieceKind == .reference,
              let relPath = manifest.structure[idx].path else {
            throw ProjectStoreError.fileSystemError("Piece is not a reference")
        }
        let targetManifestURL = newURL.appendingPathComponent("project.maugham.json")
        guard FileManager.default.fileExists(atPath: targetManifestURL.path) else {
            throw ProjectStoreError.fileSystemError(
                "Selected folder is not a Maugham project")
        }
        let bookmarkData = try newURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        manifest.structure[idx].linkedProjectPath = newURL.path
        manifest.structure[idx].linkedProjectBookmark = bookmarkData

        let linkURL = url.appendingPathComponent(relPath)
        let linkFile = CollectionLinkFile(
            version: 1,
            title: manifest.structure[idx].title,
            path: newURL.path,
            bookmark: bookmarkData.base64EncodedString(),
            linkedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(linkFile).write(to: linkURL, options: .atomic)

        manifest.modified = Date()
        try await saveManifest()
    }
}
