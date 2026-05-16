# 0005 — Right-pane mode-swap pattern (Inspector / Research / Outline)

**Status:** Accepted
**Date:** 2026-05-14

## Context

Through milestone 1d, the right column of `ProjectWindow` was a single `InspectorView` — metadata for the currently-selected manuscript document (synopsis, status, tags, word target, linked research, links).

The writing-companion milestone added three new surfaces that all wanted the same right-column real estate:

- **Linked Research browser** — show the research items linked to the active manuscript doc, with click-through to view the actual research note in place. Needed for the "side-by-side reading while drafting" pattern.
- **Outline view** — table or corkboard of every chapter's synopsis/status/word count, for "looking at the whole novel."
- **Keyboard cheatsheet** — surface every shortcut. Doesn't need a pane (it's a sheet), but informed the question of how to expose multiple right-pane modes.

We considered three patterns:

- **A. New columns / new windows.** Each surface gets its own window or sidebar. Costs screen real estate; fragments the writer's focus.
- **B. Modal sheets.** Each surface opens in a modal sheet. Works for the cheatsheet; doesn't work for "see the linked research **while I write**."
- **C. Mode-swap on the existing right pane.** A segmented picker at the top of the right pane switches between Inspector / Linked Research / Outline. Same real estate, one surface visible at a time, all driven by the same `selectedItemId`.

## Decision

**Right-pane mode-swap.** New `DetailPaneToggle` view wraps a `Picker` at the top of the right pane with three icon-only segments. Selection persists per project via `UIState.detailSegment: DetailSegment`. The keyboard shortcuts `⌘⌥1` / `⌘⌥2` / `⌘⌥3` jump between modes (and reveal the pane if it's hidden — distinct from `⌘⌥I` which toggles the whole pane).

`DetailPaneToggle` takes the Inspector branch as a `@ViewBuilder` closure so `ProjectWindow` can preserve its existing per-binder-segment switch (manuscript→Inspector, research→InspectorResearchPanel, trash→ContentUnavailableView) without duplicating that logic.

## Consequences

- **Zero new windows or columns.** Same window shape from milestone 1d still describes the app.
- **Each mode is its own SwiftUI view file** (`LinkedResearchPane`, `OutlinePane`, plus the existing Inspector). They share the right-pane container but not state — keeps the type-checker happy.
- **Outline pane has its own internal layout toggle** (`UIState.outlineLayout: OutlineLayout` — `.table` or `.cards`). Persists alongside `detailSegment`. Future modes can have their own internal options without inflating `DetailSegment`.
- **The pattern is extensible.** New right-pane modes (comments, references, glossary, etc.) can join as new `DetailSegment` cases without restructuring `ProjectWindow`. The cost of adding a new mode is: (1) new view file, (2) new enum case, (3) new switch arm in `DetailPaneToggle`, (4) optionally a new keyboard shortcut.
- **Linked-research preview specifically uses `ResearchPreview` (read-only)**, NOT `ResearchNoteEditor`. The latter goes through `DocumentStore` and would evict the active manuscript doc from the editor pane — a real bug caught in smoke before tag. Read-only side-by-side is the actual writer-useful behavior anyway.

## References

- [Writing Companion spec](../superpowers/specs/2026-05-14-writing-companion-design.md) — full DetailSegment + OutlineLayout design
- [Milestone memory: writing-companion](../../../.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_writing_companion.md) (auto-memory, not in repo)
