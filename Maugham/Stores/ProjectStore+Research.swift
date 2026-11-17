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
        // Refuse a group whose minted path would collide with the role-bearing
        // Palette folder (`research/palette`) BEFORE creating anything on disk.
        // Not a check on non-group items: only a group's own folder path can
        // equal the bare `research/palette` (a note mints `<slug>.md`).
        // `addResearchItemUnchecked` is called directly by `ensurePaletteGroup`,
        // the one legitimate minter of that exact path — this guard never sees
        // that call.
        if kind == nil {
            try Self.assertResearchGroupNameNotReserved(
                parentPath: researchParentPath(parentId: parentId), title: title)
        }
        return try await addResearchItemUnchecked(parentId: parentId, title: title, kind: kind)
    }

    /// Core group/asset-kind-guard creator. Named apart from `addResearchItem`
    /// so `ensurePaletteGroup` — the one legitimate minter of the reserved
    /// `research/palette` path — can call it directly and skip the reserved-
    /// name guard above without a bypass flag on the public API.
    func addResearchItemUnchecked(
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
            let slug = Slugifier.slug(from:title)
            let folderPath = "\(parentPath)/\(slug)"
            let folderURL = try resolvedProjectPathToChange(folderPath, isDirectory: true)
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
        beginStructuralVerb(); defer { endStructuralVerb() }
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
        let slug = Slugifier.slug(from:stem)
        var targetFilename = "\(slug).\(ext)"
        let parentURL = try resolvedProjectPathToChange(parentPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: parentURL, withIntermediateDirectories: true)
        let existing = (try? FileManager.default
            .contentsOfDirectory(atPath: parentURL.path)) ?? []
        targetFilename = Self.researchDedupedFilename(targetFilename, existing: existing)
        let relativePath = "\(parentPath)/\(targetFilename)"
        let targetURL = try resolvedProjectPathToChange(relativePath)

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
            let groupSlug = Slugifier.slug(from:parent.title)
            parentFolder = researchRoot.appendingPathComponent(groupSlug) // local-path: a slug of the group's title
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
        let slug = Slugifier.slug(from:resolvedTitle)
        // Dedup against existing files on disk (title-dedup may not match if a
        // prior rename left a stale file at the same slug path).
        var finalFilename = "\(slug).md"
        var diskCounter = 2
        // `attributesOfItem`, not `fileExists`: a dangling link at the slug is
        // taken, not vacant (fileExists follows it and answers false).
        while (try? FileManager.default.attributesOfItem(
            atPath: parentFolder.appendingPathComponent(finalFilename).path)) != nil { // local-path: slugs minted from the titles, under research/
            finalFilename = "\(slug)-\(diskCounter).md"
            diskCounter += 1
        }
        let fileURL = parentFolder.appendingPathComponent(finalFilename) // local-path: slugs minted from the titles, under research/
        try Data().write(to: fileURL, options: .withoutOverwriting) // raw-research-text: create; a link already there (even a dangling one) refuses rather than being followed

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

    // MARK: - New Table (report plan 8b Task 8, D8b-2)

    /// **A new Research table in `parentId`'s group** (nil: the shared
    /// root), blank or holding `content` — `createResearchTable(scope:)`'s
    /// shared arm, and the tree's *New Table* inside a group. See
    /// `writeBlankResearchTable`.
    @discardableResult
    public func addResearchTable(
        parentId: String?, title: String = "Untitled Table", content: ResearchTableContent? = nil
    ) async throws -> ResearchItem {
        try await writeBlankResearchTable(
            in: researchParentPath(parentId: parentId), parentId: parentId, title: title, content: content)
    }

    /// A new table in a Collection piece's own research folder —
    /// `createResearchTable(scope:)`'s piece arm.
    @discardableResult
    public func addPieceResearchTable(
        pieceId: String, title: String = "Untitled Table", content: ResearchTableContent? = nil
    ) async throws -> ResearchItem {
        let (_, _, researchFolder) = try resolveLoosePiece(pieceId)
        return try await writeBlankResearchTable(in: researchFolder, parentId: nil, title: title, content: content)
    }

    /// **What a new Research table is made holding** (report plan 9d Task 5,
    /// `create_research_table`): its table, the language and formula names it
    /// is rendered in (the book's, as the grid's save renders), and who wrote
    /// it — the label its first kept version carries.
    public struct ResearchTableContent {
        public let table: FigureTable
        public let locale: TableLocale
        public let names: FormulaNames
        public let writtenBy: ResearchWriter

        public init(table: FigureTable, locale: TableLocale, names: FormulaNames, writtenBy: ResearchWriter) {
            self.table = table
            self.locale = locale
            self.names = names
            self.writtenBy = writtenBy
        }
    }

    /// A new blank table's rows and columns: a header row and three body
    /// rows, three columns (D8b-2).
    nonisolated static let blankResearchTableShape = (rows: 4, columns: 3)

    /// **The new table's file and sidecar.** Titled `title`, or `title 2`,
    /// `title 3`… — the first no other Research table (any folder, folded as
    /// a `research:` name folds) and no sibling answers to. Its CSV is three
    /// empty columns by four empty rows (`TableCSV.renderResearch`) — or
    /// `content`'s table, rendered in its language and names, so a table made
    /// with cells (`create_research_table`) has no blank first version —
    /// written as a NEW file through the window's coordinated copy, which
    /// refuses an existing file, at a path checked for change (tripwire 58);
    /// its sidecar marks one header row (or `content`'s header, total row and
    /// formats, and who wrote it) for exactly those bytes.
    private func writeBlankResearchTable(
        in folder: String, parentId: String?, title: String, content: ResearchTableContent? = nil
    ) async throws -> ResearchItem {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let documentStore else {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Table" : trimmed
        let siblings = parentId.flatMap { findResearchItem(id: $0, in: manifest.research)?.children }
            ?? manifest.research
        var taken = Set(siblings.map { $0.title.lowercased() })
        taken.formUnion(TreeWalk.collect(in: manifest.research, where: {
            $0.type == .asset && $0.kind == .table
        }).map { $0.title.lowercased() })
        var resolvedTitle = base
        var n = 2
        while taken.contains(resolvedTitle.lowercased()) {
            resolvedTitle = "\(base) \(n)"
            n += 1
        }

        var blank = FigureTable(rows: Self.blankResearchTableShape.rows,
                                columns: Self.blankResearchTableShape.columns)
        blank.headerRows = 1
        let table = content?.table ?? blank
        let names = content?.names ?? .empty
        let data = Data(TableCSV.renderResearch(
            table, locale: content?.locale ?? TableLocale(languageTag: nil), names: names).utf8)

        let folderURL = try resolvedProjectPathToChange(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let filename = Self.researchDedupedFilename(
            "\(Slugifier.slug(from: resolvedTitle)).csv", existing: existing)
        let relativePath = "\(folder)/\(filename)"
        let target = try resolvedProjectPathToChange(relativePath)

        let staging = try FigureIngest.makeTemporaryFolder()
        let staged = staging.appendingPathComponent(filename) // local-path: a temporary folder minted here; the name is a slug
        defer { FigureIngest.removeTemporary(staged) }
        try data.write(to: staged)
        try Self.beforeNewTableCopyForTesting?(target)
        try await documentStore.executeCopy(from: staged, to: target)

        let item = ResearchItem(
            id: Self.newId(prefix: "res"), title: resolvedTitle, type: .asset, kind: .table,
            path: relativePath, addedAt: Date())
        do {
            let sidecar = content.map {
                ResearchTableSidecar(researchTable: table, contentHash: ContentHash.of(data),
                                     formulaNames: names.cited(by: table), writtenBy: $0.writtenBy)
            } ?? ResearchTableSidecar(contentHash: ContentHash.of(data), headerRows: 1)
            try ResearchTableSidecar.write(sidecar, forItem: item.id, in: url)
            appendResearchItem(item, to: parentId)
            manifest.modified = Date()
            try await saveManifest()
        } catch {
            // Nothing the writer saw: the file, its sidecar and its row go
            // back out, so no orphan CSV is left for the next one to dodge.
            removeResearchItem(id: item.id)
            try? FileManager.default.removeItem(at: target) // raw-delete: the blank CSV this verb copied in moments ago, never listed
            if let sidecar = try? ResearchTableSidecar.fileURL(forItem: item.id, in: url) {
                try? FileManager.default.removeItem(at: sidecar) // raw-delete: derived sidecar under .maugham/research-tables/
            }
            throw error
        }
        return item
    }

    /// Test seam: runs in New Table before the copy, handed its target —
    /// where a test plants a file the folder listing missed. Nil in production.
    static var beforeNewTableCopyForTesting: ((URL) throws -> Void)?

    // MARK: - Research helpers

    /// Throws `.researchNameReserved` when a group titled `title` under
    /// `parentPath` would mint the role-bearing Palette folder's own path
    /// (`research/palette`). Comparison is on the MINTED SLUG/PATH, not the
    /// display title, and case-insensitive — the filesystem is too (APFS
    /// default). A nested group (`research/<parent>/palette`) never matches.
    static func assertResearchGroupNameNotReserved(
        parentPath: String, title: String
    ) throws {
        let candidatePath = "\(parentPath)/\(Slugifier.slug(from: title))"
        guard candidatePath.lowercased() == PaletteConvention.folderPath.lowercased() else { return }
        throw ProjectStoreError.researchNameReserved(name: PaletteConvention.groupTitle)
    }

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
        TreeWalk.find(id: id, in: items)
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
        TreeWalk.mutate(id: id, in: items) { node in
            var node = node
            transform(&node)
            return node
        }
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

        // Cross-group: delegate to the batch scope-aware mover (one
        // RenamePlan incl. the note's sibling _assets/ folder, manifest
        // rewrite, single save).
        let target: ResearchMoveTarget = toParentId.map { .group($0) } ?? .sharedRoot
        try await moveResearchItems(ids: [id], to: target, atIndex: destIndex)
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
        TreeWalk.remove(id: id, in: items)
    }

    static func researchContains(id: String, in items: [ResearchItem]) -> Bool {
        TreeWalk.contains(id: id, in: items)
    }

    static func researchRewriteChildPaths(
        _ items: [ResearchItem], oldPrefix: String, newPrefix: String
    ) -> [ResearchItem] {
        TreeWalk.rewritePaths(
            in: items, replacingPrefix: oldPrefix, with: newPrefix,
            path: { $0.path }, setPath: { $0.path = $1 })
    }

    /// Duplicate a research item. Asset → copy file with "Copy of <title>".
    /// Link → new entry with same URL. Group → recursive copy with fresh ids.
    public func duplicateResearchItem(id: String) async throws -> ResearchItem {
        beginStructuralVerb(); defer { endStructuralVerb() }
        // Keys held in the Trash count too: a restore would bring them back.
        let trashedKeys = await trashedResearchCitationKeys()
        guard let source = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let parentId = findResearchParentId(of: id, in: manifest.research, parent: nil)
        let newTitle = "Copy of " + source.title

        var copy = source
        copy.id = Self.newId(prefix: source.type == .group ? "res-grp" : "res")
        copy.children = source.children?.map { Self.researchFreshIds($0) }
        // A copy must not share a citation key (`[@key]` would be ambiguous).
        // Keyed before the rename, so a key stemmed from the title uses the
        // source's title, not "Copy of …".
        copy = copy.rekeyingCitations(
            existing: manifest.research.citationKeys.union(trashedKeys))
        copy.title = newTitle
        copy.addedAt = Date()

        if let sourcePath = source.path {
            // File or folder — copy on disk.
            guard let documentStore else {
                throw ProjectStoreError.fileSystemError("DocumentStore not available")
            }
            let parentPath = researchParentPath(parentId: parentId)
            let leaf = (sourcePath as NSString).lastPathComponent
            let parentURL = try resolvedProjectPath(parentPath, isDirectory: true)
            let existing = (try? FileManager.default
                .contentsOfDirectory(atPath: parentURL.path)) ?? []
            let newLeaf = Self.researchDedupedFilename(leaf, existing: existing)
            let newPath = "\(parentPath)/\(newLeaf)"
            try await documentStore.executeCopy(
                from: try resolvedProjectPath(sourcePath),
                to: try resolvedProjectPathToChange(newPath))
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

    /// NOT a `TreeWalk` fit: regenerates every node's id (a whole-tree
    /// transform), not a find/mutate-by-id. Left hand-rolled deliberately.
    static func researchFreshIds(_ item: ResearchItem) -> ResearchItem {
        var copy = item
        copy.id = Self.newId(prefix: item.type == .group ? "res-grp" : "res")
        if let children = copy.children {
            copy.children = children.map { researchFreshIds($0) }
        }
        return copy
    }

    /// Trash one item's file (if any) and remove it from the manifest.
    /// Does NOT save the manifest or refresh trashEntries — callers batch that.
    /// Returns the trash entry when a file was trashed.
    ///
    /// Link items are never file-trashed even when `path` is non-nil: a
    /// never-moved shared link mints `path: nil` (`addResearchLink`), but a
    /// piece-scoped link (`addPieceResearchLink`) or a link that has been
    /// moved (`moveResearchItems`) carries a *synthetic* `.link` path with no
    /// backing file on disk. Attempting to trash that path would throw
    /// (`FileManager.moveItem` "no such file") instead of deleting the item.
    ///
    /// **A link still gets a trash entry** (RULING-45): delete has one meaning
    /// for every row, and a link's URL and title are trivially storable, so the
    /// entry IS the metadata record and restore puts the row back. What a link
    /// has no need of is the typed mover — there is no file to move, so
    /// tripwire 14's close-before-FS-surgery discipline has nothing to protect.
    /// **Whether `item` names a file outside every research root** — a row
    /// that owns a file (anything but a link) whose path a synced manifest
    /// (untrusted input, tripwire 58's reason) points at the manuscript or a
    /// `.maugham/` file. `ResearchTextRole.isInsideAResearchRoot` is the one
    /// spelling of the roots. The typed mover never renames, moves or trashes
    /// such a file: rename and move refuse (`outsideResearch`), and a delete
    /// takes the row only (`trashResearchItemCore`).
    func namesAFileOutsideResearch(_ item: ResearchItem) -> Bool {
        guard item.kind != .link, let path = item.path, !path.isEmpty else { return false }
        return !ResearchTextRole.isInsideAResearchRoot(path, structure: manifest.structure)
    }

    /// **Why `item` may not be trashed, thrown** — asked for every item of a
    /// batch before any is trashed (all or nothing), and again by the core. A
    /// path that leaves the project is refused as that (tripwire 58);
    /// row-only is for in-project paths outside Research. A GROUP row naming a
    /// folder outside Research is refused while it holds rows: taking its row
    /// alone would leave their files untracked.
    private func refuseTrashing(_ item: ResearchItem) throws {
        guard item.kind != .link, let path = item.path, !path.isEmpty else { return }
        _ = try resolvedProjectPathToChange(path)
        if item.type == .group, namesAFileOutsideResearch(item), !(item.children ?? []).isEmpty {
            throw ProjectStoreError.fileSystemError(
                "“\(item.title)” isn’t inside Research, so only its row can be deleted, and it still holds items. Move or delete what is in it first.")
        }
    }

    /// **Whether `item`'s file (a group's folder) is already gone from disk**
    /// — deleted in Finder, say. RULING-63: such a row is still deletable, and
    /// is trashed as the ROW (a manifest-only entry), so the gesture completes
    /// and ⌘⌥Z puts the row back. A group is missing only if its folder is;
    /// its rows go with it in the entry. The leaf is not followed (a dangling
    /// link is there, and moves as a link), and an old-style iCloud placeholder
    /// (`.<name>.icloud`) is a file still coming down, never a missing one
    /// (tripwire 18): it takes the ordinary route.
    ///
    /// **Only "no such file" is missing.** A folder Maugham may not read, or a
    /// volume that is not there, fails the same look for another reason; the
    /// file may well be there, and trashing its row alone would leave it with
    /// no row to own it. Any other failure takes the ordinary route, whose
    /// move fails and is reported.
    private func namesAMissingFile(_ item: ResearchItem) -> Bool {
        guard item.kind != .link, let path = item.path, !path.isEmpty,
              let fileURL = try? resolvedProjectPathToChange(path) else { return false }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return false
        } catch {
            return Self.isNoSuchFile(error) && !Self.hasICloudPlaceholder(for: fileURL)
        }
    }

    /// `NSFileReadNoSuchFileError`, or POSIX `ENOENT` beneath it — and nothing else.
    private static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
    }

    // MARK: - Items a verb is moving (#142 T2)

    /// The Research items a verb is moving now (`withResearchItemsInFlight`).
    var researchItemsInFlight: Set<String> { Set(researchItemsInFlightCounts.keys) }

    /// **`body` moves the files of the Research items `ids` (each one's
    /// descendants too)** — a move, a rename, a trash. Each verb wraps ONLY
    /// the span from just before it calls the typed mover until the
    /// in-memory manifest names where the items now are (or their rows are
    /// gone); the manifest's save and a moved note's asset refs are outside
    /// it. Inside `body` the task is marked as the one moving them
    /// (`ResearchItemsMoving.byThisTask`), so the mover's own flush is
    /// written as before. Nothing waits on the span (the note door turns a
    /// save that meets it away, `ResearchNoteDoor.write`). The ids leave when
    /// `body` returns or throws, and a note released then whose timer's save
    /// the span stopped has its timer set again
    /// (`DocumentStore.researchNoteSpanEnded`).
    func withResearchItemsInFlight<T>(_ ids: [String], _ body: () async throws -> T) async rethrows -> T {
        var all: [String] = []
        for id in ids {
            all.append(id)
            if let item = findResearchItem(id: id, in: manifest.research) {
                all += TreeWalk.collect(in: item.children ?? [], where: { _ in true }).map(\.id)
            }
        }
        for id in all { researchItemsInFlightCounts[id, default: 0] += 1 }
        defer {
            for id in all {
                let left = (researchItemsInFlightCounts[id] ?? 1) - 1
                researchItemsInFlightCounts[id] = left > 0 ? left : nil
            }
            for id in Set(all) where researchItemsInFlightCounts[id] == nil {
                documentStore?.researchNoteSpanEnded(itemId: id)
            }
        }
        return try await ResearchItemsMoving.$byThisTask.withValue(
            ResearchItemsMoving.byThisTask.union(all)) { try await body() }
    }

    private func trashResearchItemCore(id: String) async throws -> TrashEntry? {
        guard let item = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let parentId = findResearchParentId(
            of: id, in: manifest.research, parent: nil)
        let index = currentResearchIndex(of: id, parentId: parentId)

        try refuseTrashing(item)
        // From just before the trash until the row is gone, a note save by
        // anyone but this verb that finds the file missing (moved to the trash, or
        // already gone outside: the row-only arm) is turned away rather than
        // writing the file afresh at its old path (#142 T2): a timer save stays
        // pending and is re-armed when the span ends, a flush keeps its text
        // aside, a direct save is not made.
        return try await withResearchItemsInFlight([id]) {
            var entry: TrashEntry?
            // A link has no file; a row naming a file outside every research root
            // must not move that file (it is the manuscript or Maugham's own), so
            // both are trashed as the ROW only: the entry is the record, the file
            // stays exactly where it is, and a restore puts the row back. A row
            // whose file is already gone has nothing to move either (RULING-63).
            if item.kind == .link || namesAFileOutsideResearch(item) || namesAMissingFile(item) {
                let metadata = try JSONEncoder().encode(item)
                entry = try await trashStore.recordManifestOnlyTrash(
                    originalRelativePath: item.path ?? "",
                    itemMetadata: metadata,
                    originalParentId: parentId,
                    originalIndex: index,
                    displayTitle: item.title,
                    subject: .researchItem)
            } else if let path = item.path, !path.isEmpty {
                // Trash through the typed user-content mover. It flushes the
                // research-note debounce (and closes+unregisters any open Document)
                // INTERNALLY before the move, so a queued `scheduleFileSave` can't
                // land on the original path post-move and re-create the file
                // (tripwire 14, enforce-by-construction). With no DocumentStore
                // (load-only context) the discipline is a provable no-op.
                let metadata = try JSONEncoder().encode(item)
                if let ds = documentStore {
                    entry = try await ds.trash(
                        relativePath: path,
                        using: trashStore,
                        itemMetadata: metadata,
                        originalParentId: parentId,
                        originalIndex: index,
                        displayTitle: item.title,
                        subject: .researchItem)
                } else {
                    entry = try await trashStore.moveToTrash( // internal-move: no DocumentStore (no registry to race)
                        fileRelativePath: path,
                        itemMetadata: metadata,
                        originalParentId: parentId,
                        originalIndex: index,
                        displayTitle: item.title,
                        subject: .researchItem)
                }
            }
            removeResearchItem(id: id)
            return entry
        }
    }

    /// Delete a research item. File-backed items (assets, groups with folders)
    /// are moved into the project's .trash/ folder (recoverable). Link-type
    /// or path-less items are removed from the manifest directly.
    public func deleteResearchItem(id: String) async throws {
        try await deleteResearchItems(ids: [id])
    }

    /// Batch-delete research items in one manifest save. Descendants of a
    /// selected group are collapsed out (via `collapseResearchSelection`) so
    /// they aren't trashed twice.
    ///
    /// The whole batch is ONE delete gesture, so ⌘⌥Z is armed with every entry
    /// it made and returns all of them or none (RULING-40) — it used to be
    /// armed with the last entry alone, and returned one of fifty saying
    /// nothing about the rest.
    public func deleteResearchItems(ids: [String]) async throws {
        beginStructuralVerb(); defer { endStructuralVerb() }
        let effective = collapseResearchSelection(ids)
        // Validate the whole batch before trashing anything.
        var titles: [String] = []
        for id in effective {
            guard let item = findResearchItem(id: id, in: manifest.research) else {
                throw ProjectStoreError.structureMissing
            }
            try refuseTrashing(item)
            titles.append(item.title)
        }
        var entries: [TrashEntry] = []
        var trashed: [String] = []
        var removed: [String] = []
        for (id, title) in zip(effective, titles) {
            do {
                if let entry = try await trashResearchItemCore(id: id) {
                    entries.append(entry)
                    trashed.append(title)
                } else {
                    removed.append(title)
                }
            } catch {
                // RULING-63 (RULING-52's route): nothing changed, nothing to say
                // beyond the item's own error; something did, and it is saved,
                // shown, armed and named beside what was not deleted.
                guard !trashed.isEmpty || !removed.isEmpty else { throw error }
                throw await settleDeletedInPart(
                    entries: entries, trashed: trashed, removed: removed, failed: title, underlying: error)
            }
        }
        manifest.modified = Date()
        try await saveManifest()
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        armDeletion(trashIds: entries.map(\.id), label: Self.deletionLabel(titles))
    }

    /// **A note this call has just created, whose body the door refused,
    /// taken back** (#148 D1): `add_note`, an inbox promotion and a kept
    /// letter create the note empty and then save its body; when that save
    /// does not land, the error they throw is this function's answer. The
    /// row and file are `created`'s alone (its id is fresh, its file was
    /// minted beside any note of the same title, never over it), so a note
    /// the writer already had is never touched. They leave through the
    /// ordinary delete path, trashed by id and then permanently deleted:
    /// no Trash entry is left and ⌘⌥Z is not armed — the writer never made
    /// this note. A file that holds bytes is not the empty note this call
    /// made (something wrote it meanwhile) and is left, as is anything a
    /// failed cleanup could not take: the refusal then says what was left.
    func takeBackUnsavedNewNote(_ created: ResearchItem, refusal: Error) async -> Error {
        do {
            if let path = created.path, !path.isEmpty {
                let fileURL = try resolvedProjectPathToChange(path)
                // Gone is nothing to lose; a size that will not read is not
                // empty (RULING-7), and the catch below says it was left.
                let size = FileManager.default.fileExists(atPath: fileURL.path)
                    ? try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int : 0
                guard size == 0 else {
                    return ProjectStoreError.fileSystemError(Self.saying(refusal,
                        "; the note “\(created.title)” was left in Research because its file changed outside Maugham."))
                }
            }
            try await discardUnsavedNewNote(id: created.id)
            return refusal
        } catch {
            projectStoreLog.error(
                "The empty note \(created.id, privacy: .public) was not taken back: \(error.localizedDescription, privacy: .public)")
            return ProjectStoreError.fileSystemError(Self.saying(refusal,
                "; the empty note “\(created.title)” was left in Research."))
        }
    }

    /// `refusal`'s sentence, its full stop replaced by `tail`.
    private static func saying(_ refusal: Error, _ tail: String) -> String {
        var said = refusal.localizedDescription
        if said.hasSuffix(".") { said.removeLast() }
        return said + tail
    }

    /// The row taken through `trashResearchItemCore`, the manifest saved,
    /// and the entry permanently deleted (`permanentlyDeleteTrashEntry`).
    /// The link a kept letter's create made to its chapter (`.sharedPlusLink`)
    /// goes with it; nothing else could name a fresh id.
    private func discardUnsavedNewNote(id: String) async throws {
        beginStructuralVerb(); defer { endStructuralVerb() }
        let linking = TreeWalk.collect(in: manifest.structure) { $0.linkedResearchIds?.contains(id) == true }
        for document in linking {
            try await unlinkResearch(researchId: id, fromDocumentId: document.id)
        }
        let entry = try await trashResearchItemCore(id: id)
        manifest.modified = Date()
        try await saveManifest()
        if let entry {
            try await permanentlyDeleteTrashEntry(id: entry.id)
        } else {
            trashEntries = (try? await trashStore.list()) ?? trashEntries
        }
    }

    /// ⌘⌥Z's name for a gesture over `titles`: the one title, or "N items".
    private static func deletionLabel(_ titles: [String]) -> String {
        titles.count == 1 ? (titles.first ?? "") : "\(titles.count) items"
    }

    /// **A delete gesture that stopped partway, settled** (RULING-63): the
    /// rows already taken are saved as gone, the pane is refreshed and ⌘⌥Z
    /// is armed with exactly the entries that landed — armed before the save,
    /// so a save that fails still leaves the route back — and the error to
    /// throw names both halves. A row removed with no entry (`removed`) is
    /// named apart and never counted as what ⌘⌥Z puts back; with no entry at
    /// all, ⌘⌥Z is cleared, as a clean delete that makes no entry clears it
    /// (M3-TR-036): it never points at an earlier, unrelated gesture. Only
    /// reached once something changed. A save that fails throws its own
    /// error with the titles named in it.
    private func settleDeletedInPart(
        entries: [TrashEntry], trashed: [String], removed: [String], failed: String, underlying: Error
    ) async -> Error {
        let partial = ProjectStoreError.deletedInPart(
            trashed: trashed, removed: removed, failed: failed, underlying: underlying.localizedDescription)
        manifest.modified = Date()
        armDeletion(trashIds: entries.map(\.id), label: Self.deletionLabel(trashed))
        var saveError: Error?
        do { try await saveManifest() } catch { saveError = error }
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        guard let saveError else { return partial }
        let saveFailure: String
        if case .manifestUnwritable(let detail)? = saveError as? ProjectStoreError {
            saveFailure = detail
        } else {
            saveFailure = saveError.localizedDescription
        }
        return ProjectStoreError.manifestUnwritable("\(saveFailure). \(partial.errorDescription ?? "")")
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
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let oldItem = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }

        // Attempt to rename file/folder on disk when title changes.
        var newPathForRenamed: String?
        var childPathRewrites: [(String, String)] = []
        var assetRefs: (oldStem: String, newStem: String)?
        func applyFields() {
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
        }
        if let newTitle = title, newTitle != oldItem.title {
            // The second door: a rename that re-slugs a group onto the
            // reserved `research/palette` path is the same defect as
            // creation. Skipped for the REAL palette group (role ==
            // .paletteGroup) — renaming it back onto its own path is a no-op,
            // not a collision — and for non-groups, which can't mint a bare
            // folder path.
            if oldItem.type == .group, oldItem.role != .paletteGroup, let oldPath = oldItem.path {
                let parentPath = (oldPath as NSString).deletingLastPathComponent
                try Self.assertResearchGroupNameNotReserved(parentPath: parentPath, title: newTitle)
            }
            // Rename the backing file/folder through the typed user-content
            // mover. It closes+unregisters any open Document and flushes the
            // research-note debounce INTERNALLY before `renameResearchPath`
            // runs its coordinated moves, so a queued `scheduleFileSave` can't
            // land on the OLD path post-move and re-create a phantom file
            // (tripwire 14, enforce-by-construction). `affectedPaths` is the
            // item's own old path; the flush is path-agnostic so child notes
            // under a renamed group folder are covered too.
            // Both refusals before the typed mover runs: it closes and
            // unregisters every open Document at the path first, so a rename
            // refused inside it would leave the writer's open chapter closed
            // under the editor. A path that leaves the project is refused as
            // that (tripwire 58); a row naming a file outside every research
            // root renames nothing.
            if let oldPath = oldItem.path, oldItem.kind != .link {
                _ = try resolvedProjectPathToChange(oldPath)
                if namesAFileOutsideResearch(oldItem) { throw ProjectStoreError.outsideResearch(title: oldItem.title) }
            }
            let affected = oldItem.path.map { [$0] } ?? []
            let renameBody: () async throws -> Void = { [self] in
                if let result = try await renameResearchPath(
                    item: oldItem, oldTitle: oldItem.title, newTitle: newTitle,
                    via: documentStore) {
                    newPathForRenamed = result.newPath
                    childPathRewrites = result.childPathRewrites
                    assetRefs = result.assetRefs
                }
            }
            // From just before the typed mover until the in-memory manifest
            // names the new path (the item's, and a group's descendants'), a
            // note save by anyone but this verb that finds the old file gone is
            // turned away rather than writing it afresh (#142 T2): a timer save
            // stays pending and is re-armed when the span ends, a flush keeps
            // its text aside, a direct save is not made. The asset refs and
            // the save are outside the span.
            try await withResearchItemsInFlight([id]) {
                if let ds = documentStore {
                    try await ds.relocateUserContent(
                        affectedPaths: affected, perform: renameBody)
                } else {
                    // No DocumentStore (load-only context): no registry/scheduler to
                    // race, so the discipline is a provable no-op. renameResearchPath
                    // falls back to raw moves internally when `via` is nil.
                    try await renameBody()
                }
                applyFields()
            }
        } else {
            applyFields()
        }

        // The renamed note's `./<old>_assets/` refs, once the in-memory manifest
        // names where it now is (the note door asks the item's path at the
        // write) and BEFORE the save, so a save that throws cannot leave them
        // naming a folder that is gone (#142 T3). Outside the in-flight span.
        if let assetRefs {
            await rewriteMovedNoteAssetRefs(
                itemId: id, oldStem: assetRefs.oldStem, newStem: assetRefs.newStem)
        }

        manifest.modified = Date()
        try await saveManifest()
    }

    /// Rename the backing file or folder when a research item's title changes.
    /// Returns (newRelativePath, childPathRewrites, assetRefs) or nil if no
    /// rename is needed; `assetRefs` is the stem pair a note that travelled
    /// with its `<slug>_assets/` folder has its refs rewritten by, before the
    /// manifest is saved (`rewriteMovedNoteAssetRefs`). Runs its moves through `ds.coordinatedMove` / `coordinatedWrite`
    /// (not raw `FileManager`) and is invoked only from inside the typed mover's
    /// `relocateUserContent(perform:)` closure, so the close+flush discipline
    /// has already run (tripwire 14). The `via` DocumentStore supplies the
    /// coordinated FS primitives.
    func renameResearchPath(
        item: ResearchItem,
        oldTitle: String,
        newTitle: String,
        via ds: DocumentStore?
    ) async throws -> (newPath: String, childPathRewrites: [(String, String)],
                       assetRefs: (oldStem: String, newStem: String)?)? {
        guard let oldRelPath = item.path else { return nil }
        // A path that leaves the project is refused as that (tripwire 58)
        // first; then a row naming a file outside every research root
        // renames nothing.
        let oldURL = try resolvedProjectPathToChange(oldRelPath)
        if namesAFileOutsideResearch(item) { throw ProjectStoreError.outsideResearch(title: item.title) }
        let oldSlug = Slugifier.slug(from:oldTitle)
        let newSlug = Slugifier.slug(from:newTitle)
        guard oldSlug != newSlug else { return nil }

        let parentDir = oldURL.deletingLastPathComponent()

        // Coordinated move when a DocumentStore is present (the production
        // path); a raw move is the safe fallback when it's nil (load-only
        // context — no registry/scheduler to race). (TripwireGrepTests exclusion)
        func move(_ from: URL, _ to: URL) async throws {
            if let ds {
                try await ds.coordinatedMove(from: from, to: to)
            } else {
                try FileManager.default.moveItem(at: from, to: to) // internal-move: no DocumentStore (no registry to race)
            }
        }

        if item.type == .group {
            // Rename folder; collect child path rewrites.
            let dedupedSlug = Self.dedupedName(newSlug) {
                FileManager.default.fileExists(
                    atPath: parentDir.appendingPathComponent($0).path)
            }
            let newURL = parentDir.appendingPathComponent(dedupedSlug)
            try await move(oldURL, newURL)
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
            return (newRelative, rewrites, nil)
        } else {
            // Asset: rename file, preserve extension.
            let ext = oldURL.pathExtension
            func leaf(_ stem: String) -> String {
                ext.isEmpty ? stem : "\(stem).\(ext)"
            }
            func isTaken(_ name: String) -> Bool {
                FileManager.default.fileExists(
                    atPath: parentDir.appendingPathComponent(name).path)
            }

            // A note travelling with a sibling `<slug>_assets` folder dedups the
            // PAIR jointly, through the same helper `moveResearchItems` uses: the
            // stem must be free for BOTH names. A leaf-only dedup happily takes a
            // free `.md` beside an ORPHANED `<slug>_assets` at the target, commits
            // the note's move, then throws on the assets move with the manifest
            // still naming the old path — so the joint question has to be asked
            // BEFORE the first move, not between the two (#31, W2's last sibling).
            let oldAssetsURL = parentDir.appendingPathComponent("\(oldSlug)_assets")
            let travelsWithAssets = FileManager.default.fileExists(
                atPath: oldAssetsURL.path)
            let dedupedSlug = travelsWithAssets
                ? (Self.researchDedupedNotePair(leaf(newSlug), isTaken: isTaken)
                    as NSString).deletingPathExtension
                : Self.dedupedName(newSlug) { isTaken(leaf($0)) }
            let newURL = parentDir.appendingPathComponent(leaf(dedupedSlug))
            try await move(oldURL, newURL)

            // Propagate to the sibling <slug>_assets/ folder when there is one.
            // The note's internal refs are rewritten by the caller once the
            // manifest names the new path (`rewriteMovedNoteAssetRefs`):
            // cosmetic, and it MUST NOT abort the rename — the moves here have
            // already committed (the 2026-07-19 sweep W1's class).
            var assetRefs: (oldStem: String, newStem: String)?
            if travelsWithAssets {
                let newAssetsURL = parentDir.appendingPathComponent("\(dedupedSlug)_assets")
                try await move(oldAssetsURL, newAssetsURL)
                assetRefs = (oldSlug, dedupedSlug)
            }

            return (relativeResearchPath(newURL), [], assetRefs)
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

/// **Which Research items the CURRENT task is moving** (#142 T2): bound by
/// `ProjectStore.withResearchItemsInFlight` around its body, and inherited by
/// the tasks the note door starts from inside it (the mover's own flush). The
/// door never turns that task's saves away on the span it is in: the
/// mover's flush is the writer's last copy, written before the file moves.
enum ResearchItemsMoving {
    @TaskLocal static var byThisTask: Set<String> = []
}
