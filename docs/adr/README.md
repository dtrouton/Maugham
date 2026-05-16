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

## How to write a new ADR

1. Pick the next sequential number.
2. Copy `0001-multi-file-screenplay-abandoned.md` as a template — its structure is canonical.
3. Land the file with a Status of `Proposed` if it's still open for discussion, or `Accepted` if the decision is already taken.
4. Add an index row above with the same metadata.
5. If this ADR supersedes an older one, update the older one's Status to `Superseded by 00NN` and add a back-link.

Don't retroactively backfill ADRs for trivial decisions. The bar is: *would someone reading the code six months from now be confused about why this is the way it is?* If yes, it's an ADR.
