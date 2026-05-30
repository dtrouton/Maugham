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
- **`Bootstrap.run` must be called from any new manuscript load path.** It mints the inline `¶id` anchors the op log joins on. The contract surface is `Document.load` — it calls `Bootstrap.run` when the .md lacks anchors. Both production callers (`EditorHost.loadDocumentIfNeeded` and `AnnotationToolHelpers.withAnnotationDocument`) funnel through it. `BootstrapWiringTests` enforces this. If you add a new manuscript-load path, route it through `Document.load`; don't construct `Document` or read manuscript bytes for editing any other way.

## Build flow

```
./gen.sh                                                                       # xcodegen → Maugham.xcodeproj (run after every clone + after project.yml edits)
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
```

- **`Maugham.xcodeproj/` is generated, not tracked.** `project.yml` is the source of truth; `./gen.sh` produces the whole `.xcodeproj/` from it. If `xcodebuild` can't find a file you just added, run `./gen.sh`. Never hand-edit `project.pbxproj`, never commit anything under `Maugham.xcodeproj/` — it's all in `.gitignore` for a reason.
- **SourceKit live diagnostics in IDEs are noise.** They complain about XCTest imports and missing sibling types until Xcode re-opens the regenerated project. Trust `xcodebuild` exclusively — it is the ground truth.
- **Clean DerivedData after merging public-init / protocol-signature changes.** Xcode keys DerivedData by project path, not by git ref. So when a merge brings in a changed public `init`, protocol method, or anything else that affects the Swift name-mangling of an exported symbol, the first `xcodebuild test` on the merged result can fail with a phantom `Undefined symbol: ...` link error — the test target links against the new module while still referencing the old mangled symbol from stale `.o` files. Fix: `xcodebuild ... clean` before the test run. Test failure manifests at link time, not compile time, so the symbol name in the error message is the *old* signature even though the source is correct. Bit us on the dual-dialogue merge (`FountainLine.init` gained `isDualSecond`).
- **Smoke test format:** launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact. User runs smoke tests manually; don't claim a feature works until they confirm.
- **`Packages/MaughamCore` is a local SPM package** (Foundation-only shared substrate; declared under `project.yml` `packages:`, both app targets depend on it). After editing `Package.swift` or adding package sources, run `./gen.sh`. **WhisperKit** is a *remote* SPM dep on the **Maugham (Mac) target only** — its first resolve fetches from GitHub (needs network); if Xcode's GUI shows "missing package product", quit + reopen the regenerated project (CLI `xcodebuild` resolves fine). `.build/` is gitignored; the package source is **not** (the old blanket `Packages/` ignore was removed).

## Releases

Stable releases are tag-triggered via GitHub Actions. The recipe:

1. Write release notes: `docs/release-notes/v0.X.Y.md` (template at `docs/release-notes/_template.md`).
2. Commit them on `main`.
3. `./scripts/cut-release.sh 0.X.Y` — verifies notes exist, tree is clean, tests pass, then
   creates `v0.X.Y` tag and prints the push command. Pass `--skip-tests` only if you know why.
4. `git push --tags`. Workflow at `.github/workflows/release.yml` builds Release config,
   runs tests, packages the `.dmg`, and creates the GitHub Release with the notes file as body.
5. ~10 minutes later, the stable app's next check picks it up. Menu title goes to
   "Install Update…"; clicking reveals the `.dmg` in Finder.

**Version is tag-derived.** `project.yml`'s `CFBundleShortVersionString` stays at the placeholder
`"0.0.0-dev"` for local builds; CI rewrites it from the tag at build time. Don't bump it in
`project.yml` — bump it via the tag.

**Workflow fails before publish if `docs/release-notes/v0.X.Y.md` is missing.** Tag pattern
`v[0-9]+.[0-9]+.[0-9]+` triggers the release workflow; milestone tags (`milestone-*`) don't.

**Dev builds don't auto-update.** `BuildVariant.dev` (set by `-DMAUGHAM_DEV_BUILD` in Debug config)
disables the updater. Stable lives at bundle id `com.maugham.Maugham` in `/Applications`; dev at
`com.maugham.Maugham.dev` from Xcode. They have separate MCP socket paths and separate Claude
Desktop config entries (`maugham` vs `maugham-dev`) — see `Maugham/BuildVariant.swift`.

**Builds are currently unsigned** (ad-hoc, `CODE_SIGN_IDENTITY: "-"`). Each downloaded `.dmg`
requires a one-time right-click → Open on first launch — Gatekeeper's standard "unidentified
developer" treatment. Switching to Developer ID + notarization is a ~30-min CI change (add cert
+ notarize/staple steps to the release workflow, flip `CODE_SIGN_IDENTITY` and
`ENABLE_HARDENED_RUNTIME` in `project.yml`). The updater code doesn't change. See
`docs/superpowers/specs/2026-05-22-production-release-design.md` for the full sequence.

## Architectural tripwires

Each is a "do not do X — here's why it broke before." If your situation looks superficially different but rhymes with one of these, slow down.

1. **Don't subclass NSTextStorage to front multiple files.** AppKit's layout, undo, and selection caches downstream of NSTextStorage can't be steered cleanly from a subclass. This killed Phase 3d after 4 fix-rounds. See `memory/project_milestone_3d_abandoned.md`.
2. **Don't add SwiftUI ↔ AppKit bidirectional sync with flag-based loop guards.** `.onChange` fires *after* the synchronous flag-clear, so the guard leaks. This killed cursor↔binder sync in 3d.
3. **Don't put heavy work inside a synchronous SwiftUI binding setter.** This shape caused three separate cursor races in 24 hours (trailing-space autosave moved cursor; async restore raced key events; binding loop read stale `documentText`).
4. **Don't compute in SwiftUI list rows without caching.** Per-row Fountain re-parses became O(N²) on binder click in 3d, producing visible load pauses.
5. **Don't use NSPopover for editor autocomplete.** Abandoned in 3b — sizing was unreliable, it blocked input, character autocomplete was deferred. `CharacterAutocompleter` exists as dead code; don't wire it back without redesigning the UX.
6. **Don't reintroduce parallel observable state on `EditorHost`.** The earlier `$documentText` / `lastWrittenText` / `priorStoredMarkdown` triad drove three cursor races and is gone post-`milestone-document-first-class`. The current shape is a single `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })` where `setFullText` writes `displayText` exactly once at the end. Any new external-text path needs a regression test asserting `applyExternalText` doesn't fire during normal typing.
7. **Don't add a 4th caller to `EditorSurface.applyExternalText`.** It exists only for cloud-conflict resolution. Asserting this is what catches binding races.
8. **Use 4-char alphabet-restricted paragraph IDs in any test that crosses the .md ↔ op log boundary.** `ParagraphID.parseComment` is the gate (regex `[0123456789abcdefghjkmnpqrstvwxyz]{4}`); `recordChange(paragraphId:)` and other in-memory APIs are permissive by design, so OpLog unit tests legitimately use short IDs. If your test exercises Bootstrap, Reconciler ingest, or RenderFilter-against-parsed-anchors, use `ParagraphID.mint()` or a literal matching the alphabet.
9. **Don't use `.onTapGesture` for clickable rows inside `List(.sidebar)`.** Use `Button(.plain)`. Established SwiftUI workaround for sidebar hit-testing.
10. **Don't return >1MB from an MCP tool.** Transport cap. Image responses use crop-on-demand (`max_dimension` / `quality` / `region`, default 2048px JPEG q=85). See ADR 0004.
11. **Don't migrate test data when iterating on data shape.** The user explicitly prefers blowing away test projects: *"if I need to just delete all my test files and start again it's ok here. we don't need to migrate."* Propose deletion, not migration logic, unless asked.
12. **Don't reintroduce stringly-typed synthesisSource.** `Op.Provenance.synthesisSource` is `SynthesisSource?`. The raw values are the snake_case strings on disk (`paragraph_deleted`, `disk_at_ingest`, `use_cloud_resolution`, `rewind`). Adding a new cause means adding an enum case; emit-sites are exhaustively covered by the compiler.
13. **Don't hardcode "maugham", "Maugham", or socket paths.** Six values vary by `BuildVariant`: bundle id, display name, support folder name, MCP socket path, Claude Desktop config key, and MCP `serverInfo.name`. If you add a seventh, route it through `BuildVariant.current` instead. Compile-time check: `grep -n '"maugham"\|"Maugham"' Maugham/` should return zero matches outside `Maugham/BuildVariant.swift` and tests.
14. **Don't move/delete a file the user might be editing without closing the writing surface first.** The 750ms autosave on an open `Document` will recreate the file at its old path after `moveItem` / `moveToTrash`, leaving phantom files. For manuscript docs: `await openDoc.close(); ds.unregister(path: oldPath)` before the FS call. For research notes (which use `DocumentStore.scheduleFileSave`, not `Document`): `try? await documentStore?.flushPendingSave()` before the FS call. Pattern is documented at length in `Maugham/Views/AREA.md` → "Close-before-FS-surgery". Sites that already follow it: rename/delete in `ProjectStore+Structure`, `ProjectStore+CollectionPieces`, `ProjectStore+Research`, plus `DocumentStore.executeRenamePlan`. Adding a new FS-mutation entry point on user-edited files MUST add this guard.
15. **Don't show a `ContentUnavailableView` without `.frame(maxWidth: .infinity, maxHeight: .infinity)`.** SwiftUI sizes the empty-state to its intrinsic content and the enclosing `VStack` collapses to its content height; the parent then centers the whole pane vertically, floating the toolbar to the middle of the window. The pane's outer `VStack` ALSO needs `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`. Bug has recurred at least four times across new panes; the canonical examples are `HistoryPane`, `AnnotationsPane`, `OutlinePane`, `LinkedResearchPane`, `TasksPane`, `CollectionPiecesPane`. **Apply both frames whenever you add an empty-state.**
16. **Inline rename TextField focus claims need `Task.sleep(30ms)` deferral plus both `.onAppear` AND `.onChange(of: renamingItemId)` triggers.** A single `DispatchQueue.main.async` tick loses races with `List(selection:)`'s focus pass — the new row ends up selected-but-not-editing. The canonical shape lives in `BinderRow.claimFocus()`; `PieceRow` and `ResearchRow` mirror it. New rename-capable rows must copy the BinderRow shape verbatim.
17. **Don't share a single JSONL file across writers via iCloud Drive.** The op log (`.maugham/ops/d_<docId>.jsonl`) and inbox manifest (`.maugham/inbox/inbox.jsonl`) are **per-device-partitioned**: each device writes only its own `*.<deviceSlug>.jsonl`; readers glob siblings and merge (op log by opId; inbox last-wins). `NSFileCoordinator` serializes only within one device — iCloud's reconciler can't line-merge concurrent appends to one path and drops the loser as a silent conflict-twin (`d_x 2.jsonl`) the loader never opens. Helpers: `OpLogStore.opLogFileURLs`/`loadSyncMerged`, `DeviceSlug.make`. Inbox `writtenAt` must be **monotonic per id** (`InboxStore.append` stamps `max(now, priorWrittenAt+1ms)`) — wall-clock alone re-runs the transcription worker forever under phone/Mac clock skew. See ADR 0012 + `memory/feedback_smoke_finds_seam_bugs.md`.

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

### `Packages/MaughamCore/` — the shared Foundation-only package
- Holds the cross-target substrate: Op/OpKind/Annotation(Deriver)/Materializer/Bootstrap/Reconciler/ParagraphID/ULID/SweepReason/SynthesisSource/Checkpoint(Store), `JSONLAppendStore`, `OpLogStore`, the Fountain parser, `BuildVariant`, the Models (incl. `TypographySettings`/`ProjectTargets`), `Transcriber`, `Inbox/` (`InboxEntry`, `InboxFileKind`), and `MarkdownDisplayFilter` (the shared anchor-strip). AppKit/SwiftUI-bound code stays in `Maugham/`. Shared with the `MaughamPhone` iOS target.
- **`MarkdownDisplayFilter` is the single source of truth for hiding manuscript anchors** (`<!-- ¶id -->` paragraph + `<!--t-XXXXXX-->` task anchors) in the *display* form. The Mac editor's `RenderFilter.stripComments`/`stripTaskAnchorsInline` forward to it; the iOS reader (`DocumentReaderView`) calls it directly. Don't reintroduce a target-local stripper — that's how the phone first shipped a copy that missed task anchors. The editor-only *restore* round-trip (id reattach by shingle/LCS) stays in `Maugham/Editor/RenderFilter.swift`.
- **Cross-module = `public`.** Anything `Maugham/` (or MaughamPhone) calls must be `public`; the build tells you. `BuildVariant.current`'s `-DMAUGHAM_DEV_BUILD` is mirrored as a Debug `swiftSetting` in `Package.swift` (don't drop it — `BuildVariantTests` guards it).
- Extracted in milestone-2 (`memory/project_milestone_iphone_companion_mac.md`).

### `Maugham/Stores/` inbox + transcription (iPhone-companion Mac side)
- `InboxStore` owns `.maugham/inbox/` (per-device `inbox.<slug>.jsonl`, last-wins by monotonic `writtenAt` — tripwire 17). `InboxPane` is the ⌘⌥6 right-pane (badge/promote/audio/edit/trash-view). `InboxTranscriptionWorker` (serial, eligibility `.none`/`.onDeviceDraft`, draft-preserving) runs an injected `Transcriber`; production is `WhisperKitTranscriber` (Apple-Silicon, via `DocumentStore.makeTranscriber()` → nil on Intel). MCP: `list_inbox`/`read_inbox_entry`/`promote_inbox_entry` (read+promote). Inbox MCP scope decision + the InboxPane shortcut map live in `Maugham/MCP/AREA.md`-adjacent notes and the spec §3.x.

### `Maugham/Editor/` — see [`Maugham/Editor/AREA.md`](Maugham/Editor/AREA.md)
- `EditorCoordinator.swift` is the central nervous system and by far the largest file in this area. NSTextViewDelegate doing tokenization, cursor management, Tab-cycle, smart typography, find navigation, focus-dim, image-paste routing, wiki-link hit-testing. `applyFocusDim` is intentionally called from three paths — don't dedupe blindly.
- `EditorHost.swift` (at `Maugham/Views/EditorHost.swift`, historical placement) shape is fragile — see tripwires 2, 3, 6, 7. The binding contract is covered by `EditorIntegrationHarnessTests`.
- `ScreenplayMode.applyTypography` does full-storage `setAttributes` (not incremental). Known race-window contributor; don't add work inside it.
- `ScreenplayLayoutManager` exists but display-uppercase is the **option-A fallback** intentionally — don't try to "fix" it without rethinking the approach.
- `CharacterAutocompleter` is **dead code** (NSPopover abandoned). Don't wire `updateAutocomplete` back; redesign the UX first.

### `Maugham/OpLog/` — see [`Maugham/OpLog/AREA.md`](Maugham/OpLog/AREA.md)
- Cleanest part of the codebase per the audit. Don't refactor structurally.
- `OpLogStore` and `CheckpointStore` are thin wrappers over `JSONLAppendStore<T>` (~30 lines each). The generic is the right place to extend if you need new shared persistence semantics; the wrappers exist to keep hot-path (op log, every keystroke burst) and cold-path (checkpoints, ⌘S) concurrency profiles explicit.
- `RenderFilter` has a third matching tier (char-bigrams ≥0.6) not present in `ShingleMatcher` — late T16 fix, cleanup planned.
- `Reconciler` external-edit ingestion has integration coverage now via `PresenterRoutingTests` (echo guards) + `EditorIntegrationHarnessTests` (silent-ingest + conflict-surfaces). The Reconciler classifier itself is still unit-only.
- Echo guard for `.md` writes is `Document.lastDiskEcho: EchoState` — assignable only through the three factories in `EchoState.swift`. Don't introduce a parallel "last text" string. See [ADR 0010](docs/adr/0010-typed-cross-area-seams.md).
- Orphan-annotation sweep is gated on `Document._pendingSweep: SweepReason?` carrying the *observed* removed paragraph ids. Sweep archives only annotations on those ids — never "anything missing from sequence." Don't reintroduce a bool flag.
- `RewindCursor.swift` + `RewindRestoreResult.swift` + `SynthesisSource.swift` are the typed contracts for time travel (ADR 0010). `Document.restoreToOp(opId:)` appends a `.checkpointRestore` op with `provenance.synthesisSource = .rewind` and triggers the sweep via `SweepReason.rewind(removed:)`.

### `Maugham/MCP/` — see [`Maugham/MCP/AREA.md`](Maugham/MCP/AREA.md)
- Tool registration has a single source of truth: `MCPToolCatalog.all` in `Maugham/MCP/MCPTool.swift`. Implement `MCPTool` on the tool enum (declare `method`/`description`/`inputSchemaJSON`/`handle`) and add the type to `MCPToolCatalog.all`. `MCPToolsListHandler` and `MaughamApp.registerTools` both derive from it; `MCPCatalogConsistencyTests` enforces the contract.
- Transport is **live-only Unix socket** via the CLI bridge in `maugham-mcp/JSONRPCBridge.swift`. Don't reach for stdio (ADR 0003).
- Foundation scope: read tools + `add_note` that *only writes under `research/`*. Manuscript edits are annotation-layer (ADR 0004).
- Publishing added a large tool family; the iPhone-companion inbox added three more — the catalog is now **43 tools**: `compile`/`preview_compile`/`compile_status`/`compile_cancel`, `get`/`set_publish_config`, `list`/`read`/`read_image`/`write`/`delete_publish_file`, `list_publications`/`read_publication_page`/`republish`, `set_piece_style`/`clear_piece_style`, `list_inbox`/`read_inbox_entry`/`promote_inbox_entry`, `list_maugham_tools`. They read/write only under `.maugham/publish/` + `Exports/` + (inbox) `.maugham/inbox/` and `research/` — still never the manuscript. **Inbox MCP scope is read + promote only** (decided 2026-05-29): Claude can list/read captures and promote them into `research/` (non-destructive), but cannot `add` or `trash` — those stay writer-only, to avoid muddying the inbox's "off-desk capture" identity and to keep destructive triage out of MCP. `list_maugham_tools` returns a flat catalog + build identity (`server.{build_variant,version,built_at}`) — the authoritative way for a client to verify which build/variant it's on. Tools taking a `piece_id` validate it against `ProjectStore.collectDocuments` and **fail loudly** on unknown ids (a silent no-op here cost a multi-round debug chase — see `memory/project_publishing_namespace_footgun.md`); the inbox tools fail loudly the same way on unknown/already-resolved `entry_id`.
- "First MCP call after restart" is a known deferred flake — don't try to fix without first adding stderr logging in the bridge (see `memory/project_deferred_mcp_first_call.md`).
- SIGPIPE handling in `MCPServer.swift` is idempotent and required.
- Orphan-annotation sweep is now driven by `Document._pendingSweep: SweepReason?` carrying the observed removed-paragraph-id set; sweep archives only annotations on `reason.removed`. The earlier 1–2s auto-archive bug (sweep firing on any sequence mismatch) is fixed — `PresenterRoutingTests` is the regression net. If annotations vanish, suspect sweep-reason population, not the sweep itself.

### `Maugham/Publish/`
- The publishing pipeline (shipped & merged 2026-05-29; see `memory/project_milestone_publishing.md`). Flow: project → `ProjectStoreASTSource` (pieceID = `StructureItem.id`) → `ProjectASTBuilder` → `LaTeXBodyEmitter`/`XHTMLBodyEmitter` (`emit(_:config:)`) → tectonic (PDF) / zip (EPUB). Output to `Exports/`; template + `config.json` under `.maugham/publish/`.
- **`EMISSION.md` is generated, not hand-written.** Rendered from `EmissionContract.swift`; `EmissionContractTests` fails if the committed `Maugham/Resources/PublishStarter/EMISSION.md` drifts. To change the contract, edit the Swift source and regenerate — never hand-edit the `.md`.
- **Locality criterion** decides config-vs-template: does honoring an override need *global* knowledge the piece can't have? Global → config; piece-local → per-piece `.tex` (`style_file`). No aesthetic config flags. Documented in EMISSION.md.
- Emitter override lookup is keyed by `section.pieceID` (= `StructureItem.id`). The config `sections` key MUST be that same id — a mismatch silently no-ops (the namespace footgun). Tools validate ids; `LaTeXBodyEmitter`'s override + scoped-group logic has unit coverage but the production id round-trip is in `StyleFileProductionPathTests`.
- Per-piece `style_file` emits a scoped group (`\begingroup \input{pieces/x} … \endgroup`) so overrides revert per piece — there's a named scope-reversion regression test; **don't hoist the `\input` out of the group.**
- `PublishStarter` resources ship as a **`type: folder`** reference in `project.yml` (live at build time — new files need no `./gen.sh`). The bundled `tectonic` binary is **git-tracked** at `Maugham/Resources/bin/tectonic` (~49MB), so CI gets it via checkout (no fetch step). Compile tests do real tectonic compiles (cold CDN fetch on a fresh runner → slower first release).
- Specs: `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md`, `…/2026-05-29-publishing-feedback-design.md`. ADR [0013](docs/adr/0013-publishing-pipeline.md).

### `Maugham/Stores/` — see [`Maugham/Stores/AREA.md`](Maugham/Stores/AREA.md)
- `ProjectStore.swift` itself is a small façade; the seams live in peer files (`ProjectStore+Structure.swift`, `+Trash.swift`, `+Research.swift`, `+Metadata.swift`, `+Search.swift`, `+WikiLink.swift`, `+CollectionPieces.swift`, `+References.swift`). When you add a new seam, create a new `ProjectStore+NewSeam.swift` peer file — don't grow the main file.
- `DocumentStore.swift` is the project-folder coordinator + Document registry; per-doc state (op log, autosave, conflict detection, echo guard) lives on `Document` (post-`milestone-document-first-class`).
- Presenter routing goes through the typed `MaughamSidecarPath` enum — adding a new `.maugham/` subdir owner becomes a `switch must be exhaustive` compile error rather than a string-prefix cascade edit. See [ADR 0010](docs/adr/0010-typed-cross-area-seams.md).
- `.maugham/` subdirectory layout (`ops/`, `conflicts/`, `sessions/`, `checkpoints/`, `ui-state/`, `scratch/`, `trash/`, `publish/`) is canonical — each has one owner. Don't invent new top-level subdirs without a reason.
- ID prefixes are canonical after ADR 0008; don't double-prefix (no `scene-scene-…`).

### `Maugham/Views/`
- `ProjectWindow.swift` uses extracted `ViewModifier`s (`SessionAndNavigationModifier`, `CollectionPieceModifier`, `CheckpointModifier`) to dodge SwiftUI's body type-checker complexity ceiling. **When you hit "the compiler is unable to type-check this expression in reasonable time," extract a ViewModifier** — this is the established pattern.
- BinderSegment conditional cases (`.trash`, `.find`) auto-coerce back to `.manuscript` when their condition disappears. New conditional segments must do the same.
- Right-pane mode-swap (Inspector/Research/Outline, ⌘⌥1/2/3) is the established pattern (ADR 0005); mirror it for new right-pane content.
- `RewindWindow.swift` is the time-travel modal (opened via HistoryPane header "Rewind…" or per-row "↺"). Snapshots the op log at open-time — no live updates during the modal session. Scrubber density via the pure helper `RewindTickLayout.decimate`.
- Dark-mode propagation to side panes is a known carry-forward (lost twice). Re-check after touching theme code.

### `Maugham/Models/`
- `ProjectType` is polymorphic (shortStory/novel/screenplay/collection). Collection holds loose pieces + references to standalone projects (ADR 0009). **Collection references are Mac-local; cross-Mac via iCloud is best-effort.**
- Manifest changes need to round-trip through ISO8601 with whole-second rounding for `manifest.modified` (deliberate; remembered from milestone 1a).

## Outstanding correctness concerns (read before touching adjacent code)

- **Watch for stray `project.pbxproj` edits in diffs.** `Maugham.xcodeproj/` is generated and in `.gitignore`; past subagent commits accidentally included pbxproj changes. If you see one in a review, that's a red flag, not a real change.
- Onboarding affordance for Annotations pane vs History pane is missing — they're sibling right-pane segments with opposite affordances (Annotations = action surface with Accept/Reject/Archive buttons; History = read-only forensic log). A tooltip on the segment picker or an empty-state hint pointing across would reduce the confusion.

## Questions you do not need to ask

- "Should we use subagents?" → Yes.
- "Which model?" → Haiku mechanical, sonnet-or-opus substantive (opus preferred when in doubt).
- "Should we migrate test data?" → No. Delete and recreate.
- "Should this annotation be paragraph- or doc-scoped?" → Both should work and both need a UI surface.
- "Should I write a migration for this schema change?" → No, unless the user explicitly asks.
- "Should we ship one feature first or bundle?" → Bundle, default to ambitious.
- "How do I cut a release?" → see the Releases section above.
- "Should I bump version in `project.yml`?" → No. The git tag is the source of truth; CI writes the version into the bundle at build time.
- "Should dev or stable do X?" → see `Maugham/BuildVariant.swift` — one enum, all the seams hang off it.
