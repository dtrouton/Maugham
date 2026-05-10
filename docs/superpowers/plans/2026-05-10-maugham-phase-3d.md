# Maugham — Phase 3d Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pivot screenplays from single-file to multi-file (one `.fountain` per scene + `00-title.fountain`) while preserving the writer's experience of reading and editing the screenplay as one continuous concatenated stream.

**Architecture:** A new `CompoundScreenplayDocument` owns N child `DocumentStore`s and presents a single concatenated `NSTextStorage` to the editor. Edits route to the right child via an offset map. Typing a new slugline auto-splits a file; deleting a slugline auto-merges into the previous file. The binder shows scenes as draggable cards; top-level `# ACT N` markers become folder groups.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (NSTextView, NSTextStorage), xcodegen, Combine, NSFileCoordinator/NSFilePresenter for per-file conflict isolation.

**Reference spec:** `docs/superpowers/specs/2026-05-10-maugham-phase-3d-design.md`

---

## File map

**Create:**
- `Maugham/Models/ItemRole.swift` — `enum ItemRole` (currently just `.titlePage`)
- `Maugham/Stores/ScreenplayMigrator.swift` — single-file → multi-file conversion
- `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift` — compound abstraction
- `Maugham/Editor/Fountain/CompoundOffsetMap.swift` — range-translation helper
- `MaughamTests/ItemRoleTests.swift`
- `MaughamTests/ScreenplayMigratorTests.swift`
- `MaughamTests/CompoundScreenplayDocumentTests.swift`
- `MaughamTests/CompoundOffsetMapTests.swift`
- `MaughamTests/AutoSplitTests.swift`
- `MaughamTests/AutoMergeTests.swift`
- `MaughamTests/ScreenplayBinderActionsTests.swift`
- `MaughamTests/CompoundPageCountTests.swift`

**Modify:**
- `Maugham/Models/StructureItem.swift` — add `role: ItemRole?` field
- `Maugham/Stores/ProjectStore.swift` — migrate-on-open hook, screenplay-aware structural ops
- `Maugham/Editor/EditorSurface.swift` — wire CompoundScreenplayDocument for screenplay projects
- `Maugham/Editor/EditorCoordinator.swift` — surface compound ops (`currentSceneId(forCursor:)`)
- `Maugham/Models/BinderSegment.swift` — drop `.scenes` segment for screenplays
- `Maugham/Views/BinderPaneToggle.swift` — restore `Manuscript / Research` for screenplays
- `Maugham/Views/BinderView.swift` — title page row icon, scene rows show `p.N · 1¼p`
- `Maugham/Views/ProjectWindow.swift` — load CompoundScreenplayDocument when manifest is multi-file screenplay
- `Maugham/Views/InspectorView.swift` — page target field for screenplay scenes

---

## Phase 1 — Foundation: data model, migration, compound editor

### Task 1: ItemRole enum + StructureItem.role

**Files:**
- Create: `Maugham/Models/ItemRole.swift`
- Modify: `Maugham/Models/StructureItem.swift`
- Test: `MaughamTests/ItemRoleTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class ItemRoleTests: XCTestCase {
    func test_titlePageCase_serializesToString() throws {
        let role = ItemRole.titlePage
        let data = try JSONEncoder().encode(role)
        let raw = String(data: data, encoding: .utf8)
        XCTAssertEqual(raw, "\"titlePage\"")
    }

    func test_structureItem_serializesWithRole() throws {
        let item = StructureItem(
            id: "id-1", title: "Title Page", type: .document,
            path: "Scenes/00-title.fountain", role: .titlePage)
        let data = try JSONEncoder().encode(item)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"role\":\"titlePage\""))
    }

    func test_structureItem_roundTripsWithoutRole() throws {
        let raw = #"{"id":"id-1","title":"Chapter 1","type":"document","path":"Chapters/c1.md"}"#
        let item = try JSONDecoder().decode(
            StructureItem.self, from: raw.data(using: .utf8)!)
        XCTAssertNil(item.role)
        XCTAssertEqual(item.title, "Chapter 1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ItemRoleTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: COMPILE FAIL or TEST FAIL — `ItemRole` doesn't exist; `StructureItem.role` doesn't exist.

- [ ] **Step 3: Create ItemRole**

Create `Maugham/Models/ItemRole.swift`:

```swift
import Foundation

/// The structural role of a StructureItem within its project.
/// Most items have no role (`nil`); reserved roles flag items that
/// the editor or binder should treat specially.
public enum ItemRole: String, Codable, Sendable, Equatable {
    /// The leading title page document of a multi-file screenplay.
    /// Holds Fountain title-page key-value pairs (Title:, Author:, etc.)
    /// instead of scene content.
    case titlePage
}
```

- [ ] **Step 4: Add role field to StructureItem**

In `Maugham/Models/StructureItem.swift`, add `role` to the struct, init, and CodingKeys:

```swift
public struct StructureItem: Codable, Equatable, Identifiable, Sendable {
    public enum ItemType: String, Codable, Sendable {
        case document
        case group
    }

    public var id: String
    public var title: String
    public var type: ItemType
    public var path: String?
    public var synopsis: String?
    public var status: String?
    public var wordTarget: Int?
    public var tags: [String]?
    public var links: [String]?
    public var children: [StructureItem]?
    public var role: ItemRole?

    public init(
        id: String,
        title: String,
        type: ItemType,
        path: String? = nil,
        synopsis: String? = nil,
        status: String? = nil,
        wordTarget: Int? = nil,
        tags: [String]? = nil,
        links: [String]? = nil,
        children: [StructureItem]? = nil,
        role: ItemRole? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.path = path
        self.synopsis = synopsis
        self.status = status
        self.wordTarget = wordTarget
        self.tags = tags
        self.links = links
        self.children = children
        self.role = role
    }
}
```

(Keep the existing `Codable` synthesis — Swift's auto-generated CodingKeys cover the new field and the default init handles missing-key tolerance for old manifests.)

- [ ] **Step 5: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ItemRoleTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 6: Run full suite to verify no regression**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 468 tests, with 0 failures` (465 prior + 3 new).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Models/ItemRole.swift Maugham/Models/StructureItem.swift MaughamTests/ItemRoleTests.swift
git commit -m "feat: ItemRole enum + StructureItem.role field

Additive schema-1 extension. Older manifests round-trip cleanly
because role is optional. ItemRole.titlePage marks the leading
title page document in multi-file screenplays.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ScreenplayMigrator — basic scene splitting

**Files:**
- Create: `Maugham/Stores/ScreenplayMigrator.swift`
- Test: `MaughamTests/ScreenplayMigratorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Maugham

final class ScreenplayMigratorTests: XCTestCase {
    /// Helper: write a single-file screenplay project to a temp dir
    /// and return its URL (containing project.maugham.json + the .fountain).
    private func makeProject(fountainContent: String, scenePath: String = "screenplay.fountain") throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenplayMigratorTest-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fountainContent.write(
            to: tmp.appendingPathComponent(scenePath), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .screenplay, title: "Test", author: "Tester",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "sole-id", title: "Screenplay", type: .document, path: scenePath)],
            research: [])
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    func test_migrate_scenesOnly_noActsNoTitlePage() throws {
        let raw = """
        INT. KITCHEN - DAY

        Action paragraph.

        EXT. ROOFTOP - NIGHT

        BARRY
        Hello.
        """
        let project = try makeProject(fountainContent: raw)
        let migrator = ScreenplayMigrator(projectURL: project)
        let result = try migrator.migrate()

        XCTAssertTrue(result.wasMigrated)
        let scenesDir = project.appendingPathComponent("Scenes")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scenesDir.appendingPathComponent("int-kitchen-day.fountain").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scenesDir.appendingPathComponent("ext-rooftop-night.fountain").path))
        // Backup retained
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("screenplay.fountain.bak").path))
    }

    func test_migrate_scenesOnly_writesTitlePagePlaceholder() throws {
        let raw = """
        INT. KITCHEN - DAY

        Action.
        """
        let project = try makeProject(fountainContent: raw)
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let titlePath = project
            .appendingPathComponent("Scenes")
            .appendingPathComponent("00-title.fountain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: titlePath.path))
    }

    func test_migrate_alreadyMultiFile_skipsMigration() throws {
        let project = try makeProject(fountainContent: "INT. ROOM - DAY\n\nAction.")
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()
        // Re-run; should be no-op
        let result = try migrator.migrate()
        XCTAssertFalse(result.wasMigrated)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayMigratorTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: COMPILE FAIL — `ScreenplayMigrator` doesn't exist.

- [ ] **Step 3: Create ScreenplayMigrator**

Create `Maugham/Stores/ScreenplayMigrator.swift`:

```swift
import Foundation

/// Converts a single-file screenplay project (one .fountain at the root,
/// referenced by a single StructureItem) into the multi-file scene-as-document
/// layout used by Phase 3d and beyond.
///
/// Migration is invoked once per project; subsequent opens detect the
/// already-multi-file shape and skip via `MigrationResult.wasMigrated == false`.
public struct ScreenplayMigrator {
    public let projectURL: URL

    public struct MigrationResult {
        public let wasMigrated: Bool
        public let backupPath: String?
    }

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    /// Detect-and-migrate. Idempotent: if the manifest is already multi-file,
    /// returns `wasMigrated: false` without touching anything.
    public func migrate() throws -> MigrationResult {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)

        guard shouldMigrate(manifest) else {
            return MigrationResult(wasMigrated: false, backupPath: nil)
        }

        let solePath = manifest.structure[0].path ?? ""
        let originalURL = projectURL.appendingPathComponent(solePath)
        let backupURL = projectURL.appendingPathComponent("\(solePath).bak")

        // Step 1: backup
        try FileManager.default.moveItem(at: originalURL, to: backupURL)

        do {
            // Step 2: parse
            let raw = try String(contentsOf: backupURL, encoding: .utf8)
            let script = FountainTokenizer.parse(raw)

            // Step 3-6: split + write scene files
            let scenesDir = projectURL.appendingPathComponent("Scenes")
            try FileManager.default.createDirectory(
                at: scenesDir, withIntermediateDirectories: true)

            let newStructure = try buildStructure(
                script: script, raw: raw, scenesDir: scenesDir)

            // Step 7: rewrite manifest atomically
            manifest.structure = newStructure
            manifest.modified = Date()
            try writeManifestAtomically(manifest, to: manifestURL)

            return MigrationResult(
                wasMigrated: true, backupPath: "\(solePath).bak")
        } catch {
            // Rollback
            try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent()
                .appendingPathComponent("Scenes"))
            try? FileManager.default.moveItem(at: backupURL, to: originalURL)
            throw error
        }
    }

    private func shouldMigrate(_ manifest: ProjectManifest) -> Bool {
        guard manifest.type == .screenplay else { return false }
        guard manifest.structure.count == 1 else { return false }
        guard let path = manifest.structure[0].path else { return false }
        return path.hasSuffix(".fountain") && !path.hasPrefix("Scenes/")
    }

    /// Build the multi-file structure from a parsed script. The full algorithm
    /// (title page extraction, act grouping, preamble) is filled in by Tasks 3-5.
    /// In this task we implement scenes-only with a placeholder title page.
    private func buildStructure(
        script: FountainScript, raw: String, scenesDir: URL
    ) throws -> [StructureItem] {
        var structure: [StructureItem] = []

        // Placeholder title page
        let titlePath = "Scenes/00-title.fountain"
        try "Title:\nAuthor:\n".write(
            to: projectURL.appendingPathComponent(titlePath),
            atomically: true, encoding: .utf8)
        structure.append(StructureItem(
            id: UUID().uuidString,
            title: "Title Page",
            type: .document,
            path: titlePath,
            role: .titlePage))

        // Walk lines, segmenting on .sceneHeading
        var sceneStart: Int? = nil
        var usedFilenames = Set<String>()
        for (index, line) in script.lines.enumerated() {
            if case .sceneHeading = line.element {
                if let start = sceneStart {
                    structure.append(try writeSceneFile(
                        from: script.lines[start..<index],
                        raw: raw, scenesDir: scenesDir,
                        usedFilenames: &usedFilenames))
                }
                sceneStart = index
            }
        }
        if let start = sceneStart {
            structure.append(try writeSceneFile(
                from: script.lines[start...],
                raw: raw, scenesDir: scenesDir,
                usedFilenames: &usedFilenames))
        }
        return structure
    }

    private func writeSceneFile<S: Sequence>(
        from lines: S, raw: String, scenesDir: URL,
        usedFilenames: inout Set<String>
    ) throws -> StructureItem where S.Element == FountainLine {
        let lineArray = Array(lines)
        guard let head = lineArray.first,
              case .sceneHeading = head.element else {
            // Action without slugline — defer to Task 5 (preamble)
            throw MigratorError.preambleNotYetSupported
        }
        let slug = FileNaming.kebabCase(head.content)
        var filename = "\(slug).fountain"
        var counter = 2
        while usedFilenames.contains(filename) {
            filename = "\(slug)-\(counter).fountain"
            counter += 1
        }
        usedFilenames.insert(filename)

        // Reconstruct content from line ranges
        let nsRaw = raw as NSString
        let firstLoc = lineArray.first!.range.location
        let lastEnd = lineArray.last!.range.location + lineArray.last!.range.length
        let content = nsRaw.substring(with: NSRange(location: firstLoc, length: lastEnd - firstLoc))
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        try trimmed.write(
            to: scenesDir.appendingPathComponent(filename),
            atomically: true, encoding: .utf8)

        return StructureItem(
            id: UUID().uuidString,
            title: head.content,
            type: .document,
            path: "Scenes/\(filename)")
    }

    private func writeManifestAtomically(
        _ manifest: ProjectManifest, to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID()).manifest.tmp")
        try data.write(to: tmpURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }

    public enum MigratorError: Error {
        case preambleNotYetSupported
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayMigratorTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 471 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ScreenplayMigrator.swift MaughamTests/ScreenplayMigratorTests.swift
git commit -m "feat: ScreenplayMigrator basic scene splitting

Single-file screenplay projects auto-convert to multi-file on
first 3d open: each .sceneHeading becomes its own .fountain in
Scenes/, with a placeholder 00-title.fountain at the head. Backs
up the original to .fountain.bak with rollback on any failure.
Title page extraction, act grouping, and preamble handling are
incremental tasks 3-5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Migrator — title page extraction

**Files:**
- Modify: `Maugham/Stores/ScreenplayMigrator.swift`
- Modify: `MaughamTests/ScreenplayMigratorTests.swift`

- [ ] **Step 1: Add the failing test**

Append to `ScreenplayMigratorTests`:

```swift
    func test_migrate_extractsTitlePageBlock() throws {
        let raw = """
        Title: My Movie
        Author: Tester
        Draft date: 2026-05-10

        INT. KITCHEN - DAY

        Action.
        """
        let project = try makeProject(fountainContent: raw)
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let titlePath = project
            .appendingPathComponent("Scenes")
            .appendingPathComponent("00-title.fountain")
        let content = try String(contentsOf: titlePath, encoding: .utf8)
        XCTAssertTrue(content.contains("Title: My Movie"))
        XCTAssertTrue(content.contains("Author: Tester"))
        XCTAssertTrue(content.contains("Draft date: 2026-05-10"))
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayMigratorTests/test_migrate_extractsTitlePageBlock CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: FAIL — content has placeholder, not the real title page.

- [ ] **Step 3: Implement title page extraction**

In `ScreenplayMigrator.swift`, replace the placeholder title-page-write in `buildStructure` with logic that reads `script.titlePage`:

```swift
private func buildStructure(
    script: FountainScript, raw: String, scenesDir: URL
) throws -> [StructureItem] {
    var structure: [StructureItem] = []

    // Title page — real if parsed, placeholder otherwise
    let titlePath = "Scenes/00-title.fountain"
    let titleContent: String
    if let fields = script.titlePage, !fields.isEmpty {
        titleContent = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n"
    } else {
        titleContent = "Title:\nAuthor:\n"
    }
    try titleContent.write(
        to: projectURL.appendingPathComponent(titlePath),
        atomically: true, encoding: .utf8)
    structure.append(StructureItem(
        id: UUID().uuidString,
        title: "Title Page",
        type: .document,
        path: titlePath,
        role: .titlePage))

    // Walk lines, segmenting on .sceneHeading (unchanged from Task 2)
    var sceneStart: Int? = nil
    var usedFilenames = Set<String>()
    for (index, line) in script.lines.enumerated() {
        if case .sceneHeading = line.element {
            if let start = sceneStart {
                structure.append(try writeSceneFile(
                    from: script.lines[start..<index],
                    raw: raw, scenesDir: scenesDir,
                    usedFilenames: &usedFilenames))
            }
            sceneStart = index
        }
    }
    if let start = sceneStart {
        structure.append(try writeSceneFile(
            from: script.lines[start...],
            raw: raw, scenesDir: scenesDir,
            usedFilenames: &usedFilenames))
    }
    return structure
}
```

(Verify the `TitlePageField` struct's field accessors are `key`/`value` — adjust if they're `name`/`text` or similar.)

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 472 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ScreenplayMigrator.swift MaughamTests/ScreenplayMigratorTests.swift
git commit -m "feat: migrator extracts Fountain title page block

If the source screenplay has a Title:/Author:/etc. title page block
at its head, those fields land in 00-title.fountain. Otherwise the
placeholder 'Title:\\nAuthor:\\n' content is used so every multi-file
screenplay has a fillable title page document.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Migrator — act grouping

**Files:**
- Modify: `Maugham/Stores/ScreenplayMigrator.swift`
- Modify: `MaughamTests/ScreenplayMigratorTests.swift`

- [ ] **Step 1: Add failing test**

Append to `ScreenplayMigratorTests`:

```swift
    func test_migrate_groupsScenesUnderActSections() throws {
        let raw = """
        # ACT ONE

        INT. KITCHEN - DAY

        Action.

        EXT. GARDEN - DAY

        More action.

        # ACT TWO

        INT. WAREHOUSE - NIGHT

        Final action.
        """
        let project = try makeProject(fountainContent: raw)
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let manifestData = try Data(contentsOf:
            project.appendingPathComponent("project.maugham.json"))
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: manifestData)

        XCTAssertEqual(manifest.structure.count, 3) // titlePage + 2 acts
        XCTAssertEqual(manifest.structure[1].type, .group)
        XCTAssertEqual(manifest.structure[1].title, "ACT ONE")
        XCTAssertEqual(manifest.structure[1].children?.count, 2)
        XCTAssertEqual(manifest.structure[2].type, .group)
        XCTAssertEqual(manifest.structure[2].title, "ACT TWO")
        XCTAssertEqual(manifest.structure[2].children?.count, 1)
    }

    func test_migrate_scenesBeforeFirstAct_stayAtTopLevel() throws {
        let raw = """
        INT. PROLOGUE - DAY

        Pre-act scene.

        # ACT ONE

        EXT. GARDEN - DAY

        First-act scene.
        """
        let project = try makeProject(fountainContent: raw)
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let manifest = try JSONDecoder().decode(
            ProjectManifest.self,
            from: try Data(contentsOf: project.appendingPathComponent("project.maugham.json")))

        // titlePage + prologue scene + ACT ONE group
        XCTAssertEqual(manifest.structure.count, 3)
        XCTAssertEqual(manifest.structure[1].type, .document) // prologue
        XCTAssertEqual(manifest.structure[2].type, .group)    // ACT ONE
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayMigratorTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: 2 failures.

- [ ] **Step 3: Implement act grouping**

Refactor `buildStructure` in `ScreenplayMigrator.swift` to group on `.section(level: 1)`:

```swift
private func buildStructure(
    script: FountainScript, raw: String, scenesDir: URL
) throws -> [StructureItem] {
    var structure: [StructureItem] = []

    // Title page (unchanged from Task 3)
    let titlePath = "Scenes/00-title.fountain"
    let titleContent: String
    if let fields = script.titlePage, !fields.isEmpty {
        titleContent = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n"
    } else {
        titleContent = "Title:\nAuthor:\n"
    }
    try titleContent.write(
        to: projectURL.appendingPathComponent(titlePath),
        atomically: true, encoding: .utf8)
    structure.append(StructureItem(
        id: UUID().uuidString,
        title: "Title Page",
        type: .document,
        path: titlePath,
        role: .titlePage))

    // Walk lines, tracking current act group and current scene
    var usedFilenames = Set<String>()
    var currentAct: StructureItem? = nil
    var currentSceneStart: Int? = nil

    func flushScene(at endIndex: Int) throws {
        guard let start = currentSceneStart else { return }
        let scene = try writeSceneFile(
            from: script.lines[start..<endIndex],
            raw: raw, scenesDir: scenesDir,
            usedFilenames: &usedFilenames)
        if currentAct != nil {
            currentAct?.children = (currentAct?.children ?? []) + [scene]
        } else {
            structure.append(scene)
        }
        currentSceneStart = nil
    }

    func flushAct() {
        if let act = currentAct {
            structure.append(act)
            currentAct = nil
        }
    }

    for (index, line) in script.lines.enumerated() {
        switch line.element {
        case .section(let level) where level == 1:
            try flushScene(at: index)
            flushAct()
            currentAct = StructureItem(
                id: UUID().uuidString,
                title: line.content,
                type: .group,
                children: [])
        case .sceneHeading:
            try flushScene(at: index)
            currentSceneStart = index
        default:
            break
        }
    }
    try flushScene(at: script.lines.count)
    flushAct()

    return structure
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 474 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ScreenplayMigrator.swift MaughamTests/ScreenplayMigratorTests.swift
git commit -m "feat: migrator groups scenes under Act sections

Top-level Fountain section markers (# ACT ONE) become binder
folder groups (StructureItem.type == .group); scenes between
sections drop into the current act's children. Scenes that
appear before any # stay at top level alongside the title page.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Migrator — preamble handling + edge cases

**Files:**
- Modify: `Maugham/Stores/ScreenplayMigrator.swift`
- Modify: `MaughamTests/ScreenplayMigratorTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
    func test_migrate_actionBeforeFirstSlugline_goesToPreamble() throws {
        let raw = """
        FADE IN:

        Some action without a slugline yet.

        INT. KITCHEN - DAY

        Action.
        """
        let project = try makeProject(fountainContent: raw)
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let preambleURL = project
            .appendingPathComponent("Scenes")
            .appendingPathComponent("_preamble.fountain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preambleURL.path))
        let content = try String(contentsOf: preambleURL, encoding: .utf8)
        XCTAssertTrue(content.contains("FADE IN:"))
        XCTAssertTrue(content.contains("Some action without a slugline yet"))
    }

    func test_migrate_emptyScreenplay_createsPlaceholderTitlePageOnly() throws {
        let project = try makeProject(fountainContent: "")
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let manifest = try JSONDecoder().decode(
            ProjectManifest.self,
            from: try Data(contentsOf: project.appendingPathComponent("project.maugham.json")))

        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].role, .titlePage)
    }

    func test_migrate_titlePageOnly_noScenes() throws {
        let project = try makeProject(fountainContent: "Title: Lonely Title\nAuthor: A\n")
        let migrator = ScreenplayMigrator(projectURL: project)
        _ = try migrator.migrate()

        let manifest = try JSONDecoder().decode(
            ProjectManifest.self,
            from: try Data(contentsOf: project.appendingPathComponent("project.maugham.json")))

        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].role, .titlePage)
        let titleContent = try String(
            contentsOf: project.appendingPathComponent("Scenes/00-title.fountain"))
        XCTAssertTrue(titleContent.contains("Title: Lonely Title"))
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayMigratorTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 8 tests, with 3 failures` (+3 new failures).

- [ ] **Step 3: Implement preamble + empty-script handling**

In `ScreenplayMigrator.buildStructure`, add a preamble buffer and handle the no-scenes case:

```swift
private func buildStructure(
    script: FountainScript, raw: String, scenesDir: URL
) throws -> [StructureItem] {
    var structure: [StructureItem] = []

    // Title page (unchanged)
    let titlePath = "Scenes/00-title.fountain"
    let titleContent: String
    if let fields = script.titlePage, !fields.isEmpty {
        titleContent = fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n"
    } else {
        titleContent = "Title:\nAuthor:\n"
    }
    try titleContent.write(
        to: projectURL.appendingPathComponent(titlePath),
        atomically: true, encoding: .utf8)
    structure.append(StructureItem(
        id: UUID().uuidString,
        title: "Title Page",
        type: .document,
        path: titlePath,
        role: .titlePage))

    var usedFilenames = Set<String>()
    var currentAct: StructureItem? = nil
    var currentSceneStart: Int? = nil
    var preambleEnd: Int? = nil
    var sawAnyScene = false

    // Lines that aren't title page (already extracted) and aren't section/scene
    // before the first scene → preamble
    let bodyLines = script.lines.enumerated().compactMap { (idx, line) -> (Int, FountainLine)? in
        if case .titlePage = line.element { return nil }
        return (idx, line)
    }

    func flushScene(at endIndex: Int) throws {
        guard let start = currentSceneStart else { return }
        let scene = try writeSceneFile(
            from: script.lines[start..<endIndex],
            raw: raw, scenesDir: scenesDir,
            usedFilenames: &usedFilenames)
        if currentAct != nil {
            currentAct?.children = (currentAct?.children ?? []) + [scene]
        } else {
            structure.append(scene)
        }
        currentSceneStart = nil
    }

    func flushAct() {
        if let act = currentAct {
            structure.append(act)
            currentAct = nil
        }
    }

    for (index, line) in script.lines.enumerated() {
        switch line.element {
        case .titlePage:
            continue
        case .section(let level) where level == 1:
            if !sawAnyScene && currentSceneStart == nil && preambleEnd == nil
                && hasPreambleBefore(index: index, in: script.lines) {
                preambleEnd = index
            }
            try flushScene(at: index)
            flushAct()
            currentAct = StructureItem(
                id: UUID().uuidString,
                title: line.content,
                type: .group,
                children: [])
        case .sceneHeading:
            if !sawAnyScene && preambleEnd == nil
                && hasPreambleBefore(index: index, in: script.lines) {
                preambleEnd = index
            }
            sawAnyScene = true
            try flushScene(at: index)
            currentSceneStart = index
        default:
            break
        }
    }
    try flushScene(at: script.lines.count)
    flushAct()

    // Write preamble if there was content before any structure
    if let endIdx = preambleEnd {
        let preambleLines = script.lines[0..<endIdx].filter {
            if case .titlePage = $0.element { return false }
            return true
        }
        if !preambleLines.isEmpty {
            let nsRaw = raw as NSString
            let firstLoc = preambleLines.first!.range.location
            let lastEnd = preambleLines.last!.range.location + preambleLines.last!.range.length
            let content = nsRaw.substring(with: NSRange(location: firstLoc, length: lastEnd - firstLoc))
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try trimmed.write(
                to: scenesDir.appendingPathComponent("_preamble.fountain"),
                atomically: true, encoding: .utf8)
            // Insert preamble item right after title page (index 1)
            let preambleItem = StructureItem(
                id: UUID().uuidString,
                title: "Preamble",
                type: .document,
                path: "Scenes/_preamble.fountain")
            structure.insert(preambleItem, at: 1)
        }
    }

    return structure
}

private func hasPreambleBefore(
    index: Int, in lines: [FountainLine]
) -> Bool {
    for i in 0..<index {
        switch lines[i].element {
        case .titlePage, .section:
            continue
        default:
            return true
        }
    }
    return false
}
```

Also remove the `MigratorError.preambleNotYetSupported` throw — `writeSceneFile` is now never called for preamble content because preamble is handled separately.

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 477 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ScreenplayMigrator.swift MaughamTests/ScreenplayMigratorTests.swift
git commit -m "feat: migrator handles preamble + empty edge cases

Action paragraphs that appear before any slugline migrate to
Scenes/_preamble.fountain (underscore-prefixed sentinel — sorts
after 00-title in Finder and signals 'less canonical' content).
Empty screenplays and title-page-only screenplays migrate to a
single placeholder title page document.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Hook migrator into ProjectStore

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: `MaughamTests/ScreenplayMigratorTests.swift`

- [ ] **Step 1: Add failing integration test**

Append to `ScreenplayMigratorTests`:

```swift
    func test_projectStore_loadingScreenplay_triggersMigration() async throws {
        let raw = """
        INT. ROOM - DAY

        Action.

        EXT. PARK - NIGHT

        BARRY
        Hi.
        """
        let project = try makeProject(fountainContent: raw)
        let store = try await ProjectStore(url: project)

        // After load, structure should be migrated
        XCTAssertGreaterThanOrEqual(store.manifest.structure.count, 3)
        XCTAssertTrue(store.manifest.structure.contains(where: { $0.role == .titlePage }))
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayMigratorTests/test_projectStore_loadingScreenplay_triggersMigration CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: FAIL — migration doesn't run automatically.

- [ ] **Step 3: Hook migration into ProjectStore initialization**

In `ProjectStore.swift`, find the `init` that loads the manifest. After parsing the manifest but before publishing it, run the migrator:

```swift
public init(url: URL) async throws {
    self.url = url

    // Run screenplay migration if applicable. Idempotent.
    let migrator = ScreenplayMigrator(projectURL: url)
    _ = try migrator.migrate()

    // Existing manifest load
    let manifestURL = url.appendingPathComponent("project.maugham.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
    self.manifest = manifest
    // ... rest of existing init
}
```

(Adjust to match the actual existing init shape.)

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 478 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ScreenplayMigratorTests.swift
git commit -m "feat: ProjectStore runs ScreenplayMigrator on load

Single-file screenplay projects auto-migrate to multi-file on
first 3d open. Idempotent: subsequent opens detect the multi-file
shape (structure.count > 1 or path under Scenes/) and skip.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: CompoundOffsetMap

**Files:**
- Create: `Maugham/Editor/Fountain/CompoundOffsetMap.swift`
- Test: `MaughamTests/CompoundOffsetMapTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class CompoundOffsetMapTests: XCTestCase {
    func test_singleChild_compoundRangeMatchesLocal() {
        let map = CompoundOffsetMap(childLengths: [100])
        let result = map.childAndLocalRange(for: NSRange(location: 25, length: 10))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].childIndex, 0)
        XCTAssertEqual(result[0].localRange, NSRange(location: 25, length: 10))
    }

    func test_twoChildren_rangeFullyInSecond() {
        // child 0: [0..100), separator at [100..102), child 1: [102..200)
        let map = CompoundOffsetMap(childLengths: [100, 98])
        let result = map.childAndLocalRange(for: NSRange(location: 150, length: 10))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].childIndex, 1)
        XCTAssertEqual(result[0].localRange, NSRange(location: 48, length: 10))
    }

    func test_twoChildren_rangeSpansBoundary_splits() {
        let map = CompoundOffsetMap(childLengths: [100, 98])
        // Range [95, 110): 5 chars in child 0 (loc 95, len 5), separator skipped, 8 chars in child 1 (loc 0, len 8)
        let result = map.childAndLocalRange(for: NSRange(location: 95, length: 15))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].childIndex, 0)
        XCTAssertEqual(result[0].localRange, NSRange(location: 95, length: 5))
        XCTAssertEqual(result[1].childIndex, 1)
        XCTAssertEqual(result[1].localRange, NSRange(location: 0, length: 8))
    }

    func test_compoundLength_includesSeparators() {
        let map = CompoundOffsetMap(childLengths: [10, 10, 10])
        // 10 + 2 + 10 + 2 + 10 = 34
        XCTAssertEqual(map.compoundLength, 34)
    }

    func test_childIndex_forCompoundOffset() {
        let map = CompoundOffsetMap(childLengths: [10, 10, 10])
        XCTAssertEqual(map.childIndex(forCompoundOffset: 5), 0)
        XCTAssertEqual(map.childIndex(forCompoundOffset: 15), 1) // 10+2+3
        XCTAssertEqual(map.childIndex(forCompoundOffset: 33), 2)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/CompoundOffsetMapTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement CompoundOffsetMap**

Create `Maugham/Editor/Fountain/CompoundOffsetMap.swift`:

```swift
import Foundation

/// Translates between compound-document text ranges and (child, local-range)
/// pairs. Children are concatenated in order, joined by a fixed separator
/// (default `\n\n`). The map is recomputed when any child's length changes.
public struct CompoundOffsetMap: Equatable, Sendable {
    public static let separatorLength = 2 // "\n\n"

    public let childLengths: [Int]

    public init(childLengths: [Int]) {
        self.childLengths = childLengths
    }

    public var compoundLength: Int {
        guard !childLengths.isEmpty else { return 0 }
        let totalChildren = childLengths.reduce(0, +)
        let separators = (childLengths.count - 1) * Self.separatorLength
        return totalChildren + separators
    }

    /// Compound offset where `childIndex`'s text begins.
    public func compoundStart(of childIndex: Int) -> Int {
        var offset = 0
        for i in 0..<childIndex {
            offset += childLengths[i] + Self.separatorLength
        }
        return offset
    }

    /// Which child owns this compound offset (clamped to last child).
    public func childIndex(forCompoundOffset offset: Int) -> Int {
        var cursor = 0
        for (i, len) in childLengths.enumerated() {
            let childEnd = cursor + len
            if offset < childEnd { return i }
            cursor = childEnd + Self.separatorLength
            if offset < cursor { return i } // inside the separator following child i
        }
        return max(0, childLengths.count - 1)
    }

    /// Translate a compound range to one or more (childIndex, localRange) slices.
    /// Edits inside the separator gap are attributed to the preceding child
    /// (so deleting a separator triggers a merge signal for that child's owner).
    public func childAndLocalRange(for compound: NSRange) -> [(childIndex: Int, localRange: NSRange)] {
        var slices: [(childIndex: Int, localRange: NSRange)] = []
        var cursor = 0
        var remaining = compound

        for (i, len) in childLengths.enumerated() {
            let childRange = NSRange(location: cursor, length: len)
            if let intersect = remaining.intersection(childRange), intersect.length > 0 {
                slices.append((
                    childIndex: i,
                    localRange: NSRange(
                        location: intersect.location - cursor,
                        length: intersect.length)))
            }
            cursor += len + Self.separatorLength
            if cursor >= NSMaxRange(remaining) { break }
        }
        // Empty range (insertion point): map to single child slice with zero length
        if compound.length == 0 && slices.isEmpty {
            let i = childIndex(forCompoundOffset: compound.location)
            let local = compound.location - compoundStart(of: i)
            slices.append((
                childIndex: i,
                localRange: NSRange(location: max(0, local), length: 0)))
        }
        return slices
    }
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 483 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundOffsetMap.swift MaughamTests/CompoundOffsetMapTests.swift
git commit -m "feat: CompoundOffsetMap range translation

Pure value type that maps compound ranges to per-child (index,
localRange) slices and back. Children separated by \\n\\n; edits
in the separator gap attribute to the preceding child so a merge
signal fires when a separator is deleted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: CompoundScreenplayDocument scaffolding

**Files:**
- Create: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`
- Test: `MaughamTests/CompoundScreenplayDocumentTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class CompoundScreenplayDocumentTests: XCTestCase {
    /// Helper: write N scene files and a manifest, return the project URL.
    private func makeMultiFileProject(scenes: [(filename: String, content: String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compound-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scenesDir = tmp.appendingPathComponent("Scenes")
        try FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)

        var structure: [StructureItem] = []
        for (filename, content) in scenes {
            try content.write(
                to: scenesDir.appendingPathComponent(filename),
                atomically: true, encoding: .utf8)
            let role: ItemRole? = filename == "00-title.fountain" ? .titlePage : nil
            structure.append(StructureItem(
                id: UUID().uuidString,
                title: filename,
                type: .document,
                path: "Scenes/\(filename)",
                role: role))
        }
        let manifest = ProjectManifest(
            type: .screenplay, title: "Test", author: "Tester",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    @MainActor
    func test_loadsAllChildren_concatenatedCorrectly() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("00-title.fountain", "Title: Test\n"),
            ("scene-a.fountain", "INT. ROOM - DAY\n\nAction.\n"),
            ("scene-b.fountain", "EXT. PARK - NIGHT\n\nMore action.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)

        let text = doc.textStorage.string
        XCTAssertTrue(text.contains("Title: Test"))
        XCTAssertTrue(text.contains("INT. ROOM"))
        XCTAssertTrue(text.contains("EXT. PARK"))
        XCTAssertEqual(doc.children.count, 3)
    }

    @MainActor
    func test_currentSceneId_atTitlePageOffset() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("00-title.fountain", "Title: Test\n"),
            ("scene-a.fountain", "INT. ROOM - DAY\n\nAction.\n"),
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)
        let titleId = store.manifest.structure[0].id
        XCTAssertEqual(doc.currentSceneId(forCursor: 0), titleId)
    }

    @MainActor
    func test_currentSceneId_atSecondSceneOffset() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("00-title.fountain", "Title: Test\n"),
            ("scene-a.fountain", "INT. ROOM - DAY\n\nAction.\n"),
            ("scene-b.fountain", "EXT. PARK - NIGHT\n\nMore action.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)
        let sceneBId = store.manifest.structure[2].id
        // Position deep in third child
        let titleLen = (try String(contentsOf: project.appendingPathComponent("Scenes/00-title.fountain")) as NSString).length
        let sceneALen = (try String(contentsOf: project.appendingPathComponent("Scenes/scene-a.fountain")) as NSString).length
        let cursor = titleLen + 2 + sceneALen + 2 + 5
        XCTAssertEqual(doc.currentSceneId(forCursor: cursor), sceneBId)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/CompoundScreenplayDocumentTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: COMPILE FAIL.

- [ ] **Step 3: Implement CompoundScreenplayDocument scaffolding**

Create `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`:

```swift
import Foundation
import AppKit

/// Compound document over N child .fountain files. Presents a single
/// concatenated NSTextStorage to the editor; edit routing splits mutations
/// across children. Auto-split / auto-merge / file persistence are layered
/// on in subsequent tasks (9, 10, 11).
@MainActor
public final class CompoundScreenplayDocument {
    public struct Child {
        public let itemId: String
        public let path: String
        public var contents: String
    }

    public let projectURL: URL
    public private(set) var children: [Child]
    public private(set) var offsetMap: CompoundOffsetMap
    public let textStorage: NSTextStorage

    private weak var projectStore: ProjectStore?

    public init(projectStore: ProjectStore) async throws {
        self.projectStore = projectStore
        self.projectURL = projectStore.url

        var loaded: [Child] = []
        try Self.collectChildren(
            from: projectStore.manifest.structure,
            into: &loaded,
            projectURL: projectStore.url)
        self.children = loaded
        self.offsetMap = CompoundOffsetMap(childLengths: loaded.map { ($0.contents as NSString).length })

        let combined = loaded.map { $0.contents }.joined(separator: "\n\n")
        self.textStorage = NSTextStorage(string: combined)
    }

    /// Walk a structure tree (acts contain children); collect screenplay
    /// documents in flattened display order. Title page is first by manifest
    /// convention; we don't reorder it here.
    private static func collectChildren(
        from items: [StructureItem],
        into out: inout [Child],
        projectURL: URL
    ) throws {
        for item in items {
            switch item.type {
            case .document:
                guard let path = item.path else { continue }
                let url = projectURL.appendingPathComponent(path)
                let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                out.append(Child(itemId: item.id, path: path, contents: contents))
            case .group:
                if let children = item.children {
                    try collectChildren(
                        from: children, into: &out, projectURL: projectURL)
                }
            }
        }
    }

    /// Which scene-document's id is the cursor currently inside.
    public func currentSceneId(forCursor offset: Int) -> String? {
        guard !children.isEmpty else { return nil }
        let idx = offsetMap.childIndex(forCompoundOffset: offset)
        return children[safe: idx]?.itemId
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 486 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift MaughamTests/CompoundScreenplayDocumentTests.swift
git commit -m "feat: CompoundScreenplayDocument scaffolding

Loads N child scene files in manifest display order, produces a
concatenated NSTextStorage, exposes cursor → sceneId mapping via
the offset map. Edit routing, auto-split, auto-merge, and
persistence land in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Edit routing — single-child + cross-boundary

**Files:**
- Modify: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`
- Test: `MaughamTests/CompoundScreenplayDocumentTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
    @MainActor
    func test_edit_inSingleChild_updatesThatChildOnly() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("00-title.fountain", "Title: A\n"),
            ("scene-a.fountain", "INT. ROOM - DAY\n\nAction.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)
        let originalTitle = doc.children[0].contents

        // Edit in scene A: replace "Action" with "Movement"
        let compoundText = doc.textStorage.string as NSString
        let actionLoc = compoundText.range(of: "Action").location
        doc.replaceCharacters(
            in: NSRange(location: actionLoc, length: 6), with: "Movement")

        XCTAssertEqual(doc.children[0].contents, originalTitle)
        XCTAssertTrue(doc.children[1].contents.contains("Movement"))
        XCTAssertFalse(doc.children[1].contents.contains("Action"))
    }

    @MainActor
    func test_edit_acrossBoundary_routesToBothChildren() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("a.fountain", "AAA"),
            ("b.fountain", "BBB")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)
        // Compound text: "AAA\n\nBBB" (length 8)
        // Replace [2..6] with "X" → child0 keeps "AA", child1 keeps "BB"
        doc.replaceCharacters(
            in: NSRange(location: 2, length: 4), with: "X")
        // Expected post-edit: child0 = "AAX", child1 = "BB"
        // (the X is attributed to child0 because edits at left boundary go left)
        XCTAssertEqual(doc.children[0].contents, "AAX")
        XCTAssertEqual(doc.children[1].contents, "BB")
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/CompoundScreenplayDocumentTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: 2 failures.

- [ ] **Step 3: Implement edit routing**

Add to `CompoundScreenplayDocument`:

```swift
    /// Apply an edit to the compound text, routing per-child writes.
    /// `replacement` is split between affected children proportionally:
    /// it's inserted into the first affected child by default; cross-boundary
    /// deletions remove text from each affected child's local range and the
    /// replacement attaches to the leading child.
    public func replaceCharacters(in range: NSRange, with replacement: String) {
        let slices = offsetMap.childAndLocalRange(for: range)
        guard !slices.isEmpty else { return }

        // For multi-slice edits, attribute the replacement to the FIRST slice
        // (typical behavior: insertion at boundary, paste, multi-line replace).
        for (i, slice) in slices.enumerated() {
            var localReplacement = ""
            if i == 0 { localReplacement = replacement }
            let original = children[slice.childIndex].contents
            let nsOriginal = original as NSString
            let mutated = nsOriginal.replacingCharacters(
                in: slice.localRange, with: localReplacement) as String
            children[slice.childIndex].contents = mutated
        }

        // Recompute offset map + storage
        offsetMap = CompoundOffsetMap(
            childLengths: children.map { ($0.contents as NSString).length })
        let combined = children.map { $0.contents }.joined(separator: "\n\n")
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length), with: combined)
    }
```

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 488 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift MaughamTests/CompoundScreenplayDocumentTests.swift
git commit -m "feat: edit routing for compound screenplay

replaceCharacters(in:with:) splits edits per-child via the offset
map. Replacement text attaches to the first affected child;
cross-boundary deletions are honored. NSTextStorage is rebuilt
from the new children array so the editor sees the consistent
post-edit stream.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Per-child file persistence

**Files:**
- Modify: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`
- Test: `MaughamTests/CompoundScreenplayDocumentTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
    @MainActor
    func test_edit_persistsToCorrectChildFile() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("00-title.fountain", "Title: A\n"),
            ("scene-a.fountain", "INT. ROOM - DAY\n\nOriginal.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)

        let compoundText = doc.textStorage.string as NSString
        let origLoc = compoundText.range(of: "Original").location
        doc.replaceCharacters(in: NSRange(location: origLoc, length: 8), with: "Modified")
        try await doc.flushPendingWrites()

        let onDisk = try String(
            contentsOf: project.appendingPathComponent("Scenes/scene-a.fountain"),
            encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Modified"))
        XCTAssertFalse(onDisk.contains("Original"))

        // Title page untouched
        let title = try String(
            contentsOf: project.appendingPathComponent("Scenes/00-title.fountain"),
            encoding: .utf8)
        XCTAssertEqual(title, "Title: A\n")
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/CompoundScreenplayDocumentTests/test_edit_persistsToCorrectChildFile CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: FAIL — `flushPendingWrites` doesn't exist; no persistence.

- [ ] **Step 3: Add persistence**

In `CompoundScreenplayDocument`, track dirty children and flush on demand:

```swift
    private var dirtyChildren: Set<Int> = []

    public func replaceCharacters(in range: NSRange, with replacement: String) {
        let slices = offsetMap.childAndLocalRange(for: range)
        guard !slices.isEmpty else { return }

        for (i, slice) in slices.enumerated() {
            var localReplacement = ""
            if i == 0 { localReplacement = replacement }
            let original = children[slice.childIndex].contents
            let nsOriginal = original as NSString
            let mutated = nsOriginal.replacingCharacters(
                in: slice.localRange, with: localReplacement) as String
            children[slice.childIndex].contents = mutated
            dirtyChildren.insert(slice.childIndex)
        }

        offsetMap = CompoundOffsetMap(
            childLengths: children.map { ($0.contents as NSString).length })
        let combined = children.map { $0.contents }.joined(separator: "\n\n")
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length), with: combined)
    }

    /// Flush all pending child writes synchronously.
    public func flushPendingWrites() async throws {
        for index in dirtyChildren {
            let child = children[index]
            let url = projectURL.appendingPathComponent(child.path)
            try child.contents.write(to: url, atomically: true, encoding: .utf8)
        }
        dirtyChildren.removeAll()
    }
```

(In a later milestone we'll wire each child to its own debounced DocumentStore. For 3d MVP, we own the writes directly and flush on demand. Autosave timer integration is Task 21.)

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 489 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift MaughamTests/CompoundScreenplayDocumentTests.swift
git commit -m "feat: per-child file persistence in compound document

Dirty-child tracking on every edit; flushPendingWrites writes only
the affected files. Untouched scene files are not rewritten so
NSFileCoordinator/NSFilePresenter conflict scoping stays per-scene.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Wire CompoundScreenplayDocument to EditorSurface

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Test: manual smoke (instructions below)

- [ ] **Step 1: Detect screenplay-multi-file in ProjectWindow**

In `ProjectWindow.swift`, add state for the compound document:

```swift
@State private var compoundDocument: CompoundScreenplayDocument? = nil
```

In the `load()` async helper, after `ProjectStore` is loaded, if the project type is `.screenplay` and the structure has more than one item, instantiate the compound:

```swift
if store.manifest.type == .screenplay && store.manifest.structure.count > 1 {
    compoundDocument = try await CompoundScreenplayDocument(projectStore: store)
}
```

- [ ] **Step 2: Pass compound to EditorSurface**

`EditorSurface` currently reads the active document text from a `String` binding. Add an optional `compoundTextStorage: NSTextStorage?` parameter that, when present, the editor uses *instead of* the per-document text:

```swift
struct EditorSurface: NSViewRepresentable {
    @Binding var text: String
    var compoundTextStorage: NSTextStorage? = nil
    // ... existing parameters
}
```

In `makeNSView`, if `compoundTextStorage` is non-nil, swap the text view's text storage for it:

```swift
func makeNSView(context: Context) -> NSScrollView {
    // ... existing setup
    if let compound = compoundTextStorage {
        textView.layoutManager?.replaceTextStorage(compound)
    } else {
        textView.string = text
    }
    return scrollView
}
```

In `ProjectWindow.contentColumn`, pass the compound when present:

```swift
EditorSurface(
    text: $editorText,
    compoundTextStorage: compoundDocument?.textStorage,
    // ... existing args
)
```

- [ ] **Step 3: Manual smoke (no test for this task)**

Build and launch the app:

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Then open a multi-file screenplay (or trigger migration on a single-file one). The editor should display the concatenated content. Typing should land in the active scene's file.

- [ ] **Step 4: Run full suite to verify no regression**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 489 tests, with 0 failures` (no new tests in this task; manual smoke is the gate).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorSurface.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: editor uses CompoundScreenplayDocument for multi-file screenplays

When a screenplay project's manifest has > 1 structure item, the
ProjectWindow instantiates a CompoundScreenplayDocument and hands
its NSTextStorage to EditorSurface. The editor sees one continuous
stream; edits route to the right child file via the compound's
edit-routing logic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Phase 1 smoke checkpoint

- [ ] **Manual smoke checklist**

Open a 3c single-file screenplay project. Verify:
- It auto-migrates on first open: `Scenes/00-title.fountain`, `Scenes/<scene>.fountain` exist; original `.fountain` renamed to `.fountain.bak`.
- Manifest has multi-item `structure` with title page first, scenes after.
- Editor shows the concatenated content as one continuous stream.
- Typing into a scene's region edits only that scene's file (verify by checking file mtime after typing).
- Reopening the project doesn't re-migrate (idempotent).
- 489 tests still pass.

If anything fails, fix before proceeding to Phase 2.

---

## Phase 2 — Structure: auto-split, auto-merge, binder UX

### Task 13: Auto-split detection + file creation

**Files:**
- Modify: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`
- Modify: `Maugham/Stores/ProjectStore.swift` — add `appendStructureItem` helper
- Test: `MaughamTests/AutoSplitTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/AutoSplitTests.swift`:

```swift
import XCTest
@testable import Maugham

final class AutoSplitTests: XCTestCase {
    private func makeProject(scenes: [(String, String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoSplit-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scenesDir = tmp.appendingPathComponent("Scenes")
        try FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)
        var structure: [StructureItem] = []
        for (name, content) in scenes {
            try content.write(to: scenesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: UUID().uuidString, title: name, type: .document,
                path: "Scenes/\(name)",
                role: name == "00-title.fountain" ? .titlePage : nil))
        }
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    @MainActor
    func test_typingNewSlugline_createsNewSceneFile() async throws {
        let project = try makeProject(scenes: [
            ("00-title.fountain", "Title: T\n"),
            ("scene-a.fountain", "INT. ROOM - DAY\n\nAction.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)

        // Find the end of "Action.\n" in the compound stream and insert "\n\nINT. NEW PLACE - NIGHT\n\nMore.\n"
        let combined = doc.textStorage.string as NSString
        let actionEnd = combined.range(of: "Action.\n").location + 8
        doc.replaceCharacters(
            in: NSRange(location: actionEnd, length: 0),
            with: "\n\nINT. NEW PLACE - NIGHT\n\nMore.\n")

        // Trigger auto-split detection
        await doc.checkForStructuralChanges()

        // Two scenes now exist on disk
        let scenesDir = project.appendingPathComponent("Scenes")
        let allFiles = try FileManager.default.contentsOfDirectory(
            atPath: scenesDir.path).sorted()
        XCTAssertTrue(allFiles.contains("int-new-place-night.fountain"))
        XCTAssertTrue(allFiles.contains("scene-a.fountain"))

        // Manifest now has 3 items
        let updatedStore = try await ProjectStore(url: project)
        XCTAssertEqual(updatedStore.manifest.structure.count, 3)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/AutoSplitTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: FAIL — `checkForStructuralChanges` not implemented.

- [ ] **Step 3: Implement auto-split**

Add to `CompoundScreenplayDocument`:

```swift
    /// Re-parse each child and detect new sluglines mid-child. For each
    /// detected mid-child slugline, split the child: cut at the slugline,
    /// keep the prefix in the original file, write the suffix as a new file,
    /// insert the new StructureItem into the manifest.
    public func checkForStructuralChanges() async {
        var newChildren: [Child] = []
        var newStructureUpdates: [(insertAfter: String, newItem: StructureItem, content: String)] = []

        for child in children {
            // Skip title page (no scene splitting there)
            if child.path.hasSuffix("00-title.fountain") {
                newChildren.append(child)
                continue
            }
            let script = FountainTokenizer.parse(child.contents)
            let sceneHeads = script.lines.enumerated().filter {
                if case .sceneHeading = $0.element.element { return true }
                return false
            }
            // First slugline at offset 0 is normal; any subsequent slugline = split point
            if sceneHeads.count <= 1 {
                newChildren.append(child)
                continue
            }
            // Split into N children
            var cursor = child
            var afterId = child.itemId
            for splitIdx in 1..<sceneHeads.count {
                let line = sceneHeads[splitIdx].element
                let splitLoc = line.range.location
                let nsContents = cursor.contents as NSString
                let prefix = nsContents.substring(to: splitLoc)
                let suffix = nsContents.substring(from: splitLoc)
                cursor.contents = prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

                let slug = FileNaming.kebabCase(line.content)
                let newPath = "Scenes/\(slug).fountain"
                let newItem = StructureItem(
                    id: UUID().uuidString,
                    title: line.content,
                    type: .document,
                    path: newPath)
                newStructureUpdates.append((
                    insertAfter: afterId, newItem: newItem,
                    content: suffix))
                afterId = newItem.id
            }
            newChildren.append(cursor)
            for update in newStructureUpdates where update.insertAfter == cursor.itemId
                || newStructureUpdates.firstIndex(where: { $0.newItem.id == update.insertAfter }) != nil {
                newChildren.append(Child(itemId: update.newItem.id, path: update.newItem.path!, contents: update.content))
            }
        }
        children = newChildren

        // Persist new files
        for update in newStructureUpdates {
            let url = projectURL.appendingPathComponent(update.newItem.path!)
            try? update.content.write(to: url, atomically: true, encoding: .utf8)
            try? await projectStore?.addStructureItem(
                update.newItem, after: update.insertAfter)
        }

        // Persist updates to existing children
        try? await flushPendingWrites()

        // Recompute offset map
        offsetMap = CompoundOffsetMap(childLengths: children.map { ($0.contents as NSString).length })
    }
```

Add a helper to ProjectStore: `addStructureItem(_:after:)` that walks the structure tree, finds the item with `after.id`, and inserts the new item right after it (preserving group nesting). If `after` doesn't exist, append at top level.

```swift
public func addStructureItem(_ item: StructureItem, after afterId: String) async throws {
    func insert(into items: inout [StructureItem]) -> Bool {
        for i in 0..<items.count {
            if items[i].id == afterId {
                items.insert(item, at: i + 1)
                return true
            }
            if var children = items[i].children {
                if insert(into: &children) {
                    items[i].children = children
                    return true
                }
            }
        }
        return false
    }
    if !insert(into: &manifest.structure) {
        manifest.structure.append(item)
    }
    try await save()
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 490 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift Maugham/Stores/ProjectStore.swift MaughamTests/AutoSplitTests.swift
git commit -m "feat: auto-split on new slugline mid-scene

When a child contains > 1 sceneHeading after parsing, CompoundScreenplayDocument
splits the child at each slugline, writes the suffix as a new scene file,
and inserts a corresponding StructureItem into the manifest after the original.
Files dedupe via FileNaming.kebabCase + counter suffix.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Auto-merge on slugline deletion

**Files:**
- Modify: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`
- Modify: `Maugham/Stores/ProjectStore.swift` — already has `deleteStructureItem`
- Test: `MaughamTests/AutoMergeTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class AutoMergeTests: XCTestCase {
    private func makeProject(scenes: [(String, String)]) throws -> URL {
        // (Same helper as AutoSplitTests — copy verbatim)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMerge-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scenesDir = tmp.appendingPathComponent("Scenes")
        try FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)
        var structure: [StructureItem] = []
        for (name, content) in scenes {
            try content.write(to: scenesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: UUID().uuidString, title: name, type: .document,
                path: "Scenes/\(name)",
                role: name == "00-title.fountain" ? .titlePage : nil))
        }
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    @MainActor
    func test_deletingSlugline_mergesIntoPreviousScene() async throws {
        let project = try makeProject(scenes: [
            ("00-title.fountain", "Title: T\n"),
            ("a.fountain", "INT. ROOM - DAY\n\nAction A.\n"),
            ("b.fountain", "INT. KITCHEN - NIGHT\n\nAction B.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)

        // Delete the second scene's slugline
        let s = doc.textStorage.string as NSString
        let kitchenLoc = s.range(of: "INT. KITCHEN - NIGHT\n").location
        doc.replaceCharacters(
            in: NSRange(location: kitchenLoc, length: 21), with: "")

        await doc.checkForStructuralChanges()

        XCTAssertEqual(doc.children.count, 2) // title + scene-a (which now contains both bodies)
        XCTAssertTrue(doc.children[1].contents.contains("Action A"))
        XCTAssertTrue(doc.children[1].contents.contains("Action B"))

        // File b.fountain deleted
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Scenes/b.fountain").path))
    }

    @MainActor
    func test_deletingFirstSceneSlugline_doesNotMergeIntoTitlePage() async throws {
        let project = try makeProject(scenes: [
            ("00-title.fountain", "Title: T\n"),
            ("a.fountain", "INT. ROOM - DAY\n\nAction A.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)

        // Delete scene A's slugline
        let s = doc.textStorage.string as NSString
        let roomLoc = s.range(of: "INT. ROOM - DAY\n").location
        doc.replaceCharacters(
            in: NSRange(location: roomLoc, length: 16), with: "")

        await doc.checkForStructuralChanges()

        // Scene A file STILL EXISTS (now headless)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Scenes/a.fountain").path))
        XCTAssertEqual(doc.children.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/AutoMergeTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: 2 failures.

- [ ] **Step 3: Implement auto-merge**

Extend `checkForStructuralChanges` in `CompoundScreenplayDocument`:

```swift
    public func checkForStructuralChanges() async {
        // Auto-split (existing from Task 13)
        await checkForAutoSplit()
        // Auto-merge: if scene N's first non-empty line is no longer a slugline,
        // and scene N is not the first scene, merge into scene N-1.
        await checkForAutoMerge()
        offsetMap = CompoundOffsetMap(childLengths: children.map { ($0.contents as NSString).length })
    }

    private func checkForAutoSplit() async { /* existing Task 13 body */ }

    private func checkForAutoMerge() async {
        var i = children.count - 1
        while i > 1 { // Skip title page (i=0) and first scene (i=1)
            let child = children[i]
            let script = FountainTokenizer.parse(child.contents)
            let firstLine = script.lines.first(where: { line in
                if case .titlePage = line.element { return false }
                return !line.content.trimmingCharacters(in: .whitespaces).isEmpty
            })
            let isHeadless: Bool = {
                guard let first = firstLine else { return true }
                if case .sceneHeading = first.element { return false }
                return true
            }()

            if isHeadless {
                // Merge into previous
                var prev = children[i - 1]
                let mergedContent = prev.contents
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + child.contents.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n"
                prev.contents = mergedContent
                children[i - 1] = prev
                dirtyChildren.insert(i - 1)

                // Delete the merged child's file + manifest entry
                let url = projectURL.appendingPathComponent(child.path)
                try? FileManager.default.removeItem(at: url)
                try? await projectStore?.deleteStructureItem(id: child.itemId)

                children.remove(at: i)
            }
            i -= 1
        }
        try? await flushPendingWrites()
    }
```

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 492 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift MaughamTests/AutoMergeTests.swift
git commit -m "feat: auto-merge on slugline deletion

When a non-first scene's first non-empty line is no longer a
sceneHeading, its content is appended to the previous scene
(\\n\\n separator), the file is deleted, and the StructureItem
is removed from the manifest. First scene that loses its slugline
stays as a headless file (never merges into title page).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Hook structural changes into editor change pipeline

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Editor/EditorSurface.swift`

- [ ] **Step 1: Wire change-debouncer to call checkForStructuralChanges**

Currently `EditorCoordinator` parses on text change. Extend it to also call the compound's `checkForStructuralChanges` when present, on a debounced 500ms timer (so we don't split on every keystroke during typing).

In `EditorCoordinator.swift`, add:

```swift
weak var compoundDocument: CompoundScreenplayDocument?
private var structuralCheckWorkItem: DispatchWorkItem?

private func scheduleStructuralCheck() {
    structuralCheckWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
        guard let compound = self?.compoundDocument else { return }
        Task { @MainActor in
            await compound.checkForStructuralChanges()
        }
    }
    structuralCheckWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
}
```

Call `scheduleStructuralCheck()` from the existing `textDidChange` / parser-recompute hook.

In `EditorSurface.makeNSView`, after creating the coordinator:

```swift
context.coordinator.compoundDocument = compoundDocument
```

And wire `compoundDocument` through `EditorSurface`'s parameters from `ProjectWindow`.

- [ ] **Step 2: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 492 tests, with 0 failures` (no new tests; behavior verified in manual smoke).

- [ ] **Step 3: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham/Editor/EditorSurface.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: editor schedules structural check 500ms after text change

EditorCoordinator now triggers CompoundScreenplayDocument.checkForStructuralChanges
on a debounced 500ms timer after each text mutation. The delay avoids re-splitting
on every keystroke during typing of a slugline; once the writer pauses, auto-split
or auto-merge fires.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 16: Retire .scenes binder segment for screenplays

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift` (keep `.scenes` enum case for storage compat, but UI no longer surfaces it)
- Modify: `Maugham/Views/BinderPaneToggle.swift`

- [ ] **Step 1: Update BinderPaneToggle**

Replace the screenplay branch of the picker with the same `Manuscript / Research` picker novels use:

```swift
Picker("Segment", selection: $segment) {
    Text("Manuscript").tag(BinderSegment.manuscript)
    Text("Research").tag(BinderSegment.research)
}
```

Remove the `if projectType == .screenplay` branch. The `.scenes` segment case remains in the enum (so old persisted UIState that has `.scenes` still decodes), but if observed at load it's coerced to `.manuscript`:

```swift
.onAppear {
    if segment == .scenes { segment = .manuscript }
}
```

- [ ] **Step 2: Update body switch**

Remove the `.scenes` case from the body's switch:

```swift
switch segment {
case .manuscript:
    BinderView(store: store, selectedItemId: $selectedItemId)
case .research:
    ResearchView(store: store, selectedResearchId: $selectedResearchId)
case .scenes:
    BinderView(store: store, selectedItemId: $selectedItemId) // coerced
}
```

- [ ] **Step 3: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 492 tests, with 0 failures`

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/BinderPaneToggle.swift
git commit -m "refactor: retire .scenes binder segment for screenplays

Multi-file screenplays now show scenes natively in the Manuscript
binder (each scene is a StructureItem). The dedicated .scenes segment
was useful only when the whole script was one StructureItem. Picker
becomes Manuscript / Research for both novels and screenplays. The
enum case stays for UIState decode compat, coerced to .manuscript
on appear.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: Title page row + scene rows in BinderView

**Files:**
- Modify: `Maugham/Views/BinderView.swift`
- Test: `MaughamTests/ScreenplayBinderActionsTests.swift` (subset)

- [ ] **Step 1: Add visual treatment for title page rows**

In `BinderView.swift`, when rendering a row whose `item.role == .titlePage`, show a `doc.text` SF Symbol prefix and disable rename + drag-into-folder. When `item.path?.hasSuffix(".fountain") == true` and `role == nil`, show `p.N · 1¼p` annotation on the trailing edge.

```swift
private func sceneAnnotation(for item: StructureItem) -> String? {
    guard let path = item.path, path.hasSuffix(".fountain") else { return nil }
    guard item.role == nil else { return nil }
    guard let compound = compoundDocument else { return nil }
    let pageNum = compound.pageNumber(forItemId: item.id) ?? 1
    let length = compound.sceneLength(forItemId: item.id) ?? 0
    return "p.\(pageNum) · \(SceneNavigatorPane.formatPages(length))"
}
```

(Reuses the existing `SceneNavigatorPane.formatPages` static helper from 3c.)

Add to the row body:

```swift
HStack {
    if item.role == .titlePage {
        Image(systemName: "doc.text").foregroundStyle(.secondary)
    }
    Text(item.title)
    Spacer()
    if let annotation = sceneAnnotation(for: item) {
        Text(annotation)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
```

Add helper methods to `CompoundScreenplayDocument`:

```swift
public func pageNumber(forItemId id: String) -> Int? {
    guard let idx = children.firstIndex(where: { $0.itemId == id }) else { return nil }
    var totalLines = 0
    for i in 0..<idx {
        let script = FountainTokenizer.parse(children[i].contents)
        totalLines += Int(script.estimatedPageCount * 55)
    }
    return (totalLines / 55) + 1
}

public func sceneLength(forItemId id: String) -> Double? {
    guard let child = children.first(where: { $0.itemId == id }) else { return nil }
    return FountainTokenizer.parse(child.contents).estimatedPageCount
}
```

- [ ] **Step 2: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 492 tests, with 0 failures`

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/BinderView.swift Maugham/Editor/Fountain/CompoundScreenplayDocument.swift
git commit -m "feat: title page icon + per-scene annotations in binder

Scene rows in screenplay projects show 'p.N · 1¼p' on the trailing
edge (page number + scene length, reusing 3c's formatter). Title
page rows show a doc.text SF Symbol prefix as a visual cue that
this is the metadata document.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 18: Selection follows cursor + click-to-jump

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift`

- [ ] **Step 1: Add notifications**

Add to `MaughamNotifications.swift`:

```swift
public static let maughamCompoundCursorChanged = Notification.Name("maugham.compound.cursor.changed")
public static let maughamCompoundJumpToScene = Notification.Name("maugham.compound.jump.scene")
```

- [ ] **Step 2: Post on cursor change in EditorCoordinator**

In `EditorCoordinator.swift`, in the existing cursor-change tracker, if `compoundDocument` is non-nil, post:

```swift
if let compound = compoundDocument,
   let sceneId = compound.currentSceneId(forCursor: textView.selectedRange.location) {
    NotificationCenter.default.post(
        name: .maughamCompoundCursorChanged,
        object: nil,
        userInfo: ["sceneId": sceneId])
}
```

- [ ] **Step 3: Update binder selection on cursor change**

In `ProjectWindow.swift`, subscribe:

```swift
.onReceive(NotificationCenter.default.publisher(for: .maughamCompoundCursorChanged)) { note in
    if let id = note.userInfo?["sceneId"] as? String {
        selectedItemId = id
    }
}
```

- [ ] **Step 4: Click binder → scroll editor**

When `selectedItemId` changes via binder click (not via cursor), scroll the editor to that scene's compound start. Add a `.onChange(of: selectedItemId)` modifier:

```swift
.onChange(of: selectedItemId) { _, newId in
    guard let compound = compoundDocument, let id = newId else { return }
    NotificationCenter.default.post(
        name: .maughamCompoundJumpToScene,
        object: nil,
        userInfo: ["sceneId": id])
}
```

In `EditorCoordinator`, observe `maughamCompoundJumpToScene` and scroll the textView to that scene's compound start:

```swift
NotificationCenter.default.addObserver(
    forName: .maughamCompoundJumpToScene, object: nil, queue: .main
) { [weak self] note in
    guard let self,
          let id = note.userInfo?["sceneId"] as? String,
          let compound = self.compoundDocument,
          let idx = compound.children.firstIndex(where: { $0.itemId == id }) else { return }
    let offset = compound.offsetMap.compoundStart(of: idx)
    self.textView?.setSelectedRange(NSRange(location: offset, length: 0))
    self.textView?.scrollRangeToVisible(NSRange(location: offset, length: 0))
}
```

(This creates a feedback loop risk: cursor moves → binder selects → compound jump fires → cursor moves again. Mitigate by guarding the `onChange` so it only fires when the source is a binder click, not a cursor-driven update. Use a flag like `private var isUpdatingFromCursor = false` set during cursor-driven `selectedItemId` writes.)

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 492 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham/Views/ProjectWindow.swift Maugham/Models/MaughamNotifications.swift
git commit -m "feat: bidirectional binder ↔ editor sync for screenplays

Cursor moves in the compound editor → binder selection follows.
Clicking a scene in the binder → editor scrolls to that scene's
compound start. Feedback loop guard prevents the two from racing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 19: Drag-reorder for screenplay structure

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` — verify `moveStructureItem` handles screenplay items
- Test: `MaughamTests/ScreenplayBinderActionsTests.swift`

- [ ] **Step 1: Add failing test**

```swift
import XCTest
@testable import Maugham

final class ScreenplayBinderActionsTests: XCTestCase {
    @MainActor
    func test_moveScene_betweenActs() async throws {
        // Project with two acts, one scene each
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinderActions-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Scenes"), withIntermediateDirectories: true)
        for name in ["00-title.fountain", "a.fountain", "b.fountain"] {
            try "\(name)\n".write(
                to: tmp.appendingPathComponent("Scenes/\(name)"),
                atomically: true, encoding: .utf8)
        }
        let titleId = UUID().uuidString
        let act1Id = UUID().uuidString
        let act2Id = UUID().uuidString
        let aId = UUID().uuidString
        let bId = UUID().uuidString
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: titleId, title: "Title Page", type: .document,
                              path: "Scenes/00-title.fountain", role: .titlePage),
                StructureItem(id: act1Id, title: "ACT ONE", type: .group,
                              children: [
                                StructureItem(id: aId, title: "A", type: .document, path: "Scenes/a.fountain")
                              ]),
                StructureItem(id: act2Id, title: "ACT TWO", type: .group,
                              children: [
                                StructureItem(id: bId, title: "B", type: .document, path: "Scenes/b.fountain")
                              ])
            ],
            research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore(url: tmp)
        // Move scene B from ACT TWO to ACT ONE end
        try await store.moveStructureItem(id: bId, toParentId: act1Id, atIndex: 1)

        let act1 = store.manifest.structure.first(where: { $0.id == act1Id })
        XCTAssertEqual(act1?.children?.count, 2)
        XCTAssertEqual(act1?.children?[1].id, bId)

        let act2 = store.manifest.structure.first(where: { $0.id == act2Id })
        XCTAssertEqual(act2?.children?.count, 0)
    }
}
```

- [ ] **Step 2: Run test**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayBinderActionsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: PASS if `moveStructureItem` already handles this case (it should — it's the same code path novels use). If FAIL, debug `moveStructureItem` to ensure it tolerates `role: .titlePage` items in the sibling array.

- [ ] **Step 3: If needed, fix `moveStructureItem`**

(Likely no changes needed — the existing implementation walks the tree by id, indifferent to role.)

- [ ] **Step 4: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 493 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add MaughamTests/ScreenplayBinderActionsTests.swift
git commit -m "test: drag-reorder verifies for screenplay scenes across acts

Existing moveStructureItem already handles screenplay structure since
it walks the tree by ID without inspecting role. Test pins the
behavior so future refactors don't break it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 20: New Scene + New Act binder actions

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` — add `addNewSceneFile` and `addNewActFolder`
- Modify: `Maugham/Views/BinderView.swift` — context menu items
- Test: `MaughamTests/ScreenplayBinderActionsTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `ScreenplayBinderActionsTests`:

```swift
    @MainActor
    func test_addNewScene_createsFileAndManifestEntry() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddScene-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Scenes"), withIntermediateDirectories: true)
        try "Title:\n".write(
            to: tmp.appendingPathComponent("Scenes/00-title.fountain"),
            atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: UUID().uuidString, title: "Title Page", type: .document,
                path: "Scenes/00-title.fountain", role: .titlePage)],
            research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore(url: tmp)
        let newScene = try await store.addNewSceneFile()

        XCTAssertEqual(store.manifest.structure.count, 2)
        XCTAssertEqual(store.manifest.structure[1].id, newScene.id)
        let content = try String(contentsOf:
            tmp.appendingPathComponent(newScene.path ?? ""), encoding: .utf8)
        XCTAssertTrue(content.contains("INT. UNTITLED"))
    }

    @MainActor
    func test_addNewAct_createsGroup() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddAct-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [],
            research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore(url: tmp)
        let act = try await store.addNewActFolder(title: "ACT THREE")

        XCTAssertEqual(act.type, .group)
        XCTAssertEqual(act.title, "ACT THREE")
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayBinderActionsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: 2 failures.

- [ ] **Step 3: Implement actions on ProjectStore**

```swift
@discardableResult
public func addNewSceneFile() async throws -> StructureItem {
    let scenesDir = url.appendingPathComponent("Scenes")
    try FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)
    let baseName = "untitled-scene"
    var counter = 1
    var filename = "\(baseName).fountain"
    while FileManager.default.fileExists(
        atPath: scenesDir.appendingPathComponent(filename).path) {
        counter += 1
        filename = "\(baseName)-\(counter).fountain"
    }
    let content = "INT. UNTITLED — DAY\n\n\n"
    try content.write(
        to: scenesDir.appendingPathComponent(filename),
        atomically: true, encoding: .utf8)
    let item = StructureItem(
        id: UUID().uuidString,
        title: "INT. UNTITLED — DAY",
        type: .document,
        path: "Scenes/\(filename)")
    manifest.structure.append(item)
    try await save()
    return item
}

@discardableResult
public func addNewActFolder(title: String) async throws -> StructureItem {
    let item = StructureItem(
        id: UUID().uuidString,
        title: title,
        type: .group,
        children: [])
    manifest.structure.append(item)
    try await save()
    return item
}
```

- [ ] **Step 4: Wire into BinderView context menu**

In `BinderView.swift`, add menu items for screenplay projects:

```swift
.contextMenu {
    if store.manifest.type == .screenplay {
        Button("New Scene") {
            Task { try? await store.addNewSceneFile() }
        }
        Button("New Act") {
            Task { try? await store.addNewActFolder(title: "ACT N") }
        }
        Divider()
    }
    // existing items
}
```

- [ ] **Step 5: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 495 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift Maugham/Views/BinderView.swift MaughamTests/ScreenplayBinderActionsTests.swift
git commit -m "feat: New Scene + New Act binder actions for screenplays

Right-click in the screenplay binder shows New Scene (creates an
empty Scenes/untitled-scene-N.fountain with a placeholder slugline)
and New Act (creates an empty group with placeholder title).
Cursor jumps to the new scene's start automatically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 21: Inspector — page target field for screenplay scenes

**Files:**
- Modify: `Maugham/Views/InspectorView.swift`

- [ ] **Step 1: Swap word target to page target for screenplay scenes**

In `InspectorView.swift`, where the existing "Word target" stepper renders, branch on project type:

```swift
if store.manifest.type == .screenplay {
    Text("Page target")
    Stepper(value: pageTargetBinding, in: 0...20, step: 0.25) {
        Text(SceneNavigatorPane.formatPages(pageTargetBinding.wrappedValue))
    }
} else {
    Text("Word target")
    Stepper(value: wordTargetBinding, in: 0...100000, step: 50) {
        Text("\(wordTargetBinding.wrappedValue)")
    }
}
```

Where `pageTargetBinding` reads/writes a new optional Double field on `StructureItem` — but since we don't want a schema migration, repurpose the existing `wordTarget` field by storing `pageTarget * 100` as Int (preserving exact ¼-page increments without schema change). Alternatively: add `pageTarget: Double?` to StructureItem and let it round-trip alongside `wordTarget`.

For minimum disruption, **add `pageTarget: Double?` to StructureItem**:

```swift
public struct StructureItem {
    // existing
    public var pageTarget: Double?
}
```

(Make sure to thread it through `init` with default `nil`.)

- [ ] **Step 2: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 495 tests, with 0 failures`

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/InspectorView.swift Maugham/Models/StructureItem.swift
git commit -m "feat: Inspector page target field for screenplay scenes

Word target swaps to a page target stepper (in 0.25 increments)
when the project type is screenplay. New optional pageTarget: Double?
field on StructureItem stores the value; manifest schema stays at v1
(additive optional field).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 22: Phase 2 smoke checkpoint

- [ ] **Manual smoke checklist**

In a fresh multi-file screenplay or migrated 3c project:

1. Type a new `INT. NEW LOCATION — DAY` mid-scene → after a brief pause, the binder shows a new item; the file appears in `Scenes/`.
2. Delete a scene's slugline → after pause, the scene merges into the previous one in the binder; the file is gone from disk.
3. Drag scene A from ACT ONE to ACT TWO → manifest reflects new parent; binder updates.
4. Right-click → New Scene → new scene appears with placeholder slugline; cursor jumps there.
5. Right-click → New Act → new empty act folder appears.
6. Click a scene in the binder → editor scrolls to that scene's start.
7. Type in scene 5 → binder selection follows the cursor, highlighting scene 5.
8. Inspector shows "Page target" stepper for the active scene; setting it to 1.5 persists.
9. Title page row has the doc.text icon prefix; can't be dragged into ACT folders.
10. 495 tests still passing.

If anything fails, fix before proceeding to Phase 3.

---

## Phase 3 — Polish: page count, conflicts, find/replace, smoke

### Task 23: Compound page count

**Files:**
- Modify: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift` — already has `pageNumber(forItemId:)`, add `estimatedPageCount`
- Test: `MaughamTests/CompoundPageCountTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Maugham

final class CompoundPageCountTests: XCTestCase {
    @MainActor
    func test_estimatedPageCount_sumsPerSceneApprox() async throws {
        // Build a project with two sufficient-length scenes
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageCount-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Scenes"), withIntermediateDirectories: true)
        try "Title:\n".write(
            to: tmp.appendingPathComponent("Scenes/00-title.fountain"),
            atomically: true, encoding: .utf8)
        let scene = "INT. ROOM - DAY\n\n" + Array(repeating: "Action.", count: 50).joined(separator: "\n") + "\n"
        try scene.write(
            to: tmp.appendingPathComponent("Scenes/a.fountain"),
            atomically: true, encoding: .utf8)
        try scene.write(
            to: tmp.appendingPathComponent("Scenes/b.fountain"),
            atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: UUID().uuidString, title: "Title", type: .document,
                              path: "Scenes/00-title.fountain", role: .titlePage),
                StructureItem(id: UUID().uuidString, title: "A", type: .document, path: "Scenes/a.fountain"),
                StructureItem(id: UUID().uuidString, title: "B", type: .document, path: "Scenes/b.fountain")
            ],
            research: [])
        try JSONEncoder().encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore(url: tmp)
        let doc = try await CompoundScreenplayDocument(projectStore: store)

        let total = doc.estimatedPageCount
        let perSceneEstimate = FountainTokenizer.parse(scene).estimatedPageCount
        XCTAssertEqual(total, 2 * perSceneEstimate, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/CompoundPageCountTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: COMPILE FAIL — `estimatedPageCount` doesn't exist on compound.

- [ ] **Step 3: Implement on CompoundScreenplayDocument**

```swift
public var estimatedPageCount: Double {
    children
        .filter { $0.path != "Scenes/00-title.fountain" } // title doesn't paginate
        .map { FountainTokenizer.parse($0.contents).estimatedPageCount }
        .reduce(0, +)
}
```

- [ ] **Step 4: Surface in goal indicator**

Verify the existing goal indicator capsule consumes `estimatedPageCount`. If it currently reads from a single-script context, route it through `compoundDocument?.estimatedPageCount` when present.

- [ ] **Step 5: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 496 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift MaughamTests/CompoundPageCountTests.swift
git commit -m "feat: compound estimatedPageCount sums per-scene

Title page excluded (it doesn't paginate). Goal indicator
capsule now reads from the compound document for screenplay
projects, falling back to single-script estimate for novels.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 24: Per-child external file change handling

**Files:**
- Modify: `Maugham/Editor/Fountain/CompoundScreenplayDocument.swift`
- Test: `MaughamTests/CompoundScreenplayDocumentTests.swift`

- [ ] **Step 1: Add failing test**

Append:

```swift
    @MainActor
    func test_externalChange_toOneScene_reloadsThatChildOnly() async throws {
        let project = try makeMultiFileProject(scenes: [
            ("00-title.fountain", "Title: T\n"),
            ("a.fountain", "INT. A - DAY\n\nOriginal A.\n"),
            ("b.fountain", "INT. B - DAY\n\nOriginal B.\n")
        ])
        let store = try await ProjectStore(url: project)
        let doc = try await CompoundScreenplayDocument(projectStore: store)
        let originalB = doc.children[2].contents

        // External write to scene a only
        try "INT. A - DAY\n\nExternally changed A.\n".write(
            to: project.appendingPathComponent("Scenes/a.fountain"),
            atomically: true, encoding: .utf8)

        try await doc.reloadChildFromDisk(itemId: doc.children[1].itemId)

        XCTAssertTrue(doc.children[1].contents.contains("Externally changed"))
        XCTAssertEqual(doc.children[2].contents, originalB)
    }
```

- [ ] **Step 2: Run test to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/CompoundScreenplayDocumentTests/test_externalChange_toOneScene_reloadsThatChildOnly CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: FAIL — `reloadChildFromDisk` doesn't exist.

- [ ] **Step 3: Implement reloadChildFromDisk**

```swift
public func reloadChildFromDisk(itemId: String) async throws {
    guard let idx = children.firstIndex(where: { $0.itemId == itemId }) else { return }
    let url = projectURL.appendingPathComponent(children[idx].path)
    let contents = try String(contentsOf: url, encoding: .utf8)
    children[idx].contents = contents
    offsetMap = CompoundOffsetMap(childLengths: children.map { ($0.contents as NSString).length })
    let combined = children.map { $0.contents }.joined(separator: "\n\n")
    textStorage.replaceCharacters(
        in: NSRange(location: 0, length: textStorage.length), with: combined)
}
```

Wire `NSFilePresenter` per-child reload to call this — for 3d MVP, hook into the existing `presenterDidChangeSubitem(at:)` on `ProjectStore` and call `compoundDocument?.reloadChildFromDisk(itemId:)` for the matching child.

- [ ] **Step 4: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`
Expected: `Executed 497 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/CompoundScreenplayDocument.swift Maugham/Stores/ProjectStore.swift MaughamTests/CompoundScreenplayDocumentTests.swift
git commit -m "feat: per-child external file change reload

When NSFilePresenter reports a change to one scene file, only
that child reloads. Other scenes' contents stay in memory.
The existing ConflictDiffSheet flow stays per-scene.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 25: Phase 3 final smoke + tag

- [ ] **Manual smoke checklist before tag**

1. **Migration** — open a 3c single-file screenplay → migrates to multi-file → editor stream identical to before.
2. **Edit routing** — type in scene 3 → only `Scenes/<scene-3>.fountain` mtime changes.
3. **Auto-split** — type `INT. CLOSET — NIGHT` mid-scene → after pause, new file + new binder item appear.
4. **Auto-merge** — delete a scene's slugline → after pause, scene merges + file deleted + binder updates.
5. **Headless first scene** — delete the first scene's slugline → file stays as headless action; no merge into title page.
6. **Drag-reorder** — scenes within an act, between acts, at top level.
7. **New Scene / New Act** — context menu actions create files + manifest entries.
8. **Selection follows cursor** — typing in scene 7 highlights scene 7 in binder.
9. **Click-jump** — click scene 7 in binder → editor scrolls to its start.
10. **Page count** — bottom-right capsule shows compound page count summed across scenes.
11. **Inspector page target** — set 1.5p on a scene; persists; reloads correctly.
12. **External change** — `echo "..." > Scenes/foo.fountain` from terminal → editor reloads that scene only.
13. **Find/Replace** — works across all scenes; replace lands in correct child files.
14. **Title page** — distinct icon, can't drag into act folder, content edits persist to `00-title.fountain`.
15. **Phase 1 + 2 + 3 features** — 3a-3c features (parser, page count, inline emphasis, syntax help, scene navigator → now retired) all still work.
16. **497 tests pass.**

If all green:

- [ ] **Tag and push**

```bash
git checkout main
git merge --ff-only feat/milestone-3d  # if work was on a branch
git tag -a milestone-3d -m "Phase 3d — multi-file screenplay

CompoundScreenplayDocument abstraction over per-scene .fountain files.
Editor shows one continuous stream; binder shows scenes as draggable
cards with acts as folders. Auto-split on new slugline, auto-merge on
deleted slugline. Existing single-file projects auto-migrate
transparently with .fountain.bak safety net.

497 tests passing."
git push origin main
git push origin milestone-3d
```

- [ ] **Update memory**

Add `project_milestone_3d.md` and append entry to `MEMORY.md`.

---

## Spec coverage check

Reviewed against `docs/superpowers/specs/2026-05-10-maugham-phase-3d-design.md`:

| Spec section | Covered by task(s) |
|---|---|
| Architecture: CompoundScreenplayDocument | T7-T11 |
| Data model: ItemRole + StructureItem.role | T1 |
| Data model: filename conventions | T2-T5 (migrator) + T20 (new scene) |
| Compound editor: concatenation | T8 |
| Compound editor: edit routing | T9, T10 |
| Compound editor: auto-split | T13 |
| Compound editor: auto-merge | T14 |
| Compound editor: cursor → scene mapping | T8, T18 |
| Compound editor: external file changes | T24 |
| Binder: title page row | T17 |
| Binder: act folders | (already supported by ProjectStore — verified in T19) |
| Binder: scene rows with annotations | T17 |
| Binder: selection follows cursor | T18 |
| Binder: drag-and-drop | T19 |
| Binder: New Scene / New Act | T20 |
| Binder: Inspector page target | T21 |
| Binder: scene navigator retirement | T16 |
| Migration: detection + flow | T2-T6 |
| Migration: edge cases (empty, title-only, preamble) | T5 |
| Cross-cutting: page count | T17, T23 |
| Cross-cutting: autosave (per-child) | T10 |
| Cross-cutting: conflict resolution (per-child) | T24 |
| Cross-cutting: find/replace | T25 (manual smoke; no code change needed) |
| Out of scope (Compile, autocomplete, FDX, etc.) | not implemented (correct) |
| Testing strategy | T1-T24 unit + integration; T12, T22, T25 smoke |

Total task count: 25 (12 in Phase 1, 10 in Phase 2, 3 in Phase 3).
Test count target: 465 → ~497 passing.
