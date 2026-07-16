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

            let dedupedLeaf = Self.researchDedupedFilename(
                leaf, existing: existingNames + Array(claimed))
            claimed.insert(dedupedLeaf)
            let newPath = "\(dest.folder)/\(dedupedLeaf)"
            steps.append(.init(oldRelativePath: oldPath, newRelativePath: newPath))

            // A markdown note travels with its sibling `<stem>_assets/` folder.
            var refRewrite: (String, String, String)? = nil
            if item.type == .asset, item.kind == .document {
                let oldStem = (leaf as NSString).deletingPathExtension
                let newStem = (dedupedLeaf as NSString).deletingPathExtension
                let oldAssetsRel = oldFolder.isEmpty
                    ? "\(oldStem)_assets" : "\(oldFolder)/\(oldStem)_assets"
                if FileManager.default.fileExists(
                    atPath: url.appendingPathComponent(oldAssetsRel).path) {
                    let newAssetsLeaf = "\(newStem)_assets"
                    claimed.insert(newAssetsLeaf)
                    steps.append(.init(
                        oldRelativePath: oldAssetsRel,
                        newRelativePath: "\(dest.folder)/\(newAssetsLeaf)"))
                    if oldStem != newStem {
                        refRewrite = (oldStem, newStem, newPath)
                    }
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
                let noteURL = url.appendingPathComponent(noteRelPath)
                if let content = try? String(contentsOf: noteURL, encoding: .utf8) {  // adr-0018-ok: research-note read, not manuscript
                    let rewritten = content.replacingOccurrences(
                        of: "./\(oldStem)_assets/", with: "./\(newStem)_assets/")
                    if rewritten != content {
                        try await documentStore.coordinatedWrite(
                            text: rewritten, to: noteURL)
                    }
                }
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

        manifest.modified = Date()
        try await saveManifest()
    }
}
