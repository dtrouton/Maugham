# Maugham/Views — area notes

The SwiftUI view layer for the project window. Composes the binder (left), editor (center), and detail pane (right) plus modals and sheets.

## Important files

- `ProjectWindow.swift` — the root view. ViewModifier-extracted modal stack (`CheckpointModifier`, `SessionAndNavigationModifier`, `CollectionPieceModifier`, `RewindModifier`, `PersonaModifier`) to dodge SwiftUI's body type-check ceiling. **When you hit "the compiler is unable to type-check this expression in reasonable time," extract a ViewModifier** — established pattern. `TopChromeModifier` (private to `ProjectWindow.swift`) owns the top safe-area inset: the persona bar (topmost, hidden in `⌘\` focus mode), then the update/backup banners.
- `PersonaBar.swift` — the four-persona switcher (`PersonaBar` + private `PersonaBarButton`), mounted by `TopChromeModifier`. Holds no mutation logic — clicking a segment posts `.maughamSetPersona` exactly as ⌘1–4 do, so `PersonaModifier` is the one code path that changes persona and applies the segment coercions.
- `EditorHost.swift` — fragile cluster (see CLAUDE.md tripwires 2/3/6/7). Single-binding contract enforced by `EditorIntegrationHarnessTests`.
- `HistoryPane.swift` — read-only forensic timeline. Filter pills + per-row ↺ + header "Rewind…" button. Row rendering branches on synthesisSource enum, not strings.
- `AnnotationsPane.swift` — sibling segment to HistoryPane; action surface for Claude annotations (Accept/Reject/Archive).
- `RewindWindow.swift` — time-travel modal. Per-doc v1; scrubber + Doc/Diff preview + Snapshot/Restore footer. Snapshots the op log at open-time.
- `RewindTickLayout.swift` — pure decimation helper for the scrubber. Unit-tested independent of SwiftUI.
- `PartialRestorePicker.swift` — per-doc-vs-project picker used by checkpoint-row reverts. NOT used by rewind restore (which is per-doc by construction).
- `CheckpointLabelPromptSheet.swift` — reusable label-entry sheet; used by both ⌘⇧S and "Snapshot here" in the rewind modal.

## Patterns

- **Right-pane mode-swap**, now scoped by persona ([ADR 0005](../../docs/adr/0005-right-pane-mode-swap.md), amended by [ADR 0025](../../docs/adr/0025-persona-shell.md)) — each persona offers a subset of `DetailSegment` via `Persona.panes`; the nine pane shortcuts are `⌘⌥`-letter (⌘⌥I Inspector, ⌘⌥R Research, ⌘⌥O Outline, ⌘⌥A Annotations, ⌘⌥H History, ⌘⌥T Tasks, ⌘⌥B Inbox, ⌘⌥P Palette, ⌘⌥L Translation), dispatched from the View menu in `MaughamApp.swift` rather than `DetailPaneToggle`, so every one reveals a hidden inspector column. **A new right-pane surface is a `DetailSegment` case plus one entry in `Persona.panes`** — mirror the pattern, don't touch the picker or `ProjectWindow`.
- **Notification-based modal triggers** — `.maughamOpenRewind`, `.maughamShowProjectSettings`, etc. Posted by buttons in subviews, observed by ProjectWindow's `MaughamEvent` receive helpers (see below). Keeps the modal-state ownership in the root view.
- **Scoped window events (ADR 0021).** `ProjectWindow`'s receivers use the `MaughamEvent` helpers exclusively — `.onKeyWindowCommand`, `.onProjectEvent`, `.onGlobalEvent` (grep-verifiable: no hand-written `isKeyWindow` guard survives in this file). Every post declares its scope at the post site; `ProjectWindow` never re-derives one. When adding a new event, pick the scope where you post (`.keyWindow` for menu commands the key window alone should act on, `.project(id:)` for data events windows on that project should see, `.allWindows` for genuine app-wide fan-out), then subscribe with the matching helper — don't hand-roll a filter in the receiver closure. Panes that need to know their own window's liveness (e.g. to gate a receiver) resolve it via `WindowAccessor`, not by caching an `NSWindow?` and treating `nil` as "closed" (`WindowAccessor` caches the window and never re-nils it on close — see `MaughamEvent.isLive`).
- **Dark-mode propagation to side panes** is a known carry-forward (lost twice). Re-check after touching theme code.
- **Empty-state top-anchoring** — Any pane that conditionally shows a `ContentUnavailableView` MUST give it `.frame(maxWidth: .infinity, maxHeight: .infinity)`, AND the enclosing `VStack` (when the pane has a top toolbar + content body shape) MUST get `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`. Without both, the empty state collapses to its intrinsic size and the parent vertically centers the entire pane — the toolbar floats to the window's middle. Bug recurs every time a new pane is added; the established panes (HistoryPane, AnnotationsPane, OutlinePane, LinkedResearchPane, TasksPane, CollectionPiecesPane) all have this treatment.
- **Inline rename TextField focus claim** — `BinderRow`, `PieceRow`, and `ResearchRow` use the same shape: `.focused($isRenameFieldFocused)` + a `claimFocus()` helper that `Task.sleep(30ms)` before setting focus to `true`. The 30ms deferral lets `List(selection:)`'s focus-claim pass settle first so the TextField wins the gesture race. Both `.onAppear` (for the "row appears in rename mode" path) AND `.onChange(of: renamingItemId)` (for the "context-menu Rename on a visible row" path) trigger the helper — idempotent, either alone is incomplete. **When adding any new rename-capable row, copy the BinderRow shape verbatim.**
- **Close-before-FS-surgery (tripwire 14) — now enforced by construction.** Moving or deleting a file the user might be editing MUST close the writing surface (so its autosave can't recreate the file at the old path) AND flush the research-note debounce, BEFORE the FS call. This discipline is no longer remembered per-site: it lives INSIDE the typed `DocumentStore` mover — `relocate(plan:)` / `relocateUserContent(affectedPaths:perform:)` / `trash(relativePath:using:…)` — which is the only legal way to relocate/trash a user-editable path. See **`Maugham/Stores/AREA.md` → "Typed user-content mover"** for the entry-point table, the boundary (which moves are intentionally left raw), and the `TripwireGrepTests` guard. **When adding a new mover of user content, route it through one of those three entry points — don't re-hand-roll the close+flush.**

## Tripwires

See CLAUDE.md for the full list; the ones touching Views are:

- #2 (no SwiftUI ↔ AppKit flag-based loop guards), #3 (no heavy work in synchronous SwiftUI binding setters), #4 (no O(N²) per-row reparsing), #5 (no NSPopover-for-autocomplete), #6 (no parallel observable state on EditorHost), #7 (no fourth caller to `EditorSurface.applyExternalText`), #9 (no `.onTapGesture` for `List(.sidebar)` rows), #21 (no raw `maugham.*` NotificationCenter post/subscription outside `MaughamEvent`).

## Tests worth knowing

- `MaughamTests/Integration/EditorIntegrationHarnessTests.swift` — 10/10 contract tests for the editor binding shape.
- `MaughamTests/Views/RewindDensityTests.swift` — tick decimation rule.
- `MaughamTests/Integration/RewindEntryPointsTests.swift` — both rewind entry points route through the same notification → modal.
