# Backups & History

Three things keep your work safe, and they do different jobs:

- **Autosave** writes what you type a moment after you stop. You never press anything for it.
- **Checkpoints** are marks in your project's own history — a place you can go back to. Nothing is copied when you make one, and they cover your manuscript text.
- **Backups** are full copies of the project folder, checked and kept somewhere else — a local folder, an external drive, a synced folder outside iCloud.

A checkpoint helps when you want last Tuesday's version of a chapter back. A backup helps when the project itself is in trouble.

## Checkpoints

**⌘S makes a checkpoint and runs your backups.** Maugham names the checkpoint for you from the time, the word count of the whole project, and the document you were in — for example *14:32 — 52,310 words (Chapter 3)*. When you weren't in a document, the part in brackets is left off. Checkpoints always cover the whole project, whichever document you were in.

**⌘⇧S (File → Save Checkpoint As…) makes a checkpoint with a name you choose.** A small sheet asks you to **Name this checkpoint**, with *e.g. end of draft 2* as a hint, and **Save** stays off until you've typed something. It runs your backups too, exactly as ⌘S does.

In a piece you may not change (see [People & Devices](people-and-devices.md#what-their-mac-shows-them)), ⌘⇧S doesn't open the sheet. It says why instead: *"This text isn’t yours to change, so a checkpoint here would mark nothing of yours."* Your backups still run.

## The History pane (⌘⌥H)

The History pane shows the history of the document you have open, newest first: your typing, Claude's and your own notes, and your checkpoints. Filter it with the chips across the top:

- **All** — everything.
- **Checkpoints** — just the checkpoints.
- **Edits** — your writing, grouped into bursts. A new burst appears about every 30 seconds while you work.
- **Annotations** — every note and suggestion, and every answer you gave one.

Each filter has its own empty state, such as *No checkpoints* or *No edits*, so an empty list never leaves you guessing which one you're looking at. Edits made to the `.md` file outside Maugham aren't kept, so History has nothing to show for them.

**If some checkpoints can't be read**, a line at the top says so: *"Some checkpoints can’t be read (…). They are still in the file — check permissions or iCloud sync."* The brackets name the files, and hovering over the line shows the reason for each one. A permissions problem is fixed on this Mac. A file iCloud hasn't downloaded yet is fixed by getting online. Your other checkpoints, and your backups, carry on as normal.

### Going back to a checkpoint

Every checkpoint row has **Revert here…**. It opens a sheet titled *Revert to “<the checkpoint's name>”* and asks how much to put back, under **Scope**:

- **Whole project** — every document goes back to how it was at that checkpoint (offered only when you may change every document).
- **Document: <title>** — only that one document goes back.

When the checkpoint was made inside a document, that document is chosen for you. When it wasn't, nothing is chosen and **Revert** stays off until you pick one. That way pressing Return can never revert more than you meant.

Reverting adds to the history rather than erasing it. Everything you wrote after the checkpoint is still in the History pane, and you can rewind back to it.

### Rewinding one document

To look back at any moment, not just a checkpoint, use **Rewind**. That's the clock button beside the filter chips. You can also press the back-arrow button on an edit row (*Rewind to before this point…*), which opens Rewind at the moment just before that edit.

The Rewind window is headed **REWINDING**. Drag the scrubber to go back through the document, and switch between **Doc** (the text as it was then) and **Diff** (what restoring it would change, compared with the document now). The buttons at the bottom are:

- **Cancel** — leave without changing anything.
- **Snapshot here…** — make a named checkpoint at that moment, so you can find it again.
- **Restore here…** — put the document back as it was then. It asks first: *Restore <document> to this point?* → **Restore**.

Press ⌘Z straight after a restore and the whole thing is undone, including any suggestions it reopened. See [Annotations & Suggestions → Rewinding with suggestions](annotations-and-suggestions.md#rewinding-with-suggestions).

**Revert here…**, the back-arrow button, **Snapshot here…** and **Restore here…** only appear where this Mac may change the piece's text. In a piece you're reviewing, History is something to read.

### Other things History tells you

History also says who wrote what, and holds work that's waiting for you: changes from a device you haven't named yet, history set aside because it couldn't be read, and anything this book is missing. Those are covered where they're explained in full:

- [Getting Started → Who wrote your history](getting-started.md#who-wrote-your-history) and [Troubleshooting: a document that won't open](getting-started.md#troubleshooting-a-document-that-wont-open).
- [People & Devices → What History tells you](people-and-devices.md#what-history-tells-you) and [What this book is missing](people-and-devices.md#what-this-book-is-missing).

## Backups

Backups are off until you choose where they go. Open **Settings (⌘,) → Backups** and press **Add destination…**. Pick a folder outside iCloud: a local folder, an external drive, or a folder Dropbox or Google Drive syncs. If you have none, the tab says so: *"No destinations. Add a folder outside iCloud (a local folder, external drive, or a Dropbox/Drive-synced folder) to keep verified copies of your projects."*

Each destination shows its name, where it is, and how many backups it keeps — **Keep 10** to begin with. Use the arrows to choose anywhere from 1 to 50, and the trash button to remove the destination. Removing a destination doesn't delete the backups already in it.

The tab's own advice is worth following:

> *"Tip: local folders use copy-on-write, so keeping many generations is nearly free. For a cloud-synced folder (Dropbox, OneDrive, Drive) each generation re-uploads, so lower its count (2 is a good default) — Maugham can't tell a synced folder from a local one, so the choice is yours."*

### What happens when you press ⌘S or ⌘⇧S

*"Backups run automatically when you save (⌘S) or name a checkpoint (⌘⇧S). A copy is verified, then written to each destination; a corrupt project is detected and skipped rather than backed up."* In more detail:

- **The whole project folder is copied** — manuscript, research, the canvas, your project's history, everything in it. Several projects can share one destination, because each gets its own folder there.
- **The copy is checked before it counts.** It's written under a temporary name, checked, and only then joins your backups. A copy that was cut short never looks like a finished one.
- **Nothing is written if nothing has changed.** Pressing ⌘S (or ⌘⇧S) ten times without writing a word makes one backup, not ten. Things like which document you had selected or which persona you were in don't count as changes.
- **Old backups are cleared down to the destination's Keep number** each time a new one is made, oldest first. A backup that checks out is kept ahead of a damaged one.

### When backups pause

Before every backup, Maugham checks that the project's history is whole. If it isn't — for example, part of a document's history can't be read — it doesn't back up, because a damaged copy would start replacing your good ones. A banner appears across the project window:

> **Backups paused — this project failed an integrity check**
> *New saves aren't being backed up until this is resolved.*

**Restore…** on the banner opens the restore window (below). Your existing backups are untouched while backups are paused, and nothing is cleared from them. When the problem is fixed, the next ⌘S checks again and backs up as usual. A checkpoint file that can't be read doesn't pause backups, because a backup is most useful at exactly that moment.

## Restoring from a backup

**File → Restore from Backup…** opens a window titled *Restore <project>*, listing every backup of this project with its date and the destination folder it's in. Next to each one is a mark:

- a green seal — *"Integrity verified"*: this backup checks out.
- an orange triangle — *"This generation failed verification"*: something in this copy is damaged. Choose another one.

If none are found, the window says **No backups found** and offers **Show All Backups**, which lists every backup in your backup folders by its project's title, so you can pick the right one yourself. This helps when a project's settings file was lost and its own backups can't be matched to it.

Choose a backup and press **Restore a Copy…**. Maugham asks you to choose a folder: *"Choose a folder to restore a copy of this project into. Maugham names the copy itself."* Press **Restore Here**. The copy is called *<project> (restored)*, or *<project> (restored 2)*, *(restored 3)* and so on if that name is taken, so it never lands on top of anything. Maugham shows you the copy in Finder when it's done. **A restore never replaces your project in place.** Your current project stays exactly as it is, and you open the restored copy alongside it to take what you need.

The restored copy is a separate book. It gets its own backups, kept in their own folder and counted against Keep on their own, so backing up one never clears the other's.

If the restore goes wrong, the window says *Restore failed:* and gives the reason.

The same window opens from **Restore from Backup…** in a document that won't open (see [Troubleshooting: a document that won't open](getting-started.md#troubleshooting-a-document-that-wont-open)), and from the paused-backups banner.

If a project's settings file (`project.maugham.json`) goes missing but Maugham's safety copy of it is intact, the project still opens. Maugham puts the file back and says once: *"This project's settings file was missing, so Maugham put it back from its safety copy."* If the file is only still downloading from iCloud, Maugham doesn't replace it. It asks you to open the project again in a moment.
