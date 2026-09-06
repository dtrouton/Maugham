# Reference

## Keyboard shortcuts

The full list lives in the in-app cheatsheet: **⌘/** → Keyboard tab.

The ones you'll use most:

| Shortcut | Action |
|---|---|
| `⌘N` | New project |
| `⌘O` | Open project |
| `⌘S` | Save flash (autosave is automatic) |
| `⌘⇧S` | Save Checkpoint As… — a named checkpoint you can find again |
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
| `⌘\\` | Toggle focus mode (on the canvas, also collapses both side columns) |
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

**Two different things are called "review", and only the shortcut tells them apart.** `⌘3` is the **Review persona** — a window layout that leads with the Annotations pane. `⌘⌥⇧R` is **Toggle Review Mode** — a posture of the *editor* that makes your manuscript read-only and puts you in the reviewer's seat. They're independent: you can turn Review Mode on in any persona, and the Review persona doesn't turn it on for you.

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

## Troubleshooting

**Maugham doesn't autosave my latest edit.** Autosave debounces at 750ms — if you quit within that window, an explicit ⌘S flushes any pending writes immediately.

**A document I had open is now showing different text.** iCloud detected an outside change (e.g., from another Mac). A banner offers Keep mine / Use cloud. The losing version is archived under `.maugham/conflicts/`.

**Claude says "Maugham isn't running."** It isn't — open the app. The MCP server only runs while Maugham is alive.

**Claude says "That project isn't open in Maugham."** Open the project. MCP only sees currently-open windows; closed projects aren't reachable.

**Claude says "Maugham's MCP connection is turned off in Settings."** Settings → General → **Allow Claude to connect (MCP)** → toggle on.

**The Set up Claude Desktop sheet says "configured" before I restart.** That just means the config file is written. Restart Claude Desktop to actually pick up the new server.

**My screenplay's page count looks off.** Maugham uses Final Draft's wrap heuristic. If you're using a non-monospace screen font, the on-screen layout may not match the printed page count.

**A binder item I deleted is gone forever.** Try ⌘⌥Z — it restores the most-recent deletion. If you've moved on since, look in `.maugham/.trash/` directly; entries live for 30 days.
