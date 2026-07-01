# 0020 — Dev-only privileged Test MCP for Claude Code

- **Status:** Accepted
- **Date:** 2026-07-01
- **Design detail:** `docs/superpowers/specs/2026-07-01-test-mcp-design.md`

## Context

Smoke testing Maugham is manual, and the owner is a self-described unreliable tester. The
canonical smoke — launch → New project → Novel → name it → type a sentence → ⌘Q → relaunch →
open from Recents → confirm the sentence survived — is a human-in-the-loop UI walkthrough
repeated every release. Most of its value is verifying *invisible* internal state (op log,
autosave, cursor restore, checkpoints, clean `.md` on disk, ADR 0019), which the owner can't
easily see and no existing surface exposes.

There was no way for anything external to drive or inspect the running app: no URL scheme, no
launch arguments, no XCUITest target, no AppleScript. The production MCP surface (44 tools over
a live-only Unix socket, ADR 0003) is deliberately read-mostly and, by hard invariant, never
mutates manuscript text — it exists for Claude Desktop, a writing companion, not a test driver.

## Decision

Add a **dev-build-only privileged MCP tool layer**, `TestMCPToolCatalog`, for **Claude Code**
(not Claude Desktop), riding the existing dev-build Unix socket. It drives the app at the
`Document`/op-log layer — through the exact same edit entry point the editor uses
(`setFullText` + `recordEditorTextWrite`) — not by faking keystrokes into `NSTextView`, and not
via a second manuscript write path. Mutation is fenced to a throwaway
`~/Library/Application Support/Maugham Dev/TestWorkspace/` via `TestWorkspace.require(url:)`
(MaughamCore); read-only inspect tools are unrestricted since reading can't corrupt.

Two independent, enforced-by-construction safety layers keep this out of the owner's real
projects and out of the shipped product:

1. **Compile gate:** the catalog and its tools are wrapped in `#if MAUGHAM_DEV_BUILD` in
   `MaughamApp.registerTools`. The stable Release build sets no such condition, so the tools
   don't exist in the stable binary at all — the "Desktop/stable users can never get these"
   guarantee. `TripwireGrepTests.test_testMCPCatalog_registeredOnlyUnderDevFlag` enforces the
   registration stays inside the `#if` block.
2. **Runtime workspace guard:** every mutating tool resolves its target project URL through the
   single choke point `TestWorkspace.require(url:)`, which throws unless the path is under the
   TestWorkspace root. Real manuscripts live elsewhere and are structurally unreachable.

The harness survives app restarts without restarting Claude Code itself: the "MCP server" from
Claude Code's perspective is the long-lived `maugham-mcp` bridge process, kept alive by Claude
Code holding its stdin open — not the app. When the app quits, the socket dies; the bridge
polls up to 5s for a new instance to bind it and forwards transparently. A cheap `test_ping`
readiness tool lets the driving loop poll past the cold-launch window (absorbing the known
first-call-after-restart flake, `memory/project_deferred_mcp_first_call.md`, by treating it as
"not ready yet, retry" rather than a bug to fix). `test_quit` acks ("terminating") before
flushing and cleanly terminating ~100ms later, so a quit produces an unambiguous confirmation
instead of a dropped response.

Connection is via a committed repo-root `.mcp.json` plus `scripts/maugham-test-mcp.sh`, which
points `MAUGHAM_MCP_SOCKET` at the dev socket and execs the existing `maugham-mcp` bridge
against the built `Maugham Dev.app`. Shell orchestration (launching/relaunching the app,
reading `.maugham/` off disk directly) stays with Claude Code; everything in-app goes through
the tools.

Thirteen tools shipped, prefixed `test_`, grouped as: **Drive** (mutating —
`test_create_project`, `test_open_project`, `test_apply_edit`, `test_checkpoint`,
`test_reset_workspace`), **Lifecycle** (`test_ping`, `test_flush_autosave`, `test_quit`), and
**Inspect** (read-only — `test_dump_document`, `test_dump_oplog`, `test_autosave_status`,
`test_pending_buffer`, `test_list_checkpoints`).

## Consequences

- The op-log/autosave/checkpoint/cursor-restore loop of the canonical smoke can run
  unattended, with the owner no longer the bottleneck for the parts that don't need human
  eyes.
- **UI-fidelity checks stay manual.** Tokenization, gutter rendering, cursor-during-typing,
  focus-dim, and general "does it look and feel right" remain an eyes-on pass — this ADR
  explicitly does not attempt to automate the `EditorCoordinator`/`NSTextView` layer, which is
  exactly where the Editor tripwires (2/3/6/7) live.
- **Test tools are structurally absent from the stable binary and from the production 44-tool
  catalog.** `Maugham/MCP/AREA.md`'s "Tool catalogue (44)" count is unaffected; the test catalog
  is a separate, additive registration path.
- The tool set is extensible — new `test_`-prefixed tools can be added the same way
  (`TestMCPToolCatalog.all` + `register`) as the invariants under test grow, without touching
  the production catalog or its consistency tests.
- The harness carries its own guardrail tests (workspace-guard throws on a non-TestWorkspace
  URL, stable-exclusion tripwire, inspect-fidelity, catalog consistency) so it can't silently
  drift into reporting a false green.
