# MCP — Area guide

The local MCP server that lets Claude Desktop read and contribute to projects. Read this before editing anything in `Maugham/MCP/`. Also read the project root `CLAUDE.md` for cross-cutting invariants, and `docs/adr/0003-mcp-live-only-unix-socket.md` + `docs/adr/0004-mcp-foundation-scope.md` for the canonical transport and scope decisions.

## What this area owns

The in-app MCP server: tool registration, JSON-RPC handling, the read/search/discover surface for projects, the **two write paths into the planning plane** — `add_note` under `research/`, and (1C-c3) `add_canvas_scraps` onto the planning canvas — the annotation layer (paragraph-anchored comments from Claude), and the bridge between Claude Desktop's stdio and Maugham's Unix socket. **Manuscript text is never one of them**; see tripwire 4, which is where that half of the rule is stated and where it does not soften.

## Tool catalogue (56)

**Discovery / identity**
- `list_projects` — enumerate all open Maugham projects
- `list_maugham_tools` — flat, authoritative list of every tool + server identity block
- `get_help` — read Maugham's bundled user documentation by topic (read-only); topic `"skills"` lists Maugham's agent skills, a skill's name as topic loads its full procedure (see "SEP-2640 skills extension" below)

**Project read**
- `get_metadata` — title, type, tags, word targets, session stats for a project
- `get_outline` — hierarchical binder structure (groups + documents). **As of M3 P3 a document node reports the DERIVED review status** (`review_status`, `ReviewStatus.derived` over the piece's states — the same projection every in-app status dot draws) plus `pass_states`, the per-pass map keyed by `ReviewPass.id`, and the outline's top level carries `review_passes` in ladder order because a JSON object's key order is `Dictionary` iteration order and a reader otherwise cannot order the map. The passes come from `ProjectManifest.effectiveReviewPasses`, never the raw stored array. The legacy free-string `status` STAYS on the wire — removing a shipped field is a breaking change — but the disagreement window M3 P1's whole-branch review opened (seam 1) is **closed**: `review_status` is the truth, `status` is history nothing writes. A GROUP node reports both new fields as `null`, the uniform-schema rule `Node`'s hand-written encoder exists for (a group is not a piece and is ruled on nowhere). **As of M4 P2 each entry in `review_passes` also carries `brief`** (`PassInfo.brief`, resolved through `ReviewPass.effectiveBrief` — never `$0.brief` raw, so a stored preset-id pass with no brief of its own still serves the preset's), the pass's editorial doctrine rather than any editor persona (spec §4: the wire serves doctrine, not personas — `editorName` stays off it); `null` only for a briefless custom pass, emitted as the JSON literal, not an omitted key. Another widening of an existing read — **the tool count is unchanged**
- `list_scenes` — slugline-level scene list for screenplay projects
- `get_session_stats` — per-doc session word-count and activity stats

**Document read**
- `read_document` — full manuscript text (or image with crop-on-demand for images)
- `search_text` — cross-document full-text search within a project
- `find_references` — wiki-link back-references to a document or research item; scans manuscript documents, research note bodies (canvas promotion writes `[[…]]` into research notes) and statements (M1A moved craft intent into one). Also resolves a statement's composed title (`"Craft Intent · <doc>"`) as a `[[…]]` target, lowest precedence (2026-08-09, issue #24) — a widening of an existing read, tool count unchanged
- `list_documents_by_tag` — filter binder documents by tag

**Research / links**
- `add_note` — write a new research note under `research/` (one of two write tools; the other is `add_canvas_scraps`, under Planning canvas below)
- `list_research` — enumerate research items in a project
- `link_research` — create a research ↔ manuscript link
- `unlink_research` — remove a research ↔ manuscript link
- `list_all_links` — all research–manuscript links for a project, incl. `piece_research` edges (a collection piece's own research, no explicit link needed); wiki-link scanning covers manuscript documents, research note bodies and statements. Also resolves a statement's composed title as a `[[…]]` target, lowest precedence (2026-08-09, issue #24) — a widening of an existing read, tool count unchanged
- `move_research_item` — batch-move research items (including whole groups) between shared research, a research group, and a collection piece's research folder; exactly one of `target: "shared"` / `target_group_id` / `target_document_id`. Cross-scope moves leave explicit links (`linkedResearchIds`) untouched — association is containment-based (2026-07-17): a manual link goes dormant while the item lives in a piece's research and resurfaces on move-out; a containment-only association severs on move-out with no auto-link minted. Wraps `ProjectStore.moveResearchItems` (`Maugham/Stores/ProjectStore+ResearchMove.swift`) — read that file's header before touching this tool's validation shape.

**Palette / the spine (intent + visual language)**
- `read_craft_intent` — the writer's optional freeform statement of what a piece needs sensorially; absence returns `exists: false`, never an error. Since M1A it answers off a `Statement` and `item_id` names **any manuscript document**, not a Collection loose piece alone (a widening of an existing read, so the tool count did not move); the read derives from the op log — the open pane's `Document` through `ProjectStore.openStatementDocument(id:)`, else `derivedCache` — never the `.md`
- `read_visual_language` — the book's look: the writer's freeform prose about typography and feel, plus `image_paths`, the images it references. **M1A's second named protection** (spec §10) — visual language gets a consumer in the milestone that builds it, and the other half of that protection is the section in `docs/skills/maugham-bootstrap/SKILL.md` telling a Claude authoring a template to read this first; a tool nobody is told to call leaves it unmet. **Project scope only, and the schema says so by taking `project_id` and nothing else**: `StatementConvention.newPath` has no row for `(.visualLanguage, .document)`, so an `item_id` would promise a scope the store refuses to create. Absence is `exists: false`, never an error, and mints nothing. The prose derives from the op log through `ProjectStore.statementText(of:)` — the ONE spelling of ADR 0018's two branches for statements, shared with `read_craft_intent` so the two readers cannot disagree about which text is real — and the images are scanned out of that same text (`MarkdownBlockParser.findInlineImages`, unanchored, so an image referenced mid-paragraph counts) and resolved through `ProjectStore.resolveImageRef`. **Paths, not pixels, deliberately**, exactly as `list_canvas` reports no path: nothing in this catalogue reads a file by project-relative path, so the field says WHICH images the look is built on and the description tells Claude to ask the writer about any it needs to see. The edge, stated rather than implied: `read_document` is the only image reader here and it takes a research item id, so a visual-language image that is also a research item is reachable and a loose file at the project root is not.
- `read_edition_brief` — the third `Statement.Kind`, alongside intent and visual language: the writer's doctrine for one translated edition (register, idiom policy, and any rulings a translation session has settled there — `RulingPerformer` can write a `## Rulings` section into it, `StatementEssay.carriesRulings` says so). Mirrors `read_visual_language`'s shape exactly — resolve the project, look the statement up through `StatementLookup`, derive its prose through `ProjectStore.statementText(of:)` (never the `.md`, tripwire 20) — but keyed by `language` (`Statement.Kind.editionBrief(String)`) rather than being a singleton, since a book can have many editions. Project scope only, same reasoning as visual language: `StatementConvention.newPath` has no row for `(.editionBrief, .document)`. Absence is `exists: false` with empty `markdown`, never an error, and mints nothing — the read exists so an outside translator finds a prior session's rulings instead of re-deciding register from scratch.
- `list_palette_cards` — summaries of the project's sensory-palette cards (subject-keyed research assets: locations, characters, motifs)
- `read_palette_card` — a card's full markdown plus image thumbnails (crop-on-demand for a single image via `image`)

**Annotations (parallel comment layer)**
- `add_comment` — paragraph-anchored general comment
- `add_suggested_change` — paragraph-anchored suggested edit
- `add_query` — paragraph-anchored open question
- `add_craft_note` — paragraph-anchored craft/technique observation
- `list_annotations` — read annotations for a document (filtered by kind/status). **As of M3 P3 it reports the writer's own two marks back**: `triage` (`do`/`decline`/`discuss`, or null) and `review_pass_id` (or null). Both emit as JSON `null` rather than vanishing — "untriaged" and "belongs to every pass" are facts, and an absent key would read as "this tool does not report triage". Input-side is unchanged: no filter parameter was added, so the pass semantics stay `AnnotationPassFilter`'s and Claude still cannot set either mark
- `get_annotation` — fetch a single annotation by ID; carries the same `triage` + `review_pass_id` pair as `list_annotations`, key for key

**Tasks**
- `list_tasks` — enumerate task annotations for a project
- `get_task` — fetch a single task by ID

**Publishing**
- `initialize_publish_template` — scaffold a LaTeX/EPUB template for a project
- `get_publish_config` — read publish config (`config.json`); includes per-piece `sections.<docId>.include` (default true — set false to omit a piece from the edition, F1)
- `set_publish_config` — write publish config fields (e.g. patch `sections.<docId>.include: false` to ship a subset edition — the excluded piece drops out of compile/republish output and the translation coverage gate)
- `list_publish_files` — enumerate files under `.maugham/publish/`
- `read_publish_file` — read a publish template or config file
- `read_publish_image` — read a publish image with crop-on-demand
- `write_publish_file` — write a template or config file
- `delete_publish_file` — delete a publish file
- `compile` — compile a project to PDF or EPUB via bundled tectonic. A Publication is keyed on `(imprint, version, language, format)` (spec 2026-07-23, widened by 2026-08-27's imprints): a source compile (no `language`) takes its version from `next_version` and bumps it; a `language` edition renders an EXISTING source version — pin it with `version` (requires `language`; refused without) or omit `version` to target the latest source publication's version, and it never bumps `next_version`. No source publication yet → a language compile fails loudly ("compile the source edition first"). The collision guard refuses only an exact `(imprint, version, language, format)` match. `language`/`allow_stale` select a translated edition (behind the coverage gate); `dry_run: true` runs the same resolution + version-collision guard + coverage gate and returns the verdict (`{status: dry_run_passed, warnings}` or the failed/gate-blocked shape) with NO output, NO Publication, NO version bump (F2). `imprint` names an imprint from `config.json`'s `imprints` — its own template, rendered set, metadata and version counter — and is resolved at the orchestrator's DOOR (`PublishConfig.resolved(imprint:pieceIDs:)`), so nothing below it takes an imprint parameter; omit it for the book. An unknown name refuses through the ordinary failed shape (`{status: failed, errors, log_excerpt: "unknown_imprint: <name>"}`), never a thrown `MCPError`, and nothing is compiled, recorded or bumped
- `preview_compile` — fast subset compile, no output/Publication/version bump. `section_ids` scopes the pieces; `language`/`allow_stale` mirror compile to preview a translated edition behind the SAME coverage gate, scoped to exactly the pieces this preview renders (F2); `imprint` mirrors compile too, resolved by a two-line twin of the orchestrator's door (the failure differs — a preview's job is already registered, so the refusal fails it) and carrying the same `unknown_imprint:` excerpt. The preview's own `filename_template` names no `{imprint}`, so an imprint preview lands as `preview-<version>-<ext>-<imprint>.<ext>` through the collision guard and never replaces the book's, which matters because the preview directory is last-write-wins by design
- `compile_status` — poll an in-progress compile job
- `compile_cancel` — cancel an in-progress compile job
- `list_publications` — enumerate past publication outputs; optional `language` filter (exact tag, e.g. `"es"`; sentinel `"source"` selects the untagged source-language rows) — every row surfaces `language` explicitly (`null` for source), so a version's language family (spec 2026-07-23) can be enumerated with one call. Optional `imprint` filter is its sibling (exact name, e.g. `"special"`; sentinel `"book"` selects the rows no imprint compiled) and every row surfaces `imprint` explicitly the same way — the key is `(imprint, version, language, format)`, so the book's 0.1 and an imprint's 0.1 are different publications
- `read_publication_page` — read a page from a compiled PDF; optional `language` disambiguates a `version` shared across a language family (exact tag or the `"source"` sentinel); with `publication_id` it must agree with that publication's language, mirroring the existing `publication_id`+`version` agreement rule. Optional `imprint` disambiguates the same way (exact name or the `"book"` sentinel): with `version` it narrows the family, with `publication_id` it must agree. Version-only addressing is untouched — still first-write-wins
- `read_preview_page` — rasterize a page of the LATEST preview PDF (newest `.pdf` by mtime in `.maugham/publish/build/preview/`), closing the visual loop for `preview_compile`. No id/version addressing — always reads whatever was previewed last (incl. a language edition, F2, or an imprint's, which wears a filename of its own); response carries `preview_filename` + `preview_mtime` so staleness is self-evident. Fails loudly when no preview exists; EPUB previews error (PDF-only)
- `republish` — re-run the last successful compile

**Piece style**
- `set_piece_style` — attach per-piece LaTeX style overrides
- `clear_piece_style` — remove per-piece style overrides

**Translation**
- `write_translation` — record per-paragraph translations of a document into a language, in a parallel translation layer (the manuscript is never mutated). Each entry supplies exactly one of three forms: `text`, `verbatim: true` (copy source chrome unchanged), or `delete: true` (tombstone the paragraph's translation — the way an orphan, one whose source paragraph is gone from the manuscript, gets purged). A `text`/`verbatim` entry naming an unknown paragraph id rejects the whole batch; a `delete` entry is exempt from that check — an orphaned id is exactly what a purge names, and tombstoning an id that was never translated is an idempotent no-op — but the exemption is per-entry, not per-batch: one non-delete entry with an unknown id still rejects the batch, its delete siblings included. The server stamps every record with a hash of the current source paragraph for downstream staleness detection (a tombstone carries one too — meaningless there, and cheaper than a special case); non-verbatim entries surface structural-drift warnings plus an advisory (never blocking) when the translated text is identical to the source — a nudge to mark it `verbatim: true` instead. The whole batch persists through one `TranslationStore.appendBatch` call — every record is built before any is written, so a rejected or failed batch writes nothing. A batch of nothing BUT tombstones for a language that has no records anywhere writes nothing either, and still reports the entries written: acceptance is not persistence, and a tombstones-only file would put a language nobody translated into in `languages(forDocId:)` — and so in `translation_status` and the review picker — permanently, with nothing in it to purge (`TranslationStore.appendBatch`'s guard). Reads current paragraph state via the shared `currentParagraphState` helper (open doc → live `Document`; closed → `DerivedManuscriptCache`, never the on-disk `.md`, tripwire 20). **None of that lives in the tool.** Validation, record building and the single append are `TranslationWritePipeline.perform` (`Tools/TranslationWritePipeline.swift`), which the translator-loop ingest path shares; the tool keeps only the wire form on either side — decode, the language gate ahead of the registry lookup, the project-scoped `maughamTranslationDidUpdate` post, the response. `TripwireGrepTests.test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended` is the census: a second production `appendBatch` site is a second pipeline, and two pipelines drift on which batches are legal and which source hashes are trustworthy. The one sanctioned second site is `TranslationReviewPaneLogic.purgeOrphans`, which appends tombstones only and builds no translated text.
- `read_translation` — read a document's translation into a language, paragraph by paragraph in manuscript order; each entry pairs source with translated text and a freshness `status` (`fresh`/`stale`/`missing`). Unknown language reads as all-`missing` (not an error). Optional `status` filter narrows to matching entries (`status=stale`+`status=missing` = the retranslation worklist). Whole-doc payload, so it self-enforces the 900 KB `MCPResponseBudget`.
- `translation_status` — summarise translation progress; with `document_id` one doc, without it every manuscript doc (skipping collection references, same walk as `ProjectStoreASTSource`). One row per (document, language) with `fresh`/`stale`/`missing`/`verbatim`/`orphans` counts plus `open_queries` (unresolved translator questions for that language; wired in the annotation-language pass — **language-tagged craft notes as well as `.query`s as of P2's final wave**, because a whole-document question like "tú or usted throughout?" cannot be a `.query` at all: `addAnnotation` refuses an anchorless one, so it mints as a tagged craft note, and counting `.query` alone reported zero over a translator who was waiting on an answer. The tag discriminates — an ordinary craft note carries no `language` and is counted for no edition). The row set is the UNION of THREE sources: languages with translation files, languages named on an open query, and — as of cast-management (2026-08-21) — languages the manifest holds a stored `.translator` role for. A translator can ask a question against a language before any file for it exists, and the writer can name one on the department desk (**Add Language…**) before either; both of those rows report coverage as all-zero (not "every paragraph missing," which would conflate not-started with started-and-incomplete) with `open_queries` real. **The role source is a fact about the BOOK rather than about a document**, so a freshly named edition reports one zero row per manuscript document — which is what lets the department desk sum it into a row at all, and the honest reading either way: every chapter is untranslated into it. The union is `EditionStatus`' (`Maugham/Publish/EditionStatus.swift`), which is this tool's own body and the desk's, so neither can report an edition the other cannot see; a stored tag joins it lowercased, because a manifest spelling it `ES` while the files spell it `es` is one edition and must not become two rows. Reading the query half means the project-wide walk now opens EVERY manuscript document through `withAnnotationDocument` (a transient load per closed doc), where it used to skip a doc with no translation file before touching it — an accepted cost of the union, recorded here so it is not rediscovered as a mystery in a profile — and as of #43 one unreadable chapter degrades to a named entry in `unreadable_documents` rather than failing the call — the same fact the desk draws as a Couldn't-read line, one derivation. The field is always present (empty over a book that reads cleanly), and a skipped document's rows are ABSENT rather than zero, so a reader that ignores it will read an unreadable chapter as an untranslated one. **The degrade is for a document the MANIFEST lists that will not open, and nothing else**: a caller-supplied `document_id` the manifest does not hold still fails loudly with `invalid_argument` before the walk begins (the catalogue's unknown-id rule, unchanged), because a typo reported as an unreadable chapter would send its author off to repair a file that was never there. **Provenance, since a sweep has already got it wrong once**: the unconditional per-document open is the QUERY widening's, not the role union's.

**Planning canvas**
- `list_canvas` — the project's planning canvas read whole: every card (scrap or item node), every region with its home members and its appearances, every line, and the marks the inspector shows (`promoted_item_id`, `contributed_to_item_ids` — plural since RULING-51, every artifact the card's content fed — `bound_piece_id`). **It reads the OPEN canvas when there is one and the sidecar otherwise, which is this surface's version of tripwire 20** — a derived file is not read as truth while the thing it was derived from is in memory. `read_from` says which answered — `"open_canvas"` (the attached `CanvasModel`, live and possibly mid-sentence, because the mounted editor folds every keystroke) or `"sidecar"` (`.maugham/canvas.json` + `canvas.md`) — and it is reported rather than inferable, for the reason `read_preview_page` returns the preview's filename and mtime. The discriminator is `CanvasModel.isAttached` and it is spelled once, in the shared `CanvasClaudeWrite.readScene`, never by a reader of its own: the read and the write must not come to different conclusions about which canvas is real. `author` is absent for the writer's own cards and lines, `"claude"` for ones added through this server. **`provenance` (1C-d Task 11) says which sort of item node a card is** — `"project"` for research the canvas points at and never writes to, whose `reference_id` names it, or `"owned"` for a photograph the canvas ingested. **The path is deliberately nowhere on the wire**: nothing in this catalogue reads a file by project-relative path, so it would dangle in exactly the field a reader would most reasonably feed to another tool. What the field buys a reader is telling a picture apart from a reference whose research item has been deleted, which otherwise look identical (an `"item"` with no `reference_id`). It is a widening of an existing read — **the tool count is unchanged**. **`piece_references` (M1A Task 10) reports the REFERENCE PROJECTION rather than the fields it is computed from** — one entry per piece some region binds to, listing the cards that *live* in those regions, in piece-id order. `bound_piece_id`, `home_node_ids` and `appearance_node_ids` have been on the wire since 1C-c3 with nothing saying which to use, so a reader working a piece's context out for itself gets `home ∪ appearances` and picks up a *visitor* — a card cited in a region, not owned by it, which two regions may cite at once. The two rules (**residents only**, **unioned across regions**) live in `RegionBinding.references(forPiece:in:)` and this tool **calls** it rather than restating them; `RegionBindingTests.test_theProjectionHasAProductionCaller` is the census that keeps this the one call site, and before this task that census would have come back empty. Keyed on the REGIONS' bindings only: a card's own `bound_piece_id` is §6.2's association (where a promotion from it lands), a different relationship. A bound region with nothing in it reports an empty list rather than no entry — "bound and not filled yet" is something a writer can act on. An array of entries and not an object keyed by piece id, because a JSON object's key order comes from `Dictionary` iteration and two reads of an unchanged canvas must not differ. Another widening — **still no count change**. Scrap text is unbounded, so the tool calls `MCPResponseBudget.enforce` itself; `include_text: false` is the narrower read its refusal names.
- `add_canvas_scraps` — **the second write tool in the catalogue.** Adds cards to the planning canvas: each string in `scraps` becomes one card marked `author: claude`, and they all land together in one labelled region (nothing Claude adds is loose, §8A.2). **The signature expresses no position, no node id and no region id** — where the cards go is `CanvasClaudePlacement`'s decision, and `connect` indexes *this call's own `scraps` array* (`[[0, 2]]`), so Claude can draw the arrows it read off a page and can reach nothing the writer made. `source_item_id` is the RESEARCH ITEM the words came off; it is placed above them in the same region (the reproduction corollary — reading and source checkable side by side) and carries no author, because the photograph is the writer's. Validates fully before writing anything: an empty or blank scrap, an unknown source id, and a `connect` pair that is not two in-range distinct indices are all refusals, as is a repeated or reversed pair (a line is undirected, so `[0,1]` and `[1,0]` are one line and two coincident lines read as one). **`canvas_sidecar_unreadable` is the one refusal that is not about the call** (#33): with no canvas open the write takes the sidecar route, and a `.maugham/canvas.json` from a newer build or with damaged bytes loads as an EMPTY scene — so the tool used to save that emptiness back over another build's whole arrangement and answer "added". It is raised before any mutation, through `CanvasStore.loadForTransientWrite()`, and its hint names `list_canvas` because that read reports the very same unreadable file as an empty canvas, which is what makes adding to it look safe. Writes `canvas.md` and `.maugham/canvas.json` and nothing else; membrane reasoning in ADR 0026 and spec §8A.2. Persistence is `CanvasClaudeWrite.apply`, so the batch is one undo step whether the Plan persona is open or not.

**Inbox / capture**
- `list_inbox` — enumerate capture inbox entries (voice/text/photo); summaries include the phone's optional `palette_subject`/`sense` aim fields when present
- `read_inbox_entry` — read the content of a single inbox entry
- `promote_inbox_entry` — promote an inbox entry to research, or into an existing sensory-palette card via `palette_card_id` (by id) or `palette_subject` (by case-insensitive card-title match; no match fails rather than minting a card). `target_document_id`, `palette_card_id`, and `palette_subject` are mutually exclusive destinations — at most one. `title` is honored for research promotes only; palette-card promotes ignore it (the card's own title is unaffected by a promoted capture).

## Dev-only Test MCP (`Maugham/MCP/Test/`)

A **separate** catalog, `TestMCPToolCatalog`, that mirrors `MCPToolCatalog`'s shape
(`register(router:registry:)`) but is registered onto the **same dev-build Unix socket**
only inside `#if MAUGHAM_DEV_BUILD` in `MaughamApp.registerTools` — absent from the stable
binary entirely (enforced by `TripwireGrepTests.test_testMCPCatalog_registeredOnlyUnderDevFlag`).
It exists for **Claude Code**, not Claude Desktop, and is not part of the production 56-tool
count above — the "Tool catalogue (56)" heading is unaffected by these tools.

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
  workspace-restricted. (Under XCTest the workspace root gains a per-worker
  `xctest-worker-<pid>` leaf — `reset()` deletes the whole tree and seven parallel
  workers share the machine, so a shared root meant one worker's reset ate another's
  live fixture mid-test; see `TestWorkspace.swift` and `TestWorkspaceIsolationTests`.
  The live app keeps the bare root described above.)

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

## SEP-2640 skills extension (protocol methods, not tools)

`Maugham/MCP/SkillsExtension.swift` implements the draft **Skills Over MCP** extension
(SEP-2640, Extensions Track) on top of the existing `resources/read` primitive:
`initialize` capabilities declare `capabilities.extensions["io.modelcontextprotocol/skills"] = {}`;
`skills/list` enumerates bundled skills (`name`/`description`/`uri`/`frontmatter`/`resources`,
each resource carrying a `sha256:<hex>` digest); `skills/get` resolves a single skill **by
URI** (per the draft, names aren't unique identifiers) and fails loudly (protocol error
`-32602`) on an unknown URI; `resources/read` is implemented narrowly for `skill://` URIs
only — any other URI fails loudly too (Maugham's server has no general resources support).
These three are **protocol methods**, registered directly on the router in
`MaughamApp.registerTools` alongside `initialize`/`tools/list`/`tools/call` — not tools,
so **the tool catalogue count stays 56** whether or not a connecting client speaks the
extension.

**Content source:** `docs/skills/<name>/SKILL.md` (agentskills.io flat-frontmatter format:
`name`, `description`, markdown body) is bundled as a `folder` resource in `project.yml`
and loaded by `Maugham/Help/SkillIndex.swift` (modeled on `HelpTopicIndex`; strict/throwing
load in dev builds, skip-with-log in release so one malformed skill can't take the server
down). It's a fourth bundled content root alongside `docs/guide/` (help topics) and
`Maugham/Resources/Samples/` (sample projects) — same discipline: edit the bundled file,
don't add a second copy. Three skills are served today: `transcribing-notebooks`,
`editing-pass`, `translation-pass`. A fourth folder, `maugham-bootstrap` (frontmatter `name: maugham`), is the
Claude Code router template — `SkillIndex` loads it but `skills/list`/`skills/get`/`get_help`
never serve it; it reaches the world only via `ClaudeCodeSkillInstall`'s installer, wired
into `Views/HelpClaudeDesktopSheet.swift`'s Claude Code section (copyable variant-aware
`claude mcp add …` command + an install/update button that writes/refreshes
`~/.claude/skills/maugham/SKILL.md`, byte-compared for staleness).

**Today-compat surface:** no shipping MCP client speaks SEP-2640 yet, so `get_help` also
serves skills through the same `SkillIndex` — topic id `"skills"` returns the index (name +
one-line description per skill), a skill's own name as topic returns its full body.
`read_document` and `add_comment` each gained one nudge sentence pointing at the relevant
skill topic, so clients with only tools (today's Claude Desktop and Claude Code) still find
the procedure.

**Drift risk:** SEP-2640 is unmerged; all shapes live in `SkillsExtension.swift` with a
revision pin (`// SEP-2640 pin: PR #2640 diff fetched 2026-07-18`) — check the SEP on next
touch. One documented, deliberate deviation from the pinned diff: `skills/list` entries
carry top-level `name`/`description` in addition to the diff's `frontmatter`-nested copy —
a compatible superset (extra fields only), not a rename.

## Layout

- `MCPServer.swift` — Unix socket server, connection lifecycle, SIGPIPE handling. **SIGPIPE handling is idempotent and required** — don't simplify it away.
- `MCPToolsListHandler.swift` — tool list response. Iterates `MCPToolCatalog.all` to advertise tools; never touches them directly.
- `MCPTool.swift` — the `MCPTool` protocol (every tool conforms) and `MCPToolCatalog.all` (the single source of truth for the tool list). `MCPToolCatalog.register(router:registry:)` is the shared registration path used by both production (`MaughamApp.registerTools`) and the seam test (`MCPCatalogConsistencyTests`).
- `Tools/` — one file per tool. Read tools are pure. **Two tools write, and both write into the planning plane and nowhere else**: `add_note` under `research/`, and `add_canvas_scraps` (1C-c3, `Tools/CanvasTools.swift`) to `canvas.md` plus its `.maugham/canvas.json` sidecar. `add_note` was the only one for the whole of foundation scope, and the sentence that said so has been widened rather than qualified — a count is what a reader checks against the catalogue. The **manuscript** half is unchanged and unchangeable (tripwire 4): neither writer can reach manuscript text, and what they write reaches a manuscript only through a deliberate writer act (`promote_inbox_entry`, or the canvas's own `Promote…`).
- Paragraph-anchored annotations live in `Tools/AnnotationCreationTools.swift` (add_comment / add_suggested_change / add_query / add_craft_note), `Tools/AnnotationReadTools.swift` (list_annotations / get_annotation), and `Tools/AnnotationToolHelpers.swift` (`withAnnotationDocument` — transient-load fallback when the doc isn't open in the editor). The parallel comment layer that lets Claude annotate the manuscript without mutating it. **As of M3 P2 all four creation tools STAMP the note with the review pass the writer is working that piece through** (`AnnotationToolHelpers.activeReviewPassId`, validated through `ActivePassMemory.validatedActivePass` so a retired pass stamps nothing) — **the open-document arm only**. `withAnnotationDocument`'s closed-doc arm transient-loads a document nobody is looking at, and there is no window and so no active pass to attribute the note to: that arm writes UNSTAMPED **by design**, which is what keeps M5-AN-048 (a craft note appended to a CLOSED document) working exactly as it did, its note simply belonging to no pass. An unstamped note appears in EVERY pass's queue, so the nil hides nothing. This is **input-side only**: no tool schema gained a parameter — Claude does not choose the pass, the writer's own board click does — and the catalogue count is unmoved. **P3 closed the loop on the READ side**: `list_annotations` and `get_annotation` report `review_pass_id` (and `triage`) back, still with no schema parameter on either — the stamp is reportable without becoming choosable.
- `../maugham-mcp/` — the standalone CLI binary that bridges Claude Desktop's stdio to the app's Unix socket. Lives outside this directory but is conceptually part of this area. Main entry: `JSONRPCBridge.swift`.
- `SkillsExtension.swift` — SEP-2640 skills extension surface (`skills/list`/`skills/get`/`resources/read` for `skill://`); see the section above. `MCPInitializeHandler.swift` declares the extension capability.
- `ClaudeCodeSkillInstall.swift` — Claude Code bootstrap-skill installer: detect/install for `~/.claude/skills/maugham/SKILL.md` across four states — notInstalled/installedCurrent/stale/userModified — keyed on the `managedMarker` (`<!-- maugham:managed`) ownership prefix: a marker-less on-disk skill is `.userModified` (diverged, hand-edited) and needs an explicit confirmed Replace, not the one-click Update a marked `.stale` copy gets. Plus the copyable `claude mcp add` CLI command string (variant-aware via `BuildVariant`). Consumed by `Views/HelpClaudeDesktopSheet.swift`'s Claude Code section, not executed — Maugham never shells out to `claude`.

## Hard rules

- **Trust boundary: same-user only, filesystem-enforced.** The socket carries no auth of its own — anything that can connect to it can call every tool. That's an explicit assumption of ADR 0003, not an oversight: the socket file lives under `~/Library/…` with standard user-only permissions, so the only processes that can reach it are already running as the same user, who could read/write the project files directly anyway. Don't add socket-level auth on the theory that it "defends" anything — it doesn't, under this threat model.
- **Transport is live-only Unix socket.** No stdio inside the app. The standalone `maugham-mcp` CLI is the stdio adapter for Claude Desktop. (ADR 0003)
- **The server only runs while Maugham is running.** No background daemon, no LaunchAgent. Settings → General → "Allow Claude to connect (MCP)" toggles it; default on.
- **Foundation scope: read tools + `add_note`.** `add_note` only writes under `research/`. **Manuscript text is never mutated via MCP** — that's the annotation layer's job (or no-op, in foundation scope). The user's framing: *"the manuscript is yours, full stop. Claude operates in a parallel annotation layer."* (ADR 0004)
- **Tool responses are capped at ~1MB, and the cap is enforced — not just documented.** (The ~1 MB figure is *inferred* from the ADR-0004 incident, not a measured Claude Desktop / transport constant — treat it as the working ceiling, not a guarantee.) The limit is a property of the JSON-RPC *line*, so enforcement is layered rather than per-tool-by-hope:
  - **Text:** `MCPResponseBudget.enforce(_:hint:)` (`MCPResponseBudget.swift`, `maxTextBytes = 900_000` — 900 KB). It fails loudly with a structured `payload_too_large` tool error carrying a section-scoped hint. Two layers, and the distinction matters:
    - **Per-tool `enforce` calls** on the unbounded single-value file readers (`read_document` manuscript + research, `read_publish_file`, `read_inbox_entry`, `read_craft_intent`, `read_visual_language`, and `read_palette_card`'s markdown block — the last bypasses the default wrap because it returns a `content` envelope). These fire **regardless of how the tool was invoked**, including the top-level-JSON-RPC-method path.
    - A **central backstop** in `MCPToolsCallHandler`'s default text-wrap branch (generic hint) catches every *other* plain-JSON tool so a new text tool can't silently reintroduce the gap — **but it only covers the `tools/call` dispatch path.** Tool methods invoked as **top-level JSON-RPC methods bypass `MCPToolsCallHandler` entirely** (`MaughamApp.swift` registers each `tool.method` directly on the router; this is the audit's known Low finding, Task 26 territory), so a backstop-only tool called that way is *unguarded*. Don't rely on the backstop for end-to-end coverage that path doesn't have; the per-tool `enforce` calls are the only ones that hold universally.
    - Why 900 KB and not nearer 1 MB: the enforced payload is re-escaped as the string value of a `text` block (a second JSON escape) then wrapped in the tool-result + JSON-RPC envelopes. The real constraint is **backslash/quote density** — content around **~11–15%** literal `"`/`\` at 900 KB can push the escaped line past 1 MB. That's not hypothetical: compile logs and code/JSON samples (via `read_publish_file` / research notes) are realistic high-density cases. Ordinary prose is <1% density and sits far under. Lower the single constant if a real case bites.
    - Bounded-by-construction tools (`get_help`, `list_maugham_tools`, status/id responses) never trip it.
  - **Images:** `ImageResponseBuilder` (720 KB raw-JPEG budget, base64 + envelope headroom) with crop-on-demand step-down. These return the `content`-array envelope and pass through `MCPToolsCallHandler` untouched by the text backstop. Note `read_palette_card` composes **independent** budgets — its markdown text (`MCPResponseBudget`) and its combined thumbnails (`combinedThumbnailByteBudget`, 720 KB) are checked separately, so a worst-case card (a full 900 KB of notes *plus* six near-budget thumbnails) can in principle exceed the 1 MB line. Realistic cards are nowhere near either ceiling; documented, not fixed (reviewer Minor).
- **Image responses use crop-on-demand.** Parameters: `max_dimension` (default 2048), `quality` (default 85), `region` (optional crop rect). Default output: JPEG q=85, max 2048px on the long side. Don't return raw images.

## Tripwires

1. **Adding a tool: implement `MCPTool` on it, then add the type to `MCPToolCatalog.all`.** That's the only place to list tools. `MCPToolsListHandler` and `MaughamApp.registerTools` both derive from the catalog, so they can't drift. `MCPCatalogConsistencyTests` asserts the contract holds (catalog ↔ tools/list, catalog ↔ router, schema validity). If you find yourself editing `MCPToolsListHandler` to add a tool entry, stop — you're working against the protocol.

2. **First MCP call after (re)start: fixed 2026-07-12 — keep the two reconnect paths unified.** The old bridge polled 15s for the socket when it had a *prior* connection but fast-failed (~1.5s) when it had *none* — and "no prior connection" is exactly the first call after the app launches (Claude Desktop spawned the bridge while Maugham was closed). A cold launch slower than ~1.5s lost its first call; a retry succeeded. Fix: `handleStdinLine` runs one bounded poll loop for **both** cases (budget `MAUGHAM_MCP_RECONNECT_BUDGET_MS`, default 15s; tests set it low). Don't reintroduce a `hadPriorConnection` fast-fail branch. Pinned by `MCPColdStartTests` (real-binary harness with an in-process stub listener; RED against pre-fix). Trade-off: a genuinely-absent app now takes the full budget (15s) to synthesize `maugham_not_running` instead of ~1.5s — same as the already-shipped after-restart path.

3. **Orphan-annotation sweep is now edge-triggered via `Document._pendingSweep: SweepReason?`** carrying the observed removed-paragraph-id set; sweep archives only annotations on `reason.removed`. The earlier 1–2s auto-archive bug (sweep firing on any sequence mismatch from the live Document's view) is fixed via the SweepReason refactor (ADR 0010). `PresenterRoutingTests` covers the contract. If annotations vanish, suspect sweep-reason population at the call site (setFullText / deleteParagraph / handleExternalLogChange), not the sweep itself.

4. **Don't write to manuscripts from MCP, full stop.** Even if a future tool design "feels safe," the membrane principle is the hard rule, and *this* half of it never softens: manuscript text is the writer's, and Claude reaches it only through the parallel annotation layer. What a write tool may touch is the **planning plane** — the surfaces that are explicitly not manuscript and whose contents reach one only by a deliberate writer act. Today that is three destinations and no others: `research/` (`add_note`), the annotation/translation layers, and the planning canvas — `canvas.md` at the project root plus its `.maugham/canvas.json` sidecar (`add_canvas_scraps`), which reaches a manuscript only through promotion, a writer act (spec §8A.2 reasons this through against must-not #1; ADR 0026). A fourth destination needs the same ADR-level argument, not this list as precedent. Violating the manuscript rule loses the user's trust in the whole MCP integration.

5. **Don't return tool payloads >1MB.** Transport will choke. The byte budget is enforced (`MCPResponseBudget` for text, `ImageResponseBuilder` for images — see "Hard rules") so an overrun surfaces as a structured `payload_too_large` error rather than a silent truncation, but that error is a dead-end for the caller: for anything that scales with project size (listings, cross-doc search), still paginate, filter, or summarize so the response fits *before* it hits the guard.

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
4. If it could return >1MB: the `MCPResponseBudget` central backstop already fails such a response loudly, but a `payload_too_large` error is a poor experience — add pagination, filtering, or summarization so it fits. For a single unbounded file read, call `MCPResponseBudget.enforce` directly with a hint naming a section-scoped alternative (mirror `read_document`).
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

End-to-end-through-the-bridge coverage lives in `MaughamTests/MCP/MCPBinaryIntegrationTests.swift` (drives the real `maugham-mcp` binary against bogus/absent sockets) and `MaughamTests/MCP/MCPColdStartTests.swift` (drives the binary against an in-process stub Unix-socket listener to control cold-launch / restart timing — the regression pin for the first-call-after-restart flake, now fixed).

## What's intentionally NOT here

- Manuscript persistence — `Maugham/Stores/DocumentStore.swift`.
- The op log that MCP read tools read against — `Maugham/OpLog/`.
- Settings UI for the "Allow Claude to connect" toggle — `Maugham/Views/SettingsTabs/`.
- The "Set up Claude Desktop…" flow — `Maugham/Views/` (Help menu wiring; also hosts the Claude Code section, `HelpClaudeDesktopSheet.swift`).
- Skill content loading — `Maugham/Help/SkillIndex.swift` (mirrors `HelpTopicIndex`'s pattern but lives in `Help/`, not `MCP/`, since it's also consumed by `get_help`; this area only implements the SEP-2640 protocol surface and the Claude Code installer on top of it).
- The standalone `maugham-mcp` CLI source — `../maugham-mcp/` (separate Swift package, ships bundled inside `Maugham.app/Contents/MacOS/`).
