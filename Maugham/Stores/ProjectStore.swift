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

    /// Update an item's inspector fields. `nil` arguments mean "leave unchanged";
    /// to explicitly clear a field, pass an empty string.
    public func updateInspector(
        id: String,
        synopsis: String?,
        status: String?
    ) async throws {
        guard findItem(id: id, in: manifest.structure) != nil else {
            throw ProjectStoreError.structureMissing
        }
        mutateItem(id: id) { item in
            if let synopsis { item.synopsis = synopsis }
            if let status { item.status = status }
        }
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
