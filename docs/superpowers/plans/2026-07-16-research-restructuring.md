# Research Restructuring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move research items (single or multiselected, incl. groups) between collection level and piece level; fix the decorative-groups bug in `CollectionResearchPane`; add an MCP `move_research_item` tool.

**Architecture:** A new typed `ResearchMoveTarget` seam + batch `moveResearchItems` on `ProjectStore` (new peer file `ProjectStore+ResearchMove.swift`), building ONE `RenamePlan` through the typed `DocumentStore.relocate` mover. The existing single-item cross-group move retrofits onto it (fixing a latent `_assets`-orphan bug). UI extracts `ResearchView`'s tree rendering into a shared component that `CollectionResearchPane` adopts, then adds cross-section drops, `Set<String>` multiselect, and a "Move to ▸" context submenu.

**Tech Stack:** Swift / SwiftUI (Mac target only — no MaughamCore or phone changes), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-16-research-restructuring-design.md`

## Global Constraints

- Op log untouched — research files are plain-edited, no `¶id` anchors (existing precedent).
- All user-content moves route through `DocumentStore.relocate(plan:)` / `trash(...)` (tripwire 14). The new peer file must be added to `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`'s grep census.
- Fail loudly on invalid targets — never silently fall back to shared (scoped-research precedent).
- Role-bearing items (`item.role != nil`: paletteGroup, craftIntent, unknown) refuse cross-scope moves.
- Test after each task: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` (append `-only-testing:MaughamTests/<Class>` while iterating). No MaughamCore changes → phone scheme run only at final whole-branch verification.
- No manifest schema changes, no migration.
- Subagent models per CLAUDE.md: opus for Tasks 1–3, 5–9; haiku fine for Tasks 4, 10, 11.

---

### Task 1: Store — `ResearchMoveTarget` + batch `moveResearchItems`

**Files:**
- Create: `Maugham/Stores/ProjectStore+ResearchMove.swift`
- Modify: `MaughamTests/TripwireGrepTests.swift` (add new file to the raw-move grep census)
- Test: `MaughamTests/ResearchMoveTests.swift` (create)

**Interfaces:**
- Consumes: `RenamePlan` (`Maugham/Stores/RenamePlan.swift:18`), `documentStore.relocate(plan:)` (`DocumentStore.swift:506`), `resolveLoosePiece(_:)` (`ProjectStore+CollectionPieces.swift:425`), `findResearchItem` / `removeResearchItem` / `childrenOfResearch` / `replaceResearchChildren` / `Self.researchDedupedFilename` / `Self.researchRewriteChildPaths` / `Self.researchContains` (all `ProjectStore+Research.swift`), `Self.pieceResearchPrefix(for:)` (`ResearchScope.swift:120`), `ds.coordinatedWrite(text:to:)` (`DocumentStore.swift:630`).
- Produces (later tasks rely on these exact signatures):
  - `public enum ResearchMoveTarget: Equatable, Sendable { case sharedRoot; case group(String); case piece(String) }`
  - `public func moveResearchItems(ids: [String], to target: ResearchMoveTarget, atIndex destIndex: Int? = nil) async throws`
  - `func researchScopePieceId(ofPath path: String?) -> String?`
  - `func collapseResearchSelection(_ ids: [String]) -> [String]`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/ResearchMoveTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ResearchMoveTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// Collection with one loose piece and a wired DocumentStore
    /// (ResearchScopeTests + RenameResearchItemTests patterns combined).
    private func makeCollection() async throws
        -> (URL, ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "MoveTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, ds, piece)
    }

    private func item(_ store: ProjectStore, _ id: String) -> ResearchItem? {
        TreeWalk.find(id: id, in: store.manifest.research)
    }

    // MARK: shared → piece

    func test_sharedNote_toPiece_movesFileAndRewritesPath() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, note.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(moved.path!.hasPrefix(prefix), "got \(moved.path!)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/sarah.md").path))
        // Now derived as the piece's research
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id)
            .contains(where: { $0.id == note.id }))
        await ds.close()
    }

    // MARK: piece → shared

    func test_pieceNote_toSharedRoot_movesFileOut() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Clock Tower")

        try await store.moveResearchItems(ids: [note.id], to: .sharedRoot)

        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(moved.path, "research/clock-tower.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/clock-tower.md").path))
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id).isEmpty)
        await ds.close()
    }

    // MARK: into a group

    func test_move_intoGroup_landsAsChild() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Maps")

        try await store.moveResearchItems(ids: [note.id], to: .group(group.id))

        let g = try XCTUnwrap(item(store, group.id))
        XCTAssertTrue((g.children ?? []).contains(where: { $0.id == note.id }))
        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(moved.path, "\(g.path!)/maps.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        await ds.close()
    }

    // MARK: group with descendants across scope

    func test_group_toPiece_movesFolderAndRewritesDescendants() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Setting", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Harbor")

        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        let movedGroup = try XCTUnwrap(item(store, group.id))
        let movedChild = try XCTUnwrap(item(store, child.id))
        XCTAssertTrue(movedGroup.path!.hasPrefix(prefix))
        XCTAssertTrue(movedChild.path!.hasPrefix(movedGroup.path! + "/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(movedChild.path!).path))
        await ds.close()
    }

    // MARK: link items are manifest-only

    func test_linkItem_moves_manifestOnly() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Ref", url: "https://example.com")

        try await store.moveResearchItems(ids: [link.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, link.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(moved.path!.hasPrefix(prefix))
        XCTAssertEqual(moved.url, "https://example.com")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path),
            "synthetic .link path must not create a file")
        await ds.close()
    }

    // MARK: batch + collapsing + validation

    func test_batch_oneBadId_movesNothing() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Keep")

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(
                ids: [note.id, "res-nope"], to: .piece(piece.id)))

        let kept = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(kept.path, "research/keep.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/keep.md").path))
        await ds.close()
    }

    func test_selectedDescendant_collapsesIntoSelectedGroup() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Cluster", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Inside")

        // Selecting both must not double-move (RenamePlan would reject the
        // ancestor overlap); the group's move carries the child.
        try await store.moveResearchItems(
            ids: [group.id, child.id], to: .piece(piece.id))

        let movedChild = try XCTUnwrap(item(store, child.id))
        XCTAssertTrue(movedChild.path!.hasPrefix("pieces/"))
        await ds.close()
    }

    func test_groupIntoOwnDescendant_throwsCycle() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let outer = try await store.addResearchItem(parentId: nil, title: "Outer", kind: nil)
        let inner = try await store.addResearchItem(parentId: outer.id, title: "Inner", kind: nil)

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [outer.id], to: .group(inner.id))) { error in
            XCTAssertEqual(error as? ProjectStoreError, .cycle)
        }
        await ds.close()
    }

    func test_targetNonGroup_throwsParentNotFound() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [a.id], to: .group(b.id)))
        await ds.close()
    }

    // MARK: role guard

    func test_roleItem_crossScope_refuses() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        // Create the palette group via the convention, then stamp its role
        // the way healRole does.
        let group = try await store.addResearchItem(
            parentId: nil, title: PaletteConvention.groupTitle, kind: nil)
        store.mutateResearchItem(id: group.id) { $0.role = .paletteGroup }

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id)))
        let kept = try XCTUnwrap(item(store, group.id))
        XCTAssertFalse(kept.path!.hasPrefix("pieces/"))
        await ds.close()
    }

    // MARK: arrival name collision

    func test_nameCollisionOnArrival_dedupes() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        _ = try await store.createResearchNote(
            scope: .document(piece.id), title: "Sarah")
        let sharedNote = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        try await store.moveResearchItems(ids: [sharedNote.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, sharedNote.id))
        XCTAssertTrue(moved.path!.hasSuffix("sarah-2.md"), "got \(moved.path!)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        await ds.close()
    }
}
```

If the project has no `XCTAssertThrowsErrorAsync` helper (check `MaughamTests/` — `grep -rn "XCTAssertThrowsErrorAsync" MaughamTests | head -1`), add this to the test file:

```swift
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
```

Note: `mutateResearchItem` is `internal` — the test target uses `@testable import Maugham`, so calling it is fine.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ResearchMoveTests`
Expected: compile FAILURE — `moveResearchItems` and `ResearchMoveTarget` don't exist.

- [ ] **Step 3: Implement**

Create `Maugham/Stores/ProjectStore+ResearchMove.swift`:

```swift
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
            guard let oldPath = item.path else {
                pendings.append(Pending(oldPath: nil, newPath: nil, refRewrite: nil))
                continue
            }
            let leaf = (oldPath as NSString).lastPathComponent
            let oldFolder = (oldPath as NSString).deletingLastPathComponent

            if oldFolder == dest.folder {
                // Same folder — reorder only, no FS step, path unchanged.
                pendings.append(Pending(oldPath: oldPath, newPath: oldPath, refRewrite: nil))
                continue
            }

            if item.kind == .link {
                // Synthetic .link path — manifest-only, dedupe against paths.
                var candidate = "\(dest.folder)/\(leaf)"
                var counter = 2
                let stem = (leaf as NSString).deletingPathExtension
                while allManifestPaths.contains(candidate) || claimed.contains(candidate) {
                    candidate = "\(dest.folder)/\(stem)-\(counter).link"
                    counter += 1
                }
                claimed.insert(candidate)
                pendings.append(Pending(oldPath: oldPath, newPath: candidate, refRewrite: nil))
                continue
            }

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
            if let newPath = pending.newPath, let oldPath = pending.oldPath,
               newPath != oldPath {
                copy.path = newPath
                if let children = copy.children {
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
```

- [ ] **Step 4: Add the new file to the tripwire grep census**

In `MaughamTests/TripwireGrepTests.swift`, find `test_noRawMoveOfUserContentOutsideTypedMover` and add `"Maugham/Stores/ProjectStore+ResearchMove.swift"` to its scanned-files list (exact variable name visible in the test — it currently lists the `ProjectStore+{Structure,CollectionPieces,Research,WikiLink}` seams).

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ResearchMoveTests -only-testing:MaughamTests/TripwireGrepTests`
Expected: PASS (all new tests + tripwire census).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore+ResearchMove.swift MaughamTests/ResearchMoveTests.swift MaughamTests/TripwireGrepTests.swift
git commit -m "feat(research): batch scope-aware moveResearchItems via typed mover"
```

---

### Task 2: Store — retrofit single-item `moveResearchItem` (fixes `_assets` orphan bug)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Research.swift:308-349` (cross-group branch)
- Test: `MaughamTests/ResearchMoveTests.swift` (extend)

**Interfaces:**
- Consumes: `moveResearchItems(ids:to:atIndex:)` from Task 1.
- Produces: `moveResearchItem(id:toParentId:atIndex:)` keeps its exact existing signature and same-parent-reorder behavior; only the cross-group branch changes. All existing callers (`ResearchView.handleInternalDrop`, `CollectionResearchPane.handleResearchReorder`) are unaffected.

- [ ] **Step 1: Write the failing regression test**

Append to `MaughamTests/ResearchMoveTests.swift`:

```swift
    // MARK: existing single-item mover — _assets orphan regression

    /// Latent bug: the old cross-group branch built a one-step RenamePlan and
    /// left the note's sibling <slug>_assets/ folder behind. Pin the fix.
    func test_crossGroupMove_carriesAssetsFolder() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Harbor")
        // Simulate an image note: create the sibling assets folder on disk.
        let assetsURL = url.appendingPathComponent("research/harbor_assets")
        try FileManager.default.createDirectory(
            at: assetsURL, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assetsURL.appendingPathComponent("img.png"))

        try await store.moveResearchItem(
            id: note.id, toParentId: group.id, atIndex: 0)

        let groupPath = try XCTUnwrap(item(store, group.id)?.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("\(groupPath)/harbor_assets/img.png").path),
            "assets folder must travel with the note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetsURL.path),
            "old assets folder must be gone")
        await ds.close()
    }

    func test_sameParentReorder_stillManifestOnly() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")

        try await store.moveResearchItem(id: b.id, toParentId: nil, atIndex: 0)

        let topIds = store.manifest.research.map(\.id)
        XCTAssertEqual(topIds.firstIndex(of: b.id)! < topIds.firstIndex(of: a.id)!, true)
        XCTAssertEqual(item(store, a.id)?.path, "research/a.md")
        XCTAssertEqual(item(store, b.id)?.path, "research/b.md")
        await ds.close()
    }
```

- [ ] **Step 2: Run to verify the regression test fails**

Run: `xcodebuild ... -only-testing:MaughamTests/ResearchMoveTests`
Expected: `test_crossGroupMove_carriesAssetsFolder` FAILS (assets folder left at `research/harbor_assets`); `test_sameParentReorder_stillManifestOnly` PASSES (pre-existing behavior).

- [ ] **Step 3: Replace the cross-group branch**

In `ProjectStore+Research.swift`, `moveResearchItem(id:toParentId:atIndex:)`: keep everything through the same-parent-reorder early return (lines 269–306) unchanged. Replace the entire cross-group tail (from `// Cross-group: physical move required.` to the end of the function, lines 308–348) with:

```swift
        // Cross-group: delegate to the batch scope-aware mover (one
        // RenamePlan incl. the note's sibling _assets/ folder, manifest
        // rewrite, single save).
        let target: ResearchMoveTarget = toParentId.map { .group($0) } ?? .sharedRoot
        try await moveResearchItems(ids: [id], to: target, atIndex: destIndex)
    }
```

Also delete the now-unused destination-parent validation block above it (lines 282–287, `// Validate destination parent if non-nil.`) — `resolveResearchMoveTarget` throws the same `ProjectStoreError.parentNotFound` — and the group cycle checks (lines 274–281) — `moveResearchItems` re-validates. Keep the `findResearchItem` guard and no-op detection as they are (the same-parent path needs them).

- [ ] **Step 4: Run the full research test surface**

Run: `xcodebuild ... -only-testing:MaughamTests/ResearchMoveTests -only-testing:MaughamTests/ProjectStoreResearchTests -only-testing:MaughamTests/RenameResearchItemTests -only-testing:MaughamTests/ResearchScopeTests`
Expected: PASS. If an existing `ProjectStoreResearchTests` move test asserts a load-only (no DocumentStore) cross-group move succeeds, it will now throw `DocumentStore not available` — the old code threw the same error for path-bearing items (line 309-311), so behavior only changed for path-less link items; if such a test breaks, wire a `DocumentStore` into its fixture as in `RenameResearchItemTests.makeNovel`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+Research.swift MaughamTests/ResearchMoveTests.swift
git commit -m "fix(research): cross-group move carries _assets folder; retrofit onto batch mover"
```

---

### Task 3: Store — link cleanup both ways

**Files:**
- Modify: `Maugham/Stores/ProjectStore+ResearchMove.swift` (Phase 4, before `saveManifest`)
- Test: `MaughamTests/ResearchMoveTests.swift` (extend)

**Interfaces:**
- Consumes: `Self.applyLinkMutation(documentId:in:_:)` (`ProjectStore+Structure.swift`, used by `linkResearch`/`unlinkResearch`), `linkedResearchIds(forDocumentId:)`.
- Produces: no new API — behavior folded into `moveResearchItems`.

- [ ] **Step 1: Write failing tests**

Append to `ResearchMoveTests.swift`:

```swift
    // MARK: link cleanup

    func test_moveIntoPiece_dropsNowRedundantExplicitLink() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        try await store.linkResearch(researchId: note.id, toDocumentId: piece.id)

        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))

        XCTAssertFalse(store.linkedResearchIds(forDocumentId: piece.id).contains(note.id),
            "containment covers it — explicit link is redundant")
        await ds.close()
    }

    func test_moveOutOfPiece_preservesAssociationAsExplicitLink() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Clock Tower")

        try await store.moveResearchItems(ids: [note.id], to: .sharedRoot)

        XCTAssertTrue(store.linkedResearchIds(forDocumentId: piece.id).contains(note.id),
            "the piece association must survive the move out")
        await ds.close()
    }

    func test_groupOutOfPiece_linksDescendantAssets() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Cluster", kind: nil)
        let child = try await store.addResearchTextNote(parentId: group.id, title: "Inside")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        try await store.moveResearchItems(ids: [group.id], to: .sharedRoot)

        let links = store.linkedResearchIds(forDocumentId: piece.id)
        XCTAssertTrue(links.contains(child.id), "descendant assets get the link")
        XCTAssertFalse(links.contains(group.id), "groups themselves are not linked")
        await ds.close()
    }

    func test_pieceToPiece_movesLinkCleanupBothEnds() async throws {
        let (_, store, ds, pieceA) = try await makeCollection()
        let pieceB = try await store.addLoosePiece(title: "Story B", mode: .prose)
        let note = try await store.createResearchNote(
            scope: .document(pieceA.id), title: "Shared Cast")
        try await store.linkResearch(researchId: note.id, toDocumentId: pieceB.id)

        try await store.moveResearchItems(ids: [note.id], to: .piece(pieceB.id))

        XCTAssertFalse(store.linkedResearchIds(forDocumentId: pieceB.id).contains(note.id),
            "arrived into B's containment — link redundant")
        XCTAssertFalse(store.linkedResearchIds(forDocumentId: pieceA.id).contains(note.id),
            "piece→piece transfers the association; A gets no link")
        await ds.close()
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild ... -only-testing:MaughamTests/ResearchMoveTests`
Expected: the four new tests FAIL (no cleanup happens yet).

- [ ] **Step 3: Implement cleanup in `moveResearchItems`**

In `ProjectStore+ResearchMove.swift`, insert between the `replaceResearchChildren` call and `manifest.modified = Date()`:

```swift
        // ---- Phase 5: link cleanup (same manifest save) ----
        // Into piece X → drop X's now-redundant explicit links.
        // Out of piece Y to shared → preserve the association as an explicit
        // link (asset ids only; for groups, their descendant assets).
        // Piece→piece → the association transfers with containment: drop at
        // the destination, no link added at the source.
        for (item, updated) in zip(items, updatedItems) {
            let sourceScope = researchScopePieceId(ofPath: item.path)
            let destScope = dest.destPieceId
            guard sourceScope != destScope else { continue }

            var affectedAssetIds: [String] = []
            if item.type == .asset {
                affectedAssetIds = [item.id]
            } else {
                affectedAssetIds = TreeWalk.collect(
                    in: updated.children ?? [], where: { $0.type == .asset }).map(\.id)
            }

            if let destPiece = destScope {
                Self.applyLinkMutation(
                    documentId: destPiece, in: &manifest.structure
                ) { doc in
                    guard var ids = doc.linkedResearchIds else { return }
                    ids.removeAll { affectedAssetIds.contains($0) || $0 == item.id }
                    doc.linkedResearchIds = ids.isEmpty ? nil : ids
                }
            }
            if let sourcePiece = sourceScope, destScope == nil {
                Self.applyLinkMutation(
                    documentId: sourcePiece, in: &manifest.structure
                ) { doc in
                    var ids = doc.linkedResearchIds ?? []
                    for assetId in affectedAssetIds where !ids.contains(assetId) {
                        ids.append(assetId)
                    }
                    doc.linkedResearchIds = ids.isEmpty ? nil : ids
                }
            }
        }
```

(If `applyLinkMutation`'s closure parameter label differs, match the call shape used by `linkResearch` at `ProjectStore+Structure.swift:667` exactly.)

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... -only-testing:MaughamTests/ResearchMoveTests -only-testing:MaughamTests/LinkedResearchTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+ResearchMove.swift MaughamTests/ResearchMoveTests.swift
git commit -m "feat(research): scope moves clean up explicit links both directions"
```

---

### Task 4: Store — `deleteResearchItems(ids:)` batch delete

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Research.swift` (factor `deleteResearchItem` core; add batch API)
- Test: `MaughamTests/ResearchMoveTests.swift` (extend — keeps batch-op tests together)

**Interfaces:**
- Consumes: existing `deleteResearchItem(id:)` body (`ProjectStore+Research.swift:475`), `collapseResearchSelection(_:)` from Task 1.
- Produces: `public func deleteResearchItems(ids: [String]) async throws` — one manifest save, one trash-list refresh; `lastDeletedTrashId` points at the last trashed entry.

- [ ] **Step 1: Write failing tests**

```swift
    // MARK: batch delete

    func test_deleteResearchItems_batchOneSave() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")
        let link = try await store.addResearchLink(
            parentId: nil, title: "L", url: "https://x.example")

        try await store.deleteResearchItems(ids: [a.id, b.id, link.id])

        XCTAssertNil(item(store, a.id))
        XCTAssertNil(item(store, b.id))
        XCTAssertNil(item(store, link.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/a.md").path))
        XCTAssertNotNil(store.lastDeletedTrashId)
        await ds.close()
    }

    func test_deleteResearchItems_descendantCollapses() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(parentId: nil, title: "G", kind: nil)
        let child = try await store.addResearchTextNote(parentId: group.id, title: "C")

        // Selecting both must not attempt to trash the child twice.
        try await store.deleteResearchItems(ids: [group.id, child.id])

        XCTAssertNil(item(store, group.id))
        XCTAssertNil(item(store, child.id))
        await ds.close()
    }
```

- [ ] **Step 2: Run to verify compile failure** (`deleteResearchItems` undefined).

- [ ] **Step 3: Implement**

In `ProjectStore+Research.swift`, refactor `deleteResearchItem(id:)` by extracting its body into a private helper that defers persistence, then reimplement both entry points:

```swift
    /// Trash one item's file (if any) and remove it from the manifest.
    /// Does NOT save the manifest or refresh trashEntries — callers batch that.
    /// Returns the trash entry when a file was trashed.
    private func trashResearchItemCore(id: String) async throws -> TrashEntry? {
        guard let item = findResearchItem(id: id, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let parentId = findResearchParentId(
            of: id, in: manifest.research, parent: nil)
        let index = currentResearchIndex(of: id, parentId: parentId)

        var entry: TrashEntry?
        if let path = item.path, !path.isEmpty, item.kind != .link {
            let metadata = try JSONEncoder().encode(item)
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
        }
        removeResearchItem(id: id)
        return entry
    }

    public func deleteResearchItems(ids: [String]) async throws {
        let effective = collapseResearchSelection(ids)
        // Validate the whole batch before trashing anything.
        for id in effective {
            guard findResearchItem(id: id, in: manifest.research) != nil else {
                throw ProjectStoreError.structureMissing
            }
        }
        var lastEntry: TrashEntry?
        for id in effective {
            if let entry = try await trashResearchItemCore(id: id) {
                lastEntry = entry
            }
        }
        manifest.modified = Date()
        try await saveManifest()
        trashEntries = (try? await trashStore.list()) ?? trashEntries
        if let lastEntry { lastDeletedTrashId = lastEntry.id }
    }
```

Then rewrite the existing `deleteResearchItem(id:)` as `try await deleteResearchItems(ids: [id])`, preserving its public signature.

**Fidelity check while refactoring:** the current `deleteResearchItem` distinguishes path-bearing vs path-less items; link items have *synthetic* paths but no file on disk — confirm the current code's behavior for links (does it attempt to trash the synthetic path?). Read `ProjectStore+Research.swift:475-520` first and mirror the existing branch behavior exactly in `trashResearchItemCore` — the `item.kind != .link` guard above matches the synthetic-path design from `addPieceResearchLink`, but if the existing code trashes shared links' paths successfully today (shared links may have no `path` at all — see `moveResearchItem`'s "Link asset — no path" comment), keep that exact behavior and delete the guard.

- [ ] **Step 4: Run tests**

Run: `xcodebuild ... -only-testing:MaughamTests/ResearchMoveTests -only-testing:MaughamTests/ProjectStoreResearchTests`
Expected: PASS (including all existing delete tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+Research.swift MaughamTests/ResearchMoveTests.swift
git commit -m "feat(research): batch deleteResearchItems with single manifest save"
```

---

### Task 5: Views — extract shared research tree component (no behavior change)

**Files:**
- Create: `Maugham/Views/ResearchTree.swift`
- Modify: `Maugham/Views/ResearchView.swift` (adopt; delete now-duplicated code)

**Interfaces:**
- Consumes: `ResearchRow` (unchanged), `DropIntent.Position`.
- Produces (Tasks 6–9 build on these exact shapes):

```swift
/// Closures a hosting pane supplies to the shared research tree. One struct
/// so the recursive node view has a single dependency.
struct ResearchTreeActions {
    var rename: (String, String) -> Void
    var internalDrop: (_ draggedId: String, _ position: DropIntent.Position, _ target: ResearchItem) -> Void
    var externalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position, _ target: ResearchItem) -> Void
    var newNote: (_ parentId: String?) -> Void
    var newGroup: (_ parentId: String?) -> Void
    var addFile: (_ parentId: String?) -> Void
    var addLink: (_ parentId: String?) -> Void
    var duplicate: (String) -> Void
    var delete: (String) -> Void
}

struct ResearchTreeNode: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let findParentId: (String) -> String?
    let actions: ResearchTreeActions
    // body: DisclosureGroup recursion for groups, ResearchRow + contextMenu
}
```

- [ ] **Step 1: Create `Maugham/Views/ResearchTree.swift`**

Move the recursion + row + context menu from `ResearchView` verbatim into the new component (this is a refactor — the code below is `ResearchView.node/childNodes/row` reshaped around the actions struct):

```swift
import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

/// Shared recursive research tree node used by ResearchView (novel/short
/// story/screenplay) and CollectionResearchPane (per-section). Extracted so
/// collections get real nesting + drop-into-group instead of the flat fork
/// that made groups decorative (2026-07-16 research-restructuring spec).
struct ResearchTreeActions {
    var rename: (String, String) -> Void
    var internalDrop: (_ draggedId: String, _ position: DropIntent.Position, _ target: ResearchItem) -> Void
    var externalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position, _ target: ResearchItem) -> Void
    var newNote: (_ parentId: String?) -> Void
    var newGroup: (_ parentId: String?) -> Void
    var addFile: (_ parentId: String?) -> Void
    var addLink: (_ parentId: String?) -> Void
    var duplicate: (String) -> Void
    var delete: (String) -> Void
}

struct ResearchTreeNode: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let findParentId: (String) -> String?
    let actions: ResearchTreeActions

    var body: some View {
        if item.type == .group {
            DisclosureGroup {
                AnyView(childNodes)
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var childNodes: some View {
        ForEach(item.children ?? []) { child in
            AnyView(ResearchTreeNode(
                item: child,
                renamingItemId: $renamingItemId,
                findParentId: findParentId,
                actions: actions))
        }
    }

    private var row: some View {
        ResearchRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: actions.rename,
            onDrop: { draggedId, position in
                actions.internalDrop(draggedId, position, item)
            },
            onExternalDrop: { providers, position in
                actions.externalDrop(providers, position, item)
            })
            .tag(item.id as String?)
            .contextMenu {
                Button("New Note") {
                    actions.newNote(item.type == .group ? item.id : findParentId(item.id))
                }
                if item.type == .group {
                    Button("New Group") { actions.newGroup(item.id) }
                    Button("Add File…") { actions.addFile(item.id) }
                    Button("Add Link…") { actions.addLink(item.id) }
                    Divider()
                }
                Button("Duplicate") { actions.duplicate(item.id) }
                Button("Rename") { renamingItemId = item.id }
                Button("Delete", role: .destructive) { actions.delete(item.id) }
            }
    }
}
```

Note the `.tag(item.id as String?)` — `ResearchView`'s rows currently rely on `List(selection:)` implicit identity; `CollectionResearchPane`'s rows already tag explicitly. Tagging in the shared component keeps both correct (and Task 8 retags as non-optional `String` when selection becomes `Set<String>`).

- [ ] **Step 2: Adopt in `ResearchView`**

Replace `node(for:)`, `childNodes(for:)`, and `row(for:)` in `ResearchView.swift` with:

```swift
    private var treeActions: ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in Task { await rename(id: id, to: newTitle) } },
            internalDrop: { draggedId, position, target in
                Task { await handleInternalDrop(
                    draggedId: draggedId, position: position, target: target) }
            },
            externalDrop: { providers, position, target in
                let parent = position == .middle && target.type == .group
                    ? target.id
                    : findParentId(of: target.id)
                Task { await importExternal(providers, toParentId: parent) }
            },
            newNote: { parentId in Task { await addResearchNote(parentId: parentId) } },
            newGroup: { parentId in Task { await addGroup(parentId: parentId) } },
            addFile: { parentId in Task { await runAddFile(parentId: parentId) } },
            addLink: { parentId in
                addLinkParentId = parentId
                showingAddLinkSheet = true
            },
            duplicate: { id in Task { await duplicate(id: id) } },
            delete: { id in Task { await delete(id: id) } })
    }
```

and in `body`, replace `node(for: item)` with:

```swift
            ForEach(store.manifest.research) { item in
                ResearchTreeNode(
                    item: item,
                    renamingItemId: $renamingItemId,
                    findParentId: { findParentId(of: $0) },
                    actions: treeActions)
            }
```

Delete the now-unused `node(for:)` / `childNodes(for:)` / `row(for:)`. `handleInternalDrop`, `findParentId`, `currentIndex`, and all action funcs stay where they are.

- [ ] **Step 3: Build + full Mac test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS — pure refactor, no behavior change.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/ResearchTree.swift Maugham/Views/ResearchView.swift
git commit -m "refactor(research): extract shared ResearchTreeNode from ResearchView"
```

---

### Task 6: Views — `CollectionResearchPane` adopts the tree (groups stop being decorative)

**Files:**
- Modify: `Maugham/Views/CollectionResearchPane.swift`

**Interfaces:**
- Consumes: `ResearchTreeNode`/`ResearchTreeActions` (Task 5), `moveResearchItem` (unchanged), scoped creation APIs (`createResearchNote(scope:)` etc.), `addResearchTextNote(parentId:)`/`addResearchItem(parentId:)`/`importResearchFiles(_:toParentId:)`/`addResearchLink(parentId:)` for in-group creation.
- Produces: sections render nested trees; `.middle`-drop on a group moves into it; in-group creation context items work. Cross-*section* drops remain ignored (Task 7 adds them).

- [ ] **Step 1: Replace flat rows with tree nodes**

In `CollectionResearchPane.swift`:

1. Replace both `ForEach(items) { row(for: item, scope:) }` occurrences with:

```swift
                ForEach(items) { item in
                    ResearchTreeNode(
                        item: item,
                        renamingItemId: $renamingItemId,
                        findParentId: { findParentId(of: $0) },
                        actions: treeActions(scope: scope))
                }
```

(pass `scope: .shared` in `sharedSection`, `scope: .piece(piece.id)` in `pieceSection`).

2. Delete `row(for:scope:)` and its context menu (the tree node owns it now).

3. Add the actions builder + tree helpers (mirroring `ResearchView`, but creation at top level routes through scope):

```swift
    private func treeActions(scope: Scope) -> ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in Task { await rename(id: id, to: newTitle) } },
            internalDrop: { draggedId, position, target in
                Task { await handleInternalDrop(
                    draggedId: draggedId, position: position,
                    target: target, scope: scope) }
            },
            externalDrop: { providers, position, target in
                if position == .middle && target.type == .group {
                    Task { await importExternalIntoGroup(providers, parentId: target.id) }
                } else {
                    Task { await importExternal(providers, scope: scope) }
                }
            },
            newNote: { parentId in
                if let parentId {
                    Task { await addNoteInGroup(parentId: parentId) }
                } else {
                    Task { await addNote(scope: scope) }
                }
            },
            newGroup: { parentId in Task { await addGroup(parentId: parentId) } },
            addFile: { parentId in
                if let parentId {
                    Task { await runAddFileInGroup(parentId: parentId) }
                } else {
                    Task { await runAddFile(scope: scope) }
                }
            },
            addLink: { parentId in
                if let parentId {
                    addLinkScope = .group(parentId)
                } else {
                    addLinkScope = scope == .shared
                        ? .shared
                        : { if case .piece(let id) = scope { return .piece(id) }; return .shared }()
                }
                showingAddLinkSheet = true
            },
            duplicate: { id in Task { await duplicate(id: id) } },
            delete: { id in Task { await delete(id: id) } })
    }

    private func addNoteInGroup(parentId: String) async {
        do {
            let note = try await store.addResearchTextNote(
                parentId: parentId, title: "Untitled Note")
            selectedResearchId = note.id
            pendingRenameId = note.id
        } catch { pendingError = error.localizedDescription }
    }

    private func runAddFileInGroup(parentId: String) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            _ = try await store.importResearchFiles(panel.urls, toParentId: parentId)
        } catch { pendingError = error.localizedDescription }
    }

    private func importExternalIntoGroup(
        _ providers: [NSItemProvider], parentId: String
    ) async {
        let urls = await DropClassification.fileURLs(from: providers)
        guard !urls.isEmpty else { return }
        do {
            _ = try await store.importResearchFiles(urls, toParentId: parentId)
        } catch { pendingError = error.localizedDescription }
    }

    private func findParentId(of childId: String) -> String? {
        store.findResearchParentId(of: childId, in: store.manifest.research, parent: nil)
    }
```

4. Extend `AddLinkScope` with `case group(String)` and handle it in `addLinkForScope`:

```swift
    private enum AddLinkScope: Equatable {
        case shared
        case piece(String)
        case group(String)
    }
    // in addLinkForScope's switch:
            case .group(let parentId):
                link = try await store.addResearchLink(
                    parentId: parentId, title: title, url: url)
```

5. `addGroup` gains a `parentId: String?` parameter (`store.addResearchItem(parentId: parentId, …)`); the shared-header "New Group" passes nil. Add "New Group" to `pieceHeaderMenu` too — groups inside pieces are now real:

```swift
            Button("New Group") { Task { await addGroupInPiece(pieceId: pieceId) } }
```

with:

```swift
    /// A group created "in" a piece is a top-level manifest node whose FOLDER
    /// lives under the piece's research/ — create then move (one visible item
    /// either way; the move is cheap and reuses the validated path).
    private func addGroupInPiece(pieceId: String) async {
        do {
            let g = try await store.addResearchItem(
                parentId: nil, title: "Untitled Group", kind: nil)
            try await store.moveResearchItems(ids: [g.id], to: .piece(pieceId))
            selectedResearchId = g.id
            pendingRenameId = g.id
        } catch { pendingError = error.localizedDescription }
    }
```

6. Update `handleResearchReorder` → rename to `handleInternalDrop(draggedId:position:target:scope:)`, adding drop-into-group while keeping cross-section drops ignored for now:

```swift
    private func handleInternalDrop(
        draggedId: String, position: DropIntent.Position,
        target: ResearchItem, scope: Scope
    ) async {
        guard draggedId != target.id else { return }
        guard let dragged = TreeWalk.find(id: draggedId, in: store.manifest.research),
              scopeFor(item: dragged) == scope || findParentId(of: draggedId) != nil,
              scopeFor(item: target) == scope || findParentId(of: target.id) != nil else {
            return  // cross-section drop — Task 7
        }
        do {
            if position == .middle && target.type == .group {
                try await store.moveResearchItem(
                    id: draggedId, toParentId: target.id, atIndex: 0)
                return
            }
            let toParentId = findParentId(of: target.id)
            let siblings: [ResearchItem]
            if let toParentId,
               let parent = TreeWalk.find(id: toParentId, in: store.manifest.research) {
                siblings = parent.children ?? []
            } else {
                siblings = store.manifest.research
            }
            guard let targetIdx = siblings.firstIndex(where: { $0.id == target.id }) else { return }
            var destIdx = position == .top ? targetIdx : targetIdx + 1
            if let sourceIdx = siblings.firstIndex(where: { $0.id == draggedId }),
               sourceIdx < destIdx { destIdx -= 1 }
            try await store.moveResearchItem(
                id: draggedId, toParentId: toParentId, atIndex: destIdx)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

Note this replaces the old flat-array index math: with trees, the destination index is computed against the *sibling list* (top-level or group children), same as `ResearchView.handleInternalDrop`. `scopeFor` guards stay so that a drag from another *section* is still ignored until Task 7. Also make `findResearchParentId` reachable: it is `internal` on `ProjectStore` — call sites in views use `store.findResearchParentId(...)` (same module, fine).

- [ ] **Step 2: Build + tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 3: Manual spot-check (dev app)**

Launch, open/create a Collection: create a group in Shared → drag a note onto it (`.middle`) → disclosure triangle shows the note inside; right-click the group → New Note lands inside; create a group in a piece section → appears under the piece.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/CollectionResearchPane.swift
git commit -m "feat(research): collection pane renders nested groups with drop-into-group"
```

---

### Task 7: Views — cross-section drops become scope moves

**Files:**
- Modify: `Maugham/Views/CollectionResearchPane.swift`

**Interfaces:**
- Consumes: `moveResearchItems(ids:to:atIndex:)`, `ResearchMoveTarget`, `scopeFor(item:)`.
- Produces: dragging rows across sections (Shared ↔ piece, piece ↔ piece) performs the scope move; dropping on a section's header/whitespace targets that section's root.

- [ ] **Step 1: Route cross-section drops in `handleInternalDrop`**

Replace the `return  // cross-section drop — Task 7` guard path: instead of bailing, detect the cross-section case and call the batch mover. Reshape the top of the function to:

```swift
        guard draggedId != target.id else { return }
        guard let dragged = TreeWalk.find(id: draggedId, in: store.manifest.research) else { return }
        let draggedScope = scopeFor(item: dragged)
        let targetScope = scopeFor(item: target)

        do {
            if draggedScope != targetScope {
                // Cross-section drag = scope move.
                if position == .middle && target.type == .group {
                    try await store.moveResearchItems(
                        ids: [draggedId], to: .group(target.id), atIndex: 0)
                    return
                }
                let sectionTarget: ResearchMoveTarget = {
                    if case .piece(let pieceId) = targetScope { return .piece(pieceId) }
                    return .sharedRoot
                }()
                // Insert relative to the target row's top-level position.
                let topLevel = store.manifest.research
                if findParentId(of: target.id) == nil,
                   let targetIdx = topLevel.firstIndex(where: { $0.id == target.id }) {
                    let destIdx = position == .top ? targetIdx : targetIdx + 1
                    try await store.moveResearchItems(
                        ids: [draggedId], to: sectionTarget, atIndex: destIdx)
                } else {
                    try await store.moveResearchItems(
                        ids: [draggedId], to: sectionTarget)
                }
                return
            }
            // …existing same-section handling from Task 6 unchanged…
```

(the `scope` parameter becomes unused for internal drops — keep it for external drops, which still import into the section the row lives in).

- [ ] **Step 2: Section-level internal drops (header / whitespace)**

Each section currently has `.onDrop(of: [.fileURL, .image], …)` for external files. Add a String-payload drop alongside it so an internal drag released on the section (not a row) moves to that section's root — on `sharedSection`:

```swift
        .dropDestination(for: String.self) { ids, _ in
            guard !ids.isEmpty else { return false }
            Task { await moveToSection(ids: ids, scope: .shared) }
            return true
        }
```

and on `pieceSection(for: piece)` the same with `scope: .piece(piece.id)`, plus the helper:

```swift
    private func moveToSection(ids: [String], scope: Scope) async {
        let target: ResearchMoveTarget = {
            if case .piece(let pieceId) = scope { return .piece(pieceId) }
            return .sharedRoot
        }()
        do {
            try await store.moveResearchItems(ids: ids, to: target)
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

Row-level `.dropDestination` handlers sit deeper in the hierarchy and win when the pointer is over a row; the section-level one catches header/empty-area releases. Verify this precedence in the manual spot-check — if the section-level modifier swallows row drops, attach it to the section *header* view and the empty-state `Text` instead.

- [ ] **Step 3: Build + tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 4: Manual spot-check (dev app)**

Collection: drag a Shared note into the piece section → file lands under `pieces/<NN>-<slug>/research/` (check right pane's Piece Research shows it); drag it back onto the Shared header → returns to `research/`, and the piece's Linked Research now lists it (Task 3 cleanup visible in UI).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/CollectionResearchPane.swift
git commit -m "feat(research): cross-section drags move research between scopes"
```

---

### Task 8: Views — multiselect (`Set<String>`) on both research surfaces

**Files:**
- Modify: `Maugham/Views/ResearchView.swift`, `Maugham/Views/CollectionResearchPane.swift`
- Test: `MaughamTests/ResearchSelectionTests.swift` (create — pure logic helpers)

**Interfaces:**
- Consumes: existing `selectedResearchId: Binding<String?>` plumbing (ProjectWindow → panes), which MUST keep working — preview panes key off it.
- Produces:
  - Both panes hold `@State private var selection = Set<String>()` driving `List(selection: $selection)`.
  - `ResearchSelectionSync.previewId(for: Set<String>) -> String?` and `ResearchSelectionSync.orderedSelection(_ selection: Set<String>, in research: [ResearchItem]) -> [String]` — small pure helpers in `ResearchTree.swift`, unit-testable.
  - Drag expansion rule: dropping `draggedId` applies to `orderedSelection` when `selection.contains(draggedId) && selection.count > 1`, else `[draggedId]`.

- [ ] **Step 1: Write failing tests for the pure helpers**

Create `MaughamTests/ResearchSelectionTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class ResearchSelectionTests: XCTestCase {

    private func note(_ id: String) -> ResearchItem {
        ResearchItem(id: id, title: id, type: .asset, kind: .document,
                     path: "research/\(id).md", addedAt: Date())
    }

    func test_previewId_singleSelection() {
        XCTAssertEqual(ResearchSelectionSync.previewId(for: ["a"]), "a")
    }

    func test_previewId_multiOrEmpty_isNil() {
        XCTAssertNil(ResearchSelectionSync.previewId(for: []))
        XCTAssertNil(ResearchSelectionSync.previewId(for: ["a", "b"]))
    }

    func test_orderedSelection_followsManifestTreeOrder() {
        var group = ResearchItem(id: "g", title: "G", type: .group, kind: nil,
                                 path: "research/g", addedAt: Date())
        group.children = [note("b")]
        let research = [note("a"), group, note("c")]
        let ordered = ResearchSelectionSync.orderedSelection(
            ["c", "b", "a"], in: research)
        XCTAssertEqual(ordered, ["a", "b", "c"])
    }

    func test_expandedDragIds() {
        XCTAssertEqual(
            ResearchSelectionSync.expandedDragIds(
                draggedId: "a", selection: ["a", "b"], in: [note("a"), note("b")]),
            ["a", "b"])
        XCTAssertEqual(
            ResearchSelectionSync.expandedDragIds(
                draggedId: "c", selection: ["a", "b"], in: [note("a"), note("b"), note("c")]),
            ["c"],
            "dragging a row outside the selection moves only that row")
    }
}
```

- [ ] **Step 2: Run to verify compile failure** (`ResearchSelectionSync` undefined).

- [ ] **Step 3: Implement the helpers** (append to `Maugham/Views/ResearchTree.swift`):

```swift
/// Selection⇄preview sync + drag-expansion rules shared by the two research
/// surfaces. Pure functions — unit-tested in ResearchSelectionTests.
enum ResearchSelectionSync {
    /// The preview pane shows a single item or nothing.
    static func previewId(for selection: Set<String>) -> String? {
        selection.count == 1 ? selection.first : nil
    }

    /// Selection ordered by depth-first manifest tree position (visual order).
    static func orderedSelection(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        var ordered: [String] = []
        func walk(_ items: [ResearchItem]) {
            for item in items {
                if selection.contains(item.id) { ordered.append(item.id) }
                if let children = item.children { walk(children) }
            }
        }
        walk(research)
        return ordered
    }

    /// Standard Mac behavior: dragging a row inside the selection drags the
    /// whole selection; dragging an unselected row drags just that row.
    static func expandedDragIds(
        draggedId: String, selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        guard selection.contains(draggedId), selection.count > 1 else {
            return [draggedId]
        }
        return orderedSelection(selection, in: research)
    }
}
```

- [ ] **Step 4: Wire `Set` selection into both panes**

Same shape in `ResearchView` and `CollectionResearchPane`:

```swift
    @State private var selection = Set<String>()
```

- `List(selection: $selectedResearchId)` → `List(selection: $selection)`.
- In `ResearchTree.swift`, change the row tag to `.tag(item.id)` (plain `String`, matching `Set<String>` selection).
- Two-way sync with the external single-id binding — value-convergent `onChange`s, NO flag guards (tripwire 2: flag-based loop guards leak; these converge because `.onChange` only fires on value *change* and both writes are idempotent at the fixed point):

```swift
        .onChange(of: selection) { _, newValue in
            selectedResearchId = ResearchSelectionSync.previewId(for: newValue)
        }
        .onChange(of: selectedResearchId) { _, newValue in
            if let id = newValue, !selection.contains(id) {
                selection = [id]
            }
        }
        .onAppear {
            if let id = selectedResearchId { selection = [id] }
        }
```

- Expand drags: in each pane's internal-drop entry point, first compute

```swift
        let movingIds = ResearchSelectionSync.expandedDragIds(
            draggedId: draggedId, selection: selection, in: store.manifest.research)
```

  - `CollectionResearchPane.handleInternalDrop`: pass `movingIds` to every `store.moveResearchItems(ids: …)` call (cross-section and into-group cases). For the same-section reorder case, keep single-id `moveResearchItem` when `movingIds.count == 1`; for a multi-selection reorder call `moveResearchItems(ids: movingIds, to: sectionTargetOrGroup, atIndex: destIdx)` (same-folder moves are manifest-only — `RenamePlan` filters the no-op steps).
  - `ResearchView.handleInternalDrop`: same treatment — `movingIds.count == 1` keeps the existing `moveResearchItem` call; multi goes through `moveResearchItems(ids:to:atIndex:)` with `.group(toParentId)` / `.sharedRoot`.

- [ ] **Step 5: Build + tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS (incl. new `ResearchSelectionTests`).

- [ ] **Step 6: Manual spot-check (dev app)**

⌘-click three notes → preview pane empties; click one → preview returns. Drag one of three selected → all three land in the target piece section.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/ResearchTree.swift Maugham/Views/ResearchView.swift Maugham/Views/CollectionResearchPane.swift MaughamTests/ResearchSelectionTests.swift
git commit -m "feat(research): Set-based multiselect with whole-selection drag on both surfaces"
```

---

### Task 9: Views — "Move to ▸" context submenu + batch Delete

**Files:**
- Modify: `Maugham/Views/ResearchTree.swift`, `Maugham/Views/ResearchView.swift`, `Maugham/Views/CollectionResearchPane.swift`

**Interfaces:**
- Consumes: `moveResearchItems`, `deleteResearchItems`, `ResearchSelectionSync.orderedSelection`.
- Produces: `ResearchTreeActions` gains
  - `var moveTargets: (_ forIds: [String]) -> [ResearchMoveMenuTarget]`
  - `var move: (_ ids: [String], _ target: ResearchMoveTarget) -> Void`
  - `var deleteMany: (_ ids: [String]) -> Void`
  - `var selectionForRow: (_ rowId: String) -> [String]` (row in selection → ordered selection; else just the row)
  and a small descriptor type:

```swift
struct ResearchMoveMenuTarget: Identifiable {
    let id: String          // stable menu identity, e.g. "shared" / "group-<id>" / "piece-<id>"
    let title: String       // "Shared", "World / Maps", piece title
    let target: ResearchMoveTarget
}
```

- [ ] **Step 1: Extend the shared context menu**

In `ResearchTreeNode.row`'s `.contextMenu`, insert before "Duplicate":

```swift
                let acting = actions.selectionForRow(item.id)
                let targets = actions.moveTargets(acting)
                if !targets.isEmpty {
                    Menu("Move to") {
                        ForEach(targets) { t in
                            Button(t.title) { actions.move(acting, t.target) }
                        }
                    }
                    Divider()
                }
                if acting.count > 1 {
                    Button("Delete \(acting.count) Items", role: .destructive) {
                        actions.deleteMany(acting)
                    }
                } else {
                    Button("Duplicate") { actions.duplicate(item.id) }
                    Button("Rename") { renamingItemId = item.id }
                    Button("Delete", role: .destructive) { actions.delete(item.id) }
                }
```

(replacing the existing Duplicate/Rename/Delete tail — single-selection keeps all three; multi shows only batch Delete, per spec).

- [ ] **Step 2: Implement target computation (shared helper in `ResearchTree.swift`)**

```swift
extension ResearchSelectionSync {
    /// Menu targets for moving `ids`: Shared root, every group (nested titles
    /// flattened as "Outer / Inner"), and — in collections — every loose
    /// piece. Excludes invalid destinations: groups inside a moving group
    /// (cycle), the items' current parent (no-op), and everything cross-scope
    /// for role-bearing items.
    static func moveTargets(
        forIds ids: [String], manifest: ProjectManifest
    ) -> [ResearchMoveMenuTarget] {
        let movingItems = ids.compactMap { TreeWalk.find(id: $0, in: manifest.research) }
        guard !movingItems.isEmpty else { return [] }
        let movingGroupIds = Set(movingItems.filter { $0.type == .group }.map(\.id))
        let anyRoleBearing = movingItems.contains { $0.role != nil }

        func isInsideMovingGroup(_ id: String) -> Bool {
            movingItems.contains { g in
                g.type == .group && TreeWalk.contains(id: id, in: g.children ?? [])
            }
        }

        var targets: [ResearchMoveMenuTarget] = [
            .init(id: "shared", title: "Shared", target: .sharedRoot)
        ]
        // Groups, flattened titles.
        func walkGroups(_ items: [ResearchItem], prefix: String) {
            for item in items where item.type == .group {
                let title = prefix.isEmpty ? item.title : "\(prefix) / \(item.title)"
                if !movingGroupIds.contains(item.id), !isInsideMovingGroup(item.id) {
                    targets.append(.init(
                        id: "group-\(item.id)", title: title, target: .group(item.id)))
                }
                walkGroups(item.children ?? [], prefix: title)
            }
        }
        walkGroups(manifest.research, prefix: "")
        // Loose pieces (collections).
        if manifest.type == .collection {
            for piece in manifest.structure
                where piece.type == .document && piece.pieceKind == .loose {
                targets.append(.init(
                    id: "piece-\(piece.id)", title: piece.title,
                    target: .piece(piece.id)))
            }
        }
        // Role-bearing selections may only move within their scope — cheapest
        // honest menu: offer nothing (the store would refuse anyway).
        return anyRoleBearing ? [] : targets
    }
}
```

- [ ] **Step 3: Wire the new actions in both panes**

In each pane's actions builder add:

```swift
            selectionForRow: { rowId in
                ResearchSelectionSync.expandedDragIds(
                    draggedId: rowId, selection: selection,
                    in: store.manifest.research)
            },
            moveTargets: { ids in
                ResearchSelectionSync.moveTargets(forIds: ids, manifest: store.manifest)
            },
            move: { ids, target in
                Task {
                    do { try await store.moveResearchItems(ids: ids, to: target) }
                    catch { pendingError = error.localizedDescription }
                }
            },
            deleteMany: { ids in
                Task {
                    do { try await store.deleteResearchItems(ids: ids) }
                    catch { pendingError = error.localizedDescription }
                }
            },
```

(`ResearchView` offers no `.piece` targets automatically — `moveTargets` already keys off `manifest.type`, so novels just see Shared + groups.)

- [ ] **Step 4: Unit-test target computation** (append to `ResearchSelectionTests.swift`)

```swift
    func test_moveTargets_excludesMovingGroupAndDescendants() throws {
        var outer = ResearchItem(id: "outer", title: "Outer", type: .group,
                                 kind: nil, path: "research/outer", addedAt: Date())
        var inner = ResearchItem(id: "inner", title: "Inner", type: .group,
                                 kind: nil, path: "research/outer/inner", addedAt: Date())
        inner.children = []
        outer.children = [inner]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [outer])

        let targets = ResearchSelectionSync.moveTargets(
            forIds: ["outer"], manifest: manifest)
        let ids = targets.map(\.id)
        XCTAssertTrue(ids.contains("shared"))
        XCTAssertFalse(ids.contains("group-outer"), "can't move into itself")
        XCTAssertFalse(ids.contains("group-inner"), "can't move into own descendant")
    }

    func test_moveTargets_roleBearing_isEmpty() throws {
        var palette = ResearchItem(id: "pal", title: "Palette", type: .group,
                                   kind: nil, path: "research/palette", addedAt: Date())
        palette.role = .paletteGroup
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [palette])

        XCTAssertTrue(ResearchSelectionSync.moveTargets(
            forIds: ["pal"], manifest: manifest).isEmpty)
    }
```

(If `ProjectManifest`'s memberwise init differs, mirror the fixture style at `ResearchScopeTests.makeProject` which builds one directly.)

- [ ] **Step 5: Build + tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/ResearchTree.swift Maugham/Views/ResearchView.swift Maugham/Views/CollectionResearchPane.swift MaughamTests/ResearchSelectionTests.swift
git commit -m "feat(research): Move-to submenu and batch delete on research selections"
```

---

### Task 10: MCP — `move_research_item` tool (47→48)

**Files:**
- Create: `Maugham/MCP/Tools/MoveResearchItemTool.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (`MCPToolCatalog.all` — add entry)
- Test: `MaughamTests/MCP/Tools/MoveResearchItemToolTests.swift` (create); update tool-count assertions in `MaughamTests/MCP/MCPToolsListSmokeTest.swift`, `MaughamTests/MCP/MCPCatalogConsistencyTests.swift`, `MaughamTests/MCP/Tools/ListMaughamToolsToolTests.swift` (known ≥3-test blast radius; grep for the literal current count: `grep -rn "47" MaughamTests/MCP | head`)

**Interfaces:**
- Consumes: `MCPTool` protocol (`Maugham/MCP/MCPTool.swift`), `decodeParams` / `resolveProject` helpers (see `ResearchLinkTools.swift` template), `moveResearchItems(ids:to:)`, `researchRouting(forDocumentId:)`.
- Produces: MCP method `move_research_item`.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/MCP/Tools/MoveResearchItemToolTests.swift` following the fixture style of `ListAllLinksToolTests`/`InboxToolsTests` (registered collection project + `handle(paramsJSON:registry:)`):

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class MoveResearchItemToolTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeRegistry() async throws
        -> (ProjectRegistry, ProjectStore, DocumentStore, StructureItem, String) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "MCPMove", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let registry = ProjectRegistry()
        let projectId = registry.register(store: store, documentStore: ds)
        return (registry, store, ds, piece, projectId)
    }

    private func params(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    func test_moveToPiece_movesFile() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        _ = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target_document_id": piece.id]),
            registry: registry)

        let moved = TreeWalk.find(id: note.id, in: store.manifest.research)
        XCTAssertTrue(moved?.path?.hasPrefix("pieces/") == true)
        await ds.close()
    }

    func test_moveToShared() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Out")

        _ = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target": "shared"]),
            registry: registry)

        XCTAssertEqual(
            TreeWalk.find(id: note.id, in: store.manifest.research)?.path,
            "research/out.md")
        await ds.close()
    }

    func test_multipleTargets_failsLoudly() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "X")

        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": [note.id],
                    "target": "shared",
                    "target_document_id": piece.id]),
                registry: registry))
        await ds.close()
    }

    func test_noTarget_failsLoudly() async throws {
        let (registry, store, ds, _, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "X")

        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": [note.id]]),
                registry: registry))
        await ds.close()
    }

    func test_unknownResearchId_failsLoudly() async throws {
        let (registry, _, ds, piece, projectId) = try await makeRegistry()
        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": ["res-nope"],
                    "target_document_id": piece.id]),
                registry: registry))
        await ds.close()
    }
}
```

If `ProjectRegistry.register`'s exact signature differs, mirror whatever `InboxToolsTests` does to register a project — that file is the freshest example. Reuse the `XCTAssertThrowsErrorAsync` helper (import from wherever Task 1 put it, or redeclare file-local).

- [ ] **Step 2: Run to verify compile failure.**

- [ ] **Step 3: Implement the tool**

Create `Maugham/MCP/Tools/MoveResearchItemTool.swift`:

```swift
import Foundation

/// `move_research_item(project_id, research_ids, target | target_group_id |
/// target_document_id)` — move research items (including whole groups)
/// between shared research, a research group, and a collection piece's
/// research folder. Exactly one target must be given; unknown ids fail
/// loudly. Cross-scope moves clean up explicit links (into a piece: the
/// now-redundant link is dropped; out of a piece: an explicit link is added
/// so the association survives).
public enum MoveResearchItemTool: MCPTool {
    public static let method = "move_research_item"
    public static let description =
        "Move research items between shared research, a research group, and " +
        "a collection piece's research folder. research_ids accepts a batch. " +
        "Give exactly one of: target=\"shared\", target_group_id, or " +
        "target_document_id (a loose piece). Whole groups move with their contents."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"research_ids":{"type":"array","items":{"type":"string"}},"target":{"type":"string","enum":["shared"]},"target_group_id":{"type":"string"},"target_document_id":{"type":"string"}},"required":["project_id","research_ids"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let research_ids: [String]
        public let target: String?
        public let target_group_id: String?
        public let target_document_id: String?
    }
    public struct MovedItem: Codable, Equatable {
        public let id: String
        public let path: String?
    }
    public struct Result: Codable, Equatable {
        public let moved: [MovedItem]
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store

        var targets: [ResearchMoveTarget] = []
        if let t = params.target {
            guard t == "shared" else {
                throw MCPToolError.invalidParams("target must be \"shared\"")
            }
            targets.append(.sharedRoot)
        }
        if let gid = params.target_group_id { targets.append(.group(gid)) }
        if let did = params.target_document_id { targets.append(.piece(did)) }
        guard targets.count == 1 else {
            throw MCPToolError.invalidParams(
                "Give exactly one of target=\"shared\", target_group_id, target_document_id (got \(targets.count))")
        }
        guard !params.research_ids.isEmpty else {
            throw MCPToolError.invalidParams("research_ids must not be empty")
        }

        try await store.moveResearchItems(ids: params.research_ids, to: targets[0])

        let moved = params.research_ids.map { id in
            MovedItem(id: id,
                      path: TreeWalk.find(id: id, in: store.manifest.research)?.path)
        }
        return try JSONEncoder().encode(Result(moved: moved))
    }
}
```

Check the error type actually used by sibling tools for bad params (`grep -n "invalidParams\|MCPToolError" Maugham/MCP/Tools/InboxTools.swift`) and match it exactly. Add `import MaughamCore` if `TreeWalk` needs it.

- [ ] **Step 4: Register in the catalog**

In `Maugham/MCP/MCPTool.swift`, add `MoveResearchItemTool.self` to `MCPToolCatalog.all`, placed next to `LinkResearchTool`/`UnlinkResearchTool`.

- [ ] **Step 5: Fix the tool-count blast radius**

`grep -rn "47" MaughamTests/MCP Maugham/MCP | grep -v Tests/Tools` — update every count assertion/const to 48 (`MCPToolsListSmokeTest`, `MCPCatalogConsistencyTests`, `ListMaughamToolsToolTests`, and any snapshot list that enumerates method names — add `move_research_item`).

- [ ] **Step 6: Run MCP test surface**

Run: `xcodebuild ... -only-testing:MaughamTests/MCP`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Maugham/MCP/Tools/MoveResearchItemTool.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP
git commit -m "feat(mcp): move_research_item tool — batch scope moves for research (48 tools)"
```

---

### Task 11: Docs sweep + full verification

**Files:**
- Modify: `CLAUDE.md` (MCP area row: "**47 tools**" → "**48 tools**"), `Maugham/MCP/AREA.md` (tool list + count), `Maugham/Stores/AREA.md` (document the `ProjectStore+ResearchMove.swift` seam, `ResearchMoveTarget`, batch delete, and the collection-pane parity fix), `docs/roadmap.md` (flip/annotate any research-reorganisation line), spec status header.
- Check (grep, only edit if stale): `docs/guide/` topics that enumerate research features or MCP tools (`grep -rln "link_research\|promote_inbox_entry" docs/guide`), `docs/superpowers/notes/cross-surface-contracts.md` (no phone surface touched — expect no change).

- [ ] **Step 1: Make the doc edits above.** Follow workflow rule 10: every claim that this milestone made false gets fixed in this same commit. In `Maugham/Stores/AREA.md`, extend the typed-mover section: `moveResearchItems` is a fourth *routed caller* of `relocate(plan:)` (not a new entry point), and `ProjectStore+ResearchMove.swift` is in the tripwire grep census.

- [ ] **Step 2: Full verification**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```

Expected: both PASS (phone run is belt-and-braces; no MaughamCore change should exist in the branch diff — verify with `git diff main --stat -- Packages/MaughamCore`).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md Maugham/MCP/AREA.md Maugham/Stores/AREA.md docs
git commit -m "docs: research-restructuring sweep — 48 MCP tools, ResearchMove seam, pane parity"
```

- [ ] **Step 4: Whole-branch review** (workflow rule 9) — one review of the full branch diff before merge; per-task reviews can't see emergent interactions. Then hand to the user for manual smoke:

Manual smoke script (user-run): collection → create group in Shared → drag note onto group → disclosure shows it → multiselect 3 items (⌘-click) → right-click → Move to → piece → files under `pieces/<NN>-<slug>/research/`, right pane Piece Research shows them → drag one back to Shared header → returns to `research/`, piece's Linked Research lists it → `move_research_item` from Claude Desktop on the dev socket → tools-list shows 48.
