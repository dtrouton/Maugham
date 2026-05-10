# Research Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three small high-trust features that make Maugham feel more like a daily writing driver: New Text Note creation in research, inline images for research notes with a preview pane, and trash/undo for binder operations.

**Architecture:** Three loosely-coupled feature areas. Feature A is purely additive (new ProjectStore method + context menu). Feature B adds an `ImagePasteHandler` utility, a `ResearchNotePreviewPane` SwiftUI view, and a `MaughamTextView.paste(_:)` override. Feature C introduces a `TrashStore` value type, reroutes existing delete operations through it, adds a conditional `BinderSegment.trash`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (NSTextView, NSImage, NSPasteboard, NSTextAttachment), xcodegen, FileManager.

**Reference spec:** `docs/superpowers/specs/2026-05-10-research-polish-design.md`

---

## File map

**Create:**
- `Maugham/Stores/TrashStore.swift` — value type for trash directory operations
- `Maugham/Models/TrashEntry.swift` — public struct returned from TrashStore
- `Maugham/Editor/ImagePasteHandler.swift` — pure utility for image-paste save + ref
- `Maugham/Views/ResearchNotePreviewPane.swift` — SwiftUI preview view
- `Maugham/Views/TrashView.swift` — SwiftUI binder segment view
- `MaughamTests/TrashStoreTests.swift`
- `MaughamTests/TrashEntryTests.swift`
- `MaughamTests/ImagePasteHandlerTests.swift`
- `MaughamTests/AddResearchTextNoteTests.swift`
- `MaughamTests/TrashIntegrationTests.swift` — round-trip delete → restore
- `MaughamTests/RenameWithAssetsTests.swift`

**Modify:**
- `Maugham/Stores/ProjectStore.swift` — add `addResearchTextNote`, route deletes through TrashStore, add restore/trashEntries surface
- `Maugham/Editor/EditorSurface.swift` — add `imagePasteHandler` plumbing + `paste(_:)` override on MaughamTextView
- `Maugham/Editor/EditorCoordinator.swift` — `imagePasteHandler: ((NSImage) -> Void)?` property
- `Maugham/Models/BinderSegment.swift` — add `.trash` case
- `Maugham/Views/BinderPaneToggle.swift` — show Trash segment conditionally
- `Maugham/Views/ResearchView.swift` — add "New Note" context menu item
- `Maugham/Views/ProjectWindow.swift` — install paste handler when active doc is research note; preview pane visibility
- `Maugham/MaughamApp.swift` — `⌘Z` "Restore Last Deleted Item" command
- `Maugham/Models/MaughamNotifications.swift` — `maughamRestoreLastDeleted`, `maughamToggleResearchPreview`
- `Maugham/Stores/UIState.swift` — `researchPreviewVisible: Bool`

---

## Phase 1 — Feature A: New Text Note

### Task 1: `ProjectStore.addResearchTextNote`

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: `MaughamTests/AddResearchTextNoteTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/AddResearchTextNoteTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class AddResearchTextNoteTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddTextNote-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_addNote_atRoot_writesFileAndManifestEntry() async throws {
        let project = try makeProject()
        let store = try await ProjectStore.load(from: project)
        let note = try await store.addResearchTextNote(parentId: nil)

        XCTAssertEqual(note.kind, .document)
        XCTAssertEqual(note.type, .asset)
        XCTAssertEqual(note.title, "Untitled Note")
        XCTAssertTrue(note.path?.hasSuffix(".md") ?? false)

        let fileURL = project.appendingPathComponent(note.path ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "")
    }

    func test_addNote_titleCollision_dedupesNumerically() async throws {
        let project = try makeProject()
        let store = try await ProjectStore.load(from: project)
        let first = try await store.addResearchTextNote(parentId: nil)
        let second = try await store.addResearchTextNote(parentId: nil)
        XCTAssertEqual(first.title, "Untitled Note")
        XCTAssertEqual(second.title, "Untitled Note 2")
        XCTAssertNotEqual(first.path, second.path)
    }

    func test_addNote_intoGroup_createsInsideGroupFolder() async throws {
        let project = try makeProject()
        let store = try await ProjectStore.load(from: project)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Characters", kind: .group)
        let note = try await store.addResearchTextNote(parentId: group.id)
        XCTAssertTrue(note.path?.contains("characters/") ?? false,
                      "expected note inside characters group; got \(note.path ?? "<nil>")")
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/AddResearchTextNoteTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL — `addResearchTextNote` doesn't exist.

- [ ] **Step 3: Implement `addResearchTextNote`**

In `Maugham/Stores/ProjectStore.swift`, add (place near `addResearchItem` around line 940):

```swift
@discardableResult
public func addResearchTextNote(
    parentId: String?,
    title: String = "Untitled Note"
) async throws -> ResearchItem {
    // Determine target folder: top-level research/, or research/<group-slug>/
    let researchRoot = url.appendingPathComponent("research")
    try FileManager.default.createDirectory(
        at: researchRoot, withIntermediateDirectories: true)

    let parentFolder: URL
    if let parentId,
       let parent = findResearchItem(id: parentId, in: manifest.research),
       parent.type == .group {
        let groupSlug = Slugifier.slug(from: parent.title)
        parentFolder = researchRoot.appendingPathComponent(groupSlug)
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

    // Create the .md file
    let slug = Slugifier.slug(from: resolvedTitle)
    let filename = "\(slug).md"
    let fileURL = parentFolder.appendingPathComponent(filename)
    try Data().write(to: fileURL)

    // Compute relative path from project root
    let relativePath: String = {
        if parentFolder == researchRoot {
            return "research/\(filename)"
        }
        return "research/\(parentFolder.lastPathComponent)/\(filename)"
    }()

    let item = ResearchItem(
        id: "doc-\(UUID().uuidString.prefix(8).lowercased())",
        title: resolvedTitle,
        type: .asset,
        kind: .document,
        path: relativePath,
        addedAt: Date())

    if let parentId,
       insertResearchChild(item, intoParentId: parentId, in: &manifest.research) {
        // inserted into group
    } else {
        manifest.research.append(item)
    }

    try await save()
    return item
}

private func findResearchItem(
    id: String, in items: [ResearchItem]
) -> ResearchItem? {
    for item in items {
        if item.id == id { return item }
        if let children = item.children,
           let nested = findResearchItem(id: id, in: children) {
            return nested
        }
    }
    return nil
}

private func insertResearchChild(
    _ child: ResearchItem,
    intoParentId parentId: String,
    in items: inout [ResearchItem]
) -> Bool {
    for i in 0..<items.count {
        if items[i].id == parentId {
            items[i].children = (items[i].children ?? []) + [child]
            return true
        }
        if var children = items[i].children {
            if insertResearchChild(child, intoParentId: parentId, in: &children) {
                items[i].children = children
                return true
            }
        }
    }
    return false
}
```

Note: `findResearchItem` and `insertResearchChild` helpers may already exist (check existing `addResearchItem` for patterns). If duplicates, reuse the existing ones.

- [ ] **Step 4: Run targeted tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/AddResearchTextNoteTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Run full suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 469 tests, with 0 failures` (466 prior + 3 new).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/AddResearchTextNoteTests.swift
git commit -m "feat: ProjectStore.addResearchTextNote

Creates a new .md file in research/ (or research/<group-slug>/)
with a placeholder 'Untitled Note' title, dedupes numerically on
collision. Mirrors existing addResearchItem/addResearchAsset patterns.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ResearchView "New Note" context menu

**Files:**
- Modify: `Maugham/Views/ResearchView.swift`

- [ ] **Step 1: Read existing context menu**

```bash
grep -n "contextMenu\|New Group\|Import File" /Users/denver/src/Maugham/Maugham/Views/ResearchView.swift
```
Find the existing context menu block (likely around line 20 and line 92 from prior orientation).

- [ ] **Step 2: Add "New Note" entries**

In `Maugham/Views/ResearchView.swift`, add `Button("New Note") { ... }` to BOTH context menu sites (root + per-item) before the existing "New Group" / "Import File" entries:

```swift
Button("New Note") {
    Task {
        do {
            let note = try await store.addResearchTextNote(parentId: <parentId>)
            renamingResearchId = note.id
            selectedResearchId = note.id
        } catch {
            pendingError = error.localizedDescription
        }
    }
}
```

(Substitute `<parentId>` with the appropriate value for each context-menu site — `nil` for the root-area menu, `item.id` if context is on a group, `findResearchParentId(of: item.id)` if context is on a child item.)

Note: if `renamingResearchId` doesn't exist as State on ResearchView, add it alongside the existing rename plumbing. Look at how the manuscript binder handles `renamingItemId` for the same pattern.

- [ ] **Step 3: Build to verify no compile error**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run full suite (no new tests; manual smoke at T15)**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 469 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/ResearchView.swift
git commit -m "feat: 'New Note' context menu in research browser

Right-click research empty area or any item -> 'New Note' creates
a placeholder Untitled Note and enters rename mode. Wires the
addResearchTextNote API into the existing context menu pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Feature C: Trash & undo

### Task 3: `TrashEntry` model + `TrashStore` scaffolding (list + sweep)

**Files:**
- Create: `Maugham/Models/TrashEntry.swift`
- Create: `Maugham/Stores/TrashStore.swift`
- Test: `MaughamTests/TrashEntryTests.swift`
- Test: `MaughamTests/TrashStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/TrashEntryTests.swift`:

```swift
import XCTest
@testable import Maugham

final class TrashEntryTests: XCTestCase {
    func test_daysRemaining_freshEntry_is30() {
        let entry = TrashEntry(
            id: "20260510-153045-abc",
            trashedAt: Date(),
            originalRelativePath: "manuscript/foo.md",
            displayTitle: "Foo",
            itemMetadata: Data())
        XCTAssertEqual(entry.daysRemaining, 30)
    }

    func test_daysRemaining_almostExpired_is0() {
        let entry = TrashEntry(
            id: "20260410-153045-abc",
            trashedAt: Date(timeIntervalSinceNow: -29 * 86_400),
            originalRelativePath: "manuscript/foo.md",
            displayTitle: "Foo",
            itemMetadata: Data())
        XCTAssertLessThanOrEqual(entry.daysRemaining, 1)
        XCTAssertGreaterThanOrEqual(entry.daysRemaining, 0)
    }
}
```

Create `MaughamTests/TrashStoreTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class TrashStoreTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashStore-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func test_list_emptyProject_returnsEmpty() async throws {
        let project = try makeProject()
        let store = TrashStore(projectURL: project)
        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_sweep_removesEntriesOlderThan30Days() async throws {
        let project = try makeProject()
        let trash = project.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        // Old entry (31 days ago)
        let oldDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        let oldFolder = trash.appendingPathComponent(
            "\(Self.timestampFormatter.string(from: oldDate))-old-id")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try "{}".write(
            to: oldFolder.appendingPathComponent("meta.json"),
            atomically: true, encoding: .utf8)

        // Fresh entry
        let freshFolder = trash.appendingPathComponent(
            "\(Self.timestampFormatter.string(from: Date()))-fresh-id")
        try FileManager.default.createDirectory(at: freshFolder, withIntermediateDirectories: true)
        try "{}".write(
            to: freshFolder.appendingPathComponent("meta.json"),
            atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        try await store.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path),
                       "expected old entry swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFolder.path),
                      "expected fresh entry preserved")
    }

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TrashEntryTests -only-testing:MaughamTests/TrashStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL — `TrashEntry`, `TrashStore` don't exist.

- [ ] **Step 3: Implement `TrashEntry`**

Create `Maugham/Models/TrashEntry.swift`:

```swift
import Foundation

/// One trashed item, recoverable via TrashStore.
public struct TrashEntry: Identifiable, Equatable, Sendable {
    public let id: String                  // Folder name: "YYYYMMDD-HHMMSS-originalId"
    public let trashedAt: Date
    public let originalRelativePath: String
    public let displayTitle: String
    public let itemMetadata: Data

    public init(
        id: String,
        trashedAt: Date,
        originalRelativePath: String,
        displayTitle: String,
        itemMetadata: Data
    ) {
        self.id = id
        self.trashedAt = trashedAt
        self.originalRelativePath = originalRelativePath
        self.displayTitle = displayTitle
        self.itemMetadata = itemMetadata
    }

    /// Days remaining before the 30-day sweep removes this entry.
    public var daysRemaining: Int {
        let elapsed = Date().timeIntervalSince(trashedAt)
        let daysElapsed = Int(elapsed / 86_400)
        return max(0, 30 - daysElapsed)
    }
}
```

- [ ] **Step 4: Implement `TrashStore` scaffolding (list + sweep)**

Create `Maugham/Stores/TrashStore.swift`:

```swift
import Foundation

/// Per-project trash directory operations. Lives at <projectURL>/.trash/
/// with each trashed item in its own timestamped subfolder containing the
/// original file/folder plus a meta.json describing the restoration target.
@MainActor
public struct TrashStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    private var trashRoot: URL {
        projectURL.appendingPathComponent(".trash")
    }

    /// List all current trash entries, newest first.
    public func list() async throws -> [TrashEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot.path) else { return [] }
        let folders = (try? fm.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var entries: [TrashEntry] = []
        for folder in folders where folder.hasDirectoryPath {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(TrashMeta.self, from: data),
                  let trashedAt = Self.parseTimestamp(from: folder.lastPathComponent) else {
                continue
            }
            entries.append(TrashEntry(
                id: folder.lastPathComponent,
                trashedAt: trashedAt,
                originalRelativePath: meta.originalRelativePath,
                displayTitle: meta.displayTitle,
                itemMetadata: meta.itemMetadata))
        }
        return entries.sorted { $0.trashedAt > $1.trashedAt }
    }

    /// Remove entries older than 30 days. Called from ProjectStore.load.
    public func sweep() async throws {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let entries = try await list()
        for entry in entries where entry.trashedAt < cutoff {
            let folder = trashRoot.appendingPathComponent(entry.id)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Internal metadata persisted in each trash folder's meta.json.
    struct TrashMeta: Codable {
        let originalRelativePath: String
        let displayTitle: String
        let itemMetadata: Data
        let originalParentId: String?
        let originalIndex: Int
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()

    static func parseTimestamp(from folderName: String) -> Date? {
        // Folder name: "yyyyMMdd-HHmmss-<original-id>"
        let parts = folderName.split(separator: "-", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let stamp = "\(parts[0])-\(parts[1])"
        return timestampFormatter.date(from: stamp)
    }

    static func timestampPrefix(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
```

- [ ] **Step 5: Run targeted tests + full suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 473 tests, with 0 failures` (469 prior + 4 new).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/TrashEntry.swift Maugham/Stores/TrashStore.swift MaughamTests/TrashEntryTests.swift MaughamTests/TrashStoreTests.swift
git commit -m "feat: TrashEntry + TrashStore scaffolding (list + sweep)

Per-project .trash/ directory. Each trashed item in its own
timestamped subfolder with meta.json. list() returns entries
newest-first. sweep() removes entries older than 30 days,
called from ProjectStore.load. moveToTrash/restore/permanentlyDelete
land in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `TrashStore.moveToTrash`

**Files:**
- Modify: `Maugham/Stores/TrashStore.swift`
- Modify: `MaughamTests/TrashStoreTests.swift`

- [ ] **Step 1: Add failing test**

Append to `TrashStoreTests`:

```swift
    func test_moveToTrash_movesFileAndWritesMetadata() async throws {
        let project = try makeProject()
        let originalFile = project.appendingPathComponent("manuscript/chapter7.md")
        try FileManager.default.createDirectory(
            at: originalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "Chapter 7 content".write(to: originalFile, atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        let metadata = Data("{\"id\":\"x\"}".utf8)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/chapter7.md",
            itemMetadata: metadata,
            originalParentId: nil,
            originalIndex: 0,
            displayTitle: "Chapter 7")

        // Original is gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFile.path))

        // Trash entry exists
        let trashFolder = project.appendingPathComponent(".trash/\(entry.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashFolder.path))
        let trashedFile = trashFolder.appendingPathComponent("chapter7.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedFile.path))
        let trashedContent = try String(contentsOf: trashedFile, encoding: .utf8)
        XCTAssertEqual(trashedContent, "Chapter 7 content")

        // meta.json exists and parses
        let metaURL = trashFolder.appendingPathComponent("meta.json")
        let metaData = try Data(contentsOf: metaURL)
        let meta = try JSONDecoder().decode(TrashStore.TrashMeta.self, from: metaData)
        XCTAssertEqual(meta.originalRelativePath, "manuscript/chapter7.md")
        XCTAssertEqual(meta.displayTitle, "Chapter 7")
        XCTAssertEqual(meta.itemMetadata, metadata)
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TrashStoreTests/test_moveToTrash_movesFileAndWritesMetadata CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: COMPILE FAIL — `moveToTrash` doesn't exist.

- [ ] **Step 3: Implement `moveToTrash`**

Add to `TrashStore`:

```swift
    /// Move a file or folder to .trash/ with metadata for restoration.
    public func moveToTrash(
        fileRelativePath: String,
        itemMetadata: Data,
        originalParentId: String?,
        originalIndex: Int,
        displayTitle: String
    ) async throws -> TrashEntry {
        let fm = FileManager.default
        let now = Date()
        let timestamp = Self.timestampPrefix(for: now)
        let originalId = (itemMetadata.json["id"] as? String) ?? "x"
        let entryId = "\(timestamp)-\(originalId)"

        let entryFolder = trashRoot.appendingPathComponent(entryId)
        try fm.createDirectory(at: entryFolder, withIntermediateDirectories: true)

        // Move original file/folder into the entry folder, keeping its filename
        let source = projectURL.appendingPathComponent(fileRelativePath)
        let dest = entryFolder.appendingPathComponent(source.lastPathComponent)
        try fm.moveItem(at: source, to: dest)

        // Write meta.json
        let meta = TrashMeta(
            originalRelativePath: fileRelativePath,
            displayTitle: displayTitle,
            itemMetadata: itemMetadata,
            originalParentId: originalParentId,
            originalIndex: originalIndex)
        let metaURL = entryFolder.appendingPathComponent("meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: metaURL, options: .atomic)

        return TrashEntry(
            id: entryId,
            trashedAt: now,
            originalRelativePath: fileRelativePath,
            displayTitle: displayTitle,
            itemMetadata: itemMetadata)
    }
```

Helper: a tiny `Data.json` extension for the inline lookup, OR just decode the metadata to extract the id. Cleaner approach:

```swift
private struct _MinimalIdProbe: Decodable { let id: String? }
let originalId = ((try? JSONDecoder().decode(_MinimalIdProbe.self, from: itemMetadata))?.id) ?? "x"
```

Replace the `(itemMetadata.json["id"] as? String) ?? "x"` line with the decoded probe.

- [ ] **Step 4: Run targeted + full suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 474 tests, with 0 failures` (473 prior + 1 new).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/TrashStore.swift MaughamTests/TrashStoreTests.swift
git commit -m "feat: TrashStore.moveToTrash

Moves a file/folder from its original project-relative path into
.trash/<timestamp>-<id>/, with meta.json recording the original
path, display title, item metadata, and original parent/index for
restore.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `TrashStore.restore`

**Files:**
- Modify: `Maugham/Stores/TrashStore.swift`
- Modify: `MaughamTests/TrashStoreTests.swift`

- [ ] **Step 1: Add failing test**

Append to `TrashStoreTests`:

```swift
    func test_restore_movesFileBackAndRemovesEntry() async throws {
        let project = try makeProject()
        let originalFile = project.appendingPathComponent("manuscript/chapter9.md")
        try FileManager.default.createDirectory(
            at: originalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "Chapter 9 content".write(to: originalFile, atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/chapter9.md",
            itemMetadata: Data("{\"id\":\"abc\"}".utf8),
            originalParentId: nil,
            originalIndex: 0,
            displayTitle: "Chapter 9")

        let restored = try await store.restore(trashId: entry.id)

        // File back at original path
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        let content = try String(contentsOf: originalFile, encoding: .utf8)
        XCTAssertEqual(content, "Chapter 9 content")

        // Trash folder removed
        let trashFolder = project.appendingPathComponent(".trash/\(entry.id)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashFolder.path))

        // Returned entry matches what was restored
        XCTAssertEqual(restored.displayTitle, "Chapter 9")
        XCTAssertEqual(restored.originalRelativePath, "manuscript/chapter9.md")
    }
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TrashStoreTests/test_restore_movesFileBackAndRemovesEntry CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: FAIL — `restore` doesn't exist.

- [ ] **Step 3: Implement `restore`**

```swift
    /// Restore a trashed entry: move its file back to original path,
    /// delete the trash folder, return the original metadata.
    @discardableResult
    public func restore(trashId: String) async throws -> TrashEntry {
        let entryFolder = trashRoot.appendingPathComponent(trashId)
        let metaURL = entryFolder.appendingPathComponent("meta.json")
        let metaData = try Data(contentsOf: metaURL)
        let meta = try JSONDecoder().decode(TrashMeta.self, from: metaData)

        // Identify the file inside the entry folder (the non-meta.json file)
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: entryFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        guard let fileURL = contents.first(where: {
            $0.lastPathComponent != "meta.json"
        }) else {
            throw TrashError.entryFileMissing(trashId)
        }

        // Restore to original path; ensure parent dirs exist
        let dest = projectURL.appendingPathComponent(meta.originalRelativePath)
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fm.moveItem(at: fileURL, to: dest)

        // Delete entry folder
        try fm.removeItem(at: entryFolder)

        guard let trashedAt = Self.parseTimestamp(from: trashId) else {
            throw TrashError.malformedEntryId(trashId)
        }
        return TrashEntry(
            id: trashId,
            trashedAt: trashedAt,
            originalRelativePath: meta.originalRelativePath,
            displayTitle: meta.displayTitle,
            itemMetadata: meta.itemMetadata)
    }

    public enum TrashError: Error {
        case entryFileMissing(String)
        case malformedEntryId(String)
    }
```

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 475 tests, with 0 failures`.

```bash
git add Maugham/Stores/TrashStore.swift MaughamTests/TrashStoreTests.swift
git commit -m "feat: TrashStore.restore

Reads meta.json, moves the file/folder back to its original
project-relative path, deletes the .trash/ entry folder, returns
the restored TrashEntry for the caller (typically ProjectStore)
to use as input for re-inserting the manifest entry.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `TrashStore.permanentlyDelete`

**Files:**
- Modify: `Maugham/Stores/TrashStore.swift`
- Modify: `MaughamTests/TrashStoreTests.swift`

- [ ] **Step 1: Add failing test**

```swift
    func test_permanentlyDelete_removesEntryFolder() async throws {
        let project = try makeProject()
        let originalFile = project.appendingPathComponent("manuscript/foo.md")
        try FileManager.default.createDirectory(
            at: originalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "foo".write(to: originalFile, atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/foo.md",
            itemMetadata: Data("{\"id\":\"foo\"}".utf8),
            originalParentId: nil,
            originalIndex: 0,
            displayTitle: "Foo")

        try await store.permanentlyDelete(trashId: entry.id)

        let trashFolder = project.appendingPathComponent(".trash/\(entry.id)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashFolder.path))
    }
```

- [ ] **Step 2: Verify failure + implement**

```swift
    /// Permanently delete a trashed entry.
    public func permanentlyDelete(trashId: String) async throws {
        let entryFolder = trashRoot.appendingPathComponent(trashId)
        try FileManager.default.removeItem(at: entryFolder)
    }
```

- [ ] **Step 3: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 476 tests, with 0 failures`.

```bash
git add Maugham/Stores/TrashStore.swift MaughamTests/TrashStoreTests.swift
git commit -m "feat: TrashStore.permanentlyDelete

Removes a trashed entry's folder unconditionally. Used from the
Trash view's per-row 'Permanently Delete' and 'Empty Trash'
actions, gated behind confirmation modals in the UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: ProjectStore integration — route deletes through trash, restore API, trashEntries surface

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: `MaughamTests/TrashIntegrationTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/TrashIntegrationTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class TrashIntegrationTests: XCTestCase {
    private func makeProjectWithChapter() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter X".write(
            to: tmp.appendingPathComponent("manuscript/chapter-x.md"),
            atomically: true, encoding: .utf8)

        let chapter = StructureItem(
            id: "ch-x", title: "Chapter X", type: .document,
            path: "manuscript/chapter-x.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store, chapter)
    }

    func test_deleteStructureItem_routesToTrash() async throws {
        let (project, store, chapter) = try await makeProjectWithChapter()
        try await store.deleteStructureItem(id: chapter.id)

        XCTAssertEqual(store.manifest.structure.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("manuscript/chapter-x.md").path))
        XCTAssertEqual(store.trashEntries.count, 1)
        XCTAssertEqual(store.trashEntries[0].displayTitle, "Chapter X")
    }

    func test_restoreLastDeleted_bringsBackToOriginalPosition() async throws {
        let (project, store, chapter) = try await makeProjectWithChapter()
        try await store.deleteStructureItem(id: chapter.id)
        try await store.restoreLastDeleted()

        XCTAssertEqual(store.manifest.structure.count, 1)
        XCTAssertEqual(store.manifest.structure[0].id, chapter.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("manuscript/chapter-x.md").path))
        XCTAssertEqual(store.trashEntries.count, 0)
    }

    func test_restoreLastDeleted_whenNothingTrashed_noOps() async throws {
        let (_, store, _) = try await makeProjectWithChapter()
        // Don't delete anything
        try await store.restoreLastDeleted()  // Should not throw
        XCTAssertEqual(store.manifest.structure.count, 1)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TrashIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL — `trashEntries`, `restoreLastDeleted` don't exist; `deleteStructureItem` doesn't route to trash.

- [ ] **Step 3: Add `TrashStore` ownership + `trashEntries`**

In `Maugham/Stores/ProjectStore.swift`, add as stored properties (near the existing properties around line 30):

```swift
public private(set) var trashEntries: [TrashEntry] = []
private(set) var lastDeletedTrashId: String?
public let trashStore: TrashStore
```

In `load(from:)`, after store init, run sweep + load entries:

```swift
let trashStore = TrashStore(projectURL: url)
try? await trashStore.sweep()
let entries = (try? await trashStore.list()) ?? []
// (set trashStore + trashEntries on the constructed ProjectStore)
```

(Adapt to the actual init pattern — `load(from:)` may construct via a private init; thread the values through accordingly.)

- [ ] **Step 4: Rewrite `deleteStructureItem` to route through trash**

Replace the body of `deleteStructureItem(id:)` (around line 804):

```swift
public func deleteStructureItem(id: String) async throws {
    guard let item = findStructureItem(id: id, in: manifest.structure) else {
        return  // Already gone
    }
    let parentId = findStructureParentId(of: id)
    let index = currentStructureIndex(of: id, parentId: parentId)
    let metadata = try JSONEncoder().encode(item)
    let path = item.path ?? ""

    let entry = try await trashStore.moveToTrash(
        fileRelativePath: path,
        itemMetadata: metadata,
        originalParentId: parentId,
        originalIndex: index,
        displayTitle: item.title)

    // Remove from manifest
    removeStructureItem(id: id, from: &manifest.structure)
    try await save()

    // Update trash surface
    trashEntries = (try? await trashStore.list()) ?? trashEntries
    lastDeletedTrashId = entry.id
}

private func findStructureItem(id: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.id == id { return item }
        if let children = item.children,
           let nested = findStructureItem(id: id, in: children) {
            return nested
        }
    }
    return nil
}

private func findStructureParentId(of childId: String) -> String? {
    func walk(_ items: [StructureItem], parent: String?) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children,
               let found = walk(children, parent: item.id) {
                return found
            }
        }
        return nil
    }
    return walk(manifest.structure, parent: nil)
}

private func currentStructureIndex(of id: String, parentId: String?) -> Int {
    let siblings: [StructureItem]
    if let parentId,
       let parent = findStructureItem(id: parentId, in: manifest.structure) {
        siblings = parent.children ?? []
    } else {
        siblings = manifest.structure
    }
    return siblings.firstIndex(where: { $0.id == id }) ?? 0
}

private func removeStructureItem(id: String, from items: inout [StructureItem]) {
    items.removeAll(where: { $0.id == id })
    for i in 0..<items.count {
        if var children = items[i].children {
            removeStructureItem(id: id, from: &children)
            items[i].children = children
        }
    }
}
```

(If `findStructureItem`/`findStructureParentId`/`removeStructureItem` helpers already exist in ProjectStore, reuse them.)

- [ ] **Step 5: Rewrite `deleteResearchItem` similarly**

Mirror the structure for `deleteResearchItem(id:)` (around line 1393) using `ResearchItem` instead of `StructureItem`. Same pattern: find item, record parent/index, encode metadata, move to trash, remove from manifest, save, update trashEntries + lastDeletedTrashId.

- [ ] **Step 6: Add `restoreLastDeleted` + `restoreTrashEntry`**

```swift
public func restoreLastDeleted() async throws {
    guard let id = lastDeletedTrashId else { return }
    try await restoreTrashEntry(id: id)
    lastDeletedTrashId = nil
}

public func restoreTrashEntry(id: String) async throws {
    let entry = try await trashStore.restore(trashId: id)

    // Re-insert into manifest at original parent + index.
    // First try as StructureItem, fall back to ResearchItem.
    if let item = try? JSONDecoder().decode(StructureItem.self, from: entry.itemMetadata) {
        // Decode trash meta for parent/index
        let metaURL = trashStore.projectURL.appendingPathComponent(".trash/\(id)/meta.json")
        // (entry was just removed; we cached enough on entry, but meta is gone)
        // Insert at root for now — accurate parent/index restoration uses meta.json
        // which has already been removed by restore. Solution: have restore return the
        // full TrashMeta. Adjust signature in next iteration; for now append at root.
        manifest.structure.append(item)
    } else if let item = try? JSONDecoder().decode(ResearchItem.self, from: entry.itemMetadata) {
        manifest.research.append(item)
    }
    try await save()
    trashEntries = (try? await trashStore.list()) ?? trashEntries
}

public func permanentlyDeleteTrashEntry(id: String) async throws {
    try await trashStore.permanentlyDelete(trashId: id)
    trashEntries = (try? await trashStore.list()) ?? trashEntries
    if lastDeletedTrashId == id { lastDeletedTrashId = nil }
}

public func emptyTrash() async throws {
    for entry in trashEntries {
        try? await trashStore.permanentlyDelete(trashId: entry.id)
    }
    trashEntries = []
    lastDeletedTrashId = nil
}
```

NOTE: the parent/index restoration is partial in this initial cut — the test only verifies that a top-level chapter restores back to top level. To do precise parent/index, `TrashStore.restore` should return the full `TrashMeta` instead of just a `TrashEntry`. Add this enhancement: extend the return type to `(TrashEntry, originalParentId: String?, originalIndex: Int)`, and use those values in `restoreTrashEntry` to insert at the right position via the existing tree-insert helpers used by `addStructureItem(_:after:)` or write a parallel insert-at-position helper.

- [ ] **Step 7: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 479 tests, with 0 failures` (476 prior + 3 new).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/TrashIntegrationTests.swift
git commit -m "feat: ProjectStore routes deletes through TrashStore

deleteStructureItem and deleteResearchItem now move files to
.trash/ with metadata, instead of hard-deleting. New public surface:
trashEntries (observable list), lastDeletedTrashId (in-memory),
restoreLastDeleted, restoreTrashEntry(id:), permanentlyDeleteTrashEntry,
emptyTrash. Sweep + load runs on ProjectStore.load.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `BinderSegment.trash` + conditional picker + `TrashView` skeleton

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift`
- Modify: `Maugham/Views/BinderPaneToggle.swift`
- Create: `Maugham/Views/TrashView.swift`

- [ ] **Step 1: Add enum case**

In `Maugham/Models/BinderSegment.swift`:

```swift
public enum BinderSegment: String, Codable, Equatable, Sendable {
    case manuscript
    case research
    case scenes
    case trash   // NEW
}
```

- [ ] **Step 2: Conditional picker in BinderPaneToggle**

In `Maugham/Views/BinderPaneToggle.swift`, find the picker and add conditional trash segment:

```swift
struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    // ... existing props

    var body: some View {
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment) {
                if projectType == .screenplay {
                    Text("Scenes").tag(BinderSegment.scenes)
                    Text("Research").tag(BinderSegment.research)
                } else {
                    Text("Manuscript").tag(BinderSegment.manuscript)
                    Text("Research").tag(BinderSegment.research)
                }
                if !store.trashEntries.isEmpty {
                    Text("Trash").tag(BinderSegment.trash)
                }
            }
            // ... existing modifiers

            Group {
                switch segment {
                case .manuscript:
                    BinderView(store: store, selectedItemId: $selectedItemId)
                case .research:
                    ResearchView(store: store, selectedResearchId: $selectedResearchId)
                case .scenes:
                    SceneNavigatorPane(/* existing */)
                case .trash:
                    TrashView(store: store)
                }
            }
        }
    }
}
```

When trashEntries empties (all restored/permanently-deleted), the active segment may be `.trash`. Add `.onChange(of: store.trashEntries)` that coerces back to `.manuscript` when empty:

```swift
.onChange(of: store.trashEntries.count) { _, newValue in
    if newValue == 0 && segment == .trash {
        segment = projectType == .screenplay ? .scenes : .manuscript
    }
}
```

- [ ] **Step 3: Create TrashView skeleton**

Create `Maugham/Views/TrashView.swift`:

```swift
import SwiftUI

struct TrashView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        List(store.trashEntries) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.body)
                Text("Trashed \(daysAgo(entry.trashedAt)), sweep in \(entry.daysRemaining) days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
    }

    private func daysAgo(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let days = Int(elapsed / 86_400)
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}
```

(Actions land in Task 9.)

- [ ] **Step 4: Build + run full suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 479 tests, with 0 failures` (no new tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/BinderSegment.swift Maugham/Views/BinderPaneToggle.swift Maugham/Views/TrashView.swift
git commit -m "feat: BinderSegment.trash + conditional Trash view

BinderPaneToggle's picker shows a third 'Trash' segment when
store.trashEntries is non-empty. TrashView lists entries with
title + days-remaining caption. Restore / Permanently Delete /
Empty Trash actions land in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: TrashView per-row actions + Empty Trash

**Files:**
- Modify: `Maugham/Views/TrashView.swift`

- [ ] **Step 1: Expand TrashView with row actions**

```swift
import SwiftUI

struct TrashView: View {
    @Bindable var store: ProjectStore
    @State private var pendingPermanentDelete: TrashEntry?
    @State private var showingEmptyTrashConfirm = false
    @State private var pendingError: String?

    var body: some View {
        List(store.trashEntries) { entry in
            row(for: entry)
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Empty Trash") {
                    showingEmptyTrashConfirm = true
                }
                .disabled(store.trashEntries.isEmpty)
            }
        }
        .confirmationDialog(
            "Permanently delete this item?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete
        ) { entry in
            Button("Permanently Delete \(entry.displayTitle)", role: .destructive) {
                Task {
                    do {
                        try await store.permanentlyDeleteTrashEntry(id: entry.id)
                    } catch {
                        pendingError = error.localizedDescription
                    }
                    pendingPermanentDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDelete = nil
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $showingEmptyTrashConfirm
        ) {
            Button("Empty Trash", role: .destructive) {
                Task {
                    do {
                        try await store.emptyTrash()
                    } catch {
                        pendingError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(store.trashEntries.count) items will be permanently deleted.")
        }
        .alert("Trash error",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
    }

    private func row(for entry: TrashEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayTitle)
                .font(.body)
            Text("Trashed \(daysAgo(entry.trashedAt)), sweep in \(entry.daysRemaining) days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Restore") {
                Task {
                    do {
                        try await store.restoreTrashEntry(id: entry.id)
                    } catch {
                        pendingError = error.localizedDescription
                    }
                }
            }
            Button("Permanently Delete", role: .destructive) {
                pendingPermanentDelete = entry
            }
        }
    }

    private func daysAgo(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let days = Int(elapsed / 86_400)
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}
```

- [ ] **Step 2: Run full suite + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 479 tests, with 0 failures`.

```bash
git add Maugham/Views/TrashView.swift
git commit -m "feat: Trash view row actions (Restore, Permanently Delete, Empty Trash)

Context menu per row offers Restore (no confirmation, since
restore is undoable by deleting again) and Permanently Delete
(confirmation modal). Toolbar 'Empty Trash' button confirms then
calls store.emptyTrash().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: ⌘Z "Restore Last Deleted Item" menu command

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Add notification**

In `Maugham/Models/MaughamNotifications.swift`, append:

```swift
public static let maughamRestoreLastDeleted = Notification.Name("maugham.restore.last.deleted")
```

- [ ] **Step 2: Add menu command in MaughamApp**

In `Maugham/MaughamApp.swift`, add inside `.commands`:

```swift
CommandGroup(after: .undoRedo) {
    Button("Restore Last Deleted Item") {
        NotificationCenter.default.post(
            name: .maughamRestoreLastDeleted, object: nil)
    }
    .keyboardShortcut("z", modifiers: .command)
}
```

NSTextView's built-in `⌘Z` (text undo) wins when a text view has first responder. When the binder or research view is focused (no text view focused), this button fires.

If implementation reveals dispatch issues, fall back to `modifiers: [.command, .option]` and surface the conflict as a known limitation in the milestone memo.

- [ ] **Step 3: ProjectWindow subscribes**

In `Maugham/Views/ProjectWindow.swift`, add an `.onReceive`:

```swift
.onReceive(NotificationCenter.default.publisher(
    for: .maughamRestoreLastDeleted)) { _ in
    Task {
        try? await store?.restoreLastDeleted()
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. 479 tests passing.

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: ⌘Z Restore Last Deleted Item

Edit menu adds 'Restore Last Deleted Item' bound to ⌘Z. NSTextView's
built-in text undo wins when a text view has focus; binder/research
focus dispatches to ProjectStore.restoreLastDeleted via notification.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Feature B: Inline images

### Task 11: `ImagePasteHandler` utility

**Files:**
- Create: `Maugham/Editor/ImagePasteHandler.swift`
- Test: `MaughamTests/ImagePasteHandlerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/ImagePasteHandlerTests.swift`:

```swift
import XCTest
import AppKit
@testable import Maugham

@MainActor
final class ImagePasteHandlerTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePaste-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        return tmp
    }

    private func makeImage(size: NSSize = NSSize(width: 10, height: 10)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    func test_save_writesPNGToAssetsFolder() throws {
        let project = try makeProject()
        // Create the note file
        try Data().write(to: project.appendingPathComponent("research/sarah.md"))

        let ref = try ImagePasteHandler.saveAndReference(
            image: makeImage(),
            forNoteAt: "research/sarah.md",
            in: project)

        // Assets folder created
        let assets = project.appendingPathComponent("research/sarah_assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))

        // One image file inside
        let contents = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        XCTAssertEqual(contents.count, 1)
        let imageFile = contents[0]
        XCTAssertTrue(imageFile.hasSuffix(".png"))

        // Markdown ref shape
        XCTAssertTrue(ref.hasPrefix("![]("))
        XCTAssertTrue(ref.contains("./sarah_assets/image-"))
        XCTAssertTrue(ref.hasSuffix(".png)"))
    }

    func test_save_intoExistingAssetsFolder_addsSecondImage() throws {
        let project = try makeProject()
        try Data().write(to: project.appendingPathComponent("research/sarah.md"))
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research/sarah_assets"),
            withIntermediateDirectories: true)
        try Data().write(to:
            project.appendingPathComponent("research/sarah_assets/pre-existing.png"))

        _ = try ImagePasteHandler.saveAndReference(
            image: makeImage(),
            forNoteAt: "research/sarah.md",
            in: project)

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: project.appendingPathComponent("research/sarah_assets").path)
        XCTAssertEqual(contents.count, 2,
                       "expected pre-existing + new image; got \(contents)")
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ImagePasteHandlerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement `ImagePasteHandler`**

Create `Maugham/Editor/ImagePasteHandler.swift`:

```swift
import Foundation
import AppKit

/// Saves a pasted NSImage as a PNG file sibling to a research note and
/// returns the Markdown reference to insert at the cursor.
public enum ImagePasteHandler {

    /// Persist `image` to a `<note-slug>_assets/` folder next to the note,
    /// using a timestamp-based filename. Returns a Markdown image ref
    /// `![](./<note-slug>_assets/image-YYYYMMDD-HHMMSS.png)` for insertion.
    @discardableResult
    public static func saveAndReference(
        image: NSImage,
        forNoteAt notePath: String,
        in projectURL: URL
    ) throws -> String {
        let noteURL = projectURL.appendingPathComponent(notePath)
        let noteSlug = noteURL.deletingPathExtension().lastPathComponent
        let assetsDirName = "\(noteSlug)_assets"
        let assetsDir = noteURL
            .deletingLastPathComponent()
            .appendingPathComponent(assetsDirName)

        try FileManager.default.createDirectory(
            at: assetsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())

        // Dedupe on rare same-second paste
        var filename = "image-\(timestamp).png"
        var counter = 2
        while FileManager.default.fileExists(
            atPath: assetsDir.appendingPathComponent(filename).path) {
            filename = "image-\(timestamp)-\(counter).png"
            counter += 1
        }
        let fileURL = assetsDir.appendingPathComponent(filename)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImagePasteError.encodingFailed
        }
        try pngData.write(to: fileURL, options: .atomic)

        return "![](./\(assetsDirName)/\(filename))"
    }

    public enum ImagePasteError: Error {
        case encodingFailed
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 481 tests, with 0 failures` (479 prior + 2 new).

```bash
git add Maugham/Editor/ImagePasteHandler.swift MaughamTests/ImagePasteHandlerTests.swift
git commit -m "feat: ImagePasteHandler utility

Pure function: persist NSImage as PNG to <note-slug>_assets/ sibling
folder with timestamp filename; return Markdown image reference for
cursor insertion. Re-encodes any NSImage (e.g., from clipboard) as
PNG. Per-second collision dedup via counter suffix.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: NSTextView paste override + EditorCoordinator callback

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Editor/EditorSurface.swift`

- [ ] **Step 1: Add callback to EditorCoordinator**

In `Maugham/Editor/EditorCoordinator.swift`, near other callback properties:

```swift
/// Called when the text view receives a paste with image content on the
/// pasteboard. The handler is responsible for saving the image and
/// inserting a Markdown reference. Nil for non-research-note editing.
var imagePasteHandler: ((NSImage) -> Void)?
```

- [ ] **Step 2: Override paste in MaughamTextView**

In `Maugham/Editor/EditorSurface.swift`, find `private final class MaughamTextView: NSTextView` and add:

```swift
override func paste(_ sender: Any?) {
    if let handler = coordinator?.imagePasteHandler,
       NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil),
       let image = NSImage(pasteboard: .general) {
        handler(image)
        return
    }
    super.paste(sender)
}
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham/Editor/EditorSurface.swift
git commit -m "feat: NSTextView intercepts image paste via coordinator handler

MaughamTextView.paste(_:) checks the pasteboard for image content
and routes to coordinator.imagePasteHandler when set. Non-image
paste flows through to standard NSTextView behavior. Handler is
installed by ProjectWindow only when the active document is a
research note.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: ProjectWindow installs paste handler for research notes

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `Maugham/Editor/EditorCoordinator.swift` — add insertText helper if not present

- [ ] **Step 1: Add ProjectWindow logic**

In `Maugham/Views/ProjectWindow.swift`, find where the editor is constructed for a research item (or where `EditorHost` / `EditorSurface` receives an active path). Around the `selectedResearchId` handling:

When the active document is a research note (`ResearchItem.kind == .document`), install a paste handler:

```swift
.onChange(of: selectedResearchId) { _, newId in
    updateImagePasteHandler()
}

private func updateImagePasteHandler() {
    guard let store else { return }
    let coordinator = editorCoordinator  // however ProjectWindow holds the coordinator ref
    guard let id = selectedResearchId,
          let item = findResearchItem(id: id, in: store.manifest.research),
          item.kind == .document,
          let path = item.path else {
        coordinator?.imagePasteHandler = nil
        return
    }
    coordinator?.imagePasteHandler = { [weak coordinator] image in
        guard let coordinator else { return }
        do {
            let ref = try ImagePasteHandler.saveAndReference(
                image: image, forNoteAt: path, in: store.url)
            coordinator.insertText(ref)
        } catch {
            print("Image paste failed:", error)
        }
    }
}
```

ProjectWindow likely doesn't hold the coordinator directly — there's an intermediary `EditorHost` or `EditorCoordinator` is owned by EditorSurface's Coordinator. Adapt to match the actual ownership.

If accessing the coordinator from ProjectWindow proves awkward, an alternative is to move the install logic into the editor layer itself: `EditorSurface` checks the active document's role and installs the handler in `makeNSView`/`updateNSView`. The cleaner architectural choice depends on what's already in place.

- [ ] **Step 2: Add `insertText` on EditorCoordinator if absent**

```swift
func insertText(_ string: String) {
    guard let textView = textView,
          let storage = textView.textStorage else { return }
    let range = textView.selectedRange()
    storage.replaceCharacters(in: range, with: string)
    let newCursor = range.location + (string as NSString).length
    textView.setSelectedRange(NSRange(location: newCursor, length: 0))
}
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Views/ProjectWindow.swift Maugham/Editor/EditorCoordinator.swift
git commit -m "feat: install image paste handler for active research note

When selectedResearchId points to a document-kind research item,
ProjectWindow installs an EditorCoordinator.imagePasteHandler that
calls ImagePasteHandler.saveAndReference and inserts the returned
Markdown ref at the cursor. Cleared when selection changes to a
non-document or to a manuscript item.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: `ResearchNotePreviewPane` view + ⌘ Shift P toggle + UIState

**Files:**
- Create: `Maugham/Views/ResearchNotePreviewPane.swift`
- Modify: `Maugham/Stores/UIState.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: UIState field**

In `Maugham/Stores/UIState.swift`, add:

```swift
public var researchPreviewVisible: Bool
```

Update the init param list (defaulting to `false`), the CodingKeys (if not auto-synthesized), and the decoder fallback.

- [ ] **Step 2: Notification + menu command**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
public static let maughamToggleResearchPreview = Notification.Name("maugham.toggle.research.preview")
```

In `Maugham/MaughamApp.swift`, inside `.commands`:

```swift
CommandGroup(after: .toolbar) {
    Button("Toggle Research Preview") {
        NotificationCenter.default.post(
            name: .maughamToggleResearchPreview, object: nil)
    }
    .keyboardShortcut("p", modifiers: [.command, .shift])
}
```

- [ ] **Step 3: Create ResearchNotePreviewPane**

Create `Maugham/Views/ResearchNotePreviewPane.swift`:

```swift
import SwiftUI
import AppKit

struct ResearchNotePreviewPane: View {
    let notePath: String       // "research/sarah.md"
    let projectURL: URL
    @Binding var noteText: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(parsedBlocks().indices, id: \.self) { i in
                    render(block: parsedBlocks()[i])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    enum Block {
        case paragraph(AttributedString)
        case image(NSImage)
        case unknown(String)
    }

    private func parsedBlocks() -> [Block] {
        let lines = noteText.components(separatedBy: "\n")
        var blocks: [Block] = []
        let imageRegex = try? NSRegularExpression(
            pattern: #"^!\[.*?\]\((\./[^)]+)\)$"#)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let regex = imageRegex,
               let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(location: 0, length: (trimmed as NSString).length)),
               match.numberOfRanges >= 2 {
                let pathRange = match.range(at: 1)
                let relPath = (trimmed as NSString).substring(with: pathRange)
                let noteDir = projectURL.appendingPathComponent(notePath).deletingLastPathComponent()
                let imageURL = noteDir.appendingPathComponent(
                    relPath.hasPrefix("./") ? String(relPath.dropFirst(2)) : relPath)
                if let img = NSImage(contentsOf: imageURL) {
                    blocks.append(.image(img))
                    continue
                }
            }

            if let attr = try? AttributedString(markdown: trimmed) {
                blocks.append(.paragraph(attr))
            } else {
                blocks.append(.unknown(trimmed))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func render(block: Block) -> some View {
        switch block {
        case .paragraph(let attr):
            Text(attr)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 300)
        case .unknown(let raw):
            Text(raw)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: ProjectWindow integration**

In `Maugham/Views/ProjectWindow.swift`:

```swift
@State private var researchPreviewVisible: Bool = false

// In load(), hydrate from documentStore.uiState
researchPreviewVisible = documentStore.uiState.researchPreviewVisible

// .onReceive for the toggle notification
.onReceive(NotificationCenter.default.publisher(
    for: .maughamToggleResearchPreview)) { _ in
    researchPreviewVisible.toggle()
    documentStore?.updateUIState { $0.researchPreviewVisible = researchPreviewVisible }
}
```

In the editor pane layout, when `researchPreviewVisible && activeDocumentIsResearchNote`, split horizontally between editor and `ResearchNotePreviewPane`:

```swift
HSplitView {
    EditorHost(/* ... */)
    if researchPreviewVisible && isResearchNoteActive {
        ResearchNotePreviewPane(
            notePath: activeNotePath,
            projectURL: store.url,
            noteText: $editorText)
    }
}
```

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. 481 tests passing.

```bash
git add Maugham/Views/ResearchNotePreviewPane.swift Maugham/Stores/UIState.swift Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: ⌘ Shift P toggles ResearchNotePreviewPane

New view splits the editor pane horizontally when editing a research
note and showing-preview is on. Renders the note's Markdown line by
line, replacing solo image references with NSImage views. Persistence
via UIState.researchPreviewVisible.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Rename propagation for `_assets/` folder + internal refs

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` — extend rename pipeline
- Test: `MaughamTests/RenameWithAssetsTests.swift`

- [ ] **Step 1: Write failing test**

Create `MaughamTests/RenameWithAssetsTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class RenameWithAssetsTests: XCTestCase {
    func test_renamingNote_alsoRenamesAssetsFolderAndUpdatesRefs() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameAssets-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research/old-name_assets"),
            withIntermediateDirectories: true)
        try Data().write(
            to: project.appendingPathComponent("research/old-name_assets/image-1.png"))
        let noteContent = """
        # Old Name

        ![](./old-name_assets/image-1.png)

        Some prose.
        """
        try noteContent.write(
            to: project.appendingPathComponent("research/old-name.md"),
            atomically: true, encoding: .utf8)

        let note = ResearchItem(
            id: "note-1",
            title: "Old Name",
            type: .asset,
            kind: .document,
            path: "research/old-name.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [note])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: project.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: project)
        try await store.renameResearchItem(id: "note-1", newTitle: "New Name")

        // Old folder gone
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/old-name_assets").path))
        // New folder exists with the image
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("research/new-name_assets/image-1.png").path))
        // Note content updated
        let updated = try String(
            contentsOf: project.appendingPathComponent("research/new-name.md"),
            encoding: .utf8)
        XCTAssertTrue(updated.contains("./new-name_assets/image-1.png"))
        XCTAssertFalse(updated.contains("./old-name_assets"))
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/RenameWithAssetsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: FAIL or COMPILE FAIL — `renameResearchItem` doesn't handle assets folder.

- [ ] **Step 3: Extend rename pipeline**

Find `renameResearchItem` in `ProjectStore.swift` (or the equivalent — search for `renameStructureItem` if research uses the same pipeline). After the existing file-rename step, before saving the manifest, detect-and-rename the assets folder + update internal refs.

Pseudocode for the new logic at the end of the rename method (just before `try await save()`):

```swift
// Propagate rename to <slug>_assets/ folder + internal Markdown refs.
if oldPath != newPath {
    let oldSlug = oldPath.deletingPathExtension().lastPathComponent
    let newSlug = newPath.deletingPathExtension().lastPathComponent
    let oldAssetsURL = oldPath.deletingLastPathComponent()
        .appendingPathComponent("\(oldSlug)_assets")
    let newAssetsURL = newPath.deletingLastPathComponent()
        .appendingPathComponent("\(newSlug)_assets")

    if FileManager.default.fileExists(atPath: oldAssetsURL.path) {
        try FileManager.default.moveItem(at: oldAssetsURL, to: newAssetsURL)

        // Update internal refs in the renamed note
        var content = (try? String(contentsOf: newPath, encoding: .utf8)) ?? ""
        let oldRef = "./\(oldSlug)_assets/"
        let newRef = "./\(newSlug)_assets/"
        content = content.replacingOccurrences(of: oldRef, with: newRef)
        try content.write(to: newPath, atomically: true, encoding: .utf8)
    }
}
```

(Adapt to actual `oldPath`/`newPath` variable names in the existing implementation. `oldPath` and `newPath` should be URLs to the old and new note files.)

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 482 tests, with 0 failures` (481 prior + 1 new).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/RenameWithAssetsTests.swift
git commit -m "feat: renaming a research note propagates to its assets folder

When renaming a .md research note that has a sibling
<old-slug>_assets/ folder, the folder is renamed to
<new-slug>_assets/ and any internal Markdown refs in the note
content are updated from ./old-slug_assets/ to ./new-slug_assets/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Smoke + tag

### Task 16: Manual smoke checkpoint

- [ ] **Smoke checklist**

Build and launch:

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Then manually verify:

1. Right-click research → "New Note" → enters rename mode → type name → file exists at `research/<slug>.md`.
2. Paste an image into the note → file appears in `research/<slug>_assets/`, Markdown ref at cursor.
3. ⌘ Shift P → preview pane opens beside the editor → image renders inline.
4. Toggle preview off → pane disappears.
5. Type multi-paragraph note with mixed text + image refs → preview renders all paragraphs correctly.
6. Rename the note → assets folder renamed → preview still shows image (refs updated).
7. Delete chapter from manuscript binder → file moves to `.trash/`; Trash segment appears in picker.
8. ⌘Z → chapter restored to manuscript at original position; Trash segment hides if empty.
9. Delete 2 items → ⌘Z restores only the second; first still in Trash view → Restore via Trash view → manuscript has both back.
10. Close window + reopen → Trash view shows previously-non-restored entries.
11. Trash view → context menu → Permanently Delete → confirm modal → entry gone from `.trash/`.
12. Trash view → Empty Trash toolbar → confirm → all entries gone.
13. Pre-set a `.trash/` entry's timestamp to 31 days ago via terminal (`mv .trash/20260510-153045-x .trash/20260410-153045-x`) → relaunch → entry swept silently.
14. Phase 3c features unaffected (parser, scene navigator, ⌘/ syntax help, inline emphasis).

If any fail, fix before tagging.

### Task 17: Tag the milestone

- [ ] **Push + tag**

```bash
git push origin main
git tag -a milestone-research-polish -m "Research polish — Group 1, first milestone

Three bundled features:
- New Text Note creation in research browser
- Inline images for research notes with preview pane (⌘ Shift P)
- Trash & undo for binder operations (.trash/, ⌘Z, 30-day sweep)

482 tests passing."
git push origin milestone-research-polish
```

- [ ] **Update memory**

Create `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_research_polish.md` describing what shipped, with API surface notes and the deferred items.

Add entry to MEMORY.md index.

---

## Spec coverage check

| Spec section | Covered by task(s) |
|---|---|
| Feature A: New Text Note — public API + UI | T1, T2 |
| Feature A: dedup, group-aware path | T1 |
| Feature B: ImagePasteHandler utility | T11 |
| Feature B: paste interception in MaughamTextView | T12 |
| Feature B: ProjectWindow installs handler | T13 |
| Feature B: ResearchNotePreviewPane + ⌘ Shift P + UIState | T14 |
| Feature B: rename propagation | T15 |
| Feature C: TrashEntry + TrashStore (list, sweep) | T3 |
| Feature C: TrashStore.moveToTrash | T4 |
| Feature C: TrashStore.restore | T5 |
| Feature C: TrashStore.permanentlyDelete | T6 |
| Feature C: ProjectStore integration + restoreLastDeleted | T7 |
| Feature C: BinderSegment.trash + conditional picker + TrashView skeleton | T8 |
| Feature C: TrashView actions (Restore, Permanently Delete, Empty Trash) | T9 |
| Feature C: ⌘Z menu command | T10 |
| Smoke + tag | T16, T17 |

Test count target: 466 → 482 (16 new tests). All spec sections mapped.
