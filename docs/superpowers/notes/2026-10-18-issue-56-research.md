# Issue #56 — research before the plan (2026-10-18)

Re-verification of every finding in #56 (filed 2026-08-28) against `main` at
`baf82aaa`. Line numbers below are current. PR #89 (canvas read-only, #44) is
NOT on main and its guide edits are ignored except where they bear on M6.

Verdicts: **STILL TRUE** / **PARTLY** / **FIXED** / **OBSOLETE**.

---

## A — Backups & History topic

### H1 — no Backups topic: **STILL TRUE**

`grep -i backup docs/guide/*.md` finds only incidental mentions (getting-started
:178/180 point at "Restore from Backup…"; people-and-devices and
publish-department use "backup" for unrelated things). No topic in
`docs/guide/index.json` (17 topics, people-and-devices now 16, reference 17).

Facts and verbatim strings:

- **Settings → Backups** (`Maugham/Views/SettingsTabs/BackupSettingsTab.swift`)
  - Section title **"Backup destinations"** (:9). Empty state (:11):
    *"No destinations. Add a folder outside iCloud (a local folder, external
    drive, or a Dropbox/Drive-synced folder) to keep verified copies of your
    projects."*
  - Per row: name, path, **"Keep N"** + stepper 1…50 (:30-34), trash button.
  - **"Add destination…"** (:43) → folder panel, prompt *"Choose a backup
    folder (outside iCloud)."* (:63). New destination defaults to **Keep 10** (:73-80).
  - Caption (:46): *"Backups run automatically when you save (⌘S). A copy is
    verified, then written to each destination; a corrupt project is detected
    and skipped rather than backed up."*
  - Tip (:49): *"Tip: local folders use copy-on-write, so keeping many
    generations is nearly free. For a cloud-synced folder (Dropbox, OneDrive,
    Drive) each generation re-uploads, so lower its count (2 is a good default)
    — Maugham can't tell a synced folder from a local one, so the choice is yours."*
- **What ⌘S does** (`Maugham/Views/ProjectWindow.swift:4360-4390`): flushes
  typing, writes the auto-labelled checkpoint, then runs `backupNow` —
  *regardless of whether the checkpoint landed*. **⌘⇧S (named checkpoint) does
  NOT run a backup** (only the ⌘S handler calls `backupNow`; :4317 path has
  none). The guide should say "plain ⌘S", not "saving".
- **What a backup copies** (`Packages/MaughamCore/Sources/MaughamCore/BackupWriter.swift`):
  the whole project folder (every regular file, symlinks excluded, :14-15),
  copied to `<destination>/<generation>/` via a hidden `.partial-<id>/` plus a
  verified manifest, then renamed into place (:41-84). Old generations pruned
  to the destination's Keep count (`BackupRunner.swift:85`). An unchanged
  project is skipped (`BackupSignature.swift` ignores `sessions.json`,
  `ui-state.json`, `scratch/`, `conflicts/` and the checkpoint streams,
  :19-56) — so idle ⌘S presses don't churn generations. Writer-level wording:
  "a full copy of the project folder, verified, kept as a numbered generation;
  nothing is written if nothing changed since the last one."
- **File → Restore from Backup…** still exists — `MaughamApp.swift:198`
  (`FocusedRestoreButton`, :609-618), between the ⌘R/⌘⇧R pair and Tidy All
  Filenames; disabled with no project window. Opens window **"Restore Backup"**
  (`MaughamApp.swift:406`).
- **Restore window** (`Maugham/Views/RestoreWindow.swift`): title
  *"Restore <project>"* (:23); empty state **"No backups found"** / *"No backup
  generations exist for this project yet."* (:27-29); each generation shows its
  date and destination folder, with an icon whose tooltip is *"Integrity
  verified"* or *"This generation failed verification"* (:40-45 — the labels
  "Verified"/"Corrupt" are icon-only, so the guide should describe the green
  seal / orange triangle and quote the tooltips); buttons **Cancel** /
  **"Restore a Copy…"** (:54-55). Save panel message *"Choose where to restore
  a copy of this project."*, default name *"<project> (restored)"* beside the
  original (:76-78); refuses an existing target; reveals the copy in Finder
  (:85). Never restores in place. Failure: *"Restore failed: …"* (:88).
- **Paused banner** (`Maugham/Views/BackupRecoveryBanner.swift:18-24`):
  *"Backups paused — this project failed an integrity check"* /
  *"New saves aren't being backed up until this is resolved."* + **Restore…**
  (opens the same window).

### H3 — History's revert is one clause: **STILL TRUE**

The one mention is now `right-pane.md:228` ("a read-only timeline of edits,
annotations, and checkpoints, with a scrubber for time-travel").

- **Filter chips** (`HistoryPane.swift:46-56`): **All / Checkpoints / Edits /
  Annotations / External**. Empty states (:249-253): *"No history yet"*,
  *"No checkpoints"*, *"No edits"*, *"No annotations"*, *"No external edits"*;
  External's caption (:278) *"External edits to the .md file (e.g. via another
  editor or sync) show up here."* — NB this sits awkwardly beside the CLAUDE.md
  invariant that outside `.md` edits are not honoured; describe the chip
  neutrally, don't promise anything.
- **Checkpoint labels** (`Maugham/OpLog/CheckpointCapture.swift:114-132`):
  ⌘S auto-label `HH:mm — N words (Document)`; the parenthetical names the
  document you were in and is omitted when you were in none; words are the
  whole project's. ⌘⇧S sheet (`CheckpointLabelPromptSheet.swift:10-17`):
  **"Name this checkpoint"**, placeholder *"e.g. end of draft 2"*, **Cancel /
  Save**. A checkpoint is a bookmark in the history (no files copied) and
  covers manuscript text only — that is the difference from a backup.
- **Row verbs** (`HistoryPane.swift:1715, 1727, 1732`): a checkpoint row's
  **"Revert here…"**; an edit row's **"Rewind to before this…"** (tooltip
  *"Rewind to before this point…"*). Both drawn only where this Mac may write
  the text (people-and-devices.md:416-421 already says so).
- **Revert sheet** (`PartialRestorePicker.swift:325-358`): *"Revert to
  “<label>”"*, picker **Scope**: **Whole project** / **Document: <title>**,
  **Cancel / Revert**, then **Done**; lists only documents this Mac may write,
  and names the ones left alone in Replace All's sentence
  (`ProjectStore.leftAloneSentence`, :200-203). Revert is disabled until a scope
  is chosen when the checkpoint named no document.
- **Rewind window** (`RewindWindow.swift`): header **REWINDING**, **Doc / Diff**
  toggle (:91-98), scrubber, **Cancel / "Snapshot here…" / "Restore here…"**,
  confirm *"Restore <doc> to this point?"* → **Restore** (:260-289). Undoing a
  restore is already in annotations-and-suggestions.md:87.
- **Unreadable-checkpoint notice** (`HistoryPane.swift:285-289`): *"Some
  checkpoints can’t be read (<files>). They are still in the file — check
  permissions or iCloud sync."*, tooltip lists *name — reason* per file.
- **P3 additions in History** (set-aside records + Retry/Acknowledge, held
  lines + Admit…/Send to Inbox, "what this book is missing" + Acknowledge,
  trust events, the two signing sentences, recovered-history **View**): ALL
  already documented — `getting-started.md:184-` ("Who wrote your history"),
  `people-and-devices.md` §§ *What this book is missing* (:552), *What History
  tells you* (:567), Revoking/Retiring (:261/308). **Do not duplicate — the new
  topic gets one paragraph pointing at those two anchors.**

### L1 — on-disk layout: **STILL TRUE, and worse than reported**

`reference.md:56-79`. Missing: `.maugham/ops/` (the actual manuscript history),
`.maugham/checkpoints.<device>.jsonl`, `Exports/`, `canvas.md`,
`canvas_assets/`, `.maugham/canvas.json`, `.maugham/publish/`,
`.maugham/diagnostics/`, `.maugham/inbox/`, `.maugham/devices/` +
`.maugham/people/` (the register — people-and-devices topic). **Two errors**:
the tree puts trash at `.maugham/.trash/`; it is `<project>/.trash/`
(`TrashStore.swift:45,57`). Same wrong path in `reference.md:101` and
`research.md:36`. Also "`notes/` — for Claude-authored notes (future use)"
— the folder is still created (`ProjectFactory.swift:35`) but nothing writes
it; keep or drop the row, don't promise a future. Also: the sentence under it
("the files themselves are readable in any text editor") should add that the
`.md` is rendered *from* the history and edits made outside Maugham are not
kept (CLAUDE.md hard invariant; already said in getting-started:175 /
editor-and-focus).

### L2 — Troubleshooting lacks "won't open" / "older version": **STILL TRUE**

`reference.md:85-101`. Add two entries pointing at
`getting-started.md#troubleshooting-a-document-that-wont-open` (heading at
:173) and the new topic. Fix :101's trash path while there — and the Trash is
now a disclosure at the foot of the tree (CLAUDE.md Views row), so "look in
the folder directly" is no longer the advice.

### L3 — unlistable ops folder advice: **STILL TRUE**

`getting-started.md:180` says only "Restore from a backup". App
(`DocumentRecoveryPane.swift:82-84`): *"<reason>. Check the folder’s
permissions (.maugham/ops), then reopen — or restore from a backup."* Lead with
the permissions check; link "restore from a backup" to the new topic. Also
link :178's **Restore from Backup…**.

### Also in A (new, tiny): `reference.md:13`

"`⌘S` | Save flash (autosave is automatic)" undersells it — ⌘S writes a
checkpoint and runs backups. Suggest: "Checkpoint (and back up, if you've set
a destination) — autosave is automatic".

---

## B — Working a batch (H2): **STILL TRUE**

`review-passes.md:65-67` still promises bulk actions in Annotations &
Suggestions; `annotations-and-suggestions.md:61` is still the only mention.

Facts (`Maugham/Views/AnnotationBulkActions.swift`,
`Maugham/Views/AnnotationsPane.swift`, `Maugham/Views/Review/AnnotationsQueueToolbar.swift`):

- Entry: the toolbar's checklist button, tooltip *"Select several notes and
  answer them together"* / *"Leave selection mode"*
  (`AnnotationsQueueToolbar.swift:232-241`). Only in **This Piece** scope.
- Bar (`AnnotationsPane.swift:~1575-1600`): **Select All / Deselect All**;
  count *"All N shown"* / *"N selected"*; the verb acts on the selection, else
  on everything the filters show.
- Verbs: **Triage** menu (tooltip *"Mark what you plan to do about all of
  these"*; items are the triage marks + **Clear**), **Accept**, **Stet**.
  Accept tooltip: *"Answer these at once. ⌘Z reverses the batch — except for
  accepted suggestions, where it reaches only the last; use a row's Revert for
  the others."* Stet tooltip: *"Read, considered — and the words stand.
  Resolves these without applying or refusing anything."*
- Titles honest before the click (`AnnotationBulkActions.swift:200-206`):
  *"Accept 4 of 6"*, *"Accept 4 selected"*, *"Accept all 4"*.
- Reach = the row's own reach (:17-52, :180-191): Accept → open notes only,
  never a question (a question needs a typed **Reply…**), never a suggestion
  whose passage has changed (it would need *Apply anyway*); Stet → open notes;
  Triage → any note not already carrying that mark.
- Failures → one notice (:230-255): *"N of M accepted."* plus e.g. *"One
  suggestion could no longer be applied — the passage it would replace is no
  longer in its paragraph."* / *"Those notes stay open; ask Claude for fresh
  suggestions against the current text."* / *"N more could not be completed."*
- Undo: one ⌘Z reverses the batch; triage gives each note back its own
  earlier mark; suggestion accepts — only the last is reachable by ⌘Z, Revert
  on the row for the rest (the tooltip already says so).
- Posture: a verb this Mac may not use in this piece isn't drawn; if none
  survive, no bar (`AnnotationBulkActions.swift:167-178`). One sentence + link
  to people-and-devices#what-their-mac-shows-them.

**Undo declines — now wider than the issue (#41 + #51 + #79):**
`Maugham/OpLog/Document.swift:480-556`, `UndoDecline.sentence(count:)`. None
of these are in the guide. Plural forms (singular in source):

- drift: *"Couldn't undo stetting 2 notes — they changed on another device."*;
  same shape for accepting / rejecting / archiving / reopening notes, triage
  marks, annotation edits; *"Couldn't put back 2 notes' earlier resolutions —
  they're open again."*
- permit: *"Couldn't change 2 notes — this Mac can no longer answer notes in
  this piece."*, tasks (*"…can no longer file tasks in this piece."*), restores
  (*"Couldn't undo 2 restores — this Mac can no longer change this piece's
  text."*), suggestions (*"Couldn't undo 2 suggestions — this Mac can't change
  this piece's text right now."*).

Recommendation: put the decline paragraph at the end of the existing
"Undoing reject, archive, and your own notes" section
(`annotations-and-suggestions.md:65-77`) — it covers single undos too — and
have "Working a batch" point to it. Quote two representative sentences, not
all twelve.

---

## C — Doc-truth smalls

- **M1 — STILL TRUE.** `right-pane.md:210` still says ⌘⌥I hides the study
  column ("hiding the whole right column (⌘⌥I)" and "⌘⌥I again"). ⌘⌥I is the
  Inspector pane (`MaughamApp.swift:263-264`) and, as a ⌘⌥-letter, *ends* the
  study per the same paragraph. The column toggle is ⌘⌥0, **"Toggle
  Inspector"** in the View menu (`MaughamApp.swift:247-250`). Replace both with
  ⌘⌥0. (Menu title "Toggle Inspector" vs reference.md:50 "Toggle inspector
  column" — fine, but the guide may want to name the menu item.)
- **M2 — STILL TRUE.** `KeyboardShortcuts.swift:71,72,77`: "Research pane"
  ⌘⌥R, "Outline pane" ⌘⌥O, "Palette pane" ⌘⌥P. Menu titles are now
  **Research / Outline / Palette** but they reveal tree sections / select the
  project row (`MaughamApp.swift:265-296`). Relabel per reference.md:36-41:
  "Reveal Research section", "Select project row (outline)", "Reveal Palette
  section". Optional same-commit: "Plan mode"…"Publish mode" (:66-69) — the
  guide calls them personas (reference.md:30-33); "Toggle inspector column"
  could match the menu ("Toggle Inspector").
- **M3 — STILL TRUE.** ⌘? = **Help → Maugham Help** (`MaughamApp.swift:659-662`).
  Absent from reference.md and from the cheatsheet's Help category
  (`KeyboardShortcuts.swift:88-90`, only "Syntax Reference" ⌘/). Add both.
  Note ⌘/ is titled **"Syntax Reference"** in the menu (:678-681); reference.md:52
  says "Syntax + keyboard reference" — OK.
- **M4 — STILL TRUE, and wider.** `claude-desktop.md:38-47` Write list.
  `MCPToolCatalog.all` (`Maugham/MCP/MCPTool.swift`, 60 tools) has these
  write-capable tools the list omits: publish templates/config
  (`InitializePublishTemplateTool`, `SetPublishConfigTool`,
  `WritePublishFileTool`, `DeletePublishFileTool`), per-piece styles
  (`SetPieceStyleTool`, `ClearPieceStyleTool`), making books
  (`CompileTool`, `PreviewCompileTool`, `CompileCancelTool`, `RepublishTool`),
  and translations (`WriteTranslationTool`). Also "Add text notes and suggested
  changes" understates `AddQueryTool`/`AddCraftNoteTool` (questions and craft
  notes). Fix-shape: three capability bullets — *set up and edit your book's
  design and publishing settings, and compile it* → publishing.md; *write a
  translation of a chapter for you to review* → translation-review.md; widen
  the annotations bullet to "notes, questions, craft notes and suggested
  changes". No tool names (guide stance).
- **M5 — STILL TRUE.** `publish-department.md:325-339` ("The brief and
  rulings") never says Claude reads the brief. Add after :333: *"Claude reads
  this brief too, whenever you ask it to translate from Claude Desktop, so a
  decision made here doesn't have to be made again."* (shape of
  right-pane.md:176). The desk's own translators are already briefed on it
  (:234).
- **M6 — PARTLY / superseded by #89.** Main still has only the Send-to-Canvas
  refusal (`getting-started.md:154`); Claude's refusal is
  `canvas_sidecar_unreadable` (`Maugham/MCP/Tools/CanvasTools.swift:528-535`;
  the issue's file was wrong). PR #89 rewrites :154 and adds a "When the
  canvas is read-only" subsection that says *"…you cannot edit, add or promote
  anything, and neither can Claude or the Inbox."* That covers M6.
  **Recommendation: drop M6 from this branch and note it closed by #89.** If
  #89 is delayed, add one bullet at the END of the "What Claude can put on the
  canvas" list (after current :171) — #89 does not touch that list, so it
  merges cleanly — but don't touch :154-158.
- **L4 — STILL TRUE.** `Maugham/Views/Publish/DepartmentPane.swift:392-401`
  (path moved to `Views/Publish/`): with a chapter unreadable and no editions,
  the desk shows only *"Couldn’t read <title>"* (:881-883) + reason and
  **Add Language…**, and withholds *"No translations yet."* (:871).
  `publish-department.md:24-28` describes the unreadable line; add one clause:
  "and if the book has no editions yet it says only that — not *No
  translations yet.*, which it can't know."
- **L5 — PARTLY.** **File → "Share for Review…"** still exists
  (`MaughamApp.swift:213`, `FocusedShareForReviewButton` :620-632) and is
  still undocumented. What it does (`ProjectShareSheetPresenter.swift`): opens
  macOS's share picker (Collaborate) when the project is in iCloud Drive;
  otherwise an alert *"Move this project to iCloud Drive to share it"* /
  *"To review with others, this project needs to be in iCloud Drive. Move the
  project folder to iCloud Drive, then use Share → Collaborate to invite
  reviewers."* A pill reads *"Shared by <owner>"* / *"Shared"*
  (`SharingStatusPill.swift:30-32`). The OTHER half is FIXED:
  `annotations-and-suggestions.md:13` no longer says "resolves you as a
  reviewer on someone else's shared project" — it now speaks of the book's
  owner admitting you as a reviewer (permits), linking people-and-devices.
  people-and-devices.md:269 and :461 already explain that the iCloud share is
  not the permission. Fix-shape: a short "Sharing the folder" paragraph in
  **people-and-devices.md** (beside :461), naming the menu item, the iCloud
  Drive requirement, the read-only/read-write lock fact, and that what
  somebody may *write* is set by admission — not a subsection in annotations.
  *Product question below on the item's name.*

---

## D — Enforcement (E1)

House shape (`MaughamTests/DocSyncTests.swift`): a `static` pure parser, a
real-source assertion with an anti-vacuity floor/control, and a separate
`…WouldFireOnPlantedOffender` test feeding the parser a planted string and
asserting it is reported missing. Repo root via `#filePath`.

1. **Index census — OBSOLETE as stated.** `MaughamTests/GuideDocsDriftTests.swift:12-25`
   (`test_indexMatchesFilesExactly`, since 2026-06-16) already compares
   `index.json` slugs to `docs/guide/*.md` both directions, plus non-empty and
   bundling checks. It lacks only the planted-offender half. Optional small
   add: factor a `static func indexDrift(slugsInIndex:slugsOnDisk:)` and a
   self-check. Don't add a duplicate in DocSyncTests.
2. **Link + anchor resolver — STILL NEEDED.** Nothing exists. Today's guide is
   clean (scripted check 2026-10-18: zero broken inter-topic links or anchors)
   once two things are handled: links inside code spans must be skipped
   (`research.md:12` has `![alt](./image.png)` in backticks), and paths
   leaving `docs/guide/` resolve against the repo (`research.md:36` →
   `../adr/0006-trash-and-undo.md`, exists). Anchor rule: GitHub's — lowercase,
   strip markup (`*`, `` ` ``, `_`, link syntax), drop punctuation except `-`
   and space, spaces→`-`, duplicate headings get `-1`, `-2`. Skip fenced code
   blocks when collecting headings. Planted offender: a fixture string with
   `[x](reference.md#no-such-heading)` and `[y](no-such-topic.md)` → both
   reported; converse: a known-good real anchor
   (`getting-started.md#who-wrote-your-history`) is not.
   NB (out of scope, worth one line in the plan): the in-app renderer
   (`GuideMarkdownView`) does not route `.md` links between topics, so these
   links work on GitHub only.
3. **Every `.keyboardShortcut(` in `MaughamApp.swift` has a `reference.md`
   row — STILL NEEDED.** Current extractor
   (`extractCommandOptionShortcutTokens`, :126-145) only matches
   `modifiers: [ … ]` lists containing both ⌘ and ⌥. To widen it must handle:
   bare `modifiers: .command` (most of the file: :162, :166, :175, :225-237,
   :352, :356, :564, :662, :681); non-string keys (`.return` → `↩`, :604);
   escaped `"\\"` → `\`; glyph order ⌘⌥⇧ matching the docs (`⌘⇧S`, `⌘⇧,`,
   `⌘⇧↩`, `⌘⌥⇧R`). Today exactly one binding is undocumented: **⌘?**. Caveat:
   reference.md:28 writes `` `⌘\\` `` inside a code span, which renders as two
   backslashes on GitHub (escapes don't apply in code spans) — the current
   raw-text match only "works" because the source's `"\\"` is also two
   characters. Fix the doc to `` `⌘\` `` and unescape in the extractor, or the
   new test will either pass for the wrong reason or flag it. Keep the
   existing ⌘⌥ test and its two self-checks; the widened one should get its own
   planted offenders (bare `.command`, `.return`, `"\\"`). Apply the same token
   list to the cheatsheet (`KeyboardShortcuts.all`) only if the plan wants the
   cheatsheet to be complete — it is "curated" by its own doc comment; at
   minimum ⌘? belongs there (M3).
   Label truth (M2) stays a review check.

---

## New gaps (writer-visible, shipped since 2026-08-28, no guide coverage)

- **People & Devices / admission / permits / person key** — COVERED
  (`people-and-devices.md`, 678 lines, index order 16). Nothing to do beyond L5.
- **Updates (#67, 2026-10-18)** — NO coverage. App menu **"Check for Updates…"**
  (titles vary: *Checking for Updates…*, *Downloading Update…*, *Install
  Update…*, *Installing…* — `Maugham/Updates/UpdateMenuCommand.swift:34-41`),
  the banner *"Maugham <v> is ready"* with **Dismiss / "Restart & Update"**
  (`UpdateBannerView.swift:55-62`), a refused-install notice, and the
  twice-refused "check by hand" sentence. **Separate issue** — strings were
  rewritten yesterday and dev builds hide the updater; a short reference.md
  entry would do.
- **Translation pipeline / round report / imprints** — covered
  (`translation-review.md`, `publish-department.md`, `publishing.md`).
- **Two loops, first reader, lessons** — covered (`compiler.md`,
  `review-passes.md`).
- **In-app Help doesn't follow inter-topic links** (see D2 note) — **separate
  issue** (code, not docs).
- **`research.md:36` links an ADR** from a writer's guide (design doc, dead
  in-app) and repeats the wrong trash path — **in scope (small)**, fold into C.

---

## Recommended tasks (≤ 6)

1. **New topic `backups-and-history.md`** (H1 + H3) — checkpoint → History →
   revert/rewind → backup → restore a copy → paused banner; one paragraph
   pointing at getting-started#who-wrote-your-history and
   people-and-devices#what-history-tells-you for the signing/held/set-aside
   rows. Add to `index.json` (after `right-pane` or before `reference`;
   renumber `order`). Link from getting-started:178/180 and right-pane:228.
2. **reference.md + getting-started fixes** (L1 + L2 + L3 + ⌘S row + trash
   path in reference.md:78/:101 and research.md:36) — layout tree, two
   Troubleshooting entries, permissions-first advice.
3. **Annotations: "Working a batch" + undo declines** (H2 + #41/#51/#79
   sentences) in `annotations-and-suggestions.md`; fix review-passes.md:65-67's
   pointer to name the new section anchor.
4. **Doc-truth smalls** (M1, M3 row in reference.md, M4, M5, L4, L5 paragraph
   in people-and-devices.md). M6 dropped in favour of #89.
5. **Cheatsheet** (M2 relabels + M3 ⌘? entry) in `KeyboardShortcuts.swift`,
   plus `⌘\` doc fix.
6. **Tests** — DocSyncTests: link/anchor resolver (+ planted offender);
   all-bindings-in-reference.md extractor (+ planted offenders for bare
   `.command`, `.return`, `"\\"`); optional planted-offender for
   GuideDocsDriftTests' existing index census. Lands with/after task 5 so ⌘? is
   pinned the day it's written. Run `./gen.sh` only if a new test FILE is added.

## Product questions for Denver

1. **"Share for Review…"** — sharing the folder no longer makes anyone a
   reviewer (that's set in People & Devices now). Keep the menu name, or rename
   it to something like "Share Project Folder…"? The guide will describe
   whatever ships.
2. **Named checkpoints (⌘⇧S) don't run a backup; plain ⌘S does.** Intended?
   The guide will say so either way.
