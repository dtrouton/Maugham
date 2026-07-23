# Sweep-Hardening 2026-07-23 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 10 findings (W1–W10) from the 2026-07-19 weekly maintenance sweep (`docs/superpowers/notes/2026-07-19-sweep.md`): research-move durability (W1/W2/W5), selection hygiene (W6/W7), doc-truth (W3), and skills hardening (W4/W8/W9/W10).

**Architecture:** Three seams. (1) `DocumentStore.relocate` gains best-effort rollback-on-throw so a mid-plan failure can no longer strand files; `moveResearchItems` gains joint note+assets dedup and a compiler-enforced non-throwing cosmetic ref-rewrite. (2) `ResearchSelectionSync` gains a pure `pruned` helper wired into both research surfaces after delete. (3) `ClaudeCodeSkillInstall` gains an ownership marker + `.userModified` state with confirm-before-overwrite; `SkillsExtension` gets a defensive `files.first` guard; the setup sheet gets socket parity + copy-button reset.

**Tech Stack:** Swift / SwiftUI / XCTest. Mac target only (no MaughamCore/phone source changes except none — `TreeWalk` is consumed, not modified).

## Global Constraints

- Build: `./gen.sh` only if `project.yml` changes (it doesn't — all files exist or are new test files, which xcodegen globs; **new test files DO require `./gen.sh`** since the project is generated — run it after creating any new file).
- Test (Mac): `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` — narrow with `-only-testing:MaughamTests/<ClassName>` (class name, NOT folder path — folder paths run 0 tests, translation-layer lesson).
- Phone scheme untouched by this plan; run once in final verification.
- Tripwire 14: all user-content FS surgery stays inside `DocumentStore.relocate`/`relocateUserContent`/`trash` — this plan modifies `relocate` internals but adds no new raw moves.
- Tripwire 20 (ADR 0018): any new `String(contentsOf:)` on research notes needs `// adr-0018-ok: research-note read, not manuscript`.
- Working branch: `feat/sweep-hardening-2026-07` off `main`.
- Commit per task, message style: `fix(scope): summary (Wn)`.

---

### Task 1: W5 — `DocumentStore.relocate` rollback-on-throw

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift:506-553` (the `relocate(plan:)` body)
- Create: `MaughamTests/DocumentStoreRelocateRollbackTests.swift`

**Interfaces:**
- Consumes: existing `coordinatedMove(from:to:)`, `RenamePlan.scratchSteps`/`.directSteps`.
- Produces: `relocate(plan:)` signature unchanged; new behavior: on throw, all completed moves are unwound (best-effort) before rethrow. Task 2's W2 test relies on this only indirectly (W2 prevents the throw); no cross-task types.

- [ ] **Step 1: Write the failing test**

New file `MaughamTests/DocumentStoreRelocateRollbackTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentStoreRelocateRollbackTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// W5: a mid-plan throw must unwind already-completed moves so files are
    /// back at their manifest paths (the caller never saves the manifest on
    /// throw), not stranded half-moved or in `.maugham/scratch/`.
    func test_relocate_midPlanFailure_rollsBackCompletedSteps() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Roll", in: temp.url)
        let fm = FileManager.default
        let research = url.appendingPathComponent("research")
        try fm.createDirectory(at: research, withIntermediateDirectories: true)
        try "A".write(to: research.appendingPathComponent("a.md"),
                      atomically: true, encoding: .utf8)
        try "B".write(to: research.appendingPathComponent("b.md"),
                      atomically: true, encoding: .utf8)
        // Blocker: the second step's destination already exists on disk and
        // is NOT a plan source, so coordinatedMove throws mid-plan.
        try "X".write(to: research.appendingPathComponent("blocked.md"),
                      atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "research/a.md",
                  newRelativePath: "research/moved-a.md"),
            .init(oldRelativePath: "research/b.md",
                  newRelativePath: "research/blocked.md"),
        ])
        do {
            try await store.relocate(plan: plan)
            XCTFail("expected the blocked destination to throw")
        } catch {}

        XCTAssertTrue(fm.fileExists(atPath: research.appendingPathComponent("a.md").path),
                      "completed step must be unwound")
        XCTAssertFalse(fm.fileExists(atPath: research.appendingPathComponent("moved-a.md").path))
        XCTAssertTrue(fm.fileExists(atPath: research.appendingPathComponent("b.md").path))
        XCTAssertEqual(try String(contentsOf: research.appendingPathComponent("blocked.md"),
                                  encoding: .utf8), "X")
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathComponent(".maugham/scratch").path),
                       "no scratch leftovers")
        await store.close()
    }
}
```

If `RenamePlan.Step`'s init labels differ, mirror `ProjectStore+ResearchMove.swift:201`. If `coordinatedMove` turns out NOT to throw on an existing destination (verify — the sweep confirmed it does), stop and report rather than reshaping the test.

- [ ] **Step 2: `./gen.sh`, run test, verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DocumentStoreRelocateRollbackTests`
Expected: FAIL — `a.md` was not restored (current code leaves `moved-a.md` in place).

- [ ] **Step 3: Implement rollback in `relocate(plan:)`**

Replace the body from `let scratchDir =` down through the final scratch-cleanup block (keep the `closeFlushAndUnregister` call and all existing comments above it) with:

```swift
        let scratchDir = projectURL.appendingPathComponent(".maugham/scratch")
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)

        // Every completed move in execution order, so a mid-plan throw can
        // unwind: a half-executed plan otherwise strands files at new paths
        // (or in scratch) while the caller's manifest rewrite — Phase 3 —
        // never runs (2026-07-19 sweep W5).
        var completed: [(from: URL, to: URL)] = []
        defer {
            // Best-effort cleanup of empty scratch dir (both exit paths).
            if let contents = try? FileManager.default
                .contentsOfDirectory(atPath: scratchDir.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: scratchDir)
            }
        }
        do {
            // Phase 1: move colliding items to scratch with unique names.
            var scratchMap: [(scratchURL: URL, finalRelativePath: String)] = []
            for step in plan.scratchSteps {
                let oldURL = projectURL.appendingPathComponent(step.oldRelativePath)
                let scratchURL = scratchDir.appendingPathComponent(UUID().uuidString)
                try await coordinatedMove(from: oldURL, to: scratchURL)
                completed.append((oldURL, scratchURL))
                scratchMap.append((scratchURL, step.newRelativePath))
            }

            // Phase 2a: direct (non-colliding) renames.
            for step in plan.directSteps {
                let oldURL = projectURL.appendingPathComponent(step.oldRelativePath)
                let newURL = projectURL.appendingPathComponent(step.newRelativePath)
                try await coordinatedMove(from: oldURL, to: newURL)
                completed.append((oldURL, newURL))
            }

            // Phase 2b: scratch items to final destinations.
            for entry in scratchMap {
                let finalURL = projectURL.appendingPathComponent(entry.finalRelativePath)
                try await coordinatedMove(from: entry.scratchURL, to: finalURL)
                completed.append((entry.scratchURL, finalURL))
            }
        } catch {
            // Unwind in reverse, best-effort — a file the unwind can't
            // restore is no worse off than before this change.
            for (from, to) in completed.reversed() {
                try? await coordinatedMove(from: to, to: from)
            }
            throw error
        }

        // Phase 3: caller saves the manifest.
```

- [ ] **Step 4: Run the new test + the neighboring relocate consumers**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DocumentStoreRelocateRollbackTests -only-testing:MaughamTests/ResearchMoveTests -only-testing:MaughamTests/RenamePlanTests -only-testing:MaughamTests/RenameWithAssetsTests`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift MaughamTests/DocumentStoreRelocateRollbackTests.swift
git commit -m "fix(stores): relocate unwinds completed moves on mid-plan throw (W5)"
```

---

### Task 2: W1+W2 — research-move durability (joint dedup + best-effort ref-rewrite)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+ResearchMove.swift:194-247` (Phase 2 dedup + Phase 3 rewrite loop)
- Test: `MaughamTests/ResearchMoveTests.swift` (append tests)

**Interfaces:**
- Consumes: `ProjectStore.researchDedupedFilename(_:existing:)` (`ProjectStore+Research.swift:247`), `DocumentStore.coordinatedWrite(text:to:)`.
- Produces: `static func researchDedupedNotePair(_ name: String, taken: Set<String>) -> String` and `static func rewriteAssetRefsBestEffort(oldStem:newStem:noteURL:write:) async` (NON-throwing — the signature is the W1 pin) on `ProjectStore`. No later task consumes them.

- [ ] **Step 1: Write the failing tests** (append to `ResearchMoveTests`)

```swift
    // MARK: 2026-07-19 sweep W1/W2 — failure-path durability

    /// W2: an orphaned `<stem>_assets/` at the destination (no matching note)
    /// used to collide mid-relocate — the note + assets pair must dedup jointly.
    func test_move_orphanAssetsAtDestination_dedupesNoteAndAssetsJointly() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        // The note owns an assets folder + a relative image ref.
        let assetsURL = url.appendingPathComponent("research/sarah_assets")
        try FileManager.default.createDirectory(
            at: assetsURL, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assetsURL.appendingPathComponent("img.png"))
        try await ds.coordinatedWrite(
            text: "![img](./sarah_assets/img.png)",
            to: url.appendingPathComponent("research/sarah.md"))
        // Destination piece research holds an ORPHANED sarah_assets (no sarah.md).
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(prefix).appendingPathComponent("sarah_assets"),
            withIntermediateDirectories: true)

        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertTrue(moved.path!.hasSuffix("sarah-2.md"), "got \(moved.path!)")
        let destFolder = (moved.path! as NSString).deletingLastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("\(destFolder)/sarah-2_assets/img.png").path),
            "assets folder must travel under the deduped stem")
        let content = try String(  // adr-0018-ok: research-note read, not manuscript
            contentsOf: url.appendingPathComponent(moved.path!), encoding: .utf8)
        XCTAssertTrue(content.contains("./sarah-2_assets/"), "refs rewritten: \(content)")
        await ds.close()
    }

    /// W2 unit: joint dedup must skip a stem whose `_assets` sibling is taken
    /// even when the note leaf itself is free.
    func test_researchDedupedNotePair_avoidsTakenAssetsSibling() {
        XCTAssertEqual(
            ProjectStore.researchDedupedNotePair("sarah.md", taken: ["sarah_assets"]),
            "sarah-2.md")
        XCTAssertEqual(
            ProjectStore.researchDedupedNotePair("sarah.md", taken: []),
            "sarah.md")
        XCTAssertEqual(
            ProjectStore.researchDedupedNotePair(
                "sarah.md", taken: ["sarah.md", "sarah-2_assets"]),
            "sarah-3.md")
    }

    /// W1: the post-relocate image-ref rewrite is cosmetic — a write failure
    /// must NOT throw (the FS move already committed; the manifest rewrite
    /// that follows must always run). The non-throwing signature is the pin.
    func test_rewriteAssetRefsBestEffort_swallowsWriteFailure() async throws {
        let noteURL = temp.url.appendingPathComponent("w1.md")
        try "![i](./old_assets/i.png)".write(
            to: noteURL, atomically: true, encoding: .utf8)
        struct Boom: Error {}
        await ProjectStore.rewriteAssetRefsBestEffort(
            oldStem: "old", newStem: "new", noteURL: noteURL,
            write: { _, _ in throw Boom() })
        // No throw reached here; file keeps old refs (stale ref, intact move).
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8),
                       "![i](./old_assets/i.png)")
    }

    /// W1 happy path through the same helper.
    func test_rewriteAssetRefsBestEffort_rewritesViaWriter() async throws {
        let noteURL = temp.url.appendingPathComponent("w1b.md")
        try "![i](./old_assets/i.png)".write(
            to: noteURL, atomically: true, encoding: .utf8)
        var written: String?
        await ProjectStore.rewriteAssetRefsBestEffort(
            oldStem: "old", newStem: "new", noteURL: noteURL,
            write: { text, _ in written = text })
        XCTAssertEqual(written, "![i](./new_assets/i.png)")
    }
```

(`pieceResearchPrefix` usage mirrors `test_sharedNote_toPiece_movesFileAndRewritesPath`; adjust the `prefix` path join if it carries a trailing slash.)

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild … -only-testing:MaughamTests/ResearchMoveTests`
Expected: FAIL — `researchDedupedNotePair` / `rewriteAssetRefsBestEffort` don't compile yet. (Comment out the two helper-based tests if you want to see the orphan-assets test fail at runtime first — it should throw mid-relocate today; with Task 1 merged the rollback makes it fail on the `sarah-2.md` assertion instead.)

- [ ] **Step 3: Implement in `ProjectStore+ResearchMove.swift`**

Add two helpers at the bottom of the `extension ProjectStore` block:

```swift
    /// Dedup a note leaf JOINTLY with its sibling `<stem>_assets` folder: the
    /// chosen stem must be free for BOTH names. An orphaned `<stem>_assets`
    /// at the destination with no matching note otherwise collides
    /// mid-relocate (2026-07-19 sweep W2).
    static func researchDedupedNotePair(
        _ name: String, taken: Set<String>
    ) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func leaf(_ s: String) -> String { ext.isEmpty ? s : "\(s).\(ext)" }
        if !taken.contains(leaf(stem)), !taken.contains("\(stem)_assets") {
            return leaf(stem)
        }
        for n in 2...999 {
            let candidate = "\(stem)-\(n)"
            if !taken.contains(leaf(candidate)),
               !taken.contains("\(candidate)_assets") {
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
```

In Phase 2, replace lines 197-221 (from `let dedupedLeaf =` through the end of the assets `if` block) with:

```swift
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
                ? Self.researchDedupedNotePair(leaf, taken: taken)
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
```

In Phase 3, replace the rewrite loop body (lines 235-246) with:

```swift
            for pending in pendings {
                guard let (oldStem, newStem, noteRelPath) = pending.refRewrite else { continue }
                await Self.rewriteAssetRefsBestEffort(
                    oldStem: oldStem, newStem: newStem,
                    noteURL: url.appendingPathComponent(noteRelPath),
                    write: { try await documentStore.coordinatedWrite(text: $0, to: $1) })
            }
```

(`documentStore` is already unwrapped by the `guard let documentStore` above the `relocate` call.)

- [ ] **Step 4: Run tests, verify pass**

Run: `xcodebuild … -only-testing:MaughamTests/ResearchMoveTests -only-testing:MaughamTests/RenameWithAssetsTests -only-testing:MaughamTests/RenameResearchItemTests`
Expected: ALL PASS (including all pre-existing move tests — the happy-path dedup behavior for non-asset items is unchanged: same `existingNames + claimed` universe).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+ResearchMove.swift MaughamTests/ResearchMoveTests.swift
git commit -m "fix(stores): joint note+assets dedup, best-effort ref-rewrite in moveResearchItems (W1, W2)"
```

---

### Task 3: W6+W7 — selection pruning + TreeWalk reuse

**Files:**
- Modify: `Maugham/Views/ResearchTree.swift:119-131` (`orderedSelection`), plus add `pruned` to `ResearchSelectionSync`
- Modify: `Maugham/Views/ResearchView.swift` (`delete(id:)` at :280-286, `deleteMany` closure at :126-129)
- Modify: `Maugham/Views/CollectionResearchPane.swift` (its `delete`/`deleteMany` equivalents near :261-263 and its single-delete func)
- Test: `MaughamTests/ResearchSelectionTests.swift` (append)

**Interfaces:**
- Consumes: `TreeWalk.collect(in:where:)` / `TreeWalk.collectIds(in:)` / `TreeWalk.find(id:in:)` (MaughamCore `TreeNode.swift`).
- Produces: `ResearchSelectionSync.pruned(_ selection: Set<String>, in research: [ResearchItem]) -> Set<String>`.

- [ ] **Step 1: Write the failing test** (append to `ResearchSelectionTests`, mirroring its existing fixture style — read the file first)

```swift
    /// W6: ids deleted from the manifest must drop out of the selection so
    /// `previewId(for:)` can't resolve to a ghost item.
    func test_pruned_dropsStaleIds_keepsLive() {
        let research = [
            ResearchItem stub matching this file's existing fixture builder — e.g. two items with ids "a" and "b"
        ]
        let pruned = ResearchSelectionSync.pruned(["a", "gone"], in: research)
        XCTAssertEqual(pruned, ["a"])
    }
```

Use the file's existing item-construction helper verbatim (it already builds `ResearchItem` values for `orderedSelection` tests) — do not invent a new fixture shape.

- [ ] **Step 2: Run, verify it fails to compile** (`pruned` undefined)

Run: `xcodebuild … -only-testing:MaughamTests/ResearchSelectionTests`

- [ ] **Step 3: Implement**

In `ResearchSelectionSync` (ResearchTree.swift), replace `orderedSelection`'s hand-rolled `walk` (W7) and add `pruned` (W6):

```swift
    /// Selection ordered by depth-first manifest tree position (visual order).
    static func orderedSelection(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        TreeWalk.collect(in: research, where: { selection.contains($0.id) })
            .map(\.id)
    }

    /// Selection with ids that no longer exist in `research` dropped —
    /// post-delete hygiene (2026-07-19 sweep W6): a stale id left behind
    /// drives `previewId(for:)` to a ghost item in the single-preview pane.
    static func pruned(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> Set<String> {
        selection.intersection(TreeWalk.collectIds(in: research))
    }
```

In **both** `ResearchView.swift` and `CollectionResearchPane.swift`, add a private helper and call it after every successful delete (single `delete(id:)` and the `deleteMany` closure):

```swift
    private func pruneSelectionAfterDelete() {
        selection = ResearchSelectionSync.pruned(
            selection, in: store.manifest.research)
        if let sel = selectedResearchId,
           TreeWalk.find(id: sel, in: store.manifest.research) == nil {
            selectedResearchId = nil
        }
    }
```

e.g. in `ResearchView.delete(id:)`:

```swift
    private func delete(id: String) async {
        do {
            try await store.deleteResearchItem(id: id)
            pruneSelectionAfterDelete()
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

and in the `deleteMany` action closure, after `try await store.deleteResearchItems(ids: ids)` add `pruneSelectionAfterDelete()`. Mirror in `CollectionResearchPane` (it uses `store` for the collection's `ProjectStore` — match its actual property name when editing).

- [ ] **Step 4: Run tests**

Run: `xcodebuild … -only-testing:MaughamTests/ResearchSelectionTests`
Expected: ALL PASS (existing `orderedSelection` tests pin the W7 refactor's order-preservation).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/ResearchTree.swift Maugham/Views/ResearchView.swift Maugham/Views/CollectionResearchPane.swift MaughamTests/ResearchSelectionTests.swift
git commit -m "fix(views): prune research selection after delete; orderedSelection via TreeWalk (W6, W7)"
```

---

### Task 4: W3 — link-mechanism doc-drift rewrite ×3

**Files:**
- Modify: `Maugham/MCP/AREA.md:34`
- Modify: `Maugham/MCP/Tools/MoveResearchItemTool.swift:4-10` (header doc-comment)
- Modify: `Maugham/Views/CollectionResearchPane.swift:449` (drop the stale parenthetical)

**Interfaces:** none (prose only). Do NOT touch AREA.md's `## Tool catalogue (NN)` heading — `DocSyncTests` parses it.

- [ ] **Step 1: Rewrite all three sites**

`Maugham/MCP/AREA.md:34` — replace the sentence
`Cross-scope moves clean up explicit links both directions (into a piece drops the now-redundant link; out of a piece adds one back so the association survives).`
with:
`Cross-scope moves leave explicit links ('linkedResearchIds') untouched — association is containment-based (2026-07-17): a manual link goes dormant while the item lives in a piece's research and resurfaces on move-out; a containment-only association severs on move-out with no auto-link minted.`

`MoveResearchItemTool.swift` header — replace
`Exactly one target must be given; unknown ids fail loudly. Cross-scope moves clean up explicit links (into a piece: the now-redundant link is dropped; out of a piece: an explicit link is added so the association survives). Wraps ProjectStore.moveResearchItems.`
with:
`Exactly one target must be given; unknown ids fail loudly. Cross-scope moves never touch explicit links — association is containment-based: a manual link goes dormant while contained and resurfaces on move-out; a containment-only association severs on move-out (see the Phase 4 comment in ProjectStore+ResearchMove.swift). Wraps ProjectStore.moveResearchItems.`

`CollectionResearchPane.swift:449` — replace the parenthetical `(Task 3 also cleans up any now-orphaned links)` with `(links are untouched — association is containment-based; see ProjectStore+ResearchMove)`.

- [ ] **Step 2: Sweep for any fourth copy**

Run: `grep -rn "now-redundant link\|adds one back\|now-orphaned links" Maugham MaughamPhone Packages docs --include="*.swift" --include="*.md" | grep -v "2026-07-19-sweep\|superpowers/plans"`
Expected: no hits.

- [ ] **Step 3: Run DocSync + build**

Run: `xcodebuild … -only-testing:MaughamTests/DocSyncTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Maugham/MCP/AREA.md Maugham/MCP/Tools/MoveResearchItemTool.swift Maugham/Views/CollectionResearchPane.swift
git commit -m "docs(mcp): move_research_item prose describes containment-based association (W3)"
```

---

### Task 5: W4 — skill-install ownership marker + confirm-before-overwrite

**Files:**
- Modify: `docs/skills/maugham-bootstrap/SKILL.md` (append marker)
- Modify: `Maugham/MCP/ClaudeCodeSkillInstall.swift`
- Modify: `Maugham/Views/HelpClaudeDesktopSheet.swift` (`claudeCodeSkillControls` + new confirm state)
- Test: `MaughamTests/ClaudeCodeSkillInstallTests.swift`

**Interfaces:**
- Produces: `ClaudeCodeSkillInstall.State.userModified` (new case), `ClaudeCodeSkillInstall.managedMarker: String`. The sheet's `switch skillState` must handle the new case (compiler-enforced).

- [ ] **Step 1: Update + add tests**

In `ClaudeCodeSkillInstallTests.swift`:
- Rewrite `test_userEditedFile_readsAsStale_installOverwritesOnlyOnExplicitCall` → rename to `test_userEditedFile_readsAsUserModified_detectNeverWrites`, expecting `.userModified` for the marker-less edited file.
- In `test_install_thenCurrent_thenStale_thenUpdateRestores`, change the templates to carry the marker (as the real template now does): `let t1 = "T v1\n\(ClaudeCodeSkillInstall.managedMarker) -->"`, `let t2 = "T v2\n\(ClaudeCodeSkillInstall.managedMarker) -->"` and use them throughout; the stale expectation stands.
- Add:

```swift
    func test_detect_markerDistinguishesStaleFromUserModified() throws {
        let marked = "T v1\n\(ClaudeCodeSkillInstall.managedMarker) -->"
        let newer  = "T v2\n\(ClaudeCodeSkillInstall.managedMarker) -->"
        try ClaudeCodeSkillInstall.install(installURL: url, template: marked)
        // App update ships a new template: file still Maugham-managed → stale.
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: newer), .stale)
        // A hand-authored file without the marker must not be silently clobberable.
        try "my own skill".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeCodeSkillInstall.detect(installURL: url, template: newer), .userModified)
    }

    /// The real bundled template must carry the marker, or every install
    /// would classify as userModified forever. Repo-relative read, same
    /// technique as DocSyncTests (copy its repo-root discovery).
    func test_bundledBootstrapTemplate_carriesManagedMarker() throws {
        // Derive repo root from #filePath as DocSyncTests does.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
        let template = try String(contentsOf: repoRoot
            .appendingPathComponent("docs/skills/maugham-bootstrap/SKILL.md"),
            encoding: .utf8)
        XCTAssertTrue(template.contains(ClaudeCodeSkillInstall.managedMarker))
    }
```

(Before writing the repo-root test, check how `DocSyncTests` locates repo files and copy that exact technique.)

- [ ] **Step 2: Run, verify failure** (`managedMarker`/`.userModified` undefined)

Run: `xcodebuild … -only-testing:MaughamTests/ClaudeCodeSkillInstallTests`

- [ ] **Step 3: Implement**

`docs/skills/maugham-bootstrap/SKILL.md` — append as final line (after the existing body, blank line before):

```
<!-- maugham:managed — installed by Maugham. Hand edits are replaced when you click Update in Maugham's Claude setup sheet. -->
```

`ClaudeCodeSkillInstall.swift`:

```swift
    public enum State: Equatable {
        case notInstalled
        case installedCurrent
        /// Maugham-managed (carries the marker) but not byte-identical to
        /// the current template — an older install; safe to overwrite.
        case stale
        /// Diverged AND missing the managed marker — hand-edited or foreign.
        /// Never overwrite without explicit confirmation (2026-07-19 sweep W4).
        case userModified
    }

    /// Ownership sentinel baked into the bundled template (and therefore
    /// into every Maugham-written install). A file without it is treated as
    /// the user's, not ours. Prefix-matched so the human-readable suffix in
    /// the template can evolve without a state change.
    public static let managedMarker = "<!-- maugham:managed"

    public static func detect(installURL: URL, template: String) -> State {
        guard let installed = try? String(contentsOf: installURL, encoding: .utf8) else {  // adr-0018-ok: app-config read, not manuscript
            return .notInstalled
        }
        if installed == template { return .installedCurrent }
        return installed.contains(managedMarker) ? .stale : .userModified
    }
```

`HelpClaudeDesktopSheet.swift` — add `@State private var confirmingSkillReplace = false`; extend the switch:

```swift
        case .userModified:
            HStack {
                Label("Maugham skill has local edits", systemImage: "pencil")
                Button("Replace…") { confirmingSkillReplace = true }
            }
            Text("The installed skill file differs from Maugham's template and doesn't carry the Maugham-managed marker. Replacing discards those edits.")
                .font(.callout).foregroundStyle(.secondary)
```

and attach to `claudeCodeSection`:

```swift
        .confirmationDialog(
            "Replace the installed Maugham skill?",
            isPresented: $confirmingSkillReplace) {
            Button("Replace", role: .destructive) { installSkill() }
        } message: {
            Text("Hand edits to \(ClaudeCodeSkillInstall.defaultSkillURL.path) will be lost.")
        }
```

Note: pre-marker installs (≤ v0.24.x) lack the marker, so their next update shows one extra confirmation — deliberate conservatism; mention in the PR body.

- [ ] **Step 4: Run tests + SkillIndexTests (template file changed)**

Run: `xcodebuild … -only-testing:MaughamTests/ClaudeCodeSkillInstallTests -only-testing:MaughamTests/SkillIndexTests -only-testing:MaughamTests/SkillsExtensionTests`
Expected: ALL PASS (bootstrap template is not served over SEP-2640, so digests/shape tests are unaffected; if one pins the bootstrap body, update it).

- [ ] **Step 5: Commit**

```bash
git add docs/skills/maugham-bootstrap/SKILL.md Maugham/MCP/ClaudeCodeSkillInstall.swift Maugham/Views/HelpClaudeDesktopSheet.swift MaughamTests/ClaudeCodeSkillInstallTests.swift
git commit -m "fix(mcp): managed marker + confirm-before-overwrite for the Claude Code skill install (W4)"
```

---

### Task 6: W8 — defensive `files.first` guard in skills/list

**Files:**
- Modify: `Maugham/MCP/SkillsExtension.swift:44-58` (`handleList`)
- Modify: `Maugham/Help/SkillIndex.swift:44` (widen `private init(skills:bootstrapTemplate:)` to internal)
- Test: `MaughamTests/MCP/SkillsExtensionTests.swift`

- [ ] **Step 1: Write the failing test** (append to `SkillsExtensionTests`)

```swift
    /// W8: a skill with no files can serve nothing — skip it rather than
    /// crash on `files[0]`. Unreachable for the static bundle; defensive.
    func test_list_skipsSkillWithNoFiles_defensive() throws {
        let ghost = SkillIndex.Skill(
            name: "ghost", description: "d", body: "",
            raw: "---\nname: ghost\ndescription: d\n---\n", files: [])
        let index = SkillIndex(skills: [ghost], bootstrapTemplate: nil)
        let obj = try json(try SkillsExtension.handleList(paramsJSON: nil, index: index))
        XCTAssertEqual((obj["skills"] as? [[String: Any]])?.count, 0)
    }
```

- [ ] **Step 2: Run, verify it fails to compile** (private init)

- [ ] **Step 3: Implement**

`SkillIndex.swift`: change `private init(skills: [Skill], bootstrapTemplate: Skill?)` to `init(skills: [Skill], bootstrapTemplate: Skill?)` with comment `/// Internal (not private) so tests can assemble synthetic indexes.`

`SkillsExtension.handleList`: change `map` to `compactMap` and guard:

```swift
        let entries: [[String: Any]] = index.skills.compactMap { skill in
            // A skill with no files can serve nothing — skip rather than
            // crash the request (2026-07-19 sweep W8; unreachable for the
            // static bundle, defensive for future dynamic sources).
            guard let primary = skill.files.first else { return nil }
            let (frontmatter, _) = (try? SkillIndex.parseFrontmatter(
                skill.raw, folderName: skill.name)) ?? ([:], "")
            return [
                "name": skill.name,
                "description": skill.description,
                "uri": uri(for: skill, file: primary),
                "frontmatter": frontmatter,
                "resources": skill.files.map { file in
                    ["uri": uri(for: skill, file: file),
                     "digest": "sha256:\(file.sha256Hex)"]
                },
            ]
        }
```

- [ ] **Step 4: Run** `-only-testing:MaughamTests/SkillsExtensionTests` — ALL PASS

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/SkillsExtension.swift Maugham/Help/SkillIndex.swift MaughamTests/MCP/SkillsExtensionTests.swift
git commit -m "fix(mcp): skills/list skips a file-less skill instead of crashing (W8)"
```

---

### Task 7: W9+W10 — setup-sheet socket parity + copy-button reset

**Files:**
- Modify: `Maugham/Views/HelpClaudeDesktopSheet.swift:64-71` (`claudeCodeCLICommand`) and `:93-97` (copy button)

- [ ] **Step 1: Implement both** (UI wiring; `cliCommand`'s nil/space-quoting behavior already unit-tested — no new tests)

W9 — always pass the socket, matching the Desktop JSON snippet:

```swift
    private var claudeCodeCLICommand: String {
        // Parity with the Desktop JSON snippet (which always sets
        // MAUGHAM_MCP_SOCKET): don't rely on the binary's compiled-in
        // default matching the app's variant (2026-07-19 sweep W9).
        ClaudeCodeSkillInstall.cliCommand(
            serverKey: BuildVariant.current.mcpServerKey,
            binaryPath: binaryPath,
            socketPath: BuildVariant.current.mcpSocketPath)
    }
```

W10 — mirror the Desktop copy button's 2s reset:

```swift
            Button(cliCopied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(claudeCodeCLICommand, forType: .string)
                cliCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    cliCopied = false
                }
            }
```

- [ ] **Step 2: Build** — `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO` — succeeds.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/HelpClaudeDesktopSheet.swift
git commit -m "fix(views): CLI snippet always sets MAUGHAM_MCP_SOCKET; Copy button resets (W9, W10)"
```

---

### Task 8: Final verification

- [ ] Full Mac suite: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` — green.
- [ ] Phone suite (safety; no phone/Core source touched): `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO` — green (re-run once on simulator "Busy" flake).
- [ ] Whole-branch review of `git diff main...feat/sweep-hardening-2026-07` (default workflow #9 — emergent-interaction check; watch the Task 1 × Task 2 seam: rollback + joint dedup both touch mid-relocate failure paths).
- [ ] PR to `main` titled `Sweep hardening 2026-07-23 — W1–W10 from the 2026-07-19 maintenance sweep`, body listing each finding → fix, noting the W4 one-extra-confirm migration effect for pre-marker installs.

## Self-Review (done at plan time)

- Coverage: W1(T2) W2(T2) W3(T4) W4(T5) W5(T1) W6(T3) W7(T3) W8(T6) W9(T7) W10(T7) — all 10 scheduled, matching the sweep's binary triage.
- Types consistent: `researchDedupedNotePair(_:taken:)`, `rewriteAssetRefsBestEffort(oldStem:newStem:noteURL:write:)`, `ResearchSelectionSync.pruned(_:in:)`, `ClaudeCodeSkillInstall.managedMarker`/`.userModified` used identically across tasks.
- Known judgment calls the implementer may hit: `pieceResearchPrefix` trailing-slash join (T2 test), `ResearchSelectionTests` fixture shape (T3 test — read the file), DocSyncTests repo-root technique (T5 test — read the file first).
