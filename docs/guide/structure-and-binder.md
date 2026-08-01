# Structure & the Binder

The binder shows your manuscript structure. For a novel, that's parts and chapters; for a screenplay, scenes.

### The project row

The row at the top of the binder is the project itself. Select it the way you select a chapter, and the right-hand panes are about the whole project rather than one document. It's how you say "everything" — and it's still there when the binder is empty, so deleting your last chapter never leaves the window with nothing selected. It can't be renamed, dragged, or dropped on.

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
- **Links** — other documents you've explicitly linked to this one; add or remove from the **+** button.
- **Linked from** — backlinks: documents that wiki-link to this one.

Research association isn't shown here — see the Research mode (⌘⌥R) in [Inspector, Research & Outline](right-pane.md) for the research linked to (or automatically owned by) this document.

### Wiki links

Type `[[Chapter 2]]` in any document. Maugham renders it blue + underlined. Click to navigate. Rename Chapter 2 in the binder and the wiki links in other documents update automatically.

### Find

- **⌘F** — find within the current document (standard AppKit find bar; ⌘G next, ⌘⇧G previous).
- **⌘⌥F** — find across the whole project. Opens a panel with grouped results (per document), case-sensitive and whole-word toggles. Click a result to jump.
