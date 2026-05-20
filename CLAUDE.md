# Maugham — Guidance for Claude

Maugham is a Mac-native focus text editor for serious creative writing (prose, novels, screenplays, mixed collections). Native Swift + SwiftUI + AppKit, designed to live alongside Claude Desktop via a local MCP server. **The user does not write code** — Claude writes all of it. This file is the load-bearing context for that arrangement.

## First five minutes of any session

Read in this order, then start work:

1. `MEMORY.md` at `~/.claude/projects/-Users-denver-src-Maugham/memory/MEMORY.md` — the milestone index. Don't re-derive what's shipped; it's all there.
2. `README.md` and `docs/roadmap.md` — current shipped scope and open work.
3. `docs/adr/` — every architectural decision made since the master spec. **ADRs supersede the master spec.** Don't re-read `docs/superpowers/specs/2026-05-07-maugham-master-design.md` except for original-intent questions.
4. This file's "Hard invariants" and "Tripwires" sections.

The most recent codebase audits live at `docs/superpowers/notes/2026-05-19-state-of-the-code.md` and `docs/superpowers/notes/2026-05-19-step-back-audit.md` — load them if you're touching anything they cover.

## Hard invariants

These are non-negotiable. Violating one is a regression even if tests pass.

- **Op log is the source of truth for manuscripts.** `.md` files on disk are derived. Editing means appending to the per-doc JSONL op log under `.maugham/ops/` and re-rendering. Inline `<!-- ¶id -->` HTML-comment anchors are the join key. See `Maugham/OpLog/` and ADRs 6–8.
- **Plain text on disk, full stop.** Manuscripts live as human-readable `.md` / `.fountain` at the writer's chosen paths inside the project folder. Anything derived (op log, checkpoints, sessions, conflict backups, UI state, trash) goes under `.maugham/`. This is what makes iCloud sync, Claude Desktop reading, and tool portability all work. Don't propose sidecar formats for manuscript content.
- **MCP never mutates manuscript text directly.** The manuscript belongs to the writer. Claude operates in a parallel **annotation layer** (`add_note`, annotations against paragraph IDs), or writes into `research/` — never into the manuscript file itself. The user's framing: *"the manuscript is yours, full stop."*
- **Single-file screenplays.** One `.fountain` per screenplay project. Multi-file compound screenplay is **dead** (see Phase 3d abandonment). The Scenes segment in the binder is a slugline navigator within that one file.
- **⌘S is a labeled checkpoint, not a save.** Saving is autosave (750ms debounce via `DocumentStore`). ⌘S writes a project-scope checkpoint. Keep the muscle-memory flash even though "save" is redundant.
- **`Bootstrap.run` must be called from any new manuscript load path.** It mints the inline `¶id` anchors the op log joins on. **As of 2026-05-19 it is not wired into production load paths** — fixing this is open work, and any new load path you add must call it.

## Build flow

```
./gen.sh                                                                       # xcodegen → Maugham.xcodeproj
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
```

- **Never hand-edit or commit `Maugham.xcodeproj/project.pbxproj`.** It's regenerated from `project.yml`. New `.swift` files under `Maugham/` are auto-picked-up — just add the file. A subagent broke `main` by committing pbxproj edits for files that had been deleted; don't repeat.
- **SourceKit live diagnostics in IDEs are noise.** They complain about XCTest imports and missing sibling types until Xcode re-opens the regenerated project. Trust `xcodebuild` exclusively — it is the ground truth.
- **Smoke test format:** launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact. User runs smoke tests manually; don't claim a feature works until they confirm.

## Architectural tripwires

Each is a "do not do X — here's why it broke before." If your situation looks superficially different but rhymes with one of these, slow down.

1. **Don't subclass NSTextStorage to front multiple files.** AppKit's layout, undo, and selection caches downstream of NSTextStorage can't be steered cleanly from a subclass. This killed Phase 3d after 4 fix-rounds. See `memory/project_milestone_3d_abandoned.md`.
2. **Don't add SwiftUI ↔ AppKit bidirectional sync with flag-based loop guards.** `.onChange` fires *after* the synchronous flag-clear, so the guard leaks. This killed cursor↔binder sync in 3d.
3. **Don't put heavy work inside a synchronous SwiftUI binding setter.** This shape caused three separate cursor races in 24 hours (trailing-space autosave moved cursor; async restore raced key events; binding loop read stale `documentText`).
4. **Don't compute in SwiftUI list rows without caching.** Per-row Fountain re-parses became O(N²) on binder click in 3d, producing visible load pauses.
5. **Don't use NSPopover for editor autocomplete.** Abandoned in 3b — sizing was unreliable, it blocked input, character autocomplete was deferred. `CharacterAutocompleter` exists as dead code; don't wire it back without redesigning the UX.
6. **Don't add a 4th `.onChange` to `EditorHost`.** The existing `$documentText` / `lastWrittenText` / `priorStoredMarkdown` triad is load-bearing and brittle. Any new external-text path needs a regression test asserting it doesn't fire during normal typing.
7. **Don't add a 4th caller to `EditorSurface.applyExternalText`.** It exists only for cloud-conflict resolution. Asserting this is what catches binding races.
8. **Don't use 1-char paragraph IDs in tests.** `ParagraphID` requires exactly 4 chars. Tests using "a"/"b" silently bypass validation (currently violated in `PendingBufferTests` — known carry-forward, don't propagate).
9. **Don't use `.onTapGesture` for clickable rows inside `List(.sidebar)`.** Use `Button(.plain)`. Established SwiftUI workaround for sidebar hit-testing.
10. **Don't return >1MB from an MCP tool.** Transport cap. Image responses use crop-on-demand (`max_dimension` / `quality` / `region`, default 2048px JPEG q=85). See ADR 0004.
11. **Don't migrate test data when iterating on data shape.** The user explicitly prefers blowing away test projects: *"if I need to just delete all my test files and start again it's ok here. we don't need to migrate."* Propose deletion, not migration logic, unless asked.

## Default workflow

Follow this without asking — the user has answered these questions enough times that re-asking is friction.

1. **Brainstorm → spec → plan → subagent-driven implementation → manual smoke → tag.** The cadence works; don't redesign it. Specs live in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.
2. **Use subagent-driven dispatch by default.** Do not ask which execution mode.
3. **Model selection:**
   - `haiku` for mechanical tasks — Codable types, small structs, thin SwiftUI views, smoke-build-only files.
   - `sonnet` *or* `opus` for substantive tasks — async + file I/O with error handling, AppKit/SwiftUI architectural composition, anything touching the Editor/OpLog seam. **The user explicitly prefers paying for `opus` on substantive work over risking rework**, so default to opus when in doubt; sonnet is fine for the merely-non-mechanical.
   - Reviewer subagents: `haiku` is sufficient for spec-compliance and code-quality review.
4. **Skip the formal two-stage review for trivial tasks.** A single small Swift file from a complete spec block doesn't need fresh-implementer + spec-reviewer + code-quality-reviewer. Verify yourself with `git show <commit>`. Reserve dual-reviewer for tasks with real design judgment (file I/O design, error-handling completeness, architectural composition).
5. **Bundle related features into one milestone.** The user prefers ambitious scope; don't pre-trim on their behalf. See `memory/feedback_scope_ambition.md`.
6. **Read every bug the user lists in one message — not just the first.** Users batch regressions; "also the gutters are missing" at the end of a paragraph about something else is a separate ticket, not an aside.
7. **Help/docs surfaces describe what *ships*, not what's planned.** ⌘/ help sheets, syntax pages, etc. only document shipped behavior in the milestone they go out in.
8. **Every new data type needs a UI surface for inspection/action.** MCP access alone is not enough — annotations without an in-app view to resolve them surfaced as a real complaint.

## Per-area pointers

Brief, high-signal callouts. Treat as "things to read or grep before editing in this area." **When an area has an `AREA.md` file (e.g., `Maugham/Editor/AREA.md`), read it before editing anything in that directory.** AREA.md files exist for the areas with rich enough per-area context that one-line callouts here are insufficient.

### `Maugham/Editor/` — see [`Maugham/Editor/AREA.md`](Maugham/Editor/AREA.md)
- `EditorCoordinator.swift` is the central nervous system (~770 lines). NSTextViewDelegate doing tokenization, cursor management, Tab-cycle, smart typography, find navigation, focus-dim, image-paste routing, wiki-link hit-testing. `applyFocusDim` is intentionally called from three paths — don't dedupe blindly.
- `EditorHost.swift` shape is fragile — see tripwires 2, 3, 6, 7.
- `ScreenplayMode.applyTypography` does full-storage `setAttributes` (not incremental). Known race-window contributor; don't add work inside it.
- `ScreenplayLayoutManager` exists but display-uppercase is the **option-A fallback** intentionally — don't try to "fix" it without rethinking the approach.
- `CharacterAutocompleter` is **dead code** (NSPopover abandoned). Don't wire `updateAutocomplete` back; redesign the UX first.

### `Maugham/OpLog/` — see [`Maugham/OpLog/AREA.md`](Maugham/OpLog/AREA.md)
- Cleanest part of the codebase per the audit. Don't refactor structurally.
- `OpLogStore` and `CheckpointStore` are intentional siblings with ~95% duplicated structure. Don't dedupe without a deliberate `JSONLAppendStore<T>` design.
- `RenderFilter` has a third matching tier (char-bigrams ≥0.6) not present in `ShingleMatcher` — late T16 fix, cleanup planned.
- `Reconciler` (external-edit ingestion) has no end-to-end integration test — high-leverage place to add one.

### `Maugham/MCP/` — see [`Maugham/MCP/AREA.md`](Maugham/MCP/AREA.md)
- Tool registration has a single source of truth: `MCPToolCatalog.all` in `Maugham/MCP/MCPTool.swift`. Implement `MCPTool` on the tool enum (declare `method`/`description`/`inputSchemaJSON`/`handle`) and add the type to `MCPToolCatalog.all`. `MCPToolsListHandler` and `MaughamApp.registerTools` both derive from it; `MCPCatalogConsistencyTests` enforces the contract.
- Transport is **live-only Unix socket** via the CLI bridge in `maugham-mcp/JSONRPCBridge.swift`. Don't reach for stdio (ADR 0003).
- Foundation scope: read tools + `add_note` that *only writes under `research/`*. Manuscript edits are annotation-layer (ADR 0004).
- "First MCP call after restart" is a known deferred flake — don't try to fix without first adding stderr logging in the bridge (see `memory/project_deferred_mcp_first_call.md`).
- SIGPIPE handling in `MCPServer.swift` is idempotent and required.
- Paragraph-anchored annotations may auto-archive within 1–2s due to a post-commit handler keyed on `paragraph_id`. Suspect this path first when annotations vanish.

### `Maugham/Stores/` — see [`Maugham/Stores/AREA.md`](Maugham/Stores/AREA.md)
- `ProjectStore.swift` is 2760 lines with natural seams (Structure CRUD, Trash, Inspector, Research, Collection-Pieces, WikiLink). Already uses `extension` for Collection-Pieces — emulate that pattern for new seams.
- `DocumentStore.swift` has bolted-on op-log integration; `currentDocumentText` is overloaded between conflict detection (stored-form) and op-log context (display-form). Bug-bearing seam — be deliberate.
- `wait*` helpers in DocumentStore are test-only living in production.
- `.maugham/` subdirectory layout (`ops/`, `conflicts/`, `sessions/`, `checkpoints/`, `ui-state/`, `scratch/`, `trash/`) is canonical — each has one owner. Don't invent new top-level subdirs without a reason.
- ID prefixes are canonical after ADR 0008; don't double-prefix (no `scene-scene-…`).

### `Maugham/Views/`
- `ProjectWindow.swift` uses extracted `ViewModifier`s (`SessionAndNavigationModifier`, `CollectionPieceModifier`, `CheckpointModifier`) to dodge SwiftUI's body type-checker complexity ceiling. **When you hit "the compiler is unable to type-check this expression in reasonable time," extract a ViewModifier** — this is the established pattern.
- BinderSegment conditional cases (`.trash`, `.find`) auto-coerce back to `.manuscript` when their condition disappears. New conditional segments must do the same.
- Right-pane mode-swap (Inspector/Research/Outline, ⌘⌥1/2/3) is the established pattern (ADR 0005); mirror it for new right-pane content.
- Dark-mode propagation to side panes is a known carry-forward (lost twice). Re-check after touching theme code.

### `Maugham/Models/`
- `ProjectType` is polymorphic (shortStory/novel/screenplay/collection). Collection holds loose pieces + references to standalone projects (ADR 0009). **Collection references are Mac-local; cross-Mac via iCloud is best-effort.**
- Manifest changes need to round-trip through ISO8601 with whole-second rounding for `manifest.modified` (deliberate; remembered from milestone 1a).

## Outstanding correctness concerns (read before touching adjacent code)

These came out of the 2026-05-19 audits and are not yet fixed:

- **`Bootstrap.run` is not called from production load paths.** The stable-paragraph-ID infrastructure is dark in shipping builds. Any new manuscript load path *must* call it; the existing ones need to be retrofitted.
- **Several subagent commits over the past week included `project.pbxproj` edits** that shouldn't have been there. If you see pbxproj in a diff you're reviewing, that's a red flag.
- **`PendingBufferTests` (and old `RenderFilterTests`) use 1-char paragraph IDs** that silently bypass validation. New tests must use 4-char IDs.
- **Annotations pane shows "no history" message** that's confusing, and there's no UI affordance to resolve annotations. Mentioned by the user; not yet addressed.

## Questions you do not need to ask

- "Should we use subagents?" → Yes.
- "Which model?" → Haiku mechanical, sonnet-or-opus substantive (opus preferred when in doubt).
- "Should we migrate test data?" → No. Delete and recreate.
- "Should this annotation be paragraph- or doc-scoped?" → Both should work and both need a UI surface.
- "Should I write a migration for this schema change?" → No, unless the user explicitly asks.
- "Should we ship one feature first or bundle?" → Bundle, default to ambitious.
