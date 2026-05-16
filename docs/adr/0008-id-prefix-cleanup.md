# 0008 — ID prefix cleanup: canonical scheme adopted

**Status:** Accepted
**Date:** 2026-05-16
**Supersedes:** [0007](0007-id-prefix-no-migration.md)

## Context

[ADR 0007](0007-id-prefix-no-migration.md) accepted the historic ID prefix inconsistency (manuscript: `doc-` vs `scene-`, research: `res-grp-` / `res-ast-` / `res-lnk-` / `res-doc-`) as a "won't fix" until a future Group 4 schema-versioning milestone forced the question. The reasoning at the time: a migration runner is real engineering effort, and existing project files on disk would need careful handling.

Subsequently the writer chose to clean rather than carry the inconsistency — they're working primarily with disposable test projects at this stage and are willing to discard them rather than run a migration. The cost of the cleanup is just changing the generators; the cost of staying inconsistent is callers continuing to trip over it.

## Decision

Adopt a canonical ID prefix scheme. **No migration runner.** Existing on-disk projects with old IDs are discarded, not migrated. From this point forward, all IDs use:

- `doc-<id>` — manuscript document of any extension (`.md`, `.fountain`, anything)
- `grp-<id>` — manuscript group
- `res-<id>` — research asset of any kind (`.image`, `.document`, `.pdf`, `.audio`, `.link` — kind lives in the `kind` field, not the ID)
- `res-grp-<id>` — research group
- `proj_<id>` — MCP project identifier (runtime-derived, unchanged)

The `idPrefix` computed property in `ProjectStore.swift` collapses to two cases (`document` → `doc`, `group` → `grp`) — the file extension no longer determines the prefix. Research-asset creation sites pass `"res"` to `newId`; only group creation uses `"res-grp"`.

## Consequences

- **Callers can treat any prefix as opaque.** No code paths pattern-match on prefix to determine type — `StructureItem.type` and `ResearchItem.type` / `.kind` are the authoritative discriminators. The two defensive `hasPrefix("scene-")` sites (in `ListScenesTool` and its test) become dead branches but stay as defense against future regressions.
- **Existing project files on disk become unusable.** Anyone who has projects with `scene-` or `res-ast-` prefixed IDs needs to recreate them. The writer accepted this explicitly.
- **The scene-id double-prefix carry-forward goes away.** `ListScenesTool` builds composite scene IDs as `scene-<documentId>-<lineLocation>`; with documents no longer prefixed `scene-`, the double-prefix case can't happen. The strip-prefix defensive code stays but never triggers in practice.
- **Future Group 4 schema-versioning milestone is smaller.** It no longer has to include an ID rename pass.
- **The previous ADR is superseded, not deleted.** ADR 0007 remains as the historical record of when we accepted the inconsistency and why we changed our mind.

## References

- [ADR 0007](0007-id-prefix-no-migration.md) — the prior "won't fix" decision this supersedes
