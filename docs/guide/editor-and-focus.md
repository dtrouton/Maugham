# The Editor & Focus

Maugham's editor is a centered ~70-character column with gutters on either side. The column width comes from the typography setting; the gutters are theme-colored.

### Themes and typography

Open **Settings** (⌘,):

- **Theme** — Light, Dark, Sepia, or Follow System. Sepia is paper-yellow; useful in low light.
- **Typography** — font family (curated for prose: Iowan Old Style, New York, Charter, etc.), size, line height, paragraph spacing. Changes apply live.
- **Per-project typography** — `⌘⇧,` opens Project Settings. Override typography just for this project (e.g., a screenplay should use Courier; a novel might use a serif at 17pt). Settings persist across launches.

### Focus features

Maugham is built for focused writing sessions. The chrome gets out of your way.

- **⌘\\ — Toggle focus mode.** Hides the title bar and toolbar; just text and gutters.
- **⌘⇧F — Toggle full-screen focus.** Enters full-screen with no chrome.
- **Typewriter scrolling** (Settings → Editor → Focus) — keeps the active line at the vertical center of the viewport as you type.
- **Sentence focus** — only the current sentence is full color; the rest dims. Forces you forward.
- **Paragraph focus** — same idea, paragraph granularity.

These are sticky preferences; once you find your set, they stay.

### Smart typography

As you type, Maugham quietly fixes things:

- `--` becomes an em-dash `—`
- `...` becomes an ellipsis `…`
- Straight quotes `"like this"` become smart quotes `"like this"`

The underlying file still contains the smart characters; nothing is lost on save.

### Goals and word count

The bottom-right of the editor shows a goal capsule: today's word count, document word count, reading time. If you set a word target on a document in the Inspector, the capsule shows progress.

⌘S triggers a "Saved" flash. Autosave already runs every 750ms; the flash is muscle memory.
