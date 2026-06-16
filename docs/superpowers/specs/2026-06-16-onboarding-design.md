# Onboarding — Design

**Date:** 2026-06-16
**Status:** Approved (brainstorm), pending spec review
**Scope:** One milestone, five deliverables sharing a single documentation source.

A new writer arriving at Maugham today meets a bare launcher (New / Open / Recents) and a developer-facing README. There is a strong `docs/user-guide.md`, but it lives only in the repo — not in the app, not reachable by Claude. This milestone turns first contact into a guided, writer-centric experience and makes Maugham's own documentation a first-class, reusable asset.

This is **one milestone** ("Onboarding"). The five deliverables below share infrastructure (notably a single docs source) and ship together. The numbered list is a build order, not a set of independent milestones.

---

## Goals

- A first-launch tour that explains Maugham to a writer in their language, then lets them try it hands-on.
- In-repo documentation that is also bundled in the app and queryable by Claude — one source, no drift.
- A README that sells and orients writers first, with developer detail demoted but intact.

## Non-goals

- Real screenshots in the carousel (ship with drawn-in-code illustrations behind a swap-in slot; screenshots come later, writer-provided or via computer-use).
- A Collection-based sample (rejected in brainstorm: front-loads the most advanced concept; Novel + Screenplay samples chosen instead).
- Any change to manuscript-edit semantics, the op log, or the MCP write surface beyond adding one read-only help tool.
- iOS/phone onboarding (future).

---

## Deliverable 1 — Docs: one source, three surfaces (foundation)

The single source of truth becomes a set of topic files under **`docs/guide/`**. Everything else reads them.

### Topic files (~9)

Split the current `docs/user-guide.md` into:

| Slug | Covers |
|---|---|
| `getting-started` | Welcome window, project types, three-pane layout, the autosave/relaunch loop |
| `editor-and-focus` | Centered column, themes/typography, focus mode, typewriter, sentence/paragraph dimming, smart typography, goals/word count |
| `structure-and-binder` | Binder, adding/duplicating/deleting items, drag-reorder, Tidy Filenames, Inspector metadata, wiki-links, Find (⌘F / ⌘⌥F) |
| `research` | Research segment, notes/images/PDFs/links, inline image preview, Trash & undo |
| `right-pane` | Inspector / Linked Research / Outline modes (⌘⌥1/2/3) |
| `screenplay` | Fountain parsing, Tab-cycling, scene navigator, page count, title page, ⌘/ syntax help |
| `claude-desktop` | MCP setup, what Claude can read/annotate, the note banner, turning it off |
| `publishing` | Claude co-authored bespoke LaTeX → personalised PDF; standard EPUB; `Exports/` |
| `reference` | Keyboard shortcuts, on-disk layout, troubleshooting |

A **`docs/guide/index.json`** lists `[{ slug, title, order }]` — the canonical topic list and ordering.

### Bundling

`project.yml` adds `docs/guide/` as a bundled resource on the **Mac app target** (the Help window and the MCP server are both Mac-only). Built into `Maugham.app/Contents/Resources/guide/`.

### Drift guard

A test mirroring `MCPCatalogConsistencyTests` asserts:
- every `index.json` entry has a matching file in `docs/guide/`,
- every `.md` file in `docs/guide/` appears in `index.json`,
- every entry's file is present in the built bundle (resource lookup succeeds).

`docs/user-guide.md` is either deleted (content fully migrated) or reduced to a one-line pointer at `docs/guide/`. Decision at implementation time; default is delete-and-point.

---

## Deliverable 2 — In-app Help window + MCP exposure

Two consumers of the bundled docs.

### `HelpWindow` (in-app)

- Its own resizable `WindowGroup(id: "help")`.
- `NavigationSplitView`: sidebar lists topics from `index.json` (title, in `order`); detail pane renders the selected topic's markdown.
- Markdown rendering **reuses the existing research-note markdown renderer** (the component used by the research preview / `LinkedResearchPane`) — no new dependency, consistent look.
- Opened via **Help → Maugham Help** (⌘?). Coexists with the ⌘/ Syntax Reference sheet, which stays for fast syntax lookups.
- Empty-state / sizing follows tripwire 15 (`ContentUnavailableView` framing) where applicable.

### `GetHelpTool` (MCP)

- New `MCPTool` conformer added to `MCPToolCatalog.all` (44 tools total).
- `method: "get_help"`. Param: optional `topic` (a slug).
  - No `topic` → returns the topic index (slugs + titles) so Claude can pick.
  - Valid `topic` → returns that file's markdown text.
  - Unknown `topic` → fails loudly with a clear error listing valid slugs (consistent with catalog "fail on unknown id" behavior).
- Read-only. Reads the same bundled `guide/` resources the Help window uses.
- Update `Maugham/MCP/AREA.md` tool count and list; `docs/user-guide.md`/`README` references to "43 tools" become 44.

---

## Deliverable 3 — First-time tour: welcome carousel → sample fork

### `WelcomeCarousel`

- An 8-slide paged SwiftUI view presented as a sheet.
- Slides: **Welcome · Structure · Focus · Organize · Collaborate-with-Claude · Publish · Safety · Get Started.**
- Each slide: an illustration + a heading + one sentence of writer-facing copy. Skippable from any slide ("Skip"); Back/Next; dot indicator.
- Final **Get Started** slide forks three ways:
  - **Try a sample Novel** → builds + opens the Novel sample (Deliverable 4).
  - **Try a sample Screenplay** → builds + opens the Screenplay sample.
  - **Start a project of my own** → the normal New Project flow.
- Choosing any of the three (or Skip) sets the completion flag and dismisses.

### Imagery (option C)

Each slide's image is an `illustration` value drawn in SwiftUI now (SF Symbols + shapes, theme-aware). The slide model carries an optional bundled-image slot so a real screenshot can replace the drawn illustration with a one-line change later. **Flag point:** when we want real screenshots, the writer provides them (or we revisit computer-use).

### Trigger & re-entry

- A `UserPreferences` / `AppStorage` flag `hasCompletedWelcome` (default false).
- First launch: `WelcomeView` auto-presents the carousel when the flag is false.
- **Help → Welcome to Maugham** re-opens it anytime, via a `.maughamShowWelcome` notification mirroring the existing `.maughamShowSyntaxHelp` pattern (so it works whether the frontmost surface is the launcher or a project window).

---

## Deliverable 4 — Sample projects

### `SampleProjectBuilder`

- Seed content ships as **bundled resources** under `Maugham/Resources/Samples/{novel,screenplay}/`. The seed text *is* a mini-tour — chapters/scenes that explain a feature and invite the writer to try it ("type a sentence here," "press ⌘/ for the syntax sheet," "click the Outline tab").
- On request, the builder:
  1. Resolves a deduped destination path (`~/Documents/Maugham Sample Novel`, then `… 2`, … if taken).
  2. Constructs the project by **reusing the existing New Project creation path** (so the manifest, folder layout, and project type are produced exactly as a real project).
  3. Copies the seed manuscript/research files into place.
  4. Opens the project through the **standard load path (`Document.load`)** so **`Bootstrap.run` mints the inline `¶id` anchors** (hard invariant) and the op log is correct from first open.
  5. Adds it to Recents.
- The result is an ordinary, fully editable/movable/deletable project. No special-casing downstream.
- Reachable later via **Help → Sample Projects ▸ Novel / Screenplay** (same builder).

---

## Deliverable 5 — README rewrite

Reframe writer-first; demote, don't delete, developer content.

- **Top:** what Maugham is (one strong paragraph) → key features for writers (with screenshot slots) → Install.
- **Then:** Claude Desktop integration and Publishing described in plain, benefit-led language; link to the bundled guide / `docs/guide/`.
- **Bottom:** a single **Development** section absorbing today's Build / Test / Layout / "Working in this repo" content (reordered, lightly reworded). Nothing removed.

---

## Architecture / new units

| Unit | Responsibility | Depends on |
|---|---|---|
| `docs/guide/*.md` + `index.json` | Single docs source | — |
| `HelpTopicIndex` (small loader) | Parse `index.json`, resolve bundled topic files | bundle |
| `HelpWindow` | Render topic sidebar + markdown | `HelpTopicIndex`, research markdown renderer |
| `GetHelpTool` | MCP read access to topics | `HelpTopicIndex` |
| `WelcomeCarousel` (+ `WelcomeSlide` model) | Paged first-run tour | `SampleProjectBuilder`, New Project flow |
| `SampleProjectBuilder` | Materialize a real sample project from bundled seeds | New Project path, `Document.load`/`Bootstrap`, Recents |
| Help menu additions | Maugham Help / Welcome to Maugham / Sample Projects ▸ | notifications |

`HelpTopicIndex` is the shared seam: both `HelpWindow` and `GetHelpTool` read topics through it, so neither hand-rolls bundle lookups.

## Hard-invariant checkpoints

- Sample projects open through `Document.load` → `Bootstrap.run` (no direct `Document` construction).
- No raw file moves for user content; builder *creates* (doesn't move) — but any cleanup/relocation path uses the typed `DocumentStore` mover (tripwire 14).
- No hardcoded `"Maugham"`/paths outside `BuildVariant` (tripwire 13) — sample destination naming uses `BuildVariant.current.displayName` where user-visible.
- MCP tool fails loudly on unknown topic (catalog convention; ADR 0004 size cap respected — topic files are small, well under 1 MB).

## Testing

- **Drift guard:** `index.json` ↔ files ↔ bundle (described above).
- **`GetHelpTool`:** returns index with no topic; returns content for each valid slug; errors with valid-slug list on unknown topic.
- **`SampleProjectBuilder`:** produces a project that loads with `¶id` anchors present; dedupes destination names; both Novel and Screenplay seeds materialize and open.
- **Carousel:** slide count/order from model; Skip and each fork set `hasCompletedWelcome` and dismiss; first-launch presents, second launch does not.
- **`HelpWindow`:** sidebar topic list equals `index.json` order.
- **Manual smoke:** fresh launch → carousel → *Try a sample Novel* → edit a line → ⌘Q → relaunch (no carousel; sample in Recents; edit intact). Repeat fork via Help → Sample Projects. Open Maugham Help, page topics. Ask Claude "how do I use focus mode in Maugham?" → `get_help` answers from `editor-and-focus`.

## Build order

1. **Docs split** (`docs/guide/` + `index.json`, bundle, drift guard) — everything reads this.
2. **Help window + `GetHelpTool`** — first consumers; proves the source.
3. **Sample builder** — needed by the carousel's fork.
4. **Welcome carousel** — ties first-run together.
5. **README rewrite** — last; can reference the shipped guide.

## Open flag for the user

Real screenshots: deferred by design (option C). When desired, decide writer-captured vs computer-use; the carousel and README already carry image slots so it's a drop-in.
