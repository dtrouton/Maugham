import Foundation
import MaughamCore

// MARK: - Trash restore / permanent delete

extension ProjectStore {

    /// Restore the most-recently-deleted item from the trash.
    /// No-op if nothing was deleted in this session.
    public func restoreLastDeleted() async throws {
        guard let id = lastDeletedTrashId else { return }
        try await restoreTrashEntry(id: id)
        lastDeletedTrashId = nil
    }

    /// Restore a specific trash entry by id, re-inserting it under its
    /// recorded `originalParentId` at `originalIndex` (clamped to the parent's
    /// current child count). Falls back to root if the original parent no longer
    /// exists in the manifest.
    ///
    /// ## Descendant-path validation (finding 1.8)
    /// A trashed group's subtree snapshot may include descendant rows whose files
    /// were hard-deleted or moved after the parent was trashed. On restore, every
    /// descendant node's path is validated against the filesystem; nodes whose
    /// paths are absent are dropped. Policy: keep only descendants whose file or
    /// folder exists at the restored location. This prevents dangling binder rows.
    ///
    /// ## File-move via typed mover
    /// `TrashStore.restore` uses a raw `FileManager.moveItem` to move the file
    /// back from `.trash/` to its original path. The typed DocumentStore mover
    /// (`relocate(plan:)`) applies the close-before-FS-surgery discipline
    /// (tripwire 14), but that discipline is a provable no-op here: the
    /// destination had no open Document when it was trashed (the trash path
    /// closed + unregistered it), and there is no in-flight debounced save to
    /// flush. Routing through the typed mover would add complexity without
    /// correctness benefit, so the raw move is kept — consistent with the
    /// no-DocumentStore branch of `deleteStructureItem` and `deleteResearchItem`.
    public func restoreTrashEntry(id: String) async throws {
        let entry = try await trashStore.restore(trashId: id)

        if var item = try? JSONDecoder().decode(StructureItem.self, from: entry.itemMetadata) {
            // Drop any descendant nodes whose files no longer exist on disk
            // (they may have been hard-deleted after the parent was trashed).
            item = pruneStructureMissingFromDisk(item)

            // Re-insert at originalParentId / originalIndex.
            // Fallback: if the original parent is gone, insert at root.
            let targetParentId: String?
            if let pid = entry.originalParentId,
               findItem(id: pid, in: manifest.structure) != nil {
                targetParentId = pid
            } else {
                // Original parent was deleted or this was already a root item.
                targetParentId = nil
            }

            var siblings = childrenOf(parentId: targetParentId)
            let clampedIndex = max(0, min(entry.originalIndex, siblings.count))
            siblings.insert(item, at: clampedIndex)
            replaceChildren(parentId: targetParentId, with: siblings)

        } else if var item = try? JSONDecoder().decode(ResearchItem.self, from: entry.itemMetadata) {
            // Drop any descendant research nodes whose files no longer exist on disk.
            item = pruneResearchMissingFromDisk(item)

            // Re-insert at originalParentId / originalIndex.
            let targetParentId: String?
            if let pid = entry.originalParentId,
               findResearchItem(id: pid, in: manifest.research) != nil {
                targetParentId = pid
            } else {
                targetParentId = nil
            }

            var siblings = childrenOfResearch(parentId: targetParentId)
            let clampedIndex = max(0, min(entry.originalIndex, siblings.count))
            siblings.insert(item, at: clampedIndex)
            replaceResearchChildren(parentId: targetParentId, with: siblings)
        }

        manifest.modified = Date()
        try await saveManifest()
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        if lastDeletedTrashId == id { lastDeletedTrashId = nil }
    }

    // MARK: - Descendant-path validation

    /// Recursively drop any child nodes (and their subtrees) whose `path` does
    /// not correspond to an existing file or folder on disk. The node itself
    /// (top-level) is always kept — only descendants are filtered.
    ///
    /// Policy: keep only descendants that exist at their recorded path under
    /// the project root. A missing descendant is silently dropped rather than
    /// producing a dangling binder row.
    private func pruneStructureMissingFromDisk(_ item: StructureItem) -> StructureItem {
        guard item.type == .group, let children = item.children else { return item }
        let surviving = children.compactMap { child -> StructureItem? in
            guard let path = child.path, !path.isEmpty else { return child }
            let fullURL = url.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fullURL.path) else { return nil }
            return pruneStructureMissingFromDisk(child)
        }
        var pruned = item
        pruned.children = surviving
        return pruned
    }

    /// Recursively drop any research child nodes whose `path` does not exist on disk.
    private func pruneResearchMissingFromDisk(_ item: ResearchItem) -> ResearchItem {
        guard item.type == .group, let children = item.children else { return item }
        let surviving = children.compactMap { child -> ResearchItem? in
            guard let path = child.path, !path.isEmpty else { return child }
            let fullURL = url.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: fullURL.path) else { return nil }
            return pruneResearchMissingFromDisk(child)
        }
        var pruned = item
        pruned.children = surviving
        return pruned
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
}
