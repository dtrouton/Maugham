# Editor — Area guide

This is the most fragile area in the codebase. Three cursor races in 24 hours during the 3d window all lived here. Read this before editing anything in `Maugham/Editor/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The NSTextView-backed editing surface: text storage, tokenization, styling, cursor management, smart typography substitution, find-match navigation, focus dimming, image-paste routing, wiki-link hit-testing, Tab-element cycling (screenplay), and the SwiftUI bridge that exposes it as a binding to the rest of the app.

## Layout

- `EditorSurface.swift` — `NSViewRepresentable` wrapping `NSTextView`. The SwiftUI-side boundary.
- `EditorHost.swift` — binds the per-document `Document` actor to `EditorSurface`. Post-`milestone-document-first-class` the binding is the single source `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })`; `Document.setFullText` writes `displayText` exactly once at the end. The earlier `$documentText` / `lastWrittenText` / `priorStoredMarkdown` triad is gone — all that state moved onto `Document`.
- `EditorCoordinator.swift` (~770 lines) — `NSTextViewDelegate` implementation. The "central nervous system." Tokenizes, applies styles, manages cursor, handles Tab-cycle for screenplay, smart-quote / em-dash substitution, find-match scrolling, focus-dim, image paste routing, wiki-link `[[…]]` hit-testing.
- `ScreenplayMode.swift` and `ScreenplayLayoutManager.swift` live at `Maugham/Editor/` (not under `Fountain/`).
  - `ScreenplayMode.applyTypography` does **full-storage** `setAttributes` (not incremental). Known race-window contributor; don't add work inside it.
  - `ScreenplayLayoutManager` exists but display-uppercase for forced sluglines/characters is the **option-A fallback** intentionally (display-time uppercase rejected for cursor-positioning reasons). Don't "fix" it without rethinking the approach.
- `Fountain/` — screenplay parser primitives: `FountainTokenizer.swift` (the parser; despite the name it does parsing not just tokenizing), `FountainScript.swift`, `FountainLine.swift`, plus `CharacterAutocompleter.swift` (dead — see below).
- `Tokenizer/` — prose-side tokenizer + style application.
- `CharacterAutocompleter.swift` — **DEAD CODE**. `updateAutocomplete` is defined but never called. NSPopover was abandoned in 3b ("too brittle, blocks input"). Don't wire it back without redesigning the UX (popover → inline ghost-text or sheet, TBD).

## The binding contract

```
EditorHost: Binding(get: { doc.displayText }, set: { doc.setFullText($0) })
   ↓
Document.setFullText: parse → diff → record paragraph changes → write displayText ONCE at end
   ↓
debounced burst flush → op log + autosave → eventual disk write → Document.lastDiskEcho updates inside the coordinated-write block
```

Invariants:

- **`displayText` is written exactly once per `setFullText` call.** That's what closes the binding-loop race (see harness test `test_endOfFileTyping_doesNotFireApplyExternalText`).
- **`EditorSurface.applyExternalText` is for cloud-conflict resolution only** — not for normal typing, not for op-log re-renders. Adding a caller is a tripwire (see below).
- **Echo guard for our own writes** lives on `Document` as `lastDiskEcho: EchoState`; the editor doesn't see it. Don't introduce parallel "last text" state in the editor layer.

**If you change the shape here, every cursor race you've heard about returns.**

## Tripwires (history of pain)

1. **Don't add a parallel onChange in `EditorHost` that reads back into the binding.** The current single-binding shape replaced the older 3-onChange triad that drove three cursor races in 24 hours. New external-text paths need a regression test asserting `applyExternalText` doesn't fire during normal typing.

2. **Don't add a 2nd caller to `EditorSurface.applyExternalText`.** It exists for **cloud-conflict resolution only**. Asserting this is what catches binding races. The harness test `test_endOfFileTyping_doesNotFireApplyExternalText` is the regression net.

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
- For screenplay changes: `ScreenplayMode.swift` at `Maugham/Editor/` (start here), then `Fountain/FountainTokenizer.swift` (the parser), then the screenplay path in `EditorCoordinator`.
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
