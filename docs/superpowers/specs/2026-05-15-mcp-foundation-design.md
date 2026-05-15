# Maugham MCP Foundation — Group 2 milestone 1

**Goal:** Expose Maugham projects to Claude Desktop via a local MCP server so writers can ask Claude about their work and have it create research notes, without leaving the editor.

**Sets up:** all later Group 2 milestones (handwritten note import, prompt templates, voice notes, Claude Code companion view). Foundation here = the protocol surface + the running pipe; later milestones build on top.

**Reference:** master spec `2026-05-07-maugham-master-design.md` § Group 2.

---

## Decisions locked during brainstorm

1. **Live-only architecture.** MCP only works when Maugham is running. No disk-fallback path. Eliminates staleness, autosave coordination, and conflict semantics — Claude always sees current in-memory state.
2. **All open projects visible.** Every tool takes a `project_id`; `list_projects` returns currently-open windows. Closed projects aren't reachable until the user opens them in Maugham.
3. **Read + `add_note(research)` scope.** Eight read tools + one write tool that only creates files under `research/`. Manuscript stays read-only. Manuscript edit proposals defer to a later milestone with its own design.
4. **One-click Configure Claude Desktop.** Atomic merge into `claude_desktop_config.json` with a manual-snippet fallback for corrupt configs. Replaces the existing filesystem-MCP recommendation entirely.
5. **CLI-bridge runtime.** `maugham-mcp` binary inside the app bundle bridges Claude Desktop's stdio MCP to Maugham via a Unix socket. Two small testable pieces vs one tangled one.

---

## Architecture

### Bundle structure

- New Xcode target `maugham-mcp` (Swift CLI, ~200–300 LOC) producing a binary at `Maugham.app/Contents/MacOS/maugham-mcp`.
- Statically linked. Shares no code with the Maugham app target. Imports only standard library + Foundation.
- Its job: read JSON-RPC from stdin → forward to socket → read response from socket → write to stdout.
- Owns one local concern: synthesizing MCP error responses for cases where Maugham isn't reachable.

### IPC between binary and Maugham

- Unix domain socket at `~/Library/Application Support/Maugham/mcp.sock`.
- Wire format: line-delimited JSON-RPC 2.0 — the same format Claude Desktop already speaks. Binary forwards bytes; minimal protocol parsing.
- Maugham implements real JSON-RPC server semantics, testable directly against the socket without involving the binary.

### MCPServer inside Maugham

- New `MCPServer` actor in the Maugham target, owned by `MaughamApp`.
- Binds the socket on app launch (when `mcpEnabled` is true); unlinks on terminate.
- Maintains a registry `[ProjectId: ProjectStore]`. `MaughamApp` registers a project when its window opens, unregisters on close.
- Each accepted socket connection runs its own JSON-RPC loop.
- Tool dispatch lives in `MCPServer.handle(method:params:)` — small handler functions per tool, each using existing `ProjectStore` APIs.

### Project ID

- `project_id` = `"proj_" + SHA1(canonical project folder URL)`.
- Survives window title renames. Breaks if the folder is moved on disk — acceptable since the user re-opens the moved project in Maugham anyway.

### Server lifecycle

- Always on when Maugham runs (subject to the Settings toggle).
- No `Start MCP Server` menu item.
- Toggle off → socket is unbound → binary returns `mcp_disabled`.

### Error model

Three Maugham-specific error codes, all returned over the wire as JSON-RPC errors:

| Code | Meaning | Where it's synthesized |
|---|---|---|
| `-32001 maugham_not_running` | Binary couldn't reach socket | Binary |
| `-32002 project_not_open` | `project_id` not in registry | MCPServer |
| `-32003 mcp_disabled` | User toggled off in Settings | MCPServer (socket stays bound while Maugham is running, but every incoming request returns this error — preserves the user-actionable distinction between "Maugham closed" and "MCP turned off") |

Standard JSON-RPC errors (`-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal error) cover everything else. Internal errors get short messages over the wire; full detail stays in Maugham's local log.

---

## Tool surface

All tools take `project_id: string` except `list_projects`. Schemas are sketches — names match the master spec; details may refine during implementation.

### Read

**`list_projects() → [Project]`**
Returns currently-open projects: `{ id, title, type (novel/short-story/screenplay/collection), path }`.

**`get_outline(project_id) → Outline`**
Hierarchical structure. Each node: `{ id, title, type (document/group), status?, synopsis?, word_count?, word_target?, page_count? (screenplays only), children? }`. Reads `manifest.structure` enriched with `ProjectStore.cachedWordCount(for:)`.

**`read_document(project_id, document_id) → DocumentContent`**
Returns `{ id, title, path, mode (prose/screenplay/fountain), text, word_count, character_count, tags?, links? }`. `text` is the **live in-memory** content if the doc is open in the editor, else disk content. This is the live-only payoff. No structured Fountain parsing in v1 — raw source; Claude is good at parsing both Markdown and Fountain.

**`search_text(project_id, query, options?) → [SearchMatch]`**
Reuses `ProjectSearchEngine` from the find-replace milestone. Returns grouped matches with line context. Options: `case_sensitive`, `whole_word`. No regex in v1.

**`list_scenes(project_id) → [Scene]`**
Screenplay-only. Returns `{ id, heading, page_start, page_length, document_id }` parsed from `lastParsedScript`. Empty array (not an error) for non-screenplay projects.

**`find_references(project_id, target) → [Reference]`**
`target` is either a `document_id` or a `research_id`.
- Document target: every `[[wiki link]]` in the manuscript that resolves to it (reuses milestone 2c's wiki-link resolver).
- Research target: every chapter whose `linkedResearchIds` contains it (reuses writing-companion's link API).

Returns `{ from_id, from_title, kind (wiki/linked_research), context? }`.

**`get_metadata(project_id) → Metadata`**
`{ title, type, author?, created, modified, targets? (totalWords/pageTarget), tags_in_use, research_count }`.

**`get_session_stats(project_id, range?) → SessionStats`**
Reads `SessionLog`. `range` defaults to last 30 days. Returns `{ daily: [{date, words_written, minutes}], total_words, total_minutes }`.

### Write

**`add_note(project_id, title, body, parent_group_id?) → ResearchItem`**
Creates a new `.document`-kind research item under `research/` (or a sub-group if `parent_group_id` is supplied and validated). Goes through the existing research-create path (slugifier, manifest mutation, autosave) — behaves identically to "New Text Note" in the binder.

- **Never** writes outside `research/`.
- `parent_group_id` is validated against the current manifest; invalid → `-32602 invalid_argument`.
- On success, posts `maughamMCPNoteAdded` notification → triggers the banner UX.
- Filename collisions handled by the same `-2`/`-3` slug dedup the New Text Note path uses.

---

## Onboarding (Set up Claude Desktop)

### Menu

- Single item: `Help → Set up Claude Desktop…` (existing). The old `maughamShowClaudeDesktopHelp` notification + sheet keep their names; the sheet body is replaced. No new menu items.

### Sheet — one view, three states by `~/Library/Application Support/Claude/claude_desktop_config.json` detection

**State 1 — Claude Desktop not installed (config file missing)**
- Headline: "Claude Desktop isn't set up yet."
- Body: one paragraph explaining Claude Desktop + why connecting helps.
- Primary: `Open claude.ai/download` button (opens URL).
- Disclosure `Show manual setup` reveals the snippet for power users / non-Desktop clients.

**State 2 — Config exists, no Maugham entry**
- Headline: "Maugham isn't connected to Claude Desktop yet."
- Body: 3–4 lines summarizing what Claude will be able to do (read projects, search, add research notes).
- Primary: `Configure` — writes the merged config atomically (write `.tmp` sibling, fsync, rename), preserving other apps' `mcpServers` entries.
- After success: "Restart Claude Desktop to apply." with a `Quit Claude Desktop` button (`NSRunningApplication` quit; we don't relaunch — the user verifies).
- Disclosure: `Show manual setup` (snippet + `Reveal Config in Finder`).

**State 3 — Already configured**
- Headline: "Maugham is connected to Claude Desktop." green checkmark.
- Body: try-this hint, e.g., "Try asking Claude: 'What chapters are in my novel?'".
- Status row: bundle path it's pointing at. If path doesn't match `Bundle.main.bundleURL.path`, inline warning + `Update Path` button.
- Secondary buttons: `Reveal Config in Finder`, `Remove`.

### The snippet

```json
{
  "mcpServers": {
    "maugham": {
      "command": "/Applications/Maugham.app/Contents/MacOS/maugham-mcp"
    }
  }
}
```

Path is the actual `Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/maugham-mcp").path` — handles `~/Applications`, dev builds, etc.

### Failure handling

- Unparseable existing config → never overwrite. Sheet falls back to the manual-snippet disclosure with a "Your config has unexpected content — here's the snippet to add yourself" hint.
- Write failure (disk full, permissions) → error alert with the config file path.

### What's deleted

- The old `npx @modelcontextprotocol/server-filesystem` recommendation is removed entirely. `maugham-mcp` is a superset.
- The per-project `maugham-<slug>` server name is gone — single `maugham` entry covers all open projects.

---

## Day-to-day UX

### Settings toggle

- New row in `Settings → General`: `Allow Claude to connect (MCP)` — default ON.
- Description: "When on and Maugham is running, Claude Desktop can read your open projects and add research notes."
- Off → socket unbinds; binary returns `mcp_disabled`.
- No per-project toggle. Granularity is "is this window open?"

### `add_note` notification — the only Claude→Maugham UX surface

When Claude calls `add_note` successfully:

1. Maugham creates the file via the existing research-create pipeline.
2. Posts `maughamMCPNoteAdded` notification with `{ project_id, research_id, title }`.
3. The matching `ProjectWindow` shows a transient banner at the top of the editor pane (reuses the `SaveFlashOverlay` glass-material style from milestone 1c):

   `Claude added "<title>" to research.  [Show] [Dismiss]`

   - `Show`: switch binder to Research segment, select the new item.
   - `Dismiss`: hide banner.
   - Auto-dismisses after 8 seconds.
4. Dock badge increments while the banner is visible (single-digit unread count for the session).

### Multiple add_notes in quick succession

- Banner counter increments: `Claude added 3 notes to research. [Show latest] [Show all] [Dismiss]`.
- `Show all`: flashes Research segment + applies a search filter narrowing to items created in the last 60 seconds. Reuses milestone 2c's search + 2026-05-14 find-replace's filter UI primitives.

### Reads are silent

No UI feedback for read tools — privacy-equivalent to "Claude can read this with permission." Surfacing every read would be noisy and not actionable.

### Deferred for v1

- Menu-bar "Claude connected" indicator with read-count.
- Per-tool / per-project consent toggles.
- "Test connection" button in the setup sheet.

---

## Testing

### MCPServer unit tests

XCTest classes that write JSON-RPC requests to an ephemeral socket in `tmp/` and assert the response shape. Doesn't need the binary. One test class per tool plus a wire-protocol class.

### `maugham-mcp` integration test

Spawn the binary as a subprocess, write JSON-RPC to its stdin, read stdout, assert correct forwarding. Two states:
- Maugham reachable (mock socket server) → request/response round-trip.
- Maugham not reachable (no socket) → expect `maugham_not_running` synthesized response.

### `add_note` end-to-end

Call via socket, assert:
- File exists on disk in `research/`.
- Manifest contains the new research item.
- `maughamMCPNoteAdded` notification was posted (`NotificationCenter` expectation).
- Filename collision triggers `-2`/`-3` slug dedup.

### Settings toggle

Flip toggle off → assert socket unbinds → reconnect attempt returns `mcp_disabled`. Flip on → socket rebinds → connections succeed again.

### Estimated test count

~30–40 new tests:
- 8 read tools × 3 tests each = 24
- `add_note` × 4 = 4
- Wire protocol × 3 = 3
- Binary integration × 2 = 2
- Settings × 2 = 2
- Configure-Claude-Desktop sheet (mock filesystem) × 4 = 4

Brings test count from 516 → ~555.

### Not in CI

No dependency on Claude Desktop being installed. Every test uses our own sockets and the binary directly.

---

## Public API surface added (will be captured in milestone memory)

- `MCPServer` actor + `MCPServerError` enum
- `maughamMCPNoteAdded` notification
- Settings key `mcpEnabled` (default true)
- Tool surface (9 tools, see above)
- Bundle path: `Maugham.app/Contents/MacOS/maugham-mcp`
- Socket path: `~/Library/Application Support/Maugham/mcp.sock`

---

## Explicitly deferred (out of scope for this milestone)

- **Manuscript edit proposals.** Sibling-file vs structured-proposal vs inline-review-marks. Separate brainstorm.
- **Prompt templates.** "Brainstorm character motivations for this scene" pre-wired prompts.
- **Handwritten note import.** Group 2 follow-up using vision in Claude Desktop.
- **Voice notes / Whisper transcription.** Group 2 follow-up.
- **Claude Code companion view.** A Maugham sidebar showing Claude responses; use Claude Desktop's window for v1.
- **Per-project allow-list / per-tool toggles.** Window-open is the consent gesture.
- **Auth.** Local stdio only. If MCP-over-TCP comes up later, that's a different milestone with a real auth story.
- **Menu-bar status indicator.**
- **Disk-fallback / staleness handling.** Live-only locked in.

---

## Carry-forwards into milestone memory at tag

- Final API surface
- Wire-format and socket lifecycle
- Bundle structure changes
- Configure Claude Desktop sheet semantics
- Any quirks discovered during build (Unix socket reconnect behavior, JSON-RPC framing edge cases, Claude Desktop config quirks)
