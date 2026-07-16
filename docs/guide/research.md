# Research

The binder's **Research** segment is for everything that isn't manuscript: character sheets, location photos, PDFs, web links, voice notes.

- **New Text Note** — right-click + **New Text Note** to create a markdown note. Rename inline; the file on disk renames with it.
- **Drag in from Finder** — drop images, PDFs, audio, text files. They land in `research/`.
- **Paste an image** — Cmd-V into the research pane. Saved as `pasted-…png` next to your notes.
- **Add Link…** — paste a URL. Opens via WKWebView when clicked.

Click a research item to view it. Documents are editable in place. Images, PDFs, audio, and links use Maugham's preview renderers. Mark inline images in notes with `![alt](./image.png)` — ⌘⇧P toggles the preview pane.

### Organizing research

Groups nest — right-click + **New Group** to make a folder, drop items into it. In a Collection, both the shared research section and each piece's own research section render full nested trees the same way.

Select several items (⌘-click) to work on them together. Right-click a selection for **Move to ▸** (Shared, any group, or — in a Collection — any loose piece) and batch **Delete**. Dragging a row that's part of your selection moves the whole selection; drop it on a group to nest it there, or drop it in a different Collection section to move it between shared research and a piece's research folder. Moving into a piece drops any now-redundant explicit link; moving out restores one automatically so the association isn't lost.

### Capture inbox

Voice/text/photo captures from the iPhone companion app land in the Mac's capture inbox (⌘⌥6). Right-click an entry to promote it into research — three destinations:

- **Promote to Research** — shared project research, unscoped.
- **Promote to Research for "…"** — the currently active document; only appears when one's open and it's a valid target (a chapter in a novel, or a loose piece in a collection — not a referenced piece; in short-story and screenplay projects any open manuscript document qualifies, and promotion there files into shared research).
- **Promote to Research for…** — opens a picker to choose any chapter or collection piece.

Promoting into a collection piece drops the item straight into that piece's own research folder, where it shows up automatically under **Piece Research** — no separate linking step. Promoting into a novel chapter files it under shared research and links it to that chapter, so it shows up under **Linked** (see [Inspector, Research & Outline](right-pane.md)).

### Trash & undo

Deleting an item moves it to `.maugham/.trash/` (project-local, syncs with iCloud). ⌘⌥Z restores the most-recent deletion in place. A 30-day automatic sweep clears old entries on launch. See [ADR 0006](../adr/0006-trash-and-undo.md) for the design.

⌘Z is intentionally reserved for in-doc text undo; ⌘⌥Z is the binder-undo shortcut.
