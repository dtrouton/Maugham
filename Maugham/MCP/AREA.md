# MCP — Area guide

The local MCP server that lets Claude Desktop read and contribute to projects. Read this before editing anything in `Maugham/MCP/`. Also read the project root `CLAUDE.md` for cross-cutting invariants, and `docs/adr/0003-mcp-live-only-unix-socket.md` + `docs/adr/0004-mcp-foundation-scope.md` for the canonical transport and scope decisions.

## What this area owns

The in-app MCP server: tool registration, JSON-RPC handling, the read/search/discover surface for projects, the `add_note` write path (research-only), the annotation layer (paragraph-anchored comments from Claude), and the bridge between Claude Desktop's stdio and Maugham's Unix socket.

## Tool catalogue (44)

**Discovery / identity**
- `list_projects` — enumerate all open Maugham projects
- `list_maugham_tools` — flat, authoritative list of every tool + server identity block
- `get_help` — read Maugham's bundled user documentation by topic (read-only)

**Project read**
- `get_metadata` — title, type, tags, word targets, session stats for a project
- `get_outline` — hierarchical binder structure (groups + documents)
- `list_scenes` — slugline-level scene list for screenplay projects
- `get_session_stats` — per-doc session word-count and activity stats

**Document read**
- `read_document` — full manuscript text (or image with crop-on-demand for images)
- `search_text` — cross-document full-text search within a project
- `find_references` — wiki-link back-references to a document
- `list_documents_by_tag` — filter binder documents by tag

**Research / links**
- `add_note` — write a new research note under `research/` (the only write tool)
- `list_research` — enumerate research items in a project
- `link_research` — create a research ↔ manuscript link
- `unlink_research` — remove a research ↔ manuscript link
- `list_all_links` — all research–manuscript links for a project, incl. `piece_research` edges (a collection piece's own research, no explicit link needed)

**Annotations (parallel comment layer)**
- `add_comment` — paragraph-anchored general comment
- `add_suggested_change` — paragraph-anchored suggested edit
- `add_query` — paragraph-anchored open question
- `add_craft_note` — paragraph-anchored craft/technique observation
- `list_annotations` — read annotations for a document (filtered by kind/status)
- `get_annotation` — fetch a single annotation by ID

**Tasks**
- `list_tasks` — enumerate task annotations for a project
- `get_task` — fetch a single task by ID

**Publishing**
- `initialize_publish_template` — scaffold a LaTeX/EPUB template for a project
- `get_publish_config` — read publish config (`config.json`)
- `set_publish_config` — write publish config fields
- `list_publish_files` — enumerate files under `.maugham/publish/`
- `read_publish_file` — read a publish template or config file
- `read_publish_image` — read a publish image with crop-on-demand
- `write_publish_file` — write a template or config file
- `delete_publish_file` — delete a publish file
- `compile` — compile a project to PDF or EPUB via bundled tectonic
- `preview_compile` — dry-run compile (no output written)
- `compile_status` — poll an in-progress compile job
- `compile_cancel` — cancel an in-progress compile job
- `list_publications` — enumerate past publication outputs
- `read_publication_page` — read a page from a compiled PDF
- `republish` — re-run the last successful compile

**Piece style**
- `set_piece_style` — attach per-piece LaTeX style overrides
- `clear_piece_style` — remove per-piece style overrides

**Inbox / capture**
- `list_inbox` — enumerate capture inbox entries (voice/text/photo)
- `read_inbox_entry` — read the content of a single inbox entry
- `promote_inbox_entry` — promote an inbox entry to research; optional `target_document_id` scopes it to a piece's own research folder or a chapter's shared-research link

## Dev-only Test MCP (`Maugham/MCP/Test/`)

A **separate** catalog, `TestMCPToolCatalog`, that mirrors `MCPToolCatalog`'s shape
(`register(router:registry:)`) but is registered onto the **same dev-build Unix socket**
only inside `#if MAUGHAM_DEV_BUILD` in `MaughamApp.registerTools` — absent from the stable
binary entirely (enforced by `TripwireGrepTests.test_testMCPCatalog_registeredOnlyUnderDevFlag`).
It exists for **Claude Code**, not Claude Desktop, and is not part of the production 44-tool
count above — the "Tool catalogue (44)" heading is unaffected by these tools.

Purpose: let Claude Code drive the full create → edit → autosave → checkpoint → quit →
relaunch → verify loop end to end without the owner acting as a human tester, so the
canonical smoke's real value — verifying *invisible* internal state (op log, autosave,
cursor restore, checkpoints, clean `.md` on disk) — can run unattended. It deliberately does
**not** cover UI fidelity (typing feel, rendering, focus-dim); that stays a manual, eyes-on
pass. See `docs/superpowers/specs/2026-07-01-test-mcp-design.md` and ADR 0020.

Safety model — mutation is fenced to a throwaway workspace, never the owner's real projects:
- **Compile gate:** the whole catalog and its tool implementations only exist in dev builds.
- **Runtime guard:** every mutating tool resolves its target project URL through
  `TestWorkspace.require(url:)` (MaughamCore), which throws unless the path is under
  `~/Library/Application Support/Maugham Dev/TestWorkspace/`. Read-only inspect tools are not
  workspace-restricted.

Driving semantics: `test_apply_edit` routes through the **same** `Document` op-recording entry
point the editor uses (`setFullText` + `recordEditorTextWrite`, mirroring `EditorHost`) — not a
parallel mutation path, not faked keystrokes into `NSTextView`. This keeps a single manuscript
write path (tripwires 6/7) and exercises the real op log → materializer → autosave → clean
`.md` pipeline.

Connection: a repo-root `.mcp.json` plus `scripts/maugham-test-mcp.sh`, which points
`MAUGHAM_MCP_SOCKET` at the dev socket and execs the existing `maugham-mcp` bridge against the
built `Maugham Dev.app`, surfacing the tools to Claude Code as `mcp__maugham_test__*`.

**Drive** (mutating, `TestWorkspace`-fenced, dev-only):
- `test_create_project` — create + open a project under TestWorkspace via the real
  `Document.load`→`Bootstrap` path
- `test_open_project` — open an existing TestWorkspace project
- `test_apply_edit` — insert/edit/delete a paragraph via the real `Document` edit API
- `test_checkpoint` — fire a labeled project-scope checkpoint
- `test_reset_workspace` — delete everything under (and only under) TestWorkspace

**Lifecycle:**
- `test_ping` — cheap readiness probe; the loop polls it after relaunch to absorb the
  cold-launch window before asserting
- `test_flush_autosave` — force the 750ms debounced write to happen now
- `test_quit` — acks ("terminating") first, then flushes and cleanly terminates ~100ms later

**Inspect** (read-only, not workspace-fenced):
- `test_dump_document` — in-memory `Document`: paragraphs by `sequence`, `¶id`+text, cursor,
  `lastDiskEcho`, pending sweep
- `test_dump_oplog` — raw ops for a doc: sequence, kind, paragraphId, payload
- `test_autosave_status` — pending debounced write / echo state
- `test_pending_buffer` — `PendingBuffer` durable sequence (crash-recovery / clean-`.md`
  domain, ADR 0019)
- `test_list_checkpoints` — checkpoints + metadata

## Layout

- `MCPServer.swift` — Unix socket server, connection lifecycle, SIGPIPE handling. **SIGPIPE handling is idempotent and required** — don't simplify it away.
- `MCPToolsListHandler.swift` — tool list response. Iterates `MCPToolCatalog.all` to advertise tools; never touches them directly.
- `MCPTool.swift` — the `MCPTool` protocol (every tool conforms) and `MCPToolCatalog.all` (the single source of truth for the tool list). `MCPToolCatalog.register(router:registry:)` is the shared registration path used by both production (`MaughamApp.registerTools`) and the seam test (`MCPCatalogConsistencyTests`).
- `Tools/` — one file per tool. Read tools are pure; `add_note` is the only writer in foundation scope and it can only write under `research/`.
- Paragraph-anchored annotations live in `Tools/AnnotationCreationTools.swift` (add_comment / add_suggested_change / add_query / add_craft_note), `Tools/AnnotationReadTools.swift` (list_annotations / get_annotation), and `Tools/AnnotationToolHelpers.swift` (`withAnnotationDocument` — transient-load fallback when the doc isn't open in the editor). The parallel comment layer that lets Claude annotate the manuscript without mutating it.
- `../maugham-mcp/` — the standalone CLI binary that bridges Claude Desktop's stdio to the app's Unix socket. Lives outside this directory but is conceptually part of this area. Main entry: `JSONRPCBridge.swift`.

## Hard rules

- **Transport is live-only Unix socket.** No stdio inside the app. The standalone `maugham-mcp` CLI is the stdio adapter for Claude Desktop. (ADR 0003)
- **The server only runs while Maugham is running.** No background daemon, no LaunchAgent. Settings → General → "Allow Claude to connect (MCP)" toggles it; default on.
- **Foundation scope: read tools + `add_note`.** `add_note` only writes under `research/`. **Manuscript text is never mutated via MCP** — that's the annotation layer's job (or no-op, in foundation scope). The user's framing: *"the manuscript is yours, full stop. Claude operates in a parallel annotation layer."* (ADR 0004)
- **Tool responses are capped at ~1MB.** Transport limit. Larger payloads will fail silently or get truncated; design around it.
- **Image responses use crop-on-demand.** Parameters: `max_dimension` (default 2048), `quality` (default 85), `region` (optional crop rect). Default output: JPEG q=85, max 2048px on the long side. Don't return raw images.

## Tripwires

1. **Adding a tool: implement `MCPTool` on it, then add the type to `MCPToolCatalog.all`.** That's the only place to list tools. `MCPToolsListHandler` and `MaughamApp.registerTools` both derive from the catalog, so they can't drift. `MCPCatalogConsistencyTests` asserts the contract holds (catalog ↔ tools/list, catalog ↔ router, schema validity). If you find yourself editing `MCPToolsListHandler` to add a tool entry, stop — you're working against the protocol.

2. **First MCP call after restart is a known deferred flake.** Three rounds of bridge fixes didn't resolve it; the user deferred 2026-05-17 (see `memory/project_deferred_mcp_first_call.md`). Don't try to fix without first adding stderr logging in the bridge (`maugham-mcp/JSONRPCBridge.swift`) so you can see what's failing.

3. **Orphan-annotation sweep is now edge-triggered via `Document._pendingSweep: SweepReason?`** carrying the observed removed-paragraph-id set; sweep archives only annotations on `reason.removed`. The earlier 1–2s auto-archive bug (sweep firing on any sequence mismatch from the live Document's view) is fixed via the SweepReason refactor (ADR 0010). `PresenterRoutingTests` covers the contract. If annotations vanish, suspect sweep-reason population at the call site (setFullText / deleteParagraph / handleExternalLogChange), not the sweep itself.

4. **Don't write to manuscripts from MCP, full stop.** Even if a future tool design "feels safe," the membrane principle is the hard rule. Writes go via the annotation layer or to `research/`. Violating this loses the user's trust in the whole MCP integration.

5. **Don't return tool payloads >1MB.** Transport will choke. For listings that could blow past the cap, paginate or summarize.

6. **Don't add a tool without thinking about the membrane.** Read tools: low-risk, generally fine. Write tools: needs explicit ADR-level justification. Annotation tools: belong to the annotation layer, not direct manuscript mutation.

7. **Don't reach for stdio inside the app.** The Unix socket is the contract. The standalone CLI is the only stdio surface.

## How tools are wired (end to end)

```
Claude Desktop  ──stdio──>  maugham-mcp CLI  ──Unix socket──>  MCPServer  ──>  tool handler in Tools/
                                                                      │
                                                                      └──>  reads/writes via Stores/MCPServices
```

Adding a new tool:

1. Implement the handler in `Tools/<ToolName>.swift`. Conform the enum to `MCPTool` and declare `method`, `description`, `inputSchemaJSON`, `handle(paramsJSON:registry:)` on it.
2. Add the type to `MCPToolCatalog.all` in `MCPTool.swift`. That's the only registration step — `MCPToolsListHandler` and `MaughamApp.registerTools` derive from this list.
3. If it returns images, use the crop-on-demand parameters (`max_dimension`, `quality`, `region`).
4. If it could return >1MB, add pagination or summarization.
5. Test from Claude Desktop with the configure-flow (Settings → Help → "Set up Claude Desktop…").

`MCPCatalogConsistencyTests` will catch a missing catalog entry, a malformed schema, or any drift between advertisement and dispatch at test time.

## What to read before editing

- For transport / connection lifecycle / SIGPIPE: `MCPServer.swift` + `docs/adr/0003-mcp-live-only-unix-socket.md`.
- For the tool surface and scope decisions: `docs/adr/0004-mcp-foundation-scope.md`.
- For the bridge (stdio ↔ socket): `../maugham-mcp/JSONRPCBridge.swift`.
- For annotation behavior (especially auto-archive): grep for `paragraph_id` in this area and `Maugham/Stores/`.
- For an example of a well-shaped read tool: `Tools/DocumentTools.swift` (contains both `ReadDocumentTool` and `SearchTextTool` — `ReadDocumentTool` is the model for polymorphic responses on images vs text, with crop-on-demand parameters).

## Tests worth knowing about

- `MaughamTests/MCP/` — unit tests per tool handler.
- `MaughamTests/MCP/MCPCatalogConsistencyTests.swift` — enforces the catalog-as-single-source-of-truth rule (every method in `MCPToolCatalog.all` is advertised by `tools/list`, is dispatchable through the router, and has a parseable object schema). This is what catches "added a tool but forgot to register it" at test time, not at user time.
- The annotation auto-archive contract is covered by `MaughamTests/Integration/PresenterRoutingTests.swift` — specifically the test asserting MCP `add_annotation` on a live doc doesn't synthesize spurious `claude_archive` ops.

Known thin coverage: end-to-end through the bridge (the deferred first-call-after-restart flake has no regression test because it's reproduction-only; see `memory/project_deferred_mcp_first_call.md`).

## What's intentionally NOT here

- Manuscript persistence — `Maugham/Stores/DocumentStore.swift`.
- The op log that MCP read tools read against — `Maugham/OpLog/`.
- Settings UI for the "Allow Claude to connect" toggle — `Maugham/Views/SettingsTabs/`.
- The "Set up Claude Desktop…" flow — `Maugham/Views/` (Help menu wiring).
- The standalone `maugham-mcp` CLI source — `../maugham-mcp/` (separate Swift package, ships bundled inside `Maugham.app/Contents/MacOS/`).
