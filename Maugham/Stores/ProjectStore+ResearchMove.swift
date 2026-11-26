import Foundation
import MaughamCore

/// Destination of a cross-scope research move (typed seam, ADR 0010 pattern).
/// Scope in a collection is path-derived (`pieces/<NN>-<slug>/research/` =
/// piece research); a scope move is therefore a file move + manifest path
/// rewrite. Spec: docs/superpowers/specs/2026-07-16-research-restructuring-design.md
public enum ResearchMoveTarget: Equatable, Sendable {
    /// Top level of the shared `research/` tree.
    case sharedRoot
    /// Into an existing research group, wherever it lives (shared or inside
    /// a piece folder).
    case group(String)
    /// Top level of a loose piece's `research/` folder.
    case piece(String)
}

/// **The link edits a research move makes in its own save** (closing round
/// A3): each row's links to `unlink`'s pieces removed, then every row linked
/// to `linkTo`.
public struct ResearchLinkEdit: Equatable, Sendable {
    public var unlink: [String: [String]]
    public var linkTo: (ids: [String], piece: String)?

    public static let none = ResearchLinkEdit(unlink: [:], linkTo: nil)

    public init(unlink: [String: [String]], linkTo: (ids: [String], piece: String)?) {
        self.unlink = unlink
        self.linkTo = linkTo
    }

    public static func == (lhs: ResearchLinkEdit, rhs: ResearchLinkEdit) -> Bool {
        lhs.unlink == rhs.unlink && lhs.linkTo?.ids == rhs.linkTo?.ids
            && lhs.linkTo?.piece == rhs.linkTo?.piece
    }

    func apply(to structure: inout [StructureItem]) {
        for (id, pieces) in unlink {
            for piece in pieces {
                structure = TreeWalk.mutate(id: piece, in: structure) { node in
                    var node = node
                    let links = (node.linkedResearchIds ?? []).filter { $0 != id }
                    node.linkedResearchIds = links.isEmpty ? nil : links
                    return node
                }
            }
        }
        if let linkTo {
            structure = TreeWalk.mutate(id: linkTo.piece, in: structure) { node in
                var node = node
                var links = node.linkedResearchIds ?? []
                for id in linkTo.ids where !links.contains(id) { links.append(id) }
                node.linkedResearchIds = links.isEmpty ? nil : links
                return node
            }
        }
    }
}

extension ProjectStore {

    /// Path of the ROOT ancestor of `id` within `research` (the item's own
    /// path if it is top-level; nil if `id` isn't present). The pure,
    /// testable core of section classification: nested items — especially
    /// pathless links inside a group — can't be classified by their own path,
    /// but the root always carries a reliable path. Combine with
    /// `researchScopePieceId(ofPath:)` to get the owning scope.
    nonisolated static func researchRootPath(
        ofItemId id: String, in research: [ResearchItem]
    ) -> String? {
        var rootId = id
        while let parent = TreeWalk.first(in: research, where: {
            ($0.children ?? []).contains { $0.id == rootId }
        }) {
            rootId = parent.id
        }
        return TreeWalk.find(id: rootId, in: research)?.path
    }

    /// Scope of a manifest-relative research path: the owning loose piece's
    /// id for paths under `pieces/<NN>-<slug>/research/`, nil for shared.
    func researchScopePieceId(ofPath path: String?) -> String? {
        Self.researchScopePieceId(ofPath: path, structure: manifest.structure)
    }

    /// The pure core of `researchScopePieceId(ofPath:)` — the structure passed
    /// in as a value rather than read off `self.manifest`, so a store-free
    /// layer can ask which scope a research path is in. Extracted (not
    /// restated) for `TreeDropIntent`, the binder tree's drop classifier
    /// (stage-2a Task 7): *which scope is this item in* is the question its
    /// whole routing turns on, and a second spelling of the piece-prefix rule
    /// is exactly the copy that drifts. Same shape as
    /// `researchRouting(for:projectType:)` and
    /// `pieceResearchSectionRoots(forDocumentId:structure:research:projectType:)`,
    /// both split for the same reason.
    nonisolated static func researchScopePieceId(
        ofPath path: String?, structure: [StructureItem]
    ) -> String? {
        researchScopePieceId(ofPath: path, in: researchFolders(in: structure))
    }

    /// Each loose piece's research folder prefix and its id, worked out once
    /// so a caller asking of many paths (`ResearchHomes`, `ReadThroughGate`)
    /// walks the structure once.
    nonisolated static func researchFolders(
        in structure: [StructureItem]
    ) -> [(prefix: String, pieceId: String)] {
        structure.compactMap { piece in
            guard piece.pieceKind == .loose else { return nil }
            return pieceResearchPrefix(for: piece).map { ($0, piece.id) }
        }
    }

    /// `researchScopePieceId(ofPath:structure:)` over folders already worked out.
    nonisolated static func researchScopePieceId(
        ofPath path: String?, in folders: [(prefix: String, pieceId: String)]
    ) -> String? {
        guard let path, path.hasPrefix("pieces/") else { return nil }
        return folders.first { path.hasPrefix($0.prefix) }?.pieceId
    }

    /// Drop ids that are descendants of another selected group — the group's
    /// move carries them (and RenamePlan rejects ancestor-overlapping steps).
    /// Preserves order, dedupes.
    func collapseResearchSelection(_ ids: [String]) -> [String] {
        var effective: [String] = []
        for id in ids {
            guard !effective.contains(id) else { continue }
            let isCarried = ids.contains { other in
                guard other != id,
                      let g = findResearchItem(id: other, in: manifest.research),
                      g.type == .group else { return false }
                return Self.researchContains(id: id, in: g.children ?? [])
            }
            if !isCarried { effective.append(id) }
        }
        return effective
    }

    struct ResearchMoveResolution {
        let folder: String        // manifest-relative destination folder
        let parentId: String?     // manifest-tree parent (nil = top level)
        let destPieceId: String?  // destination scope
    }

    func resolveResearchMoveTarget(
        _ target: ResearchMoveTarget
    ) throws -> ResearchMoveResolution {
        switch target {
        case .sharedRoot:
            return .init(folder: "research", parentId: nil, destPieceId: nil)
        case .group(let groupId):
            guard let group = findResearchItem(id: groupId, in: manifest.research),
                  group.type == .group, let groupPath = group.path else {
                throw ProjectStoreError.parentNotFound(groupId)
            }
            return .init(folder: groupPath, parentId: groupId,
                         destPieceId: researchScopePieceId(ofPath: groupPath))
        case .piece(let pieceId):
            let (_, _, researchFolder) = try resolveLoosePiece(pieceId)
            return .init(folder: researchFolder, parentId: nil,
                         destPieceId: pieceId)
        }
    }

    /// Move a batch of research items (assets, links, whole groups) to a
    /// destination scope/parent. Validates the whole batch up front — one
    /// invalid id moves nothing. One RenamePlan through the typed mover, one
    /// manifest save. `destIndex` is the insertion index within the
    /// destination sibling list (group children, or the top-level
    /// `manifest.research` array); nil appends. Returns what the move left:
    /// the notes whose picture links could not be rewritten
    /// (`RenameOutcome.assetRefsLeftIn`, #148 D2).
    @discardableResult
    public func moveResearchItems(
        ids: [String], to target: ResearchMoveTarget, atIndex destIndex: Int? = nil,
        relinking: ResearchLinkEdit = .none
    ) async throws -> RenameOutcome {
        beginStructuralVerb(); defer { endStructuralVerb() }
        let dest = try resolveResearchMoveTarget(target)
        // A destination folder outside every research root (a synced
        // manifest's group pointing at the manuscript) takes nothing.
        guard ResearchTextRole.isInsideAResearchRoot(dest.folder + "/item", structure: manifest.structure) else {
            throw ProjectStoreError.outsideResearch(title: dest.folder)
        }
        let effectiveIds = collapseResearchSelection(ids)

        // ---- Phase 1: validate everything, mutate nothing ----
        var items: [ResearchItem] = []
        for id in effectiveIds {
            guard let item = findResearchItem(id: id, in: manifest.research) else {
                throw ProjectStoreError.structureMissing
            }
            // A path that leaves the project is refused as that (tripwire
            // 58) first; then a row naming a file outside every research
            // root moves nothing.
            if item.kind != .link, let path = item.path, !path.isEmpty {
                _ = try resolvedProjectPathToChange(path)
            }
            if namesAFileOutsideResearch(item) { throw ProjectStoreError.outsideResearch(title: item.title) }
            if item.type == .group, case .group(let gid) = target {
                if gid == id || Self.researchContains(id: gid, in: item.children ?? []) {
                    throw ProjectStoreError.cycle
                }
            }
            // Role-bearing items (palette group, craft intent, forward-compat
            // unknown roles) are identity-bearing: they may reorder within
            // their scope but never change scope.
            if item.role != nil,
               researchScopePieceId(ofPath: item.path) != dest.destPieceId {
                throw ProjectStoreError.fileSystemError(
                    "“\(item.title)” has a fixed home, so it stays in the research it belongs to")
            }
            // C1: the palette group's lookup (`PaletteLookup.paletteGroup`)
            // scans only the TOP level of `research`. A same-scope group move
            // passes the cross-scope guard above (scope unchanged) yet would
            // NEST the palette group, hiding it from the wall/phone/MCP and
            // letting the next `ensurePaletteGroup` mint a duplicate. Refuse
            // any destination inside a group. Scoped to `.paletteGroup` (not
            // all roles): craft intent stays nestable — its lookup walks the
            // whole tree — and unknown roles keep only the scope guard above.
            if item.role == .paletteGroup, dest.parentId != nil {
                throw ProjectStoreError.fileSystemError(
                    "“\(item.title)” is the palette group and must stay at the top level of research")
            }
            items.append(item)
        }

        // ---- Phase 2: build ONE RenamePlan ----
        struct Pending {
            let oldPath: String?
            let newPath: String?
            let refRewrite: (oldStem: String, newStem: String)?
        }
        var steps: [RenamePlan.Step] = []
        var pendings: [Pending] = []
        var claimed = Set<String>()  // leaf names claimed by this batch
        let destURL = url.appendingPathComponent(dest.folder, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: destURL, withIntermediateDirectories: true)
        let existingNames = (try? FileManager.default
            .contentsOfDirectory(atPath: destURL.path)) ?? []
        let allManifestPaths = Set(
            TreeWalk.collect(in: manifest.research, where: { _ in true })
                .compactMap(\.path))

        for item in items {
            // Same-folder move is a reorder only — no FS step, path unchanged.
            // (Only possible for path-backed items already in the dest folder.)
            if let oldPath = item.path,
               (oldPath as NSString).deletingLastPathComponent == dest.folder {
                pendings.append(Pending(oldPath: oldPath, newPath: oldPath, refRewrite: nil))
                continue
            }

            // Links are manifest-only with a synthetic `.link` path. They may
            // arrive path-less (`addResearchLink` mints no path) or carry a
            // prior `.link` path from an earlier move; derive the leaf from the
            // existing path when present, else from the title slug. Dedupe
            // against manifest paths — never create a file.
            if item.kind == .link {
                let baseLeaf = item.path
                    .map { ($0 as NSString).lastPathComponent }
                    ?? "\(Slugifier.slug(from: item.title)).link"
                let stem = (baseLeaf as NSString).deletingPathExtension
                var candidate = "\(dest.folder)/\(baseLeaf)"
                var counter = 2
                while allManifestPaths.contains(candidate) || claimed.contains(candidate) {
                    candidate = "\(dest.folder)/\(stem)-\(counter).link"
                    counter += 1
                }
                claimed.insert(candidate)
                pendings.append(Pending(oldPath: item.path, newPath: candidate, refRewrite: nil))
                continue
            }

            guard let oldPath = item.path else {
                // Path-less non-link item — manifest-only, nothing to relocate.
                pendings.append(Pending(oldPath: nil, newPath: nil, refRewrite: nil))
                continue
            }
            let leaf = (oldPath as NSString).lastPathComponent
            let oldFolder = (oldPath as NSString).deletingLastPathComponent

            let oldStem = (leaf as NSString).deletingPathExtension
            let oldAssetsRel = oldFolder.isEmpty
                ? "\(oldStem)_assets" : "\(oldFolder)/\(oldStem)_assets"
            // The manifest's path is synced: refused here, in validation,
            // before any file call (tripwire 58). `relocate(plan:)` checks
            // every step again.
            let assetsURL = try resolvedProjectPath(oldAssetsRel)
            let travelsWithAssets = item.type == .asset && item.kind == .document
                && FileManager.default.fileExists(atPath: assetsURL.path)

            // W2: a note that travels with `<stem>_assets` dedups the PAIR
            // jointly — the plain per-leaf dedup misses an orphaned assets
            // dir at the destination and throws mid-relocate.
            let taken = Set(existingNames).union(claimed)
            let dedupedLeaf = travelsWithAssets
                ? Self.researchDedupedNotePair(leaf, isTaken: { taken.contains($0) })
                : Self.researchDedupedFilename(leaf, existing: Array(taken))
            claimed.insert(dedupedLeaf)
            let newPath = "\(dest.folder)/\(dedupedLeaf)"
            steps.append(.init(oldRelativePath: oldPath, newRelativePath: newPath))

            var refRewrite: (String, String)? = nil
            if travelsWithAssets {
                let newStem = (dedupedLeaf as NSString).deletingPathExtension
                let newAssetsLeaf = "\(newStem)_assets"
                claimed.insert(newAssetsLeaf)
                steps.append(.init(
                    oldRelativePath: oldAssetsRel,
                    newRelativePath: "\(dest.folder)/\(newAssetsLeaf)"))
                if oldStem != newStem {
                    refRewrite = (oldStem, newStem)
                }
            }
            pendings.append(Pending(
                oldPath: oldPath, newPath: newPath, refRewrite: refRewrite))
        }

        let plan = try RenamePlan(steps: steps)
        if !plan.steps.isEmpty, documentStore == nil {
            throw ProjectStoreError.fileSystemError("DocumentStore not available")
        }
        // From just before the typed mover until the in-memory manifest names
        // where the items now are, a note save by anyone but this verb that
        // finds the old file gone is turned away rather than writing it afresh
        // (#142 T2): a timer save stays pending and is re-armed when the span
        // ends, a flush keeps its text aside, a direct save is not made. The
        // asset refs and the save are outside the span.
        try await withResearchItemsInFlight(items.map(\.id)) {
            // ---- Phase 3: execute FS surgery through the typed mover ----
            if !plan.steps.isEmpty, let documentStore {
                try await documentStore.relocate(plan: plan)
            }

            // ---- Phase 4: rewrite the manifest, one save ----
            var updatedItems: [ResearchItem] = []
            for (item, pending) in zip(items, pendings) {
                var copy = item
                if let newPath = pending.newPath, newPath != pending.oldPath {
                    copy.path = newPath
                    // A group's descendant paths rebase under the new prefix (only
                    // meaningful when the group had a prior path).
                    if let oldPath = pending.oldPath, let children = copy.children {
                        copy.children = Self.researchRewriteChildPaths(
                            children, oldPrefix: oldPath, newPrefix: newPath)
                    }
                }
                updatedItems.append(copy)
            }
            for item in items { removeResearchItem(id: item.id) }
            var siblings = childrenOfResearch(parentId: dest.parentId)
            let insertAt = max(0, min(destIndex ?? siblings.count, siblings.count))
            siblings.insert(contentsOf: updatedItems, at: insertAt)
            replaceResearchChildren(parentId: dest.parentId, with: siblings)
        }

        // Scope moves deliberately leave `linkedResearchIds` UNTOUCHED (user
        // feedback 2026-07-17). Because we now auto-associate on move-in
        // (containment) and creation-in-a-piece, a manual link goes DORMANT
        // while contained — the data model tracks the distinction regardless
        // of whether a UI surfaces it (`linkableResearchItems` excludes
        // contained items from the link picker) — and it RESURFACES on
        // move-out. A containment-only association simply severs on move-out;
        // no auto-link is minted.

        // Dedup changed a note's stem → its assets folder was renamed to
        // match; rewrite the note's ./<stem>_assets/ image refs. The in-memory
        // manifest already names where the note is (the note door asks it), and
        // this runs BEFORE the save so a save that throws cannot leave the
        // refs naming a folder that is gone (#142 T3). Outside the in-flight
        // span, so the rewrite's own save is an ordinary one.
        // A rewrite that fails is named in the outcome (#148 D2): the move
        // stands, and the writer is told which notes' picture links it left.
        var assetRefsLeftIn: [String] = []
        for (item, pending) in zip(items, pendings) {
            guard let (oldStem, newStem) = pending.refRewrite else { continue }
            if let left = await rewriteMovedNoteAssetRefs(itemId: item.id, oldStem: oldStem, newStem: newStem) {
                assetRefsLeftIn.append(left)
            }
        }

        // **The move's link edits, in the same save** (shell p5a closing
        // round A3): a move to the book drops the rows' links, a drop on a
        // chapter links them — one write, never a moved row whose links lag.
        relinking.apply(to: &manifest.structure)

        manifest.modified = Date()
        return try await saveManifest(saying: RenameOutcome(assetRefsLeftIn: assetRefsLeftIn, act: .moved))
    }

    /// **The manifest save that ends a Research rename or move**, returning
    /// `outcome`. A save that throws after picture links were left
    /// (`assetRefsLeftIn`) throws `manifestUnwritable` naming both — the save
    /// failure's own detail, then the links (#148 D2, RULING-52) — the shape
    /// `settleDeletedInPart` gives its save failure; one with nothing left
    /// throws the save's own error unchanged.
    func saveManifest(saying outcome: RenameOutcome) async throws -> RenameOutcome {
        do {
            try await saveManifest()
        } catch {
            guard let refs = outcome.assetRefsAfterAFailedSave else { throw error }
            let saveFailure: String
            if case .manifestUnwritable(let detail)? = error as? ProjectStoreError {
                saveFailure = detail
            } else {
                saveFailure = error.localizedDescription
            }
            throw ProjectStoreError.manifestUnwritable(Self.saveFailure(saveFailure, thenSaying: refs))
        }
        return outcome
    }

    /// **A moved or renamed note's `./<old>_assets/` refs, rewritten** once
    /// the in-memory manifest names where it now is (before the save). A note
    /// or a palette card goes through the note door (what it held is kept as
    /// a version; an editor open on it reloads); with no `DocumentStore` the
    /// raw write. Anything else (`ResearchTextRole` nil) is not written. It
    /// lands even when the earlier version cannot be kept (`mustLand`); a
    /// write that fails is logged and the move stands.
    ///
    /// **Returns the note's title when its refs were left stale** (the file
    /// would not resolve, read or write), so the verb's outcome names it
    /// (`RenameOutcome.assetRefsLeftIn`, #148 D2, RULING-52); nil when they
    /// were rewritten, needed nothing, or the item is not a note.
    @discardableResult
    func rewriteMovedNoteAssetRefs(itemId: String, oldStem: String, newStem: String) async -> String? {
        guard let item = findResearchItem(id: itemId, in: manifest.research),
              let path = item.path else { return nil }
        // Only a note or a palette card inside a research root is rewritten:
        // a synced manifest's `.document` naming any other file is left alone.
        guard ResearchTextRole.of(item, structure: manifest.structure, research: manifest.research) != nil else {
            projectStoreLog.error(
                "Asset refs: \(path, privacy: .public) is not inside a research root, not rewritten")
            return nil
        }
        guard let noteURL = try? resolvedProjectPathToChange(path) else {
            projectStoreLog.error("Asset refs: \(path, privacy: .public) is refused by the project, not rewritten")
            return item.title
        }
        await documentStore?.settleResearchNoteEdits(itemId: itemId)
        let leftStale = await Self.rewriteAssetRefsBestEffort(
            oldStem: oldStem, newStem: newStem, noteURL: noteURL,
            write: { [self] text, url in
                if let ds = documentStore {
                    // It must land: the move has happened, so refs left
                    // stale point at a folder that is gone (the door says
                    // when the earlier version could not be kept).
                    guard case .saved = await ds.saveResearchNote(
                        itemId: itemId, text: text, mustLand: true, from: self) else {
                        throw ProjectStoreError.fileSystemError("“\(item.title)” was not saved")
                    }
                } else {
                    // Lost its store (teardown): refused, never raw (#141 N6);
                    // the best-effort rewrite logs the throw.
                    guard rawNoteWriteWithNoDoor() == .allowed else {
                        throw ProjectStoreError.noteWriteRefusedAsTheProjectCloses
                    }
                    try text.write(to: url, atomically: true, encoding: .utf8)  // raw-research-text: no-door fallback
                }
            })
        return leftStale ? item.title : nil
    }

    /// Dedup a note leaf JOINTLY with its sibling `<stem>_assets` folder: the
    /// chosen stem must be free for BOTH names. An orphaned `<stem>_assets`
    /// at the destination with no matching note otherwise collides
    /// mid-relocate (2026-07-19 sweep W2).
    ///
    /// `isTaken` rather than a name set (`dedupedName`'s shape) because a name
    /// set would force the rename caller to pre-list the whole destination
    /// directory just to build one: both callers ask the filesystem for what's
    /// taken, and the batch mover additionally unions its own in-flight claims.
    /// One implementation, because a second copy is the drift W2 existed to
    /// kill.
    static func researchDedupedNotePair(
        _ name: String, isTaken: (String) -> Bool
    ) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func leaf(_ s: String) -> String { ext.isEmpty ? s : "\(s).\(ext)" }
        if !isTaken(leaf(stem)), !isTaken("\(stem)_assets") {
            return leaf(stem)
        }
        for n in 2...999 {
            let candidate = "\(stem)-\(n)"
            if !isTaken(leaf(candidate)), !isTaken("\(candidate)_assets") {
                return leaf(candidate)
            }
        }
        return UUID().uuidString
    }

    /// Post-move fix — MUST NOT abort the move. `relocate` has already
    /// committed the FS state when this runs, so a failure here is logged and
    /// never thrown, to keep the manifest rewrite (Phase 4) alive (2026-07-19
    /// sweep W1). The non-throwing signature is deliberate; the failure is
    /// RETURNED (true: the refs were left stale) so the verb can say it
    /// (#148 D2).
    @discardableResult
    static func rewriteAssetRefsBestEffort(
        oldStem: String, newStem: String, noteURL: URL,
        write: (String, URL) async throws -> Void
    ) async -> Bool {
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else {  // adr-0018-ok: research-note read, not manuscript
            NSLog("moveResearchItems: asset-ref rewrite could not read %@ — refs stale, move intact",
                  noteURL.lastPathComponent)
            return true
        }
        let rewritten = content.replacingOccurrences(
            of: "./\(oldStem)_assets/", with: "./\(newStem)_assets/")
        guard rewritten != content else { return false }
        do {
            try await write(rewritten, noteURL)
            return false
        } catch {
            NSLog("moveResearchItems: asset-ref rewrite failed for %@ — refs stale, move intact: %@",
                  noteURL.lastPathComponent, "\(error)")
            return true
        }
    }
}
