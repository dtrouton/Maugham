# Maugham — Master Architecture Design

**Date:** 2026-05-07
**Status:** Draft v1, awaiting author review
**Scope:** Master architecture spec. Each phase below will get its own brainstorm → spec → plan → implementation cycle anchored on this document.

---

## Vision

Maugham is a focus text editor for serious creative writing on the Mac. It treats prose, novels, screenplays, and collections as first-class forms in a single coherent app. Files live as plain text on disk so they sync naturally through iCloud Drive and remain readable by other tools — including Claude desktop, which is the deliberate channel for AI-assisted feedback, research, and editing.

The app's design philosophy:

- **Files-as-truth.** The manuscript is plain text. The manifest coordinates structure. Nothing important is locked in a proprietary blob.
- **Polymorphic from day one.** All four project types (Short Story, Novel, Screenplay, Collection) are first-class in the data model from the first commit, even when their UI depth ramps up over phases.
- **Friction is a feature** at the AI boundary. Claude lives in another window — never inside the editor — so writing-mode and feedback-mode stay distinct.
- **Unglamorous correctness.** NSFileCoordinator, atomic writes, conflict preservation, debounced autosave. The user trusts their novel to this app.

---

## Locked-in foundations

| Foundation | Choice |
|---|---|
| Platform | Native macOS (macOS 14+), Swift + SwiftUI, TextKit 2 |
| Editor surface | NSTextView wrapped via `NSViewRepresentable` for control over caret, scrolling, and paragraph styles |
| Project depth | All four types polymorphic from day one; per-form depth ramps over phases |
| File format | `.md` for prose (CommonMark + smart typography), `.fountain` for screenplay |
| Project format | Folder on disk with `project.maugham.json` manifest (not a `.maugham` package bundle) |
| Sync | User-pickable folder location; default an iCloud Drive subfolder. NSFileCoordinator handles iCloud invisibly. |
| Manifest format | JSON with `schemaVersion` and forward-compatible unknown-field tolerance |
| Claude integration | Phase 1: Claude desktop reads the shared folder via its built-in filesystem MCP server. Phase 6: bundled custom MCP server for structural access. **No in-app AI panel ever.** |
| Trust model | Project folder is the unit of trust. No fine-grained permission UI. |
| Preferences | User-level in `~/Library/Preferences/com.maugham.app.plist`, with optional per-project overrides in `<project>/.maugham/preferences.json` |

---

## Section 1 — Project Model and File Format

A **Maugham project** is a folder on disk with a fixed internal layout and a `project.maugham.json` manifest at its root.

### Project types (all first-class)

| Type | Manuscript shape | Default extension |
|---|---|---|
| Short Story | Single file | `.md` |
| Novel | Multi-file: parts → chapters → scenes | `.md` |
| Screenplay | Single file or multi-file scenes | `.fountain` |
| Collection | References to other projects (or contains short story files) | `.md` |

### On-disk layout (Novel example)

```
MyNovel/
  project.maugham.json     # manifest: structure, order, metadata, settings
  manuscript/
    01-act-one/
      01-opening.md
      02-meeting.md
    02-act-two/
      01-the-call.md
  research/                # anything non-manuscript
    characters/
      larry-darrell.md
      larry-portrait.jpg
      isabel-1920s-ref.jpg
    locations/
      paris-flat.jpg
      mood-board.png
    sources/
      maugham-letter.pdf
  notes/
    todo.md
    ideas.md
  snapshots/               # phase 5
    2026-05-07T14-22-pre-rewrite.zip
  .maugham/                # app-private state: caches, indexes, ui-state.json
```

For a Short Story, the manuscript is a single `story.md` file at the root. For a Screenplay, it's `screenplay.fountain` or a `manuscript/` folder of `.fountain` scene files. The structure adapts to the type but the root manifest pattern is universal.

Subfolders inside `research/` are user-created — Maugham doesn't enforce names. A noir writer might have "Suspects" and "Crime Scenes"; a fantasy writer "Magic System" and "Houses." Flexibility beats opinion.

### The manifest — `project.maugham.json`

The source of truth for project-level facts the filesystem can't express on its own: ordering, hierarchy, synopses, status flags, word-count goals, compile settings, research metadata.

```json
{
  "schemaVersion": 1,
  "type": "novel",
  "title": "The Razor's Edge",
  "author": "Larry Darrell",
  "created": "2026-05-07T14:22:00Z",
  "modified": "2026-05-07T15:48:11Z",
  "structure": [
    {
      "id": "act-1",
      "title": "Act One",
      "type": "group",
      "children": [
        {
          "id": "ch-1",
          "title": "Opening",
          "type": "document",
          "path": "manuscript/01-act-one/01-opening.md",
          "synopsis": "Larry returns from the war.",
          "status": "draft",
          "wordTarget": 3000
        }
      ]
    }
  ],
  "research": [
    {
      "id": "characters",
      "title": "Characters",
      "type": "group",
      "children": [
        {
          "id": "larry",
          "title": "Larry Darrell",
          "type": "asset",
          "kind": "image",
          "path": "research/characters/larry-portrait.jpg",
          "caption": "Late 1920s, Paris, before India",
          "tags": ["protagonist"],
          "links": ["ch-1", "ch-7"]
        }
      ]
    }
  ],
  "targets": { "totalWords": 90000, "deadline": "2026-12-31" },
  "compile": {},
  "claudeContext": {}
}
```

The `compile` block is populated in phase 5 (compile presets, output formats, manuscript-format settings). The `claudeContext` block is populated in phase 6 (hints to the bundled MCP server about which paths are manuscript vs research, scene-level guidance). Phase 1 writes both as empty objects; older Maugham versions always treat unknown fields as opaque-and-preserved.

**Stable, append-only, forward-compatible.** `schemaVersion` plus tolerance for unknown fields means future versions of Maugham can read older manifests, and older versions ignore future fields rather than corrupting them.

### Asset model (research items)

| `kind` | What it is |
|---|---|
| `image` | Image file in `research/` (jpg, png, heic, gif) |
| `document` | Markdown / RTF / plain text |
| `pdf` | PDF file |
| `audio` | Audio file (mp3, m4a, wav) |
| `link` | URL bookmark, no on-disk file |
| `group` | Folder grouping with `children` |

Common metadata: `id`, `title`, `caption`, `tags`, `links` (to manuscript item IDs), `addedAt`. Images are file references, never base64-embedded — keeps manifests small and lets iCloud sync media efficiently.

### Why this shape

- **Files-as-truth, manifest-as-coordination.** The text you wrote is always recoverable even if the manifest is corrupted.
- **Portable.** Zip the folder, send it; anyone can read the prose with a text editor.
- **Claude-ready.** Claude desktop pointed at the folder sees the whole structure naturally with no special handling.
- **`.maugham/` for caches.** Regenerable; can be `.gitignore`d cleanly if writers version-control their projects.

---

## Section 2 — The Editor

### Architecture

```
        +-------------------------------------------------+
        |              EditorSurface (SwiftUI)             |
        |  Wraps NSTextView via NSViewRepresentable        |
        |  Owns: typography, theme, focus chrome,          |
        |         typewriter scroll, sentence/para focus   |
        +----------------+--------------------------------+
                         | delegates content rules to
                         v
        +-------------------------------------------------+
        |           WritingMode (Swift protocol)           |
        |   tokenize(text)                                 |
        |   handleEdit(range, replacement) -> EditAction   |
        |   handleSpecialKey(key) -> KeyAction             |
        |   metrics(text) -> EditorMetrics                 |
        |   styleFor(token, theme) -> Attributes           |
        |   completion(at: cursor) -> [Suggestion]?        |
        +----------------+--------------------------------+
                         | implemented by
          +--------------+--------------+
          v              v              v
     ProseMode      ScreenplayMode   NotesMode
     (Markdown)     (Fountain)       (Markdown,
                                      reduced chrome)
```

**One surface, many modes.** The surface is the part that's hard to get right — typography, focus chrome, NSTextView edge cases — so we build it once. Modes are smaller, focused, replaceable.

### Modes

**ProseMode (Markdown)**
- Tokenize markdown: headings, emphasis, links, blockquotes, lists
- Live-render `**bold**` as **bold** with the asterisks dimmed (iA-Writer-style visible-but-quiet syntax)
- Smart typography: `--` → em dash, `...` → ellipsis, straight quotes → curly
- Word count, character count, reading time
- No autocomplete in v1

**ScreenplayMode (Fountain)**
- Tokenize Fountain: scene heading, action, character, dialogue, parenthetical, transition, lyric, page break
- Auto-uppercase character names, sluglines, transitions
- Tab/Enter cycling: blank+Tab → Character; Character+Enter → Dialogue; Dialogue+Tab → Parenthetical
- Character autocomplete from prior usage in the file
- Page count (Fountain ≈ 1 minute per page; standard heuristic)
- Scene navigator (sluglines as a jump list)

**NotesMode**
- Same as ProseMode but with reduced chrome — no targets, no typewriter mode by default

### Focus mode features (built into the surface, mode-agnostic)

| Feature | Default | Sticky |
|---|---|---|
| Typewriter scrolling | Off | Yes |
| Sentence focus | Off | Yes |
| Paragraph focus | Off | Yes |
| No-chrome mode (`⌘\`) | Off | Per-window |
| Full-screen focus (`⌘⇧F`) | Off | Per-window |
| Theme (Light / Dark / Sepia) | System | Yes |
| Goal indicators | On | Yes |

Goal indicators are intentionally **quiet, not gamified**: a small unobtrusive readout, never a coercive progress bar. The author said "I don't want to be told what to write" — the same instinct applies to "you're 757 words below target."

### Typography

Default curated set (all included with macOS 14+ except where noted):

- **Iowan Old Style** — warm literary serif, default for prose
- **New York** — Apple's modern serif
- **Charter** — bundled with macOS, journalistic
- **JetBrains Mono** — for screenplay (monospace required for accurate page count)

User-configurable: font, size (12–24pt typical), line-height (1.4–2.0), page width (60–90 characters), paragraph spacing.

### File handling at the editor level

- The editor binds to a single document at a time via SwiftUI `Binding<String>`.
- Loading and saving go through the **DocumentStore** (Section 3); the editor never touches the filesystem.
- External changes (iCloud sync, Finder edit, Claude desktop saving) come in as published updates. The editor reconciles based on whether there are unsaved local edits.

### Phase delivery

| Phase | Editor capability |
|---|---|
| 1 | EditorSurface + ProseMode complete. ScreenplayMode stub (monospaced plain text, no parser). Typewriter scroll, sentence/paragraph focus, themes, typography all in. |
| 2 | Multi-document editing — switching between files in the binder without losing focus state. Word goals, session tracking. |
| 3 | ScreenplayMode full: Fountain parser, auto-format, Tab/Enter cycling, character autocomplete, scene navigator, page count. |
| 4 | Final Draft parity: scene numbers, dual dialogue, revisions, FDX import/export. |
| 5+ | Snapshots in editor (compare versions), Compile UI. |

---

## Section 3 — File Handling, iCloud, and Conflict Resolution

### The DocumentStore

```
                  Editor / UI
                       |
                       v
              +------------------+
              |  DocumentStore   |
              +--------+---------+
                       | owns
        +--------------+--------------+
        v              v              v
  ManifestActor  TextDocumentSet  AssetIndex
  (project.       (open .md /     (research
   maugham.json)   .fountain      files,
                   files)          lazy-loaded)
                       |
                       v
            NSFileCoordinator
                  +
            NSFilePresenter
                       |
                       v
              Filesystem (any
              folder, including
              iCloud Drive)
```

The DocumentStore is the **only** part of Maugham that touches the filesystem. The editor, binder, and focus chrome never know whether a file is local, iCloud, or on Dropbox.

### Why a single coordinator

NSFileCoordinator is Apple's machinery for "multiple processes might be touching this file." When iCloud syncs in a new version of a Markdown file the user is also editing, NSFileCoordinator + NSFilePresenter notifies us before bytes change under us. The same pattern protects against TextEdit, Claude desktop, or any other app touching the file.

We register the DocumentStore as the file presenter for the project folder. Any change — iCloud, another app, `mv` in a terminal — gets routed to us. We respond on a serial queue, never racing.

### Save model

- Autosave on a **750ms debounce** after last keystroke (configurable globally).
- Saves go through `NSFileCoordinator(filePresenter:)` so iCloud sees the change cleanly.
- Manifest writes are atomic: write to `project.maugham.json.tmp`, rename in place.
- ⌘S as a **dummy save** that triggers the autosave timer immediately and flashes "Saved" briefly in the title bar — psychological comfort, not new behavior.
- We never lose unsaved data on quit.

### Conflict resolution

**Case A — file changed externally while not actively editing.**
File presenter sees the change, the store reloads, the editor's binding updates. No drama.

**Case B — file changed externally while you have unsaved local edits.**
The store stops the autosave timer and presents a non-blocking notice in the editor:

> **Outside change detected.** Your version (143 words ahead) and the cloud version are different.
> [ Keep mine ] [ Use cloud ] [ Show diff ]

"Show diff" arrives in phase 2. Phase 1 ships Keep/Use only. We never silently overwrite either side; both are stored to `.maugham/conflicts/` until resolved.

**Case C — manifest conflict (rare).**
Last-writer-wins by `modified` timestamp; the loser is preserved as `.maugham/conflicts/manifest-<timestamp>.json` for inspection.

### Snapshots (phase 5)

Copy the file (or whole `manuscript/`) to `snapshots/<timestamp>-<label>.zip` with a small entry in the manifest. Plain filesystem; users could rummage through `snapshots/` in Finder.

### What doesn't go through the store

- Editor in-flight text — transient SwiftUI state.
- UI-only state (open file, scroll position, focus chrome on/off) — persisted to `.maugham/ui-state.json`, written by the store but logically separate from the manifest.

### Phase delivery

| Phase | Capability |
|---|---|
| 1 | Single-document store. NSFileCoordinator in place. Autosave + ⌘S dummy save. Conflict notice with Keep/Use. |
| 2 | Multi-document handling for novel projects. Manifest reads/writes through the store. Diff view for conflicts. |
| 3 | Same store, screenplay files added (just another extension). |
| 4 | — |
| 5 | Snapshots. |

---

## Section 4 — App Shell, Window, and Project Navigation

### Window layout (three-pane `NavigationSplitView`)

```
+-- Maugham — The Razor's Edge ------------------------------------+
|  +------- Binder ------+ +------- Editor ------+ +-- Inspector -+|
|  | v Manuscript        | |                     | | Synopsis     ||
|  |   v Act One         | |  Chapter 1          | | -----------  ||
|  |     . Opening    *  | |                     | | Larry returns||
|  |     . Meeting       | |  Larry returned     | | from the war.||
|  |   > Act Two         | |  to Chicago in      | |              ||
|  | v Research          | |  the spring of      | | Status: Draft||
|  |   v Characters      | |  1919...            | | Tags: opening||
|  |     . Larry         | |                     | | Goal: 3,000  ||
|  |     . Isabel        | |                     | | Words: 1,243 ||
|  |   v Locations       | |                     | |              ||
|  |     . Paris flat    | |                     | |              ||
|  | v Notes             | |                     | |              ||
|  +---------------------+ +---------------------+ +--------------+|
|  v status: 1,243 words · 3,000 target · saved · ⌘\ to focus      |
+------------------------------------------------------------------+
```

| Pane | Toggle | Default for project type |
|---|---|---|
| Binder | ⌘1 | Visible (Novel, Screenplay, Collection); hidden (Short Story) |
| Inspector | ⌘3 | Visible |
| Status bar | ⌘/ | Visible |

### Focus mode (the most important UI state)

`⌘\` collapses every pane and toolbar — text on a configurable page width, centered. ESC restores. `⌘⇧F` adds full-screen.

The principle: writing posture in one keystroke, recovery in one keystroke.

### The binder

Per project type:

- **Novel** — Manuscript tree (Acts → Chapters → Scenes), Research, Notes, Snapshots as parallel sections.
- **Short Story** — Single document plus research/notes folders. Often hidden by default.
- **Screenplay** — Scenes (sluglines from `.fountain` in phase 3+) plus research and notes.
- **Collection** — Included stories (references to other Maugham project folders or contained `.md` files) plus shared research.

Drag-drop reorders structure (writes to manifest). Right-click menu: rename, duplicate, delete-to-trash, snapshot.

### The inspector

Per-document metadata for the open file. Phase 1 ships minimal: synopsis + status + word count. Tags, links, per-document targets fill in over phases 2–4.

### Project lifecycle

```
        First launch
              |
              v
       +--------------+
       |  Welcome     |  "Create new project" / "Open project" /
       |  window      |  "Open recent" + tutorial project link
       +------+-------+
              |
              v "New project"
       +--------------+
       |  Project     |  Pick: Short Story / Novel / Screenplay / Collection
       |  type        |  Pick: name + folder location
       |  chooser     |  --> creates folder, manifest, opens project window
       +------+-------+
              |
              v
       +--------------+
       |  Project     |  Three-pane window. Binder + Editor + Inspector.
       |  window      |  Closes --> cleanly closes file presenters,
       +--------------+  releases iCloud coordinator.
```

Multiple project windows open simultaneously, each independent.

### Project type is immutable after creation

You can't convert a Short Story into a Novel later. If your short story turns into a novel, "new novel project, drag old story in" is cleaner than coercing types.

### Menu structure (essentials)

- **File**: New Project, Open Project (folder picker), Open Recent, Close, Save (dummy flash), Compile (phase 5), Print
- **Edit**: standard, plus Find/Replace
- **View**: Toggle Binder ⌘1, Toggle Inspector ⌘3, Focus Mode ⌘\, Full-Screen Focus ⌘⇧F, Theme ▸
- **Format**: Typography, Paragraph, Smart Quotes toggle
- **Project**: Snapshot, Statistics, Project Settings…, Show in Finder
- **Tools**: phase 6 — Configure Claude Desktop…
- **Window**: standard
- **Help**: Set up Claude desktop (instructions), About, Release Notes

### Native macOS behavior we get for free

Versions / Time Machine, Quick Look, Spotlight indexing, Stage Manager / Spaces, Continuity Camera, Markup, Sidecar with iPad — all of these work on plain text files without special handling.

### Phase delivery

| Phase | Shell capability |
|---|---|
| 1 | Three-pane window. Binder works for short stories (mostly invisible) and basic novels (manuscript only). Inspector minimal. Focus mode works. Welcome window. |
| 2 | Binder full for novels: drag-reorder, right-click menu, status indicators, research section visible. |
| 3 | Binder for screenplays: scene navigator generated from sluglines. |
| 4 | Inspector grows: tags, links, references-to. |
| 5 | Compile flow, project statistics. |
| 6 | "Configure Claude Desktop" menu item. |

---

## Section 5 — Claude Integration Architecture

### Phase 1 — Shared folder, zero new code

```
   +--------------+         +------------------+
   |   Maugham    |  writes |  iCloud Drive    |
   |   .app       | ------> |  /Maugham/       |
   +--------------+         |   MyNovel/       |
                            |     manuscript/  |
                            |     research/    |
                            +---------+--------+
                                      | reads
                                      v
                            +------------------+
                            | Claude desktop   |
                            | (filesystem MCP  |
                            |  pointed at      |
                            |  /Maugham/)      |
                            +------------------+
```

**What ships in phase 1 from Maugham:** nothing in the binary itself. The user configures Claude desktop's built-in filesystem MCP server to point at their Maugham folder.

**What Maugham does ship:** a Help → "Set up Claude desktop" menu item that opens documentation explaining the one-time configuration. We can't write Claude desktop's config for them; it's their app, not ours, and that boundary is correct.

### Phase 6 — Bundled MCP server

```
   +--------------------------+
   |   Maugham.app            |
   |   |__ Maugham binary     |
   |   |__ Resources/         |
   |       |__ maugham-mcp    |  bundled MCP server executable
   |                              (separate Swift binary)
   +-----------+--------------+
               | launched by Claude desktop
               v
   +--------------------------+         +---------------------+
   |  maugham-mcp (stdio)     | reads   |  ~/iCloud/Maugham/  |
   |  Tools exposed:          | <-----> |   project folders   |
   |   . list_projects        |         +---------------------+
   |   . open_project         |
   |   . get_outline          |
   |   . read_document        |
   |   . search_text          |
   |   . list_scenes          |
   |   . find_references      |
   |   . get_metadata         |
   |   . get_session_stats    |
   +--------------------------+
```

Phase 6 deliverables:

- A separate Swift executable, `maugham-mcp`, bundled inside `Maugham.app/Contents/Resources/`.
- A "Configure Claude Desktop…" menu item that writes the right entry into `~/Library/Application Support/Claude/mcp.json`.
- The MCP server reads the same project folders Maugham writes. Maugham doesn't have to be running.

### Architectural choices

- **No in-app AI panel ever.** Friction between writing and feedback is preserved by design.
- **MCP server reads only.** Claude can read manuscript; only the writer writes. Optional `add_note(scene_id)` may be allowed as an exception (writes go to `notes/`, never to manuscript).
- **No fine-grained permission UI.** Project folder is the unit of trust — confirmed by the author. If something shouldn't be visible, it doesn't go in the project folder.
- **Maugham binary has no Anthropic SDK and no API key handling.** Token spend, rate limits, model selection — all stay in Claude desktop.

---

## Section 6 — Phase Roadmap

### Phase 1 — Foundation + Short Story (writeable v1)

**Goal:** A working Mac app you can write a short story in, with iCloud sync and Claude desktop reading the files. The smallest deliverable that lets you abandon other tools for short fiction.

**Deliverables:**
- Mac app, signed, runs on macOS 14+
- `EditorSurface` + `ProseMode` (Markdown), with smart typography, themes (light/dark/sepia), curated fonts, configurable typography
- Focus mode (⌘\), full-screen focus (⌘⇧F), typewriter scroll + sentence/paragraph focus (sticky, default off)
- Goal indicators (sticky, default on) — quiet metrics, not gamified
- DocumentStore with NSFileCoordinator + NSFilePresenter; autosave + ⌘S dummy save
- Conflict resolution (Keep / Use cloud)
- Project type: **Short Story** — single-file project, minimal binder
- Project type: **Novel** — basic skeleton (manuscript folder, manifest), text-only binder navigation, no drag-reorder yet
- Project type: **Screenplay stub** — opens `.fountain` files as monospace plain text, no parser yet
- Project type: **Collection stub** — placeholder type
- Welcome window, New Project flow, Open Recent
- Inspector minimal (synopsis + word count)
- Help → "Set up Claude desktop" instructions

**Out of phase 1:** Fountain parser, drag-reorder in binder, snapshots, compile, FDX, MCP server, screenplay autocomplete, advanced inspector, conflict diff view.

### Phase 2 — Novel Project Depth

**Goal:** A novelist's working environment.

- Binder: drag-reorder, right-click menu, status indicators
- Research section: show files in `research/`, basic preview pane for images and PDFs
- Inspector grows: tags, status, word target per document
- Session stats (words this session, today vs target)
- Conflict-resolution diff view
- Multi-document editor: switch between docs without losing focus state
- Project Statistics window

### Phase 3 — Screenplay (Fountain Depth)

**Goal:** A working Highland-equivalent for first drafts.

- `ScreenplayMode` complete: Fountain tokenizer, live formatting, auto-uppercase
- Tab/Enter cycling for screenplay element entry
- Character autocomplete from prior usage
- Scene navigator generated from sluglines
- Page count estimation
- Multi-file screenplay projects (one file per scene optionally)
- Title page support

### Phase 4 — Final Draft Parity + Research Tagging

**Goal:** Production-readiness for screenplays plus research/character tagging.

- FDX export and import
- Scene numbers, dual dialogue, MORE/CONT'D markers, transitions
- Revisions (color-coded change marks per draft)
- Research tagging: links between research items and manuscript items
- Drag-drop images from web/Finder into research, manifest auto-populates
- Inspector shows linked research for current document

### Phase 5 — Scrivener Parity

**Goal:** Snapshots, compile, the long-haul novelist's tools.

- Snapshots (versioned manuscript saves with labels)
- Compile UI: assemble manuscript into a single export — manuscript-format Word, EPUB, PDF, plain text
- Corkboard view: index-card style synopses for binder items
- Outliner view: synopses + status + word counts in a table
- Project templates (Three-Act Novel, Short Story, Hero's Journey, etc.)

### Phase 6 — MCP Server + Claude Integration Depth

**Goal:** Claude understands your project, not just your files.

- `maugham-mcp` bundled binary
- "Configure Claude desktop" menu item
- MCP tools: `list_projects`, `get_outline`, `read_document`, `search_text`, `list_scenes`, `find_references`, `get_metadata`, `get_session_stats`
- Optional `add_note(scene_id)` so Claude can drop notes into `notes/` (read-only on manuscript)
- Documentation for prompt patterns

### Beyond phase 6 (speculative)

- iPad companion (read-only first, then drafting)
- Shared folder collaboration (writing partner, editor)
- Voice notes / audio drafting (Whisper-based transcription)
- Goal-tracking Calendar widget
- Inline character/place autocomplete in prose mode
- **Handwritten draft import.** Drag-drop photos of handwritten pages into Maugham; they're transcribed to `.md` files using phone-camera filenames (timestamps, sequence numbers) as ordering hints, with Claude doing the multimodal transcription. Lets the writer move freely between pen-and-paper and digital. **Already possible today** as a Claude desktop workflow (drop images in `research/handwritten/`, ask Claude desktop to transcribe and order); the phase-7+ work is a dedicated import pane with live progress, page-by-page accept/edit/reject, and automatic placement into the manuscript structure.

Each gets its own brainstorm if and when we go there.

### Phase dependencies

```
Phase 1  -->  Phase 2  -->  Phase 3  -->  Phase 4
  |             |             ^              ^
  v             v             |              |
(every later phase depends on Phase 1 foundations)
                |             |              |
                v             |              |
             Phase 5  <-------+              |
                |                            |
                v                            |
             Phase 6  <----------------------+
             (needs project structure mature
              enough to be worth exposing)
```

Phase 2 is the gate to almost everything else. Phase 1 can ship and be useful for short stories alone, even if you never went further.

---

## Open architectural decisions deferred

Architectural questions the spec doesn't resolve, flagged for later phase brainstorms (these are not blockers for phase 1):

- **Custom themes.** Phase 1 ships Light/Dark/Sepia. Whether to allow user-defined themes, and the file format (TOML? JSON? a Swift bundle?), is a phase-2-ish decision.
- **iCloud quota strategy for heavy media.** Writers with hundreds of high-res research images can hit iCloud quota. Whether to support "store images locally only" or lazy-evict thumbnails is a phase 4 brainstorm.
- **Project template catalog format.** Phase 5 introduces project templates ("Three-Act Novel," "Hero's Journey"). The on-disk format for a template, and whether templates are user-authorable, is a phase-5 brainstorm.
- **Collection cross-references and security-scoped URLs.** Collections can reference other Maugham project folders. macOS security-scoped bookmark persistence (so the references survive sandbox restrictions across launches) needs care; deferred to the Collection-focus phase.
- **Print formatting.** Phase 1 inherits macOS default print behavior. A real manuscript-format print dialog (12pt Courier double-spaced, header info, page numbers) is part of Compile in phase 5.

---

## Appendix — The shape of subsequent specs

Each phase will produce its own design document in `docs/superpowers/specs/`, named `YYYY-MM-DD-maugham-phase-<n>-<focus>-design.md`. Each phase spec answers:

1. What does this phase deliver, in concrete user-visible terms?
2. What new code modules or refactors does it require?
3. What does it change in the manifest schema (if anything)?
4. What testing strategy applies (unit / snapshot / UI)?
5. What's the rollout — single milestone, or multiple sub-milestones?

Phase specs will reference back to this master document for architectural context and will not re-derive locked-in foundations.
