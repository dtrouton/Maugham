import Foundation
import MaughamCore

// MARK: - The record of one delete gesture

/// Everything one delete action put in the trash, and what to call it.
/// `trashIds` is in the order the entries were made; `label` is what the
/// writer would call the thing they deleted ("Chapter 2", "3 items").
public struct TrashDeletion: Equatable, Sendable {
    public var trashIds: [String]
    public var label: String

    public init(trashIds: [String], label: String) {
        self.trashIds = trashIds
        self.label = label
    }
}

/// What a restore actually gave back. A restore that returns less than was
/// deleted NAMES what it could not return, at the moment of the restore
/// (RULING-42) — including writer-authored arrangement (nesting, names), which
/// counts as something returned or named.
public struct TrashRestoreReport: Equatable, Sendable {

    /// An item that came back, but not as it was: under another name because
    /// something already held its own (RULING-38), or in another folder because
    /// the one it lived in is gone (RULING-41).
    public struct Relocation: Equatable, Sendable {
        public var title: String
        public var originalPath: String
        public var restoredPath: String
        /// The title it was deleted under, when the restore had to change it.
        public var renamedFrom: String?
    }

    /// Rows that were part of the deletion and did not come back, named.
    public var unreturned: [String] = []
    public var relocated: [Relocation] = []

    public var isComplete: Bool { unreturned.isEmpty && relocated.isEmpty }

    /// One writer-facing sentence, or nil when everything came back as it was.
    public var message: String? {
        var parts: [String] = []
        if !unreturned.isEmpty {
            parts.append("Couldn’t bring back: \(unreturned.joined(separator: ", ")).")
        }
        for move in relocated {
            if let renamedFrom = move.renamedFrom {
                parts.append("“\(renamedFrom)” came back as “\(move.title)” "
                             + "(\(move.restoredPath)) — something already had its place.")
            } else {
                parts.append("“\(move.title)” came back to \(move.restoredPath), "
                             + "not \(move.originalPath).")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    mutating func absorb(_ other: TrashRestoreReport) {
        unreturned.append(contentsOf: other.unreturned)
        relocated.append(contentsOf: other.relocated)
    }
}

// MARK: - Trash restore / permanent delete

extension ProjectStore {

    /// Restore everything the last delete GESTURE removed — one item or fifty
    /// (RULING-40). Whole, or refused with its reason: the entries are checked
    /// before anything moves, so a refusal restores nothing.
    ///
    /// No-op if nothing has been deleted in this session.
    @discardableResult
    public func restoreLastDeletion() async throws -> TrashRestoreReport? {
        guard let deletion = lastDeletion else { return nil }

        let available = Set(((try? await trashStore.entriesIncludingInternal()) ?? []).map(\.id))
        let missing = deletion.trashIds.filter { !available.contains($0) }
        guard missing.isEmpty else {
            throw ProjectStoreError.deletionNotRestorableWhole(
                label: deletion.label,
                reason: missing.count == deletion.trashIds.count
                    ? "it is no longer in the project’s trash."
                    : "\(missing.count) of its \(deletion.trashIds.count) items are no longer "
                        + "in the project’s trash, and a deletion is restored whole or not at all.")
        }

        var report = TrashRestoreReport()
        for trashId in deletion.trashIds {
            report.absorb(try await restoreTrashEntry(id: trashId))
        }
        lastDeletion = nil
        return report
    }

    /// Restore a specific trash entry by id, re-inserting it under its
    /// recorded `originalParentId` at `originalIndex` (clamped to the parent's
    /// current child count). Falls back to root if the original parent no longer
    /// exists in the manifest.
    ///
    /// ## The binder and the disk agree afterwards (RULING-41)
    /// The destination is computed from where the ROW is going — the recorded
    /// parent if it is still in the manifest, the tree's root folder if it is
    /// not — and handed to `TrashStore.restore`. A row that falls back to root
    /// used to keep its nested path while its file was restored into a
    /// re-created copy of the folder the writer had deleted: a folder no binder
    /// row owned, which then blocked that group's own restore. Nothing
    /// re-creates a deleted folder now, and the row's path is rewritten to
    /// wherever the file actually landed.
    ///
    /// ## Descendant-path validation (finding 1.8)
    /// A trashed group's subtree snapshot may include descendant rows whose files
    /// were hard-deleted or moved after the parent was trashed. On restore, every
    /// descendant node's path is validated against the filesystem; nodes whose
    /// paths are absent are dropped — and NAMED in the returned report, because
    /// nesting the writer authored is something a restore can fail to give back
    /// (RULING-42).
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
    @discardableResult
    public func restoreTrashEntry(id: String) async throws -> TrashRestoreReport {
        let pending = ((try? await trashStore.entriesIncludingInternal()) ?? [])
            .first { $0.id == id }

        var report = TrashRestoreReport()
        switch try restoreRoute(for: pending) {
        case .manuscript(let item):
            report = try await restoreStructureItem(item, entryId: id, pending: pending)
        case .research(let item):
            report = try await restoreResearchItem(item, entryId: id, pending: pending)
        case .fileOnly:
            // A capture's asset (RULING-15): there is no row to rewire, and
            // putting the file back where it was is the whole restore.
            _ = try await trashStore.restore(trashId: id)
        case .unknownEntry:
            // Not in the trash at all: let the store raise its own error rather
            // than inventing one here.
            _ = try await trashStore.restore(trashId: id)
        }

        manifest.modified = Date()
        try await saveManifest()
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        forgetTrashId(id)
        return report
    }

    // MARK: - Routing

    private enum RestoreRoute {
        case manuscript(StructureItem)
        case research(ResearchItem)
        case fileOnly
        case unknownEntry
    }

    /// Which tree (if any) this entry's row goes back to.
    ///
    /// The recorded `subject` decides it where there is one. Where there is not
    /// — an entry written before the field existed — the metadata's shape is
    /// sniffed as it always was, StructureItem first. **An entry that decodes as
    /// neither is REFUSED** (RULING-43): it used to restore its file, change no
    /// manifest row and report success, which is a Restore that means nothing.
    private func restoreRoute(for entry: TrashEntry?) throws -> RestoreRoute {
        guard let entry else { return .unknownEntry }

        func structureItem() -> StructureItem? {
            try? JSONDecoder().decode(StructureItem.self, from: entry.itemMetadata)
        }
        func researchItem() -> ResearchItem? {
            try? JSONDecoder().decode(ResearchItem.self, from: entry.itemMetadata)
        }

        switch entry.subject {
        case .manuscriptItem:
            guard let item = structureItem() else {
                throw ProjectStoreError.trashEntryNotRewirable(
                    title: entry.displayTitle,
                    reason: "its record of where it sat in the binder can’t be read.")
            }
            return .manuscript(item)
        case .researchItem:
            guard let item = researchItem() else {
                throw ProjectStoreError.trashEntryNotRewirable(
                    title: entry.displayTitle,
                    reason: "its record of where it sat in the research tree can’t be read.")
            }
            return .research(item)
        case .captureAsset:
            return .fileOnly
        case .internalArtifact:
            throw ProjectStoreError.trashEntryNotRewirable(
                title: entry.displayTitle,
                reason: "it is Maugham’s own copy of a file you didn’t delete, "
                    + "and nothing in the project would point at it again.")
        case .none:
            if let item = structureItem() { return .manuscript(item) }
            if let item = researchItem() { return .research(item) }
            throw ProjectStoreError.trashEntryNotRewirable(
                title: entry.displayTitle,
                reason: "nothing in the project describes where it belongs.")
        }
    }

    // MARK: - Per-tree restore

    private func restoreStructureItem(
        _ decoded: StructureItem, entryId: String, pending: TrashEntry?
    ) async throws -> TrashRestoreReport {
        var item = decoded
        let targetParentId = survivingParentId(
            pending?.originalParentId, exists: { findItem(id: $0, in: manifest.structure) != nil })
        let parentPath = targetParentId
            .flatMap { findItem(id: $0, in: manifest.structure)?.path }

        let entry = try await trashStore.restore(
            trashId: entryId,
            to: Self.restoreDestination(for: item.path, underParentPath: parentPath))

        var report = TrashRestoreReport()
        if let landed = entry.restoredRelativePath, let was = item.path, landed != was {
            item = Self.rewritingStructurePaths(item, from: was, to: landed)
            let deletedAs = item.title
            item.title = distinguishedTitle(
                item.title,
                amongst: childrenOf(parentId: targetParentId).map(\.title))
            report.relocated.append(.init(
                title: item.title,
                originalPath: was,
                restoredPath: landed,
                renamedFrom: item.title == deletedAs ? nil : deletedAs))
        }

        let pruned = pruneStructureMissingFromDisk(item)
        item = pruned.item
        report.unreturned.append(contentsOf: pruned.dropped)

        var siblings = childrenOf(parentId: targetParentId)
        let clampedIndex = max(0, min(pending?.originalIndex ?? 0, siblings.count))
        siblings.insert(item, at: clampedIndex)
        replaceChildren(parentId: targetParentId, with: siblings)
        return report
    }

    private func restoreResearchItem(
        _ decoded: ResearchItem, entryId: String, pending: TrashEntry?
    ) async throws -> TrashRestoreReport {
        var item = decoded
        let targetParentId = survivingParentId(
            pending?.originalParentId,
            exists: { findResearchItem(id: $0, in: manifest.research) != nil })
        let parentPath = targetParentId
            .flatMap { findResearchItem(id: $0, in: manifest.research)?.path }

        // A manifest-only row (a link, RULING-45) has no file; `restore` hands
        // the record back and touches nothing on disk.
        let entry = try await trashStore.restore(
            trashId: entryId,
            to: (pending?.carriesFile ?? true)
                ? Self.restoreDestination(for: item.path, underParentPath: parentPath)
                : nil)

        var report = TrashRestoreReport()
        if let landed = entry.restoredRelativePath, let was = item.path, landed != was {
            item = Self.rewritingResearchPaths(item, from: was, to: landed)
            let deletedAs = item.title
            item.title = distinguishedTitle(
                item.title,
                amongst: childrenOfResearch(parentId: targetParentId).map(\.title))
            report.relocated.append(.init(
                title: item.title,
                originalPath: was,
                restoredPath: landed,
                renamedFrom: item.title == deletedAs ? nil : deletedAs))
        }

        let pruned = pruneResearchMissingFromDisk(item)
        item = pruned.item
        report.unreturned.append(contentsOf: pruned.dropped)

        var siblings = childrenOfResearch(parentId: targetParentId)
        let clampedIndex = max(0, min(pending?.originalIndex ?? 0, siblings.count))
        siblings.insert(item, at: clampedIndex)
        replaceResearchChildren(parentId: targetParentId, with: siblings)
        return report
    }

    private func survivingParentId(
        _ recorded: String?, exists: (String) -> Bool
    ) -> String? {
        guard let recorded, exists(recorded) else { return nil }
        return recorded
    }

    /// Where the file should land, given where the ROW is going (RULING-41).
    /// Under the target parent's folder when it has one; otherwise beside the
    /// tree's other root-level files — the first component of the item's own
    /// recorded path (`manuscript/`, `research/`), which is a folder that
    /// exists precisely because the tree's other rows live in it. Never inside
    /// a folder the writer deleted.
    static func restoreDestination(for itemPath: String?, underParentPath: String?) -> String? {
        guard let itemPath, !itemPath.isEmpty else { return nil }
        let filename = (itemPath as NSString).lastPathComponent
        if let underParentPath, !underParentPath.isEmpty {
            return "\(underParentPath)/\(filename)"
        }
        let components = itemPath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return itemPath }
        return "\(components[0])/\(filename)"
    }

    /// `title` when nothing else in `amongst` is called that, else the same
    /// numeric-suffix dedupe `addResearchTextNote` uses on a colliding title.
    /// The writer asked for their item back and got it beside the occupant
    /// (RULING-38); two rows with one name would make that indistinguishable.
    private func distinguishedTitle(_ title: String, amongst siblings: [String]) -> String {
        let taken = Set(siblings)
        guard taken.contains(title) else { return title }
        var counter = 2
        var candidate = "\(title) \(counter)"
        while taken.contains(candidate) {
            counter += 1
            candidate = "\(title) \(counter)"
        }
        return candidate
    }

    // MARK: - Path rewriting

    static func rewritingStructurePaths(
        _ item: StructureItem, from oldPath: String, to newPath: String
    ) -> StructureItem {
        var copy = item
        copy.path = newPath
        // A child with no path (or one outside the moved subtree) keeps its own.
        if let children = item.children {
            copy.children = children.map { child in
                guard let childPath = child.path,
                      let moved = Self.rewritten(childPath, from: oldPath, to: newPath) else {
                    return child
                }
                return rewritingStructurePaths(child, from: childPath, to: moved)
            }
        }
        return copy
    }

    static func rewritingResearchPaths(
        _ item: ResearchItem, from oldPath: String, to newPath: String
    ) -> ResearchItem {
        var copy = item
        copy.path = newPath
        if let children = item.children {
            copy.children = children.map { child in
                guard let childPath = child.path,
                      let moved = Self.rewritten(childPath, from: oldPath, to: newPath) else {
                    return child
                }
                return rewritingResearchPaths(child, from: childPath, to: moved)
            }
        }
        return copy
    }

    /// `path` with a leading `oldPrefix/` swapped for `newPrefix/`, or nil when
    /// it isn't under `oldPrefix` at all.
    private static func rewritten(_ path: String?, from oldPrefix: String, to newPrefix: String) -> String? {
        guard let path else { return nil }
        if path == oldPrefix { return newPrefix }
        guard path.hasPrefix(oldPrefix + "/") else { return nil }
        return newPrefix + path.dropFirst(oldPrefix.count)
    }

    // MARK: - Descendant-path validation

    /// Recursively drop any child nodes (and their subtrees) whose `path` does
    /// not correspond to an existing file or folder on disk, RETURNING what was
    /// dropped so the caller can name it (RULING-42). The node itself
    /// (top-level) is always kept — only descendants are filtered.
    private func pruneStructureMissingFromDisk(
        _ item: StructureItem
    ) -> (item: StructureItem, dropped: [String]) {
        guard item.type == .group, let children = item.children else { return (item, []) }
        var dropped: [String] = []
        var surviving: [StructureItem] = []
        for child in children {
            guard let path = child.path, !path.isEmpty else {
                surviving.append(child)
                continue
            }
            guard FileManager.default.fileExists(
                atPath: url.appendingPathComponent(path).path) else {
                dropped.append(child.title)
                continue
            }
            let pruned = pruneStructureMissingFromDisk(child)
            surviving.append(pruned.item)
            dropped.append(contentsOf: pruned.dropped)
        }
        var result = item
        result.children = surviving
        return (result, dropped)
    }

    /// Research sibling of `pruneStructureMissingFromDisk`.
    private func pruneResearchMissingFromDisk(
        _ item: ResearchItem
    ) -> (item: ResearchItem, dropped: [String]) {
        guard item.type == .group, let children = item.children else { return (item, []) }
        var dropped: [String] = []
        var surviving: [ResearchItem] = []
        for child in children {
            guard let path = child.path, !path.isEmpty else {
                surviving.append(child)
                continue
            }
            guard FileManager.default.fileExists(
                atPath: url.appendingPathComponent(path).path) else {
                dropped.append(child.title)
                continue
            }
            let pruned = pruneResearchMissingFromDisk(child)
            surviving.append(pruned.item)
            dropped.append(contentsOf: pruned.dropped)
        }
        var result = item
        result.children = surviving
        return (result, dropped)
    }

    // MARK: - Disposal

    /// Permanently delete a specific trash entry (no recovery after this).
    ///
    /// **The armed deletion is NOT quietly forgotten here.** Destroying part of
    /// a gesture is exactly the condition under which ⌘⌥Z owes the writer a
    /// reason rather than a silent nothing (RULING-40) — `restoreLastDeletion`
    /// finds the entry gone and refuses, saying so.
    public func permanentlyDeleteTrashEntry(id: String) async throws {
        try await trashStore.permanentlyDelete(trashId: id)
        trashEntries = (try? await trashStore.list()) ?? trashEntries
    }

    /// Permanently delete all trash entries for this project.
    public func emptyTrash() async throws {
        for entry in trashEntries {
            try? await trashStore.permanentlyDelete(trashId: entry.id)
        }
        trashEntries = []
    }

    /// Drop `id` from the armed deletion once a RESTORE has consumed it — the
    /// gesture is that much closer to being back. The whole deletion is
    /// disarmed once its last entry has returned. Destruction does not call
    /// this; see `permanentlyDeleteTrashEntry`.
    func forgetTrashId(_ id: String) {
        guard var deletion = lastDeletion else { return }
        deletion.trashIds.removeAll { $0 == id }
        lastDeletion = deletion.trashIds.isEmpty ? nil : deletion
    }

    /// Arm ⌘⌥Z with one delete gesture's worth of entries (RULING-40).
    func armDeletion(trashIds: [String], label: String) {
        lastDeletion = trashIds.isEmpty
            ? nil
            : TrashDeletion(trashIds: trashIds, label: label)
    }

    /// Move a promoted capture's asset into the project trash instead of
    /// unlinking it (RULING-15: Maugham does not delete a file). There is no
    /// manifest row for an inbox asset — the entry is the file, restorable and
    /// then re-ingestable (RULING-14) — so this arms nothing: the writer's last
    /// delete gesture is not what put it there.
    @discardableResult
    func trashCaptureAsset(at relativePath: String, displayTitle: String) async throws -> TrashEntry {
        let metadata = try JSONSerialization.data(
            withJSONObject: ["id": "capture-\((relativePath as NSString).lastPathComponent)"])
        // The asset lives under `.maugham/inbox/` and is never an open Document
        // or a debounced research-note save, so the typed mover's
        // close-before-FS-surgery discipline (tripwire 14) is a provable no-op
        // here — the same reasoning the no-DocumentStore delete branches use.
        let entry = try await trashStore.moveToTrash(  // internal-move: inbox asset, never an open Document
            fileRelativePath: relativePath,
            itemMetadata: metadata,
            originalParentId: nil,
            originalIndex: 0,
            displayTitle: displayTitle,
            subject: .captureAsset)
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        return entry
    }
}
