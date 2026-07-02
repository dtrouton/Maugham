# Window-teardown discipline audit (ADR 0021, Task 8)

**Date:** 2026-07-02
**Branch:** `feat/adr-0021-scoped-window-events`
**Scope:** read-only trace of every ProjectWindow close path, verifying which of
the two teardown obligations actually run on each:

1. **Graph release:** `EditorSurface.dismantleNSView` → `EditorCoordinator.detach()`
   (drops the `NSScrollView→NSTextView→NSTextStorage` graph, cancels async Tasks,
   removes the five scoped observer tokens, flips `isDetached`).
2. **Store/presenter release:** `ProjectWindow.onDisappear` →
   `mcpRegistry.unregister(url:)` + `documentStore.close()` (ends the session,
   flushes the pending save, removes the file presenter).

Citations are `file:line` against the branch state at audit time.

## Sources traced

- `Maugham/Editor/EditorSurface.swift:253-263` — `dismantleNSView` (the ONLY body
  is `MainActor.assumeIsolated { coordinator.detach() }`).
- `Maugham/Editor/EditorCoordinator.swift:561-582` — `detach()`.
- `Maugham/Views/ProjectWindow.swift:159-162` — `.onDisappear { mcpRegistry.unregister(url:); Task { await documentStore?.close() } }`.
- `Maugham/Views/ProjectWindow.swift:188-194` — `.onGlobalEvent(.maughamAppWillTerminate) { Task { await ds.close() } }`.
- `Maugham/MaughamApp.swift:30-56` — `NSApplication.willTerminateNotification`
  observer posts `.maughamAppWillTerminate` to `.allWindows`.
- `Maugham/Views/EditorHost.swift:210` — `.id(path)` on the `EditorSurface`
  (piece-flip identity).
- `Maugham/Editor/AREA.md:26` — "Effective-appearance change" teardown paragraph
  (SwiftUI `WindowGroup` scene retention rationale for the liveness guard).
- Memory note: "quit ≠ close(): `.onDisappear` does NOT run on quit — that's why
  the `appWillTerminate` flush exists."

## Path-by-path matrix

| Close path | `dismantleNSView → detach()` | `onDisappear → close() + unregister` | Store/graph released by |
|---|---|---|---|
| **Red-button close** | **NOT guaranteed** (SwiftUI `WindowGroup` retains the closed-window scene storage; `dismantleNSView` runs only when SwiftUI cooperatively dismantles the representable — see AREA.md:26 & `EditorCoordinator.swift:554-560`) | **YES** — `.onDisappear` fires reliably on window close (`ProjectWindow.swift:159-162`): `mcpRegistry.unregister(url:)` + `documentStore.close()` both run | close/unregister via `onDisappear`; graph release **best-effort** (liveness guard is the net) |
| **⌘W (Close Window)** | Same as red-button — routes through the identical SwiftUI window-close, so **NOT guaranteed** | **YES** — identical `.onDisappear` path | same as above |
| **⌘Q (Quit — quit ≠ close())** | **NOT run** — quit terminates the process; SwiftUI does not dismantle representables on termination | **`onDisappear` does NOT run on quit.** `close()` instead runs via the belt-and-suspenders bridge: `willTerminate` (`MaughamApp.swift:33-37`) → `.maughamAppWillTerminate` to `.allWindows` → `ProjectWindow.onGlobalEvent` (`ProjectWindow.swift:188-194`) → `Task { await ds.close() }`. **`mcpRegistry.unregister` is NOT called** — the whole registry dies with the process (the socket is also `unlink()`ed synchronously at `MaughamApp.swift:45`) | `close()` via the `appWillTerminate` global bridge; graph + registry torn down with the process |
| **Piece flip within a window (`.id(path)`, `EditorHost.swift:210`)** | **YES — deterministic.** Changing `.id` makes SwiftUI dismantle the outgoing `EditorSurface` (representable leaves the view tree) → `dismantleNSView` → `detach()` runs for the old piece's coordinator | **`onDisappear` does NOT run** (window stays open) — and correctly so: same project, same `DocumentStore`. The outgoing *document* is closed separately by `EditorHost.loadDocumentIfNeeded` (`EditorHost.swift:276-278`: `await prior.close(); documentStore.unregister(path:)`) | `detach()` (graph) + `Document.close()` per-doc (not the whole store) |
| **Reopen same URL via Recents** | **No teardown** — `WindowGroup(for: URL.self)` scene identity is by value (`MaughamApp.swift:231`), so reopening an already-open project's URL brings the existing window forward rather than tearing anything down | n/a (no close) | n/a |

## Outcome — all paths clean; NO new defect

The audit confirms the intended contract and surfaces **no path where a required
teardown silently fails to run**:

- **Store/presenter release** (`documentStore.close()`) runs on **every** close
  path: `onDisappear` on interactive close, the `appWillTerminate` global bridge
  on quit, and the per-document `close()` on piece flip. `DocumentStore.close()` is
  idempotent (see the zombie-harm audit note on `maughamAppWillTerminate` in
  `MaughamNotifications.swift:36-48`), so the belt-and-suspenders double-close on a
  close-then-quit sequence is harmless.

- **Graph release** (`detach()`) is deterministic on the two paths SwiftUI
  controls directly (piece flip; any cooperative dismantle) and **intentionally
  best-effort** on plain window close. This is **not a defect — it is the exact
  gap ADR 0021's liveness guard exists to cover.** SwiftUI's `WindowGroup` does
  not deterministically release a closed window's scene storage, so a coordinator
  (and its retained text-view graph) can outlive its window as a *zombie*. The
  guard neutralises the zombie without depending on `detach()` running:
  `MaughamEvent.isLive(window)` / `EventReceiverContext.forWindow` drop every
  scoped delivery to a closed (non-visible, non-miniaturized) window, and
  `receiverContext` returns `nil` once `isDetached`. `detach()` is the proactive
  cleanup on the teardowns SwiftUI *does* perform; the liveness guard is the net
  for the ones it doesn't.

**Conclusion:** every close path releases the DocumentStore; graph release is
guaranteed where SwiftUI dismantles and defended by the ADR 0021 liveness guard
where it doesn't. No ad-hoc fix required.

## What this task pins (headless-testable subset)

- `EditorSurface.dismantleNSView(_:coordinator:)` actually invokes `detach()`
  (isDetached flips, textView nils) — the wiring point, previously only pinned by
  calling `detach()` directly (`EditorAppearanceChangeTests.test_detach_releasesViewAndSilencesRestyle`).
- `detach()` silences the review-toggle observer (token removal + `isDetached`
  context-nil, belt-and-braces) — distinct observer from the navigate one already
  covered by `MaughamEventLivenessTests.test_detachedCoordinator_receivesNoNavigateToScene`.
- The per-scope-class closed-window matrix in `MaughamEventLivenessTests`
  (`.keyWindow`, `.project`, `.document`, and the deliberate `.allWindows`
  exception).

The `⌘Q`-quit and SwiftUI-window-close paths themselves are **not** unit-pinnable
headlessly (they require the SwiftUI scene lifecycle / `NSApplication` termination,
neither drivable from an XCTest host); they are covered by the manual smoke test
and by the liveness-guard tests that make graph-release non-load-bearing.
