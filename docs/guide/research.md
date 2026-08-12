# Research

The binder tree's **Research** section is for everything that isn't manuscript: character sheets, location photos, PDFs, web links, voice notes.

**It's in the tree, in every persona** — making research is a tree action wherever you're standing, not a trip to a particular persona. ⌘⌥R expands the tree's own **Research** section and scrolls it into view, rather than opening anything in the right column (it's a no-op while Find in Project covers the tree). There's no separate reading pane: the tree is the one place research is browsed, in every persona, and the same right-click menus and empty-state buttons work from Plan as anywhere else.

- **New Note** — right-click the Research section (or a group inside it) → **New Note** to create a markdown note. Rename inline; the file on disk renames with it.
- **Drag in from Finder** — drop images, PDFs, audio, text files. They land in `research/`.
- **Paste an image** — Cmd-V into the research pane. Saved as `pasted-…png` next to your notes.
- **Add Link…** — paste a URL. Opens via WKWebView when clicked.

Click a research item to view it. Documents are editable in place — except in Review, where every note and card opens read-only: you can look and select text, but not change it, because Review's job is adjudicating the manuscript rather than editing what's behind it. Switch to Author (⌘2) to make the change. Images, PDFs, audio, and links use Maugham's preview renderers. Mark inline images in notes with `![alt](./image.png)` — ⌘⇧P toggles the preview pane.

### Organizing research

Groups nest — right-click + **New Group** to make a folder, drop items into it. In a Collection, both the shared research section and each piece's own research section render full nested trees the same way. "Palette" is reserved for the shared root — it's the Palette section's own folder — so naming or renaming a top-level group to it is refused; a nested group can still be called Palette.

Select several items (⌘-click) to work on them together. Right-click a selection for **Move to ▸** (Shared, any group, or — in a Collection — any loose piece) and batch **Delete**. Dragging a row that's part of your selection moves the whole selection; drop it on a group to nest it there, or drop it in a different Collection section to move it between shared research and a piece's research folder. Scope moves leave your links alone: an item inside a piece is already associated by containment, so a link you added by hand goes quietly dormant while it lives there (Maugham just hides the now-redundant entry) and reappears as a link on that document if you move the item back out. An association that only ever came from containment ends when you move the item out — nothing is auto-linked in its place.

### Capture inbox

Voice/text/photo captures from the iPhone companion app land in the Mac's capture inbox (⌘⌥B). Right-click an entry to promote it into research — three destinations:

- **Promote to Research** — shared project research, unscoped.
- **Promote to Research for "…"** — the currently active document; only appears when one's open and it's a valid target (a chapter in a novel, or a loose piece in a collection — not a referenced piece; in short-story and screenplay projects any open manuscript document qualifies, and promotion there files into shared research).
- **Promote to Research for…** — opens a picker to choose any chapter or collection piece.

A capture can also go **straight to the planning canvas** instead — drag the row onto the canvas, or right-click → **Send to Canvas** — which is the shorter road when you don't yet know what the capture is. Promoting from the canvas afterwards makes the research note whenever you're ready for it. See [Getting Started → Sending a capture from the Inbox to the canvas](getting-started.md#sending-a-capture-from-the-inbox-to-the-canvas).

Promoting into a collection piece drops the item straight into that piece's own research folder, where it shows up automatically under that piece's fold in the tree — no separate linking step. Promoting into a novel chapter files it under shared research and links it to that chapter, so it shows up under that chapter's own (read-only) fold, drawn flat. You can link an existing shared item to a chapter yourself too, without promoting: drag its row from the tree's Research section onto the chapter's own row, or right-click the chapter and choose **Link Research…** for a searchable list with a toggle per item — the keyboard- and VoiceOver-reachable route to the same thing the drag does.

### Trash & undo

Deleting an item moves it to `.maugham/.trash/` (project-local, syncs with iCloud). ⌘⌥Z restores the most-recent deletion in place — the whole of it, whether that gesture deleted one row or fifty, or it tells you why it can't. A 30-day automatic sweep clears old entries on launch. See [ADR 0006](../adr/0006-trash-and-undo.md) for the design.

⌘Z is intentionally reserved for in-doc text undo; ⌘⌥Z is the binder-undo shortcut.
