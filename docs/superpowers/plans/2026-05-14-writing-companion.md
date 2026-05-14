# Writing Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three connected QoL features — keyboard cheatsheet, research↔manuscript linking, structure views (Outliner + Corkboard) — bundled around a new right-pane mode-swap pattern (Inspector / Research / Outline).

**Architecture:** Data layer adds `StructureItem.linkedResearchIds: [String]?` + `DetailSegment` / `OutlineLayout` enums + UIState persistence. UI introduces `DetailPaneToggle` mirroring `BinderPaneToggle`'s segment-picker pattern. `LinkedResearchPane` shows linked research for the active manuscript document (drag-drop + picker sheet for adding). `OutlinePane` renders manifest.structure with table/cards layout toggle. `SyntaxHelpSheet` extended to a TabView with a new Keyboard tab listing curated shortcuts.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, `Table` for outliner, `LazyVGrid` for corkboard, `TabView` for help sheet.

**Reference spec:** `docs/superpowers/specs/2026-05-14-writing-companion-design.md`

---

## File map

**Create:**
- `Maugham/Models/DetailSegment.swift` — `DetailSegment` enum
- `Maugham/Models/OutlineLayout.swift` — `OutlineLayout` enum
- `Maugham/Resources/KeyboardShortcuts.swift` — curated shortcut catalog
- `Maugham/Views/DetailPaneToggle.swift` — right-pane picker + body switch
- `Maugham/Views/LinkedResearchPane.swift` — linked research for active doc
- `Maugham/Views/LinkedResearchRow.swift` — row with inline preview + unlink
- `Maugham/Views/ResearchLinkPickerSheet.swift` — `+ Add Link…` picker
- `Maugham/Views/OutlinePane.swift` — outline + layout toggle
- `Maugham/Views/OutlineTable.swift` — table layout
- `Maugham/Views/CorkboardGrid.swift` — cards layout
- `Maugham/Views/KeyboardCheatsheetView.swift` — Keyboard tab content
- `MaughamTests/LinkedResearchTests.swift`
- `MaughamTests/UIStateDetailPersistenceTests.swift`
- `MaughamTests/KeyboardShortcutsTests.swift`

**Modify:**
- `Maugham/Models/StructureItem.swift` — add `linkedResearchIds: [String]?`
- `Maugham/Stores/UIState.swift` — add `detailSegment` + `outlineLayout`
- `Maugham/Stores/ProjectStore.swift` — add link/unlink/resolve APIs
- `Maugham/Models/MaughamNotifications.swift` — `maughamSetDetailSegment`
- `Maugham/MaughamApp.swift` — `⌘⌥1/2/3` menu commands
- `Maugham/Views/ProjectWindow.swift` — replace `inspectorPane` with `DetailPaneToggle`, add `detailSegment` State, subscribe to `maughamSetDetailSegment`
- `Maugham/Views/SyntaxHelpSheet.swift` — refactor to `TabView` with Markdown / Fountain / Keyboard tabs
- `Maugham/Views/ResearchView.swift` — make research items `.draggable(item.id)` if not already

---

## Phase 1 — Data layer

### Task 1: `StructureItem.linkedResearchIds` + ProjectStore link APIs

**Files:**
- Modify: `Maugham/Models/StructureItem.swift`
- Modify: `Maugham/Stores/ProjectStore.swift`
- Test: `MaughamTests/LinkedResearchTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/LinkedResearchTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class LinkedResearchTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedResearch-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Chapter 1 content\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Sarah\n".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document,
            path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store)
    }

    func test_linkResearch_addsIdToDocument() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let ids = store.linkedResearchIds(forDocumentId: "ch-1")
        XCTAssertEqual(ids, ["res-sarah"])
    }

    func test_linkResearch_isIdempotent() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let ids = store.linkedResearchIds(forDocumentId: "ch-1")
        XCTAssertEqual(ids, ["res-sarah"])
    }

    func test_unlinkResearch_removesId() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        try await store.unlinkResearch(researchId: "res-sarah", fromDocumentId: "ch-1")
        let ids = store.linkedResearchIds(forDocumentId: "ch-1")
        XCTAssertEqual(ids, [])
    }

    func test_unlinkResearch_idempotentOnAbsent() async throws {
        let (_, store) = try await makeProject()
        // Never linked → unlink is a no-op
        try await store.unlinkResearch(researchId: "res-sarah", fromDocumentId: "ch-1")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [])
    }

    func test_resolveResearchLinks_returnsItemsInOrder() async throws {
        let (_, store) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let resolved = store.resolveResearchLinks(["res-sarah"])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].id, "res-sarah")
        XCTAssertEqual(resolved[0].title, "Sarah")
    }

    func test_resolveResearchLinks_skipsOrphans() async throws {
        let (_, store) = try await makeProject()
        let resolved = store.resolveResearchLinks(["res-sarah", "missing-id", "also-missing"])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].id, "res-sarah")
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/LinkedResearchTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Add `linkedResearchIds` to StructureItem**

In `Maugham/Models/StructureItem.swift`, add to the struct + init:

```swift
public struct StructureItem {
    // ...existing fields
    public var linkedResearchIds: [String]?  // NEW
}
```

In the init param list, add `linkedResearchIds: [String]? = nil` as the last param. In the init body, add `self.linkedResearchIds = linkedResearchIds`.

The existing `Codable` synthesis picks up the new optional field; older manifests round-trip cleanly with `linkedResearchIds == nil`.

- [ ] **Step 4: Add ProjectStore link APIs**

In `Maugham/Stores/ProjectStore.swift`, add (place near other manuscript-mutation methods, like `addStructureItem` around line 148):

```swift
/// Link a research item to a manuscript document. Idempotent.
public func linkResearch(
    researchId: String, toDocumentId documentId: String
) async throws {
    var changed = false
    Self.applyLinkMutation(
        documentId: documentId,
        in: &manifest.structure
    ) { item in
        var ids = item.linkedResearchIds ?? []
        if !ids.contains(researchId) {
            ids.append(researchId)
            item.linkedResearchIds = ids
            changed = true
        }
    }
    if changed {
        manifest.modified = Date()
        try await saveManifest()
    }
}

/// Remove a research link. Idempotent.
public func unlinkResearch(
    researchId: String, fromDocumentId documentId: String
) async throws {
    var changed = false
    Self.applyLinkMutation(
        documentId: documentId,
        in: &manifest.structure
    ) { item in
        if var ids = item.linkedResearchIds, let idx = ids.firstIndex(of: researchId) {
            ids.remove(at: idx)
            item.linkedResearchIds = ids.isEmpty ? nil : ids
            changed = true
        }
    }
    if changed {
        manifest.modified = Date()
        try await saveManifest()
    }
}

/// IDs of research items linked to the given document.
public func linkedResearchIds(forDocumentId documentId: String) -> [String] {
    Self.findItemLinks(documentId: documentId, in: manifest.structure) ?? []
}

/// Resolve a research-id list to actual ResearchItems, skipping orphans.
public func resolveResearchLinks(_ ids: [String]) -> [ResearchItem] {
    ids.compactMap { id in findResearchItem(id: id, in: manifest.research) }
}

private static func applyLinkMutation(
    documentId: String,
    in items: inout [StructureItem],
    transform: (inout StructureItem) -> Void
) {
    for i in 0..<items.count {
        if items[i].id == documentId {
            transform(&items[i])
            return
        }
        if var children = items[i].children {
            applyLinkMutation(documentId: documentId, in: &children, transform: transform)
            items[i].children = children
        }
    }
}

private static func findItemLinks(
    documentId: String, in items: [StructureItem]
) -> [String]? {
    for item in items {
        if item.id == documentId { return item.linkedResearchIds ?? [] }
        if let children = item.children,
           let nested = findItemLinks(documentId: documentId, in: children) {
            return nested
        }
    }
    return nil
}
```

(`findResearchItem(id:in:)` already exists from research-polish milestone.)

- [ ] **Step 5: Run targeted + full**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/LinkedResearchTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 6 tests, with 0 failures`.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 510 tests, with 0 failures` (504 prior + 6 new).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/StructureItem.swift Maugham/Stores/ProjectStore.swift MaughamTests/LinkedResearchTests.swift
git commit -m "feat: StructureItem.linkedResearchIds + ProjectStore link APIs

Additive optional field on StructureItem for unidirectional links
from manuscript documents to research items. linkResearch /
unlinkResearch / linkedResearchIds / resolveResearchLinks are
idempotent and orphan-tolerant (resolveResearchLinks skips IDs
that no longer exist in manifest.research).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `DetailSegment` + `OutlineLayout` + UIState

**Files:**
- Create: `Maugham/Models/DetailSegment.swift`
- Create: `Maugham/Models/OutlineLayout.swift`
- Modify: `Maugham/Stores/UIState.swift`
- Test: `MaughamTests/UIStateDetailPersistenceTests.swift`

- [ ] **Step 1: Write failing tests**

Create `MaughamTests/UIStateDetailPersistenceTests.swift`:

```swift
import XCTest
@testable import Maugham

final class UIStateDetailPersistenceTests: XCTestCase {
    func test_detailSegment_roundTrip() throws {
        let state = UIState(
            selectedItemId: nil,
            isNoChromeOn: false,
            binderSegment: .manuscript,
            detailSegment: .research,
            outlineLayout: .table)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.detailSegment, .research)
    }

    func test_outlineLayout_roundTrip() throws {
        let state = UIState(
            selectedItemId: nil,
            isNoChromeOn: false,
            binderSegment: .manuscript,
            detailSegment: .inspector,
            outlineLayout: .cards)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.outlineLayout, .cards)
    }

    func test_olderUIState_decodesWithDefaults() throws {
        // Pre-companion UIState JSON (no detailSegment / outlineLayout fields)
        let raw = """
        {
          "schemaVersion": 1,
          "isNoChromeOn": false,
          "binderSegment": "manuscript",
          "researchPreviewVisible": false
        }
        """
        let decoded = try JSONDecoder().decode(
            UIState.self, from: raw.data(using: .utf8)!)
        XCTAssertEqual(decoded.detailSegment, .inspector)
        XCTAssertEqual(decoded.outlineLayout, .table)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/UIStateDetailPersistenceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Create the enums**

Create `Maugham/Models/DetailSegment.swift`:

```swift
import Foundation

/// Which mode the right pane displays.
public enum DetailSegment: String, Codable, Equatable, Sendable {
    case inspector
    case research
    case outline
}
```

Create `Maugham/Models/OutlineLayout.swift`:

```swift
import Foundation

/// Visual layout of the Outline pane: table vs index cards.
public enum OutlineLayout: String, Codable, Equatable, Sendable {
    case table
    case cards
}
```

- [ ] **Step 4: Extend UIState**

In `Maugham/Stores/UIState.swift`, add the two new fields. Read the existing structure first; the file has `isNoChromeOn: Bool`, `binderSegment: BinderSegment`, and likely `researchPreviewVisible: Bool` (from research-polish) — match that pattern.

```swift
public struct UIState: Codable, Equatable, Sendable {
    // ...existing fields
    public var detailSegment: DetailSegment        // NEW
    public var outlineLayout: OutlineLayout        // NEW

    public init(
        // ...existing init params
        detailSegment: DetailSegment = .inspector,
        outlineLayout: OutlineLayout = .table
    ) {
        // ...existing assignments
        self.detailSegment = detailSegment
        self.outlineLayout = outlineLayout
    }

    // If UIState has a Decodable init that uses optional decode-with-default
    // patterns (look at how isNoChromeOn handles older state), mirror it:
    enum CodingKeys: String, CodingKey {
        // existing cases
        case detailSegment, outlineLayout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // existing decodes
        self.detailSegment =
            (try? c.decode(DetailSegment.self, forKey: .detailSegment)) ?? .inspector
        self.outlineLayout =
            (try? c.decode(OutlineLayout.self, forKey: .outlineLayout)) ?? .table
    }
}
```

(The actual file may or may not have an explicit `init(from:)` — if it relies on Codable synthesis, you'll need to add an explicit decoder to provide the defaults for missing keys. Match what's there.)

- [ ] **Step 5: Run targeted + full**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/UIStateDetailPersistenceTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 3 tests, with 0 failures`.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 513 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/DetailSegment.swift Maugham/Models/OutlineLayout.swift Maugham/Stores/UIState.swift MaughamTests/UIStateDetailPersistenceTests.swift
git commit -m "feat: DetailSegment + OutlineLayout enums + UIState persistence

DetailSegment (.inspector/.research/.outline) drives the new
right-pane segment picker. OutlineLayout (.table/.cards) drives
the Outline pane's internal layout toggle. Both round-trip via
UIState; older state without the fields decodes with defaults
(.inspector + .table).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Right pane scaffolding

### Task 3: `DetailPaneToggle` + ProjectWindow integration

**Files:**
- Create: `Maugham/Views/DetailPaneToggle.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Create DetailPaneToggle**

Create `Maugham/Views/DetailPaneToggle.swift`:

```swift
import SwiftUI

struct DetailPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedItemId: String?
    let activeManuscriptItemId: String?

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
                case .inspector:
                    inspectorPlaceholder
                case .research:
                    LinkedResearchPane(
                        store: store,
                        activeDocumentId: activeManuscriptItemId)
                case .outline:
                    OutlinePane(
                        store: store,
                        layout: $outlineLayout,
                        selectedItemId: $selectedItemId)
                }
            }
        }
        .onChange(of: segment) { _, newValue in
            store.documentStore?.updateUIState { $0.detailSegment = newValue }
        }
    }

    /// Placeholder until ProjectWindow's existing InspectorView call site is
    /// moved here in a follow-up step within this task.
    private var inspectorPlaceholder: some View {
        Text("Inspector lives here")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

(The `LinkedResearchPane` and `OutlinePane` references will be unresolved until T5 and T8 — that's expected; this task is scaffolding. The placeholder for Inspector is replaced in Step 2 below.)

- [ ] **Step 2: Wire DetailPaneToggle in ProjectWindow + move InspectorView call site**

In `Maugham/Views/ProjectWindow.swift`:

1. Add `@State private var detailSegment: DetailSegment = .inspector` and `@State private var outlineLayout: OutlineLayout = .table` near other `@State`.

2. Hydrate from UIState in `load()`:
   ```swift
   detailSegment = documentStore.uiState.detailSegment
   outlineLayout = documentStore.uiState.outlineLayout
   ```

3. Find `private func inspectorPane(store:)` (around line 426). Replace its body to use `DetailPaneToggle`:
   ```swift
   private func inspectorPane(store: ProjectStore) -> some View {
       DetailPaneToggle(
           store: store,
           segment: $detailSegment,
           outlineLayout: $outlineLayout,
           selectedItemId: $selectedItemId,
           activeManuscriptItemId: selectedItemId)
   }
   ```

4. Replace the `inspectorPlaceholder` in `DetailPaneToggle` (created in Step 1) with the actual InspectorView call. Move the contents of the original `inspectorPane(store:)`'s `InspectorView(...)` invocation into DetailPaneToggle. The simplest approach: pass through any additional bindings InspectorView needs as parameters to DetailPaneToggle.

Look at the existing InspectorView call to see its parameters. Likely something like:
```swift
InspectorView(
    store: store,
    selectedItemId: $selectedItemId,
    metrics: metrics)  // or similar
```

Add the corresponding parameters to `DetailPaneToggle` and pass them through:
```swift
struct DetailPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedItemId: String?
    let activeManuscriptItemId: String?
    // Inspector pass-through:
    let metrics: EditorMetrics  // or whatever InspectorView needs

    // ...

    case .inspector:
        InspectorView(
            store: store,
            selectedItemId: $selectedItemId,
            metrics: metrics)
}
```

Update the call site in ProjectWindow accordingly.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD FAIL — `LinkedResearchPane` and `OutlinePane` don't exist yet. That's expected; we'll add stubs next so this task can land.

- [ ] **Step 4: Add placeholder stubs for LinkedResearchPane and OutlinePane**

Create `Maugham/Views/LinkedResearchPane.swift`:

```swift
import SwiftUI

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?

    var body: some View {
        Text("Linked Research (T5)")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Create `Maugham/Views/OutlinePane.swift`:

```swift
import SwiftUI

struct OutlinePane: View {
    @Bindable var store: ProjectStore
    @Binding var layout: OutlineLayout
    @Binding var selectedItemId: String?

    var body: some View {
        Text("Outline (T8)")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 5: Build + run full suite**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 513 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/DetailPaneToggle.swift Maugham/Views/LinkedResearchPane.swift Maugham/Views/OutlinePane.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: DetailPaneToggle scaffolding for right-pane segments

Mirrors BinderPaneToggle. Picker at top (Inspector / Research /
Outline) with body switch. Inspector branch wraps existing
InspectorView. Research and Outline branches use placeholder
views that T5 and T8 fill in. detailSegment State hydrates from
UIState on load; changes write back via documentStore.updateUIState.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `⌘⌥1/2/3` menu commands

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Add notification**

In `Maugham/Models/MaughamNotifications.swift`:

```swift
public static let maughamSetDetailSegment = Notification.Name("maugham.set.detail.segment")
```

- [ ] **Step 2: Add menu commands**

In `Maugham/MaughamApp.swift`, find the `CommandGroup(after: .toolbar)` block (the one with Toggle Focus Mode, Toggle Full-Screen Focus, etc.). Add inside it:

```swift
Divider()
Button("Inspector") {
    NotificationCenter.default.post(
        name: .maughamSetDetailSegment,
        object: nil,
        userInfo: ["segment": "inspector"])
}
.keyboardShortcut("1", modifiers: [.command, .option])
Button("Linked Research") {
    NotificationCenter.default.post(
        name: .maughamSetDetailSegment,
        object: nil,
        userInfo: ["segment": "research"])
}
.keyboardShortcut("2", modifiers: [.command, .option])
Button("Outline") {
    NotificationCenter.default.post(
        name: .maughamSetDetailSegment,
        object: nil,
        userInfo: ["segment": "outline"])
}
.keyboardShortcut("3", modifiers: [.command, .option])
```

- [ ] **Step 3: ProjectWindow subscribes**

In `Maugham/Views/ProjectWindow.swift`, add an `.onReceive` (use SessionAndNavigationModifier if body complexity bites):

```swift
.onReceive(NotificationCenter.default.publisher(
    for: .maughamSetDetailSegment)) { note in
    guard let raw = note.userInfo?["segment"] as? String,
          let seg = DetailSegment(rawValue: raw) else { return }
    showInspector = true     // ensure pane is visible
    detailSegment = seg
}
```

- [ ] **Step 4: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 513 tests, with 0 failures`.

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: ⌘⌥1/2/3 menu commands switch right-pane segment

Inspector / Linked Research / Outline bound to ⌘⌥1/2/3 in the
View menu. Posts maughamSetDetailSegment with the raw value;
ProjectWindow listens, sets showInspector = true (revealing the
pane if hidden), then updates detailSegment.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Research mode

### Task 5: `LinkedResearchPane` (real implementation)

**Files:**
- Modify: `Maugham/Views/LinkedResearchPane.swift`
- Create: `Maugham/Views/LinkedResearchRow.swift`

- [ ] **Step 1: Replace stub with real LinkedResearchPane**

Replace contents of `Maugham/Views/LinkedResearchPane.swift`:

```swift
import SwiftUI

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?
    @State private var showingLinkPicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingLinkPicker) {
            if let docId = activeDocumentId {
                ResearchLinkPickerSheet(store: store, documentId: docId)
            }
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

    @ViewBuilder
    private var content: some View {
        if let docId = activeDocumentId {
            let items = linkedItems(for: docId)
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No linked research", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Drag research items here, or use the + button.")
                }
            } else {
                List {
                    ForEach(items) { item in
                        LinkedResearchRow(item: item) {
                            Task {
                                try? await store.unlinkResearch(
                                    researchId: item.id,
                                    fromDocumentId: docId)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        } else {
            ContentUnavailableView {
                Label("No document selected", systemImage: "doc.text")
            } description: {
                Text("Select a chapter or scene to see its linked research")
            }
        }
    }

    private func linkedItems(for docId: String) -> [ResearchItem] {
        let ids = store.linkedResearchIds(forDocumentId: docId)
        return store.resolveResearchLinks(ids)
    }
}
```

- [ ] **Step 2: Create LinkedResearchRow**

Create `Maugham/Views/LinkedResearchRow.swift`:

```swift
import SwiftUI
import AppKit

struct LinkedResearchRow: View {
    let item: ResearchItem
    let onUnlink: () -> Void

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.body)
                Spacer()
                if isExpandable {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onUnlink) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unlink")
            }
            if expanded {
                preview
                    .padding(.leading, 24)
            }
        }
    }

    private var iconName: String {
        switch item.kind {
        case .document: return "doc.text"
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .audio:    return "waveform"
        case .link:     return "link"
        case .none:     return "folder"
        }
    }

    private var isExpandable: Bool {
        item.kind == .document || item.kind == .image || item.kind == .link
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .document:
            if let path = item.path,
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        case .image:
            if let path = item.path,
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
            }
        case .link:
            if let urlStr = item.url {
                Text(urlStr)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        default:
            EmptyView()
        }
    }
}
```

(Note: `ResearchLinkPickerSheet` reference in LinkedResearchPane will be unresolved until T6. Add a stub or block the sheet behind a `#if false` until T6 lands. Easier: add a temporary placeholder ResearchLinkPickerSheet at the end of LinkedResearchPane.swift that T6 will replace:)

```swift
// Temporary stub — T6 replaces with real picker
struct ResearchLinkPickerSheet: View {
    @Bindable var store: ProjectStore
    let documentId: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Text("Picker (T6)")
            Button("Done") { dismiss() }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 150)
    }
}
```

Move this stub to its own file `Maugham/Views/ResearchLinkPickerSheet.swift` so T6 can replace it cleanly.

- [ ] **Step 3: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 513 tests, with 0 failures`.

```bash
git add Maugham/Views/LinkedResearchPane.swift Maugham/Views/LinkedResearchRow.swift Maugham/Views/ResearchLinkPickerSheet.swift
git commit -m "feat: LinkedResearchPane shows linked items with inline previews

Header with title + plus-button (opens picker — T6 wires it).
List of linked research with per-row unlink × and chevron to
expand inline preview (note text, image, or URL). Empty state
prompts to drag-drop or use the + button. ContentUnavailableView
when no manuscript doc is active.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `ResearchLinkPickerSheet` (real implementation)

**Files:**
- Modify: `Maugham/Views/ResearchLinkPickerSheet.swift`

- [ ] **Step 1: Replace stub with real picker**

Replace contents:

```swift
import SwiftUI

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
                        row(for: item)
                    }
                }
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle("Link Research")
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func row(for item: ResearchItem) -> some View {
        HStack {
            Image(systemName: iconName(for: item))
                .foregroundStyle(.secondary)
            Text(item.title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isLinked(item.id) },
                set: { newValue in toggleLink(item.id, link: newValue) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func iconName(for item: ResearchItem) -> String {
        switch item.kind {
        case .document: return "doc.text"
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .audio:    return "waveform"
        case .link:     return "link"
        case .none:     return "folder"
        }
    }

    private func isLinked(_ id: String) -> Bool {
        store.linkedResearchIds(forDocumentId: documentId).contains(id)
    }

    private func toggleLink(_ id: String, link: Bool) {
        Task {
            if link {
                try? await store.linkResearch(researchId: id, toDocumentId: documentId)
            } else {
                try? await store.unlinkResearch(researchId: id, fromDocumentId: documentId)
            }
        }
    }

    private func filteredItems() -> [ResearchItem] {
        let all = flatten(store.manifest.research)
        if query.isEmpty { return all }
        let lower = query.lowercased()
        return all.filter { $0.title.lowercased().contains(lower) }
    }

    private func flatten(_ items: [ResearchItem]) -> [ResearchItem] {
        var out: [ResearchItem] = []
        for item in items {
            out.append(item)
            if let children = item.children {
                out.append(contentsOf: flatten(children))
            }
        }
        return out
    }
}
```

- [ ] **Step 2: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 513 tests, with 0 failures`.

```bash
git add Maugham/Views/ResearchLinkPickerSheet.swift
git commit -m "feat: ResearchLinkPickerSheet with search + toggle links

Modal sheet shows full research tree flattened with a search box.
Each row has a switch that toggles linked state for the given
document. Live filter on title (case-insensitive substring). Done
dismisses; linking happens instantly via toggle, no Apply step.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Drag-drop links from binder Research segment

**Files:**
- Modify: `Maugham/Views/ResearchView.swift` — confirm `.draggable(item.id)` is on research rows
- Modify: `Maugham/Views/LinkedResearchPane.swift` — add `.dropDestination`

- [ ] **Step 1: Verify research rows are draggable**

```bash
grep -n "draggable" /Users/denver/src/Maugham/Maugham/Views/ResearchView.swift /Users/denver/src/Maugham/Maugham/Views/ResearchRow.swift 2>&1 | head
```

If `.draggable(item.id)` is already on research rows (likely from research-polish drag-reorder work), no change needed.

If not, add to the row body in `ResearchView.swift` or `ResearchRow.swift`:

```swift
.draggable(item.id) {
    Text(item.title)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
}
```

- [ ] **Step 2: Add drop destination to LinkedResearchPane**

In `Maugham/Views/LinkedResearchPane.swift`, in `content`'s `if let docId = activeDocumentId { if items.isEmpty { ... } else { ... } }`, attach `.dropDestination(for: String.self)` to both the empty-state ContentUnavailableView and the populated List:

```swift
// In both branches:
.dropDestination(for: String.self) { ids, _ in
    for id in ids {
        Task {
            try? await store.linkResearch(
                researchId: id, toDocumentId: docId)
        }
    }
    return true
}
```

Wrap both branches in a common container if cleaner, e.g., factor the dropDestination onto a parent VStack.

- [ ] **Step 3: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 513 tests, with 0 failures`.

```bash
git add Maugham/Views/ResearchView.swift Maugham/Views/ResearchRow.swift Maugham/Views/LinkedResearchPane.swift
git commit -m "feat: drag research from binder onto LinkedResearchPane to link

LinkedResearchPane accepts dropped research IDs and calls
store.linkResearch for each. Drop works on both the empty state
and the populated list. ResearchView rows already had .draggable
from research-polish drag-reorder; reuse it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Outline mode

### Task 8: `OutlinePane` with layout toggle

**Files:**
- Modify: `Maugham/Views/OutlinePane.swift`

- [ ] **Step 1: Replace stub with real OutlinePane**

Replace contents:

```swift
import SwiftUI

struct OutlinePane: View {
    @Bindable var store: ProjectStore
    @Binding var layout: OutlineLayout
    @Binding var selectedItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.manifest.structure.isEmpty {
                ContentUnavailableView {
                    Label("No items yet", systemImage: "list.bullet.indent")
                } description: {
                    Text("Add chapters or scenes from the Manuscript binder")
                }
            } else if layout == .table {
                OutlineTable(
                    items: flattenDocs(store.manifest.structure),
                    store: store,
                    selectedItemId: $selectedItemId)
            } else {
                CorkboardGrid(
                    items: flattenDocs(store.manifest.structure),
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

    /// Flatten manifest.structure to document items only, recursing through
    /// groups. Used by both OutlineTable and CorkboardGrid.
    private func flattenDocs(_ items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            switch item.type {
            case .document: out.append(item)
            case .group:
                if let children = item.children {
                    out.append(contentsOf: flattenDocs(children))
                }
            }
        }
        return out
    }
}
```

(`OutlineTable` and `CorkboardGrid` are stubbed in T9 and T10 below — define minimal stubs here so this file compiles standalone.)

Add placeholder stubs at the bottom of OutlinePane.swift (will move to separate files in T9/T10):

```swift
// Temporary stubs — T9 and T10 replace
struct OutlineTable: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    var body: some View { Text("Table (T9)") }
}

struct CorkboardGrid: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    var body: some View { Text("Cards (T10)") }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

```bash
git add Maugham/Views/OutlinePane.swift
git commit -m "feat: OutlinePane scaffolding with layout toggle

Header with title + layout-toggle picker (table/cards). Body
switches on layout. Empty state when manifest.structure is
empty. Flattens groups recursively to document-only items.
OutlineTable and CorkboardGrid stubs will be filled in by T9
and T10.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `OutlineTable` (table layout)

**Files:**
- Create: `Maugham/Views/OutlineTable.swift`
- Modify: `Maugham/Views/OutlinePane.swift` — remove the inline stub

- [ ] **Step 1: Create OutlineTable**

Create `Maugham/Views/OutlineTable.swift`:

```swift
import SwiftUI

struct OutlineTable: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?

    var body: some View {
        Table(items, selection: $selectedItemId) {
            TableColumn("Title") { item in
                Text(item.title)
            }
            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(item.status))
                        .frame(width: 6, height: 6)
                    Text(item.status ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("Synopsis") { item in
                Text(item.synopsis ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Words") { item in
                if let count = store.cachedWordCount(for: item.id) {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }
}
```

- [ ] **Step 2: Remove stub from OutlinePane.swift**

In `Maugham/Views/OutlinePane.swift`, delete the temporary `struct OutlineTable` stub at the bottom (keep `CorkboardGrid` stub).

- [ ] **Step 3: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 513 tests, with 0 failures`.

```bash
git add Maugham/Views/OutlineTable.swift Maugham/Views/OutlinePane.swift
git commit -m "feat: OutlineTable — table layout with Title/Status/Synopsis/Words

SwiftUI Table with 4 columns. Title is the document title.
Status renders the status dot + label (mirrors the binder
convention). Synopsis is one-line-truncated. Words reads from
ProjectStore.cachedWordCount; nil shows '—'. Click row → updates
selectedItemId, which the editor pane picks up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `CorkboardGrid` (cards layout)

**Files:**
- Create: `Maugham/Views/CorkboardGrid.swift`
- Modify: `Maugham/Views/OutlinePane.swift` — remove inline stub

- [ ] **Step 1: Create CorkboardGrid**

Create `Maugham/Views/CorkboardGrid.swift`:

```swift
import SwiftUI

struct CorkboardGrid: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 180), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    card(for: item)
                }
            }
            .padding(12)
        }
    }

    private func card(for item: StructureItem) -> some View {
        Button {
            selectedItemId = item.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(statusColor(item.status))
                        .frame(width: 8, height: 8)
                }
                if let synopsis = item.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No synopsis")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 4)
                HStack {
                    Spacer()
                    if let count = store.cachedWordCount(for: item.id) {
                        Text("\(count) words")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .frame(minHeight: 140, maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selectedItemId == item.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selectedItemId == item.id ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }
}
```

- [ ] **Step 2: Remove stub from OutlinePane.swift**

Delete the temporary `struct CorkboardGrid` stub at the bottom of OutlinePane.swift.

- [ ] **Step 3: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 513 tests, with 0 failures`.

```bash
git add Maugham/Views/CorkboardGrid.swift Maugham/Views/OutlinePane.swift
git commit -m "feat: CorkboardGrid — index-card layout

LazyVGrid with adaptive columns (min 180pt). Each card shows
title (bold), status dot in the top-right, synopsis (up to 6
lines), word count badge in bottom-right. Selected card has
an accent-colored border. Click → updates selectedItemId.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Keyboard cheatsheet

### Task 11: `KeyboardShortcuts` catalog + cheatsheet view

**Files:**
- Create: `Maugham/Resources/KeyboardShortcuts.swift`
- Create: `Maugham/Views/KeyboardCheatsheetView.swift`
- Test: `MaughamTests/KeyboardShortcutsTests.swift`

- [ ] **Step 1: Write failing test**

Create `MaughamTests/KeyboardShortcutsTests.swift`:

```swift
import XCTest
@testable import Maugham

final class KeyboardShortcutsTests: XCTestCase {
    func test_all_isNonEmpty() {
        XCTAssertFalse(KeyboardShortcuts.all.isEmpty)
    }

    func test_all_containsBaselineCategories() {
        let names = Set(KeyboardShortcuts.all.map(\.category))
        XCTAssertTrue(names.contains("File"))
        XCTAssertTrue(names.contains("Edit"))
        XCTAssertTrue(names.contains("View"))
        XCTAssertTrue(names.contains("Help"))
    }

    func test_each_category_has_at_least_one_entry() {
        for category in KeyboardShortcuts.all {
            XCTAssertFalse(category.items.isEmpty,
                "category \(category.category) is empty")
        }
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/KeyboardShortcutsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: COMPILE FAIL.

- [ ] **Step 3: Create the catalog**

Create `Maugham/Resources/KeyboardShortcuts.swift`:

```swift
import Foundation

/// Curated catalog of keyboard shortcuts surfaced via the Help → Syntax
/// Reference sheet's Keyboard tab. Hand-maintained; manual smoke at tag
/// time verifies parity with MaughamApp.commands.
public enum KeyboardShortcuts {
    public struct Category {
        public let category: String
        public let items: [Entry]
    }
    public struct Entry {
        public let label: String
        public let shortcut: String
    }

    public static let all: [Category] = [
        Category(category: "File", items: [
            Entry(label: "New Project…",            shortcut: "⌘N"),
            Entry(label: "Open Project…",            shortcut: "⌘O"),
            Entry(label: "Save",                     shortcut: "⌘S"),
            Entry(label: "Project Settings…",        shortcut: "⌘⇧,"),
        ]),
        Category(category: "Edit", items: [
            Entry(label: "Find in Editor",           shortcut: "⌘F"),
            Entry(label: "Find Next",                shortcut: "⌘G"),
            Entry(label: "Find Previous",            shortcut: "⌘⇧G"),
            Entry(label: "Find in Project…",         shortcut: "⌘⌥F"),
            Entry(label: "Restore Last Deleted Item",shortcut: "⌘⌥Z"),
        ]),
        Category(category: "View", items: [
            Entry(label: "Toggle Focus Mode",        shortcut: "⌘\\"),
            Entry(label: "Toggle Full-Screen Focus", shortcut: "⌘⇧F"),
            Entry(label: "Toggle Inspector",         shortcut: "⌘⌥I"),
            Entry(label: "Inspector mode",           shortcut: "⌘⌥1"),
            Entry(label: "Linked Research mode",     shortcut: "⌘⌥2"),
            Entry(label: "Outline mode",             shortcut: "⌘⌥3"),
            Entry(label: "Toggle Research Preview",  shortcut: "⌘⇧P"),
        ]),
        Category(category: "Help", items: [
            Entry(label: "Syntax Reference",         shortcut: "⌘/"),
        ]),
    ]
}
```

(If `File → Add Research File…` or `Show Project Statistics` are in commands with shortcuts I missed, add them. Look at `MaughamApp.swift` for the actual set. Adjust shortcuts to match real bindings.)

- [ ] **Step 4: Create KeyboardCheatsheetView**

Create `Maugham/Views/KeyboardCheatsheetView.swift`:

```swift
import SwiftUI

struct KeyboardCheatsheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(KeyboardShortcuts.all, id: \.category) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.category)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(category.items, id: \.label) { item in
                                HStack {
                                    Text(item.label)
                                        .font(.body)
                                    Spacer()
                                    Text(item.shortcut)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.secondary.opacity(0.1)))
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
```

- [ ] **Step 5: Run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: `Executed 516 tests, with 0 failures`.

```bash
git add Maugham/Resources/KeyboardShortcuts.swift Maugham/Views/KeyboardCheatsheetView.swift MaughamTests/KeyboardShortcutsTests.swift
git commit -m "feat: KeyboardShortcuts catalog + KeyboardCheatsheetView

Curated list of every Maugham shortcut grouped by category (File,
Edit, View, Help). Cheatsheet view renders sections with two-
column rows (label + monospaced chip). Tests cover non-empty
catalog and baseline category coverage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Extend `SyntaxHelpSheet` to TabView with Keyboard tab

**Files:**
- Modify: `Maugham/Views/SyntaxHelpSheet.swift`

- [ ] **Step 1: Refactor SyntaxHelpSheet**

Read the existing file. It probably has:
- An enum `SyntaxHelpMode` (`.markdown`, `.fountain`)
- A `mode: SyntaxHelpMode` property
- A body that renders one doc (Markdown or Fountain) based on mode

Refactor to a TabView. The `SyntaxHelpMode` becomes `initialMode` controlling which tab is selected on open:

```swift
import SwiftUI

public enum SyntaxHelpMode {
    case markdown
    case fountain
}

public struct SyntaxHelpSheet: View {
    let initialMode: SyntaxHelpMode
    @State private var selectedTab: Tab
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, Hashable {
        case markdown, fountain, keyboard
    }

    public init(mode: SyntaxHelpMode) {
        self.initialMode = mode
        switch mode {
        case .markdown: self._selectedTab = State(initialValue: .markdown)
        case .fountain: self._selectedTab = State(initialValue: .fountain)
        }
    }

    public var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                MarkdownHelpView()
                    .tabItem { Text("Markdown") }
                    .tag(Tab.markdown)
                FountainHelpView()
                    .tabItem { Text("Fountain") }
                    .tag(Tab.fountain)
                KeyboardCheatsheetView()
                    .tabItem { Text("Keyboard") }
                    .tag(Tab.keyboard)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle("Reference")
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

/// Markdown reference rendered from the existing markdown-syntax.md resource.
private struct MarkdownHelpView: View {
    var body: some View {
        // Reuse the existing rendering code from the prior single-mode sheet.
        // The previous body had a switch on mode that read markdown-syntax.md
        // for prose mode — move that branch's rendering into here verbatim.
        // ...(existing markdown rendering)
    }
}

/// Fountain reference rendered from the existing fountain-syntax.md resource.
private struct FountainHelpView: View {
    var body: some View {
        // Existing fountain rendering — move from the prior single-mode body.
        // ...(existing fountain rendering)
    }
}
```

(Look at the existing SyntaxHelpSheet's body and extract the per-mode rendering into MarkdownHelpView and FountainHelpView. The two new private wrappers are the same logic, just split.)

- [ ] **Step 2: Build + run + commit**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```
Expected: BUILD SUCCEEDED. `Executed 516 tests, with 0 failures`.

```bash
git add Maugham/Views/SyntaxHelpSheet.swift
git commit -m "feat: SyntaxHelpSheet becomes TabView with Keyboard tab

Refactor the single-mode sheet to a TabView with Markdown /
Fountain / Keyboard tabs. initialMode picks which tab is
pre-selected when opened via ⌘/. Existing prose-vs-screenplay
mode detection in ProjectWindow keeps working (picks the tab,
doesn't pick the doc).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Smoke + tag

### Task 13: Final smoke + tag

- [ ] **Manual smoke checklist**

Build:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Verify:
1. `⌘/` → help sheet has Markdown / Fountain / Keyboard tabs. Keyboard tab lists shortcuts grouped by category with monospaced chips.
2. Right pane has a 3-segment picker (info / search / list icons) at the top.
3. `⌘⌥1` → Inspector mode. `⌘⌥2` → Linked Research. `⌘⌥3` → Outline.
4. `⌘⌥I` toggles whole pane visibility; segment selection persists across hide/show.
5. With a manuscript chapter active, switch to Research segment → empty state with `+` button and drag-drop prompt.
6. Drag a research item from the binder onto the right-pane Research panel → linked, appears in list with title + icon.
7. Click `+ Add Link…` → picker sheet with search field; toggle a few items; close; linked items appear.
8. Click `×` on a linked row → unlinked instantly.
9. Click row's chevron → inline preview expands (note text / image / URL).
10. Switch to a different chapter → linked panel updates to the new doc's links.
11. Switch right pane to Outline → table layout shows chapters with title/status/synopsis/words columns.
12. Toggle to cards layout → same data, index-card grid.
13. Click a row in the table → editor jumps to that doc. Click a card → same.
14. Quit + reopen project → `detailSegment` and `outlineLayout` restored from UIState.
15. Older project (no `linkedResearchIds`, no `detailSegment` in UIState) opens cleanly with `.inspector` + `.table` defaults.
16. Phase 3c, research-polish, find-replace features unaffected.

Verify Keyboard cheatsheet content matches actual menu shortcuts in `MaughamApp.swift`. Flag drift.

- [ ] **Push + tag**

```bash
git checkout main
git merge --ff-only feat/milestone-writing-companion
git tag -a milestone-writing-companion -m "Writing Companion — Group 1

Three QoL features tied by the right-pane mode-swap pattern:
- Keyboard shortcuts cheatsheet (new 'Keyboard' tab in ⌘/ sheet)
- Research↔manuscript linking (Inspector / Research / Outline
  segment picker on the right pane; drag-drop + picker sheet)
- Structure views (Outline pane with table + cards layouts)

DetailSegment + OutlineLayout enums persist via UIState. ⌘⌥1/2/3
switches segments. StructureItem.linkedResearchIds optional field
holds links; orphan filtering on read.

~516 tests passing."
git push origin main
git push origin milestone-writing-companion
```

- [ ] **Update memory**

Create `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_writing_companion.md` capturing the milestone + API surface + carry-forwards.

Add entry to MEMORY.md index.

---

## Spec coverage check

| Spec section | Covered by task(s) |
|---|---|
| `StructureItem.linkedResearchIds` field | T1 |
| ProjectStore link APIs (link/unlink/IDs/resolve) | T1 |
| DetailSegment + OutlineLayout enums | T2 |
| UIState round-trip + default fallback | T2 |
| Notifications (`maughamSetDetailSegment`) | T4 |
| DetailPaneToggle scaffolding | T3 |
| ⌘⌥1/2/3 menu commands + ProjectWindow subscriber | T4 |
| LinkedResearchPane (with empty states + previews) | T5 |
| LinkedResearchRow (inline previews, unlink) | T5 |
| ResearchLinkPickerSheet (search + toggle links) | T6 |
| Drag-drop from binder to LinkedResearchPane | T7 |
| OutlinePane scaffolding + layout toggle | T8 |
| OutlineTable (table layout) | T9 |
| CorkboardGrid (cards layout) | T10 |
| KeyboardShortcuts catalog | T11 |
| KeyboardCheatsheetView | T11 |
| SyntaxHelpSheet TabView with Keyboard tab | T12 |
| Smoke + tag | T13 |

Total task count: 13.
Test count target: 504 → ~516 (12 new across L1, L2, L11).
