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

extension ProjectStore {

    /// Path of the ROOT ancestor of `id` within `research` (the item's own
    /// path if it is top-level; nil if `id` isn't present). The pure,
    /// testable core of section classification: nested items — especially
    /// pathless links inside a group — can't be classified by their own path,
    /// but the root always carries a reliable path. Combine with
    /// `researchScopePieceId(ofPath:)` to get the owning scope.
    static func researchRootPath(
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
        guard let path, path.hasPrefix("pieces/") else { return nil }
        for piece in manifest.structure where piece.pieceKind == .loose {
            if let prefix = Self.pieceResearchPrefix(for: piece),
               path.hasPrefix(prefix) {
                return piece.id
            }
        }
        return nil
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
    /// `manifest.research` array); nil appends.
    public func moveResearchItems(
        ids: [String], to target: ResearchMoveTarget, atIndex destIndex: Int? = nil
    ) async throws {
        let dest = try resolveResearchMoveTarget(target)
        let effectiveIds = collapseResearchSelection(ids)

        // ---- Phase 1: validate everything, mutate nothing ----
        var items: [ResearchItem] = []
        for id in effectiveIds {
            guard let item = findResearchItem(id: id, in: manifest.research) else {
                throw ProjectStoreError.structureMissing
            }
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
                    "“\(item.title)” has a fixed home and can't move between shared and piece research")
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
            let refRewrite: (oldStem: String, newStem: String, noteRelPath: String)?
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
            let travelsWithAssets = item.type == .asset && item.kind == .document
                && FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(oldAssetsRel).path)

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

            var refRewrite: (String, String, String)? = nil
            if travelsWithAssets {
                let newStem = (dedupedLeaf as NSString).deletingPathExtension
                let newAssetsLeaf = "\(newStem)_assets"
                claimed.insert(newAssetsLeaf)
                steps.append(.init(
                    oldRelativePath: oldAssetsRel,
                    newRelativePath: "\(dest.folder)/\(newAssetsLeaf)"))
                if oldStem != newStem {
                    refRewrite = (oldStem, newStem, newPath)
                }
            }
            pendings.append(Pending(
                oldPath: oldPath, newPath: newPath, refRewrite: refRewrite))
        }

        // ---- Phase 3: execute FS surgery through the typed mover ----
        let plan = try RenamePlan(steps: steps)
        if !plan.steps.isEmpty {
            guard let documentStore else {
                throw ProjectStoreError.fileSystemError("DocumentStore not available")
            }
            try await documentStore.relocate(plan: plan)
            // Dedup changed a note's stem → its assets folder was renamed to
            // match; rewrite the note's ./<stem>_assets/ image refs.
            for pending in pendings {
                guard let (oldStem, newStem, noteRelPath) = pending.refRewrite else { continue }
                await Self.rewriteAssetRefsBestEffort(
                    oldStem: oldStem, newStem: newStem,
                    noteURL: url.appendingPathComponent(noteRelPath),
                    write: { try await documentStore.coordinatedWrite(text: $0, to: $1) })
            }
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

        // Scope moves deliberately leave `linkedResearchIds` UNTOUCHED (user
        // feedback 2026-07-17). Because we now auto-associate on move-in
        // (containment) and creation-in-a-piece, a manual link goes DORMANT
        // while contained — the UI hides it (LinkedResearchPane filters derived
        // ids out of the Linked section; `linkableResearchItems` excludes
        // contained items) and it RESURFACES on move-out. A containment-only
        // association simply severs on move-out; no auto-link is minted.

        manifest.modified = Date()
        try await saveManifest()
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

    /// Cosmetic post-move fix — MUST NOT abort the move. `relocate` has
    /// already committed the FS state when this runs, so a failure here is
    /// logged and swallowed to keep the manifest rewrite (Phase 4) alive
    /// (2026-07-19 sweep W1). The non-throwing signature is deliberate.
    static func rewriteAssetRefsBestEffort(
        oldStem: String, newStem: String, noteURL: URL,
        write: (String, URL) async throws -> Void
    ) async {
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else { return }  // adr-0018-ok: research-note read, not manuscript
        let rewritten = content.replacingOccurrences(
            of: "./\(oldStem)_assets/", with: "./\(newStem)_assets/")
        guard rewritten != content else { return }
        do {
            try await write(rewritten, noteURL)
        } catch {
            NSLog("moveResearchItems: asset-ref rewrite failed for %@ — refs stale, move intact: %@",
                  noteURL.lastPathComponent, "\(error)")
        }
    }
}
