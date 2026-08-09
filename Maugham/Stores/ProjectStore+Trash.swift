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
        case .priorVersion:
            report = try await restorePriorVersion(entryId: id)
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
        case priorVersion
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

        // An entry Maugham could not read is now VISIBLE (RULING-7), which means
        // Restore is now a thing the writer can ask of it. It is refused here,
        // naming the real cause, rather than at the sniff below — which would
        // say "nothing in the project describes where it belongs" and sound like
        // a judgement about their item instead of a failure of Maugham's record.
        if entry.isUnreadable {
            throw ProjectStoreError.trashEntryNotRewirable(
                title: entry.displayTitle,
                reason: "Maugham’s record of what it was and where it lived can’t be read. "
                    + "What was deleted is still in the trash folder on disk.")
        }

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
        case .priorVersion:
            // The manifest row was never removed — it points at the rewritten
            // note — so nothing is REWIRED. But a row of its own is minted, or
            // the restore is invisible: see `restorePriorVersion`.
            return .priorVersion
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

    /// Put a kept prior version back, and give it a ROW (whole-branch review,
    /// 2026-08-09).
    ///
    /// **A restore the writer cannot see is not a restore.** This was routed to
    /// `.fileOnly` on the reasoning that nothing needs rewiring — true, and not
    /// the whole question. `.captureAsset`, the other `.fileOnly` subject, goes
    /// back to `.maugham/inbox/`, where the Inbox pane is already looking; a
    /// prior version lands beside the live note in `research/`, where nothing
    /// looks. The row vanished from the Trash pane, the research tree gained
    /// nothing, and the writer's afternoon of prose was a file on disk that no
    /// surface in Maugham would ever show them again — after they had asked for
    /// it back and been told it came.
    ///
    /// The row is minted rather than rewired: the deleted note's own row still
    /// exists and points at the rewritten text, so this is a second artifact,
    /// named for what it is. It lands at the tree's root, beside the live note's
    /// own row, because `TrashStore.restore` lands the FILE beside the live file
    /// — the row and the disk agree afterwards (RULING-41).
    private func restorePriorVersion(entryId: String) async throws -> TrashRestoreReport {
        let entry = try await trashStore.restore(trashId: entryId)
        // Nothing landed: a `carriesFile: false` entry, which no prior version
        // is written as. Nothing to point a row at, and inventing one would
        // give the writer a row over a file that does not exist.
        guard let landed = entry.restoredRelativePath else { return TrashRestoreReport() }
        appendResearchItem(
            ResearchItem(
                id: Self.newId(prefix: "res"),
                title: distinguishedTitle("\(entry.displayTitle) (previous version)",
                                          amongst: manifest.research.map(\.title)),
                type: .asset,
                kind: .document,
                path: landed,
                url: nil,
                caption: nil,
                tags: nil,
                links: nil,
                addedAt: Date(),
                children: nil),
            to: nil)
        return TrashRestoreReport()
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

    /// Permanently delete everything in this project's trash.
    ///
    /// **Empties the trash DIRECTORY, not the cached array** (RULING-7). An
    /// entry written straight through `TrashStore` — which is exactly how the
    /// MCP piece-style tools write one — is in no cache, and an "Empty Trash"
    /// that skipped it reported a completed destruction of content it never
    /// looked at. The writer emptied the trash to be rid of a draft; it was
    /// still in `.trash/`, bound for every backup of the project.
    ///
    /// **A failure is reported, not swallowed.** Each entry is attempted, the
    /// ones that could not be destroyed are counted, and the throw carries them
    /// to `TrashView`'s alert — whose catch was dead code while this method
    /// could not throw. Whatever survived is re-listed first, so the pane and
    /// the message agree about what is left.
    public func emptyTrash() async throws {
        let ids = try await trashStore.entryFolderIds()
        var undestroyed = 0
        for id in ids {
            do {
                try await trashStore.permanentlyDelete(trashId: id)
            } catch {
                undestroyed += 1
            }
        }
        trashEntries = (try? await trashStore.list()) ?? []
        guard undestroyed == 0 else {
            throw ProjectStoreError.trashNotEmptied(undestroyed: undestroyed, total: ids.count)
        }
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

    /// Keep what is at `relativePath` NOW, because Maugham is about to write
    /// over it on the writer's behalf (M6-PR-037, RULING-24, 2026-08-09).
    ///
    /// **The minimal bridge, and deliberately not the versioning milestone.**
    /// RULING-24 places research in the middle tier — recoverable, though not
    /// versioned — and a canvas Rewrite replaced a research note's whole body
    /// with no route back at all: research notes have no op log, checkpoints
    /// walk `manifest.structure` and never `manifest.research`, and nothing was
    /// left in the trash. The same note *deleted* would have been recoverable
    /// for the retention window. This gives a rewrite the standard a delete
    /// already has, using the machinery that already exists, and it is expected
    /// to be superseded by GAP-P1 / research protection when research versioning
    /// is actually scoped.
    ///
    /// The manifest is untouched: the row stays, pointing at the path this
    /// entry's file still occupies, and the caller writes the new body over it.
    /// Nothing arms ⌘⌥Z — the writer's last delete gesture is not what put this
    /// here.
    ///
    /// ## A move, then a copy straight back (whole-branch review, 2026-08-09)
    /// The net effect is a COPY, and it is reached by moving because the MOVE is
    /// what carries the typed mover's flush discipline (tripwire 14) — a queued
    /// 750 ms save landing mid-operation would re-create the note's pre-rewrite
    /// text at the path the rewrite is about to write. A plain copy has no such
    /// discipline to borrow.
    ///
    /// What the copy-back buys is that **the live file exists continuously**.
    /// The caller's next act — writing the new body — is fallible, and while
    /// this method ended at the move, a failed write left the manifest row
    /// pointing at nothing: the note was in the trash, the research pane showed
    /// a row over a missing file, and a rewrite the writer had been told failed
    /// had taken their note with it. Now a failed write leaves the note exactly
    /// as it was, and the trash holds the same words either way.
    @discardableResult
    func trashPriorVersion(at relativePath: String, displayTitle: String,
                           id: String) async throws -> TrashEntry {
        let metadata = try JSONSerialization.data(withJSONObject: ["id": id])
        // Through the typed mover where there is one: a research note has a
        // 750 ms debounced save behind it, and a queued `scheduleFileSave`
        // landing after this move would re-create the note's PRE-rewrite text at
        // the path the rewrite is about to write — tripwire 14 exactly, on the
        // one path that reaches this. With no DocumentStore (load-only context)
        // the discipline is a provable no-op.
        let entry: TrashEntry
        if let ds = documentStore {
            entry = try await ds.trash(
                relativePath: relativePath,
                using: trashStore,
                itemMetadata: metadata,
                originalParentId: nil,
                originalIndex: 0,
                displayTitle: displayTitle,
                subject: .priorVersion)
        } else {
            entry = try await trashStore.moveToTrash( // internal-move: no DocumentStore (no debounce to race)
                fileRelativePath: relativePath,
                itemMetadata: metadata,
                originalParentId: nil,
                originalIndex: 0,
                displayTitle: displayTitle,
                subject: .priorVersion)
        }
        // The copy back, before anything else can fail. A throw here is a disk
        // failure rather than a stranded note — the words are in the entry, the
        // entry is in the pane, and the caller has not written anything yet.
        if let kept = trashStore.entryFileURL(trashId: entry.id) {
            try FileManager.default.copyItem(
                at: kept,
                to: try SafeRelativePath.resolve(relativePath, under: url))
        }
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        return entry
    }

    /// Keep the TEXT an artifact holds now, for the artifacts whose body is not
    /// a file of its own (whole-branch review, 2026-08-09).
    ///
    /// `trashPriorVersion`'s sibling, and the same promise on the other rewrite
    /// arm: a canvas Rewrite of a PALETTE CARD replaces its prose with no route
    /// back, and RULING-24's middle tier is owed to a card's afternoon exactly
    /// as it is owed to a note's. The card's prose lives inside its card file
    /// with the swatches, sensory notes and image references, all of which the
    /// rewrite deliberately keeps — so what is preserved here is the body alone,
    /// written into the entry rather than moved into it.
    ///
    /// No flush dance and no typed mover: nothing on disk is touched, so there
    /// is no debounced save to race. The caller flushes before it reads the body
    /// (`performPaletteCard` does, for its own reasons), which is what makes the
    /// text handed here the text that is really in the card.
    @discardableResult
    func trashPriorVersionText(text: String, displayTitle: String,
                               id: String) async throws -> TrashEntry {
        let metadata = try JSONSerialization.data(withJSONObject: ["id": id])
        // Under `research/` because that is where a RESTORE has to be able to
        // put it: the `.priorVersion` arm files what comes back as a research
        // note, and a note has to live in the research tree to be openable.
        let slug = Slugifier.slug(from: displayTitle)
        let entry = try await trashStore.recordTextEntry(
            text: text,
            filename: "\(slug)-prior.md",
            originalRelativePath: "research/\(slug)-prior.md",
            itemMetadata: metadata,
            displayTitle: displayTitle,
            subject: .priorVersion)
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        return entry
    }
}
