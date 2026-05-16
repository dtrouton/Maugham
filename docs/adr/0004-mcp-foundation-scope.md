# 0004 — MCP foundation scope: read + add_note + research links

**Status:** Accepted
**Date:** 2026-05-15

## Context

Once [the live-only Unix socket transport](0003-mcp-live-only-unix-socket.md) was decided, the next scope question for the MCP foundation milestone was: *what can Claude do via this transport?* Three options surfaced during the brainstorm:

- **Read-only.** Eight read tools (list_projects, get_outline, read_document, search_text, list_scenes, find_references, get_metadata, get_session_stats). No writes. Smallest test surface, fastest to ship, lowest "Claude wrote in the wrong place" risk.
- **Read + add_note (research only).** Add one write tool that only lands files under `research/`. Claude can summarize a scene into a research note, but never touches the manuscript.
- **Read + add_note + manuscript edit hints.** Full write surface including review comments adjacent to manuscript docs. Significantly more design work — needs a sandbox / proposal / review pattern.

The writer's stated use case (over the brainstorm): they want Claude to be able to drop research notes immediately ("Claude, summarize this scene into a research note"). Manuscript edits, when they come up, are a "fix small errors" use case — *not a primary flow* and the writer is open to a non-destructive approach when we do tackle it ("maybe it creates a copy of the file?").

## Decision

Foundation milestone ships **read + targeted writes**:

- **Read** (now 11 tools after pre-tag polish): `list_projects`, `get_metadata`, `get_outline`, `read_document`, `search_text`, `list_scenes`, `find_references`, `get_session_stats`, `list_research`, `list_documents_by_tag`, `list_all_links`.
- **Targeted writes** (3 tools): `add_note` (creates research notes), `link_research`, `unlink_research` (wire research to a manuscript document, reuses writing-companion APIs).
- **Explicitly deferred** to a future Group 2 milestone with its own design:
  - Update or append existing documents
  - Set status / word target / synopsis / tags
  - Create chapters, scenes, or groups
  - Programmatic wiki link insertion

## Consequences

- **Manuscript is read-only over MCP.** Claude can't accidentally edit a draft. The writer's draft surface stays uncontested.
- **Research is fair game for Claude.** Banner overlay (`MCPNoteBanner`) on `add_note` makes Claude's contributions discoverable without interrupting flow. Link/unlink are silent (matches in-app drag-drop).
- **A future "MCP Write" milestone will design the manuscript proposal pattern.** Candidate approaches noted at brainstorm time: sibling proposal file (`c1.proposed.md`), structured proposals folder (`.maugham/proposals/<doc-id>.json`), inline review marks (separate-from-text annotations with gutter UI). Each has different blast-radius vs ergonomics trade-offs.
- **Discovery gaps surfaced during smoke** and were filled before tag: `list_research` (enumerate research items so Claude can find ids), `list_documents_by_tag` (tag-axis queries), `list_all_links` (full reference graph for "what's orphaned"). These are still part of the foundation scope — they don't expand the write surface, they make reads composable.
- **Tools-list catalog is hand-maintained.** Adding a new tool means three edits: the `Tool.swift` file, the `MCPToolsListHandler` catalog entry, and a router registration in `MaughamApp.registerTools`. Tested via `test_toolsList_returnsAllExpectedTools`.

## References

- [MCP Foundation spec](../superpowers/specs/2026-05-15-mcp-foundation-design.md)
- [ADR 0003](0003-mcp-live-only-unix-socket.md) — the transport this scope rides on
- [Milestone memory: mcp-foundation](../../../.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_mcp_foundation.md) (auto-memory, not in repo) — full tool surface + carry-forwards
