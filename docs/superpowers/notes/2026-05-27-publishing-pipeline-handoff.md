# Publishing Pipeline — mid-execution handoff note

**Date:** 2026-05-27
**Branch:** `worktree-publishing-pipeline-design` (in `.claude/worktrees/publishing-pipeline-design/`)
**Progress:** 14 of 49 tasks complete (Phases 1–2). Phase 3 (tectonic engine) is next.

This note exists so a fresh Claude session can pick up the implementation cleanly. It captures the WHAT (where we are) and the WHY/HOW (session-learned gotchas that won't be obvious from spec + plan alone).

---

## Where to look first

In this order, then start work:

1. **This file** — current state + gotchas.
2. **Plan:** `docs/superpowers/plans/2026-05-26-publishing-pipeline.md` — 49 tasks, 9 phases, complete code and test fixtures in every step.
3. **Spec:** `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md` — architecture, decisions, scope-out, risks.
4. **Project CLAUDE.md** at the repo root — Maugham conventions, hard invariants, tripwires.

The spec describes the WHAT. The plan describes the HOW step-by-step. This note adds the WHY of choices that look surprising and the gotchas that bit us in the first 14 tasks.

---

## Working directory

Implementation work happens in this isolated worktree:

```
/Users/denver/src/Maugham/.claude/worktrees/publishing-pipeline-design/
```

NOT in `/Users/denver/src/Maugham/` — that's the main worktree on `main`. Subagents inherit CWD from the main worktree, so EVERY subagent prompt MUST prepend:

```
cd /Users/denver/src/Maugham/.claude/worktrees/publishing-pipeline-design &&
```

to every Bash command. We learned this the hard way — a subagent committed Task 2 (PublishConfig) directly to `main`. That commit (`a232031`) was cherry-picked to this branch as `d55194d`. The duplicate on `main` is harmless and will merge cleanly.

---

## What's done (Phases 1–2)

All 14 commits land cleanly on `worktree-publishing-pipeline-design`. Full test suite passes (1161 tests, 0 failures).

### Phase 1 — Foundations (8 tasks)

| Commit | What |
|---|---|
| `77c8f13` | Task 1 — `MaughamSidecarPath` extended with 7 publishing cases + downstream switch fixed in `DocumentStore` |
| `d55194d` | Task 2 — `PublishConfig` Codable model with all nested types |
| `9ff22e6` | Task 3 — `PublishConfigStore` actor with atomic JSON read/write |
| `167e874` | Task 4 — `JSONMergePatch` (RFC 7396) helper |
| `28b6fed` | Task 5 — `PublishConfigValidator` + `bumpedNextVersion` |
| `d3ae828` | Task 6 — `PublishConfigStore.applyPatch` wired (validates, gates persist) |
| `cda0c78` | Task 7 — barebones starter files in `Maugham/Resources/PublishStarter/` + `project.yml` wiring |
| `038a6dc` | Task 8 — `PublishStarter` enum + `ProjectFactory.installIfMissing` calls in three factory methods |

### Phase 2 — Body emitter (6 tasks)

| Commit | What |
|---|---|
| `c7904c3` | Task 9 — `ProjectAST` sectioned model |
| `569a9f9` | Task 10 — `LaTeXEscape` for ten special chars |
| `f92f4cb` | Task 11 — `XHTMLEscape` for `& < > " '` |
| `7b81803` | Task 12 — `LaTeXBodyEmitter` |
| `2d92f54` | Task 13 — `XHTMLBodyEmitter` |
| `b66835a` | Task 14 — `ProjectASTBuilder` + inline fountain classifier (production wiring deferred to Task 31) |

---

## What's next (Tasks 15–49)

| Phase | Tasks | Subject |
|---|---|---|
| 3 | 15–19 | Tectonic engine (bundle binary, locator, cache, log parser, invoker) |
| 4 | 20–23 | EPUB packager (package model, container.xml, OPF writer, zip via `/usr/bin/zip`) |
| 5 | 24–28 | Publications + snapshots (Publication, PublicationSnapshot, two stores, sidecar wiring) |
| 6 | 29–36 | Job manager + compilers (CompileJob/Manager, PDFCompiler, EPUBCompiler, CompileOrchestrator, PreviewCompiler, Republisher, ProjectStoreASTSource adapter) |
| 7 | 37–42 | 15 MCP tools across 6 task groups (initialize, file tools, config, compile tools, publication tools, catalog sweep) |
| 8 | 43–46 | UI (ExportsListView, PublishStatusPill, InspectorPublishSection, notification post) |
| 9 | 47–49 | Integration smoke (E2E test, republish reproducibility, full sweep + manual smoke) |

The next phase boundary that produces a working end-to-end compile is **end of Phase 6** (the orchestrator can produce a PDF + EPUB + Publication record from a real project). Phase 7 makes it Claude-driveable via MCP.

---

## Session-learned gotchas (load-bearing)

### 1. SourceKit IDE diagnostics are false-positive noise

After every commit, the IDE will report errors like:

```
PublishConfigTests.swift:1:8 No such module 'XCTest'
PublishConfigStore.swift:16:34 Cannot find type 'PublishConfig' in scope
ProjectFactory.swift:64:13 Cannot find 'PublishStarter' in scope
```

**Ignore them.** They are SourceKit failing to re-index after xcodegen regenerates the project. CLAUDE.md is explicit: "SourceKit live diagnostics in IDEs are noise … Trust `xcodebuild` exclusively." Every commit so far had these warnings and tests passed via `xcodebuild test` regardless.

### 2. Subagent CWD inheritance

Subagents launched from this session start in `/Users/denver/src/Maugham/` (the main worktree), NOT in the calling Claude's CWD. You MUST tell them explicitly:

> Prepend `cd /Users/denver/src/Maugham/.claude/worktrees/publishing-pipeline-design && ` to every Bash command. Verify branch with `git branch --show-current` before committing.

Without this guard, the very first dispatched implementer committed Task 2 to `main`. Don't repeat that mistake. Reinforce it in every prompt.

### 3. Test file location convention

The plan specifies paths like `MaughamTests/Stores/MaughamSidecarPathTests.swift` and `MaughamTests/Publish/PublishConfigTests.swift`. These subdirectories are **not the existing convention** — `MaughamTests/` is flat. Both work because xcodegen picks up either layout, but PREFER flat (root of `MaughamTests/`) to match the existing pattern. Some early commits put test files in subdirs; later commits matched the flat convention. Either way functions correctly.

### 4. xcodegen syntax for bundling a folder verbatim

The plan suggested:

```yaml
resources:
  - path: Maugham/Resources/PublishStarter
    type: folder
```

This DOES NOT WORK — under `resources:` it creates a `PBXGroup` and flattens the files into `Contents/Resources/` (losing the subdirectory). The correct shape, which Task 7 actually used, is:

```yaml
sources:
  - path: Maugham
    excludes:
      - Info.plist
      - "**/AREA.md"
      - "Resources/PublishStarter/**"   # exclude from parent so files aren't picked up twice
  - path: Maugham/Resources/PublishStarter
    type: folder                         # under sources:, not resources:
```

This produces a `PBXFileReference` with `lastKnownFileType = folder` — a true Xcode folder reference. Files land at `.app/Contents/Resources/PublishStarter/<filename>` (subdirectory preserved). `Bundle.main.url(forResource: "X", withExtension: nil, subdirectory: "PublishStarter")` works correctly.

If Task 15 (bundle tectonic binary) needs the same trick, copy this pattern.

### 5. Run `./gen.sh` after every `project.yml` edit

CLAUDE.md tripwire. Without it, `xcodebuild` won't find new source files. If a build fails with "no such file or directory" right after you added one, run `./gen.sh` first.

### 6. Per-task review discipline

CLAUDE.md item 4: "Skip the formal two-stage review for trivial tasks. A single small Swift file from a complete spec block doesn't need fresh-implementer + spec-reviewer + code-quality-reviewer. Verify yourself with `git show <commit>`. Reserve dual-reviewer for tasks with real design judgment."

This session followed that: trivial tasks (Codable types, escape helpers, simple stores) got single haiku implementer + manual git-show verification. Tasks involving real judgment (Task 7's xcodegen syntax, Task 14's fountain classifier, Task 8's bundle integration) got sonnet. Continue that discipline. The plan's task complexity classification suggested in earlier setup:

- **Trivial (haiku):** 9, 10, 11, 12, 13, 16, 17, 18, 20, 21, 22, 24, 25, 26, 28, 29, 30, 37, 39, 43, 44, 46
- **Substantive (sonnet/opus + optional dual review):** 14 (done), 15, 19, 23, 27, 31, 32, 33, 34, 35, 36, 38, 40, 41, 42, 45, 47, 48, 49

### 7. The DerivedData clean tripwire

CLAUDE.md (newly added): "Clean DerivedData after merging public-init / protocol-signature changes." If a phantom `Undefined symbol: ...` link error appears at test-link time after merging a change to a public init or protocol signature, run `xcodebuild ... clean` first. Not currently relevant to publishing work, but Tasks 31 (ProjectStoreASTSource integration with live `ProjectStore`) and 34 (CompileOrchestrator wiring against real protocols) might encounter it.

### 8. Tectonic binary distribution (Task 15) — judgment call

The plan commits the tectonic binary (~25 MB) directly into `Maugham/Resources/bin/tectonic`. Alternative: add a Build Phase script that runs `scripts/fetch-tectonic.sh` and `.gitignore` the binary. Both work; the plan flags this as "engineer judgment call" in its known-gaps section. The repo-commit approach is simpler for offline builds; the build-phase approach keeps repo small. Pick whichever fits the user's preference (default: commit the binary — matches "self-contained Mac app" sensibility).

### 9. First-publish-after-install will be slow

Tasks 19 and 32 trigger real tectonic invocations. The first such invocation downloads ~150 MB of TeX Live packages from the tectonic CDN and caches them under `~/Library/Caches/Maugham/tectonic/`. Expect 30–90s for that first run. Subsequent runs are fast. Tests should `XCTSkip` if `TectonicLocator.locate()` throws, to allow running on CI without the binary bundled.

### 10. Publication.checkpointID is empty in v1

Task 34's `CompileOrchestrator` leaves `Publication.checkpointID = ""`. This is deliberately deferred per the plan's known-gaps section — manuscript-state pinning via a CheckpointStore append is a follow-up. The PublicationSnapshot pins publish artifacts (template, styles, config, cover, fonts) but not an op-log pointer. Reproducibility on the publish-artifact side is strong; manuscript-text drift between original compile and republish would surface but isn't a hard guarantee. Don't try to fix this without raising it.

---

## Recommended execution approach

Per the plan's handoff section and the brainstorming-skill's terminal state, two options:

### Option A — subagent-driven-development (recommended for fresh sessions)

```
Use superpowers:subagent-driven-development to continue executing
docs/superpowers/plans/2026-05-26-publishing-pipeline.md starting at Task 15.
Read docs/superpowers/notes/2026-05-27-publishing-pipeline-handoff.md first.
```

Fresh context per subagent dispatch, two-stage review on substantive tasks, single-stage on trivial. Faster end-to-end than the alternative.

### Option B — executing-plans (single inline session)

```
Use superpowers:executing-plans to continue executing
docs/superpowers/plans/2026-05-26-publishing-pipeline.md starting at Task 15.
Read docs/superpowers/notes/2026-05-27-publishing-pipeline-handoff.md first.
```

Step through tasks inline with batch checkpoints. Slower but no subagent context-handoff cost.

The first session used Option A. It worked but consumed substantial context. A fresh session with Option A starting from Task 15 should comfortably reach Phase 6 or beyond before context tightens.

---

## Parallel-review workflow (optional)

If two Claude sessions are running:

- **Implementer session:** runs Option A from Task 15 onward.
- **Reviewer session (held open in the original brainstorm context):** receives commit SHAs from the implementer and reviews via `git show <sha>`, surfacing concerns or pattern drift. Low context burn per review.

The reviewer benefits from continuity (knows why decisions were made); the implementer benefits from fresh context (reliable dispatching).

---

## Known parallel state on `main`

`/Users/denver/src/Maugham/` (main worktree, branch `main`) has these recent commits not on this branch:

- Several dual-dialogue / fountain commits and a merge of `worktree-screenplay-syntax-docs-and-dual-dialogue`
- `a232031 feat(publish): PublishConfig Codable model` — duplicate of `d55194d` on this branch (mis-routed by a subagent; cherry-picked here; harmless on main)

None of these conflict with publishing work. The screenplay-syntax merge and any dual-dialogue changes are independent. When this branch eventually merges to main, git should handle the duplicate Task 2 commit as a no-op (same files, same content).

---

## Stable contracts you should not rename

If you're tempted to refactor: don't, unless the plan calls for it. Several types/functions defined in earlier tasks are referenced by later tasks' code blocks:

- `PublishConfig` and its nested types (Metadata, Outputs, Cover, Section, StartOn, EPUBOverrides, Format)
- `PublishConfigStore` (load / save / applyPatch / ApplyPatchResult)
- `PublishConfigValidator` (validate, bumpedNextVersion, ValidationError)
- `PublishStarter` (install, installIfMissing, isInitialized, Error)
- `ProjectAST` and its nested types (Section, Mode, Node, ProseNode, FountainNode)
- `LaTeXEscape.escape`, `XHTMLEscape.escape`, `XHTMLEscape.attribute`
- `LaTeXBodyEmitter.emit`, `XHTMLBodyEmitter.emit`
- `ProjectASTBuilder.build(from:)`, `ProjectASTBuilder.Source`, `ProjectASTBuilder.PieceRef`
- `MaughamSidecarPath` cases: `.publishTemplate`, `.publishStyles`, `.publishConfig`, `.publishAsset`, `.publishBuild`, `.publicationsLog`, `.publicationSnapshot`

The plan's later task code blocks reference these names directly. Renaming any of them means editing the plan first.

---

## Final reminders

- Stay on `worktree-publishing-pipeline-design`. Verify via `git branch --show-current` before every commit.
- Trust `xcodebuild`. Ignore SourceKit.
- Plan's file paths sometimes use `MaughamTests/Stores/` or `MaughamTests/Publish/` — substitute `MaughamTests/` at the root.
- Don't touch `Maugham.xcodeproj/` directly. Edit `project.yml` + run `./gen.sh`.
- Don't commit anything under `Maugham.xcodeproj/` — it's gitignored for a reason.
- Don't fix the duplicate commit on `main`.
