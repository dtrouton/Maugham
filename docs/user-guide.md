# Maugham — User Guide

Maugham is a focus text editor for serious creative writing on macOS. It treats prose, novels, screenplays, and collections as first-class forms. Files live as plain text on disk — they sync naturally through iCloud Drive and remain readable by other tools, including Claude Desktop.

This guide assumes you've installed Maugham and can run it.

---

## Getting started

When you launch Maugham, you'll see the Welcome window with two options: **New Project…** and **Open Recent**. Click **New Project…**.

You'll be asked to pick a project type:

- **Short Story** — a single `.md` file. Simplest shape; best for one-sitting drafts.
- **Novel** — multi-file: parts → chapters → scenes. The binder navigates the structure.
- **Screenplay** — `.fountain` files. Maugham parses Fountain syntax (slug lines, character names, dialogue, parentheticals) and shows them in the scene navigator.
- **Collection** — a project that references other projects. Useful for short-fiction collections.

Pick a type, give the project a name, choose a folder (iCloud Drive is the default — sync just works), and click **Create**.

The project opens in a three-pane window:

- **Binder** (left) — the project structure (manuscript / research / find / trash). Drag-reorder items, right-click for menus.
- **Editor** (center) — the prose surface.
- **Inspector** (right) — metadata for the selected item (synopsis, status, tags, word target, linked research).

Type a sentence. Quit Maugham (⌘Q). Relaunch. Your project is in Open Recent, and your sentence is still there. That's the autosave-and-iCloud loop you'll rely on every day.

---

## The editor

Maugham's editor is a centered ~70-character column with gutters on either side. The column width comes from the typography setting; the gutters are theme-colored.

### Themes and typography

Open **Settings** (⌘,):

- **Theme** — Light, Dark, Sepia, or Follow System. Sepia is paper-yellow; useful in low light.
- **Typography** — font family (curated for prose: Iowan Old Style, New York, Charter, etc.), size, line height, paragraph spacing. Changes apply live.
- **Per-project typography** — `⌘⇧,` opens Project Settings. Override typography just for this project (e.g., a screenplay should use Courier; a novel might use a serif at 17pt). Settings persist across launches.

### Focus features

Maugham is built for focused writing sessions. The chrome gets out of your way.

- **⌘\\ — Toggle focus mode.** Hides the title bar and toolbar; just text and gutters.
- **⌘⇧F — Toggle full-screen focus.** Enters full-screen with no chrome.
- **Typewriter scrolling** (Settings → Editor → Focus) — keeps the active line at the vertical center of the viewport as you type.
- **Sentence focus** — only the current sentence is full color; the rest dims. Forces you forward.
- **Paragraph focus** — same idea, paragraph granularity.

These are sticky preferences; once you find your set, they stay.

### Smart typography

As you type, Maugham quietly fixes things:

- `--` becomes an em-dash `—`
- `...` becomes an ellipsis `…`
- Straight quotes `"like this"` become smart quotes `“like this”`

The underlying file still contains the smart characters; nothing is lost on save.

### Goals and word count

The bottom-right of the editor shows a goal capsule: today's word count, document word count, reading time. If you set a word target on a document in the Inspector, the capsule shows progress.

⌘S triggers a "Saved" flash. Autosave already runs every 750ms; the flash is muscle memory.

---

## Working with the manuscript

The binder shows your manuscript structure. For a novel, that's parts and chapters; for a screenplay, scenes.

### Adding items

Right-click a row in the binder:

- **New Document** — adds a sibling document; rename it inline.
- **New Group** — adds a folder (e.g., "Act One"). Drag chapters into it.
- **Duplicate** — copies the document or group with fresh IDs.
- **Delete** — moves to Maugham's project-local Trash (see below).

Drag items to reorder. Move chapters between groups; folders physically move on disk. Filenames keep an `NN-` prefix so the on-disk order matches the binder order.

If gaps appear in numbering after deletes, **Tidy Filenames** (right-click a group, or File → Tidy All Filenames) renumbers cleanly.

### The Inspector

Click an item to see its metadata:

- **Synopsis** — short summary. Shows in the Outline view (see Right pane below).
- **Status** — Draft / Revising / Final, surfaced as a colored dot in the binder.
- **Tags** — comma-separated. Search by tag via Claude Desktop's `list_documents_by_tag` tool.
- **Word target** — per-document goal. Drives the bottom-right goal capsule.
- **Linked research** — research items linked to this document (see Research below).
- **Linked from** — backlinks: documents that wiki-link to this one.

### Wiki links

Type `[[Chapter 2]]` in any document. Maugham renders it blue + underlined. Click to navigate. Rename Chapter 2 in the binder and the wiki links in other documents update automatically.

### Find

- **⌘F** — find within the current document (standard AppKit find bar; ⌘G next, ⌘⇧G previous).
- **⌘⌥F** — find across the whole project. Opens a panel with grouped results (per document), case-sensitive and whole-word toggles. Click a result to jump.

---

## The right pane: Inspector, Research, Outline

The right column has three modes. Switch with ⌘⌥1 / ⌘⌥2 / ⌘⌥3, or with the small picker at the top of the pane.

### Inspector mode (⌘⌥1)

Default. Shows metadata for whatever's selected in the binder.

### Research mode (⌘⌥2)

Shows research items linked to the current manuscript document. Click a linked item → the pane swaps to a read-only Markdown preview of that research note, side-by-side with your editor. Back chevron returns to the list.

Link new research either by **dragging** from the binder's Research segment onto this pane, or via the **+** button (opens a picker sheet).

Unlink: × on the row.

### Outline mode (⌘⌥3)

Either a **table** view (Title / Status / Synopsis / Words) or a **cards** view (corkboard with synopses). Toggle between the two with the small picker in the pane header. Click a row or card → editor jumps to that document.

Layout choice persists per project.

⌘⌥I toggles the whole right pane visibility.

---

## Research

The binder's **Research** segment is for everything that isn't manuscript: character sheets, location photos, PDFs, web links, voice notes.

- **New Text Note** — right-click + **New Text Note** to create a markdown note. Rename inline; the file on disk renames with it.
- **Drag in from Finder** — drop images, PDFs, audio, text files. They land in `research/`.
- **Paste an image** — Cmd-V into the research pane. Saved as `pasted-…png` next to your notes.
- **Add Link…** — paste a URL. Opens via WKWebView when clicked.

Click a research item to view it. Documents are editable in place. Images, PDFs, audio, and links use Maugham's preview renderers. Mark inline images in notes with `![alt](./image.png)` — ⌘⇧P toggles the preview pane.

### Trash & undo

Deleting an item moves it to `.maugham/.trash/` (project-local, syncs with iCloud). ⌘⌥Z restores the most-recent deletion in place. A 30-day automatic sweep clears old entries on launch. See [ADR 0006](adr/0006-trash-and-undo.md) for the design.

⌘Z is intentionally reserved for in-doc text undo; ⌘⌥Z is the binder-undo shortcut.

---

## Screenplay mode

Open a Screenplay project. Maugham parses Fountain as you type:

- **Slug lines** — `INT. KITCHEN - DAY` → recognized as a scene heading, uppercased, styled distinctly. Appears in the scene navigator.
- **Characters** — `SARAH` on its own line → recognized as a character cue.
- **Dialogue** — the lines after a character cue.
- **Parentheticals** — `(quietly)` → recognized and styled.
- **Transitions** — `FADE OUT:`, `CUT TO:` → right-aligned.

**Tab and Shift+Tab** cycle the current line through element types if Fountain's prefix-recognition didn't catch what you meant. A faint element label in the gutter shows what Maugham thinks you're writing.

### Scene navigator

The binder's Scenes segment shows every slug line in the screenplay, with the page number each one starts on. Click to scroll.

### Page count

Maugham uses Final Draft's wrap heuristic (60-char action lines, 35-char dialogue, 20-char parenthetical, 55 lines per page). The page count shows in the goal capsule. Set a page target in Project Settings for a screenplay.

### Title page

Add a title page block at the top of the file (Fountain syntax: `Title: My Script` etc.). Maugham styles it.

### Syntax help

⌘/ opens the syntax reference sheet — three tabs: Markdown, Fountain, Keyboard shortcuts. The Keyboard tab is also where you find the full list of shortcuts grouped by category.

---

## Claude Desktop integration

Maugham ships a local MCP server. Once configured, Claude Desktop can read your projects and create research notes for you.

### One-time setup

1. Install Claude Desktop (claude.ai/download).
2. Open Maugham. **Help → Set up Claude Desktop…**
3. Click **Configure**. Maugham writes a small entry into Claude Desktop's config.
4. Restart Claude Desktop.

That's it. You can test by asking Claude: *"What Maugham projects are open?"*

### What Claude can do

Read:
- List open projects, outlines, and chapters
- Read documents (live in-memory — Claude sees text you haven't saved yet)
- Search across manuscript
- Discover research items by enumeration or title
- List the reference graph (wiki links + linked research backrefs)
- Read your session stats ("how much have I written this week?")
- Filter chapters by tag

Write:
- Create research notes ("Claude, write me a character sheet for Sarah based on what you see in Chapter 1")
- Link research notes to chapters
- Unlink as needed

Claude can't write to your manuscript directly. That's intentional — the manuscript surface stays uncontested. A future milestone will design the manuscript-edit proposal flow ("Claude, draft a fix for this scene" → a non-destructive proposal you review).

### When Claude adds a research note

A small banner appears at the top of the editor pane: *"Claude added 'Sarah Voice' to research."* Click **Show** to jump to the note. The banner auto-dismisses after 8 seconds.

### Turning it off

Settings → General → **Allow Claude to connect (MCP)**. Toggle off; Claude gets a polite "MCP is turned off in Settings" error and you can re-enable any time. The MCP server also stops when Maugham isn't running (it's not a background process).

---

## Keyboard shortcuts

The full list lives in the in-app cheatsheet: **⌘/** → Keyboard tab.

The ones you'll use most:

| | |
|---|---|
| `⌘N` | New project |
| `⌘O` | Open project |
| `⌘S` | Save flash (autosave is automatic) |
| `⌘,` | Settings |
| `⌘⇧,` | Project Settings |
| `⌘F` | Find in editor |
| `⌘G` / `⌘⇧G` | Find next / previous |
| `⌘⌥F` | Find in project |
| `⌘⌥Z` | Restore last deleted item |
| `⌘\\` | Toggle focus mode |
| `⌘⇧F` | Toggle full-screen focus |
| `⌘⌥I` | Toggle Inspector pane |
| `⌘⌥1` / `⌘⌥2` / `⌘⌥3` | Right pane: Inspector / Linked Research / Outline |
| `⌘⇧P` | Toggle Research preview |
| `⌘/` | Syntax + keyboard reference |

---

## On-disk layout

Every Maugham project is a folder. You can open it in Finder and see:

```
My Novel/
├── project.maugham.json    # the manifest — structure, metadata
├── manuscript/             # your prose lives here
│   ├── 01-chapter-1.md
│   ├── 02-act-one/         # groups are folders
│   │   ├── 01-scene-1.md
│   │   └── 02-scene-2.md
│   └── 03-chapter-2.md
├── research/               # everything that isn't manuscript
│   ├── sarah.md
│   ├── locations.pdf
│   └── pasted-2026-05-10.png
├── notes/                  # for Claude-authored notes (future use)
└── .maugham/               # project-internal state
    ├── ui-state.json       # selected doc, scroll position, etc.
    ├── sessions.json       # session log for stats
    ├── conflicts/          # iCloud conflict archives
    └── .trash/             # restorable deletes
```

Everything important is plain text. The manifest coordinates structure; the files themselves are readable in any text editor. iCloud handles the sync invisibly via `NSFileCoordinator`.

The on-disk filenames have a numeric prefix (`01-chapter-1.md`) so manuscripts sort correctly in Finder. **Tidy All Filenames** (File menu) renumbers any sequence with gaps.

---

## Troubleshooting

**Maugham doesn't autosave my latest edit.** Autosave debounces at 750ms — if you quit within that window, an explicit ⌘S flushes any pending writes immediately.

**A document I had open is now showing different text.** iCloud detected an outside change (e.g., from another Mac). A banner offers Keep mine / Use cloud. The losing version is archived under `.maugham/conflicts/`.

**Claude says "Maugham isn't running."** It isn't — open the app. The MCP server only runs while Maugham is alive.

**Claude says "That project isn't open in Maugham."** Open the project. MCP only sees currently-open windows; closed projects aren't reachable.

**Claude says "Maugham's MCP connection is turned off in Settings."** Settings → General → **Allow Claude to connect (MCP)** → toggle on.

**The Set up Claude Desktop sheet says "configured" before I restart.** That just means the config file is written. Restart Claude Desktop to actually pick up the new server.

**My screenplay's page count looks off.** Maugham uses Final Draft's wrap heuristic. If you're using a non-monospace screen font, the on-screen layout may not match the printed page count.

**A binder item I deleted is gone forever.** Try ⌘⌥Z — it restores the most-recent deletion. If you've moved on since, look in `.maugham/.trash/` directly; entries live for 30 days.
