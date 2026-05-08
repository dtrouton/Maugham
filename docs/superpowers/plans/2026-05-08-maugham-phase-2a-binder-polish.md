# Maugham Phase 2a — Binder Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full-fidelity binder editing. Drag any item (document or group) to any new position — within siblings, into a different group, or out to root — and the filesystem keeps in lockstep through coordinated multi-file rename. Right-click adds **Duplicate** (with `"Copy of "` prefix). Right-click on a group adds **Tidy Filenames**; a project-wide **Tidy All Filenames** does the same recursively.

**Architecture:** Pure-logic foundations land first: `RenamePlan` (encodes a multi-file-rename batch with collision detection) and `DropIntent` (computes whether a drop is reorder-above / reorder-below / re-parent-into). Then `ProjectStore` mutators that use these primitives: `moveStructureItem`, `duplicateStructureItem`, `tidyFilenames`. Each routes filesystem ops through `DocumentStore` (NSFileCoordinator-coordinated, scratch-swap pattern for colliding renames). Then UI: `BinderRow` becomes draggable + drop destination; `BinderView` wires drag intent to `moveStructureItem`, gains Duplicate + Tidy context-menu items, and `MaughamApp` adds a File menu Tidy All Filenames command.

**Tech Stack:** Swift 5.10+, SwiftUI (`.draggable`, `.dropDestination(for:String.self)`, `.confirmationDialog`), AppKit (NSFileCoordinator), Foundation (`FileManager.copyItem`, `moveItem`), XCTest. macOS 14+.

**Anchor:** This plan implements `docs/superpowers/specs/2026-05-08-maugham-phase-2a-binder-polish-design.md`.

**Execution branch:** `feat/phase-2a-binder-polish` (created in Task 1; merge to main on milestone tag).

---

## Locked decisions (from brainstorm)

1. Drag-reorder is **siblings + cross-group** (full Scrivener-equivalent reorder). Drop intent computed from drop position thirds.
2. Tidy Filenames is **per-group right-click** + **project-wide File menu command**. **Never automatic.**
3. Duplicate produces **`"Copy of <title>"`** with **inline rename mode active immediately**.
4. Multi-file rename safety via **scratch directory** at `.maugham/scratch/<uuid>` (not system temp dir — stays on volume, in presenter's purview, recoverable on crash).
5. **No auto-recovery** of stragglers in `.maugham/scratch/` after a crash; just **log on `DocumentStore.open`**.

---

## File structure (created or modified during this plan)

```
Maugham/Stores/
  RenamePlan.swift                    # NEW — value type + validator for multi-file-rename batches
  ProjectStore.swift                  # MODIFIED — adds moveStructureItem, duplicateStructureItem, tidyFilenames, tidyAllFilenames
  DocumentStore.swift                 # MODIFIED — adds executeRenamePlan + scratch-stragglers log on open

Maugham/Views/
  DropIntent.swift                    # NEW — pure-logic enum + classifier for binder drop intent
  BinderRow.swift                     # MODIFIED — .draggable(item.id) + .dropDestination(for: String.self)
  BinderView.swift                    # MODIFIED — drag/drop wiring + Duplicate + Tidy context menu items + Tidy alert
  ProjectWindow.swift                 # MODIFIED — listen for maughamTidyAllFilenames notification + alert

Maugham/MaughamApp.swift              # MODIFIED — File menu adds "Tidy All Filenames"
Maugham/Models/MaughamNotifications.swift  # MODIFIED — adds maughamTidyAllFilenames

MaughamTests/
  RenamePlanTests.swift               # NEW (unit, ~6 tests)
  DropIntentTests.swift               # NEW (unit, ~5 tests)
  ProjectStoreReorderTests.swift      # NEW (~5 integration tests)
  ProjectStoreDuplicateTests.swift    # NEW (~4 integration tests)
  ProjectStoreTidyTests.swift         # NEW (~4 integration tests)
```

3 new main-target files, 5 new test files, 5 modified main files. **Estimate: 14 tasks** for execution.

---

## Task 1: Create feature branch

**Working directory:** `/Users/denver/src/Maugham`

- [ ] **Step 1: Confirm clean main and create branch**

```bash
git status
git log --oneline -3
git checkout -b feat/phase-2a-binder-polish
```

Expected: working tree clean, latest commit on main is the 2a spec push (`6adbfda Add phase 2a binder polish design spec`). Branch creation prints `Switched to a new branch 'feat/phase-2a-binder-polish'`.

No commit for this task.

---

## Task 2: RenamePlan

**Files:**
- Create: `Maugham/Stores/RenamePlan.swift`
- Create: `MaughamTests/RenamePlanTests.swift`

The core primitive. Encodes a set of (oldRelativePath → newRelativePath) renames; validates them; classifies which need scratch-swap due to path collisions.

- [ ] **Step 1: Write failing tests**

`MaughamTests/RenamePlanTests.swift`:
```swift
import XCTest
@testable import Maugham

final class RenamePlanTests: XCTestCase {

    func test_emptyPlan_isValid_andHasNoSteps() throws {
        let plan = try RenamePlan(steps: [])
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.scratchSteps, [])
        XCTAssertEqual(plan.directSteps, [])
    }

    func test_planFiltersNoOpSteps() throws {
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "a/01-foo.md", newRelativePath: "a/01-foo.md"),
            .init(oldRelativePath: "a/02-bar.md", newRelativePath: "a/03-bar.md"),
        ])
        // No-op step is filtered out
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].oldRelativePath, "a/02-bar.md")
    }

    func test_planRejectsDuplicateSourcePaths() {
        XCTAssertThrowsError(try RenamePlan(steps: [
            .init(oldRelativePath: "a.md", newRelativePath: "b.md"),
            .init(oldRelativePath: "a.md", newRelativePath: "c.md"),
        ])) { error in
            guard case RenamePlanError.duplicateSource(let p) = error else {
                return XCTFail("expected duplicateSource, got \(error)")
            }
            XCTAssertEqual(p, "a.md")
        }
    }

    func test_planRejectsDuplicateDestinationPaths() {
        XCTAssertThrowsError(try RenamePlan(steps: [
            .init(oldRelativePath: "a.md", newRelativePath: "x.md"),
            .init(oldRelativePath: "b.md", newRelativePath: "x.md"),
        ])) { error in
            guard case RenamePlanError.duplicateDestination(let p) = error else {
                return XCTFail("expected duplicateDestination, got \(error)")
            }
            XCTAssertEqual(p, "x.md")
        }
    }

    func test_planRejectsAncestorOverlap() {
        // Renaming a parent folder AND a child within it would invalidate the
        // child's oldRelativePath after the parent move. Reject up front.
        XCTAssertThrowsError(try RenamePlan(steps: [
            .init(oldRelativePath: "act-one", newRelativePath: "act-uno"),
            .init(oldRelativePath: "act-one/01-chapter-1.md",
                  newRelativePath: "act-one/02-chapter-1.md"),
        ])) { error in
            guard case RenamePlanError.ancestorOverlap = error else {
                return XCTFail("expected ancestorOverlap, got \(error)")
            }
        }
    }

    func test_nonCollidingRenames_areAllDirect() throws {
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "01-a.md", newRelativePath: "10-a.md"),
            .init(oldRelativePath: "02-b.md", newRelativePath: "20-b.md"),
        ])
        XCTAssertEqual(plan.scratchSteps.count, 0)
        XCTAssertEqual(plan.directSteps.count, 2)
    }

    func test_collidingRenames_useScratch() throws {
        // Swap A and B: A's new path = B's old path, B's new path = A's old path.
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "01-a.md", newRelativePath: "02-a.md"),
            .init(oldRelativePath: "02-b.md", newRelativePath: "01-b.md"),
        ])
        // Both steps need scratch because each one's new path matches another's old path.
        XCTAssertEqual(plan.scratchSteps.count, 2)
        XCTAssertEqual(plan.directSteps.count, 0)
    }

    func test_mixedColliding_andNonColliding() throws {
        // c → d (no collision), a → b (collision with second step), b → x (collision)
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "c.md", newRelativePath: "d.md"),
            .init(oldRelativePath: "a.md", newRelativePath: "b.md"),
            .init(oldRelativePath: "b.md", newRelativePath: "x.md"),
        ])
        XCTAssertEqual(plan.directSteps.count, 1)
        XCTAssertEqual(plan.directSteps.first?.oldRelativePath, "c.md")
        XCTAssertEqual(plan.scratchSteps.count, 2)
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/RenamePlanTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find 'RenamePlan' in scope`.

- [ ] **Step 3: Implement RenamePlan**

`Maugham/Stores/RenamePlan.swift`:
```swift
import Foundation

public enum RenamePlanError: Error, Equatable {
    case duplicateSource(String)
    case duplicateDestination(String)
    case ancestorOverlap
}

/// A validated batch of (oldRelativePath → newRelativePath) renames, classified
/// into ones that can run direct and ones that need a scratch-directory swap
/// to avoid intermediate path collisions.
public struct RenamePlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Hashable {
        public let oldRelativePath: String
        public let newRelativePath: String

        public init(oldRelativePath: String, newRelativePath: String) {
            self.oldRelativePath = oldRelativePath
            self.newRelativePath = newRelativePath
        }
    }

    /// All non-no-op steps after filtering and validation.
    public let steps: [Step]

    /// Steps whose newRelativePath equals some other step's oldRelativePath.
    /// These need to go through scratch to avoid clobbering siblings.
    public let scratchSteps: [Step]

    /// Steps that can run direct (no collision risk).
    public let directSteps: [Step]

    public init(steps: [Step]) throws {
        // Filter no-op renames.
        let filtered = steps.filter { $0.oldRelativePath != $0.newRelativePath }

        // Detect duplicate sources.
        var seenSources = Set<String>()
        for step in filtered {
            if !seenSources.insert(step.oldRelativePath).inserted {
                throw RenamePlanError.duplicateSource(step.oldRelativePath)
            }
        }

        // Detect duplicate destinations.
        var seenDestinations = Set<String>()
        for step in filtered {
            if !seenDestinations.insert(step.newRelativePath).inserted {
                throw RenamePlanError.duplicateDestination(step.newRelativePath)
            }
        }

        // Detect ancestor overlap: any step's path is a directory prefix of
        // another step's path. Reject; would invalidate the inner step's
        // oldRelativePath after the outer step renames.
        let allPaths = filtered.flatMap { [$0.oldRelativePath, $0.newRelativePath] }
        for a in filtered {
            for b in filtered where a != b {
                if Self.isAncestor(a.oldRelativePath, of: b.oldRelativePath) ||
                   Self.isAncestor(a.newRelativePath, of: b.newRelativePath) {
                    throw RenamePlanError.ancestorOverlap
                }
            }
        }
        _ = allPaths  // silence unused warning if any path checks added later

        // Classify scratch vs direct based on collision detection.
        let allOldPaths = Set(filtered.map(\.oldRelativePath))
        var scratch: [Step] = []
        var direct: [Step] = []
        for step in filtered {
            if allOldPaths.contains(step.newRelativePath) {
                scratch.append(step)
            } else {
                direct.append(step)
            }
        }

        self.steps = filtered
        self.scratchSteps = scratch
        self.directSteps = direct
    }

    /// True if `prefix` is a proper directory ancestor of `path`.
    /// I.e., path == "\(prefix)/..." with prefix being a path segment match.
    private static func isAncestor(_ prefix: String, of path: String) -> Bool {
        guard prefix != path else { return false }
        return path.hasPrefix(prefix + "/")
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 8 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/RenamePlanTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: 8 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/RenamePlan.swift MaughamTests/RenamePlanTests.swift
git commit -m "feat: add RenamePlan with collision classification"
```

---

## Task 3: DropIntent

**Files:**
- Create: `Maugham/Views/DropIntent.swift`
- Create: `MaughamTests/DropIntentTests.swift`

Pure-logic helper that classifies a drop position (top/middle/bottom of a row, plus target item) into an action: insert above, insert below, or insert as first child of a group.

- [ ] **Step 1: Write failing tests**

`MaughamTests/DropIntentTests.swift`:
```swift
import XCTest
@testable import Maugham

final class DropIntentTests: XCTestCase {

    private func makeDocument(id: String) -> StructureItem {
        StructureItem(id: id, title: "Doc \(id)", type: .document, path: "x")
    }

    private func makeGroup(id: String) -> StructureItem {
        StructureItem(id: id, title: "Group \(id)", type: .group, path: "x", children: [])
    }

    func test_topThirdOnDocument_isInsertAbove() {
        let intent = DropIntent.classify(
            position: .top, target: makeDocument(id: "doc-1"))
        XCTAssertEqual(intent, .insertAbove(targetId: "doc-1"))
    }

    func test_bottomThirdOnDocument_isInsertBelow() {
        let intent = DropIntent.classify(
            position: .bottom, target: makeDocument(id: "doc-1"))
        XCTAssertEqual(intent, .insertBelow(targetId: "doc-1"))
    }

    func test_middleOnDocument_isInsertBelow() {
        // Documents can't have children — middle drop becomes "below".
        let intent = DropIntent.classify(
            position: .middle, target: makeDocument(id: "doc-1"))
        XCTAssertEqual(intent, .insertBelow(targetId: "doc-1"))
    }

    func test_middleOnGroup_isInsertChild() {
        let intent = DropIntent.classify(
            position: .middle, target: makeGroup(id: "grp-1"))
        XCTAssertEqual(intent, .insertChild(parentId: "grp-1"))
    }

    func test_topOnGroup_isInsertAbove() {
        let intent = DropIntent.classify(
            position: .top, target: makeGroup(id: "grp-1"))
        XCTAssertEqual(intent, .insertAbove(targetId: "grp-1"))
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DropIntentTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement DropIntent**

`Maugham/Views/DropIntent.swift`:
```swift
import Foundation

/// Classifies a drag-and-drop gesture in the binder into a structural action.
public enum DropIntent: Equatable, Sendable {
    case insertAbove(targetId: String)
    case insertBelow(targetId: String)
    case insertChild(parentId: String)
}

extension DropIntent {
    /// Vertical position of the drop within a row's height.
    public enum Position: Equatable, Sendable {
        case top, middle, bottom
    }

    /// Classify a drop. Documents can't have children, so a middle drop on
    /// a document becomes "below".
    public static func classify(
        position: Position, target: StructureItem
    ) -> DropIntent {
        switch position {
        case .top:
            return .insertAbove(targetId: target.id)
        case .bottom:
            return .insertBelow(targetId: target.id)
        case .middle:
            return target.type == .group
                ? .insertChild(parentId: target.id)
                : .insertBelow(targetId: target.id)
        }
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 5 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DropIntentTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/DropIntent.swift MaughamTests/DropIntentTests.swift
git commit -m "feat: add DropIntent for binder drag-drop classification"
```

---

## Task 4: DocumentStore — coordinated rename helpers + scratch-stragglers log

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`

Adds two helpers to `DocumentStore`: `executeRenamePlan(_:)` (multi-file rename with scratch-swap) and `executeCopy(from:to:)` (used by Duplicate). Also extends `open(url:)` to log if `.maugham/scratch/` has stragglers from a crash.

- [ ] **Step 1: Add helpers to DocumentStore**

In `Maugham/Stores/DocumentStore.swift`, append the following methods to the class body (place near `writeManifest` / `readManifest`):

```swift
    /// Execute a RenamePlan. Phase 1 moves colliding items to scratch; Phase 2
    /// moves scratch items to final destinations and direct items to their
    /// final destinations. Coordinated through NSFileCoordinator.
    public func executeRenamePlan(_ plan: RenamePlan) async throws {
        guard !plan.steps.isEmpty else { return }

        let scratchDir = projectURL.appendingPathComponent(".maugham/scratch")
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)

        // Phase 1: move colliding items to scratch with unique names.
        var scratchMap: [(scratchURL: URL, finalRelativePath: String)] = []
        for step in plan.scratchSteps {
            let oldURL = projectURL.appendingPathComponent(step.oldRelativePath)
            let scratchURL = scratchDir.appendingPathComponent(UUID().uuidString)
            try await coordinatedMove(from: oldURL, to: scratchURL)
            scratchMap.append((scratchURL, step.newRelativePath))
        }

        // Phase 2a: direct (non-colliding) renames.
        for step in plan.directSteps {
            let oldURL = projectURL.appendingPathComponent(step.oldRelativePath)
            let newURL = projectURL.appendingPathComponent(step.newRelativePath)
            try await coordinatedMove(from: oldURL, to: newURL)
        }

        // Phase 2b: scratch items to final destinations.
        for entry in scratchMap {
            let finalURL = projectURL.appendingPathComponent(entry.finalRelativePath)
            try await coordinatedMove(from: entry.scratchURL, to: finalURL)
        }

        // Phase 3: caller saves the manifest.

        // Best-effort cleanup of empty scratch dir.
        if let contents = try? FileManager.default
            .contentsOfDirectory(atPath: scratchDir.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: scratchDir)
        }
    }

    /// Coordinated copy of a file or folder. Used by Duplicate.
    public func executeCopy(from sourceURL: URL, to destinationURL: URL) async throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: sourceURL, options: [],
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordError
        ) { readURL, writeURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
    }

    /// Coordinated move of a file or folder. Wraps NSFileCoordinator's
    /// reading + writing pair for the source/destination.
    private func coordinatedMove(from sourceURL: URL, to destinationURL: URL) async throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: sourceURL, options: .forMoving,
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordError
        ) { fromURL, toURL in
            do {
                try FileManager.default.moveItem(at: fromURL, to: toURL)
            } catch {
                moveError = error
            }
        }
        if let coordError { throw coordError }
        if let moveError { throw moveError }
    }
```

- [ ] **Step 2: Add scratch-stragglers log to `open(url:)`**

In the same file, find the existing `public static func open(url: URL) async throws -> DocumentStore` method body. After `let store = DocumentStore(projectURL: url, uiState: uiState)` (or right before the manifest seeding block), insert:

```swift
        // Log scratch stragglers from a previous crashed multi-rename.
        // 2a accepts manual cleanup; future milestone may auto-recover.
        let scratchDir = url.appendingPathComponent(".maugham/scratch")
        if let entries = try? FileManager.default
            .contentsOfDirectory(atPath: scratchDir.path),
           !entries.isEmpty {
            print("[DocumentStore] WARNING: \(entries.count) stragglers in \(scratchDir.path) — likely from a crashed reorder/tidy. Manual inspection recommended.")
        }
```

`print()` goes to the Xcode debug console / Console.app; acceptable for 2a's "log only" stance.

- [ ] **Step 3: Smoke-build + run all DocumentStore tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentStoreOpenCloseTests -only-testing:MaughamTests/DocumentStoreSaveTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: existing 9 DocumentStore tests still pass. The new helpers aren't directly tested yet — they get exercised through ProjectStore mutator tests in Tasks 5–7.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Stores/DocumentStore.swift
git commit -m "feat: DocumentStore.executeRenamePlan + executeCopy + scratch log"
```

---

## Task 5: ProjectStore.moveStructureItem

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectStoreReorderTests.swift`

Implements the reorder mutator. Builds a `RenamePlan` from the move semantics, executes through `DocumentStore`, updates manifest.

- [ ] **Step 1: Write failing tests**

`MaughamTests/ProjectStoreReorderTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreReorderTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// Helper: create a Novel with N chapters at root.
    private func makeNovel(chapters: Int) async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Reorder", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        // Novel comes with Chapter 1; add additional chapters as needed.
        for i in 2...chapters {
            _ = try await store.addStructureItem(
                parentId: nil,
                title: "Chapter \(i)",
                kind: .document(extension: "md"))
        }
        return (url, store, ds)
    }

    func test_moveSiblings_swapAdjacent() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 3)
        let chapterIds = store.manifest.structure.map(\.id)

        // Move chapter 1 to position 1 (between chapter 1 and 2 → swap with 2)
        try await store.moveStructureItem(
            id: chapterIds[0], toParentId: nil, atIndex: 1)

        // Order is now [ch2, ch1, ch3] in manifest
        let newOrder = store.manifest.structure.map(\.id)
        XCTAssertEqual(newOrder, [chapterIds[1], chapterIds[0], chapterIds[2]])

        // Filenames renumbered: ch2 has 01, ch1 has 02, ch3 has 03
        XCTAssertTrue(store.manifest.structure[0].path?.contains("/01-") ?? false)
        XCTAssertTrue(store.manifest.structure[1].path?.contains("/02-") ?? false)
        XCTAssertTrue(store.manifest.structure[2].path?.contains("/03-") ?? false)

        // Files exist at new paths
        for item in store.manifest.structure {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: url.appendingPathComponent(item.path!).path))
        }
        await ds.close()
    }

    func test_moveDocument_intoGroup() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 2)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let chapter1Id = store.manifest.structure[0].id

        try await store.moveStructureItem(
            id: chapter1Id, toParentId: group.id, atIndex: 0)

        // Chapter 1 no longer at root
        XCTAssertFalse(store.manifest.structure
            .contains { $0.id == chapter1Id })
        // Chapter 1 now in Act One's children
        let updatedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })!
        XCTAssertEqual(updatedGroup.children?.first?.id, chapter1Id)
        // File physically in Act One's folder
        let movedItem = updatedGroup.children!.first!
        XCTAssertTrue(movedItem.path!.contains("/act-one/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(movedItem.path!).path))
        await ds.close()
    }

    func test_moveGroup_intoAnotherGroup() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 1)
        let act1 = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let act2 = try await store.addStructureItem(
            parentId: nil, title: "Act Two", kind: .group)
        // Add a chapter inside act2 so we can verify children follow
        let chapInAct2 = try await store.addStructureItem(
            parentId: act2.id, title: "Inner",
            kind: .document(extension: "md"))

        // Move act2 (with its child) into act1
        try await store.moveStructureItem(
            id: act2.id, toParentId: act1.id, atIndex: 0)

        let updatedAct1 = store.manifest.structure
            .first(where: { $0.id == act1.id })!
        let movedAct2 = updatedAct1.children?.first(where: { $0.id == act2.id })
        XCTAssertNotNil(movedAct2)
        // act2's new path is inside act1's folder
        XCTAssertTrue(movedAct2!.path!.contains("act-one"))
        // The inner chapter's path follows
        let updatedChap = movedAct2!.children!
            .first(where: { $0.id == chapInAct2.id })!
        XCTAssertTrue(updatedChap.path!.contains("act-one"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(updatedChap.path!).path))
        await ds.close()
    }

    func test_moveItemIntoOwnDescendant_throws() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 1)
        _ = url
        let outerGroup = try await store.addStructureItem(
            parentId: nil, title: "Outer", kind: .group)
        let innerGroup = try await store.addStructureItem(
            parentId: outerGroup.id, title: "Inner", kind: .group)

        // Try to move outer into inner — that's a cycle
        do {
            try await store.moveStructureItem(
                id: outerGroup.id, toParentId: innerGroup.id, atIndex: 0)
            XCTFail("expected throw")
        } catch ProjectStoreError.cycle {
            // ok
        }
        await ds.close()
    }

    func test_moveSameParent_atSameIndex_isNoOp() async throws {
        let (url, store, ds) = try await makeNovel(chapters: 3)
        _ = url
        let manifestBefore = store.manifest

        try await store.moveStructureItem(
            id: store.manifest.structure[0].id,
            toParentId: nil, atIndex: 0)

        // Manifest structure should be byte-identical (modulo modified date)
        XCTAssertEqual(
            store.manifest.structure.map(\.id),
            manifestBefore.structure.map(\.id))
        await ds.close()
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreReorderTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `cannot find 'cycle'` and `value of type 'ProjectStore' has no member 'moveStructureItem'`.

- [ ] **Step 3: Add `cycle` error case + implement moveStructureItem**

In `Maugham/Stores/ProjectStore.swift`, add a new case to `ProjectStoreError`:

```swift
public enum ProjectStoreError: Error, Equatable {
    // ... existing cases ...
    case cycle
}
```

Then add `moveStructureItem` to the class body (place near `addStructureItem`):

```swift
    /// Move an item to a new position. `toParentId` of nil means root. The
    /// destination index is into the children array of the new parent (or
    /// root structure if nil). Filename NN values renumber to keep contiguous
    /// 01, 02, 03 ordering.
    ///
    /// Cross-group moves (changing parent) physically move the file or folder
    /// between locations; sibling-only moves only renumber the NN prefix.
    public func moveStructureItem(
        id: String, toParentId: String?, atIndex destIndex: Int
    ) async throws {
        // 1. Find source item and its current parent + index.
        guard let item = findItem(id: id, in: manifest.structure),
              let oldPath = item.path else {
            throw ProjectStoreError.structureMissing
        }
        let oldParentId = findParentId(of: id, in: manifest.structure, parent: nil)
        let oldIndex = currentIndex(of: id, parentId: oldParentId)

        // 2. Cycle check: cannot move a group into one of its descendants.
        if let toParentId, item.type == .group {
            if Self.isDescendant(
                ancestorId: id,
                candidateId: toParentId,
                in: manifest.structure) {
                throw ProjectStoreError.cycle
            }
        }

        // 3. Validate target parent exists and is a group (if non-nil).
        if let toParentId {
            guard let parent = findItem(id: toParentId, in: manifest.structure),
                  parent.type == .group else {
                throw ProjectStoreError.parentNotFound(toParentId)
            }
            _ = parent
        }

        // 4. No-op detection: same parent + same index = no op.
        if oldParentId == toParentId, oldIndex == destIndex {
            return
        }

        // 5. Compute the post-move sibling order in the destination parent.
        var destSiblings = childrenOf(parentId: toParentId)
        // Remove the item if it's currently in the destination siblings (same-parent move).
        destSiblings.removeAll(where: { $0.id == id })
        // Clamp destIndex.
        let clampedIndex = max(0, min(destIndex, destSiblings.count))
        destSiblings.insert(item, at: clampedIndex)

        // 6. Build the rename plan.
        // For each destination sibling, the new NN is its zero-based position + 1.
        // The item being moved gets a new path under the destination parent.
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
            // Extract slug + extension from current filename (or recompute).
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
            // Build updated sibling with new path; for groups, recursively
            // rewrite descendant paths.
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
        try await documentStore.executeRenamePlan(plan)

        // 7. Mutate the manifest tree: remove the item from its old location;
        //    set the destination's children to the new sibling list.
        removeFromStructure(id: id)
        replaceChildren(parentId: toParentId, with: newDestSiblings)
        manifest.modified = Date()
        try await saveManifest()
        _ = oldPath
    }

    // MARK: - Helpers used by moveStructureItem

    private func findParentId(
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

    private func currentIndex(of id: String, parentId: String?) -> Int {
        let siblings = childrenOf(parentId: parentId)
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func childrenOf(parentId: String?) -> [StructureItem] {
        if let parentId {
            return findItem(id: parentId, in: manifest.structure)?.children ?? []
        }
        return manifest.structure
    }

    private static func isDescendant(
        ancestorId: String,
        candidateId: String,
        in items: [StructureItem]
    ) -> Bool {
        // Returns true if candidateId appears in the subtree rooted at ancestorId.
        guard let ancestor = findItemStatic(id: ancestorId, in: items) else { return false }
        return Self.containsId(candidateId, in: ancestor.children ?? [])
    }

    private static func findItemStatic(
        id: String, in items: [StructureItem]
    ) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItemStatic(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    private static func containsId(
        _ id: String, in items: [StructureItem]
    ) -> Bool {
        for item in items {
            if item.id == id { return true }
            if let children = item.children, containsId(id, in: children) {
                return true
            }
        }
        return false
    }

    private func replaceChildren(
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
```

(Note: this task introduces several private helpers. The existing `findItem`, `mutateItem`, `removeFromStructure`, `rewriteChildPaths` from earlier milestones stay. The new helpers are `findParentId`, `currentIndex`, `childrenOf`, `isDescendant`, `findItemStatic`, `containsId`, `replaceChildren`.)

- [ ] **Step 4: Regenerate, run, expect 5 reorder tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreReorderTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

If a test fails, iterate the implementation. Common pitfalls:
- Forgetting to recursively update descendant paths after a group's path changes (use the existing `rewriteChildPaths` helper).
- Off-by-one in NN renumbering: the position-zero-based index must produce NN starting at 01 (not 00).
- Path string concatenation: avoid double slashes by ensuring parent path doesn't end with `/`.

- [ ] **Step 5: Run all existing tests to verify no regression**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 173 + 8 (RenamePlan) + 5 (DropIntent) + 5 (Reorder) = 191 tests passing. (DocumentStore tests unchanged at this point.)

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreReorderTests.swift
git commit -m "feat: ProjectStore.moveStructureItem with sibling renumber + cross-group move"
```

---

## Task 6: ProjectStore.duplicateStructureItem

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectStoreDuplicateTests.swift`

Document copy via `DocumentStore.executeCopy`; group recursive copy with fresh ids for every descendant.

- [ ] **Step 1: Write failing tests**

`MaughamTests/ProjectStoreDuplicateTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreDuplicateTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Dupe", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_duplicateDocument_createsCopyWithCopyOfPrefix() async throws {
        let (url, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]
        // Seed some content
        try "Hello world".write(
            to: url.appendingPathComponent(chapter1.path!),
            atomically: true, encoding: .utf8)

        let copy = try await store.duplicateStructureItem(id: chapter1.id)

        XCTAssertEqual(copy.title, "Copy of Chapter 1")
        XCTAssertNotEqual(copy.id, chapter1.id)
        XCTAssertEqual(copy.type, .document)

        // File exists at new path with same content
        let copyURL = url.appendingPathComponent(copy.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        let copyContent = try String(contentsOf: copyURL, encoding: .utf8)
        XCTAssertEqual(copyContent, "Hello world")

        // Manifest entry: copy is next sibling of chapter1
        XCTAssertEqual(store.manifest.structure.count, 2)
        XCTAssertEqual(store.manifest.structure[1].id, copy.id)
        await ds.close()
    }

    func test_duplicateDocument_filenameUsesNextNN() async throws {
        let (_, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]

        let copy = try await store.duplicateStructureItem(id: chapter1.id)

        XCTAssertTrue(copy.path!.hasPrefix("manuscript/02-"),
                      "expected NN '02-' prefix, got \(copy.path!)")
        await ds.close()
    }

    func test_duplicateGroup_recursivelyCopiesDescendants() async throws {
        let (url, store, ds) = try await makeNovel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let inner1 = try await store.addStructureItem(
            parentId: group.id, title: "Scene 1",
            kind: .document(extension: "md"))
        try "scene 1 text".write(
            to: url.appendingPathComponent(inner1.path!),
            atomically: true, encoding: .utf8)

        let copy = try await store.duplicateStructureItem(id: group.id)

        XCTAssertEqual(copy.title, "Copy of Act One")
        XCTAssertEqual(copy.type, .group)
        XCTAssertNotEqual(copy.id, group.id)
        XCTAssertEqual(copy.children?.count, 1)
        // Descendant has fresh id
        let copiedInner = copy.children!.first!
        XCTAssertNotEqual(copiedInner.id, inner1.id)
        XCTAssertEqual(copiedInner.title, "Scene 1")  // descendant title preserved
        // File copied
        let copiedFileURL = url.appendingPathComponent(copiedInner.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFileURL.path))
        let copiedContent = try String(contentsOf: copiedFileURL, encoding: .utf8)
        XCTAssertEqual(copiedContent, "scene 1 text")
        await ds.close()
    }

    func test_duplicate_invalidId_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        do {
            _ = try await store.duplicateStructureItem(id: "nope")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {}
        await ds.close()
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreDuplicateTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement duplicateStructureItem**

In `Maugham/Stores/ProjectStore.swift`, add to the class body:

```swift
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

        // Compute filename for the copy.
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

        // Copy on disk via DocumentStore.executeCopy (works for files and folders).
        try await documentStore.executeCopy(from: sourceFullURL, to: newFullURL)

        // Build the new StructureItem subtree with fresh ids.
        let copy = duplicatedItemTree(
            from: source,
            newTitle: newTitle,
            newPath: newPath,
            newPrefixForChildren: newPath)

        // Insert as next sibling of source.
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
    private func duplicatedItemTree(
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
                // Compute child's new path under the new prefix.
                let childRelativeFromOldParent = childPath.dropFirst(
                    (source.path?.count ?? 0) + 1)  // +1 for the slash
                let childNewPath = "\(newPrefixForChildren)/\(childRelativeFromOldParent)"
                copiedChildren.append(duplicatedItemTree(
                    from: child,
                    newTitle: child.title,  // descendants keep original title
                    newPath: childNewPath,
                    newPrefixForChildren: childNewPath))
            }
            copy.children = copiedChildren
        }
        return copy
    }

    private static func newDuplicateId(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }
```

- [ ] **Step 4: Regenerate, run, expect 4 duplicate tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreDuplicateTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreDuplicateTests.swift
git commit -m "feat: ProjectStore.duplicateStructureItem (document and group)"
```

---

## Task 7: ProjectStore.tidyFilenames + tidyAllFilenames

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectStoreTidyTests.swift`

Compact NN gaps within a parent (or root). `tidyAllFilenames()` walks post-order.

- [ ] **Step 1: Write failing tests**

`MaughamTests/ProjectStoreTidyTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreTidyTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel(chapters: Int) async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Tidy", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        for i in 2...chapters {
            _ = try await store.addStructureItem(
                parentId: nil, title: "Chapter \(i)",
                kind: .document(extension: "md"))
        }
        return (url, store, ds)
    }

    func test_tidyAfterDelete_compactsContiguous() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 5)
        // Delete chapters 2 and 4
        try await store.deleteStructureItem(
            id: store.manifest.structure[1].id)  // ch2
        try await store.deleteStructureItem(
            id: store.manifest.structure[2].id)  // ch4 (now at index 2 after ch2 removed)

        // Before tidy: NN sequence has gaps (01, 03, 05)
        let beforePaths = store.manifest.structure.compactMap(\.path)
        XCTAssertEqual(beforePaths.count, 3)

        try await store.tidyFilenames(parentId: nil)

        // After tidy: contiguous 01, 02, 03
        let afterPaths = store.manifest.structure.compactMap(\.path)
        XCTAssertTrue(afterPaths[0].contains("/01-"),
                      "got \(afterPaths[0])")
        XCTAssertTrue(afterPaths[1].contains("/02-"),
                      "got \(afterPaths[1])")
        XCTAssertTrue(afterPaths[2].contains("/03-"),
                      "got \(afterPaths[2])")
        await ds.close()
    }

    func test_tidy_isIdempotent() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 3)
        // Already contiguous.
        try await store.tidyFilenames(parentId: nil)
        let firstPaths = store.manifest.structure.compactMap(\.path)
        try await store.tidyFilenames(parentId: nil)
        let secondPaths = store.manifest.structure.compactMap(\.path)
        XCTAssertEqual(firstPaths, secondPaths)
        await ds.close()
    }

    func test_tidyAllFilenames_walksTree() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 3)
        // Create a group with two children, then delete the first child to
        // create a gap.
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let scene1 = try await store.addStructureItem(
            parentId: group.id, title: "Scene 1",
            kind: .document(extension: "md"))
        _ = try await store.addStructureItem(
            parentId: group.id, title: "Scene 2",
            kind: .document(extension: "md"))
        try await store.deleteStructureItem(id: scene1.id)

        try await store.tidyAllFilenames()

        // Group's child is now at NN 01 (compacted from 02)
        let updatedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })!
        let remainingScene = updatedGroup.children!.first!
        XCTAssertTrue(remainingScene.path!.contains("/01-"))
        await ds.close()
    }

    func test_tidy_preservesSlugs() async throws {
        let (_, store, ds) = try await makeNovel(chapters: 3)
        // Rename chapter 2 to something else
        let ch2 = store.manifest.structure[1]
        try await store.renameStructureItem(
            id: ch2.id, newTitle: "The Funeral")
        // Now delete chapter 1 → gap, ch2-renamed at NN=02
        try await store.deleteStructureItem(
            id: store.manifest.structure[0].id)

        try await store.tidyFilenames(parentId: nil)

        // Top item should still have "the-funeral" slug, just at NN=01 now
        let top = store.manifest.structure[0]
        XCTAssertTrue(top.path!.contains("the-funeral"),
                      "got \(top.path!)")
        XCTAssertTrue(top.path!.contains("/01-"))
        await ds.close()
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreTidyTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement tidyFilenames + tidyAllFilenames**

Add to `ProjectStore` class:

```swift
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
            // Drop existing NN- prefix.
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
        try await documentStore.executeRenamePlan(plan)
        replaceChildren(parentId: parentId, with: newSiblings)
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Walk the structure tree post-order, calling tidyFilenames at every
    /// group level. Single batched manifest save at the end.
    public func tidyAllFilenames() async throws {
        // Collect all group ids in post-order (deepest first).
        var groupIds: [String?] = []  // nil sentinel for root
        Self.collectGroupIds(in: manifest.structure, into: &groupIds)
        groupIds.append(nil)  // root last

        for parentId in groupIds {
            try await tidyFilenames(parentId: parentId)
        }
    }

    private static func collectGroupIds(
        in items: [StructureItem],
        into result: inout [String?]
    ) {
        for item in items where item.type == .group {
            // Recurse first (post-order)
            if let children = item.children {
                collectGroupIds(in: children, into: &result)
            }
            result.append(item.id)
        }
    }
```

- [ ] **Step 4: Regenerate, run, expect 4 tidy tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreTidyTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Run full test suite to verify no regression**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 173 + 8 + 5 + 5 + 4 + 4 = 199 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreTidyTests.swift
git commit -m "feat: ProjectStore.tidyFilenames + tidyAllFilenames"
```

---

## Task 8: BinderRow draggable + dropDestination

**Files:**
- Modify: `Maugham/Views/BinderRow.swift`

Add `.draggable(item.id)` and `.dropDestination(for: String.self)` modifiers. Drop-region detection lives at the row level: each row reports its drop position via a callback that BinderView wires into the `moveStructureItem` flow (Task 9).

- [ ] **Step 1: Read existing BinderRow**

```bash
cat Maugham/Views/BinderRow.swift
```

- [ ] **Step 2: Add drag + drop modifiers**

Replace `Maugham/Views/BinderRow.swift` with:

```swift
import SwiftUI

struct BinderRow: View {
    let item: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void  // (id, newTitle)
    /// Called when a drop completes on this row. The closure receives the
    /// dragged item id and the vertical position within this row (top/middle/
    /// bottom). Caller (BinderView) translates that to a DropIntent and
    /// invokes the appropriate ProjectStore mutator.
    let onDrop: (_ draggedId: String, _ position: DropIntent.Position) -> Void

    @State private var draftTitle: String = ""

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            if renamingItemId == item.id {
                TextField("", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .onAppear { draftTitle = item.title }
                    .onExitCommand { renamingItemId = nil }
            } else {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .draggable(item.id) {
            // Drag preview: just show the title.
            Text(item.title)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .dropDestination(for: String.self) { ids, location in
            guard let droppedId = ids.first else { return false }
            // Determine the vertical position within this row's bounds.
            // SwiftUI's dropDestination provides location relative to the row.
            // Without GeometryReader we can use a heuristic: SwiftUI rows are
            // typically ~22pt tall in sidebar lists. We split into thirds.
            let rowHeight: CGFloat = 22
            let position: DropIntent.Position
            if location.y < rowHeight / 3 { position = .top }
            else if location.y > (rowHeight * 2 / 3) { position = .bottom }
            else { position = .middle }
            onDrop(droppedId, position)
            return true
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if item.type == .document {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        } else {
            Image(systemName: "folder")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != item.title {
            onRename(item.id, trimmed)
        }
        renamingItemId = nil
    }
}
```

- [ ] **Step 3: Smoke-build (will fail until Task 9 wires onDrop)**

The build will fail because BinderView doesn't yet pass `onDrop:` to BinderRow. T9 fixes this.

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `error: missing argument for parameter 'onDrop' in call`. That's expected.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/BinderRow.swift
git commit -m "feat: BinderRow gains .draggable + .dropDestination"
```

---

## Task 9: BinderView drag/drop wiring + Duplicate context menu

**Files:**
- Modify: `Maugham/Views/BinderView.swift`

Wires the row's `onDrop` callback to `moveStructureItem`. Adds Duplicate to the context menu.

- [ ] **Step 1: Read existing BinderView to confirm structure**

```bash
cat Maugham/Views/BinderView.swift
```

- [ ] **Step 2: Update BinderView with drag wiring + Duplicate item**

Replace the existing `row(for:)` private method in `Maugham/Views/BinderView.swift` with:

```swift
    private func row(for item: StructureItem) -> some View {
        BinderRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
            },
            onDrop: { draggedId, position in
                Task { await handleDrop(draggedId: draggedId,
                                        position: position,
                                        target: item) }
            }
        )
        .contextMenu {
            Button("New Document") {
                Task { await addItem(parent: item, kind: .document(extension: "md")) }
            }
            Button("New Group") {
                Task { await addItem(parent: item, kind: .group) }
            }
            Divider()
            Button("Duplicate") {
                Task { await duplicate(id: item.id) }
            }
            Button("Rename") { renamingItemId = item.id }
            Button("Delete", role: .destructive) {
                Task { await deleteItem(id: item.id) }
            }
            if item.type == .group {
                Divider()
                Button("Tidy Filenames") {
                    pendingTidyParentId = item.id
                    showingTidyConfirmation = true
                }
            }
        }
    }
```

Add new helper methods to the class body, near `addItem`/`rename`/`deleteItem`:

```swift
    private func handleDrop(
        draggedId: String,
        position: DropIntent.Position,
        target: StructureItem
    ) async {
        guard draggedId != target.id else { return }  // can't drop on self
        let intent = DropIntent.classify(position: position, target: target)
        let toParentId: String?
        let destIndex: Int
        switch intent {
        case .insertAbove(let targetId):
            toParentId = findParentId(of: targetId)
            destIndex = currentIndex(of: targetId, in: toParentId)
        case .insertBelow(let targetId):
            toParentId = findParentId(of: targetId)
            destIndex = currentIndex(of: targetId, in: toParentId) + 1
        case .insertChild(let parentId):
            toParentId = parentId
            destIndex = 0
        }
        do {
            try await store.moveStructureItem(
                id: draggedId, toParentId: toParentId, atIndex: destIndex)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func duplicate(id: String) async {
        do {
            let copy = try await store.duplicateStructureItem(id: id)
            renamingItemId = copy.id  // immediately offer rename
            selectedItemId = copy.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func currentIndex(of id: String, in parentId: String?) -> Int {
        let siblings: [StructureItem]
        if let parentId,
           let parent = findItem(id: parentId, in: store.manifest.structure) {
            siblings = parent.children ?? []
        } else {
            siblings = store.manifest.structure
        }
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func findItem(
        id: String, in items: [StructureItem]
    ) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }
```

(The `findParentId` static helper from existing BinderView is reused — leave it as-is.)

Also add the `pendingTidyParentId` and `showingTidyConfirmation` `@State` properties at the top of `BinderView`:

```swift
    @State private var pendingTidyParentId: String?
    @State private var showingTidyConfirmation: Bool = false
```

- [ ] **Step 3: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED. Tidy alert wiring follows in Task 10.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/BinderView.swift
git commit -m "feat: BinderView drag-drop wiring + Duplicate context menu"
```

---

## Task 10: BinderView Tidy Filenames alert + handler

**Files:**
- Modify: `Maugham/Views/BinderView.swift`

Adds the confirmation alert and the actual call to `tidyFilenames(parentId:)`.

- [ ] **Step 1: Add alert modifier and tidy handler**

In `Maugham/Views/BinderView.swift`, find the existing `.alert(...)` modifier on the body (it's on `pendingError`). After that alert, append a second alert for tidy:

```swift
        .alert("Renumber filenames?",
               isPresented: $showingTidyConfirmation,
               presenting: pendingTidyParentId
        ) { _ in
            Button("Renumber", role: .destructive) {
                if let parentId = pendingTidyParentId {
                    Task { await runTidy(parentId: parentId) }
                } else {
                    Task { await runTidy(parentId: nil) }
                }
                pendingTidyParentId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTidyParentId = nil
            }
        } message: { _ in
            Text("Existing files will be moved to fix gaps in numbering. This change is visible to other apps that read this folder.")
        }
```

Add the handler method:

```swift
    private func runTidy(parentId: String?) async {
        do {
            try await store.tidyFilenames(parentId: parentId)
        } catch {
            pendingError = error.localizedDescription
        }
    }
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/BinderView.swift
git commit -m "feat: BinderView Tidy Filenames context action + confirmation alert"
```

---

## Task 11: ProjectWindow + MaughamApp — Tidy All Filenames command

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

Adds the project-wide File-menu command. Posts a notification; ProjectWindow handles it with a confirmation alert and calls `tidyAllFilenames()`.

- [ ] **Step 1: Add new notification name**

In `Maugham/Models/MaughamNotifications.swift`, append before the closing `}`:

```swift
    public static let maughamTidyAllFilenames = Notification.Name("maugham.tidyAllFilenames")
```

- [ ] **Step 2: Add File menu command in MaughamApp**

In `Maugham/MaughamApp.swift`, find the existing `CommandGroup(replacing: .newItem)` block in `.commands`. Locate the existing "Save" button at the bottom of that block. After the Save button, add:

```swift
                Divider()
                Button("Tidy All Filenames") {
                    NotificationCenter.default.post(
                        name: .maughamTidyAllFilenames, object: nil)
                }
```

(No keyboard shortcut — rare-use action.)

- [ ] **Step 3: Wire ProjectWindow to handle the notification**

In `Maugham/Views/ProjectWindow.swift`, add a new `@State` property near the other UI state:

```swift
    @State private var showingTidyAllConfirmation: Bool = false
```

Add a new `.onReceive` to the body chain (alongside the existing maugham notifications):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamTidyAllFilenames)) { _ in
            showingTidyAllConfirmation = true
        }
```

Add an alert modifier on the body (next to existing alerts/sheets):

```swift
        .alert("Renumber every chapter and scene?",
               isPresented: $showingTidyAllConfirmation
        ) {
            Button("Renumber", role: .destructive) {
                Task {
                    do {
                        try await store?.tidyAllFilenames()
                    } catch {
                        // Best-effort; surfacing project-wide tidy errors is
                        // a future enhancement.
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Filenames in every group will be renumbered to fix gaps. This change is visible to other apps that read this folder.")
        }
```

- [ ] **Step 4: Smoke-build + run all tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 199 tests passing (no new tests; just wiring).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: File menu Tidy All Filenames command with confirmation"
```

---

## Task 12: End-to-end smoke + tag milestone-2a

- [ ] **Step 1: Run full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 199 tests passing total — 173 from end of 1e + 8 RenamePlan + 5 DropIntent + 5 Reorder + 4 Duplicate + 4 Tidy.

- [ ] **Step 2: Manual smoke test (8 steps from spec)**

In Xcode, ⌘R (or `open` the built `.app`). Walk these:

1. Open a Novel project. Drag chapter 3 to position 1 (within Act One). In Finder, files renumber: `01-chapter-3.md`, `02-chapter-1.md`, `03-chapter-2.md`. Editor binding still valid for visible chapter.
2. Drag a chapter from Act One to Act Two. File moves between folders; manifest updates; binder shows the move.
3. Drag a group ("Act Three") to be a child of another group ("Act Two"). Folder physically moves under Act Two; descendants visible at the new location.
4. Right-click a chapter → Duplicate. New "Copy of <title>" appears as next sibling, in inline rename mode. Type a new name; press Return; rename completes.
5. Right-click a group with descendants → Duplicate. New "Copy of <group>" appears with all children deep-copied with fresh ids and content.
6. Delete chapters 2, 4, 6 from a group. Right-click the group → Tidy Filenames → confirm. Remaining chapters renumber 01, 02, 03 contiguously.
7. File menu → Tidy All Filenames → confirm. Every group in the project gets its NN sequence compacted in one pass.
8. Force-quit Maugham mid-reorder (drag-reorder + immediately Activity Monitor). Reopen. `.maugham/scratch/` should contain stragglers; the project loads at the pre-rename state with some files appearing missing in the binder. Console log mentions stragglers count. (Edge case acceptance test — manual cleanup expected.)

If all 8 pass, milestone 2a is healthy.

- [ ] **Step 3: Tag and merge**

```bash
git checkout main
git merge --ff-only feat/phase-2a-binder-polish
git tag -a milestone-2a -m "Maugham milestone 2a — Binder Polish

Drag-reorder works for any binder item: within siblings (NN renumber),
into a different group (folder move), or out to root. Right-click
adds Duplicate (with 'Copy of ' prefix, inline rename mode immediately).
Right-click on a group adds Tidy Filenames; File menu adds project-wide
Tidy All Filenames. Multi-file rename safety via .maugham/scratch/
swap pattern; coordinated through DocumentStore for iCloud safety.
Crash recovery is best-effort: stragglers in .maugham/scratch/ are
logged on next open for manual inspection.

199 tests passing including 26 new (8 RenamePlan + 5 DropIntent + 5
reorder integration + 4 duplicate integration + 4 tidy integration)."
git tag --list 'milestone-*'
```

Expected: `milestone-1a milestone-1b milestone-1c milestone-1d milestone-1e milestone-2a`.

- [ ] **Step 4: Update README**

Append after the existing 1e smoke section in `README.md`:

```markdown

## Phase 2a smoke test

Once running on milestone-2a:

1. Open a Novel. Drag chapter 3 to position 1. Filenames renumber 01/02/03 and the editor binding stays valid.
2. Drag a chapter from Act One to Act Two. File moves between folders; binder updates.
3. Drag a group into another group. Folder physically moves; descendants follow.
4. Right-click a chapter → Duplicate. "Copy of <title>" appears as next sibling, in inline rename mode.
5. Right-click a group → Duplicate. Group + all descendants deep-copied with fresh ids.
6. Delete chapters in a group leaving NN gaps. Right-click → Tidy Filenames → confirm. Remaining chapters renumber contiguously.
7. File → Tidy All Filenames → confirm. Every group's NN sequence compacts.
8. Force-quit mid-reorder, reopen. `.maugham/scratch/` stragglers are logged in console; project loads without crashing.

If all eight pass, milestone 2a is healthy.
```

```bash
git add README.md
git commit -m "docs: add phase 2a smoke test checklist"
```

- [ ] **Step 5: Push to remote**

```bash
git push && git push --tags
```

Expected: pushes the new commits and the `milestone-2a` tag to GitHub.

---

## Self-review checklist

- [x] **Spec coverage:** Drag-reorder siblings + cross-group (T5 + T8 + T9), Tidy per-group + project-wide (T7 + T10 + T11), Duplicate document + group (T6 + T9), RenamePlan + scratch swap (T2 + T4), DocumentStore.executeRenamePlan + scratch-stragglers log (T4), confirmation alerts for Tidy (T10 + T11), drop intent classification (T3), DropIntent.Position regions (T8 + T9). Manual smoke (T12) covers the 8 steps from the spec. ✓
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later", "fill in details", "appropriate error handling", or "similar to Task N". Every step has actual code or commands. ✓
- [x] **Type consistency:** `RenamePlan(steps:)` constructor, `RenamePlan.Step(oldRelativePath:newRelativePath:)`, `RenamePlan.scratchSteps`/`directSteps` consistent across T2, T4, T5, T7. `DropIntent.Position { .top, .middle, .bottom }` and `DropIntent.classify(position:target:)` consistent across T3, T8, T9. `ProjectStoreError.cycle` introduced in T5 and used in T9's catch block. `BinderRow.onDrop: (String, DropIntent.Position) -> Void` consistent across T8 and T9. `DocumentStore.executeRenamePlan(_:)` and `executeCopy(from:to:)` consistent across T4, T5, T6, T7. `tidyFilenames(parentId:)` and `tidyAllFilenames()` consistent across T7, T10, T11. ✓
- [x] **TDD:** Pure-logic tasks T2 (RenamePlan, 8 tests), T3 (DropIntent, 5 tests) follow TDD. Integration tasks T5, T6, T7 use real temp directory + real DocumentStore + real NSFileCoordinator with explicit fail/pass test runs. UI tasks T8, T9, T10, T11 are smoke-build only with manual smoke at T12. ✓
- [x] **Crash recovery:** T4 includes the scratch-stragglers log on `DocumentStore.open`. T12's manual smoke test step 8 verifies the log fires after a force-quit. ✓
