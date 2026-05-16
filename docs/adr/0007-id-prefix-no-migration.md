# 0007 — ID prefix inconsistency: accept, no migration runner

**Status:** Accepted
**Date:** 2026-05-16

## Context

IDs in Maugham use different prefix schemes depending on what kind of thing they identify:

- `proj_*` — MCP project identifier (runtime-derived from SHA1 of canonical path, not persisted)
- `doc-*` — manuscript document `StructureItem.id` (created by some binder code paths)
- `scene-*` — manuscript document `StructureItem.id` (created by other binder code paths, notably newer screenplay-related flows)
- `res-doc-*`, `res-ast-*`, `res-grp-*`, `res-lnk-*` — research item IDs, prefix varies by `AssetKind`
- `grp-*` — manuscript group `StructureItem.id`

The mix mostly went unnoticed until [MCP Foundation](0003-mcp-live-only-unix-socket.md) made the IDs visible to Claude — at which point pattern-matching agents tripped over the inconsistency ("`doc-` for one document, `scene-` for the next").

Two of these mixes are persisted on disk (in `project.maugham.json` manifests for every existing project):

- The `doc-` vs `scene-` mix on structure items
- The `res-doc-` / `res-ast-` / `res-grp-` / `res-lnk-` family for research

A migration would need to:

1. Walk every project's `project.maugham.json` and rename IDs to a canonical scheme
2. Update `linkedResearchIds` arrays to reference the new IDs
3. Bump `manifest.schemaVersion` and add an in-place migration runner that fires on load when an old version is detected
4. Reset saved `selectedItemId` in `.maugham/ui-state.json` to a fallback when it points at a renamed ID

That's the kind of work that fits a [Group 4](0002-roadmap-by-writer-intent.md) "Manifest schema versioning" milestone — and is real engineering effort.

## Decision

**Accept the inconsistency. No migration runner.** The writer is currently working with disposable test projects; they're fine to delete and re-create against the canonical-prefix scheme whenever a future milestone decides to clean it up.

For real (non-test) project files, the cost of running a migration outweighs the benefit — IDs are opaque to the user, callers shouldn't pattern-match on prefix anyway, and the foundation's correctness doesn't depend on the prefix being uniform.

## Consequences

- **No schema versioning runner is needed yet.** The day we DO need one (e.g., when a future milestone adds a non-additive manifest change), the runner can include the prefix cleanup as a free byproduct.
- **Callers must treat IDs as opaque strings.** Don't pattern-match on prefix to determine type — always check `StructureItem.type` or look up the item.
- **MCP responses include a documented warning.** The `list_scenes` tool's scene `id` field is composite (`scene-<documentId>-<lineLocation>`) and may visually double the `scene-` prefix when the underlying document ID also starts with `scene-`. We strip the redundant prefix when constructing the composite — but the scene `id` is opaque to callers; primary addressing is `(document_id, page_start)`.
- **Future cosmetic cleanup is cheap once the migration story exists.** Pick a canonical prefix (`doc-*` for documents, `grp-*` for groups, `res-*` flat for research) and rename in a single migration pass when Group 4's schema versioning milestone lands.

## References

- [ADR 0003](0003-mcp-live-only-unix-socket.md) — MCP transport, where the prefix mix became visible to callers
- Master spec, Group 4 — "Manifest schema versioning" deferred work
