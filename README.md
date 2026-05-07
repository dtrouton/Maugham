# Maugham

A focus text editor for serious creative writing on macOS.

See `docs/superpowers/specs/2026-05-07-maugham-master-design.md` for the architectural spec.
See `docs/superpowers/plans/` for milestone implementation plans.

## Build

Requires macOS 14+, Xcode 15+, and `xcodegen`:

    brew install xcodegen

Generate the Xcode project, then build:

    ./gen.sh
    open Maugham.xcodeproj

In Xcode: ⌘R to run, ⌘U to test.

## Layout

- `Maugham/` — main app target source
- `MaughamTests/` — XCTest target
- `project.yml` — xcodegen project description; edit this, not `Maugham.xcodeproj`
- `docs/superpowers/specs/` — architectural design documents
- `docs/superpowers/plans/` — milestone implementation plans

## Phase 1a smoke test

To verify a fresh build, walk through these seven steps:

1. Launch Maugham (⌘R in Xcode, or `open` the built `.app`).
2. Click **New project…**, name it "Smoke Test", click **Create**.
3. Type a sentence in the editor: *"The first line of a brand new story."*
4. Quit (⌘Q).
5. Relaunch. The Welcome window should list "Smoke Test" under Recents.
6. Click "Smoke Test". The project should reopen with your sentence intact.
7. Confirm the on-disk layout in Finder: `project.maugham.json`, `story.md`, `research/`, `notes/`. Open `story.md` in TextEdit; it shows your sentence.

If all seven pass, milestone 1a is healthy.

## Phase 1b smoke test

Once running on milestone-1b:

1. Open Maugham, open a Short Story project from Recents.
2. Editor uses Iowan Old Style 17pt with calm syntax highlighting.
3. Type `**bold**` — asterisks dim, "bold" renders bold.
4. ⌘, → Theme → Sepia. Background turns paper-yellow.
5. Type `--` and `...` — see them transform to `—` and `…`.
6. ⌘, → Editor → drag size slider. Editor reflows live.
7. Quit and relaunch. Settings persist.

If all seven pass, milestone 1b is healthy.

## Phase 1c smoke test

Once running on milestone-1c:

1. Open a project from Recents. Editor sits in a centered ~70-char column with theme-colored gutters; resizing the window grows or shrinks the gutters.
2. Settings (⌘,) → Editor → Focus → enable Typewriter scrolling. Active line stays at the vertical center as you type.
3. Enable Sentence focus. Only the current sentence is full color; the rest dims.
4. Switch to Paragraph focus. The current paragraph is full color; siblings dim.
5. ⌘\\ hides the title bar; press again to restore.
6. ⌘⇧F enters full-screen with no-chrome already on; ⌘⇧F again exits.
7. Toggle "Show goal indicators" — the bottom-right capsule (word count + reading time) appears or disappears.
8. ⌘S flashes "Saved" briefly at the top of the editor (autosave is real; this is just the muscle-memory reflex).

If all eight pass, milestone 1c is healthy.

## Tests

    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO

Expect 90 tests passing — 33 from milestone 1a (project model, factory, store, recents), 44 from milestone 1b (Token, Theme, TypographySettings, ThemeManager, MarkdownTokenizer, SmartTypography, ProseMode), and 13 from milestone 1c (extended ThemeManager focus prefs + FocusFinder).
