import AppKit
import MaughamCore
import Foundation

// MARK: - Research mutators

extension ProjectStore {

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

    func researchParentPath(parentId: String?) -> String {
        if let parentId,
           let parent = findResearchItem(id: parentId, in: manifest.research),
           let parentPath = parent.path {
            return parentPath
        }
        return "research"
    }

    func appendResearchItem(_ item: ResearchItem, to parentId: String?) {
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

    func findResearchItem(
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

    func mutateResearchItem(
        id: String,
        _ transform: (inout ResearchItem) -> Void
    ) {
        manifest.research = Self.applyResearchMutation(
            id: id, in: manifest.research, transform: transform)
    }

    static func applyResearchMutation(
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

    static func researchSlugify(_ s: String) -> String {
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

    static func researchDedupedFilename(
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

    func findResearchParentId(
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

    func currentResearchIndex(of id: String, parentId: String?) -> Int {
        let siblings = childrenOfResearch(parentId: parentId)
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    func childrenOfResearch(parentId: String?) -> [ResearchItem] {
        if let parentId {
            return findResearchItem(id: parentId, in: manifest.research)?.children ?? []
        }
        return manifest.research
    }

    func replaceResearchChildren(
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

    func removeResearchItem(id: String) {
        manifest.research = Self.applyResearchRemoval(
            id: id, in: manifest.research)
    }

    static func applyResearchRemoval(
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

    static func researchContains(id: String, in items: [ResearchItem]) -> Bool {
        for it in items {
            if it.id == id { return true }
            if let children = it.children, researchContains(id: id, in: children) {
                return true
            }
        }
        return false
    }

    static func researchRewriteChildPaths(
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

    static func researchFreshIds(_ item: ResearchItem) -> ResearchItem {
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
            // Flush any pending research-note autosave before trashing. A
            // queued save would otherwise land on the original path moments
            // after the trash move, re-creating the file. Same race fix as
            // the deleteStructureItem manuscript close.
            try? await documentStore?.flushPendingSave()
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

    func importResearchFolder(
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
            // Flush any pending research-note autosave before the disk
            // move. Research notes save via `DocumentStore.scheduleFileSave`
            // on a 750ms debounce; if a save is pending it'd land on the
            // OLD path moments after our move, re-creating a phantom file.
            // Same race-class as the manuscript Document close-before-FS
            // pattern, but research notes don't have a Document handle to
            // close — instead we flush the path-keyed scheduler.
            try? await documentStore?.flushPendingSave()
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
    func renameResearchPath(
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
    func relativeResearchPath(_ fileURL: URL) -> String {
        let fullPath = fileURL.path
        let prefix = url.path
        guard fullPath.hasPrefix(prefix) else { return fullPath }
        let relative = String(fullPath.dropFirst(prefix.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    /// Walk `items` recursively and update the first matching `path` in-place.
    func rewriteResearchItemPath(
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
