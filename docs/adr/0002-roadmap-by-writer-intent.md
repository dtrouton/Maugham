# 0002 — Roadmap reorganized by writer intent (Groups 1–4)

**Status:** Accepted
**Date:** 2026-05-10

## Context

The master spec ([2026-05-07](../superpowers/specs/2026-05-07-maugham-master-design.md)) sketched the roadmap as a linear sequence of phases (1 → 2 → 3 → 4 → 5 → 6), each phase a coherent capability bundle. By the time Phase 3 wrapped — and especially after [Phase 3d was abandoned](0001-multi-file-screenplay-abandoned.md) — the linear sequence stopped describing how the work was being prioritized in practice.

Several observations forced the question:

- Some Phase 2 deliverables had already shipped during Phase 1 (binder right-click, status indicators, multi-document handling via DocumentStore).
- Phase 4 (Compile) wasn't actually next; the writer wanted research-polish features that the linear plan put further out.
- Some features didn't belong to any one phase — e.g., cross-document find/replace is "Phase 2-ish" but useful at every phase.
- Foundational reliability work (snapshots, backups, distribution) lived in Phase 5+ but kept coming up as needed earlier.

## Decision

From milestone 3c forward, the roadmap is organized by **writer intent**, not by linear phase. Four parallel groups:

- **Group 1 — Editing flow polish.** Daily-writing improvements: research polish, find/replace, structure views, screenplay intelligence, mood boards.
- **Group 2 — Claude integration.** AI assist: the MCP server (foundation), then handwritten import, voice notes, prompt templates, Claude companion view.
- **Group 3 — Publishing flow.** Delivery: compile to Word/EPUB/PDF, screenplay-specific production polish, submission tracker, mixed-content collections.
- **Group 4 — Foundations & safety.** Reliability: snapshots, manifest schema versioning, performance, distribution (signing/notarization), templates, welcome experience.

Groups are independent. Each group has a "next up" recommended first milestone, but the writer picks what to work on next based on day-to-day friction, not a linear order.

## Consequences

- **Milestone naming** stopped being phase-numbered. From 3d onward, milestones are named by intent (`milestone-research-polish`, `milestone-find-replace`, `milestone-writing-companion`, `milestone-mcp-foundation`, etc.). Tags follow the same convention.
- **Phase 1–3 history is preserved** in the master spec as historical record; Phases 4–6 of the master spec are effectively superseded by the group structure.
- **The deferred surfaces list** (iPad companion, shared folder collaboration, calendar widget) is unchanged — those are still outside the roadmap.
- **Sequencing notes** in the master spec call out the recommended starting milestone for each group and the dependencies between them (e.g., Group 2's foundation can start anytime after Group 1's first milestone).
- **Each shipped milestone gets a memory entry** capturing what shipped + carry-forwards. The roadmap doesn't try to be exhaustive about completed work; that's what memory and the dated milestone plans are for.

## References

- Master spec, Section 6 — the legacy linear Phase 1–6 view (kept intact as the pre-reorg snapshot)
- `docs/superpowers/notes/2026-05-08-phase-2-breakdown.md` and `2026-05-09-phase-3-breakdown-and-handoff.md` — earlier breakdowns that hinted at the group structure before it was named
