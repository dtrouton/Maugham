# Mixed-Content Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ProjectType.collection` functional. A Collection holds a flat list of "pieces" — each is either a loose mixed-content document (`.md` prose or `.fountain` screenplay, with its own optional research subfolder) or a reference to a standalone Maugham project. Pieces can be promoted from loose to standalone.

**Architecture:** Additive optional fields on `StructureItem` (`pieceKind`, `pageTarget`, `linkedProjectPath`, `linkedProjectBookmark`). Folder-per-piece on disk (`pieces/<NN>-<slug>/`). New `ProjectStore` APIs for piece + reference creation, resolution, and promotion. Collection-specific binder (Pieces / Research-with-Shared+per-piece / Find / Trash). Inspector polymorphic per piece kind. Right-pane Outline mode hidden in Collection windows. Promote-to-standalone uses atomic staging + replaceItemAt.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, security-scoped bookmarks (`NSURL.bookmarkData`), existing `ProjectSearchEngine`, existing `FountainTokenizer`, existing right-pane mode-swap pattern.

**Reference spec:** `docs/superpowers/specs/2026-05-16-mixed-content-collection-design.md`. Related ADRs: [0005](../../adr/0005-right-pane-mode-swap.md), [0008](../../adr/0008-id-prefix-cleanup.md), [0009](../../adr/0009-collection-references-mac-local.md).

---

## File map

**Create:**
- `Maugham/Models/PieceKind.swift` — `.loose` / `.reference` enum
- `Maugham/Models/CollectionLinkFile.swift` — `.maugham-link.json` model (Codable)
- `Maugham/Views/CollectionBinderPaneToggle.swift` — Collection-specific binder shell
- `Maugham/Views/CollectionPiecesPane.swift` — flat list of pieces
- `Maugham/Views/PieceRow.swift` — single piece row with kind icon + status dot
- `Maugham/Views/CollectionResearchPane.swift` — two-section Research segment (Shared + active piece)
- `Maugham/Views/ProsePieceInspector.swift`
- `Maugham/Views/ScreenplayPieceInspector.swift`
- `Maugham/Views/ReferencePieceInspector.swift`
- `Maugham/Views/ReferencePlaceholderCard.swift` — editor-pane placeholder when a reference is selected
- `MaughamTests/Collection/StructureItemPieceFieldsTests.swift`
- `MaughamTests/Collection/CollectionFactoryTests.swift`
- `MaughamTests/Collection/AddLoosePieceTests.swift`
- `MaughamTests/Collection/AddProjectReferenceTests.swift`
- `MaughamTests/Collection/ResolveReferenceTests.swift`
- `MaughamTests/Collection/PieceResearchTests.swift`
- `MaughamTests/Collection/PromotePieceTests.swift`
- `MaughamTests/Collection/CollectionSearchTests.swift`

**Modify:**
- `Maugham/Models/StructureItem.swift` — add 4 optional fields
- `Maugham/Stores/ProjectFactory.swift` — Collection projects also create `pieces/` directory
- `Maugham/Stores/ProjectStore.swift` — `addLoosePiece`, `addProjectReference`, `resolveReference`, `addPieceResearchNote`, `promotePieceToProject`
- `Maugham/Views/ProjectWindow.swift` — switch to CollectionBinderPaneToggle when manifest.type == .collection; conditional ⌘N / ⌘⇧N; hide Outline mode in DetailPaneToggle for Collections; goal indicator polymorphism
- `Maugham/Views/DetailPaneToggle.swift` — accept a `hideOutline: Bool` flag
- `Maugham/MaughamApp.swift` — File menu: New Prose Story / New Screenplay / Link Existing Project conditional commands
- `Maugham/Models/MaughamNotifications.swift` — `maughamAddLoosePiece`, `maughamAddScreenplayPiece`, `maughamLinkProject`

---

## Phase 1 — Data layer

### Task 1: PieceKind enum + StructureItem field additions

**Files:**
- Create: `Maugham/Models/PieceKind.swift`
- Modify: `Maugham/Models/StructureItem.swift`
- Test: `MaughamTests/Collection/StructureItemPieceFieldsTests.swift`

The current `StructureItem` at `Maugham/Models/StructureItem.swift` (47 lines) has `id`, `title`, `type` (`.group`/`.document`), `path`, `synopsis`, `status`, `wordTarget`, `tags`, `links`, `children`, `linkedResearchIds`. We add 4 additive optional fields. Existing Novel / Short Story / Screenplay manifests round-trip cleanly because all new fields default to nil.

- [ ] **Step 1: Write failing tests**

Create directory `MaughamTests/Collection/` then `MaughamTests/Collection/StructureItemPieceFieldsTests.swift`:

```swift
import XCTest
@testable import Maugham

final class StructureItemPieceFieldsTests: XCTestCase {
    func test_pieceKind_roundTrip() throws {
        let item = StructureItem(
            id: "doc-1", title: "Story A", type: .document,
            pieceKind: .loose)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.pieceKind, .loose)
    }

    func test_pageTarget_roundTrip() throws {
        let item = StructureItem(
            id: "doc-1", title: "Screenplay A", type: .document,
            pageTarget: 5, pieceKind: .loose)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.pageTarget, 5)
    }

    func test_linkedProjectFields_roundTrip() throws {
        let bookmark = Data([0x01, 0x02, 0x03])
        let item = StructureItem(
            id: "doc-1", title: "The Long One", type: .document,
            pieceKind: .reference,
            linkedProjectPath: "/Users/x/Projects/Long",
            linkedProjectBookmark: bookmark)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.linkedProjectPath, "/Users/x/Projects/Long")
        XCTAssertEqual(decoded.linkedProjectBookmark, bookmark)
        XCTAssertEqual(decoded.pieceKind, .reference)
    }

    func test_olderManifest_decodesWithNilDefaults() throws {
        // No piece-kind fields in the JSON — pre-collection-milestone manifest shape.
        let raw = """
        {"id":"doc-1","title":"Ch 1","type":"document","path":"manuscript/c1.md"}
        """
        let item = try JSONDecoder().decode(StructureItem.self, from: Data(raw.utf8))
        XCTAssertNil(item.pieceKind)
        XCTAssertNil(item.pageTarget)
        XCTAssertNil(item.linkedProjectPath)
        XCTAssertNil(item.linkedProjectBookmark)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
cd /Users/denver/src/Maugham
xcodegen generate
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/StructureItemPieceFieldsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL — `pieceKind`, `pageTarget`, etc. don't exist on StructureItem.

- [ ] **Step 3: Implement PieceKind**

Create `Maugham/Models/PieceKind.swift`:

```swift
import Foundation

/// Distinguishes a Collection piece that's a loose document (with its own
/// folder + main doc + optional research/) from one that's a reference to
/// a standalone Maugham project elsewhere on disk.
public enum PieceKind: String, Codable, Equatable, Sendable {
    case loose
    case reference
}
```

- [ ] **Step 4: Extend StructureItem**

In `Maugham/Models/StructureItem.swift`, add the four optional fields before `children` and update the init to include them. Final shape:

```swift
public struct StructureItem: Codable, Equatable, Identifiable, Sendable {
    public enum ItemType: String, Codable, Sendable {
        case group, document
    }

    public var id: String
    public var title: String
    public var type: ItemType
    public var path: String?
    public var synopsis: String?
    public var status: String?
    public var wordTarget: Int?
    public var pageTarget: Int?              // NEW
    public var pieceKind: PieceKind?         // NEW
    public var linkedProjectPath: String?    // NEW
    public var linkedProjectBookmark: Data?  // NEW
    public var tags: [String]?
    public var links: [String]?
    public var children: [StructureItem]?
    public var linkedResearchIds: [String]?

    public init(
        id: String,
        title: String,
        type: ItemType,
        path: String? = nil,
        synopsis: String? = nil,
        status: String? = nil,
        wordTarget: Int? = nil,
        pageTarget: Int? = nil,
        pieceKind: PieceKind? = nil,
        linkedProjectPath: String? = nil,
        linkedProjectBookmark: Data? = nil,
        tags: [String]? = nil,
        links: [String]? = nil,
        children: [StructureItem]? = nil,
        linkedResearchIds: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.path = path
        self.synopsis = synopsis
        self.status = status
        self.wordTarget = wordTarget
        self.pageTarget = pageTarget
        self.pieceKind = pieceKind
        self.linkedProjectPath = linkedProjectPath
        self.linkedProjectBookmark = linkedProjectBookmark
        self.tags = tags
        self.links = links
        self.children = children
        self.linkedResearchIds = linkedResearchIds
    }
}
```

Existing callers of the init use trailing labels; all 4 new params have defaults so no caller needs updating.

- [ ] **Step 5: Run tests + commit**

```bash
xcodegen generate
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 589 tests, with 0 failures` (585 prior + 4 new).

```bash
git add Maugham/Models/PieceKind.swift Maugham/Models/StructureItem.swift MaughamTests/Collection/StructureItemPieceFieldsTests.swift
git commit -m "feat: PieceKind enum + StructureItem fields for Collection pieces

Additive optional fields: pageTarget, pieceKind, linkedProjectPath,
linkedProjectBookmark. Pre-collection-milestone manifests round-trip
cleanly because all new fields default to nil. PieceKind.loose
denotes a loose mixed-content document; PieceKind.reference denotes
a pointer to a standalone Maugham project.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: CollectionLinkFile model

**Files:**
- Create: `Maugham/Models/CollectionLinkFile.swift`
- Test: extend `MaughamTests/Collection/StructureItemPieceFieldsTests.swift` (or new test file)

`.maugham-link.json` is the on-disk representation of a Collection reference. Lives at `pieces/<NN>-<slug>/.maugham-link.json` inside the Collection.

- [ ] **Step 1: Write failing tests**

Append to `MaughamTests/Collection/StructureItemPieceFieldsTests.swift` (or create a new file `MaughamTests/Collection/CollectionLinkFileTests.swift`):

```swift
final class CollectionLinkFileTests: XCTestCase {
    func test_linkFile_roundTrip() throws {
        let now = Date()
        let file = CollectionLinkFile(
            version: 1,
            title: "The Long One",
            path: "/Users/denver/Documents/Long",
            bookmark: "AAEC",
            linkedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CollectionLinkFile.self, from: data)
        XCTAssertEqual(decoded.title, "The Long One")
        XCTAssertEqual(decoded.path, "/Users/denver/Documents/Long")
        XCTAssertEqual(decoded.bookmark, "AAEC")
        XCTAssertEqual(decoded.version, 1)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/CollectionLinkFileTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement CollectionLinkFile**

Create `Maugham/Models/CollectionLinkFile.swift`:

```swift
import Foundation

/// `.maugham-link.json` — the on-disk representation of a Collection's
/// reference to a standalone Maugham project. Lives at
/// `pieces/<NN>-<slug>/.maugham-link.json`.
///
/// `path` is the absolute path at link-time; used for display + best-effort
/// fallback when the bookmark fails (e.g., cross-Mac via iCloud).
/// `bookmark` is base64-encoded NSURL.bookmarkData with .withSecurityScope.
public struct CollectionLinkFile: Codable, Equatable, Sendable {
    public var version: Int
    public var title: String
    public var path: String
    public var bookmark: String
    public var linkedAt: Date

    public init(version: Int, title: String, path: String, bookmark: String, linkedAt: Date) {
        self.version = version
        self.title = title
        self.path = path
        self.bookmark = bookmark
        self.linkedAt = linkedAt
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 590 tests, with 0 failures` (589 + 1).

```bash
git add Maugham/Models/CollectionLinkFile.swift MaughamTests/Collection/StructureItemPieceFieldsTests.swift
git commit -m "feat: CollectionLinkFile model for .maugham-link.json

Codable shape for the link file Maugham writes inside each
reference's piece folder. Stores title (seed from linked project),
absolute path (for display + best-effort fallback), base64
security-scoped bookmark, and linkedAt timestamp.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: ProjectFactory creates pieces/ directory

**Files:**
- Modify: `Maugham/Stores/ProjectFactory.swift`
- Test: Create `MaughamTests/Collection/CollectionFactoryTests.swift`

Collection projects currently create `research/` and `notes/`. They also need `pieces/`.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/Collection/CollectionFactoryTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class CollectionFactoryTests: XCTestCase {
    func test_createCollectionProject_createsPiecesDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CF-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let pieces = url.appendingPathComponent("pieces")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pieces.path),
            "Collection project should create pieces/ directory")

        // Also still creates research/ and notes/
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("notes").path))
    }

    func test_createCollectionProject_manifestStructureEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CF2-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manifest.type, .collection)
        XCTAssertEqual(store.manifest.structure.count, 0)
        XCTAssertEqual(store.manifest.research.count, 0)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodegen generate
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/CollectionFactoryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: FAIL — `pieces/` directory not created.

- [ ] **Step 3: Modify createCollectionProject**

In `Maugham/Stores/ProjectFactory.swift`, find `createCollectionProject` (around line 99). Inside the `do` block, after the existing `try fm.createDirectory(at: projectURL.appendingPathComponent("notes"), ...)` line, add:

```swift
try fm.createDirectory(at: projectURL.appendingPathComponent("pieces"),
                       withIntermediateDirectories: true)
```

The block now creates research/, notes/, pieces/. The manifest doesn't change shape.

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 592 tests, with 0 failures` (590 + 2).

```bash
git add Maugham/Stores/ProjectFactory.swift MaughamTests/Collection/CollectionFactoryTests.swift
git commit -m "feat: Collection projects create pieces/ directory at init

Mirrors existing research/ + notes/. Empty pieces/ awaits the first
loose piece or project reference. Manifest unchanged on shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — ProjectStore mutations

### Task 4: addLoosePiece(title:mode:)

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: Create `MaughamTests/Collection/AddLoosePieceTests.swift`

`addLoosePiece` creates `pieces/<NN>-<slug>/<slug>.<ext>` + `pieces/<NN>-<slug>/research/`, then writes a StructureItem with `pieceKind: .loose`. The `<NN>` prefix uses the same `FileNaming` machinery Maugham already uses for chapters.

`PieceMode` mirrors the file extension choice:

```swift
public enum PieceMode {
    case prose       // → .md
    case screenplay  // → .fountain
}
```

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/Collection/AddLoosePieceTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class AddLoosePieceTests: XCTestCase {
    private func makeCollection() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "Test", in: tmp)
        let store = try await ProjectStore.load(from: url)
        return (url, store)
    }

    func test_addLoosePiece_prose_createsFolderDocAndResearch() async throws {
        let (url, store) = try await makeCollection()
        let piece = try await store.addLoosePiece(
            title: "The Lighthouse Keeper", mode: .prose)

        XCTAssertEqual(piece.pieceKind, .loose)
        XCTAssertEqual(piece.type, .document)
        XCTAssertTrue(piece.path?.hasSuffix(".md") == true)

        let pieceFolder = url.appendingPathComponent(
            piece.path!).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pieceFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pieceFolder.appendingPathComponent("research").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(piece.path!).path))

        XCTAssertEqual(store.manifest.structure.count, 1)
        XCTAssertEqual(store.manifest.structure[0].id, piece.id)
    }

    func test_addLoosePiece_screenplay_createsFountain() async throws {
        let (_, store) = try await makeCollection()
        let piece = try await store.addLoosePiece(
            title: "The Visit", mode: .screenplay)
        XCTAssertTrue(piece.path?.hasSuffix(".fountain") == true)
        XCTAssertEqual(piece.pieceKind, .loose)
    }

    func test_addLoosePiece_dedupsSlugCollision() async throws {
        let (_, store) = try await makeCollection()
        _ = try await store.addLoosePiece(title: "Story", mode: .prose)
        let piece2 = try await store.addLoosePiece(title: "Story", mode: .prose)
        XCTAssertTrue(piece2.path?.contains("story-2") == true,
            "second 'Story' should dedup to story-2; got: \(piece2.path ?? "nil")")
    }

    func test_addLoosePiece_assignsContiguousNumericPrefix() async throws {
        let (url, store) = try await makeCollection()
        let p1 = try await store.addLoosePiece(title: "A", mode: .prose)
        let p2 = try await store.addLoosePiece(title: "B", mode: .prose)

        // Folder names start with 01-, 02-
        let p1Folder = url.appendingPathComponent(
            p1.path!).deletingLastPathComponent().lastPathComponent
        let p2Folder = url.appendingPathComponent(
            p2.path!).deletingLastPathComponent().lastPathComponent
        XCTAssertTrue(p1Folder.hasPrefix("01-"), "got: \(p1Folder)")
        XCTAssertTrue(p2Folder.hasPrefix("02-"), "got: \(p2Folder)")
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/AddLoosePieceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL — `addLoosePiece` doesn't exist.

- [ ] **Step 3: Implement PieceMode + addLoosePiece**

In `Maugham/Stores/ProjectStore.swift`, near the existing `addStructureItem` method (around line 175), add:

```swift
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

    // Slug dedup against existing pieces
    var slug = Slugifier.slug(from: baseTitle) ?? "piece"
    var resolvedTitle = baseTitle
    var counter = 2
    let existingSlugs = Set(manifest.structure.compactMap { piece -> String? in
        guard let path = piece.path else { return nil }
        // path is "pieces/<NN>-<slug>/<slug>.<ext>"; pull the doc slug from
        // the file's basename without extension.
        return (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: ".fountain", with: "")
    })
    while existingSlugs.contains(slug) {
        slug = "\(Slugifier.slug(from: baseTitle) ?? "piece")-\(counter)"
        resolvedTitle = "\(baseTitle) \(counter)"
        counter += 1
    }

    // Folder NN prefix — find max existing prefix and increment.
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
        let folderName = ((path as NSString).deletingLastPathComponent
            as NSString).lastPathComponent
        let parts = folderName.components(separatedBy: "-")
        guard let first = parts.first, let n = Int(first) else { return nil }
        return n
    }
    return (prefixes.max() ?? 0) + 1
}
```

NOTE: `Slugifier.slug(from:)` already exists in `Maugham/Models/Slugifier.swift`. Confirm its exact signature by grep before final code; if it returns `String?` use `?? "piece"` like above.

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 596 tests, with 0 failures` (592 + 4).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/Collection/AddLoosePieceTests.swift
git commit -m "feat: ProjectStore.addLoosePiece(title:mode:)

Creates pieces/<NN>-<slug>/ with the main doc and an empty research/.
Slug deduplication mirrors the New Text Note pattern. NN prefix
assigned by next-available logic. PieceMode.prose creates .md;
PieceMode.screenplay creates .fountain. Manifest entry tagged with
pieceKind: .loose.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: addProjectReference(targetURL:)

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: Create `MaughamTests/Collection/AddProjectReferenceTests.swift`

Reads the target's manifest for title seed, creates a security-scoped bookmark, writes `.maugham-link.json` inside `pieces/<NN>-<slug>/`, adds a StructureItem with `pieceKind: .reference`.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/Collection/AddProjectReferenceTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class AddProjectReferenceTests: XCTestCase {
    private func makeCollectionAndTarget() async throws -> (collection: URL, target: URL, store: ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("APR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let target = try await ProjectFactory.createShortStoryProject(
            named: "The Long One", in: tmp)
        let store = try await ProjectStore.load(from: collection)
        return (collection, target, store)
    }

    func test_addProjectReference_seedsTitleFromTarget() async throws {
        let (_, target, store) = try await makeCollectionAndTarget()
        let piece = try await store.addProjectReference(targetURL: target)
        XCTAssertEqual(piece.title, "The Long One")
        XCTAssertEqual(piece.pieceKind, .reference)
        XCTAssertNotNil(piece.linkedProjectBookmark)
        XCTAssertEqual(piece.linkedProjectPath, target.path)
    }

    func test_addProjectReference_writesLinkFile() async throws {
        let (collection, target, store) = try await makeCollectionAndTarget()
        let piece = try await store.addProjectReference(targetURL: target)
        let linkFileURL = collection.appendingPathComponent(piece.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkFileURL.path))
        let data = try Data(contentsOf: linkFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let link = try decoder.decode(CollectionLinkFile.self, from: data)
        XCTAssertEqual(link.title, "The Long One")
        XCTAssertEqual(link.path, target.path)
        XCTAssertFalse(link.bookmark.isEmpty)
    }

    func test_addProjectReference_failsOnNonProjectFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("APR-bad-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: collection)

        let notAProject = tmp.appendingPathComponent("just-a-folder")
        try FileManager.default.createDirectory(at: notAProject, withIntermediateDirectories: true)

        do {
            _ = try await store.addProjectReference(targetURL: notAProject)
            XCTFail("expected throw")
        } catch {
            // ok
        }
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/AddProjectReferenceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement addProjectReference**

Append to `Maugham/Stores/ProjectStore.swift` (near `addLoosePiece`):

```swift
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
    let targetManifestURL = targetURL.appendingPathComponent("project.maugham.json")
    guard FileManager.default.fileExists(atPath: targetManifestURL.path) else {
        throw ProjectStoreError.fileSystemError(
            "Selected folder is not a Maugham project: \(targetURL.path)")
    }
    let data = try Data(contentsOf: targetManifestURL)
    let targetManifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
    let title = targetManifest.title

    // Slug from title; dedup against existing pieces (same logic as addLoosePiece)
    var slug = Slugifier.slug(from: title) ?? "linked-project"
    let existingSlugs = Set(manifest.structure.compactMap { piece -> String? in
        guard let path = piece.path else { return nil }
        let folderName = ((path as NSString).deletingLastPathComponent
            as NSString).lastPathComponent
        let parts = folderName.components(separatedBy: "-").dropFirst()
        return parts.joined(separator: "-")
    })
    var counter = 2
    while existingSlugs.contains(slug) {
        slug = "\(Slugifier.slug(from: title) ?? "linked-project")-\(counter)"
        counter += 1
    }

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
```

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 599 tests, with 0 failures` (596 + 3).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/Collection/AddProjectReferenceTests.swift
git commit -m "feat: ProjectStore.addProjectReference(targetURL:)

Validates the target has a project.maugham.json. Reads target title
from its manifest as the reference's display title. Generates a
security-scoped bookmark. Writes .maugham-link.json inside
pieces/<NN>-<slug>/. Manifest entry tagged with pieceKind: .reference
and linkedProjectPath + linkedProjectBookmark populated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: resolveReference + ReferenceResolution result type

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: Create `MaughamTests/Collection/ResolveReferenceTests.swift`

Resolution order: bookmark → path fallback (with silent re-bookmark on success) → unresolved.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/Collection/ResolveReferenceTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class ResolveReferenceTests: XCTestCase {
    func test_resolveReference_bookmarkResolves_returnsURL() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let target = try await ProjectFactory.createShortStoryProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: collection)
        let piece = try await store.addProjectReference(targetURL: target)

        let resolution = store.resolveReference(piece)
        switch resolution {
        case .resolved(let url):
            XCTAssertEqual(url.standardized.path, target.standardized.path)
        case .resolvedViaPathFallback, .unresolved:
            XCTFail("expected .resolved, got: \(resolution)")
        }
    }

    func test_resolveReference_bookmarkFails_pathSucceeds_resolvesViaFallback() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-fb-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let target = try await ProjectFactory.createShortStoryProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: collection)
        var piece = try await store.addProjectReference(targetURL: target)

        // Corrupt the bookmark to force fallback
        piece.linkedProjectBookmark = Data([0xFF])

        let resolution = store.resolveReference(piece)
        switch resolution {
        case .resolvedViaPathFallback(let url):
            XCTAssertEqual(url.standardized.path, target.standardized.path)
        case .resolved, .unresolved:
            XCTFail("expected fallback, got: \(resolution)")
        }
    }

    func test_resolveReference_bothFail_returnsUnresolved() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR-un-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: collection)

        let piece = StructureItem(
            id: "doc-x",
            title: "Gone",
            type: .document,
            pieceKind: .reference,
            linkedProjectPath: "/nope/does/not/exist",
            linkedProjectBookmark: Data([0xFF]))

        let resolution = store.resolveReference(piece)
        switch resolution {
        case .unresolved:
            break  // ok
        case .resolved, .resolvedViaPathFallback:
            XCTFail("expected unresolved, got: \(resolution)")
        }
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/ResolveReferenceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement ReferenceResolution + resolveReference**

Append to `Maugham/Stores/ProjectStore.swift`:

```swift
public enum ReferenceResolution: Equatable {
    case resolved(URL)
    case resolvedViaPathFallback(URL)
    case unresolved
}

public func resolveReference(_ piece: StructureItem) -> ReferenceResolution {
    guard piece.pieceKind == .reference else { return .unresolved }
    // Bookmark path
    if let bookmark = piece.linkedProjectBookmark {
        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale) {
            // Validate it still points at a project
            let manifestURL = resolved.appendingPathComponent("project.maugham.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return .resolved(resolved)
            }
        }
    }
    // Path fallback
    if let pathStr = piece.linkedProjectPath {
        let candidate = URL(fileURLWithPath: pathStr)
        let manifestURL = candidate.appendingPathComponent("project.maugham.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return .resolvedViaPathFallback(candidate)
        }
    }
    return .unresolved
}
```

NOTE: the spec describes a "silent re-bookmark" when the path fallback succeeds. That's a mutation of the manifest entry. To keep `resolveReference` pure (read-only), we expose a second method `refreshReferenceBookmark(pieceId:from:)` that callers invoke when they get `.resolvedViaPathFallback`. Tests for `refreshReferenceBookmark` aren't strictly required for v1 — the resolution chain works correctly; re-bookmarking is an optimization.

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 602 tests, with 0 failures` (599 + 3).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/Collection/ResolveReferenceTests.swift
git commit -m "feat: ProjectStore.resolveReference + ReferenceResolution

Three-way result: .resolved (bookmark worked), .resolvedViaPathFallback
(bookmark failed but path matches a valid Maugham project — cross-Mac
iCloud case per ADR 0009), .unresolved (neither worked).

resolveReference is read-only; refreshReferenceBookmark (optional
write to upgrade fallback to a fresh bookmark) is a separate method
that callers invoke on demand.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: addPieceResearchNote(pieceId:title:)

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: Create `MaughamTests/Collection/PieceResearchTests.swift`

Analogue of existing `addResearchTextNote` but lands inside `pieces/<piece-slug>/research/` rather than top-level `research/`. The research item's `path` is relative to the project root, e.g., `pieces/01-story-a/research/notes.md`.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/Collection/PieceResearchTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class PieceResearchTests: XCTestCase {
    private func makeCollectionWithPiece() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
    }

    func test_addPieceResearchNote_landsInPieceFolder() async throws {
        let (url, store, piece) = try await makeCollectionWithPiece()
        let note = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Sarah Notes")
        XCTAssertTrue(note.path?.hasPrefix("pieces/01-story-a/research/") == true,
            "expected pieces/01-story-a/research/; got: \(note.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(note.path!).path))
    }

    func test_addPieceResearchNote_unknownPiece_throws() async throws {
        let (_, store, _) = try await makeCollectionWithPiece()
        do {
            _ = try await store.addPieceResearchNote(
                pieceId: "doc-nope", title: "x")
            XCTFail("expected throw")
        } catch {
            // ok
        }
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/PieceResearchTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement addPieceResearchNote**

Append to `Maugham/Stores/ProjectStore.swift`:

```swift
/// Add a research note inside a piece's research/ subfolder. Adds a
/// ResearchItem to manifest.research with a piece-scoped path. The note
/// is project-local research from the manifest's POV — discoverability
/// in the binder is done by path-prefix matching (UI layer).
public func addPieceResearchNote(
    pieceId: String, title: String
) async throws -> ResearchItem {
    guard manifest.type == .collection else {
        throw ProjectStoreError.fileSystemError(
            "addPieceResearchNote only valid for Collection projects")
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
    let researchFolderURL = url.appendingPathComponent(researchFolder)
    try FileManager.default.createDirectory(
        at: researchFolderURL, withIntermediateDirectories: true)

    let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = baseTitle.isEmpty ? "Untitled Note" : baseTitle
    let slug = Self.researchSlugify(resolvedTitle)
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
```

NOTE: `researchSlugify` is the existing helper used by `addResearchTextNote` (around line 1305 in ProjectStore.swift). Reuse it.

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 604 tests, with 0 failures` (602 + 2).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/Collection/PieceResearchTests.swift
git commit -m "feat: ProjectStore.addPieceResearchNote(pieceId:title:)

Creates an empty .md research note inside the named piece's
pieces/<NN>-<slug>/research/ folder. Adds a ResearchItem to
manifest.research with a piece-scoped path. UI layer filters
research items into Shared vs piece-scoped sections by
path-prefix matching (next phase).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Collection binder UI

### Task 8: PieceRow + CollectionPiecesPane

**Files:**
- Create: `Maugham/Views/PieceRow.swift`
- Create: `Maugham/Views/CollectionPiecesPane.swift`

A flat SwiftUI List of pieces, each row showing kind icon + title + status dot. Selection bound to `selectedItemId` (same binding the existing binder uses).

- [ ] **Step 1: Implement PieceRow**

Create `Maugham/Views/PieceRow.swift`:

```swift
import SwiftUI

/// One row in the Collection's Pieces segment: kind icon, title, status dot.
struct PieceRow: View {
    let piece: StructureItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            Text(piece.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let status = piece.status, !status.isEmpty {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var iconName: String {
        switch piece.pieceKind {
        case .reference:
            return "link"
        case .loose, .none:
            if let path = piece.path, path.hasSuffix(".fountain") {
                return "film"
            }
            return "doc.text"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "draft":     return .gray
        case "revising":  return .orange
        case "final":     return .green
        default:          return .secondary
        }
    }
}
```

- [ ] **Step 2: Implement CollectionPiecesPane**

Create `Maugham/Views/CollectionPiecesPane.swift`:

```swift
import SwiftUI

/// The Pieces segment of a Collection binder. Flat list with kind icons.
struct CollectionPiecesPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    let onAddPiece: () -> Void   // opens the new-piece menu

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.manifest.structure.isEmpty {
                ContentUnavailableView {
                    Label("No pieces yet", systemImage: "doc.text")
                } description: {
                    Text("Add your first piece. Use the + button.")
                }
            } else {
                List(selection: $selectedItemId) {
                    ForEach(store.manifest.structure) { piece in
                        PieceRow(piece: piece)
                            .tag(piece.id as String?)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Pieces").font(.headline)
            Spacer()
            Button {
                onAddPiece()
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("Add a piece")
        }
        .padding(8)
    }
}
```

- [ ] **Step 3: Build + commit (no tests yet — UI views; covered by smoke)**

```bash
xcodegen generate
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED. (PieceRow + CollectionPiecesPane reference no UI sites yet, so they compile in isolation.)

```bash
git add Maugham/Views/PieceRow.swift Maugham/Views/CollectionPiecesPane.swift
git commit -m "feat: PieceRow + CollectionPiecesPane

Flat-list view of Collection pieces. Kind icon (doc.text for prose,
film for screenplay, link for reference). Status dot. Header with
'+' to open the new-piece menu (wired in T15).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: CollectionResearchPane (Shared + per-piece sections)

**Files:**
- Create: `Maugham/Views/CollectionResearchPane.swift`

The Research segment for a Collection. Two sections: Shared (research items whose path is outside `pieces/`), and `<active piece title>` (research items whose path starts with `pieces/<active-piece-slug>/research/`). When no piece is selected, only Shared renders.

- [ ] **Step 1: Implement**

Create `Maugham/Views/CollectionResearchPane.swift`:

```swift
import SwiftUI

struct CollectionResearchPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedResearchId: String?
    let activePiece: StructureItem?
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void

    var body: some View {
        List(selection: $selectedResearchId) {
            Section {
                ForEach(sharedItems()) { item in
                    Text(item.title).tag(item.id as String?)
                }
            } header: {
                HStack {
                    Text("Shared")
                    Spacer()
                    Button(action: onAddSharedNote) {
                        Image(systemName: "plus.circle")
                    }.buttonStyle(.plain)
                }
            }
            if let piece = activePiece, piece.pieceKind == .loose {
                Section {
                    let items = pieceItems(piece: piece)
                    if items.isEmpty {
                        Text("No research yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            Text(item.title).tag(item.id as String?)
                        }
                    }
                } header: {
                    HStack {
                        Text(piece.title)
                        Spacer()
                        Button(action: onAddPieceNote) {
                            Image(systemName: "plus.circle")
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sharedItems() -> [ResearchItem] {
        store.manifest.research.filter { item in
            guard let path = item.path else { return true }
            return !path.hasPrefix("pieces/")
        }
    }

    private func pieceItems(piece: StructureItem) -> [ResearchItem] {
        guard let piecePath = piece.path else { return [] }
        let pieceFolder = (piecePath as NSString).deletingLastPathComponent
        let prefix = "\(pieceFolder)/research/"
        return store.manifest.research.filter { item in
            item.path?.hasPrefix(prefix) == true
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Views/CollectionResearchPane.swift
git commit -m "feat: CollectionResearchPane — Shared + per-piece sections

Filters manifest.research by path prefix to split into Shared (paths
not starting with pieces/) and the active piece's (paths starting with
pieces/<piece-folder>/research/). Section headers carry add-note
buttons; piece section only renders when a loose piece is selected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: CollectionBinderPaneToggle

**Files:**
- Create: `Maugham/Views/CollectionBinderPaneToggle.swift`

The Collection-specific binder shell. Hosts Pieces / Research / Find / Trash segments. Mirrors `BinderPaneToggle` for Novel but renders Collection-specific panes.

- [ ] **Step 1: Implement**

Create `Maugham/Views/CollectionBinderPaneToggle.swift`:

```swift
import SwiftUI

struct CollectionBinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedItemId: String?
    @Binding var selectedResearchId: String?
    @Binding var findActive: Bool
    let activePiece: StructureItem?
    let onAddPiece: () -> Void
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment) {
                Image(systemName: "doc.text").tag(BinderSegment.manuscript)
                Image(systemName: "books.vertical").tag(BinderSegment.research)
                Image(systemName: "magnifyingglass").tag(BinderSegment.find)
                Image(systemName: "trash").tag(BinderSegment.trash)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch segment {
                case .manuscript:
                    CollectionPiecesPane(
                        store: store,
                        selectedItemId: $selectedItemId,
                        onAddPiece: onAddPiece)
                case .research:
                    CollectionResearchPane(
                        store: store,
                        selectedResearchId: $selectedResearchId,
                        activePiece: activePiece,
                        onAddSharedNote: onAddSharedNote,
                        onAddPieceNote: onAddPieceNote)
                case .find:
                    // Reuse existing ProjectSearchView; manuscript scope already
                    // walks structure recursively (which for a Collection means
                    // walking pieces).
                    ProjectSearchView(
                        store: store,
                        findActive: $findActive,
                        onSelectMatch: { match in
                            selectedItemId = match.documentId
                            segment = .manuscript
                        })
                case .trash, .scenes:
                    // Trash uses existing TrashPane (or analogue). For Collection
                    // milestone scope, use the existing pattern from Novel.
                    Text("Trash / segments shared with Novel")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
```

NOTE: this stub uses `BinderSegment.scenes` as a no-op for Collection (it doesn't apply but the enum lists it). The trash branch uses a placeholder; the existing `TrashPane` in `ProjectWindow.swift` (or wherever it lives) should be reused — confirm during implementation. The find branch reuses the existing `ProjectSearchView` which already walks `manifest.structure` recursively; for a Collection that's the pieces, so search works without further plumbing.

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Views/CollectionBinderPaneToggle.swift
git commit -m "feat: CollectionBinderPaneToggle — Collection binder shell

Mirrors BinderPaneToggle. Pieces / Research / Find / Trash segments.
Find reuses ProjectSearchView (structure-walking already covers
pieces). Trash placeholder pending unification with Novel's
trash pane in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Wire CollectionBinderPaneToggle into ProjectWindow

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

When `manifest.type == .collection`, ProjectWindow renders `CollectionBinderPaneToggle` in place of `BinderPaneToggle`. The active piece is `manifest.structure.first(where: { $0.id == selectedItemId })`.

- [ ] **Step 1: Add the conditional binder rendering**

In `Maugham/Views/ProjectWindow.swift`, find where `BinderPaneToggle` is constructed in the `NavigationSplitView`'s `sidebar` slot. Wrap it in a conditional:

```swift
NavigationSplitView {
    if store.manifest.type == .collection {
        CollectionBinderPaneToggle(
            store: store,
            segment: $binderSegment,
            selectedItemId: $selectedItemId,
            selectedResearchId: $selectedResearchId,
            findActive: $findActive,
            activePiece: activePiece(),
            onAddPiece: { /* T15 wires the menu */ },
            onAddSharedNote: { Task { try? await addSharedNoteAction() } },
            onAddPieceNote: { Task { try? await addPieceNoteAction() } }
        )
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } else {
        BinderPaneToggle(
            store: store,
            segment: $binderSegment,
            selectedItemId: $selectedItemId,
            selectedResearchId: $selectedResearchId,
            projectType: store.manifest.type,
            lastParsedScript: lastParsedScript,
            findActive: $findActive)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}
```

Add the helper methods near other private funcs in ProjectWindow:

```swift
private func activePiece() -> StructureItem? {
    guard store?.manifest.type == .collection,
          let id = selectedItemId else { return nil }
    return store?.manifest.structure.first(where: { $0.id == id })
}

private func addSharedNoteAction() async throws {
    guard let store else { return }
    let item = try await store.addResearchTextNote(parentId: nil, title: "Untitled Note")
    selectedResearchId = item.id
}

private func addPieceNoteAction() async throws {
    guard let store, let pieceId = selectedItemId else { return }
    let item = try await store.addPieceResearchNote(
        pieceId: pieceId, title: "Untitled Note")
    selectedResearchId = item.id
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 604 tests, with 0 failures`.

```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "feat: ProjectWindow renders CollectionBinderPaneToggle for collections

Branches in the sidebar slot: Collection projects get the new
binder; Novel/Short Story/Screenplay keep BinderPaneToggle.
Active piece resolved from selectedItemId for the Research
segment's per-piece header. New-piece menu wired in T15.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Inspector polymorphism

### Task 12: ProsePieceInspector + ScreenplayPieceInspector + ReferencePieceInspector

**Files:**
- Create: `Maugham/Views/ProsePieceInspector.swift`
- Create: `Maugham/Views/ScreenplayPieceInspector.swift`
- Create: `Maugham/Views/ReferencePieceInspector.swift`
- Create: `Maugham/Views/ReferencePlaceholderCard.swift`

Three inspector views, each tailored to a piece kind, plus an editor-pane placeholder for references.

- [ ] **Step 1: Implement the three inspectors**

`Maugham/Views/ProsePieceInspector.swift`:

```swift
import SwiftUI

struct ProsePieceInspector: View {
    @Bindable var store: ProjectStore
    let pieceId: String

    var body: some View {
        if let piece = store.manifest.structure.first(where: { $0.id == pieceId }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(piece.title).font(.headline)
                Text("Prose").font(.caption).foregroundStyle(.secondary)
                // Reuse existing InspectorView's metadata pieces — synopsis,
                // status, tags, word target, linked research. Implementation
                // detail: extract the relevant Section views from InspectorView
                // into shared helpers, OR inline them here using the same
                // shape. For v1 inline for simplicity.
                synopsisSection(piece: piece)
                statusSection(piece: piece)
                wordTargetSection(piece: piece)
                Spacer()
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select a piece", systemImage: "doc.text")
        }
    }

    @ViewBuilder private func synopsisSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Synopsis").font(.caption).foregroundStyle(.secondary)
            TextField("Optional summary",
                      text: Binding(
                        get: { piece.synopsis ?? "" },
                        set: { newValue in updateSynopsis(piece: piece, newValue: newValue) }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
        }
    }

    @ViewBuilder private func statusSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.caption).foregroundStyle(.secondary)
            Picker("Status", selection: Binding(
                get: { piece.status ?? "draft" },
                set: { newValue in updateStatus(piece: piece, newValue: newValue) })) {
                Text("Draft").tag("draft")
                Text("Revising").tag("revising")
                Text("Final").tag("final")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder private func wordTargetSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Word target").font(.caption).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { piece.wordTarget ?? 0 },
                set: { newValue in updateWordTarget(piece: piece, newValue: newValue) }),
                in: 0...100000, step: 100) {
                Text("\(piece.wordTarget ?? 0)")
            }
        }
    }

    private func updateSynopsis(piece: StructureItem, newValue: String) {
        var copy = piece
        copy.synopsis = newValue.isEmpty ? nil : newValue
        Task { try? await store.updateStructureItem(copy) }
    }

    private func updateStatus(piece: StructureItem, newValue: String) {
        var copy = piece
        copy.status = newValue
        Task { try? await store.updateStructureItem(copy) }
    }

    private func updateWordTarget(piece: StructureItem, newValue: Int) {
        var copy = piece
        copy.wordTarget = newValue == 0 ? nil : newValue
        Task { try? await store.updateStructureItem(copy) }
    }
}
```

NOTE: `store.updateStructureItem(_:)` may or may not exist with that exact signature. Look at how the existing `InspectorView` writes through to store and mirror the pattern. If the existing pattern uses a `manifest.modifyItem(id:transform:)` helper, use that instead.

`Maugham/Views/ScreenplayPieceInspector.swift` — same structure, but `pageTarget` instead of `wordTarget`:

```swift
import SwiftUI

struct ScreenplayPieceInspector: View {
    @Bindable var store: ProjectStore
    let pieceId: String

    var body: some View {
        if let piece = store.manifest.structure.first(where: { $0.id == pieceId }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(piece.title).font(.headline)
                Text("Screenplay").font(.caption).foregroundStyle(.secondary)
                synopsisSection(piece: piece)
                statusSection(piece: piece)
                pageTargetSection(piece: piece)
                Spacer()
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select a piece", systemImage: "film")
        }
    }

    // synopsisSection + statusSection same as ProsePieceInspector — duplicate
    // verbatim or extract into shared helpers (pick one for consistency).

    @ViewBuilder private func pageTargetSection(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Page target").font(.caption).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { piece.pageTarget ?? 0 },
                set: { newValue in updatePageTarget(piece: piece, newValue: newValue) }),
                in: 0...500, step: 1) {
                Text("\(piece.pageTarget ?? 0) pages")
            }
        }
    }

    private func updatePageTarget(piece: StructureItem, newValue: Int) {
        var copy = piece
        copy.pageTarget = newValue == 0 ? nil : newValue
        Task { try? await store.updateStructureItem(copy) }
    }

    // (synopsisSection, statusSection, updateSynopsis, updateStatus same as ProsePieceInspector)
}
```

(Implementer can choose to extract shared helpers if duplication bothers; for v1 inline duplication is fine.)

`Maugham/Views/ReferencePieceInspector.swift`:

```swift
import SwiftUI
import AppKit

struct ReferencePieceInspector: View {
    @Bindable var store: ProjectStore
    let pieceId: String
    @State private var resolution: ReferenceResolution?

    var body: some View {
        if let piece = store.manifest.structure.first(where: { $0.id == pieceId }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(piece.title).font(.headline)
                    .textSelection(.enabled)
                Text("Linked project").font(.caption).foregroundStyle(.secondary)
                statusRow(piece: piece)
                Text(piece.linkedProjectPath ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                actionButtons(piece: piece)
                Spacer()
            }
            .padding(16)
            .task(id: pieceId) {
                resolution = store.resolveReference(piece)
            }
        }
    }

    @ViewBuilder private func statusRow(piece: StructureItem) -> some View {
        HStack {
            switch resolution {
            case .resolved, .resolvedViaPathFallback:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Resolved").font(.callout)
            case .unresolved:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Unresolved").font(.callout)
            case .none:
                ProgressView()
            }
        }
    }

    @ViewBuilder private func actionButtons(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open in New Window") {
                openInWindow(piece: piece)
            }
            .buttonStyle(.borderedProminent)
            .disabled(resolution == .unresolved)

            Button("Reveal in Finder") {
                guard let pathStr = piece.linkedProjectPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: pathStr)])
            }

            Button("Re-link…") {
                relink(piece: piece)
            }

            Button("Remove", role: .destructive) {
                Task { try? await store.deleteStructureItem(id: piece.id) }
            }
        }
    }

    private func openInWindow(piece: StructureItem) {
        let url: URL
        switch resolution {
        case .resolved(let u): url = u
        case .resolvedViaPathFallback(let u): url = u
        default: return
        }
        NotificationCenter.default.post(
            name: .maughamOpenProject,
            object: nil,
            userInfo: ["url": url])
    }

    private func relink(piece: StructureItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let newURL = panel.url else { return }
            Task {
                try? await store.relinkReference(pieceId: piece.id, newURL: newURL)
                resolution = store.resolveReference(piece)
            }
        }
    }
}
```

NOTE: `store.relinkReference(pieceId:newURL:)` and `store.deleteStructureItem(id:)` may need to be added or confirmed. `deleteStructureItem` likely already exists from milestone 2a's binder operations. `relinkReference` is new — add it to ProjectStore in this task or T13 (see fallback note).

Create `Maugham/Views/ReferencePlaceholderCard.swift`:

```swift
import SwiftUI

/// Editor-pane placeholder shown when a project reference is selected.
struct ReferencePlaceholderCard: View {
    let piece: StructureItem
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(piece.title).font(.title2)
            Text("Linked project")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open in New Window", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Add `relinkReference` and verify `updateStructureItem` / `deleteStructureItem` exist**

Append to `Maugham/Stores/ProjectStore.swift`:

```swift
public func relinkReference(pieceId: String, newURL: URL) async throws {
    guard let idx = manifest.structure.firstIndex(where: { $0.id == pieceId }) else {
        throw ProjectStoreError.fileSystemError("Unknown piece: \(pieceId)")
    }
    guard manifest.structure[idx].pieceKind == .reference,
          let relPath = manifest.structure[idx].path else {
        throw ProjectStoreError.fileSystemError("Piece is not a reference")
    }
    // Validate target
    let targetManifestURL = newURL.appendingPathComponent("project.maugham.json")
    guard FileManager.default.fileExists(atPath: targetManifestURL.path) else {
        throw ProjectStoreError.fileSystemError(
            "Selected folder is not a Maugham project")
    }
    let bookmarkData = try newURL.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
    manifest.structure[idx].linkedProjectPath = newURL.path
    manifest.structure[idx].linkedProjectBookmark = bookmarkData

    // Rewrite .maugham-link.json
    let linkURL = url.appendingPathComponent(relPath)
    let linkFile = CollectionLinkFile(
        version: 1,
        title: manifest.structure[idx].title,
        path: newURL.path,
        bookmark: bookmarkData.base64EncodedString(),
        linkedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(linkFile).write(to: linkURL, options: .atomic)

    manifest.modified = Date()
    try await saveManifest()
}

/// Generic StructureItem field updater — applies the change to the matching
/// item (recursively in structure, since Collection pieces are top-level but
/// the helper is general-purpose). If a method with similar functionality
/// already exists in ProjectStore (e.g., updateStructureItemTitle, etc.),
/// reuse it instead of adding this one.
public func updateStructureItem(_ updated: StructureItem) async throws {
    guard let idx = manifest.structure.firstIndex(where: { $0.id == updated.id }) else {
        // Fall through to recursive search if your data model nests
        throw ProjectStoreError.fileSystemError("Unknown item: \(updated.id)")
    }
    manifest.structure[idx] = updated
    manifest.modified = Date()
    try await saveManifest()
}
```

NOTE: `updateStructureItem` may already exist in ProjectStore for the inspector pattern from milestone 2c. Grep `grep -n "updateStructureItem\|setSynopsis\|setStatus\|setWordTarget" Maugham/Stores/ProjectStore.swift` to check. If it exists, omit this helper and use what's there.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Views/ProsePieceInspector.swift Maugham/Views/ScreenplayPieceInspector.swift Maugham/Views/ReferencePieceInspector.swift Maugham/Views/ReferencePlaceholderCard.swift Maugham/Stores/ProjectStore.swift
git commit -m "feat: piece-kind-polymorphic Inspectors + reference placeholder card

Three Inspector views (prose / screenplay / reference) for Collection
pieces. Prose shows word target; Screenplay shows page target;
Reference shows resolution status + Open in New Window + Reveal in
Finder + Re-link + Remove. ReferencePlaceholderCard is the editor-
pane content when a reference is selected.

ProjectStore.relinkReference rewrites the .maugham-link.json with a
fresh bookmark for the picked URL.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: DetailPaneToggle hides Outline for Collections; ProjectWindow routes Inspector

**Files:**
- Modify: `Maugham/Views/DetailPaneToggle.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

`DetailPaneToggle` (from writing-companion milestone) currently shows three segments: Inspector / Linked Research / Outline. For Collection windows, the Outline segment doesn't apply — hide it.

- [ ] **Step 1: Add `hideOutline` parameter to DetailPaneToggle**

In `Maugham/Views/DetailPaneToggle.swift`, find the Picker that contains the three DetailSegment cases. Add a new parameter `let hideOutline: Bool = false` to the struct and wrap the `Outline` tag in a conditional:

```swift
struct DetailPaneToggle<Inspector: View>: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedItemId: String?
    let activeManuscriptItemId: String?
    let hideOutline: Bool                  // NEW (default false)
    @ViewBuilder var inspectorContent: () -> Inspector

    var body: some View {
        VStack(spacing: 0) {
            Picker("Right pane", selection: $segment) {
                Image(systemName: "info.circle").tag(DetailSegment.inspector)
                Image(systemName: "doc.text.magnifyingglass").tag(DetailSegment.research)
                if !hideOutline {
                    Image(systemName: "list.bullet.indent").tag(DetailSegment.outline)
                }
            }
            // ... rest unchanged
        }
    }
}
```

Update all call sites of `DetailPaneToggle` to pass `hideOutline:`. In `ProjectWindow.swift`, pass `true` when `store.manifest.type == .collection`; otherwise `false`.

If `segment == .outline` and `hideOutline == true`, fall back to `.inspector` automatically (in the body's switch on segment, treat `.outline` as a redirect to `.inspector` when `hideOutline` is true).

- [ ] **Step 2: ProjectWindow routes Inspector polymorphism**

In `Maugham/Views/ProjectWindow.swift`, find the `inspectorPane(store:)` method (was last modified in writing-companion milestone). For Collections, the inspector branch shows one of the three piece inspectors based on the active piece's `pieceKind` / mode:

```swift
@ViewBuilder
private func inspectorPane(store: ProjectStore) -> some View {
    DetailPaneToggle(
        store: store,
        segment: $detailSegment,
        outlineLayout: $outlineLayout,
        selectedItemId: $selectedItemId,
        activeManuscriptItemId: selectedItemId,
        hideOutline: store.manifest.type == .collection
    ) {
        if store.manifest.type == .collection {
            collectionInspector(store: store)
        } else {
            existingInspectorSwitch(store: store)
        }
    }
}

@ViewBuilder
private func collectionInspector(store: ProjectStore) -> some View {
    if let id = selectedItemId,
       let piece = store.manifest.structure.first(where: { $0.id == id }) {
        switch piece.pieceKind {
        case .reference:
            ReferencePieceInspector(store: store, pieceId: id)
        case .loose, .none:
            if let path = piece.path, path.hasSuffix(".fountain") {
                ScreenplayPieceInspector(store: store, pieceId: id)
            } else {
                ProsePieceInspector(store: store, pieceId: id)
            }
        }
    } else {
        ContentUnavailableView("Select a piece", systemImage: "doc.text")
    }
}

@ViewBuilder
private func existingInspectorSwitch(store: ProjectStore) -> some View {
    // The original switch on binderSegment that wraps InspectorView /
    // InspectorResearchPanel / unavailable views — unchanged from
    // writing-companion milestone's implementation.
    switch binderSegment {
    case .manuscript, .scenes, .find:
        InspectorView(
            store: store,
            selectedItemId: selectedItemId,
            metrics: metrics,
            onOpenProjectSettings: { activeSheet = .projectSettings })
    case .research:
        if let id = selectedResearchId,
           let item = findResearchItem(id: id, in: store.manifest.research) {
            InspectorResearchPanel(store: store, item: item)
        } else {
            ContentUnavailableView("Select an item", systemImage: "info.circle")
        }
    case .trash:
        ContentUnavailableView("No selection", systemImage: "trash")
    }
}
```

- [ ] **Step 3: Editor pane handles references**

In `ProjectWindow.editorPane(store:documentStore:)`, add an early return for Collection-with-reference:

```swift
@ViewBuilder
private func editorPane(
    store: ProjectStore, documentStore: DocumentStore
) -> some View {
    if store.manifest.type == .collection,
       let id = selectedItemId,
       let piece = store.manifest.structure.first(where: { $0.id == id }),
       piece.pieceKind == .reference {
        ReferencePlaceholderCard(piece: piece) {
            openReferenceInWindow(piece: piece, store: store)
        }
    } else {
        // ... existing switch on binderSegment unchanged
        existingEditorSwitch(store: store, documentStore: documentStore)
    }
}

private func openReferenceInWindow(piece: StructureItem, store: ProjectStore) {
    let resolution = store.resolveReference(piece)
    let url: URL
    switch resolution {
    case .resolved(let u): url = u
    case .resolvedViaPathFallback(let u): url = u
    case .unresolved: return
    }
    NotificationCenter.default.post(
        name: .maughamOpenProject, object: nil, userInfo: ["url": url])
}
```

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 604 tests, with 0 failures`.

```bash
git add Maugham/Views/DetailPaneToggle.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: Inspector + editor pane polymorphic for Collection pieces

DetailPaneToggle gains hideOutline flag — set true for Collections
(pieces are flat). ProjectWindow's inspector pane branches on
manifest.type: Collection routes through collectionInspector which
picks the right piece inspector based on pieceKind + file extension.
Editor pane shows ReferencePlaceholderCard when a reference piece
is selected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Creation flow

### Task 14: Goal indicator polymorphism for Collections

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

`goalIndicatorState` currently checks `store.manifest.type == .screenplay`. For Collections, it should pick the active piece's mode.

- [ ] **Step 1: Update goalIndicatorState**

In `Maugham/Views/ProjectWindow.swift`, find the `goalIndicatorState` computed property and update:

```swift
private var goalIndicatorState: GoalIndicatorState {
    guard let store else { return .empty }
    let currentDoc = selectedItemId.flatMap {
        findItem(id: $0, in: store.manifest.structure)
    }

    // For a Collection, derive isScreenplay from the active piece, not the
    // project. Reference pieces hide the goal indicator entirely.
    let isScreenplay: Bool
    let docWordTarget: Int?
    let docPageTarget: Int?
    if store.manifest.type == .collection {
        if let piece = currentDoc, piece.pieceKind == .reference {
            return .empty  // hidden for references
        }
        if let path = currentDoc?.path, path.hasSuffix(".fountain") {
            isScreenplay = true
            docWordTarget = nil
            docPageTarget = currentDoc?.pageTarget
        } else {
            isScreenplay = false
            docWordTarget = currentDoc?.wordTarget
            docPageTarget = nil
        }
    } else {
        isScreenplay = store.manifest.type == .screenplay
        docWordTarget = currentDoc?.wordTarget
        docPageTarget = nil
    }

    return GoalIndicatorState(
        docWordCount: metrics.wordCount,
        docWordTarget: docWordTarget,
        projectWordCount: store.projectWordCount,
        projectWordTarget: store.manifest.targets?.totalWords,
        wordsToday: sessionLog.wordsToday(),
        readingMinutes: metrics.readingMinutes,
        pageCount: metrics.pageCount,
        pageTarget: store.manifest.type == .collection ? docPageTarget : store.manifest.targets?.pageTarget,
        isScreenplay: isScreenplay)
}
```

NOTE: the `GoalIndicatorState` shape may need a way to express "hide the capsule." If it doesn't currently, returning `.empty` from `goalIndicatorState` when reference is selected covers the hide case (assuming `GoalIndicatorView` hides on empty state, which it does for the no-project case today).

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "feat: goal indicator polymorphic per piece in Collections

Reference piece → goal capsule hides. Loose prose piece → word
metrics. Loose screenplay piece → page metrics. Same machinery as
Novel/Screenplay for non-Collections.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: New-piece menu + File menu items + conditional ⌘N / ⌘⇧N

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

Three actions need wiring: New Prose Story, New Screenplay, Link Existing Project. Wired via:
- Right-click on Pieces segment (in CollectionPiecesPane's `onAddPiece` callback)
- `+` button in Pieces segment header
- File menu items (with conditional ⌘N / ⌘⇧N override when a Collection window is focused)

- [ ] **Step 1: Add notification names**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
public static let maughamAddLoosePiece = Notification.Name("maugham.add.loose.piece")
public static let maughamAddScreenplayPiece = Notification.Name("maugham.add.screenplay.piece")
public static let maughamLinkProject = Notification.Name("maugham.link.project")
```

- [ ] **Step 2: Add File menu items in MaughamApp**

In `Maugham/MaughamApp.swift`, find the `CommandGroup(replacing: .newItem)` block (existing — has the current New Project / Open Project items). After New Project, add conditional commands. Pattern:

```swift
CommandGroup(after: .newItem) {
    Divider()
    Button("New Prose Story") {
        NotificationCenter.default.post(
            name: .maughamAddLoosePiece, object: nil)
    }
    .keyboardShortcut("n", modifiers: .command)
    // Note: ⌘N is currently bound to "New Project". When a Collection
    // window is focused, this Button takes precedence due to first
    // responder hit-test ordering in NSMenu. If you'd rather avoid the
    // override behavior, drop the .keyboardShortcut here.

    Button("New Screenplay (Collection)") {
        NotificationCenter.default.post(
            name: .maughamAddScreenplayPiece, object: nil)
    }
    .keyboardShortcut("n", modifiers: [.command, .shift])

    Button("Link Existing Project…") {
        NotificationCenter.default.post(
            name: .maughamLinkProject, object: nil)
    }
}
```

If the conditional-shortcut override turns out to be awkward in practice (e.g., ⌘N globally still triggers New Project even with a Collection focused), the simpler resolution is to drop the keyboard shortcuts here and ship the menu items as discoverable-only. Implementer can choose.

- [ ] **Step 3: ProjectWindow listens for the notifications**

In `Maugham/Views/ProjectWindow.swift`, add `.onReceive` handlers (alongside other `maugham*` notifications):

```swift
.onReceive(NotificationCenter.default.publisher(for: .maughamAddLoosePiece)) { _ in
    guard let store, store.manifest.type == .collection else { return }
    Task {
        let piece = try? await store.addLoosePiece(title: "Untitled Piece", mode: .prose)
        if let piece { selectedItemId = piece.id }
    }
}
.onReceive(NotificationCenter.default.publisher(for: .maughamAddScreenplayPiece)) { _ in
    guard let store, store.manifest.type == .collection else { return }
    Task {
        let piece = try? await store.addLoosePiece(title: "Untitled Screenplay", mode: .screenplay)
        if let piece { selectedItemId = piece.id }
    }
}
.onReceive(NotificationCenter.default.publisher(for: .maughamLinkProject)) { _ in
    guard let store, store.manifest.type == .collection else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.begin { response in
        guard response == .OK, let target = panel.url else { return }
        Task {
            let piece = try? await store.addProjectReference(targetURL: target)
            if let piece { selectedItemId = piece.id }
        }
    }
}
```

- [ ] **Step 4: Wire the `+` button in CollectionBinderPaneToggle**

The `onAddPiece` callback in CollectionBinderPaneToggle (added in T11) currently is `{ /* T15 wires the menu */ }`. Update it to post a notification:

```swift
onAddPiece: {
    // Show a small popup menu at the +-button location.
    // Simplest implementation: just default to "New Prose Story" —
    // users discover screenplay + link via the File menu.
    NotificationCenter.default.post(name: .maughamAddLoosePiece, object: nil)
},
```

If you want the `+` button to show a popup menu (Prose / Screenplay / Link), wrap it in a `Menu` element in `CollectionPiecesPane.header`:

```swift
private var header: some View {
    HStack {
        Text("Pieces").font(.headline)
        Spacer()
        Menu {
            Button("New Prose Story") {
                NotificationCenter.default.post(name: .maughamAddLoosePiece, object: nil)
            }
            Button("New Screenplay") {
                NotificationCenter.default.post(name: .maughamAddScreenplayPiece, object: nil)
            }
            Button("Link Existing Project…") {
                NotificationCenter.default.post(name: .maughamLinkProject, object: nil)
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Add a piece")
    }
    .padding(8)
}
```

The Menu-on-button pattern is preferred — discoverable from the `+` icon without leaving the binder.

- [ ] **Step 5: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift Maugham/Views/CollectionPiecesPane.swift
git commit -m "feat: new-piece menu + File menu items for Collection windows

Pieces segment '+' button surfaces a Menu (Prose / Screenplay / Link
Existing Project). Three new notifications wire the menu to
ProjectWindow's handlers. File menu adds parallel items with ⌘N /
⌘⇧N shortcuts; the override behavior is contextual to Collection
windows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Promote loose piece to standalone project

### Task 16: ProjectStore.promotePieceToProject

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: Create `MaughamTests/Collection/PromotePieceTests.swift`

Atomic flow: stage new project structure under `.maugham-staging-<uuid>/`, validate via `ProjectStore.load`, then `replaceItemAt` to final destination. Move piece's files (not copy) into the new project. Convert Collection's manifest entry from `.loose` to `.reference`.

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/Collection/PromotePieceTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class PromotePieceTests: XCTestCase {
    private func makeCollectionWithPiece(
        mode: ProjectStore.PieceMode
    ) async throws -> (collection: URL, store: ProjectStore, piece: StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collectionURL = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: collectionURL)
        let piece = try await store.addLoosePiece(title: "Story A", mode: mode)
        return (collectionURL, store, piece)
    }

    func test_promote_prose_createsShortStoryProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Story A")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

        // New project exists with .shortStory type
        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .shortStory)
        XCTAssertEqual(newStore.manifest.title, "Story A")

        // Collection's piece is now a reference
        guard let converted = store.manifest.structure.first(where: { $0.id == piece.id }) else {
            XCTFail("piece not found in Collection after promote"); return
        }
        XCTAssertEqual(converted.pieceKind, .reference)
        XCTAssertNotNil(converted.linkedProjectBookmark)
    }

    func test_promote_screenplay_createsScreenplayProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .screenplay)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Screenplay")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .screenplay)
    }

    func test_promote_referenceFails() async throws {
        let (collection, store, _) = try await makeCollectionWithPiece(mode: .prose)
        // Make a reference to test against
        let tmp = collection.deletingLastPathComponent()
        let other = try await ProjectFactory.createShortStoryProject(
            named: "Other", in: tmp)
        let refPiece = try await store.addProjectReference(targetURL: other)

        let dest = tmp.appendingPathComponent("Promoted")
        do {
            _ = try await store.promotePieceToProject(
                pieceId: refPiece.id, destination: dest)
            XCTFail("expected throw — can't promote a reference")
        } catch {
            // ok
        }
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
  -only-testing:MaughamTests/PromotePieceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement promotePieceToProject**

Append to `Maugham/Stores/ProjectStore.swift`:

```swift
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

    // 1. Flush + close any open document for this piece via the documentStore.
    if let docStore = documentStore,
       docStore.openDocumentPath == piecePath {
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

    do {
        try FileManager.default.createDirectory(
            at: stagingURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagingURL.appendingPathComponent("notes"),
            withIntermediateDirectories: true)
        // research/ created via move below if the piece has one

        // 3. Move main doc into staging/manuscript/
        let newDocURL = stagingURL.appendingPathComponent("manuscript/\(mainDocName)")
        try FileManager.default.moveItem(
            at: pieceFolderURL.appendingPathComponent(mainDocName),
            to: newDocURL)

        // 4. Move piece's research/ subfolder into staging/research/ (if non-empty)
        let pieceResearchURL = pieceFolderURL.appendingPathComponent("research")
        let newResearchURL = stagingURL.appendingPathComponent("research")
        if FileManager.default.fileExists(atPath: pieceResearchURL.path) {
            try FileManager.default.moveItem(at: pieceResearchURL, to: newResearchURL)
        } else {
            try FileManager.default.createDirectory(
                at: newResearchURL, withIntermediateDirectories: true)
        }

        // 5. Build + write new project manifest
        let now = Date()
        let docStructItem = StructureItem(
            id: Self.newId(prefix: "doc"),
            title: piece.title,
            type: .document,
            path: "manuscript/\(mainDocName)",
            synopsis: piece.synopsis,
            status: piece.status,
            wordTarget: piece.wordTarget,
            pageTarget: piece.pageTarget,
            tags: piece.tags,
            links: piece.links)
        // Carry over per-piece research as the new project's research items
        let carriedResearch: [ResearchItem] = manifest.research.compactMap { item in
            guard let p = item.path,
                  p.hasPrefix("\(pieceFolderRel)/research/") else { return nil }
            var copy = item
            // Rewrite the path from pieces/<NN>-<slug>/research/X to research/X
            copy.path = "research/" + p.dropFirst("\(pieceFolderRel)/research/".count)
            return copy
        }
        let newManifest = ProjectManifest(
            type: newType,
            title: piece.title,
            author: manifest.author,
            created: now,
            modified: now,
            structure: [docStructItem],
            research: carriedResearch,
            targets: piece.wordTarget.map { ProjectTargets(totalWords: $0) }
                ?? piece.pageTarget.map { ProjectTargets(pageTarget: $0) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(newManifest).write(
            to: stagingURL.appendingPathComponent("project.maugham.json"),
            options: .atomic)

        // 6. Validate by loading
        _ = try await ProjectStore.load(from: stagingURL)

        // 7. Atomic replace to final destination
        if FileManager.default.fileExists(atPath: destination.path) {
            // Destination exists — replaceItemAt handles it via atomic swap
            _ = try FileManager.default.replaceItemAt(
                destination, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destination)
        }

        // 8. Convert Collection piece to a reference:
        //    a. Write .maugham-link.json
        //    b. Update manifest entry
        //    c. Remove per-piece research items from manifest.research
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
        manifest.structure[pieceIdx].synopsis = nil  // now lives in the new project
        manifest.structure[pieceIdx].status = nil
        manifest.structure[pieceIdx].wordTarget = nil
        manifest.structure[pieceIdx].pageTarget = nil
        // Remove per-piece research entries from Collection's manifest
        manifest.research.removeAll { item in
            item.path?.hasPrefix("\(pieceFolderRel)/research/") == true
        }
        manifest.modified = now
        try await saveManifest()

        return destination
    } catch {
        // Rollback: delete staging if present
        try? FileManager.default.removeItem(at: stagingURL)
        throw error
    }
}
```

NOTE: `ProjectTargets` may have specific named-argument shape (`totalWords:` / `pageTarget:`). Match what's in `Maugham/Models/ProjectTargets.swift`.

- [ ] **Step 4: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 607 tests, with 0 failures` (604 + 3).

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/Collection/PromotePieceTests.swift
git commit -m "feat: ProjectStore.promotePieceToProject

Atomic flow: stage new project under .maugham-staging-<uuid>/,
move main doc + research/ subfolder, write fresh manifest with
.shortStory or .screenplay type, validate by re-loading, then
replaceItemAt to final destination. Convert Collection's manifest
entry from .loose to .reference with fresh bookmark; remove per-
piece research items from Collection's manifest.research (they
live in the new project now).

Rollback on any failure: delete staging, source piece intact.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Promote-to-project UI affordance

**Files:**
- Modify: `Maugham/Views/CollectionPiecesPane.swift` or `PieceRow.swift` (add context menu)
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

Right-click a loose piece → context menu with "Promote to Standalone Project…" entry. Posts a notification with the piece id. ProjectWindow handles the notification: shows NSSavePanel, calls `promotePieceToProject`, opens the new project in a new window.

- [ ] **Step 1: Notification + UI**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
public static let maughamPromotePiece = Notification.Name("maugham.promote.piece")
```

In `Maugham/Views/CollectionPiecesPane.swift`, add a context menu to the piece rows:

```swift
ForEach(store.manifest.structure) { piece in
    PieceRow(piece: piece)
        .tag(piece.id as String?)
        .contextMenu {
            if piece.pieceKind == .loose {
                Button("Promote to Standalone Project…") {
                    NotificationCenter.default.post(
                        name: .maughamPromotePiece,
                        object: nil,
                        userInfo: ["piece_id": piece.id])
                }
            }
        }
}
```

- [ ] **Step 2: ProjectWindow handles the notification**

In `Maugham/Views/ProjectWindow.swift`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .maughamPromotePiece)) { note in
    guard let store, store.manifest.type == .collection,
          let info = note.userInfo,
          let pieceId = info["piece_id"] as? String,
          let piece = store.manifest.structure.first(where: { $0.id == pieceId }) else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = piece.title
    panel.directoryURL = store.url.deletingLastPathComponent()
    panel.message = "Promote \"\(piece.title)\" to a standalone Maugham project"
    panel.begin { response in
        guard response == .OK, let destination = panel.url else { return }
        Task {
            do {
                let newProjectURL = try await store.promotePieceToProject(
                    pieceId: pieceId, destination: destination)
                NotificationCenter.default.post(
                    name: .maughamOpenProject, object: nil,
                    userInfo: ["url": newProjectURL])
            } catch {
                // Surface error to user via an alert
                // (or just log for v1 — proper alert is a polish task)
                print("Promote failed: \(error)")
            }
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 607 tests, with 0 failures`.

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/Views/CollectionPiecesPane.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: 'Promote to Standalone Project…' context menu item

Right-click a loose piece → opens NSSavePanel pre-filled with the
piece title. On confirm, promotePieceToProject runs; on success
the new project opens in a new window via maughamOpenProject.
Reference pieces don't get the menu item (already standalone).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 7 — Cross-collection search + MCP smoke

### Task 18: Verify ProjectSearchEngine walks pieces correctly

**Files:**
- Create: `MaughamTests/Collection/CollectionSearchTests.swift`

Existing `ProjectSearchEngine` walks `manifest.structure` recursively and reads each item's `path`. For a Collection, pieces are top-level items with `path` pointing at the main doc. This should work without any engine changes — we just need a regression test.

- [ ] **Step 1: Write tests**

Create `MaughamTests/Collection/CollectionSearchTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class CollectionSearchTests: XCTestCase {
    private func makeCollectionWithPieces() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let p1 = try await store.addLoosePiece(title: "Lighthouse", mode: .prose)
        try "The lighthouse keeper watched the storm.\n".write(
            to: url.appendingPathComponent(p1.path!),
            atomically: true, encoding: .utf8)
        let p2 = try await store.addLoosePiece(title: "Storm", mode: .prose)
        try "Another storm story altogether.\n".write(
            to: url.appendingPathComponent(p2.path!),
            atomically: true, encoding: .utf8)
        // Trigger DocumentStore awareness
        try await store.documentStore?.flushPendingSave()
        return (url, store)
    }

    func test_search_findsMatchesAcrossPieces() async throws {
        let (_, store) = try await makeCollectionWithPieces()
        let engine = ProjectSearchEngine()
        let results = try await engine.search(
            query: "storm",
            options: SearchOptions(caseSensitive: false, wholeWord: false),
            in: store)
        // At least 2 matches (one in each piece)
        XCTAssertGreaterThanOrEqual(results.matches.count, 2,
            "got: \(results.matches.map { $0.linePreview })")
        let docTitles = Set(results.matches.map { $0.documentTitle })
        XCTAssertTrue(docTitles.contains("Lighthouse"))
        XCTAssertTrue(docTitles.contains("Storm"))
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 608 tests, with 0 failures` (607 + 1).

If the test fails, it likely means ProjectSearchEngine assumes `pieces/` isn't in the search path. Check `ProjectSearchEngine.swift`; if it filters paths by prefix (e.g., only walks `manuscript/`), update the filter to also include `pieces/` for Collection projects.

```bash
git add MaughamTests/Collection/CollectionSearchTests.swift
git commit -m "test: ProjectSearchEngine walks Collection pieces correctly

Regression test confirming cross-piece text search works without
engine changes (structure-walking already covers pieces as top-
level items).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 19: MCP integration smoke — verify tools work on Collections

**Files:**
- Test: extend `MaughamTests/MCP/Tools/DocumentToolsTests.swift` and `ProjectToolsTests.swift`

Most MCP tools "just work" against a Collection because they read `manifest.structure`. Add lightweight regression tests for the most-likely-to-bite tools.

- [ ] **Step 1: Add tests**

Append to `MaughamTests/MCP/Tools/ProjectToolsTests.swift`:

```swift
extension ProjectToolsTests {
    func test_listProjects_includesCollection() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-coll-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let data = try await ListProjectsTool.handle(paramsJSON: nil, registry: reg)
        let projects = try JSONDecoder().decode(
            [ListProjectsTool.Project].self, from: data)
        XCTAssertTrue(projects.contains { $0.type == "collection" })
    }

    func test_getOutline_Collection_returnsPiecesFlat() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-out-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addLoosePiece(title: "Story A", mode: .prose)
        _ = try await store.addLoosePiece(title: "Story B", mode: .screenplay)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)

        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let data = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let outline = try JSONDecoder().decode(
            GetOutlineTool.Outline.self, from: data)
        XCTAssertEqual(outline.nodes.count, 2)
        XCTAssertNil(outline.nodes[0].children)
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 610 tests, with 0 failures` (608 + 2).

```bash
git add MaughamTests/MCP/Tools/ProjectToolsTests.swift
git commit -m "test: MCP tools work on Collections

list_projects reports Collection type. get_outline returns pieces
as flat top-level nodes (children: nil). The other tools (read_document,
search_text, find_references, list_research, list_all_links) flow
through the same manifest.structure walking and work uncha­nged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 8 — Smoke + tag

### Task 20: Final smoke + tag

**Files:** none beyond memory updates.

- [ ] **Manual smoke checklist**

Build:
```bash
xcodegen generate
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Verify in the running app:

1. New Project → Collection → name "Smoke Anthology" → create. Window opens with empty Pieces segment, "+ Add your first piece" empty state.
2. `+` button in Pieces header → menu shows New Prose Story / New Screenplay / Link Existing Project. Click "New Prose Story". Inline-rename mode; rename to "Story A". Filename renames on disk.
3. Type a paragraph. Inspector shows Prose-piece inspector with synopsis, status, word target Stepper. Goal indicator shows word count.
4. `+` → New Screenplay. Inline rename to "Story B". Switch to it. Editor opens `.fountain` file with Fountain styling. Inspector swaps to Screenplay-piece inspector with page target. Goal indicator shows page count.
5. Switch right pane to Research mode (⌘⌥2). Shared section and "Story B" section both visible. Add a note in each via `+` buttons. Verify on disk: shared lands under `research/`, piece lands under `pieces/02-story-b/research/`.
6. Outline mode (⌘⌥3) is hidden in the right pane picker for this Collection window.
7. Click `+` → Link Existing Project → pick another Maugham project (Novel or Short Story) → reference appears as the next piece. Click the reference → editor pane shows the Reference placeholder card. Click "Open in New Window" → the linked project opens in a separate Maugham window.
8. In the Reference inspector: click "Reveal in Finder" — Finder reveals the linked project. Edit the title — Collection's manifest updates; linked project's manifest untouched.
9. Right-click a loose piece → "Promote to Standalone Project…". NSSavePanel opens. Save somewhere. Promotion completes; the new project opens in a window. Back in the Collection, the piece is now a reference. The piece's old folder is empty except for `.maugham-link.json`. The new project on disk has `manuscript/<slug>.md` + `research/` + `notes/`.
10. ⌘⌥F find across pieces → matches show with correct document titles.
11. Delete a loose piece → moves to .trash/. ⌘⌥Z → restores in place. ⌘Z → in-doc text undo (separate from binder undo).
12. Quit, relaunch, open from Recents → Collection state intact: pieces in order, selected piece + scroll position restored.
13. Open Claude Desktop. Ask "What Maugham projects are open?" → Collection appears with type "collection". Ask "What pieces are in my Smoke Anthology?" → flat list of pieces returned. Ask "Read me Story A" → text returned. Ask "Add a research note to the collection called 'Voice Notes' with body 'Reminder to revise dialogue'" → note appears in Shared section.
14. Cross-Mac smoke (optional): copy the Collection folder to another Mac via iCloud Drive. Open in Maugham. References that pointed at same-iCloud-path projects resolve via path fallback. References that pointed at non-iCloud paths show ⚠ Unresolved with Re-link affordance.

- [ ] **Final build + full test**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 610 tests, with 0 failures`.

- [ ] **Push + tag**

```bash
git checkout main
git merge --ff-only feat/milestone-mixed-content-collection
git tag -a milestone-mixed-content-collection -m "Mixed-Content Collection — Group 3 milestone

Collection projects now functional with hybrid model:
- Loose mixed-content pieces (.md prose + .fountain screenplay)
  in pieces/<NN>-<slug>/, each with own optional research/ subfolder
- Project references via .maugham-link.json with security-scoped
  bookmarks; cross-Mac best-effort per ADR 0009
- Collection binder: Pieces / Research (Shared + per-piece) / Find / Trash
- Inspector polymorphic per piece kind (prose / screenplay / reference)
- Goal indicator per active piece
- Promote loose piece to standalone project (atomic staging)
- MCP tools work uniformly on Collections

~610 tests passing."
git push origin main
git push origin milestone-mixed-content-collection
```

- [ ] **Update memory**

Create `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_mixed_content_collection.md` capturing the API surface added (`addLoosePiece`, `addProjectReference`, `resolveReference`, `relinkReference`, `addPieceResearchNote`, `promotePieceToProject`), the on-disk layout (pieces/<NN>-<slug>/ with main doc + optional research/), the bookmark resolution semantics, and carry-forwards (no cross-piece research drag, no per-piece SessionLog, no Outline mode in Collection windows, cross-Mac bookmark caveat per ADR 0009, MCP add_note(parent_group_id) semantics for piece-scoped research locked in during implementation).

Add an entry to `~/.claude/projects/-Users-denver-src-Maugham/memory/MEMORY.md` index.

---

## Spec coverage check

| Spec section | Covered by task(s) |
|---|---|
| `StructureItem` new fields (`pageTarget`, `pieceKind`, `linkedProjectPath`, `linkedProjectBookmark`) | T1 |
| `CollectionLinkFile` model | T2 |
| `ProjectFactory` creates `pieces/` | T3 |
| `addLoosePiece(title:mode:)` | T4 |
| `addProjectReference(targetURL:)` | T5 |
| `resolveReference` + `ReferenceResolution` | T6 |
| `addPieceResearchNote` | T7 |
| `CollectionPiecesPane` + `PieceRow` | T8 |
| `CollectionResearchPane` (Shared + per-piece) | T9 |
| `CollectionBinderPaneToggle` | T10 |
| ProjectWindow integration (Collection vs non-Collection binder) | T11 |
| Inspector polymorphism (prose / screenplay / reference) | T12 |
| DetailPaneToggle Outline-hide + Inspector routing + editor placeholder | T13 |
| Goal indicator polymorphism | T14 |
| New-piece menu + File menu items | T15 |
| Promote loose piece to standalone project (API + UI) | T16, T17 |
| Cross-collection search regression | T18 |
| MCP tools on Collections | T19 |
| Smoke + tag + memory | T20 |
| Cross-Mac bookmark caveat (ADR 0009) | Spec § Project references; ADR landed with spec commit |
| Out-of-scope items (compile, cross-piece research drag, etc.) | Documented in spec § Out of scope; not in plan |
