# Editor — Area guide

This is the most fragile area in the codebase. Three cursor races in 24 hours during the 3d window all lived here. Read this before editing anything in `Maugham/Editor/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The NSTextView-backed editing surface: text storage, tokenization, styling, cursor management, smart typography substitution, find-match navigation, focus dimming, image-paste routing, wiki-link hit-testing, Tab-element cycling (screenplay), and the SwiftUI bridge that exposes it as a binding to the rest of the app.

## Layout

- `EditorSurface.swift` — `NSViewRepresentable` wrapping `NSTextView`. The SwiftUI-side boundary.
- `EditorHost.swift` — owns the document-text binding for the surface. Three onChange handlers (`$documentText`, `lastWrittenText`, `priorStoredMarkdown`) form a triad that is **load-bearing and brittle**. See tripwire #1 below.
- `EditorCoordinator.swift` (~770 lines) — `NSTextViewDelegate` implementation. The "central nervous system." Tokenizes, applies styles, manages cursor, handles Tab-cycle for screenplay, smart-quote / em-dash substitution, find-match scrolling, focus-dim, image paste routing, wiki-link `[[…]]` hit-testing.
- `Fountain/` — screenplay parser + per-element styling.
  - `ScreenplayMode.applyTypography` does **full-storage** `setAttributes` (not incremental). Known race-window contributor; don't add work inside it.
  - `ScreenplayLayoutManager` exists but display-uppercase for forced sluglines/characters is the **option-A fallback** intentionally (display-time uppercase rejected for cursor-positioning reasons). Don't "fix" it without rethinking the approach.
- `Tokenizer/` — prose-side tokenizer + style application.
- `CharacterAutocompleter.swift` — **DEAD CODE**. `updateAutocomplete` is defined but never called. NSPopover was abandoned in 3b ("too brittle, blocks input"). Don't wire it back without redesigning the UX (popover → inline ghost-text or sheet, TBD).

## The load-bearing triad in EditorHost

```
$documentText  ←→  NSTextView.string
lastWrittenText  →  conflict detection vs disk
priorStoredMarkdown  →  op-log context for diff generation
```

These three pieces of state co-evolve on every keystroke. The three onChange handlers must stay in sync. Specifically:

- `$documentText` change → write through to op log (debounced) → eventual write to disk → `lastWrittenText` updates after the write resolves.
- External text arrival (cloud conflict resolution only) → call `EditorSurface.applyExternalText` → coordinator-side update without re-firing the onChange loop.
- Op-log re-render → set `priorStoredMarkdown` before pushing to `$documentText` to keep the differ correct.

**If you change the shape here, every cursor race you've heard about returns.**

## Tripwires (history of pain)

1. **Don't add a 4th onChange to EditorHost.** The triad is fragile by design — any new external-text path needs a regression test asserting it doesn't fire during normal typing.

2. **Don't add a 4th caller to `EditorSurface.applyExternalText`.** It exists for **cloud-conflict resolution only**. Asserting this is what catches binding races. Current callers: conflict resolution flow, … (intentionally limited).

3. **Don't put heavy work inside a synchronous SwiftUI binding setter.** This caused three separate cursor races in 24 hours:
   - Trailing-space autosave moved the cursor (autosave wrote, NSTextView re-laid-out, cursor jumped).
   - Async restore raced key events (restore set selection mid-typing).
   - Binding loop read stale `documentText` (onChange fired before write completed).
   Use the established pattern: debounce + isolate the write side from the read side.

4. **Don't subclass NSTextStorage to front multiple files.** This killed Phase 3d. AppKit's layout, undo, and selection caches downstream of NSTextStorage can't be steered cleanly from a subclass. Multi-file screenplay is **dead**. See `memory/project_milestone_3d_abandoned.md`.

5. **Don't add SwiftUI ↔ AppKit bidirectional sync with flag-based loop guards.** `.onChange` fires *after* the synchronous flag-clear, so the guard leaks. Killed cursor↔binder sync in 3d.

6. **Don't compute in SwiftUI list rows that render editor-adjacent metadata** without caching. Per-row Fountain re-parses became O(N²) on binder click in 3d, producing visible load pauses.

7. **Don't reach for NSPopover for in-editor UI.** Sizing is unreliable, it blocks input, it fights NSTextView focus. Use inline ghost-text, a sheet, or a sidebar pane instead.

8. **`applyFocusDim` is called from three paths intentionally.** Don't dedupe blindly — selection-change, focus-change, and explicit theme-update all need to drive it.

## What to read before editing

- For prose tokenization changes: `Tokenizer/` and the prose path in `EditorCoordinator.applyStyles`.
- For screenplay changes: `Fountain/ScreenplayMode.swift` (start here), then `Fountain/FountainParser.swift`, then the screenplay path in `EditorCoordinator`.
- For anything touching cursor / selection / external-text arrival: re-read the triad section above before touching `EditorHost.swift` or `EditorSurface.swift`.
- For op-log boundary: `Maugham/OpLog/AREA.md` (companion file).

## Tests worth knowing about

- Editor-side tests live in `MaughamTests/EditorTests/` (and the Fountain subfolder for screenplay-specific).
- **Missing high-value coverage:** there is no regression test asserting `applyExternalText` doesn't fire during normal typing. Adding one is leverage.
- Smoke test (manual, user-driven): launch → create Novel → type → ⌘Q → relaunch → reopen from Recents → sentence intact.

## What's intentionally NOT here

- Document persistence — `Maugham/Stores/DocumentStore.swift`.
- Op log mutation — `Maugham/OpLog/`.
- Binder / outline / inspector UI — `Maugham/Views/`.
- Find/replace data model — `Maugham/Stores/` (BinderSegment.find).
- Wiki-link resolution to other docs — `Maugham/Stores/ProjectStore` (WikiLink extension); the *hit-testing* (mouse over `[[…]]`) lives here but resolution doesn't.
