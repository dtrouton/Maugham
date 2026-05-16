# 0003 — MCP transport: live-only Unix socket via CLI bridge

**Status:** Accepted
**Date:** 2026-05-15

## Context

The master spec planned Claude integration via Claude Desktop's built-in **filesystem** MCP server — Claude reads files in the project folder directly, no Maugham-side MCP code required. This was the lowest-effort option and the right call for the first day's design.

By the time we got around to actually building Group 2's foundation, two things made the filesystem approach insufficient:

1. **Stale-read risk.** Claude reading from disk only sees what's been autosaved. The 750ms debounce in `DocumentStore` means Claude can see a doc that's seconds out of date during active typing — confusing for "read me Chapter 1" while the writer is mid-paragraph.
2. **No first-class structure access.** Filesystem MCP gives Claude bytes. Claude has to re-derive the project structure (manifest parsing, fountain parsing, scene boundaries, linked research) on every read. Slow and error-prone for a tool surface we control.

The brainstorm on [2026-05-15](../superpowers/specs/2026-05-15-mcp-foundation-design.md) compared three transport architectures:

- **A. Disk-only (no Maugham coupling)** — what the master spec implied. Filesystem MCP server, Claude reads disk. Stale by up to one autosave debounce; no structured tools.
- **B. Live-only (requires Maugham running)** — Maugham itself implements MCP via a Unix socket. Always sees in-memory state. Useless when Maugham is closed.
- **C. Hybrid (live if available, disk fallback)** — both paths. Most complex; two code paths to maintain and a "staleness" indicator to design.

## Decision

Live-only. **Maugham binds a Unix socket at `~/Library/Application Support/Maugham/mcp.sock` when running.** A small CLI binary `maugham-mcp` ships inside `Maugham.app/Contents/MacOS/`; Claude Desktop spawns it via stdio (the MCP transport Claude already speaks). The binary forwards line-delimited JSON-RPC bytes between Claude's stdio and the socket. When the socket isn't there (Maugham closed), the binary synthesizes a `-32001 maugham_not_running` response per request.

Inside Maugham, an `MCPServer` actor runs the accept loop and dispatches to a method registry. `ProjectRegistry` holds the set of currently-open projects (each `ProjectWindow` registers on `load()` and unregisters on `onDisappear`). Every tool takes a `project_id` and looks up the matching `ProjectStore`.

## Consequences

- **No staleness.** Tools read `ProjectStore.manifest` and `DocumentStore.currentDocumentText` directly. Claude sees current in-memory state, including unsaved edits.
- **No disk-fallback code path** — half the architectural cost of option C avoided. The graceful failure mode is "ask the user to open Maugham."
- **Closed projects aren't visible.** Discoverable via `list_projects`. The trade-off is acceptable: writers open the projects they're working in.
- **Two processes need lifecycle discipline.** Maugham binds + unlinks the socket; the binary handles `maugham_not_running` synthesis cleanly. SIGPIPE on socket-peer-close was discovered to kill both processes silently — both now install `signal(SIGPIPE, SIG_IGN)` at start (caught in smoke as a separate failure mode).
- **Bundle structure changed.** New `maugham-mcp` Xcode target produces a CLI binary copied into `Maugham.app/Contents/MacOS/` via xcodegen's `dependencies: copy: destination: executables`.
- **MCP protocol envelope is required.** Claude Desktop sends `initialize` → `notifications/initialized` → `tools/list` → `tools/call` as the handshake; raw JSON-RPC tool methods aren't enough. Three protocol-layer handlers sit in front of the tools, plus the server suppresses responses to JSON-RPC notifications (id-less requests).
- **Cooperative thread pool starvation gotcha.** Swift's structured concurrency uses a bounded thread pool; blocking POSIX `accept`/`recv` in a `Task.detached` deadlocks the executor. The accept loop dispatches blocking calls onto GCD's `DispatchQueue.global()` (unbounded) via `withCheckedContinuation`. Don't put blocking syscalls in `Task.detached` — caught the hard way during build.

## References

- [MCP Foundation spec](../superpowers/specs/2026-05-15-mcp-foundation-design.md)
- [MCP Foundation plan](../superpowers/plans/2026-05-15-mcp-foundation.md) — 17 task breakdown
- [ADR 0004](0004-mcp-foundation-scope.md) — the tool surface scope choice
