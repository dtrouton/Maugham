# Skills over MCP — Maugham-served agent skills + bootstrap

**Date:** 2026-07-18
**Status:** Implemented (branch `feat/skills-over-mcp-2026-07-18`, 2026-07-18)

## Problem

The writer wants Claude to carry two procedures reliably: the notebook-photo
transcription workflow (now run through Claude Code after the Claude Desktop
image regression, see `docs/superpowers/notes/2026-07-17-claude-desktop-image-block-bug.md`)
and an editing-pass procedure. Today that knowledge lives in the writer's
prompts. Agent Skills are the right container, but no shipping client loads
skills from an MCP server — while the MCP community is actively standardizing
exactly that: the **Skills Over MCP Working Group**
(modelcontextprotocol.io/community/working-groups/skills-over-mcp) and
**SEP-2640 — Skills Extension** (Extensions Track, Resources-based, open PR,
28 commits as of 2026-07-15). Direction requested by the user: follow the
emerging standard.

**Constraints discovered in brainstorm:**
- SEP-2640 is an unmerged draft that is still churning → implement behind one
  seam, pin the targeted revision, expect drift.
- No client consumes the extension yet → today's delivery must ride the one
  MCP primitive models invoke autonomously (tools), plus a local bootstrap
  skill in Claude Code.
- Editing guidelines are per-project → they live in craft intent (existing
  machinery); the skill is the app-owned *procedure*, which reads craft
  intent first.

## Design

One content source, three delivery surfaces, two install affordances.

### 1. Skill content — bundled, single-sourced

New `docs/skills/<name>/SKILL.md`, agentskills.io format (YAML frontmatter:
`name`, `description`; markdown body). Two skills ship:

- **`transcribing-notebooks`** — the image-transcription procedure:
  `list_research` to find pages; `read_document` at sensible sizes
  (default→1350px; `region` crops for hard lines); transcriptions written via
  `add_note` into the piece's research (never the manuscript — hard
  invariant); continuity checks against previously transcribed pages; honesty
  rule: mark illegible passages `[illegible]`, never reconstruct.
- **`editing-pass`** — the app-owned procedure: read `read_craft_intent`
  for THIS project first (the writer's per-project guidelines); work through
  the annotation layer (`add_comment` / `add_suggested_change` / `add_query`),
  never direct edits; scope and batching conventions.

Loader: `SkillIndex` (Mac target, modeled on `HelpTopicIndex`) — parses
frontmatter, exposes name/description/body/files. The **same files** feed all
three surfaces below; no second copy anywhere (same discipline as
`docs/guide/`, workflow rule "docs describe what ships").

### 2. Standards surface — SEP-2640, pinned, one seam

New seam `Maugham/MCP/SkillsExtension.swift` (all SEP knowledge lives here):

- `initialize` capabilities declare extension id
  **`io.modelcontextprotocol/skills`** (exact capability JSON shape verified
  against the SEP text at implementation time — the draft's prose says
  "include the identifier in capabilities"; pin whatever shape the
  reference implementation uses).
- **`skills/list`** — returns all bundled skills, cursor-pagination-shaped
  (single page). Entry shape per draft: `name`, `description`, `uri`
  (`skill://<name>/SKILL.md`), `frontmatter` (YAML rendered as JSON),
  `resources` (`[{uri, digest: "sha256:<hex>"}]` for every file in the
  skill folder).
- **`skills/get`** — single-skill lookup by SKILL.md URI; unknown URI →
  protocol error `-32602` (per draft), not a silent empty.
- **`resources/read`** — implemented narrowly for `skill://` URIs only;
  any other URI fails loudly. (Maugham's server has no resources support
  today; this stays scoped to skills until something else needs it.)
- Digests computed at load from bundled bytes; contract test asserts
  digest(listed) == sha256(read bytes) so the integrity promise holds.
- A `// SEP-2640 rev 2026-07-15` pin comment + one doc paragraph in
  `Maugham/MCP/AREA.md`; when the SEP merges or drifts, this seam is the
  only place to touch. These are protocol methods (router-level, like
  `tools/list`), NOT tools — tool count stays 48.

### 3. Today-compat surface — get_help + tool nudges

- `get_help` serves each skill body as a topic (topic id = skill name) plus
  a tiny **`skills` index topic** listing available skills with one-line
  descriptions. Served through the same loader; frontmatter stripped for
  display.
- Tool-description nudges (the auto-trigger for clients without skills):
  `read_document` gains one sentence pointing at
  `get_help("transcribing-notebooks")` for notebook transcription;
  `add_suggested_change` (or `add_comment`) gains one pointing at
  `get_help("editing-pass")`. Known blast radius: tools-list snapshot tests.

### 4. Bootstrap skill + install affordances (UI)

- Bundled template `maugham/SKILL.md` — the router: description tuned to
  trigger on Maugham-related work; body ≈ "Maugham serves its own skills
  over MCP: call `get_help('skills')` for the index, load the relevant
  skill with `get_help(<name>)`, follow it." Static by design; deletable
  the day clients speak SEP-2640.
- **MCP setup sheet** gains a Claude Code section:
  1. *Install Claude Code skill* — writes the router to
     `~/.claude/skills/maugham/SKILL.md`. States: not installed / installed
     current / stale (byte-compare against bundled template → offer update),
     mirroring the `ClaudeDesktopConfig.detect` state pattern. Plain
     `FileManager` write outside any project (not the typed mover — that
     seam is for project user content; this is app-support-style config).
  2. *Connect Claude Code* — a copyable CLI command, variant-aware via
     `BuildVariant` (tripwire 13):
     stable → `claude mcp add maugham /Applications/Maugham.app/Contents/MacOS/maugham-mcp`;
     dev → `claude mcp add maugham-dev <dev bundle binary>` + the
     `MAUGHAM_MCP_SOCKET` env flag. Copy button; no shelling out to
     `claude` (the command is documentation, not execution).
- Bootstrap skill is variant-neutral (names both `maugham`/`maugham-dev`
  server prefixes? No — keep it simple: it references tool names bare,
  which Claude Code prefixes per-server; body stays server-name-agnostic).

### 5. Explicitly out of scope

- Phone: nothing (Mac + MCP only; MaughamCore untouched).
- Dynamic/per-project skills over MCP (craft intent already covers
  per-project guidance; revisit if the SEP's dynamic-skill story matures).
- Skill authoring UI in-app; skills are repo-authored, app-bundled.
- `skill://index.json` catalog convention (aaif.io post) — the draft SEP's
  `skills/list` supersedes it for our size; note in AREA.md.
- Uploading skills to claude.ai/Desktop capabilities; revisit when Desktop
  fixes tool-result images.

## Error handling

- `skills/get` unknown URI → `-32602` protocol error (per draft).
  `resources/read` non-`skill://` URI → loud tool-layer error, catalog
  policy. `get_help` unknown topic already fails loudly.
- Skill bundle malformed at load (bad frontmatter) → fail loudly at server
  init in dev; skip-with-log in release (a broken skill must not take down
  the whole MCP server).
- Router install: file-write failures surface in the sheet; stale detection
  never overwrites without the user clicking update.

## Testing

- `SkillIndex` loader: frontmatter parse, body, per-file digest stability.
- SEP surface contract tests: capability declared; `skills/list` shape
  (entry fields, uri scheme, digest format); `skills/get` known/unknown;
  `resources/read` round-trip bytes match digests; non-skill URI fails.
- `get_help`: skills index topic + per-skill topics resolve; unknown still
  fails.
- Tools-list snapshots updated for nudged descriptions (count stays 48).
- Router install state machine: not-installed → installed → stale (mutate
  file) → update restores; write-failure surfaces.
- MCP pre-smoke (established lesson): `mcp__maugham_test__*` against the dev
  app — get_help skills topics readable; skills/list via raw socket probe
  (script exists from the 2026-07-17 investigation).
- Manual smoke: setup sheet → install skill → new Claude Code session →
  "transcribe the next notebook page in Playlist" fires router →
  get_help chain → correct workflow followed; copy CLI command works.
