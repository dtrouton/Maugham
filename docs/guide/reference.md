# Reference

## Keyboard shortcuts

The full list lives in the in-app cheatsheet: **⌘/** → Keyboard tab.

The ones you'll use most:

| Shortcut | Action |
|---|---|
| `⌘N` | New project |
| `⌘O` | Open project |
| `⌘S` | Checkpoint, and back up if you've set a backup destination — autosave is automatic (see [Backups & History](backups-and-history.md)) |
| `⌘⇧S` | Save Checkpoint As… — a named checkpoint you can find again (it doesn't run a backup) |
| `⌘R` | **Check Writing** in Author — notes on what you've written since the last check; **Run Round** in Review — a numbered round in the piece's pass |
| `⌘⇧R` | **Reread** in Author, **Fresh Eyes** in Review — ends the warm session and reads the whole piece cold |
| `⌘⇧↩` | Promote… — turn the canvas selection into a durable artifact |
| `⌘Z` | Undo (text, annotation action, task, checkbox, or History Rewind) |
| `⌘⇧Z` | Redo |
| `⌘,` | Settings |
| `⌘⇧,` | Project Settings |
| `⌘F` | Find in editor |
| `⌘G` / `⌘⇧G` | Find next / previous |
| `⌘⌥F` | Find in project |
| `⌘⌥A` | Show Annotations pane |
| `⌘⌥C` | Translator's Note… — a directive on the paragraph under the caret, into the piece's craft intent (every edition) or one edition's brief |
| `⌘⌥Z` | Restore last deletion |
| `⌘\` | Toggle focus mode (on the canvas, also collapses both side columns) |
| `⌘⇧F` | Toggle full-screen focus (turns focus mode on, so the canvas collapses too) |
| `⌘1` | Plan persona |
| `⌘2` | Author persona |
| `⌘3` | Review persona |
| `⌘4` | Publish persona |
| `⌘⌥⇧R` | Toggle Review Mode — the annotate-only posture, see [Annotations & Suggestions](annotations-and-suggestions.md#review-mode--reading-your-own-draft-cold) |
| `⌘⌥I` | Inspector pane |
| `⌘⌥R` | Open the tree's Research section, scrolled into view (no-op while Find in Project covers the tree) |
| `⌘⌥O` | Select the project row — corkboard/outline in Author, the review board (pieces × passes) in Review, the planning canvas in Plan, the compiled book in Publish once you've made one (corkboard/outline there too, before you have) |
| `⌘⌥H` | History pane |
| `⌘⌥T` | Tasks pane |
| `⌘⌥B` | Inbox pane |
| `⌘⌥P` | Open the tree's Palette section, scrolled into view (no-op while Find in Project covers the tree) |
| `⌘⌥L` | Translation pane |
| `⌘⌥N` | Intent pane |
| `⌘⌥G` | What I've Learned pane — the lessons ledger, across the whole project |
| `⌘⌥Y` | First Reader pane — who reads this project, and what she knows |
| `⌘⌥V` | Visual Language pane |
| `⌘⌥D` | Diagnostics pane — the compiler's notes on what you've written |
| `⌘⌥E` | References pane — what this piece is pinned to |
| `⌘⌥K` | Department pane — Publish's desk: the book's design and its language editions |
| `⌘⌥0` | Toggle inspector column |
| `⌘⇧P` | Toggle Research preview |
| `⌘/` | Syntax + keyboard reference |
| `⌘?` | Maugham Help — this guide |

**Two different things are called "review", and only the shortcut tells them apart.** `⌘3` is the **Review persona** — a window layout that leads with the Annotations pane. `⌘⌥⇧R` is **Toggle Review Mode** — a posture of the *editor* that makes your manuscript read-only and puts you in the reviewer's seat. They're independent: you can turn Review Mode on in any persona, and the Review persona doesn't turn it on for you.

## On-disk layout

Every Maugham project is a folder. You can open it in Finder and see:

```
My Novel/
├── project.maugham.json    # the manifest — structure, metadata
├── manuscript/             # your prose, as plain Markdown
│   ├── 01-chapter-1.md
│   ├── 02-act-one/         # groups are folders
│   │   ├── 01-scene-1.md
│   │   └── 02-scene-2.md
│   └── 03-chapter-2.md
├── research/               # everything that isn't manuscript
│   ├── sarah.md
│   ├── locations.pdf
│   └── pasted-2026-05-10.png
├── intent.md               # your craft intent; intent/ holds each document's own
├── visual-language.md      # the book's visual language, once you've written one
├── lessons.md              # What I've Learned
├── first-reader.md         # your first reader, once you've named one
├── editions/               # one brief per language edition
├── canvas.md               # the words on your planning canvas
├── canvas_assets/          # photographs you put on the canvas
├── Exports/                # the PDFs and EPUBs you compile
├── notes/                  # made with every project; nothing is kept here today
├── .trash/                 # what you deleted, kept for 30 days
└── .maugham/               # Maugham's own working files
    ├── ops/                # each document's history — what your manuscript is made from
    ├── checkpoints.<device>.jsonl   # your checkpoints, one file per device
    ├── devices/            # the devices that write in this book
    ├── people/             # the people, and what each may write
    ├── inbox/              # captures from your phone
    ├── canvas.json         # how the canvas is arranged
    ├── publish/            # your book's design and publishing settings
    ├── diagnostics/        # what Checking Your Writing last found
    ├── ui-state.json       # selected doc, scroll position, etc.
    ├── sessions.json       # session log for stats
    └── conflicts/          # iCloud conflict archives
```

A short story keeps its one document at the top level as `story.md`, and a screenplay keeps its `.fountain` file in `manuscript/`. Files like `intent.md` and `first-reader.md` appear only once you've written something in them.

Everything you write is plain text. The `.md` and `.fountain` files are readable in any text editor, but they are written *from* each document's history in `.maugham/ops/`, not the other way round: an edit made to them outside Maugham isn't kept, and is replaced the next time Maugham writes the file. Do your editing in Maugham. iCloud handles the sync invisibly via `NSFileCoordinator`. Who may write in the book (`devices/` and `people/`) is explained in [People & Devices](people-and-devices.md).

The on-disk filenames have a numeric prefix (`01-chapter-1.md`) so manuscripts sort correctly in Finder. **Tidy All Filenames** (File menu) renumbers any sequence with gaps.

## Troubleshooting

**Maugham doesn't autosave my latest edit.** Autosave debounces at 750ms — if you quit within that window, an explicit ⌘S flushes any pending writes immediately.

**A document won't open.** Maugham names what's wrong and offers a way forward — wait for iCloud, open it read-only, set the unreadable file aside, or restore from a backup. See [Getting Started → Troubleshooting: a document that won't open](getting-started.md#troubleshooting-a-document-that-wont-open).

**My project won't open.** The window says *Couldn't open project* and gives the reason. If it says the project was made by a newer version of Maugham, update Maugham (**Maugham → Check for Updates…**). Otherwise fix what it names if you can and open the project again. **File → Restore from Backup…** works from that window. If the project's settings file is the problem, Maugham finds its backups through its safety copy; if it still finds none, press **Show All Backups** to pick from every backup by title. See [Backups & History → Restoring from a backup](backups-and-history.md#restoring-from-a-backup).

**How do I get an older version back?** For a chapter, open the History pane (⌘⌥H) and use **Revert here…** on a checkpoint, or **Rewind** to any moment. For the whole project, restore a copy from a backup. Both are explained in [Backups & History](backups-and-history.md).

**A document I had open is now showing different text.** iCloud detected an outside change (e.g., from another Mac). A banner offers Keep mine / Use cloud. The losing version is archived under `.maugham/conflicts/`.

**Claude says "Maugham isn't running."** It isn't — open the app. The MCP server only runs while Maugham is alive.

**Claude says "That project isn't open in Maugham."** Open the project. MCP only sees currently-open windows; closed projects aren't reachable.

**Claude says "Maugham's MCP connection is turned off in Settings."** Settings → General → **Allow Claude to connect (MCP)** → toggle on.

**The Set up Claude Desktop sheet says "configured" before I restart.** That just means the config file is written. Restart Claude Desktop to actually pick up the new server.

**My screenplay's page count looks off.** Maugham uses Final Draft's wrap heuristic. If you're using a non-monospace screen font, the on-screen layout may not match the printed page count.

**A binder item I deleted is gone forever.** Try ⌘⌥Z — it restores the most-recent deletion. If you've moved on since, open **Trash** at the very foot of the tree and right-click the item → **Restore**; deleted items stay there for 30 days (on disk, they're in the project's `.trash/` folder). If you didn't delete it and it isn't in Trash — another Mac saved an older outline over it — look under **Removed Elsewhere** at the foot of the binder.

## Updates

Maugham looks for a new version a minute after it opens and once a day after that, and downloads it in the background. To look now, choose **Maugham → Check for Updates…**. While it's working, the menu item says what it's doing: *Checking for Updates…*, *Downloading Update…*, *Install Update…* once one is ready, then *Installing…*.

When an update is ready, a banner across the top of the project window says *Maugham <version> is ready*:

- **Restart & Update** installs it now and reopens Maugham.
- **Dismiss** hides the banner for that version. The update is still installed the next time you quit.

Before an update is installed, Maugham checks it once more — that it's really from Maugham's developer and approved by Apple. If it doesn't pass, nothing changes: the Maugham you have stays exactly as it was. The next time you open Maugham, a line at the top of the window tells you what happened, once, until you dismiss it:

- *"The update to Maugham <version> didn't pass its safety check and wasn't installed. Maugham will download it again."*
- *"The update to Maugham <version> didn't pass its safety check again and wasn't installed. Choose Check for Updates… to try once more."* — after the same version has been refused twice, Maugham stops downloading it on its own.
- *"The update to Maugham <version> couldn't be installed. Maugham will try again."* — something went wrong part-way through installing. The download is kept, and the next **Restart & Update** or quit tries again.

If a new version needs a newer macOS than this Mac has, the check says so — *"Maugham <version> needs macOS <version> or later."* — and downloads nothing.

Maugham deletes the updates it downloaded once it no longer needs them, so they don't pile up on your Mac.
