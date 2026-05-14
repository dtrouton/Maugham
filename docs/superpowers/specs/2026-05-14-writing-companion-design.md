# Maugham — Writing Companion Design

**Status:** approved 2026-05-14
**Group:** 1 — Editing flow polish
**Follows:** milestone-find-replace

## Goal

Three quality-of-life features tied together by a single architectural insight — the right pane (currently Inspector-only) becomes a **mode-swappable reference panel**:

- **Keyboard shortcuts cheatsheet** — surfaces every Maugham shortcut alongside the existing Markdown/Fountain syntax references.
- **Research ↔ manuscript linking** — explicitly link research items to manuscript documents; see them in a focused panel while drafting.
- **Structure views** — Outliner (table) and Corkboard (cards) layouts for the manuscript's structure with synopsis + status + word count, click-to-navigate.

The unifying pattern: the right pane (currently `InspectorView`) gains a segment picker (Inspector / Research / Outline) — same shape as the binder pane's existing picker. The writer can keep one mode active while drafting, hide the whole pane with `⌘⌥I`, or hop between modes with `⌘⌥1/2/3`.

## Architecture

Three connected features held together by the right-pane mode swap:

- **New `DetailSegment` enum** (mirrors `BinderSegment`): `.inspector` / `.research` / `.outline`. Picker at the top of the right pane switches modes. Persisted per-project via `UIState.detailSegment`. The existing `⌘⌥I Toggle Inspector` becomes "Toggle Right Pane" — hides the whole pane regardless of mode.

- **New `OutlineLayout` enum**: `.table` / `.cards`. Internal toggle inside the Outline pane; one set of data, two layouts.

- **Right pane composition**:
  - `.inspector` → existing `InspectorView` (unchanged)
  - `.research` → new `LinkedResearchPane` showing items linked to the active manuscript document, with drag-drop link target + `+ Add Link…` button
  - `.outline` → new `OutlinePane` rendering the manuscript structure with synopsis + status + word count, table/cards layout toggle

- **Data model**: add `StructureItem.linkedResearchIds: [String]?`. Schema-1 additive. Links unidirectional (manuscript → research); back-references rendered are computed on read, not stored.

- **Keyboard cheatsheet**: extend the existing `SyntaxHelpSheet` (⌘/) with a third tab. Sheet becomes a `TabView` with Markdown / Fountain / Keyboard tabs.

- **Linking surfaces**:
  - Drag from the binder's Research segment onto the right-pane Research panel → linked
  - Click `+ Add Link…` → modal sheet with full research tree + search; checkboxes toggle linked state
  - `×` on each linked row → unlink (no confirmation; reversible)

Cross-cutting:
- Right pane works for all project types except `.collection` (existing guard).
- `.research` and `.outline` show empty states when no manuscript document is active.
- Outline updates reactively from manifest mutations; word counts use existing `ProjectStore.cachedWordCount(for:)`.

## Data model

### Manifest additions

```swift
public struct StructureItem {
    // ...existing fields
    public var linkedResearchIds: [String]?  // NEW — IDs of linked research items
}
```

Additive optional field. Schema-1 unchanged.

Note: `StructureItem.links: [String]?` already exists (from 2c wiki-link work) and stores wiki-link target paths/titles — a different semantic. Keeping them separate avoids overloading.

### New enums

```swift
public enum DetailSegment: String, Codable, Equatable, Sendable {
    case inspector
    case research
    case outline
}

public enum OutlineLayout: String, Codable, Equatable, Sendable {
    case table
    case cards
}
```

### `UIState` additions

```swift
public struct UIState {
    // ...existing fields
    public var detailSegment: DetailSegment        // default .inspector
    public var outlineLayout: OutlineLayout        // default .table
}
```

Defaults stay friendly: writers who never touch the picker stay on Inspector + table-layout outline.

### ProjectStore APIs

```swift
/// Link a research item to a manuscript document. Idempotent.
public func linkResearch(researchId: String, toDocumentId documentId: String) async throws

/// Remove a research link. Idempotent.
public func unlinkResearch(researchId: String, fromDocumentId documentId: String) async throws

/// IDs of research items linked to the given document.
public func linkedResearchIds(forDocumentId documentId: String) -> [String]

/// Resolve a research-id list to actual ResearchItems, skipping orphans.
public func resolveResearchLinks(_ ids: [String]) -> [ResearchItem]
```

Internally these walk `manifest.structure` recursively to find/update `linkedResearchIds`, then `save()`. `resolveResearchLinks` walks `manifest.research` and skips IDs that don't resolve.

### Notification names

```swift
public static let maughamShowKeyboardCheatsheet = Notification.Name("maugham.show.keyboard.cheatsheet")
public static let maughamSetDetailSegment       = Notification.Name("maugham.set.detail.segment")
```

`maughamSetDetailSegment.userInfo["segment"]` carries the raw value of `DetailSegment`.

### Keyboard cheatsheet content format

Static curated list in `Maugham/Resources/KeyboardShortcuts.swift`:

```swift
public enum KeyboardShortcuts {
    public struct Category {
        public let category: String
        public let items: [Entry]
    }
    public struct Entry {
        public let label: String
        public let shortcut: String  // e.g., "⌘N", "⌘⌥F"
    }
    public static let all: [Category] = [
        // File / Edit / View / Navigation / Find / Help — hand-curated
    ]
}
```

Hand-curated. A test verifies the curated list isn't empty and contains a baseline set of categories. Drift between this list and `MaughamApp.commands` is tagged as a manual smoke-step concern.

## UI components

### `DetailPaneToggle`

New SwiftUI view wrapping the right pane's content. Picker at top, body switches on `DetailSegment`:

```swift
struct DetailPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    let activeManuscriptItemId: String?
    let activeResearchItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Right pane", selection: $segment) {
                Image(systemName: "info.circle").tag(DetailSegment.inspector)
                Image(systemName: "doc.text.magnifyingglass").tag(DetailSegment.research)
                Image(systemName: "list.bullet.indent").tag(DetailSegment.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch segment {
                case .inspector: InspectorView(/* existing args */)
                case .research:  LinkedResearchPane(store: store,
                                                   activeDocumentId: activeManuscriptItemId)
                case .outline:   OutlinePane(store: store, /* layout binding */)
                }
            }
        }
    }
}
```

`ProjectWindow.inspectorPane(...)` is replaced by `DetailPaneToggle(...)`. The existing `showInspector: Bool` toggle controls whole-pane visibility (renamed semantically to "right pane" but the Bool itself can stay).

### `LinkedResearchPane`

```swift
struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?
    @State private var showingLinkPicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let docId = activeDocumentId {
                List {
                    ForEach(linkedItems(for: docId)) { item in
                        LinkedResearchRow(item: item, onUnlink: {
                            Task { try? await store.unlinkResearch(
                                researchId: item.id, fromDocumentId: docId) }
                        })
                    }
                }
                .listStyle(.sidebar)
                .dropDestination(for: String.self) { ids, _ in
                    for id in ids {
                        Task { try? await store.linkResearch(
                            researchId: id, toDocumentId: docId) }
                    }
                    return true
                }
            } else {
                ContentUnavailableView("No document selected",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a chapter or scene to see its linked research"))
            }
        }
        .sheet(isPresented: $showingLinkPicker) {
            ResearchLinkPickerSheet(
                store: store, documentId: activeDocumentId ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Linked Research").font(.headline)
            Spacer()
            Button {
                showingLinkPicker = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .disabled(activeDocumentId == nil)
            .help("Link research…")
        }
        .padding(8)
    }

    private func linkedItems(for docId: String) -> [ResearchItem] {
        let ids = store.linkedResearchIds(forDocumentId: docId)
        return store.resolveResearchLinks(ids)
    }
}
```

`LinkedResearchRow` renders the item title + an inline-expandable preview (text for `.document`-kind items, image for `.image`, URL for `.link`). Each row has an `×` for unlink and a chevron toggle for expand/collapse.

### `OutlinePane`

```swift
struct OutlinePane: View {
    @Bindable var store: ProjectStore
    @Binding var layout: OutlineLayout
    @Binding var selectedItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if layout == .table {
                OutlineTable(items: store.manifest.structure,
                             store: store,
                             selectedItemId: $selectedItemId)
            } else {
                CorkboardGrid(items: store.manifest.structure,
                              store: store,
                              selectedItemId: $selectedItemId)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Outline").font(.headline)
            Spacer()
            Picker("Layout", selection: $layout) {
                Image(systemName: "list.bullet").tag(OutlineLayout.table)
                Image(systemName: "rectangle.grid.2x2").tag(OutlineLayout.cards)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(8)
        .onChange(of: layout) { _, newValue in
            store.documentStore?.updateUIState { $0.outlineLayout = newValue }
        }
    }
}
```

- **`OutlineTable`**: SwiftUI `Table` rendering each `.document` item (recursing through groups) with columns: Title, Status (dot + label), Synopsis (truncated), Words. Click → sets `selectedItemId`.

- **`CorkboardGrid`**: `LazyVGrid` of index cards. Each card shows title, synopsis, status dot, word-count badge. Click → sets `selectedItemId`. Read-only in v1; inline edit is a polish pass.

### `ResearchLinkPickerSheet`

```swift
struct ResearchLinkPickerSheet: View {
    @Bindable var store: ProjectStore
    let documentId: String
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search research…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List {
                    ForEach(filteredItems()) { item in
                        HStack {
                            Image(systemName: iconName(for: item))
                            Text(item.title)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { isLinked(item.id) },
                                set: { newValue in toggleLink(item.id, link: newValue) }))
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Link Research")
        }
        .frame(minWidth: 500, minHeight: 400)
    }
    // helpers: filteredItems(), isLinked(_:), toggleLink(_:link:)
}
```

Live filter on `query`. Toggles call `linkResearch`/`unlinkResearch` instantly (no submit).

### `SyntaxHelpSheet` extended

```swift
struct SyntaxHelpSheet: View {
    let initialMode: SyntaxHelpMode
    @State private var selection: SyntaxHelpTab

    enum SyntaxHelpTab: String, Hashable {
        case markdown, fountain, keyboard
    }

    var body: some View {
        TabView(selection: $selection) {
            MarkdownHelpView()
                .tabItem { Text("Markdown") }
                .tag(SyntaxHelpTab.markdown)
            FountainHelpView()
                .tabItem { Text("Fountain") }
                .tag(SyntaxHelpTab.fountain)
            KeyboardCheatsheetView()
                .tabItem { Text("Keyboard") }
                .tag(SyntaxHelpTab.keyboard)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}
```

`KeyboardCheatsheetView` renders `KeyboardShortcuts.all` as section headers + two-column rows (label | monospaced shortcut text).

### Menu commands

In `MaughamApp.commands`:

```swift
CommandGroup(after: .toolbar) {
    Divider()
    Button("Inspector") { post(.maughamSetDetailSegment, value: "inspector") }
        .keyboardShortcut("1", modifiers: [.command, .option])
    Button("Linked Research") { post(.maughamSetDetailSegment, value: "research") }
        .keyboardShortcut("2", modifiers: [.command, .option])
    Button("Outline") { post(.maughamSetDetailSegment, value: "outline") }
        .keyboardShortcut("3", modifiers: [.command, .option])
}
```

ProjectWindow subscribes to `maughamSetDetailSegment`; on receipt, sets `showInspector = true` AND updates `detailSegment`.

### Drag-drop integration

Research items in the binder's Research segment need `.draggable(item.id)`. If the research polish milestone didn't already add this (it added drag-reorder, which uses different machinery), add it. The right-pane Research panel has `.dropDestination(for: String.self)` accepting dropped research IDs.

## Cross-cutting concerns

### Active document tracking

`LinkedResearchPane` receives `activeDocumentId: String?` derived from `selectedItemId` (manuscript). When the writer is editing a research note (not a manuscript chapter), the linked-research view shows the empty state — research-to-research linking is out of scope.

### Right-pane visibility

`showInspector: Bool` + `⌘⌥I Toggle Inspector` becomes the whole-pane visibility toggle. The per-mode shortcuts (`⌘⌥1/2/3`) implicitly show the pane (set `showInspector = true` before changing segment).

### Orphaned links

When a research item is deleted, its ID may remain in `linkedResearchIds` arrays. `resolveResearchLinks(_:)` filters orphans on read. No auto-cleanup; passive filtering is enough for now.

### Screenplay interactions

Outline pane shows manifest.structure as-is. For screenplays (single `.fountain` item), the outline shows one row — not as useful as for novels. Writers use the existing Scene Navigator binder segment for scene browsing. Deeper screenplay outline awareness is Phase 4a territory.

### Collection projects

Right pane is already hidden for `.collection` projects. No change.

### Word count freshness

Outline reads from `ProjectStore.cachedWordCount(for:)`. Documents that haven't been opened in the current session may have nil counts; display "—" instead of zero.

### Keyboard cheatsheet drift

The curated list in `KeyboardShortcuts.all` is hand-maintained. A unit test asserts the list is non-empty + contains expected categories, but doesn't verify it matches `MaughamApp.commands` (would require runtime introspection). Manual smoke before tagging verifies parity.

## Testing strategy

### Unit tests

- `LinkedResearchTests`:
  - `linkResearch` adds ID, idempotent on re-link
  - `unlinkResearch` removes ID, idempotent on unlink-of-absent
  - `linkedResearchIds(forDocumentId:)` returns persisted list
  - `resolveResearchLinks` returns existing items in order, skips orphans
- `UIStateDetailPersistenceTests`:
  - `detailSegment` round-trips through encode/decode
  - `outlineLayout` round-trips
  - Older UIState without the new fields decodes with defaults (`.inspector`, `.table`)
- `KeyboardShortcutsTests`:
  - `KeyboardShortcuts.all` is non-empty
  - Contains baseline categories (File, Edit, View, Help)

### Manual smoke before tagging

1. `⌘/` → help sheet shows Markdown / Fountain / Keyboard tabs; Keyboard tab lists shortcuts grouped by category with monospaced shortcut formatting.
2. Right pane has a 3-segment picker (Inspector / Research / Outline) at the top.
3. `⌘⌥1/2/3` switches segments instantly; pane shows if hidden.
4. `⌘⌥I` toggles whole pane visibility; segment selection persists across hide/show.
5. With a manuscript chapter active, switch to `.research` segment → empty state with `+ Add Link…` button.
6. Drag a research item from the binder's Research segment onto the right-pane Research panel → linked, appears in list.
7. Click `+ Add Link…` → picker sheet with search; toggle multiple items; close sheet; linked items appear in the panel.
8. Click `×` on a linked row → unlinks instantly.
9. Click a row's chevron → inline preview expands (note text / image / URL).
10. Switch to a different chapter → linked panel updates to the new doc's links.
11. Switch right pane to Outline → table layout shows chapters with title/synopsis/status/words columns.
12. Toggle to cards layout → same data, index-card grid.
13. Click an outline row/card → editor jumps to that document.
14. Reload project → `detailSegment` and `outlineLayout` restored from UIState.
15. Phase 3c + research-polish + find-replace features unaffected.

Target: 504 → ~520 tests passing (~16 new).

## Out of scope (deferred)

- **Bidirectional link surface** — ResearchItem doesn't show "linked from these chapters". Future "Backlinks" tab on the Inspector.
- **Outline drag-reorder** — binder already does this; Outline is read-only navigation.
- **Inline synopsis editing in Corkboard cards** — start read-only.
- **Outline search/filter** — table can sort by column; explicit filter is a polish pass.
- **Auto-cleanup of orphaned links** — passive filter on read is enough.
- **Screenplay scene-aware outline** — Phase 4a / outline-minimap territory.
- **Card customization** (color themes, status visualization).
- **Research-to-research linking** — manuscript→research only in v1.
