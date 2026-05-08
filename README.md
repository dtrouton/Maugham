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

## Phase 1d smoke test

Once running on milestone-1d:

1. New Project → Novel → name it "Smoke Novel". Three-pane window opens with Chapter 1 in the binder.
2. Right-click Chapter 1 → New Document. Renames inline to "Chapter 2".
3. Right-click Chapter 1 → New Group. Renames inline to "Act One".
4. Right-click Act One → New Document. Renames inline to "Scene 1". Verify file path in Finder includes `03-act-one/01-scene-1.md`.
5. Type prose in Chapter 2; word count in inspector and goal indicator update live.
6. Inspector Status = Revising. Binder dot for Chapter 2 turns orange.
7. ⌘⇧, → Customize for this project → font size 22 → Done. Reopen project. Typography persists.
8. File → Open Recent → Smoke Novel. Re-opens.
9. Help → Set up Claude Desktop. Copy snippet. Paste anywhere — JSON contains the project path.
10. Right-click Chapter 2 → Delete. Disappears from binder; appears in Finder Trash.

If all ten pass, milestone 1d is healthy.

## Phase 1e smoke test

Once running on milestone-1e:

1. Open a project, type a sentence, wait ~1s; in Finder verify the file's modified date updated. Autosave is invisible.
2. ⌘S while typing → "Saved" flash appears, file's modified date updates to now.
3. Type, close window before 750ms elapses, reopen; sentence persisted.
4. Edit a manuscript file via Terminal while Maugham is open. Banner: "Outside change detected".
5. Click **Keep mine**. Disk has your version; cloud version archived under `.maugham/conflicts/`.
6. Repeat with **Use cloud**. Disk has cloud version; your version archived under `.maugham/conflicts/`.
7. Edit `project.maugham.json` in TextEdit. Maugham reloads silently; previous manifest archived.
8. Switch documents, close, reopen. Same document selected. Toggle no-chrome, close, reopen. State restored.
9. In a long chapter, leave cursor near the end. Switch chapters. Switch back. Cursor restored to where you left it; editor scrolls to make it visible; no extra click needed to start typing.
10. Paste a multi-line block at the end of a chapter. Cursor lands at end of pasted text; view stays scrolled with the cursor.

If all ten pass, milestone 1e is healthy.

## Phase 2a smoke test

Once running on milestone-2a:

1. Open a Novel. Drag chapter 3 to position 1. Filenames renumber 01/02/03 and the editor binding stays valid.
2. Drag a chapter from Act One to Act Two. File moves between folders; binder updates.
3. Drag a group into another group. Folder physically moves; descendants follow.
4. Right-click a chapter → Duplicate. "Copy of <title>" appears as next sibling, in inline rename mode.
5. Right-click a group → Duplicate. Group + all descendants deep-copied with fresh ids.
6. Delete chapters in a group leaving NN gaps. Right-click → Tidy Filenames → confirm. Remaining chapters renumber contiguously.
7. File → Tidy All Filenames → confirm. Every group's NN sequence compacts.
8. Force-quit mid-reorder, reopen. `.maugham/scratch/` stragglers are logged in console; project loads without crashing.

If all eight pass, milestone 2a is healthy.

## Phase 2b smoke test

Once running on milestone-2b:

1. Open a Novel. Click `Research` segment at the top of the binder. Empty state shows in the editor pane.
2. Drag a JPEG from Finder into the research pane. Image renders inline at fit-to-pane.
3. Drag a PDF in. Click; PDFKit scrolls.
4. Right-click → New Group "Locations". Drag the PDF into the group. File physically moves; preview still works.
5. Right-click → Add Link… title "Maugham Wiki" + URL. WKWebView loads.
6. Paste an image (⌘V). New `pasted-…png` appears.
7. Click `Manuscript`. Binder restores; manuscript editor reopens with per-segment selection.
8. Click `Research`. Per-segment selection restored.
9. Edit a manuscript chapter externally so a conflict fires. Banner appears with Show diff. Click; side-by-side diff sheet opens. Click `Keep mine` on the left to dismiss; mine wins.
10. Repeat conflict; click `Use cloud` on the right. Cloud version persists; mine archived under `.maugham/conflicts/`.

If all ten pass, milestone 2b is healthy.

## Phase 2c smoke test

Once running on milestone-2c:

1. Open a Novel. Inspector shows Tags / Word target / Links / Linked from sections under Synopsis.
2. Type tags, set Word target via Stepper. Goal indicator updates with target progress + today's words.
3. Add a Link to another doc via the + popover. Open that doc; backlink appears in its Linked from section.
4. Type `[[Chapter 2]]` in a body. Renders blue + underlined; click navigates to that chapter.
5. Type ~200 words. Idle 30 min (or temporarily lower `DocumentStore.sessionIdleThreshold` to 30s to test). A session lands in `.maugham/sessions.json`.
6. File → Show Project Statistics. Window opens.
7. Project total shows correctly. Heatmap stretches to pane width with per-month labels (Feb / Mar / Apr / May).
8. Click a chapter bar — project window comes forward with that chapter selected.

If all eight pass, milestone 2c is healthy.

## Tests

    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO

Expect 265 tests passing — 33 from 1a (project model, factory, store, recents), 44 from 1b (Token, Theme, TypographySettings, UserPreferences, MarkdownTokenizer, SmartTypography, ProseMode), 13 from 1c (UserPreferences focus prefs + FocusFinder), 53 from 1d (Slugifier, FileNaming, ProjectStore mutations, project typography, factories, ScreenplayMode, WritingModeFactory), 30 from 1e (UIState, ConflictState, DebounceScheduler, plus 15 integration tests against real NSFileCoordinator + NSFilePresenter for DocumentStore lifecycle, save, document conflict, conflict resolution, manifest conflict), 26 from 2a (8 RenamePlan, 5 DropIntent, 5 reorder integration, 4 duplicate integration, 4 tidy integration), 34 from 2b (10 LineDiff, 6 ResearchKindInference, 4 UIState migration, 14 ProjectStoreResearch integration), and 32 from 2c (2 StructureItem Codable, 8 SessionLog, 7 SessionTracker, 7 WikiLinkTokenizer, 5 ProjectStoreInspector, 3 DocumentStoreSession).
