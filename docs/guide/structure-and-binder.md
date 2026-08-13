# Structure & the Binder

The binder shows your manuscript structure. For a novel, that's parts and chapters; for a screenplay, scenes.

### The project row

The row at the top of the binder is the project itself. Select it the way you select a chapter, and the right-hand panes are about the whole project rather than one document. It's how you say "everything" — and it's still there when the binder is empty, so deleting your last chapter never leaves the window with nothing selected. It can't be renamed, dragged, or dropped on.

**In Author, Review, and Publish, selecting it also zooms the centre column out.** Instead of the editor's "Select a document" placeholder, the centre fills with a corkboard or table of every chapter — the same view a **group** row shows too. Toggle between corkboard and table with the small picker at the top; the choice persists per project. Click a card or a table row and that chapter opens in the editor, in the same place. ⌘⌥O selects the project row from anywhere, which is the fastest way there. In Plan the project row does none of this — Plan's centre column is always the planning canvas.

**Publish is the exception, once you've compiled something.** The moment a PDF exists in `Exports/`, Publish's centre column shows it instead — for the project row, a chapter, or a group alike, because reviewing the finished book doesn't depend on which part of the tree you're standing on. Selecting the project row (⌘⌥O) still gets you there fastest, but clicking a card or a table row does nothing further, since it's the same book either way. Nothing compiled yet? Publish looks exactly like Author and Review, above. See [Publishing → The Publish persona's centre column](publishing.md#the-publish-personas-centre-column).

A **Collection** has the same row at the top of its Pieces list, and there it matters from the first moment: a new Collection starts with no pieces at all, and the project row is what you select to write the collection's own intent before there is anything to put in it.

A **screenplay** has it too, at the top of the Scenes list, and directly beneath it a row called **Script**. A screenplay is one file, so those two rows are the whole binder — the project, then the project's one document — and the sluglines below them are jumps around that document rather than documents of their own. The two rows are what you *select*; the sluglines are what you *jump to*. Select **Script** any time to bring the screenplay back on screen, including on a brand-new screenplay that has no sluglines yet. Click a slugline afterwards and you're back on the script too; the first click after leaving the project row lands you in the screenplay rather than on that scene, because the editor is coming back on screen — click it again and it jumps. The project row is there before you've written a single INT. or EXT., which is when a screenplay's own intent is most worth writing down.

### From Plan to Author

Plan's tree is the same tree everywhere else, but its centre column is always the planning canvas — a chapter, a research note, or a palette card has nowhere to open there. **Double-click any row and Maugham takes you to Author with it open** — a structure row, the project row, a research or palette row, even a screenplay's **Script** row. ⌘1 brings you straight back to Plan, right where you left it. The same double-click does nothing extra outside Plan, since a single click there already puts you where you're going. The Palette section's **Open Wall** door travels the same way — see [Getting Started → Personas](getting-started.md#personas).

### Adding items

Right-click a row in the binder:

- **New Document** — adds a sibling document; rename it inline.
- **New Group** — adds a folder (e.g., "Act One"). Drag chapters into it.
- **Duplicate** — copies the document or group with fresh IDs.
- **Delete** — moves to Maugham's project-local Trash (see below).

You can do all of that from **Plan** as well. Plan's left column is this very tree, with the planning canvas still in the middle, and it carries the same right-click menus and the same empty-binder buttons.

**A screenplay is the exception, deliberately.** A screenplay is one file, so there is nothing to add to its tree: its structure is its sluglines, and you type those in the script itself. Its tree offers no New Document and no New Scene, in Plan or anywhere else — select **Script** (or ⌘2 for Author) and write the scene heading.

Plan's tree lists a screenplay's sluglines the same way it does everywhere else, and it does it from the moment you open the window — you don't have to visit Author first to make them appear. Selecting the project row or the **Script** row keeps you in Plan. Clicking a **slugline** does not: a slugline is a jump into the script itself, so it takes you to **Author**, where the script is on screen. As above, that first click lands you in the screenplay rather than on that scene, because the editor is arriving at the same moment — click the slugline again and it jumps.

Drag items to reorder. Move chapters between groups; folders physically move on disk. Filenames keep an `NN-` prefix so the on-disk order matches the binder order.

If gaps appear in numbering after deletes, **Tidy Filenames** (right-click a group, or File → Tidy All Filenames) renumbers cleanly.

### The Inspector

Click an item to see its metadata:

- **Synopsis** — short summary. Shows in the project's corkboard/table view (see [The project row](#the-project-row) above).
- **Status** — Draft / Revising / Final, surfaced as a colored dot in the binder.
- **Tags** — comma-separated. Search by tag via Claude Desktop's `list_documents_by_tag` tool.
- **Word target** — per-document goal. Drives the bottom-right goal capsule.
- **Links** — other documents you've explicitly linked to this one; add or remove from the **+** button.
- **Linked from** — backlinks: documents that wiki-link to this one.

Research association isn't shown here — the tree's own fold under this document (and its Research section, ⌘⌥R) shows the research linked to it, or automatically owned by it. See [Research](research.md).

### Wiki links

Type `[[Chapter 2]]` in any document. Maugham renders it blue + underlined. Click to navigate. Rename Chapter 2 in the binder and the wiki links in other documents update automatically.

Following a link to a manuscript document from **Plan** takes you to Author with it, because reading and writing the manuscript is Author's job. ⌘1 brings you straight back to where you left Plan.

### Find

- **⌘F** — find within the current document (standard AppKit find bar; ⌘G next, ⌘⇧G previous).
- **⌘⌥F** — find across the whole project. The search panel takes over the left column, with grouped results (per document), case-sensitive and whole-word toggles. Click a result to jump: a manuscript hit opens the document, a research hit opens the note. **Escape** or the ✕ closes it, and the column you were in comes straight back — nothing moves while the panel is up.
