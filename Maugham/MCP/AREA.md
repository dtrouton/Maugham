# MCP — area guide

The in-app MCP server that lets Claude Desktop, Claude Code and the app's own `claude` sessions read and contribute to open projects: the Unix-socket transport, JSON-RPC dispatch, the tool catalogue, the SEP-2640 skills surface, the dev-only test catalogue, and the stdio bridge (`maugham-mcp/`). Claude reads projects, annotates manuscripts in a parallel layer, writes into the planning plane (`research/`, the canvas) and stages statement drafts the writer adopts. The one rule from CLAUDE.md: **one catalogue, `MCPToolCatalog.all`; MCP never writes manuscript text.** The area carries tripwires 10, 13, 20, 21, 38, 51, 52 and 54. The narrative and history behind the rules below are in `docs/history/mcp.md`.

## Map

Every source file in `Maugham/MCP/` appears once, by file or by family.

### Server and protocol
- `MCPServer.swift` — the Unix-socket server, connection lifecycle, and the idempotent process-wide SIGPIPE ignore.
- `MCPRouter.swift` — pure dispatch: method name → handler (`MCPRouterError.methodNotFound`).
- `MCPProtocol.swift` — JSON-RPC 2.0 request/response types (`MCPRequestId`, `MCPRequest`); params stay raw JSON so each tool decodes its own shape.
- `MCPInitializeHandler.swift` — the `initialize` handshake; declares the skills extension capability.
- `MCPToolsListHandler.swift` — `tools/list`, iterating `MCPToolCatalog.all`; it never names a tool.
- `MCPToolsCallHandler.swift` — `tools/call`: unwraps `{name, arguments}`, dispatches through the router, turns every tool failure into an `isError: true` result with a structured payload, and holds the central text-budget backstop.
- `MCPTool.swift` — the `MCPTool` protocol and `MCPToolCatalog.all`, the single list of tools; `MCPToolCatalog.register(router:registry:)` is the one registration path, used by `MaughamApp.registerTools` and `MCPCatalogConsistencyTests`.
- `MCPToolHelpers.swift` — shared `MCPTool` boilerplate: typed param decoding and `project_id` resolution, with the one "unknown project" failure (`unknownProjectID`).
- `MCPError.swift` — Maugham's error codes (`maughamNotRunning` -32001, `projectNotOpen` -32002, `mcpDisabled` -32003, `invalidArgument`, `internalError`, `toolError(payload:)`).
- `MCPResponseBudget.swift` — the text byte budget (`maxTextBytes` 900 KB, `enforce(_:hint:)`). Tripwire 10.
- `ImageResponseBuilder.swift` — crop-on-demand JPEG responses under a 720 KB raw budget. Tripwire 10.
- `ProjectRegistry.swift` — the open projects by id (`register`, `unregister`, `lookup`).
- `ProjectIdentifier.swift` — a project's stable id, derived from its on-disk path.
- `SkillsExtension.swift` — the SEP-2640 surface: `skills/list`, `skills/get`, `resources/read` for `skill://` URIs.
- `ClaudeCodeSkillInstall.swift` — the Claude Code bootstrap-skill installer and the copyable `claude mcp add` command (variant-aware through `BuildVariant`).
- `ClaudeDesktopConfig.swift` — detects and edits Claude Desktop's config file for the "Set up Claude Desktop…" flow (variant-aware server key).

### `Tools/` — one family per file
- `ProjectTools.swift` — `list_projects`, `get_metadata`, `get_outline`.
- `ListMaughamToolsTool.swift` — `list_maugham_tools`. `GetHelpTool.swift` — `get_help`.
- `DocumentTools.swift` — `read_document`, `search_text`; `ReadDocumentTool` is the model for a polymorphic image-or-text response with crop-on-demand, and is tripwire 54's one allow-listed tool (`read_document.mode`'s wire value); no other tool spells a `"fountain"` literal.
- `ReferenceTools.swift` — `list_scenes`, `find_references`, `get_session_stats`.
- `ListDocumentsByTagTool.swift` — `list_documents_by_tag`.
- `AddNoteTool.swift` — `add_note`. `ListResearchTool.swift` — `list_research`. `ResearchLinkTools.swift` — `link_research`, `unlink_research`. `ListAllLinksTool.swift` — `list_all_links`. `MoveResearchItemTool.swift` — `move_research_item`.
- `CraftIntentTools.swift`, `VisualLanguageTools.swift`, `EditionBriefTools.swift`, `LessonsTools.swift`, `FirstReaderTools.swift` — the five statement readers (`read_craft_intent`, `read_visual_language`, `read_edition_brief`, `read_lessons`, `read_first_reader`). Tripwire 20.
- `StatementProposalTools.swift` — `propose_edition_brief`, `propose_visual_language`.
- `PaletteTools.swift` — `list_palette_cards`, `read_palette_card`.
- `AnnotationCreationTools.swift` — `add_comment`, `add_suggested_change`, `add_query`, `add_craft_note`. `AnnotationReadTools.swift` — `list_annotations`, `get_annotation`. `AnnotationToolHelpers.swift` — `withAnnotationDocument` (the open-or-transient-load door) and `activeReviewPassId`. Tripwire 38.
- `TaskReadTools.swift` — `list_tasks`, `get_task`. Tripwire 38.
- `InitializePublishTemplateTool.swift`, `PublishConfigTools.swift` (`get_publish_config`, `set_publish_config`), `PublishFileTools.swift` (`list_publish_files`, `read_publish_file`, `read_publish_image`, `write_publish_file`, `delete_publish_file`), `CompileTools.swift` (`compile`, `preview_compile`, `compile_status`, `compile_cancel`), `PublicationTools.swift` (`list_publications`, `read_publication_page`, `republish`), `ReadPreviewPageTool.swift` (`read_preview_page`), `PieceStyleTools.swift` (`set_piece_style`, `clear_piece_style`) — publishing.
- `TranslationTools.swift` — `write_translation`, `read_translation`, `translation_status`, and `currentParagraphState`. `TranslationWritePipeline.swift` — validation, record building and the one append, shared with the translator loop. Tripwires 20, 38.
- `CanvasTools.swift` — `list_canvas`, `add_canvas_scraps`.
- `InboxTools.swift` — `list_inbox`, `read_inbox_entry`, `promote_inbox_entry`.

### `Test/` — the dev-only catalogue
- `Maugham/MCP/Test/TestMCPToolCatalog.swift` — `TestMCPToolCatalog`, registered only under `#if MAUGHAM_DEV_BUILD`; every method is `test_`-prefixed.
- `Maugham/MCP/Test/TestOpenBridge.swift` — the dev-only notification that asks the Welcome window to open a project.
- `Test/Tools/` — `TestProjectTools.swift`, `TestDocumentTools.swift`, `TestEditTool.swift`, `TestLifecycleTools.swift`, `TestPingTool.swift`, `TestInspectTools.swift`.

### Outside the folder
- `maugham-mcp/` (repo root) — the standalone CLI bridging Claude Desktop's stdio to the app's socket (`maugham-mcp/JSONRPCBridge.swift`, `maugham-mcp/main.swift`); an xcodegen tool target (`maugham-mcp` in `project.yml`) copied into `Maugham.app/Contents/MacOS/`.
- `Maugham/Help/SkillIndex.swift` — loads the bundled skills (mirrors `HelpTopicIndex`; lives in `Help/` because `get_help` also serves it).
- `Maugham/Views/HelpClaudeDesktopSheet.swift` — the "Set up Claude Desktop…" flow and its Claude Code section; `Maugham/Views/SettingsTabs/GeneralSettingsTab.swift` — the "Allow Claude to connect (MCP)" toggle.

## Tool catalogue (60)

The count is `MCPToolCatalog.all.count`; `DocSyncTests` checks this heading against it. Contracts beyond one line are under Rules → Tool contracts.

**Discovery / identity**
- `list_projects` — every open project.
- `list_maugham_tools` — every tool plus a server identity block.
- `get_help` — Maugham's bundled user documentation by topic; topic `"skills"` lists the agent skills, a skill's name loads its procedure.

**Project read**
- `get_metadata` — title, type, tags, word targets, session stats.
- `get_outline` — the binder tree, with derived review status, pass states and each pass's brief.
- `list_scenes` — sluglines of a screenplay.
- `get_session_stats` — per-document session word counts and activity.

**Document read**
- `read_document` — a manuscript's text, or an image (crop-on-demand).
- `search_text` — full-text search across a project's manuscript documents.
- `find_references` — wiki-link back-references to a document, research item or statement.
- `list_documents_by_tag` — binder documents by tag.

**Research / links**
- `add_note` — a new research note under `research/` (a write tool).
- `list_research` — research items.
- `link_research` / `unlink_research` — create or remove a research ↔ manuscript link.
- `list_all_links` — every research–manuscript link, `piece_research` edges included.
- `move_research_item` — batch-move research items between shared research, a group and a piece's research folder.

**The spine (statements) and the palette**
- `read_craft_intent` — a manuscript document's or the project's craft intent.
- `read_visual_language` — the book's look: the prose and `image_paths`.
- `read_edition_brief` — one translated edition's doctrine, by `language`.
- `read_lessons` — the project's lessons ledger.
- `read_first_reader` — the writer's first reader: `name` and her description.
- `propose_edition_brief` / `propose_visual_language` — STAGE a draft statement the writer adopts or discards.
- `list_palette_cards` / `read_palette_card` — sensory-palette card summaries; one card's markdown and thumbnails.

**Annotations (the parallel comment layer)**
- `add_comment`, `add_suggested_change`, `add_query`, `add_craft_note` — paragraph-anchored notes.
- `list_annotations` / `get_annotation` — a document's notes (filter by kind/status) or one by id, with `triage` and `review_pass_id`.

**Tasks**
- `list_tasks` / `get_task` — task annotations.

**Publishing**
- `initialize_publish_template` — scaffold a LaTeX/EPUB template.
- `get_publish_config` / `set_publish_config` — read or patch the publish config (`<project>/.maugham/publish/config.json`) (per-piece `sections.<docId>.include`, default true; false drops the piece from compile, republish and the translation coverage gate).
- `list_publish_files`, `read_publish_file`, `read_publish_image`, `write_publish_file`, `delete_publish_file` — files under `.maugham/publish/`.
- `compile` — compile to PDF or EPUB through bundled tectonic.
- `preview_compile` — a fast subset compile: no output, Publication or version bump.
- `compile_status` / `compile_cancel` — poll or cancel a job.
- `list_publications` — past outputs, filterable by `language` and `imprint`.
- `read_publication_page` — a page of a compiled PDF.
- `read_preview_page` — a page of the latest preview PDF.
- `republish` — re-run the last successful compile.
- `set_piece_style` / `clear_piece_style` — per-piece LaTeX style overrides.

**Translation**
- `write_translation` — per-paragraph translations into a language, in the parallel translation layer.
- `read_translation` — a document's translation, paragraph by paragraph, with freshness.
- `translation_status` — coverage per (document, language), open queries, the cast and the last round.

**Planning canvas**
- `list_canvas` — the canvas read whole: cards, regions, lines, marks, piece references.
- `add_canvas_scraps` — cards marked `author: claude`, in one labelled region (a write tool).

**Inbox / capture**
- `list_inbox` — capture inbox entries (voice/text/photo), with the optional `palette_subject`/`sense` aim fields when present.
- `read_inbox_entry` — one entry's content.
- `promote_inbox_entry` — promote an entry to research or into an existing palette card.

## Rules

### The membrane
- **MCP never writes manuscript text, full stop**: the manuscript is the writer's, and Claude reaches it only through the parallel annotation layer. Even a tool that "feels safe" does not soften this; violating it loses the writer's trust in the whole integration (ADR 0004).
- **A write tool may touch only the planning plane, and today that is three destinations**: `research/` (`add_note`), the annotation and translation layers, and the planning canvas (`canvas.md` plus `<project>/.maugham/canvas.json`, `add_canvas_scraps`; ADR 0026). Over the inbox MCP may read and promote only, never add or trash. What they write reaches a manuscript only through a deliberate writer act (`promote_inbox_entry`, the canvas's own Promote…). A fourth destination needs its own ADR-level argument, not this list as precedent.
- **Think about the membrane before adding a tool**: a read tool is low-risk; a write tool needs ADR-level justification; an annotation tool belongs to the annotation layer.
- **No tool writes a statement.** The two propose tools stage a draft that only the writer's click at `StatementPane`'s gate turns into a statement (`StatementProposalGate.adopt`). `CompilerAllowlistTests.test_noStatementWritingToolExistsAnywhereClaudeCanReach` fails on a statement writer in the catalogue as well as the compiler's allowlist; its predicate passes the two propose tools by name and catches `write_edition_brief`, `propose_craft_intent` and the like.
- **Claude never writes the lessons ledger, the first reader, craft intent or visual language**: the ledger moves only through the writer's own verbs in Maugham (Keep as lesson / These are all choices / retire).

### Actors and the op log
- **This layer IS the `assistant` actor** (ADR 0032): `withAnnotationDocument` and `TaskReadTools` call `Document.load(url:actor: .assistant, …)`, so Claude's notes land in `<doc>.assistant-<hex>-<8hex>.jsonl`, sealed by a key the writer's hand does not hold. (The hex run is shorter than the author's: `DeviceSlug.make` caps its prefix at 24 characters.)
- **`write_translation` is the one tool that is not the assistant**: it loads `.translator`, because a translation record is the pipeline's work.
- **Never hand-build a device string at a `Document.load` here**: name the actor and let `LocalIdentities` answer (tripwire 38, `TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad`).
- **Both of `withAnnotationDocument`'s arms yield assistant-signed notes, and only one loads as the assistant.** The closed-document arm transient-loads `.assistant`. The OPEN-document arm writes through the live `Document` the editor loaded as `.author`, so `Document.addAnnotation` stamps the actor off the annotation's AUTHOR (`deviceFor(author:)`: a `sourceKind` that is not `.human` is the assistant's). The writer's own dispositions of those notes stay the writer's (`Maugham/OpLog/AREA.md`).
- **Reads derive from the op log, never the `.md`** (tripwire 20): an open document through its live `Document`, a closed one through `DerivedManuscriptCache`/`derivedCache` (`currentParagraphState`), a statement through `ProjectStore.statementText(of:)`. Any other file read here (a research note, a publish file, a config) carries `// adr-0018-ok: <reason>` naming why it is not manuscript (`TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler`).
- **Nothing under `Maugham/MCP` emits a task op** (`TripwireGrepTests.test_nothingUnderMCPEmitsATaskOp`): `Permit.isALoadEmission` waives the actor narrowing for `taskCreate` by kind, which is safe only while the load is the one non-author emitter. A task-writing tool is a permit-layer decision first.
- **Post through `MaughamEvent`** (tripwire 21, `TripwireGrepTests.test_noRawMaughamPostsOrSubscriptionsOutsideWrapper`), project-scoped: `maughamStatementProposalsChanged`, `maughamTranslationDidUpdate`.

### The catalogue and dispatch
- **`MCPToolCatalog.all` is the only list of tools.** `MCPToolsListHandler` and `MaughamApp.registerTools` both derive from it; if you find yourself editing `MCPToolsListHandler` to add a tool, stop (`MCPCatalogConsistencyTests`: catalogue ↔ `tools/list`, catalogue ↔ router, schema validity).
- **The tool count is the catalogue's, never a number elsewhere**: the `## Tool catalogue (NN)` heading is checked by `DocSyncTests.test_toolCountSyncedAcrossDocsAndCatalog`, which also fails if CLAUDE.md states a count again.
- **The protocol methods are not tools**: `initialize`, `tools/list`, `tools/call` and the three skills methods are registered directly on the router and add nothing to the count.
- **Tools fail loudly on unknown ids**: an id the manifest does not hold is a caller error, never a degraded answer.
- **A tool failure is a tool result, not a JSON-RPC error**: `MCPToolsCallHandler` turns every handler failure into `isError: true` with `{error, message, hint?}`; only protocol failures (`methodNotFound`, malformed `tools/call` params) throw.
- **Widening an existing read changes no count**: a new field on an existing tool is a widening; only a new tool moves the heading. Never remove a shipped wire field; that is a breaking change.
- **A JSON field whose value is a fact emits `null` rather than vanishing** (`triage`, `review_pass_id`, a group node's review fields, a briefless pass's `brief`): an absent key reads as "this tool does not report it".
- **An ordered list is a JSON array, never an object keyed by id**: a JSON object's key order is `Dictionary` iteration order, and two reads of unchanged state must not differ.

### Transport and lifecycle
- **The trust boundary is same-user, filesystem-enforced.** The socket carries no auth: it lives under `~/Library/…` with user-only permissions, so anything that can reach it could read the project files anyway. Don't add socket-level auth; under this threat model it defends nothing (ADR 0003).
- **The transport is a live-only Unix socket; no stdio inside the app.** The standalone `maugham-mcp` CLI is the only stdio surface (ADR 0003).
- **The server runs only while Maugham runs**: no daemon, no LaunchAgent. Settings → General → "Allow Claude to connect (MCP)" toggles it; default on.
- **SIGPIPE handling is idempotent and required**: don't simplify it away.
- **Socket paths come from `BuildVariant`** (tripwire 13, `TripwireGrepTests.test_noHardcodedIdentityStringsInMacSources`); `MaughamApp.swift` binds `TestHost.mcpSocketPath`, never `BuildVariant.current.mcpSocketPath`.
- **A test host binds a socket of its own, never the variant's.** The app starts an `MCPServer` from the Welcome scene's `.task` on every launch, and `start()`, `stop()` and `willTerminate` each unlink the path, so a gate run used to delete the socket the open dev app was listening on: every later `claude -p` reported `mcp_servers: [{maugham-dev, failed}]` and the writer saw a compiler check that "couldn't be read as notes". `TestHost.mcpSocketPath` is the one decision: the variant's path for a writer's launch, `<temp>/maugham-host-<pid>.sock` for a host (`TripwireGrepTests.test_theAppBindsTheEffectiveSocketPathAndNotTheVariantsOwn` and its planted-offender companion). The `*Environment+Project` files and `HelpClaudeDesktopSheet` name the variant's path on purpose: they tell an OUTSIDE process where the real app listens.
- **Socket tests bind isolated paths of their own** (`MCPServerLifecycleTests`, `MCPColdStartTests`, `MCPBinaryIntegrationTests`); nothing connects to a host's socket.
- **The bridge runs one bounded poll loop for both reconnect cases** (`handleStdinLine`; budget `MAUGHAM_MCP_RECONNECT_BUDGET_MS`, default 15 s, low in tests). Never reintroduce a `hadPriorConnection` fast-fail branch: "no prior connection" is exactly the first call after a cold launch. Pinned by `MCPColdStartTests`. The cost: a genuinely absent app takes the whole budget to answer `maugham_not_running`.

### The response budget (tripwire 10)
- **No tool response over ~1 MB, and the cap is enforced, not just documented.** The figure is inferred from a real incident (ADR 0004), not a measured constant; treat it as the working ceiling. The limit belongs to the JSON-RPC *line*, so enforcement is layered.
- **Text: `MCPResponseBudget.enforce(_:hint:)`** (`maxTextBytes` = 900 KB) fails with a structured `payload_too_large` tool error carrying a section-scoped hint.
- **Per-tool `enforce` calls hold on every invocation path**, on the unbounded readers: `read_document` (manuscript and research), `read_publish_file`, `read_inbox_entry`, the five statement readers, `read_translation`, `list_canvas`, and `read_palette_card`'s markdown block (which returns a `content` envelope and bypasses the default wrap).
- **The central backstop in `MCPToolsCallHandler`'s default text-wrap branch covers only `tools/call`.** Each `tool.method` is also registered as a top-level JSON-RPC method, which bypasses `MCPToolsCallHandler`, so a backstop-only tool called that way is unguarded. Don't rely on the backstop for end-to-end coverage; a new unbounded reader calls `enforce` itself.
- **Why 900 KB**: the payload is re-escaped as the string value of a `text` block and wrapped in two envelopes, so content around 11–15% literal `"`/`\` at 900 KB can pass 1 MB (compile logs, code or JSON samples). Prose is under 1%. Lower the single constant if a real case bites.
- **Bounded-by-construction tools** (`get_help`, `list_maugham_tools`, status and id responses) never trip it.
- **Images: `ImageResponseBuilder`** (720 KB raw-JPEG budget, base64 plus envelope headroom) with crop-on-demand step-down; these return the `content` array and pass the text backstop untouched.
- **Image responses always use crop-on-demand**: `max_dimension` (default 2048), `quality` (default 85), `region` (an optional crop rect). Never return raw images.
- **`read_palette_card` composes independent budgets** (its markdown through `MCPResponseBudget`, its thumbnails through `combinedThumbnailByteBudget`, 720 KB), so a worst-case card can in principle pass 1 MB. Documented, not fixed.
- **The guard is a dead end for the caller**: for anything that scales with the project (listings, cross-document search), paginate, filter or summarize so the response fits before it reaches the guard.

### Tool contracts

**Project and document reads**
- **`get_outline` reports the DERIVED review status**: `review_status` (`ReviewStatus.derived` over the piece's states, the projection every in-app dot draws) and `pass_states` keyed by `ReviewPass.id`, with `review_passes` at the top level in ladder order. The passes come from `ProjectManifest.effectiveReviewPasses`, never the raw stored array.
- **`get_outline`'s legacy `status` stays on the wire and nothing writes it**: `review_status` is the truth. A GROUP node reports both new fields as `null` (`Node`'s hand-written encoder keeps the schema uniform).
- **Each `review_passes` entry carries `brief`** (`PassInfo.brief`), resolved through `ReviewPass.effectiveBrief`, never the raw `brief`, so a preset pass serves the preset's. The wire serves doctrine, never an editor persona: `editorName` stays off it. `null` only for a briefless custom pass.
- **`search_text` filters to `.manuscript`; ⌘⌥F does not reach a statement**, and that is a stop, not an omission.
- **`find_references` and `list_all_links` scan manuscript documents, research note bodies (canvas promotion writes `[[…]]` into notes) and statements**, and resolve a statement's composed title (`"Craft Intent · <doc>"`) as a `[[…]]` target at lowest precedence.
- **`move_research_item` takes exactly one of `target: "shared"`, `target_group_id`, `target_document_id`**, and wraps `ProjectStore.moveResearchItems` (`Maugham/Stores/ProjectStore+ResearchMove.swift`; read its header before touching the validation).
- **A cross-scope move leaves explicit links (`linkedResearchIds`) untouched**: association is containment-based. A manual link goes dormant while the item lives in a piece's research and resurfaces on move-out; a containment-only association severs on move-out and no link is minted.

**Statements and the palette**
- **Every statement reader looks its statement up through `StatementLookup` and derives through `ProjectStore.statementText(of:)`** (the open pane's `Document` through `ProjectStore.openStatementDocument(id:)`, else `derivedCache`), so no two readers disagree about which text is real. Absence is `exists: false` (with empty `markdown`), never an error, and a read mints nothing.
- **`read_craft_intent`'s `item_id` names any manuscript document**; the other four are project scope only, and their schemas take no `item_id`, because `StatementConvention.newPath` has no document row for visual language, an edition brief, the lessons ledger or the first reader.
- **`read_edition_brief` is keyed by `language`** (`Statement.Kind.editionBrief(String)`) and returns any `## Rulings` a translation session settled (`RulingPerformer`, `StatementEssay.carriesRulings`), so an outside translator finds them instead of re-deciding register.
- **`read_lessons`' description tells Claude to read it before the piece and to cite a habit by its heading verbatim.**
- **`read_first_reader`'s `name` comes from `ProjectManifest.firstReaderName`**, not the statement, so `name` can be present while `exists` is false.
- **`read_visual_language` returns paths, not pixels.** The images are scanned out of the statement text (`MarkdownBlockParser.findInlineImages`, unanchored, so a mid-paragraph image counts) and resolved through `ProjectStore.resolveImageRef`. Nothing in this catalogue reads a file by project-relative path, so the description tells Claude to ask the writer about any image it needs; `read_document` reaches one only if it is also a research item.
- **A reader the skills do not tell Claude to call leaves its consumer unmet**: `docs/skills/maugham-bootstrap/SKILL.md` tells a template-authoring Claude to read visual language first, and names the paragraph anchors and cross-link command. No tool reads an anchor or a cross-link, deliberately.
- **The propose tools write nothing to a statement.** `propose_edition_brief` (`language`, `markdown`, `rationale?`) validates through `StatementProposalStore.validate` (project, tag, and a `## Rulings` section holding only glossary-shaped lines), overwrites the one slot `.maugham/statements/proposals/edition-brief-<tag>.json`, and posts `maughamStatementProposalsChanged`; the desk's Edition Brief door presents `StatementPane`, where the writer adopts or discards it.
- **`propose_visual_language` refuses a `## Rulings` section** (visual language has no strata); its slot is `<project>/.maugham/statements/proposals/visual-language.json`, adopted in the Visual Language pane (⌘⌥V), whose picker carries a "proposed" badge while a slot stands.
- **Neither propose tool is in `CompilerAllowlist`.**
- **`promote_inbox_entry`'s destinations are exclusive**: at most one of `target_document_id`, `palette_card_id`, `palette_subject` (a case-insensitive title match; no match fails, never mints a card). `title` is honoured for research promotes only.

**Annotations**
- **The four creation tools stamp the review pass the writer is working that piece through, on the open-document arm only** (`activeReviewPassId`, validated through `ActivePassMemory.validatedActivePass`, so a retired pass stamps nothing). The closed-document arm has no window and no active pass, so it writes unstamped by design; an unstamped note appears in EVERY pass's queue.
- **Claude never chooses the pass or the triage**: no tool schema takes either; `list_annotations` and `get_annotation` report `triage` (`do`/`decline`/`discuss` or null) and `review_pass_id` back, key for key, and no filter parameter exists, so pass semantics stay `AnnotationPassFilter`'s.
- **The orphan-annotation sweep is edge-triggered**: `Document._pendingSweep: SweepReason?` carries the removed paragraph ids, and the sweep archives only annotations on `reason.removed` (ADR 0010; `PresenterRoutingTests`, including MCP annotation on a live doc minting no spurious `claude_archive`). If annotations vanish, suspect the reason's population at the call site (`setFullText`, `deleteParagraph`, `handleExternalLogChange`), not the sweep.

**Publishing**
- **A Publication is keyed on `(imprint, version, language, format)`.** A source `compile` (no `language`) takes its version from `next_version` and bumps it; a `language` edition renders an EXISTING source version (pin it with `version`, which requires `language`, or omit it for the latest source publication) and never bumps. With no source publication, a language compile fails loudly ("compile the source edition first"). The collision guard refuses only an exact four-part match.
- **`compile`'s `dry_run: true` runs the same resolution, collision guard and coverage gate and returns the verdict** (`{status: dry_run_passed, warnings}` or the failed shape) with no output, Publication or bump. `language`/`allow_stale` select a translated edition behind the coverage gate.
- **`imprint` is resolved at the orchestrator's door** (`PublishConfig.resolved(imprint:pieceIDs:)`), so nothing below takes an imprint; omit it for the book. An unknown name refuses through the ordinary failed shape (`{status: failed, errors, log_excerpt: "unknown_imprint: <name>"}`), never a thrown `MCPError`, and nothing is compiled, recorded or bumped.
- **`preview_compile` scopes its pieces with `section_ids`, and mirrors `compile`'s `language`/`allow_stale` behind the SAME gate, scoped to the pieces it renders**, and resolves `imprint` through a two-line twin of the door (the refusal fails the already-registered job, with the same excerpt). The preview's `filename_template` names no `{imprint}`, so an imprint preview lands as `preview-<version>-<ext>-<imprint>.<ext>` through the collision guard and never replaces the book's: the preview directory is last-write-wins.
- **`list_publications` surfaces `language` and `imprint` on every row** (`null` for source / the book), filterable by exact value or the sentinels `"source"` and `"book"`.
- **`read_publication_page`'s `language` and `imprint` narrow a shared `version`, and with `publication_id` they must agree with it**; version-only addressing stays first-write-wins.
- **`read_preview_page` reads the newest `.pdf` by mtime in `.maugham/publish/build/preview/`** with no id addressing, and returns `preview_filename` and `preview_mtime` so staleness is visible. It fails loudly with no preview; an EPUB preview errors.

**Translation**
- **Each `write_translation` entry supplies exactly one of `text`, `verbatim: true` or `delete: true`**: `verbatim` copies source chrome unchanged; `delete` is a tombstone, how an orphan (a translation whose source paragraph is gone) is purged. An empty or whitespace-only `text` counts as ABSENT (`ReportJSON.nonEmptyString`), so it meets the exactly-one refusal rather than storing `""` that coverage would read as translated.
- **A `text`/`verbatim` entry naming an unknown paragraph rejects the whole batch; a `delete` entry is exempt**, per entry, not per batch. Tombstoning an id never translated is an idempotent no-op.
- **The server stamps every record with a hash of the current source paragraph**; non-verbatim entries surface structural-drift warnings and an advisory (never blocking) when the text equals the source.
- **The batch persists through one `TranslationStore.appendBatch`, every record built first**, so a rejected or failed batch writes nothing. A tombstones-only batch for a language with no records writes nothing and still reports the entries (otherwise the language would appear in `languages(forDocId:)` forever).
- **The permit refuses first**: `TranslationWritePipeline.refuseUnlessTranslatable` asks Core's `PostureDoor.posture(as:using:)` for the translator in the `.translation(piece:)` class and checks `.allows(.translate)` before anything is built; a refusal is a `translation_not_permitted` tool error naming the piece. The file is admitted no permit or posture spelling of its own (tripwire 51, `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`). The orphan purge asks the same door under the author's key.
- **None of that lives in the tool**: validation, record building and the single append are `TranslationWritePipeline.perform`, shared with the translator loop; the tool keeps the wire form (decode, the language gate ahead of the registry lookup, the project-scoped post, the response). `TripwireGrepTests.test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended` counts `appendBatch` sites; the one sanctioned second is `TranslationReviewPaneLogic.purgeOrphans`, tombstones only.
- **`read_translation` reads an unknown language as all-`missing`, but a translation file that is PRESENT and unreadable fails the call by name** (`OpLogStore.ReadError.unreadableFile`): skipping it would answer like not-started and send Claude to re-translate a chapter already on disk. `status` filters entries (`stale` + `missing` is the retranslation worklist).
- **`translation_status` reports one row per (document, language)** with `fresh`/`stale`/`missing`/`verbatim`/`orphans` counts and `open_queries`; `document_id` narrows it to one document, and the whole-project walk skips collection references (the `ProjectStoreASTSource` walk).
- **`translation_status`'s rows are the UNION of three sources**: languages with translation files, languages named on an open query, and languages the manifest holds a `.translator` role for. The union is `EditionStatus`' (`Maugham/Publish/EditionStatus.swift`), the tool's body and the desk's, so neither reports an edition the other cannot see; a stored tag joins lowercased.
- **A row with no translation file reports coverage as all-zero, not every paragraph missing**, and a role-only edition reports one zero row per manuscript document.
- **`open_queries` counts language-tagged craft notes as well as `.query`s**: a whole-document question cannot be an anchorless `.query`, so it mints as a tagged craft note.
- **The walk opens EVERY manuscript document through `withAnnotationDocument`** (an accepted cost of the query half), and an unreadable chapter degrades to an entry in `unreadable_documents`, always present; its rows are ABSENT, not zero. A caller-supplied `document_id` the manifest does not hold still fails loudly with `invalid_argument` before the walk.
- **`reader`, `collator` and `translator` name the edition's cast** (`EditionStatus.readerName`/`collatorName`: stored role, then preset, then omitted; a read never mints a role). `last_round` carries the newest `TranslationRoundStore.latest` round for that exact `(document, language)` pair, omitted until one has run: its number, `leg2_verdict`/`leg4_verdict`, its note/departure/declined counts, its summary, and the leg it `stopped_at` when it failed or was cancelled (`TranslationStatusToolTests.test_rowsNameTheReaderAndCollatorWithoutMinting`, `test_theLastRoundIsThisPairsNewestAndAnotherChaptersIsNotReported`). The department desk reads the same store, so the tool and the desk report one round.

**The planning canvas**
- **`list_canvas` reads the OPEN canvas when there is one and the sidecar otherwise**: a derived file is not read as truth while its source is in memory. `read_from` says which (`"open_canvas"`, live and possibly mid-sentence, or `"sidecar"`).
- **The discriminator is `CanvasModel.isAttached`, spelled once in the shared `CanvasClaudeWrite.readScene`**: the read and the write must not disagree about which canvas is real.
- **`list_canvas` reports every card, region (its home members and appearances), line and inspector mark** (`promoted_item_id`, `contributed_to_item_ids` — every artifact the card's content fed — and `bound_piece_id`).
- **`author` is absent for the writer's cards and lines and `"claude"` for ones added here; `provenance` is `"project"` (research the canvas points at, named by `reference_id`) or `"owned"` (an ingested photograph).** No path is on the wire, since nothing here reads one; `provenance` is what tells a picture from an `"item"` whose research was deleted.
- **`piece_references` reports the projection, not its inputs**: a reader computing `home ∪ appearances` from `home_node_ids`/`appearance_node_ids` picks up a *visitor* (a card cited in a region, not owned by it). Residents only, unioned across regions, through `RegionBinding.references(forPiece:in:)`, which the tool calls rather than restates (`RegionBindingTests.test_theProjectionHasAProductionCaller`). It is keyed on the regions' bindings only (a card's own `bound_piece_id` is where a promotion from it lands, a different relationship), an array in piece-id order, and a bound empty region reports an empty list.
- **`list_canvas` says whether the layout could be read** (`layout_readable`, `layout_unreadable_reason`) on both routes, because a refused file loads as every card loose. Scrap text is unbounded, so it calls `MCPResponseBudget.enforce` itself; `include_text: false` is the narrower read its refusal names.
- **`add_canvas_scraps` takes no position, node id or region id**: placement is `CanvasClaudePlacement`'s, and `connect` indexes this call's own `scraps` array (`[[0, 2]]`), so Claude can reach nothing the writer made. Everything lands in one labelled region; nothing Claude adds is loose.
- **`source_item_id` is the research item the words came off**, placed above them in the same region and carrying no author.
- **`add_canvas_scraps` validates fully before writing**: a blank scrap, an unknown source id, an out-of-range or self `connect` pair, and a repeated or reversed pair (a line is undirected: `[0,1]` and `[1,0]` are one line) are each refusals.
- **`canvas_sidecar_unreadable` refuses before any mutation** (through `CanvasStore.loadForTransientWrite()`, on both routes): a newer-build or damaged `<project>/.maugham/canvas.json` loads as an EMPTY scene, and saving that would overwrite the whole arrangement. Its hint is per reason (newer version or damaged; an attached read-only canvas refuses too) and names `list_canvas`, which flags the file with `layout_readable: false`.
- **It writes `canvas.md` and `<project>/.maugham/canvas.json` and nothing else, through `CanvasClaudeWrite.apply`**, so the batch is one undo step whether or not the Plan persona is open.

### Skills (SEP-2640)
- **The skills methods are protocol methods on top of `resources/read`, not tools**: `initialize` declares `capabilities.extensions["io.modelcontextprotocol/skills"] = {}`; `skills/list` enumerates bundled skills (`name`/`description`/`uri`/`frontmatter`/`resources`, each resource with a `sha256:<hex>` digest); `skills/get` resolves **by URI** and fails with `-32602` on an unknown one; `resources/read` serves `skill://` URIs only and fails loudly on any other.
- **Content is `docs/skills/<name>/SKILL.md`**, flat frontmatter (`name`, `description`), bundled as a folder resource in `project.yml` and loaded by `SkillIndex` (strict and throwing in dev builds, skip-with-log in release). Edit the bundled file; never add a second copy.
- **Served skills**: `edition-brief`, `editing-pass`, `transcribing-notebooks`, `translation-pass`, `visual-language`. The two interview skills end by calling their propose tool; `editing-pass` opens with the two-loops split (a check's reader versus a round's editor).
- **`maugham-bootstrap` (frontmatter `name: maugham`) is never served** by `skills/list`, `skills/get` or `get_help`; it reaches the world only through `ClaudeCodeSkillInstall`, which writes and refreshes `~/.claude/skills/maugham/SKILL.md` from `HelpClaudeDesktopSheet`'s Claude Code section.
- **`get_help` also serves skills**, because no shipping client speaks SEP-2640 yet: topic `"skills"` is the index; a skill's name returns its body. `read_document` and `add_comment` each carry one nudge sentence pointing at the relevant skill topic.
- **`get_help` serves the bundled `docs/guide/` topics**, the same single source as Help → Maugham Help (`HelpWindow`) and GitHub, loaded by `HelpTopicIndex`; edit `docs/guide/`, never a second copy. The skills are a fourth bundled content root beside `docs/guide/` and `Maugham/Resources/Samples/`, under the same discipline.
- **SEP-2640 is unmerged; every shape lives in `SkillsExtension.swift` under its revision pin** (`// SEP-2640 pin: PR #2640 diff fetched 2026-07-18`): check the SEP on next touch. The one deliberate deviation is a superset: `skills/list` entries carry top-level `name`/`description` beside the `frontmatter` copy.
- **The installer has four states keyed on `managedMarker`** (`<!-- maugham:managed`): notInstalled, installedCurrent, stale, userModified (byte-compared). A marker-less file is `.userModified` and needs an explicit confirmed Replace, never the one-click Update a `.stale` copy gets.
- **Maugham never shells out to `claude`**: the `claude mcp add` command is copyable text.

### The dev-only test catalogue
- **`TestMCPToolCatalog` is registered only under `#if MAUGHAM_DEV_BUILD`, on the same dev socket**, and is absent from the stable binary (`TripwireGrepTests.test_testMCPCatalog_registeredOnlyUnderDevFlag`). It is for Claude Code and outside the production count.
- **It drives the full create → edit → autosave → checkpoint → quit → relaunch → verify loop** to check invisible state (op log, autosave, cursor restore, checkpoints, the clean `.md`); it does not cover UI fidelity, which stays a manual pass (ADR 0020).
- **Every mutating test tool resolves its project through `TestWorkspace.require(_:)`** (MaughamCore), which throws unless the path is under `~/Library/Application Support/Maugham Dev/TestWorkspace/`. Inspect tools are not fenced. Under XCTest the root gains a per-worker `xctest-worker-<pid>` leaf, because `reset()` deletes the whole tree (`TestWorkspaceIsolationTests`).
- **`test_apply_edit` writes through the editor's own entry point** (`setFullText` + `recordEditorTextWrite`, mirroring `EditorHost`), never a parallel mutation path or faked keystrokes, so there is one manuscript write path (tripwires 6/7). Its one `setFullText(` is a counted site in tripwire 52's `TripwireGrepTests.manuscriptWriterCallSites`; a second manuscript writer in a test tool changes that count.
- **The tools**: drive (`test_create_project`, `test_open_project`, `test_add_document`, `test_open_document`, `test_close_document`, `test_apply_edit`, `test_checkpoint`, `test_reset_workspace`); lifecycle (`test_ping`, the readiness probe after relaunch; `test_flush_autosave`; `test_quit`, which acks first and terminates ~100 ms later); inspect (`test_dump_document`: paragraphs by `sequence`, `¶id` and text, cursor, `lastDiskEcho`, the pending sweep; `test_dump_oplog`; `test_autosave_status`; `test_pending_buffer`, the `PendingBuffer` durable sequence; `test_list_checkpoints`).
- **Connection**: the repo-root `.mcp.json` and `scripts/maugham-test-mcp.sh` point `MAUGHAM_MCP_SOCKET` at the dev socket and exec the `maugham-mcp` bridge, surfacing the tools as `mcp__maugham_test__*`.

## Recipes

### Add a tool
1. Implement it in `Tools/<Family>.swift`: an enum conforming to `MCPTool` with `method`, `description`, `inputSchemaJSON` and `handle(paramsJSON:registry:)`; decode params and resolve `project_id` through `MCPToolHelpers.swift`.
2. Decide its side of the membrane (Rules → The membrane). A write tool needs an ADR, and goes into `writeTools` in `MaughamTests/CompilerAllowlistTests.swift` (`test_noWriteToolIsAllowed`). A name that writes a statement fails `test_noStatementWritingToolExistsAnywhereClaudeCanReach`. A tool that would write a task fails `test_nothingUnderMCPEmitsATaskOp`; decide `Permit.isALoadEmission` first.
3. Add the type to `MCPToolCatalog.all` in `MCPTool.swift`; that is the only registration.
4. Add its method to the expected set in `MaughamTests/MCP/MCPProtocolHandlersTests.swift` (`test_toolsList_returnsAllExpectedTools`).
5. If the compiler's session should reach it, add `mcp__maugham__<method>` to `Maugham/Compiler/CompilerAllowlist.swift` (reads only; `test_everyEntryNamesACatalogTool`).
6. Images: use the crop-on-demand parameters through `ImageResponseBuilder.swift`. Unbounded text: call `MCPResponseBudget.enforce` with a section-scoped hint (mirror `read_document`), and paginate or filter anything that scales with the project.
7. Load documents only through `withAnnotationDocument` or with a named `DeviceActor` (tripwire 38); derive from the op log (tripwire 20).
8. List it under `## Tool catalogue (NN)` above, bump NN (`DocSyncTests`), and add its contract to Rules → Tool contracts.
9. If a procedure should call it, name it in that skill's `docs/skills/<name>/SKILL.md` and in the router `docs/skills/maugham-bootstrap/SKILL.md`; if writers see it, in the relevant `docs/guide/` page (`claude-desktop.md`'s *What Claude can do*, or the feature's own page, e.g. `review-passes.md`). A tool nobody is told to call has no consumer.
10. Tests in `MaughamTests/MCP/Tools/`; then try it from Claude Desktop (Settings → Help → "Set up Claude Desktop…").

### Add a skill
1. Write `docs/skills/<name>/SKILL.md` with `name` and `description` frontmatter; the `docs/skills` folder resource in `project.yml` bundles it.
2. `Maugham/Help/SkillIndex.swift` loads it; a malformed or duplicate frontmatter throws in dev (`SkillIndexTests`), and a skill name must not collide with a `docs/guide/` slug (`GetHelpToolTests.test_bundledGuideSlugsAndSkillNames_areDisjoint`).
3. Add it to the served-skills list under Rules → Skills, and point the router `docs/skills/maugham-bootstrap/SKILL.md` at it if Claude Code should reach for it.

### Add a dev-only test tool
1. Implement it in `Test/Tools/`, `test_`-prefixed, under `#if MAUGHAM_DEV_BUILD`; a mutating tool resolves its project through `TestWorkspace.require(_:)`. A manuscript write is a counted site in tripwire 52's `TripwireGrepTests.manuscriptWriterCallSites` (`TestEditTool.swift` holds the one `setFullText(`); a new one changes that count.
2. Add it to `TestMCPToolCatalog.all` in `Maugham/MCP/Test/TestMCPToolCatalog.swift`; `TestMCPCatalogConsistencyTests` covers it. The production heading does not move.

## Pointers

- ADRs: 0003 (live-only Unix socket), 0004 (foundation scope, the 1 MB incident), 0010 (typed seams, the sweep reason), 0020 (the test MCP), 0026 (the canvas write), 0032 (the signed op log, actors); ADR 0030 §7 and the translation pipeline spec for the propose tools.
- `docs/superpowers/specs/2026-07-01-test-mcp-design.md`.
- `docs/tripwires.md` rows 10, 13, 20, 21, 38, 51, 52, 54.
- Tests: `MCPCatalogConsistencyTests`, `MCPProtocolHandlersTests`, `DocSyncTests`, `CompilerAllowlistTests`, `MCPBinaryIntegrationTests` (the real bridge against bogus or absent sockets), `MCPColdStartTests` (the bridge against a stub listener; the cold-launch pin), `MCPServerLifecycleTests`, `PresenterRoutingTests`, `TestMCPCatalogConsistencyTests`, and per-tool tests under `MaughamTests/MCP/`.
- Elsewhere: manuscript persistence in `Maugham/Stores/DocumentStore.swift`; the op log in `Maugham/OpLog/`.
- Neighbouring guides: `Maugham/OpLog/AREA.md` (actors; "Chain, identity and seals"), `Maugham/Canvas/AREA.md` (`CanvasClaudeWrite`, placement), `Maugham/Compiler/AREA.md` (the allowlist, the statement gate), `Maugham/Stores/AREA.md` (the research mover, statements).
- History: `docs/history/mcp.md`.
