# Maugham/Views — area notes

The SwiftUI view layer for the project window. Composes the binder (left), editor (center), and detail pane (right) plus modals and sheets.

## Important files

- `ProjectWindow.swift` — the root view. ViewModifier-extracted modal stack (`CheckpointModifier`, `SessionAndNavigationModifier`, `CollectionPieceModifier`, `RewindModifier`) to dodge SwiftUI's body type-check ceiling. **When you hit "the compiler is unable to type-check this expression in reasonable time," extract a ViewModifier** — established pattern.
- `EditorHost.swift` — fragile cluster (see CLAUDE.md tripwires 2/3/6/7). Single-binding contract enforced by `EditorIntegrationHarnessTests`.
- `HistoryPane.swift` — read-only forensic timeline. Filter pills + per-row ↺ + header "Rewind…" button. Row rendering branches on synthesisSource enum, not strings.
- `AnnotationsPane.swift` — sibling segment to HistoryPane; action surface for Claude annotations (Accept/Reject/Archive).
- `RewindWindow.swift` — time-travel modal. Per-doc v1; scrubber + Doc/Diff preview + Snapshot/Restore footer. Snapshots the op log at open-time.
- `RewindTickLayout.swift` — pure decimation helper for the scrubber. Unit-tested independent of SwiftUI.
- `PartialRestorePicker.swift` — per-doc-vs-project picker used by checkpoint-row reverts. NOT used by rewind restore (which is per-doc by construction).
- `CheckpointLabelPromptSheet.swift` — reusable label-entry sheet; used by both ⌘⇧S and "Snapshot here" in the rewind modal.

## Patterns

- **Right-pane mode-swap** (Inspector / Research / Outline / Annotations / History) — ⌘⌥1/2/3 + ⌘⌥A/⌘⌥4. Mirror the pattern for new right-pane content.
- **Notification-based modal triggers** — `.maughamOpenRewind`, `.maughamShowProjectSettings`, etc. Posted by buttons in subviews, observed by ProjectWindow's `.onReceive`. Keeps the modal-state ownership in the root view.
- **Dark-mode propagation to side panes** is a known carry-forward (lost twice). Re-check after touching theme code.

## Tripwires

See CLAUDE.md for the full list; the ones touching Views are:

- #2 (no SwiftUI ↔ AppKit flag-based loop guards), #3 (no heavy work in synchronous SwiftUI binding setters), #4 (no O(N²) per-row reparsing), #5 (no NSPopover-for-autocomplete), #6 (no parallel observable state on EditorHost), #7 (no fourth caller to `EditorSurface.applyExternalText`), #9 (no `.onTapGesture` for `List(.sidebar)` rows).

## Tests worth knowing

- `MaughamTests/Integration/EditorIntegrationHarnessTests.swift` — 10/10 contract tests for the editor binding shape.
- `MaughamTests/Views/RewindDensityTests.swift` — tick decimation rule.
- `MaughamTests/Integration/RewindEntryPointsTests.swift` — both rewind entry points route through the same notification → modal.
