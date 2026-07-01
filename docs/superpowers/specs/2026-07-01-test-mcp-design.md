# Test MCP — a dev-build-only privileged MCP surface for Claude Code

**Date:** 2026-07-01
**Status:** Draft — pending owner review
**Author:** Claude (brainstormed with the owner)

## Problem

Smoke testing Maugham is manual and the owner is (self-described) an unreliable tester.
The canonical smoke — *launch → New project → Novel → name it → type a sentence → ⌘Q →
relaunch → open from Recents → confirm the sentence survived* — is a human-in-the-loop UI
walkthrough repeated every release. Most of its **value** is verifying invisible internal
state (op log, autosave, cursor restore, checkpoints, clean `.md` on disk), which the owner
can't easily see and which no automated surface currently exposes.

Today there is **no way for anything external to drive or inspect the running app**: no URL
scheme, no launch arguments, no XCUITest target, no AppleScript. The production MCP surface
(44 tools over a live-only Unix socket, ADR 0003) is deliberately read-mostly and, by hard
invariant, **never mutates manuscript text** — it exists for Claude Desktop, a writing
companion, not a test driver.

A secondary, rarer pain: verifying Claude Desktop's MCP access has meant the owner
copy-pasting Desktop's output back to Claude Code.

## Goal

Let Claude Code drive the **data/persistence feedback loop end to end without the owner** —
create a project, edit it, autosave, checkpoint, quit, relaunch, and assert that the op log,
in-memory `Document`, on-disk `.md`, and checkpoints are all correct across the restart. The
only tests that remain manual are **genuine UI-fidelity checks** (rendering, typing feel,
focus-dim, gutters) — few, and eyes-only.

### Non-goals

- **Not** a shipping feature. Everything here is compiled out of the stable release.
- **Not** UI-fidelity testing. Driving happens at the op-log layer, not by faking keystrokes
  into `NSTextView` (see "Driving semantics"). The `EditorCoordinator`/text-view layer stays
  a manual pass.
- **Not** a replacement for the production MCP surface or its invariants. This is a separate,
  additive, dev-only catalog.
- **Not** in scope: observing Claude Desktop's own LLM interpretation/rendering. Giving Claude
  Code the same read tools verifies tool *correctness* directly, which dissolves most of the
  copy-paste pain; Desktop's LLM behavior is not a Maugham bug domain.

## Approach (chosen)

A **dev-build-only privileged MCP tool layer** on the **existing dev socket**, connected to
Claude Code (not Claude Desktop), driving at the `Document`/op-log layer, with mutation fenced
to a throwaway TestWorkspace. Claude Code orchestrates launch/relaunch from the shell; every
in-app action goes through the tools.

Rejected alternatives:

- **Headless scenario runner** (launch-arg-driven, dumps JSON, exits) — batch, not
  interactive; can't adapt mid-loop; still needs every drive/inspect primitive underneath.
- **Full-fidelity UI driving** (synthesize keystrokes via accessibility) — fragile
  (main-thread/focus/view-existence dependent) and pokes directly at the binding races the
  Editor tripwires (2/3/6/7) exist to prevent. This class of check stays manual.

## Architecture & transport wiring

The test tools ride the **existing dev MCP socket** — no second socket, no new server.

- **New `Maugham/MCP/Test/TestMCPToolCatalog.swift`** mirrors `MCPToolCatalog`
  (`Maugham/MCP/MCPTool.swift`): an ordered list of test tools plus
  `register(router:registry:)`. Kept **separate** from the production catalog so
  `MCPToolCatalog.all`, `MCPToolsListHandler`, and the catalog-consistency tests are
  untouched.
- **Registration** in `MaughamApp.registerTools` (`Maugham/MaughamApp.swift`): always register
  `MCPToolCatalog`, then — inside `#if MAUGHAM_DEV_BUILD` — also register
  `TestMCPToolCatalog`. `MAUGHAM_DEV_BUILD` is a **compile** condition set for dev builds via
  the app target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (`project.yml`) — and, for
  MaughamCore, via `Package.swift` `.define(..., .when(configuration: .debug))`. The stable
  **Release** build sets neither, so `#if MAUGHAM_DEV_BUILD` in the app compiles the test-tool
  registration (and the tools themselves) **out of the stable binary entirely** — the
  top-level "Desktop can never get these" guarantee. (The plan must confirm `project.yml`'s
  stable config does not carry the condition — tripwire-13 territory.)
- **Connection (how the owner connects Claude Code):** a committed `.mcp.json` at the repo root
  with one server entry whose command is a small committed wrapper, `scripts/maugham-test-mcp.sh`,
  that (a) sets `MAUGHAM_MCP_SOCKET` to the dev socket path
  (`~/Library/Application Support/Maugham Dev/mcp.sock`, from `BuildVariant.mcpSocketPath`) and
  (b) execs the existing `maugham-mcp` bridge (`maugham-mcp/JSONRPCBridge.swift`) from the built
  `Maugham Dev.app`. The test tools then surface to Claude Code as native
  `mcp__maugham_test__*` tools. The wrapper absorbs "the dev app was rebuilt" churn so
  `.mcp.json` never changes.
- **Orchestration stays in the shell:** Claude Code `open`s / relaunches the dev app and reads
  `.maugham/` off disk directly; everything in-app goes through the tools. The socket dying on
  quit is expected — Claude Code relaunches externally and reconnects.

### Surviving app restarts (no Claude-Code restart needed)

From Claude Code's side the "MCP server" is the long-lived **bridge process**, not the app.
The bridge stays alive as long as its stdin is open (`JSONRPCBridge.swift:34-40`); stdin is
held open by Claude Code's MCP client for the life of the registered server. So the tool list
**persists across every quit/relaunch cycle** — no need to restart Claude Code or re-add the
server.

When the app restarts, the socket dies; on the next request the bridge sees it *had* a prior
connection and **polls up to 5s for the new instance to bind the socket, then forwards
transparently** (`JSONRPCBridge.swift:74-88`). A relaunch inside that window is invisible.

**Known caveat — the deferred first-call-after-restart flake**
(`memory/project_deferred_mcp_first_call.md`): if cold launch takes **>5s**, the first call
after relaunch returns a synthesized `maugham_not_running` error (code `-32001`,
`JSONRPCBridge.swift:96-99`). That bug was deferred because it's confusing for a *human* firing
one Desktop call; for an automated agent it's trivially handled by retry. Two design elements
absorb it (see Tool inventory + The loop):

1. A cheap `test_ping` readiness tool the loop polls after relaunch (treating `-32001` as
   "not ready, back off and retry") before running any assertion.
2. `test_quit` **acks then terminates** (replies "terminating", then flushes + terminates
   ~100ms later) so the quit produces a clean confirmation rather than an ambiguous dropped
   response.

## Safety model — TestWorkspace

Two independent layers, both **enforced by construction** (matching the typed-mover /
tripwire-14 ethos), so mutation can never touch the owner's real writing:

1. **Compile gate:** mutating tools don't exist in the stable binary at all (`#if
   MAUGHAM_DEV_BUILD`).
2. **Workspace prefix guard (runtime, dev build):** every *mutating* tool resolves its target
   project URL through a single choke point — `TestWorkspace.require(url:)` — that **throws**
   unless the path is under the fixed root
   `~/Library/Application Support/Maugham Dev/TestWorkspace/`. One function; all drive/reset
   tools funnel through it. Real manuscripts live elsewhere and are structurally unreachable.

- **Read-only inspect tools are NOT workspace-restricted** — reading can't corrupt, and
  inspecting a real open project's op log is occasionally useful. Only mutation is fenced.
- `test_reset_workspace` deletes everything under (and only under) the TestWorkspace root, so
  each run starts clean — matching the owner's "delete and recreate test files freely" stance
  (tripwire 11).

## Tool inventory

Extensible; start with what the canonical smoke and the op-log/autosave/cursor/checkpoint
invariants need (YAGNI — no speculative tools). All tools are prefixed `test_`.

**Drive** (mutating → `TestWorkspace.require()`-fenced, dev-only):

| Tool | Purpose |
|---|---|
| `test_create_project` | Create + open a project (novel/screenplay/short-story/collection) under TestWorkspace via `ProjectFactory`, through the real `Document.load`→`Bootstrap` path. Returns project URL + docIds. |
| `test_open_project` | Open an existing TestWorkspace project into a window/registry. |
| `test_apply_edit` | The "typing" surrogate: insert / edit / delete a paragraph by docId + paragraphId (or position). Routes through the same `Document` op-recording API the editor uses (see Driving semantics). |
| `test_checkpoint` | Fire a labeled ⌘S project-scope checkpoint. |
| `test_reset_workspace` | Delete everything under (and only under) TestWorkspace. |

**Lifecycle:**

| Tool | Purpose |
|---|---|
| `test_ping` | Cheap readiness probe. The loop polls it after relaunch to absorb the cold-launch window before asserting. |
| `test_flush_autosave` | Force the 750ms debounced write to happen *now* — assert against disk without sleeping. |
| `test_quit` | Ack ("terminating") first, then flush + clean-terminate ~100ms later. Socket dies; Claude Code relaunches via `open`. |

**Inspect** (read-only, *not* workspace-fenced):

| Tool | Reveals |
|---|---|
| `test_dump_oplog` | Raw ops for a doc: sequence, kind, paragraphId, payload. The core assertion surface (LWW, ULID ordering, keyframes). |
| `test_dump_document` | In-memory `Document`: paragraphs walked by `sequence`, each `¶id`+text, cursor, `lastDiskEcho`, pending sweep, materialized render. |
| `test_autosave_status` | Pending debounced write? echo state? — the invisible autosave state. |
| `test_pending_buffer` | `PendingBuffer` durable sequence (crash-recovery / clean-`.md` domain, ADR 0019). |
| `test_list_checkpoints` | Checkpoints + metadata for partial-restore assertions. |

On-disk `.md` and `.maugham/` are read **directly via the shell** — no tool needed. The
inspect tools exist specifically for *in-memory* state otherwise invisible.

## Driving semantics (load-bearing correctness point)

`test_apply_edit` must **route through the exact same op-recording entry point on `Document`
that the editor uses** when the owner types — appending ops, bumping `sequence`,
re-materializing — **not** a parallel mutation path and **not** faked keystrokes into the
`NSTextView`. Rationale:

- It exercises the real source of truth (op log → materializer → autosave → clean `.md` on
  disk), which is exactly what the smoke verifies.
- It avoids introducing a second manuscript write path (tripwires 6/7; the "no 4th
  `applyExternalText` caller" rule). **The implementation plan must identify the single
  existing `Document` edit API and reuse it**, not invent one.
- It deliberately does **not** cover tokenization, gutter, cursor-during-typing, or focus-dim —
  the `EditorCoordinator`/NSTextView layer. Those stay the manual, eyes-on tests.

## The loop, end to end (worked example: the canonical smoke)

Shell orchestration in **bold**, MCP tools in `code`:

1. **`open` the dev app** (Bash); the `mcp__maugham_test__*` server is already in `.mcp.json`.
2. **poll `test_ping`** until it succeeds (readiness handshake; absorbs cold-launch).
3. `test_reset_workspace` → clean slate.
4. `test_create_project(novel, "Smoke")` → returns docId.
5. `test_apply_edit(docId, insert, "The cat sat.")` → op appended, materialized.
6. `test_dump_oplog` + `test_dump_document` → assert the op landed, `sequence` advanced,
   `¶id` minted, echo state sane.
7. `test_flush_autosave` → **read `Smoke.md` off disk** → assert it's clean Markdown (no
   `¶id`/`t-` anchors — ADR 0019) and the sentence is present.
8. `test_checkpoint("smoke")` → `test_list_checkpoints` → assert it recorded.
9. `test_quit` → ack received; socket closes (expected).
10. **`open` the dev app again** (Bash) → **poll `test_ping`** until ready.
11. `test_open_project(Smoke)` → `test_dump_document` → **assert "The cat sat." survived** the
    quit/relaunch; op log + cursor intact.

No human in the loop. Genuine-UI checks (render, typing feel, focus-dim) are a separate short
manual pass with a checklist Claude Code hands over.

## Verifying the harness itself

The test tooling needs its own guardrails or it can lie to us. These run in the normal
`xcodebuild test` suite:

- **Workspace-guard unit test:** a mutating tool given a non-TestWorkspace URL **throws**
  (proves the fence).
- **Stable-exclusion tripwire:** assert `TestMCPToolCatalog` symbols are absent from a stable
  build — mirrors the existing `TripwireGrepTests` ethos so the dev-only tools can't leak into
  a release.
- **Inspect-fidelity test:** apply a known edit, then assert `test_dump_document` /
  `test_dump_oplog` report exactly that edit — so the inspection surface can't drift from
  reality and give a false green.
- **Catalog-consistency:** extend the existing consistency check so every `TestMCPToolCatalog`
  tool is dispatchable + schema-valid (same protection the production catalog has).

## Change inventory (indicative — the plan will finalize)

- `Maugham/MCP/Test/TestMCPToolCatalog.swift` — new catalog + `register`.
- `Maugham/MCP/Test/Tools/*.swift` — the ~15 tool implementations.
- `Packages/MaughamCore/Sources/MaughamCore/TestWorkspace.swift` — root constant +
  `require(url:)` guard (MaughamCore so tools and tests share it).
- `Maugham/MaughamApp.swift` — `#if MAUGHAM_DEV_BUILD` registration call; `test_quit` /
  `test_ping` hooks into app lifecycle.
- `.mcp.json` (repo root) + `scripts/maugham-test-mcp.sh` — connection wiring.
- Tests under `MaughamTests/MCP/Test/` — the four guardrail suites above.
- `Maugham/MCP/AREA.md` — document the dev-only catalog and its boundary.
- Possibly a new short ADR recording "dev-only privileged test MCP, op-log-layer driving,
  TestWorkspace fence."

## Open questions / deferred

- **Exact `Document` edit entry point** for `test_apply_edit` — resolved during planning by
  reading `Document+*.swift`; must be the single existing editor path.
- **`test_quit` termination mechanism** — cleanest hook for flush-then-`NSApp.terminate` on a
  short delay; the plan pins it.
- **Whether `test_ping` needs to report app version / build id** so the loop can assert it
  relaunched the intended binary — likely yes, cheap to include.
- The Desktop-LLM-observation pain stays out of scope unless the owner revisits it.
