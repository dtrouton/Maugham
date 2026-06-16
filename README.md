# Maugham

A focus text editor for serious creative writing on macOS, with an iPhone companion for capture, reading, and annotation review on the go. Native Swift + SwiftUI + AppKit, files-as-truth on disk, designed to live alongside Claude Desktop — Claude reads and annotates your manuscript; it never rewrites it.

<!-- screenshot: three-pane window showing Binder, editor in focus mode, and Outline pane -->

## What you can do

- **Focus writing.** Full-screen focus mode (⌘\\), typewriter scroll, sentence- and paragraph-level dimming, smart typography, and a distraction-free column layout so the words stay front and centre.
<!-- screenshot: editor in focus mode with dimmed surrounding paragraphs -->
- **Structure your project.** Maugham organises work into four project types: Short Story, Novel, Screenplay, and Collection. The Binder holds your pieces — drag to reorder, group into acts or chapters, rename, duplicate, and trash within the app.
- **Organise and navigate.** The Inspector holds per-piece synopsis, status, tags, and word targets. The Outline pane (corkboard or table view) gives a birds-eye view of your project. `[[wiki-links]]` connect related pieces; Research lives in its own browser pane beside the draft.
<!-- screenshot: Inspector showing synopsis, tags, and word target fields -->
- **Screenplays.** Fountain format with full per-element styling, a scene navigator, Tab/Shift+Tab element cycling, page count, and a title page.
- **Write with Claude.** Claude reads your open projects — binder, manuscript text, research, wiki-link graph — and can annotate specific paragraphs. All Claude work appears in the Annotations pane inside Maugham. The manuscript itself is always yours; Claude never edits it directly.
- **Publish.** Claude co-authors a bespoke LaTeX template tuned to your typographic preferences, then compiles it to a personalised PDF (via bundled tectonic) or produces a standard EPUB. Outputs land in the project's `Exports/` folder, shown in the Binder.
- **iPhone companion.** Capture text, photos, and voice notes on the go. Read your manuscript. Review and accept or reject Claude's annotations. Everything syncs back to the Mac via the op log.

First launch shows a welcome carousel. Sample Novel and Screenplay projects are available from **Help → Sample Projects ▸**.

## Install

Latest release: <https://github.com/dtrouton/Maugham/releases/latest>

Download the `.dmg` and drag `Maugham.app` to `/Applications`. Builds are signed with a Developer ID certificate and notarized by Apple, so they launch Gatekeeper-clean — no right-click → Open needed.

Maugham checks for updates daily in the background and shows a banner across the top of any project window when one is ready. Force a check from the **Maugham → Check for Updates…** menu.

Dev builds from Xcode coexist with the installed stable copy under the name **Maugham Dev** (bundle id `com.maugham.Maugham.dev`); they don't share state or update settings.

## Documentation

Full guide: [`docs/guide/`](docs/guide/) — start with [`docs/guide/getting-started.md`](docs/guide/getting-started.md). The same guide is available in-app via **Help → Maugham Help**.

Ask Claude `get_help` for any topic, or `list_maugham_tools` to see everything Claude can do with your projects.

## Writing with Claude

Maugham ships a local MCP server (`maugham-mcp`, bundled inside `Maugham.app/Contents/MacOS/`). Once configured, Claude Desktop can read your open projects (binder, manuscript, research, wiki-link graph), add research notes, and annotate the manuscript without mutating it. The manuscript itself stays yours — Claude operates in a parallel annotation layer, surfaced in Maugham's Annotations pane.

Claude Desktop can also **publish** your project — compile it to PDF (bundled tectonic/LaTeX) or EPUB, co-authoring a per-project LaTeX template tuned to your typographic taste. Outputs land in the project's `Exports/` folder (shown in the binder). The template and a small `config.json` live under `.maugham/publish/`; `EMISSION.md` there is the authoritative contract describing what the body emitter produces. Ask Claude `list_maugham_tools` to see the full tool surface, or "set up publishing for this project."

To configure: open Maugham, then **Help → Set up Claude Desktop…** → click `Configure`. Restart Claude Desktop. Try asking "What Maugham projects are open?"

The server only runs while Maugham is running. **Settings → General → "Allow Claude to connect (MCP)"** toggles it off (default on). See [ADR 0003](docs/adr/0003-mcp-live-only-unix-socket.md) for the transport design and [ADR 0004](docs/adr/0004-mcp-foundation-scope.md) for the tool surface.

## Development

### Status

Active development. The current state of what's shipped and what's open lives in [`docs/roadmap.md`](docs/roadmap.md). Architectural decisions taken since the initial design are recorded as ADRs under [`docs/adr/`](docs/adr/); the initial design itself is [`docs/superpowers/specs/2026-05-07-maugham-master-design.md`](docs/superpowers/specs/2026-05-07-maugham-master-design.md).

### Build

Requires macOS 14+, Xcode 15+, and `xcodegen`:

    brew install xcodegen

Generate the Xcode project and open it:

    ./gen.sh
    open Maugham.xcodeproj

In Xcode: ⌘R to run, ⌘U to test.

Smoke a fresh build: launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence is intact. If that works, the foundation is healthy.

### Test

    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO

The iOS companion is a separate scheme (read [`MaughamPhone/AREA.md`](MaughamPhone/AREA.md) before editing it):

    xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO

### Layout

- `Maugham/` — main macOS app source (Swift, SwiftUI, AppKit)
- `MaughamPhone/` — the iOS companion app (SwiftUI; see `MaughamPhone/AREA.md`)
- `Packages/MaughamCore/` — Foundation-only substrate shared by both apps (op log, Fountain parser, models, `Deriver`, anchor strip, …)
- `maugham-mcp/` — the MCP CLI binary that bridges Claude Desktop's stdio to Maugham's Unix socket
- `MaughamTests/` / `MaughamPhoneTests/` — XCTest targets (Mac / iOS)
- `project.yml` — xcodegen project description; edit this, not `Maugham.xcodeproj`
- `docs/guide/` — the full user guide (also available in-app via Help → Maugham Help)
- `docs/user-guide.md` — legacy single-page writer reference
- `docs/roadmap.md` — current live roadmap (shipped + open, grouped by writer intent)
- `docs/adr/` — Architecture Decision Records (decisions made since the initial design)
- `docs/superpowers/specs/` — per-milestone design documents
- `docs/superpowers/plans/` — per-milestone implementation plans

### Working in this repo

Per-milestone smokes, designs, plans, and post-mortem memory are anchored by date in `docs/superpowers/`. The MEMORY/auto-memory file in `~/.claude/projects/-Users-denver-src-Maugham/memory/` summarizes each shipped milestone's API surface and carry-forwards.

This codebase is built with Claude Code's agent-driven workflow. Per-milestone plans live in `docs/superpowers/plans/`; they're dispatched task-by-task to subagents via the `subagent-driven-development` skill. The dated specs and plans are the historical record of how each milestone got shaped.

## License

Maugham's source is licensed under the **PolyForm Noncommercial License 1.0.0** — see [`LICENSE.md`](LICENSE.md). In short: you may read it, build it, and use it for personal and other noncommercial purposes, but you may not sell it or ship a commercial product based on it. All commercial rights are reserved by the copyright holder.

Bundled third-party components (WhisperKit, Tectonic) keep their own MIT licenses — see [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md).
