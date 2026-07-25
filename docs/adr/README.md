# Architecture Decision Records

This directory captures architectural decisions made *after* the initial master design at `docs/superpowers/specs/2026-05-07-maugham-master-design.md`. The master spec is the snapshot of the design as it was on the first day; ADRs record where we've diverged from that snapshot, deliberately, since.

## Why ADRs

The master spec was getting amended inline ("Reorganized by intent (2026-05-10)…", strike-through paragraphs, new sections appended). That mixes "original vision" with "we changed our mind, here's why." ADRs separate the two: the master spec stays frozen as the initial design; each later decision gets its own short, dated record.

## Format

Each ADR is a short Markdown file in this directory, named `NNNN-kebab-case-title.md`. The numbering is sequential and stable — never renumber. The standard sections:

- **Status** — Proposed / Accepted / Superseded / Deprecated (and what supersedes if applicable)
- **Date** — when the decision was taken
- **Context** — what was true at the time; what forced the question
- **Decision** — what we chose, in one or two sentences
- **Consequences** — what changed because of this; what we now do or don't do; known limitations

Keep them short. One to two pages is the right scale. If an ADR keeps growing, it probably wants to be broken into a follow-up.

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [0001](0001-multi-file-screenplay-abandoned.md) | Multi-file screenplay (Phase 3d) abandoned | Accepted | 2026-05-10 |
| [0002](0002-roadmap-by-writer-intent.md) | Roadmap reorganized by writer intent (Groups 1–4) | Accepted | 2026-05-10 |
| [0003](0003-mcp-live-only-unix-socket.md) | MCP transport: live-only Unix socket via CLI bridge | Accepted | 2026-05-15 |
| [0004](0004-mcp-foundation-scope.md) | MCP foundation scope: read + add_note + research links | Accepted | 2026-05-15 |
| [0005](0005-right-pane-mode-swap.md) | Right-pane mode-swap pattern (Inspector / Research / Outline) | Accepted | 2026-05-14 |
| [0006](0006-trash-and-undo.md) | Trash & undo design (.trash/ folder + ⌘⌥Z) | Accepted | 2026-05-13 |
| [0007](0007-id-prefix-no-migration.md) | ID prefix inconsistency — accept, no migration runner | Superseded by [0008](0008-id-prefix-cleanup.md) | 2026-05-16 |
| [0008](0008-id-prefix-cleanup.md) | ID prefix cleanup: canonical scheme adopted | Accepted | 2026-05-16 |
| [0009](0009-collection-references-mac-local.md) | Collection references are Mac-local; iCloud cross-Mac is best-effort | Accepted | 2026-05-16 |
| [0010](0010-typed-cross-area-seams.md) | Type-driven cross-area contracts (typed seams + integration tests) | Accepted | 2026-05-20 |
| [0012](0012-per-device-jsonl-partitioning.md) | Per-device JSONL file partitioning for multi-writer sidecars | Accepted | 2026-05-24 |
| [0011](0011-tasks-first-class-with-inline-anchors.md) | Tasks first-class with inline anchors | Proposed | 2026-05-25 |
| [0013](0013-publishing-pipeline.md) | Publishing pipeline: Claude-authored bespoke typography | Accepted | 2026-05-29 |
| [0014](0014-backup-and-integrity.md) | Backup & integrity: filesystem-only, integrity-gated, restore-beside | Accepted | 2026-06-07 |
| [0015](0015-persisted-schema-evolution.md) | Persisted-schema evolution: schemaVersion gate + graceful enum/field decoding | Accepted | 2026-06-08 |
| [0016](0016-op-log-growth-without-compaction.md) | Op-log growth without compaction: keyframed sequence + sealed compressed segments + derive cache | Accepted | 2026-06-09 |
| [0017](0017-editor-control-plane.md) | Editor control plane: an observed `EditorControl` model, not `updateNSView`/notifications | Accepted | 2026-06-27 |
| [0018](0018-manuscript-reads-derive-from-oplog.md) | Manuscript reads always derive from the op log (never the `.md`); enforced by a tripwire | Accepted | 2026-06-28 |
| [0019](0019-clean-md-on-disk.md) | Manuscript files on disk are clean Markdown/Fountain (anchors live only in the op log) | Accepted | 2026-06-29 |
| [0020](0020-dev-only-test-mcp.md) | Dev-only privileged Test MCP for Claude Code | Accepted | 2026-07-01 |
| [0021](0021-scoped-window-events.md) | Window events are scoped at the post site (typed event bus over NotificationCenter) | Implemented | 2026-07-02 |
| [0022](0022-commonmark-fountain-ledger.md) | CommonMark + Fountain grammar ledger | Implemented | 2026-07-06 |
| [0023](0023-unified-oplog-backed-undo.md) | Unified op-log-backed ⌘Z undo: compensating ops on one native stack | Accepted | 2026-07-10 |
| [0024](0024-translation-layer.md) | Translation layer: a second Claude-parallel data plane | Accepted | 2026-07-22 |
| [0025](0025-persona-shell.md) | Persona shell: four optional lenses over one project (Plan/Author/Review/Publish) | Accepted | 2026-07-25 |

## How to write a new ADR

1. Pick the next sequential number.
2. Copy `0001-multi-file-screenplay-abandoned.md` as a template — its structure is canonical.
3. Land the file with a Status of `Proposed` if it's still open for discussion, or `Accepted` if the decision is already taken.
4. Add an index row above with the same metadata.
5. If this ADR supersedes an older one, update the older one's Status to `Superseded by 00NN` and add a back-link.

Don't retroactively backfill ADRs for trivial decisions. The bar is: *would someone reading the code six months from now be confused about why this is the way it is?* If yes, it's an ADR.
