# Maugham Phase 1d — Project Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Maugham from a single-document Short Story experience into a real multi-document project workspace. Novel projects ship with a writable hierarchical binder (right-click add/rename/delete; no reorder yet); Screenplay and Collection ship as functional stubs. The window grows to a three-pane `NavigationSplitView`. Inspector shows synopsis, status, live word count. `Project Settings…` (⌘⌥,) overrides typography per-project. File menu gets Open Recent. Help → Set up Claude Desktop opens a sheet with a copyable MCP config snippet for the current project.

**Architecture:** Infrastructure tidy lands first: `ThemeManager` → `UserPreferences` rename and notification consolidation, so subsequent work uses clean names. Then pure-logic foundations (Slugifier, FileNaming, manifest schema addition, ProjectStore mutation methods) — each TDD'd. Then ScreenplayMode + WritingModeFactory + per-extension mode selection. Then UI layer: BinderView, InspectorView, ProjectSettingsSheet, HelpClaudeDesktopSheet, EditorHost (binds editor to selected document, picks WritingMode by extension). ProjectWindow refactors to three-pane NavigationSplitView. App-level commands (Open Recent, Help, ⌘⌥,) wire into MaughamApp.

**Tech Stack:** Swift 5.10+, SwiftUI (`NavigationSplitView`, `OutlineGroup`, `.contextMenu`, `.sheet`), AppKit (`NSWorkspace.recycle`, `NSPasteboard`), Foundation (`FileManager`, atomic JSON write), XCTest. macOS 14+ deployment. xcodegen-managed project.

**Anchor:** This plan implements the spec at `docs/superpowers/specs/2026-05-07-maugham-phase-1d-projects-design.md`.

**Execution branch:** `feat/phase-1d-projects` (created in Task 1; merge to main on milestone tag).

---

## Locked decisions (from brainstorm)

1. Scope: project expansion only; DocumentStore + iCloud + conflict resolution land separately as 1e.
2. Binder writes: right-click add/rename/delete; **no reorder UI** in 1d (drag-reorder + multi-file rename require DocumentStore).
3. Novel default skeleton: single chapter at root (mirrors Short Story's pattern).
4. Status values: Draft / Revising / Final (picker; binder shows colored dot).
5. Per-project typography: `Project Settings…` modal sheet at ⌘⌥, with a "Use my defaults" toggle.
6. Help → Claude Desktop: in-app sheet with copyable per-project JSON MCP config.
7. Filename scheme: `NN-slug.ext` numbered prefix (final-state-aligned with Phase 2).
8. ThemeManager rename to `UserPreferences` lands first (infra).

---

## File structure (created or modified during this plan)

```
Maugham/Models/
  MaughamNotifications.swift            # NEW (consolidated Notification.Name extensions)
  ProjectManifest.swift                 # MODIFIED — adds optional typography: TypographySettings?
  Slugifier.swift                       # NEW
  FileNaming.swift                      # NEW

Maugham/Preferences/                    # NEW (renamed from Theme/)
  Theme.swift                           # MOVED from Theme/
  TypographySettings.swift              # MOVED from Theme/ + extended with .screenplayDefaults
  UserPreferences.swift                 # RENAMED from ThemeManager.swift

Maugham/Editor/
  ScreenplayMode.swift                  # NEW
  WritingModeFactory.swift              # NEW
  EditorSurface.swift                   # MODIFIED — minor (mode dynamic per file)

Maugham/Stores/
  ProjectStore.swift                    # MODIFIED — adds 5 mutation methods + effectiveTypography
  ProjectFactory.swift                  # MODIFIED — adds Novel/Screenplay/Collection factories

Maugham/Views/
  EditorHost.swift                      # NEW (binds editor to selected document, picks WritingMode)
  BinderRow.swift                       # NEW
  BinderView.swift                      # NEW
  InspectorView.swift                   # NEW
  ProjectSettingsSheet.swift            # NEW
  HelpClaudeDesktopSheet.swift          # NEW
  ProjectWindow.swift                   # MODIFIED — three-pane NavigationSplitView
  NewProjectSheet.swift                 # MODIFIED — enables Novel/Screenplay/Collection
  SettingsView.swift                    # MODIFIED — uses UserPreferences (rename)
  SettingsTabs/EditorSettingsTab.swift  # MODIFIED — uses UserPreferences (rename)
  SettingsTabs/ThemeSettingsTab.swift   # MODIFIED — uses UserPreferences (rename)
  SettingsTabs/TypographySettingsTab.swift  # MODIFIED — uses UserPreferences (rename)

Maugham/MaughamApp.swift                # MODIFIED — Open Recent submenu, Help, ⌘⌥,, Show Inspector toggle

MaughamTests/
  SlugifierTests.swift                  # NEW
  FileNamingTests.swift                 # NEW
  ProjectStoreMutationTests.swift       # NEW
  ProjectStoreTypographyTests.swift     # NEW
  WritingModeFactoryTests.swift         # NEW
  ScreenplayModeTests.swift             # NEW
  ProjectFactoryTests.swift             # MODIFIED — covers all four types
  ProjectManifestTests.swift            # MODIFIED — covers typography roundtrip
  ThemeManagerTests.swift               # RENAMED to UserPreferencesTests.swift (mechanical)
```

11 new main files, 6 new test files, 9 modified main files, 2 modified test files, 1 renamed test file.

---

## Task 1: Create feature branch

**Working directory:** `/Users/denver/src/Maugham`

- [ ] **Step 1: Confirm clean main and create branch**

```bash
git status
git log --oneline -3
git checkout -b feat/phase-1d-projects
```

Expected: working tree clean, latest commit on main is `21ad371` (1d design spec). Branch creation prints `Switched to a new branch 'feat/phase-1d-projects'`.

No commit for this task.

---

## Task 2: Consolidate Notification.Name extensions

**Files:**
- Create: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift` (remove the inline extension)
- Modify: `Maugham/Views/ProjectWindow.swift` (remove the inline extension)

The notification names are currently scattered across two files. Consolidate them into one location for clarity.

- [ ] **Step 1: Create MaughamNotifications.swift**

`Maugham/Models/MaughamNotifications.swift`:
```swift
import Foundation

extension Notification.Name {
    public static let maughamNewProject = Notification.Name("maugham.newProject")
    public static let maughamOpenProject = Notification.Name("maugham.openProject")
    public static let maughamToggleNoChrome = Notification.Name("maugham.toggleNoChrome")
    public static let maughamToggleFullScreen = Notification.Name("maugham.toggleFullScreen")
    public static let maughamDummySave = Notification.Name("maugham.dummySave")
}
```

- [ ] **Step 2: Remove the inline extension at the top of MaughamApp.swift**

In `Maugham/MaughamApp.swift`, delete lines 4–7 (the `extension Notification.Name { ... }` block with `maughamNewProject` and `maughamOpenProject`).

- [ ] **Step 3: Remove the inline extension at the bottom of ProjectWindow.swift**

In `Maugham/Views/ProjectWindow.swift`, delete the `extension Notification.Name { ... }` block (containing `maughamToggleNoChrome`, `maughamToggleFullScreen`, `maughamDummySave`).

- [ ] **Step 4: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Names resolve via the new file.

- [ ] **Step 5: Run full test suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 90 tests passing (no test changes; just verifying nothing regressed).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "refactor: consolidate Notification.Name extensions into MaughamNotifications.swift"
```

---

## Task 3: Rename ThemeManager → UserPreferences and move folder

**Files:**
- Move: `Maugham/Theme/ThemeManager.swift` → `Maugham/Preferences/UserPreferences.swift`
- Move: `Maugham/Theme/Theme.swift` → `Maugham/Preferences/Theme.swift`
- Move: `Maugham/Theme/TypographySettings.swift` → `Maugham/Preferences/TypographySettings.swift`
- Rename: `MaughamTests/ThemeManagerTests.swift` → `MaughamTests/UserPreferencesTests.swift`
- Modify: `Maugham/MaughamApp.swift` (replace `ThemeManager` references with `UserPreferences`)
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `Maugham/Views/SettingsView.swift`
- Modify: `Maugham/Views/SettingsTabs/EditorSettingsTab.swift`
- Modify: `Maugham/Views/SettingsTabs/ThemeSettingsTab.swift`
- Modify: `Maugham/Views/SettingsTabs/TypographySettingsTab.swift`

This is a mechanical rename across ~7 files. After this task, `ThemeManager` doesn't exist anywhere; `UserPreferences` is the new name.

- [ ] **Step 1: Move files**

```bash
mkdir -p Maugham/Preferences
git mv Maugham/Theme/Theme.swift Maugham/Preferences/Theme.swift
git mv Maugham/Theme/TypographySettings.swift Maugham/Preferences/TypographySettings.swift
git mv Maugham/Theme/ThemeManager.swift Maugham/Preferences/UserPreferences.swift
rmdir Maugham/Theme
git mv MaughamTests/ThemeManagerTests.swift MaughamTests/UserPreferencesTests.swift
```

- [ ] **Step 2: Update class name inside UserPreferences.swift**

In `Maugham/Preferences/UserPreferences.swift`, find:
```swift
public final class ThemeManager {
```
Replace with:
```swift
public final class UserPreferences {
```

Update the doc comment at the top to reflect the new name. The full updated body should match the existing file but with all `ThemeManager` strings replaced. Verify with:
```bash
grep -n "ThemeManager" Maugham/Preferences/UserPreferences.swift
```
Expected: no matches.

- [ ] **Step 3: Update test class name and references**

In `MaughamTests/UserPreferencesTests.swift`:
```bash
sed -i '' 's/ThemeManager/UserPreferences/g' MaughamTests/UserPreferencesTests.swift
sed -i '' 's/ThemeManagerTests/UserPreferencesTests/g' MaughamTests/UserPreferencesTests.swift
```

Open the file and confirm:
- Class is `final class UserPreferencesTests: XCTestCase`
- All `manager: ThemeManager!` → `manager: UserPreferences!`
- All `ThemeManager(defaults: ...)` → `UserPreferences(defaults: ...)`

- [ ] **Step 4: Update consumers**

For each of the 6 consumer files, replace `ThemeManager` with `UserPreferences`:

```bash
sed -i '' 's/ThemeManager/UserPreferences/g' \
  Maugham/MaughamApp.swift \
  Maugham/Views/ProjectWindow.swift \
  Maugham/Views/SettingsView.swift \
  Maugham/Views/SettingsTabs/EditorSettingsTab.swift \
  Maugham/Views/SettingsTabs/ThemeSettingsTab.swift \
  Maugham/Views/SettingsTabs/TypographySettingsTab.swift
```

After this, verify no `ThemeManager` references remain anywhere:
```bash
grep -rn "ThemeManager" Maugham MaughamTests
```
Expected: empty output.

Note: the user-defaults *keys* inside UserPreferences (e.g., `"maugham.theme"`, `"maugham.typewriterScroll"`) stay as they were so persisted preferences continue to load correctly across the rename.

- [ ] **Step 5: Regenerate, run tests, expect 90 passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 90 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Preferences MaughamTests/UserPreferencesTests.swift Maugham/MaughamApp.swift Maugham/Views/
git rm -r Maugham/Theme 2>/dev/null || true
git commit -m "refactor: rename ThemeManager to UserPreferences and move to Preferences folder"
```

---

## Task 4: Slugifier

**Files:**
- Create: `Maugham/Models/Slugifier.swift`
- Create: `MaughamTests/SlugifierTests.swift`

Pure-logic helper that converts a project/document title to a filesystem slug.

- [ ] **Step 1: Write failing tests**

`MaughamTests/SlugifierTests.swift`:
```swift
import XCTest
@testable import Maugham

final class SlugifierTests: XCTestCase {

    func test_simpleTitle_lowercased_and_dashed() {
        XCTAssertEqual(Slugifier.slug(from: "Chapter 1"), "chapter-1")
    }

    func test_punctuation_isStripped() {
        XCTAssertEqual(Slugifier.slug(from: "The Razor's Edge!"), "the-razors-edge")
    }

    func test_consecutiveSpaces_collapseToSingleDash() {
        XCTAssertEqual(Slugifier.slug(from: "Chapter   One"), "chapter-one")
    }

    func test_leadingTrailingSpaces_areTrimmed() {
        XCTAssertEqual(Slugifier.slug(from: "  Hello World  "), "hello-world")
    }

    func test_emptyString_fallsBackToUntitled() {
        XCTAssertEqual(Slugifier.slug(from: ""), "untitled")
    }

    func test_onlyPunctuation_fallsBackToUntitled() {
        XCTAssertEqual(Slugifier.slug(from: "!!!???"), "untitled")
    }

    func test_unicode_isStrippedToAscii() {
        // "Über das Leben" — the umlaut decomposes to "Uber" via NFD
        XCTAssertEqual(Slugifier.slug(from: "Über das Leben"), "uber-das-leben")
    }

    func test_longTitle_truncatesTo40Chars() {
        let long = String(repeating: "a", count: 100)
        let slug = Slugifier.slug(from: long)
        XCTAssertEqual(slug.count, 40)
        XCTAssertEqual(slug, String(repeating: "a", count: 40))
    }

    func test_truncationDoesNotEndOnDash() {
        // 50 chars: 40 a's + dash + ... should truncate to 40 a's, not 39 a's + dash
        let title = String(repeating: "a", count: 40) + " " + String(repeating: "b", count: 10)
        let slug = Slugifier.slug(from: title)
        XCTAssertFalse(slug.hasSuffix("-"))
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SlugifierTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find 'Slugifier' in scope`.

- [ ] **Step 3: Implement**

`Maugham/Models/Slugifier.swift`:
```swift
import Foundation

/// Converts a human-readable title into a filesystem-safe slug:
/// lowercase, ASCII-only, dashes for spaces, max 40 chars, fallback "untitled".
public enum Slugifier {

    private static let maxLength = 40
    private static let fallback = "untitled"

    public static func slug(from title: String) -> String {
        // Step 1: NFD-normalise then strip combining marks (decomposes "ü" → "u" + combining diaeresis)
        let folded = title.folding(options: [.diacriticInsensitive], locale: .current)

        // Step 2: lowercased
        let lowered = folded.lowercased()

        // Step 3: keep only [a-z 0-9 space dash], replace everything else with space
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 -")
        let filtered = String(lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })

        // Step 4: collapse runs of whitespace/dashes to single dash, trim
        var collapsed = ""
        var prevDash = false
        for ch in filtered {
            if ch == " " || ch == "-" {
                if !prevDash && !collapsed.isEmpty {
                    collapsed.append("-")
                    prevDash = true
                }
            } else {
                collapsed.append(ch)
                prevDash = false
            }
        }
        if collapsed.hasSuffix("-") {
            collapsed.removeLast()
        }

        // Step 5: truncate, then strip trailing dash if truncation landed on one
        var truncated = String(collapsed.prefix(maxLength))
        while truncated.hasSuffix("-") {
            truncated.removeLast()
        }

        return truncated.isEmpty ? fallback : truncated
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 9 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SlugifierTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

If a test fails (especially `test_unicode_isStrippedToAscii` — Unicode normalization is finicky), iterate the implementation, NOT the test.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/Slugifier.swift MaughamTests/SlugifierTests.swift
git commit -m "feat: add Slugifier for title-to-filename conversion"
```

---

## Task 5: FileNaming

**Files:**
- Create: `Maugham/Models/FileNaming.swift`
- Create: `MaughamTests/FileNamingTests.swift`

Computes `NN-slug.ext` (or `NN-slug` for groups) given existing siblings.

- [ ] **Step 1: Write failing tests**

`MaughamTests/FileNamingTests.swift`:
```swift
import XCTest
@testable import Maugham

final class FileNamingTests: XCTestCase {

    func test_documentInEmptyFolder_getsNN01() {
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md", siblingFilenames: [])
        XCTAssertEqual(name, "01-chapter-1.md")
    }

    func test_documentAfterTwoSiblings_getsNN03() {
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 3", extension: "md",
            siblingFilenames: ["01-chapter-1.md", "02-chapter-2.md"])
        XCTAssertEqual(name, "03-chapter-3.md")
    }

    func test_documentWithGapInNN_skipsToMaxPlusOne() {
        // After deletes, NN sequence may have gaps. Always use max+1.
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 4", extension: "md",
            siblingFilenames: ["01-chapter-1.md", "04-chapter-4.md"])
        XCTAssertEqual(name, "05-chapter-4.md")
    }

    func test_documentWithSlugCollision_getsSuffix() {
        // Same title twice: second gets "-2" before extension
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md",
            siblingFilenames: ["01-chapter-1.md"])
        XCTAssertEqual(name, "02-chapter-1-2.md")
    }

    func test_documentWithMultipleSlugCollisions_getsSequentialSuffix() {
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md",
            siblingFilenames: ["01-chapter-1.md", "02-chapter-1-2.md"])
        XCTAssertEqual(name, "03-chapter-1-3.md")
    }

    func test_groupFolderName_followsSamePattern() {
        let name = FileNaming.nextGroupFolderName(
            title: "Act One", siblingFilenames: ["01-prologue.md"])
        XCTAssertEqual(name, "02-act-one")
    }

    func test_groupFolderName_emptyFolder_getsNN01() {
        let name = FileNaming.nextGroupFolderName(
            title: "Act One", siblingFilenames: [])
        XCTAssertEqual(name, "01-act-one")
    }

    func test_fountainExtension_supportedForScreenplay() {
        let name = FileNaming.nextDocumentFilename(
            title: "Scene 1", extension: "fountain", siblingFilenames: [])
        XCTAssertEqual(name, "01-scene-1.fountain")
    }

    func test_unrelatedFiles_areIgnoredForNNComputation() {
        // .DS_Store, .gitkeep, anything not matching NN-slug pattern
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md",
            siblingFilenames: [".DS_Store", "01-chapter-1.md", "notes.txt"])
        XCTAssertEqual(name, "02-chapter-1-2.md")
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FileNamingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find 'FileNaming' in scope`.

- [ ] **Step 3: Implement**

`Maugham/Models/FileNaming.swift`:
```swift
import Foundation

/// Computes filenames for new structure items: `NN-slug.ext` for documents,
/// `NN-slug` for group folders. NN is monotonically increasing within a
/// parent folder; slug collisions get a numeric suffix.
public enum FileNaming {

    /// `siblingFilenames` is the list of existing files/folders in the parent.
    /// Returns a name guaranteed not to collide.
    public static func nextDocumentFilename(
        title: String,
        extension ext: String,
        siblingFilenames: [String]
    ) -> String {
        let base = Slugifier.slug(from: title)
        let nn = nextNN(in: siblingFilenames)
        let slug = uniqueSlug(base: base, ext: ext, isFolder: false,
                              siblings: siblingFilenames)
        return "\(nn)-\(slug).\(ext)"
    }

    public static func nextGroupFolderName(
        title: String,
        siblingFilenames: [String]
    ) -> String {
        let base = Slugifier.slug(from: title)
        let nn = nextNN(in: siblingFilenames)
        let slug = uniqueSlug(base: base, ext: nil, isFolder: true,
                              siblings: siblingFilenames)
        return "\(nn)-\(slug)"
    }

    // MARK: - Helpers

    /// Parse `NN-...` from each sibling. NN must be a 2-digit prefix
    /// followed by a dash. Files that don't match are ignored.
    private static func nextNN(in siblings: [String]) -> String {
        let regex = try? NSRegularExpression(pattern: #"^(\d{2})-"#)
        var maxNN = 0
        for name in siblings {
            let range = NSRange(name.startIndex..., in: name)
            guard let regex,
                  let match = regex.firstMatch(in: name, range: range),
                  let nnRange = Range(match.range(at: 1), in: name),
                  let n = Int(name[nnRange]) else { continue }
            if n > maxNN { maxNN = n }
        }
        return String(format: "%02d", maxNN + 1)
    }

    private static func uniqueSlug(
        base: String,
        ext: String?,
        isFolder: Bool,
        siblings: [String]
    ) -> String {
        // Extract the post-NN slug part of each sibling (with same extension or folder type)
        let regex = try? NSRegularExpression(pattern: #"^\d{2}-(.+?)(\.[^.]+)?$"#)
        var existingSlugs = Set<String>()
        for name in siblings {
            let range = NSRange(name.startIndex..., in: name)
            guard let regex,
                  let match = regex.firstMatch(in: name, range: range),
                  let slugRange = Range(match.range(at: 1), in: name) else { continue }
            // Match if extension matches (for documents) or no extension (for folders)
            let extPart = match.range(at: 2).location != NSNotFound
                ? Range(match.range(at: 2), in: name).map { String(name[$0]) }
                : nil
            if isFolder {
                if extPart == nil {
                    existingSlugs.insert(String(name[slugRange]))
                }
            } else if let ext, extPart == ".\(ext)" {
                existingSlugs.insert(String(name[slugRange]))
            }
        }

        if !existingSlugs.contains(base) {
            return base
        }
        var n = 2
        while existingSlugs.contains("\(base)-\(n)") {
            n += 1
        }
        return "\(base)-\(n)"
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 9 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FileNamingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/FileNaming.swift MaughamTests/FileNamingTests.swift
git commit -m "feat: add FileNaming for NN-slug filename allocation"
```

---

## Task 6: Add `typography` field to ProjectManifest

**Files:**
- Modify: `Maugham/Models/ProjectManifest.swift`
- Modify: `MaughamTests/ProjectManifestTests.swift`

Adds an optional `typography: TypographySettings?` field to the manifest. Schema-compatible (older Maugham tolerates unknown fields per master spec).

- [ ] **Step 1: Add failing test**

In `MaughamTests/ProjectManifestTests.swift`, append a new test method to the existing class:

```swift
    func test_codable_roundTrips_withTypographyOverride() throws {
        let typography = TypographySettings(
            fontFamily: "New York",
            fontSize: 19,
            lineHeightMultiplier: 1.6,
            pageWidthCharacters: 80,
            paragraphSpacingMultiplier: 0.8,
            smartQuotes: false,
            emDashAutoReplace: false,
            ellipsisAutoReplace: false
        )
        let manifest = ProjectManifest(
            type: .novel,
            title: "Test",
            author: "",
            created: Date(),
            modified: Date(),
            structure: [],
            research: [],
            typography: typography
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(decoded.typography?.fontFamily, "New York")
        XCTAssertEqual(decoded.typography?.fontSize, 19)
    }

    func test_codable_omitsTypography_whenNil() throws {
        let manifest = ProjectManifest(
            type: .shortStory,
            title: "Test",
            author: "",
            created: Date(),
            modified: Date(),
            structure: [],
            research: [],
            typography: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let json = String(data: data, encoding: .utf8)!
        // Either typography key is absent OR present as null. Both acceptable.
        // The roundtrip is what matters.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectManifest.self, from: data)
        XCTAssertNil(decoded.typography)
        _ = json  // silence unused
    }
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectManifestTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error about extra argument `typography:` in ProjectManifest init.

- [ ] **Step 3: Add field to ProjectManifest**

Replace the entire `Maugham/Models/ProjectManifest.swift` body with:

```swift
import Foundation

/// The root of a `project.maugham.json` manifest file.
///
/// Schema is versioned via `schemaVersion`. Phase 1a was at version 1; 1d
/// adds an optional `typography` override field while keeping schema 1
/// (older Maugham tolerates unknown fields rather than corrupting them).
public struct ProjectManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var type: ProjectType
    public var title: String
    public var author: String
    public var created: Date
    public var modified: Date
    public var structure: [StructureItem]
    public var research: [ResearchItem]
    public var targets: ProjectTargets?

    /// Per-project typography override. When non-nil, takes precedence over
    /// the user-level UserPreferences.typography.
    public var typography: TypographySettings?

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        type: ProjectType,
        title: String,
        author: String,
        created: Date,
        modified: Date,
        structure: [StructureItem],
        research: [ResearchItem],
        targets: ProjectTargets? = nil,
        typography: TypographySettings? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.title = title
        self.author = author
        self.created = created
        self.modified = modified
        self.structure = structure
        self.research = research
        self.targets = targets
        self.typography = typography
    }
}
```

- [ ] **Step 4: Regenerate, run all manifest tests, expect passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectManifestTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/ProjectManifest.swift MaughamTests/ProjectManifestTests.swift
git commit -m "feat: add optional per-project typography to ProjectManifest"
```

---

## Task 7: ProjectStore.addStructureItem

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectStoreMutationTests.swift`

First of five mutation methods. Adds a new document or group beneath a parent (or at root). Performs filesystem op + manifest update + atomic save.

- [ ] **Step 1: Define ItemKind in ProjectStore.swift**

In `Maugham/Stores/ProjectStore.swift`, add this public enum at the top of the file (above the existing `ProjectStoreError`):

```swift
public enum StructureItemKind: Equatable, Sendable {
    case document(extension: String)  // "md" or "fountain"
    case group
}
```

Add a new error case to `ProjectStoreError`:
```swift
public enum ProjectStoreError: Error, Equatable {
    case manifestNotFound
    case manifestUnreadable(String)
    case manuscriptUnreadable(String)
    case manuscriptUnwritable(String)
    case manifestUnwritable(String)
    case structureMissing
    case parentNotFound(String)
    case fileSystemError(String)
}
```

- [ ] **Step 2: Write failing tests**

Create `MaughamTests/ProjectStoreMutationTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreMutationTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - addStructureItem

    func test_addDocument_atRoot_appendsAndCreatesFile() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let initialCount = store.manifest.structure.count

        let item = try await store.addStructureItem(
            parentId: nil,
            title: "Chapter 2",
            kind: .document(extension: "md"))

        XCTAssertEqual(store.manifest.structure.count, initialCount + 1)
        XCTAssertEqual(item.title, "Chapter 2")
        XCTAssertEqual(item.type, .document)
        let path = item.path ?? ""
        XCTAssertTrue(path.hasPrefix("manuscript/"))
        let fullURL = url.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path))
    }

    func test_addGroup_atRoot_createsFolder() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)

        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 0)
        let path = group.path ?? ""
        let fullURL = url.appendingPathComponent(path)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fullURL.path,
                                                      isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_addDocument_underGroup_nestsCorrectly() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)

        let scene = try await store.addStructureItem(
            parentId: group.id,
            title: "Opening Scene",
            kind: .document(extension: "md"))

        // Group's children should contain the new scene
        let updatedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })
        XCTAssertEqual(updatedGroup?.children?.count, 1)
        XCTAssertEqual(updatedGroup?.children?.first?.id, scene.id)

        // Scene's path should be under the group's folder
        let scenePath = scene.path ?? ""
        XCTAssertTrue(scenePath.contains("/01-act-one/"))
    }

    func test_addStructureItem_withInvalidParentId_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        do {
            _ = try await store.addStructureItem(
                parentId: "does-not-exist",
                title: "X",
                kind: .document(extension: "md"))
            XCTFail("expected throw")
        } catch ProjectStoreError.parentNotFound(let id) {
            XCTAssertEqual(id, "does-not-exist")
        }
    }

    func test_addStructureItem_persistsAcrossReload() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2",
            kind: .document(extension: "md"))

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertTrue(reloaded.manifest.structure
            .contains { $0.title == "Chapter 2" })
    }
}
```

- [ ] **Step 3: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `cannot find ... addStructureItem`.

- [ ] **Step 4: Implement addStructureItem in ProjectStore**

In `Maugham/Stores/ProjectStore.swift`, add the method to the class body. Before adding, also add an `id` generator helper.

Add inside the class, after the `manuscriptText` property:

```swift
    private static func newId(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }

    /// Add a new document or group beneath a parent (or at root if `parentId` is nil).
    /// Creates the file/folder on disk and saves the manifest atomically.
    public func addStructureItem(
        parentId: String?,
        title: String,
        kind: StructureItemKind
    ) async throws -> StructureItem {
        // 1. Resolve parent path for the new item
        let parentPath: String
        if let parentId {
            guard let parent = findItem(id: parentId, in: manifest.structure),
                  parent.type == .group else {
                throw ProjectStoreError.parentNotFound(parentId)
            }
            parentPath = parent.path ?? ""
        } else {
            parentPath = "manuscript"
        }

        // 2. Make sure the parent folder exists on disk
        let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentURL.path) {
            try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        // 3. Compute filename based on existing siblings
        let siblingNames = (try? fm.contentsOfDirectory(atPath: parentURL.path)) ?? []
        let filename: String
        switch kind {
        case .document(let ext):
            filename = FileNaming.nextDocumentFilename(
                title: title, extension: ext, siblingFilenames: siblingNames)
        case .group:
            filename = FileNaming.nextGroupFolderName(
                title: title, siblingFilenames: siblingNames)
        }
        let newURL = parentURL.appendingPathComponent(filename)
        let relativePath = "\(parentPath)/\(filename)"

        // 4. Create file or folder on disk
        do {
            switch kind {
            case .document:
                try Data().write(to: newURL)
            case .group:
                try fm.createDirectory(at: newURL, withIntermediateDirectories: false)
            }
        } catch {
            throw ProjectStoreError.fileSystemError(error.localizedDescription)
        }

        // 5. Build the new StructureItem
        let item = StructureItem(
            id: Self.newId(prefix: kind.idPrefix),
            title: title,
            type: kind.itemType,
            path: relativePath,
            children: kind.itemType == .group ? [] : nil)

        // 6. Mutate manifest: append to parent's children or to root structure
        if let parentId {
            mutateItem(id: parentId) { parent in
                var children = parent.children ?? []
                children.append(item)
                parent.children = children
            }
        } else {
            manifest.structure.append(item)
        }
        manifest.modified = Date()
        try await saveManifest()
        return item
    }

    // MARK: - tree helpers

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

    /// Mutate the item with the given id in place. The closure receives an
    /// inout reference and can change any field.
    private func mutateItem(
        id: String,
        transform: (inout StructureItem) -> Void
    ) {
        var newStructure = manifest.structure
        Self.applyMutation(id: id, in: &newStructure, transform: transform)
        manifest.structure = newStructure
    }

    private static func applyMutation(
        id: String,
        in items: inout [StructureItem],
        transform: (inout StructureItem) -> Void
    ) {
        for i in items.indices {
            if items[i].id == id {
                transform(&items[i])
                return
            }
            if items[i].children != nil {
                var children = items[i].children!
                applyMutation(id: id, in: &children, transform: transform)
                items[i].children = children
            }
        }
    }

    private func saveManifest() async throws {
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let tmpURL = manifestURL.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmpURL)
        } catch {
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }
    }
```

Also add this private extension at the bottom of the file (outside the class):

```swift
private extension StructureItemKind {
    var itemType: StructureItem.ItemType {
        switch self {
        case .document: return .document
        case .group: return .group
        }
    }

    var idPrefix: String {
        switch self {
        case .document(let ext) where ext == "fountain": return "scene"
        case .document: return "doc"
        case .group: return "grp"
        }
    }
}
```

- [ ] **Step 5: Regenerate, run, expect 5 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 6: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreMutationTests.swift
git commit -m "feat: ProjectStore.addStructureItem (document and group)"
```

---

## Task 8: ProjectStore.renameStructureItem

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Modify: `MaughamTests/ProjectStoreMutationTests.swift`

Renames an item: updates `title` in manifest, mv's the file/folder to the new slug while preserving the NN prefix.

- [ ] **Step 1: Append failing tests**

In `MaughamTests/ProjectStoreMutationTests.swift`, append before the closing `}` of the class:

```swift
    // MARK: - renameStructureItem

    func test_renameDocument_movesFileAndUpdatesManifest() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let item = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2",
            kind: .document(extension: "md"))
        let oldPath = item.path!
        let oldFullURL = url.appendingPathComponent(oldPath)

        try await store.renameStructureItem(id: item.id, newTitle: "The Funeral")

        // Manifest title updated
        let updated = store.manifest.structure
            .first(where: { $0.id == item.id })!
        XCTAssertEqual(updated.title, "The Funeral")

        // Path's slug updated, NN preserved
        let newPath = updated.path!
        XCTAssertTrue(newPath.contains("the-funeral"))
        XCTAssertTrue(newPath.hasPrefix("manuscript/02-"))

        // File at old path gone, new path exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFullURL.path))
        let newFullURL = url.appendingPathComponent(newPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFullURL.path))
    }

    func test_renameGroup_movesFolderAndKeepsChildren() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let scene = try await store.addStructureItem(
            parentId: group.id, title: "Opening",
            kind: .document(extension: "md"))

        try await store.renameStructureItem(id: group.id, newTitle: "Prologue")

        // Group folder moved
        let renamedGroup = store.manifest.structure
            .first(where: { $0.id == group.id })!
        XCTAssertEqual(renamedGroup.title, "Prologue")
        XCTAssertTrue(renamedGroup.path!.contains("prologue"))

        // Scene's path updated to follow group's new path
        let updatedScene = renamedGroup.children!
            .first(where: { $0.id == scene.id })!
        XCTAssertTrue(updatedScene.path!.contains("/02-prologue/"))

        // Scene file still exists at the new path
        let sceneURL = url.appendingPathComponent(updatedScene.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sceneURL.path))
    }

    func test_rename_withInvalidId_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mut", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        do {
            try await store.renameStructureItem(
                id: "nope", newTitle: "X")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {
            // ok
        }
    }
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement renameStructureItem**

Add to `ProjectStore` class:

```swift
    /// Rename an item: updates manifest title and moves the file or folder
    /// to a new slug while preserving the NN prefix. For groups, recursively
    /// updates child paths.
    public func renameStructureItem(
        id: String, newTitle: String
    ) async throws {
        guard let item = findItem(id: id, in: manifest.structure),
              let oldPath = item.path else {
            throw ProjectStoreError.structureMissing
        }

        // Compute new slug. NN prefix is preserved by extracting it from the old path.
        let oldFilename = (oldPath as NSString).lastPathComponent
        let nn = String(oldFilename.prefix(2))

        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let parentURL = url.appendingPathComponent(parentPath, isDirectory: true)

        let fm = FileManager.default
        let siblingNames = ((try? fm.contentsOfDirectory(atPath: parentURL.path)) ?? [])
            .filter { $0 != oldFilename }  // exclude self

        let newFilename: String
        switch item.type {
        case .document:
            let ext = (oldFilename as NSString).pathExtension
            // We need a base slug + extension; reuse FileNaming logic but
            // override NN to preserve the original.
            let baseSlug = Slugifier.slug(from: newTitle)
            let dedupedSlug = Self.dedupeSlug(
                base: baseSlug, ext: ext, isFolder: false,
                siblings: siblingNames)
            newFilename = "\(nn)-\(dedupedSlug).\(ext)"
        case .group:
            let baseSlug = Slugifier.slug(from: newTitle)
            let dedupedSlug = Self.dedupeSlug(
                base: baseSlug, ext: nil, isFolder: true,
                siblings: siblingNames)
            newFilename = "\(nn)-\(dedupedSlug)"
        }

        let newPath = parentPath.isEmpty ? newFilename : "\(parentPath)/\(newFilename)"
        let newURL = url.appendingPathComponent(newPath)

        // Move on disk
        do {
            try fm.moveItem(at: url.appendingPathComponent(oldPath), to: newURL)
        } catch {
            throw ProjectStoreError.fileSystemError(error.localizedDescription)
        }

        // Update manifest: title and path on the item, plus recursive child path
        // updates for groups (their relative locations within the group are
        // unchanged but the absolute prefix changes).
        mutateItem(id: id) { mutable in
            mutable.title = newTitle
            mutable.path = newPath
            if mutable.type == .group, var children = mutable.children {
                Self.rewriteChildPaths(
                    in: &children, oldPrefix: oldPath, newPrefix: newPath)
                mutable.children = children
            }
        }
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Static slug-deduper used by rename (since we already know NN).
    private static func dedupeSlug(
        base: String, ext: String?, isFolder: Bool, siblings: [String]
    ) -> String {
        let regex = try? NSRegularExpression(pattern: #"^\d{2}-(.+?)(\.[^.]+)?$"#)
        var existing = Set<String>()
        for name in siblings {
            let r = NSRange(name.startIndex..., in: name)
            guard let regex,
                  let m = regex.firstMatch(in: name, range: r),
                  let slugRange = Range(m.range(at: 1), in: name) else { continue }
            let extPart = m.range(at: 2).location != NSNotFound
                ? Range(m.range(at: 2), in: name).map { String(name[$0]) }
                : nil
            if isFolder {
                if extPart == nil { existing.insert(String(name[slugRange])) }
            } else if let ext, extPart == ".\(ext)" {
                existing.insert(String(name[slugRange]))
            }
        }
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Rewrites the path prefix of every child item recursively.
    private static func rewriteChildPaths(
        in children: inout [StructureItem],
        oldPrefix: String,
        newPrefix: String
    ) {
        for i in children.indices {
            if let p = children[i].path, p.hasPrefix(oldPrefix + "/") {
                children[i].path = newPrefix + p.dropFirst(oldPrefix.count)
            }
            if children[i].children != nil {
                var nested = children[i].children!
                rewriteChildPaths(in: &nested,
                                  oldPrefix: oldPrefix, newPrefix: newPrefix)
                children[i].children = nested
            }
        }
    }
```

- [ ] **Step 4: Regenerate, run, expect 8 mutation tests passing (5 add + 3 rename)**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreMutationTests.swift
git commit -m "feat: ProjectStore.renameStructureItem with path preservation"
```

---

## Task 9: ProjectStore.deleteStructureItem

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Modify: `MaughamTests/ProjectStoreMutationTests.swift`

Moves the file or folder to system trash via `NSWorkspace.recycle` and removes the manifest entry.

- [ ] **Step 1: Append failing tests**

In `MaughamTests/ProjectStoreMutationTests.swift`:

```swift
    // MARK: - deleteStructureItem

    func test_deleteDocument_recyclesFileAndRemovesEntry() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Del", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let item = try await store.addStructureItem(
            parentId: nil, title: "Doomed",
            kind: .document(extension: "md"))
        let path = item.path!
        let fullURL = url.appendingPathComponent(path)

        try await store.deleteStructureItem(id: item.id)

        // Manifest entry gone
        XCTAssertFalse(store.manifest.structure
            .contains { $0.id == item.id })
        // File no longer at original path (it's in Trash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fullURL.path))
    }

    func test_deleteGroup_recyclesFolderRecursively() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Del", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Doomed Act", kind: .group)
        _ = try await store.addStructureItem(
            parentId: group.id, title: "Inside",
            kind: .document(extension: "md"))

        try await store.deleteStructureItem(id: group.id)

        XCTAssertFalse(store.manifest.structure
            .contains { $0.id == group.id })
        let groupURL = url.appendingPathComponent(group.path!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupURL.path))
    }

    func test_delete_withInvalidId_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Del", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        do {
            try await store.deleteStructureItem(id: "nope")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {
            // ok
        }
    }
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement deleteStructureItem**

Add to `ProjectStore` class:

```swift
    /// Move the item's file or folder to the system Trash and remove its
    /// manifest entry. For groups, the entire folder (including all children)
    /// is recycled in one atomic system call.
    public func deleteStructureItem(id: String) async throws {
        guard let item = findItem(id: id, in: manifest.structure),
              let path = item.path else {
            throw ProjectStoreError.structureMissing
        }

        let fullURL = url.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: fullURL.path) {
            do {
                try await NSWorkspace.shared.recycle([fullURL])
            } catch {
                throw ProjectStoreError.fileSystemError(error.localizedDescription)
            }
        }

        removeFromStructure(id: id)
        manifest.modified = Date()
        try await saveManifest()
    }

    private func removeFromStructure(id: String) {
        var newStructure = manifest.structure
        Self.applyRemoval(id: id, in: &newStructure)
        manifest.structure = newStructure
    }

    private static func applyRemoval(
        id: String, in items: inout [StructureItem]
    ) {
        items.removeAll(where: { $0.id == id })
        for i in items.indices where items[i].children != nil {
            var children = items[i].children!
            applyRemoval(id: id, in: &children)
            items[i].children = children
        }
    }
```

The async-await + `NSWorkspace.recycle` API: `NSWorkspace.shared.recycle(_:completionHandler:)` is the AppKit signature. Wrap in `withCheckedThrowingContinuation` since it's a callback API:

Actually, replace the `try await NSWorkspace.shared.recycle([fullURL])` line with this helper-based version. Add this helper to the class:

```swift
    private func recycleURLs(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
```

Then in `deleteStructureItem`, replace the `try await NSWorkspace.shared.recycle([fullURL])` line with:
```swift
                try await recycleURLs([fullURL])
```

You'll also need `import AppKit` at the top of `Maugham/Stores/ProjectStore.swift` (it currently only imports `Foundation` and `SwiftUI`).

- [ ] **Step 4: Regenerate, run, expect 11 mutation tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreMutationTests.swift
git commit -m "feat: ProjectStore.deleteStructureItem (recycle to Trash)"
```

---

## Task 10: ProjectStore.updateInspector

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Modify: `MaughamTests/ProjectStoreMutationTests.swift`

Updates `synopsis` and/or `status` fields on a structure item. No filesystem ops.

- [ ] **Step 1: Append failing tests**

In `MaughamTests/ProjectStoreMutationTests.swift`:

```swift
    // MARK: - updateInspector

    func test_updateInspector_setsSynopsisAndStatus() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Insp", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let rootItem = store.manifest.structure[0]

        try await store.updateInspector(
            id: rootItem.id,
            synopsis: "Larry returns from the war.",
            status: "revising")

        let updated = store.manifest.structure[0]
        XCTAssertEqual(updated.synopsis, "Larry returns from the war.")
        XCTAssertEqual(updated.status, "revising")
    }

    func test_updateInspector_partial_keepsOtherField() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Insp", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let rootId = store.manifest.structure[0].id
        try await store.updateInspector(
            id: rootId, synopsis: "First", status: "draft")
        try await store.updateInspector(
            id: rootId, synopsis: nil, status: "final")

        let updated = store.manifest.structure[0]
        // synopsis: nil means "leave unchanged"
        XCTAssertEqual(updated.synopsis, "First")
        XCTAssertEqual(updated.status, "final")
    }

    func test_updateInspector_invalidId_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Insp", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        do {
            try await store.updateInspector(
                id: "nope", synopsis: "x", status: "x")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {}
    }
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

Add to `ProjectStore`:

```swift
    /// Update an item's inspector fields. `nil` arguments mean "leave unchanged";
    /// to explicitly clear a field, pass an empty string.
    public func updateInspector(
        id: String,
        synopsis: String?,
        status: String?
    ) async throws {
        guard findItem(id: id, in: manifest.structure) != nil else {
            throw ProjectStoreError.structureMissing
        }
        mutateItem(id: id) { item in
            if let synopsis { item.synopsis = synopsis }
            if let status { item.status = status }
        }
        manifest.modified = Date()
        try await saveManifest()
    }
```

- [ ] **Step 4: Regenerate, run, expect 14 mutation tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreMutationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreMutationTests.swift
git commit -m "feat: ProjectStore.updateInspector (synopsis + status)"
```

---

## Task 11: ProjectStore.setProjectTypography + effectiveTypography

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectStoreTypographyTests.swift`

Per-project typography override. Plus a static `effectiveTypography(override:userDefault:)` helper for the resolution logic.

- [ ] **Step 1: Write failing tests**

`MaughamTests/ProjectStoreTypographyTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreTypographyTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_setOverride_persistsInManifest() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Typo", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        var custom = TypographySettings.defaults
        custom.fontSize = 22
        try await store.setProjectTypography(custom)

        XCTAssertEqual(store.manifest.typography?.fontSize, 22)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.typography?.fontSize, 22)
    }

    func test_setOverride_nil_clearsManifestField() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Typo", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        var custom = TypographySettings.defaults
        custom.fontSize = 22
        try await store.setProjectTypography(custom)

        try await store.setProjectTypography(nil)
        XCTAssertNil(store.manifest.typography)
    }

    func test_effectiveTypography_returnsOverrideWhenSet() {
        var override = TypographySettings.defaults
        override.fontSize = 24
        let result = ProjectStore.effectiveTypography(
            override: override, userDefault: .defaults)
        XCTAssertEqual(result.fontSize, 24)
    }

    func test_effectiveTypography_fallsBackToUserDefault() {
        var userDefault = TypographySettings.defaults
        userDefault.fontSize = 19
        let result = ProjectStore.effectiveTypography(
            override: nil, userDefault: userDefault)
        XCTAssertEqual(result.fontSize, 19)
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreTypographyTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

In `Maugham/Stores/ProjectStore.swift`, add:

```swift
    /// Set or clear the per-project typography override.
    /// Pass `nil` to clear (fall back to user-level defaults).
    public func setProjectTypography(_ override: TypographySettings?) async throws {
        manifest.typography = override
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Resolve the effective typography for an editor: prefer the
    /// project-level override, otherwise fall back to the user default.
    public static func effectiveTypography(
        override: TypographySettings?,
        userDefault: TypographySettings
    ) -> TypographySettings {
        override ?? userDefault
    }
```

- [ ] **Step 4: Regenerate, run, expect 4 typography tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectStoreTypographyTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore.swift MaughamTests/ProjectStoreTypographyTests.swift
git commit -m "feat: ProjectStore per-project typography override + effective resolution"
```

---

## Task 12: ProjectFactory — Novel/Screenplay/Collection skeletons

**Files:**
- Modify: `Maugham/Stores/ProjectFactory.swift`
- Modify: `MaughamTests/ProjectFactoryTests.swift`

Add three creation methods. Novel/Screenplay each get a single starter document; Collection gets an empty manifest.

- [ ] **Step 1: Append failing tests**

In `MaughamTests/ProjectFactoryTests.swift`, append these tests inside the existing test class:

```swift
    func test_createNovel_seedsManifestAndChapter1() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "Razor", in: temp.url)

        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.type, .novel)
        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].title, "Chapter 1")
        XCTAssertEqual(manifest.structure[0].type, .document)

        let chapterURL = url.appendingPathComponent(manifest.structure[0].path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chapterURL.path))
    }

    func test_createScreenplay_seedsManifestAndScene1Fountain() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "TheTrip", in: temp.url)

        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.type, .screenplay)
        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].title, "Scene 1")
        XCTAssertTrue(manifest.structure[0].path?.hasSuffix(".fountain") ?? false)

        let sceneURL = url.appendingPathComponent(manifest.structure[0].path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sceneURL.path))
    }

    func test_createCollection_seedsEmptyManifest() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createCollectionProject(
            named: "MyShorts", in: temp.url)

        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.type, .collection)
        XCTAssertTrue(manifest.structure.isEmpty)

        // Collection has research and notes folders but no manuscript
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("notes").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manuscript").path))
    }
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectFactoryTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement the three new factories**

In `Maugham/Stores/ProjectFactory.swift`, append three new public static methods:

```swift
    /// Creates a Novel project at `parent/<name>` with one Chapter 1 document.
    public static func createNovelProject(
        named rawName: String,
        in parent: URL
    ) async throws -> URL {
        try await createProject(
            named: rawName,
            in: parent,
            type: .novel,
            initialDocumentTitle: "Chapter 1",
            initialDocumentExtension: "md")
    }

    /// Creates a Screenplay project at `parent/<name>` with one Scene 1.fountain.
    public static func createScreenplayProject(
        named rawName: String,
        in parent: URL
    ) async throws -> URL {
        try await createProject(
            named: rawName,
            in: parent,
            type: .screenplay,
            initialDocumentTitle: "Scene 1",
            initialDocumentExtension: "fountain")
    }

    /// Creates a Collection project at `parent/<name>` with an empty manifest.
    public static func createCollectionProject(
        named rawName: String,
        in parent: URL
    ) async throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFactoryError.invalidName }

        let fm = FileManager.default
        let projectURL = parent.appendingPathComponent(name, isDirectory: true)

        if fm.fileExists(atPath: projectURL.path) {
            throw ProjectFactoryError.projectAlreadyExists(projectURL)
        }

        do {
            try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("research"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("notes"),
                                   withIntermediateDirectories: true)

            let now = Date()
            let manifest = ProjectManifest(
                type: .collection,
                title: name, author: "",
                created: now, modified: now,
                structure: [], research: [])
            try writeManifest(manifest, to: projectURL)
        } catch let e as ProjectFactoryError {
            try? fm.removeItem(at: projectURL)
            throw e
        } catch {
            try? fm.removeItem(at: projectURL)
            throw ProjectFactoryError.ioError(error.localizedDescription)
        }

        return projectURL
    }

    // MARK: - Shared helpers

    /// Shared logic for Novel + Screenplay (and could be reused for any
    /// "single-starter-document" project type). Creates manuscript/, research/,
    /// notes/ and a single document with NN-slug naming.
    private static func createProject(
        named rawName: String,
        in parent: URL,
        type: ProjectType,
        initialDocumentTitle: String,
        initialDocumentExtension: String
    ) async throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFactoryError.invalidName }

        let fm = FileManager.default
        let projectURL = parent.appendingPathComponent(name, isDirectory: true)

        if fm.fileExists(atPath: projectURL.path) {
            throw ProjectFactoryError.projectAlreadyExists(projectURL)
        }

        do {
            try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("manuscript"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("research"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("notes"),
                                   withIntermediateDirectories: true)

            let filename = FileNaming.nextDocumentFilename(
                title: initialDocumentTitle,
                extension: initialDocumentExtension,
                siblingFilenames: [])
            let docURL = projectURL.appendingPathComponent("manuscript/\(filename)")
            try Data().write(to: docURL)

            let now = Date()
            let item = StructureItem(
                id: "doc-\(UUID().uuidString.prefix(8).lowercased())",
                title: initialDocumentTitle,
                type: .document,
                path: "manuscript/\(filename)",
                status: "draft")
            let manifest = ProjectManifest(
                type: type,
                title: name, author: "",
                created: now, modified: now,
                structure: [item], research: [])
            try writeManifest(manifest, to: projectURL)
        } catch let e as ProjectFactoryError {
            try? fm.removeItem(at: projectURL)
            throw e
        } catch {
            try? fm.removeItem(at: projectURL)
            throw ProjectFactoryError.ioError(error.localizedDescription)
        }

        return projectURL
    }

    /// Atomic manifest write helper.
    private static func writeManifest(
        _ manifest: ProjectManifest, to projectURL: URL
    ) throws {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }
```

- [ ] **Step 4: Regenerate, run all factory tests, expect passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectFactoryTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectFactory.swift MaughamTests/ProjectFactoryTests.swift
git commit -m "feat: ProjectFactory creates Novel, Screenplay, Collection projects"
```

---

## Task 13: TypographySettings.screenplayDefaults

**Files:**
- Modify: `Maugham/Preferences/TypographySettings.swift`
- Modify: `MaughamTests/TypographySettingsTests.swift`

Adds a screenplay-tuned default and a curated list of monospace fonts.

- [ ] **Step 1: Append failing tests**

In `MaughamTests/TypographySettingsTests.swift`:

```swift
    func test_screenplayDefaults_areMonospaceWith60ColWidth() {
        let s = TypographySettings.screenplayDefaults
        XCTAssertEqual(s.fontFamily, "JetBrains Mono")
        XCTAssertEqual(s.fontSize, 13)
        XCTAssertEqual(s.pageWidthCharacters, 60)
        XCTAssertFalse(s.smartQuotes)
        XCTAssertFalse(s.emDashAutoReplace)
        XCTAssertFalse(s.ellipsisAutoReplace)
    }

    func test_curatedScreenplayFonts_includesMonospace() {
        let names = TypographySettings.curatedScreenplayFonts.map(\.fontName)
        XCTAssertTrue(names.contains("JetBrains Mono"))
        XCTAssertTrue(names.contains("Menlo"))
    }
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TypographySettingsTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Append the new defaults**

In `Maugham/Preferences/TypographySettings.swift`, append these inside `public struct TypographySettings` before the closing `}`:

```swift
    public static let screenplayDefaults = TypographySettings(
        fontFamily: "JetBrains Mono",
        fontSize: 13,
        lineHeightMultiplier: 1.5,
        pageWidthCharacters: 60,
        paragraphSpacingMultiplier: 0.6,
        smartQuotes: false,
        emDashAutoReplace: false,
        ellipsisAutoReplace: false
    )

    public static let curatedScreenplayFonts: [CuratedFont] = [
        CuratedFont(displayName: "JetBrains Mono", fontName: "JetBrains Mono"),
        CuratedFont(displayName: "Menlo", fontName: "Menlo"),
        CuratedFont(displayName: "SF Mono", fontName: "SF Mono"),
    ]
```

- [ ] **Step 4: Regenerate, run, expect tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TypographySettingsTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Preferences/TypographySettings.swift MaughamTests/TypographySettingsTests.swift
git commit -m "feat: add TypographySettings.screenplayDefaults and curated mono fonts"
```

---

## Task 14: ScreenplayMode

**Files:**
- Create: `Maugham/Editor/ScreenplayMode.swift`
- Create: `MaughamTests/ScreenplayModeTests.swift`

Plain monospace WritingMode for `.fountain` files. No Fountain parser in 1d (Phase 3).

- [ ] **Step 1: Write failing tests**

`MaughamTests/ScreenplayModeTests.swift`:
```swift
import XCTest
import AppKit
@testable import Maugham

final class ScreenplayModeTests: XCTestCase {
    private let mode = ScreenplayMode()

    func test_tokenize_emptyText_returnsEmpty() {
        XCTAssertEqual(mode.tokenize(""), [])
    }

    func test_tokenize_returnsSinglePlainToken() {
        let text = "FADE IN:\n\nINT. ROOM - DAY\n\nLarry sits."
        let tokens = mode.tokenize(text)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .plain)
        XCTAssertEqual(tokens[0].range.length, (text as NSString).length)
    }

    func test_smartTypographyTransform_alwaysReturnsNil() {
        XCTAssertNil(mode.smartTypographyTransform(
            currentText: "ah-",
            replacementRange: NSRange(location: 3, length: 0),
            replacement: "-",
            settings: .defaults))
    }

    func test_metrics_countsWordsLikeProse() {
        let metrics = mode.metrics("hello world this is text")
        XCTAssertEqual(metrics.wordCount, 5)
        XCTAssertEqual(metrics.characterCount, 24)
    }

    func test_applyTypography_setsMonospaceFont() {
        let storage = NSTextStorage(string: "FADE IN:")
        let tokens = [Token(range: NSRange(location: 0, length: 8), kind: .plain)]
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.foregroundColor])
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

`Maugham/Editor/ScreenplayMode.swift`:
```swift
import Foundation
import AppKit

/// Plain monospace mode for .fountain files. No Fountain parser in 1d
/// (Phase 3 will add tokenizer, auto-format, Tab/Enter cycling, etc.).
public struct ScreenplayMode: WritingMode {
    private static let wordsPerMinute = 200

    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        return [Token(
            range: NSRange(location: 0, length: (text as NSString).length),
            kind: .plain)]
    }

    public func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        nil  // Screenplays are ASCII; never auto-curlify or em-dash.
    }

    public func metrics(_ text: String) -> EditorMetrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty
            ? 0
            : trimmed.split(whereSeparator: \.isWhitespace).count
        let chars = (text as NSString).length
        let mins = words / Self.wordsPerMinute
        return EditorMetrics(
            wordCount: words, characterCount: chars, readingMinutes: mins)
    }

    public func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    ) {
        let resolved = theme.resolved(systemAppearanceIsDark: false)
        let palette = resolved.palette
        let font = baseFont(for: typography)
        let attrs = bodyAttributes(palette: palette, baseFont: font,
                                   typography: typography)
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(attrs, range: fullRange)
        storage.endEditing()
    }

    public func bodyTypingAttributes(
        theme: Theme,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let resolved = theme.resolved(systemAppearanceIsDark: false)
        return bodyAttributes(palette: resolved.palette,
                              baseFont: baseFont(for: typography),
                              typography: typography)
    }

    public func textColumnWidth(typography: TypographySettings) -> CGFloat {
        let font = baseFont(for: typography)
        let sample = "the quick brown fox jumps over the lazy dog"
        let sampleWidth = (sample as NSString)
            .size(withAttributes: [.font: font]).width
        let avgCharWidth = sampleWidth / CGFloat(sample.count)
        return avgCharWidth * CGFloat(typography.pageWidthCharacters)
    }

    private func baseFont(for typography: TypographySettings) -> NSFont {
        if let font = NSFont(name: typography.fontFamily,
                             size: CGFloat(typography.fontSize)) {
            return font
        }
        return NSFont.monospacedSystemFont(
            ofSize: CGFloat(typography.fontSize), weight: .regular)
    }

    private func bodyAttributes(
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing =
            max(0, baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))
        paragraph.paragraphSpacing =
            baseFont.pointSize * CGFloat(typography.paragraphSpacingMultiplier)
        return [
            .font: baseFont,
            .foregroundColor: palette.bodyText,
            .paragraphStyle: paragraph,
        ]
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 5 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/ScreenplayModeTests.swift
git commit -m "feat: add ScreenplayMode (monospace, no parser yet)"
```

---

## Task 15: WritingModeFactory

**Files:**
- Create: `Maugham/Editor/WritingModeFactory.swift`
- Create: `MaughamTests/WritingModeFactoryTests.swift`

Picks the right `WritingMode` for a given file path based on extension.

- [ ] **Step 1: Write failing tests**

`MaughamTests/WritingModeFactoryTests.swift`:
```swift
import XCTest
@testable import Maugham

final class WritingModeFactoryTests: XCTestCase {

    func test_mdFile_returnsProseMode() {
        let mode = WritingModeFactory.mode(for: "manuscript/01-chapter-1.md")
        XCTAssertTrue(mode is ProseMode)
    }

    func test_fountainFile_returnsScreenplayMode() {
        let mode = WritingModeFactory.mode(for: "manuscript/01-scene-1.fountain")
        XCTAssertTrue(mode is ScreenplayMode)
    }

    func test_unknownExtension_defaultsToProseMode() {
        let mode = WritingModeFactory.mode(for: "manuscript/notes.txt")
        XCTAssertTrue(mode is ProseMode)
    }

    func test_typographyFor_mdFile_usesProseDefaults() {
        let typography = WritingModeFactory.defaultTypography(
            for: "manuscript/01-chapter-1.md")
        XCTAssertEqual(typography.fontFamily, "Iowan Old Style")
    }

    func test_typographyFor_fountainFile_usesScreenplayDefaults() {
        let typography = WritingModeFactory.defaultTypography(
            for: "manuscript/01-scene-1.fountain")
        XCTAssertEqual(typography.fontFamily, "JetBrains Mono")
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/WritingModeFactoryTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

`Maugham/Editor/WritingModeFactory.swift`:
```swift
import Foundation

/// Selects the appropriate WritingMode and default TypographySettings
/// for a given document path based on its file extension.
public enum WritingModeFactory {

    public static func mode(for path: String) -> any WritingMode {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "fountain": return ScreenplayMode()
        default:         return ProseMode()
        }
    }

    public static func defaultTypography(for path: String) -> TypographySettings {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "fountain": return .screenplayDefaults
        default:         return .defaults
        }
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 5 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/WritingModeFactoryTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/WritingModeFactory.swift MaughamTests/WritingModeFactoryTests.swift
git commit -m "feat: add WritingModeFactory for path-based mode selection"
```

---

## Task 16: EditorHost

**Files:**
- Create: `Maugham/Views/EditorHost.swift`

SwiftUI view that binds the EditorSurface to the currently-selected document. Picks WritingMode by extension. Reads project text from disk on demand and writes it back on edit.

- [ ] **Step 1: Implement EditorHost**

`Maugham/Views/EditorHost.swift`:
```swift
import SwiftUI
import Foundation

/// Hosts the EditorSurface for a single selected document.
/// Picks the WritingMode by file extension. Reads the file on appear and
/// writes back on edit. When `selectedItemId` is nil, shows a placeholder.
struct EditorHost: View {
    @Bindable var store: ProjectStore
    let selectedItemId: String?
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedItemId: String?

    var body: some View {
        Group {
            if let item = currentItem, item.type == .document, let path = item.path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            saveDocument(path: path, text: newValue)
                        }
                    ),
                    theme: userPreferences.theme,
                    typography: ProjectStore.effectiveTypography(
                        override: store.manifest.typography,
                        userDefault: userPreferences.typography),
                    mode: WritingModeFactory.mode(for: path),
                    typewriterScroll: userPreferences.typewriterScroll,
                    sentenceFocus: userPreferences.sentenceFocus,
                    paragraphFocus: userPreferences.paragraphFocus
                )
                .id(path)  // Force re-creation when switching documents
            } else if currentItem?.type == .group {
                placeholder("Select a document inside this group to edit.")
            } else {
                placeholder("Select a document.")
            }
        }
        .onChange(of: selectedItemId) { _, _ in loadDocumentIfNeeded() }
        .task { loadDocumentIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return findItem(id: id, in: store.manifest.structure)
    }

    private func loadDocumentIfNeeded() {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              loadedItemId != item.id else { return }
        let url = store.url.appendingPathComponent(path)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            documentText = text
        } else {
            documentText = ""
        }
        loadedItemId = item.id
    }

    private func saveDocument(path: String, text: String) {
        let url = store.url.appendingPathComponent(path)
        try? text.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. (EditorHost isn't used yet; it'll be wired in Task 22.)

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/EditorHost.swift
git commit -m "feat: add EditorHost binding editor to selected document"
```

---

## Task 17: BinderRow

**Files:**
- Create: `Maugham/Views/BinderRow.swift`

A single row in the binder: status dot, title (with inline rename support), expand/collapse chevron for groups.

- [ ] **Step 1: Implement BinderRow**

`Maugham/Views/BinderRow.swift`:
```swift
import SwiftUI

struct BinderRow: View {
    let item: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void  // (id, newTitle)

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

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/BinderRow.swift
git commit -m "feat: add BinderRow with status dot and inline rename"
```

---

## Task 18: BinderView with hierarchical rendering

**Files:**
- Create: `Maugham/Views/BinderView.swift`

The recursive list of structure items with selection, expand/collapse, and right-click context menu wiring.

- [ ] **Step 1: Implement BinderView**

`Maugham/Views/BinderView.swift`:
```swift
import SwiftUI

struct BinderView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    @State private var renamingItemId: String?
    @State private var pendingError: String?

    var body: some View {
        List(selection: $selectedItemId) {
            outline(items: store.manifest.structure)
        }
        .listStyle(.sidebar)
        .alert("Couldn't update project",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } }
               )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
    }

    @ViewBuilder
    private func outline(items: [StructureItem]) -> some View {
        ForEach(items) { item in
            if item.type == .group, let children = item.children {
                DisclosureGroup {
                    outline(items: children)
                } label: {
                    row(for: item)
                }
                .tag(item.id)
            } else {
                row(for: item)
                    .tag(item.id)
            }
        }
    }

    private func row(for item: StructureItem) -> some View {
        BinderRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
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
            Button("Rename") { renamingItemId = item.id }
            Button("Delete", role: .destructive) {
                Task { await deleteItem(id: item.id) }
            }
        }
    }

    // MARK: - Actions

    private func addItem(parent: StructureItem, kind: StructureItemKind) async {
        let parentId: String? = parent.type == .group ? parent.id : findParentId(of: parent.id)
        let title: String
        switch kind {
        case .document: title = "New Document"
        case .group:    title = "New Group"
        }
        do {
            let item = try await store.addStructureItem(
                parentId: parentId, title: title, kind: kind)
            renamingItemId = item.id  // immediately go to rename mode
            selectedItemId = item.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func rename(id: String, to newTitle: String) async {
        do {
            try await store.renameStructureItem(id: id, newTitle: newTitle)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func deleteItem(id: String) async {
        do {
            try await store.deleteStructureItem(id: id)
            if selectedItemId == id { selectedItemId = nil }
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Find the parent id of an item by id, or nil if at root.
    private func findParentId(of childId: String) -> String? {
        Self.findParent(childId: childId, in: store.manifest.structure, parent: nil)
    }

    private static func findParent(
        childId: String, in items: [StructureItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children {
                if let found = findParent(
                    childId: childId, in: children, parent: item.id) {
                    return found
                }
            }
        }
        return nil
    }
}
```

Note: SwiftUI's `List(selection:)` paired with `DisclosureGroup`+`ForEach` produces a sidebar list with expand/collapse and selection. The right-click context menu on each row gives the user New Document / New Group / Rename / Delete. New items immediately switch to rename mode so the user can type a real name.

The "right-click on empty area" case from the spec — for the very first item at the root with an empty manifest (Collection projects, or after deleting everything) — is reachable via the context menu on a placeholder. Add this enhancement in Task 22 when wiring the binder into ProjectWindow; for now the binder works for non-empty structure.

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/BinderView.swift
git commit -m "feat: BinderView with hierarchical list, selection, and right-click menu"
```

---

## Task 19: InspectorView

**Files:**
- Create: `Maugham/Views/InspectorView.swift`

Synopsis (debounced), status picker, live word count.

- [ ] **Step 1: Implement InspectorView**

`Maugham/Views/InspectorView.swift`:
```swift
import SwiftUI

struct InspectorView: View {
    @Bindable var store: ProjectStore
    let selectedItemId: String?
    let metrics: EditorMetrics
    let onOpenProjectSettings: () -> Void

    @State private var draftSynopsis: String = ""
    @State private var draftStatus: String = "draft"
    @State private var loadedItemId: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            if let item = currentItem, item.type == .document {
                Section("Document") {
                    LabeledContent("Title", value: item.title)
                    Picker("Status", selection: $draftStatus) {
                        Text("Draft").tag("draft")
                        Text("Revising").tag("revising")
                        Text("Final").tag("final")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: draftStatus) { _, _ in scheduleSave() }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Synopsis")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draftSynopsis)
                            .frame(minHeight: 80)
                            .onChange(of: draftSynopsis) { _, _ in scheduleSave() }
                    }

                    LabeledContent("Words") {
                        Text(wordsLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let item = currentItem {
                Section("Group") {
                    LabeledContent("Title", value: item.title)
                    Text("Select a document inside this group to view document fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Project") {
                Button("Project Settings…", action: onOpenProjectSettings)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 240, idealWidth: 280)
        .onChange(of: selectedItemId) { _, _ in loadDraftIfNeeded() }
        .task { loadDraftIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return findItem(id: id, in: store.manifest.structure)
    }

    private var wordsLabel: String {
        let w = metrics.wordCount.formatted(.number)
        return metrics.readingMinutes == 0
            ? "\(w) words"
            : "\(w) words · \(metrics.readingMinutes) min read"
    }

    private func loadDraftIfNeeded() {
        guard let item = currentItem,
              loadedItemId != item.id else { return }
        draftSynopsis = item.synopsis ?? ""
        draftStatus = item.status ?? "draft"
        loadedItemId = item.id
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let id = loadedItemId
        let synopsis = draftSynopsis
        let status = draftStatus
        saveTask = Task { [weak store] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard let store, let id else { return }
            try? await store.updateInspector(
                id: id, synopsis: synopsis, status: status)
        }
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/InspectorView.swift
git commit -m "feat: InspectorView with debounced synopsis + status + word count"
```

---

## Task 20: ProjectSettingsSheet

**Files:**
- Create: `Maugham/Views/ProjectSettingsSheet.swift`

Modal sheet bound to `manifest.typography`. Toggle for "Use my defaults" vs "Customize for this project". When customising, the same controls as the global Editor settings tab appear, bound to the project's manifest typography.

- [ ] **Step 1: Implement**

`Maugham/Views/ProjectSettingsSheet.swift`:
```swift
import SwiftUI

struct ProjectSettingsSheet: View {
    @Bindable var store: ProjectStore
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var useDefaults: Bool = true
    @State private var draft: TypographySettings = .defaults

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text(store.manifest.title)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                Section("Typography") {
                    Picker("Source", selection: $useDefaults) {
                        Text("Use my defaults").tag(true)
                        Text("Customize for this project").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: useDefaults) { _, newValue in
                        Task { await applyDefaultsToggle(newValue) }
                    }

                    if !useDefaults {
                        Picker("Font", selection: Binding(
                            get: { draft.fontFamily },
                            set: { draft.fontFamily = $0; saveDraft() })) {
                            ForEach(curatedFonts(), id: \.fontName) { font in
                                Text(font.displayName).tag(font.fontName)
                            }
                        }
                        .pickerStyle(.menu)

                        Stepper("Size: \(draft.fontSize) pt",
                                value: Binding(get: { draft.fontSize },
                                               set: { draft.fontSize = $0; saveDraft() }),
                                in: 12...24)

                        VStack(alignment: .leading) {
                            Text("Line height: \(String(format: "%.2f", draft.lineHeightMultiplier))")
                            Slider(value: Binding(get: { draft.lineHeightMultiplier },
                                                  set: { draft.lineHeightMultiplier = $0; saveDraft() }),
                                   in: 1.4...2.0, step: 0.05)
                        }

                        Stepper("Page width: \(draft.pageWidthCharacters) chars",
                                value: Binding(get: { draft.pageWidthCharacters },
                                               set: { draft.pageWidthCharacters = $0; saveDraft() }),
                                in: 60...90)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 360)
        .task { initializeDraft() }
    }

    private func curatedFonts() -> [TypographySettings.CuratedFont] {
        store.manifest.type == .screenplay
            ? TypographySettings.curatedScreenplayFonts
            : TypographySettings.curatedFonts
    }

    private func initializeDraft() {
        if let override = store.manifest.typography {
            useDefaults = false
            draft = override
        } else {
            useDefaults = true
            draft = userPreferences.typography
        }
    }

    private func applyDefaultsToggle(_ usingDefaults: Bool) async {
        if usingDefaults {
            try? await store.setProjectTypography(nil)
        } else {
            // Seed the override with the user-default snapshot
            draft = userPreferences.typography
            try? await store.setProjectTypography(draft)
        }
    }

    private func saveDraft() {
        guard !useDefaults else { return }
        let d = draft
        Task { try? await store.setProjectTypography(d) }
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/ProjectSettingsSheet.swift
git commit -m "feat: ProjectSettingsSheet for per-project typography overrides"
```

---

## Task 21: HelpClaudeDesktopSheet

**Files:**
- Create: `Maugham/Views/HelpClaudeDesktopSheet.swift`

Modal sheet showing Claude Desktop MCP config snippet pre-filled with the current project path; copy-to-clipboard button.

- [ ] **Step 1: Implement**

`Maugham/Views/HelpClaudeDesktopSheet.swift`:
```swift
import SwiftUI
import AppKit

struct HelpClaudeDesktopSheet: View {
    let projectURL: URL?
    let projectTitle: String?
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Claude Desktop")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Claude Desktop can read your Maugham project folder via its built-in filesystem MCP server. Add the snippet below to Claude Desktop's `claude_desktop_config.json` and restart Claude Desktop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Config snippet:")
                    .font(.callout)
                    .fontWeight(.medium)
                ScrollView {
                    Text(snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                HStack {
                    Button(copied ? "Copied" : "Copy snippet") {
                        copySnippet()
                    }
                    Spacer()
                    Text("Config file: ~/Library/Application Support/Claude/claude_desktop_config.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 420)
    }

    private var snippet: String {
        let path = projectURL?.path ?? "<your-project-path>"
        let key = projectTitle.flatMap { Slugifier.slug(from: $0) } ?? "your-project"
        return """
        {
          "mcpServers": {
            "maugham-\(key)": {
              "command": "npx",
              "args": [
                "-y",
                "@modelcontextprotocol/server-filesystem",
                "\(path)"
              ]
            }
          }
        }
        """
    }

    private func copySnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/HelpClaudeDesktopSheet.swift
git commit -m "feat: HelpClaudeDesktopSheet with copyable per-project MCP config"
```

---

## Task 22: NewProjectSheet — enable all four project types

**Files:**
- Modify: `Maugham/Views/NewProjectSheet.swift`

The 1a sheet had Novel/Screenplay/Collection disabled with "Coming in milestone 1d" captions. 1d enables all four and dispatches to the matching factory.

- [ ] **Step 1: Read existing NewProjectSheet to understand its shape**

```bash
cat Maugham/Views/NewProjectSheet.swift
```

The existing sheet has: a TextField for name, a Picker for project type with all four types listed but only Short Story enabled, a "Create" button that calls `ProjectFactory.createShortStoryProject(...)`.

- [ ] **Step 2: Replace the "Create" handler to dispatch by type**

Locate the body of the Create button handler in `Maugham/Views/NewProjectSheet.swift`. It looks something like:

```swift
let url = try await ProjectFactory.createShortStoryProject(
    named: trimmedName, in: parentURL)
```

Replace the entire block with a switch on `selectedType`:

```swift
let url: URL
switch selectedType {
case .shortStory:
    url = try await ProjectFactory.createShortStoryProject(
        named: trimmedName, in: parentURL)
case .novel:
    url = try await ProjectFactory.createNovelProject(
        named: trimmedName, in: parentURL)
case .screenplay:
    url = try await ProjectFactory.createScreenplayProject(
        named: trimmedName, in: parentURL)
case .collection:
    url = try await ProjectFactory.createCollectionProject(
        named: trimmedName, in: parentURL)
}
```

- [ ] **Step 3: Remove the disabled state and the "Coming in milestone 1d" caption**

In the same file, find any code that disables non-Short-Story types in the Picker and any text saying "Available in milestone 1d" or "Coming in milestone 1d" — remove those. The picker should show all four types as enabled.

The exact lines depend on how 1a wrote the sheet; search:
```bash
grep -n "milestone 1d\|Available in\|Coming in" Maugham/Views/NewProjectSheet.swift
```
Remove all matches, preserving surrounding code.

If the sheet has a Picker like:
```swift
Picker("Type", selection: $selectedType) {
    ForEach(ProjectType.allCases, id: \.self) { t in
        Text(label(for: t))
            .tag(t)
    }
}
.disabled(selectedType != .shortStory)  // remove this
```

The `.disabled(...)` line is gone. The descriptions per type can stay; just drop "Available in milestone 1d" if present.

- [ ] **Step 4: Smoke-build + tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 90 + new test count = roughly 130+ tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/NewProjectSheet.swift
git commit -m "feat: enable Novel/Screenplay/Collection in New Project sheet"
```

---

## Task 23: ProjectWindow — three-pane NavigationSplitView

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

The big integration. ProjectWindow becomes a `NavigationSplitView` hosting BinderView, EditorHost, InspectorView. Sheets for Project Settings and Claude Desktop. Word-count metrics derived live from the editor text.

- [ ] **Step 1: Read existing ProjectWindow to know what to preserve**

```bash
cat Maugham/Views/ProjectWindow.swift
```

Preserve: load logic, error states, no-chrome and full-screen handlers from 1c, save flash, window accessor, window state.

- [ ] **Step 2: Replace ProjectWindow with three-pane layout**

Replace the contents of `Maugham/Views/ProjectWindow.swift` with:

```swift
import SwiftUI
import AppKit

enum ProjectActiveSheet: Identifiable {
    case projectSettings
    case claudeDesktop
    var id: Int { hashValue }
}

struct ProjectWindow: View {
    @State private var store: ProjectStore?
    @State private var loadError: String?
    @State private var isNoChromeOn: Bool = false
    @State private var window: NSWindow?
    @State private var metrics: EditorMetrics =
        EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
    @State private var showingSaveFlash: Bool = false
    @State private var selectedItemId: String?
    @State private var activeSheet: ProjectActiveSheet?
    @State private var showInspector: Bool = true
    @Environment(UserPreferences.self) private var userPreferences

    let url: URL

    var body: some View {
        Group {
            if let store {
                NavigationSplitView {
                    BinderView(store: store, selectedItemId: $selectedItemId)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    ZStack(alignment: .bottomTrailing) {
                        EditorHost(store: store, selectedItemId: selectedItemId)
                            .onChange(of: store.manifest.structure) { _, _ in
                                refreshMetricsForSelection()
                            }
                            .onChange(of: selectedItemId) { _, _ in
                                refreshMetricsForSelection()
                            }
                        if userPreferences.goalIndicatorsVisible {
                            GoalIndicatorView(metrics: metrics)
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 480, ideal: 720)
                } detail: {
                    if showInspector && store.manifest.type != .collection {
                        InspectorView(
                            store: store,
                            selectedItemId: selectedItemId,
                            metrics: metrics,
                            onOpenProjectSettings: { activeSheet = .projectSettings }
                        )
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                    }
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $showingSaveFlash)
                }
                .navigationTitle(store.manifest.title)
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .projectSettings:
                        ProjectSettingsSheet(store: store)
                    case .claudeDesktop:
                        HelpClaudeDesktopSheet(
                            projectURL: store.url,
                            projectTitle: store.manifest.title)
                    }
                }
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't open project").font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(48)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 540)
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleNoChrome)) { _ in
            isNoChromeOn.toggle()
            applyNoChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleFullScreen)) { _ in
            toggleFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamDummySave)) { _ in
            showSaveFlash()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowProjectSettings)) { _ in
            activeSheet = .projectSettings
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowClaudeDesktopHelp)) { _ in
            activeSheet = .claudeDesktop
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleInspector)) { _ in
            showInspector.toggle()
        }
        .onChange(of: isNoChromeOn) { _, _ in applyNoChrome() }
    }

    // MARK: - Helpers

    private func refreshMetricsForSelection() {
        guard let store, let id = selectedItemId,
              let item = findItem(id: id, in: store.manifest.structure),
              item.type == .document, let path = item.path else {
            metrics = EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
            return
        }
        let url = store.url.appendingPathComponent(path)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            metrics = WritingModeFactory.mode(for: path).metrics(text)
        }
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let n = findItem(id: id, in: children) { return n }
        }
        return nil
    }

    private func applyNoChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = isNoChromeOn
        window.titleVisibility = isNoChromeOn ? .hidden : .visible
        window.standardWindowButton(.closeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.zoomButton)?.isHidden = isNoChromeOn
    }

    private func toggleFullScreen() {
        guard let window else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        if !wasFullScreen && !isNoChromeOn {
            isNoChromeOn = true
            applyNoChrome()
        }
        window.toggleFullScreen(nil)
    }

    @MainActor
    private func showSaveFlash() {
        showingSaveFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run { showingSaveFlash = false }
        }
    }

    @MainActor
    private func load() async {
        do {
            store = try await ProjectStore.load(from: url)
            // Auto-select the first document for usability
            if let first = firstDocument(in: store?.manifest.structure ?? []) {
                selectedItemId = first.id
            }
            refreshMetricsForSelection()
            loadError = nil
        } catch ProjectStoreError.manifestNotFound {
            loadError = "No project.maugham.json was found in this folder."
        } catch ProjectStoreError.manifestUnreadable(let msg) {
            loadError = "Manifest is corrupt or unreadable: \(msg)"
        } catch ProjectStoreError.manuscriptUnreadable(let msg) {
            loadError = "Manuscript file couldn't be read: \(msg)"
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func firstDocument(in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.type == .document { return item }
            if let children = item.children,
               let nested = firstDocument(in: children) { return nested }
        }
        return nil
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window == nil { self.window = nsView.window }
        }
    }
}
```

This adds three new notification names that don't exist yet — they'll be added in Task 24 below. The build will fail until Task 24 lands.

- [ ] **Step 3: Skip smoke-build (Task 24 adds the missing notifications)**

The build will fail at this step with "no member `maughamShowProjectSettings`" etc. That's expected. Don't run the build; commit and continue to Task 24.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "feat: ProjectWindow three-pane NavigationSplitView with binder, editor, inspector"
```

---

## Task 24: MaughamApp — Open Recent, Help, ⌘⌥,, Show Inspector

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift` (add 3 new names)
- Modify: `Maugham/MaughamApp.swift`

Adds the menu commands that drive the new sheets and inspector toggle, plus the Open Recent submenu and Help → Set up Claude Desktop.

- [ ] **Step 1: Add 3 new notification names**

In `Maugham/Models/MaughamNotifications.swift`, append before the closing `}`:

```swift
    public static let maughamShowProjectSettings = Notification.Name("maugham.showProjectSettings")
    public static let maughamShowClaudeDesktopHelp = Notification.Name("maugham.showClaudeDesktopHelp")
    public static let maughamToggleInspector = Notification.Name("maugham.toggleInspector")
```

- [ ] **Step 2: Update MaughamApp commands**

In `Maugham/MaughamApp.swift`, replace the `.commands { ... }` block on the Welcome window scene with:

```swift
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    NotificationCenter.default.post(name: .maughamNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") {
                    NotificationCenter.default.post(name: .maughamOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    OpenRecentSubmenu()
                }
                Divider()
                Button("Save") {
                    NotificationCenter.default.post(
                        name: .maughamDummySave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Project Settings…") {
                    NotificationCenter.default.post(
                        name: .maughamShowProjectSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .option])
            }
            CommandMenu("View") {
                Button("Toggle Focus Mode") {
                    NotificationCenter.default.post(
                        name: .maughamToggleNoChrome, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
                Button("Toggle Full-Screen Focus") {
                    NotificationCenter.default.post(
                        name: .maughamToggleFullScreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(
                        name: .maughamToggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Set up Claude Desktop…") {
                    NotificationCenter.default.post(
                        name: .maughamShowClaudeDesktopHelp, object: nil)
                }
            }
        }
```

- [ ] **Step 3: Add OpenRecentSubmenu helper view**

At the bottom of `Maugham/MaughamApp.swift`, add:

```swift
private struct OpenRecentSubmenu: View {
    @State private var recents = RecentsStore()

    var body: some View {
        Group {
            if recents.recents.isEmpty {
                Text("(No recent projects)")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recents.recents, id: \.path) { url in
                    Button(url.lastPathComponent) {
                        NotificationCenter.default.post(
                            name: .maughamOpenProject,
                            object: nil,
                            userInfo: ["url": url])
                    }
                }
                Divider()
                Button("Clear Recent Projects") {
                    for url in recents.recents { recents.remove(url) }
                }
            }
        }
    }
}
```

The `userInfo: ["url": url]` is a new pattern — previously `.maughamOpenProject` carried no payload. Update `WelcomeHost.openViaPanel` and the existing `.maughamOpenProject` observer in `WelcomeHost` to accept an optional `url` from userInfo.

In `WelcomeHost`, modify the `.onReceive` for `.maughamOpenProject`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamOpenProject)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                open(url)
            } else {
                openViaPanel()
            }
        }
```

This way, the menu-bar Open Recent items dispatch directly to `open(_:)`, skipping the file picker; the menu-bar "Open Project…" still opens the picker.

- [ ] **Step 4: Smoke-build + full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(Executed |TEST FAILED|TEST SUCCEEDED|BUILD FAILED|error:)" | tail -10
```

Expected: BUILD SUCCEEDED, all tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift
git commit -m "feat: Open Recent, Project Settings ⌘⌥,, Help → Claude Desktop, Toggle Inspector"
```

---

## Task 25: End-to-end smoke test + tag milestone-1d

- [ ] **Step 1: Run full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: ~135 tests passing total. Breakdown:
- 1a (33) + 1b (44) + 1c (13) = 90 from prior milestones
- Slugifier (9) + FileNaming (9) + ProjectStoreMutation (14 across add/rename/delete/inspector) + ProjectStoreTypography (4) + ProjectFactory (3 new) + ProjectManifest (2 new) + WritingModeFactory (5) + ScreenplayMode (5) + TypographySettings (2 new) ≈ 53 new
- 90 + 53 = 143 expected. Allow ±5 for any test count drift.

- [ ] **Step 2: Manual smoke test (10 steps)**

In Xcode, ⌘R or `open` the built `.app`. Walk these:

1. From Welcome window, pick **New Project…**, choose **Novel**, name it "Smoke Novel". Project opens with three-pane layout: binder showing "Chapter 1", editor with Iowan Old Style typography, inspector showing Title/Status/Synopsis/Words.
2. Right-click "Chapter 1" in the binder → **New Document**. New row appears, immediately in rename mode. Type "Chapter 2", press Return. Binder shows two chapters. Editor switches to Chapter 2 (empty).
3. Right-click "Chapter 1" → **New Group**. New "New Group" row appears. Rename it to "Act One". Press Return.
4. Right-click "Act One" → **New Document**. Names it "Scene 1" via rename mode. The editor switches to the new scene; in Finder, verify `manuscript/03-act-one/01-scene-1.md` exists.
5. Switch back to Chapter 2. Type some prose. Inspector updates: word count rises live.
6. In the inspector, set Status to "Revising". Binder dot for Chapter 2 turns orange.
7. Press ⌘⌥, → Project Settings sheet opens. Pick "Customize for this project", change font size to 22pt. Editor reflows. Press Done. Reopen project (close window, double-click in Recents) — typography persists at 22pt.
8. File menu → Open Recent → "Smoke Novel". Project re-opens.
9. Help menu → "Set up Claude Desktop…" → Sheet shows JSON snippet with the project's path. Click "Copy snippet". Switch to TextEdit, paste — JSON contains `"command": "npx"` and the project path.
10. Right-click Chapter 2 → Delete. Confirmation panel shows. Click Move to Trash. Chapter 2 disappears from binder; verify in Finder Trash that the file is there. Editor shows placeholder.

If all 10 pass, milestone 1d is healthy.

- [ ] **Step 3: Tag and merge**

```bash
git checkout main
git merge --ff-only feat/phase-1d-projects
git tag -a milestone-1d -m "Maugham milestone 1d — Project Expansion

Three-pane NavigationSplitView (Binder + Editor + Inspector). Novel
projects ship with a writable hierarchical binder (right-click add/
rename/delete; no reorder yet). Screenplay opens .fountain files in
monospace via ScreenplayMode (no parser). Collection is a placeholder
project type. Inspector shows synopsis (debounced), status, live word
count. Project Settings sheet at ⌘⌥, overrides typography per-project.
File menu has Open Recent submenu. Help → Set up Claude Desktop opens
a sheet with a copyable per-project MCP config snippet. ThemeManager
renamed to UserPreferences; notifications consolidated."
git tag --list 'milestone-*'
```

Expected: `milestone-1a milestone-1b milestone-1c milestone-1d`.

- [ ] **Step 4: Update README**

Append after the existing 1c smoke section in `README.md`:

```markdown

## Phase 1d smoke test

Once running on milestone-1d:

1. New Project → Novel → name it "Smoke Novel". Three-pane window opens.
2. Right-click Chapter 1 → New Document. Renames to "Chapter 2".
3. Right-click Chapter 1 → New Group. Renames to "Act One".
4. Right-click Act One → New Document. Renames to "Scene 1". Verify file path in Finder includes `03-act-one/01-scene-1.md`.
5. Type prose in Chapter 2; word count in inspector updates live.
6. Inspector Status = Revising. Binder dot for Chapter 2 turns orange.
7. ⌘⌥, → Customize for this project → font size 22 → Done. Reopen project. Typography persists.
8. File → Open Recent → Smoke Novel. Re-opens.
9. Help → Set up Claude Desktop. Copy snippet. Paste anywhere — JSON contains the project path.
10. Right-click Chapter 2 → Delete → Move to Trash. Disappears from binder; appears in Finder Trash.

If all ten pass, milestone 1d is healthy.
```

```bash
git add README.md
git commit -m "docs: add phase 1d smoke test checklist"
```

---

## Self-review checklist

- [x] **Spec coverage:** Every spec section has at least one task. Three-pane (T23), Novel/Screenplay/Collection (T12), binder writes (T18), inspector (T19), per-project typography (T20+T11), ScreenplayMode (T14), WritingModeFactory (T15), Open Recent + Help (T24), infra rename (T3) and notification consolidation (T2). 8-step manual smoke (in T25) maps to spec acceptance criteria. ✓
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later", "fill in details", "appropriate error handling", "similar to Task N". Every step has actual code. ✓
- [x] **Type consistency:** `StructureItemKind` used in T7, T8, T18 has matching cases (`.document(extension:)`, `.group`). `effectiveTypography(override:userDefault:)` static signature used in T11 and T16/T23. `ProjectActiveSheet` enum same in T23. `Slugifier.slug(from:)` API consistent across T4 and T5. `FileNaming.nextDocumentFilename(title:extension:siblingFilenames:)` consistent across T5, T7, T12. `ItemStatus` is a string ("draft"/"revising"/"final") consistently in T10 (mutation), T17 (BinderRow), T19 (InspectorView). ✓
- [x] **TDD:** Pure-logic tasks (T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15) follow TDD with explicit fail/pass test runs. UI tasks (T16, T17, T18, T19, T20, T21, T23) are smoke-build only with manual smoke at T25 — appropriate test strategy. ✓
- [x] **Decomposition:** 25 tasks. Big enough to be the largest milestone yet, but each task is self-contained and follows the established 1b/1c pattern. Critical dependency ordering: infra rename (T2-T3) → pure logic (T4-T15) → UI (T16-T21) → integration (T22-T24) → smoke (T25). ✓
