# 0001 — Multi-file screenplay (Phase 3d) abandoned

**Status:** Accepted
**Date:** 2026-05-10

## Context

The master spec ([2026-05-07](../superpowers/specs/2026-05-07-maugham-master-design.md)) listed multi-file screenplay projects as a Phase 3 deliverable: a screenplay could optionally be one `.fountain` file per scene, with the binder navigating between them.

We attempted this as milestone 3d. The implementation strategy was a "compound editor" — an `NSTextStorage` subclass that presents a single contiguous stream over multiple on-disk files, so the writer reads the script as one continuous flow but the binder lets them jump to individual scenes.

T1–T22/25 of the milestone shipped on a branch before we abandoned. Smoke surfaced loading pauses, wrong-destination clicks, the editor pane jumping mid-edit, and undo behavior that fought NSTextView's own caches. The complexity wasn't isolated: every interaction with selection, layout, find, autosave, and undo had to be re-derived under the compound storage.

The deeper issue: the **value** of multi-file screenplay is letting the writer read the script as one continuous stream. Single-file already provides that natively — and reading is the primary value, not file-per-scene. Treating each scene as its own document loses the continuous-stream reading flow.

## Decision

Abandon multi-file screenplay. Phase 3 ships at milestone 3c (title page, scene navigator, page-position math, inline emphasis, syntax help). The durable single-file screenplay surface is the final shape.

## Consequences

- **What's lost:** the ability to organize a screenplay as one folder of files, one per scene. Not currently a missed feature in practice.
- **What's gained:** NSTextView keeps its native behavior — caret position, layout, undo, find, autosave all work the way the OS expects. Selection bugs, layout jitter, and undo divergence go away.
- **Scene navigation** is implemented as a UI overlay on the parsed Fountain script (the `SceneNavigatorPane`), not as separate documents on disk. The binder shows scenes by parsing slug lines; clicking scrolls within the single document rather than switching files.
- **The MCP `list_scenes` tool** (see [ADR 0003](0003-mcp-live-only-unix-socket.md)) walks every `.document` and parses Fountain on demand. It survives this decision because it doesn't assume one-file-per-scene.
- **Branch artifacts:** the 3d branch was deleted after abandonment. The dated design + plan documents remain at `docs/superpowers/specs/2026-05-10-maugham-phase-3d-design.md` and `docs/superpowers/plans/2026-05-10-maugham-phase-3d.md` as historical record.

## References

- [Milestone 3d abandonment memory](../../../.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_3d_abandoned.md) (auto-memory, not in repo)
- `docs/superpowers/specs/2026-05-10-maugham-phase-3d-design.md` — what we attempted
- `docs/superpowers/plans/2026-05-10-maugham-phase-3d.md` — task breakdown
