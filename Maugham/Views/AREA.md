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
- **Empty-state top-anchoring** — Any pane that conditionally shows a `ContentUnavailableView` MUST give it `.frame(maxWidth: .infinity, maxHeight: .infinity)`, AND the enclosing `VStack` (when the pane has a top toolbar + content body shape) MUST get `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`. Without both, the empty state collapses to its intrinsic size and the parent vertically centers the entire pane — the toolbar floats to the window's middle. Bug recurs every time a new pane is added; the established panes (HistoryPane, AnnotationsPane, OutlinePane, LinkedResearchPane, TasksPane, CollectionPiecesPane) all have this treatment.
- **Inline rename TextField focus claim** — `BinderRow`, `PieceRow`, and `ResearchRow` use the same shape: `.focused($isRenameFieldFocused)` + a `claimFocus()` helper that `Task.sleep(30ms)` before setting focus to `true`. The 30ms deferral lets `List(selection:)`'s focus-claim pass settle first so the TextField wins the gesture race. Both `.onAppear` (for the "row appears in rename mode" path) AND `.onChange(of: renamingItemId)` (for the "context-menu Rename on a visible row" path) trigger the helper — idempotent, either alone is incomplete. **When adding any new rename-capable row, copy the BinderRow shape verbatim.**
- **Close-before-FS-surgery** — Any code that moves or deletes a file the user might be editing MUST first close the writing surface so its autosave can't recreate the file at the old path. For `Document` instances: `await openDoc.close(); ds.unregister(path: oldPath)`. For research notes (path-keyed scheduler): `await documentStore?.flushPendingSave()`. Sites that follow this pattern: `ProjectStore+Structure.renameStructureItem`, `ProjectStore+Structure.deleteStructureItem`, `ProjectStore+CollectionPieces.renamePiece`, `ProjectStore+CollectionPieces.movePiece`, `ProjectStore+Research.updateResearchItem`, `ProjectStore+Research.deleteResearchItem`, `DocumentStore.executeRenamePlan`. **Any new FS-mutation entry point on user-edited files must add this guard.**

## Tripwires

See CLAUDE.md for the full list; the ones touching Views are:

- #2 (no SwiftUI ↔ AppKit flag-based loop guards), #3 (no heavy work in synchronous SwiftUI binding setters), #4 (no O(N²) per-row reparsing), #5 (no NSPopover-for-autocomplete), #6 (no parallel observable state on EditorHost), #7 (no fourth caller to `EditorSurface.applyExternalText`), #9 (no `.onTapGesture` for `List(.sidebar)` rows).

## Tests worth knowing

- `MaughamTests/Integration/EditorIntegrationHarnessTests.swift` — 10/10 contract tests for the editor binding shape.
- `MaughamTests/Views/RewindDensityTests.swift` — tick decimation rule.
- `MaughamTests/Integration/RewindEntryPointsTests.swift` — both rewind entry points route through the same notification → modal.
