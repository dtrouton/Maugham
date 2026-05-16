# Maugham

A focus text editor for serious creative writing on macOS. Native Swift + SwiftUI + AppKit, files-as-truth on disk, designed to live alongside Claude Desktop.

## Status

Twelve milestones shipped, **585 tests passing**. Most recent: `milestone-mcp-foundation` (2026-05-16) — Claude Desktop can read and contribute to your projects via a local MCP server with 14 tools.

For the current state of the roadmap (what's shipped, what's open), see [`docs/roadmap.md`](docs/roadmap.md). For architectural decisions made since the initial design, see [`docs/adr/`](docs/adr/). For the initial design itself, see [`docs/superpowers/specs/2026-05-07-maugham-master-design.md`](docs/superpowers/specs/2026-05-07-maugham-master-design.md).

## Build

Requires macOS 14+, Xcode 15+, and `xcodegen`:

    brew install xcodegen

Generate the Xcode project and open it:

    ./gen.sh
    open Maugham.xcodeproj

In Xcode: ⌘R to run, ⌘U to test.

Smoke a fresh build: launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence is intact. If that works, the foundation is healthy.

## Test

    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO

Currently 585 tests passing.

## Claude Desktop integration

Maugham ships a local MCP server (`maugham-mcp`, bundled inside `Maugham.app/Contents/MacOS/`). Once configured, Claude Desktop can:

- List your open projects, outlines, and chapters
- Read documents (live in-memory text when the doc is open)
- Search across manuscript
- Discover research items and the reference graph (wiki links + linked research)
- Create research notes for you and link them to chapters

To configure: open Maugham, then **Help → Set up Claude Desktop…** → click `Configure`. Restart Claude Desktop. Try asking "What Maugham projects are open?"

The server only runs while Maugham is running. Settings → General → "Allow Claude to connect (MCP)" toggles it off (default on). See [ADR 0003](docs/adr/0003-mcp-live-only-unix-socket.md) for the transport design and [ADR 0004](docs/adr/0004-mcp-foundation-scope.md) for the tool surface.

## Layout

- `Maugham/` — main app source (Swift, SwiftUI, AppKit)
- `maugham-mcp/` — the MCP CLI binary that bridges Claude Desktop's stdio to Maugham's Unix socket
- `MaughamTests/` — XCTest target
- `project.yml` — xcodegen project description; edit this, not `Maugham.xcodeproj`
- `docs/user-guide.md` — for writers using Maugham
- `docs/roadmap.md` — current live roadmap (shipped + open, grouped by writer intent)
- `docs/adr/` — Architecture Decision Records (decisions made since the initial design)
- `docs/superpowers/specs/` — per-milestone design documents
- `docs/superpowers/plans/` — per-milestone implementation plans

## Working in this repo

Per-milestone smokes, designs, plans, and post-mortem memory are anchored by date in `docs/superpowers/`. The MEMORY/auto-memory file in `~/.claude/projects/-Users-denver-src-Maugham/memory/` summarizes each shipped milestone's API surface and carry-forwards.

This codebase is built with Claude Code's agent-driven workflow. Per-milestone plans live in `docs/superpowers/plans/`; they're dispatched task-by-task to subagents via the `subagent-driven-development` skill. The dated specs and plans are the historical record of how each milestone got shaped.
