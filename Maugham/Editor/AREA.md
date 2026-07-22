# Editor — Area guide

This is the most fragile area in the codebase. Three cursor races in 24 hours during the 3d window all lived here. Read this before editing anything in `Maugham/Editor/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The NSTextView-backed editing surface: text storage, tokenization, styling, cursor management, smart typography substitution, find-match navigation, focus dimming, image-paste routing, wiki-link hit-testing, Tab-element cycling (screenplay), and the SwiftUI bridge that exposes it as a binding to the rest of the app.

## TextKit version

The editor is **pinned to TextKit 1**. A fresh `NSTextView` on recent macOS is TextKit 2, whose caret is a private `NSTextInsertionIndicator` with no resize hook — so the empty-line caret renders at the full line-fragment height (glyph + the body line spacing) and visibly "shrinks" on the first keystroke. `EditorSurface.makeNSView` touches `textView.layoutManager` once, which permanently downgrades the view to TextKit 1, where `MaughamTextView.drawInsertionPoint` clamps the caret to glyph height (`CaretHeightTests`). Screenplay/review/typewriter already forced TK1 (gutter + overlays touch `layoutManager`), and the typing-perf milestone was tuned against that TK1 screenplay path — so this just makes prose consistent. **That `_ = textView.layoutManager` line looks unused; it is load-bearing — don't remove it.**

## Layout

- `EditorSurface.swift` — `NSViewRepresentable` wrapping `NSTextView`. The SwiftUI-side boundary.
- `EditorHost.swift` (lives at `Maugham/Views/EditorHost.swift`, not here — historical placement) — binds the per-document `Document` actor to `EditorSurface`. The binding is the single source `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })`; `Document.setFullText` writes `displayText` exactly once at the end. The earlier `$documentText` / `lastWrittenText` / `priorStoredMarkdown` triad is gone — all that state moved onto `Document`.
- `EditorCoordinator.swift` — `NSTextViewDelegate` implementation. The "central nervous system" and by far the largest file in this area. Tokenizes, applies styles, manages cursor, handles Tab-cycle for screenplay, smart-quote / em-dash substitution, find-match scrolling, focus-dim, image paste routing, wiki-link `[[…]]` hit-testing.
- `ScreenplayMode.swift` lives at `Maugham/Editor/` (not under `Fountain/`).
  - `applyTypography` takes a `restyleWindow` so callers can `setAttributes` over just a sub-range (the modes still honour it; `WindowedTypographyEquivalenceTests` pins window≡whole-doc equivalence). **The typing path is now mode-gated (tripwire 9, `WritingMode.defersRestyleWhileTyping`):** prose DEFERS a windowed repaint to the burst settle (`performDeferredRestyle`), while screenplay paints LIVE & WINDOWED per keystroke (`paintLiveWindowed`). Both compute the window via `changedParagraphWindow` (character diff vs a baseline), so the coordinator DOES compute per-keystroke windows again on the live path. Don't add work *inside* `applyTypography` on either path.
  - **History (not live code):** display-time uppercase for forced sluglines/characters was rejected as an "option-A fallback" for cursor-positioning reasons — making text render uppercase while the source/selection stayed lowercase desynced the caret. The shared `ScreenplayUppercase` in MaughamCore uppercases the *source* instead. A dead `ScreenplayLayoutManager` (glyph-substitution `NSLayoutManager` keyed on a never-set `.maughamDisplayUppercase` attribute) lingered as a relic of that rejected approach and was deleted 2026-06-10. Don't reintroduce display-time uppercase without rethinking the cursor-positioning problem.
- Typing-perf milestone (2026-06-10, branch `typing-perf`): `FountainTokenizer` is a single UTF-16 buffer pass over an internal `LineRecord` array — `LineRecord` is the documented seam a future INCREMENTAL tokenizer re-derives from (don't inline it away); any grammar change must update BOTH the tokenizer and the frozen `FountainTokenizerReference` oracle in MaughamCoreTests. The footer/inspector metrics pipeline is `EditorCoordinator.onMetricsChanged` (computed from the keystroke's own parse, debounced with the script broadcast — no consumer re-parses). `ElementGutterView` draws only visible-range lines via binary search + a color-keyed label cache (tripwire 4).
- **Crafted review render (Component F, review-mode only):** `ReviewPalette.swift` (pure colour policy — Claude = fixed terracotta, humans = stable FNV-hash into a capped muted set; TDD'd by `ReviewPaletteTests`) + `ReviewRenderViews.swift` (two transparent overlay NSViews installed on the text view like the gutter: `AnnotationMarkRenderer` draws inline pencil marks — underline / strike+caret / query-`?` — and `ReviewMarginRailView` draws the right-margin slip cards + leader lines). Both are coordinator-owned, shown only when `coordinator.isReviewMode`, and bound to the visible glyph range (tripwire 4). The coordinator resolves each `Annotation` to absolute UTF-16 (`ResolvedReviewMark`) in `recomputeReviewMarks()` — grapheme `resolvedSpanRange` → UTF-16 via `ReviewSpanCapture.graphemeRangeToUTF16` + the paragraph's `displayRange(forParagraphId:)` location — caching the result and recomputing only on annotation-set change (pushed one-way from EditorHost off `Document.annotationsVersion`) or text change, never per draw. Overlays self-observe scroll/text via `NotificationCenter` (mirrors `ElementGutterView`); resize re-frames them from `MaughamTextView.updateColumnInset`.
- `Fountain/` — screenplay parser primitives: `FountainTokenizer.swift` (the parser; despite the name it does parsing not just tokenizing), `FountainScript.swift`, `FountainLine.swift`.
- `Tokenizer/` — prose-side tokenizer + style application.
- **Character autocomplete is intentionally absent.** The NSPopover-based `CharacterAutocompleter` was deleted (2026-06-06) after being dead since 3b ("too brittle, blocks input"). Don't reintroduce a popover-based autocomplete; if character autocomplete returns, redesign the UX first (inline ghost-text or sheet).
- **Effective-appearance change (OS light/dark) — DIRECT per-view call, not a broadcast (2026-07-02):** `MaughamTextView.viewDidChangeEffectiveAppearance` calls `coordinator?.effectiveAppearanceDidChange()` directly (one delegate hop). It does NOT post a NotificationCenter broadcast. AppKit fires `viewDidChangeEffectiveAppearance` on a view's FIRST mount, not only on a real light/dark flip — and every piece flip builds a fresh `EditorSurface` — so the old `object: nil` broadcast (`.maughamEffectiveAppearanceChanged`, now deleted) fanned a whole-doc restyle out to EVERY live coordinator, including leaked ones from closed windows (a 174KB screenplay restyle = ~seconds). Two belts: `effectiveAppearanceDidChange()` no-ops when `textView.effectiveAppearance.name` is unchanged since the last handled change (baseline seeded in `attach`); and `coordinator.detach()` runs on teardown — from `EditorSurface.dismantleNSView` on IN-window teardowns (the `.id(path)` piece flip) AND from `MaughamTextView.viewWillMove(toWindow: nil)` on window close (the retain-root trace proved `dismantleNSView` NEVER runs on ⌘W — `GraphHost.sharedGraph` retains the dead scene). `detach()` releases the text-view graph, cancels the async Tasks, and flips `isDetached` so a coordinator SwiftUI has not yet released does no restyle work; it is explicitly idempotent (`guard !isDetached`) because a flip fires both hooks. The coordinator has **no internal ARC cycle** — every back-reference (delegate, `textView`, overlay/gutter `coordinator`, NC observers, Tasks) is `weak`/`[weak self]`; the post-window-close leak is SwiftUI `WindowGroup` scene retention, which `detach()` cannot force-release but neutralises. The heavy `@State` payload (Document, ProjectStore, DocumentStore, FountainScript AST) is separately scorched in `ProjectWindow`/`EditorHost` `.onDisappear` (workaround 1, see the scene-storage spike note). NOTE this is distinct from theme/typography changes, which flow via `EditorControl` (below) — `applyAppearance` serves both, so the same-appearance no-op guard lives in `effectiveAppearanceDidChange()`, not in `applyAppearance`. Regression net: `EditorAppearanceChangeTests`.
- **Control plane (ADR 0017):** Control state (posture/appearance/review annotation set) flows through `EditorControl`, observed by the coordinator via `withObservationTracking` — it does NOT ride `updateNSView` and does NOT get a new notification. `updateNSView` is text + frame + gutter + provider-wiring only; the text binding/data plane is unchanged. D1 — `EditorControl` holds only control state, never text-/cursor-derived values (else observation fires on the typing hot path). D2 — `applyControl` stays per-sub-area no-op-guarded; callers add no-op guards to avoid redundant AppKit calls. The ⌘⌥R `maughamToggleReviewMode` observer is kept deliberately for a synchronous membrane flip (Bug B).
  - **Narrowed observation capture (ADR 0017 addendum, 2026-07-02):** `armControlObservation` runs the initial `applyControl` **outside** `withObservationTracking`; the tracking closure reads ONLY the `control.*` properties (each touched explicitly). This closes D1's latent exposure: `applyControl` reads *through* Document/UserPreferences providers in review posture (`recomputeReviewMarks` → `reviewLocalAuthorName`), so if the apply ran *inside* tracking those reads were tracked and any shared `UserPreferences`/`Document` mutation re-fired the whole-doc restyle in every review-mode window. Don't move `applyControl` back inside the tracking closure, and don't add a `control.*` read to the closure without a matching read in `applyControl` (keep the tracked set == the consumed set). Regression net: `EditorControlBridgeTests.test_reviewObservation_ignoresSharedPreferencesMutation` / `…_stillFiresOnControlPropertyChange` (via the internal `applyControlCount`).
- **Scoped `maughamScriptDidUpdate` (Channel A, now ADR 0021):** the coordinator's script-did-update post routes through `MaughamEvent`'s `.project` scope, not a bespoke channel. `postScriptDidUpdate` posts `MaughamEvent.post(.maughamScriptDidUpdate, to: .project(id: scriptOriginProjectId), object: script)`, where `scriptOriginProjectId` is stamped by the coordinator (wired by `EditorSurface` from `EditorHost` = `ProjectIdentifier.id(for: store.url)`). Receivers subscribe via `.onProjectEvent(.maughamScriptDidUpdate, url:, window:)` (`ProjectWindow.swift`) — adopt the script only when the event's project id matches their own. This is NOT a key-window guard (a background window's own MCP-driven re-parse must still update its scene navigator). Before scoping, any window flipping to a screenplay piece wrote every other window's `lastParsedScript`, triggering a ~0.8–1s NavigationStack relayout of the bound editor and silently clobbering that window's navigator payload. `scriptOriginProjectId` can be nil (non-manuscript surface); the nil case gates only the `MaughamEvent.post` call — the debounce cancel/reschedule bookkeeping in `postScriptDidUpdate` stays unconditional, so a nil-origin call can't strand a stale in-flight debounced post. The old bespoke `ScriptUpdateRouting.swift` channel is deleted — absorbed into the wrapper. Regression net: `ScriptUpdateScopingTests`.

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
- The binding setter's side effects (`recordEditorTextWrite` → `recordWordCount`/`recordSessionActivity`) are part of the contract — pinned by `EditorBindingSideEffectsTests` (regression b37609a). Preserve them in any binding change.

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

9. **Scroll position is hand-governed; a whole-doc `setAttributes` snaps the origin toward the top on a long scrolled doc.** `retokenizeAndStyle`'s full-storage `setAttributes` invalidates all layout, which AppKit then re-lays-out from the top. The mitigation depends on *when* the paint happens:
   - **Typing path — MODE-GATED on `WritingMode.defersRestyleWhileTyping` (since 2026-06-27).** Both branches restyle only the changed paragraph(s) via a CHARACTER diff (`changedParagraphWindow` — not a token diff: plain prose produces no syntax tokens, so the token-window approach falls back to whole-doc and re-introduces the scroll snap; this exact bug shipped in the first cut). A *local* `setAttributes` doesn't invalidate whole-doc layout, so it never moves scroll — **AppKit's native caret-following autoscroll is left to work** and `textDidChange` no longer captures/restores the origin (that old per-keystroke restore was *fighting* the autoscroll: "recoil on the last line" + "caret runs off the bottom mid-document").
     - **Prose (`defersRestyleWhileTyping == true`) — the "settle paint":** the repaint is **deferred** off the keystroke to the trailing edge of the burst (`scheduleDeferredRestyle` → `performDeferredRestyle`, ~`restyleSettleDelayMs`=300ms). On the keystroke itself NO paint happens. `shouldChangeTextIn` snapshots the pre-burst text (`burstBaselineText`); `performDeferredRestyle` diffs it against the post-burst text and windows the restyle. Deferral kills the emphasis-flicker: a transient invalid syntax state (`*italic *` while editing the end of a run) never gets painted because the paint waits for rest. The whole-doc + capture/restore branch survives only as a no-baseline defensive fallback.
     - **Screenplay (`defersRestyleWhileTyping == false`) — `paintLiveWindowed`:** paints synchronously ON the keystroke, but windowed (diffed against `liveRestyleBaseline`, the text as of the last paint). Live because screenplay styling is element-classification heavy — nearly every line is a different element, so a 300ms settle lag reads as pervasive sluggishness. The cursor restore in `textDidChange` covers any windowed-`setAttributes` jostle (no restore inside `paintLiveWindowed`). Trade-off: screenplay's (rarer) inline emphasis CAN flicker at a run edge again, since it no longer defers — acceptable vs. the constant element lag.
     - **Don't re-introduce a per-keystroke origin-restore, a whole-doc settle/live paint, or a token diff.** (`DeferredRestyleTests` — `test_settleRestyleIsWindowedNotWholeDocument`, `test_screenplayRestylesLiveWhileTyping`, `test_screenplayLiveRestyleIsWindowedNotWholeDocument` — is the regression net.)
   - **Non-typing callers (attach, applyExternalText, theme/typography/focus):** still paint synchronously and whole-doc; they don't go through `textDidChange` and historically never had the origin restore. They tolerate the snap because they re-assert the caret/scroll themselves (e.g. `applyExternalText` clamps + the attach deferred `scrollRangeToVisible`).
   - **Typewriter on:** centering needs half-a-viewport of headroom above the first line and below the last, or the active line pins to the top/bottom edge instead of center. `refreshTypewriterInset` sets `textContainerInset.height` to `clipHeight/2` (restored to 24 when off) and must be re-run on resize (wired from `MaughamTextView.updateColumnInset`). `scrollSelectionToVerticalCenter` adds `textContainerInset.height` to the container-space `lineRect.midY` to land in view space — **don't drop that correction**, it's what makes centering accurate once the inset is large. Centering still runs per-keystroke in `textDidChange` (it's a scroll op, not a paint).

10. **Any control flag that swaps which BUFFER the editor is showing (not just its styling) must flip the membrane synchronously, before the buffer-swap decision is made.** Translation review (Task 11, ADR 0024) hit this: `EditorSurface.reconcileTextBuffer` calls `coordinator.setTranslationReview(...)` FIRST, then checks whether `textView.string != text` to decide on a replace — in that order, deliberately. Reordering it (check-then-flip, or flipping on a later pass) let the membrane see a stale posture for one layout pass, and separately let an in-mode translated-content refresh retain a stale `preserveUndoStack` decision across a buffer swap that must always drop the native undo stack (carrying the SOURCE manuscript's undo actions across a translation-render swap reopens the ADR-0023 D1 corruption class). `setLockEditing` established the "plain stored-property flip, read live in `shouldChangeTextIn`" shape this reuses; the buffer-identity case adds the ordering requirement on top. `EditorUndoStackClearTests` is the regression net.

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
