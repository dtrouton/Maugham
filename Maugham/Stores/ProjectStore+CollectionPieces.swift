import Foundation
import MaughamCore

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
        let targetManifestURL = targetURL.appendingPathComponent(ProjectManifest.fileName)
        guard FileManager.default.fileExists(atPath: targetManifestURL.path) else {
            throw ProjectStoreError.fileSystemError(
                "Selected folder is not a Maugham project: \(targetURL.path)")
        }
        let data = try Data(contentsOf: targetManifestURL)  // adr-0018-ok: piece project manifest JSON read, not manuscript
        // Respect the schemaVersion gate (ADR 0015): don't add a reference to a
        // project written by a newer Maugham this build can't fully read.
        let targetManifest: ProjectManifest
        do {
            targetManifest = try ProjectManifest.decodeGuardingSchema(data)
        } catch let e as ProjectManifest.SchemaTooNewError {
            throw ProjectStoreError.manifestSchemaTooNew(
                found: e.found, supported: e.supported)
        }
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
        let slug = Self.dedupedName(baseSlug) { existingSlugs.contains($0) }

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
        if let docStore = documentStore {
            if let doc = docStore.document(for: piecePath) {
                await doc.close()
                docStore.unregister(path: piecePath)
            }
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

        let researchPrefix = "\(pieceFolderRel)/research/"
        let now = Date()
        let encoder = ProjectManifest.makeEncoder()

        do {
            // 2b. Create the new project's empty subfolders.
            try stagePromotedSubfolders(staging: stagingURL)

            // 3. Move main doc into staging/manuscript/
            try stagePromotedMainDocument(
                staging: stagingURL,
                from: pieceFolderURL,
                docName: mainDocName)

            // 4. Move piece's research/ subfolder into staging/research/ (if non-empty)
            try stagePromotedResearch(staging: stagingURL, from: pieceFolderURL)

            // 5. Build + write new project manifest
            try writePromotedManifest(
                staging: stagingURL,
                piece: piece,
                newType: newType,
                docName: mainDocName,
                researchPrefix: researchPrefix,
                now: now,
                encoder: encoder)

            // 6. Validate by loading
            try await validatePromotedProject(staging: stagingURL)

            // 7. Atomic replace to final destination
            try atomicReplacePromotedProject(staging: stagingURL, destination: destination)

            // 8. Convert Collection piece to a reference + prune carried research.
            try await convertPromotedPieceToReference(
                pieceIdx: pieceIdx,
                piece: piece,
                pieceFolderURL: pieceFolderURL,
                pieceFolderRel: pieceFolderRel,
                researchPrefix: researchPrefix,
                destination: destination,
                now: now,
                encoder: encoder)

            return destination
        } catch {
            // Rollback: delete staging if present
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Step 2b: create the new project's empty `manuscript/` and `notes/` subfolders
    /// inside the staging folder.
    private func stagePromotedSubfolders(staging: URL) throws {
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("notes"),
            withIntermediateDirectories: true)
    }

    /// Step 3: move the piece's main document into `staging/manuscript/`.
    private func stagePromotedMainDocument(
        staging: URL, from pieceFolderURL: URL, docName: String
    ) throws {
        let newDocURL = staging.appendingPathComponent("manuscript/\(docName)")
        // internal-move: into the promote-to-project `staging/` temp tree.
        // promotePieceToProject already closes+flushes the live doc (line ~205)
        // before staging begins, so this move doesn't race a live autosave —
        // it's not the tripwire-14 user-path class. (TripwireGrepTests exclusion)
        try FileManager.default.moveItem( // internal-move: staging
            at: pieceFolderURL.appendingPathComponent(docName),
            to: newDocURL)
    }

    /// Step 4: move the piece's `research/` subfolder into `staging/research/`,
    /// or create an empty `staging/research/` when the piece has none.
    private func stagePromotedResearch(staging: URL, from pieceFolderURL: URL) throws {
        let pieceResearchURL = pieceFolderURL.appendingPathComponent("research")
        let newResearchURL = staging.appendingPathComponent("research")
        if FileManager.default.fileExists(atPath: pieceResearchURL.path) {
            // internal-move: into the promote-to-project `staging/` temp tree
            // (close+flush already ran upstream). (TripwireGrepTests exclusion)
            try FileManager.default.moveItem(at: pieceResearchURL, to: newResearchURL) // internal-move: staging
        } else {
            try FileManager.default.createDirectory(
                at: newResearchURL, withIntermediateDirectories: true)
        }
    }

    /// Step 5: build the new project's manifest (carrying over the piece's metadata
    /// and rewriting per-piece research paths) and write it into the staging folder.
    private func writePromotedManifest(
        staging: URL,
        piece: StructureItem,
        newType: ProjectType,
        docName: String,
        researchPrefix: String,
        now: Date,
        encoder: JSONEncoder
    ) throws {
        let docStructItem = StructureItem(
            id: Self.newId(prefix: "doc"),
            title: piece.title,
            type: .document,
            path: "manuscript/\(docName)",
            synopsis: piece.synopsis,
            status: piece.status,
            wordTarget: piece.wordTarget,
            pageTarget: piece.pageTarget,
            tags: piece.tags,
            links: piece.links)
        // Carry over per-piece research as the new project's research items;
        // rewrite their paths from pieces/<NN>-<slug>/research/X to research/X.
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
        try encoder.encode(newManifest).write(
            to: staging.appendingPathComponent(ProjectManifest.fileName),
            options: .atomic)
    }

    /// Step 6: validate the staged project by loading it.
    private func validatePromotedProject(staging: URL) async throws {
        _ = try await ProjectStore.load(from: staging)
    }

    /// Step 7: atomically move/replace the staged project into its final destination.
    private func atomicReplacePromotedProject(staging: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination, withItemAt: staging)
        } else {
            // internal-move: final staging→destination swap of the promoted
            // project tree (not a live user-edited path). (TripwireGrepTests exclusion)
            try FileManager.default.moveItem(at: staging, to: destination) // internal-move: staging
        }
    }

    /// Step 8: convert the Collection's loose piece into a reference —
    ///   a. write `.maugham-link.json`
    ///   b. update the piece's manifest entry
    ///   c. remove the per-piece research items from `manifest.research`
    /// then persist the Collection manifest.
    private func convertPromotedPieceToReference(
        pieceIdx: Int,
        piece: StructureItem,
        pieceFolderURL: URL,
        pieceFolderRel: String,
        researchPrefix: String,
        destination: URL,
        now: Date,
        encoder: JSONEncoder
    ) async throws {
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
    }

    /// Validate this is a Collection project, look up the loose piece by id,
    /// and derive its folder paths. Throws if the project is not a Collection
    /// or if `pieceId` does not identify a loose piece.
    /// `internal` (not `private`) so `ProjectStore+ResearchMove` can resolve a
    /// `.piece` move target's research folder through the same validated path.
    func resolveLoosePiece(_ pieceId: String) throws
        -> (piece: StructureItem, pieceFolder: String, researchFolder: String) {
        guard manifest.type == .collection else {
            throw ProjectStoreError.fileSystemError(
                "Operation only valid for Collection projects")
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
        return (piece: piece, pieceFolder: pieceFolder, researchFolder: researchFolder)
    }

    /// Add a research note inside a piece's research/ subfolder. Adds a
    /// ResearchItem to manifest.research with a piece-scoped path. The note
    /// is project-local research from the manifest's POV — discoverability
    /// in the binder is done by path-prefix matching (UI layer).
    public func addPieceResearchNote(
        pieceId: String, title: String
    ) async throws -> ResearchItem {
        let (_, _, researchFolder) = try resolveLoosePiece(pieceId)
        let researchFolderURL = url.appendingPathComponent(researchFolder)
        try FileManager.default.createDirectory(
            at: researchFolderURL, withIntermediateDirectories: true)

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = baseTitle.isEmpty ? "Untitled Note" : baseTitle
        let slug = Slugifier.slug(from:resolvedTitle)
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
        let (_, _, researchFolder) = try resolveLoosePiece(pieceId)
        let researchFolderURL = url.appendingPathComponent(researchFolder)
        try FileManager.default.createDirectory(
            at: researchFolderURL, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent
        let kind = ResearchKindInference.kind(forFilename: filename) ?? .document
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let slug = Slugifier.slug(from:stem)
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
        let (_, _, researchFolder) = try resolveLoosePiece(pieceId)
        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = baseTitle.isEmpty ? "Untitled Link" : baseTitle
        let slug = Slugifier.slug(from:resolvedTitle)
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

        // 3. Move the piece folders on disk through the typed user-content
        //    mover. `relocateUserContent` runs the close-before-FS-surgery
        //    discipline (close+unregister every open piece Document so its
        //    750ms autosave can't race the move; flush the research-note
        //    debounce so a queued `scheduleFileSave` can't land at the OLD
        //    path) INTERNALLY before the `perform` closure runs the move
        //    (tripwire 14, enforce-by-construction). The closure preserves the
        //    two-phase temp-suffix swap that avoids collisions when pieces swap
        //    positions (e.g. swap 01 and 02 would have a direct move fail
        //    because the destination exists).
        // The open Document paths inside the folders about to move.
        let affectedPiecePaths: [String] = folderRewrites.compactMap { rewrite in
            reordered.first {
                guard let p = $0.path else { return false }
                return (p as NSString).deletingLastPathComponent == rewrite.oldRel
            }?.path
        }
        let tmpSuffix = "-mv-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        // Coordinated move when a DocumentStore is present (production); raw
        // move is the safe fallback when nil (load-only context — no
        // registry/scheduler to race). (TripwireGrepTests exclusion)
        func move(_ from: URL, _ to: URL) async throws {
            if let ds = documentStore {
                try await ds.coordinatedMove(from: from, to: to)
            } else {
                try fm.moveItem(at: from, to: to) // internal-move: no DocumentStore (no registry to race)
            }
        }
        let projectURL = url
        let swapFolders: () async throws -> Void = {
            // Phase A: oldRel -> oldRel + tmpSuffix
            for rewrite in folderRewrites {
                let oldURL = projectURL.appendingPathComponent(rewrite.oldRel)
                let tmpURL = projectURL.appendingPathComponent("\(rewrite.oldRel)\(tmpSuffix)")
                try await move(oldURL, tmpURL)
            }
            // Phase B: oldRel + tmpSuffix -> newRel
            for rewrite in folderRewrites {
                let tmpURL = projectURL.appendingPathComponent("\(rewrite.oldRel)\(tmpSuffix)")
                let newURL = projectURL.appendingPathComponent(rewrite.newRel)
                try await move(tmpURL, newURL)
            }
        }
        if let ds = documentStore {
            try await ds.relocateUserContent(
                affectedPaths: affectedPiecePaths, perform: swapFolders)
        } else {
            try await swapFolders()
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
        let slug = Self.dedupedName(baseSlug) { siblingSlugs.contains($0) }

        let newFolderName = "\(nnPrefix)\(slug)"
        let newFolderRel = piecesDirRel.isEmpty ? newFolderName : "\(piecesDirRel)/\(newFolderName)"
        let oldFolderURL = url.appendingPathComponent(oldFolderRel)
        let newFolderURL = url.appendingPathComponent(newFolderRel)

        // Move the piece folder (and rename the loose doc inside) through the
        // typed user-content mover. `relocateUserContent` closes+unregisters
        // the open Document at oldPath and flushes the research-note debounce
        // INTERNALLY before the `perform` closure — so the open doc's 750ms
        // autosave can't re-create a phantom at its old path, and a queued
        // research-note `scheduleFileSave` can't land at the OLD folder
        // (tripwire 14, enforce-by-construction). Same race class as
        // renameStructureItem. The closure preserves the folder-then-inner-doc
        // two-step.
        let newDocBaseName: String
        if piece.pieceKind == .loose {
            let oldDocName = (oldPath as NSString).lastPathComponent
            let oldExt = (oldDocName as NSString).pathExtension
            newDocBaseName = "\(slug).\(oldExt)"
        } else {
            // References keep .maugham-link.json
            newDocBaseName = (oldPath as NSString).lastPathComponent
        }
        let finalDocBaseName = newDocBaseName
        // Coordinated move when a DocumentStore is present (production); raw
        // move is the safe fallback when nil (load-only context — no
        // registry/scheduler to race). (TripwireGrepTests exclusion)
        func move(_ from: URL, _ to: URL) async throws {
            if let ds = documentStore {
                try await ds.coordinatedMove(from: from, to: to)
            } else {
                try FileManager.default.moveItem(at: from, to: to) // internal-move: no DocumentStore (no registry to race)
            }
        }
        let renameFolderAndDoc: () async throws -> Void = {
            // 1. Move the parent folder.
            if oldFolderURL.path != newFolderURL.path {
                try await move(oldFolderURL, newFolderURL)
            }
            // 2. For loose pieces, rename the main doc inside the new folder.
            if piece.pieceKind == .loose {
                let oldDocName = (oldPath as NSString).lastPathComponent
                if oldDocName != finalDocBaseName {
                    try await move(
                        newFolderURL.appendingPathComponent(oldDocName),
                        newFolderURL.appendingPathComponent(finalDocBaseName))
                }
            }
        }
        if let ds = documentStore {
            try await ds.relocateUserContent(
                affectedPaths: [oldPath], perform: renameFolderAndDoc)
        } else {
            try await renameFolderAndDoc()
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
