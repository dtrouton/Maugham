# Research

The binder tree's **Research** section is for everything that isn't manuscript: character sheets, location photos, PDFs, web links, voice notes.

**It's in the tree, in every persona** — making research is a tree action wherever you're standing, not a trip to a particular persona. ⌘⌥R expands the tree's own **Research** section and scrolls it into view, rather than opening anything in the right column (it's a no-op while Find in Project covers the tree). There's no separate reading pane: the tree is the one place research is browsed, in every persona, and the same right-click menus and empty-state buttons work from Plan as anywhere else.

- **New Note** — right-click the Research section (or a group inside it) → **New Note** to create a markdown note. Rename inline; the file on disk renames with it.
- **New Table** — the same menus offer **New Table**: a blank table of three columns, a header row and three empty rows, named "Untitled Table". Rename it inline; it opens in the table grid. Not offered in Review or on a view-only share.
- **Drag in from Finder** — drop images, PDFs, audio, text files. They land in `research/`.
- **Paste an image** — Cmd-V into the research pane. Saved as `pasted-…png` next to your notes.
- **Add Link…** — paste a URL. Opens via WKWebView when clicked.

Click a research item to view it. Documents are editable in place — except in Review, where every note and card opens read-only: you can look and select text, but not change it, because Review's job is adjudicating the manuscript rather than editing what's behind it. Switch to Author (⌘2) to make the change. Images, PDFs, audio, and links use Maugham's preview renderers. Mark inline images in notes with `![alt](./image.png)` — ⌘⇧P toggles the preview pane.

### Organizing research

Groups nest — right-click + **New Group** to make a folder, drop items into it. In a Collection, both the shared research section and each piece's own research section render full nested trees the same way. "Palette" is reserved for the shared root — it's the Palette section's own folder — so naming or renaming a top-level group to it is refused; a nested group can still be called Palette.

Select several items (⌘-click) to work on them together. Right-click a selection for **Move to ▸** (Shared, any group, or — in a Collection — any loose piece) and batch **Delete**. Dragging a row that's part of your selection moves the whole selection; drop it on a group to nest it there, or drop it in a different Collection section to move it between shared research and a piece's research folder. Scope moves leave your links alone: an item inside a piece is already associated by containment, so a link you added by hand goes quietly dormant while it lives there (Maugham just hides the now-redundant entry) and reappears as a link on that document if you move the item back out. An association that only ever came from containment ends when you move the item out — nothing is auto-linked in its place.

### Tables and pictures from Research

A table, picture or PDF in Research can become a figure of the book, and a figure can go back.

- **Use in Document** — right-click one Research item, or press the button in its inspector. It makes a figure that no line uses yet (its number shows "—" in the **Figures** section, tagged **unused**). Place it with **Insert ▸ Existing Figure…** (see [Editor](editor-and-focus.md)). Dragging the item onto the **Figures** section does the same (see [Structure and binder](structure-and-binder.md#figures-in-the-binder)). Offered for tables, pictures and PDFs in a project that holds figures, not in Review or on a view-only share, and not for several items at once.
- **Whose figure it is.** An item in a piece's own Research makes that piece's figure. An item in Shared Research makes a figure that belongs to the whole book, so only an author of the whole book may make or edit it; if this Mac may not, nothing is made and you are told.
- **The name** comes from the item's title. A title that is already a valid label name keeps its capitals ("Q3" stays "Q3"); otherwise it is folded to lower case with hyphens ("Q3 revenue (draft)" becomes `q3-revenue-draft`), and a name already taken gets `_2`.
- **Bring Back to Figures** — a figure you sent to Research leaves a copy there. On that copy the same menu and button read **Bring Back to Figures**, which puts the figure back, unchanged if the copy is unchanged.
- **"changed"** — a table made from Research shows the **changed** tag in the Figures section when its source file in Research has changed since the figure took it.

### Editing a Research table

A table in Research opens in the same grid as a figure's table: in the centre column, and in Plan's right column. Edits are saved to the CSV file itself after a short pause, and the file keeps its separator (comma, semicolon or tab), its line endings and its byte-order mark.

- **Undo.** While the table is open, ⌘Z and ⇧⌘Z undo and redo its cell, row and column changes. If the table has changed since, the undo is declined with a sentence.
- **No versions yet.** Saved changes to a Research table are not versioned yet: earlier states of the file are not kept.
- **An outside change.** If the file changes outside Maugham (another Mac, a spreadsheet app), the grid reloads and says so. If you had unsaved edits in the grid, your edits are written and the outside version is kept as a backup in the project's `.maugham/conflicts/` folder, and a notice says so.
- **`research:` formulas** inside a Research table are not evaluated and show `#REF!`.
- **Very large files** are shown as text, not a grid.
- **Read-only** in Review and on a view-only share; the grid opens for looking, with a reason.

### Citation details

A source you cite in a manuscript as `[@key]` carries its citation details in the inspector's **Citation** section, below Caption and URL: **Key**, **Authors** (one per entry — "Ada Lovelace" or "Lovelace, Ada"), **Source title**, **Publisher**, **Year**, **Accessed** and **Pages**. **Suggest** fills in a free key from the first author's surname and the year (`lovelace1843`). A key is letters, digits, `-` and `_`, starting with a letter or digit, and no two sources share one — a source in the Trash keeps its key, since restoring it would bring it back. A citation needs a key: details without one are refused, and the reason shows under the fields with what you typed kept. Clear every field to remove the citation (clear the key last to avoid the "needs a key" notice). See [Publishing → Tables, figures, footnotes, citations and cross-references](publishing.md) for how a citation prints.

### Capture inbox

Voice/text/photo captures from the iPhone companion app land in the Mac's capture inbox (⌘⌥B). Right-click an entry to promote it into research — three destinations:

- **Promote to Research** — shared project research, unscoped.
- **Promote to Research for "…"** — the currently active document; only appears when one's open and it's a valid target (a chapter in a novel, or a loose piece in a collection — not a referenced piece; in short-story and screenplay projects any open manuscript document qualifies, and promotion there files into shared research).
- **Promote to Research for…** — opens a picker to choose any chapter or collection piece.

**If captures from your phone aren't appearing here at all**, the Mac hasn't been told who that phone is yet, and a banner at the top of the Inbox says so with an **Admit…** button beside it: *"3 captures from iPhone are waiting for admission."* They are held, not lost — admit the phone and all of them arrive at once. See [People & Devices](people-and-devices.md).

A capture can also go **straight to the planning canvas** instead — drag the row onto the canvas, or right-click → **Send to Canvas** — which is the shorter road when you don't yet know what the capture is. Promoting from the canvas afterwards makes the research note whenever you're ready for it. See [Getting Started → Sending a capture from the Inbox to the canvas](getting-started.md#sending-a-capture-from-the-inbox-to-the-canvas).

Promoting into a collection piece drops the item straight into that piece's own research folder, where it shows up automatically under that piece's fold in the tree — no separate linking step. Promoting into a novel chapter files it under shared research and links it to that chapter, so it shows up under that chapter's own (read-only) fold, drawn flat. You can link an existing shared item to a chapter yourself too, without promoting: drag its row from the tree's Research section onto the chapter's own row, or right-click the chapter and choose **Link Research…** for a searchable list with a toggle per item — the keyboard- and VoiceOver-reachable route to the same thing the drag does.

### Trash & undo

Deleting an item moves it to the project's `.trash/` folder (project-local, syncs with iCloud), and it shows under **Trash** at the very foot of the tree, where right-click → **Restore** puts it back. ⌘⌥Z restores the most-recent deletion in place — the whole of it, whether that gesture deleted one row or fifty, or it tells you why it can't. Entries older than 30 days are cleared automatically when the project opens.

⌘Z is intentionally reserved for in-doc text undo; ⌘⌥Z is the binder-undo shortcut.
