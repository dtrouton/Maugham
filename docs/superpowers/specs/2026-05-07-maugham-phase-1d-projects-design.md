# Maugham Phase 1d — Project Expansion Design Spec

**Anchor:** This spec implements the *project expansion* slice of Phase 1's remaining deliverables (master design Sections 1, 2 typography overrides, and 4). The orthogonal *file foundation* slice (DocumentStore, NSFileCoordinator/NSFilePresenter, conflict resolution) lands separately as milestone 1e.

**Goal:** Turn the single-document Short Story experience into a real multi-document project workspace. Novel projects ship with a writable hierarchical binder (right-click to add chapters/scenes, rename, delete-to-trash). Screenplay and Collection ship as functional stubs. The window grows to a three-pane `NavigationSplitView` (Binder ▸ Editor ▸ Inspector). Inspector shows synopsis, status, live word count. A `Project Settings…` sheet at ⌘⌥, lets the user override typography per-project. File menu gets an Open Recent submenu. Help → Set up Claude Desktop opens an in-app sheet with a copyable MCP config snippet for the current project's path.

After 1d, a writer can create a Novel, build out chapters and scenes as they go, see live metrics in the inspector, customise typography for the manuscript at hand, and one-click-copy a Claude Desktop config snippet to start an AI conversation against their files.

---

## Out of scope (deferred to later milestones)

| Feature | Lands in |
|---|---|
| DocumentStore + NSFileCoordinator + NSFilePresenter | 1e |
| Autosave debounce + conflict resolution (Keep / Use cloud) | 1e |
| Drag-reorder of binder items | Phase 2 (needs DocumentStore) |
| "Tidy filenames" (compact NN sequence after deletes) | Phase 2 |
| Inspector tags, links, per-document word target | Phase 2–4 |
| Fountain parser (Tab/Enter cycling, character autocomplete) | Phase 3 |
| Inspector synopsis appears as binder hover-tooltip | Phase 2 |

---

## Architecture

```
ProjectWindow
├─ NavigationSplitView(.balanced)
│   ├─ Sidebar: BinderView(structure: store.manifest.structure,
│   │                       selection: $selectedItemId,
│   │                       store: store)
│   ├─ Content: EditorHost(store: store, selectedItemId: ...)
│   │            └─ EditorSurface(text: doc.text, theme, typography, ...)
│   │            OR PlaceholderView("Select a document")
│   └─ Detail:  InspectorView(itemId: selectedItemId, store: ...)
├─ .sheet(item: $activeSheet) { sheet in
│       ProjectSettingsSheet | HelpClaudeDesktopSheet
│   }
└─ .background(WindowAccessor(window: $window))   // 1c hold-over
```

`ProjectStore` becomes the single mutator for project state. New methods:

- `addStructureItem(parentId: String?, kind: ItemKind) async throws`
- `renameStructureItem(id: String, newTitle: String) async throws`
- `deleteStructureItem(id: String) async throws` — moves file or folder to system trash, removes manifest entry
- `updateInspector(id: String, synopsis: String?, status: ItemStatus?) async throws`
- `setProjectTypography(_ override: TypographySettings?) async throws`
- `manuscriptText(forItem id: String) -> String` and the matching set
- `effectiveTypography: TypographySettings` — computed: `manifest.typography ?? userPreferences.typography`

Each mutator updates `manifest`, performs filesystem ops if needed, and saves the manifest atomically (existing pattern).

UI binds to `store.manifest.structure` (which is `@Observable`-equivalent via the existing `ProjectStore` `@Observable` annotation). Re-renders happen automatically.

---

## Project types

All four types ship in 1d. The four-radio chooser in `NewProjectSheet` becomes fully enabled (no more "Coming in milestone 1d" caption).

### Short Story (unchanged)

Manifest type `"shortStory"`. Single document at root: `manuscript/story.md`. Binder optional — users may navigate via the binder pane or simply have a one-document project where the binder shows that single item. UI behaviour: binder pane visible by default, but the structure is a single document.

### Novel

Manifest type `"novel"`. Default skeleton at creation time:

```
project.maugham.json
manuscript/
  01-chapter-1.md       (single document, "Chapter 1")
research/
notes/
```

Manifest `structure[0]` = `{ id: "ch-…", type: "document", title: "Chapter 1", path: "manuscript/01-chapter-1.md", status: "draft" }`.

The user grows the structure via the binder right-click menu. Typical evolution: add a Group ("Act One") → add documents inside it → repeat for Acts Two and Three. Or stay flat with chapters at the root. Maugham doesn't impose a structure beyond what `StructureItem` allows (recursive groups + documents).

### Screenplay (stub)

Manifest type `"screenplay"`. Default skeleton:

```
project.maugham.json
manuscript/
  01-scene-1.fountain
research/
notes/
```

A new `ScreenplayMode` (sibling of `ProseMode`) is the writing mode for `.fountain` files. ScreenplayMode v1 in 1d:

- Monospace typography. Default font: JetBrains Mono if installed (the master spec curates it for screenplays); fallback to `NSFont.monospacedSystemFont`.
- Plain text — no Fountain parser, no auto-format, no Tab/Enter cycling. The `.fountain` extension just *triggers the mode*; rendering is plain monospace.
- `tokenize(_:)` returns one `.plain` token spanning the entire text.
- `applyTypography` applies the monospace font + theme palette body text. No syntax colouring.
- `bodyTypingAttributes` mirrors the body attrs.
- `smartTypographyTransform` returns nil (screenplays don't want curly quotes etc — Fountain is plain ASCII).
- `metrics(_:)` reuses ProseMode's word-count math.
- `textColumnWidth` uses the same pangram-based avg (monospace will produce a slightly wider column at the same character count, which is correct).

Mode selection: `EditorHost` picks `ScreenplayMode()` if the document path ends in `.fountain`, else `ProseMode()`. Factory: `WritingMode.for(path: String) -> any WritingMode` lives in a new `Maugham/Editor/WritingModeFactory.swift`.

### Collection (stub)

Manifest type `"collection"`. Default skeleton:

```
project.maugham.json
research/
notes/
```

No `manuscript/` folder. `structure[]` is empty. The project window shows the binder (empty), the editor pane shows a placeholder ("Collection support — including referenced sub-projects and shared research — arrives in Phase 2."), and the inspector is hidden. The user can still create the project, see the folder in Finder, and use Claude Desktop with the folder. Right-click in the empty binder offers no actions in 1d (collection structure-building is a Phase 2 feature).

---

## Binder

### Layout

`BinderView` renders `store.manifest.structure` as a SwiftUI `List`-with-`OutlineGroup`-style hierarchy. Each row:

- 16pt indent per level
- Expand/collapse chevron for groups
- Status dot (4pt circle) coloured by status — Draft = `.secondary`, Revising = `.orange`, Final = `.green` (uses theme palette)
- Title (truncated mid-string with ellipsis at narrow widths)
- Selection highlight using SwiftUI's standard list selection

Single-click selects (binds `selectedItemId`). Selecting a document item makes the editor pane bind to that document's text. Selecting a group item shows a placeholder in the editor: "(Group: <title>) — select a document to edit."

### Right-click menu

```
─ New Document        (creates a sibling document if right-clicked on a document
                       or empty area; child document if right-clicked on a group)
─ New Group           (same parent rules as New Document)
─ Rename              (inline TextField over the row title, ⏎ to commit, Esc to cancel)
─ Delete              (NSWorkspace.recycle + manifest entry removed; confirmation
                       sheet "Move 'Chapter 1' to Trash?" with destructive style)
```

The "parent rules" are deliberate:
- **Right-click on empty area**: parent = root (manifest.structure)
- **Right-click on a document**: parent = that document's parent (sibling creation)
- **Right-click on a group**: parent = the group itself (child creation, inside the group)

### Filenames (scheme A — final-state-aligned)

`NN-slug.<ext>` where:

- `NN` = creation-order index within the parent group, zero-padded to 2 digits, monotonically increasing. Computed at *creation time* as `max(existing NN) + 1`. Never changes in 1d (no reorder).
- `slug` = `Slugify(title)` → ASCII-only (Unicode normalised then stripped to `[a-z0-9-]`), spaces → `-`, lowercased, max 40 chars. Empty slug falls back to `untitled`.
- `<ext>` = `.md` for prose documents, `.fountain` for screenplay documents
- Collisions: append `-2`, `-3`, etc. (e.g., two chapters titled "Chapter 1" → `01-chapter-1.md`, `02-chapter-1-2.md`)
- Folders for groups: `manuscript/<NN-slug>/` recursive

### Operations under scheme A

| Op | Filesystem effect | Manifest effect | Failure mode |
|---|---|---|---|
| **Add document** | Create empty file at `manuscript/<parent-path>/NN-slug.<ext>` | Append `StructureItem(type: .document, ...)` to parent's children, save manifest | If file write fails, abort with no manifest change |
| **Add group** | Create empty folder at `manuscript/<parent-path>/NN-slug/` | Append `StructureItem(type: .group, children: [])` | If folder create fails, abort |
| **Rename** | `mv NN-old-slug.<ext> NN-new-slug.<ext>` (NN preserved) | Update `title` in manifest, save | If `mv` fails (target exists, permissions), revert manifest |
| **Delete** | `NSWorkspace.shared.recycle(URLs:)` (system trash, recoverable) | Remove `StructureItem` from parent's children, save | If recycle fails, manifest is not changed |

**No reorder UI in 1d.** Items appear in the binder in their manifest order, which equals creation order. Drag-reorder + multi-file rename land in Phase 2 alongside DocumentStore.

**Path immutability for groups:** the *NN* component is locked at creation; only the slug part of a group folder updates on rename. So renaming a group "Act One" → "The Beginning" mv's `01-act-one/` to `01-the-beginning/`, preserving all children's relative paths. (Group rename is rare and atomic at the folder level — `Foundation` handles it as a single op.)

---

## Inspector

`InspectorView(itemId: String?, store: ProjectStore)`. SwiftUI Form with two sections:

### Section: Document

Visible only when `itemId` resolves to a document. Hidden for groups.

- **Title** (read-only Text, mirrors binder)
- **Status** (Picker, 3 cases: Draft / Revising / Final, default Draft)
- **Synopsis** (multi-line `TextEditor`, 3 lines visible, scrolls inside, placeholder "What happens here?")
- **Word count** (read-only, formatted `1,247 words · 6 min read` from `mode.metrics(currentText)`)

Edits debounce 500ms then call `store.updateInspector(id:, synopsis:, status:)`. On status change, the binder dot recolours immediately (manifest write is async, but the UI updates on `manifest` mutation).

### Section: Project

Always visible regardless of selection.

- Button "Project Settings…" — opens `ProjectSettingsSheet` (also reachable via ⌘⌥,)

### Inspector visibility

Per master spec, inspector is part of the standard three-pane window. In 1d it's:

- Visible by default in `.balanced` NavigationSplitView mode
- Toggleable via View menu → "Show Inspector" (which we add to the existing `CommandMenu("View")` block from 1c)
- Hidden when no project is open (Welcome window)
- Hidden for Collection projects (no documents yet)

---

## Project Settings sheet (⌘⌥,)

Modal sheet on the project window. Shape:

```
┌─ Project Settings — The Razor's Edge ────────────────────────────┐
│                                                                   │
│  Typography                                                       │
│  ────────────────────                                             │
│  ◉ Use my defaults                                                │
│  ○ Customize for this project                                     │
│                                                                   │
│  [ When "Customize" is selected, the same controls as             │
│    Settings → Editor → Typography appear here, bound to           │
│    a per-project TypographySettings stored in the manifest. ]     │
│                                                                   │
│                                       [ Done ]                    │
└───────────────────────────────────────────────────────────────────┘
```

Sheet binds to `store.manifest.typography: TypographySettings?` (new optional field, schema-compatible — older Maugham reads new manifests, new Maugham reads old manifests). Toggle ON ("Use my defaults") sets it to `nil`; OFF copies `userPreferences.typography` into the manifest, then live-edits there.

`EditorHost` reads `store.effectiveTypography` (`manifest.typography ?? userPreferences.typography`) and feeds it to `EditorSurface`. So changing per-project typography updates the editor immediately, and clearing the override falls back to user defaults instantly.

**Manifest schema addition (1d only):** `manifest.typography: TypographySettings?` — new optional field. Schema version stays at 1. Older Maugham builds tolerate unknown fields (per master spec); newer builds tolerate `nil`. No migration required.

---

## Open Recent

`RecentsStore` already exists (1a). New: a `Menu("Open Recent")` inside the existing `CommandGroup(replacing: .newItem)` block in `MaughamApp.swift`, populated from `RecentsStore`. Each item is a `Button(url.lastPathComponent)` posting `maughamOpenProject` notification with the URL. A `Divider()` and "Clear Recent Projects" item at the bottom calls `RecentsStore.shared.clear()`.

Limit to 10 most recent (existing `RecentsStore` already enforces this).

---

## Help → Set up Claude Desktop

`HelpClaudeDesktopSheet` — modal sheet, opens via `Help` menu → "Set up Claude Desktop…".

Content:

1. Short paragraph: "Claude Desktop can read your Maugham project folder via its built-in filesystem MCP server. Add the snippet below to Claude Desktop's `claude_desktop_config.json` and restart Claude Desktop."
2. A read-only monospace `TextEditor` containing the JSON snippet, pre-filled with the *currently-focused* project's path:
    ```json
    {
      "mcpServers": {
        "maugham-the-razors-edge": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem",
                   "/Users/you/Documents/Maugham/The Razors Edge"]
        }
      }
    }
    ```
   (Path inserted dynamically; key name slugified from project title.)
3. "Copy snippet" button — `NSPasteboard` write, brief "Copied" toast.
4. "Where is `claude_desktop_config.json`?" disclosure: macOS path is `~/Library/Application Support/Claude/claude_desktop_config.json`.
5. Done button.

When no project is open, the sheet shows a placeholder snippet with `<your-project-path>` and instructions to open a project first.

Menu wiring: replaces `.help` command group, with one item plus the system Help menu's standard items preserved.

---

## ScreenplayMode

New file: `Maugham/Editor/ScreenplayMode.swift`. Implements `WritingMode` protocol. Body:

```swift
public struct ScreenplayMode: WritingMode {
    private static let wordsPerMinute = 200
    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        text.isEmpty ? [] : [Token(range: NSRange(location: 0, length: (text as NSString).length), kind: .plain)]
    }

    public func smartTypographyTransform(...) -> String? { nil }  // screenplays = ASCII

    public func metrics(_ text: String) -> EditorMetrics { /* same as ProseMode */ }

    public func applyTypography(in storage:, theme:, typography:, tokens:) {
        // Use monospace font (typography.fontFamily for screenplay = "JetBrains Mono"
        // if available, else NSFont.monospacedSystemFont). Apply body palette.
    }

    public func bodyTypingAttributes(theme:, typography:) -> [...] { /* monospace body */ }

    public func textColumnWidth(typography:) -> CGFloat { /* same pangram math */ }
}
```

For 1d, the typography settings used for screenplays come from a new `TypographySettings.screenplayDefaults` — `JetBrains Mono` 13pt, 1.5 line height multiplier, 60-char page width. The Project Settings sheet for a screenplay project shows screenplay-appropriate fonts (a curated list including JetBrains Mono and other monospace options).

`WritingMode.for(path:)` factory:

```swift
public static func `for`(path: String) -> any WritingMode {
    if path.hasSuffix(".fountain") { return ScreenplayMode() }
    return ProseMode()
}
```

`EditorHost` calls this when binding to a document.

---

## Infrastructure tidy (included in 1d)

Two small refactors that 1d's expanded preference surface makes worth doing now:

### Rename ThemeManager → UserPreferences

`ThemeManager` now holds: theme + typography + 4 focus prefs + goal indicators. The "Theme" name is misleading. With 1d adding *project*-level prefs alongside *user*-level prefs, the asymmetry should be reflected in naming. Rename:

- Type: `ThemeManager` → `UserPreferences`
- File: `Maugham/Theme/ThemeManager.swift` → `Maugham/Preferences/UserPreferences.swift`
- All `@Environment(ThemeManager.self)` sites update (3 files: `MaughamApp.swift`, `ProjectWindow.swift`, `SettingsView.swift`)
- Tests: `ThemeManagerTests.swift` → `UserPreferencesTests.swift`

Folder reorg: move `Maugham/Theme/` → `Maugham/Preferences/`. Theme.swift, TypographySettings.swift, UserPreferences.swift all live there.

### Consolidate Notification.Name extensions

Currently scattered:
- `MaughamApp.swift` — `maughamNewProject`, `maughamOpenProject`
- `ProjectWindow.swift` — `maughamToggleNoChrome`, `maughamToggleFullScreen`, `maughamDummySave`

Move all to a new `Maugham/Models/MaughamNotifications.swift`. Pure mechanical refactor.

These tasks land *first* in 1d so subsequent work uses the new names.

---

## Testing strategy

### TDD (pure logic) — ~30 new tests

- `ProjectStoreMutationTests` — add/rename/delete/updateInspector/setProjectTypography. Cover happy-path + failure-paths (rename target exists, delete moves to trash but file already gone, save manifest fails).
- `SlugifierTests` — title → slug rules, collision suffixing.
- `WritingModeFactoryTests` — extension routing.
- `EffectiveTypographyTests` — fallback resolution (override present → override; override nil → user default).
- `ScreenplayModeTests` — tokenize returns single plain token; smart typography always nil; metrics correct; applyTypography sets monospace.
- `UserPreferencesTests` — re-named from ThemeManagerTests, no behaviour change beyond rename.

### Smoke-build only

- BinderView, InspectorView, ProjectSettingsSheet, HelpClaudeDesktopSheet
- Three-pane integration in ProjectWindow
- Right-click menu wiring

### Manual smoke (T-end)

10 steps covering: create Novel, add chapter via right-click, add scene under a group, rename a chapter, delete a chapter (verify in Finder trash), switch documents (editor binds to selected), edit synopsis (debounced save → reload from disk), set status to Revising (binder dot recolours), open Project Settings → customize typography → editor reflows, Help → Set up Claude Desktop → Copy snippet → paste verifies path is correct.

---

## Files (created or modified)

```
Maugham/Preferences/                          # NEW (renamed from Theme/)
  Theme.swift                                 # MOVED
  TypographySettings.swift                    # MOVED + extended (.screenplayDefaults, curatedScreenplayFonts)
  UserPreferences.swift                       # RENAMED from ThemeManager.swift

Maugham/Editor/
  ScreenplayMode.swift                        # NEW
  WritingModeFactory.swift                    # NEW
  EditorSurface.swift                         # MODIFIED — now takes mode dynamically per file

Maugham/Models/
  MaughamNotifications.swift                  # NEW (consolidated)
  ProjectManifest.swift                       # MODIFIED — adds optional typography: TypographySettings?
  Slugifier.swift                             # NEW

Maugham/Stores/
  ProjectStore.swift                          # MODIFIED — adds add/rename/delete/updateInspector/setProjectTypography mutators
  ProjectFactory.swift                        # MODIFIED — fills in createNovelProject, createScreenplayProject, createCollectionProject

Maugham/Views/
  ProjectWindow.swift                         # MODIFIED — three-pane NavigationSplitView, hosts BinderView + EditorHost + InspectorView
  EditorHost.swift                            # NEW — binds editor to selected document, picks WritingMode by extension
  BinderView.swift                            # NEW
  BinderRow.swift                             # NEW (status dot + title + inline rename)
  InspectorView.swift                         # NEW
  ProjectSettingsSheet.swift                  # NEW
  HelpClaudeDesktopSheet.swift                # NEW
  NewProjectSheet.swift                       # MODIFIED — enables Novel/Screenplay/Collection radios
  WelcomeView.swift                           # unchanged

Maugham/MaughamApp.swift                      # MODIFIED — Open Recent submenu, Help → Set up Claude Desktop, Show Inspector toggle, ⌘⌥, Project Settings command

MaughamTests/
  SlugifierTests.swift                        # NEW
  ProjectStoreMutationTests.swift             # NEW
  WritingModeFactoryTests.swift               # NEW
  EffectiveTypographyTests.swift              # NEW
  ScreenplayModeTests.swift                   # NEW
  UserPreferencesTests.swift                  # RENAMED from ThemeManagerTests
  ProjectFactoryTests.swift                   # MODIFIED — covers Novel/Screenplay/Collection skeletons
  ProjectManifestTests.swift                  # MODIFIED — covers typography roundtrip
```

Roughly: 11 new files in main target, 5 new test files, 7 modified main files, 2 modified test files. Substantial milestone — bigger than 1c (~12 commits) but smaller than 1b (~20 commits). Estimate: 18-22 tasks.

---

## Open questions for plan-writing

1. The `BinderView` recursive structure is non-trivial in SwiftUI — inline rename, right-click context menu, status dots, indentation, selection. The plan should decompose this into 2–3 separate tasks (BinderRow first, then BinderView outer, then context-menu wiring).
2. `ProjectStore.deleteStructureItem` for a *group* with children: recursive delete (move whole folder to trash) — straightforward via `NSWorkspace.recycle` on the folder URL.
3. `addStructureItem` when the parent is at the root needs to disambiguate between "manifest.structure" (top-level) and "a specific group's children". Single Swift API: `parentId: String?` where `nil` = root.
4. SwiftUI sheet management: ProjectSettingsSheet and HelpClaudeDesktopSheet share the project window's sheet slot — use an `enum ActiveSheet { case projectSettings, claudeDesktop }` with `@State var activeSheet: ActiveSheet?`.
