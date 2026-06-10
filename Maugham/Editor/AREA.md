# Editor — Area guide

This is the most fragile area in the codebase. Three cursor races in 24 hours during the 3d window all lived here. Read this before editing anything in `Maugham/Editor/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The NSTextView-backed editing surface: text storage, tokenization, styling, cursor management, smart typography substitution, find-match navigation, focus dimming, image-paste routing, wiki-link hit-testing, Tab-element cycling (screenplay), and the SwiftUI bridge that exposes it as a binding to the rest of the app.

## Layout

- `EditorSurface.swift` — `NSViewRepresentable` wrapping `NSTextView`. The SwiftUI-side boundary.
- `EditorHost.swift` (lives at `Maugham/Views/EditorHost.swift`, not here — historical placement) — binds the per-document `Document` actor to `EditorSurface`. The binding is the single source `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })`; `Document.setFullText` writes `displayText` exactly once at the end. The earlier `$documentText` / `lastWrittenText` / `priorStoredMarkdown` triad is gone — all that state moved onto `Document`.
- `EditorCoordinator.swift` — `NSTextViewDelegate` implementation. The "central nervous system" and by far the largest file in this area. Tokenizes, applies styles, manages cursor, handles Tab-cycle for screenplay, smart-quote / em-dash substitution, find-match scrolling, focus-dim, image paste routing, wiki-link `[[…]]` hit-testing.
- `ScreenplayMode.swift` lives at `Maugham/Editor/` (not under `Fountain/`).
  - `ScreenplayMode.applyTypography` is **windowed on the typing path** (since 2026-06-10, commit `0506638`): it takes a `restyleWindow` and `setAttributes` only over the classification-changed range — the per-keystroke restyle is no longer whole-document (that was O(N²) at 70-page scale). The whole-doc path remains for external/theme changes (pass a nil/whole-storage window). Still a known race-window contributor; don't add work *inside* it on either path.
  - **History (not live code):** display-time uppercase for forced sluglines/characters was rejected as an "option-A fallback" for cursor-positioning reasons — making text render uppercase while the source/selection stayed lowercase desynced the caret. The shared `ScreenplayUppercase` in MaughamCore uppercases the *source* instead. A dead `ScreenplayLayoutManager` (glyph-substitution `NSLayoutManager` keyed on a never-set `.maughamDisplayUppercase` attribute) lingered as a relic of that rejected approach and was deleted 2026-06-10. Don't reintroduce display-time uppercase without rethinking the cursor-positioning problem.
- `Fountain/` — screenplay parser primitives: `FountainTokenizer.swift` (the parser; despite the name it does parsing not just tokenizing), `FountainScript.swift`, `FountainLine.swift`.
- `Tokenizer/` — prose-side tokenizer + style application.
- **Character autocomplete is intentionally absent.** The NSPopover-based `CharacterAutocompleter` was deleted (2026-06-06) after being dead since 3b ("too brittle, blocks input"). Don't reintroduce a popover-based autocomplete; if character autocomplete returns, redesign the UX first (inline ghost-text or sheet).

## Task anchor styling

Two new `Token.Kind` values were added in the task-anchors milestone:

- `Token.Kind.taskBody` — paints the checkbox body text distinctly (currently `palette.syntaxPunctuation`) so the writer can see the boundary between task text and surrounding prose.
- `Token.Kind.invisibleAnchor` — paints `NSColor.clear` so the `<!--t-XXXXXX-->` span is present in NSTextStorage (required for the strip/restore round-trip via `RenderFilter`) but invisible to the writer.

Both the Markdown and Fountain tokenizers emit these kinds for anchored inline tasks. `ScreenplayMode` adds the invisible-anchor attributes **after** its full-storage `setAttributes` call — consistent with the existing race-window discipline (don't add work *inside* `applyTypography`).

`EditorCoordinator` records cursor position to `Document.recordCursorAt(_:)` on selection changes. `Document.setFullText` reads the recorded cursor as `preEditCursor` for V2 cross-paragraph alignment, which detects cut/paste of anchored task lines between paragraphs.

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

9. **Scroll position is hand-governed; the per-keystroke full-range restyle fights it.** `retokenizeAndStyle`'s full-storage `setAttributes` invalidates all layout, which snaps the scroll origin toward the top on a long scrolled doc. Two mitigations live in `EditorCoordinator` and must both stay:
   - **Typewriter off:** `textDidChange` captures the scroll origin *before* the restyle and restores it *after* (symmetric with the caret capture-and-restore right above it). NSTextView has already scrolled to the caret by the time `textDidChange` fires, so the captured origin is correct. This is what stops the "space/delete jumps to top then back" bug.
   - **Typewriter on:** centering needs half-a-viewport of headroom above the first line and below the last, or the active line pins to the top/bottom edge instead of center. `refreshTypewriterInset` sets `textContainerInset.height` to `clipHeight/2` (restored to 24 when off) and must be re-run on resize (wired from `MaughamTextView.updateColumnInset`). `scrollSelectionToVerticalCenter` adds `textContainerInset.height` to the container-space `lineRect.midY` to land in view space — **don't drop that correction**, it's what makes centering accurate once the inset is large.

## What to read before editing

- For prose tokenization changes: `Tokenizer/` and the prose path in `EditorCoordinator.applyStyles`.
- For screenplay changes: `ScreenplayMode.swift` at `Maugham/Editor/` (start here), then `Fountain/FountainTokenizer.swift` (the parser), then the screenplay path in `EditorCoordinator`.
- For anything touching cursor / selection / external-text arrival: re-read the triad section above before touching `EditorHost.swift` or `EditorSurface.swift`.
- For op-log boundary: `Maugham/OpLog/AREA.md` (companion file).

## Tests worth knowing about

- Editor-side tests live in `MaughamTests/Editor/` (and the `Fountain/` subfolder for screenplay-specific).
- `EditorIntegrationHarness` + `EditorIntegrationHarnessTests` is the regression net for the binding contract: `assertNoApplyExternalText` (via `applyExternalTextCallCount` on the coordinator) wraps a block of simulated typing and fails if `applyExternalText` fires. `test_endOfFileTyping_doesNotFireApplyExternalText` is the canonical assertion — extend it whenever you touch the binding shape.
- Smoke test (manual, user-driven): launch → create Novel → type → ⌘Q → relaunch → reopen from Recents → sentence intact.

## What's intentionally NOT here

- Document persistence — `Maugham/Stores/DocumentStore.swift`.
- Op log mutation — `Maugham/OpLog/`.
- Binder / outline / inspector UI — `Maugham/Views/`.
- Find/replace data model — `Maugham/Stores/` (BinderSegment.find).
- Wiki-link resolution to other docs — `Maugham/Stores/ProjectStore` (WikiLink extension); the *hit-testing* (mouse over `[[…]]`) lives here but resolution doesn't.
