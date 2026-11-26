# Research

Research is everything that isn't manuscript: character sheets, location photos, PDFs, web links, voice notes. It lives in the binder, in two kinds of place, and **where a note is, is whose it is**:

- **The book's** — in the binder's **Research** section. A note there belongs to the whole book.
- **A chapter's** — in that chapter's fold, under its row in the manuscript. A note there belongs to that chapter. In a novel the file stays in the project's `research/` folder and the chapter links to it; in a Collection it lives in the piece's own folder. Either way you see it in one place only, under its chapter.

A note linked to two chapters shows in both folds. One that no chapter holds is the book's.

**In an older project, notes you linked to a chapter are now in that chapter's fold**, not the Research section. The section says how many went, in one quiet line at its foot: *12 notes are with their chapters — open a chapter’s fold to see them.* (In a Collection, "pieces".) With none of the book's own left, it reads *No whole-book research.* followed by the same line.

### Making research

- **New Note** — right-click the Research section, a group in it, or a chapter's fold, and choose **New Note**. Rename it inline; the file on disk renames with it.
- **New Table** — the same menus offer a blank table: three columns, a header row and three empty rows, named "Untitled Table". It opens in the table grid.
- **New Group** — a folder. Groups nest.
- **Add Web Link…** — paste a URL.
- **Drag in from Finder** — images, PDFs, audio, text files.
- **Paste an image** — ⌘V into a note. It is saved as `pasted-…png` beside your notes.

"Palette" is the Palette section's own folder, so a top-level group can't take that name; a nested one can.

### Reading research

**Click a note and it opens beside your text**, in the right column's [Pulled up](right-column.md#pulled-up-3), and you can edit it there. Double-click it, or press **Open in Centre**, to give it the centre. Images, PDFs, audio and links use Maugham's previews. Mark inline images in a note with `![alt](./image.png)`; ⌘⇧P (View ▸ Show Research Preview) shows them drawn.

⌘⌥R (View ▸ Go to Research) opens the binder's Research section and scrolls to it.

### Moving research

**Moving a note changes whose it is.** Drag it, or right-click it:

- **Move to Chapter ▸** gives it to a chapter (a submenu per Part, in book order).
- **Make Whole-Book** gives a chapter's note back to the book: it moves to the Research section and its chapter links go.
- **Remove from “Three”** appears where another chapter holds the note too, and takes it from this one only.
- **Move to ▸** puts a note in a group. From a chapter's fold, each target says whose it is: *Ships — Chapter One* is a group of Chapter One's; *Places — whole book* is the book's. Moving into a chapter's group makes the note that chapter's; moving into the Research section or a whole-book group makes it the book's, and takes away its chapter links.

Dragging works the same way: onto a chapter's row or into its fold, onto the Research section, or onto a group. Where the note lands opens and scrolls into view.

**Maugham asks only when a move would take something from a chapter you didn't mean to move it from.** Taking one note out of the fold you took it from is just a move. Anything more — a group, several rows, a note another chapter also holds — asks once, in one sentence that names what leaves where: *“Hull” also belongs to Two; moving it to “Places” takes it from Two.*

**A group in the Research section can hide chapters' notes.** Delete it, or move it somewhere else, and any notes in it that belong to a chapter stay with their chapter; Maugham says so first — *“Maps” stays with Chapter Three; the rest of “Ships” goes to the Trash.* A whole-book group that holds only chapters' notes isn't drawn in the Research section at all.

Select several items (⌘-click) to move or delete them together; dragging one of a selection moves all of it.

**In read-through**, a chapter's research can be read but not renamed, deleted, moved out or unlinked; the binder names the chapter when it refuses. New Note and moving something in still work.

### Tables and pictures from Research

A table, picture or PDF in Research can become a figure of the book, and a figure can go back.

- **Use in Document** — right-click one Research item, or press the button in its details. It makes a figure that no line uses yet (its number shows "—" in the **Figures** section, tagged **unused**). Place it with **Insert ▸ Existing Figure…** (see [Editor](editor-and-focus.md)). Dragging the item onto the **Figures** section does the same (see [Structure and binder](structure-and-binder.md#figures-in-the-binder)). Offered for tables, pictures and PDFs, not on a view-only share, and not for several items at once.
- **Whose figure it is.** A chapter's item makes that chapter's figure. An item of the book's makes a figure that belongs to the whole book, so only an author of the whole book may make or edit it; if this Mac may not, nothing is made and you are told.
- **The name** comes from the item's title. A title that is already a valid label name keeps its capitals ("Q3" stays "Q3"); otherwise it is folded to lower case with hyphens ("Q3 revenue (draft)" becomes `q3-revenue-draft`), and a name already taken gets `_2`.
- **Bring Back to Figures** — a figure you sent to Research leaves a copy there. On that copy the same menu and button read **Bring Back to Figures**, which puts the figure back, unchanged if the copy is unchanged.
- **"changed"** — a table, picture or PDF made from Research shows the **changed** tag in the Figures section when its source file in Research has changed since the figure took it.

### Editing a Research table

A table in Research opens in the same grid as a figure's table: in the centre, or pulled up beside your text. Edits are saved to the CSV file itself after a short pause, and the file keeps its separator (comma, semicolon or tab), its line endings and its byte-order mark.

- **Undo.** While the table is open, ⌘Z and ⇧⌘Z undo and redo its cell, row and column changes. If the table has changed since, the undo is declined with a sentence.
- **Versions.** Every save of a Research table keeps the state before it. Your own editing run keeps one version, the state before the run began (a pause of ten minutes, or closing the grid, ends a run); each write by Claude and each Restore keeps one too.

  Its details' **Versions** section lists them newest first, marks the state before each of Claude's writes **Before the assistant’s change** and a version holding values Claude wrote **Written by assistant**, and offers **Restore previous version** and a **Restore** on each row. Restoring is itself kept as a version, so restoring again undoes it, and it keeps the table's link to its figure. If a version's formats or widths can't be put back, the notice says so.

  A table keeps its last 50 versions on each Mac. Versions stay with the table in the Trash and come back with it, are removed when it is deleted for good, move with it when a piece is promoted to a project, and are not copied by Duplicate. On a view-only share, and for a chapter in read-through, the section lists the versions with Restore turned off and says why.
- **When a save can't be made.** If the file can't be written (it is gone, unreadable, moved out of Research, or the folder won't take it), Maugham doesn't leave your edits only in the grid. At ⌘S, when you leave the grid, and when you close the project or quit, they are kept as a copy in the project's `.maugham/conflicts` folder, and the notice names the file. After a quit there is no window left to show that notice, so look in that folder for a file ending `-unsaved-` and a date. Maugham tries again at the next save. Until the edits are saved, **Use in Document** and **Bring Back to Figures** are refused for that table, and say so. If the only trouble is that the table's previous version can't be kept, your edits are saved anyway and the notice says so.
- **An outside change.** If the file changes outside Maugham (another Mac, a spreadsheet app), the grid reloads and says so. If you had unsaved edits in the grid, your edits are written and the outside version is kept as a backup in the project's `.maugham/conflicts/` folder, and a notice says so.
- **`research:` formulas** inside a Research table are not evaluated and show `#REF!`; they compute only through a figure's pins.
- **Very large files** are shown as text, not a grid.
- **Read-only** on a view-only share and for a chapter in read-through; the grid opens for looking, with a reason.

### Earlier versions of a Research note

A Research note keeps earlier versions of itself. Your own typing keeps one version for each stretch of writing: the text as it was before you began (a pause of ten minutes ends a stretch). Anything else that changes a note's words keeps what it replaced, every time: a Rewrite from the canvas or a link added there, a wiki-link rename, Search & Replace, a reference rewritten after you rename or move a note that has pictures, a Restore, and a rewrite by Claude. A change made to the file outside Maugham is kept the next time Maugham saves the note.

The **Versions** section in a note's details works as it does for a table: each version by its date, newest first, with **Restore previous version** and a **Restore** on each row. The versions from Claude's writes are marked **Before the assistant’s change** and **Written by assistant**. Restoring is itself kept as a version, so restoring again undoes it.

If the note is open, the editor shows the restored text; a change you had not yet saved is saved first, so it is a version too. Restore is turned off on a view-only share and for a chapter in read-through, and says why, and a view-only share also keeps you from typing in the note. A note keeps its last 50 versions on each Mac. If Maugham can't keep the earlier version, it tells you.

If a note's file can't be read at all, Maugham never saves over it: when you leave the note, the text you typed is kept in the project's `.maugham/conflicts` folder, and Maugham tells you its name.

A palette card keeps versions the same way. Your own changes in the card's editor keep one version for each stretch of work; anything else that changes the card keeps what it replaced, every time: a promotion from the canvas or the inbox, a wiki-link rename, Search & Replace, and a Restore. A promotion Claude made from the inbox is marked **Before the assistant’s change**. Click the card in the binder's Palette section and its **Versions** are in its details; if the card is open, its editor shows a restored version. Claude never rewrites a palette card.

A Rewrite from the canvas keeps the note's or card's text as a version before it writes; if that version can't be kept, the Rewrite isn't made, nothing changes, and Maugham tells you why. Older versions of Maugham left a Rewrite's old text in the Trash as a "previous version" instead; those entries still restore. Pictures, PDFs, audio and other files are not versioned: your backups (see [Backups & History](backups-and-history.md)) cover them. Research history is kept to a lower standard than your manuscript's: the manuscript keeps every change, while Research text keeps one version per stretch of work and its last 50 versions on each Mac.

### Citation details

A source you cite in a manuscript as `[@key]` carries its citation details in the **Citation** section of its details, below Caption and URL: **Key**, **Authors** (one per entry — "Ada Lovelace" or "Lovelace, Ada"), **Source title**, **Publisher**, **Year**, **Accessed** and **Pages**. **Suggest** fills in a free key from the first author's surname and the year (`lovelace1843`). A key is letters, digits, `-` and `_`, starting with a letter or digit, and no two sources share one — a source in the Trash keeps its key, since restoring it would bring it back. A citation needs a key: details without one are refused, and the reason shows under the fields with what you typed kept. Clear every field to remove the citation (clear the key last to avoid the "needs a key" notice). See [Publishing → Tables, figures, footnotes, citations and cross-references](publishing.md) for how a citation prints.

### Capture inbox

Voice, text and photo captures from the iPhone companion app land in the **Inbox**. Click its row in the binder (or press ⌘⌥B) and the captures fill the centre. Right-click one to file it:

- **Promote to Whole-Book Research** — the book's own research, not one chapter's.
- **Promote to Research for…** — a list of every chapter to choose from.
- **Promote to Palette Card…** — onto a palette card.

**If captures from your phone aren't appearing here at all**, the Mac hasn't been told who that phone is yet, and a banner at the top of the Inbox says so with an **Admit…** button beside it: *"3 captures from iPhone are waiting for admission."* They are held, not lost — admit the phone and all of them arrive at once. See [People & Devices](people-and-devices.md).

A capture can also go **straight to the planning canvas** instead — drag it onto the binder's Canvas row, or right-click → **Send to Canvas** — which is the shorter road when you don't yet know what the capture is. Promoting from the canvas afterwards makes the research note whenever you're ready for it. See [Getting Started → Sending a capture from the Inbox to the canvas](getting-started.md#sending-a-capture-from-the-inbox-to-the-canvas).

Promoted for a chapter, a capture becomes that chapter's note and shows in its fold. **Link Research…**, in a chapter's row menu, is the keyboard's way to do what a drag onto its row does: a searchable list with a toggle per note. A note you turn on becomes that chapter's.

### Trash & undo

Deleting an item moves it to the project's `.trash/` folder (project-local, syncs with iCloud), and it shows under **Trash** at the foot of the binder, where right-click → **Restore** puts it back. ⌘⌥Z restores the most-recent deletion in place — the whole of it, whether that gesture deleted one row or fifty, or it tells you why it can't. Entries older than 30 days are cleared automatically when the project opens.

⌘Z is intentionally reserved for in-doc text undo; ⌘⌥Z is the binder-undo shortcut.
