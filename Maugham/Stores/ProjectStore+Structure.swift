import AppKit
import MaughamCore
import Foundation

// MARK: - StructureItem CRUD, move, rename, duplicate, tidy

extension ProjectStore {

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
        try await documentStore.relocate(plan: plan)

        removeFromStructure(id: id)
        replaceChildren(parentId: toParentId, with: newDestSiblings)
        manifest.modified = Date()
        try await saveManifest()
        _ = oldPath
    }

    // MARK: - Reorder helpers

    func findParentId(
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

    func currentIndex(of id: String, parentId: String?) -> Int {
        let siblings = childrenOf(parentId: parentId)
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    func childrenOf(parentId: String?) -> [StructureItem] {
        if let parentId {
            return findItem(id: parentId, in: manifest.structure)?.children ?? []
        }
        return manifest.structure
    }

    static func isDescendant(
        ancestorId: String,
        candidateId: String,
        in items: [StructureItem]
    ) -> Bool {
        guard let ancestor = TreeWalk.find(id: ancestorId, in: items) else { return false }
        return TreeWalk.contains(id: candidateId, in: ancestor.children ?? [])
    }

    func replaceChildren(
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

    func findItem(
        id: String, in items: [StructureItem]
    ) -> StructureItem? {
        TreeWalk.find(id: id, in: items)
    }

    /// Mutate the item with the given id in place. The closure receives an
    /// inout reference and can change any field.
    func mutateItem(
        id: String,
        transform: (inout StructureItem) -> Void
    ) {
        manifest.structure = TreeWalk.mutate(id: id, in: manifest.structure) { node in
            var node = node
            transform(&node)
            return node
        }
    }

    func saveManifest() async throws {
        let data: Data
        do {
            data = try ProjectManifest.makeEncoder().encode(manifest)
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
        let manifestURL = url.appendingPathComponent(ProjectManifest.fileName)
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

        // Move on disk through the typed user-content mover. It runs the
        // close-before-FS-surgery discipline (close+unregister the open
        // Document at oldPath so its 750ms autosave can't re-create a phantom
        // at the pre-rename name; flush the research-note debounce) INTERNALLY
        // before the coordinated move (tripwire 14, enforce-by-construction).
        let oldDocURL = url.appendingPathComponent(oldPath)
        do {
            if let ds = documentStore {
                try await ds.relocateUserContent(affectedPaths: [oldPath]) {
                    try await ds.coordinatedMove(from: oldDocURL, to: newURL)
                }
            } else {
                // No DocumentStore (load-only context, e.g. a unit test): no
                // registry and no debounced research saves exist, so the
                // close+flush discipline is a provable no-op and the move is
                // safe to run directly. (TripwireGrepTests exclusion)
                try fm.moveItem(at: oldDocURL, to: newURL) // internal-move: no DocumentStore (no registry to race)
            }
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
    /// `[[oldTitle]]`, rewrite to `[[newTitle]]` THROUGH THE OP LOG.
    ///
    /// The op log is the source of truth for manuscripts; the `.md` on disk is
    /// derived (hard invariant #1). So this rewrite must produce ops, not raw
    /// bytes — the same discipline as `ProjectStore+Search.swift`'s
    /// `replaceInManuscript`. A raw `String.write(to:)` here (the historical
    /// shape) corrupted manuscripts on every rename: for a CLOSED doc the `.md`
    /// diverged from its op log (the reconciler had to guess on the next load);
    /// for an OPEN doc the live `Document` re-materialized and clobbered the
    /// raw write (tripwires 7 + 14, finding 0.1).
    ///
    /// Per-doc failures (a transient load or close that throws) are logged via
    /// `projectStoreLog` and skipped — one bad doc must not abort propagation
    /// to the rest — never swallowed by a bare `try?`. The method stays
    /// non-throwing so a single I/O hiccup can't unwind the whole rename.
    func propagateWikiLinkRename(
        excludeId: String, oldTitle: String, newTitle: String
    ) async {
        for doc in Self.collectDocuments(in: manifest.structure)
        where doc.id != excludeId {
            guard let path = doc.path else { continue }

            // Obtain the Document — the live registry instance if this doc is
            // open, else a transient load. The wiki link appears identically
            // in display form (it isn't an anchor), so we compute the rewrite
            // on `displayText`.
            let docURL = url.appendingPathComponent(path)
            let openDoc = documentStore?.document(for: path)
            let isTransient = (openDoc == nil)

            let resolved: Document
            if let openDoc {
                resolved = openDoc
            } else {
                // Cheap pre-check from the op log (ADR 0018 — op log is source
                // of truth for manuscript content): skip loading a doc whose
                // derived content has no occurrence of oldTitle at all.
                // Guard on !isEmpty: an unbootstrapped doc has no op log yet
                // and materialises to ""; skipping it would silently miss the
                // rename, so we fall through to Document.load which bootstraps.
                let preCheckBody = DerivedManuscript.materialize(
                    forDocId: doc.id, in: url)
                if !preCheckBody.isEmpty,
                   WikiLinkRewriter.rewrite(
                       body: preCheckBody, oldTitle: oldTitle, newTitle: newTitle) == nil {
                    continue
                }
                do {
                    resolved = try await Document.load(
                        url: docURL,
                        device: "wiki-rename",
                        session: "wiki-rename-\(UUID().uuidString.prefix(8))",
                        presenter: documentStore?.presenter)
                } catch {
                    projectStoreLog.error(
                        "Wiki-rename: failed to load \(path, privacy: .public) for propagation: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }

            // Rewrite on display form. nil → no occurrence; nothing to do.
            // Close a transiently-loaded doc on this early-out path too.
            guard let rewritten = WikiLinkRewriter.rewrite(
                body: resolved.displayText,
                oldTitle: oldTitle, newTitle: newTitle) else {
                if isTransient { await resolved.close() }
                continue
            }

            // Commit through the same path normal typing uses (appends an op).
            resolved.setFullText(rewritten)

            // Refresh per-doc word-count cache since the body changed.
            let count = WritingModeFactory.mode(for: path)
                .wordCount(rewritten)
            recordWordCount(forDocumentId: doc.id, wordCount: count)

            // Persist + tear down a transiently-loaded doc, AWAITED exactly
            // once. close() flushes the burst so the `.md` + op log are durable.
            // An already-open doc is left to its live schedulers (its editor
            // binding already reflects the new displayText) — do NOT close it.
            if isTransient { await resolved.close() }
        }
    }

    /// Static slug-deduper used by rename (since we already know NN).
    /// Mirrors FileNaming's collision logic but without computing a new NN.
    static func dedupeSlug(
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
        return dedupedName(base) { existing.contains($0) }
    }

    /// Rewrites the path prefix of every child item recursively.
    /// Thin forwarder to `TreeWalk.rewritePaths` (the reconciled prefix rule).
    static func rewriteChildPaths(
        in children: inout [StructureItem],
        oldPrefix: String,
        newPrefix: String
    ) {
        children = TreeWalk.rewritePaths(
            in: children, replacingPrefix: oldPrefix, with: newPrefix,
            path: { $0.path }, setPath: { $0.path = $1 })
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
    func duplicatedItemTree(
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

    static func newDuplicateId(prefix: String) -> String {
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
        try await documentStore.relocate(plan: plan)
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

    static func applyLinkMutation(
        documentId: String,
        in items: inout [StructureItem],
        transform: (inout StructureItem) -> Void
    ) {
        items = TreeWalk.mutate(id: documentId, in: items) { node in
            var node = node
            transform(&node)
            return node
        }
    }

    static func findItemLinks(
        documentId: String, in items: [StructureItem]
    ) -> [String]? {
        TreeWalk.find(id: documentId, in: items).map { $0.linkedResearchIds ?? [] }
    }

    /// NOT a clean `TreeWalk.collectIds` fit: filters to `.group` AND emits
    /// POST-order (deepest groups first) — `tidyAllFilenames` depends on that
    /// ordering. Left hand-rolled deliberately.
    static func collectGroupIds(
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

        // Trash through the typed user-content mover. It closes+unregisters the
        // open Document and flushes the research-note debounce INTERNALLY before
        // the move, so the 750ms autosave can't re-create a phantom alongside
        // the trashed copy (tripwire 14, enforce-by-construction). With no
        // DocumentStore (load-only context) the discipline is a provable no-op,
        // so the trash move runs directly via the TrashStore.
        let entry: TrashEntry
        if let ds = documentStore {
            entry = try await ds.trash(
                relativePath: path,
                using: trashStore,
                itemMetadata: metadata,
                originalParentId: parentId,
                originalIndex: index,
                displayTitle: item.title)
        } else {
            entry = try await trashStore.moveToTrash( // internal-move: no DocumentStore (no registry to race)
                fileRelativePath: path,
                itemMetadata: metadata,
                originalParentId: parentId,
                originalIndex: index,
                displayTitle: item.title)
        }

        removeFromStructure(id: id)
        manifest.modified = Date()
        try await saveManifest()

        trashEntries = (try? await trashStore.list()) ?? trashEntries
        lastDeletedTrashId = entry.id
    }

    /// Wrap NSWorkspace.recycle's callback API in async/await.
    func recycleURLs(_ urls: [URL]) async throws {
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

    func removeFromStructure(id: String) {
        manifest.structure = TreeWalk.remove(id: id, in: manifest.structure)
    }
}

// MARK: - StructureItemKind helpers

private extension StructureItemKind {
    var itemType: StructureItem.ItemType {
        switch self {
        case .document: return .document
        case .group: return .group
        }
    }

    var idPrefix: String {
        switch self {
        case .document: return "doc"
        case .group: return "grp"
        }
    }
}
