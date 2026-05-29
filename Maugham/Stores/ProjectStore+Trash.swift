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
}
