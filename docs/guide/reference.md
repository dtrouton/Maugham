# Reference

## Keyboard shortcuts

The full list lives in the in-app cheatsheet: **⌘/** → Keyboard tab.

The ones you'll use most:

| Shortcut | Action |
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
| `⌘⌥1` / `⌘⌥2` / `⌘⌥3` | Right pane: Inspector / Research / Outline |
| `⌘⇧P` | Toggle Research preview |
| `⌘/` | Syntax + keyboard reference |

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
