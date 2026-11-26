# Screenplays

Open a Screenplay project. Maugham parses Fountain as you type:

- **Slug lines** — `INT. KITCHEN - DAY` → recognized as a scene heading, uppercased, styled distinctly. Appears in the binder as a scene.
- **Characters** — `SARAH` on its own line → recognized as a character cue.
- **Dialogue** — the lines after a character cue.
- **Parentheticals** — `(quietly)` → recognized and styled.
- **Transitions** — `FADE OUT:`, `CUT TO:` → right-aligned.

**Tab and Shift+Tab** cycle the current line through element types if Fountain's prefix-recognition didn't catch what you meant. A faint element label in the gutter shows what Maugham thinks you're writing.

### Scenes in the binder

A screenplay is one file, so its binder is the Book, the **Script**, and the scenes beneath it — every slug line, with the page it starts on. Click a scene to scroll the script there. A scene is a place in the script, not a document: it has no fold and no Brief of its own. The script has one Brief and one set of passes, and its [To resolve](right-column.md#to-resolve-1) groups by scene, with **Before the first scene** first. A scene carries a dot when something in To resolve falls in it. Reading the script in a language, To resolve groups the translator's questions by scene too.

### Page count

Maugham uses Final Draft's wrap heuristic (60-char action lines, 35-char dialogue, 20-char parenthetical, 55 lines per page). The page count shows in the status line under the text, whose right end is a menu with **Set Page Target…**. The page target is the whole script's.

### Title page

Add a title page block at the top of the file (Fountain syntax: `Title: My Script` etc.). Maugham styles it.

### Syntax help

⌘/ (Help ▸ Syntax & Keyboard Shortcuts) opens the syntax sheet — three tabs: Markdown, Fountain, Keyboard shortcuts. The Keyboard tab is also where you find the full list of shortcuts grouped by category.
