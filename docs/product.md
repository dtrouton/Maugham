# Maugham — What It Is

*Written for a smart outsider. Facts only, including the unflattering ones. The opinions live in [`constitution.md`](constitution.md); the demand-side job map in [`problem-map.md`](problem-map.md).*

## What it is

Maugham is a Mac-native focus text editor for serious creative writing — prose, novels, screenplays, and mixed collections — with an iPhone companion for capture, reading, and review on the go. It is built in Swift, SwiftUI, and AppKit. An AI collaborator connects from outside the app: Claude Desktop attaches through a local socket, reads the manuscript, and annotates it. The integration contains no tools that edit manuscript text.

The name is after W. Somerset Maugham, a working writer's writer.

## Who uses it

One person: its author, who is writing fiction in it daily. That is the honest userbase today, and the noncommercial source license reflects it. It is built, however, as if for a real audience: serious creative writers who want AI as reader, researcher, and production assistant — not a ghostwriter — and who want their manuscript in plain text they own.

## What it does

Organized by what a writer is doing, not by feature list:

**Writing.** A focused editor with a centered column, typewriter scrolling, sentence- and paragraph-level focus dimming (⌘\), smart typography, and per-project fonts and themes. Prose is Markdown; screenplays are Fountain with full per-element styling, Tab-cycling between elements, scene numbers, dual dialogue, page counts, and a title page. Saving is automatic; ⌘S instead writes a *labeled checkpoint* — a named moment you can return to — and flashes on use.

**Structuring.** Four project types (Short Story, Novel, Screenplay, Collection). A Binder sidebar holds the pieces — drag to reorder, group into acts and chapters. An Inspector carries per-piece synopsis, status, tags, and word targets. Outline and corkboard views give the aerial picture; `[[wiki-links]]` connect pieces to each other and to research.

**Research.** A research browser lives beside the draft — notes, images, PDFs — plus a *sensory palette*: subject-keyed cards (a character, a place) holding color swatches, reference images, and sense-tagged notes, paired with an optional craft-intent document stating what the story needs sensorially.

**Working with Claude.** A bundled local MCP server exposes 54 tools to Claude Desktop. Claude can read everything — binder, manuscript, research, wiki-graph, tasks, palette, planning canvas — and can *propose*: comments, queries, craft notes, and suggested changes, all anchored to specific paragraphs. It can also add cards to the **planning canvas**, which is the one surface it writes to besides research: the case built for is a page the writer filled by hand and photographed, and Claude cannot choose where a card lands — every batch arrives in one labelled region beside the page it was read off, drawn perfectly straight where the writer's cards lean, and one ⌘Z takes the whole batch back. Proposals land in an Annotations pane where the writer accepts, rejects, or archives each one; the MCP layer has no tools that modify manuscript text. Claude can also translate the book into another language (a parallel, paragraph-keyed layer — the source manuscript never changes), compile it (below), and answer help questions from the same guide the app ships.

**Capturing on the go.** The iPhone app captures text, photos, and voice notes into a per-project inbox; voice is transcribed on the Mac by a local Whisper model. Captures can be aimed at a palette subject in the moment. On the Mac, inbox entries are promoted into research, palette cards, or notes. The phone also reads the manuscript and triages Claude's annotations away from the desk.

**Publishing.** Claude co-authors a per-project LaTeX template tuned to the writer's typographic taste, and the app compiles it to a bespoke PDF with a bundled TeX engine (tectonic) — no TeX installation required — or to a standard EPUB. A project can also compile a translated edition once Claude has filled in the translation layer for that language; a coverage gate blocks a compile that would ship stale or missing paragraphs unless the writer explicitly allows a partial preview. Output lands in the project's `Exports/` folder.

**Keeping the words safe.** Autosave (750ms), labeled checkpoints, unified undo across every kind of change, per-document History Rewind (scrub back through every edit ever made), trash-not-delete for binder operations, integrity-checked backups to any local or cloud-synced folder, and self-healing for a corrupted project manifest. The words are plain text on disk at all times.

## How it's structured

Five parts, one repository:

- **The Mac app** (`Maugham/`) — the full writing environment.
- **The iPhone app** (`MaughamPhone/`) — capture, read, review; not an editor.
- **MaughamCore** (`Packages/MaughamCore/`) — a shared Foundation-only package holding everything both surfaces need: the operation log, the Fountain parser, the data models. A tripwire test suite enforces that the phone never reimplements what the Mac owns.
- **The MCP bridge** (`maugham-mcp/`) — a small CLI that connects Claude Desktop's stdio to the Mac app's Unix socket. Live-only: Claude can only reach projects that are open in a running Maugham.
- **The docs** (`docs/`) — a user guide (served identically in-app, to Claude, and on GitHub), ADRs recording every architectural decision, and dated specs and plans for each milestone.

The central architectural idea is the **operation log**: every edit to a manuscript is an append-only operation in a per-document journal. The `.md`/`.fountain` files on disk are *derived* from that log — clean, standard, portable plain text, readable by any tool forever — but the log is the truth. This buys conflict-free sync between Mac and phone (each device appends to its own file; iCloud Drive never has to merge), a complete forensic history, rewind to any point, and undo that spans every kind of change. The cost is discipline: all editing must flow through Maugham, and an outside edit to the `.md` is deliberately discarded.

Distribution is grown-up: signed and notarized `.dmg` releases with silent in-place auto-update on the Mac, TestFlight for the phone, tag-driven CI for both.

## How it's built

The author of Maugham does not write code. Every line is written by Claude via Claude Code's agent-driven workflow: each milestone is brainstormed into a spec, planned into tasks, and dispatched to subagents; decisions land as ADRs; hard-won lessons become tripwire tests and memory files so they are never relearned. The repository is as much a record of that working method as it is a codebase — roughly two months old at this writing, with 20+ ADRs and a per-milestone paper trail under `docs/superpowers/`.

## The unglamorous truth

What the marketing paragraph above won't tell you:

- **The userbase is one.** Nobody else has installed it. Everything claimed about "writers" is really a claim about one writer plus conviction.
- **The safety net is largely untested by disaster.** History Rewind and the backup system are insurance that has rarely been drawn on in anger. They are well-tested in code and barely tested by life.
- **The newest surfaces are unproven.** The sensory palette, craft intent, and the tasks layer shipped recently and haven't yet demonstrated they earn their place in a real writing practice.
- **The writer statistics are interesting more than useful.** Session tracking, activity views, project statistics — pleasant to look at, not yet load-bearing for the actual writing. Screenplay statistics still render novel-shaped ("words by chapter" for a one-file screenplay).
- **There is no screenplay intelligence.** No character autocomplete, no slugline reuse, no prefix completion. An earlier attempt at multi-file screenplays was abandoned outright, and a screenplay is now a single Fountain file.
- **Maugham is strictly single-writer.** No collaboration or human-reviewer capability exists.
- **The Annotations and History panes still confuse** — sibling tabs with opposite affordances and no onboarding hint.
- **Some polish is testing-driven, not use-driven.** A few shipped features have been exercised more thoroughly by their test suites and release smokes than by actual writing sessions.

A fair summary of Maugham: a genuinely solid foundation (editor, op log, sync, safety, publishing, the annotation layer) with a set of newer surfaces that have not yet proven themselves in use.
