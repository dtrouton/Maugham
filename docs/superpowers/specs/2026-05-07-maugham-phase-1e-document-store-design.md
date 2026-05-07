# Maugham Phase 1e — DocumentStore + Conflict Resolution Design Spec

**Anchor:** This spec implements the *file foundation* slice of Phase 1's remaining deliverables (master design Section 3) plus the `.maugham/ui-state.json` persistence mentioned in Section 3's "What doesn't go through the store" subsection. The orthogonal *project expansion* slice (Novel binder, inspector, project types) shipped as milestone 1d.

**Goal:** Wrap the open-document path in `NSFileCoordinator` + `NSFilePresenter` so iCloud, Claude Desktop, Finder, or any other process can touch the project folder without losing user edits. Add a 750ms autosave debounce in place of the current keystroke-by-keystroke writes. Detect external changes to the open document and present a non-blocking *Outside change detected* banner with **Keep mine** / **Use cloud** actions; the loser is preserved under `.maugham/conflicts/` until the user resolves. Persist UI state (selected document, no-chrome flag, scroll position) to `.maugham/ui-state.json` so reopening a project restores the user's previous workspace.

After 1e, Maugham is iCloud-safe and shareable. A user can edit *Chapter 3* in Maugham on one Mac while iCloud syncs an updated version from another, and Maugham surfaces the conflict cleanly instead of silently overwriting.

---

## Out of scope (deferred to later milestones)

| Feature | Lands in |
|---|---|
| "Show diff" view inside conflict banner | Phase 2 |
| Snapshots (`snapshots/<timestamp>-<label>.zip`) | Phase 5 |
| Per-file `NSFilePresenter` registration (we use one coarse-grained presenter on the project folder) | n/a — coarse-grained is the design |
| Full filesystem-touchpoint refactor of `ProjectFactory` and `ProjectStore.add/rename/delete` | n/a — those keep direct calls; rationale below |

---

## Architecture

```
                    ProjectWindow
                          |
                EditorHost  InspectorView  BinderView
                       \\        |          /
                        \\       |         /
                         v      v        v
                         +-----------------+
                         |  DocumentStore  |   <-- NEW, owns the open
                         +--------+--------+       document & manifest I/O
                                  |
                   ┌──────────────┼──────────────┐
                   v              v              v
           ManifestActor   OpenDocument    ProjectFolderPresenter
           (atomic JSON     (.md/.fountain  (NSFilePresenter on
            read/write,      reads/writes,   project URL — receives
            via coordinator) via coordinator) iCloud/Finder events)

           ProjectStore                    ProjectFactory
           (mutation API,                  (one-shot creation,
            calls into                      direct FS calls — NOT
            DocumentStore for save)         through DocumentStore)
```

`DocumentStore` is a new `@MainActor @Observable` type owned by `ProjectWindow` and shared with views via Environment. Created by `DocumentStore.open(url:)` which loads the manifest, registers an `NSFilePresenter` on the project folder, and reads `.maugham/ui-state.json` (or seeds defaults). Disposed on window close, which unregisters the presenter and synchronously flushes any pending save.

`ProjectStore` becomes the structure-mutation API only: `addStructureItem`, `renameStructureItem`, `deleteStructureItem`, `updateInspector`, `setProjectTypography` keep their direct FS calls (these run once per UI event and don't race with iCloud — adding coordination there would be theatre). But ProjectStore now holds a reference to its `DocumentStore` so it can flush the manifest *through the coordinator* when it saves.

`ProjectFolderPresenter` is a private inner class of DocumentStore conforming to `NSFilePresenter`. Implements `presentedItemDidChange()`, `presentedSubitemDidAppear(at:)`, and `presentedSubitemDidChange(at:)`. Routes events to DocumentStore on the main actor.

`ProjectFactory` is unchanged. It runs once at project creation, before any presenter is active, and writes a fixed set of files into a fresh folder. Adding NSFileCoordinator there would buy nothing — there's no other process holding the folder.

---

## DocumentStore — public API

```swift
@MainActor
@Observable
public final class DocumentStore {

    // MARK: - Lifecycle

    public static func open(url: URL) async throws -> DocumentStore
    public func close() async  // synchronous flush of pending save + presenter unregister

    // MARK: - Open document

    /// The path of the document currently bound to the editor, or nil.
    public private(set) var openDocumentPath: String?

    /// Last text the editor wrote to disk via this store. Used to distinguish
    /// "external changed" from "our own save echoed back".
    public private(set) var lastWrittenText: String = ""

    /// Bind the editor to a new document. Reads from disk, updates state,
    /// flushes any pending save for the previously-open document.
    public func openDocument(at path: String) async throws -> String

    /// Schedule a save with the 750ms debounce. Restarts the timer if called
    /// again within that window.
    public func scheduleSave(for path: String, text: String)

    /// Cancel the debounce timer and save immediately. Called by ⌘S and on close.
    public func flushPendingSave() async throws

    // MARK: - Manifest

    /// Coordinated atomic manifest write. Replaces the direct write in
    /// ProjectStore.saveManifest.
    public func writeManifest(_ data: Data) async throws

    /// Coordinated read for project setup paths that don't load via ProjectStore.
    public func readManifest() async throws -> Data

    // MARK: - Conflict

    /// Set when an external change is detected while the user has unsaved
    /// edits. Cleared on resolution.
    public private(set) var pendingConflict: ConflictState?

    public func resolveConflictKeepMine() async throws
    public func resolveConflictUseCloud() async throws

    // MARK: - UI state

    /// Loaded from .maugham/ui-state.json on open; nil-defaulted if absent.
    public private(set) var uiState: UIState

    /// Schedule a 500ms-debounced write of `.maugham/ui-state.json`.
    public func updateUIState(_ transform: (inout UIState) -> Void)
}
```

### State machine for conflict detection

When `presentedSubitemDidChange(at: url)` fires for the currently-open document:

```
┌─────────────────────────────┐
│ Disk text == lastWrittenText │   YES   ┌──────────────────────────┐
│ ?                            │ ──────> │ No-op (our own write     │
└──────────────┬──────────────┘         │ echoing back through      │
               │ NO                      │ NSFilePresenter)          │
               v                         └──────────────────────────┘
┌──────────────────────────────┐
│ documentText == lastWrittenText│  YES   ┌──────────────────────────┐
│ (no pending edits)?            │──────> │ Case A: silent reload.   │
└──────────────┬─────────────────┘        │ Update lastWrittenText.  │
               │ NO                       │ Post documentReloaded.   │
               v                          └──────────────────────────┘
┌──────────────────────────────┐
│ User has unsaved edits.       │
│ Case B: capture both versions │
│ in pendingConflict. Cancel    │
│ autosave timer.               │
└───────────────────────────────┘
```

For `project.maugham.json` (Case C):

```
┌──────────────────────────────────────────────────────────┐
│ Compare disk manifest's `modified` to in-memory's.       │
└──────────────────────┬───────────────────────────────────┘
                       │
       ┌───────────────┴───────────────┐
       v                               v
┌──────────────┐              ┌─────────────────────────────┐
│ Disk newer:  │              │ In-memory newer or equal:   │
│ copy local   │              │ no-op (next coordinated     │
│ to .maugham/ │              │ write will overwrite disk). │
│ conflicts/   │              └─────────────────────────────┘
│ manifest-ISO │
│ .json,       │
│ reload from  │
│ disk.        │
└──────────────┘
```

---

## Save model: autosave debounce + ⌘S flush

EditorHost replaces:

```swift
// 1d (current — every keystroke writes synchronously to disk):
set: { newValue in
    documentText = newValue
    saveDocument(path: path, text: newValue)   // writes immediately
    onTextChange?(newValue)
}
```

with:

```swift
// 1e:
set: { newValue in
    documentText = newValue
    documentStore.scheduleSave(for: path, text: newValue)
    onTextChange?(newValue)
}
```

`scheduleSave` cancels any prior pending Task, then starts a new one:

```swift
public func scheduleSave(for path: String, text: String) {
    pendingSaveTask?.cancel()
    pendingSavePath = path
    pendingSaveText = text
    pendingSaveTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(750))
        if Task.isCancelled { return }
        try? await self?.performSave(path: path, text: text)
    }
}
```

`flushPendingSave` is what `⌘S` calls (via `maughamDummySave` notification, already wired in 1c):

```swift
public func flushPendingSave() async throws {
    guard let path = pendingSavePath, let text = pendingSaveText else { return }
    pendingSaveTask?.cancel()
    try await performSave(path: path, text: text)
}
```

`performSave` is the only direct-write path, gated behind NSFileCoordinator:

```swift
private func performSave(path: String, text: String) async throws {
    let url = projectURL.appendingPathComponent(path)
    let coordinator = NSFileCoordinator(filePresenter: presenter)
    var coordError: NSError?
    var saveError: Error?
    coordinator.coordinate(
        writingItemAt: url, options: .forReplacing, error: &coordError
    ) { writeURL in
        do {
            try text.data(using: .utf8)?.write(to: writeURL, options: [.atomic])
            self.lastWrittenText = text
            self.lastWrittenAt = Date()
        } catch {
            saveError = error
        }
    }
    if let coordError { throw coordError }
    if let saveError { throw saveError }
}
```

---

## ConflictBanner UX

```
┌──────────────────────────────────────────────────────────────────────┐
│ ⚠ Outside change detected. Your version (143 words ahead) and the    │
│   cloud version are different.                                       │
│   [ Keep mine ]   [ Use cloud ]    [ Show diff (Phase 2) — disabled ]│
└──────────────────────────────────────────────────────────────────────┘
```

SwiftUI view, rendered in ProjectWindow as `.safeAreaInset(edge: .top)` on the editor pane (above the text, full width, sticky). Visible only when `documentStore.pendingConflict != nil`. The user keeps editing while the banner is visible — the master spec is explicit that the notice is non-blocking.

The "(143 words ahead)" string is computed by comparing `documentText` and `externalText` word counts using `ProseMode.metrics` (or `ScreenplayMode.metrics` for `.fountain` files) — `localCount - externalCount` clamped to a positive number, with phrasing flipped if the external is ahead.

### Resolution actions

**Keep mine** — `documentStore.resolveConflictKeepMine()`:
1. Write `pendingConflict.localText` to `path` through the coordinator.
2. Copy `pendingConflict.externalText` to `.maugham/conflicts/<NN-slug>-cloud-<ISO8601>.<ext>`.
3. Clear `pendingConflict`.

**Use cloud** — `documentStore.resolveConflictUseCloud()`:
1. Copy `pendingConflict.localText` to `.maugham/conflicts/<NN-slug>-local-<ISO8601>.<ext>`.
2. The disk already has `externalText`; update `lastWrittenText = externalText`.
3. Post `documentStore.documentReloaded` (an internal signal — EditorHost listens via `.onChange(of: documentStore.lastWrittenText)`); EditorHost re-binds to the external text.
4. Clear `pendingConflict`.

`.maugham/` directory is created on first conflict write if absent.

### Show diff (disabled)

Rendered as a third button with `.disabled(true)` and a `.help("Available in Phase 2")` tooltip. Surfaces the future feature without committing to it now.

---

## UI state persistence

New file: `.maugham/ui-state.json`. Schema:

```json
{
  "schemaVersion": 1,
  "selectedItemId": "doc-a3f8b9...",
  "isNoChromeOn": false,
  "scrollLine": 0
}
```

Maugham reads this at `DocumentStore.open(url:)`. Returns a `UIState.empty` default if the file is absent, malformed, or has a schema version we don't recognise (forward-compat).

ProjectWindow seeds its `selectedItemId` and `isNoChromeOn` from `documentStore.uiState` before the user sees the window. EditorSurface receives an additional optional `initialScrollLine: Int?` parameter that, when non-nil, scrolls to that line on first layout.

Updates are debounced 500ms via:

```swift
documentStore.updateUIState { state in
    state.selectedItemId = newSelection
}
```

The transform mutates a draft copy in-memory; a 500ms-debounced Task writes the JSON to disk through the coordinator.

`scrollLine` rather than `scrollOffset` because line-based positioning is robust across font/typography changes (a user changes font size from 17 to 22, "where I was" stays meaningful as line 47, not as offset 1234.5pt).

---

## Migration from 1d

Six 1d filesystem touchpoints get rerouted; one stays.

| 1d location | 1e treatment |
|---|---|
| `ProjectStore.saveManifest()` direct atomic write | Routes through `documentStore.writeManifest(data)` |
| `ProjectStore.load(...)` direct manifest read | Direct read still — runs before DocumentStore exists |
| `ProjectStore.addStructureItem` file create | Direct write (one-shot, no race window) |
| `ProjectStore.renameStructureItem` mv | Direct mv (one-shot) |
| `ProjectStore.deleteStructureItem` recycle | Direct recycle (one-shot) |
| `EditorHost.loadDocumentIfNeeded()` direct read | Routes through `documentStore.openDocument(at: path)` |
| `EditorHost.saveDocument(...)` direct write | Routes through `documentStore.scheduleSave(for:text:)` |
| `ProjectFactory.*` writes | Unchanged (project creation, before presenter exists) |

The single 1d file with the deepest behaviour change is `EditorHost.swift`, where the synchronous-on-keystroke save becomes a debounced async path.

`ProjectStore` gains a `weak documentStore: DocumentStore?` property set by ProjectWindow at open time. Manifest writes call `documentStore.writeManifest(...)` if the reference is live, else fall back to the 1d direct write path (which is needed for the brief window during `ProjectStore.load(...)` before DocumentStore is constructed).

---

## Testing strategy

### Pure logic — TDD, ~12 new tests

- `UIStateTests`: Codable roundtrip, malformed JSON falls back to empty, unknown schemaVersion falls back to empty, `.empty` defaults match spec.
- `ConflictStateTests`: Equality, "(N words ahead)" phrasing computation for local-ahead, external-ahead, equal cases.
- `DebounceSchedulerTests`: Helper that wraps the cancel-and-restart Task pattern; tested in isolation so DocumentStore can use it without re-implementing.

### Integration — real temp dir + real NSFileCoordinator, ~10 tests

- `DocumentStoreOpenCloseTests`: open creates store, reads UI state if present; close flushes pending save, unregisters presenter (verify by attempting another open immediately).
- `DocumentStoreSaveTests`: scheduleSave fires after 750ms, restarts on rapid edits, flushPendingSave forces immediate write.
- `DocumentStoreConflictTests`: simulate external write by directly touching the file (a separate `try Data().write(to: url)` while DocumentStore is registered as presenter). Assert `pendingConflict` materialises with correct local/external text and modifiedAt. Cover Case A (no pending edits → silent reload), Case B (pending edits → conflict). Case C tested separately with manifest.
- `ConflictResolutionTests`: Keep mine writes loser to `.maugham/conflicts/<...>-cloud-<ISO8601>.md` with timestamp ≈ now; manifest path file ends up with local content. Use cloud is the mirror.
- `ManifestConflictTests`: directly write a newer manifest to disk; presenter fires; in-memory copy preserved at `.maugham/conflicts/manifest-<ISO8601>.json`; new manifest loaded.

### Smoke-build — UI integration

- `ConflictBanner` SwiftUI rendering
- `EditorHost` integration with documentStore
- `ProjectWindow` wiring (DocumentStore creation in `load()`, Environment injection, banner placement, ConflictBanner action plumbing)

### Manual smoke at T-end

12 steps:

1. Open a project. Verify the editor still works (autosave is invisible to the user).
2. Type a sentence; wait ~1s; in Finder verify the file's modified date updated.
3. Type a sentence; close the project window immediately (don't wait for debounce); reopen; verify the sentence is there.
4. ⌘S while typing → "Saved" flash; in Finder verify the file's modified date updated to *now*, not 750ms in the future.
5. With Maugham open, edit the manuscript file via Terminal: `printf 'external edit\n' > path/to/file.md`. Banner appears: "Outside change detected".
6. Click **Keep mine**. Banner disappears. File on disk now has *your* version. `.maugham/conflicts/<file>-cloud-*.md` contains the terminal edit.
7. Repeat the conflict scenario. Click **Use cloud**. Editor swaps to the external content. `.maugham/conflicts/<file>-local-*.md` contains your version.
8. Edit a manifest field by ⌘-clicking `project.maugham.json` in Finder, opening with TextEdit, changing `title`, save. Maugham reloads silently (no banner; manifest conflict path).
9. With Maugham editing a chapter, open the same project file in TextEdit, edit, save. Maugham presents the banner. Either resolution is correct.
10. Switch documents in the binder. Close the window. Reopen. The same document is selected.
11. Toggle no-chrome (⌘\\). Close the window. Reopen. No-chrome state is restored.
12. Force-quit Maugham (Activity Monitor) mid-edit. Reopen. Up to 750ms of unsaved edits may be lost — that's acceptable; the autosave debounce was running. Verify nothing else is corrupt.

---

## Files (created or modified)

```
Maugham/Stores/
  DocumentStore.swift                   # NEW — top-level coordinator + presenter + save/UI debouncers
  ProjectFolderPresenter.swift          # NEW — private NSFilePresenter inner type
  ConflictState.swift                   # NEW — value type, Equatable/Sendable
  UIState.swift                         # NEW — Codable struct for .maugham/ui-state.json
  ProjectStore.swift                    # MODIFIED — saveManifest goes through DocumentStore
  ProjectFactory.swift                  # unchanged

Maugham/Views/
  ConflictBanner.swift                  # NEW — banner UI with Keep/Use buttons
  EditorHost.swift                      # MODIFIED — uses documentStore.openDocument/scheduleSave
  ProjectWindow.swift                   # MODIFIED — owns DocumentStore, renders ConflictBanner

Maugham/MaughamApp.swift                # unchanged

MaughamTests/
  UIStateTests.swift                    # NEW
  ConflictStateTests.swift              # NEW
  DebounceSchedulerTests.swift          # NEW (helper extracted from DocumentStore)
  DocumentStoreOpenCloseTests.swift     # NEW (integration)
  DocumentStoreSaveTests.swift          # NEW (integration)
  DocumentStoreConflictTests.swift      # NEW (integration)
  ConflictResolutionTests.swift         # NEW (integration)
  ManifestConflictTests.swift           # NEW (integration)
```

5 new main-target files, 8 new test files (3 unit + 5 integration), 3 modified main files, 0 modified test files. Estimate: 14–18 tasks for execution.

---

## Open questions for plan-writing

1. The 750ms debounce should probably be cancellable on `applicationWillTerminate` so we get a final flush. SwiftUI has a `@Environment(\.scenePhase)` that delivers `.background` on app quit. Plan should wire this.
2. When `closeDocument` is called (window close, switch documents), the current document's pending save needs synchronous flush. Plan should explicitly use `await flushPendingSave()` on the path-switch in EditorHost.
3. The `ConflictBanner`'s "143 words ahead" wording requires deciding the WritingMode for the open document. Plan should pull this from `WritingModeFactory.mode(for: path).metrics(text)` rather than re-implementing word count.
4. `lastWrittenText` initial value: when a document is first opened, set to disk contents so an immediate external change before the user types correctly classifies as Case A (silent reload) not Case B (conflict).
5. UI state is per-project, but `selectedItemId` may reference a deleted item if the project was modified externally between sessions. Plan should validate the saved selection against current `manifest.structure` and fall back to first document if not found.
