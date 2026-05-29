# Publishing Pipeline — second handoff (mid-Phase 7)

**Date:** 2026-05-27 (session 2)
**Branch:** `worktree-publishing-pipeline-design` (in `.claude/worktrees/publishing-pipeline-design/`)
**Progress:** 25 of 49 tasks complete (Phases 1–6 + Tasks 37, 39, 42 of Phase 7).

Pick up here for Phase 7 cleanup (Tasks 38, 40, 41) and Phases 8–9 (Tasks 43–49).

Read these in order, then start:

1. **This file** — what's done since handoff #1, what's left, and the cross-cutting API drift the plan needs translated.
2. **First handoff:** `docs/superpowers/notes/2026-05-27-publishing-pipeline-handoff.md` — load-bearing context that's still all valid (CWD guard, xcodegen folder syntax, SourceKit noise rules, etc.).
3. **Plan:** `docs/superpowers/plans/2026-05-26-publishing-pipeline.md` — Tasks 38, 40, 41, 43–49.
4. **Spec:** `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md`.

Everything in the *original* handoff (gotchas 1–10) still applies. The 11+ items below extend it.

---

## What shipped this session (Tasks 15–37, 39, 42 + hardening)

All commits on `worktree-publishing-pipeline-design`. Full test suite: green except the three pre-bumped tools-list-count tests (now fixed at `659a256`).

### Phase 3 — Tectonic engine (5 tasks)

| Commit | What |
|---|---|
| `0274d36` | Task 15 — `tectonic 0.15.0` binary bundled at `Maugham/Resources/bin/tectonic` (49 MB), `scripts/fetch-tectonic.sh` with pinned SHA `7b8efd25…`. project.yml `sources: type: folder` pattern (NOT `resources:`) — see handoff #1 gotcha 4. |
| `2cfa735` | Task 16 — `TectonicLocator` (locate / locateInBundle for XCTest) |
| `7ae7873` | Task 17 — `TectonicCache` (~/Library/Caches/Maugham/tectonic) |
| `645ef39` | Task 18 — `TectonicLogParser` (error/warning extraction) |
| `096fa09` | Task 19 — `TectonicInvoker` (Process wrapper, async continuation) |

### Phase 4 — EPUB packager (4 tasks)

| Commit | What |
|---|---|
| `bc6cc53` | Task 20 — `EPUBPackage` model |
| `ef64ff5` | Task 21 — `EPUBContainerWriter` |
| `0261d56` | Task 22 — `EPUBOPFWriter` (opf, nav, sectionXHTML) |
| `30a5eb8` | Task 23 — `EPUBZipPackager` (`/usr/bin/zip` with mimetype-first `-X0`) |

### Phase 5 — Publications (5 tasks + security)

| Commit | What |
|---|---|
| `cfa79d4` | Task 24 — `Publication` Codable |
| `3dd02ae` | Task 25 — `PublicationSnapshot` Codable |
| `b7dcdd2` | Task 26 — `PublicationStore` JSONL log |
| `3728c4b` | Task 27 — `PublicationSnapshotStore` (capture/save/load/extract) |
| `1d35ef1` | Task 28 — sidecar classification tests |
| `10cdcea` | **Security fix** — path-traversal validation in `extract()` + `load(id:)` + `save(_:)`. Snapshots are JSON-on-disk and arrive via iCloud + (Phase 7) MCP republish; we treat their fields as untrusted. Threw `Error.pathTraversal(_)` / `.invalidSnapshotID(_)`. **Don't roll this back** — Task 41's RepublishTool consumes the hardened API. |

### Phase 6 — Job manager + orchestrator (8 tasks)

| Commit | What |
|---|---|
| `5b225d7` | Task 29 — `CompileJob` state types |
| `a423fb4` | Task 30 — `CompileJobManager` actor |
| `0044ed7` | Task 31 — `ProjectStoreASTSource` adapter |
| `51e98b0` | Starter fix — added `\InputIfFileExists{build/metadata}{}{}` to `template.tex`. The plan's PDFCompiler writes `build/metadata.tex` but the template didn't `\input` it. |
| `2cfbefa` | Task 32 — `PDFCompiler` + a `preamble.tex` ordering fix (`\providecommand` now precedes `\hypersetup`). Without that fix `\Title` etc. resolved late and crashed in PDF metadata generation. |
| `e0e3137` | Task 33 — `EPUBCompiler` |
| `e293d16` | Task 34 — `CompileOrchestrator` (PDF/EPUB dispatch + Publication writing + version bump) |
| `9ddb67c` | Task 35 — `PreviewCompiler` (subset, no publish, no version bump) |
| `3e298ef` | Task 36 — `Republisher` (extract snapshot → stage → compile → move output to real Exports/) |

### Phase 7 — MCP tools (3 of 6 task groups done)

| Commit | What |
|---|---|
| `6de105a` | Task 37 — `initialize_publish_template` |
| `cf177e9` | Task 39 — `get_publish_config` + `set_publish_config` (RFC 7396 patch) |
| Task 42 — `MCPCatalogConsistencyTests` passes cleanly with the 3 new tools; no commit needed |
| `659a256` | Hard-coded tool-count assertions bumped 22 → 25 (`MCPProtocolHandlersTests`, `MCPToolsListSmokeTest`) |

---

## What's left

| Task | Phase | Notes |
|---|---|---|
| 38 | 7 | `PublishFileTools` — 5 tools (list/read/read_image/write/delete) under `.maugham/publish/`. **Requires extracting `ImageResponseBuilder`** from `Maugham/MCP/Tools/DocumentTools.swift` (image handling is currently inlined). |
| 40 | 7 | `CompileTools` — 4 tools (compile/preview/status/cancel). Needs new `PublishingStores` singleton-per-project (plan Step 1). Also adds `CompileJobManager.allInProgress()`. |
| 41 | 7 | `PublicationTools` — 3 tools (list/read_page/republish). `read_publication_page` rasterizes PDF via `PDFKit` — see plan. |
| 43–46 | 8 | UI: `ExportsListView`, `PublishStatusPill`, `InspectorPublishSection`, completion notification. |
| 47–49 | 9 | E2E smoke, reproducibility, final sweep. |

---

## Cross-cutting plan-vs-codebase API drift (the part the plan got wrong)

Every Phase 7 MCP task in the plan uses **stub API names that don't exist** in the codebase. You MUST translate as you implement. The patterns I've already corrected in Tasks 37/39 are the same ones Tasks 38/40/41 need:

| Plan says | Codebase has | Where verified |
|---|---|---|
| `MCPError.invalidParams("...")` | `MCPError.invalidArgument("...")` | `Maugham/MCP/MCPError.swift` (cases: maughamNotRunning, projectNotOpen, mcpDisabled, invalidArgument, internalError, toolError) |
| `registry.store(forID:)` | `registry.lookup(id:)?.store` and `.url` | `Maugham/MCP/ProjectRegistry.swift` (`lookup(id:) -> Entry?`, `Entry.{id,url,store}`) |
| `store.projectURL` | `store.url` | `Maugham/Stores/ProjectStore.swift` line 27 |
| `ProjectStore.bootstrap(emptyAt:title:type:)` | Use real factories: `ProjectFactory.createNovelProject(named:in:)`, then `try await ProjectStore.load(from: url)` | `Maugham/Stores/ProjectFactory.swift` |
| `registry.register(store: ...)` returning ID | `registry.register(url:store:)` — no return; derive ID via `ProjectIdentifier.id(for: url)` |  |
| `ImageResponseBuilder.encode(imageAt:...)` / `(nsImage:...)` with absolute pixel `Region` | **Does not exist.** ReadDocumentTool inlines image handling at `Maugham/MCP/Tools/DocumentTools.swift:163-300ish`. Extract it as a real shared helper **before** Task 38 and Task 41. Also note: existing region coords are **normalized 0–1**, not absolute pixels — the plan's "x:Int, y:Int, w:Int, h:Int" is inconsistent with the established convention. |
| `PublishConfigStore.applyPatch(_:) -> ApplyPatchResult` | Real shape verified: returns `(config: PublishConfig, errors: [ValidationError])`-shaped result and the persists-only-on-no-errors gate is already implemented (Task 6). The plan's response encoding works as-written. |

### Recommended approach for Task 38

1. **First**, extract `ImageResponseBuilder` as a separate prep commit. Pull the image transcoding logic out of `DocumentTools.swift` into `Maugham/MCP/ImageResponseBuilder.swift` (or similar). Keep `ReadDocumentTool` calling into it. Tests for that refactor: confirm `ReadDocumentToolTests` still pass unchanged. Use **normalized 0–1 coordinates** for `Region` (matches existing surface), not absolute pixels.
2. **Then** Task 38's `ReadPublishImageTool` calls the same helper. The other four tools (list/read_file/write/delete) don't need it.
3. Path-traversal validation in `PublishPath.validateAndResolve` should reuse the same shape as `PublicationSnapshotStore` (the security fix): reject `..` segments, leading `/`, `\0`, leading `.`, then standardized prefix check. Don't trust the plan's simpler `contains("..")` — that misses some paths and over-rejects others (it'd reject `chapter..outline.tex`). Use `.split(separator: "/").contains("..")`.

### Recommended approach for Task 40

The plan adds `PublishingStores.sharedFor(projectID:projectURL:)` as a per-project singleton dictionary. **One subtlety**: that dictionary leaks across tests unless cleared. Add a `static func _resetForTesting()` and call from `tearDown` of `CompileToolsTests`. Without that, a second test gets the stale `jobManager` from the first test's project URL — non-flaky on first run, flaky on rerun.

### Recommended approach for Task 41

`read_publication_page` opens a PDF and rasterizes a page via PDFKit + NSImage. Per-page rendering is fine for the response; just don't return a PDF that's already over the 1MB MCP cap. Pipe through the same `ImageResponseBuilder` from Task 38 with `quality=85` and `max_dimension=2048` defaults.

---

## Session-learned gotchas (additions to handoff #1's list)

### 11. `XCTAssertThrowsError(try await ...)` doesn't compile

The assertion's autoclosure isn't async-marked. Pattern is:

```swift
do {
    try await store.save(snap)
    XCTFail("expected throw")
} catch SomeError.specificCase(let payload) {
    XCTAssertEqual(payload, ...)
}
```

Bit us during the path-traversal hardening. The CompileTools tests in Task 40 will hit this on `cancel(jobID:)` paths too.

### 12. Static helper `ProjectStore.collectDocuments(in:)` is internal — call directly

Plan's Task 31 had pseudo-code with imaginary names (`binderPiecesInDisplayOrder`, `text(forPiece:)`). Reality is: `ProjectStore.collectDocuments(in: store.manifest.structure) -> [StructureItem]` walks the tree flat. Mode (prose/fountain) derives from `item.path` extension. Anchor stripping (`<!-- ¶id -->`) happens *inside* `ProjectASTBuilder.build`, not in the adapter.

### 13. Publish pipeline reads `.md` files directly — never via `Document`

Deliberate. CLAUDE.md tripwire 14 ("Don't move/delete a file the user might be editing") implies: don't open a `Document` for read-only manuscript inspection either. Publish output reflects last-autosaved disk state, not the editor's unsaved keystrokes. ⌘S is the user's explicit "checkpoint now" if they want the latest in the next compile.

### 14. The PDF compile is FAST once tectonic's cache is warm

The first tectonic invocation downloads ~150 MB of TeX Live packages (~12s in the test). All subsequent compiles run in ~70–400 ms. The cache lives at `~/Library/Caches/Maugham/tectonic/` and survives across xcodebuild test runs — so Tasks 32–34's tests run real PDF compiles in under a second.

### 15. The starter `preamble.tex` had a pre-existing ordering bug

`\hypersetup{pdftitle={\Title}}` ran before `\providecommand{\Title}{Untitled}` was declared. Fixed in commit `2cfbefa` as part of Task 32 (the first real PDF compile that exercised it). If you regenerate the starter or revert that commit, the bug returns.

### 16. `template.tex` must `\InputIfFileExists{build/metadata}{}{}`

Fixed in `51e98b0`. PDFCompiler writes per-compile metadata overrides to `build/metadata.tex`; the template must include them. The `\InputIfFileExists` (rather than `\input`) keeps the template hand-compilable without going through Maugham.

### 17. Test files: flat OR under `MaughamTests/MCP/Tools/` — both work

xcodegen sources `MaughamTests/` recursively. The earlier subagents mostly used flat; the Task 37/39 subagent used `MaughamTests/MCP/Tools/`. Either compiles. Don't sweat consistency — newer tests just match whatever the surrounding test files do.

### 18. Tool-count hard-codes break on every catalog addition

Two tests assert `tools.count == N`. Bumped 22 → 25 in commit `659a256`. Next session will need to bump again when Tasks 38/40/41 land:
- Task 38: +5 → 30
- Task 40: +4 → 34
- Task 41: +3 → 37

Also update `test_toolsList_returnsAllExpectedTools`'s name set in `MaughamTests/MCP/MCPProtocolHandlersTests.swift` to include the new tool names.

---

## Catalog state at end of this session

`MCPToolCatalog.all` (25 tools, last 3 are the new ones):

```
ListProjectsTool, GetMetadataTool, GetOutlineTool, ReadDocumentTool,
SearchTextTool, ListScenesTool, FindReferencesTool, GetSessionStatsTool,
AddNoteTool, ListResearchTool, ListDocumentsByTagTool, LinkResearchTool,
UnlinkResearchTool, ListAllLinksTool, AddCommentTool,
AddSuggestedChangeTool, AddQueryTool, AddCraftNoteTool,
ListAnnotationsTool, GetAnnotationTool, ListTasksTool, GetTaskTool,
InitializePublishTemplateTool, GetPublishConfigTool, SetPublishConfigTool
```

---

## Tests status

Full suite passes. Verify with:

```bash
cd /Users/denver/src/Maugham/.claude/worktrees/publishing-pipeline-design
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
```

Failing tests at end of last run: 0. Test count: 1280+ (200+ new this session).

---

## How to continue

```
Use superpowers:subagent-driven-development to continue executing
docs/superpowers/plans/2026-05-26-publishing-pipeline.md starting at Task 38.
Read docs/superpowers/notes/2026-05-27-publishing-pipeline-handoff-2.md first
(and the original handoff that it builds on).
```

Same recommendation as handoff #1: dispatch fresh subagents per task block,
trust `xcodebuild`, ignore SourceKit, prepend the `cd` guard to every command.
