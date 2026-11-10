# ADR 0034 — The assistant may rewrite a Research note

**Date:** 2026-11-10 · **Status:** Accepted · **Milestone:** typing loop and note versions (plan 2, Task 6; branch `claude/typing-loop-and-note-versions`)

## Context

Over MCP the assistant could create a Research note (`add_note`, [ADR 0004](0004-mcp-foundation-scope.md)) but not change one. When a writer asked Claude to revise a note, the only way was to edit the `.md` file on disk. That write was:

- **unattributed** — nothing recorded that the text was the assistant's;
- **unversioned** — the writer's text was gone, with no Restore;
- **lost under an open editor** — the editor still held the old text, and its next save put it back over the assistant's.

Plan 2 of the note-versions milestone gave every Research note one write door (`ResearchNoteDoor`, through `DocumentStore.saveResearchNote`), which keeps the text it replaces as a version, records who wrote the text now on disk, and tells an open editor to reload. Research tables already had the same through `write_research_cells` and the table's door. The owner ruled on 2026-11-10 that this milestone adds the note tool.

## Decision

**One tool, `update_note(project_id, research_id, body)`, replaces the whole body of an existing Research note, through the note door, as the assistant** (`saveResearchNote(by: .assistant)`).

- It always keeps the previous text as a version (an open editor's unsaved edit is saved first and is that version), marked **Before the assistant’s change**; the writer restores it from the note's inspector (Versions). The text the assistant wrote is recorded as the assistant's, so a later version of it lists as **Written by assistant**.
- It takes Research notes only — what `ResearchTextRole.of` calls a note, asked directly so a palette card stays refused whatever pending ruling P2 decides. A note's path must sit under a research root (`research/…` or a loose piece's own `research/` folder, no component starting with "."), so a synced manifest item naming the manuscript or a `.maugham/` file is refused as not a Research note Maugham can change, and the note door writes no such path for anyone. Any other id is refused with a sentence naming what it is: a manuscript document, a figure, a statement, a table, a picture, a PDF, a recording, a web link, a palette card or a group.
- A view-only share refuses it before anything is read. When the door cannot save, the call fails and says the note was not changed; there is no retry and no raw file write.
- It is a write tool: not in `CompilerAllowlist`, listed in `CompilerAllowlistTests.writeTools`. The response names the note (`id`, `title`, `path`, `kept_previous_version`) and never carries its body.

## Consequences

- The planning plane's `research/` destination now has a rewrite as well as a create; the membrane rule in `Maugham/MCP/AREA.md` lists it.
- The writer can undo any rewrite from the inspector, and an open note shows the assistant's text at once instead of overwriting it.
- Every rewrite costs one version file; retention is the door's (50 per note per device).
- No new UI event: the inspector's versions and the open editor already follow the door. The "Claude added a note" banner stays about creation.

## What it deliberately does not do

- **No manuscript.** MCP never writes manuscript text (ADR 0004); a suggestion stays an annotation.
- **No palette cards.** They have no versions yet (pending ruling P2) and keep their own writer.
- **No tables.** `write_research_cells` and `create_research_table` are their door.
- **No partial or patch edits.** The body is replaced whole; the assistant reads the note first with `read_document`.
