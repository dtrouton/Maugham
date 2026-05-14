# Maugham — Cross-Document Find/Replace Design

**Status:** approved 2026-05-14
**Group:** 1 — Editing flow polish
**Follows:** milestone-research-polish

## Goal

Two complementary find/replace surfaces:

- **In-doc find** (`⌘F`): re-enable NSTextView's built-in find bar so the writer can search within the active document with native UX — match navigation, replace, case toggle, all included.
- **Cross-doc find** (`⌘⌥F`): a new "Find" binder segment that searches across all manuscript items and research notes simultaneously, with results grouped by document and per-row + bulk replace.

Scope is **manuscript + research-note text only**. Trash, inspector tags, binder titles, synopses, and image-kind research assets are not searched.

## Architecture

Two surfaces share one substrate:

- **In-doc find**: flip `MaughamTextView.usesFindBar` from false to true. AppKit handles the UI, navigation, undo, and selection highlighting natively. `⌘F` opens the bar; `⌘G` next; `⌘⇧G` previous. Zero custom code beyond the flag (and verifying the scroll view parents the find bar correctly).

- **Cross-doc find**: a new `ProjectSearchEngine` value type walks all manuscript + research document paths from `manifest.structure` and `manifest.research`, reads each `.md` / `.fountain` file, and emits `SearchMatch` records. Results are exposed observably on `ProjectStore` for the Find view to bind to. A new conditional `BinderSegment.find` case (4th segment, mirroring trash) hosts the `ProjectSearchView` — search field at the top, options toggles, results grouped by document, per-row Replace + top-level Replace All.

- Clicking a result opens the document in the editor and scrolls to / highlights the match range. The existing per-doc autosave handles post-replace writes.

Cross-cutting:
- `⌘⌥F` opens the cross-doc find segment + focuses the search field (`⌘⇧F` stays as Toggle Full-Screen Focus).
- Replace operations write through `DocumentStore` — autosave + conflict scoping preserved.
- Find indexing is in-memory; no on-disk cache. Fine for projects under a few hundred docs.

## Data model

### `SearchMatch`, `SearchResults`, `SearchOptions`

```swift
public struct SearchMatch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentPath: String      // "manuscript/01-chapter-1.md"
    public let documentTitle: String     // From the manifest item
    public let documentSource: SearchDocumentSource  // .manuscript / .research
    public let lineNumber: Int           // 1-indexed
    public let charRangeInDocument: NSRange  // Whole-doc offset
    public let linePreview: String       // Line text (possibly truncated; see below)
    public let matchRangeInLine: NSRange // Range within linePreview to highlight
}

public enum SearchDocumentSource: Sendable {
    case manuscript
    case research
}

public struct SearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool = false
    public var wholeWord: Bool = false
}

public struct SearchResults: Equatable, Sendable {
    public let query: String
    public let options: SearchOptions
    public let matches: [SearchMatch]    // Sorted by (source, path, lineNumber)

    public var matchCount: Int { matches.count }
    public var documentCount: Int { Set(matches.map(\.documentPath)).count }
}
```

### `ProjectSearchEngine`

```swift
@MainActor
public struct ProjectSearchEngine {
    public init() {}

    /// Search all manuscript + research documents under projectURL.
    /// Honors task cancellation between documents.
    public func search(
        query: String,
        options: SearchOptions,
        in store: ProjectStore
    ) async -> SearchResults
}
```

Walks both trees:
1. Manuscript: `store.manifest.structure` recursively flat-walked, only `.document`-type items with a `path`.
2. Research: `store.manifest.research` recursively flat-walked, only `.document`-kind items with a `path` ending in `.md`.

For each document:
- Read file contents from disk (after a pre-search flush — see below).
- Split by `\n`.
- For each line, regex-match the query with appropriate options.
- Emit `SearchMatch` entries.
- `await Task.yield()` between documents so cancellation can interrupt.

Search runs on a detached priority-userInitiated Task from the UI; the result lands on MainActor.

### Wiring into `ProjectStore`

```swift
public private(set) var currentSearch: SearchResults?
public private(set) var searchInProgress: Bool = false

public func performSearch(query: String, options: SearchOptions) async
public func clearSearch()
public func replaceMatch(_ match: SearchMatch, with replacement: String) async throws
public func replaceAll(in results: SearchResults, with replacement: String) async throws
```

`performSearch` cancels any in-flight Task, debounces 300ms, flushes pending writes for the active doc, runs the engine, updates `currentSearch` on MainActor. Setting `currentSearch` triggers Observable view updates.

### Pre-search flush for active-doc freshness

The active editor doc may have unsaved changes (within the 750ms autosave window). Before search runs:

```swift
try? await documentStore?.flushPendingSave()
```

Search always reads from disk → simple, correct. Adds ~10ms per search; acceptable for 300ms-debounced live search.

### Match options applied

- **caseSensitive: false (default)**: `String.range(of:options:)` with `.caseInsensitive`. Foundation's localized matching handles Unicode folding.
- **caseSensitive: true**: same without `.caseInsensitive`.
- **wholeWord: true**: regex match with `\b<escaped-query>\b`. Query is regex-escaped via `NSRegularExpression.escapedPattern(for:)` so `.`/`*`/`?` in the user's query are treated literally.
- **wholeWord: false**: plain `String.range(of:)` — faster, no regex compile.

### Replace semantics

**Single match**:
1. Load the file via DocumentStore.
2. Slice content on `match.charRangeInDocument`, splice in replacement.
3. Save via DocumentStore.
4. Re-run `performSearch` so results refresh.

**Replace all**: groups matches by document, applies all per-document replacements **right-to-left** (highest `location` first) so earlier offsets don't shift. Each document saved once via DocumentStore.

## UI components

### `ProjectSearchView` (new SwiftUI view)

Rendered as the body of `BinderSegment.find`. Top-down:

```swift
VStack(spacing: 0) {
    SearchHeader(
        query: $query,
        options: $options,
        replacement: $replacement,
        matchCount: results?.matchCount ?? 0,
        documentCount: results?.documentCount ?? 0,
        onReplaceAll: ...,
        onClose: { findActive = false })

    Divider()

    if searchInProgress { ProgressView() }
    else if let r = results, !r.matches.isEmpty {
        ResultsList(results: r, replacement: replacement, onTapMatch: ..., onReplaceMatch: ...)
    } else if !query.isEmpty {
        Text("No matches").foregroundStyle(.secondary)
    } else {
        Text("Type to search across manuscript and research")
            .foregroundStyle(.tertiary)
    }
}
```

**`SearchHeader`**:
- Search field bound to `query: String`, focused on appear via `@FocusState`
- Replace field bound to `replacement: String` (collapsible — `> Replace…` disclosure)
- Toggle row: case sensitive, whole word
- Match count badge: "N matches in M documents"
- Replace All button (disabled when query/results empty), triggers confirmation modal
- Close (X) button to dismiss the Find segment

**`ResultsList`**:
- Grouped by source (Manuscript first, then Research)
- Within each source, grouped by document — `Section` per doc with title + match count in header
- Each row: line number gutter + line preview with the matched range highlighted (`AttributedString` background tint), trailing per-row Replace button (icon)
- Click row → posts `maughamFindMatchSelected` notification

**Live debounce**: `query` changes drive a `Task` that cancels the prior task, sleeps 300ms, then calls `store.performSearch`. Same pattern for `options` toggle changes.

### `BinderPaneToggle` extension

Add `.find` conditionally:

```swift
Picker("Segment", selection: $segment) {
    // ...existing cases (manuscript/research/scenes/trash)
    if findActive {
        Text("Find").tag(BinderSegment.find)
    }
}

switch segment {
case .manuscript: BinderView(...)
case .research:   ResearchView(...)
case .scenes:     SceneNavigatorPane(...)
case .trash:      TrashView(...)
case .find:       ProjectSearchView(store: store, isActive: $findActive)
}
```

`findActive: Bool` is `@State` on `ProjectWindow`. Set true when `⌘⌥F` fires; reset false when the Find tab's close button is hit — coercing `segment` back to `.manuscript` (mirroring the trash-empties pattern).

### Editor jump-to-match

When the user clicks a result row:

1. `ProjectSearchView` posts `maughamFindMatchSelected` with the `SearchMatch`.
2. `ProjectWindow` subscribes. On receipt: looks up the StructureItem (or ResearchItem) whose `path == match.documentPath`; sets `selectedItemId` or `selectedResearchId` accordingly. Existing editor-load machinery picks it up.
3. After document load completes (one runloop tick via `Task { @MainActor in await Task.yield(); ... }`), the editor coordinator scrolls the textView to `match.charRangeInDocument` and `setSelectedRange` to highlight the match using NSTextView's native selection highlight.

### `⌘⌥F` menu command + Edit menu integration

In `MaughamApp.commands`:

```swift
CommandGroup(after: .textFormatting) {
    Button("Find in Project…") {
        NotificationCenter.default.post(
            name: .maughamFindInProject, object: nil)
    }
    .keyboardShortcut("f", modifiers: [.command, .option])
}
```

In `ProjectWindow`, subscribe to `maughamFindInProject`: `findActive = true`, `segment = .find`. The search field's `@FocusState` autofocuses on Find segment appearance.

NSTextView's built-in find bar handles its own `⌘F` — Maugham only needs `usesFindBar = true`. AppKit auto-populates the Edit → Find submenu.

### Match-row preview highlight

```swift
private func highlightedLine(_ line: String, range: NSRange) -> AttributedString {
    var attr = AttributedString(line)
    if let r = Range(range, in: attr) {
        attr[r].backgroundColor = .yellow.opacity(0.4)
    }
    return attr
}
```

## Cross-cutting concerns

### Find-while-editing

After search runs, results are static. Editing in the editor afterwards doesn't auto-rerun. The writer triggers re-search by changing the query, toggling options, or just re-typing. Avoids cursor-jumpy chaos.

### Conflict resolution mid-search

If `NSFilePresenter` reports an external change mid-search, the search Task simply re-reads on the next debounce. Results may briefly reflect old content; not worth complicating.

### Performance ceiling

A long-haul novel: ~100 chapters × ~5,000 words ≈ ~500k characters total. Walking + matching on Apple Silicon completes in well under 100ms. We don't need an index; full-walk per search is fine. If a future project breaks the ceiling, we add an in-memory inverted index later.

### Long-line preview truncation

`linePreview` truncated to ~120 characters centered on the match, with `…` markers on either end when truncated. `matchRangeInLine` is recomputed against the truncated string.

### Replace introduces new matches

Replace `foo` → `foo bar` then re-search surfaces the introduced `bar` if it matches the next query. No recursion in `replaceAll` itself; the engine just runs again after writes.

## Out of scope (deferred)

- **Regex queries** — possible future polish pass; current `wholeWord` is the only internal regex use.
- **Multi-line / newline-spanning** queries — line-based only in v1.
- **Search history / saved searches**.
- **Fuzzy matching**.
- **Match highlight in binder rows** — only in find results.
- **Scoped search** (e.g., "only this act", "only research") — search is everything-or-nothing for v1.
- **Search in trash, inspector tags, binder titles, synopses, image-kind research assets** — explicitly excluded.

## Testing strategy

### Unit tests

- `ProjectSearchEngineTests` — fixture project with 3 manuscript docs + 2 research notes. Verify match counts, ordering, line numbers, char ranges, source-grouping. Tests for case-sensitive on/off and whole-word on/off behaviors. Edge: query with regex-special chars (`.`, `*`, `?`) is treated literally.
- `ProjectSearchReplaceTests` — single-match replace, replace-all, replace-with-empty (deletion), right-to-left ordering preserves later-doc offsets, replace in research and manuscript.
- `SearchMatchHighlightTests` — `highlightedLine(_:range:)` returns AttributedString with the right range marked, including the long-line truncation behavior.

### Integration tests

- `SearchInEditorJumpTests` — perform a search, simulate click on a result, verify `selectedItemId`/`selectedResearchId` updates correctly (NSTextView geometry isn't tested; the navigation side is).
- `SearchFreshnessTests` — write text to active doc via DocumentStore, call performSearch, verify the new text is in results (proves the flush-before-search works end-to-end).

### Manual smoke before tagging

1. `⌘F` in editor → NSTextView find bar appears; type a word; navigate next/previous; replace works inline.
2. `⌘⌥F` → binder switches to Find segment, search field focused.
3. Type a word → results appear after 300ms debounce, grouped by doc with line previews + highlighted match ranges.
4. Toggle case-sensitive / whole word → results refresh.
5. Click a result → editor opens that doc (manuscript or research), scrolls to match, native NSTextView selection highlights the match.
6. Per-row Replace icon → that one match replaced; results refresh; doc autosaves.
7. Replace All → confirmation modal → all matches across all docs replaced.
8. Search a word that exists in both manuscript and research → both sections appear.
9. Search for empty query → results clear; placeholder shown.
10. Trashed docs are NOT searched.
11. Phase 1c features still work (focus mode, typewriter scroll, etc.); Phase 1b features (themes, fonts) unaffected.
12. Phase 3c screenplay features unaffected.

Target: 486 → ~498 tests passing (~12 new).
